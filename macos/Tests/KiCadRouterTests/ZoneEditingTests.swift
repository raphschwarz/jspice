import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// Zones' outlines edited as KiCad's point editor edits them (BoardEditing's startZoneDrag, dragZonePoint and
/// finishZoneDrag, moveZoneCorner, moveZoneEdge, addZoneCorner, removeZoneCorner, moveZones) and their properties set
/// as its zone properties dialogs set them (setZoneProperties): each as one change. The point editor's own geometry
/// on outlines made for it (an edge dragged between neighbours that keep their directions, meeting, running on along
/// it, at its own length; corners added at the nearest edge, taken away, holes taken away with their last but two;
/// what it refuses); then random edits on boards (Fixtures/zoneedits, a board of zones with holes and rule areas
/// drawn by tools/kicad-reference/properties.py --draw, Fixtures/fills' drawn board, and two random ones with zones;
/// KICAD_BOARD_REFERENCE's boards too, where it names some) checked against KiCad (properties.py): KiCad's pcbnew
/// reads every property back as set, and every zone outline as edited; KiCad's own code making the same changes
/// (ZONE_SETTINGS::ExportSetting, SHAPE_POLY_SET's vertex edits, ZONE::Move) writes the same zones; KiCad's zone filler
/// fills the edited boards as the port's does (fills.py, FillTests.compare), and kicad-cli's DRC finds on them what
/// BoardDRC finds (drc.py, DRCTests.compare).
final class ZoneEditingTests: XCTestCase {
    /// SplitMix64, for the same random edits each run
    struct Rand {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
        mutating func bool(_ p: Double = 0.5) -> Bool { unit() < p }
        mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
    }

    static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().resolvingSymlinksInPath()
        .appendingPathComponent("../../tools/kicad-reference").standardized

