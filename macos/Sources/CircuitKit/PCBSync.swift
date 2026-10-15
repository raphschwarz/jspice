import Foundation
import KiCadKit

/// The schematic and its board kept as one, as Eagle's and Fusion's forward and back annotation keep them: what was
/// changed on the board since the two were last together (a part renamed, given another value or footprint, marked not
/// to be fitted, deleted) is brought back to the schematic, and then the board is brought up to date with the
/// schematic (KiCad's netlist updater: parts added, exchanged and removed, nets reconnected). Each difference is known
/// to be the board's or the schematic's by what the board had when they were last together (PCBDesign.synced); where
/// both changed the same thing, the schematic's change stands. A part deleted on the board is not deleted from the
/// schematic without asking: until it is decided, it is left off the board.
public enum PCBSync {
    public enum Change: Hashable, Sendable, CustomStringConvertible {
        /// A part renamed on the board
        case reference(parts: [UUID], from: String, to: String)
        /// A part given another value on the board
        case value(parts: [UUID], reference: String, from: String, to: String)
        /// A part given another footprint on the board
        case footprint(parts: [UUID], reference: String, from: String, to: String)
        /// A part marked on the board as not to be fitted, or to be fitted again
        case doNotPopulate(parts: [UUID], reference: String, Bool)
        /// A part deleted on the board: to be deleted from the schematic too, or put back
        case removed(parts: [UUID], reference: String)

        public var description: String {
            switch self {
            case .reference(_, let from, let to): return "\(from) renamed \(to) on the board"
            case .value(_, let ref, let from, let to): return "\(ref)'s value changed from \(from) to \(to) on the board"
            case .footprint(_, let ref, let from, let to): return "\(ref)'s footprint changed from \(from) to \(to) on the board"
            case .doNotPopulate(_, let ref, let dnp): return dnp ? "\(ref) marked not to be fitted on the board" : "\(ref) to be fitted again"
            case .removed(_, let ref): return "\(ref) deleted from the board"
            }
        }

        public var parts: [UUID] {
            switch self {
            case .reference(let p, _, _), .value(let p, _, _, _), .footprint(let p, _, _, _), .doNotPopulate(let p, _, _), .removed(let p, _):
                return p
            }
        }
    }

    public struct Result {
        /// The circuit with the board's changes brought back (and its PCBDesign brought up to date)
        public var circuit: Circuit
        /// The netlist the board was brought up to date with
        public var netlist: PCBNetlist
        /// What updating the board did
        public var report: NetlistUpdater.Report
        /// The board's changes brought back to the schematic
        public var applied: [Change]
        /// Parts deleted on the board, waiting for the user's word: delete them from the schematic, or put them back
        public var removed: [Change]
        /// What could not be brought back (a value JSpice cannot read for its part)
        public var warnings: [String]
        /// The schematic's parts each footprint stands for, by reference
        public var parts: [String: [UUID]]
        /// The parts left without a footprint
        public var unassigned: [String]
        public var notes: [String]

        /// Whether the schematic (the circuit or what it keeps of its board) changed
        public let circuitChanged: Bool
    }

