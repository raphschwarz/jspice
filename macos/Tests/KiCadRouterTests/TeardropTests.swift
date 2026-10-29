import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// The teardrops KiCad's teardrop manager makes, against the port's: tools/kicad-reference/teardrops.py has kicad-cli
/// make each board's teardrops (its zones refilled, which has TEARDROP_MANAGER::UpdateTeardrops make them all again
/// first; with --random, after setting random teardrop settings as KiCad's Set Teardrops dialog sets them), and writes
/// NAME.teardrops next to NAME.kicad_pcb: the settings, each teardrop (its layer, net, type, priority, outline, fill,
/// and what it is connected with), every other zone's fill as kicad-cli made it, and the order it wrote the zones in.
/// Teardrops must make the same teardrops, point for point (KiCad writes them without the uuids it orders them by, so
/// each of KiCad's is found among the port's by its outline), the board with the port's teardrops must have its zones
/// in KiCad's order and, filled by ZoneFiller, the same fills as KiCad's of its own, and BoardEditing must add and take
/// them away as one change. KICAD_BOARD_REFERENCE and KICAD_TEARDROP_REFERENCE name folders of such boards (each
/// several, separated by colons: the second for boards of teardrops.py --boards, which have no other references);
/// with neither, Fixtures/teardrops. TEARDROP_BOARD keeps to the boards whose names contain it.
final class TeardropTests: XCTestCase {
    private static var folders: [URL] {
        let env = ProcessInfo.processInfo.environment
        let named = [env["KICAD_BOARD_REFERENCE"], env["KICAD_TEARDROP_REFERENCE"]].compactMap { $0 }
        if !named.isEmpty {
            return named.flatMap { $0.split(separator: ":") }.map { URL(fileURLWithPath: String($0)) }
        }
        return ["teardrops"].compactMap { Bundle.module.url(forResource: $0, withExtension: nil, subdirectory: "Fixtures") }
    }

    private struct Reference {
        var name: String
        var board: KiCadBoard
        var project: [String: Any]?
        var settings: TeardropSettings
        var teardrops: [[String: Any]]
        var fills: [String: [String: [[String: Any]]]]
        /// The order KiCad wrote the board's zones in, where the reference has it
        var order: [String]?
    }

