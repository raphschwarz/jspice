import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// Routing on real boards checked by KiCad's own design rules check: pads of a net joined with BoardRouter (start on
/// one, the pointer to the other, fixed there), the board written, and kicad-cli's DRC run on it; no clearance,
/// crossing, short or size violation may involve a track or via the router put there. The boards are those of
/// KICAD_BOARD_REFERENCE (boards.py's), or Fixtures/boards; it needs kicad-cli (JSPICE_REQUIRE_KICAD: fail without).
/// And the same on Fixtures/arcboards (boards.py --arcs), with arc tracks on them, routed with rounded corners: the
/// arcs the router puts on written into the board as KiCad writes arc tracks, which its DRC reads.
final class BoardRoutingTests: XCTestCase {
    /// The violations a router must not cause (KiCad's DRC error keys)
    static let routerViolations: Set<String> = ["clearance", "hole_clearance", "copper_edge_clearance", "hole_to_hole",
                                                "tracks_crossing", "shorting_items", "track_width", "via_diameter",
                                                "annular_width", "drill_out_of_range", "holes_co_located"]

    func testRoutesPassKiCadsDRC() throws {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["KICAD_BOARD_REFERENCE"].map(URL.init(fileURLWithPath:))
                ?? Bundle.module.url(forResource: "boards", withExtension: nil, subdirectory: "Fixtures") else { throw XCTSkip("no boards") }
        try check(folder, cornerModes: [.mitered45])
    }

    /// On boards with arc tracks, each route in a corner mode of its own, rounded ones among them: the arcs it puts on
    /// are in the board as KiCad writes them, and pass its DRC as the segments do
    func testRoundedRoutesPassKiCadsDRC() throws {
        guard let folder = Bundle.module.url(forResource: "arcboards", withExtension: nil, subdirectory: "Fixtures") else {
            throw XCTSkip("no boards")
        }
        let arcs = try check(folder, cornerModes: [.rounded45, .mitered45, .rounded90, .rounded45, .mitered90])
        XCTAssertGreaterThan(arcs, 0, "no arcs put on")
    }

