import Foundation
import XCTest
@testable import KiCadRouter

/// The router's geometry against KiCad's own: Fixtures/kicad-geometry.json holds random cases and what KiCad 10.0.7's
/// code makes of them (tools/kicad-reference/geometry.cpp, linked with KiCad's libs/kimath and the router's hulls).
/// KICAD_GEOMETRY_REFERENCE names another such file, a larger one say.
final class GeometryTests: XCTestCase {
    private static let reference: [String: Any] = {
        let url = ProcessInfo.processInfo.environment["KICAD_GEOMETRY_REFERENCE"].map(URL.init(fileURLWithPath:))
            ?? Bundle.module.url(forResource: "kicad-geometry", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    private func cases(_ name: String) -> [[String: Any]] { Self.reference[name] as! [[String: Any]] }

    /// The mismatches of one kind of case, the first few told in full
    private final class Mismatches {
        var count = 0
        var told: [String] = []
        func check<T: Equatable>(_ ours: T, _ kicad: T, _ what: String, _ c: [String: Any]) {
            guard ours != kicad else { return }
            count += 1
            if told.count < 8 { told.append("\(what): ours \(ours), KiCad's \(kicad), in \(c)") }
        }

        /// A floating point result KiCad's own computes with the platform's sine, cosine and arc tangent: the same
        /// within a few units in the last place (Apple's maths library and its JSON reader round the last bit
        /// otherwise than glibc's; the nanometres the router works in come out the same)
        func close(_ ours: Double, _ kicad: Double, _ what: String, _ c: [String: Any]) {
            guard abs(ours - kicad) > 4 * max(ours.magnitude, kicad.magnitude).ulp else { return }
            count += 1
            if told.count < 8 { told.append("\(what): ours \(ours), KiCad's \(kicad), in \(c)") }
        }
    }

    private func report(_ m: Mismatches, _ kind: String, of n: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(n, 0, "no \(kind) cases", file: file, line: line)
        XCTAssertEqual(m.count, 0, "\(kind): \(m.count) differences from KiCad in \(n) cases:\n" + m.told.joined(separator: "\n"),
                       file: file, line: line)
    }

    func testVectors() {
        let m = Mismatches(), all = cases("vectors")
        for c in all {
            let v = point(c["v"]), l = int(c["l"])
            m.check(v.norm, int(c["norm"]), "norm", c)
            m.check(v.resized(l), point(c["resized"]), "resized", c)
        }
        report(m, "vectors", of: all.count)
        let r = Mismatches(), rescales = cases("rescales")
        for c in rescales {
            r.check(KiMath.rescale(int(c["a"]), int(c["b"]), int(c["c"])), int(c["r"]), "rescale", c)
        }
        report(r, "rescales", of: rescales.count)
    }

    func testSegments() {
        let m = Mismatches(), all = cases("segments")
        for c in all {
            let s = seg(c["s"]), t = seg(c["t"]), p = point(c["p"]), cl = int(c["cl"])
            m.check(s.length, int(c["length"]), "length", c)
            m.check(s.center, point(c["center"]), "center", c)
            m.check(s.side(p), int(c["side"]), "side", c)
            m.check(s.nearestPoint(p), point(c["nearest"]), "nearest point", c)
            m.check(s.nearestPoint(t), point(c["nearestSeg"]), "nearest point to a segment", c)
            m.check(s.lineProject(p), point(c["project"]), "projection", c)
            m.check(s.squaredDistance(p), int(c["distSqP"]), "squared distance to a point", c)
            m.check(s.squaredDistance(t), int(c["distSqT"]), "squared distance to a segment", c)
            m.check(s.lineDistance(p, determineSide: true), int(c["lineDist"]), "line distance", c)
            m.check(s.intersect(t), optionalPoint(c["intersect"]), "intersection", c)
            m.check(s.intersect(t, ignoreEndpoints: true), optionalPoint(c["intersectNoEnds"]), "intersection, ends not counted", c)
            m.check(s.intersectLines(t), optionalPoint(c["intersectLines"]), "lines' intersection", c)
            var actual: Int?
            let hit = s.collide(t, clearance: cl, actual: &actual)
            m.check(hit, bool(c["collide"]), "collision", c)
            if hit { m.check(actual ?? -1, int(c["actual"]), "collision's distance", c) }
            m.check(s.collinear(t), bool(c["collinear"]), "collinear", c)
            m.check(s.overlaps(t), bool(c["overlaps"]), "overlaps", c)
            m.check(s.contains(p), bool(c["containsP"]), "contains a point", c)
            m.check(s.contains(t), bool(c["containsT"]), "contains a segment", c)
            m.check(s.approxCollinear(t), bool(c["approxCollinear"]), "nearly collinear", c)
            m.check(s.approxParallel(t), bool(c["approxParallel"]), "nearly parallel", c)
        }
        report(m, "segments", of: all.count)
    }

    func testDirectionsAndInitialTraces() {
        let m = Mismatches(), all = cases("directions")
        for c in all {
            let d = Direction45(point(c["v"]))
            m.check(d.description, c["dir"] as! String, "direction", c)
            let p0 = point(c["p0"]), p1 = point(c["p1"]), diag = bool(c["diag"])
            let trace = d.buildInitialTrace(p0, p1, startDiagonal: diag, mode: bool(c["ninety"]) ? .mitered90 : .mitered45)
            m.check(trace.points, points(c["trace"]), "initial trace", c)
            m.check(Direction45().buildInitialTrace(p0, p1, startDiagonal: diag).points, points(c["traceUndefined"]),
                    "initial trace, no direction", c)
        }
        report(m, "directions", of: all.count)
    }

    func testLineChains() {
        let m = Mismatches(), all = cases("chains")
        for c in all {
            let chain = LineChain(points(c["points"]), closed: bool(c["closed"]))
            let other = LineChain(points(c["other"]), closed: bool(c["otherClosed"]))
            let p = point(c["p"]), s = seg(c["s"]), cl = int(c["cl"])
            var simplified = chain
            simplified.simplify(int(c["tol"]))
            m.check(simplified.points, points(c["simplify"]), "simplified", c)
            var simplified2 = chain
            simplified2.simplify2()
            m.check(simplified2.points, points(c["simplify2"]), "simplified (the router's way)", c)
            var simplified2k = chain
            simplified2k.simplify2(removeColinear: false)
            m.check(simplified2k.points, points(c["simplify2KeepColinear"]), "simplified, collinear points kept", c)
            var split = chain
            m.check(split.split(p), int(c["splitAt"]), "split's index", c)
            m.check(split.points, points(c["split"]), "split", c)
            m.check(describe(chain.intersect(other)), describe(c["intersectChain"]), "chains' intersections", c)
            m.check(describe(chain.intersect(other, excludeColinearAndTouching: true)), describe(c["intersectChainExcluding"]),
                    "chains' crossings", c)
            m.check(describe(chain.intersect(s)), describe(c["intersectSeg"]), "intersections with a segment", c)
            let selfX = chain.selfIntersecting().map { "\($0.p) \($0.indexOur) \($0.indexTheir)" } ?? "none"
            let kicadSelf = (c["self"] as? [String: Any]).map { "\(point($0["p"])) \(int($0["our"])) \(int($0["their"]))" } ?? "none"
            m.check(selfX, kicadSelf, "self-intersection", c)
            m.check(chain.pointInside(p), bool(c["inside"]), "inside", c)
            m.check(chain.pointInside(p, accuracy: 3), bool(c["insideAccuracy"]), "inside, within 3 nm", c)
            m.check(chain.pointOnEdge(p), bool(c["onEdge"]), "on the edge", c)
            m.check(chain.nearestPoint(p), point(c["nearest"]), "nearest point", c)
            var dist = 0
            m.check(chain.nearestPoint(s, dist: &dist), point(c["nearestToSeg"]), "nearest point to a line", c)
            m.check(dist, int(c["nearestToSegDist"]), "nearest point to a line's distance", c)
            m.check(chain.pathLength(p), int(c["pathLength"]), "path length", c)
            m.check(chain.length, int(c["length"]), "length", c)
            m.check(chain.pointAlong(int(c["along"])), point(c["pointAlong"]), "point along", c)
            var actual: Int?, location: IPoint?
            let hitSeg = chain.collide(s, clearance: cl, actual: &actual, location: &location)
            m.check(hitSeg, bool(c["collideSeg"]), "collision with a segment", c)
            if hitSeg { m.check(actual ?? -1, int(c["collideSegActual"]), "collision with a segment's distance", c) }
            actual = nil
            let hitP = chain.collide(p, clearance: cl, actual: &actual, location: &location)
            m.check(hitP, bool(c["collideP"]), "collision with a point", c)
            if hitP { m.check(actual ?? -1, int(c["collidePActual"]), "collision with a point's distance", c) }
            m.close(chain.area(), double(c["area"]), "area", c)
        }
        report(m, "line chains", of: all.count)
    }

    func testShapeCollisions() {
        let m = Mismatches(), all = cases("collisions")
        for c in all {
            let a = shape(c["a"]), b = shape(c["b"]), cl = int(c["cl"])
            var actual: Int?
            let hit = a.collide(b, clearance: cl, actual: &actual)
            m.check(hit, bool(c["collide"]), "collision", c)
            m.check(a.collide(b, clearance: cl), bool(c["collideNoActual"]), "collision, its distance not asked", c)
            if hit { m.check(actual ?? -1, int(c["actual"]), "collision's distance", c) }
        }
        report(m, "shape collisions", of: all.count)
    }

    func testHulls() {
        let m = Mismatches(), all = cases("hulls")
        for c in all {
            let hull = shape(c["shape"]).hull(clearance: int(c["cl"]), walkaroundThickness: int(c["thickness"]))
            m.check(hull.points, points(c["hull"]), "hull", c)
            let line = LineChain(points(c["line"]))
            m.check(describe(Shape.hullIntersection(LineChain(points(c["hull"]), closed: true), line)), describe(c["crossings"]),
                    "hull crossings", c)
        }
        report(m, "hulls", of: all.count)
    }

    func testWalkarounds() {
        let m = Mismatches(), all = cases("walkarounds")
        for c in all {
            let hull = LineChain(points(c["hull"]), closed: true)
            let line = Line()
            line.setShape(LineChain(points(c["path"])))
            for (key, cw) in [("ccw", false), ("cw", true)] {
                let k = c[key] as! [String: Any]
                var walked = LineChain()
                let ok = line.walkaround(hull, &walked, cw: cw)
                m.check(ok, bool(k["ok"]), "\(key) walk's success", c)
                if ok && bool(k["ok"]) { m.check(walked.points, points(k["path"]), "\(key) walk", c) }
            }
        }
        report(m, "walkarounds", of: all.count)
    }

    func testArcs() {
        let m = Mismatches(), all = cases("arcs")
        for c in all {
            guard case .arc(let arc) = shape(c["arc"]) else { return XCTFail("not an arc") }
            let cl = int(c["cl"]), p = point(c["p"])
            m.check(arc.center, point(c["center"]), "centre", c)
            m.close(arc.radius, double(c["radius"]), "radius", c)
            let b = arc.bbox(cl), kb = points(c["bbox"])
            m.check([IPoint(b.minX, b.minY), IPoint(b.maxX, b.maxY)], kb, "box", c)
            m.close(arc.startAngle.degrees, double(c["startAngle"]), "start angle", c)
            m.close(arc.endAngle.degrees, double(c["endAngle"]), "end angle", c)
            m.close(arc.centralAngle.degrees, double(c["centralAngle"]), "central angle", c)
            m.check(arc.isCCW, bool(c["ccw"]), "counter-clockwise", c)
            m.check(arc.isEffectiveLine, bool(c["effectiveLine"]), "all but straight", c)
            var actual: Int?, location: IPoint?
            let hit = arc.collide(p, clearance: cl, actual: &actual, location: &location)
            m.check(hit, bool(c["collide"]), "point collision", c)
            if hit { m.check(actual ?? -1, int(c["actual"]), "point collision's distance", c) }
            m.check(arc.nearestPoint(p), point(c["nearest"]), "nearest point", c)
            if let poly = c["polyline"] {
                m.check(arc.convertToPolyline(int(c["maxError"])).points, points(poly), "polyline", c)
                m.check(arc.hull(clearance: cl, walkaroundThickness: int(c["thickness"])).points, points(c["hull"]), "hull", c)
            }
        }
        report(m, "arcs", of: all.count)
    }

    func testArcCollisions() {
        let m = Mismatches(), all = cases("arcCollisions")
        for c in all {
            let a = shape(c["a"]), b = shape(c["b"]), cl = int(c["cl"])
            var actual: Int?, actualR: Int?
            let hit = a.collide(b, clearance: cl, actual: &actual)
            m.check(hit, bool(c["collide"]), "collision", c)
            m.check(a.collide(b, clearance: cl), bool(c["collideNoActual"]), "collision, its distance not asked", c)
            if hit { m.check(actual ?? -1, int(c["actual"]), "collision's distance", c) }
            let hitR = b.collide(a, clearance: cl, actual: &actualR)
            m.check(hitR, bool(c["collideReversed"]), "collision the other way round", c)
            m.check(b.collide(a, clearance: cl), bool(c["collideReversedNoActual"]), "collision the other way round, not asked", c)
            if hitR { m.check(actualR ?? -1, int(c["actualReversed"]), "collision's distance the other way round", c) }
            if let mtv = c["mtv"], case .circle(let center, let r) = b {
                m.check(a.pushout(circle: center, radius: r, clearance: cl), optionalPoint(mtv), "via pushed out", c)
            }
        }
        report(m, "arc collisions", of: all.count)
    }

    func testPadPolygons() {
        let m = Mismatches(), all = cases("padPolygons")
        for c in all {
            let pos = point(c["pos"]), size = point(c["size"]), rotation = EDAAngle(degrees: double(c["rotation"]))
            let inflate = int(c["inflate"]), maxError = int(c["maxError"])
            let location: ErrorLocation = bool(c["outside"]) ? .outside : .inside
            let outline: LineChain
            switch c["kind"] as! String {
            case "roundrect":
                outline = PadPolygon.roundChamferedRect(position: pos, size: size, rotation: rotation, cornerRadius: int(c["radius"]),
                                                        chamferRatio: double(c["chamferRatio"]), chamferCorners: int(c["chamferCorners"]),
                                                        inflate: inflate, maxError: maxError, errorLocation: location)
            case "trapezoid":
                outline = PadPolygon.trapezoid(position: pos, size: size, rotation: rotation, deltaX: int(c["dx"]), deltaY: int(c["dy"]),
                                               inflate: inflate, maxError: maxError, errorLocation: location)
            default:
                outline = PadPolygon.circle(center: pos, radius: size.x, maxError: maxError, errorLocation: location,
                                            minSegCount: int(c["minSegs"]))
            }
            m.check(outline.points, points(c["outline"]), "\(c["kind"]!) outline", c)
        }
        report(m, "pad polygons", of: all.count)
    }

    // MARK: - Reading the cases

    private func int(_ v: Any?) -> Int { (v as! NSNumber).intValue }
    private func bool(_ v: Any?) -> Bool { (v as! NSNumber).boolValue }
    /// (Foundation on Linux reads a number of 17 digits as an NSDecimalNumber, whose doubleValue can be a bit off;
    /// its digits read as a Double are the number KiCad wrote)
    private func double(_ v: Any?) -> Double {
        if let d = v as? NSDecimalNumber, let x = Double(d.stringValue) { return x }
        return (v as! NSNumber).doubleValue
    }

    private func point(_ v: Any?) -> IPoint {
        let a = v as! [Any]
        return IPoint(int(a[0]), int(a[1]))
    }

    private func optionalPoint(_ v: Any?) -> IPoint? { v is NSNull || v == nil ? nil : point(v) }
    private func points(_ v: Any?) -> [IPoint] { (v as! [Any]).map(point) }

    private func seg(_ v: Any?) -> Seg {
        let a = v as! [Any]
        return Seg(point(a[0]), point(a[1]))
    }

    private func shape(_ v: Any?) -> Shape {
        let d = v as! [String: Any]
        if let c = d["circle"] { return .circle(center: point(c), radius: int(d["r"])) }
        if let p = d["rect"] {
            let o = point(p), size = point(d["size"])
            return .rect(IBox(minX: o.x, minY: o.y, maxX: o.x + size.x, maxY: o.y + size.y))
        }
        if let s = d["segment"] { return .segment(seg(s), width: int(d["w"])) }
        if let s = d["simple"] { return .simple(LineChain(points(s), closed: true)) }
        if let a = d["arc"] {
            let p = points(a)
            return .arc(ShapeArc(start: p[0], mid: p[1], end: p[2], width: int(d["w"])))
        }
        return .chain(LineChain(points(d["chain"])))
    }

    private func describe(_ xs: [LineChain.Intersection]) -> [String] {
        xs.map { "\($0.p) \($0.indexOur) \($0.indexTheir) \($0.isCornerOur) \($0.isCornerTheir) \($0.valid)" }
    }

    private func describe(_ v: Any?) -> [String] {
        (v as! [[String: Any]]).map {
            "\(point($0["p"])) \(int($0["our"])) \(int($0["their"])) \(bool($0["cornerOur"])) \(bool($0["cornerTheir"])) \(bool($0["valid"]))"
        }
    }
}