    static func parameters(_ d: [String: Any]?) -> TeardropParameters {
        guard let d else { return TeardropParameters() }
        func int(_ k: String) -> Int { (d[k] as? NSNumber)?.intValue ?? 0 }
        func double(_ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
        func bool(_ k: String) -> Bool { (d[k] as? NSNumber)?.boolValue ?? false }
        return TeardropParameters(maxLength: int("maxLength"), maxWidth: int("maxWidth"), bestLengthRatio: double("bestLengthRatio"),
                                  bestWidthRatio: double("bestWidthRatio"), widthToSizeFilterRatio: double("widthToSizeFilterRatio"),
                                  curvedEdges: bool("curvedEdges"), enabled: bool("enabled"), allowTwoSegments: bool("allowTwoSegments"),
                                  onPadsInZones: bool("onPadsInZones"))
    }

    /// The boards with references, each with the settings teardrops.py set applied as the port applies them
    private func references() throws -> [Reference] {
        let only = ProcessInfo.processInfo.environment["TEARDROP_BOARD"]
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "kicad_pcb" && (only == nil || $0.lastPathComponent.contains(only!)) }
            .sorted { $0.path < $1.path }
        var out: [Reference] = []
        for file in files {
            let ref = file.deletingPathExtension().appendingPathExtension("teardrops")
            guard let data = try? Data(contentsOf: ref), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let pro = file.deletingPathExtension().appendingPathExtension("kicad_pro")
            let project = (try? Data(contentsOf: pro)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let board = try KiCadBoard.read(file)
            var settings = TeardropSettings(project: project)
            if let s = json["settings"] as? [String: Any] {
                settings = TeardropSettings(round: Self.parameters(s["round"] as? [String: Any]), rect: Self.parameters(s["rect"] as? [String: Any]),
                                            track: Self.parameters(s["track"] as? [String: Any]), vias: (s["vias"] as? Bool) ?? false,
                                            pthPads: (s["pthPads"] as? Bool) ?? false, smdPads: (s["smdPads"] as? Bool) ?? false,
                                            trackToTrack: (s["trackToTrack"] as? Bool) ?? false)
                settings = Teardrops.applySettings(settings, to: board)
            }
            out.append(Reference(name: file.deletingPathExtension().lastPathComponent, board: board, project: project, settings: settings,
                                 teardrops: json["teardrops"] as? [[String: Any]] ?? [],
                                 fills: json["fills"] as? [String: [String: [[String: Any]]]] ?? [:], order: json["order"] as? [String]))
        }
        return out
    }

    static func points(_ any: Any?) -> [IPoint] {
        (any as? [[NSNumber]] ?? []).map { IPoint($0[0].intValue, $0[1].intValue) }
    }

    static func polygons(_ any: [[String: Any]]) -> [[[IPoint]]] {
        any.map { ($0["polygon"] as? [Any] ?? []).map { points($0) } }
    }

    /// A teardrop's outline as KiCad reads it back from the file (SHAPE_LINE_CHAIN::SetClosed( true ), which takes a
    /// last point that is the first away); KiCad's references are of the board it saved, read again
    static func asRead(_ outline: [IPoint]) -> [IPoint] {
        outline.count > 1 && outline.first == outline.last ? Array(outline.dropLast()) : outline
    }

    /// Each of KiCad's teardrops, the index of the port's with the same layer and outline (nil for none)
    static func match(_ kicad: [[String: Any]], _ ours: [Teardrops.Teardrop]) -> [Int?] {
        var used = Set<Int>()
        return kicad.map { k in
            let layer = k["layer"] as? String ?? "", outline = points(k["outline"])
            let i = ours.indices.first { !used.contains($0) && ours[$0].layer == layer && Self.asRead(ours[$0].outline) == outline }
            guard let i else { return nil }
            used.insert(i)
            return i
        }
    }

    func testTeardropsMadeAsKiCadMakesThem() throws {
        var boards = 0, teardrops = 0, points = 0, unsupportedBoards = 0, narrowed = 0, notFitted = 0
        var unsupported: [String: Int] = [:]
        var differences: [String] = []
        for r in try references() {
            let made = Teardrops(board: r.board, project: r.project, settings: r.settings)
            if !made.unsupported.isEmpty {
                unsupportedBoards += 1
                for u in made.unsupported { unsupported[u, default: 0] += 1 }
                continue
            }
            boards += 1
            (narrowed, notFitted) = (narrowed + made.narrowed, notFitted + made.notFitted)
            let ours = made.teardrops
            let matched = Self.match(r.teardrops, ours)
            for (k, m) in zip(r.teardrops, matched) {
                teardrops += 1
                let outline = Self.points(k["outline"])
                points += outline.count
                let what = "\(r.name) \(k["layer"] ?? "") \(k["net"] ?? "") teardrop at \(outline.first.map { "\($0)" } ?? "?")"
                guard let m else {
                    let near = ours.filter { $0.layer == k["layer"] as? String && $0.net == k["net"] as? String }
                        .min { ($0.outline.first ?? .zero).distance(outline.first ?? .zero) < ($1.outline.first ?? .zero).distance(outline.first ?? .zero) }
                    var detail = ""
                    if let near {
                        detail = " (the nearest of ours: \(near.outline.count) points against \(outline.count)"
                        if let d = zip(outline, near.outline).enumerated().first(where: { $0.element.0 != $0.element.1 }) {
                            detail += ", from point \(d.offset): \(d.element.0) against \(d.element.1)"
                        }
                        if ProcessInfo.processInfo.environment["TEARDROP_BOARD"] != nil { detail += "; KiCad's \(outline), ours \(near.outline)" }
                        detail += ")"
                    }
                    differences.append("\(what): not made by the port\(detail)")
                    continue
                }
                let t = ours[m]
                if (k["priority"] as? Int ?? 0) != t.priority { differences.append("\(what): priority \(k["priority"] ?? 0), ours \(t.priority)") }
                if (k["type"] as? String) != (t.kind == .padVia ? "padvia" : "track_end") {
                    differences.append("\(what): type \(k["type"] ?? ""), ours \(t.kind)")
                }
                if (k["net"] as? String ?? "") != (t.isMask ? "" : t.net) { differences.append("\(what): net, ours \(t.net)") }
                // (what KiCad's connectivity finds it connected with, where it has a fill: its track among them; its
                // pad or via too, unless that is of another net, which a track shorted to it gives a teardrop too)
                let touches = Set((k["pads"] as? [String] ?? []) + (k["vias"] as? [String] ?? []) + (k["tracks"] as? [String] ?? []))
                if !t.isMask && !touches.isEmpty && !touches.contains(t.track) {
                    differences.append("\(what): on track \(t.track), which KiCad's is not connected with")
                }
            }
            if ours.count != r.teardrops.count {
                differences.append("\(r.name): KiCad made \(r.teardrops.count) teardrops, the port \(ours.count)")
            }
        }
        print("TeardropTests: \(boards) boards (\(unsupportedBoards) with what the port does not make: \(unsupported.sorted { $0.key < $1.key })), "
              + "\(teardrops) teardrops (\(narrowed) narrowed to keep clear of other nets, \(notFitted) not made for them), \(points) points; "
              + "\(differences.count) differ")
        XCTAssertTrue(differences.isEmpty, "\(differences.count) teardrops differ from KiCad's:\n" + differences.prefix(40).joined(separator: "\n"))
    }

    /// Teardrops added to a board in the PCB view as one change (BoardEditing.addTeardrops, the board's zones filled
    /// again with it), written as KiCad writes them: read back from the change's board, KiCad's outlines and fills;
    /// then all taken away as one change, the pads and vias left with teardrops off, so that none are made again
    func testTeardropsAreAddedAndRemovedAsOneChange() throws {
        var boards = 0, added = 0
        for r in try references() where !r.teardrops.isEmpty {
            let original = try KiCadBoard.read(Self.folders.map { $0.appendingPathComponent(r.name + ".kicad_pcb") }
                .first { FileManager.default.fileExists(atPath: $0.path) }!)
            let session = BoardEditing(board: original, project: r.project)
            session.refillsZones = true
            guard Teardrops(board: r.board, project: r.project, settings: r.settings).unsupported.isEmpty,
                  ZoneFiller(board: r.board, project: r.project).unsupported.isEmpty else { continue }
            // (a board KiCad made its own teardrops on, with no settings set, is not one to set them on)
            guard let settings = try settingsOf(r) else { continue }
            let edit = try XCTUnwrap(session.addTeardrops(settings: settings), "\(r.name): teardrops added")
            XCTAssertEqual(edit.name, "Add Teardrops")
            XCTAssertTrue(edit.refilled)
            boards += 1
            // (the board as written, read again)
            let written = try KiCadBoard(text: edit.after.text)
            let zones = written.root.all("zone").filter { $0["attr"]?["teardrop"] != nil }
            XCTAssertEqual(zones.count, r.teardrops.count, "\(r.name): teardrops written")
            XCTAssertEqual(edit.zones.count, zones.count)
            var outlines: [String: [[IPoint]]] = [:]
            for z in zones {
                let outline = (z["polygon"]?["pts"]?.arguments ?? []).filter { $0.head == "xy" }.map { BoardWorld.point($0) }
                let fill = z.all("filled_polygon").map { ($0["pts"]?.arguments ?? []).filter { $0.head == "xy" }.map { BoardWorld.point($0) } }
                outlines["\(z.value("layer") ?? "") \(Self.asRead(outline))"] = fill
            }
            for k in r.teardrops {
                let key = "\(k["layer"] as? String ?? "") \(Self.points(k["outline"]))"
                let at = Self.points(k["outline"]).first.map { "\($0)" } ?? "?"
                let fill = try XCTUnwrap(outlines[key], "\(r.name): KiCad's teardrop at \(at) written")
                XCTAssertEqual(fill, Self.polygons(k["fill"] as? [[String: Any]] ?? []).map { $0[0] }, "\(r.name): its fill as KiCad fills it")
                added += 1
            }
            let removed = try XCTUnwrap(session.removeTeardrops(), "\(r.name): teardrops taken away")
            XCTAssertFalse(removed.after.root.all("zone").contains { $0["attr"]?["teardrop"] != nil })
            XCTAssertFalse((removed.teardropSettings ?? session.teardropSettings).track.enabled)
            XCTAssertTrue(Teardrops(board: removed.after, project: r.project, settings: removed.teardropSettings).teardrops.isEmpty,
                          "\(r.name): none made again")
            XCTAssertNil(session.removeTeardrops(), "nothing more to take away")
        }
        print("TeardropTests (added as a change): \(boards) boards, \(added) teardrops")
    }

    /// The settings teardrops.py set (for addTeardrops, which sets them as the dialog does)
    private func settingsOf(_ r: Reference) throws -> TeardropSettings? {
        let file = try XCTUnwrap(Self.folders.map { $0.appendingPathComponent(r.name + ".teardrops") }
            .first { FileManager.default.fileExists(atPath: $0.path) })
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        guard let s = json?["settings"] as? [String: Any] else { return nil }
        return TeardropSettings(round: Self.parameters(s["round"] as? [String: Any]), rect: Self.parameters(s["rect"] as? [String: Any]),
                                track: Self.parameters(s["track"] as? [String: Any]), vias: (s["vias"] as? Bool) ?? false,
                                pthPads: (s["pthPads"] as? Bool) ?? false, smdPads: (s["smdPads"] as? Bool) ?? false,
                                trackToTrack: (s["trackToTrack"] as? Bool) ?? false)
    }

    /// The whole way: the board with the port's teardrops, its zones filled by the port's filler, against KiCad's
    /// fills of its own teardrops and of the board's zones round them
    func testTeardropsFilledAsKiCadFillsThem() throws {
        var boards = 0, zones = 0, polygons = 0, points = 0, orders = 0
        var differences: [String] = []
        for r in try references() {
            let made = Teardrops(board: r.board, project: r.project, settings: r.settings)
            guard made.unsupported.isEmpty else { continue }
            let board = made.board(r.board)
            let filler = ZoneFiller(board: board, project: r.project)
            guard filler.unsupported.isEmpty else { continue }
            boards += 1
            // the port's teardrops' keys among the board's zones, as the filler keeps them
            var keys: [String: String] = [:]
            for (n, node) in board.root.all("zone").enumerated() where node["attr"]?["teardrop"] != nil {
                let outline = (node["polygon"]?["pts"]?.arguments ?? []).filter { $0.head == "xy" }.map { BoardWorld.point($0) }
                keys["\(node.value("layer") ?? "") \(Self.asRead(outline))"] = ZoneFiller.zoneKey(node, n)
            }
            func compare(_ what: String, _ kicad: [[String: Any]], _ key: String?, _ layer: String) {
                zones += 1
                let k = Self.polygons(kicad)
                polygons += k.count
                points += k.joined().map(\.count).reduce(0, +)
                let o = key.flatMap { filler.fills[$0]?[layer] }.map { $0.polygons.map { $0.map(\.points) } } ?? []
                if k != o {
                    differences.append("\(r.name) \(what) \(layer): KiCad's \(k.count) polygons (\(k.joined().map(\.count).reduce(0, +)) points), "
                                       + "ours \(o.count) (\(o.joined().map(\.count).reduce(0, +)))")
                }
            }
            for k in r.teardrops {
                let layer = k["layer"] as? String ?? ""
                compare("teardrop at \(Self.points(k["outline"]).first.map { "\($0)" } ?? "?")", k["fill"] as? [[String: Any]] ?? [],
                        keys["\(layer) \(Self.points(k["outline"]))"], layer)
            }
            for (uuid, layers) in r.fills.sorted(by: { $0.key < $1.key }) {
                for (layer, fill) in layers.sorted(by: { $0.key < $1.key }) { compare("zone \(uuid)", fill, uuid, layer) }
            }
            // the zones in the order KiCad writes them (the teardrops by the uuids it makes them with)
            if let order = r.order {
                // (teardrops of one outline, two pads' in one place, are one another's, in KiCad's order of them)
                var index: [String: [Int]] = [:]
                for (i, k) in r.teardrops.enumerated() { index["\(k["layer"] as? String ?? "") \(Self.points(k["outline"]))", default: []].append(i) }
                let ours = board.root.all("zone").map { node -> String in
                    guard node["attr"]?["teardrop"] != nil else { return node.value("uuid") ?? "" }
                    let outline = (node["polygon"]?["pts"]?.arguments ?? []).filter { $0.head == "xy" }.map { BoardWorld.point($0) }
                    let key = "\(node.value("layer") ?? "") \(Self.asRead(outline))"
                    guard let i = index[key]?.first else { return "a teardrop KiCad did not make" }
                    index[key]?.removeFirst()
                    return "teardrop #\(i)"
                }
                orders += 1
                if ours != order { differences.append("\(r.name): its zones written in another order than KiCad's: \(ours) against \(order)") }
            }
        }
        print("TeardropTests (filled): \(boards) boards (\(orders) of their zones' orders as KiCad writes them), \(zones) zone layers, "
              + "\(polygons) polygons, \(points) points; \(differences.count) differ")
        XCTAssertTrue(differences.isEmpty, "\(differences.count) fills differ from KiCad's:\n" + differences.prefix(40).joined(separator: "\n"))
    }
}
