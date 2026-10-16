import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// Routing on real boards checked by KiCad's own design rules check: pads of a net joined with BoardRouter (start on
/// one, the pointer to the other, fixed there), the board written, and kicad-cli's DRC run on it; no clearance,
/// crossing, short or size violation may involve a track or via the router put there. The boards are those of
/// KICAD_BOARD_REFERENCE (boards.py's), or Fixtures/boards; it needs kicad-cli (JSPICE_REQUIRE_KICAD: fail without).
final class BoardRoutingTests: XCTestCase {
    /// The violations a router must not cause (KiCad's DRC error keys)
    static let routerViolations: Set<String> = ["clearance", "hole_clearance", "copper_edge_clearance", "hole_to_hole",
                                                "tracks_crossing", "shorting_items", "track_width", "via_diameter",
                                                "annular_width", "drill_out_of_range", "holes_co_located"]

    func testRoutesPassKiCadsDRC() throws {
        let env = ProcessInfo.processInfo.environment
        guard let kicad = KiCadInstallation.find(), kicad.major >= KiCadInstallation.minimumMajor else {
            if env["JSPICE_REQUIRE_KICAD"] != nil { return XCTFail("KiCad 10's kicad-cli is needed") }
            throw XCTSkip("no kicad-cli")
        }
        guard let folder = env["KICAD_BOARD_REFERENCE"].map(URL.init(fileURLWithPath:))
                ?? Bundle.module.url(forResource: "boards", withExtension: nil, subdirectory: "Fixtures") else { throw XCTSkip("no boards") }
        let limit = Int(env["KICAD_DRC_BOARDS"] ?? "") ?? 24
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }.prefix(limit)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var routes = 0, finished = 0, placed = 0
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
            let report = try KiCadFabrication(installation: kicad).drc(copy, refillZones: false)
            if let control {
                XCTAssert(report.violations.contains { Self.routerViolations.contains($0.type) && $0.items.contains { $0.uuid == control } },
                          "the check did not find the control track")
            }
            for v in report.violations where Self.routerViolations.contains(v.type) && v.items.contains(where: { added.contains($0.uuid) }) {
                bad.append("\(name): \(v.type): \(v.description) — \(v.items.map(\.description).joined(separator: "; "))")
            }
        }
        print("BoardRoutingTests: \(files.count) boards, \(routes) routes tried, \(finished) finished, \(placed) tracks and vias placed")
        XCTAssertGreaterThan(placed, 0)
        XCTAssert(bad.isEmpty, "\(bad.count) violations of KiCad's DRC by routed tracks:\n" + bad.prefix(10).joined(separator: "\n"))
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
