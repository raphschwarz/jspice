import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// What a box drawn on the board selects, the port's (BoxSelection) against KiCad's:
/// tools/kicad-reference/boxes.py draws rectangles on each board and asks KiCad which tracks, arcs, vias and footprints
/// each takes, wholly in it and touched by it (their HitTest( BOX2I, aContained ), NAME.boxes next to
/// NAME.kicad_pcb); the port must take the same. KICAD_BOARD_REFERENCE names a folder of such boards (or several,
/// separated by colons); with none, Fixtures/boards, arcboards, courtyards and silk (footprints of drawings of every
/// kind).
final class BoxSelectionTests: XCTestCase {
    private static var folders: [URL] {
        if let f = ProcessInfo.processInfo.environment["KICAD_BOARD_REFERENCE"] {
            return f.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        return ["boards", "arcboards", "courtyards", "silk"].compactMap { Bundle.module.url(forResource: $0, withExtension: nil, subdirectory: "Fixtures") }
    }

    func testBoxesSelectAsKiCadsDo() throws {
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
        var boards = 0, boxes = 0, taken = 0, differences: [String] = []
        for file in files {
            let reference = file.deletingPathExtension().appendingPathExtension("boxes")
            guard let data = try? Data(contentsOf: reference),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let board = try KiCadBoard(text: String(contentsOf: file, encoding: .utf8))
            let selection = BoxSelection(board: board)
            let kinds = Dictionary(board.root.items.compactMap { n in n.value("uuid").map { ($0, n.head ?? "") } }
                                   + board.footprints.map { ($0.uuid, "footprint \($0.reference)") }, uniquingKeysWith: { _, b in b })
            boards += 1
            for entry in json["boxes"] as? [[String: Any]] ?? [] {
                let b = (entry["box"] as? [NSNumber] ?? []).map(\.intValue)
                let box = IBox(minX: b[0], minY: b[1], maxX: b[2], maxY: b[3])
                boxes += 1
                for (key, touching) in [("inside", false), ("touching", true)] {
                    let theirs = Set(entry[key] as? [String] ?? [])
                    let ours = Set(selection.items(in: box, touching: touching))
                    taken += theirs.count
                    for uuid in theirs.symmetricDifference(ours).sorted() {
                        differences.append("\(file.lastPathComponent) \(b) \(key): \(kinds[uuid] ?? uuid) \(theirs.contains(uuid) ? "KiCad's only" : "ours only")")
                    }
                }
            }
        }
        print("box selection: \(boards) boards, \(boxes) boxes, \(taken) items taken by KiCad, \(differences.count) differences")
        XCTAssertGreaterThan(boxes, 0)
        XCTAssertEqual(differences, [], differences.prefix(40).joined(separator: "\n"))
    }
}
