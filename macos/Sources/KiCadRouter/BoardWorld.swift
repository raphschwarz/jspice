// Ported from KiCad 10.0.7: pcbnew/router/pns_kicad_iface.cpp (SyncWorld, syncPad, syncTrack, syncVia, syncZone,
// syncGraphicalItem), pcbnew/pad.cpp (BuildEffectiveShapes, TransformShapeToPolygon, FlashLayer, IsOnCopperLayer,
// GetClearanceOverrides), common/eda_shape.cpp (makeEffectiveShapes, SetArcGeometry, GetArcAngle, rotate),
// pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp (how a board's items are read: units, pad and drawing
// placement), pcbnew/board_design_settings.cpp and common/project/net_settings.cpp (the rules and net classes).
// Copyright (C) 2013-2016 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// A KiCad board as KiCad's router sees it: its items in the order KiCad's SyncWorld puts them in the router's world,
/// with the shapes KiCad makes of them, and the board's rules as its DRC engine works them out with no rules of the
/// user's own. What KiCad's router would see and this cannot make yet (a text on copper, a keepout zone's triangles,
/// an arc track, a custom pad's merged outline) is named in `unsupported`.
public struct BoardWorld {
    public private(set) var copperLayers = 2
    public private(set) var items: [WorldItem] = []
    public private(set) var rules = WorldRules()
    /// Nets by name, numbered as KiCad numbers them reading the board (0 the "no net" net)
    public private(set) var netCodes: [String: Int] = ["": 0]
    public private(set) var netNames: [Int: String] = [0: ""]
    public private(set) var unsupported: Set<String> = []
    /// The board's copper layers by name, as router layers (F.Cu 0, the inner ones in turn, B.Cu last)
    public private(set) var layerIndex: [String: Int] = [:]
    /// The board's minimum track width, via diameter and via drill (its design settings)
    public private(set) var minTrackWidth = 0
    public private(set) var minViaDiameter = 500_000
    public private(set) var minViaDrill = 300_000

    let netClasses: NetClasses

    /// The world of `board`, its rules from its project file's JSON (`project`, nil for KiCad's defaults)
    public init(board: KiCadBoard, project: [String: Any]? = nil) {
        netClasses = NetClasses(project: project)
        readLayers(board)
        numberNets(board.root)
        readRules(board, project: project)
        sync(board)
    }

    public init(board: KiCadBoard, projectURL: URL?) {
        let json = projectURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        self.init(board: board, project: json)
    }

    // MARK: - Reading

    /// Millimetres as KiCad's parser makes them board units: nanometres, rounded (parseBoardUnits)
    static func iu(_ mm: Double) -> Int {
        let limit = Double(Int32.max) - 10
        return KiMath.round(min(max(mm * 1_000_000, -limit), limit))
    }

    static func iu(_ list: SExpr?, _ i: Int) -> Int { iu(list?.number(at: i) ?? 0) }

    static func point(_ list: SExpr?) -> IPoint { IPoint(iu(list, 0), iu(list, 1)) }

    private mutating func readLayers(_ board: KiCadBoard) {
        var inner: [Int] = []
        var hasFront = false, hasBack = false
        for l in board.root["layers"]?.arguments ?? [] {
            guard let name = l.text(at: 0), name.hasSuffix(".Cu") else { continue }
            if name == "F.Cu" {
                hasFront = true
            } else if name == "B.Cu" {
                hasBack = true
            } else if name.hasPrefix("In"), let n = Int(name.dropFirst(2).dropLast(3)) {
                inner.append(n)
            }
        }
        copperLayers = max(2, (hasFront ? 1 : 0) + (hasBack ? 1 : 0) + inner.count)
        layerIndex["F.Cu"] = 0
        layerIndex["B.Cu"] = copperLayers - 1
        for n in inner { layerIndex["In\(n).Cu"] = n }
    }

    /// The copper layers a list of layer names covers ("*.Cu", "F&B.Cu" or each by name), as router layers
    func copper(_ names: [String]) -> [Int] {
        var out = Set<Int>()
        for n in names {
            if n == "*.Cu" {
                out.formUnion(0..<copperLayers)
            } else if n == "F&B.Cu" {
                out.formUnion([0, copperLayers - 1])
            } else if let l = layerIndex[n] {
                out.insert(l)
            }
        }
        return out.sorted()
    }

    /// Nets numbered in the order KiCad's parser meets them (a KiCad 10 board names its nets on its items)
    private mutating func numberNets(_ node: SExpr) {
        for item in node.items {
            if item.head == "net" {
                // (KiCad 9: (net 3 "name") in a table, or on a pad; KiCad 10: (net "name"))
                let name = item.items.count >= 3 ? item.text(at: 1) : item.text(at: 0)
                if let name, Int(name) == nil || item.items.count >= 3, netCodes[name] == nil {
                    netCodes[name] = netCodes.count
                    netNames[netCodes[name]!] = name
                }
            } else if item.kind == .list {
                numberNets(item)
            }
        }
    }

    private func netCode(_ node: SExpr) -> Int {
        guard let n = node["net"] else { return 0 }
        let name = n.items.count >= 3 ? n.text(at: 1) : n.text(at: 0)
        return name.flatMap { netCodes[$0] } ?? 0
    }

