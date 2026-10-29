// Ported from KiCad 10.0.7: pcbnew/drc/drc_test_provider_courtyard_clearance.cpp (footprints' courtyards: malformed
// and missing ones, courtyards overlapping or nearer than a rule's clearance, and plated and unplated holes in
// another footprint's courtyard, each by EvalRules of the courtyard clearance between the two), with
// libs/kimath/src/geometry/shape_poly_set.cpp (SHAPE_POLY_SET::Collide: two sets triangle by triangle, the nearest
// pair's distance, a hole by its distance to the polygons).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardDRC {
    /// SHAPE_POLY_SET::Collide of two sets at no clearance: whether a triangle of one touches a triangle of the other
    static func polySetsCollide(_ a: PolySet, _ b: PolySet) -> Bool { polySetsCollide(a, b, clearance: 0) != nil }

    /// The same at a clearance, with how near (the least of the colliding triangles' distances, every pair of them
    /// tried, as KiCad tries them when it asks how near)
    static func polySetsCollide(_ a: PolySet, _ b: PolySet, clearance: Int) -> Int? {
        var a = a, b = b
        a.cacheTriangulation()
        b.cacheTriangulation()
        var trisB: [Shape] = []
        for tpoly in b.triangulatedPolygons {
            for i in tpoly.triangles.indices {
                let (p, q, r) = tpoly.triangle(i)
                trisB.append(.simple(LineChain([p, q, r], closed: true)))
            }
        }
        let boxesB = trisB.map(\.bbox)
        var best: Int?
        for tpoly in a.triangulatedPolygons {
            for i in tpoly.triangles.indices {
                let (p, q, r) = tpoly.triangle(i)
                let triA = Shape.simple(LineChain([p, q, r], closed: true))
                let boxA = triA.bbox.inflated(clearance)
                for (j, triB) in trisB.enumerated() where boxA.intersects(boxesB[j]) {
                    var actual: Int?
                    if triB.collide(triA, clearance: clearance, wantActual: true, actual: &actual) {
                        let v = max(0, actual ?? 0)
                        if clearance == 0 { return v }
                        if best == nil || v < best! { best = v }
                    }
                }
            }
        }
        return best
    }

    /// A BOX2I as KiCad holds one: its position a 32-bit VECTOR2I, which an inflate wraps round where it
    /// overflows (as it does about a courtyard drawn at the coordinates' limits), its size 64 bits, its end cut to
    /// the 32 bits (KiCheckedCast)
    struct KBox {
        var x: Int32, y: Int32
        var w: Int, h: Int

        init(_ b: IBox) {
            x = Int32(clamping: b.minX)
            y = Int32(clamping: b.minY)
            w = b.maxX - b.minX
            h = b.maxY - b.minY
        }

        /// Inflate (of a box of no negative size)
        mutating func inflate(_ d: Int) {
            if w < -2 * d {
                x = Int32(clamping: Int(x) + w / 2)
                w = 0
            } else {
                x = x &- Int32(truncatingIfNeeded: d)
                w += 2 * d
            }
            if h < -2 * d {
                y = Int32(clamping: Int(y) + h / 2)
                h = 0
            } else {
                y = y &- Int32(truncatingIfNeeded: d)
                h += 2 * d
            }
        }

        mutating func normalize() {
            if h < 0 {
                y = Int32(clamping: Int(y) + h)
                h = -h
            }
            if w < 0 {
                x = Int32(clamping: Int(x) + w)
                w = -w
            }
        }

        /// Merge: its position the lesser, its end (cut to 32 bits) the greater
        mutating func merge(_ other: KBox) {
            normalize()
            var r = other
            r.normalize()
            let ex = max(Int32(clamping: Int(x) + w), Int32(clamping: Int(r.x) + r.w))
            let ey = max(Int32(clamping: Int(y) + h), Int32(clamping: Int(r.y) + r.h))
            x = min(x, r.x)
            y = min(y, r.y)
            w = Int(ex) - Int(x)
            h = Int(ey) - Int(y)
        }

        func intersects(_ other: KBox) -> Bool {
            var me = self, r = other
            me.normalize()
            r.normalize()
            let left = max(Int(me.x), Int(r.x)), right = min(Int(me.x) + me.w, Int(r.x) + r.w)
            let top = max(Int(me.y), Int(r.y)), bottom = min(Int(me.y) + me.h, Int(r.y) + r.h)
            return left <= right && top <= bottom
        }
    }

    /// A courtyard's BBoxFromCaches: each polygon's outline's cached box (GenerateBBoxCache: its points' box, the
    /// first outline's grown by the width the courtyard gives it), merged
    static func cachedBox(_ set: PolySet, width: Int) -> KBox? {
        var out: KBox?
        for (i, p) in set.polygons.enumerated() {
            var b = KBox(p[0].bbox)
            if i == 0 && width != 0 { b.inflate(width) }
            if out == nil { out = b } else { out!.merge(b) }
        }
        return out
    }

    // MARK: - The check (DRC_TEST_PROVIDER_COURTYARD_CLEARANCE)

    func checkCourtyards(_ out: inout Report, _ c: Copper) {
        let fps = board.root.all("footprint")
        var yards: [Courtyards] = []
        // the courtyards' definitions: malformed ones (each of the conversion's complaints), missing ones
        for (i, fp) in fps.enumerated() {
            var messages: [String] = []
            let y = world.courtyards(fp) { messages.append($0) }
            yards.append(y)
            guard let uuid = fp.value("uuid") else { continue }
            if y.malformedFront || y.malformedBack {
                for m in messages { out.add("malformed_courtyard", m, [uuid]) }
            } else if y.front.polygons.isEmpty && y.back.polygons.isEmpty {
                let attr = fp["attr"]?.arguments.map(\.text) ?? []
                if !attr.contains("allow_missing_courtyard") { out.add("missing_courtyard", nil, [uuid]) }
            }
            _ = i
        }
        // each pair of footprints, in the order of their uuids
        let order = fps.indices.compactMap { i in fps[i].value("uuid").map { (i, $0) } }.sorted { $0.1 < $1.1 }
        let frontBoxes = yards.map { Self.cachedBox($0.front, width: $0.frontWidth) }
        let backBoxes = yards.map { Self.cachedBox($0.back, width: $0.backWidth) }
        let fpBoxes = fps.indices.map { KBox(footprintBox($0, fps[$0], c)) }

        /// A plated or unplated pad's hole in another footprint's courtyard, the front's tried first where its rule
        /// leaves it to be tested, then the back's (not a heatsink pad's)
        func testPad(_ pad: CopperItem, _ node: SExpr, against f: Int, front checkFront: Bool, back checkBack: Bool) {
            guard let p = pad.pad, let hole = pad.hole,
                  node["property"]?.arguments.contains(where: { $0.text == "pad_prop_heatsink" }) != true else { return }
            let type: String
            switch p.pad.attribute {
            case .pth: type = "pth_inside_courtyard"
            case .npth: type = "npth_inside_courtyard"
            default: return
            }
            guard !out.exceeded(type) else { return }
            let target = fps[f].value("uuid") ?? ""
            if checkFront, !yards[f].front.polygons.isEmpty, Self.polySetCollide(yards[f].front, [hole], compound: false, wantActual: false) {
                out.add(type, nil, [pad.uuid, target])
            } else if checkBack, !yards[f].back.polygons.isEmpty,
                      Self.polySetCollide(yards[f].back, [hole], compound: false, wantActual: false) {
                out.add(type, nil, [pad.uuid, target])
            }
        }

        // (the worst courtyard clearance the rules have, which a footprint's courtyards' boxes are grown by)
        let engine = ruleState.engine
        let largest = engine.worstConstraint(.courtyardClearance)?.value.min ?? 0
        func grown(_ box: KBox?) -> KBox? { box.map { var b = $0; b.inflate(largest); return b } }
        for (k, (a, uuidA)) in order.enumerated() {
            let frontA = grown(frontBoxes[a]), backA = grown(backBoxes[a])
            let fpA = ruleState.footprints[a]
            for (b, uuidB) in order[(k + 1)...] {
                let fpB = ruleState.footprints[b]
                for (setA, setB, boxA, boxB, layer) in [(yards[a].front, yards[b].front, frontA, frontBoxes[b], KiLayer.fCu),
                                                        (yards[a].back, yards[b].back, backA, backBoxes[b], KiLayer.bCu)] {
                    guard !out.exceeded("courtyards_overlap"), !setA.polygons.isEmpty, !setB.polygons.isEmpty,
                          let ba = boxA, let bb = boxB, ba.intersects(bb) else { continue }
                    let constraint = engine.evalRules(.courtyardClearance, fpA, fpB, layer: layer)
                    let clearance = constraint.value.min
                    guard constraint.severity != .ignore && clearance >= 0,
                          let actual = Self.polySetsCollide(setA, setB, clearance: clearance) else { continue }
                    let detail = clearance > 0
                        ? Self.formatMsg({ "(\($0) clearance \($1); actual \($2))" }, constraint.ruleName, clearance, actual) : nil
                    out.add("courtyards_overlap", detail, [uuidA, uuidB], rule: constraint.parentRule)
                }
                // (whether the holes are tested against the courtyards: by the rule between the two, each way round, on
                // each side, asked only where a hole could be in one)
                let padsOfBNearA = (frontA.map { $0.intersects(fpBoxes[b]) } ?? false) || (backA.map { $0.intersects(fpBoxes[b]) } ?? false)
                let padsOfANearB = (frontBoxes[b].map { $0.intersects(fpBoxes[a]) } ?? false)
                    || (backBoxes[b].map { $0.intersects(fpBoxes[a]) } ?? false)
                var checkFront = false, checkBack = false
                if padsOfBNearA || padsOfANearB {
                    for (x, y, layer) in [(fpA, fpB, KiLayer.fCu), (fpB, fpA, KiLayer.fCu), (fpA, fpB, KiLayer.bCu), (fpB, fpA, KiLayer.bCu)] {
                        let constraint = engine.evalRules(.courtyardClearance, x, y, layer: layer)
                        if constraint.severity != .ignore && constraint.value.min >= 0 {
                            if layer == KiLayer.fCu { checkFront = true } else { checkBack = true }
                        }
                    }
                }
                if padsOfBNearA {
                    let nodes = fps[b].all("pad")
                    for (j, pad) in c.footprintPads[b].enumerated() { testPad(pad, nodes[j], against: a, front: checkFront, back: checkBack) }
                }
                if padsOfANearB {
                    let nodes = fps[a].all("pad")
                    for (j, pad) in c.footprintPads[a].enumerated() { testPad(pad, nodes[j], against: b, front: checkFront, back: checkBack) }
                }
            }
        }
    }
}
