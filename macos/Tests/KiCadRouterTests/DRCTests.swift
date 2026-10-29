import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// The port's design rules check against KiCad's: tools/kicad-reference/drc.py has kicad-cli check each board
/// (NAME.drc, its report, next to NAME.kicad_pcb), and BoardDRC, checking the same board itself, must find the same
/// violations of the checks it makes: of the same kind, between the same items, in the same words (its rule and the
/// actual value, to KiCad's digits). KICAD_BOARD_REFERENCE names a folder of such boards; with none,
/// Fixtures/boards, Fixtures/courtyards (courtyards drawn malformed in their many ways, some out at the coordinates'
/// limits), Fixtures/outlines (boards' outlines drawn malformed in theirs), Fixtures/thermals (thermal reliefs),
/// Fixtures/copper (copper of the kinds random boards do not have, and slivers), Fixtures/texts (texts on the
/// silkscreen over each other), Fixtures/silk (silkscreen of every kind over pads, vias, tracks, mask and itself,
/// across the board's edges; with a silk clearance, and with a minimum mask web), Fixtures/regressions (boards of CI
/// runs the port once got wrong: a net tie's pad of arcs against items of no net, a footprint reaching a keepout's box
/// by its texts only) and Fixtures/rules (boards with rules files: one of every kind of check the port follows, one
/// KiCad cannot compile, whose rules before the one it cannot it keeps, one it cannot read, one of the filler's
/// constraints, and three of rules.py's). A board with a rules file beside it (NAME.kicad_dru, rules.py's) is checked
/// by its rules, as kicad-cli checks it; one whose rules the port does not follow as KiCad's do (BoardDRC.unsupported)
/// is left out, and counted.
final class DRCTests: XCTestCase {
    private static var folders: [URL] {
        if let f = ProcessInfo.processInfo.environment["KICAD_BOARD_REFERENCE"] { return [URL(fileURLWithPath: f)] }
        return ["boards", "courtyards", "outlines", "thermals", "copper", "texts", "silk", "regressions", "rules"].compactMap {
            Bundle.module.url(forResource: $0, withExtension: nil, subdirectory: "Fixtures")
        }
    }

    /// The checks BoardDRC makes
    static let checked: Set<String> = ["track_width", "via_diameter", "drill_out_of_range", "microvia_drill_out_of_range",
                                       "annular_width", "hole_to_hole", "holes_co_located", "clearance", "hole_clearance",
                                       "shorting_items", "tracks_crossing", "copper_edge_clearance", "track_dangling",
                                       "via_dangling", "unconnected_items", "items_not_allowed",
                                       "courtyards_overlap", "missing_courtyard", "malformed_courtyard", "pth_inside_courtyard",
                                       "npth_inside_courtyard", "solder_mask_bridge", "isolated_copper", "starved_thermal",
                                       "invalid_outline", "zones_intersect", "copper_sliver", "silk_overlap",
                                       "silk_over_copper", "silk_edge_clearance", "assertion_failure"]

