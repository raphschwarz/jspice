// Ported from KiCad 10.0.7: pcbnew/footprint.cpp (FOOTPRINT::BuildCourtyardCaches: a footprint's courtyards made of
// its drawings on F.CrtYd and B.CrtYd, and whether either is malformed), pcbnew/pcb_io/kicad_sexpr/
// pcb_io_kicad_sexpr_parser.cpp (parsePCB_SHAPE: a drawing's line width where it has none, and the drawing placed
// with its footprint) and common/eda_shape.cpp (rotate and move as they leave a drawing's ends, an arc's middle,
// a rectangle turned off square made a polygon).
// Copyright (C) 2015 Jean-Pierre Charras; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// A footprint's courtyards as KiCad's FOOTPRINT::BuildCourtyardCaches makes them: the outlines of its drawings on
/// F.CrtYd and B.CrtYd, shrunk by the 5 µm their curves may be off (touching courtyards are allowed), and cut into
/// triangles
public struct Courtyards: Sendable {
    public var front = PolySet()
    public var back = PolySet()
    /// The width KiCad gives a courtyard's first outline: the line width most of its drawings have (0.05 mm if
    /// that is none), 0 where it has no outline (a malformed courtyard's, the width of the first drawing of its
    /// first outline, unless Clipper2 made the outlines again)
    public var frontWidth = 0
    public var backWidth = 0
    /// MALFORMED_F_COURTYARD, MALFORMED_B_COURTYARD: its drawings do not close, or cross each other (what was made of
    /// them is kept then, not shrunk)
    public var malformedFront = false
    public var malformedBack = false

    public init() {}

    /// The courtyard on the back or the front (FOOTPRINT::GetCachedCourtyard)
    public func courtyard(back: Bool) -> PolySet { back ? self.back : front }
}

extension BoardWorld {
    /// The drawing kinds a footprint holds as PCB_SHAPEs
    static let footprintShapeHeads: Set<String> = ["fp_line", "fp_rect", "fp_circle", "fp_arc", "fp_poly", "fp_curve"]

    /// A drawing's line width as KiCad reads it (its stroke's): one with none, and not filled, gets 0.1 mm
    /// (DEFAULT_LINE_WIDTH), and a rectangle or circle of none with no fill clause is filled, as is a polygon off
    /// Edge.Cuts
    static func strokeWidth(_ node: SExpr) -> Int {
        var width = node["stroke"]?["width"].map { iu($0, 0) } ?? node["width"].map { iu($0, 0) } ?? 0
        let kind = String((node.head ?? "").dropFirst(3))
        var filled: Bool
        if let fill = node["fill"] {
            let v = fill.text(at: 0) ?? fill["type"]?.text(at: 0)
            filled = v == "yes" || v == "solid" || v == "hatch" || v == "reverse_hatch" || v == "cross_hatch"
        } else {
            filled = (width == 0 && (kind == "rect" || kind == "circle")) || (kind == "poly" && node.value("layer") != "Edge.Cuts")
        }
        if width <= 0 && !filled { width = iu(0.1) }
        return width
    }

