import Foundation

/// Where footprints come from: KiCad's libraries, or (in tests) footprints at hand
public protocol KiCadFootprintSource {
    func footprint(_ libID: String) throws -> SExpr
}

extension KiCadFootprintLibrary: KiCadFootprintSource {}

/// Brings a board up to date with the schematic: KiCad's BOARD_NETLIST_UPDATER (pcbnew/netlist_reader/
/// board_netlist_updater.cpp, KiCad 10.0.7) brought over to work on the board's file, what KiCad's Update PCB from
/// Schematic does. Each part finds its footprint by the id of the symbol it stands for; a part with none gets one from
/// its library, a footprint whose part has changed footprint is exchanged for the new one where it stands; references,
/// values, fields and the pads' nets are made the schematic's; footprints whose parts are gone are removed; zones and
/// vias left on a net that no longer exists follow it to its new name. Then, as KiCad does when the change is
/// committed, the tracks and vias take the nets of the pads they reach.
public struct NetlistUpdater {
    public struct Options: Sendable, Hashable {
        /// Remove footprints whose parts are gone from the schematic (unless they are board-only or locked)
        public var deleteUnusedFootprints = true
        /// Exchange a footprint for the part's new one when the part's footprint changes
        public var replaceFootprints = true
        /// Make the footprints' fields the parts' fields
        public var updateFields = true
        /// Remove fields the parts no longer have
        public var removeExtraFields = false
        /// Remove and exchange locked footprints too
        public var overrideLocks = false
        /// Match footprints to parts by the parts' ids (true) or by reference
        public var matchByID = true
        /// Give tracks and vias the nets of the pads they reach, as KiCad does on committing a change (a board KiCad
        /// itself is changing does it on its own)
        public var propagateNets = true

        public init() {}
    }

    public enum Severity: String, Sendable { case action, info, warning, error }

    public struct Message: Sendable, Hashable, CustomStringConvertible {
        public var severity: Severity
        public var text: String
        /// The reference it is about
        public var reference: String?

        public var description: String { text }
    }

    /// What updating did, or (on a dry run) would do
    public struct Report: Sendable {
        public var messages: [Message] = []
        /// The ids of the footprints added
        public var added: [String] = []
        /// The ids of the footprints removed
        public var removed: [String] = []
        /// Whether the board was changed
        public var changed: Bool { messages.contains { $0.severity == .action } }
        public var errors: [Message] { messages.filter { $0.severity == .error } }
        public var warnings: [Message] { messages.filter { $0.severity == .warning } }
        public var actions: [Message] { messages.filter { $0.severity == .action } }
    }

    public let board: KiCadBoard
    public let library: KiCadFootprintSource
    public var options: Options

    var report = Report()
    var oldToNewNets: [String: String] = [:]
    var zoneConnections: [ObjectIdentifier: [SExpr]] = [:]
    var added: [SExpr] = []

    public init(board: KiCadBoard, library: KiCadFootprintSource, options: Options = Options()) {
        self.board = board
        self.library = library
        self.options = options
    }

    /// Updates `board` to `netlist`, or (with `dryRun`) says what would change and leaves it as it is
    public static func update(_ board: KiCadBoard, to netlist: PCBNetlist, library: KiCadFootprintSource,
                              options: Options = Options(), dryRun: Bool = false) -> Report {
        var updater = NetlistUpdater(board: dryRun ? board.copy() : board, library: library, options: options)
        return updater.update(netlist)
    }

    mutating func say(_ severity: Severity, _ text: String, _ reference: String? = nil) {
        report.messages.append(Message(severity: severity, text: text, reference: reference))
    }

    /// Whether a board's footprint id and a schematic's are the same footprint (BOARD_NETLIST_UPDATER::
    /// fpidsEquivalent): the same library and name, or the same name where the schematic gives no library
    public static func equivalent(_ board: String, _ schematic: String) -> Bool {
        guard schematic.contains(":") else { return board.split(separator: ":").last.map(String.init) == schematic }
        return board == schematic
    }

