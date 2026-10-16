import Foundation
import XCTest
@testable import KiCadRouter

/// The polygon clipper against KiCad's own: Fixtures/kicad-clipper.json holds random cases and what Clipper2, as
/// KiCad 10.0.7 ships and compiles it, makes of them (tools/kicad-reference/clipper.cpp). KICAD_CLIPPER_REFERENCE
/// names another such file, a larger one say. Paths must match point for point, z values and the order of the paths
/// and of their points included, and so must the calls of the z callback.
final class ClipperTests: XCTestCase {
    private typealias Point64 = Clipper.Point64
    private typealias Paths64 = Clipper.Paths64

    private static let reference: [String: Any] = {
        let url = ProcessInfo.processInfo.environment["KICAD_CLIPPER_REFERENCE"].map(URL.init(fileURLWithPath:))
            ?? Bundle.module.url(forResource: "kicad-clipper", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    private func cases(_ name: String) -> [[String: Any]] { Self.reference[name] as! [[String: Any]] }

    /// The mismatches of one kind of case, the first few told
    private final class Mismatches {
        var count = 0
        var told: [String] = []
        func check<T: Equatable>(_ ours: T, _ kicad: T, _ what: String, _ index: Int) {
            guard ours != kicad else { return }
            count += 1
            if told.count < 8 { told.append("case \(index), \(what): ours \(brief(ours)), KiCad's \(brief(kicad))") }
        }

        private func brief<T>(_ v: T) -> String {
            let s = "\(v)"
            return s.count > 400 ? s.prefix(400) + "..." : s
        }
    }

    private func report(_ m: Mismatches, _ kind: String, of n: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(n, 0, "no \(kind) cases", file: file, line: line)
        XCTAssertEqual(m.count, 0, "\(kind): \(m.count) differences from KiCad in \(n) cases:\n" + m.told.joined(separator: "\n"),
                       file: file, line: line)
    }

    /// The z callback as the reference program has it (KiCad's way): each call recorded, each point given the next z
    private final class ZLog {
        var calls: [[Int]] = []
        var next: Int

        init(_ next: Int) { self.next = next }

        var callback: Clipper.ZCallback64 {
            { [self] e1bot, e1top, e2bot, e2top, pt in
                calls.append([e1bot.z, e1top.z, e2bot.z, e2top.z, pt.x, pt.y, pt.z])
                pt.z = next
                next += 1
            }
        }
    }

    func testBooleans() {
        let m = Mismatches(), all = cases("booleans")
        for (i, c) in all.enumerated() {
            let subject = paths(c["subject"]), open = paths(c["open"]), clip = paths(c["clip"])
            let clipType = Clipper.ClipType(rawValue: int(c["clipType"]))!
            let fillRule = Clipper.FillRule(rawValue: int(c["fillRule"]))!
            func clipper(_ log: ZLog) -> Clipper.Clipper64 {
                let clipper = Clipper.Clipper64()
                clipper.preserveCollinear = bool(c["preserveCollinear"])
                clipper.reverseSolution = bool(c["reverse"])
                clipper.defaultZ = int(c["defaultZ"])
                clipper.pipIndexThreshold = int(c["pipThreshold"])
                if bool(c["zCallback"]) { clipper.zCallback = log.callback }
                clipper.addSubject(subject)
                if !open.isEmpty { clipper.addOpenSubject(open) }
                clipper.addClip(clip)
                return clipper
            }

            let log = ZLog(int(c["zBase"]))
            var closed = Paths64(), openOut = Paths64()
            let ok = clipper(log).execute(clipType, fillRule, closedPaths: &closed, openPaths: &openOut)
            let tree = Clipper.PolyTree64()
            var treeOpen = Paths64()
            let treeLog = ZLog(int(c["zBase"]))
            let treeOk = clipper(treeLog).execute(clipType, fillRule, polytree: tree, openPaths: &treeOpen)
            // (where KiCad's copy crashes, the port has only to finish)
            if c["crashed"] != nil { continue }

            m.check(ok, bool(c["ok"]), "success", i)
            m.check(describe(closed), describe(c["closed"]), "closed paths", i)
            m.check(describe(openOut), describe(c["openOut"]), "open paths", i)
            m.check(log.calls, calls(c["calls"]), "z callbacks", i)
            m.check(treeOk, bool(c["treeOk"]), "success, as a tree", i)
            m.check(describe(tree), describe(tree: c["tree"]), "tree", i)
            m.check(tree.area, double(c["treeArea"]), "tree's area", i)
            m.check(describe(treeOpen), describe(c["treeOpen"]), "open paths, with a tree", i)
            m.check(treeLog.calls, calls(c["treeCalls"]), "z callbacks, as a tree", i)
        }
        report(m, "boolean operations", of: all.count)
    }

    func testOffsets() {
        let m = Mismatches(), all = cases("offsets")
        for (i, c) in all.enumerated() {
            let delta = double(c["delta"])
            let groups = (c["groups"] as! [[String: Any]]).map {
                (paths($0["paths"]), Clipper.JoinType(rawValue: int($0["join"]))!, Clipper.EndType(rawValue: int($0["end"]))!)
            }
            let deltaFunction: Clipper.DeltaCallback64 = { _, _, curr, prev in delta * (1.0 + 0.25 * Double((curr + prev) % 3)) }
            func offsetter(_ log: ZLog) -> Clipper.ClipperOffset {
                let offsetter = Clipper.ClipperOffset()
                offsetter.miterLimit = double(c["miterLimit"])
                offsetter.arcTolerance = double(c["arcTolerance"])
                offsetter.preserveCollinear = bool(c["preserveCollinear"])
                offsetter.reverseSolution = bool(c["reverse"])
                if bool(c["zCallback"]) { offsetter.zCallback = log.callback }
                for (p, join, end) in groups {
                    if p.count == 1 { offsetter.addPath(p[0], join, end) } else { offsetter.addPaths(p, join, end) }
                }
                return offsetter
            }
            let byCallback = bool(c["deltaCallback"])

            let log = ZLog(int(c["zBase"]))
            let out = byCallback ? offsetter(log).execute(deltaFunction) : offsetter(log).execute(delta)
            let treeLog = ZLog(int(c["zBase"]))
            let tree = Clipper.PolyTree64()
            let treeOffsetter = offsetter(treeLog)
            if byCallback { treeOffsetter.deltaCallback = deltaFunction }
            treeOffsetter.execute(byCallback ? 1.0 : delta, polytree: tree)
            if c["crashed"] != nil { continue }

            m.check(describe(out), describe(c["out"]), "offset", i)
            m.check(log.calls, calls(c["calls"]), "z callbacks", i)
            m.check(describe(tree), describe(tree: c["tree"]), "offset, as a tree", i)
            m.check(treeLog.calls, calls(c["treeCalls"]), "z callbacks, as a tree", i)

            // KiCad's inflate, when it simplifies: the offset simplified, and its union as a tree
            if let s = c["simplify"] as? [String: Any] {
                let simplified = Clipper.simplifyPaths(out, double(s["epsilon"]), isClosedPath: bool(s["closed"]))
                m.check(describe(simplified), describe(s["paths"]), "offset simplified", i)
                let union = Clipper.Clipper64()
                union.preserveCollinear = false
                union.reverseSolution = false
                union.addSubject(simplified)
                let unionTree = Clipper.PolyTree64()
                union.execute(.union, .positive, polytree: unionTree)
                m.check(describe(unionTree), describe(tree: s["tree"]), "offset simplified, its union", i)
            }
        }
        report(m, "offsets", of: all.count)
    }

    func testHelpers() {
        let m = Mismatches(), all = cases("helpers")
        for (i, c) in all.enumerated() {
            let p = path(c["path"]), other = path(c["other"])
            m.check(Clipper.area(p), double(c["area"]), "area", i)
            m.check(Clipper.area([p, other]), double(c["areaBoth"]), "area of two paths", i)
            m.check(Clipper.isPositive(p), bool(c["positive"]), "orientation", i)
            for probe in c["pips"] as! [[Any]] {
                let pt = Point64(int(probe[0]), int(probe[1]))
                m.check(Clipper.pointInPolygon(pt, p).rawValue, int(probe[2]), "point in polygon at \(pt)", i)
            }
            m.check(Clipper.path2ContainsPath1(p, other), bool(c["contains"]), "holds the other", i)
            m.check(Clipper.path2ContainsPath1(other, p), bool(c["containedBy"]), "held by the other", i)
            for s in c["simplify"] as! [[String: Any]] {
                let simplified = Clipper.simplifyPath(p, double(s["epsilon"]), isClosedPath: bool(s["closed"]))
                m.check(describe(simplified), describe(path(s["path"])), "simplified", i)
            }
            let r = c["rdp"] as! [String: Any]
            m.check(describe(Clipper.ramerDouglasPeucker(p, double(r["epsilon"]))), describe(path(r["path"])),
                    "simplified (Ramer-Douglas-Peucker)", i)
        }
        report(m, "helpers", of: all.count)
    }

    /// The order libstdc++'s std::sort leaves equal elements in (Clipper2 sorts each scanbeam's crossings with it)
    func testSorts() {
        let m = Mismatches(), all = cases("sorts")
        for (i, c) in all.enumerated() {
            let items = (c["points"] as! [[Any]]).enumerated().map { (Point64(int($0.element[0]), int($0.element[1])), $0.offset) }
            let less: ((Point64, Int), (Point64, Int)) -> Bool = { a, b in a.0.y == b.0.y ? a.0.x < b.0.x : a.0.y > b.0.y }
            var sorted = items
            Clipper.introSort(&sorted, less)
            m.check(sorted.map(\.1), (c["sorted"] as! [Any]).map(int), "std::sort", i)
            var heap = items
            Clipper.heapSort(&heap, 0, heap.count, less)
            m.check(heap.map(\.1), (c["heap"] as! [Any]).map(int), "the heap sort", i)
        }
        report(m, "sorts", of: all.count)
    }

    // MARK: - Reading the cases

    private func int(_ v: Any?) -> Int { (v as! NSNumber).intValue }
    private func bool(_ v: Any?) -> Bool { (v as! NSNumber).boolValue }
    /// (Foundation on Linux reads a number of 17 digits as an NSDecimalNumber, whose doubleValue can be a bit off;
    /// its digits read as a Double are the number the reference wrote)
    private func double(_ v: Any?) -> Double {
        if let d = v as? NSDecimalNumber, let x = Double(d.stringValue) { return x }
        return (v as! NSNumber).doubleValue
    }

    private func path(_ v: Any?) -> Clipper.Path64 {
        (v as! [[Any]]).map { Point64(int($0[0]), int($0[1]), int($0[2])) }
    }

    private func paths(_ v: Any?) -> Paths64 { (v as! [Any]).map(path) }

    private func calls(_ v: Any?) -> [[Int]] { (v as! [[Any]]).map { $0.map(int) } }

    /// Paths as lists of x, y and z (Point64's == leaves z out)
    private func describe(_ path: Clipper.Path64) -> [[Int]] { path.map { [$0.x, $0.y, $0.z] } }
    private func describe(_ paths: Paths64) -> [[[Int]]] { paths.map(describe) }
    private func describe(_ v: Any?) -> [[[Int]]] { describe(paths(v)) }

    /// A tree as text: each polygon's points (and whether it is a hole), and its children in braces
    private func describe(_ tree: Clipper.PolyPath64) -> String {
        tree.children.map { "\(describe($0.polygon))\($0.isHole ? " hole" : ""){\(describe($0))}" }.joined(separator: " ")
    }

    private func describe(tree v: Any?) -> String {
        (v as! [[String: Any]]).map {
            "\(describe(path($0["p"])))\(bool($0["h"]) ? " hole" : ""){\(describe(tree: $0["c"]))}"
        }.joined(separator: " ")
    }
}