    private func netName(_ node: SExpr) -> String {
        guard let n = node["net"] else { return "" }
        return (n.items.count >= 3 ? n.text(at: 1) : n.text(at: 0)) ?? ""
    }

    // MARK: - Rules

    private mutating func readRules(_ board: KiCadBoard, project: [String: Any]?) {
        let ds = ((project?["board"] as? [String: Any])?["design_settings"] as? [String: Any])?["rules"] as? [String: Any] ?? [:]
        func mm(_ key: String, _ d: Double) -> Int {
            // (PARAM_SCALED: the value over the scale, rounded)
            Self.iuScaled((ds[key] as? NSNumber)?.doubleValue ?? d)
        }
        rules.board = true
        rules.clearance = mm("min_clearance", 0.0)
        rules.holeClearance = mm("min_hole_clearance", 0.25)
        rules.holeToHole = mm("min_hole_to_hole", 0.25)
        rules.edgeClearance = mm("min_copper_edge_clearance", 0.5)
        rules.maxError = mm("max_error", 0.005)
        rules.epsilon = 500
        minTrackWidth = mm("min_track_width", 0.0)
        minViaDiameter = mm("min_via_diameter", 0.5)
        minViaDrill = mm("min_through_hole_diameter", 0.3)
        for (name, code) in netCodes { rules.netClearance[code] = netClasses.effective(name).clearance ?? 0 }
        // the board's worst clearance (BOARD::GetMaxClearanceValue): its minimums, its net classes', a millimetre
        // (DRC's implicit physical clearance round barcodes), its zones' own and its pads' own
        var worst = max(rules.clearance, rules.holeClearance, rules.holeToHole, rules.edgeClearance)
        worst = max(worst, netClasses.worstClearance, 1_000_000)
        worst = min(worst, Self.maximumClearance)
        for zone in board.root.all("zone") + board.root.all("footprint").flatMap({ $0.all("zone") }) {
            if let c = zone["connect_pads"]?["clearance"] { worst = max(worst, Self.iu(c, 0)) }
        }
        for fp in board.root.all("footprint") {
            for pad in fp.all("pad") {
                if let o = clearanceOverride(pad, fp) { worst = max(worst, o) }
            }
        }
        rules.maxClearance = worst
    }

    /// KiCad's MAXIMUM_CLEARANCE: half a metre
    static let maximumClearance = 500_000_000

    /// A project file's millimetres as PARAM_SCALED reads them: over a millionth of a millimetre, rounded
    static func iuScaled(_ mm: Double) -> Int { KiMath.round(mm / 1e-6) }

    // MARK: - SyncWorld

    private mutating func sync(_ board: KiCadBoard) {
        let root = board.root
        // the board's own drawings, its zones, its footprints (pads, then texts, zones and drawings), its tracks
        for item in root.items {
            switch item.head ?? "" {
            case "gr_line", "gr_rect", "gr_arc", "gr_circle", "gr_poly", "gr_curve":
                graphic(item, placement: nil)
            case "gr_text", "gr_text_box", "dimension", "gr_table", "barcode":
                text(item)
            default:
                break
            }
        }
        for zone in root.all("zone") { self.zone(zone, footprint: nil) }
        for fp in root.all("footprint") {
            let placement = FootprintPlacement(fp)
            for pad in fp.all("pad") { self.pad(pad, fp, placement) }
            for child in fp.items {
                switch child.head ?? "" {
                case "property", "fp_text": text(child)
                default: break
                }
            }
            for zone in fp.all("zone") { self.zone(zone, footprint: fp) }
            for child in fp.items {
                switch child.head ?? "" {
                case "fp_line", "fp_rect", "fp_arc", "fp_circle", "fp_poly", "fp_curve":
                    graphic(child, placement: placement)
                case "fp_text_box", "dimension", "table", "barcode":
                    text(child)
                default:
                    break
                }
            }
        }
        for item in root.items {
            switch item.head ?? "" {
            case "segment": track(item)
            case "arc": arcTrack(item)
            case "via": via(item)
            default: break
            }
        }
    }

    /// Where a footprint is, as KiCad turns its pads and drawings onto the board
    struct FootprintPlacement {
        var position: IPoint
        var orientation: EDAAngle
        var reference: String

        init(_ fp: SExpr) {
            position = BoardWorld.point(fp["at"])
            orientation = EDAAngle(degrees: fp["at"]?.number(at: 2) ?? 0)
            reference = fp.all("property").first { $0.text(at: 0) == "Reference" }?.text(at: 1) ?? fp.value("reference") ?? ""
        }

        /// A point of the footprint's on the board (BOARD_ITEM::SetFPRelativePosition)
        func apply(_ p: IPoint) -> IPoint { KiMath.rotate(p, orientation) + position }
    }

    private func layerNames(_ node: SExpr) -> [String] {
        if let l = node["layers"] { return l.arguments.map(\.text) }
        if let l = node.value("layer") { return [l] }
        return []
    }

    private mutating func text(_ node: SExpr) {
        // (a text on copper is an obstacle in KiCad's router, its outline made from its strokes; not here yet)
        let names = layerNames(node)
        guard !copper(names).isEmpty else { return }
        if node.head == "property" || node.head == "fp_text" {
            if node.flag("hide") || node["hide"]?.text(at: 0) == "yes" { return }
        }
        unsupported.insert("text on copper")
    }

