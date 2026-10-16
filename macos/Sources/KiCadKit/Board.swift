import Foundation

/// A KiCad board (a .kicad_pcb file), read into its S-expression tree and edited there, so that writing it back keeps
/// everything as KiCad wrote it. The typed views (footprints, pads, tracks, vias, zones, the outline) read and change
/// the tree they stand on.
public final class KiCadBoard {
    public let root: SExpr

    public init(_ root: SExpr) { self.root = root }

    public convenience init(text: String) throws {
        let root = try SExpr.parse(text)
        guard root.head == "kicad_pcb" else { throw SExpr.ParseError(description: "not a KiCad board") }
        self.init(root)
    }

    public static func read(_ url: URL) throws -> KiCadBoard {
        try KiCadBoard(text: String(contentsOf: url, encoding: .utf8))
    }

    /// The board as KiCad writes it
    public var text: String { root.formatted() }

    public func write(to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The file format's version (the date its last change was made, 20260206 for KiCad 10)
    public var version: Int { root.value("version").flatMap(Int.init) ?? 0 }

    /// The version KiCad 10 writes, the one JSpice writes
    public static let formatVersion = 20260206

    /// Whether the board numbers its nets in a table (KiCad 9 and before), where KiCad 10 names them on every item
    public var numbersNets: Bool { root.items.contains { $0.head == "net" } }

    /// A copy of the whole board
    public func copy() -> KiCadBoard { KiCadBoard(root.copy()) }

    // MARK: - Items

    public var footprints: [KiCadFootprint] { root.all("footprint").map { KiCadFootprint($0, board: self) } }

    public func footprint(uuid: String) -> KiCadFootprint? { footprints.first { $0.uuid == uuid } }

    public var tracks: [KiCadTrack] {
        root.items.filter { $0.head == "segment" || $0.head == "arc" }.map { KiCadTrack($0, board: self) }
    }

    public var vias: [KiCadVia] { root.all("via").map { KiCadVia($0, board: self) } }

    public var zones: [KiCadZone] { root.all("zone").map { KiCadZone($0, board: self) } }

    /// The board's own drawings (not the footprints'): lines, rectangles, arcs, circles and polygons
    public var drawings: [KiCadDrawing] {
        root.items.filter { KiCadDrawing.heads.contains($0.head ?? "") }.map { KiCadDrawing($0, placement: nil) }
    }

    /// The edge of the board: its drawings on Edge.Cuts, and the footprints'
    public var outline: [KiCadDrawing] {
        drawings.filter { $0.layer == "Edge.Cuts" } + footprints.flatMap { $0.drawings.filter { $0.layer == "Edge.Cuts" } }
    }

    /// The board's outline when it is one rectangle drawn as one (round cut-outs and polygons aside): its corners, and
    /// its corners' radius (mm, 0 if square)
    public var outlineRectangle: (box: KiCadBox, radius: Double)? {
        let edges = root.items.filter { KiCadDrawing.heads.contains($0.head ?? "") && $0.value("layer") == "Edge.Cuts" }
        let rects = edges.filter { $0.head == "gr_rect" }
        guard rects.count == 1, edges.allSatisfy({ ["gr_rect", "gr_circle", "gr_poly"].contains($0.head ?? "") }),
              let rect = rects.first, let s = rect["start"], let e = rect["end"],
              let x0 = s.number(at: 0), let y0 = s.number(at: 1), let x1 = e.number(at: 0), let y1 = e.number(at: 1) else { return nil }
        return (KiCadBox(minX: min(x0, x1), minY: min(y0, y1), maxX: max(x0, x1), maxY: max(y0, y1)), rect["radius"]?.number(at: 0) ?? 0)
    }

    /// The box round the board's edge (GetBoardEdgesBoundingBox), or round everything on it if it has no edge yet
    public var edgeBounds: KiCadBox? {
        var box: KiCadBox?
        for drawing in outline {
            for p in drawing.points {
                if box == nil { box = KiCadBox(minX: p.x, minY: p.y, maxX: p.x, maxY: p.y) } else { box!.include(p) }
            }
        }
        return box ?? itemBounds
    }

    /// The box round every footprint, track and via
    public var itemBounds: KiCadBox? {
        var points: [KiCadPoint] = []
        for footprint in footprints { if let b = footprint.bounds { points += [KiCadPoint(b.minX, b.minY), KiCadPoint(b.maxX, b.maxY)] } }
        for track in tracks { points += [track.start, track.end] }
        for via in vias { points.append(via.position) }
        return KiCadBox(points)
    }

    /// Every net named on the board's items
    public var netNames: Set<String> {
        var names = Set<String>()
        for footprint in footprints { for pad in footprint.pads { if let n = pad.net { names.insert(n) } } }
        for track in tracks { if let n = track.net { names.insert(n) } }
        for via in vias { if let n = via.net { names.insert(n) } }
        for zone in zones { if let n = zone.net { names.insert(n) } }
        return names
    }

    // MARK: - Nets

    /// A net's name from an item's (net …) list, either way KiCad writes it
    public func netName(_ list: SExpr?) -> String? {
        guard let list else { return nil }
        if let code = list.text(at: 0), list.items.count == 2, list.items[1].kind == .symbol, let n = Int(code) {
            // KiCad 9: a track's (net 3), named in the table
            return n == 0 ? nil : netTable[n]
        }
        let name = list.items.count >= 3 ? list.text(at: 1) : list.text(at: 0)
        return name?.isEmpty == false ? name : nil
    }

    /// KiCad 9's table of nets by number
    var netTable: [Int: String] {
        var table: [Int: String] = [:]
        for net in root.all("net") { if let n = net.number(at: 0).map(Int.init), let name = net.text(at: 1) { table[n] = name } }
        return table
    }

    /// The (net …) list naming `name` on an item, as this board writes it
    public func netList(_ name: String, pad: Bool) -> SExpr {
        guard numbersNets else { return SExpr("net", name) }
        if name.isEmpty { return SExpr("net", 0) }
        let code = netCode(name)
        return pad ? SExpr("net", code, name) : SExpr("net", code)
    }

    /// A net's number in KiCad 9's table, adding it if it is new
    func netCode(_ name: String) -> Int {
        let table = netTable
        if let (code, _) = table.first(where: { $0.value == name }) { return code }
        let code = (table.keys.max() ?? 0) + 1
        root.insert(SExpr("net", code, name), after: ["net", "setup", "layers"])
        return code
    }

    // MARK: - Editing

    /// Adds a footprint after the others
    public func add(_ footprint: SExpr) {
        root.insert(footprint, after: ["footprint", "net", "setup", "layers", "title_block", "paper", "general"])
    }

    public func remove(_ footprint: KiCadFootprint) { root.remove(footprint.node) }

    static let copperHeads: Set<String> = ["segment", "arc", "via"]

    /// The board's tracks, arc tracks and vias, as they stand in its file
    public var copperItems: [SExpr] { root.items.filter { Self.copperHeads.contains($0.head ?? "") } }

    /// A track, arc track or via put after the board's others, where KiCad keeps them (before its zones and groups)
    public func addCopper(_ node: SExpr) {
        let items = root.items
        if let last = items.lastIndex(where: { Self.copperHeads.contains($0.head ?? "") }) {
            root.items.insert(node, at: last + 1)
        } else if let first = items.firstIndex(where: { ["zone", "group", "generated", "embedded_fonts", "embedded_files"].contains($0.head ?? "") }) {
            root.items.insert(node, at: first)
        } else {
            root.items.append(node)
        }
    }

    /// What was done to the tracks and vias of `before` to make `after`, done to this board (by their ids: those made
    /// added, those changed changed, those taken away taken away): a change made on an older copy of the board
    /// carried onto this one, which keeps its own changes
    public func carryCopper(from before: KiCadBoard, to after: KiCadBoard) {
        func byID(_ items: [SExpr]) -> [String: SExpr] {
            Dictionary(items.compactMap { n in n.value("uuid").map { ($0, n) } }, uniquingKeysWith: { a, _ in a })
        }
        let old = byID(before.copperItems), new = byID(after.copperItems)
        for node in copperItems {
            guard let uuid = node.value("uuid"), let was = old[uuid] else { continue }
            if let now = new[uuid] {
                if now.compact != was.compact, let i = root.items.firstIndex(where: { $0 === node }) { root.items[i] = now.copy() }
            } else {
                root.remove(node)
            }
        }
        let here = byID(copperItems)
        for node in after.copperItems {
            guard let uuid = node.value("uuid"), old[uuid] == nil, here[uuid] == nil else { continue }
            addCopper(node.copy())
        }
    }

    /// A copper pour: a zone of `net` filling `outline` on `layers`, as KiCad makes a new zone (pads of the net
    /// joined by thermal reliefs, other copper kept 0.5 mm away, no copper narrower than 0.25 mm), put after the
    /// board's tracks; empty until KiCad fills it. Its id.
    @discardableResult
    public func addPour(net: String, layers: [String], outline: [KiCadPoint], clearance: Double = 0.5,
                        minThickness: Double = 0.25, thermalGap: Double = 0.5, thermalBridge: Double = 0.5) -> String {
        let uuid = Self.newUUID()
        let node = SExpr("zone",
                         layers.count == 1 ? SExpr("layer", layers[0]) : SExpr("layers", layers.map { $0 as SExprConvertible }),
                         SExpr("uuid", uuid), SExpr("name", net), SExpr("hatch", SExpr(symbol: "edge"), 0.5),
                         SExpr("connect_pads", SExpr("clearance", clearance)), SExpr("min_thickness", minThickness),
                         SExpr("filled_areas_thickness", SExpr(symbol: "no")),
                         SExpr("fill", SExpr("thermal_gap", thermalGap), SExpr("thermal_bridge_width", thermalBridge)),
                         SExpr("polygon", SExpr("pts", outline.map { SExpr("xy", $0.x, $0.y) as SExprConvertible })))
        KiCadZone(node, board: self).setNet(net)
        let items = root.items
        if let last = items.lastIndex(where: { $0.head == "zone" }) ?? items.lastIndex(where: { Self.copperHeads.contains($0.head ?? "") }) {
            root.items.insert(node, at: last + 1)
        } else if let first = items.firstIndex(where: { ["group", "generated", "embedded_fonts", "embedded_files"].contains($0.head ?? "") }) {
            root.items.insert(node, at: first)
        } else {
            root.items.append(node)
        }
        return uuid
    }

    /// The board's own drawings on Edge.Cuts (its outline, as drawn on the board rather than by footprints)
    public var edgeDrawings: [SExpr] {
        root.items.filter { KiCadDrawing.heads.contains($0.head ?? "") && $0.value("layer") == "Edge.Cuts" }
    }

    /// The outline `after` has, if it differs from `before`'s, drawn on this board in place of its own
    public func carryOutline(from before: KiCadBoard, to after: KiCadBoard) {
        let was = before.edgeDrawings.map(\.compact), now = after.edgeDrawings
        guard was != now.map(\.compact) else { return }
        let at = root.items.firstIndex { KiCadDrawing.heads.contains($0.head ?? "") && $0.value("layer") == "Edge.Cuts" }
        for node in edgeDrawings { root.remove(node) }
        let index = min(at ?? root.items.count, root.items.count)
        root.items.insert(contentsOf: now.map { $0.copy() }, at: index)
    }

    /// A zone's outline and settings, without its fill (which KiCad makes anew)
    static func unfilled(_ zone: SExpr) -> String {
        let z = zone.copy()
        z.remove("filled_polygon")
        return z.compact
    }

    /// Zones added between `before` and `after` added to this board, those taken away taken away, and those changed
    /// (their outlines, nets, layers) changed (by their ids)
    public func carryZones(from before: KiCadBoard, to after: KiCadBoard) {
        let oldNodes = Dictionary(before.zones.map { ($0.uuid, $0.node) }, uniquingKeysWith: { a, _ in a })
        let old = Set(oldNodes.keys), new = Dictionary(after.zones.map { ($0.uuid, $0.node) }, uniquingKeysWith: { a, _ in a })
        for zone in zones where old.contains(zone.uuid) && new[zone.uuid] == nil { root.remove(zone.node) }
        for zone in zones {
            guard let was = oldNodes[zone.uuid], let now = new[zone.uuid], Self.unfilled(was) != Self.unfilled(now),
                  let i = root.items.firstIndex(where: { $0 === zone.node }) else { continue }
            root.items[i] = now.copy()
        }
        let here = Set(zones.map(\.uuid))
        for (uuid, node) in new where !old.contains(uuid) && !here.contains(uuid) {
            let items = root.items
            let at = (items.lastIndex { $0.head == "zone" } ?? items.lastIndex { Self.copperHeads.contains($0.head ?? "") }).map { $0 + 1 } ?? items.count
            root.items.insert(node.copy(), at: at)
        }
    }

    /// Footprints moved, turned or turned over between `before` and `after`, placed so on this board too (by their
    /// ids): a change made on an older copy of the board carried onto this one, which keeps its own changes
    /// Footprints added between `before` and `after` (mounting holes, made in the board editor) added to this board as
    /// they are in `after`, and those taken away taken away
    public func carryFootprints(from before: KiCadBoard, to after: KiCadBoard) {
        let was = Set(before.footprints.map(\.uuid)), now = Set(after.footprints.map(\.uuid))
        for f in after.footprints where !was.contains(f.uuid) && footprint(uuid: f.uuid) == nil { add(f.node.copy()) }
        for f in footprints where was.contains(f.uuid) && !now.contains(f.uuid) { remove(f) }
    }

    public func carryPlacement(from before: KiCadBoard, to after: KiCadBoard) {
        let old = Dictionary(before.footprints.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        for f in after.footprints {
            guard let o = old[f.uuid], let here = footprint(uuid: f.uuid),
                  o.position != f.position || o.rotation != f.rotation || o.layer != f.layer else { continue }
            if here.layer != f.layer { here.flip() }
            here.move(to: f.position, rotation: f.rotation)
        }
    }

    /// Takes nets no item names out of KiCad 9's table (RemoveUnusedNets)
    public func removeUnusedNets() {
        guard numbersNets else { return }
        let used = netNames
        root.items.removeAll { item in
            guard item.head == "net", let n = item.number(at: 0), n != 0, let name = item.text(at: 1) else { return false }
            return !used.contains(name)
        }
    }

    /// A new id for an item, as KiCad makes them (a random UUID, in lower case)
    public static func newUUID() -> String { UUID().uuidString.lowercased() }
}

/// A footprint placed on a board
public struct KiCadFootprint {
    public let node: SExpr
    unowned let board: KiCadBoard

    init(_ node: SExpr, board: KiCadBoard) { self.node = node; self.board = board }

    /// The library and name it was placed from, "Resistor_SMD:R_0805_2012Metric"
    public var libID: String {
        get { node.text(at: 0) ?? "" }
        nonmutating set { node.items[1] = SExpr(string: newValue) }
    }

    public var uuid: String { node.value("uuid") ?? "" }

    /// The symbol it stands for in the schematic: the path of sheet and symbol ids, "/<uuid>" on the root sheet
    public var path: String? {
        get { node.value("path") }
        nonmutating set {
            node.remove("path")
            if let newValue { node.insert(SExpr("path", newValue), after: ["property", "tags", "descr", "at", "uuid", "locked", "layer"]) }
        }
    }

    public var layer: String { node.value("layer") ?? "F.Cu" }

    public var isOnBack: Bool { layer == "B.Cu" }

    public var position: KiCadPoint {
        get { KiCadPoint(node["at"]?.number(at: 0) ?? 0, node["at"]?.number(at: 1) ?? 0) }
        nonmutating set { move(to: newValue, rotation: rotation) }
    }

    /// Degrees counter-clockwise
    public var rotation: Double { node["at"]?.number(at: 2) ?? 0 }

    public var placement: KiCadPlacement { KiCadPlacement(position: position, rotation: rotation) }

    /// Places it at `point` turned to `degrees`, its pads' and texts' own angles turning with it, as KiCad's
    /// FOOTPRINT::SetOrientation turns them
    public func move(to point: KiCadPoint, rotation degrees: Double) {
        let turn = degrees - rotation
        // KiCad 10 keeps a footprint's points and zones where they are on the board, not on the footprint
        let (old, new) = (placement, KiCadPlacement(position: point, rotation: degrees))
        KiCadFootprint.transformAbsolute(node) { new.apply(old.local($0)) }
        var at = [point.x, point.y] as [SExprConvertible]
        let normalized = KiCadFootprint.normalize(degrees)
        if normalized != 0 { at.append(normalized) }
        node.set(SExpr("at", at))
        guard turn != 0 else { return }
        // KiCad cannot keep a rectangle turned off square: it makes it a polygon of its four corners
        if (degrees / 90).rounded() != degrees / 90 {
            for child in node.items where child.head == "fp_rect" {
                guard let s = child["start"], let e = child["end"], let x0 = s.number(at: 0), let y0 = s.number(at: 1),
                      let x1 = e.number(at: 0), let y1 = e.number(at: 1) else { continue }
                let (left, right, top, bottom) = (min(x0, x1), max(x0, x1), min(y0, y1), max(y0, y1))
                // one with no area comes to nothing, as in KiCad
                if left == right || top == bottom { node.remove(child); continue }
                let pts = SExpr("pts", [SExpr("xy", left, top), SExpr("xy", right, top), SExpr("xy", right, bottom), SExpr("xy", left, bottom)])
                child.items[0] = SExpr(symbol: "fp_poly")
                child.items.removeAll { $0.head == "start" || $0.head == "end" }
                child.items.insert(pts, at: 1)
            }
        }
        for child in node.items where child.head == "pad" || child.head == "property" || child.head == "fp_text" {
            guard let a = child["at"] else { continue }
            let angle = KiCadFootprint.normalize360((a.number(at: 2) ?? 0) + turn)
            var values = [a.number(at: 0) ?? 0, a.number(at: 1) ?? 0] as [SExprConvertible]
            // a text keeps its angle written even when 0; a pad drops it
            if angle != 0 || child.head != "pad" { values.append(angle) }
            let unlocked = a.items.dropFirst(4).filter { $0.kind == .symbol }
            let list = SExpr("at", values)
            list.items += unlocked
            child.set(list)
        }
    }

    /// Turns it over onto the other side of the board where it stands, as KiCad's FOOTPRINT::SetLayerAndFlip does (a
    /// mirror top to bottom about its position and a half turn): its items' layers swapped front for back, their
    /// places mirrored on the footprint, its angle and theirs reflected, its texts read mirrored
    public func flip() {
        let theta = rotation
        let turned = KiCadFootprint.normalize(180 - theta)
        let origin = position
        func mirror(_ list: SExpr?) {
            guard let list, let x = list.number(at: 0), let y = list.number(at: 1) else { return }
            list.items[1] = x.sexpr
            list.items[2] = (-y).sexpr
        }
        /// An arc mirrored runs the other way: KiCad swaps its ends to keep it running as arcs do
        func swapEnds(_ arc: SExpr) {
            guard let s = arc.items.firstIndex(where: { $0.head == "start" }), let e = arc.items.firstIndex(where: { $0.head == "end" }) else { return }
            let start = arc.items[s]
            arc.items[s] = SExpr("start", Array(arc.items[e].arguments))
            arc.items[e] = SExpr("end", Array(start.arguments))
        }
        func mirrorPoints(_ item: SExpr) {
            for name in ["start", "end", "mid", "center"] { mirror(item[name]) }
            if item.head == "fp_arc" || item.head == "gr_arc" { swapEnds(item) }
            for p in item["pts"]?.items ?? [] {
                if p.head == "xy" { mirror(p) } else { for name in ["start", "mid", "end"] { mirror(p[name]) }; swapEnds(p) }
            }
        }
        func flipLayers(_ item: SExpr) {
            for name in ["layer", "layers"] {
                guard let list = item[name] else { continue }
                for i in 1..<list.items.count where list.items[i].kind == .string {
                    list.items[i] = SExpr(string: KiCadFootprint.flipLayer(list.items[i].text))
                }
            }
        }
        node.set(SExpr("layer", KiCadFootprint.flipLayer(layer)))
        KiCadFootprint.transformAbsolute(node) { KiCadPoint(2 * origin.x - $0.x, $0.y) }
        var at = [origin.x, origin.y] as [SExprConvertible]
        if turned != 0 { at.append(turned) }
        node.set(SExpr("at", at))
        for child in node.items {
            switch child.head {
            case "pad":
                if let a = child["at"], let x = a.number(at: 0), let y = a.number(at: 1) {
                    let local = (a.number(at: 2) ?? 0) - theta
                    let angle = KiCadFootprint.normalize360(turned - local)
                    var values = [x, -y] as [SExprConvertible]
                    if angle != 0 { values.append(angle) }
                    child.set(SExpr("at", values))
                }
                mirror(child["drill"]?["offset"])
                mirror(child["rect_delta"])
                if let chamfer = child["chamfer"] {
                    let swap = ["top_left": "bottom_left", "bottom_left": "top_left", "top_right": "bottom_right", "bottom_right": "top_right"]
                    for i in 1..<chamfer.items.count { chamfer.items[i] = SExpr(symbol: swap[chamfer.items[i].text] ?? chamfer.items[i].text) }
                }
                for primitive in child["primitives"]?.arguments ?? [] { mirrorPoints(primitive) }
                flipLayers(child)
            case "property", "fp_text":
                if let a = child["at"], let x = a.number(at: 0), let y = a.number(at: 1) {
                    // mirrored top to bottom (180 - angle), then the half turn (-angle), then kept upright as the
                    // half turn keeps a text upright (PCB_TEXT::KeepUpright): one that would read upside down is
                    // turned half round again, its justification reversed
                    var angle = KiCadFootprint.normalize360(-(a.number(at: 2) ?? 0))
                    let upright = !child.flag("unlocked") && !a.arguments.contains { $0.kind == .symbol && $0.text == "unlocked" }
                    if upright && angle >= 180 {
                        angle -= 180
                        if let justify = child["effects"]?["justify"] {
                            let opposite = ["left": "right", "right": "left", "top": "bottom", "bottom": "top"]
                            for i in 1..<justify.items.count { justify.items[i] = SExpr(symbol: opposite[justify.items[i].text] ?? justify.items[i].text) }
                        }
                    }
                    let list = SExpr("at", x, -y, angle)
                    list.items += a.items.dropFirst(4).filter { $0.kind == .symbol }
                    child.set(list)
                }
                let sided = (child.value("layer") ?? "").hasPrefix("F.") || (child.value("layer") ?? "").hasPrefix("B.")
                flipLayers(child)
                if sided, let effects = child["effects"] { KiCadFootprint.toggleMirror(effects) }
            case "fp_line", "fp_rect", "fp_arc", "fp_circle", "fp_poly", "fp_curve":
                mirrorPoints(child)
                flipLayers(child)
            case "zone", "point":
                flipLayers(child)
            default:
                break
            }
        }
    }

    /// Moves the items a footprint keeps in board coordinates (its points and zones) by `transform`
    static func transformAbsolute(_ node: SExpr, _ transform: (KiCadPoint) -> KiCadPoint) {
        func move(_ list: SExpr?) {
            guard let list, let x = list.number(at: 0), let y = list.number(at: 1) else { return }
            let p = transform(KiCadPoint(x, y))
            list.items[1] = p.x.sexpr
            list.items[2] = p.y.sexpr
        }
        for child in node.items {
            if child.head == "point" { move(child["at"]) }
            if child.head == "zone" {
                for outline in child.all("polygon") + child.all("filled_polygon") {
                    for p in outline["pts"]?.items ?? [] {
                        if p.head == "xy" { move(p) } else { for name in ["start", "mid", "end"] { move(p[name]) } }
                    }
                }
            }
        }
    }

    /// The layer on the other side: F.Cu for B.Cu, B.SilkS for F.SilkS…
    public static func flipLayer(_ layer: String) -> String {
        if layer.hasPrefix("F.") { return "B." + layer.dropFirst(2) }
        if layer.hasPrefix("B.") { return "F." + layer.dropFirst(2) }
        return layer
    }

    /// Reads a text mirrored, or no longer mirrored
    static func toggleMirror(_ effects: SExpr) {
        if let justify = effects["justify"] {
            if let i = justify.items.firstIndex(where: { $0.kind == .symbol && $0.text == "mirror" }) {
                justify.items.remove(at: i)
                if justify.items.count == 1 { effects.remove(justify) }
            } else {
                justify.items.append(SExpr(symbol: "mirror"))
            }
        } else {
            effects.items.append(SExpr("justify", Keyword("mirror")))
        }
    }

    /// An item's angle as KiCad writes a pad's or a text's: from 0 up to 360
    static func normalize360(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d == 360 ? 0 : d
    }

    /// A footprint's angle as KiCad writes it: above -180, up to 180
    static func normalize(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        if d > 180 { d -= 360 }
        return d == -180 ? 180 : d
    }

    public var isLocked: Bool { node.flag("locked") }

    /// A field's text: "Reference", "Value", "Datasheet", "Description" or one of the symbol's own
    public func property(_ name: String) -> String? {
        node.all("property").first { $0.text(at: 0) == name }?.text(at: 1)
    }

    /// Every field, in order, with its text
    public var properties: [(name: String, value: String)] {
        node.all("property").compactMap { p in p.text(at: 0).map { (name: $0, value: p.text(at: 1) ?? "") } }
    }

    /// Sets a field's text, adding the field (hidden, on the fab layer, as KiCad adds a symbol's fields) if it is new
    public func setProperty(_ name: String, _ value: String) {
        if let p = node.all("property").first(where: { $0.text(at: 0) == name }) {
            p.items[2] = SExpr(string: value)
            return
        }
        let field = SExpr("property", name, value,
                          SExpr("at", 0.0, 0.0, KiCadFootprint.normalize(rotation)),
                          SExpr("layer", isOnBack ? "B.Fab" : "F.Fab"),
                          SExpr("hide", Keyword("yes")),
                          SExpr("uuid", KiCadBoard.newUUID()),
                          SExpr("effects", SExpr("font", SExpr("size", 1.27, 1.27), SExpr("thickness", 0.15))))
        node.insert(field, after: ["property", "tags", "descr", "at", "uuid", "locked", "layer"])
    }

    public func removeProperty(_ name: String) {
        node.items.removeAll { $0.head == "property" && $0.text(at: 0) == name }
    }

    public var reference: String {
        get { property("Reference") ?? "" }
        nonmutating set { setProperty("Reference", newValue) }
    }

    public var value: String {
        get { property("Value") ?? "" }
        nonmutating set { setProperty("Value", newValue) }
    }

    /// The flags of its (attr …) list: smd, through_hole, board_only, exclude_from_pos_files, exclude_from_bom,
    /// allow_missing_courtyard, dnp
    public var attributes: Set<String> {
        get { Set(node["attr"]?.arguments.filter { $0.kind == .symbol }.map(\.text) ?? []) }
        nonmutating set {
            // KiCad's order: the mounting type first, then the flags
            let order = ["smd", "through_hole", "board_only", "exclude_from_pos_files", "exclude_from_bom",
                         "allow_missing_courtyard", "dnp", "allow_soldermask_bridges"]
            let flags = newValue.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
            if flags.isEmpty { node.remove("attr"); return }
            node.set(SExpr("attr", flags.map { Keyword($0) }), after: ["path", "sheetfile", "sheetname", "property"])
        }
    }

    public var pads: [KiCadPad] { node.all("pad").map { KiCadPad($0, footprint: self) } }

    public func pads(numbered number: String) -> [KiCadPad] { pads.filter { $0.number == number } }

    /// Its drawings (silkscreen, fabrication, courtyard, edge cuts…), on the board
    public var drawings: [KiCadDrawing] {
        let placement = self.placement
        return node.items.filter { KiCadDrawing.footprintHeads.contains($0.head ?? "") }.map { KiCadDrawing($0, placement: placement) }
    }

    /// The box round its courtyard, or round its pads and drawings if it has none
    public var bounds: KiCadBox? {
        let courtyard = drawings.filter { $0.layer.hasSuffix("CrtYd") }.flatMap(\.points)
        if let box = KiCadBox(courtyard) { return box }
        return KiCadBox(drawings.flatMap(\.points) + pads.flatMap(\.outline))
    }
}

/// A footprint's pad
public struct KiCadPad {
    public let node: SExpr
    public let footprint: KiCadFootprint

    init(_ node: SExpr, footprint: KiCadFootprint) { self.node = node; self.footprint = footprint }

    /// Its number, "1", "A3", "EP"; empty for a mounting hole
    public var number: String { node.text(at: 0) ?? "" }

    /// thru_hole, smd, connect or np_thru_hole
    public var type: String { node.text(at: 1) ?? "" }

    /// circle, rect, oval, trapezoid, roundrect or custom
    public var shape: String { node.text(at: 2) ?? "" }

    public var uuid: String { node.value("uuid") ?? "" }

    /// Where it is on its footprint, before the footprint turns
    public var localPosition: KiCadPoint { KiCadPoint(node["at"]?.number(at: 0) ?? 0, node["at"]?.number(at: 1) ?? 0) }

    /// Its angle on the board (its footprint's included)
    public var angle: Double { node["at"]?.number(at: 2) ?? 0 }

    public var position: KiCadPoint { footprint.placement.apply(localPosition) }

    public var size: (width: Double, height: Double) { (node["size"]?.number(at: 0) ?? 0, node["size"]?.number(at: 1) ?? 0) }

    public var drill: Double? { node["drill"].flatMap { d in d.number(at: 0) ?? d.number(at: 1) } }

    public var layers: [String] { node["layers"]?.arguments.map(\.text) ?? [] }

    /// Whether it reaches a copper layer
    public var isCopper: Bool { layers.contains { $0.hasSuffix(".Cu") } }

    /// The copper layers it is on ("*.Cu" for every one)
    public func isOn(copper layer: String) -> Bool {
        layers.contains { $0 == layer || $0 == "*.Cu" || ($0 == "F&B.Cu" && (layer == "F.Cu" || layer == "B.Cu")) }
    }

    public var net: String? { footprint.board.netName(node["net"]) }

    /// Puts the pad on `name`'s net, or on none
    public func setNet(_ name: String?) {
        node.remove("net")
        guard let name, !name.isEmpty else { return }
        let list = footprint.board.netList(name, pad: true)
        if let i = node.items.firstIndex(where: { KiCadPad.afterNet.contains($0.head ?? "") }) {
            node.items.insert(list, at: i)
        } else {
            node.items.append(list)
        }
    }

    /// What KiCad writes after a pad's net
    static let afterNet: Set<String> = ["pinfunction", "pintype", "die_length", "die_delay", "solder_mask_margin",
                                        "solder_paste_margin", "solder_paste_margin_ratio", "clearance", "zone_connect",
                                        "thermal_bridge_width", "thermal_bridge_angle", "thermal_gap", "options",
                                        "primitives", "teardrops", "tenting", "zone_layer_connections", "uuid"]

    public var pinFunction: String? { node.value("pinfunction") }

    public var pinType: String? { node.value("pintype") }

    public func setPin(function: String?, type: String?) {
        node.remove("pinfunction"); node.remove("pintype")
        var lists: [SExpr] = []
        if let function, !function.isEmpty { lists.append(SExpr("pinfunction", function)) }
        if let type, !type.isEmpty { lists.append(SExpr("pintype", type)) }
        guard !lists.isEmpty else { return }
        let i = (node.items.lastIndex { $0.head == "net" }).map { $0 + 1 }
            ?? node.items.firstIndex { KiCadPad.afterNet.contains($0.head ?? "") } ?? node.items.count
        node.items.insert(contentsOf: lists, at: i)
    }

    /// A pad whose pin the schematic leaves unconnected (KiCad's "no_connect" pin type)
    public var isNoConnect: Bool { pinType?.hasPrefix("no_connect") ?? false }

    /// Its outline on the board
    public var outline: [KiCadPoint] {
        let (w, h) = size
        let center = position
        switch shape {
        case "circle": return KiCadPolygon.circle(center: center, radius: w / 2)
        case "oval": return KiCadPolygon.oval(center: center, width: w, height: h, rotation: angle)
        case "roundrect":
            let ratio = node["roundrect_rratio"]?.number(at: 0) ?? 0.25
            return KiCadPolygon.roundedRect(center: center, width: w, height: h, rotation: angle, radius: ratio * min(w, h))
        case "custom":
            // the anchor and the primitives drawn on it
            var points = KiCadPolygon.roundedRect(center: center, width: w, height: h, rotation: angle)
            for primitive in node["primitives"]?.arguments ?? [] {
                let local = KiCadDrawing(primitive, placement: KiCadPlacement(position: center, rotation: angle)).points
                points += local
            }
            return KiCadBox(points).map { b in
                [KiCadPoint(b.minX, b.minY), KiCadPoint(b.maxX, b.minY), KiCadPoint(b.maxX, b.maxY), KiCadPoint(b.minX, b.maxY)]
            } ?? points
        default:
            return KiCadPolygon.roundedRect(center: center, width: w, height: h, rotation: angle)
        }
    }
}

/// A track: a straight segment, or an arc through a middle point
public struct KiCadTrack {
    public let node: SExpr
    unowned let board: KiCadBoard

    init(_ node: SExpr, board: KiCadBoard) { self.node = node; self.board = board }

    public var isArc: Bool { node.head == "arc" }
    public var start: KiCadPoint { KiCadPoint(node["start"]?.number(at: 0) ?? 0, node["start"]?.number(at: 1) ?? 0) }
    public var end: KiCadPoint { KiCadPoint(node["end"]?.number(at: 0) ?? 0, node["end"]?.number(at: 1) ?? 0) }
    public var mid: KiCadPoint? { node["mid"].map { KiCadPoint($0.number(at: 0) ?? 0, $0.number(at: 1) ?? 0) } }
    public var width: Double { node["width"]?.number(at: 0) ?? 0.25 }
    public var layer: String { node.value("layer") ?? "F.Cu" }
    public var uuid: String { node.value("uuid") ?? "" }
    public var net: String? { board.netName(node["net"]) }

    public func setNet(_ name: String?) {
        node.set(board.numbersNets ? SExpr("net", name.map(board.netCode) ?? 0) : SExpr("net", name ?? ""), after: ["layer", "locked", "width", "end", "mid", "start"])
        if !board.numbersNets && (name ?? "").isEmpty { node.remove("net") }
    }

    /// Its centre line
    public var points: [KiCadPoint] {
        if isArc, let mid { return KiCadPolygon.arc(start: start, mid: mid, end: end) }
        return [start, end]
    }
}

/// A via
public struct KiCadVia {
    public let node: SExpr
    unowned let board: KiCadBoard

    init(_ node: SExpr, board: KiCadBoard) { self.node = node; self.board = board }

    public var position: KiCadPoint { KiCadPoint(node["at"]?.number(at: 0) ?? 0, node["at"]?.number(at: 1) ?? 0) }
    public var size: Double { node["size"]?.number(at: 0) ?? 0.6 }
    public var drill: Double { node["drill"]?.number(at: 0) ?? 0.3 }
    public var layers: [String] { node["layers"]?.arguments.map(\.text) ?? ["F.Cu", "B.Cu"] }
    public var uuid: String { node.value("uuid") ?? "" }
    public var net: String? { board.netName(node["net"]) }

    public func setNet(_ name: String?) {
        node.set(board.numbersNets ? SExpr("net", name.map(board.netCode) ?? 0) : SExpr("net", name ?? ""), after: ["layers", "drill", "size", "at"])
        if !board.numbersNets && (name ?? "").isEmpty { node.remove("net") }
    }
}

/// A copper zone (or a rule area)
public struct KiCadZone {
    public let node: SExpr
    unowned let board: KiCadBoard

    init(_ node: SExpr, board: KiCadBoard) { self.node = node; self.board = board }

    public var uuid: String { node.value("uuid") ?? "" }
    public var name: String? { node.value("name") }
    public var isRuleArea: Bool { node["keepout"] != nil || node["placement"] != nil && node["fill"] == nil }

    public var layers: [String] {
        if let l = node.value("layer") { return [l] }
        return node["layers"]?.arguments.map(\.text) ?? []
    }

    public var isCopper: Bool { !isRuleArea && layers.contains { $0.hasSuffix(".Cu") } }

    public var net: String? {
        if board.numbersNets { return node.value("net_name").flatMap { $0.isEmpty ? nil : $0 } }
        return board.netName(node["net"])
    }

    public func setNet(_ name: String?) {
        if board.numbersNets {
            node.set(SExpr("net", name.map(board.netCode) ?? 0))
            node.set(SExpr("net_name", name ?? ""), after: ["net"])
        } else {
            node.remove("net")
            if let name, !name.isEmpty { node.items.insert(SExpr("net", name), at: 1) }
        }
    }

    /// Its outline
    public var outline: [KiCadPoint] { KiCadZone.points(node["polygon"]?["pts"]) }

    /// The copper it was last filled with, by layer
    public var fills: [(layer: String, points: [KiCadPoint])] {
        node.all("filled_polygon").map { (layer: $0.value("layer") ?? layers.first ?? "", points: KiCadZone.points($0["pts"])) }
    }

    static func points(_ pts: SExpr?) -> [KiCadPoint] {
        var out: [KiCadPoint] = []
        for item in pts?.items ?? [] {
            if item.head == "xy" {
                out.append(KiCadPoint(item.number(at: 0) ?? 0, item.number(at: 1) ?? 0))
            } else if item.head == "arc", let s = item["start"], let m = item["mid"], let e = item["end"] {
                out += KiCadPolygon.arc(start: KiCadPoint(s.number(at: 0) ?? 0, s.number(at: 1) ?? 0),
                                        mid: KiCadPoint(m.number(at: 0) ?? 0, m.number(at: 1) ?? 0),
                                        end: KiCadPoint(e.number(at: 0) ?? 0, e.number(at: 1) ?? 0))
            }
        }
        return out
    }
}

/// A drawing: a line, rectangle, arc, circle, polygon or curve, the board's own or a footprint's
public struct KiCadDrawing {
    public let node: SExpr
    /// Where its footprint is, for a footprint's
    public let placement: KiCadPlacement?

    init(_ node: SExpr, placement: KiCadPlacement?) { self.node = node; self.placement = placement }

    public static let heads: Set<String> = ["gr_line", "gr_rect", "gr_arc", "gr_circle", "gr_poly", "gr_curve"]
    static let footprintHeads: Set<String> = ["fp_line", "fp_rect", "fp_arc", "fp_circle", "fp_poly", "fp_curve"]

    /// line, rect, arc, circle, poly or curve
    public var kind: String { String((node.head ?? "").split(separator: "_").last ?? "") }

    public var layer: String { node.value("layer") ?? "" }

    public var width: Double { node["stroke"]?["width"]?.number(at: 0) ?? node["width"]?.number(at: 0) ?? 0.1 }

    public var isFilled: Bool {
        guard let fill = node["fill"] else { return false }
        let v = fill.text(at: 0) ?? fill["type"]?.text(at: 0)
        return v == "yes" || v == "solid"
    }

    func point(_ name: String) -> KiCadPoint? {
        guard let list = node[name], let x = list.number(at: 0), let y = list.number(at: 1) else { return nil }
        let p = KiCadPoint(x, y)
        return placement?.apply(p) ?? p
    }

    /// The points it runs through, on the board (a rectangle's four corners, a circle's and an arc's in pieces)
    public var points: [KiCadPoint] {
        switch kind {
        case "line": return [point("start"), point("end")].compactMap { $0 }
        case "rect":
            guard let s = node["start"], let e = node["end"] else { return [] }
            let (x0, y0, x1, y1) = (s.number(at: 0) ?? 0, s.number(at: 1) ?? 0, e.number(at: 0) ?? 0, e.number(at: 1) ?? 0)
            let r = cornerRadius
            guard r > 0 else {
                let corners = [KiCadPoint(x0, y0), KiCadPoint(x1, y0), KiCadPoint(x1, y1), KiCadPoint(x0, y1)]
                return corners.map { placement?.apply($0) ?? $0 }
            }
            // its sides and its corners' quarter circles, clockwise from the top left
            let (l, t, rt, b) = (min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1))
            let k = r * (1 - 1 / 2.0.squareRoot())
            let corners: [(KiCadPoint, KiCadPoint, KiCadPoint)] = [
                (KiCadPoint(rt - r, t), KiCadPoint(rt - k, t + k), KiCadPoint(rt, t + r)),
                (KiCadPoint(rt, b - r), KiCadPoint(rt - k, b - k), KiCadPoint(rt - r, b)),
                (KiCadPoint(l + r, b), KiCadPoint(l + k, b - k), KiCadPoint(l, b - r)),
                (KiCadPoint(l, t + r), KiCadPoint(l + k, t + k), KiCadPoint(l + r, t)),
            ]
            var pts: [KiCadPoint] = []
            for (a, m, c) in corners {
                for p in KiCadPolygon.arc(start: a, mid: m, end: c, segments: 8) where pts.last != p { pts.append(p) }
            }
            if pts.first == pts.last { pts.removeLast() }
            return pts.map { placement?.apply($0) ?? $0 }
        case "circle":
            guard let c = point("center"), let e = point("end") else { return [] }
            return KiCadPolygon.circle(center: c, radius: c.distance(to: e), segments: 32)
        case "arc":
            guard let s = point("start"), let m = point("mid"), let e = point("end") else { return [] }
            return KiCadPolygon.arc(start: s, mid: m, end: e)
        case "poly":
            let pts = KiCadZone.points(node["pts"])
            return pts.map { placement?.apply($0) ?? $0 }
        case "curve":
            let pts = KiCadZone.points(node["pts"]).map { placement?.apply($0) ?? $0 }
            guard pts.count == 4 else { return pts }
            return (0...16).map { k in
                let t = Double(k) / 16, u = 1 - t
                return pts[0] * (u * u * u) + pts[1] * (3 * u * u * t) + pts[2] * (3 * u * t * t) + pts[3] * (t * t * t)
            }
        default: return []
        }
    }

    /// Whether its points close on themselves
    public var isClosed: Bool { kind == "rect" || kind == "circle" || kind == "poly" }

    /// A rectangle's rounded corners' radius (mm; no more than half its shorter side, as KiCad keeps it), 0 if square
    public var cornerRadius: Double {
        guard kind == "rect", let r = node["radius"]?.number(at: 0), r > 0, let s = node["start"], let e = node["end"] else { return 0 }
        let w = abs((e.number(at: 0) ?? 0) - (s.number(at: 0) ?? 0)), h = abs((e.number(at: 1) ?? 0) - (s.number(at: 1) ?? 0))
        return min(r, min(w, h) / 2)
    }
}
