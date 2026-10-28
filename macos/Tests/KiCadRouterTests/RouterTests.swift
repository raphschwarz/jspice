import Foundation
import XCTest
@testable import KiCadRouter

/// The router against KiCad's own: Fixtures/kicad-routes.json holds boards with routes to make on them, and what
/// KiCad 10.0.7's router made of each (tools/kicad-reference/router.cpp, made by scenes.py); kicad-board-routes.json
/// the same on the boards of Fixtures/boards, as KiCad's router sees them (scenes.py --boards); kicad-shove-routes.json
/// routes that shove what is in their way (scenes.py --mode shove), with the board as the router has it after each
/// step, what it has shoved where; kicad-drag-routes.json and kicad-board-drag-routes.json tracks and vias dragged
/// (scenes.py --mode drag), with what the dragger dragged and the board as it has it after each step;
/// kicad-diffpair-routes.json and kicad-board-diffpair-routes.json differential pairs routed (scenes.py --mode
/// diffpair, on random boards and on Fixtures/pairboards), with the pair's two lines and the board as the router has
/// it after each step; kicad-arc-routes.json and kicad-board-arc-routes.json routes on boards with arc tracks (from
/// them, to them, walking round, shoving and marking), each in a corner mode of its own, rounded ones among them, and
/// kicad-arc-drag-routes.json and kicad-board-arc-drag-routes.json drags on such boards, arcs dragged among them
/// (scenes.py --arcs, --rounded, on random boards and on Fixtures/arcboards), the lines with their arcs;
/// kicad-meander-routes.json and kicad-board-meander-routes.json tracks' lengths tuned by KiCad's meander placer
/// (scenes.py --mode meander, on random boards with arc tracks and on Fixtures/boards), and kicad-dpmeander-routes.json
/// differential pairs' lengths and skews tuned (scenes.py --mode dpmeander), with the tuned lines, the tuning's status
/// and length, and the board as the placer has it after each step. The port must make the same, point for point.
/// KICAD_ROUTER_REFERENCE names other such files (separated by colons).
final class RouterTests: XCTestCase {
    private static let reference: [[String: Any]] = {
        let urls = ProcessInfo.processInfo.environment["KICAD_ROUTER_REFERENCE"].map {
            $0.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        } ?? ["kicad-routes", "kicad-board-routes", "kicad-shove-routes", "kicad-drag-routes",
              "kicad-board-drag-routes", "kicad-diffpair-routes", "kicad-board-diffpair-routes", "kicad-arc-routes",
              "kicad-arc-drag-routes", "kicad-board-arc-routes", "kicad-board-arc-drag-routes", "kicad-meander-routes",
              "kicad-board-meander-routes", "kicad-dpmeander-routes"].map {
            Bundle.module.url(forResource: $0, withExtension: "json", subdirectory: "Fixtures")!
        }
        return urls.flatMap { try! JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as! [[String: Any]] }
    }()

    override func setUp() {
        // (KICAD_ROUTER_DEBUG: the port's trace on standard error, as router.cpp writes KiCad's)
        if ProcessInfo.processInfo.environment["KICAD_ROUTER_DEBUG"] != nil {
            Router.trace = { FileHandle.standardError.write(($0 + "\n").data(using: .utf8)!) }
        }
    }

    func testRoutesAsKiCadRoutesThem() {
        var differences: [String] = []
        var routes = 0, identical = 0
        for (n, c) in Self.reference.enumerated() {
            let scene = c["scene"] as! [String: Any]
            let kicad = c["kicad"] as! [[String: Any]]
            let ours = SceneRouting.route(scene)
            XCTAssertEqual(ours.count, kicad.count, "scene \(n): routes")
            for (i, (o, k)) in zip(ours, kicad).enumerated() {
                routes += 1
                // (what a route added, in any order: KiCad lists it from a hash set)
                var o = o, k = k
                o["added"] = Self.sorted(o["added"])
                k["added"] = Self.sorted(k["added"])
                if let d = Self.difference(o, k, "scene \(n) (\(c["name"] ?? "")) route \(i)") {
                    differences.append(d)
                } else {
                    identical += 1
                }
            }
        }
        if let dump = ProcessInfo.processInfo.environment["KICAD_ROUTER_DUMP"] {
            // (for comparing by hand: ours, as router.cpp writes KiCad's)
            let all = Self.reference.map { SceneRouting.route($0["scene"] as! [String: Any]) }
            try? JSONSerialization.data(withJSONObject: all).write(to: URL(fileURLWithPath: dump))
        }
        XCTAssertGreaterThan(routes, 0)
        XCTAssertEqual(identical, routes, "\(routes - identical) of \(routes) routes differ from KiCad's:\n"
                       + differences.prefix(10).joined(separator: "\n"))
    }

    private static func sorted(_ v: Any?) -> [Any] {
        ((v as? [Any]) ?? []).sorted { compact($0) < compact($1) }
    }

    /// Where two JSON values first differ
    static func difference(_ a: Any, _ b: Any, _ path: String) -> String? {
        switch (a, b) {
        case let (a as [String: Any], b as [String: Any]):
            for key in Set(a.keys).union(b.keys).sorted() {
                guard let av = a[key] else { return "\(path).\(key): ours missing, KiCad's \(b[key]!)" }
                guard let bv = b[key] else { return "\(path).\(key): ours \(av), KiCad's missing" }
                if let d = difference(av, bv, "\(path).\(key)") { return d }
            }
            return nil
        case let (a as [Any], b as [Any]):
            if a.count != b.count { return "\(path): ours \(compact(a)), KiCad's \(compact(b))" }
            for (i, (x, y)) in zip(a, b).enumerated() {
                if let d = difference(x, y, "\(path)[\(i)]") { return a.count < 8 ? "\(path): ours \(compact(a)), KiCad's \(compact(b))" : d }
            }
            return nil
        default:
            return "\(a)" == "\(b)" || (a as? NSNumber)?.isEqual(b) == true ? nil : "\(path): ours \(a), KiCad's \(b)"
        }
    }

    private static func compact(_ v: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) else { return "\(v)" }
        return String(decoding: data, as: UTF8.self)
    }
}