    // MARK: - Pads (syncPad)

    /// A pad as KiCad holds it once read
    struct Pad {
        enum Attribute { case pth, smd, conn, npth }
        enum Kind { case circle, rect, oval, trapezoid, roundrect, chamferedRect, custom }
        var attribute: Attribute
        var kind: Kind
        var pos: IPoint
        var orientation: EDAAngle
        var size: IPoint
        var drill: IPoint
        var oblong = false
        var offset = IPoint.zero
        var delta = IPoint.zero
        var roundRatio = 0.25
        var chamferRatio = 0.2
        var chamfers = 0
        var layers: [String]
        var anchorRect = false
        var removeUnconnected = false

        /// Its shape's centre on the board (PAD::ShapePos)
        var shapePos: IPoint { offset == .zero ? pos : pos + KiMath.rotate(offset, orientation) }

        var cornerRadius: Int { KiMath.round(Double(min(size.x, size.y)) * roundRatio) }
    }

    func readPad(_ node: SExpr, _ placement: FootprintPlacement) -> Pad {
        let attribute: Pad.Attribute
        switch node.text(at: 1) {
        case "smd": attribute = .smd
        case "connect": attribute = .conn
        case "np_thru_hole": attribute = .npth
        default: attribute = .pth
        }
        var kind: Pad.Kind
        switch node.text(at: 2) {
        case "rect": kind = .rect
        case "oval": kind = .oval
        case "trapezoid": kind = .trapezoid
        case "roundrect": kind = .roundrect
        case "custom": kind = .custom
        default: kind = .circle
        }
        // (KiCad's defaults: a 60 mil pad, a 30 mil drill; a through-hole pad with no drill one of a nanometre)
        var pad = Pad(attribute: attribute, kind: kind, pos: placement.position, orientation: .zero, size: IPoint(1_524_000, 1_524_000),
                      drill: attribute == .npth ? IPoint(762_000, 762_000) : attribute == .pth ? IPoint(1, 1) : .zero,
                      layers: layerNames(node))
        if let at = node["at"] {
            pad.pos = placement.apply(Self.point(at))
            if let a = at.number(at: 2) { pad.orientation = EDAAngle(degrees: a) }
        }
        if let s = node["size"] { pad.size = Self.point(s) }
        if let d = node["drill"] {
            var size = pad.drill
            var haveWidth = false
            for arg in d.arguments {
                if arg.kind == .symbol && arg.text == "oval" {
                    pad.oblong = true
                } else if arg.head == "offset" {
                    pad.offset = Self.point(arg)
                } else if let v = Double(arg.text) {
                    if !haveWidth {
                        size = IPoint(Self.iu(v), Self.iu(v))
                        haveWidth = true
                    } else {
                        size.y = Self.iu(v)
                    }
                }
            }
            pad.drill = attribute == .smd || attribute == .conn ? .zero : size
        }
        if let d = node["rect_delta"] { pad.delta = Self.point(d) }
        if let r = node["roundrect_rratio"]?.number(at: 0) { pad.roundRatio = min(max(r, 0), 0.5) }
        if let c = node["chamfer_ratio"]?.number(at: 0) {
            pad.chamferRatio = min(max(c, 0), 0.5)
            if pad.chamferRatio > 0 && pad.kind == .roundrect { pad.kind = .chamferedRect }
        }
        if let c = node["chamfer"] {
            var bits = 0
            for a in c.arguments {
                switch a.text {
                case "top_left": bits |= PadPolygon.chamferTopLeft
                case "top_right": bits |= PadPolygon.chamferTopRight
                case "bottom_left": bits |= PadPolygon.chamferBottomLeft
                case "bottom_right": bits |= PadPolygon.chamferBottomRight
                default: break
                }
            }
            pad.chamfers = bits
            if bits != 0 && (pad.kind == .roundrect || pad.kind == .chamferedRect) { pad.kind = .chamferedRect }
        }
        pad.anchorRect = node["options"]?["anchor"]?.text(at: 0) == "rect"
        pad.removeUnconnected = node["remove_unused_layers"].map { $0.text(at: 0) != "no" } ?? false
        return pad
    }

    /// The pads' (and its footprint's) own clearance (PAD::GetClearanceOverrides)
    private func clearanceOverride(_ pad: SExpr, _ fp: SExpr) -> Int? {
        if let c = pad["clearance"] { return Self.iu(c, 0) }
        if let c = fp["clearance"] { return Self.iu(c, 0) }
        return nil
    }