    /// Routes on the boards of `folder`, each in the next of `cornerModes`, checked by KiCad's DRC; the arcs put on
    @discardableResult
    func check(_ folder: URL, cornerModes: [Direction45.CornerMode]) throws -> Int {
        let env = ProcessInfo.processInfo.environment
        guard let kicad = KiCadInstallation.find(), kicad.major >= KiCadInstallation.minimumMajor else {
            if env["JSPICE_REQUIRE_KICAD"] != nil { XCTFail("KiCad 10's kicad-cli is needed"); return 0 }
            throw XCTSkip("no kicad-cli")
        }
        let limit = Int(env["KICAD_DRC_BOARDS"] ?? "") ?? 24
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }.prefix(limit)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var routes = 0, finished = 0, placed = 0, touching = 0, arcs = 0
        var bad: [String] = []
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let copy = work.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: copy)
            let pro = file.deletingPathExtension().appendingPathExtension("kicad_pro")
            var project: [String: Any]?
            if FileManager.default.fileExists(atPath: pro.path) {
                try FileManager.default.copyItem(at: pro, to: copy.deletingPathExtension().appendingPathExtension("kicad_pro"))
                project = try JSONSerialization.jsonObject(with: Data(contentsOf: pro)) as? [String: Any]
            }
            let board = try KiCadBoard.read(copy)
            let router = BoardRouter(board: board, project: project)
            var added = Set<String>()
            for (a, b, layer) in Self.pairs(router.world, seed: name) {
                router.cornerMode = cornerModes[routes % cornerModes.count]
                routes += 1
                guard router.start(at: a, layer: layer) else { continue }
                // the pointer from one pad to the other, a little off the straight line on the way
                for k in 1...3 {
                    let t = Double(k) / 4
                    let off = IPoint(k == 2 ? 600_000 : -300_000, k == 1 ? 400_000 : -200_000)
                    router.move(to: IPoint(a.x + Int(Double(b.x - a.x) * t), a.y + Int(Double(b.y - a.y) * t)) + off)
                }
                router.move(to: b)
                if router.fix(at: b) { finished += 1 }
                router.commit()
                added.formUnion(router.lastAdded)
                placed += router.lastAdded.count
            }
            // (a control, on the first board: a track straight from a pad to one of another net, which the check
            // must find)
            var control: String?
            if file == files.first, let (a, b) = Self.otherNets(router.world) {
                let uuid = KiCadBoard.newUUID()
                board.root.items.append(SExpr("segment", SExpr("start", Double(a.x) / 1e6, Double(a.y) / 1e6),
                                              SExpr("end", Double(b.x) / 1e6, Double(b.y) / 1e6), SExpr("width", 0.25),
                                              SExpr("layer", "F.Cu"), SExpr("net", ""), SExpr("uuid", uuid)))
                control = uuid
            }
            try board.write(to: copy)
            // (the arcs put on, in the file written as KiCad writes an arc track: its start, mid and end, width, layer,
            // net and uuid)
            for node in try KiCadBoard.read(copy).copperItems where node.head == "arc" && added.contains(node.value("uuid") ?? "") {
                XCTAssertEqual(node.arguments.compactMap(\.head), ["start", "mid", "end", "width", "layer", "net", "uuid"])
                arcs += 1
            }
            let report = try KiCadFabrication(installation: kicad).drc(copy, refillZones: false)
            if let control {
                XCTAssert(report.violations.contains { Self.routerViolations.contains($0.type) && $0.items.contains { $0.uuid == control } },
                          "the check did not find the control track")
            }
            // (a violation the control is in is the control's, though it crosses a routed track)
            var wrong = report.violations.filter { v in
                Self.routerViolations.contains(v.type) && v.items.contains { added.contains($0.uuid) } && !v.items.contains { $0.uuid == control }
            }
            // (a board whose hole clearance is 0: KiCad's router takes tracks along a hole's very edge, and its DRC
            // finds them touching it, "actual < 0", by rounding; KiCad's router does the same on these boards, route
            // for route. Those only touching are counted apart; one that cuts into a hole is wrong.)
            wrong.removeAll { v in
                guard v.type == "hole_clearance", v.description.contains("hole clearance 0 mm"),
                      let overlap = Self.holeOverlap(v, board: board, world: router.world), overlap < 1_000 else { return false }
                touching += 1
                return true
            }
            for v in wrong {
                bad.append("\(name): \(v.type): \(v.description) — \(v.items.map(\.description).joined(separator: "; "))")
            }
            // (KICAD_DRC_KEEP: the boards routed wrong kept there, the original beside the routed one, to look at)
            if !wrong.isEmpty, let keep = env["KICAD_DRC_KEEP"].map(URL.init(fileURLWithPath:)) {
                try? FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
                for (from, to) in [(file, name + ".kicad_pcb"), (pro, name + ".kicad_pro"), (copy, name + "-routed.kicad_pcb"),
                                   (file.deletingPathExtension().appendingPathExtension("json"), name + ".json")] {
                    try? FileManager.default.copyItem(at: from, to: keep.appendingPathComponent(to))
                }
            }
        }
        print("BoardRoutingTests: \(files.count) boards, \(routes) routes tried, \(finished) finished, \(placed) tracks and vias placed"
              + (arcs > 0 ? " (\(arcs) arcs)" : "")
              + (touching > 0 ? ", \(touching) along a hole's edge at a hole clearance of 0" : ""))
        XCTAssertGreaterThan(placed, 0)
        XCTAssert(bad.isEmpty, "\(bad.count) violations of KiCad's DRC by routed tracks:\n" + bad.prefix(10).joined(separator: "\n"))
        return arcs
    }

    /// Pads of the same net to join, and a layer both are on (up to five pairs a board, chosen by its name)
    static func pairs(_ world: BoardWorld, seed: String) -> [(IPoint, IPoint, Int)] {
        var rng = SplitMix(seed: UInt64(truncatingIfNeeded: seed.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) }))
        let pads = world.items.filter { $0.kind == .pad && ($0.net ?? 0) != 0 && !$0.npth && $0.pos != nil }
        let byNet = Dictionary(grouping: pads) { $0.net! }.values.filter { $0.count >= 2 }.sorted { ($0[0].net ?? 0) < ($1[0].net ?? 0) }
        var out: [(IPoint, IPoint, Int)] = []
        for group in byNet {
            guard out.count < 5 else { break }
            let i = Int(rng.next() % UInt64(group.count))
            var j = Int(rng.next() % UInt64(group.count))
            if j == i { j = (i + 1) % group.count }
            let a = group[i], b = group[j]
            let common = (0..<world.copperLayers).filter { l in
                [a, b].allSatisfy { $0.layers.start <= l && l <= $0.layers.end && ($0.flashed.isEmpty || $0.flashed[l]) }
            }
            guard let layer = common.first else { continue }
            out.append((a.pos!, b.pos!, layer))
        }
        return out
    }

    /// How far (nm) a track of a hole clearance violation cuts into the hole: the track's distance from the hole's
    /// own centre line, less their half widths (nil: not a track and a pad's hole)
    static func holeOverlap(_ v: KiCadFabrication.Violation, board: KiCadBoard, world: BoardWorld) -> Int? {
        var track: SExpr?
        var hole: Shape?
        for item in v.items {
            if let node = board.copperItems.first(where: { $0.value("uuid") == item.uuid && $0.head == "segment" }) { track = node }
            if let w = world.items.first(where: { $0.source == item.uuid && $0.hole != nil }) { hole = w.hole }
        }
        guard let track, let hole, let s = track["start"], let e = track["end"],
              let w = track["width"]?.number(at: 0) else { return nil }
        func nm(_ x: Double?) -> Int { Int(((x ?? 0) * 1e6).rounded()) }
        let seg = Seg(IPoint(nm(s.number(at: 0)), nm(s.number(at: 1))), IPoint(nm(e.number(at: 0)), nm(e.number(at: 1))))
        let half = nm(w) / 2
        switch hole {
        case .circle(let c, let r): return r + half - seg.distance(c)
        case .segment(let h, let width): return width / 2 + half - seg.distance(h)
        default: return nil
        }
    }

    /// Two front pads of different nets
    static func otherNets(_ world: BoardWorld) -> (IPoint, IPoint)? {
        let pads = world.items.filter { $0.kind == .pad && ($0.net ?? 0) != 0 && $0.layers.start == 0 && $0.pos != nil }
        guard let a = pads.first, let b = pads.first(where: { $0.net != a.net }) else { return nil }
        return (a.pos!, b.pos!)
    }

    /// A small deterministic generator (SplitMix64)
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
