import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// Copy, paste and duplicate (BoardClipboard, BoardEditing.copy, paste and duplicate) against KiCad's own PCB editor
/// (tools/kicad-reference/editing.py, on the boards of Fixtures/clipboard): each copy KiCad made (everything, a box's
/// items, a footprint alone) the port makes from the same selection with the pointer where KiCad's was, its reference
/// point KiCad's (BestDragOrigin) and its text KiCad's, character for character; each paste KiCad made of its copies
/// (into the board they came from, with Paste Special's unique references, into a board of fewer layers, and of a text
/// that is not KiCad's) the port makes at the point KiCad placed it, and the boards come out alike (their items, ids
/// aside, groups by their members', the net of an item KiCad's connectivity cannot tell the net of aside:
/// padlessClusters); each paste KiCad made of the port's own copies (BOARD-ours-pasted) the port's paste of them
/// likewise; each duplicate KiCad made, moved as far, likewise.
final class ClipboardTests: XCTestCase {
    static func folder() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["KICAD_CLIPBOARD_REFERENCE"] { return URL(fileURLWithPath: path) }
        return try XCTUnwrap(Bundle.module.url(forResource: "clipboard", withExtension: nil, subdirectory: "Fixtures"))
    }

    static func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func files(_ ext: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == ext }.sorted { $0.path < $1.path }
    }

    static func session(_ board: URL) throws -> BoardEditing {
        let pro = board.deletingPathExtension().appendingPathExtension("kicad_pro")
        let project = (try? Data(contentsOf: pro)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return BoardEditing(board: try KiCadBoard.read(board), project: project)
    }

    static func point(_ v: Any?) -> KiCadPoint {
        let a = (v as? [NSNumber])?.map(\.doubleValue) ?? [0, 0]
        return KiCadPoint(a[0], a[1])
    }

    /// A clipboard's text as the two are compared: each footprint's mandatory fields' ids, which KiCad's copy makes
    /// anew each time, left out; and where it holds a group or a tuning pattern, its items in order of their text
    /// (KiCad writes a group's members in the order of its unordered set)
    static func comparable(_ text: String) -> String {
        guard let root = try? SExpr.parse(text) else { return text }
        let fps = root.head == "footprint" ? [root] : root.all("footprint")
        for fp in fps {
            for field in fp.all("property") where BoardClipboard.mandatoryFields.contains(field.text(at: 0) ?? "") {
                field.remove("uuid")
            }
        }
        if root.items.contains(where: { $0.head == "group" || $0.head == "generated" }) {
            let head = root.items.prefix { !BoardItems.heads.contains($0.head ?? "") }
            let rest = root.items.dropFirst(head.count).sorted { $0.compact < $1.compact }
            root.items = Array(head) + rest
        }
        return root.formatted(.compactTextProperties)
    }

    /// The first line two texts differ at, for a failure's message
    static func difference(_ a: String, _ b: String) -> String {
        let x = a.components(separatedBy: "\n"), y = b.components(separatedBy: "\n")
        for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : nil) != (i < y.count ? y[i] : nil) {
            return "line \(i + 1): ours \(i < x.count ? x[i] : "-") | KiCad's \(i < y.count ? y[i] : "-")"
        }
        return "same"
    }

    /// The board's tracks, vias and drawings on copper by the clusters of no pads its connectivity makes of them
    /// (SearchClusters( CSM_PROPAGATE )), by id. KiCad gives each the net of the first of its items with one that its
    /// search comes to, from the item of the lowest address in memory (a std::set of CN_ITEM pointers): where a copy
    /// joins items of two nets and no pad, which of them KiCad gives it cannot be known from outside KiCad
    static func padlessClusters(_ board: KiCadBoard) -> [[String]] {
        let drc = BoardDRC(board: board)
        let cn = drc.buildConnectivity(drc.makeCopper())
        var serial = cn.clusterSerial
        return drc.searchClusters(cn, ratsnest: false, serial: &serial)
            .filter { !$0.items.contains { $0.parent.kind == .pad } }
            .map { $0.items.filter { !$0.isZone }.map(\.parent.uuid) }
    }

    /// A board's items as two boards are compared: each item's text with every id left out (and the net of one in a
    /// cluster of no pads, `padless`), a group's or tuning pattern's members by their texts (sorted), a zone's name as
    /// it is; a multiset, by count. And the board's other lists (its layers, setup, nets), as they are.
    static func contents(_ board: KiCadBoard, padless: Set<String> = []) -> (items: [String: Int], rest: [String]) {
        func bare(_ node: SExpr) -> String {
            let c = node.copy()
            if padless.contains(node.value("uuid") ?? "") { c.remove("net") }
            c.walk { n in n.items.removeAll { $0.head == "uuid" } }
            return c.compact
        }
        let byID = Dictionary(board.root.items.compactMap { n in n.value("uuid").map { ($0, n) } }, uniquingKeysWith: { a, _ in a })
        var items: [String: Int] = [:], rest: [String] = []
        for node in board.root.items {
            guard BoardItems.heads.contains(node.head ?? "") else {
                if node.head != "embedded_fonts" { rest.append(node.compact) }
                continue
            }
            let key: String
            if node.head == "group" || node.head == "generated" {
                let c = node.copy()
                c.remove("uuid")
                let members = BoardItems.members(node).map { byID[$0].map(bare) ?? "?" }.sorted()
                c.set(SExpr("members", members))
                key = c.compact
            } else {
                key = bare(node)
            }
            items[key, default: 0] += 1
        }
        return (items, rest)
    }

    /// The items one board has more of than the other, for a failure's message. An item in a cluster of no pads is
    /// compared without its net (padlessClusters), each such cluster of one net on either board.
    static func compare(_ ours: KiCadBoard, _ theirs: KiCadBoard, _ what: String) {
        if let dump = ProcessInfo.processInfo.environment["KICAD_CLIPBOARD_DUMP"] {
            try? ours.write(to: URL(fileURLWithPath: dump).appendingPathComponent(what + ".ours.kicad_pcb"))
        }
        var padless: [Set<String>] = []
        for board in [ours, theirs] {
            let nodes = Dictionary(board.root.items.compactMap { n in n.value("uuid").map { ($0, n) } }, uniquingKeysWith: { a, _ in a })
            let clusters = padlessClusters(board)
            for cluster in clusters {
                let nets = Set(cluster.compactMap { nodes[$0].map(BoardDRC.netName) })
                XCTAssertLessThanOrEqual(nets.count, 1, "\(what): a cluster of no pads of nets \(nets.sorted())")
            }
            padless.append(Set(clusters.joined()))
        }
        let a = contents(ours, padless: padless[0]), b = contents(theirs, padless: padless[1])
        XCTAssertEqual(a.rest, b.rest, "\(what): the board's setup")
        let onlyOurs = a.items.filter { (b.items[$0.key] ?? 0) < $0.value }.keys.sorted()
        let onlyTheirs = b.items.filter { (a.items[$0.key] ?? 0) < $0.value }.keys.sorted()
        XCTAssert(onlyOurs.isEmpty && onlyTheirs.isEmpty,
                  "\(what): \(onlyOurs.count) items only ours, \(onlyTheirs.count) only KiCad's\n"
                    + "ours: \(onlyOurs.prefix(3).map { String($0.prefix(900)) })\n"
                    + "KiCad's: \(onlyTheirs.prefix(3).map { String($0.prefix(900)) })")
    }

    func testPastesAreKiCads() throws {
        var pastes = 0
        for record in try Self.files("pastes") {
            // (BOARD-pasted.pastes, or BOARD-from-SOURCE.pastes: pasted into BOARD)
            let name = record.deletingPathExtension().lastPathComponent
            let base = ["-ours-pasted", "-pasted"].first { name.hasSuffix($0) }.map { String(name.dropLast($0.count)) }
                ?? String(name[..<(name.range(of: "-from-")?.lowerBound ?? name.endIndex)])
            let board = try Self.folder().appendingPathComponent(base + ".kicad_pcb")
            let session = try Self.session(board)
            for p in try XCTUnwrap(Self.json(record)["pastes"] as? [[String: Any]]) {
                let mode = p["mode"] as? String
                let text = try XCTUnwrap(p["text"] as? String)
                let edit = session.paste(text, at: Self.point(p["cursor"]), annotations: mode == "unique" ? .unique : .keep)
                XCTAssertNotNil(edit, "\(name) \(p["copy"] ?? "text") \(mode ?? "")")
                pastes += 1
            }
            let theirs = try KiCadBoard.read(record.deletingPathExtension().appendingPathExtension("kicad_pcb"))
            Self.compare(session.board, theirs, name)
        }
        XCTAssertGreaterThan(pastes, 0)
    }

    func testDuplicatesAreKiCads() throws {
        var made = 0
        for record in try Self.files("duplicates") {
            let name = record.deletingPathExtension().lastPathComponent
            let board = try Self.folder().appendingPathComponent(String(name.dropLast("-duplicated".count)) + ".kicad_pcb")
            let session = try Self.session(board)
            let scale = try XCTUnwrap((Self.json(board.deletingPathExtension().appendingPathExtension("copies"))["scale"] as? NSNumber)?.doubleValue)
            for d in try XCTUnwrap(Self.json(record)["duplicates"] as? [[String: Any]]) {
                let selection = try XCTUnwrap(d["selection"] as? [String])
                guard !selection.isEmpty else { continue }
                // (picked up by the point KiCad's move takes, BestDragOrigin, put where the pointer was clicked)
                let origin = session.dragOrigin(selection, cursor: Self.point(d["start"]), snapDistance: 50 * scale, moving: true)
                let end = Self.point(d["end"])
                XCTAssertNotNil(session.duplicate(selection, by: KiCadPoint(end.x - origin.x, end.y - origin.y)), name)
                made += 1
            }
            Self.compare(session.board, try KiCadBoard.read(record.deletingPathExtension().appendingPathExtension("kicad_pcb")), name)
        }
        XCTAssertGreaterThan(made, 0)
    }

    func testCopiesAreKiCadsText() throws {
        var copies = 0
        var dumped: [String: String] = [:]
        for record in try Self.files("copies") {
            let board = record.deletingPathExtension().appendingPathExtension("kicad_pcb")
            let session = try Self.session(board)
            let r = try Self.json(record)
            let scale = try XCTUnwrap((r["scale"] as? NSNumber)?.doubleValue)
            for c in try XCTUnwrap(r["copies"] as? [[String: Any]]) {
                let what = "\(board.lastPathComponent) \(c["name"] ?? "")"
                let selection = try XCTUnwrap(c["selection"] as? [String])
                // (a box that took nothing: KiCad copies what is under the pointer then, which JSpice does not)
                guard !selection.isEmpty else { continue }
                let theirs = try XCTUnwrap(c["text"] as? String, what)
                let reference = session.dragOrigin(selection, cursor: Self.point(c["cursor"]), snapDistance: 50 * scale)
                let ours = try XCTUnwrap(session.copy(selection, reference: reference), what)
                let (a, b) = (Self.comparable(ours), Self.comparable(theirs))
                XCTAssertEqual(a, b, "\(what): \(Self.difference(a, b))")
                dumped[c["name"] as? String ?? ""] = ours
                copies += 1
            }
            if let dump = ProcessInfo.processInfo.environment["KICAD_CLIPBOARD_DUMP"] {
                try JSONSerialization.data(withJSONObject: dumped).write(to: URL(fileURLWithPath: dump)
                    .appendingPathComponent(record.deletingPathExtension().lastPathComponent + ".ours"))
            }
            dumped = [:]
        }
        XCTAssertGreaterThan(copies, 0)
    }
}
