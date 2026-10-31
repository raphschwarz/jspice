import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// A board's stackup edited as Board Setup's Physical Stackup and Board Finish pages edit it (BoardEditing.setStackup):
/// on each board of Fixtures/stackups, each layer's thickness changed (now and then a dielectric's locked, or given a
/// sublayer), materials picked from KiCad's lists (their epsilon R and loss tangent with them) or named, colours,
/// the finish, impedance control and the edges, by random numbers of the board's own. Fixtures/stackupedits holds the
/// port's boards as KiCad read and wrote them again (tools/kicad-reference/stackups.py measure: pcbnew's LoadBoard and
/// SaveBoard), and the heights KiCad's DRC measured between their layers: the port's stackup and board thickness must
/// be what KiCad reads back, and its heights between layers (Stackup, which a length tuning counts for a via) KiCad's.
/// KICAD_STACKUP_EDIT_DUMP names a folder to write the port's boards to, for stackups.py measure.
final class StackupEditTests: XCTestCase {
    /// A splitmix64, seeded by the board's name
    struct Random {
        var state: UInt64
        init(_ name: String) { state = name.utf8.reduce(0x9E37_79B9_7F4A_7C15) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 } }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
        mutating func chance(_ p: Double) -> Bool { Double(next() % 1_000_000) / 1_000_000 < p }
    }

    /// The page's stackup with random edits of its own
    static func edited(_ page: BoardStackup, _ rng: inout Random) -> BoardStackup {
        var s = page
        for i in s.items.indices {
            let kind = s.items[i].kind
            switch kind {
            case .copper:
                s.items[i].sublayers[0].thickness = [17_500, 35_000, 70_000, rng.int(9...105) * 1000][rng.int(0...3)]
            case .dielectric:
                if rng.chance(0.25) { s.addSublayer(item: i) }
                for j in s.items[i].sublayers.indices {
                    s.items[i].sublayers[j].thickness = rng.int(50...900) * 1000
                    s.items[i].sublayers[j].thicknessLocked = rng.chance(0.2)
                    let materials = BoardStackup.materials(.dielectric)
                    if rng.chance(0.8) {
                        s.setMaterial(materials[rng.int(1...(materials.count - 1))].name, item: i, sublayer: j)
                    } else {
                        s.items[i].sublayers[j].material = "Own \(rng.int(1...9))"
                        s.items[i].sublayers[j].epsilonR = Double(rng.int(200...600)) / 100
                        s.items[i].sublayers[j].lossTangent = Double(rng.int(1...300)) / 10_000
                    }
                    if rng.chance(0.3) { s.items[i].sublayers[j].color = BoardStackup.colors(.dielectric)[rng.int(0...5)] }
                }
                s.items[i].typeName = rng.chance(0.5) ? "core" : "prepreg"
            case .solderMask:
                s.items[i].sublayers[0].thickness = rng.int(5...30) * 1000
                s.items[i].sublayers[0].color = rng.chance(0.2) ? "#20A060D0" : BoardStackup.colors(.solderMask)[rng.int(0...7)]
                s.setMaterial(BoardStackup.materials(.solderMask)[rng.int(0...3)].name, item: i)
            case .silkscreen:
                s.items[i].sublayers[0].color = BoardStackup.colors(.silkscreen)[rng.int(0...7)]
                s.setMaterial(BoardStackup.materials(.silkscreen)[rng.int(0...2)].name, item: i)
            case .solderPaste:
                break
            }
        }
        s.finish = BoardStackup.finishes[rng.int(0...(BoardStackup.finishes.count - 1))]
        s.dielectricConstraints = rng.chance(0.5)
        s.edgeConnector = rng.int(0...2)
        s.edgePlating = rng.chance(0.5)
        return s
    }

    func testEditedStackupsAreWhatKiCadReadsBack() throws {
        let base = try XCTUnwrap(Bundle.module.url(forResource: "stackups", withExtension: nil, subdirectory: "Fixtures"))
        let reference = try XCTUnwrap(Bundle.module.url(forResource: "stackupedits", withExtension: nil, subdirectory: "Fixtures"))
        let dump = ProcessInfo.processInfo.environment["KICAD_STACKUP_EDIT_DUMP"].map { URL(fileURLWithPath: $0) }
        var boards = 0, pairs = 0
        for file in try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "kicad_pcb" }).sorted(by: { $0.path < $1.path }) {
            let project = BoardEditingTests.project(file)
            let session = BoardEditing(board: try KiCadBoard.read(file), project: project)
            var rng = Random(file.lastPathComponent)
            let page = session.boardSetupStackup
            let edit = try XCTUnwrap(session.setStackup(Self.edited(page, &rng)), file.lastPathComponent)
            XCTAssertEqual(edit.name, "Edit Board Stackup")
            XCTAssertTrue(edit.setup)
            // (the page shows what was set, as it was set)
            XCTAssertEqual(session.boardSetupStackup.node?.compact, session.board.root["setup"]?["stackup"]?.compact)
            if let dump {
                try session.board.write(to: dump.appendingPathComponent(file.lastPathComponent))
                if let project {
                    try JSONSerialization.data(withJSONObject: project).write(to: dump.appendingPathComponent(file.deletingPathExtension()
                        .appendingPathExtension("kicad_pro").lastPathComponent))
                }
            }
            let kicadFile = reference.appendingPathComponent(file.lastPathComponent)
            guard FileManager.default.fileExists(atPath: kicadFile.path) else { continue }
            let kicad = try KiCadBoard.read(kicadFile)
            let what = file.lastPathComponent
            XCTAssertEqual(session.board.root["setup"]?["stackup"]?.compact, kicad.root["setup"]?["stackup"]?.compact, "\(what): the stackup")
            XCTAssertEqual(session.board.root["general"]?["thickness"]?.compact, kicad.root["general"]?["thickness"]?.compact,
                           "\(what): the board's thickness")
            let world = BoardWorld(board: session.board, project: project)
            let measured = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: kicadFile.deletingPathExtension()
                .appendingPathExtension("stackup"))) as? [String: Any])
            for h in measured["heights"] as? [[String: Any]] ?? [] {
                let names = try XCTUnwrap(h["layers"] as? [String])
                let a = try XCTUnwrap(world.layerIndex[names[0]]), b = try XCTUnwrap(world.layerIndex[names[1]])
                // (the DRC's length to the nearest tenth of a micrometre)
                XCTAssertEqual(Double(world.stackupHeights[a][b]), try XCTUnwrap(h["height"] as? NSNumber).doubleValue, accuracy: 50,
                               "\(what): \(names[0]) to \(names[1])")
                pairs += 1
            }
            boards += 1
        }
        XCTAssertGreaterThan(boards, 0)
        XCTAssertGreaterThan(pairs, 0)
    }
}