    /// Brings `board` and `circuit` together. `putBack` names parts deleted on the board that are to go back on it.
    public static func sync(_ circuit: Circuit, board: KiCadBoard, library: KiCadFootprintSource,
                            putBack: Set<UUID> = [], options: NetlistUpdater.Options = NetlistUpdater.Options()) -> Result {
        var circuit = circuit
        let original = circuit.pcb ?? PCBDesign()
        var design = original
        let before = PCBNetlistBuilder.netlist(circuit, design: design)
        var applied: [Change] = []
        var removed: [Change] = []
        var warnings: [String] = []

        // the board's changes since the two were last together
        var footprintsByPath: [String: KiCadFootprint] = [:]
        for footprint in board.footprints { if let path = footprint.path { footprintsByPath[path] = footprint } }
        for component in before.netlist.components where !component.excludeFromBoard {
            let parts = before.parts[component.reference] ?? []
            guard let synced = original.synced[component.path] else { continue }
            guard let footprint = component.paths.lazy.compactMap({ footprintsByPath[$0] }).first
                    ?? board.footprints.first(where: { $0.path == nil && $0.reference == synced.reference }) else {
                // gone from the board
                if !parts.isEmpty && !parts.contains(where: putBack.contains) {
                    removed.append(.removed(parts: parts, reference: component.reference))
                }
                continue
            }
            if footprint.reference != synced.reference && component.reference == synced.reference && !footprint.reference.isEmpty {
                applied.append(.reference(parts: parts, from: component.reference, to: footprint.reference))
            }
            if footprint.value != synced.value && component.value == synced.value {
                applied.append(.value(parts: parts, reference: component.reference, from: component.value, to: footprint.value))
            }
            if footprint.libID != synced.footprint && component.footprint == synced.footprint {
                applied.append(.footprint(parts: parts, reference: component.reference, from: component.footprint, to: footprint.libID))
            }
            let dnp = footprint.attributes.contains("dnp")
            if dnp != synced.doNotPopulate && component.doNotPopulate == synced.doNotPopulate {
                applied.append(.doNotPopulate(parts: parts, reference: component.reference, dnp))
            }
        }
        for change in applied { warnings += apply(change, to: &circuit, design: &design, components: before) }
        for id in putBack {
            // to go back on the board: as if it had never been there
            if let component = before.netlist.components.first(where: { c in before.parts[c.reference]?.contains(id) == true }) {
                design.synced[component.path] = nil
            }
        }

        // then the board brought up to date with the schematic, the parts deleted on it left off until decided
        circuit.pcb = design
        let after = applied.isEmpty ? before : PCBNetlistBuilder.netlist(circuit, design: design)
        var netlist = after.netlist
        let waiting = Set(removed.flatMap(\.parts))
        for k in netlist.components.indices where (after.parts[netlist.components[k].reference] ?? []).contains(where: waiting.contains) {
            netlist.components[k].excludeFromBoard = true
        }
        // what was put on the board without the schematic (mounting holes, logos, test points) stays
        var updateOptions = options
        updateOptions.deleteOnlyLinked = true
        let hadFootprints = !board.footprints.isEmpty
        let report = NetlistUpdater.update(board, to: netlist, library: library, options: updateOptions)
        if hadFootprints { spread(board, added: report.added) }

        // what the board now has, as the common ground for the next time; the parts deleted on it, until decided, as
        // they were
        design = after.design
        design.synced = [:]
        for footprint in board.footprints {
            guard let path = footprint.path, netlist.components.contains(where: { $0.paths.contains(path) }) else { continue }
            design.synced[path] = PCBDesign.Synced(reference: footprint.reference, value: footprint.value, footprint: footprint.libID,
                                                   doNotPopulate: footprint.attributes.contains("dnp"))
        }
        for component in before.netlist.components where (before.parts[component.reference] ?? []).contains(where: waiting.contains) {
            design.synced[component.path] = original.synced[component.path]
        }
        circuit.pcb = design
        return Result(circuit: circuit, netlist: netlist, report: report, applied: applied, removed: removed, warnings: warnings,
                      parts: after.parts, unassigned: after.unassigned, notes: after.notes,
                      circuitChanged: !applied.isEmpty || design != original)
    }

    /// A new board for `circuit`: its parts arranged as the schematic has them, read left to right and top to bottom,
    /// in an outline round them
    public static func newBoard(_ circuit: Circuit, title: String, library: KiCadFootprintSource, date: Date = Date()) -> (KiCadBoard, Result) {
        let board = KiCadProject.newBoard(title: title, date: date, company: "JSpice", copperLayers: circuit.pcb?.copperLayers ?? 2)
        let result = sync(circuit, board: board, library: library)
        // in the schematic's order: rows of parts by where they are in it
        var hints: [String: KiCadPoint] = [:]
        for footprint in board.footprints {
            if let c = result.netlist.components.first(where: { $0.paths.contains(footprint.path ?? "") }), let hint = c.placementHint {
                hints[footprint.uuid] = hint
            }
        }
        let order = board.footprints.sorted { a, b in
            let (pa, pb) = (hints[a.uuid] ?? KiCadPoint(1e9, 1e9), hints[b.uuid] ?? KiCadPoint(1e9, 1e9))
            // rows of the schematic about six grid units apart
            let (ra, rb) = ((pa.y / 6).rounded(.down), (pb.y / 6).rounded(.down))
            return ra != rb ? ra < rb : pa.x < pb.x
        }
        KiCadProject.arrangeNewBoard(board, order: order)
        return (board, result)
    }

