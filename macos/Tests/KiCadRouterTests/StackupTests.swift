import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// The board's thickness between its copper layers as KiCad's length calculation counts it for a via (Stackup, the
/// port of BOARD_STACKUP::GetLayerDistance and LENGTH_DELAY_CALCULATION::StackupHeight), against KiCad's own:
/// Fixtures/stackups holds boards of random stackups (tools/kicad-reference/stackups.py: their own, or KiCad's default
/// for their thickness and layers), each with what kicad-cli's DRC measured of a via between each pair of its layers
/// (BOARD.stackup), to the tenth of a micrometre the DRC writes lengths to; KICAD_STACKUP_REFERENCE names another
/// folder of them. A length tuning of a path through a via counts what the port finds here.
final class StackupTests: XCTestCase {
    func testViaHeightsAreKiCads() throws {
        let folder = try ProcessInfo.processInfo.environment["KICAD_STACKUP_REFERENCE"].map { URL(fileURLWithPath: $0) }
            ?? XCTUnwrap(Bundle.module.url(forResource: "stackups", withExtension: nil, subdirectory: "Fixtures"))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
        XCTAssertFalse(files.isEmpty)
        var pairs = 0
        for file in files {
            let world = BoardWorld(board: try KiCadBoard.read(file), project: BoardEditingTests.project(file))
            let kicad = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file.deletingPathExtension()
                .appendingPathExtension("stackup"))) as? [String: Any])
            for h in kicad["heights"] as? [[String: Any]] ?? [] {
                let names = h["layers"] as! [String]
                let a = try XCTUnwrap(world.layerIndex[names[0]]), b = try XCTUnwrap(world.layerIndex[names[1]])
                // (the DRC's length to the nearest tenth of a micrometre)
                XCTAssertEqual(Double(world.stackupHeights[a][b]), (h["height"] as! NSNumber).doubleValue, accuracy: 50,
                               "\(file.lastPathComponent): \(names[0]) to \(names[1])")
                pairs += 1
            }
        }
        print("StackupTests: \(pairs) pairs of layers on \(files.count) boards")
    }
}
