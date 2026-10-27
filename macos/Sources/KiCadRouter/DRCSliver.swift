// Ported from KiCad 10.0.7: pcbnew/drc/drc_test_provider_sliver_checker.cpp (copper slivers: each copper layer's
// copper made one polygon set, and the narrow points of its outlines), with pcbnew/drc/drc_test_provider.cpp
// (forEachGeometryItem: the order the board's items are taken in), common/eda_shape.cpp
// (EDA_SHAPE::TransformShapeToPolygon), pcbnew/pcb_track.cpp (PCB_TRACK::TransformShapeToPolygon) and
// pcbnew/pcb_text.cpp (PCB_TEXT::TransformShapeToPolygon and buildBoundingHull: a text on copper by its box).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardDRC {
    /// A drawing's fill as KiCad reads it (a rectangle or circle of no width with no fill clause filled, a polygon off
    /// Edge.Cuts too), a hatched fill as solid (TransformShapeToPolygon without its fill's hatching)
    static func solidFill(_ node: SExpr) -> Bool {
        let kind = String((node.head ?? "").dropFirst(3))
        if let fill = node["fill"] {
            let v = fill.text(at: 0) ?? fill["type"]?.text(at: 0)
            return v == "yes" || v == "solid" || v == "hatch" || v == "reverse_hatch" || v == "cross_hatch"
        }
        let width = node["stroke"]?["width"].map { BoardWorld.iu($0, 0) } ?? node["width"].map { BoardWorld.iu($0, 0) } ?? 0
        return (width == 0 && (kind == "rect" || kind == "circle")) || (kind == "poly" && node.value("layer") != "Edge.Cuts")
    }

    /// EDA_SHAPE::TransformShapeToPolygon of a drawing (placed on the board if it is a footprint's), no clearance;
    /// nil for one the port does not make (an outlined rectangle with round corners, an arc in the oldest format)
    func drawingPolygon(_ node: SExpr, placement: BoardWorld.FootprintPlacement?, maxError: Int,
                        errorLocation: ErrorLocation) -> PolySet? {
        guard let o = world.outlineShape(node, placement: placement) else { return nil }
        let solid = Self.solidFill(node)
        let width = o.width
        var out = PolySet()
        func oval(_ a: IPoint, _ b: IPoint) {
            out.append(PadPolygon.oval(start: a, end: b, width: width, maxError: maxError, errorLocation: errorLocation))
        }
        switch o.kind {
        case .circle:
            if solid {
                out.addOutline(PadPolygon.circle(center: o.start, radius: o.radius + width / 2, maxError: maxError,
                                                 errorLocation: errorLocation))
            } else {
                out.append(PadPolygon.ring(center: o.start, radius: o.radius, width: width, maxError: maxError,
                                           errorLocation: errorLocation))
            }
        case .rect:
            if o.cornerRadius > 0 {
                guard solid else { return nil }
                let size = IPoint(abs(o.end.x - o.start.x), abs(o.end.y - o.start.y))
                let box = IBox(o.start, o.end)
                let center = IPoint(box.minX + (box.maxX - box.minX) / 2, box.minY + (box.maxY - box.minY) / 2)
                out.addOutline(PadPolygon.roundChamferedRect(position: center, size: size, rotation: .zero, cornerRadius: o.cornerRadius,
                                                             chamferRatio: 0, chamferCorners: 0, inflate: width / 2, maxError: maxError,
                                                             errorLocation: errorLocation))
            } else {
                // (GetRectCorners)
                let pts = [o.start, IPoint(o.end.x, o.start.y), o.end, IPoint(o.start.x, o.end.y)]
                if solid {
                    out.newOutline()
                    for p in pts { out.append(p) }
                }
                if width > 0 || !solid {
                    for i in 0..<4 { oval(pts[i], pts[(i + 1) % 4]) }
                }
            }
        case .arc:
            out.append(PadPolygon.arc(start: o.start, mid: o.mid, end: o.end, width: width, maxError: maxError,
                                      errorLocation: errorLocation))
        case .segment:
            oval(o.start, o.end)
        case .poly:
            // (IsPolyShapeValid)
            guard o.points.count > 2 else { return out }
            if solid {
                var tmp = PolySet()
                tmp.newOutline()
                for p in o.points { tmp.append(p) }
                if width > 0 {
                    tmp.inflate(width / 2 + (errorLocation == .outside ? maxError : 0), .roundAllCorners, maxError: maxError)
                }
                out.append(tmp)
            } else {
                let chain = LineChain(o.points, closed: true)
                for i in 0..<chain.segmentCount {
                    let s = chain.segment(i)
                    oval(s.a, s.b)
                }
            }
        case .bezier:
            let pts = Outlines.bezierPoints(o.start, o.control1, o.control2, o.end, maxError: maxError)
            for i in pts.indices.dropFirst() { oval(pts[i - 1], pts[i]) }
        }
        return out
    }

    /// PCB_TEXT::TransformShapeToPolygon: a text on copper as the box round its strokes' polygons, turned with it;
    /// nil for one the port does not make
    static func textHull(_ node: SExpr, footprint: SExpr?, maxError: Int, errorLocation: ErrorLocation) -> PolySet? {
        guard let t = BoardWorld.textStrokes(node, footprint: footprint) else { return nil }
        var rendered = PolySet()
        for s in t.segments {
            rendered.append(PadPolygon.oval(start: s.a, end: s.b, width: t.width, maxError: maxError, errorLocation: errorLocation))
        }
        guard !rendered.polygons.isEmpty else { return PolySet() }
        rendered.rotate(-t.rotation, around: t.position)
        guard var box = rendered.polygons.first.map({ $0[0].bbox }) else { return PolySet() }
        for p in rendered.polygons.dropFirst() { box.merge(p[0].bbox) }
        let corners = [IPoint(box.minX, box.minY), IPoint(box.maxX, box.minY), IPoint(box.maxX, box.maxY), IPoint(box.minX, box.maxY)]
        var out = PolySet()
        out.newOutline()
        for c in corners { out.append(KiMath.rotate(c, around: t.position, t.rotation)) }
        return out
    }

    /// A copper layer's copper as the sliver check makes it (ARC_LOW_DEF, the error inside), in forEachGeometryItem's
    /// order: tracks, the board's drawings and texts, its zones, then each footprint's fields, pads, drawings and texts
    /// and zones; united; nil where something on it is one the port cannot make
    func copperLayerPolygons(_ c: Copper, _ l: Int) -> PolySet? {
        let arcLowDef = 20000
        let fps = board.root.all("footprint")
        let drawingHeads: Set<String> = ["gr_line", "gr_rect", "gr_arc", "gr_circle", "gr_poly", "gr_curve"]
        let fpDrawingHeads: Set<String> = ["fp_line", "fp_rect", "fp_arc", "fp_circle", "fp_poly", "fp_curve"]
        var poly = PolySet()
        func onLayer(_ node: SExpr) -> Bool { node.value("layer").flatMap { world.layerIndex[$0] } == l }
        for t in c.tracks where t.layers.contains(l) {
            switch t.kind {
            case .via:
                let v = t.via!
                poly.addOutline(PadPolygon.circle(center: v.start, radius: v.diameter / 2, maxError: arcLowDef, errorLocation: .inside))
            case .arc:
                poly.append(PadPolygon.arc(start: t.trackStart, mid: t.trackMid, end: t.trackEnd, width: t.trackWidth,
                                           maxError: arcLowDef, errorLocation: .inside))
            default:
                poly.append(PadPolygon.oval(start: t.trackStart, end: t.trackEnd, width: t.trackWidth, maxError: arcLowDef,
                                            errorLocation: .inside))
            }
        }
        for node in board.root.items {
            let head = node.head ?? ""
            if drawingHeads.contains(head) {
                guard onLayer(node) else { continue }
                guard let p = drawingPolygon(node, placement: nil, maxError: arcLowDef, errorLocation: .inside) else { return nil }
                poly.append(p)
            } else if head == "gr_text" {
                guard onLayer(node) else { continue }
                guard let p = Self.textHull(node, footprint: nil, maxError: arcLowDef, errorLocation: .inside) else { return nil }
                poly.append(p)
            } else if ["gr_text_box", "dimension", "target", "table", "barcode"].contains(head) {
                if onLayer(node) || (node["layers"]?.arguments.contains { world.layerIndex[$0.text] == l } ?? false) { return nil }
            }
        }
        for z in c.zones where z.footprint == nil {
            for chain in z.fills[l] ?? [] { poly.addOutline(chain) }
        }
        for (f, fp) in fps.enumerated() {
            let placement = BoardWorld.FootprintPlacement(fp)
            for node in fp.items where node.head == "property" || (node.head == "fp_text" && node.text(at: 0) != "user") {
                guard onLayer(node) else { continue }
                guard let p = Self.textHull(node, footprint: fp, maxError: arcLowDef, errorLocation: .inside) else { return nil }
                poly.append(p)
            }
            for pad in c.footprintPads[f] {
                guard let p = pad.pad, p.hasHole || pad.layers.contains(l) else { continue }
                guard let shape = world.padPolygon(p.pad, primitives: p.primitives, errorLocation: .inside, arcError: arcLowDef) else {
                    return nil
                }
                poly.append(shape)
            }
            for node in fp.items {
                let head = node.head ?? ""
                if fpDrawingHeads.contains(head) {
                    guard onLayer(node) else { continue }
                    guard let p = drawingPolygon(node, placement: placement, maxError: arcLowDef, errorLocation: .inside) else {
                        return nil
                    }
                    poly.append(p)
                } else if head == "fp_text" && node.text(at: 0) == "user" {
                    guard onLayer(node) else { continue }
                    guard let p = Self.textHull(node, footprint: fp, maxError: arcLowDef, errorLocation: .inside) else { return nil }
                    poly.append(p)
                } else if ["fp_text_box", "dimension"].contains(head) && onLayer(node) {
                    return nil
                }
            }
            for z in c.zones where z.footprint == f {
                for chain in z.fills[l] ?? [] { poly.addOutline(chain) }
            }
        }
        poly.simplify()
        return poly
    }

    // MARK: - The check (DRC_TEST_PROVIDER_SLIVER_CHECKER)

    func checkSlivers(_ out: inout Report, _ c: Copper) {
        guard !out.exceeded("copper_sliver") else { return }
        // (ADVANCED_CFG's sliver tolerances: 0.08 mm wide, 20 degrees, points nearer than 0.8 µm taken as one)
        let widthTolerance = 80_000, squaredWidth = Double(widthTolerance) * Double(widthTolerance)
        let cosAngleTol = 2.0 * cos(20.0 * .pi / 180.0)
        let minLen = 800
        for l in kicadLayerOrder.filter({ $0 < world.copperLayers }) {
            guard !out.exceeded("copper_sliver") else { continue }
            guard let poly = copperLayerPolygons(c, l) else { continue }
            let detail = "(\(boardLayerName(l)))"
            for p in poly.polygons {
                let pts = p[0].points
                let n = pts.count
                guard n > 5 else { continue }
                func area(_ p: IPoint, _ q: IPoint, _ r: IPoint) -> Int { (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y) }
                func isLocallyInside(_ a: Int, _ b: Int) -> Bool {
                    let prev = (n + a - 1) % n, next = (a + 1) % n
                    if area(pts[prev], pts[a], pts[next]) < 0 {
                        return area(pts[a], pts[b], pts[next]) >= 0 && area(pts[a], pts[prev], pts[b]) >= 0
                    }
                    return area(pts[a], pts[b], pts[prev]) < 0 || area(pts[a], pts[next], pts[b]) < 0
                }
                var kk = 0, offset = 0
                while kk < n {
                    let priorIndex = (n + kk - 1) % n
                    var nextIndex = (kk + 1) % n
                    var pt = pts[kk]
                    let ptPrior = pts[priorIndex]
                    var vPrior = ptPrior - pt
                    var forwardOffset = 1
                    offset = 1
                    while abs(vPrior.x) < minLen && abs(vPrior.y) < minLen && offset < n {
                        pt = pts[(kk + offset) % n]
                        offset += 1
                        vPrior = ptPrior - pt
                    }
                    if offset >= n { break }
                    var ptAfter = pts[nextIndex]
                    var vAfter = ptAfter - pt
                    while abs(vAfter.x) < minLen && abs(vAfter.y) < minLen && forwardOffset < n {
                        nextIndex = (kk + forwardOffset) % n
                        forwardOffset += 1
                        ptAfter = pts[nextIndex]
                        vAfter = ptAfter - pt
                    }
                    defer { kk += offset }
                    if offset >= n { break }
                    // (an angle over 90 degrees)
                    if vPrior.x * vAfter.x + vPrior.y * vAfter.y <= 0 { continue }
                    if !isLocallyInside(priorIndex, nextIndex) { continue }
                    let vIncluded = ptAfter - ptPrior
                    let arm1 = Double(vPrior.squaredNorm), arm2 = Double(vAfter.squaredNorm), opp = Double(vIncluded.squaredNorm)
                    let cosAng = abs((opp - arm1 - arm2) / (arm1.squareRoot() * arm2.squareRoot()))
                    if cosAng > cosAngleTol && 2.0 - cosAng > Double(Float.ulpOfOne) && opp > squaredWidth {
                        guard !out.exceeded("copper_sliver") else { break }
                        out.add("copper_sliver", detail, [])
                    }
                }
            }
        }
    }
}