    /// New footprints laid out in rows below the board's edge, as KiCad spreads the footprints an update adds
    static func spread(_ board: KiCadBoard, added: [String]) {
        let footprints = added.compactMap(board.footprint(uuid:))
        guard !footprints.isEmpty else { return }
        let others = board.footprints.filter { !added.contains($0.uuid) }
        var box = board.edgeBounds
        for footprint in others { if let b = footprint.bounds { if box == nil { box = b } else { box!.include(b) } } }
        let origin = box.map { KiCadPoint($0.minX, $0.maxY + 5) } ?? KiCadPoint(100, 60)
        KiCadProject.arrange(footprints, from: origin, width: max(box?.width ?? 0, KiCadProject.rowWidth(for: footprints)))
    }

    /// Brings one of the board's changes back to the schematic; what could not be brought back
    static func apply(_ change: Change, to circuit: inout Circuit, design: inout PCBDesign, components: PCBNetlistBuilder.Result) -> [String] {
        let ids = Set(change.parts)
        let indices = circuit.elements.indices.filter { ids.contains(circuit.elements[$0].id) }
        switch change {
        case .reference(_, let from, let to):
            if indices.count == 1 && circuit.elements[indices[0]].name == from {
                guard !circuit.elements.contains(where: { $0.name == to }) else { return ["\(to) is already a part's name: \(from) keeps its own"] }
                circuit.elements[indices[0]].name = to
            } else {
                // a package of several units, or a supply's header: the board's name for it is kept for it
                for (id, unit) in design.units where unit.package == from { design.units[id] = PCBDesign.Unit(package: to, unit: unit.unit) }
                for (key, ref) in design.references where ref == from { design.references[key] = to }
                if let c = components.netlist.component(reference: from), let key = c.ids.first { design.references[key] = to }
            }
        case .value(_, let reference, _, let to):
            var unread: [String] = []
            for i in indices {
                if !setValue(to, of: &circuit.elements[i]) { unread.append("\(reference)'s value \(to) on the board is not one JSpice can give \(circuit.elements[i].name)") }
            }
            return unread
        case .footprint(let parts, _, _, let to):
            for id in parts { design.footprints[id.uuidString] = to }
        case .doNotPopulate(let parts, _, let dnp):
            for id in parts { if dnp { design.doNotPopulate.insert(id.uuidString) } else { design.doNotPopulate.remove(id.uuidString) } }
        case .removed:
            break
        }
        return []
    }

    /// Gives a part the value KiCad's board names ("4k7", "100n", "2N3906", "TL082"); false if it means nothing for it
    public static func setValue(_ text: String, of element: inout Element) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        func number(_ key: String) -> Bool {
            guard let v = SI.parse(trimmed.split(separator: " ").first.map(String.init) ?? trimmed), v > 0 else { return false }
            element.params[key] = v
            return true
        }
        switch element.kind {
        case .resistor: return number("resistance")
        case .capacitor: return number("capacitance")
        case .inductor: return number("inductance")
        case .potentiometer:
            guard number("resistance") else { return false }
            if trimmed.hasSuffix(" A") { element.params["taper"] = 1 } else if trimmed.hasSuffix(" B") { element.params["taper"] = 0 }
            return true
        case .led:
            let colors = ["red", "green", "blue", "yellow", "white"]
            guard let c = colors.firstIndex(where: { trimmed.lowercased().contains($0) }) else { return false }
            element.params["color"] = Double(c)
            return true
        default:
            // a model the part knows by that name: its maker's numbers
            let name = trimmed.uppercased()
            guard let model = element.kind.models.first(where: { m in ([m.name] + m.aliases).contains { $0.uppercased() == name } }) else {
                return element.model.map { $0.name.uppercased() == name } ?? false
            }
            for (key, value) in model.values { element.params[key] = value }
            return true
        }
    }

    /// Takes the parts deleted on the board out of the schematic, as Eagle does when the user agrees
    public static func delete(_ change: Change, from circuit: inout Circuit) {
        circuit.remove(Set(change.parts))
    }

    /// How far the schematic and the board are apart: what bringing the board up to date would change, and the
    /// connections still to route
    public struct Status: Sendable {
        public var actions: [String]
        public var removed: [String]
        public var back: [String]
        public var unrouted: Int
        public var consistent: Bool { actions.isEmpty && removed.isEmpty && back.isEmpty }
    }

    public static func status(_ circuit: Circuit, board: KiCadBoard, library: KiCadFootprintSource) -> Status {
        let copy = board.copy()
        let result = sync(circuit, board: copy, library: library)
        return Status(actions: result.report.actions.map(\.text), removed: result.removed.map(\.description),
                      back: result.applied.map(\.description), unrouted: KiCadConnectivity(board).ratsnest().count)
    }
}
