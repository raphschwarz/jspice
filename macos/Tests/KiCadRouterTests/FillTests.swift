import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// The zones' fills as KiCad's zone filler makes them, against the port's: tools/kicad-reference/fills.py has KiCad
/// fill each board's zones (pcbnew.ZONE_FILLER(board).Fill(board.Zones()); NAME.fills next to NAME.kicad_pcb: each
/// zone's polygons on each of its layers, outline and holes, their points, and whether KiCad keeps it as an island),
/// and ZoneFiller must make the same, polygon for polygon, point for point. KICAD_BOARD_REFERENCE names a folder of
/// such boards (or several, separated by colons); with none, Fixtures/fills (a board drawn by fills.py --draw to take
/// the filler down the ways random boards do not, and one by --draw-open whose edges do not close). FILL_BOARD keeps
/// to the boards whose names contain it; FILL_DUMP names a folder to write the port's fills and their stages to.
final class FillTests: XCTestCase {
    private static var folders: [URL] {
        if let f = ProcessInfo.processInfo.environment["KICAD_BOARD_REFERENCE"] {
            return f.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        return ["fills"].compactMap { Bundle.module.url(forResource: $0, withExtension: nil, subdirectory: "Fixtures") }
    }

    func testZonesFilledAsKiCadFillsThem() throws {
        let only = ProcessInfo.processInfo.environment["FILL_BOARD"]
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "kicad_pcb" && (only == nil || $0.lastPathComponent.contains(only!)) }
            .sorted { $0.path < $1.path }
        var boards = 0, zones = 0, layers = 0, polygons = 0, points = 0, unsupportedBoards = 0
        var differences: [String] = []
        var unsupported: [String: Int] = [:]
        for file in files {
            let ref = file.deletingPathExtension().appendingPathExtension("fills")
            guard let data = try? Data(contentsOf: ref),
                  let theirs = try JSONSerialization.jsonObject(with: data) as? [String: [String: [[String: Any]]]] else { continue }
            let pro = file.deletingPathExtension().appendingPathExtension("kicad_pro")
            let project = (try? Data(contentsOf: pro)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            var stages: [[String: Any]] = []
            let dumping = ProcessInfo.processInfo.environment["FILL_DUMP"] != nil
            let board = try KiCadBoard.read(file)
            let filler = ZoneFiller(board: board, project: project, debug: dumping ? { stage, zone, set in
                stages.append(["stage": stage, "zone": zone.uuid, "polygons": set.polygons.map { $0.map { $0.points.map { [$0.x, $0.y] } } }])
            } : nil)
            boards += 1
            let name = file.deletingPathExtension().lastPathComponent
            if let dump = ProcessInfo.processInfo.environment["FILL_DUMP"] {
                // (the port's fills, as fills.py writes KiCad's, for looking into a difference)
                var out: [String: [String: [[String: Any]]]] = [:]
                for (uuid, layers) in filler.fills {
                    var l: [String: [[String: Any]]] = [:]
                    for (layer, set) in layers {
                        l[layer] = set.polygons.enumerated().map { i, poly in
                            ["polygon": poly.map { $0.points.map { [$0.x, $0.y] } },
                             "island": filler.islands[uuid]?[layer]?.contains(i) == true]
                        }
                    }
                    out[uuid] = l
                }
                let json = try JSONSerialization.data(withJSONObject: out)
                try json.write(to: URL(fileURLWithPath: dump).appendingPathComponent(name + ".ours"))
                try JSONSerialization.data(withJSONObject: stages).write(to: URL(fileURLWithPath: dump).appendingPathComponent(name + ".stages"))
            }
            var notMade = filler.unsupported
            if FileManager.default.fileExists(atPath: file.deletingPathExtension().appendingPathExtension("kicad_dru").path) {
                notMade.insert("design rules file")
            }
            if !notMade.isEmpty {
                unsupportedBoards += 1
                for u in notMade { unsupported[u, default: 0] += 1 }
                continue
            }
            // the fills written back as KiCad writes them, and read again
            var written: [String: [String: [[IPoint]]]] = [:]
            for (n, node) in filler.refilledBoard(board).root.all("zone").enumerated() {
                let uuid = ZoneFiller.zoneKey(node, n)
                for fill in node.all("filled_polygon") {
                    let pts = (fill["pts"]?.arguments ?? []).filter { $0.head == "xy" }.map { BoardWorld.point($0) }
                    written[uuid, default: [:]][fill.value("layer") ?? "", default: []].append(pts)
                }
            }
            for (uuid, kicadLayers) in theirs.sorted(by: { $0.key < $1.key }) {
                zones += 1
                guard let ours = filler.fills[uuid] else {
                    differences.append("\(name) zone \(uuid): not filled by the port")
                    continue
                }
                for (layerName, kicad) in kicadLayers.sorted(by: { $0.key < $1.key }) {
                    layers += 1
                    let k = kicad.map { ($0["polygon"] as? [[[NSNumber]]] ?? []).map { $0.map { IPoint($0[0].intValue, $0[1].intValue) } } }
                    let kIslands = kicad.enumerated().filter { ($0.element["island"] as? Bool) == true }.map(\.offset)
                    let o = (ours[layerName] ?? PolySet()).polygons.map { $0.map(\.points) }
                    let oIslands = (0..<o.count).filter { filler.islands[uuid]?[layerName]?.contains($0) == true }
                    polygons += k.count
                    points += k.joined().map(\.count).reduce(0, +)
                    if k != o {
                        let first = zip(k, o).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                        var detail = ""
                        if let f = first {
                            let kp = k[f].first ?? [], op = o[f].first ?? []
                            detail = ", first different #\(f) (KiCad's \(kp.count) points, ours \(op.count)"
                            if let d = zip(kp, op).enumerated().first(where: { $0.element.0 != $0.element.1 }) {
                                detail += ", from point \(d.offset): \(d.element.0) against \(d.element.1)"
                            }
                            detail += ")"
                        }
                        differences.append("\(name) zone \(uuid) \(layerName): KiCad's \(k.count) polygons, ours \(o.count)\(detail)")
                    } else if kIslands != oIslands {
                        differences.append("\(name) zone \(uuid) \(layerName): KiCad's islands \(kIslands), ours \(oIslands)")
                    } else if (written[uuid]?[layerName] ?? []) != k.map({ $0[0] }) {
                        differences.append("\(name) zone \(uuid) \(layerName): not written back as made")
                    }
                }
            }
        }
        print("FillTests: \(boards) boards (\(unsupportedBoards) with what the port does not make: \(unsupported.sorted { $0.key < $1.key })), "
              + "\(zones) zones, \(layers) zone layers, \(polygons) polygons, \(points) points; \(differences.count) differ")
        XCTAssertTrue(differences.isEmpty, "\(differences.count) fills differ from KiCad's:\n" + differences.prefix(40).joined(separator: "\n"))
    }
}
