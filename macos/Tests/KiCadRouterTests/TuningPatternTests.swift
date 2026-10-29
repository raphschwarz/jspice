import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// Tuning patterns kept in the board as KiCad keeps them (TuningPattern, its generator side and BoardEditing's
/// tuning), against KiCad itself: the boards of Fixtures/tuning (and of KICAD_TUNING_REFERENCE, a folder of more) were
/// tuned by KiCad's own PCB editor driven as a user drives it (tools/kicad-reference/tuning.py): BOARD-placed is what
/// its Tune Length tools made of BOARD (each tuning of BOARD.plan: the tool picked, a click on the track, the pointer
/// moved on twice, a click; BOARD.placed says where KiCad's pointer was), BOARD-updated what its Edit > Update All
/// Tuning Patterns made of BOARD-edit (BOARD-placed with its patterns' properties changed in the file, and patterns of
/// no base line added), BOARD-removed what its Delete of one of the patterns (BOARD.removed) made of BOARD-updated. The
/// port makes the same of the same boards, which must come out alike to the nanometre: every track and arc, and every
/// pattern's properties and members (its tracks, by their shapes: the uuids of new tracks are new). KiCad's patterns
/// are read and written back as KiCad wrote them; and, where KiCad is installed, KiCad reads the port's boards
/// (tuning.py check) as it reads its own: their patterns found with the port's members, written back as the port wrote
/// them, its DRC finding what it finds on its own boards.
final class TuningPatternTests: XCTestCase {
    /// The boards tuned (BOARD.plan beside each), Fixtures/tuning's and then KICAD_TUNING_REFERENCE's, each folder's
    /// by name (wherever the folders are: the tests that take the first few take Fixtures/tuning's)
    static func boards() throws -> [URL] {
        var folders = [try XCTUnwrap(Bundle.module.url(forResource: "tuning", withExtension: nil, subdirectory: "Fixtures"))]
        if let more = ProcessInfo.processInfo.environment["KICAD_TUNING_REFERENCE"] { folders.append(URL(fileURLWithPath: more)) }
        var out: [URL] = []
        for folder in folders {
            out += try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "plan" }
                .map { $0.deletingPathExtension().appendingPathExtension("kicad_pcb") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return out
    }

    static func sibling(_ board: URL, _ suffix: String, _ ext: String = "kicad_pcb") -> URL {
        let base = board.deletingPathExtension().lastPathComponent
        return board.deletingLastPathComponent().appendingPathComponent("\(base)\(suffix).\(ext)")
    }

    static func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// A session on `file` and its project
    static func session(_ file: URL, project: URL? = nil) throws -> BoardEditing {
        BoardEditing(board: try KiCadBoard.read(file), project: BoardEditingTests.project(project ?? file))
    }

    // MARK: - Boards compared

    /// A track, arc track or via by its shape, width, layer and net
    static func signature(_ n: SExpr) -> String {
        var s = n.head ?? ""
        for k in ["start", "mid", "end", "at"] { if let v = n[k] { s += " \(k) \(v.text(at: 0) ?? "") \(v.text(at: 1) ?? "")" } }
        s += " width \(n.value("width") ?? "") \(n.value("layer") ?? "") \(n.value("net") ?? "")"
        return s
    }

    /// Each pattern of the board, its uuid aside, its members by their signatures
    static func patterns(_ board: KiCadBoard, keepUUID: Bool) -> [String] {
        let byID = Dictionary(board.copperItems.map { ($0.value("uuid") ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        return board.root.all("generated").map { n -> String in
            let c = n.copy()
            let members = c["members"]?.arguments.map { m in byID[m.text].map(signature) ?? "missing \(m.text)" }.sorted() ?? []
            c.remove("members")
            if !keepUUID { c.remove("uuid") }
            return c.compact + " members: " + members.joined(separator: "; ")
        }.sorted()
    }

    /// What differs between the port's board and KiCad's: tracks one has and the other has not, patterns that differ
    static func differences(_ ours: KiCadBoard, _ kicad: KiCadBoard, keepUUIDs: Bool = true) -> [String] {
        var out: [String] = []
        let a = ours.copperItems.map(signature).sorted(), b = kicad.copperItems.map(signature).sorted()
        if a != b {
            var bag: [String: Int] = [:]
            for x in a { bag[x, default: 0] += 1 }
            for x in b { bag[x, default: 0] -= 1 }
            for (x, n) in bag.sorted(by: { $0.key < $1.key }) where n != 0 { out.append("\(n > 0 ? "ours" : "KiCad's") only (\(abs(n))): \(x)") }
        }
        let pa = patterns(ours, keepUUID: keepUUIDs), pb = patterns(kicad, keepUUID: keepUUIDs)
        if pa.count != pb.count { out.append("\(pa.count) patterns, KiCad \(pb.count)") }
        for (x, y) in zip(pa, pb) where x != y { out.append("pattern: ours \(x)\n  KiCad's \(y)") }
        return out
    }

    // MARK: - Placed as KiCad's Tune Length tools place them

    /// A unit step along the run from `a` to `b` (of a line at 0, 45 or 90 degrees), and the step across it
    static func steps(_ a: IPoint, _ b: IPoint) -> (along: IPoint, across: IPoint) {
        let d = b - a
        let u = IPoint(d.x == 0 ? 0 : d.x / abs(d.x), d.y == 0 ? 0 : d.y / abs(d.y))
        return (u, IPoint(-u.y, u.x))
    }

    /// `p` moved across the run from `a` to `b` by `amount` steps, to the side `like` is on
    static func across(_ p: IPoint, _ a: IPoint, _ b: IPoint, _ amount: Int, like: IPoint) -> IPoint {
        let n = steps(a, b).across
        let q = IPoint(p.x + n.x * amount, p.y + n.y * amount)
        return Seg(a, b).side(q) == Seg(a, b).side(like) ? q : IPoint(p.x - n.x * amount, p.y - n.y * amount)
    }

    /// The tunings of BOARD.plan made with the port's tools as KiCad's were used (startTuning, moveTuning twice,
    /// fixTuning): the click where KiCad's pattern starts (the point of the track its click came to); the pointer's way
    /// point where KiCad's pointer was (where a skew pattern keeps it: its other line's base line ends at the point of
    /// that line nearest it); the last move and click on the side of the line KiCad's pointer was on, across from where
    /// KiCad's pattern ends (the point of the line its pointer came to, which the status bar and the view's scale say to
    /// a micrometre only)
    static func place(_ board: URL) throws -> BoardEditing {
        let session = try session(board)
        let kicad = try KiCadBoard.read(sibling(board, "-placed"))
        let record = try json(board.deletingPathExtension().appendingPathExtension("placed"))
        let patterns = TuningPattern.all(kicad)
        for t in try XCTUnwrap(record["tunings"] as? [[String: Any]]) {
            let modeName = t["mode"] as? String
            let mode: BoardRouter.TuningMode = modeName == "single" ? .single : modeName == "skew" ? .skew : .diffPair
            func point(_ key: String) -> IPoint {
                let a = t[key] as? [Double] ?? [0, 0]
                return BoardEditing.nm(KiCadPoint(a[0], a[1]))
            }
            guard let kp = patterns.first(where: { $0.lastNetName == t["net"] as? String }) else {
                XCTFail("\(board.lastPathComponent): KiCad made no pattern of \(t["net"] ?? "")")
                continue
            }
            let run = (t["run"] as? [[Double]] ?? []).map { BoardEditing.nm(KiCadPoint($0[0], $0[1])) }
            XCTAssertNotNil(session.startTuning(at: BoardEditing.mm(kp.origin), layer: kp.layer, mode: mode),
                            "\(board.lastPathComponent) \(kp.lastNetName): \(session.failureReason)")
            var via = point("via")
            if mode == .skew, let c = kp.baseLineCoupled, c.segmentCount > 0 {
                let s = c.segment(-1)
                via = across(c.lastPoint, s.a, s.b, 300_000, like: via)
            }
            session.moveTuning(to: BoardEditing.mm(via))
            let end = across(kp.end, run[0], run[1], 600_000, like: point("end"))
            session.moveTuning(to: BoardEditing.mm(end))
            XCTAssertNotNil(session.fixTuning(at: BoardEditing.mm(end)), "\(board.lastPathComponent) \(kp.lastNetName)")
        }
        return session
    }

    func testPatternsArePlacedAsKiCadsToolsPlaceThem() throws {
        var boards = 0, tunings = 0
        for board in try Self.boards() {
            let session = try Self.place(board)
            let kicad = try KiCadBoard.read(Self.sibling(board, "-placed"))
            let diff = Self.differences(session.board, kicad, keepUUIDs: false)
            XCTAssertEqual(diff, [], "\(board.lastPathComponent)")
            boards += 1
            tunings += TuningPattern.all(kicad).count
        }
        print("TuningPatternTests: \(tunings) patterns placed on \(boards) boards as KiCad's tools placed them")
        XCTAssertGreaterThan(tunings, 0)
    }

    // MARK: - Tuned again as KiCad's Update All Tuning Patterns tunes them

    func testPatternsAreTunedAgainAsKiCadTunesThem() throws {
        var count = 0, changed = 0
        for board in try Self.boards() {
            let edited = Self.sibling(board, "-edit")
            let session = try Self.session(edited, project: board)
            let edit = try XCTUnwrap(session.updateAllTuningPatterns(), board.lastPathComponent)
            XCTAssertEqual(edit.name, "Update Tuning Patterns")
            let kicad = try KiCadBoard.read(Self.sibling(board, "-updated"))
            XCTAssertEqual(Self.differences(session.board, kicad), [], "\(board.lastPathComponent)")
            count += TuningPattern.all(kicad).count
            changed += edit.generators.count
        }
        print("TuningPatternTests: \(count) patterns tuned again as KiCad tuned them (\(changed) changed)")
        XCTAssertGreaterThan(count, 0)
    }

    /// The same patterns given targets by the board's own rules (BOARD-rules: BOARD-placed with a design rules file,
    /// tuning.py rules: length rules of single tracks' nets in each way a rule can give a length, and of pairs, skew
    /// rules of pairs, one pattern overriding the rules), tuned again as KiCad's Update All tuned them by the rules
    /// (BOARD-rules-updated): EditStart's targets from the rules (PNS_PCBNEW_RULE_RESOLVER::QueryConstraint's
    /// CT_LENGTH and CT_DIFF_PAIR_SKEW, the DRC engine's length and skew constraints)
    func testPatternsAreTargetedByTheBoardsRules() throws {
        var count = 0, retargeted = 0
        for board in try Self.boards() {
            let edited = Self.sibling(board, "-rules")
            guard FileManager.default.fileExists(atPath: edited.path) else { continue }
            let project = edited.deletingPathExtension().appendingPathExtension("kicad_pro")
            let rules = try XCTUnwrap(BoardDRC.designRules(project), edited.lastPathComponent)
            let session = BoardEditing(board: try KiCadBoard.read(edited), project: BoardEditingTests.project(project),
                                       designRules: rules)
            XCTAssertNotNil(session.updateAllTuningPatterns(), edited.lastPathComponent)
            let kicad = try KiCadBoard.read(Self.sibling(board, "-rules-updated"))
            XCTAssertEqual(Self.differences(session.board, kicad), [], edited.lastPathComponent)
            let before = Dictionary(TuningPattern.all(try KiCadBoard.read(edited)).map { ($0.uuid, $0.settings) },
                                    uniquingKeysWith: { a, _ in a })
            for p in TuningPattern.all(kicad) {
                count += 1
                guard let was = before[p.uuid] else { continue }
                if was.targetLength != p.settings.targetLength || was.targetSkew != p.settings.targetSkew { retargeted += 1 }
            }
        }
        print("TuningPatternTests: \(count) patterns tuned again by the boards' rules as KiCad tuned them (\(retargeted) given new targets)")
        XCTAssertGreaterThan(retargeted, 0)
    }

    /// Patterns on boards of Fixtures/boards and Fixtures/arcboards (Fixtures/tuningboards: NAME-edit, the board with
    /// patterns written into it on lines of its own, of no base line, by tuning.py edit), tuned as KiCad's Update All
    /// Tuning Patterns tuned them (NAME-updated): their tracks ending in pads that are on one side only, or on vias,
    /// the lengths KiCad measures clipped to the pads' and vias' copper and with the vias it infers in the pads
    func testPatternsOnBoardsAreTunedAsKiCadTunesThem() throws {
        let folder = try XCTUnwrap(Bundle.module.url(forResource: "tuningboards", withExtension: nil, subdirectory: "Fixtures"))
        let boards = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("-edit.kicad_pcb") }.sorted { $0.path < $1.path }
        var count = 0
        for edited in boards {
            let session = try Self.session(edited)
            let edit = try XCTUnwrap(session.updateAllTuningPatterns(), edited.lastPathComponent)
            let name = edited.lastPathComponent.replacingOccurrences(of: "-edit.kicad_pcb", with: "-updated.kicad_pcb")
            let kicad = try KiCadBoard.read(folder.appendingPathComponent(name))
            XCTAssertEqual(Self.differences(session.board, kicad), [], name)
            XCTAssertEqual(edit.generators.count, TuningPattern.all(kicad).count, name)
            count += TuningPattern.all(kicad).count
        }
        print("TuningPatternTests: \(count) patterns on \(boards.count) boards tuned as KiCad tuned them")
        XCTAssertGreaterThan(count, 0)
    }

    /// The same patterns edited one by one, as their properties are changed (editTuningPattern: each pattern of
    /// BOARD-placed given its properties of BOARD-edit, in the board's order), come out as KiCad's Update All made them
    func testPatternsAreEditedAsTheirPropertiesAreChanged() throws {
        var count = 0
        for board in try Self.boards() {
            let session = try Self.session(Self.sibling(board, "-placed"), project: board)
            let edited = try KiCadBoard.read(Self.sibling(board, "-edit"))
            let placed = Set(TuningPattern.all(session.board).map(\.uuid))
            // (patterns added in the file, of no base line: added to the board as they are, then tuned)
            for node in edited.root.all("generated") where !placed.contains(node.value("uuid") ?? "") {
                session.router.board.root.items.append(node.copy())
            }
            session.load(session.router.board.copy())
            for p in TuningPattern.all(edited) {
                let edit = session.editTuningPattern(p.uuid, settings: p.settings, end: BoardEditing.mm(p.end))
                XCTAssertEqual(edit?.name, "Edit Tuning Pattern")
                count += 1
            }
            let kicad = try KiCadBoard.read(Self.sibling(board, "-updated"))
            XCTAssertEqual(Self.differences(session.board, kicad), [], "\(board.lastPathComponent)")
        }
        print("TuningPatternTests: \(count) patterns edited one by one as KiCad tuned them")
        XCTAssertGreaterThan(count, 0)
    }

    // MARK: - Deleted as KiCad deletes one

    func testPatternsAreDeletedAsKiCadDeletesThem() throws {
        var count = 0
        for board in try Self.boards() {
            let record = board.deletingPathExtension().appendingPathExtension("removed")
            guard FileManager.default.fileExists(atPath: record.path) else { continue }
            let uuid = try XCTUnwrap(Self.json(record)["removed"] as? String)
            let session = try Self.session(Self.sibling(board, "-updated"), project: board)
            let before = session.tuningPatterns.count
            let edit = try XCTUnwrap(session.removeTuningPattern(uuid), board.lastPathComponent)
            XCTAssertEqual(edit.name, "Delete")
            XCTAssertEqual(edit.generators, [uuid])
            XCTAssertEqual(session.tuningPatterns.count, before - 1)
            let kicad = try KiCadBoard.read(Self.sibling(board, "-removed"))
            XCTAssertEqual(Self.differences(session.board, kicad), [], "\(board.lastPathComponent)")
            count += 1
        }
        print("TuningPatternTests: \(count) patterns deleted as KiCad deleted them")
        XCTAssertGreaterThan(count, 0)
    }

    // MARK: - Read and written as KiCad reads and writes them

    /// Every pattern KiCad wrote read by the port and written back: the board's text as KiCad wrote it; or, where
    /// BOARD.saved says how KiCad writes the board's patterns having read it (tuning.py saved), as that says (KiCad
    /// cuts a length to the nanometre as it reads it, so that one it wrote can come back a nanometre short)
    func testPatternsAreReadAndWrittenAsKiCadWritesThem() throws {
        var count = 0, cut = 0
        for board in try Self.boards() {
            for suffix in ["-placed", "-updated", "-removed", "-rules-updated"] {
                let url = Self.sibling(board, suffix)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                let b = try KiCadBoard.read(url)
                XCTAssertEqual(b.text, text, url.lastPathComponent)
                let record = url.deletingPathExtension().appendingPathExtension("saved")
                let saved = FileManager.default.fileExists(atPath: record.path)
                    ? try (Self.json(record)["saved"] as? [String] ?? []).map { try SExpr.parse($0).compact } : nil
                let nodes = b.root.items.filter { $0.head == "generated" }
                let expected = saved ?? nodes.map(\.compact)
                XCTAssertEqual(expected.count, nodes.count, url.lastPathComponent)
                for ((i, node), want) in zip(b.root.items.enumerated().filter { $0.1.head == "generated" }, expected) {
                    let p = try XCTUnwrap(TuningPattern(node))
                    XCTAssertEqual(p.node.compact, want, url.lastPathComponent)
                    if want != node.compact { cut += 1 }
                    b.root.items[i] = p.node
                    count += 1
                }
                if expected == nodes.map(\.compact) { XCTAssertEqual(b.text, text, url.lastPathComponent) }
            }
        }
        print("TuningPatternTests: \(count) patterns read and written as KiCad wrote them (\(cut) as KiCad writes them having read them)")
        XCTAssertGreaterThan(count, 0)
    }

    /// A pattern's properties as KiCad reads them (SetProperties): lengths cut toward 0 to the nanometre, a target
    /// delay not given taking the target length, a target's tolerance KiCad's where its min and max are not given
    func testPropertiesAreReadAsKiCadReadsThem() throws {
        let node = try SExpr.parse("""
            (generated (uuid "11111111-2222-4333-8444-555555555555") (type tuning_pattern) (name "Tuning Pattern") (layer "F.Cu")
             (corner_radius_percent 80.7) (end (xy 123.106666 69.538738)) (initial_side "left") (last_netname "N3")
             (last_status "tuned") (max_amplitude 0.29) (min_amplitude 0.2) (min_spacing 0.5999999)
             (origin (xy 126.961657 62.982391)) (override_custom_rules no) (rounded yes) (single_sided no)
             (target_length 50.1) (target_skew 0.0000007) (target_skew_max -0.3) (last_tuning_length 123.4567891)
             (last_track_width 0.2999999999) (tuning_mode "single") (members "900652df-021c-48ce-a4e1-fcd39bf1bc88"))
            """)
        let p = try XCTUnwrap(TuningPattern(node))
        // (what KiCad's pcbnew module wrote back of the same: tuning.py's reading of it, by hand)
        let kicad = try SExpr.parse("""
            (generated (uuid "11111111-2222-4333-8444-555555555555") (type tuning_pattern) (name "Tuning Pattern") (layer "F.Cu")
             (corner_radius_percent 80) (end (xy 123.106666 69.538738)) (initial_side "left") (is_time_domain no)
             (last_diff_pair_gap 0) (last_netname "N3") (last_status "tuned") (last_track_width 0.299999)
             (last_tuning_length 123.456789) (max_amplitude 0.29) (min_amplitude 0.2) (min_spacing 0.599999)
             (origin (xy 126.961657 62.982391)) (override_custom_rules no) (rounded yes) (single_sided no)
             (target_delay 50.1) (target_delay_max 50.2) (target_delay_min 50) (target_length 50.1)
             (target_length_max 50.2) (target_length_min 50) (target_skew 0) (target_skew_max -0.3)
             (target_skew_min -0.1) (tuning_mode "single") (members "900652df-021c-48ce-a4e1-fcd39bf1bc88"))
            """)
        XCTAssertEqual(p.node.compact, kicad.compact)
        // (no members: a pattern KiCad's parser drops)
        XCTAssertNil(TuningPattern(try SExpr.parse("(generated (uuid \"a\") (type tuning_pattern) (members))")))
    }

    // MARK: - The board's patterns, edited

    /// The board's patterns listed (their nets, modes, targets, what they came to); a pattern's track tuned again is
    /// the pattern's end dragged, as KiCad's point editor drags it, which comes out as the end set in its properties;
    /// the router keeps off a pattern's tracks (KiCad's router has them locked) but for the pattern being edited's
    func testPatternsAreListedAndTheirTracksEditThem() throws {
        var dragged = 0
        for board in try Self.boards().prefix(3) {
            let url = Self.sibling(board, "-placed")
            let session = try Self.session(url, project: board)
            let kicad = try KiCadBoard.read(url)
            let listed = session.tuningPatterns
            XCTAssertEqual(listed.map(\.uuid), TuningPattern.all(kicad).map(\.uuid))
            for (info, p) in zip(listed, TuningPattern.all(kicad)) {
                XCTAssertEqual(info.nets.first, p.lastNetName)
                XCTAssertEqual(info.nets.count, p.mode == .single ? 1 : 2)
                XCTAssertEqual(info.length, Double(p.tuningLength) / 1e6, accuracy: 1e-9)
                XCTAssertEqual(info.members.sorted(), p.members.sorted())
                XCTAssertFalse(info.outline.isEmpty)
                // (its tracks locked in the router's world; not while it is edited)
                let world = BoardWorld(board: kicad, project: BoardEditingTests.project(board))
                let members = Set(p.members)
                XCTAssertTrue(world.items.filter { members.contains($0.source ?? "") }.allSatisfy(\.locked))
                let editing = BoardWorld(board: kicad, project: BoardEditingTests.project(board), editing: p.uuid)
                XCTAssertTrue(editing.items.filter { members.contains($0.source ?? "") }.allSatisfy { !$0.locked })
            }
            // (each pattern's end dragged along its line, from one of its tracks, by the tune tool)
            for p in TuningPattern.all(kicad) {
                // (the track of it nearest its end: its end dragged, not its origin)
                func distance(_ n: SExpr) -> Int {
                    let a = BoardWorld.point(n["start"]), b = BoardWorld.point(n["end"])
                    return (IPoint((a.x + b.x) / 2, (a.y + b.y) / 2) - p.end).squaredNorm
                }
                guard let base = p.baseLine, base.segmentCount > 0, p.mode != .skew,
                      let member = kicad.copperItems.filter({ $0.head == "segment" && p.members.contains($0.value("uuid") ?? "") })
                        .min(by: { distance($0) < distance($1) })
                else { continue }
                let s = base.segment(-1)
                let newEnd = s.a + (s.b - s.a).divided(by: 4) * 3
                // (on its middle; three quarters of the way to its end nearer the pattern's end where its middle is
                // no nearer the pattern's end than its origin, the track the pattern's whole line)
                let a0 = BoardWorld.point(member["start"]), b0 = BoardWorld.point(member["end"])
                let (a, b) = (a0 - p.end).squaredNorm < (b0 - p.end).squaredNorm ? (b0, a0) : (a0, b0)
                let middle = IPoint((a.x + b.x) / 2, (a.y + b.y) / 2)
                let toEnd = (middle - p.end).squaredNorm < (middle - p.origin).squaredNorm
                let on = BoardEditing.mm(toEnd ? middle : a + (b - a).divided(by: 4) * 3)
                let drag = try Self.session(url, project: board)
                XCTAssertNotNil(drag.startTuning(at: on, layer: p.layer, mode: p.mode.tuningMode))
                XCTAssertTrue(drag.isTuning)
                XCTAssertEqual(drag.tuningPatternPreview?.uuid, p.uuid)
                drag.moveTuning(to: BoardEditing.mm(newEnd))
                let edit = try XCTUnwrap(drag.fixTuning(at: BoardEditing.mm(newEnd)))
                XCTAssertEqual(edit.name, "Edit Tuning Pattern")
                XCTAssertEqual(edit.generators, [p.uuid])
                XCTAssertEqual(drag.tuningPatterns.count, listed.count)
                let set = try Self.session(url, project: board)
                XCTAssertNotNil(set.editTuningPattern(p.uuid, end: BoardEditing.mm(newEnd)))
                XCTAssertEqual(Self.differences(drag.board, set.board), [], "\(url.lastPathComponent) \(p.uuid)")
                dragged += 1
            }
        }
        print("TuningPatternTests: \(dragged) patterns' ends dragged as their properties set them")
        XCTAssertGreaterThan(dragged, 0)
    }

    /// A pattern's tracks taken off the board leave it (KiCad's commit takes them out of their group); a pattern
    /// left with none is gone, as KiCad does not write one so. A change carried onto another copy of the board carries
    /// its patterns too.
    func testPatternsLoseTheTracksTakenAway() throws {
        let board = try XCTUnwrap(try Self.boards().first)
        let url = Self.sibling(board, "-placed")
        let session = try Self.session(url, project: board)
        let before = session.board.copy()
        let p = try XCTUnwrap(TuningPattern.all(session.board).first)
        let one = Set(p.members.prefix(1))
        _ = session.remove(one)
        let after = try XCTUnwrap(session.tuningPattern(p.uuid))
        XCTAssertEqual(Set(after.members), Set(p.members).subtracting(one))
        let edit = try XCTUnwrap(session.remove(Set(p.members)))
        XCTAssertNil(session.tuningPattern(p.uuid))
        XCTAssertTrue(edit.generators.contains(p.uuid))
        // (carried onto another copy of the board as it was)
        let other = before.copy()
        other.carryGenerators(from: before, to: session.board)
        XCTAssertEqual(other.root.all("generated").map(\.compact), session.board.root.all("generated").map(\.compact))
    }

    // MARK: - KiCad reads the port's patterns

    /// KiCad's reading of `files` (tuning.py check), nil where its pcbnew module or kicad-cli is not to be had
    static func kicadChecks(_ files: [URL]) throws -> [String: Any]? {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent("../../tools/kicad-reference/tuning.py").standardized
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, "check"] + files.map(\.path)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func testKiCadReadsThePortsPatterns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tuning-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var ours: [URL] = [], theirs: [URL] = []
        var boardsByURL: [URL: KiCadBoard] = [:]
        for board in try Self.boards().prefix(4) {
            let project = board.deletingPathExtension().appendingPathExtension("kicad_pro")
            func keep(_ b: KiCadBoard, _ name: String, kicad: URL) throws {
                let url = dir.appendingPathComponent("\(board.deletingPathExtension().lastPathComponent)\(name).kicad_pcb")
                try b.write(to: url)
                try? FileManager.default.copyItem(at: project, to: url.deletingPathExtension().appendingPathExtension("kicad_pro"))
                ours.append(url)
                theirs.append(kicad)
                boardsByURL[url] = b
            }
            let placed = try Self.place(board)
            try keep(placed.board, "-placed", kicad: Self.sibling(board, "-placed"))
            let updated = try Self.session(Self.sibling(board, "-edit"), project: board)
            _ = updated.updateAllTuningPatterns()
            try keep(updated.board, "-updated", kicad: Self.sibling(board, "-updated"))
        }
        guard let mine = try Self.kicadChecks(ours), let kicads = try Self.kicadChecks(theirs) else {
            throw XCTSkip("KiCad's pcbnew module or kicad-cli is not to be had")
        }
        var patterns = 0
        for (url, kicadURL) in zip(ours, theirs) {
            let o = try XCTUnwrap(mine[url.path] as? [String: Any]), k = try XCTUnwrap(kicads[kicadURL.path] as? [String: Any])
            let board = try XCTUnwrap(boardsByURL[url])
            let found = try XCTUnwrap(o["patterns"] as? [[String: Any]])
            XCTAssertEqual(o["generators"] as? Int, TuningPattern.all(board).count, url.lastPathComponent)
            for (entry, p) in zip(found, TuningPattern.all(board)) {
                XCTAssertEqual(entry["found"] as? Bool, true, url.lastPathComponent)
                XCTAssertEqual(entry["members"] as? [String], p.members.sorted(), url.lastPathComponent)
                patterns += 1
            }
            // (written back by KiCad as the port wrote them, as KiCad reads them: a length it reads cut to the
            // nanometre, as TuningPatternMemory has it)
            let saved = try (o["saved"] as? [String] ?? []).map { try SExpr.parse($0).compact }
            let read = board.copy()
            TuningPatternMemory().read(read)
            XCTAssertEqual(saved, read.root.all("generated").map(\.compact), url.lastPathComponent)
            // (KiCad's DRC: what it finds on KiCad's own board, by the items' descriptions)
            XCTAssertEqual(o["drc"] as? [String], k["drc"] as? [String], url.lastPathComponent)
        }
        print("TuningPatternTests: KiCad read \(patterns) of the port's patterns on \(ours.count) boards")
    }
}