    /// The pad's effective shapes on its layers (PAD::buildEffectiveShape)
    func effectiveShapes(_ p: Pad) -> [Shape] {
        let shapePos = p.shapePos
        var kind = p.kind
        if kind == .custom { kind = p.anchorRect ? .rect : .circle }
        switch kind {
        case .circle:
            return [.circle(center: shapePos, radius: p.size.x / 2)]
        case .oval:
            if p.size.x == p.size.y { return [.circle(center: shapePos, radius: p.size.x / 2)] }
            let half = p.size.divided(by: 2)
            let hw = min(half.x, half.y)
            let len = KiMath.rotate(IPoint(half.x - hw, half.y - hw), p.orientation)
            return [.segment(Seg(shapePos - len, shapePos + len), width: hw * 2)]
        case .rect, .trapezoid, .roundrect:
            let r = kind == .roundrect ? p.cornerRadius : 0
            var half = IPoint(p.size.x / 2, p.size.y / 2)
            var td = IPoint.zero
            if r != 0 {
                half = half - IPoint(r, r)
                // (a rounded rectangle all but round is a circle)
                if half.x < 100 && half.y < 100 { return [.circle(center: shapePos, radius: r)] }
            } else if kind == .trapezoid {
                td = p.delta.divided(by: 2)
            }
            var corners = LineChain([IPoint(-half.x - td.y, half.y + td.x), IPoint(half.x + td.y, half.y - td.x),
                                     IPoint(half.x - td.y, -half.y + td.x), IPoint(-half.x + td.y, -half.y - td.x)])
            corners = corners.rotated(p.orientation).moved(shapePos)
            let c = corners.points
            var shapes: [Shape]
            if c.count == 4 && ((c[0].y == c[1].y && c[1].x == c[2].x && c[2].y == c[3].y && c[3].x == c[0].x)
                                || (c[0].x == c[1].x && c[1].y == c[2].y && c[2].x == c[3].x && c[3].y == c[0].y)) {
                let w = abs(c[2].x - c[0].x), h = abs(c[2].y - c[0].y)
                let o = IPoint(min(c[2].x, c[0].x), min(c[2].y, c[0].y))
                shapes = [.rect(IBox(minX: o.x, minY: o.y, maxX: o.x + w, maxY: o.y + h))]
            } else {
                shapes = [.simple(LineChain(c, closed: true))]
            }
            if r != 0 {
                for i in 0..<4 { shapes.append(.segment(Seg(c[i], c[(i + 1) % 4]), width: r * 2)) }
            }
            return shapes
        case .chamferedRect:
            let o = PadPolygon.roundChamferedRect(position: shapePos, size: p.size, rotation: p.orientation, cornerRadius: p.cornerRadius,
                                                  chamferRatio: p.chamferRatio, chamferCorners: p.chamfers, inflate: 0,
                                                  maxError: rules.maxError, errorLocation: .inside)
            return [.simple(LineChain(o.points, closed: true))]
        case .custom:
            return []
        }
    }

    /// The pad's polygon, the error outside it (PAD::TransformShapeToPolygon, as GetEffectivePolygon makes it)
    func effectivePolygon(_ p: Pad) -> LineChain? {
        switch p.kind {
        case .roundrect, .chamferedRect:
            let o = PadPolygon.roundChamferedRect(position: p.shapePos, size: p.size, rotation: p.orientation, cornerRadius: p.cornerRadius,
                                                  chamferRatio: p.kind == .chamferedRect ? p.chamferRatio : 0,
                                                  chamferCorners: p.kind == .chamferedRect ? p.chamfers : 0, inflate: 0,
                                                  maxError: rules.maxError, errorLocation: .outside)
            return LineChain(o.points, closed: true)
        default:
            return nil
        }
    }

    /// The pad's hole (PAD::GetEffectiveHoleShape)
    func holeShape(_ p: Pad) -> Shape {
        let half = p.drill.divided(by: 2)
        if !p.oblong { return .segment(Seg(p.pos, p.pos), width: half.x * 2) }
        let hw = min(half.x, half.y)
        let len = KiMath.rotate(IPoint(half.x - hw, half.y - hw), p.orientation)
        return .segment(Seg(p.pos - len, p.pos + len), width: hw * 2)
    }

    private mutating func pad(_ node: SExpr, _ fp: SExpr, _ placement: FootprintPlacement) {
        let p = readPad(node, placement)
        let lmsk = copper(p.layers)
        if lmsk.isEmpty && p.drill.x == 0 { return }
        var layers = LayerRange(0, copperLayers - 1)
        switch p.attribute {
        case .pth, .npth:
            break
        case .smd, .conn:
            guard let front = lmsk.first else { return }
            layers = LayerRange(front, front)
        }
        if node["padstack"] != nil { unsupported.insert("pad padstack") }
        if node.text(at: 2) == "custom" { unsupported.insert("custom pad") }
        if p.removeUnconnected && p.attribute == .pth { unsupported.insert("pad without unconnected layers") }
        if node["property"]?.arguments.contains(where: { $0.text == "pad_prop_castellated" }) == true { unsupported.insert("castellated pad") }

        var w = WorldItem(kind: .pad)
        w.net = netCode(node)
        w.layers = layers
        w.pos = p.pos
        w.offset = p.shapePos - p.pos
        w.npth = p.attribute == .npth
        let pintype = node.value("pintype") ?? ""
        w.freePad = netName(node).hasPrefix("unconnected-(") && pintype == "free"
        w.copper = isOnCopper(p, lmsk)
        w.drilled = p.drill.x > 0 && p.drill.y > 0 && p.drill.x == p.drill.y
        w.npthSlot = p.attribute == .npth && p.drill.x != p.drill.y
        w.flashed = (0..<copperLayers).map { flash(p, lmsk, $0) }
        w.clearanceOverride = clearanceOverride(node, fp)
        w.footprint = placement.reference
        w.source = node.value("uuid")
        if p.drill.x > 0 { w.hole = holeShape(p) }
        let shapes = effectiveShapes(p)
        if p.kind == .custom && !(node["primitives"]?.arguments.isEmpty ?? true) {
            // (KiCad merges a custom pad's anchor and pieces into one outline; until the port can, an outline round
            // them all)
            w.shape = customApproximation(node, p)
            w.approximate = true
        } else if shapes.count == 1 {
            w.shape = shapes[0]
        } else if let poly = effectivePolygon(p) {
            w.shape = .simple(poly)
        } else {
            return
        }
        items.append(w)
    }

