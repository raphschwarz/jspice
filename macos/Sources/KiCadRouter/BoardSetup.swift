// A board set up as KiCad 10.0.7's Board Setup dialog sets it up: its copper layer count changed as the dialog's
// Physical Stackup and Board Editor Layers pages change it on OK (pcbnew/dialogs/panel_setup_layers.cpp,
// PANEL_SETUP_LAYERS::TransferDataFromWindow and transferDataFromWindow: the items on the layers removed taken away as
// pcbnew/board.cpp's BOARD::RemoveAllItemsOnLayer takes them, the layers enabled as BOARD_DESIGN_SETTINGS::
// SetEnabledLayers keeps them, written as pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.cpp writes the layer table and a
// zone's layers; its stackup as BoardStackup.throughBoardSetup brings it to them, its thickness the stackup's); and
// the project's pre-defined track widths and via sizes (pcbnew/dialogs/panel_setup_tracks_and_vias.cpp: the lists as
// its page reads, checks and writes them; pcbnew/board_design_settings.cpp: track_widths and via_dimensions,
// GetCurrentTrackWidth, GetCurrentViaSize and GetCurrentViaDrill) as the router takes the one chosen
// (pcbnew/router/router_tool.cpp's track width menu, pcbnew/router/pns_kicad_iface.cpp's ImportSizes).
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension KiCadProject {
    /// A project's pre-defined sizes (Board Setup > Pre-defined Sizes: board.design_settings.track_widths and
    /// via_dimensions), in mm, without the first entry of each list, which KiCad keeps for the net class's own
    /// ("use netclass") and its page leaves out
    public struct PredefinedSizes: Sendable, Equatable {
        public struct Via: Sendable, Equatable, Hashable {
            public var diameter: Double
            public var drill: Double
            public init(diameter: Double, drill: Double) {
                self.diameter = diameter
                self.drill = drill
            }
        }

        public var trackWidths: [Double]
        public var vias: [Via]

        public init(trackWidths: [Double] = [], vias: [Via] = []) {
            self.trackWidths = trackWidths
            self.vias = vias
        }

        /// The project's lists as BOARD_DESIGN_SETTINGS reads them (each number in mm, to the nanometre; a via without
        /// both its diameter and its drill left out), their first entries left out as the page leaves them out
        public init(_ project: [String: Any]?) {
            let ds = (project?["board"] as? [String: Any])?["design_settings"] as? [String: Any]
            let widths = (ds?["track_widths"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }.map(Self.nm)
            let vias = (ds?["via_dimensions"] as? [Any] ?? []).compactMap { entry -> Via? in
                guard let e = entry as? [String: Any], let d = (e["diameter"] as? NSNumber)?.doubleValue,
                      let h = (e["drill"] as? NSNumber)?.doubleValue else { return nil }
                return Via(diameter: Self.nm(d), drill: Self.nm(h))
            }
            trackWidths = Array(widths.dropFirst())
            self.vias = Array(vias.dropFirst())
        }

        /// A length in mm to the whole nanometre, as KiCad keeps it (mmToIU) and writes it back (IUTomm)
        static func nm(_ mm: Double) -> Double { Double(KiMath.round(mm * 1e6)) / 1e6 }

        /// What the page refuses (PANEL_SETUP_TRACKS_AND_VIAS::Validate, PCB_VIA::ValidateViaParameters), as it says it;
        /// a track width of nothing or less too (the page takes any number for one)
        public var problem: String? {
            if trackWidths.contains(where: { !($0 > 0) }) { return "A track width must be more than nothing." }
            for v in vias {
                if v.diameter < 0.001 { return "Via diameter is too small." }
                if v.drill < 0.001 { return "Via drill is too small." }
                if v.diameter <= v.drill { return "Via hole size must be smaller than via diameter" }
            }
            return nil
        }

        /// The lists as the page writes them (TransferDataFromWindow): each sorted, smallest first (a via by its
        /// diameter, then its drill), duplicates kept
        public var sorted: PredefinedSizes {
            PredefinedSizes(trackWidths: trackWidths.map(Self.nm).sorted(),
                            vias: vias.map { Via(diameter: Self.nm($0.diameter), drill: Self.nm($0.drill)) }
                                .sorted { ($0.diameter, $0.drill) < ($1.diameter, $1.drill) })
        }
    }

    /// The project's pre-defined sizes set to `sizes` as the Board Setup page writes them: sorted, after the net
    /// class's entry (0, and a via of 0 by 0)
    public static func setPredefinedSizes(_ sizes: PredefinedSizes, in project: inout [String: Any]) {
        let s = sizes.sorted
        var board = project["board"] as? [String: Any] ?? [:]
        var ds = board["design_settings"] as? [String: Any] ?? [:]
        ds["track_widths"] = [0.0] + s.trackWidths
        ds["via_dimensions"] = [["diameter": 0.0, "drill": 0.0]] + s.vias.map { ["diameter": $0.diameter, "drill": $0.drill] }
        board["design_settings"] = ds
        project["board"] = board
    }
}

extension KiCadBoard {
    /// The board's layer table, stackup and thickness `after` has, where they differ from `before`'s, put on this
    /// board in place of its own (a copper layer count changed on an older copy of the board carried onto this one:
    /// the items it took away go with carryCopper, carryZones and carryDrawings)
    public func carrySetup(from before: KiCadBoard, to after: KiCadBoard) {
        if before.root["layers"]?.compact != after.root["layers"]?.compact, let layers = after.root["layers"],
           let i = root.items.firstIndex(where: { $0.head == "layers" }) {
            root.items[i] = layers.copy()
        }
        if before.root["setup"]?["stackup"]?.compact != after.root["setup"]?["stackup"]?.compact,
           let stackup = after.root["setup"]?["stackup"], let setup = root["setup"] {
            if let i = setup.items.firstIndex(where: { $0.head == "stackup" }) {
                setup.items[i] = stackup.copy()
            } else {
                setup.items.insert(stackup.copy(), at: 1)
            }
        }
        let thickness = after.root["general"]?["thickness"]
        if before.root["general"]?["thickness"]?.compact != thickness?.compact, let thickness, let general = root["general"] {
            general.set(thickness.copy())
        }
    }
}

extension BoardEditing {
    /// The copper layer counts the Board Setup dialog offers (2 to 32, even)
    public static let copperLayerCounts = Array(stride(from: 2, through: 32, by: 2))

    /// The board's copper layers' names, front to back, as its layer table has them (canonical names)
    static func copperEntries(_ board: KiCadBoard) -> [SExpr] {
        (board.root["layers"]?.arguments ?? []).filter { $0.isList && ($0.text(at: 0)?.hasSuffix(".Cu") ?? false) }
    }

    /// The board's items that are on the copper layers a count of `copperLayers` would remove, by id, as KiCad's Board
    /// Setup lists them ("Items have been found on removed layers. This operation will delete all items from removed
    /// layers and cannot be undone.") before it takes them away or off those layers: of each layer removed that has
    /// items of its own (getRemovedLayersWithItems, BOARD::HasItemsOnLayer: the board's own items on it, a through via
    /// not counted, a blind or buried one only where it starts or ends there; or a pad defined on it of its own), the
    /// board's own items on it (through vias, and zones on other layers too, among them) and those pads. Empty where
    /// KiCad does not warn.
    public func itemsOnRemovedLayers(copperLayers: Int) -> [String] {
        let removed = Set(BoardStackup.copperNames(BoardStackup.BoardSettings(router.board).copperLayers))
            .subtracting(BoardStackup.copperNames(copperLayers))
        guard !removed.isEmpty else { return [] }
        let items = router.board.root.items.filter { $0.value("uuid") != nil && $0.head != "footprint" && $0.head != "group" }
        let pads = router.board.root.all("footprint").flatMap { $0.all("pad") }
        func padLayers(_ pad: SExpr) -> Set<String> { Set(pad["padstack"]?.all("layer").compactMap { $0.text(at: 0) } ?? []) }
        func counts(_ node: SExpr, on layer: String) -> Bool {
            guard Self.layerMask(of: node).contains(layer) else { return false }
            guard node.head == "via" else { return true }
            let through = !node.arguments.contains { $0.kind == .symbol && ["blind", "buried", "micro"].contains($0.text) }
            return !through && (node["layers"]?.arguments.map(\.text) ?? []).contains(layer)
        }
        let withItems = removed.filter { layer in
            items.contains { counts($0, on: layer) } || pads.contains { padLayers($0).contains(layer) }
        }
        guard !withItems.isEmpty else { return [] }
        var out: [String] = []
        for node in items where !Self.layerMask(of: node).isDisjoint(with: withItems) { out.append(node.value("uuid") ?? "") }
        for pad in pads where !padLayers(pad).isDisjoint(with: withItems) { out.append(pad.value("uuid") ?? "") }
        return out
    }

    /// Every copper layer KiCad has (LSET::AllCuMask)
    static let allCopper = Set(BoardStackup.copperNames(32))

    /// The layers a board item is on, its wildcards spelled out as KiCad's parser spells them out (*.Cu every copper
    /// layer there is, not the board's only); a via on those of its span
    static func layerMask(of node: SExpr) -> Set<String> {
        if node.head == "via" {
            let pair = node["layers"]?.arguments.map(\.text) ?? []
            guard pair.count == 2 else { return Set(pair) }
            let stack = BoardStackup.copperNames(32)
            guard let a = stack.firstIndex(of: pair[0]), let b = stack.firstIndex(of: pair[1]) else { return Set(pair) }
            return Set(stack[min(a, b)...max(a, b)])
        }
        if let layer = node.value("layer") { return [layer] }
        var mask: Set<String> = []
        for name in node["layers"]?.arguments.map(\.text) ?? [] {
            switch name {
            case "*.Cu": mask.formUnion(allCopper)
            case "*In.Cu": mask.formUnion(allCopper.subtracting(["F.Cu", "B.Cu"]))
            case "F&B.Cu": mask.formUnion(["F.Cu", "B.Cu"])
            case "*.Adhes", "*.Paste", "*.Mask", "*.SilkS", "*.Fab", "*.CrtYd":
                let side = String(name.dropFirst(2))
                mask.formUnion(["F." + side, "B." + side])
            default: mask.insert(name)
            }
        }
        return mask
    }

    /// The board's copper layer count set to `copperLayers` (2 to 32, even) as KiCad's Board Setup sets it, its
    /// Physical Stackup page's count changed and the dialog closed with OK, as one change:
    /// - the board's own items on the copper layers removed taken away (BOARD::RemoveAllItemsOnLayer): tracks, arcs,
    ///   drawings, texts and other items on one of them; blind, buried and micro vias that start or end on one (a
    ///   through via is kept); zones and rule areas taken off them, and away when they are on no layer left (a zone
    ///   taken off a layer is left unfilled, its properties of the layers it is no longer on dropped, as ZONE::
    ///   SetLayerSet leaves it; written as KiCad writes a zone's layers); the groups of what went, without it (a group
    ///   left with nothing taken away too); footprints, and what they have on those layers, as they are;
    /// - the layer table's copper layers those of the count, front to back, those kept as they were (names, types),
    ///   those added signal layers of their standard names;
    /// - the stackup brought to the new layers as the Physical Stackup page brings it (BoardStackup.
    ///   throughBoardSetup: the dielectrics' thicknesses set anew, the board as thick as its stackup made it), written
    ///   into the board's setup (which then always has one), and the board's thickness the stackup's.
    /// Edit.setup says so; Edit.removed has the tracks and vias taken away, Edit.zones the zones changed or taken
    /// away, Edit.drawings the drawings and texts taken away. nil for a count KiCad does not offer, or the board's own.
    public func setCopperLayerCount(_ copperLayers: Int) -> Edit? {
        guard !isRouting, Self.copperLayerCounts.contains(copperLayers) else { return nil }
        let board = router.board
        let settings = BoardStackup.BoardSettings(board)
        guard copperLayers != settings.copperLayers, let table = board.root["layers"] else { return nil }
        let kept = BoardStackup.copperNames(copperLayers)
        let removed = Set(BoardStackup.copperNames(settings.copperLayers)).subtracting(kept)
        // (the stackup as the page made it, of the board as it was)
        let stackup = BoardStackup.read(board).stackup.throughBoardSetup(settings, copperLayers: copperLayers)

        // the layer table (formatBoardLayers: the copper layers front to back, first)
        let old = Dictionary(Self.copperEntries(board).compactMap { e in e.text(at: 0).map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        let at = table.items.firstIndex { $0.isList && ($0.text(at: 0)?.hasSuffix(".Cu") ?? false) } ?? 1
        table.items.removeAll { $0.isList && ($0.text(at: 0)?.hasSuffix(".Cu") ?? false) }
        let entries = kept.map { name -> SExpr in
            old[name] ?? SExpr(list: [SExpr(symbol: String(Self.layerID(name))), SExpr(string: name), SExpr(symbol: "signal")])
        }
        table.items.insert(contentsOf: entries, at: min(at, table.items.count))
        let enabled = Set((table.arguments).compactMap { $0.text(at: 0) })
        let ids = Dictionary(table.arguments.compactMap { e -> (String, Int)? in
            guard let name = e.text(at: 0), let id = e.items.first.flatMap({ Int($0.text) }) else { return nil }
            return (name, id)
        }, uniquingKeysWith: { a, _ in a })

        // the items on the layers removed (RemoveAllItemsOnLayer)
        var copperGone: Set<String> = []
        var zonesChanged: [String] = []
        var drawingsGone: [String] = []
        var gone: Set<String> = []
        if !removed.isEmpty {
            for node in board.root.items {
                guard let head = node.head, let uuid = node.value("uuid"), head != "footprint", head != "group" else { continue }
                let mask = Self.layerMask(of: node)
                guard !mask.isDisjoint(with: removed) else { continue }
                switch head {
                case "via":
                    let through = !node.arguments.contains { $0.kind == .symbol && ["blind", "buried", "micro"].contains($0.text) }
                    let pair = node["layers"]?.arguments.map(\.text) ?? []
                    if !through && pair.contains(where: removed.contains) { copperGone.insert(uuid) }
                case "zone":
                    let left = mask.subtracting(removed)
                    if left.isEmpty {
                        board.root.remove(node)
                        gone.insert(uuid)
                    } else {
                        Self.setZoneLayers(node, left, enabled: enabled, ids: ids)
                    }
                    zonesChanged.append(uuid)
                case "segment", "arc":
                    copperGone.insert(uuid)
                default:
                    board.root.remove(node)
                    gone.insert(uuid)
                    drawingsGone.append(uuid)
                }
            }
            // (the groups of what went, without it; a group of nothing left taken away)
            var changed = true
            while changed {
                changed = false
                for group in board.root.all("group") {
                    guard let members = group["members"] else { continue }
                    let before = members.items.count
                    members.items.removeAll { $0.kind == .string && (gone.contains($0.text) || copperGone.contains($0.text)) }
                    if members.items.count != before && members.items.count == 1, let uuid = group.value("uuid") {
                        board.root.remove(group)
                        gone.insert(uuid)
                        changed = true
                    }
                }
            }
        }

        // the setup: the stackup first in it, and the board's thickness the stackup's
        if let node = stackup.node {
            let setup = board.root["setup"] ?? {
                let s = SExpr("setup")
                board.root.insert(s, after: ["layers"])
                return s
            }()
            if let i = setup.items.firstIndex(where: { $0.head == "stackup" }) {
                setup.items[i] = node
            } else {
                setup.items.insert(node, at: 1)
            }
        }
        let general = board.root["general"] ?? {
            let g = SExpr("general")
            board.root.insert(g, after: ["generator_version", "generator", "version"])
            return g
        }()
        let thickness = SExpr("thickness", Keyword(BoardStackup.formatLength(stackup.boardThickness)))
        if let i = general.items.firstIndex(where: { $0.head == "thickness" }) {
            general.items[i] = thickness
        } else {
            general.items.insert(thickness, at: min(1, general.items.count))
        }

        if copperGone.isEmpty {
            router.boardChanged()
        } else {
            router.remove(copperGone)
        }
        return change("Change Copper Layer Count", zones: zonesChanged, drawings: drawingsGone, setup: true)
    }

    /// A copper layer's id (In1.Cu is 4, In2.Cu 6…), as the layer table numbers it
    static func layerID(_ name: String) -> Int {
        if name == "F.Cu" { return 0 }
        if name == "B.Cu" { return 2 }
        return Int(name.dropFirst(2).dropLast(3)).map { 2 + 2 * $0 } ?? 0
    }

    /// A zone put on `layers` as ZONE::SetLayerSet puts it and KiCad then writes it: unfilled, its properties of other
    /// layers dropped, its layers those of them the board has, each named (or one alone as its layer)
    static func setZoneLayers(_ zone: SExpr, _ layers: Set<String>, enabled: Set<String>, ids: [String: Int]) {
        func id(_ l: String) -> Int { ids[l] ?? (l.hasSuffix(".Cu") ? layerID(l) : 1000) }
        var shown = layers.intersection(enabled).sorted { id($0) < id($1) }
        if shown.isEmpty, let first = layers.sorted(by: { id($0) < id($1) }).first { shown = [first] }
        let node = shown.count == 1 ? SExpr("layer", shown[0]) : SExpr("layers", shown)
        if let i = zone.items.firstIndex(where: { $0.head == "layers" || $0.head == "layer" }) {
            zone.items[i] = node
        } else {
            zone.items.insert(node, at: min(1, zone.items.count))
        }
        zone.remove("filled_polygon")
        zone.remove("fill_segments")
        zone.items.removeAll { $0.head == "property" && !layers.contains($0.value("layer") ?? "") }
        if let fill = zone["fill"] { fill.items.removeAll { $0.kind == .symbol && $0.text == "yes" } }
    }

    // MARK: - Pre-defined sizes

    /// The project's pre-defined track widths and via sizes
    public var predefinedSizes: KiCadProject.PredefinedSizes { KiCadProject.PredefinedSizes(project) }

    /// The project's pre-defined sizes set as the Board Setup's page sets them (sorted); the project's settings as
    /// they then are, for its file, or nil if the page would refuse them (`problem`). The router takes them at once.
    @discardableResult
    public func setPredefinedSizes(_ sizes: KiCadProject.PredefinedSizes) -> [String: Any]? {
        guard sizes.problem == nil else { return nil }
        var p = project ?? [:]
        KiCadProject.setPredefinedSizes(sizes, in: &p)
        project = p
        return p
    }

    /// The pre-defined size a track or via is routed with (the router tool's track width menu): 0 for the net
    /// class's, i for the project's i-th (as KiCad numbers its list, from 1 after the net class's entry)
    public struct SizeChoice: Sendable, Equatable {
        public var track = 0
        public var via = 0
        public init(track: Int = 0, via: Int = 0) {
            self.track = track
            self.via = via
        }
    }

    /// The track width chosen, nm (GetCurrentTrackWidth, the board's minimum width kept as ImportSizes keeps it), or
    /// nil for the net class's (an index out of the list's range is the net class's)
    public func chosenTrackWidth() -> Int? {
        let widths = predefinedSizes.trackWidths
        guard sizeChoice.track > 0, sizeChoice.track <= widths.count else { return nil }
        return max(router.world.minTrackWidth, KiMath.round(widths[sizeChoice.track - 1] * 1e6))
    }

    /// The via size chosen, nm (GetCurrentViaSize and GetCurrentViaDrill, taken as they are), or nil for the net
    /// class's
    public func chosenViaSize() -> (diameter: Int, drill: Int)? {
        let vias = predefinedSizes.vias
        guard sizeChoice.via > 0, sizeChoice.via <= vias.count else { return nil }
        let v = vias[sizeChoice.via - 1]
        return (KiMath.round(v.diameter * 1e6), KiMath.round(v.drill * 1e6))
    }

    /// The via size a via placed on its own takes (VIA_PLACER: GetCurrentViaSize and GetCurrentViaDrill): the
    /// chosen pre-defined one, or the Default net class's
    func currentViaSize(default diameter: Int, _ drill: Int) -> (diameter: Int, drill: Int) {
        chosenViaSize() ?? (diameter, drill)
    }
}