    func testViolationsAsKiCadFindsThem() throws {
        // (DRC_DISALLOW_BY_ENGINE: the keepout check by the rules engine, as it goes with the user's disallow rules, on
        // every board)
        BoardDRC.disallowByEngine = ProcessInfo.processInfo.environment["DRC_DISALLOW_BY_ENGINE"] != nil
        defer { BoardDRC.disallowByEngine = false }
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
        var boards = 0, found = 0, exactUnconnected = 0, descriptions = 0, ambiguousBoards = 0, unsureFound = 0
        var ruleBoards = 0, unsupportedBoards = 0
        var unsupported: [String: Int] = [:]
        var differences: [String] = []
        var byType: [String: Int] = [:]
        var all: [String] = []
        for file in files {
            let reportURL = file.deletingPathExtension().appendingPathExtension("drc")
            guard let data = try? Data(contentsOf: reportURL) else { continue }
            var report = try KiCadFabrication.parseDRC(data)
            // (the board itself, which KiCad gives a new uuid each time it reads it, by the port's uuid for it)
            for (i, v) in report.violations.enumerated() {
                for (j, item) in v.items.enumerated() where item.description == "PCB" {
                    report.violations[i].items[j].uuid = BoardDRC.boardUUID
                }
            }
            let pro = file.deletingPathExtension().appendingPathExtension("kicad_pro")
            let drc = BoardDRC(board: try KiCadBoard.read(file), projectURL: FileManager.default.fileExists(atPath: pro.path) ? pro : nil)
            boards += 1
            let name = file.deletingPathExtension().lastPathComponent
            // (a solder mask bridge's items in no order: KiCad's threads decide which of two it tries first)
            func key(_ type: String, _ severity: String, _ description: String, _ items: [String]) -> String {
                "\(type) [\(severity)] \(description) \((type == "solder_mask_bridge" ? items.sorted() : items).joined(separator: " "))"
            }
            let ourReport = drc.runReport()
            if FileManager.default.fileExists(atPath: file.deletingPathExtension().appendingPathExtension("kicad_dru").path) {
                ruleBoards += 1
            }
            if !drc.unsupported.isEmpty {
                unsupportedBoards += 1
                for u in drc.unsupported { unsupported[u, default: 0] += 1 }
                continue
            }
            var ourViolations = ourReport.violations
            // (a check KiCad stopped at its limit of: which it found first goes by its threads, so only that the port
            // stops at the limit too)
            var capped: Set<String> = []
            var unlimited: BoardDRC.Report?
            for type in Self.checked {
                let limit = BoardDRC.errorLimit(type)
                let n = report.violations.filter { $0.type == type }.count
                // (a check the port stopped at the limit of and KiCad did not, where some of the port's are ones
                // KiCad may find or not: its threads found fewer of them, so all the port would find, past the limit)
                if n < limit && ourViolations.filter({ $0.type == type }).count == limit
                    && ourViolations.contains(where: { $0.type == type && ourReport.isUnsure(type, $0.items) }) {
                    if unlimited == nil { unlimited = drc.runReport(limited: false) }
                    ourViolations.removeAll { $0.type == type }
                    ourViolations += unlimited!.violations.filter { $0.type == type }
                }
                guard n == limit else { continue }
                capped.insert(type)
                let m = ourViolations.filter { $0.type == type }.count
                // (hole clearances once KiCad's clearances are at their limit: its threads test the holes of pairs
                // they would have found too near, which come before then by how they happen to run; so as many as
                // the port finds with the clearances at their limit from the start, at most)
                if m < limit && type == "hole_clearance"
                    && report.violations.filter({ $0.type == "clearance" }).count == BoardDRC.errorLimit("clearance")
                    && drc.runReport(exhausted: ["clearance"]).violations.filter({ $0.type == type }).count == limit {
                    continue
                }
                // (solder mask bridges once KiCad's are at their limit: which of those it may find or not its threads
                // found decides how many it took to reach it, as many as its runs of the same board differ by; so each
                // KiCad found that the port is sure of, the port finds too)
                if m < limit && type == "solder_mask_bridge" && !(ourReport.unsure[type]?.isEmpty ?? true) {
                    let ours = Set(ourViolations.filter { $0.type == type }.map { key($0.type, $0.severity, $0.description, $0.items) })
                    let missing = report.violations.filter { v in
                        v.type == type && !ourReport.isUnsure(type, v.items.map(\.uuid))
                            && !ours.contains(key(v.type, v.severity, v.description, v.items.map(\.uuid)))
                    }
                    if missing.isEmpty { continue }
                }
                if m != limit { differences.append("\(name): KiCad finds \(limit) \(type), its limit, ours \(m)") }
            }
            // (and once the shorts are, the copper's checks: KiCad reports what it would have as a short as a
            // clearance, and which go by the order it found them in)
            if capped.contains("shorting_items") || capped.contains("clearance") || capped.contains("hole_clearance") {
                capped.formUnion(["clearance", "shorting_items", "hole_clearance", "tracks_crossing"])
            }
            // (violations KiCad may or may not find: solder mask bridges its threads find by which way round they try
            // a pair first, silkscreen across a corner named with whichever of the corner's two edges KiCad's set of
            // them happens to hold first; left out of both, and counted)
            let unsureBefore = report.violations.count + ourViolations.count
            let unsureReport = unlimited ?? ourReport
            report.violations.removeAll { unsureReport.isUnsure($0.type, $0.items.map(\.uuid)) }
            ourViolations.removeAll { unsureReport.isUnsure($0.type, $0.items) }
            unsureFound += unsureBefore - report.violations.count - ourViolations.count
            // (items KiCad may or may not join, by where they are in its memory (two arcs touching one way round
            // and not the other): what is dangling and what is still to connect about them is left out, and counted)
            let cnAll = drc.buildConnectivity(drc.makeCopper())
            let unsure = Set(cnAll.ambiguous.flatMap { [$0.0, $0.1] })
            if !unsure.isEmpty {
                ambiguousBoards += 1
                capped.insert("unconnected_items")
                func near(_ v: KiCadFabrication.Violation) -> Bool { v.items.contains { unsure.contains($0.uuid) } }
                report.violations.removeAll { ($0.type == "track_dangling" || $0.type == "via_dangling") && near($0) }
                ourViolations.removeAll { ($0.type == "track_dangling" || $0.type == "via_dangling") && $0.items.contains(where: unsure.contains) }
            }
            // (missing connections: KiCad's ratsnest picks among connections of the same length by where its
            // items happen to be in memory, which differs from one run of it to the next; so KiCad's are checked to
            // join the port's clusters of each net into one, as many of them as the port's)
            if !capped.contains("unconnected_items") {
                capped.insert("unconnected_items")
                let cn = cnAll
                let theirsU = report.unconnected.map { $0.items.map(\.uuid) }
                let oursU = ourViolations.filter { $0.type == "unconnected_items" }.map(\.items)
                exactUnconnected += Self.minus(theirsU.map { $0.joined(separator: " ") }, Self.minus(theirsU.map { $0.joined(separator: " ") }, oursU.map { $0.joined(separator: " ") })).count
                byType["unconnected_items", default: 0] += theirsU.count
                found += theirsU.count
                if theirsU.count != oursU.count {
                    differences.append("\(name): KiCad finds \(theirsU.count) missing connections, ours \(oursU.count)")
                }
                // (a zone is in as many clusters as it has fills, one for each island on each of its layers: KiCad's
                // connection is to one of them, which its report does not say; so the clusters of KiCad's connections
                // are chosen, the plain ones first, so that each joins two not joined yet, if they can be)
                var edges: [[[Int]]] = [], edgeItems: [[String]] = []
                for e in theirsU {
                    guard e.count == 2, let aa = cn.clusterOf[e[0]], let bb = cn.clusterOf[e[1]] else {
                        differences.append("\(name): KiCad's missing connection \(e) between items not in the port's clusters")
                        continue
                    }
                    edges.append([aa, bb])
                    edgeItems.append(e)
                }
                let order = edges.indices.sorted { (edges[$0][0].count * edges[$0][1].count, $0) < (edges[$1][0].count * edges[$1][1].count, $1) }
                var root: [Int: Int] = [:]
                func find(_ x: Int, _ root: inout [Int: Int]) -> Int {
                    var r = x
                    while let p = root[r], p != r { r = p }
                    root[x] = r
                    return r
                }
                var budget = 200_000
                func place(_ k: Int, _ root: inout [Int: Int]) -> Bool {
                    guard k < order.count else { return true }
                    budget -= 1
                    guard budget > 0 else { return false }
                    let e = edges[order[k]]
                    for a in e[0] {
                        for b in e[1] {
                            var r = root
                            let ra = find(a, &r), rb = find(b, &r)
                            guard ra != rb else { continue }
                            r[ra] = rb
                            if place(k + 1, &r) {
                                root = r
                                return true
                            }
                        }
                    }
                    return false
                }
                if !place(0, &root) {
                    // (which one cannot, taking each in turn the first way it can be)
                    root = [:]
                    for k in order {
                        let e = edges[k]
                        guard let (a, b) = e[0].lazy.flatMap({ a in e[1].lazy.map { (a, $0) } }).first(where: { find($0.0, &root) != find($0.1, &root) }) else {
                            differences.append("\(name): KiCad's missing connection \(edgeItems[k]) joins what is joined already")
                            continue
                        }
                        root[find(a, &root)] = find(b, &root)
                    }
                }
                func find(_ x: Int) -> Int { find(x, &root) }
                for e in oursU where e.count == 2 {
                    if let aa = cn.clusterOf[e[0]], let bb = cn.clusterOf[e[1]],
                       !aa.contains(where: { a in bb.contains { find($0) == find(a) } }) {
                        differences.append("\(name): KiCad's missing connections leave apart what ours joins: \(e)")
                    }
                }
            }
            // (the items as KiCad describes them, in the report the app shows)
            let described = drc.itemDescriptions()
            for v in report.violations + report.unconnected where Self.checked.contains(v.type) {
                for item in v.items where described[item.uuid]?.description != item.description {
                    descriptions += 1
                    if descriptions <= 10 {
                        differences.append("\(name): KiCad describes \(item.uuid) as \"\(item.description)\", ours as \"\(described[item.uuid]?.description ?? "nothing")\"")
                    }
                }
            }
            let theirs = report.violations.filter { Self.checked.contains($0.type) && !capped.contains($0.type) }
                .map { key($0.type, $0.severity, $0.description, $0.items.map(\.uuid)) }.sorted()
            let ours = ourViolations.filter { Self.checked.contains($0.type) && !capped.contains($0.type) }
                .map { key($0.type, $0.severity, $0.description, $0.items) }.sorted()
            for v in theirs { byType[String(v.prefix { $0 != " " }), default: 0] += 1 }
            found += theirs.count
            let missing = Self.minus(theirs, ours), extra = Self.minus(ours, theirs)
            for m in missing { all.append("\(name): KiCad finds, ours does not: \(m)") }
            for e in extra { all.append("\(name): ours finds, KiCad does not: \(e)") }
            for m in missing.prefix(5) { differences.append("\(name): KiCad finds, ours does not: \(m)") }
            for e in extra.prefix(5) { differences.append("\(name): ours finds, KiCad does not: \(e)") }
        }
        // (DRC_DIFFERENCES: every difference written there, for looking at by hand)
        if let path = ProcessInfo.processInfo.environment["DRC_DIFFERENCES"] {
            try? all.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        print("DRCTests: \(boards) boards (\(ruleBoards) with rules of their own"
              + (unsupportedBoards > 0 ? ", \(unsupportedBoards) with what the port does not follow: \(unsupported.sorted { $0.key < $1.key })" : "")
              + "), \(found) violations of the checks made: "
              + byType.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
              + " (\(exactUnconnected) of the missing connections between the same items as KiCad's)"
              + (ambiguousBoards > 0 ? "; \(ambiguousBoards) boards with arcs KiCad may join or not, their connections not compared" : "")
              + (unsureFound > 0 ? "; \(unsureFound) violations KiCad may find or not left out" : ""))
        XCTAssertGreaterThan(boards, 0)
        XCTAssert(differences.isEmpty, "\(differences.count) differences from KiCad's DRC:\n" + differences.prefix(30).joined(separator: "\n"))
    }

    /// What `a` has more of than `b` (as multisets)
    static func minus(_ a: [String], _ b: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for x in b { counts[x, default: 0] += 1 }
        var out: [String] = []
        for x in a {
            if let c = counts[x], c > 0 { counts[x] = c - 1 } else { out.append(x) }
        }
        return out
    }
}
