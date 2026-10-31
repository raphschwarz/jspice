import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// Graphics and dimensions drawn on boards with the port's tools (GraphicTool, DimensionTool: pointer moves and
/// clicks, Ctrl, the angle snap modes, W), edited with its point editor (ShapePointEditor), corners added and taken
/// away, moved, turned and taken away, each as one change; then KiCad (its pcbnew module, tools/kicad-reference/
/// graphics.py) reads the boards: each graphic as the port made it (its kind, points, an arc's middle and centre,
/// pen, fill, layer) and as KiCad's tools would have made it on its layer (GetLineThickness, a polygon's fill), KiCad
/// writing each again as the port wrote it; each dimension's text, where KiCad's Update puts it and at what angle,
/// what it measured and every line it draws, as the port has them. KiCad's Move and Rotate of the same items make what
/// the port's make. An outline drawn on Edge.Cuts with the port's tools is one KiCad's DRC and the port's find whole.
final class GraphicsTests: XCTestCase {
    /// KiCad's reading of `files` (graphics.py, with `arguments` before them), nil where its pcbnew module is not to be
    /// had
    static func kicadReads(_ files: [URL], arguments: [String] = []) throws -> [String: Any]? {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent("../../tools/kicad-reference/graphics.py").standardized
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path] + arguments + files.map(\.path)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        // (SWIG's notes of leaks come before the JSON on standard output)
        guard let start = data.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        return try JSONSerialization.jsonObject(with: data[start...]) as? [String: Any]
    }

    static func requireKiCad() throws {
        if ProcessInfo.processInfo.environment["JSPICE_REQUIRE_KICAD"] != nil { XCTFail("KiCad 10's pcbnew module is needed") }
        throw XCTSkip("KiCad's pcbnew module is not installed")
    }

    static func nm(_ x: Double, _ y: Double) -> IPoint { IPoint(Int((x * 1e6).rounded()), Int((y * 1e6).rounded())) }

    static func ints(_ v: Any?) -> [Int]? { (v as? [NSNumber])?.map(\.intValue) }

    /// A project of other defaults: line widths, dimension settings (every other board's)
    static func project(_ file: URL, _ n: Int) -> [String: Any]? {
        guard var p = BoardEditingTests.project(file) else { return nil }
        guard n % 2 == 1, var b = p["board"] as? [String: Any], var ds = b["design_settings"] as? [String: Any],
              var d = ds["defaults"] as? [String: Any] else { return p }
        d["silk_line_width"] = 0.12
        d["copper_line_width"] = 0.25
        d["board_outline_line_width"] = 0.1
        d["courtyard_line_width"] = 0.075
        d["fab_line_width"] = 0.11
        d["other_line_width"] = 0.13
        d["dimension_units"] = n % 4 == 1 ? 0 : 2
        d["dimension_precision"] = n % 4 == 1 ? 3 : 7
        var dims = d["dimensions"] as? [String: Any] ?? [:]
        dims["units_format"] = n % 4 == 1 ? 1 : 2
        dims["suppress_zeroes"] = n % 4 != 1
        dims["text_position"] = n % 4 == 1 ? 1 : 0
        dims["keep_text_aligned"] = n % 4 != 1
        dims["arrow_length"] = 1_000_000
        dims["extension_offset"] = 250_000
        d["dimensions"] = dims
        ds["defaults"] = d
        b["design_settings"] = ds
        p["board"] = b
        return p
    }

    /// What the tests drew on a board, by id: each graphic and dimension as the port has it
    struct Drawn {
        var shapes: [String: BoardShape] = [:]
        var dimensions: [String: BoardDimension] = [:]
        var widened: Set<String> = []
        var edits = 0
    }

    /// Graphics drawn with each of the tools on `layer`, around `o` (nm), as the pointer would draw them
    static func draw(_ session: BoardEditing, layer: String, at o: IPoint, k: Int, into drawn: inout Drawn) throws {
        func commit(_ shapes: [BoardShape], widened: Bool = false) throws {
            for s in shapes {
                let edit = try XCTUnwrap(session.addShape(s), layer)
                XCTAssertEqual(edit.name, BoardEditing.drawName(s))
                XCTAssertEqual(edit.outline, layer == "Edge.Cuts")
                let uuid = try XCTUnwrap(edit.drawings.first)
                drawn.shapes[uuid] = try XCTUnwrap(session.shape(uuid))
                if widened { drawn.widened.insert(uuid) }
                drawn.edits += 1
            }
        }
        func p(_ dx: Double, _ dy: Double) -> IPoint { o + nm(dx, dy) }
        // a chain of lines, held to 45° (the editor's snap mode), finished by a double click
        var line = session.graphicTool(.line, layer: layer, angleSnap: k % 2 == 0 ? .deg45 : .direct)
        XCTAssertEqual(line.width, session.lineWidths.width(layer))
        try commit(line.click(at: p(0, 0)))
        for (i, q) in [p(3.123, 0.4), p(4.2, 3.9), p(1.7, 6.31), p(-0.8, 5.95)].enumerated() {
            line.move(to: q, ctrl: i == 3)
            try commit(line.click(at: q))
        }
        line.move(to: p(-0.8, 5.95))
        XCTAssertEqual(line.committedLines.count, 4)
        try commit(line.click(at: p(-0.8, 5.95), double: true))
        XCTAssertFalse(line.isDrawing)
        // one closed on the end of a line already there (KiCad's snap to it)
        var closing = session.graphicTool(.line, layer: layer)
        try commit(closing.click(at: p(-0.8, 5.95)))
        closing.move(to: p(0, 0))
        try commit(closing.click(at: p(0, 0), onGraphicEnd: true))
        XCTAssertFalse(closing.isDrawing)
        // a rectangle (Ctrl: square), drawn from its bottom right
        var rect = session.graphicTool(.rectangle, layer: layer)
        try commit(rect.click(at: p(9.5, 4.25)))
        rect.move(to: p(6.1, 1.3), ctrl: k % 2 == 1)
        try commit(rect.click(at: p(6.1, 1.3)))
        // a circle, its pen made wider (W)
        var circle = session.graphicTool(.circle, layer: layer)
        circle.stepWidth(true)
        _ = circle.click(at: p(12.0, 2.0))
        circle.move(to: p(13.37, 2.9), ctrl: k % 3 == 0)
        try commit(circle.click(at: p(13.37, 2.9)), widened: true)
        // arcs by their centre, start and end: counterclockwise, clockwise, and past a half turn
        for (j, (c, s, ways)) in [(p(17, 3), p(19.5, 3.2), [p(18.9, 1.4), p(17.2, 0.5)]),
                                  (p(17, 9), p(19.1, 8.0), [p(18.6, 10.4), p(16.0, 11.1)]),
                                  (p(23, 5), p(25.0, 5.0), [p(23.1, 3.0), p(21.0, 5.2), p(22.6, 7.0)])].enumerated() {
            var arc = session.graphicTool(.arc, layer: layer, angleSnap: j == 1 && k % 2 == 0 ? .deg45 : .direct)
            arc.move(to: c)
            _ = arc.click(at: c)
            arc.move(to: s)
            _ = arc.click(at: s)
            for q in ways { arc.move(to: q) }
            let made = arc.click(at: ways.last!)
            XCTAssertEqual(made.count, 1, "arc \(j)")
            try commit(made)
        }
        // polygons: free, at 45° and at 90°, finished by a double click and by a click on the first corner
        for (j, mode) in [LeaderMode.direct, .deg45, .deg90].enumerated() {
            var poly = session.graphicTool(.polygon, layer: layer, angleSnap: mode)
            let corners = [p(0, 10 + Double(j) * 6), p(4.3, 10.7 + Double(j) * 6), p(5.1, 14.2 + Double(j) * 6), p(1.2, 15.3 + Double(j) * 6)]
            for q in corners {
                poly.move(to: q)
                _ = poly.click(at: q)
            }
            let made: [BoardShape]
            if j == 1 {
                poly.move(to: corners[0])
                made = poly.click(at: corners[0])
            } else {
                made = poly.click(at: corners[3], double: true)
            }
            XCTAssertEqual(made.count, 1, "polygon \(mode)")
            try commit(made)
        }
    }

    func testGraphicsAreDrawnAndEditedAsKiCadMakesThem() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-graphics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var written: [(URL, Drawn, BoardEditing)] = []
        var total = 0
        for (n, file) in try BoardEditingTests.boards().enumerated() {
            let board = try KiCadBoard.read(file)
            let project = n == 4 ? nil : Self.project(file, n)
            let session = BoardEditing(board: board, project: project)
            let layers = Set(board.root["layers"]?.items.compactMap { $0.text(at: 0) } ?? [])
            var drawn = Drawn()
            var k = 0
            for layer in ["F.SilkS", "B.SilkS", "F.Cu", "In1.Cu", "B.Cu", "F.Fab", "Dwgs.User", "User.1", "F.CrtYd", "Edge.Cuts"]
            where layers.contains(layer) {
                let o = Self.nm(40 + Double(k % 4) * 32, -60 - Double(k / 4) * 40 - Double(n) * 0.01)
                try Self.draw(session, layer: layer, at: o, k: k + n, into: &drawn)
                k += 1
            }
            // each kind's points dragged with the point editor, each a change (Move Point)
            var dragged = 0
            for (uuid, shape) in drawn.shapes.sorted(by: { $0.key < $1.key }) where shape.layer != "Edge.Cuts" || dragged % 2 == 0 {
                var editor = ShapePointEditor(shape)
                editor.arcEditMode = [.keepCenterAdjustAngleRadius, .keepEndpointsOrStartDirection, .keepCenterEndsAdjustAngle][dragged % 3]
                let grid = PointGrid(size: IPoint(1000, 1000))
                for (h, handle) in editor.handles.enumerated() {
                    let from = editor.position(handle)
                    editor.beginDrag(handle)
                    for t in [0.4, 1.0] {
                        let to = from + IPoint(Int(Double(310_000 + 70_000 * h) * t), Int(Double(-170_000 + 50_000 * (h % 3)) * t))
                        editor.drag(handle, to: to, grid: grid, stickyLimit: 50_000)
                    }
                    editor.endDrag()
                }
                if let edit = session.setShape(uuid, to: editor.shape) {
                    XCTAssertEqual(edit.name, "Move Point")
                    drawn.shapes[uuid] = try XCTUnwrap(session.shape(uuid))
                    drawn.edits += 1
                }
                dragged += 1
            }
            // corners added and taken away, lines and arcs split
            for (uuid, shape) in drawn.shapes.sorted(by: { $0.key < $1.key }) where shape.layer == "Dwgs.User" || shape.layer == "F.Fab" {
                switch shape.kind {
                case .polygon:
                    let edit = try XCTUnwrap(session.addCorner(uuid, at: BoardEditingTests.mm(Seg(shape.points[0], shape.points[1]).center + IPoint(3, 2))))
                    XCTAssertEqual(edit.name, "Add Zone Corner")
                    let removed = try XCTUnwrap(session.removeCorner(uuid, index: 2))
                    XCTAssertEqual(removed.name, "Remove Polygon Corner")
                    drawn.shapes[uuid] = try XCTUnwrap(session.shape(uuid))
                    XCTAssertEqual(drawn.shapes[uuid]?.points.count, shape.points.count)
                    drawn.edits += 2
                case .segment, .arc:
                    let mid = shape.kind == .arc ? shape.arcMidPoint : Seg(shape.start, shape.end).center
                    let edit = try XCTUnwrap(session.addCorner(uuid, at: BoardEditingTests.mm(mid + IPoint(1234, -987))))
                    XCTAssertEqual(edit.name, shape.kind == .arc ? "Split Arc" : "Split Segment")
                    XCTAssertEqual(edit.drawings.count, 2)
                    for id in edit.drawings { drawn.shapes[id] = try XCTUnwrap(session.shape(id)) }
                    drawn.edits += 1
                default:
                    break
                }
            }
            total += drawn.shapes.count
            let copy = work.appendingPathComponent(file.lastPathComponent)
            try session.router.board.write(to: copy)
            if let project {
                try JSONSerialization.data(withJSONObject: project).write(to: copy.deletingPathExtension().appendingPathExtension("kicad_pro"))
            }
            written.append((copy, drawn, session))
        }
        guard let read = try Self.kicadReads(written.map(\.0)) else { return try Self.requireKiCad() }
        var checked = 0, saved = 0
        for (file, drawn, session) in written {
            let board = try XCTUnwrap(read[file.path] as? [String: Any])
            let widths = try XCTUnwrap(board["widths"] as? [String: NSNumber])
            for (layer, w) in widths { XCTAssertEqual(session.lineWidths.width(layer), w.intValue, "\(file.lastPathComponent) \(layer)") }
            let texts = try XCTUnwrap(board["saved"] as? [String: String])
            for s in board["shapes"] as? [[String: Any]] ?? [] {
                guard let uuid = s["uuid"] as? String, let ours = drawn.shapes[uuid] else { continue }
                checked += 1
                let what = "\(file.lastPathComponent) \(ours.layer) \(ours.kind)"
                XCTAssertEqual(s["kind"] as? String, ours.kind.rawValue, what)
                XCTAssertEqual(s["layer"] as? String, ours.layer, what)
                XCTAssertEqual((s["width"] as? NSNumber)?.intValue, ours.width, what)
                let expected = try XCTUnwrap(s["expected"] as? [String: Any])
                // (KiCad's tools give each new graphic its layer's pen; W made one 0.1 mm wider)
                let pen = (expected["width"] as? NSNumber)?.intValue ?? -1
                XCTAssertEqual(ours.width, drawn.widened.contains(uuid) ? pen + GraphicTool.widthStep : pen, what)
                XCTAssertEqual(s["filled"] as? Bool, ours.filled, what)
                XCTAssertEqual(ours.filled, ours.kind == .polygon && (expected["filled"] as? Bool ?? false), what)
                switch ours.kind {
                case .segment, .rectangle:
                    XCTAssertEqual(Self.ints(s["start"]), [ours.start.x, ours.start.y], what)
                    XCTAssertEqual(Self.ints(s["end"]), [ours.end.x, ours.end.y], what)
                    if ours.kind == .rectangle { XCTAssertEqual((s["radius"] as? NSNumber)?.intValue, ours.cornerRadius, what) }
                case .arc:
                    XCTAssertEqual(Self.ints(s["start"]), [ours.start.x, ours.start.y], what)
                    XCTAssertEqual(Self.ints(s["end"]), [ours.end.x, ours.end.y], what)
                    XCTAssertEqual(Self.ints(s["mid"]), [ours.arcMidPoint.x, ours.arcMidPoint.y], what)
                    XCTAssertEqual(Self.ints(s["center"]), [ours.center.x, ours.center.y], what)
                    XCTAssertEqual((s["radius"] as? NSNumber)?.intValue, ours.radius, what)
                case .circle:
                    XCTAssertEqual(Self.ints(s["center"]), [ours.start.x, ours.start.y], what)
                    XCTAssertEqual(Self.ints(s["end"]), [ours.end.x, ours.end.y], what)
                    XCTAssertEqual((s["radius"] as? NSNumber)?.intValue, ours.radius, what)
                case .polygon:
                    XCTAssertEqual((s["points"] as? [[NSNumber]])?.map { [$0[0].intValue, $0[1].intValue] }, ours.points.map { [$0.x, $0.y] }, what)
                }
                // KiCad writes it again as the port wrote it
                let node = try XCTUnwrap(session.router.board.root.items.first { $0.value("uuid") == uuid })
                let theirs = try SExpr.parse(try XCTUnwrap(texts[uuid], what))
                XCTAssertEqual(theirs.compact, node.compact, what)
                saved += 1
            }
        }
        print("graphics: \(written.count) boards, \(total) graphics, \(written.map(\.1.edits).reduce(0, +)) changes; KiCad read \(checked) as made, wrote \(saved) as the port wrote them")
        XCTAssertEqual(checked, total)
        XCTAssertGreaterThan(checked, 100)
    }

    /// The port's line tool and its 45° hold, its rectangle, circle and arc tools, and its polygon's leader, by
    /// what KiCad's geometry managers make of the same points (GetVectorSnapped45, the arc's radius and angles)
    func testToolsHoldTheirAnglesAsKiCadsDo() throws {
        XCTAssertEqual(vectorSnapped45(IPoint(1000, 300)), IPoint(1000, 0))
        XCTAssertEqual(vectorSnapped45(IPoint(1000, 600)), IPoint(1000, 1000))
        XCTAssertEqual(vectorSnapped45(IPoint(-300, 1000)), IPoint(0, 1000))
        XCTAssertEqual(vectorSnapped45(IPoint(-700, 1000)), IPoint(-1000, 1000))
        XCTAssertEqual(vectorSnapped45(IPoint(1000, 0), only45: true), IPoint(1000, 1000))
        XCTAssertEqual(vectorSnapped45(IPoint(-1000, 10), only45: true), IPoint(-1000, 1000))
        // a line held to 45° goes on from where the last ended
        var line = GraphicTool(.line, layer: "F.SilkS", angleSnap: .deg45)
        _ = line.click(at: IPoint(0, 0))
        line.move(to: IPoint(1_000_000, 380_000))
        let first = line.click(at: IPoint(1_000_000, 380_000))
        XCTAssertEqual(first.map(\.end), [IPoint(1_000_000, 0)])
        line.move(to: IPoint(1_600_000, 700_000))
        let second = line.click(at: IPoint(1_600_000, 700_000))
        XCTAssertEqual(second.map(\.start), [IPoint(1_000_000, 0)])
        XCTAssertEqual(second.map(\.end), [IPoint(1_700_000, 700_000)])
        XCTAssertEqual(line.deleteLastPoint(), .undoLine)
        XCTAssertTrue(line.isDrawing)
        // an arc from centre (0, 0), start (2, 0): counterclockwise on the screen through (0, -2) to (-2, 0)
        var arc = GraphicTool(.arc, layer: "Dwgs.User")
        _ = arc.click(at: .zero)
        arc.move(to: IPoint(2_000_000, 0))
        _ = arc.click(at: IPoint(2_000_000, 0))
        arc.move(to: IPoint(1_000_000, -1_900_000))
        arc.move(to: IPoint(-2_000_000, 0))
        let made = try XCTUnwrap(arc.click(at: IPoint(-2_000_000, 0)).first)
        XCTAssertEqual(made.center, .zero)
        XCTAssertEqual(made.radius, 2_000_000)
        XCTAssertEqual(made.arcMidPoint, IPoint(0, -2_000_000))
        // a polygon of fewer than three corners is none
        var poly = GraphicTool(.polygon, layer: "F.SilkS")
        _ = poly.click(at: .zero)
        _ = poly.click(at: IPoint(1_000_000, 0))
        XCTAssertEqual(poly.click(at: IPoint(1_000_000, 0), double: true), [])
        // the measure tool's readout
        var ruler = Ruler()
        ruler.click(at: IPoint(1_000_000, 1_000_000))
        ruler.move(to: IPoint(4_000_000, -3_000_000))
        XCTAssertEqual(ruler.readout(), ["x: 3.000 mm", "y: -4.000 mm", "r: 5.000 mm", "θ: 53.1°"])
        ruler.move(to: IPoint(4_000_000, -2_000_000), shift: true)
        XCTAssertEqual(ruler.end, IPoint(4_000_000, -2_000_000))
        XCTAssertEqual(ruler.readout(.mils)[2], "r: 167.0 mils")
        ruler.move(to: IPoint(4_100_000, -1_000_000), shift: true)
        XCTAssertEqual(ruler.end, IPoint(4_100_000, -2_100_000))
    }

    /// Dimensions of each kind drawn with the port's dimension tool on boards whose projects have other dimension
    /// defaults (units, precision, units format, zeroes, text position, text kept aligned, arrow length, extension
    /// offset), on the front and the back; KiCad reads each as made: the text KiCad's Update makes and where it puts
    /// it, at what angle, what it measured, every line it draws (GetShapes); KiCad writes each again as the port wrote it
    func testDimensionsAreMadeAsKiCadMakesThem() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-dimensions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var written: [(URL, [String: BoardDimension], BoardEditing)] = []
        for (n, file) in try BoardEditingTests.boards().enumerated() {
            let project = n == 4 ? nil : Self.project(file, n)
            let session = BoardEditing(board: try KiCadBoard.read(file), project: project)
            var made: [String: BoardDimension] = [:]
            var k = 0
            for layer in ["Dwgs.User", "F.SilkS", "B.Fab", "Cmts.User"] {
                for kind in BoardDimension.Kind.allCases {
                    k += 1
                    let o = Self.nm(30 + Double(k % 5) * 14.5, -40 - Double(k / 5) * 13 - Double(n) * 0.013)
                    var tool = session.dimensionTool(kind, layer: layer, angleSnap: k % 4 == 0 ? .deg45 : .direct)
                    let a = o, b = o + Self.nm(7.3 + Double(k % 3), Double(k % 7) - 3.1)
                    let h = o + Self.nm(Double(k % 5) - 1.2, k % 2 == 0 ? 3.7 : -2.9)
                    tool.move(to: a)
                    XCTAssertNil(tool.click(at: a))
                    tool.move(to: b)
                    var dim = tool.click(at: b)
                    if kind == .aligned || kind == .orthogonal {
                        XCTAssertNil(dim)
                        tool.move(to: h)
                        dim = tool.click(at: h)
                    }
                    var d = try XCTUnwrap(dim, "\(kind)")
                    // (now and then arrows inward, a leader's frame, a prefix and suffix)
                    if k % 3 == 0 { d.arrowsInward = kind == .aligned || kind == .orthogonal }
                    if kind == .leader { d.textFrame = k % 3 }
                    if k % 4 == 1 && kind != .center && kind != .leader {
                        d.prefix = "~"
                        d.suffix = " max"
                    }
                    d.update()
                    let edit = try XCTUnwrap(session.addDimension(d))
                    XCTAssertEqual(edit.name, "Draw Dimension")
                    let uuid = try XCTUnwrap(edit.drawings.first)
                    made[uuid] = try XCTUnwrap(session.dimension(uuid))
                }
            }
            let copy = work.appendingPathComponent(file.lastPathComponent)
            try session.router.board.write(to: copy)
            if let project {
                try JSONSerialization.data(withJSONObject: project).write(to: copy.deletingPathExtension().appendingPathExtension("kicad_pro"))
            }
            written.append((copy, made, session))
        }
        guard let read = try Self.kicadReads(written.map(\.0)) else { return try Self.requireKiCad() }
        var checked = 0
        for (file, made, session) in written {
            let board = try XCTUnwrap(read[file.path] as? [String: Any])
            let texts = try XCTUnwrap(board["saved"] as? [String: String])
            for d in board["dimensions"] as? [[String: Any]] ?? [] {
                guard let uuid = d["uuid"] as? String, let ours = made[uuid] else { continue }
                let what = "\(file.lastPathComponent) \(ours.layer) \(ours.kind)"
                DrawingToolsTests.compare(d, ours, what)
                let node = try XCTUnwrap(session.router.board.root.items.first { $0.value("uuid") == uuid })
                XCTAssertEqual(try SExpr.parse(try XCTUnwrap(texts[uuid])).compact, node.compact, what)
                checked += 1
            }
        }
        print("dimensions: \(checked) made, as KiCad reads and writes them")
        XCTAssertEqual(checked, written.map(\.1.count).reduce(0, +))
    }

    /// Graphics, dimensions and texts moved and turned by the port (moveDrawings, rotateTexts, rotateDrawings) and by
    /// KiCad (its Move and Rotate, graphics.py --transform) from the same board: the same items, as KiCad writes them
    func testMovesAndTurnsAreKiCads() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-turns-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var compared = 0
        for (n, file) in try BoardEditingTests.boards().enumerated() where n < 3 {
            let project = Self.project(file, n)
            let session = BoardEditing(board: try KiCadBoard.read(file), project: project)
            var drawn = Drawn()
            try Self.draw(session, layer: "Dwgs.User", at: Self.nm(40, -60), k: n, into: &drawn)
            try Self.draw(session, layer: "Edge.Cuts", at: Self.nm(80, -60), k: n + 1, into: &drawn)
            var dims: [String] = []
            for (j, kind) in BoardDimension.Kind.allCases.enumerated() {
                var tool = session.dimensionTool(kind, layer: "Cmts.User")
                let a = Self.nm(40 + Double(j) * 12, -20), b = a + Self.nm(6.2, 1.7)
                _ = tool.click(at: a)
                tool.move(to: b)
                var d = tool.click(at: b)
                if d == nil {
                    tool.move(to: a + Self.nm(1, 4))
                    d = tool.click(at: a + Self.nm(1, 4))
                }
                dims.append(try XCTUnwrap(session.addDimension(try XCTUnwrap(d))?.drawings.first))
            }
            let text = try XCTUnwrap(session.addText("Turned", at: KiCadPoint(45, -30), layer: "F.SilkS", angle: 30)?.drawings.first)
            let before = work.appendingPathComponent("before-" + file.lastPathComponent)
            try session.router.board.write(to: before)
            // the same moves and turns, one item at a time, by the port and by KiCad
            var ops: [[String: Any]] = []
            let shapes = drawn.shapes.keys.sorted()
            for (i, uuid) in (shapes + dims + [text]).enumerated() {
                if i % 3 == 0 {
                    let d = KiCadPoint(0.123456 * Double(i % 5 + 1), -0.987654)
                    XCTAssertNotNil(session.moveDrawings([uuid], by: d), uuid)
                    let delta = BoardEditing.nm(d)
                    ops.append(["uuid": uuid, "move": [delta.x, delta.y]])
                } else {
                    let degrees = i % 3 == 1 ? 90.0 : (session.shape(uuid)?.kind == .rectangle ? 270.0 : 33.5)
                    XCTAssertNotNil(session.rotateTexts([uuid], by: degrees), uuid)
                    ops.append(["uuid": uuid, "rotate": degrees, "center": NSNull()])
                }
            }
            // several turned together about a point
            let group = Array(shapes.prefix(4)) + [dims[0]]
            XCTAssertNotNil(session.rotateDrawings(group, by: 90, about: KiCadPoint(50.5, -55.25)))
            for uuid in group { ops.append(["uuid": uuid, "rotate": 90.0, "center": [50_500_000, -55_250_000]]) }
            let opsFile = work.appendingPathComponent("ops-\(n).json")
            try JSONSerialization.data(withJSONObject: ops).write(to: opsFile)
            guard let read = try Self.kicadReads([before], arguments: ["--transform", opsFile.path]) else { return try Self.requireKiCad() }
            let texts = try XCTUnwrap((read[before.path] as? [String: Any])?["saved"] as? [String: String])
            for uuid in shapes + dims + [text] {
                let node = try XCTUnwrap(session.router.board.root.items.first { $0.value("uuid") == uuid })
                XCTAssertEqual(try SExpr.parse(try XCTUnwrap(texts[uuid], uuid)).compact, node.compact, "\(file.lastPathComponent) \(node.head ?? "")")
                compared += 1
            }
        }
        print("moves and turns: \(compared) items as KiCad moves and turns them")
        XCTAssertGreaterThan(compared, 50)
    }

    /// A board's outline drawn anew with the port's line and arc tools (a corner rounded, the last line closing on the
    /// first's start), or as a polygon held to 45°: KiCad's DRC and the port's find it whole (no invalid_outline); left
    /// open, both find it malformed. (A board whose footprints draw on Edge.Cuts themselves, not closed, is malformed
    /// whatever is drawn: on it the two need only agree.)
    func testAnOutlineDrawnIsWholeToKiCadsDRC() throws {
        let kicad = KiCadInstallation.find()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-outline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var checked = 0, drawn = 0, whole = 0
        for file in try BoardEditingTests.boards() {
            for variant in ["lines", "polygon", "open"] {
                let board = try KiCadBoard.read(file)
                let project = BoardEditingTests.project(file)
                let session = BoardEditing(board: board, project: project)
                let box = try XCTUnwrap(board.itemBounds)
                let edges = Set(board.edgeDrawings.compactMap { $0.value("uuid") })
                let footprintEdges = board.root.items.contains { fp in
                    fp.head == "footprint" && fp.items.contains { $0.value("layer") == "Edge.Cuts" }
                }
                if !edges.isEmpty { XCTAssertTrue(try XCTUnwrap(session.removeDrawings(edges)).outline) }
                // (2 to 3 mm round everything, off the grid)
                let l = box.minX - 2.0371, t = box.minY - 2.5013, r = box.maxX + 2.9137, b = box.maxY + 2.2219
                func p(_ x: Double, _ y: Double) -> IPoint { Self.nm(x, y) }
                if variant == "polygon" {
                    var poly = session.graphicTool(.polygon, layer: "Edge.Cuts", angleSnap: .deg45)
                    for q in [p(l, t), p(r, t), p(r, b - 4), p(r - 4, b), p(l, b)] {
                        poly.move(to: q)
                        _ = poly.click(at: q)
                    }
                    let made = poly.click(at: p(l, b), double: true)
                    XCTAssertEqual(made.count, 1)
                    XCTAssertEqual(made.first?.filled, false)
                    for s in made { XCTAssertNotNil(session.addShape(s)) }
                } else {
                    var line = session.graphicTool(.line, layer: "Edge.Cuts")
                    var shapes: [BoardShape] = []
                    _ = line.click(at: p(l, t))
                    line.move(to: p(r - 3, t))
                    shapes += line.click(at: p(r - 3, t))
                    line.cancel()
                    // the top right corner rounded: an arc about (r - 3, t + 3) from the line's end, a quarter turn
                    var arc = session.graphicTool(.arc, layer: "Edge.Cuts")
                    _ = arc.click(at: p(r - 3, t + 3))
                    arc.move(to: p(r - 3, t))
                    _ = arc.click(at: p(r - 3, t))
                    arc.move(to: p(r - 0.8, t + 0.9))
                    arc.move(to: p(r, t + 3))
                    let corner = try XCTUnwrap(arc.click(at: p(r, t + 3)).first)
                    shapes.append(corner)
                    // on from the arc's other end (snapped to it) round the board, back to the start
                    let from = corner.start == p(r - 3, t) ? corner.end : corner.start
                    var rest = session.graphicTool(.line, layer: "Edge.Cuts")
                    _ = rest.click(at: from)
                    for q in [p(r, b), p(l, b)] {
                        rest.move(to: q)
                        shapes += rest.click(at: q)
                    }
                    if variant == "lines" {
                        rest.move(to: p(l, t))
                        shapes += rest.click(at: p(l, t), onGraphicEnd: true)
                    }
                    for s in shapes { XCTAssertTrue(try XCTUnwrap(session.addShape(s)).outline) }
                }
                drawn += 1
                let ours = BoardDRC(board: session.router.board, project: project).run().filter { $0.type == "invalid_outline" }
                if !footprintEdges {
                    XCTAssertEqual(ours.isEmpty, variant != "open", "\(file.lastPathComponent) \(variant): \(ours.map(\.description))")
                    whole += variant == "open" ? 0 : 1
                }
                guard let kicad, kicad.major >= KiCadInstallation.minimumMajor else { continue }
                let copy = work.appendingPathComponent("\(variant)-" + file.lastPathComponent)
                try session.router.board.write(to: copy)
                try? FileManager.default.copyItem(at: file.deletingPathExtension().appendingPathExtension("kicad_pro"),
                                                  to: copy.deletingPathExtension().appendingPathExtension("kicad_pro"))
                let report = try KiCadFabrication(installation: kicad).drc(copy, refillZones: false)
                let theirs = report.violations.filter { $0.type == "invalid_outline" }
                if !footprintEdges {
                    XCTAssertEqual(theirs.isEmpty, variant != "open", "\(file.lastPathComponent) \(variant): \(theirs.map(\.description))")
                }
                XCTAssertEqual(theirs.count, ours.count, "\(file.lastPathComponent) \(variant): \(theirs.map(\.description)) \(ours.map(\.description))")
                checked += 1
            }
        }
        print("outlines: \(drawn) drawn (\(whole) whole to the port), \(checked) checked by KiCad's DRC and the port's alike")
        XCTAssertGreaterThan(whole, 0)
        if checked == 0, ProcessInfo.processInfo.environment["JSPICE_REQUIRE_KICAD"] != nil { XCTFail("KiCad 10's kicad-cli is needed") }
    }
}
