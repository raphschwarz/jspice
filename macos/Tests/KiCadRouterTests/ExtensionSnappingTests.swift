import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

// MARK: - KiCad 10's extension snaps, and the line modes

/// KiCad 10's construction geometry (the extensions of the items the pointer snaps to or rests on, their crossings,
/// the snap lines) and its line modes (free, 45°, 90°), the port's (PCBGridHelper's ConstructionManager, GraphicTool's
/// angle snap) against KiCad's own: tools/kicad-reference/snapping.py (extend, extended) draws lines with KiCad's Draw
/// Lines tool on boards of graphics, tracks, a via, footprints and a zone, with the extension snaps on and in each
/// line mode, the pointer resting (KiCad's activation timer set off by the plugin: `rest`) on points of the items or
/// not, then moved along their extensions, to where they cross each other, the snap lines and other items, to anchors
/// or anywhere, now and then with Ctrl (no grid: the pointer onto the extension itself, and a line held to no angle)
/// or Shift (no snapping); NAME.extended has every event and the lines KiCad drew. The port, given the same pointer
/// positions, the same rests, in the same order, a grid helper and a Draw Lines tool of its own for each line, on the
/// board as it then was, must have the same proposal waiting at each rest as KiCad's timer had and draw each line
/// where KiCad did, to the nanometre (an end Ctrl left off the grid and off any anchor: within the half micrometre the
/// view's transform gives the pointer's place to).
extension SnappingTests {
    func testExtensionsAndLineModesSnapAsKiCadDoes() throws {
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "extended" }.sorted { $0.path < $1.path }
        var lines = 0, byMode = [0, 0, 0], rests = 0, fired = 0, onConstruction = 0, unsure = 0, near = 0
        var differences: [String] = [], kinds: [String: Int] = [:]
        for file in files {
            guard let record = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                  let events = record["events"] as? [[String: Any]], let t = record["transform"] as? [String: Double],
                  let plan = record["plan"] as? [String: Any] else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            let text = try String(contentsOf: file.deletingPathExtension().appendingPathExtension("kicad_pcb"), encoding: .utf8)
            let project = (try? Data(contentsOf: file.deletingPathExtension().appendingPathExtension("kicad_pro")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let mode = LeaderMode(rawValue: plan["mode"] as? Int ?? 0) ?? .direct
            let made = record["made"] as? [String: [String]] ?? [:]
            let drawn = record["lines"] as? [String: [String: Any]] ?? [:]
            var magnetic = MagneticSettings()
            magnetic.pads = .captureAlways
            magnetic.tracks = .captureAlways
            magnetic.graphics = true
            var before: [String] = []
            var step: Int?
            var helper: PCBGridHelper?, view: SnapView?, tool: GraphicTool?
            var pointer = IPoint.zero, raw = DPoint(0, 0), held = Set<String>(), lastPixel: [Int]?
            var clicks = 0, mine: [[IPoint]] = [], endRaw = DPoint(0, 0), startRaw = DPoint(0, 0)
            // (whether the line's end is the pointer itself, Ctrl's, on no anchor: known to the transform's half micrometre)
            var endFree = false, startFree = false
            func point(_ e: [String: Any]) -> (IPoint, DPoint) {
                let r = e["raw"] as? [Double] ?? [0, 0]
                return (IPoint(KiMath.round(r[0]), KiMath.round(r[1])), DPoint(r[0], r[1]))
            }
            /// BestSnapAnchor where the pointer is, as each event of the drawing tool's asks it
            func snap() -> IPoint? {
                guard var h = helper, let v = view else { return nil }
                h.enableSnap = !held.contains("shift")
                h.enableGrid = !held.contains("ctrl")
                let q = h.bestSnapAnchor(pointer, layers: [0], view: v, grid: .graphics)
                helper = h
                if trace {
                    print("  \(pointer) -> \(q) snapped \(String(describing: h.snapped)) pending \(h.hasPendingConstruction)"
                          + " batches \(h.construction.batches.map { $0.map { $0.item ?? -99 } }) line \(String(describing: h.snapLineOrigin))"
                          + "-\(String(describing: h.snapLineEnd))")
                }
                return q
            }
            let trace = ProcessInfo.processInfo.environment["JSPICE_EXTENSION_TRACE"] != nil
            /// What the pointer went to: a crossing of construction geometry (an extension's, a snap line's) with
            /// something, a point of construction geometry, or something else
            func kind(of q: IPoint) -> String {
                guard let h = helper else { return "" }
                if let a = h.snapItem, a.pos == q, a.flags.contains(.constructed) {
                    if a.items.count == 1 { return "construction point" }
                    if a.items.contains(where: { $0 == nil }) { return "snap line crossing" }
                    let own = a.items.allSatisfy { i in
                        guard let i, let g = PCBGridHelper.intersectable(h.board.items[i]) else { return false }
                        return PCBGridHelper.nearest(g, q).distance(q) <= 2
                    }
                    return own ? "items crossing" : "extension crossing"
                }
                if held.contains("ctrl"), h.snapItem?.pos != q, q.x % 1_000 != 0 || q.y % 1_000 != 0 { return "on construction or item" }
                return ""
            }
            var endKind = ""
            for e in events {
                if trace, step != nil || e["ev"] as? String == "mark" { print(e) }
                switch e["ev"] as? String {
                case "move":
                    let pixel = e["pixel"] as? [Int] ?? [0, 0]
                    defer { lastPixel = pixel }
                    (pointer, raw) = point(e)
                    // (no motion where the pointer stays on its pixel: KiCad's dispatcher sends none)
                    guard step != nil, pixel != lastPixel, let q = snap() else { continue }
                    tool?.move(to: q, ctrl: held.contains("ctrl"))
                    endRaw = raw
                    endFree = held.contains("ctrl") && helper?.snapItem?.pos != q
                    endKind = kind(of: q)
                case "hold":
                    held.insert(e["key"] as? String ?? "")
                case "release":
                    held.remove(e["key"] as? String ?? "")
                case "rest":
                    guard step != nil, var h = helper else { continue }
                    rests += 1
                    let kicadFired = e["fired"] as? Bool ?? false
                    if kicadFired { fired += 1 }
                    if h.hasPendingConstruction != kicadFired {
                        differences.append("\(name) line \(step!): at a rest KiCad's timer \(kicadFired ? "had" : "had no") proposal, ours \(h.hasPendingConstruction ? "had" : "had none")")
                    }
                    h.rested()
                    helper = h
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
                    let appearance = KiCadAppearanceControls(opening: KiCadLocalSettings(text: nil).board, boardLayers: layers).appearance
                    view = SnapView(appearance: appearance, enabledLayers: layers, worldPerPixel: abs(t["sx"] ?? 0) * 1e6,
                                    grid: IPoint(1_000, 1_000))
                    helper = PCBGridHelper(board: SnapBoard(board: board, project: project), magnetic: magnetic)
                    tool = GraphicTool(.line, layer: "F.Cu", angleSnap: mode)
                    clicks = 0
                    mine = []
                    endFree = false
                    endKind = ""
                    // (the tool's first event, the preview refreshed, where the pointer waits)
                    _ = snap()
                case "click":
                    guard step != nil, var t = tool, let q = snap() else { continue }
                    let onGraphic = helper?.snapped.map { helper!.board.items[$0].kind == .shape } ?? false
                    if clicks == 0 {
                        // (Draw Lines' first click: the line starts there, which a snap line does not snap to)
                        helper?.skipPoint = q
                        startRaw = raw
                        startFree = held.contains("ctrl") && helper?.snapItem?.pos != q
                        endFree = startFree
                        endRaw = raw
                    }
                    let out = t.click(at: q, ctrl: held.contains("ctrl"), onGraphicEnd: onGraphic)
                    if clicks == 1 { mine = out.map { [$0.start, $0.end] } }
                    clicks += 1
                    tool = t
                case "made":
                    guard let i = step else { continue }
                    lines += 1
                    byMode[mode.rawValue] += 1
                    let uuids = made[String(i)] ?? []
                    before += uuids
                    let theirs = uuids.compactMap { drawn[$0] }.map { l -> [IPoint] in
                        let s = l["start"] as? [Int] ?? [], en = l["end"] as? [Int] ?? []
                        return [IPoint(s[0], s[1]), IPoint(en[0], en[1])]
                    }
                    // (a coordinate a micrometre off the grid's where the pixel is half way between two of the grid's
                    // points, or, where Ctrl left it the pointer, within the transform's half micrometre)
                    func sameOrUnsure(_ k: IPoint, _ m: IPoint, _ r: DPoint, free: Bool) -> (same: Bool, unsure: Bool) {
                        if k == m { return (true, false) }
                        if free { return (abs(k.x - m.x) <= 600 && abs(k.y - m.y) <= 600, true) }
                        func coordinate(_ a: Int, _ b: Int, _ v: Double) -> Bool {
                            if a == b { return true }
                            let frac = v / 1_000 - (v / 1_000).rounded(.down)
                            return a % 1_000 == 0 && b % 1_000 == 0 && abs(a - b) == 1_000 && abs(frac - 0.5) < 0.35
                        }
                        return (coordinate(k.x, m.x, r.x) && coordinate(k.y, m.y, r.y), true)
                    }
                    let counted = differences.count
                    defer { if differences.count == counted, !endKind.isEmpty, !theirs.isEmpty { kinds[endKind, default: 0] += 1 } }
                    if theirs == mine {
                        // (an end on neither the grid nor the pointer: an anchor, a crossing, the construction itself)
                        for l in theirs { for p in l where p.x % 1_000 != 0 || p.y % 1_000 != 0 { onConstruction += 1 } }
                    } else if theirs.count == 1, mine.count == 1 {
                        let a = sameOrUnsure(theirs[0][0], mine[0][0], startRaw, free: startFree)
                        let b = sameOrUnsure(theirs[0][1], mine[0][1], endRaw, free: endFree)
                        if a.same && b.same {
                            if startFree || endFree { near += 1 } else { unsure += 1 }
                        } else {
                            differences.append("\(name) line \(i) (mode \(mode)): KiCad \(theirs), ours \(mine)")
                        }
                    } else {
                        differences.append("\(name) line \(i) (mode \(mode)): KiCad \(theirs), ours \(mine)")
                    }
                    step = nil
                    helper = nil
                    tool = nil
                default:
                    break
                }
            }
        }
        print("extensions: \(lines) lines drawn in KiCad (\(byMode[0]) free, \(byMode[1]) at 45°, \(byMode[2]) at 90°), \(rests) rests"
              + " (\(fired) with a proposal taken), \(onConstruction) ends off the grid, \(near) within the pointer's half micrometre"
              + " where Ctrl took the grid away, \(unsure) a micrometre off the grid's point where the pixel is half way between two,"
              + " \(differences.count) differences; ends at \(kinds.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "))")
        XCTAssertGreaterThan(lines, 0)
        XCTAssertEqual(differences, [], differences.prefix(12).joined(separator: "\n"))
    }

