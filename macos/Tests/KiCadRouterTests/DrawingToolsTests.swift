import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// KiCad's own drawing tools and point editor, driven by the pointer in its PCB editor (tools/kicad-reference/
/// drawing.py: lines, rectangles, circles, arcs, polygons and dimensions of each kind drawn, then edit points of the
/// graphics dragged, KiCad's angle snap mode the plan's), and the port's (GraphicTool, DimensionTool,
/// ShapePointEditor) given the same events at the same points of the grid: every graphic and dimension the port makes
/// is the one KiCad made, to the nanometre (its kind, points, an arc's middle and centre, its pen, its fill; a
/// dimension's text, where it is put and at what angle, and every line it is drawn with), and every graphic the port's
/// point editor leaves is the one KiCad's left. The fixtures are Fixtures/drawing (drawing.py's boards, drawn by
/// KiCad); KICAD_DRAWING_REFERENCE names another folder of them.
final class DrawingToolsTests: XCTestCase {
    static func records() throws -> [URL] {
        let folder: URL
        if let other = ProcessInfo.processInfo.environment["KICAD_DRAWING_REFERENCE"] {
            folder = URL(fileURLWithPath: other)
        } else {
            folder = try XCTUnwrap(Bundle.module.url(forResource: "drawing", withExtension: nil, subdirectory: "Fixtures"))
        }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "drawn" }.sorted { $0.path < $1.path }
    }

    static func point(_ v: Any?) -> IPoint? {
        guard let a = v as? [NSNumber], a.count == 2 else { return nil }
        return IPoint(a[0].intValue, a[1].intValue)
    }

    /// What KiCad read of a graphic, and the port's as it reads back from what it writes
    static func compare(_ s: [String: Any], _ made: BoardShape, _ what: String) {
        let ours = BoardShape(made.node(uuid: "0"))!
        XCTAssertEqual(s["kind"] as? String, ours.kind.rawValue, what)
        XCTAssertEqual((s["width"] as? NSNumber)?.intValue, ours.width, what)
        XCTAssertEqual(s["filled"] as? Bool, ours.filled, what)
        XCTAssertEqual(s["layer"] as? String, ours.layer, what)
        switch ours.kind {
        case .segment, .rectangle:
            XCTAssertEqual(point(s["start"]), ours.start, what + " start")
            XCTAssertEqual(point(s["end"]), ours.end, what + " end")
        case .arc:
            XCTAssertEqual(point(s["start"]), ours.start, what + " start")
            XCTAssertEqual(point(s["mid"]), ours.arcMidPoint, what + " mid")
            XCTAssertEqual(point(s["end"]), ours.end, what + " end")
            XCTAssertEqual(point(s["center"]), ours.center, what + " centre")
        case .circle:
            XCTAssertEqual(point(s["center"]), ours.start, what + " centre")
            XCTAssertEqual(point(s["end"]), ours.end, what + " end")
        case .polygon:
            XCTAssertEqual((s["points"] as? [[NSNumber]])?.map { IPoint($0[0].intValue, $0[1].intValue) }, ours.points, what + " corners")
        }
    }

    static func compare(_ d: [String: Any], _ made: BoardDimension, _ what: String) {
        guard let ours = BoardDimension(made.node(uuid: "0")) else { return XCTFail(what) }
        XCTAssertEqual(d["kind"] as? String, ours.kind.rawValue, what)
        XCTAssertEqual(point(d["start"]), ours.start, what + " start")
        XCTAssertEqual(point(d["end"]), ours.end, what + " end")
        XCTAssertEqual(d["text"] as? String, ours.text, what + " text")
        XCTAssertEqual(point(d["textPos"]), ours.textPos, what + " text position")
        XCTAssertEqual((d["textAngle"] as? NSNumber)?.doubleValue ?? .nan, ours.textAngle.degrees, accuracy: 1e-9, what + " text angle")
        XCTAssertEqual((d["measured"] as? NSNumber)?.intValue, ours.measuredValue, what + " measured")
        XCTAssertEqual((d["lineThickness"] as? NSNumber)?.intValue, ours.lineThickness, what + " line")
        if let h = d["height"] as? NSNumber { XCTAssertEqual(h.intValue, ours.height, what + " height") }
        let theirs = (d["shapes"] as? [[Any]] ?? []).map { s -> String in
            if s.first as? String == "circle" { return "circle \(point(s[1]) ?? .zero) \((s[2] as? NSNumber)?.intValue ?? 0)" }
            return "segment \(point(s[1]) ?? .zero) \(point(s[2]) ?? .zero)"
        }
        let mine = ours.shapes.map { s -> String in
            switch s {
            case .segment(let a, let b): return "segment \(a) \(b)"
            case .circle(let c, let r): return "circle \(c) \(r)"
            }
        }
        XCTAssertEqual(theirs, mine, what + " lines")
    }

    func testKiCadsDrawingToolsAndPointEditorAreFollowed() throws {
        let files = try Self.records()
        guard !files.isEmpty else { throw XCTSkip("no drawing fixtures") }
        var graphics = 0, dimensions = 0, edits = 0, heightsOffGrid = 0, heightsExact = 0, heightsOff = 0
        for file in files {
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let plan = try XCTUnwrap(record["plan"] as? [String: Any])
            let steps = try XCTUnwrap(plan["steps"] as? [[String: Any]])
            let snap = LeaderMode(rawValue: (plan["angleSnap"] as? NSNumber)?.intValue ?? 0) ?? .direct
            let project = BoardEditingTests.project(file.deletingPathExtension().appendingPathExtension("kicad_pro"))
            let widths = LineWidths(project: project), texts = TextDefaults(project: project)
            let defaults = DimensionDefaults(project: project)
            let kicad = try XCTUnwrap(record["kicad"] as? [String: Any])
            let drawn = try XCTUnwrap(kicad["drawn"] as? [String: Any]), edited = try XCTUnwrap(kicad["edited"] as? [String: Any])
            func byID(_ board: [String: Any], _ key: String) -> [String: [String: Any]] {
                Dictionary((board[key] as? [[String: Any]] ?? []).map { ($0["uuid"] as? String ?? "", $0) }, uniquingKeysWith: { a, _ in a })
            }
            let drawnShapes = byID(drawn, "shapes"), drawnDims = byID(drawn, "dimensions"), editedShapes = byID(edited, "shapes")
            let name = file.lastPathComponent
            // (five pixels at the view's scale: how far the pointer goes from a polygon's corner held at 45° before
            // it lets go)
            let transform = record["transform"] as? [String: Any]
            let pixel = abs((transform?["sx"] as? NSNumber)?.doubleValue ?? 0.05) * 1e6
            let sticky = KiMath.round(5 * pixel)
            // the port's tools given KiCad's events
            var tool: GraphicTool?
            var dimTool: DimensionTool?
            var made: [String: [Any]] = [:]
            var making: [Any] = []
            var step = 0
            var at = IPoint.zero
            var offGrid = false
            var downPixel: IPoint?
            var downAt = IPoint.zero
            var dragging = false
            let dragThreshold = Self.point(record["dragThreshold"]) ?? IPoint(8, 8)
            var editor: ShapePointEditor?
            var editedUUID = "", editedHandle: ShapePointEditor.Handle?
            var portShapes: [String: BoardShape] = [:]
            for ev in record["events"] as? [[String: Any]] ?? [] {
                switch ev["ev"] as? String {
                case "mark":
                    step = (ev["step"] as? NSNumber)?.intValue ?? 0
                    making = []
                case "menu":
                    let path = ev["path"] as? [String] ?? []
                    tool = nil
                    dimTool = nil
                    let kinds: [String: GraphicTool.Kind] = ["Draw Lines": .line, "Draw Rectangles": .rectangle, "Draw Circles": .circle,
                                                             "Draw Arcs": .arc, "Draw Polygons": .polygon]
                    let dims: [String: BoardDimension.Kind] = ["Draw Aligned Dimensions": .aligned, "Draw Orthogonal Dimensions": .orthogonal,
                                                               "Draw Center Dimensions": .center, "Draw Radial Dimensions": .radial,
                                                               "Draw Leaders": .leader]
                    if let k = kinds[path.last ?? ""] { tool = GraphicTool(k, layer: "F.Cu", widths: widths, angleSnap: snap) }
                    if let k = dims[path.last ?? ""] { dimTool = DimensionTool(k, layer: "F.Cu", defaults: defaults, widths: widths, texts: texts, angleSnap: snap) }
                case "move":
                    at = try XCTUnwrap(Self.point(ev["at"]))
                    if editedHandle != nil, !dragging, let p = Self.point(ev["pixel"]), let d = downPixel {
                        // (KiCad's tool dispatcher takes the pointer for a drag once it is past the system's drag
                        // threshold from where the button went down: a move short of it drags nothing; and the
                        // point editor then drags the first edit point within eight pixels of where it went down)
                        dragging = abs(p.x - d.x) > dragThreshold.x || abs(p.y - d.y) > dragThreshold.y
                        if !dragging { continue }
                        guard var e = editor else { continue }
                        let h = e.handle(at: downAt, size: KiMath.round(8 * pixel))
                        if h != editedHandle, let h {
                            e.endDrag()
                            e.beginDrag(h)
                            editedHandle = h
                            editor = e
                        }
                    }
                    // (KiCad's grid off for an aligned dimension's height: the pointer where the view puts it, which the
                    // view's transform fitted to the status bar's micrometres gives to some tens of nanometres)
                    if let t = dimTool, !t.snapsToGrid, let raw = ev["raw"] as? [NSNumber] {
                        at = IPoint(KiMath.round(raw[0].doubleValue), KiMath.round(raw[1].doubleValue))
                        offGrid = true
                    }
                    if let h = editedHandle, var e = editor {
                        // (the pointer in the drag: where the view puts it, KiCad rounding it to the nanometre)
                        let raw = (ev["raw"] as? [NSNumber]).map { IPoint(KiMath.round($0[0].doubleValue), KiMath.round($0[1].doubleValue)) } ?? at
                        e.drag(h, to: raw, grid: PointGrid(size: IPoint(1000, 1000)), stickyLimit: sticky)
                        editor = e
                    } else {
                        tool?.move(to: at)
                        dimTool?.move(to: at)
                    }
                case "click", "dclick":
                    let double = ev["ev"] as? String == "dclick"
                    if var t = tool {
                        making += t.click(at: at)
                        if double { making += t.click(at: at, double: true) }
                        tool = t
                    }
                    if var t = dimTool {
                        if let d = t.click(at: at) { making.append(d) }
                        if double, let d = t.click(at: at, double: true) { making.append(d) }
                        dimTool = t
                    }
                case "key":
                    tool?.cancel()
                    dimTool?.cancel()
                case "made":
                    let uuids = ev["uuids"] as? [String] ?? []
                    made["\(step)"] = making
                    XCTAssertEqual(uuids.count, making.count, "\(name) step \(step) \(steps[step]["op"] ?? "")")
                    for (uuid, m) in zip(uuids, making) {
                        if let s = m as? BoardShape, let theirs = drawnShapes[uuid] {
                            Self.compare(theirs, s, "\(name) step \(step) \(s.kind)")
                            // (edited as KiCad has it in memory, not as it reads it back: an arc's centre as drawn)
                            portShapes[uuid] = s
                            graphics += 1
                        } else if var d = m as? BoardDimension, let theirs = drawnDims[uuid] {
                            if offGrid, let h = (theirs["height"] as? NSNumber)?.intValue {
                                // (its height from a pointer known to a hundred nanometres or so: KiCad's height, within
                                // that, then all the dimension makes of it to the nanometre)
                                XCTAssertEqual(Double(d.height), Double(h), accuracy: 250, "\(name) step \(step) height off the grid")
                                heightsExact += d.height == h ? 1 : 0
                                heightsOff = max(heightsOff, abs(d.height - h))
                                d.height = h
                                d.update()
                                offGrid = false
                                heightsOffGrid += 1
                            }
                            Self.compare(theirs, d, "\(name) step \(step) \(d.kind) dimension")
                            dimensions += 1
                        } else {
                            XCTFail("\(name) step \(step): KiCad's \(uuid) not read")
                        }
                    }
                case "select", "copy":
                    // (the drawing done: the edits, with the select tool)
                    tool = nil
                    dimTool = nil
                case "hover":
                    editedUUID = ev["uuid"] as? String ?? ""
                    let shape = try XCTUnwrap(portShapes[editedUUID], "\(name): \(editedUUID)")
                    var e = ShapePointEditor(shape)
                    e.arcEditMode = .keepCenterAdjustAngleRadius
                    e.angleSnap = snap
                    let handleName = ev["handle"] as? String ?? ""
                    let handle: ShapePointEditor.Handle
                    switch (shape.kind, handleName) {
                    case (_, "start"): handle = .point(0)
                    case (.arc, "mid"): handle = .point(ShapePointEditor.arcMid)
                    case (.arc, "end"): handle = .point(ShapePointEditor.arcEnd)
                    case (.arc, "center"): handle = .point(ShapePointEditor.arcCenter)
                    case (.segment, "end"), (.circle, "end"): handle = .point(1)
                    case (.circle, "center"): handle = .point(0)
                    case (.rectangle, "center"): handle = .point(ShapePointEditor.rectCenter)
                    case (_, let h) where h.hasPrefix("corner"): handle = .point(Int(h.dropFirst(6)) ?? 0)
                    case (_, let h) where h.hasPrefix("side"): handle = .line(Int(h.dropFirst(4)) ?? 0)
                    default: return XCTFail("\(name): handle \(handleName)")
                    }
                    // KiCad's edit point is where the port's is
                    XCTAssertEqual(Self.point(ev["handleAt"]), e.position(handle), "\(name) \(shape.kind) \(handleName)")
                    e.beginDrag(handle)
                    editor = e
                    editedHandle = handle
                    downPixel = Self.point(ev["pixel"])
                    downAt = (ev["raw"] as? [NSNumber]).map { IPoint(KiMath.round($0[0].doubleValue), KiMath.round($0[1].doubleValue)) } ?? .zero
                    dragging = false
                case "up":
                    guard var e = editor else { continue }
                    e.endDrag()
                    portShapes[editedUUID] = e.shape
                    editor = nil
                    editedHandle = nil
                    edits += 1
                default:
                    break
                }
            }
            // the graphics as KiCad's point editor left them
            for (uuid, theirs) in editedShapes {
                guard let ours = portShapes[uuid] else { continue }
                Self.compare(theirs, ours, "\(name) edited \(ours.kind)")
            }
        }
        print("drawing tools: \(files.count) boards, \(graphics) graphics and \(dimensions) dimensions as KiCad's tools drew them (\(heightsOffGrid) heights off the grid, \(heightsExact) of them to the nanometre, the others within \(heightsOff) nm), \(edits) points dragged as its point editor dragged them")
        XCTAssertGreaterThan(graphics, 0)
    }
}