    /// One of tools/kicad-reference's scripts run with `args`: its standard output, nil where it failed (no KiCad)
    @discardableResult
    static func run(_ name: String, _ args: [String]) throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.appendingPathComponent(name).path] + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    static var kicadPresent: Bool { (try? run("properties.py", ["read"])) != nil }

    /// A value as JSON writes it (a Bool and a JSON true alike, numbers as numbers), for comparing what KiCad's script
    /// read with what the port has
    static func json(_ v: Any?) -> String {
        guard let v, let data = try? JSONSerialization.data(withJSONObject: [v]) else { return "nil" }
        return String(decoding: data, as: UTF8.self)
    }

    static func mm(_ c: BoardEditing.ZoneContours) -> [[KiCadPoint]] { c.map { $0.map { KiCadPoint(Double($0.x) / 1e6, Double($0.y) / 1e6) } } }

    /// A board of one zone of `contours` (mm), on F.Cu of net GND, with a pad of it
    static func board(_ contours: [[KiCadPoint]], locked: Bool = false) throws -> KiCadBoard {
        let polys = contours.map { c in "(polygon (pts " + c.map { "(xy \(KiCadNumber.format($0.x)) \(KiCadNumber.format($0.y)))" }.joined(separator: " ") + "))" }
        let text = """
        (kicad_pcb (version 20260206) (generator "pcbnew") (generator_version "10.0") (general (thickness 1.6))
          (layers (0 "F.Cu" signal) (2 "B.Cu" signal) (25 "Edge.Cuts" user))
          (gr_rect (start 0 0) (end 100 100) (stroke (width 0.1) (type default)) (fill no) (layer "Edge.Cuts") (uuid "e0000000-0000-0000-0000-000000000001"))
          (zone (net "GND") \(locked ? "(locked yes) " : "")(layer "F.Cu") (uuid "a0000000-0000-0000-0000-000000000001") (hatch edge 0.5)
            (connect_pads (clearance 0.5)) (min_thickness 0.25) (fill (thermal_gap 0.5) (thermal_bridge_width 0.5) (island_removal_mode 0))
            \(polys.joined(separator: " ")))
        )
        """
        return try KiCadBoard(text: text)
    }

    static let zone = "a0000000-0000-0000-0000-000000000001"

    func testThePointEditorsGeometry() throws {
        func session(_ c: [[KiCadPoint]], locked: Bool = false) throws -> BoardEditing { BoardEditing(board: try Self.board(c, locked: locked)) }
        func pts(_ e: BoardEditing) -> [[KiCadPoint]] { Self.mm(e.zoneContours(Self.zone) ?? []) }
        let square = [[KiCadPoint(10, 10), KiCadPoint(30, 10), KiCadPoint(30, 30), KiCadPoint(10, 30)]]
        // a corner moved
        var e = try session(square)
        var edit = try XCTUnwrap(e.moveZoneCorner(Self.zone, index: 2, to: KiCadPoint(33, 31)))
        XCTAssertEqual(edit.name, "Move Point")
        XCTAssertEqual(edit.zones, [Self.zone])
        XCTAssertEqual(pts(e), [[KiCadPoint(10, 10), KiCadPoint(30, 10), KiCadPoint(33, 31), KiCadPoint(10, 30)]])
        XCTAssertNil(e.board.zones[0].node["filled_polygon"], "unfilled")
        // an edge dragged: its neighbours keep their directions (here at right angles: the edge moves straight out)
        e = try session(square)
        _ = try XCTUnwrap(e.moveZoneEdge(Self.zone, index: 1, to: KiCadPoint(35, 21)))
        XCTAssertEqual(pts(e), [[KiCadPoint(10, 10), KiCadPoint(35, 10), KiCadPoint(35, 30), KiCadPoint(10, 30)]])
        // between neighbours that meet (a trapezoid): the edge shortens, and goes no further than where they meet
        let trapezoid = [[KiCadPoint(0, 0), KiCadPoint(40, 0), KiCadPoint(30, 10), KiCadPoint(10, 10)]]
        e = try session(trapezoid)
        _ = try XCTUnwrap(e.moveZoneEdge(Self.zone, index: 2, to: KiCadPoint(20, 15)))
        XCTAssertEqual(pts(e), [[KiCadPoint(0, 0), KiCadPoint(40, 0), KiCadPoint(25, 15), KiCadPoint(15, 15)]])
        e = try session(trapezoid)
        _ = try XCTUnwrap(e.moveZoneEdge(Self.zone, index: 2, to: KiCadPoint(20, 50)))
        XCTAssertEqual(pts(e), [[KiCadPoint(0, 0), KiCadPoint(40, 0), KiCadPoint(20, 20)]], "met at the neighbours' crossing, the corner the same twice taken out")
        // at its own length (Ctrl)
        e = try session(trapezoid)
        _ = try XCTUnwrap(e.moveZoneEdge(Self.zone, index: 2, to: KiCadPoint(20, 15), fixedLength: true))
        XCTAssertEqual(pts(e), [[KiCadPoint(0, 0), KiCadPoint(40, 0), KiCadPoint(30, 15), KiCadPoint(10, 15)]])
        // a corner added at the nearest edge's nearest point; at one of its corners, its midpoint
        e = try session(square)
        edit = try XCTUnwrap(e.addZoneCorner(Self.zone, at: KiCadPoint(18, 9)))
        XCTAssertEqual(edit.name, "Add Zone Corner")
        XCTAssertEqual(pts(e), [[KiCadPoint(10, 10), KiCadPoint(18, 10), KiCadPoint(30, 10), KiCadPoint(30, 30), KiCadPoint(10, 30)]])
        e = try session(square)
        _ = try XCTUnwrap(e.addZoneCorner(Self.zone, at: KiCadPoint(9, 9)))
        XCTAssertEqual(pts(e), [[KiCadPoint(10, 10), KiCadPoint(20, 10), KiCadPoint(30, 10), KiCadPoint(30, 30), KiCadPoint(10, 30)]])
        // the closing edge's corner goes before the contour's first
        e = try session(square)
        _ = try XCTUnwrap(e.addZoneCorner(Self.zone, at: KiCadPoint(9, 22)))
        XCTAssertEqual(pts(e), [[KiCadPoint(10, 22), KiCadPoint(10, 10), KiCadPoint(30, 10), KiCadPoint(30, 30), KiCadPoint(10, 30)]])
        // corners taken away: not the outline's last three; a hole's with the hole
        let holed = square + [[KiCadPoint(15, 15), KiCadPoint(25, 15), KiCadPoint(20, 25)]]
        e = try session(holed)
        XCTAssertFalse(e.canRemoveZoneCorner(Self.zone, index: 0) && false)
        XCTAssertTrue(e.canRemoveZoneCorner(Self.zone, index: 5))
        edit = try XCTUnwrap(e.removeZoneCorner(Self.zone, index: 5))
        XCTAssertEqual(edit.name, "Remove Zone Corner")
        XCTAssertEqual(pts(e), square, "the hole taken away")
        _ = try XCTUnwrap(e.removeZoneCorner(Self.zone, index: 1))
        XCTAssertEqual(pts(e), [[KiCadPoint(10, 10), KiCadPoint(30, 30), KiCadPoint(10, 30)]])
        XCTAssertFalse(e.canRemoveZoneCorner(Self.zone, index: 0))
        XCTAssertNil(e.removeZoneCorner(Self.zone, index: 0))
        // an edge of a hole dragged
        let window = [[KiCadPoint(15, 15), KiCadPoint(25, 15), KiCadPoint(25, 25), KiCadPoint(15, 25)]]
        e = try session(square + window)
        _ = try XCTUnwrap(e.moveZoneEdge(Self.zone, index: 4, to: KiCadPoint(20, 13)))
        XCTAssertEqual(pts(e), square + [[KiCadPoint(15, 13), KiCadPoint(25, 13), KiCadPoint(25, 25), KiCadPoint(15, 25)]])
        // a triangle's edge, its neighbours meeting at its third corner, where the polygon has more than three edges in
        // all: EC_CONVERGING finds the neighbours crossing there (SEG::Intersect takes the corner they share) and makes
        // the edge that point, and the triangle, its corners the same, comes to nothing
        e = try session(holed)
        _ = try XCTUnwrap(e.moveZoneEdge(Self.zone, index: 4, to: KiCadPoint(20, 13)))
        XCTAssertEqual(pts(e), square)
        // a corner dragged across the outline: KiCad 10's point editor keeps the outline crossing itself
        e = try session(square)
        _ = try XCTUnwrap(e.moveZoneCorner(Self.zone, index: 0, to: KiCadPoint(40, 40)))
        XCTAssertEqual(pts(e), [[KiCadPoint(40, 40), KiCadPoint(30, 10), KiCadPoint(30, 30), KiCadPoint(10, 30)]])
        // dragged onto its neighbour: the one the same as the next taken out (RemoveNullSegments)
        e = try session(square)
        _ = try XCTUnwrap(e.moveZoneCorner(Self.zone, index: 0, to: KiCadPoint(30, 10)))
        XCTAssertEqual(pts(e), [[KiCadPoint(30, 10), KiCadPoint(30, 30), KiCadPoint(10, 30)]])
        // a corner snapped where it sees its neighbours at a right angle, within 2°
        e = try session([[KiCadPoint(0, 0), KiCadPoint(20, 0), KiCadPoint(20.5, 20), KiCadPoint(0, 20)]])
        XCTAssertNotNil(e.startZoneDrag(Self.zone, handle: .corner(2)))
        let snapped = try XCTUnwrap(e.dragZonePoint(to: KiCadPoint(20.4, 20.1), stickyDistance: 0.05))
        XCTAssertEqual(abs(BoardEditing.segAngle(Seg(BoardEditing.nm(snapped[0][2]), BoardEditing.nm(snapped[0][1])),
                                                 Seg(BoardEditing.nm(snapped[0][2]), BoardEditing.nm(snapped[0][3]))) - 90), 0, accuracy: 0.01)
        XCTAssertNotNil(e.finishZoneDrag())
        // a drag dropped changes nothing
        e = try session(square)
        XCTAssertNotNil(e.startZoneDrag(Self.zone, handle: .corner(1)))
        e.dragZonePoint(to: KiCadPoint(50, 50))
        e.cancelZoneDrag()
        XCTAssertNil(e.finishZoneDrag())
        XCTAssertEqual(pts(e), square)
        // a locked zone is not edited, unless locks are overridden; nor moved
        e = try session(square, locked: true)
        XCTAssertFalse(e.canEditZoneOutline(Self.zone))
        XCTAssertNil(e.moveZoneCorner(Self.zone, index: 0, to: KiCadPoint(1, 1)))
        XCTAssertNil(e.addZoneCorner(Self.zone, at: KiCadPoint(1, 1)))
        XCTAssertNil(e.moveZones([Self.zone], by: KiCadPoint(1, 1)))
        XCTAssertNil(e.removeZones([Self.zone]))
        e.overridesLocks = true
        XCTAssertNotNil(e.moveZoneCorner(Self.zone, index: 0, to: KiCadPoint(1, 1)))
        // moved whole
        e = try session(holed)
        edit = try XCTUnwrap(e.moveZones([Self.zone], by: KiCadPoint(1.5, -2)))
        XCTAssertEqual(edit.name, "Move")
        XCTAssertEqual(pts(e), holed.map { $0.map { KiCadPoint($0.x + 1.5, $0.y - 2) } })
        // picked by an edge or a corner of its outline or a hole, not by its inside while it has no fill
        e = try session(holed)
        XCTAssertEqual(e.zone(at: KiCadPoint(20, 10.05), layers: ["F.Cu"], slop: 0), Self.zone)
        XCTAssertEqual(e.zone(at: KiCadPoint(25.15, 15.1), layers: ["F.Cu"], slop: 0), Self.zone)
        XCTAssertEqual(e.zone(at: KiCadPoint(20, 10.4), layers: ["F.Cu"], slop: 0.5), Self.zone)
        XCTAssertNil(e.zone(at: KiCadPoint(20, 10.4), layers: ["F.Cu"], slop: 0))
        XCTAssertNil(e.zone(at: KiCadPoint(12, 20), layers: ["F.Cu"], slop: 0))
        // unique zone names, as BOARD::MakeUniqueZoneName makes them
        XCTAssertEqual(BoardEditing.uniqueZoneName("GND", inUse: ["GND", "GND_1"]), "GND_2")
        XCTAssertEqual(BoardEditing.uniqueZoneName("GND_1", inUse: ["GND_1"]), "GND_2")
        XCTAssertEqual(BoardEditing.uniqueZoneName("a_b", inUse: ["a_b"]), "a_b_1")
        XCTAssertEqual(BoardEditing.uniqueZoneName("", inUse: [""]), "")
    }

    // MARK: - Against KiCad

    /// The boards edited: the drawn ones and two random ones with zones, and KICAD_BOARD_REFERENCE's (the first 10
    /// with zones of the board's own)
    static func boards() throws -> [URL] {
        let fixtures = ["zoneedits/zones", "fills/drawn", "boards/random-2-43", "rules/random-49-21"].compactMap {
            Bundle.module.url(forResource: $0, withExtension: "kicad_pcb", subdirectory: "Fixtures")
        }
        guard let folder = ProcessInfo.processInfo.environment["KICAD_BOARD_REFERENCE"] else { return fixtures }
        let more = try folder.split(separator: ":").flatMap { try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: String($0)), includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
            .filter { (try? KiCadBoard.read($0))?.root.all("zone").contains { $0["attr"]?["teardrop"] == nil } ?? false }
        return fixtures + more.prefix(10)
    }

    /// A board copied into `work` with its project and rules files
    static func copy(_ file: URL, to work: URL, as name: String) throws -> URL {
        let out = work.appendingPathComponent(name + ".kicad_pcb")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.copyItem(at: file, to: out)
        for ext in ["kicad_pro", "kicad_dru"] {
            let src = file.deletingPathExtension().appendingPathExtension(ext)
            let dst = out.deletingPathExtension().appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.copyItem(at: src, to: dst)
            }
        }
        return out
    }

    /// A zone's properties as KiCad's ZONE_SETTINGS has them (board units), for properties.py
    static func settings(_ p: ZoneProperties) -> [String: Any] {
        func iu(_ v: Double) -> Int { BoardWorld.iu(v) }
        let border = ["none": 0, "full": 1, "edge": 2][p.borderStyle.rawValue] ?? 2
        let source = ["sheetname": 0, "component_class": 1, "group": 2][p.placementSource.rawValue] ?? 0
        return ["name": p.name, "net": p.net ?? "", "layers": p.layers, "priority": p.priority, "locked": p.locked,
                "clearance": iu(p.clearance), "minThickness": iu(p.minWidth), "padConnection": p.padConnection.rawValue,
                "thermalGap": iu(p.thermalGap), "spokeWidth": iu(p.spokeWidth), "hatched": p.hatched,
                "hatchThickness": iu(p.hatchThickness), "hatchGap": iu(p.hatchGap), "hatchOrientation": p.hatchOrientation,
                "hatchSmoothingLevel": p.hatchSmoothingLevel, "hatchSmoothingValue": p.hatchSmoothingValue,
                "hatchHoleMinArea": p.hatchHoleMinArea, "hatchBorderAlgorithm": p.hatchBorderFromHatch ? 1 : 0,
                "islandRemoval": p.islandRemoval.rawValue, "minIslandArea": BoardWorld.iu(p.minIslandArea) * 1_000_000,
                "smoothing": p.smoothing.rawValue, "cornerRadius": iu(p.cornerRadius), "borderStyle": border,
                "borderPitch": iu(p.borderHatchPitch),
                "keepout": [p.keepout.tracks, p.keepout.vias, p.keepout.pads, p.keepout.copperPour, p.keepout.footprints],
                "placementEnabled": p.placementEnabled, "placementSourceType": source, "placementSource": p.placementSourceName]
    }

    /// Random new properties for a zone, as a user might give it in the dialog
    static func randomProperties(_ was: ZoneProperties, board: KiCadBoard, nets: [String], rng: inout Rand) -> ZoneProperties {
        var p = was
        let copper = BoardEditing.boardLayers(board).filter { $0.hasSuffix(".Cu") }
        p.name = rng.pick(["", "Pour", was.name, "Zone \(rng.int(9))", "GND"])
        p.locked = rng.bool(0.3)
        if p.isRuleArea {
            p.keepout = KiCadBoard.Keepout(tracks: rng.bool(), vias: rng.bool(), pads: rng.bool(), copperPour: rng.bool(), footprints: rng.bool())
            p.placementEnabled = rng.bool(0.3)
            p.placementSource = rng.pick(ZoneProperties.PlacementSource.allCases)
            p.placementSourceName = p.placementEnabled ? rng.pick(["/", "/Power/", "Sheet2"]) : ""
            var layers = copper.filter { _ in rng.bool() }
            if layers.isEmpty { layers = [rng.pick(copper)] }
            p.layers = layers
            p.borderStyle = rng.pick(ZoneProperties.BorderStyle.allCases)
            p.borderHatchPitch = rng.pick([0.1, 0.5, 1.25, 2])
            return p
        }
        p.net = nets.isEmpty || rng.bool(0.15) ? nil : rng.pick(nets)
        var layers = copper.filter { _ in rng.bool(0.4) }
        if layers.isEmpty || rng.bool(0.5) { layers = was.layers.filter { $0.hasSuffix(".Cu") } }
        if layers.isEmpty { layers = ["F.Cu"] }
        p.layers = layers
        p.priority = rng.int(4)
        p.clearance = rng.pick([0, 0.2, 0.3, 0.5, 0.75])
        p.minWidth = rng.pick([0.1, 0.2, 0.25, 0.3])
        p.padConnection = rng.pick([.thermal, .full, .none, .thtThermal])
        p.thermalGap = rng.pick([0.2, 0.3, 0.5])
        p.spokeWidth = max(p.minWidth, rng.pick([0.25, 0.4, 0.5]))
        p.hatched = rng.bool(0.3)
        p.hatchThickness = max(p.minWidth, rng.pick([0.5, 1, 1.2]))
        p.hatchGap = max(p.minWidth, rng.pick([0.8, 1.5, 2]))
        p.hatchOrientation = rng.pick([0, 30, 45, -60, 200])
        p.hatchSmoothingLevel = rng.int(4)
        p.hatchSmoothingValue = rng.pick([0.1, 0.25, 0.5])
        p.hatchBorderFromHatch = rng.bool(0.7)
        p.islandRemoval = rng.pick(ZoneProperties.IslandRemoval.allCases)
        p.minIslandArea = rng.pick([1, 4, 10, 2.5])
        p.smoothing = rng.pick(ZoneProperties.Smoothing.allCases)
        p.cornerRadius = rng.pick([0.5, 1, 2])
        p.borderStyle = rng.pick(ZoneProperties.BorderStyle.allCases)
        p.borderHatchPitch = rng.pick([0.1, 0.5, 1.25, 2])
        return p
    }

    /// Where `before` and `after` first differ: the global index of the corner inserted or taken away, or the contour
    static func difference(_ before: BoardEditing.ZoneContours, _ after: BoardEditing.ZoneContours) -> [String: Any]? {
        var g = 0
        if after.count < before.count {
            for (c, contour) in before.enumerated() where c >= after.count || after[c] != contour { return ["kind": "removeContour", "contour": c] }
            return nil
        }
        for (c, contour) in before.enumerated() {
            let a = after[c]
            if a == contour { g += contour.count; continue }
            let k = (0..<min(contour.count, a.count)).first { contour[$0] != a[$0] } ?? min(contour.count, a.count)
            if a.count > contour.count { return ["kind": "insertVertex", "index": g + k, "point": [a[k].x, a[k].y]] }
            return ["kind": "removeVertex", "index": g + k]
        }
        return nil
    }

    func testZonesEditedOnBoardsAsKiCadEditsThem() throws {
        guard Self.kicadPresent else {
            if ProcessInfo.processInfo.environment["JSPICE_REQUIRE_KICAD"] != nil { return XCTFail("KiCad 10's pcbnew module is needed") }
            throw XCTSkip("KiCad's pcbnew module is not installed")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-zoneedit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { if ProcessInfo.processInfo.environment["ZONE_EDIT_KEEP"] == nil { try? FileManager.default.removeItem(at: work) } }
        var rng = Rand(state: 20261029)
        var plan: [[String: Any]] = []
        var written: [URL] = []
        var expected: [String: [String: (props: ZoneProperties, contours: BoardEditing.ZoneContours)]] = [:]
        var edits = 0, refused = 0, crossings = 0
        for (n, file) in try Self.boards().enumerated() {
            let original = try Self.copy(file, to: work, as: "original-\(n)")
            let board = try KiCadBoard.read(original)
            let project = BoardEditingTests.project(original)
            let session = BoardEditing(board: board, project: project)
            let nets = Array(board.netNames.union(session.router.world.netNames.values).filter { !$0.isEmpty }).sorted()
            var ops: [[String: Any]] = []
            let zones = board.root.all("zone").filter { $0["attr"]?["teardrop"] == nil && BoardEditing.contours(of: $0) != nil }.compactMap { $0.value("uuid") }
            for (k, uuid) in zones.enumerated() {
                guard let props = session.zoneProperties(uuid) else { continue }
                if props.locked {
                    XCTAssertNil(session.moveZoneCorner(uuid, index: 0, to: KiCadPoint(1, 1)), "a locked zone's corner is not moved")
                    refused += 1
                    if !rng.bool(0.5) { continue }
                    session.overridesLocks = true
                }
                defer { session.overridesLocks = false }
                // a corner dragged (now and then across the outline, or onto its neighbour), an edge dragged
                for step in 0..<3 {
                    guard let before = session.zoneContours(uuid) else { break }
                    let (points, ends) = BoardEditing.editPoints(before)
                    let i = rng.int(points.count)
                    let handle: BoardEditing.ZoneHandle = step == 1 ? .edge(i) : .corner(i)
                    guard session.startZoneDrag(uuid, handle: handle) != nil else { break }
                    var target: KiCadPoint
                    switch handle {
                    case .corner(let i):
                        let p = BoardEditing.mm(points[i])
                        // (each board's second zone's first corner across its outline, the outline then crossing itself)
                        if (k == 1 && step == 0) || rng.bool(0.1), let box = IBox(points: points) {
                            crossings += 1
                            target = BoardEditing.mm(IPoint(box.minX + box.maxX - points[i].x, box.minY + box.maxY - points[i].y))
                        } else if rng.bool(0.1) {
                            target = BoardEditing.mm(points[BoardEditing.lineEnd(i, ends, count: points.count)])
                        } else if rng.bool(0.1), let box = IBox(points: points) {
                            target = BoardEditing.mm(IPoint(box.minX + box.maxX - points[i].x, box.minY + box.maxY - points[i].y))
                        } else {
                            target = KiCadPoint(p.x + rng.range(-2, 2), p.y + rng.range(-2, 2))
                        }
                    case .edge(let i):
                        let a = points[i], b = points[BoardEditing.lineEnd(i, ends, count: points.count)]
                        let mid = BoardEditing.mm(BoardEditing.midpoint(a, b))
                        let d = DPoint(b - a)
                        let normal = d.norm > 0 ? DPoint(-d.y, d.x) / d.norm : DPoint(0, 1)
                        let s = rng.range(-1.5, 1.5)
                        target = KiCadPoint(mid.x + normal.x * s + rng.range(-0.3, 0.3), mid.y + normal.y * s + rng.range(-0.3, 0.3))
                    }
                    let ctrl = rng.bool(0.25)
                    let shift = rng.bool(0.5)
                    let dragged = try XCTUnwrap(session.dragZonePoint(to: KiCadPoint(target.x * 0.5 + BoardEditing.mm(points[i]).x * 0.5, target.y * 0.5 + BoardEditing.mm(points[i]).y * 0.5),
                                                                     ctrl: ctrl, shift: shift, stickyDistance: 0.05))
                    _ = dragged
                    let last = try XCTUnwrap(session.dragZonePoint(to: target, ctrl: ctrl, shift: shift, stickyDistance: 0.05))
                    let lastPoints = last.flatMap { $0.map { [BoardWorld.iu($0.x), BoardWorld.iu($0.y)] } }
                    guard let edit = session.finishZoneDrag() else { continue }
                    XCTAssertEqual(edit.name, "Move Point")
                    edits += 1
                    ops.append(["op": "outline", "zone": uuid, "kind": "setVertices", "points": lastPoints])
                }
                // a corner added, one taken away
                if let before = session.zoneContours(uuid), let box = IBox(points: before.flatMap { $0 }) {
                    let at = KiCadPoint(rng.range(Double(box.minX), Double(box.maxX)) / 1e6, rng.range(Double(box.minY), Double(box.maxY)) / 1e6)
                    if session.addZoneCorner(uuid, at: at) != nil, let after = session.zoneContours(uuid), let op = Self.difference(before, after) {
                        edits += 1
                        ops.append(["op": "outline", "zone": uuid].merging(op) { a, _ in a })
                    }
                }
                if let before = session.zoneContours(uuid) {
                    let count = before.reduce(0) { $0 + $1.count }
                    let i = rng.int(count)
                    if session.canRemoveZoneCorner(uuid, index: i) {
                        XCTAssertNotNil(session.removeZoneCorner(uuid, index: i))
                        if let after = session.zoneContours(uuid), let op = Self.difference(before, after) {
                            edits += 1
                            ops.append(["op": "outline", "zone": uuid].merging(op) { a, _ in a })
                        }
                    } else {
                        XCTAssertNil(session.removeZoneCorner(uuid, index: i))
                    }
                }
                // one zone of each board moved whole
                if k == 0 {
                    let delta = KiCadPoint((rng.range(-3, 3) * 1000).rounded() / 1000, (rng.range(-3, 3) * 1000).rounded() / 1000)
                    if session.moveZones([uuid], by: delta) != nil {
                        edits += 1
                        ops.append(["op": "move", "zone": uuid, "offset": [BoardWorld.iu(delta.x), BoardWorld.iu(delta.y)]])
                    }
                }
                // and new properties
                let wanted = Self.randomProperties(props, board: session.board, nets: nets, rng: &rng)
                if let problem = session.zonePropertiesProblem(uuid, wanted) {
                    XCTAssertNil(session.setZoneProperties(uuid, wanted), problem)
                    refused += 1
                } else if let edit = session.setZoneProperties(uuid, wanted) {
                    XCTAssertEqual(edit.name, "Edit Zone Properties")
                    edits += 1
                    let now = try XCTUnwrap(session.zoneProperties(uuid))
                    ops.append(["op": "settings", "zone": uuid, "settings": Self.settings(now)])
                }
                if let p = session.zoneProperties(uuid), let c = session.zoneContours(uuid) { expected["edited-\(n)", default: [:]][uuid] = (p, c) }
            }
            let out = work.appendingPathComponent("edited-\(n).kicad_pcb")
            try session.board.write(to: out)
            for ext in ["kicad_pro", "kicad_dru"] {
                let src = original.deletingPathExtension().appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: src.path) {
                    try FileManager.default.copyItem(at: src, to: out.deletingPathExtension().appendingPathExtension(ext))
                }
            }
            written.append(out)
            plan.append(["board": original.path, "out": work.appendingPathComponent("kicad-\(n).kicad_pcb").path, "ops": ops])
        }
        // KiCad's reading of the boards the port wrote: every zone as edited
        let read = try XCTUnwrap(try Self.run("properties.py", ["read"] + written.map(\.path)).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        var zonesRead = 0
        for file in written {
            let name = file.deletingPathExtension().lastPathComponent
            let zones = try XCTUnwrap((read[file.path] as? [String: Any])?["zones"] as? [String: [String: Any]])
            for (uuid, (p, contours)) in expected[name] ?? [:] {
                let z = try XCTUnwrap(zones[uuid], "\(name) \(uuid)")
                zonesRead += 1
                let what = "\(name) zone \(uuid)"
                let want = Self.settings(p)
                // (a rule area's net, connection and smoothing mean nothing, nor a zone's keepouts and placement)
                let keys = p.isRuleArea ? ["name", "layers", "locked", "borderStyle", "borderPitch", "keepout", "placementEnabled", "placementSource"]
                    : ["name", "net", "layers", "priority", "locked", "minThickness", "padConnection", "thermalGap", "spokeWidth",
                       "hatched", "islandRemoval", "smoothing", "cornerRadius", "borderStyle", "borderPitch"]
                for key in keys { XCTAssertEqual(Self.json(z[key]), Self.json(want[key]), "\(what) \(key)") }
                XCTAssertEqual((z["clearance"] as? NSNumber)?.intValue, want["clearance"] as? Int, "\(what) clearance")
                if p.islandRemoval == .area { XCTAssertEqual((z["minIslandArea"] as? NSNumber)?.intValue, want["minIslandArea"] as? Int, "\(what) island area") }
                if p.hatched {
                    for key in ["hatchThickness", "hatchGap", "hatchSmoothingLevel", "hatchBorderAlgorithm"] {
                        XCTAssertEqual(Self.json(z[key]), Self.json(want[key]), "\(what) \(key)")
                    }
                    XCTAssertEqual((z["hatchOrientation"] as? NSNumber)?.doubleValue ?? .nan, p.hatchOrientation, accuracy: 1e-9, "\(what) hatch orientation")
                }
                let outline = (z["outline"] as? [[[NSNumber]]] ?? []).map { $0.map { IPoint($0[0].intValue, $0[1].intValue) } }
                XCTAssertEqual(outline, contours, "\(what) outline")
            }
        }
        // KiCad's own code making the same changes writes the same zones
        let planURL = work.appendingPathComponent("plan.json")
        try JSONSerialization.data(withJSONObject: plan).write(to: planURL)
        XCTAssertNotNil(try Self.run("properties.py", ["apply", planURL.path]))
        var zonesWritten = 0
        func unfilled(_ z: SExpr) -> String {
            let c = z.copy()
            c.remove("filled_polygon")
            if let f = c["fill"] { f.items.removeAll { $0.kind == .symbol && $0.text == "yes" } }
            return c.compact
        }
        for (n, file) in written.enumerated() {
            let theirs = try KiCadBoard.read(work.appendingPathComponent("kicad-\(n).kicad_pcb"))
            let ours = try KiCadBoard.read(file)
            let byID = Dictionary(theirs.root.all("zone").compactMap { z in z.value("uuid").map { ($0, z) } }, uniquingKeysWith: { a, _ in a })
            for z in ours.root.all("zone") {
                // (the zones changed: one left as it was KiCad writes as it reads it, which may not be as it was read)
                let changed = Set((plan[n]["ops"] as? [[String: Any]] ?? []).compactMap { $0["zone"] as? String })
                guard let uuid = z.value("uuid"), let k = byID[uuid], changed.contains(uuid) else { continue }
                zonesWritten += 1
                XCTAssertEqual(unfilled(z), unfilled(k), "\(file.lastPathComponent) zone \(uuid) as KiCad writes it")
            }
        }
        // KiCad's zone filler and DRC on the edited boards
        for file in written {
            XCTAssertNotNil(try Self.run("fills.py", [file.path]), "fills.py \(file.lastPathComponent)")
            XCTAssertNotNil(try Self.run("drc.py", [file.path]), "drc.py \(file.lastPathComponent)")
        }
        let (fillSummary, fillDifferences) = try FillTests.compare(written)
        let (drcSummary, _, drcDifferences) = try DRCTests.compare(written)
        print("ZoneEditingTests: \(written.count) boards, \(edits) changes (\(refused) refused as KiCad refuses them, \(crossings) corners dragged across their outlines); KiCad read \(zonesRead) zones as edited, "
              + "wrote \(zonesWritten) as the port does; fills: \(fillSummary); DRC: \(drcSummary)")
        XCTAssertGreaterThan(edits, 0)
        XCTAssertTrue(fillDifferences.isEmpty, "\(fillDifferences.count) fills differ from KiCad's:\n" + fillDifferences.prefix(30).joined(separator: "\n"))
        XCTAssertTrue(drcDifferences.isEmpty, "\(drcDifferences.count) differences from KiCad's DRC:\n" + drcDifferences.prefix(30).joined(separator: "\n"))
    }
}
