import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// Each copper layer's copper as KiCad's sliver check makes it, against the port's: tools/kicad-reference/copper.py
/// has KiCad make it (each item's TransformShapeToPolygon in forEachGeometryItem's order, zones' fills, united by
/// SHAPE_POLY_SET::Simplify; NAME.copper next to NAME.kicad_pcb: each layer's polygons, outline and holes, their
/// points), and BoardDRC.copperLayerPolygons must give the same, point for point. KICAD_BOARD_REFERENCE names a folder
/// of such boards (or several, separated by colons); with none, Fixtures/boards and Fixtures/copper (copper of the
/// kinds random boards do not have: texts, curves, rounded rectangles, footprints' drawings turned off square, blind
/// vias, a custom pad).
final class CopperTests: XCTestCase {
    private static var folders: [URL] {
        if let f = ProcessInfo.processInfo.environment["KICAD_BOARD_REFERENCE"] {
            return f.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        return ["boards", "copper"].compactMap { Bundle.module.url(forResource: $0, withExtension: nil, subdirectory: "Fixtures") }
    }

    func testLayersUnitedAsKiCadUnitesThem() throws {
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
        var boards = 0, layers = 0, polygons = 0, points = 0, unsupported = 0
        var differences: [String] = []
        for file in files {
            let ref = file.deletingPathExtension().appendingPathExtension("copper")
            guard let data = try? Data(contentsOf: ref),
                  let theirs = try JSONSerialization.jsonObject(with: data) as? [String: [[[[NSNumber]]]]] else { continue }
            let pro = file.deletingPathExtension().appendingPathExtension("kicad_pro")
            let drc = BoardDRC(board: try KiCadBoard.read(file), projectURL: FileManager.default.fileExists(atPath: pro.path) ? pro : nil)
            let copper = drc.makeCopper()
            boards += 1
            let name = file.deletingPathExtension().lastPathComponent
            for (layerName, kicad) in theirs.sorted(by: { $0.key < $1.key }) {
                guard let l = drc.world.layerIndex[layerName] else {
                    differences.append("\(name) \(layerName): no such copper layer in the port")
                    continue
                }
                guard let ours = drc.copperLayerPolygons(copper, l) else {
                    unsupported += 1
                    continue
                }
                layers += 1
                let k = kicad.map { $0.map { $0.map { IPoint($0[0].intValue, $0[1].intValue) } } }
                let o = ours.polygons.map { $0.map(\.points) }
                polygons += k.count
                points += k.joined().map(\.count).reduce(0, +)
                if k != o {
                    let first = zip(k, o).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                    differences.append("\(name) \(layerName): KiCad's \(k.count) polygons, ours \(o.count)"
                                       + (first.map { ", first different #\($0)" } ?? ""))
                }
            }
        }
        print("CopperTests: \(boards) boards, \(layers) layers (\(unsupported) the port does not make), \(polygons) polygons, \(points) points")
        XCTAssertTrue(differences.isEmpty, "\(differences.count) layers differ from KiCad's:\n" + differences.prefix(30).joined(separator: "\n"))
    }
}
