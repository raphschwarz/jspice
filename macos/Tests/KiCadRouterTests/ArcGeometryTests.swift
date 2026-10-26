import Foundation
import XCTest
@testable import KiCadRouter

/// Line chains with arcs in them, against KiCad's own: Fixtures/kicad-arc-geometry.json holds random chains of segments
/// and arcs, as the router keeps a track's path, what KiCad 10.0.7's SHAPE_LINE_CHAIN makes of them (cut, split,
/// spliced, turned round, simplified, collided, walked round: tools/kicad-reference/geometry.cpp --arcs), and the
/// traces DIRECTION_45 starts in each corner mode, rounded too. The port must keep the same points, the same arcs
/// (to their centres) and the same note of which point is on which arc. KICAD_ARC_GEOMETRY_REFERENCE names another
/// such file.
final class ArcGeometryTests: XCTestCase {
    private static let reference: [String: Any] = {
        let url = ProcessInfo.processInfo.environment["KICAD_ARC_GEOMETRY_REFERENCE"].map(URL.init(fileURLWithPath:))
            ?? Bundle.module.url(forResource: "kicad-arc-geometry", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    private func cases(_ name: String) -> [[String: Any]] { Self.reference[name] as? [[String: Any]] ?? [] }

    /// The mismatches of one kind of case, the first few told in full
    private final class Mismatches {
        var count = 0
        var told: [String] = []
        func check<T: Equatable>(_ ours: T, _ kicad: T, _ what: String, _ c: [String: Any]) {
            guard ours != kicad else { return }
            count += 1
            if told.count < 6 { told.append("\(what): ours \(ours), KiCad's \(kicad), in \(Self.compact(c))") }
        }

        private static func compact(_ c: [String: Any]) -> String {
            let s = String(decoding: (try? JSONSerialization.data(withJSONObject: c, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
            return s.count > 1500 ? String(s.prefix(1500)) + "..." : s
        }
    }

    private func report(_ m: Mismatches, _ kind: String, of n: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(n, 0, "no \(kind) cases", file: file, line: line)
        XCTAssertEqual(m.count, 0, "\(kind): \(m.count) differences from KiCad in \(n) cases:\n" + m.told.joined(separator: "\n"),
                       file: file, line: line)
    }

    func testArcChains() {
        let m = Mismatches(), all = cases("chains")
        for c in all {
            let chain = Self.chain(c["steps"], closed: bool(c["closed"]))
            m.check(Self.describe(chain), Self.describe(c["chain"]), "chain built", c)
            // (each point's: shared, on an arc, an arc's segment from it, an arc's start, an arc's end, as 0 or 1; its
            // arc; the next shape's point)
            let query = (0..<chain.pointCount).map { k -> [Int] in
                [chain.isSharedPoint(k), chain.isPointOnArc(k), chain.isArcSegment(k), chain.isArcStart(k), chain.isArcEnd(k)].map { $0 ? 1 : 0 }
                    + [chain.arcIndex(k), chain.nextShape(k)]
            }
            let kicadQuery = (c["query"] as! [[Any]]).map { $0.map { int($0) } }
            m.check(query, kicadQuery, "arc queries", c)
            m.check(chain.shapeCount, int(c["shapeCount"]), "shape count", c)
            m.check(chain.length, int(c["length"]), "length", c)
            m.check(Self.describe(chain.reversed()), Self.describe(c["reverse"]), "reversed", c)
            let slice = c["slice"] as! [String: Any]
            m.check(Self.describe(chain.slice(int(slice["s"]), int(slice["e"]))), Self.describe(slice["result"]), "slice", c)
            let remove = c["remove"] as! [String: Any]
            var r = chain
            r.remove(int(remove["s"]), int(remove["e"]))
            m.check(Self.describe(r), Self.describe(remove["result"]), "remove", c)
            let removeShape = c["removeShape"] as! [String: Any]
            r = chain
            r.removeShape(int(removeShape["i"]))
            m.check(Self.describe(r), Self.describe(removeShape["result"]), "remove shape", c)
            let replace = c["replace"] as! [String: Any]
            r = chain
            r.replace(int(replace["s"]), int(replace["e"]), with: Self.chain(replace["with"], closed: false))
            m.check(Self.describe(r), Self.describe(replace["result"]), "replace", c)
            let insert = c["insert"] as! [String: Any]
            r = chain
            r.insert(point(insert["p"]), at: int(insert["i"]))
            m.check(Self.describe(r), Self.describe(insert["result"]), "insert", c)
            let append = c["append"] as! [String: Any]
            r = chain
            r.append(Self.chain(append["with"], closed: false))
            m.check(Self.describe(r), Self.describe(append["result"]), "append", c)
            let split = c["split"] as! [String: Any]
            r = chain
            m.check(r.split(point(split["p"]), exact: bool(split["exact"])), int(split["index"]), "split's index", c)
            m.check(Self.describe(r), Self.describe(split["result"]), "split", c)
            let setPoint = c["setPoint"] as! [String: Any]
            r = chain
            r.setPoint(int(setPoint["i"]), point(setPoint["p"]))
            m.check(Self.describe(r), Self.describe(setPoint["result"]), "set point", c)
            let simplify = c["simplify"] as! [String: Any]
            r = chain
            r.simplify(int(simplify["tol"]))
            m.check(Self.describe(r), Self.describe(simplify["result"]), "simplified", c)
            r = chain
            r.simplify2()
            m.check(Self.describe(r), Self.describe(c["simplify2"]), "simplified (the router's way)", c)
            r = chain
            r.simplify2(removeColinear: false)
            m.check(Self.describe(r), Self.describe(c["simplify2KeepColinear"]), "simplified, collinear points kept", c)
            r = chain
            r.removeDuplicatePoints()
            m.check(Self.describe(r), Self.describe(c["removeDuplicates"]), "duplicate points removed", c)
            r = chain
            r.clearArcs()
            m.check(Self.describe(r), Self.describe(c["clearArcs"]), "arcs cleared", c)
            r = chain
            r.setClosed(!chain.isClosed)
            m.check(Self.describe(r), Self.describe(c["setClosed"]), "closed or opened", c)
            let nearest = c["nearest"] as! [String: Any]
            m.check(chain.nearestPoint(point(nearest["p"])), point(nearest["any"]), "nearest point", c)
            if let ends = nearest["ends"] {
                m.check(chain.nearestPoint(point(nearest["p"]), allowInternalShapePoints: false), point(ends),
                        "nearest point, an arc's ends only", c)
            }
            let collide = c["collide"] as! [String: Any]
            let cl = int(collide["cl"])
            var actual: Int?, location: IPoint?
            let hitP = chain.collide(point(collide["p"]), clearance: cl, actual: &actual, location: &location)
            m.check(hitP, bool(collide["hitP"]), "collision with a point", c)
            if hitP { m.check(actual ?? -1, int(collide["actualP"]), "collision with a point's distance", c) }
            actual = nil
            let s = seg(collide["s"])
            let hitS = chain.collide(s, clearance: cl, actual: &actual, location: &location)
            m.check(hitS, bool(collide["hitS"]), "collision with a segment", c)
            if hitS { m.check(actual ?? -1, int(collide["actualS"]), "collision with a segment's distance", c) }
            m.check(chain.collide(s, clearance: cl), bool(collide["hitSNoActual"]), "collision with a segment, not asked how near", c)
            let shapeCase = c["collideShape"] as! [String: Any]
            let other = shape(shapeCase["shape"])
            let me = Shape.chain(chain)
            actual = nil
            let hit = me.collide(other, clearance: cl, actual: &actual)
            m.check(hit, bool(shapeCase["hit"]), "collision with a shape", c)
            if hit { m.check(actual ?? -1, int(shapeCase["actual"]), "collision with a shape's distance", c) }
            m.check(me.collide(other, clearance: cl), bool(shapeCase["hitNoActual"]), "collision with a shape, not asked how near", c)
            actual = nil
            let hitR = other.collide(me, clearance: cl, actual: &actual)
            m.check(hitR, bool(shapeCase["hitReversed"]), "a shape's collision with it", c)
            if hitR { m.check(actual ?? -1, int(shapeCase["actualReversed"]), "a shape's collision with it, its distance", c) }
            m.check(other.collide(me, clearance: cl), bool(shapeCase["hitReversedNoActual"]), "a shape's collision with it, not asked", c)
            if let splitAt = c["splitAt"] as? [String: Any] {
                let (pre, mid, post) = chain.split(point(splitAt["a"]), point(splitAt["b"]))
                m.check([Self.describe(pre), Self.describe(mid), Self.describe(post)],
                        [Self.describe(splitAt["pre"]), Self.describe(splitAt["mid"]), Self.describe(splitAt["post"])],
                        "split in three", c)
            }
        }
        report(m, "chains with arcs", of: all.count)
    }

    func testInitialTracesInEveryCornerMode() {
        let m = Mismatches(), all = cases("traces")
        var arcs = 0
        for c in all {
            let d = c["v"] is NSNull ? Direction45() : Direction45(point(c["v"]))
            let mode = Direction45.CornerMode(rawValue: int(c["mode"]))!
            let trace = d.buildInitialTrace(point(c["p0"]), point(c["p1"]), startDiagonal: bool(c["diag"]), mode: mode)
            m.check(Self.describe(trace), Self.describe(c["trace"]), "initial trace", c)
            if trace.arcCount > 0 { arcs += 1 }
        }
        XCTAssertGreaterThan(arcs, 0, "no rounded corners")
        report(m, "initial traces", of: all.count)
    }

    func testArcWalkarounds() {
        let m = Mismatches(), all = cases("walkarounds")
        for c in all {
            let hull = LineChain(points(c["hull"]), closed: true)
            let line = Line()
            line.setShape(Self.chain(c["steps"], closed: false))
            for (key, cw) in [("ccw", false), ("cw", true)] {
                let k = c[key] as! [String: Any]
                var walked = LineChain()
                let ok = line.walkaround(hull, &walked, cw: cw)
                m.check(ok, bool(k["ok"]), "\(key) walk's success", c)
                if ok && bool(k["ok"]) { m.check(Self.describe(walked), Self.describe(k["path"]), "\(key) walk", c) }
            }
        }
        report(m, "walkarounds with arcs", of: all.count)
    }

    func testArcDrags() {
        let m = Mismatches(), all = cases("arcDrags")
        for c in all {
            let line = Line()
            line.setShape(Self.chain(c["steps"], closed: false))
            line.setWidth(250_000)
            line.dragArc(point(c["p"]), int(c["index"]))
            m.check(Self.describe(line.cLine), Self.describe(c["result"]), "arc dragged", c)
        }
        report(m, "arcs dragged", of: all.count)
    }

    // MARK: - Reading and writing chains

    /// The chain geometry.cpp's steps make: points appended, arcs appended as arcs
    static func chain(_ v: Any?, closed: Bool) -> LineChain {
        var c = LineChain()
        for s in v as! [[String: Any]] {
            if let a = s["arc"] as? [Any] {
                let p = a.map(Self.point)
                c.append(ShapeArc(start: p[0], mid: p[1], end: p[2]))
            } else {
                c.append(point(s["p"]), allowDuplication: (s["dup"] as? NSNumber)?.boolValue ?? false)
            }
        }
        c.setClosed(closed)
        return c
    }

    /// A chain as geometry.cpp writes one: its points, the arcs each is on, its arcs (their points, centre and width)
    static func describe(_ c: LineChain) -> String {
        let pts = c.points.map { "\($0.x),\($0.y)" }.joined(separator: " ")
        let shapes = c.shapes.map { "\($0.first)/\($0.second)" }.joined(separator: " ")
        let arcs = c.arcs.map { "[\($0.start) \($0.mid) \($0.end) c \($0.center) w \($0.width)]" }.joined(separator: " ")
        return "\(c.isClosed ? "closed" : "open") \(pts) | \(shapes) | \(arcs)"
    }

    static func describe(_ v: Any?) -> String {
        let d = v as! [String: Any]
        let pts = (d["points"] as! [Any]).map { p -> String in let q = point(p); return "\(q.x),\(q.y)" }.joined(separator: " ")
        let shapes = (d["shapes"] as! [[Any]]).map { "\(int($0[0]))/\(int($0[1]))" }.joined(separator: " ")
        let arcs = (d["arcs"] as! [[Any]]).map {
            "[\(point($0[0])) \(point($0[1])) \(point($0[2])) c \(point($0[3])) w \(int($0[4]))]"
        }.joined(separator: " ")
        return "\(bool(d["closed"]) ? "closed" : "open") \(pts) | \(shapes) | \(arcs)"
    }

    private static func int(_ v: Any?) -> Int { (v as! NSNumber).intValue }
    private func int(_ v: Any?) -> Int { Self.int(v) }
    private static func bool(_ v: Any?) -> Bool { (v as! NSNumber).boolValue }
    private func bool(_ v: Any?) -> Bool { Self.bool(v) }

    private static func point(_ v: Any?) -> IPoint {
        let a = v as! [Any]
        return IPoint(int(a[0]), int(a[1]))
    }

    private func point(_ v: Any?) -> IPoint { Self.point(v) }
    private func points(_ v: Any?) -> [IPoint] { (v as! [Any]).map(Self.point) }

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
        return .chain(Self.chain(d["steps"], closed: bool(d["closed"])))
    }
}