    /// DRAWING_TOOL::DrawZone draws a zone's outline as it draws a graphic polygon, with the same POLYGON_GEOM_MANAGER
    /// in the line mode (Draw Polygons is DrawZone in its graphic polygon mode, checked against KiCad by
    /// DrawingToolsTests): the zone's outline PolygonDrawing makes is the polygon GraphicTool draws from the same moves
    /// and clicks, in each line mode, Ctrl letting a leader go free
    func testZoneOutlineInLineModesIsThePolygonTools() {
        // (a little linear congruential generator, for the same cases each run)
        var seed: UInt64 = 20261128
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        var cases = 0
        for mode in LeaderMode.allCases {
            for _ in 0..<300 {
                var zone = PolygonDrawing(leaderMode: mode)
                var polygon = GraphicTool(.polygon, layer: "F.Cu", angleSnap: mode)
                var closed = false
                var made: [BoardShape] = []
                var first: IPoint?
                for k in 0..<(3 + next(5)) {
                    // (now and then the first corner again, which closes the outline)
                    var p = IPoint((next(41) - 20) * 500_000, (next(41) - 20) * 500_000)
                    if k >= 3, next(4) == 0, let f = first { p = f }
                    if first == nil { first = p }
                    let ctrl = next(5) == 0
                    zone.move(to: p, ctrl: ctrl)
                    polygon.move(to: p, ctrl: ctrl)
                    closed = zone.click(p, ctrl: ctrl)
                    made = polygon.click(at: p, ctrl: ctrl)
                    if closed { break }
                }
                if !closed { made = polygon.finishPolygon() }
                XCTAssertEqual(zone.outline, made.first?.points, "mode \(mode)")
                cases += 1
            }
        }
        XCTAssertEqual(cases, 900)
    }
}