    mutating func update(_ netlist: PCBNetlist) -> Report {
        let preexisting = board.footprints
        cacheZoneConnections()
        var used = Set<ObjectIdentifier>()
        var footprintOf: [Int: KiCadFootprint] = [:]

        for (index, component) in netlist.components.enumerated() where !component.excludeFromBoard {
            let fpid = component.footprint
            if !fpid.isEmpty && !fpid.contains(":") {
                say(.warning, "\(component.reference) has a footprint without its library ('\(fpid)'); give it as Library:Name.", component.reference)
            }
            let matching = preexisting.filter { footprint in
                options.matchByID ? component.paths.contains(footprint.path ?? "")
                    : footprint.reference.caseInsensitiveCompare(component.reference) == .orderedSame
            }
            var base = matching.first { !used.contains(ObjectIdentifier($0.node)) && !fpid.isEmpty && Self.equivalent($0.libID, fpid) }
            if fpid.isEmpty, base == nil { base = matching.first { !used.contains(ObjectIdentifier($0.node)) } }
            if base == nil, let candidate = matching.first(where: { !used.contains(ObjectIdentifier($0.node)) }) {
                if options.replaceFootprints {
                    base = replace(candidate, with: component) ?? candidate
                } else {
                    base = candidate
                }
            }
            if base == nil {
                base = add(component)
            }
            guard let footprint = base else { continue }
            used.insert(ObjectIdentifier(footprint.node))
            footprintOf[index] = footprint
            updateParameters(footprint, component)
            updatePads(footprint, component)
            updateUnits(footprint, component)
        }

        updateZoneAndViaNets(netlist)

        // footprints whose parts are gone
        for footprint in board.footprints {
            var matched = used.contains(ObjectIdentifier(footprint.node))
            if !matched {
                let component = options.matchByID ? footprint.path.flatMap(netlist.component(path:))
                    : netlist.component(reference: footprint.reference)
                if let component, !component.excludeFromBoard { matched = true }
            }
            var delete = options.deleteUnusedFootprints && !footprint.attributes.contains("board_only")
            if delete && !matched && footprint.isLocked && !options.overrideLocks {
                say(.warning, "Cannot remove unused footprint \(footprint.reference) (locked).", footprint.reference)
                delete = false
            }
            if delete && !matched {
                say(.action, "Remove unused footprint \(footprint.reference).", footprint.reference)
                report.removed.append(footprint.uuid)
                board.remove(footprint)
            } else if !matched && footprint.path != nil {
                footprint.path = nil
            }
        }

        // pads the schematic has that the footprints lack
        for (index, component) in netlist.components.enumerated() {
            guard let footprint = footprintOf[index] else { continue }
            let numbers = Set(footprint.pads.map(\.number))
            for pad in component.pins.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) where !numbers.contains(pad) {
                say(.error, "\(component.reference) pad \(pad) not found in \(footprint.libID).", component.reference)
            }
        }