    /// A drawing as ConvertOutlineToPolygon takes it (a PCB_SHAPE as KiCad has it once read), placed on the board if
    /// it is a footprint's; nil for one the port does not read (an arc in the oldest format)
    func outlineShape(_ node: SExpr, placement: FootprintPlacement?) -> OutlineShape? {
        let head = node.head ?? ""
        let place: (IPoint) -> IPoint = { p in placement?.apply(p) ?? p }
        let width = max(Self.strokeWidth(node), 0)
        if head.dropFirst(3) == "rect", let placement, placement.orientation.normalized.degrees.truncatingRemainder(dividingBy: 90) != 0 {
            // a rectangle turned off square made a polygon (EDA_SHAPE::rotate: a ROUNDRECT's outline turned), its
            // start and end left as they were in its footprint
            let s0 = Self.point(node["start"]), e0 = Self.point(node["end"])
            let r = node["radius"].map { max(0, min(Self.iu($0, 0), min(abs(e0.x - s0.x), abs(e0.y - s0.y)) / 2)) } ?? 0
            var o = OutlineShape(kind: .poly)
            o.start = s0
            o.end = e0
            o.points = Self.roundRect(start: s0, width: e0.x - s0.x, height: e0.y - s0.y, radius: r,
                                      maxError: rules.maxError / 5).points.map(place)
            o.width = width
            return o
        }
        if head.dropFirst(3) == "curve" {
            let pts = (node["pts"]?.arguments ?? []).filter { $0.head == "xy" }.map(Self.point)
            guard pts.count == 4 else { return nil }
            var o = OutlineShape(kind: .bezier)
            (o.start, o.control1, o.control2, o.end) = (place(pts[0]), place(pts[1]), place(pts[2]), place(pts[3]))
            o.width = width
            return o
        }
        guard let d = readDrawing(node, placement: placement) else { return nil }
        var o: OutlineShape
        switch d.kind {
        case .segment:
            o = OutlineShape(kind: .segment)
            (o.start, o.end) = (d.start, d.end)
        case .arc:
            guard node["mid"] != nil else { return nil }
            o = OutlineShape(kind: .arc)
            (o.start, o.end, o.center) = (d.start, d.end, d.center)
            // (GetArcMid: the middle it was read with, turned and moved with it, unless SetArcGeometry swapped its
            // ends, when the middle is worked out)
            let s = Self.point(node["start"]), m = Self.point(node["mid"]), e = Self.point(node["end"])
            if Self.arcDrawing(s, m, e).start == s {
                o.mid = place(m)
            } else {
                o.mid = KiMath.rotate(d.start, around: d.center, -d.arcAngle / 2.0)
            }
        case .circle:
            o = OutlineShape(kind: .circle)
            (o.start, o.end) = (d.start, d.end)
            o.radius = d.radius
        case .rect:
            o = OutlineShape(kind: .rect)
            (o.start, o.end) = (d.start, d.end)
            o.cornerRadius = d.cornerRadius
            o.maxError = rules.maxError
        case .poly:
            // (its start and end never set: the origin)
            o = OutlineShape(kind: .poly)
            o.points = d.poly
        case .bezier:
            return nil
        }
        o.width = width
        return o
    }

    /// FOOTPRINT::BuildCourtyardCaches of a footprint (its node in the board): its drawings on F.CrtYd and on
    /// B.CrtYd, in the order it holds them, each side's made polygons (ConvertOutlineToPolygon, curves 5 µm from
    /// true at most, ends 20 µm apart chained), shrunk by 5 µm (Inflate, chamfering acute corners) and cut into
    /// triangles (CacheTriangulation( false )), or marked malformed
    public func courtyards(_ footprint: SExpr) -> Courtyards {
        var out = Courtyards()
        let placement = FootprintPlacement(footprint)
        var listFront: [OutlineShape] = [], listBack: [OutlineShape] = []
        var frontHistogram: [Int: Int] = [:], backHistogram: [Int: Int] = [:]
        for node in footprint.items where Self.footprintShapeHeads.contains(node.head ?? "") {
            let layer = node.value("layer")
            guard layer == "F.CrtYd" || layer == "B.CrtYd", let s = outlineShape(node, placement: placement) else { continue }
            if layer == "B.CrtYd" {
                listBack.append(s)
                backHistogram[Self.strokeWidth(node), default: 0] += 1
            } else {
                listFront.append(s)
                frontHistogram[Self.strokeWidth(node), default: 0] += 1
            }
        }
        if listFront.isEmpty && listBack.isEmpty { return out }
        let maxError = Self.iuMM(0.005), chainingEpsilon = Self.iuMM(0.02)
        func build(_ list: [OutlineShape], _ histogram: [Int: Int], _ polygons: inout PolySet, _ width: inout Int) -> Bool {
            // (a malformed courtyard's first outline keeps its first shape's width)
            guard Outlines.convertOutlineToPolygon(list, &polygons, maxError: maxError, chainingEpsilon: chainingEpsilon,
                                                   allowDisjoint: true, errorHandler: nil, firstOutlineWidth: &width) else {
                return false
            }
            polygons.inflate(-maxError, .chamferAcuteCorners, maxError: maxError)
            polygons.cacheTriangulation()
            // (std::max_element over the widths in order: the narrowest of those most drawings have)
            var w = 0, most = 0
            for (key, count) in histogram.sorted(by: { $0.key < $1.key }) where count > most { (w, most) = (key, count) }
            if w == 0 { w = Self.iuMM(0.05) }
            width = polygons.outlineCount > 0 ? w : 0
            return true
        }
        if !build(listFront, frontHistogram, &out.front, &out.frontWidth) { out.malformedFront = true }
        if !build(listBack, backHistogram, &out.back, &out.backWidth) { out.malformedBack = true }
        return out
    }
}

extension BoardDRC {
    /// The courtyards of the board's footprint `footprint` (its index among the board's footprints), as KiCad's
    /// FOOTPRINT::BuildCourtyardCaches makes them
    public func courtyards(_ footprint: Int) -> Courtyards { world.courtyards(board.root.all("footprint")[footprint]) }
}