    /// A custom pad's anchor and primitives, all in one convex outline: no smaller than KiCad's merged outline
    private func customApproximation(_ node: SExpr, _ p: Pad) -> Shape {
        var pts: [IPoint] = []
        for s in effectiveShapes(Pad(attribute: p.attribute, kind: p.anchorRect ? .rect : .circle, pos: p.pos, orientation: p.orientation,
                                     size: p.size, drill: p.drill, layers: p.layers)) {
            let b = s.bbox
            pts += [IPoint(b.minX, b.minY), IPoint(b.maxX, b.minY), IPoint(b.maxX, b.maxY), IPoint(b.minX, b.maxY)]
        }
        for prim in node["primitives"]?.arguments ?? [] {
            let width = prim["width"].map { Self.iu($0, 0) } ?? prim["stroke"]?["width"].map { Self.iu($0, 0) } ?? 0
            let local = Self.drawingPoints(prim)
            for q in local {
                let c = KiMath.rotate(q, p.orientation) + p.shapePos
                pts += [c + IPoint(-width / 2, -width / 2), c + IPoint(width / 2, width / 2), c + IPoint(-width / 2, width / 2),
                        c + IPoint(width / 2, -width / 2)]
            }
        }
        return .simple(LineChain(Self.convexHull(pts), closed: true))
    }

    /// The points a drawing runs through, its circles' and arcs' by their boxes
    static func drawingPoints(_ node: SExpr) -> [IPoint] {
        switch node.head ?? "" {
        case "gr_line", "fp_line": return [point(node["start"]), point(node["end"])]
        case "gr_rect", "fp_rect":
            let s = point(node["start"]), e = point(node["end"])
            return [s, IPoint(e.x, s.y), e, IPoint(s.x, e.y)]
        case "gr_circle", "fp_circle":
            let c = point(node["center"]), e = point(node["end"])
            let r = Int(c.distance(e).rounded(.up))
            return [c + IPoint(-r, -r), c + IPoint(r, r), c + IPoint(-r, r), c + IPoint(r, -r)]
        case "gr_arc", "fp_arc":
            let a = ShapeArc(start: point(node["start"]), mid: point(node["mid"]), end: point(node["end"]))
            let b = a.bbox()
            return [IPoint(b.minX, b.minY), IPoint(b.maxX, b.maxY), IPoint(b.minX, b.maxY), IPoint(b.maxX, b.minY)]
        default:
            return (node["pts"]?.arguments ?? []).filter { $0.head == "xy" }.map(point)
        }
    }