        if options.propagateNets {
            let changes = KiCadConnectivity(board).propagateNets(on: board)
            if !changes.isEmpty {
                let nets = Set(changes.map(\.to)).sorted()
                say(.action, "Put \(changes.count) track\(changes.count == 1 ? "" : "s") and vias on the nets of the pads they reach (\(nets.joined(separator: ", "))).")
            }
        }
        board.removeUnusedNets()
        report.added = added.compactMap { $0.value("uuid") }
        return report
    }

    // MARK: - Footprints

    /// Where new footprints go (estimateFootprintInsertionPosition): below the board's edge, or (on an empty board)
    /// in the middle of an A4 page
    func insertionPosition() -> KiCadPoint {
        if let box = board.edgeBounds, box.width > 0 || box.height > 0 {
            return KiCadPoint(box.center.x, box.maxY + 10)
        }
        return KiCadPoint(148.5, 105)
    }

    mutating func add(_ component: PCBNetlist.Component) -> KiCadFootprint? {
        guard !component.footprint.isEmpty else {
            say(.error, "No footprint is assigned to \(component.reference).", component.reference)
            return nil
        }
        let node: SExpr
        do {
            node = KiCadFootprintLibrary.placeable(try library.footprint(component.footprint), libID: component.footprint,
                                                   reference: component.reference, value: component.value,
                                                   at: insertionPosition())
        } catch {
            say(.error, "Cannot add \(component.reference): footprint '\(component.footprint)' not found (\(error)).", component.reference)
            return nil
        }
        board.add(node)
        added.append(node)
        say(.action, "Add \(component.reference) (footprint '\(component.footprint)').", component.reference)
        return KiCadFootprint(node, board: board)
    }

    /// Exchanges a footprint for the part's new one, where the old one stands (PCB_EDIT_FRAME::ExchangeFootprint, as
    /// the updater calls it): its place, side, turn, lock and id kept, its pads' nets and ids passed on pad by pad
    mutating func replace(_ old: KiCadFootprint, with component: PCBNetlist.Component) -> KiCadFootprint? {
        guard !component.footprint.isEmpty else {
            say(.error, "No footprint is assigned to \(component.reference).", component.reference)
            return nil
        }
        if old.isLocked && !options.overrideLocks {
            say(.warning, "Cannot change \(old.reference) footprint from '\(old.libID)' to '\(component.footprint)' (locked).", old.reference)
            return nil
        }
        let node: SExpr
        do {
            node = KiCadFootprintLibrary.placeable(try library.footprint(component.footprint), libID: component.footprint,
                                                   reference: old.reference, value: old.value, at: old.position)
        } catch {
            say(.error, "Cannot update \(component.reference) (footprint '\(component.footprint)' not found).", component.reference)
            return nil
        }
        // turned over if the old one was on the back, then turned as it was
        let new = KiCadFootprint(node, board: board)
        if old.isOnBack { new.flip() }
        new.move(to: old.position, rotation: old.rotation)
        node.set(SExpr("uuid", old.uuid))
        if old.isLocked { node.set(SExpr("locked", Keyword("yes")), after: ["footprint"]) }
        // the reference's and value's ids
        for name in ["Reference", "Value"] {
            if let id = old.node.all("property").first(where: { $0.text(at: 0) == name })?.value("uuid"),
               let field = node.all("property").first(where: { $0.text(at: 0) == name }) {
                field.set(SExpr("uuid", id))
            }
        }
        // pads matched by number take the old pads' nets, pin functions and ids
        var oldPads = old.pads
        for pad in new.pads {
            guard let i = oldPads.firstIndex(where: { $0.number == pad.number && !pad.number.isEmpty }) else { continue }
            let match = oldPads.remove(at: i)
            pad.node.set(SExpr("uuid", match.uuid))
            pad.setNet(pad.isCopper ? match.net : nil)
            pad.setPin(function: match.pinFunction, type: match.pinType)
        }
        if let path = old.path { new.path = path }
        // in the old one's place among the board's items
        if let i = board.root.items.firstIndex(where: { $0 === old.node }) { board.root.items[i] = node }
        say(.action, "Change \(old.reference) footprint from '\(old.libID)' to '\(component.footprint)'.", old.reference)
        return new
    }

    // MARK: - Parameters

    mutating func updateParameters(_ footprint: KiCadFootprint, _ component: PCBNetlist.Component) {
        if footprint.reference != component.reference {
            say(.action, "Change \(footprint.reference) reference designator to \(component.reference).", component.reference)
            footprint.reference = component.reference
        }
        if footprint.value != component.value {
            say(.action, "Change \(footprint.reference) value from \(footprint.value) to \(component.value).", component.reference)
            footprint.value = component.value
        }
        if footprint.path != component.path {
            if footprint.path != nil {
                say(.action, "Update \(footprint.reference) symbol association from \(footprint.path ?? "") to \(component.path).", component.reference)
            }
            footprint.path = component.path
        }
        // the fields beyond reference and value
        let fpFields = footprint.properties.filter { !["Reference", "Value", "Component Class", "ki_fp_filters"].contains($0.name) }
        var fpMap: [String: String] = [:]
        for f in fpFields { fpMap[f.name] = f.value }
        let compFields = component.fields.filter { !["Reference", "Value", "Footprint", "Component Class"].contains($0.name) }
        let compNames = Set(compFields.map(\.name))
        var same = true
        var removeOnly = true
        for field in compFields where fpMap[field.name] != field.value {
            same = false
            removeOnly = false
            break
        }
        if fpFields.contains(where: { !compNames.contains($0.name) }) { same = false }
        if !same {
            if options.updateFields && (!removeOnly || options.removeExtraFields) {
                say(.action, "Update \(footprint.reference) fields.", component.reference)
                for field in compFields { footprint.setProperty(field.name, field.value) }
            }
            if options.removeExtraFields {
                let mandatory: Set<String> = ["Reference", "Value", "Datasheet", "Description", "Footprint"]
                for field in fpFields where !compNames.contains(field.name) && !mandatory.contains(field.name) {
                    say(.action, "Remove \(footprint.reference) field \(field.name).", component.reference)
                    footprint.removeProperty(field.name)
                }
            }
        }
        // the fabrication flags
        var attributes = footprint.attributes
        let flags: [(String, Bool, String)] = [("exclude_from_bom", component.excludeFromBOM, "exclude from bill of materials"),
                                               ("dnp", component.doNotPopulate, "do not populate"),
                                               ("exclude_from_pos_files", component.excludeFromPositionFiles, "exclude from position files")]
        for (flag, wanted, title) in flags where options.updateFields && attributes.contains(flag) != wanted {
            say(.action, "\(wanted ? "Add" : "Remove") \(footprint.reference) '\(title)' attribute.", component.reference)
            if wanted { attributes.insert(flag) } else { attributes.remove(flag) }
        }
        if attributes != footprint.attributes { footprint.attributes = attributes }
    }

    /// The pads' nets (updateComponentPadConnections)
    mutating func updatePads(_ footprint: KiCadFootprint, _ component: PCBNetlist.Component) {
        var padNetNames = Set<String>()
        let schematicNets = Set(component.pins.values.map(\.net))
        for pad in footprint.pads.sorted(by: { $0.uuid < $1.uuid }) {
            let pin = component.pins[pad.number]
            if pad.pinFunction != pin?.function.nilIfEmpty || pad.pinType != pin?.type.nilIfEmpty {
                pad.setPin(function: pin?.function, type: pin?.type)
            }
            guard let pin, pad.isCopper else {
                if let net = pad.net {
                    say(.action, "Disconnect \(footprint.reference) pin \(pad.number) (from \(net)).", component.reference)
                } else if pad.isCopper && !pad.number.isEmpty {
                    say(.warning, "No net found for component \(footprint.reference) pad \(pad.number).", component.reference)
                }
                pad.setNet(nil)
                continue
            }
            var netName = pin.net
            if pad.isNoConnect {
                // each unconnected pad on a net of its own
                var k = 1
                while !padNetNames.insert(netName).inserted || (netName != pin.net && schematicNets.contains(netName)) {
                    netName = "\(pin.net)_\(k)"
                    k += 1
                }
            }
            guard pad.net != netName else { continue }
            if let old = pad.net {
                oldToNewNets[old] = netName
                say(.action, "Reconnect \(footprint.reference) pin \(pad.number) from \(old) to \(netName).", component.reference)
            } else {
                say(.action, "Connect \(footprint.reference) pin \(pad.number) to \(netName).", component.reference)
            }
            pad.setNet(netName)
        }
    }

    /// KiCad 10's unit metadata, for gate swapping
    mutating func updateUnits(_ footprint: KiCadFootprint, _ component: PCBNetlist.Component) {
        let current = footprint.units
        guard current != component.units else { return }
        footprint.units = component.units
        say(.action, "Updated \(footprint.reference) unit metadata.", component.reference)
    }

    // MARK: - Zones and vias

    mutating func cacheZoneConnections() {
        let zones = board.zones.filter(\.isCopper)
        guard !zones.isEmpty else { return }
        let connectivity = KiCadConnectivity(board)
        for zone in zones { zoneConnections[ObjectIdentifier(zone.node)] = connectivity.pads(touching: zone.node).map(\.node) }
    }

    /// Zones and vias left on a net the schematic no longer has follow it to its new name (updateCopperZoneNets)
    mutating func updateZoneAndViaNets(_ netlist: PCBNetlist) {
        let names = netlist.netNames
        for via in board.vias {
            guard let net = via.net, !names.contains(net) else { continue }
            if let new = oldToNewNets[net] {
                say(.action, "Reconnect via from \(net) to \(new).")
                via.setNet(new)
            } else {
                say(.warning, "Via connected to unknown net (\(net)).")
            }
        }
        func inNetlist(_ name: String) -> Bool { names.contains(name) || names.contains { name.hasPrefix($0) } }
        for zone in board.zones where zone.isCopper {
            guard let net = zone.net, !inNetlist(net) else { continue }
            var updated: String?
            for padNode in zoneConnections[ObjectIdentifier(zone.node)] ?? [] {
                if let n = board.netName(padNode["net"]), n != net { updated = n; break }
            }
            if updated == nil { updated = oldToNewNets[net] }
            let label = zone.name.map { "zone '\($0)'" } ?? "copper zone"
            if let updated {
                say(.action, "Reconnect \(label) from \(net) to \(updated).")
                zone.setNet(updated)
            } else {
                say(.warning, "Copper zone (\(net)) has no pads connected.")
            }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension KiCadFootprint {
    /// KiCad 10's unit metadata: each gate's name and pads
    public var units: [PCBNetlist.Unit] {
        get {
            node["units"]?.all("unit").map { unit in
                PCBNetlist.Unit(name: unit.value("name") ?? "", pins: unit["pins"]?.arguments.map(\.text) ?? [])
            } ?? []
        }
        nonmutating set {
            node.remove("units")
            guard !newValue.isEmpty else { return }
            let list = SExpr("units", newValue.map { u in SExpr("unit", SExpr("name", u.name), SExpr("pins", u.pins)) })
            node.insert(list, after: ["sheetfile", "sheetname", "path", "property"])
        }
    }
}
