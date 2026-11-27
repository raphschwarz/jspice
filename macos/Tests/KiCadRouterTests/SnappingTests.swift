import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// Where the pointer snaps to the board's items, the port's (BoardSnapping.swift: PCBGridHelper on a SnapBoard)
/// against KiCad's own: tools/kicad-reference/snapping.py draws lines with KiCad's Draw Lines tool, the pointer moved
/// to pixels near the board's pads, tracks, vias, footprints, zones and graphics (and level with them, and anywhere)
/// and clicked, with the Magnetic Points snapping to pads, tracks and graphics always and KiCad 10's extension snaps
/// off, some boards opened on local settings that dim the inactive layers or hide objects; NAME.snapped has every
/// event and the lines KiCad drew. The port, given the same pointer positions (the view's
/// transform applied to the pixels) in the same order, a grid helper of its own for each line as each Draw Lines has
/// one, and the board as it then was (the lines drawn before on it), must put each line's ends where KiCad did, to the
/// nanometre. KICAD_SNAPPING_REFERENCE names a folder of such boards (or several, separated by colons); with none,
/// Fixtures/snapping.
final class SnappingTests: XCTestCase {
    static var folders: [URL] {
        if let f = ProcessInfo.processInfo.environment["KICAD_SNAPPING_REFERENCE"] {
            return f.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        return ["snapping"].compactMap { Bundle.module.url(forResource: $0, withExtension: nil, subdirectory: "Fixtures") }
    }

    func testDrawnLinesEndWhereKiCadSnapsThem() throws {
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "snapped" }.sorted { $0.path < $1.path }
        var lines = 0, snappedToItems = 0, unsure = 0, missed = 0, differences: [String] = []
        for file in files {
            guard let record = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                  let events = record["events"] as? [[String: Any]], let t = record["transform"] as? [String: Double] else { continue }
            let boardURL = file.deletingPathExtension().appendingPathExtension("kicad_pcb")
            let text = try String(contentsOf: boardURL, encoding: .utf8)
            let project = (try? Data(contentsOf: file.deletingPathExtension().appendingPathExtension("kicad_pro")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let made = record["made"] as? [String: [String]] ?? [:]
            // (the local settings the board was opened on, if the plan gave it any)
            let local = KiCadLocalSettings(text: (record["plan"] as? [String: Any])?["prl"] as? String)
            let drawn = record["lines"] as? [String: [String: Any]] ?? [:]
            var magnetic = MagneticSettings()
            magnetic.pads = .captureAlways
            magnetic.tracks = .captureAlways
            magnetic.graphics = true
            // (the lines drawn before each step, on the board as it then was)
            var before: [String] = []
            var step: Int?
            var helper: PCBGridHelper?
            var view: SnapView?
            var clicks: [IPoint] = []
            var pointer = IPoint.zero
            var raw = (0.0, 0.0)
            var clickRaws: [(Double, Double)] = []
            // (a move KiCad's canvas did not see: the pointer gone off it, below or beside the view, the status bar
            // reading where it was before though the pointer went well away; not given to the port either)
            var lastPixel: [Int]?, lastReading: [Double]?, pendingMove: (IPoint, (Double, Double))?
            // (and the clicks there, which it did not see either)
            var offCanvas = false
            func point(_ e: [String: Any]) -> IPoint {
                let raw = e["raw"] as? [Double] ?? [0, 0]
                return IPoint(KiMath.round(raw[0]), KiMath.round(raw[1]))
            }
            for e in events {
                switch e["ev"] as? String {
                case "mark":
                    step = e["step"] as? Int
                    let board = try KiCadBoard(text: text)
                    for uuid in before {
                        guard let l = drawn[uuid], let s = l["start"] as? [Int], let en = l["end"] as? [Int], let w = l["width"] as? Int else { continue }
                        func mm(_ v: Int) -> Double { Double(v) / 1e6 }
                        board.root.items.append(SExpr("gr_line", SExpr("start", mm(s[0]), mm(s[1])), SExpr("end", mm(en[0]), mm(en[1])),
                                                      SExpr("stroke", SExpr("width", mm(w)), SExpr("type", Keyword("solid"))),
                                                      SExpr("layer", "F.Cu"), SExpr("uuid", uuid)))
                    }
                    let layers = Set(KiCadLayers.enabled(board).map(\.id))
                    let appearance = KiCadAppearanceControls(opening: local.board, boardLayers: layers).appearance
                    view = SnapView(appearance: appearance, enabledLayers: layers, worldPerPixel: abs(t["sx"] ?? 0) * 1e6,
                                    grid: IPoint(1_000, 1_000))
                    helper = PCBGridHelper(board: SnapBoard(board: board, project: project), magnetic: magnetic)
                    clicks = []
                    clickRaws = []
                case "move":
                    let r = e["raw"] as? [Double] ?? [0, 0]
                    let pixel = e["pixel"] as? [Int] ?? [0, 0]
                    defer { lastPixel = pixel }
                    guard step != nil else {
                        lastReading = nil
                        continue
                    }
                    if let lp = lastPixel, abs(lp[0] - pixel[0]) + abs(lp[1] - pixel[1]) > 40 {
                        pendingMove = (point(e), (r[0], r[1]))
                        continue
                    }
                    guard var h = helper, let v = view else { continue }
                    pointer = point(e)
                    offCanvas = false
                    raw = (r[0], r[1])
                    _ = h.bestSnapAnchor(pointer, layers: [0], view: v)
                    helper = h
                case "check":
                    let reading = e["cursor"] as? [Double]
                    defer { lastReading = reading }
                    guard let (p, r) = pendingMove else { continue }
                    pendingMove = nil
                    if reading != nil && reading == lastReading {
                        missed += 1
                        offCanvas = true
                        continue
                    }
                    guard step != nil, var h = helper, let v = view else { continue }
                    pointer = p
                    offCanvas = false
                    raw = r
                    _ = h.bestSnapAnchor(pointer, layers: [0], view: v)
                    helper = h
                case "click":
                    guard step != nil, !offCanvas, var h = helper, let v = view else { continue }
                    let p = h.bestSnapAnchor(pointer, layers: [0], view: v)
                    // (Draw Lines' first click: the line starts there, which a snap line does not snap to)
                    if clicks.isEmpty { h.skipPoint = p }
                    clicks.append(p)
                    clickRaws.append(raw)
                    helper = h
                case "made":
                    guard let i = step else { continue }
                    lines += 1
                    let uuids = made[String(i)] ?? []
                    before += uuids
                    let theirs = uuids.compactMap { drawn[$0] }.map { l -> [IPoint] in
                        let s = l["start"] as? [Int] ?? [], en = l["end"] as? [Int] ?? []
                        return [IPoint(s[0], s[1]), IPoint(en[0], en[1])]
                    }
                    let mine: [[IPoint]] = clicks.count >= 2 && clicks[0] != clicks[1] ? [[clicks[0], clicks[1]]] : []
                    // (a coordinate of a grid point, KiCad's and ours a micrometre apart, where the pixel's place on the
                    // board is half way between two of the grid's: the view's transform, fitted to the status bar's
                    // readings to the micrometre, does not know which side of the half the pixel is; counted)
                    func sameOrUnsure(_ k: IPoint, _ m: IPoint, _ r: (Double, Double)) -> Bool {
                        func coordinate(_ a: Int, _ b: Int, _ v: Double) -> Bool {
                            if a == b { return true }
                            let frac = v / 1_000 - (v / 1_000).rounded(.down)
                            return a % 1_000 == 0 && b % 1_000 == 0 && abs(a - b) == 1_000 && abs(frac - 0.5) < 0.35
                        }
                        return coordinate(k.x, m.x, r.0) && coordinate(k.y, m.y, r.1)
                    }
                    if theirs != mine, theirs.count == 1, mine.count == 1, clickRaws.count >= 2,
                       sameOrUnsure(theirs[0][0], mine[0][0], clickRaws[0]), sameOrUnsure(theirs[0][1], mine[0][1], clickRaws[1]) {
                        unsure += 1
                    } else if theirs != mine {
                        differences.append("\(file.lastPathComponent) line \(i): KiCad \(theirs), ours \(mine)")
                    }
                    // (an end KiCad put off the grid: on an item)
                    for l in theirs { for p in l where p.x % 1_000 != 0 || p.y % 1_000 != 0 { snappedToItems += 1 } }
                    step = nil
                default:
                    break
                }
            }
        }
        print("snapping: \(lines) lines drawn in KiCad, \(snappedToItems) ends off the grid, \(unsure) a micrometre off the grid's"
              + " point where the pixel is half way between two, \(missed) moves off KiCad's canvas, \(differences.count) differences")
        XCTAssertGreaterThan(lines, 0)
        XCTAssertEqual(differences, [], differences.prefix(10).joined(separator: "\n"))
    }

    /// The Magnetic Points preferences as KiCad reads them from pcbnew.json, its defaults where it has none
    func testMagneticSettingsAsKiCadReadsThem() {
        let d = MagneticSettings(pcbnewSettings: nil)
        XCTAssertEqual(d.pads, .captureCursorInTrackTool)
        XCTAssertEqual(d.tracks, .captureCursorInTrackTool)
        XCTAssertTrue(d.graphics)
        XCTAssertFalse(d.allLayers)
        let s = MagneticSettings(pcbnewSettings: ["editing": ["magnetic_pads": 2, "magnetic_tracks": 0, "magnetic_graphics": false,
                                                              "magnetic_all_layers": true]])
        XCTAssertEqual(s.pads, .captureAlways)
        XCTAssertEqual(s.tracks, .noEffect)
        XCTAssertFalse(s.graphics)
        XCTAssertTrue(s.allLayers)
        XCTAssertFalse(s.routerSnapsToTracks)
    }
}

// MARK: - The other tools that snap the pointer

/// Where KiCad's other tools put what they move or make, the port's against KiCad's own: tools/kicad-reference/
/// snapping.py (tools, use) does with KiCad's PCB editor under Xvfb, on the boards Draw Lines was checked on, the
/// pointer moved to pixels near the board's items (now and then with Shift or Ctrl held): footprints moved (M with the
/// pointer on one, EDIT_TOOL::doMoveSelection), zones and rule areas drawn (DRAWING_TOOL::DrawZone), texts placed
/// (DRAWING_TOOL::PlaceText), a footprint placed (BOARD_EDITOR_CONTROL::PlaceFootprint), corners and sides of
/// graphics and corners of zones dragged with the point editor (PCB_POINT_EDITOR); NAME.used has every event and what
/// each step changed. The port, given the same pointer positions in the same order and the board as it then was (the
/// steps before done on it), must move, make and place each as KiCad did, to the nanometre (or, where Ctrl took the
/// grid away and nothing was snapped to, within the half micrometre the view's transform gives the pointer's place to).
extension SnappingTests {
    /// A step's board: the board's text as KiCad had it with what the steps before changed done on it
    static func board(_ text: String, changed: [[String: Any]], placed: String) throws -> KiCadBoard {
        let board = try KiCadBoard(text: text)
        func mm(_ v: Any?) -> (Double, Double)? {
            guard let a = v as? [NSNumber], a.count == 2 else { return nil }
            return (a[0].doubleValue / 1e6, a[1].doubleValue / 1e6)
        }
        func node(_ head: String, _ uuid: String) -> SExpr? {
            board.root.items.first { $0.head == head && $0.value("uuid") == uuid }
        }
        for diff in changed {
            for (uuid, v) in diff["footprints"] as? [String: Any] ?? [:] {
                let old = node("footprint", uuid)
                guard let f = v as? [String: Any], let (x, y) = mm(f["at"]) else {
                    if let old { board.root.remove(old) }
                    continue
                }
                let angle = (f["angle"] as? NSNumber)?.doubleValue ?? 0
                let fp: SExpr
                if let old {
                    fp = old
                    // (a footprint moved: its points, which the file has where they are on the board, moved with it)
                    let was = fp["at"]
                    let (dx, dy) = (x - (was?.number(at: 0) ?? x), y - (was?.number(at: 1) ?? y))
                    for point in fp.all("point") {
                        guard let at = point["at"], let px = at.number(at: 0), let py = at.number(at: 1) else { continue }
                        point.set(SExpr("at", px + dx, py + dy))
                    }
                } else {
                    // (a footprint placed: the library's, put on the board)
                    fp = try SExpr.parse(placed)
                    fp.set(SExpr("uuid", uuid), after: ["layer"])
                    board.root.items.append(fp)
                }
                fp.set(angle == 0 ? SExpr("at", x, y) : SExpr("at", x, y, angle), after: ["uuid", "layer"])
            }
            for (uuid, v) in diff["zones"] as? [String: Any] ?? [:] {
                if let old = node("zone", uuid) { board.root.remove(old) }
                guard let z = v as? [String: Any], let rings = z["rings"] as? [[[NSNumber]]] else { continue }
                let layers = z["layers"] as? [String] ?? ["F.Cu"]
                var parts: [SExprConvertible] = [SExpr("net", 0), SExpr("net_name", ""),
                                                 layers.count == 1 ? SExpr("layer", layers[0]) : SExpr("layers", layers),
                                                 SExpr("uuid", uuid), SExpr("hatch", Keyword("edge"), 0.5)]
                if z["rule"] as? Bool == true {
                    parts.append(SExpr("keepout", SExpr("tracks", Keyword("not_allowed")), SExpr("vias", Keyword("not_allowed"))))
                }
                for ring in rings {
                    parts.append(SExpr("polygon", SExpr("pts", ring.map { SExpr("xy", $0[0].doubleValue / 1e6, $0[1].doubleValue / 1e6) })))
                }
                board.root.items.append(SExpr("zone", parts))
            }
            for (uuid, v) in diff["shapes"] as? [String: Any] ?? [:] {
                guard let s = v as? [String: Any] else { continue }
                let heads = ["gr_line", "gr_rect", "gr_circle", "gr_arc", "gr_poly", "gr_curve"]
                guard let n = board.root.items.first(where: { heads.contains($0.head ?? "") && $0.value("uuid") == uuid }) else { continue }
                if let (x, y) = mm(s["start"]) { n.set(SExpr(n.head == "gr_circle" ? "center" : "start", x, y)) }
                if let (x, y) = mm(s["end"]) { n.set(SExpr("end", x, y)) }
                if let (x, y) = mm(s["mid"]) { n.set(SExpr("mid", x, y)) }
            }
        }
        return board
    }

    func testOtherToolsSnapWhereKiCadSnaps() throws {
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "used" }.sorted { $0.path < $1.path }
        var checked: [String: Int] = [:], unsure = 0, halfWays = 0, skipped = 0, differences: [String] = []
        for file in files {
            guard let record = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                  let events = record["events"] as? [[String: Any]], let t = record["transform"] as? [String: Double],
                  let plan = (record["plan"] as? [String: Any])?["tools"] as? [[String: Any]] else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            let text = try String(contentsOf: file.deletingPathExtension().appendingPathExtension("kicad_pcb"), encoding: .utf8)
            let project = (try? Data(contentsOf: file.deletingPathExtension().appendingPathExtension("kicad_pro")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let made = record["made"] as? [String: [String: Any]] ?? [:]
            let placed = record["placed"] as? String ?? ""
            let threshold = (record["dragThreshold"] as? [Int]) ?? [8, 8]
            var magnetic = MagneticSettings()
            magnetic.pads = .captureAlways
            magnetic.tracks = .captureAlways
            magnetic.graphics = true
            let pixel = abs(t["sx"] ?? 0) * 1e6
            // (what the steps before changed, in order)
            var changed: [[String: Any]] = []
            var step: Int?, op = "", skippedStep = false
            var board: KiCadBoard?, snapBoard: SnapBoard?, view: SnapView?
            var pointer = IPoint.zero, raw = DPoint(0, 0), held = Set<String>(), raws: [DPoint] = []
            var lastPixel: [Int]?, lastReading: [Double]?, pending: (IPoint, DPoint, [Int])?
            // (each tool's state)
            var active = false, helper: PCBGridHelper?, move: SelectionMove?, polygon = PolygonDrawing(), finished = false
            var textAt: IPoint?, textMade = false, footprintAt: IPoint?, choosing = false, footprintMade = false
            var exact = true
            var editor: ShapePointEditor?, handle: ShapePointEditor.Handle?, pointSnap: PointEditorSnap?
            var session: BoardEditing?, editedZone: String?, editedShape: String?, down = false, downPixel: [Int]?, dragging = false
            func point(_ e: [String: Any]) -> (IPoint, DPoint) {
                let r = e["raw"] as? [Double] ?? [0, 0]
                return (IPoint(KiMath.round(r[0]), KiMath.round(r[1])), DPoint(r[0], r[1]))
            }
            var shift: Bool { held.contains("shift") }
            var ctrl: Bool { held.contains("ctrl") }
            func differ(_ what: String, _ theirs: IPoint?, _ ours: IPoint?) {
                guard theirs != ours else { return }
                // (where Ctrl took the grid away, the pointer itself: known to the view's transform's half micrometre)
                if let a = theirs, let b = ours, !exact, abs(a.x - b.x) <= 500 && abs(a.y - b.y) <= 500 {
                    unsure += 1
                    return
                }
                // (a coordinate of a grid point, KiCad's and ours a micrometre apart, where a pointer of the step was
                // half way between them: the view's transform, fitted to the status bar's micrometres, does not know
                // which side of the half the pixel is)
                func halfWay(_ a: Int, _ b: Int, _ axis: KeyPath<DPoint, Double>) -> Bool {
                    if a == b { return true }
                    guard a % 1_000 == 0, b % 1_000 == 0, abs(a - b) == 1_000 else { return false }
                    return raws.contains { r in
                        let v = r[keyPath: axis] / 1_000
                        return Int(v.rounded(.down)) * 1_000 == min(a, b) && abs(v - v.rounded(.down) - 0.5) < 0.35
                    }
                }
                if let a = theirs, let b = ours, halfWay(a.x, b.x, \.x), halfWay(a.y, b.y, \.y) {
                    halfWays += 1
                    return
                }
                differences.append("\(name) step \(step ?? -1) \(op) \(what): KiCad \(String(describing: theirs)), ours \(String(describing: ours))")
            }
            /// The tool's response to the pointer at a place KiCad's canvas saw
            func moved(_ p: IPoint, _ r: DPoint) {
                pointer = p
                raw = r
                raws.append(r)
                guard step != nil, !skippedStep, let v = view else { return }
                switch op {
                case "move":
                    guard move != nil else { return }
                    let q = move!.moved(to: p, layers: [0], view: v, shift: shift, ctrl: ctrl)
                    // (with Ctrl, anywhere but on an anchor: of the pointer itself, along a snap line or not)
                    if ctrl && move!.helper.snapItem?.pos != q { exact = false }
                case "zone", "rule":
                    guard active, !finished else { return }
                    helper!.enableSnap = !shift
                    helper!.enableGrid = !ctrl
                    _ = helper!.bestSnapAnchor(p, layers: [0], view: v, grid: .graphics)
                case "text":
                    guard active else { return }
                    helper!.enableSnap = !shift
                    helper!.enableGrid = !ctrl
                    let q = helper!.bestSnapAnchor(p, layers: [0], view: v, grid: .text)
                    if textMade {
                        textAt = q
                        exact = !(ctrl && helper!.snapItem?.pos != q)
                    }
                case "footprint":
                    // (no grid helper: the cursor, the grid's point under the pointer, or with Ctrl the pointer)
                    if footprintMade && !choosing {
                        footprintAt = ctrl ? p : PCBGridHelper.gridPoint(r, view: v)
                        exact = !ctrl
                    }
                case "edit":
                    guard down, let d = downPixel, let px = lastPixel else { return }
                    if !dragging { dragging = abs(px[0] - d[0]) > threshold[0] || abs(px[1] - d[1]) > threshold[1] }
                    guard dragging else { return }
                    let sticky = KiMath.round(5 * pixel)
                    if var e = editor, let h = handle, var s = pointSnap {
                        e.drag(h, to: p, snap: &s, stickyLimit: sticky, free: shift, ctrl: ctrl)
                        editor = e
                        pointSnap = s
                        if ctrl && s.helper.snapItem?.pos != e.position(h) { exact = false }
                    } else if let session {
                        session.dragZonePoint(to: KiCadPoint(Double(p.x) / 1e6, Double(p.y) / 1e6), ctrl: ctrl, shift: shift,
                                              stickyDistance: 5 * pixel / 1e6)
                        if ctrl { exact = false }
                    }
                default:
                    break
                }
            }
            /// A click (or a double click's first) where the pointer is
            func click(double: Bool) {
                guard step != nil, !skippedStep, let v = view else { return }
                switch op {
                case "zone", "rule":
                    guard active, !finished else { return }
                    helper!.enableSnap = !shift
                    helper!.enableGrid = !ctrl
                    let q = helper!.bestSnapAnchor(pointer, layers: [0], view: v, grid: .graphics)
                    if polygon.click(q) || double { finished = true }
                    if ctrl && helper!.snapItem?.pos != q { exact = false }
                case "text":
                    guard active else { return }
                    let q = helper!.bestSnapAnchor(pointer, layers: [0], view: v, grid: .text)
                    if !textMade {
                        textMade = true
                        textAt = q
                    } else {
                        active = false
                    }
                case "footprint":
                    if !footprintMade {
                        footprintMade = true
                        choosing = true
                    } else {
                        active = false
                    }
                default:
                    break
                }
            }
            for e in events {
                switch e["ev"] as? String {
                case "mark":
                    step = (e["step"] as? NSNumber)?.intValue
                    guard let i = step, i < plan.count else { continue }
                    op = plan[i]["op"] as? String ?? ""
                    let b = try Self.board(text, changed: changed, placed: placed)
                    board = b
                    let layers = Set(KiCadLayers.enabled(b).map(\.id))
                    let appearance = KiCadAppearanceControls(opening: KiCadLocalSettings(text: nil).board, boardLayers: layers).appearance
                    view = SnapView(appearance: appearance, enabledLayers: layers, worldPerPixel: pixel, grid: IPoint(1_000, 1_000))
                    snapBoard = SnapBoard(board: b, project: project)
                    skippedStep = false
                    raws = []
                    active = false
                    helper = nil
                    move = nil
                    polygon = PolygonDrawing()
                    finished = false
                    textAt = nil
                    textMade = false
                    footprintAt = nil
                    footprintMade = false
                    choosing = false
                    exact = true
                    editor = nil
                    handle = nil
                    pointSnap = nil
                    session = nil
                    editedZone = nil
                    editedShape = nil
                    down = false
                    dragging = false
                case "menu":
                    guard step != nil, let sb = snapBoard else { continue }
                    active = true
                    helper = PCBGridHelper(board: sb, magnetic: magnetic)
                    // (Add Text and Add Footprint, with KiCad's immediate actions, start with a click where the
                    // pointer is: PrimeTool)
                    if op == "text" || op == "footprint" { click(double: false) }
                case "move", "eselect", "ehover":
                    if e["missing"] as? Bool == true {
                        skippedStep = true
                        continue
                    }
                    let (p, r) = point(e)
                    let px = e["pixel"] as? [Int] ?? [0, 0]
                    defer { lastPixel = px }
                    // (no motion where the pointer stays on its pixel)
                    if px != lastPixel {
                        if e["ev"] as? String == "move", let lp = lastPixel, abs(lp[0] - px[0]) + abs(lp[1] - px[1]) > 40 {
                            // (a move KiCad's canvas may not have seen: known by the status bar's reading after it)
                            pending = (p, r, px)
                            continue
                        }
                        pending = nil
                        moved(p, r)
                    }
                    if e["ev"] as? String == "ehover", step != nil, let i = step, let b = board, let sb = snapBoard, let v = view {
                        // (the point editor on the graphic or zone, its handle under the pointer)
                        let name = e["handle"] as? String ?? ""
                        let spec = e["spec"] as? [String: String] ?? [:]
                        if let uuid = spec["shape"], let n = b.root.items.first(where: { $0.value("uuid") == uuid }), let shape = BoardShape(n) {
                            var ed = ShapePointEditor(shape)
                            switch (shape.kind, name) {
                            case (_, "start"): handle = .point(0)
                            case (.segment, "end"), (.circle, "end"): handle = .point(1)
                            case (_, let h) where h.hasPrefix("corner"): handle = .point(Int(h.dropFirst(6)) ?? 0)
                            case (_, let h) where h.hasPrefix("side"): handle = .line(Int(h.dropFirst(4)) ?? 0)
                            default: handle = nil
                            }
                            if let h = handle {
                                XCTAssertEqual(Self.ipoint(e["handleAt"]), ed.position(h), "\(name) step \(i): the handle where KiCad has it")
                                ed.beginDrag(h)
                            }
                            editor = ed
                            editedShape = uuid
                            pointSnap = PointEditorSnap(board: sb, item: uuid, magnetic: magnetic, view: v)
                        } else if var uuid = spec["zone"] {
                            if uuid.hasPrefix("made:") {
                                let zones = made[String(uuid.dropFirst(5))]?["zones"] as? [String: Any] ?? [:]
                                uuid = zones.first { !($0.value is NSNull) }?.key ?? uuid
                            }
                            let s = BoardEditing(board: try KiCadBoard(text: b.text), project: project)
                            s.magnetic = magnetic
                            if s.startZoneDrag(uuid, handle: .corner(Int(name.dropFirst(6)) ?? 0), view: v) != nil {
                                session = s
                                editedZone = uuid
                            }
                        }
                    }
                case "check":
                    let reading = e["cursor"] as? [Double]
                    defer { lastReading = reading }
                    guard let (p, r, _) = pending else { continue }
                    pending = nil
                    if reading != nil && reading == lastReading {
                        // (KiCad's canvas did not see it)
                        continue
                    }
                    moved(p, r)
                case "hold":
                    held.insert(e["key"] as? String ?? "")
                case "release":
                    held.remove(e["key"] as? String ?? "")
                case "press":
                    // (M: the footprint under the pointer moved, picked up by its point nearest the pointer)
                    guard step != nil, op == "move", let sb = snapBoard, let v = view, let i = step,
                          let uuid = plan[i]["footprint"] as? String else { continue }
                    move = SelectionMove(board: sb, items: [uuid], mouse: pointer, view: v, magnetic: magnetic)
                case "warped":
                    // (the pointer warped to where the footprint was picked up: a motion there, if it moved)
                    let (p, r) = point(e)
                    let px = e["pixel"] as? [Int] ?? [0, 0]
                    if px != lastPixel { moved(p, r) }
                    lastPixel = px
                case "msel", "echeck":
                    if e["ok"] as? Bool != true { skippedStep = true }
                case "click":
                    if op == "edit" { continue }
                    click(double: false)
                case "dclick":
                    click(double: false)
                    click(double: true)
                case "settle":
                    // (the text's dialog closed, or the footprint chosen: a refresh, where the pointer is)
                    choosing = false
                    if op == "text", textMade, let v = view {
                        textAt = helper!.bestSnapAnchor(pointer, layers: [0], view: v, grid: .text)
                    }
                    if op == "footprint", footprintMade, let v = view { footprintAt = PCBGridHelper.gridPoint(raw, view: v) }
                case "down":
                    down = true
                    downPixel = lastPixel
                    dragging = false
                case "up":
                    down = false
                case "tmade":
                    guard let i = step else { continue }
                    let theirs = made[String(i)] ?? [:]
                    defer {
                        changed.append(theirs)
                        step = nil
                    }
                    if skippedStep {
                        skipped += 1
                        continue
                    }
                    checked[op, default: 0] += 1
                    switch op {
                    case "move":
                        let uuid = plan[i]["footprint"] as? String ?? ""
                        let was = snapBoard?.items.first { $0.uuid == uuid && $0.kind == .footprint }
                        let now = ((theirs["footprints"] as? [String: Any])?[uuid] as? [String: Any]).flatMap { Self.ipoint($0["at"]) }
                        let ours = was.map { $0.start + (move?.offset ?? .zero) }
                        differ("footprint \(uuid)", now ?? was?.start, ours)
                    case "zone", "rule":
                        let zones = (theirs["zones"] as? [String: Any] ?? [:]).compactMap { $0.value as? [String: Any] }
                        let ring = (zones.first?["rings"] as? [[[NSNumber]]])?.first.map { $0.map { IPoint($0[0].intValue, $0[1].intValue) } }
                        let ours = finished ? polygon.outline : nil
                        if ring?.count != ours?.count {
                            differences.append("\(name) step \(i) \(op): KiCad \(String(describing: ring)), ours \(String(describing: ours)) (\(polygon.corners))")
                        } else if let ring, let ours {
                            for (k, (a, b)) in zip(ring, ours).enumerated() { differ("corner \(k)", a, b) }
                        }
                    case "text":
                        let texts = (theirs["texts"] as? [String: Any] ?? [:]).compactMap { $0.value as? [String: Any] }
                        differ("text", texts.first.flatMap { Self.ipoint($0["at"]) }, active ? nil : textAt)
                    case "footprint":
                        let fps = (theirs["footprints"] as? [String: Any] ?? [:]).compactMap { $0.value as? [String: Any] }
                        differ("footprint placed", fps.first.flatMap { Self.ipoint($0["at"]) }, active ? nil : footprintAt)
                    case "edit":
                        if let uuid = editedShape, let ed = editor {
                            let s = ((theirs["shapes"] as? [String: Any])?[uuid] as? [String: Any])
                            let was = board.flatMap { b in b.root.items.first { $0.value("uuid") == uuid } }.flatMap { BoardShape($0) }
                            let theirStart = s.flatMap { Self.ipoint($0["start"]) } ?? was?.start
                            let theirEnd = s.flatMap { Self.ipoint($0["end"]) } ?? was?.end
                            if ed.shape.kind == .rectangle {
                                // (a rectangle's corners, whichever way round KiCad keeps them)
                                let ours = IBox(ed.shape.start, ed.shape.end)
                                let box = theirStart.flatMap { a in theirEnd.map { IBox(a, $0) } }
                                differ("rectangle's corner", box.map { IPoint($0.minX, $0.minY) }, IPoint(ours.minX, ours.minY))
                                differ("rectangle's opposite corner", box.map { IPoint($0.maxX, $0.maxY) }, IPoint(ours.maxX, ours.maxY))
                            } else {
                                differ("start", theirStart, ed.shape.kind == .circle ? ed.shape.center : ed.shape.start)
                                differ("end", theirEnd, ed.shape.end)
                            }
                        } else if let uuid = editedZone, let s = session {
                            _ = s.finishZoneDrag()
                            let z = (theirs["zones"] as? [String: Any])?[uuid] as? [String: Any]
                            let ring = (z?["rings"] as? [[[NSNumber]]])?.first.map { $0.map { IPoint($0[0].intValue, $0[1].intValue) } }
                            let ours = s.zoneContours(uuid)?.first
                            if let ring, ring.count != ours?.count {
                                differences.append("\(name) step \(i) zone edit: KiCad \(ring), ours \(String(describing: ours))")
                            } else if let ring, let ours {
                                for (k, (a, b)) in zip(ring, ours).enumerated() { differ("zone corner \(k)", a, b) }
                            } else if ring == nil, let before = board.flatMap({ try? BoardEditing(board: $0).zoneContours(uuid)?.first }), before != ours {
                                differences.append("\(name) step \(i) zone edit: KiCad left it, ours \(String(describing: ours))")
                            }
                        } else {
                            skipped += 1
                            checked[op, default: 0] -= 1
                        }
                    default:
                        break
                    }
                default:
                    break
                }
            }
        }
        print("other tools: \(checked.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")) checked, "
              + "\(unsure) within the pointer's half micrometre where Ctrl took the grid away, \(halfWays) a micrometre off the grid's "
              + "point where the pixel is half way between two, \(skipped) not done, \(differences.count) differences")
        XCTAssertGreaterThan(checked.values.reduce(0, +), 0)
        XCTAssertEqual(differences, [], differences.prefix(12).joined(separator: "\n"))
    }

    static func ipoint(_ v: Any?) -> IPoint? {
        guard let a = v as? [NSNumber], a.count == 2 else { return nil }
        return IPoint(a[0].intValue, a[1].intValue)
    }
}