    /// The convex hull of points, counter-clockwise (Andrew's monotone chain)
    static func convexHull(_ points: [IPoint]) -> [IPoint] {
        let p = Array(Set(points)).sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count > 2 else { return p }
        func cross(_ o: IPoint, _ a: IPoint, _ b: IPoint) -> Int { (a - o).cross(b - o) }
        var lower: [IPoint] = [], upper: [IPoint] = []
        for q in p {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// PAD::IsOnCopperLayer: on a copper layer, unless an unplated hole without a ring round it
    private func isOnCopper(_ p: Pad, _ lmsk: [Int]) -> Bool {
        if p.attribute == .npth {
            switch p.kind {
            case .circle where p.offset == .zero && p.size.x <= p.drill.x: return false
            case .oval where p.offset == .zero && p.size.x <= p.drill.x && p.size.y <= p.drill.y: return false
            default: break
            }
        }
        return !lmsk.isEmpty || p.layers.contains { $0 == "*.Cu" || $0 == "F&B.Cu" || $0.hasSuffix(".Cu") }
    }

    /// PAD::FlashLayer on a copper layer (a through-hole pad keeping all its layers, as boards mostly do)
    private func flash(_ p: Pad, _ lmsk: [Int], _ layer: Int) -> Bool {
        guard lmsk.contains(layer) else { return false }
        if p.attribute == .npth {
            if p.kind == .circle && !p.oblong && p.offset == .zero && p.drill.x >= p.size.x { return false }
            if p.kind == .oval && p.oblong && p.offset == .zero && p.drill.x >= p.size.x && p.drill.y >= p.size.y { return false }
        }
        return true
    }

    // MARK: - Drawings (syncGraphicalItem)

    /// A drawing as KiCad holds it once read (EDA_SHAPE): its corners, or its arc's centre and ends
    struct Drawing {
        enum Kind { case segment, rect, arc, circle, poly, bezier }
        var kind: Kind
        var start = IPoint.zero
        var end = IPoint.zero
        var center = IPoint.zero
        var poly: [IPoint] = []
        var width = 0
        var filled = false
        var polyHasArcs = false

        /// The arc's angle from its start round to its end (EDA_SHAPE::GetArcAngle)
        var arcAngle: EDAAngle {
            let s = EDAAngle(DPoint(start - center))
            var e = EDAAngle(DPoint(end - center))
            if e == s { e = s + .a360 }
            while e < s { e += .a360 }
            return e - s
        }

        /// A circle's radius (EDA_SHAPE::GetRadius)
        var radius: Int {
            var r = start.distance(end)
            if r > Double(Int32.max) / 2 { r = Double(Int32.max) / 2 }
            return max(1, KiMath.round(r))
        }
    }

    /// A drawing read, and placed on the board if it is a footprint's (parsePCB_SHAPE, EDA_SHAPE::rotate and move)
    func readDrawing(_ node: SExpr, placement: FootprintPlacement?) -> Drawing? {
        let head = node.head ?? ""
        var d: Drawing
        switch head.dropFirst(3) {
        case "line":
            d = Drawing(kind: .segment, start: Self.point(node["start"]), end: Self.point(node["end"]))
        case "rect":
            d = Drawing(kind: .rect, start: Self.point(node["start"]), end: Self.point(node["end"]))
            if (node["radius"]?.number(at: 0) ?? 0) > 0 { return nil }
            if placement == nil {
                // (KiCad normalizes a board's rectangle as it reads it, a footprint's not)
                let (s, e) = (d.start, d.end)
                d.start = IPoint(min(s.x, e.x), min(s.y, e.y))
                d.end = IPoint(max(s.x, e.x), max(s.y, e.y))
            }
        case "circle":
            d = Drawing(kind: .circle, start: Self.point(node["center"]), end: Self.point(node["end"]))
        case "arc":
            // SetArcGeometry: the centre through the three points, the ends swapped if they run the other way
            let s = Self.point(node["start"]), m = Self.point(node["mid"]), e = Self.point(node["end"])
            d = Drawing(kind: .arc, start: s, end: e, center: KiMath.arcCenter(s, m, e))
            let newMid = KiMath.rotate(d.start, around: d.center, -d.arcAngle / 2.0)
            let dist = DPoint(newMid - m), dist2 = DPoint(newMid - d.center)
            if dist.squaredNorm > dist2.squaredNorm { swap(&d.start, &d.end) }
        case "poly":
            let pts = node["pts"]?.arguments ?? []
            d = Drawing(kind: .poly, poly: pts.filter { $0.head == "xy" }.map(Self.point))
            d.polyHasArcs = pts.contains { $0.head == "arc" }
        case "curve":
            d = Drawing(kind: .bezier)
        default:
            return nil
        }
        d.width = node["stroke"]?["width"].map { Self.iu($0, 0) } ?? node["width"].map { Self.iu($0, 0) } ?? 0
        let fill = node["fill"]
        let fillValue = fill?.text(at: 0) ?? fill?["type"]?.text(at: 0)
        d.filled = fillValue == "yes" || fillValue == "solid" || fillValue == "hatch" || fillValue == "reverse_hatch"
            || fillValue == "cross_hatch"
        if let placement {
            let a = placement.orientation
            switch d.kind {
            case .segment, .circle:
                d.start = KiMath.rotate(d.start, a)
                d.end = KiMath.rotate(d.end, a)
            case .arc:
                d.start = KiMath.rotate(d.start, a)
                d.end = KiMath.rotate(d.end, a)
                d.center = KiMath.rotate(d.center, a)
            case .rect:
                if a.normalized.degrees.truncatingRemainder(dividingBy: 90) == 0 {
                    d.start = KiMath.rotate(d.start, a)
                    d.end = KiMath.rotate(d.end, a)
                } else {
                    // (KiCad makes a rectangle turned off square a polygon)
                    d.kind = .poly
                    d.poly = [d.start, IPoint(d.end.x, d.start.y), d.end, IPoint(d.start.x, d.end.y)].map { KiMath.rotate($0, a) }
                }
            case .poly:
                d.poly = d.poly.map { KiMath.rotate($0, a) }
            case .bezier:
                break
            }
            d.start += placement.position
            d.end += placement.position
            d.center += placement.position
            d.poly = d.poly.map { $0 + placement.position }
        }
        return d
    }

    /// A drawing's effective shapes (EDA_SHAPE::makeEffectiveShapes)
    func effectiveShapes(_ d: Drawing) -> [Shape]? {
        let w = d.width
        switch d.kind {
        case .arc:
            return [.arc(ShapeArc(center: d.center, start: d.start, angle: d.arcAngle, width: w))]
        case .segment:
            return [.segment(Seg(d.start, d.end), width: w)]
        case .rect:
            let pts = [d.start, IPoint(d.end.x, d.start.y), d.end, IPoint(d.start.x, d.end.y)]
            var out: [Shape] = []
            if d.filled { out.append(.simple(LineChain(pts, closed: true))) }
            if w > 0 || !d.filled { for i in 0..<4 { out.append(.segment(Seg(pts[i], pts[(i + 1) % 4]), width: w)) } }
            return out
        case .circle:
            var out: [Shape] = []
            if d.filled { out.append(.circle(center: d.start, radius: d.radius)) }
            if w > 0 || !d.filled { out.append(.arc(ShapeArc(center: d.start, start: d.end, angle: .a360, width: w))) }
            return out
        case .poly:
            if d.polyHasArcs || d.poly.isEmpty { return nil }
            let l = LineChain(d.poly, closed: true)
            var out: [Shape] = []
            if d.filled { out.append(.simple(l)) }
            if w > 0 || !d.filled { for i in 0..<l.segmentCount { out.append(.segment(l.segment(i), width: w)) } }
            return out
        case .bezier:
            return nil
        }
    }

    private mutating func graphic(_ node: SExpr, placement: FootprintPlacement?) {
        guard let layerName = node.value("layer") else { return }
        let edge = layerName == "Edge.Cuts" || layerName == "Margin"
        let cu = layerIndex[layerName]
        guard edge || cu != nil else { return }
        guard let d = readDrawing(node, placement: placement), let shapes = effectiveShapes(d) else {
            unsupported.insert(edge ? "edge drawing" : "copper drawing")
            return
        }
        for var s in shapes {
            if layerName == "Edge.Cuts" {
                switch s {
                case .segment(let g, _): s = .segment(g, width: 0)
                case .arc(var a):
                    a.width = 0
                    s = .arc(a)
                default: break
                }
            }
            var w = WorldItem(kind: edge ? .edge : .graphic)
            w.shape = s
            w.net = netCode(node)
            w.layers = edge ? LayerRange(0, copperLayers - 1) : LayerRange(cu!, cu!)
            w.copper = !edge
            w.compound = shapes.count > 1
            w.source = node.value("uuid")
            items.append(w)
        }
    }

    // MARK: - Zones (syncZone)

    private mutating func zone(_ node: SExpr, footprint: SExpr?) {
        guard let k = node["keepout"] else { return }
        func notAllowed(_ name: String) -> Bool { k[name]?.text(at: 0) == "not_allowed" }
        let keepout = WorldItem.Keepout(tracks: notAllowed("tracks"), vias: notAllowed("vias"), pads: notAllowed("pads"),
                                        footprints: notAllowed("footprints"),
                                        footprint: footprint.map { FootprintPlacement($0).reference })
        guard keepout.tracks || keepout.vias || keepout.pads || keepout.footprints || notAllowed("copperpour") else { return }
        var w = WorldItem(kind: .keepout)
        w.net = nil
        w.keepout = keepout
        let ls = copper(layerNames(node))
        guard let lo = ls.first, let hi = ls.last else { return }
        w.layers = LayerRange(lo, hi)
        w.polygons = node.all("polygon").map { poly in
            [LineChain((poly["pts"]?.arguments ?? []).filter { $0.head == "xy" }.map(Self.point), closed: true)]
        }
        w.source = node.value("uuid")
        unsupported.insert("keepout zone")
        items.append(w)
    }

    // MARK: - Tracks and vias (syncTrack, syncVia)

    private mutating func track(_ node: SExpr) {
        guard let layer = node.value("layer").flatMap({ layerIndex[$0] }) else { return }
        var w = WorldItem(kind: .track)
        w.net = netCode(node)
        w.a = Self.point(node["start"])
        w.b = Self.point(node["end"])
        w.width = node["width"].map { Self.iu($0, 0) } ?? 0
        w.layer = layer
        w.locked = node.flag("locked") || node["locked"]?.text(at: 0) == "yes"
        w.source = node.value("uuid")
        items.append(w)
    }

    private mutating func arcTrack(_ node: SExpr) {
        guard let layer = node.value("layer").flatMap({ layerIndex[$0] }) else { return }
        var w = WorldItem(kind: .arc)
        w.net = netCode(node)
        w.a = Self.point(node["start"])
        w.mid = Self.point(node["mid"])
        w.b = Self.point(node["end"])
        w.width = node["width"].map { Self.iu($0, 0) } ?? 0
        w.layer = layer
        w.locked = node.flag("locked") || node["locked"]?.text(at: 0) == "yes"
        w.source = node.value("uuid")
        unsupported.insert("arc track")
        items.append(w)
    }

    private mutating func via(_ node: SExpr) {
        let names = node["layers"]?.arguments.map(\.text) ?? ["F.Cu", "B.Cu"]
        let ls = names.compactMap { layerIndex[$0] }
        guard let lo = ls.min(), let hi = ls.max() else { return }
        var w = WorldItem(kind: .via)
        w.net = netCode(node)
        w.a = Self.point(node["at"])
        w.layers = LayerRange(lo, hi)
        w.diameter = node["size"].map { Self.iu($0, 0) } ?? 0
        w.drill = node["drill"].map { Self.iu($0, 0) } ?? 0
        w.free = node["free"]?.text(at: 0) == "yes" || node.flag("free")
        w.locked = node.flag("locked") || node["locked"]?.text(at: 0) == "yes"
        w.flashed = (0..<copperLayers).map { $0 >= lo && $0 <= hi }
        w.source = node.value("uuid")
        if node.arguments.contains(where: { $0.kind == .symbol && ($0.text == "blind" || $0.text == "micro" || $0.text == "buried") }) {
            unsupported.insert("blind or micro via")
        }
        if node["remove_unused_layers"].map({ $0.text(at: 0) != "no" }) == true { unsupported.insert("via without unconnected layers") }
        if node["padstack"] != nil { unsupported.insert("via padstack") }
        items.append(w)
    }
}

/// A project's net classes (its .kicad_pro's net_settings), and how KiCad resolves a net's (NET_SETTINGS::
/// GetEffectiveNetClass): the classes assigned to it or whose pattern it matches, the most important first (the
/// lowest priority number, then the name), each value from the first that has one, the default class's after
struct NetClasses {
    struct NetClass {
        var name: String
        var priority: Int
        var clearance: Int?
        var trackWidth: Int?
        var viaDiameter: Int?
        var viaDrill: Int?
    }

    /// A net's net class values, each from the most important class that has it, else the default class's
    struct Effective {
        var name: String
        var clearance: Int?
        var trackWidth: Int?
        var viaDiameter: Int?
        var viaDrill: Int?
    }

    var classes: [String: NetClass] = [:]
    var defaultClass = NetClass(name: "Default", priority: Int.max, clearance: 200_000, trackWidth: 200_000, viaDiameter: 600_000,
                                viaDrill: 300_000)
    var assignments: [String: [String]] = [:]
    var patterns: [(pattern: String, netClass: String)] = []

    init(project: [String: Any]?) {
        let ns = project?["net_settings"] as? [String: Any] ?? [:]
        for c in ns["classes"] as? [[String: Any]] ?? [] {
            guard let name = c["name"] as? String else { continue }
            func mm(_ key: String) -> Int? { (c[key] as? NSNumber).map { BoardWorld.iuMM($0.doubleValue) } }
            let nc = NetClass(name: name, priority: (c["priority"] as? NSNumber)?.intValue ?? Int.max, clearance: mm("clearance"),
                              trackWidth: mm("track_width"), viaDiameter: mm("via_diameter"), viaDrill: mm("via_drill"))
            if name == "Default" {
                defaultClass = NetClass(name: name, priority: Int.max, clearance: nc.clearance ?? 200_000,
                                        trackWidth: nc.trackWidth ?? 200_000, viaDiameter: nc.viaDiameter ?? 600_000,
                                        viaDrill: nc.viaDrill ?? 300_000)
            } else {
                classes[name] = nc
            }
        }
        for (net, value) in ns["netclass_assignments"] as? [String: Any] ?? [:] {
            if let list = value as? [String] { assignments[net] = list } else if let one = value as? String { assignments[net] = [one] }
        }
        for p in ns["netclass_patterns"] as? [[String: Any]] ?? [] {
            if let pattern = p["pattern"] as? String, let nc = p["netclass"] as? String { patterns.append((pattern, nc)) }
        }
    }

    /// A net's effective net class (NET_SETTINGS::GetEffectiveNetClass)
    func effective(_ net: String) -> Effective {
        let d = defaultClass
        func whole(_ c: NetClass) -> Effective {
            Effective(name: c.name, clearance: c.clearance ?? d.clearance, trackWidth: c.trackWidth ?? d.trackWidth,
                      viaDiameter: c.viaDiameter ?? d.viaDiameter, viaDrill: c.viaDrill ?? d.viaDrill)
        }
        if net.isEmpty { return whole(d) }
        var resolved: [NetClass] = []
        func add(_ name: String) {
            if name == "Default" {
                if !resolved.contains(where: { $0.name == "Default" }) { resolved.append(defaultClass) }
            } else if let c = classes[name] {
                if !resolved.contains(where: { $0.name == name }) { resolved.append(c) }
            } else if !resolved.contains(where: { $0.name == name }) {
                // (a class named on a net but not set up: no values of its own)
                resolved.append(NetClass(name: name, priority: Int.max - 1, clearance: nil, trackWidth: nil, viaDiameter: nil, viaDrill: nil))
            }
        }
        for name in assignments[net] ?? [] { add(name) }
        for (pattern, name) in patterns where Self.matches(pattern, net) { add(name) }
        if resolved.isEmpty { return whole(d) }
        resolved.sort { $0.priority != $1.priority ? $0.priority < $1.priority : $0.name < $1.name }
        func first(_ k: KeyPath<NetClass, Int?>) -> Int? { resolved.first(where: { $0[keyPath: k] != nil })?[keyPath: k] ?? d[keyPath: k] }
        return Effective(name: resolved.count == 1 ? resolved[0].name : resolved.map(\.name).joined(separator: ","),
                         clearance: first(\.clearance), trackWidth: first(\.trackWidth), viaDiameter: first(\.viaDiameter),
                         viaDrill: first(\.viaDrill))
    }

    /// The worst of the classes' clearances
    var worstClearance: Int { (classes.values.compactMap(\.clearance) + [defaultClass.clearance ?? 0]).max() ?? 0 }

    /// A net class pattern against a net name: a regular expression or a wildcard pattern, either matching it from
    /// its start (EDA_COMBINED_MATCHER::StartsWith with KiCad's anchored matchers)
    static func matches(_ pattern: String, _ name: String) -> Bool {
        if let re = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$"),
           re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
            return true
        }
        var wildcard = "^"
        for ch in pattern {
            switch ch {
            case "*": wildcard += ".*"
            case "?": wildcard += "."
            default: wildcard += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        wildcard += "$"
        guard let re = try? NSRegularExpression(pattern: wildcard) else { return false }
        return re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }
}

extension BoardWorld {
    /// A project file's net class millimetres as KiCad reads them (mmToIU: rounded half away from zero)
    static func iuMM(_ mm: Double) -> Int { Int(mm < 0 ? mm * 1_000_000 - 0.5 : mm * 1_000_000 + 0.5) }
}
