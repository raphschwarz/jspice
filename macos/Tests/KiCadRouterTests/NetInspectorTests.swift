import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// KiCad's Net Inspector, the port's (NetInspector, with LengthCalculation) against KiCad's own:
/// tools/kicad-reference/nets.py opens each board in KiCad's PCB editor and writes NAME.nets next to NAME.kicad_pcb:
/// the panel's rows (every column's text), their order sorted by each column up and down, the nets shown for filter
/// texts, the rows grouped by net class and by custom group rules, and each track's BOARD::GetTrackLength to the
/// nanometre. KICAD_NETS_REFERENCE names a folder of such boards (or several, separated by colons); with none,
/// Fixtures/nets.
final class NetInspectorTests: XCTestCase {
    private static var folders: [URL] {
        if let f = ProcessInfo.processInfo.environment["KICAD_NETS_REFERENCE"] {
            return f.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        return ["nets"].compactMap { Bundle.module.url(forResource: $0, withExtension: nil, subdirectory: "Fixtures") }
    }

    private struct Reference {
        var file: URL
        var json: [String: Any]
        var inspector: NetInspector
        /// Nets whose vias KiCad found other pads of first than the port's, and whose lengths are then as KiCad's
        var padOrdered: Int
    }

    /// The nets' lengths as KiCad came to them where a via of theirs is joined to pads of both sides and KiCad took
    /// another of them first (by their places in memory): the lengths of KiCad's choice taken, which the other tests
    /// then go by; counted
    private static func adoptingKiCadsPadOrder(_ inspector: inout NetInspector, _ json: [String: Any]) -> Int {
        var adopted = 0
        let theirs = Dictionary((json["rows"] as? [[String: Any]] ?? []).compactMap { $0["cells"] as? [String] }.map { ($0[0], $0) },
                                uniquingKeysWith: { a, _ in a })
        for net in inspector.nets {
            guard let cells = theirs[net.name] else { continue }
            func cellsOf(_ stats: LengthCalculation.Stats) -> [String] {
                let row = NetInspector.Row(net: net, stats: stats, number: net.code)
                return (0..<inspector.columns.count).map { inspector.value(row, column: $0) }
            }
            guard cellsOf(net.stats) != cells,
                  let match = inspector.alternatives(net.code).first(where: { cellsOf($0) == cells }) else { continue }
            inspector.adopt(net.code, match)
            adopted += 1
        }
        return adopted
    }

    private func references() throws -> [Reference] {
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
        return try files.compactMap { file in
            let reference = file.deletingPathExtension().appendingPathExtension("nets")
            guard let data = try? Data(contentsOf: reference),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let board = try KiCadBoard(text: String(contentsOf: file, encoding: .utf8))
            let projectURL = file.deletingPathExtension().appendingPathExtension("kicad_pro")
            let project = (try? Data(contentsOf: projectURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            var inspector = NetInspector(board: board, project: project)
            let adopted = Self.adoptingKiCadsPadOrder(&inspector, json)
            return Reference(file: file, json: json, inspector: inspector, padOrdered: adopted)
        }
    }

    /// Each net's row, every column as KiCad's panel shows it (a net with a via joined to pads of both sides as the
    /// port's other choice of pad makes it, where that is KiCad's: counted)
    func testRowsAsKiCadsInspectorShowsThem() throws {
        var boards = 0, rows = 0, padOrdered = 0, differences: [String] = []
        for r in try references() {
            boards += 1
            padOrdered += r.padOrdered
            let theirs = (r.json["rows"] as? [[String: Any]] ?? []).compactMap { $0["cells"] as? [String] }
            XCTAssertEqual(r.json["columns"] as? [String], r.inspector.titles, r.file.lastPathComponent)
            var settings = NetInspector.Settings()
            settings.showZeroPadNets = true
            let ours = Dictionary(r.inspector.rows(settings).map { row in
                (row.name, (0..<r.inspector.columns.count).map { r.inspector.value(row, column: $0) })
            }, uniquingKeysWith: { a, _ in a })
            rows += theirs.count
            for cells in theirs {
                guard let mine = ours[cells[0]] else {
                    differences.append("\(r.file.lastPathComponent) \(cells[0]): KiCad's only")
                    continue
                }
                if mine != cells { differences.append("\(r.file.lastPathComponent) \(cells[0]): KiCad \(cells), ours \(mine)") }
            }
            if ours.count != theirs.count { differences.append("\(r.file.lastPathComponent): \(ours.count) rows, KiCad's \(theirs.count)") }
        }
        print("net inspector: \(boards) boards, \(rows) nets, \(padOrdered) of them by KiCad's other first pad of a via, \(differences.count) differences")
        XCTAssertGreaterThan(rows, 0)
        XCTAssertEqual(differences, [], differences.prefix(40).joined(separator: "\n"))
    }

    /// Each track's length of the copper it is connected to, its vias' heights with it, to the nanometre. KiCad
    /// measures a cluster's items in the order of their places in memory, and a line cut by vias at both ends comes
    /// out a few nanometres longer or shorter by which cuts it first (and by which line of a chain the others are
    /// merged into): where the port's order gives another length, it must come to KiCad's with the items in some other
    /// order (counted)
    func testTrackLengthsAsKiCadsToTheNanometre() throws {
        var tracks = 0, orderDependent = 0, differences: [String] = []
        for r in try references() {
            for (uuid, value) in r.json["tracks"] as? [String: [NSNumber]] ?? [:] {
                tracks += 1
                let theirs = value.map(\.intValue)
                guard let ours = r.inspector.trackLength(uuid) else {
                    differences.append("\(r.file.lastPathComponent) \(uuid): no track")
                    continue
                }
                if [ours.items, ours.length, ours.padToDie] != theirs {
                    if ours.items == theirs[0], ours.padToDie == theirs[2], r.inspector.trackLengths(uuid, orders: 256).contains(theirs[1]) {
                        orderDependent += 1
                        continue
                    }
                    differences.append("\(r.file.lastPathComponent) \(uuid): KiCad \(theirs), ours \([ours.items, ours.length, ours.padToDie])")
                }
            }
        }
        print("track lengths: \(tracks) tracks, \(orderDependent) of KiCad's lengths by another order of their items, \(differences.count) differences")
        XCTAssertGreaterThan(tracks, 0)
        XCTAssertEqual(differences, [], differences.prefix(40).joined(separator: "\n"))
    }

    /// The rows in the order KiCad's panel sorts them by each column, up and down (rows its Compare tells apart only
    /// by their places in memory, such as R1 and R10, whose R is a decimal point to it, in either order)
    func testSortingAsKiCadsInspectorSorts() throws {
        var orders = 0, ties = 0, differences: [String] = []
        for r in try references() {
            for (key, names) in r.json["orders"] as? [String: [String]] ?? [:] {
                guard let column = Int(key.dropLast()) else { continue }
                var settings = NetInspector.Settings()
                settings.showZeroPadNets = true
                settings.sortingColumn = column
                settings.sortAscending = key.hasSuffix("+")
                let rows = r.inspector.rows(settings)
                let ours = rows.map(\.name)
                orders += 1
                if ours == names { continue }
                // (rows KiCad's Compare tells apart only by their places in memory: in either order)
                let byName = Dictionary(rows.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
                let theirs = names.compactMap { byName[$0] }
                let consistent = theirs.count == names.count && Set(names) == Set(ours)
                    && zip(theirs, theirs.dropFirst()).allSatisfy {
                        r.inspector.compare($0, $1, column: column, ascending: settings.sortAscending, lastResort: false) <= 0
                    }
                if consistent {
                    ties += 1
                } else {
                    differences.append("\(r.file.lastPathComponent) by \(key): KiCad \(names), ours \(ours)")
                }
            }
        }
        print("net inspector sorting: \(orders) orders, \(ties) of rows KiCad tells apart by their places in memory alone, \(differences.count) differences")
        XCTAssertGreaterThan(orders, 0)
        XCTAssertEqual(differences, [], differences.prefix(20).joined(separator: "\n"))
    }

    /// The nets shown for filter texts typed in the filter box
    func testFilteringAsKiCadsInspectorFilters() throws {
        var filters = 0, differences: [String] = []
        for r in try references() {
            for entry in r.json["filters"] as? [[String: Any]] ?? [] {
                guard let text = entry["text"] as? String, let names = entry["nets"] as? [String] else { continue }
                var settings = NetInspector.Settings()
                settings.showZeroPadNets = true
                settings.filterText = text
                let ours = Set(r.inspector.rows(settings).map(\.name))
                filters += 1
                if ours != Set(names) { differences.append("\(r.file.lastPathComponent) \"\(text)\": KiCad \(names.sorted()), ours \(ours.sorted())") }
            }
        }
        print("net inspector filters: \(filters) filters, \(differences.count) differences")
        XCTAssertGreaterThan(filters, 0)
        XCTAssertEqual(differences, [], differences.prefix(20).joined(separator: "\n"))
    }

    /// The nets grouped by their net classes and by custom group rules, each group's sums
    func testGroupingAsKiCadsInspectorGroups() throws {
        var groups = 0, differences: [String] = []
        for r in try references() {
            guard let grouped = r.json["grouped"] as? [String: Any] else { continue }
            // (KiCad's second run, whose pads are in other places in memory: its nets' lengths as it came to them)
            var inspector = r.inspector
            let children = (grouped["rows"] as? [[String: Any]] ?? []).flatMap { $0["children"] as? [[String: Any]] ?? [] }
            _ = Self.adoptingKiCadsPadOrder(&inspector, ["rows": children])
            var settings = NetInspector.Settings()
            settings.showZeroPadNets = true
            settings.groupByNetclass = true
            settings.customGroupRules = grouped["rules"] as? [String] ?? []
            func cells(_ row: NetInspector.Row) -> [String] { (0..<inspector.columns.count).map { inspector.value(row, column: $0) } }
            var ours: [String: (cells: [String], children: Set<[String]>)] = [:]
            for row in inspector.rows(settings) { ours[row.name] = (cells(row), Set(row.children.map(cells))) }
            for entry in grouped["rows"] as? [[String: Any]] ?? [] {
                guard let theirCells = entry["cells"] as? [String] else { continue }
                let children = Set((entry["children"] as? [[String: Any]] ?? []).compactMap { $0["cells"] as? [String] })
                groups += 1
                guard let mine = ours.removeValue(forKey: theirCells[0]) else {
                    differences.append("\(r.file.lastPathComponent) \(theirCells[0]): KiCad's only")
                    continue
                }
                if mine.cells != theirCells { differences.append("\(r.file.lastPathComponent): KiCad \(theirCells), ours \(mine.cells)") }
                if mine.children != children { differences.append("\(r.file.lastPathComponent) \(theirCells[0]): KiCad's nets \(children.map { $0[0] }.sorted()), ours \(mine.children.map { $0[0] }.sorted())") }
            }
            for name in ours.keys.sorted() { differences.append("\(r.file.lastPathComponent) \(name): ours only") }
        }
        print("net inspector groups: \(groups) rows, \(differences.count) differences")
        XCTAssertGreaterThan(groups, 0)
        XCTAssertEqual(differences, [], differences.prefix(20).joined(separator: "\n"))
    }

    /// ValueStringCompare as KiCad's: beginnings case aside, then numbers (multipliers applied), then endings; an R
    /// before a number is a decimal point to it, as in 4R7 (so that R2 comes after R10: 0.2 against 0.10)
    func testValueStringCompare() {
        XCTAssertEqual(NetInspector.valueStringCompare("C2", "C10"), -1)
        XCTAssertEqual(NetInspector.valueStringCompare("R2", "R10"), 1)
        XCTAssertEqual(NetInspector.valueStringCompare("net10", "Net9"), 1)
        XCTAssertEqual(NetInspector.valueStringCompare("4k7", "4700"), 0)
        XCTAssertEqual(NetInspector.valueStringCompare("1,000.5", "1000.5"), 0)
    }
}
