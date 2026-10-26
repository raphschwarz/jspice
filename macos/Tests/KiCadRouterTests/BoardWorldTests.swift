import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// The router's world of a real board against KiCad's: tools/kicad-reference/board-scene.py has KiCad (its pcbnew
/// module) read each board and write what its router's SyncWorld makes of it; BoardWorld, reading the same board
/// itself, must make the same items in the same order, with the same shapes to the nanometre and the same rules.
/// KICAD_BOARD_REFERENCE names a folder of boards (NAME.kicad_pcb, NAME.kicad_pro if it has one) and KiCad's scenes
/// of them (NAME.json); with none, Fixtures/boards and Fixtures/arcboards (boards with arc tracks).
final class BoardWorldTests: XCTestCase {
    private static var folders: [URL] {
        if let f = ProcessInfo.processInfo.environment["KICAD_BOARD_REFERENCE"] { return [URL(fileURLWithPath: f)] }
        return ["boards", "arcboards"].compactMap { Bundle.module.url(forResource: $0, withExtension: nil, subdirectory: "Fixtures") }
    }

    func testWorldsAsKiCadMakesThem() throws {
        guard !Self.folders.isEmpty else { throw XCTSkip("no boards") }
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
        var boards = 0, itemsCompared = 0, approximated = 0
        var differences: [String] = []
        for file in files {
            let sceneURL = file.deletingPathExtension().appendingPathExtension("json")
            guard let data = try? Data(contentsOf: sceneURL),
                  let kicad = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let pro = file.deletingPathExtension().appendingPathExtension("kicad_pro")
            let world = BoardWorld(board: try KiCadBoard.read(file),
                                   projectURL: FileManager.default.fileExists(atPath: pro.path) ? pro : nil)
            boards += 1
            let name = file.deletingPathExtension().lastPathComponent
            let names = (kicad["netNames"] as? [String: Any] ?? [:]).reduce(into: [Int: String]()) { $0[Int($1.key)!] = $1.value as? String }
            let theirs = (kicad["items"] as! [[String: Any]]).map { Self.named($0, names) }
            let ours = world.items.map { Self.named($0.scene, world.netNames) }
            let approximate = Set(world.items.indices.filter { world.items[$0].approximate })
            if ours.count != theirs.count {
                differences.append("\(name): \(ours.count) items, KiCad's \(theirs.count)")
            }
            for (i, (o, k)) in zip(ours, theirs).enumerated() {
                // (an item the port makes otherwise, knowingly: a custom pad with a curve among its pieces, a convex
                // outline round them all)
                if approximate.contains(i) {
                    approximated += 1
                    continue
                }
                itemsCompared += 1
                if let d = RouterTests.difference(o, k, "\(name) item \(i) (\(k["kind"] ?? ""))") {
                    differences.append(d)
                    break
                }
            }
            let ourRules = Self.namedRules(world.rules.scene, world.netNames)
            let theirRules = Self.namedRules(kicad["rules"] as! [String: Any], names)
            if let d = RouterTests.difference(ourRules, theirRules, "\(name) rules") { differences.append(d) }
            let unsupported = Set(kicad["unsupported"] as? [String] ?? []).union(world.unsupported)
            if !unsupported.isEmpty { print("BoardWorldTests: \(name): \(unsupported.sorted().joined(separator: ", "))") }
        }
        print("BoardWorldTests: \(boards) boards, \(itemsCompared) items compared, \(approximated) approximate")
        XCTAssertGreaterThan(boards, 0)
        XCTAssert(differences.isEmpty, "\(differences.count) of \(boards) boards differ from KiCad's (\(itemsCompared) items compared):\n"
                  + differences.prefix(12).joined(separator: "\n"))
    }

    /// An item with its net by name, as the two boards number nets each their own way
    static func named(_ item: [String: Any], _ names: [Int: String]) -> [String: Any] {
        var j = item
        if let n = j["net"] as? NSNumber { j["net"] = names[n.intValue] ?? "#\(n.intValue)" }
        return j
    }

    static func namedRules(_ rules: [String: Any], _ names: [Int: String]) -> [String: Any] {
        var r = rules
        if let nc = r["netClearance"] as? [String: Any] {
            r["netClearance"] = nc.reduce(into: [String: Any]()) { $0[names[Int($1.key)!] ?? $1.key] = $1.value }
        }
        return r
    }
}
