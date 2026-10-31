import AppKit
import Combine
import SwiftUI
import KiCadKit
import KiCadRouter

/// Graphics, dimensions and the measure tool in the PCB view, as KiCad's PCB editor has them (KiCadRouter's
/// GraphicTool, DimensionTool, ShapePointEditor and Ruler, ports of its drawing tools, point editor and measure
/// tool): lines (chains of them), arcs, rectangles, circles and polygons drawn on any layer (Edge.Cuts drawing the
/// board's outline), each as one change; dimensions of each kind; a graphic selected shows its edit points, each
/// dragged as KiCad's point editor drags it; the ruler shows a distance, its x and y and its angle, and changes
/// nothing. The pointer goes to a graphic's end, corner or centre near it, else to the 0.05 mm grid (KiCad's magnetic
/// snapping is not ported: this is the view's own).
@MainActor
final class PCBGraphicsEditing: ObservableObject {
    /// What the draw tool draws (KiCad's Draw Lines, Draw Arcs, Draw Rectangles, Draw Circles, Draw Polygons)
    enum Kind: String, CaseIterable, Identifiable {
        case line, arc, rectangle, circle, polygon
        var id: Self { self }
        var title: String {
            switch self {
            case .line: return "Lines"
            case .arc: return "Arcs"
            case .rectangle: return "Rectangles"
            case .circle: return "Circles"
            case .polygon: return "Polygons"
            }
        }
        var symbol: String {
            switch self {
            case .line: return "line.diagonal"
            case .arc: return "circle.bottomhalf.filled"
            case .rectangle: return "rectangle"
            case .circle: return "circle"
            case .polygon: return "hexagon"
            }
        }
        var tool: GraphicTool.Kind {
            switch self {
            case .line: return .line
            case .arc: return .arc
            case .rectangle: return .rectangle
            case .circle: return .circle
            case .polygon: return .polygon
            }
        }
    }

    /// The layers graphics and dimensions go on (any of the board's: its copper among them)
    static let otherLayers = ["F.SilkS", "B.SilkS", "F.Fab", "B.Fab", "F.CrtYd", "B.CrtYd", "Dwgs.User", "Cmts.User",
                              "Eco1.User", "Eco2.User", "User.1", "User.2", "Edge.Cuts", "Margin"]

    weak var editing: PCBEditing?
    /// Its changes passed on to the editing session's (for the view to draw them)
    var forwarding: AnyCancellable?

    @Published var kind = Kind.line {
        didSet { if kind != oldValue { restart() } }
    }
    @Published var dimensionKind = BoardDimension.Kind.aligned {
        didSet { if dimensionKind != oldValue { restart() } }
    }
    /// The layer the next graphic or dimension goes on (KiCad's active layer)
    @Published var layer = "F.SilkS" {
        didSet {
            guard layer != oldValue else { return }
            tool?.setLayer(layer)
            dimensionTool?.setLayer(layer)
        }
    }
    /// The editor's angle snap mode (KiCad's: lines and polygons held to 45° or 90°; Ctrl lets them go free, and off
    /// the grid)
    @Published var angleSnap = LeaderMode.direct {
        didSet {
            tool?.angleSnap = angleSnap
            dimensionTool?.angleSnap = angleSnap
            editor?.editor.angleSnap = angleSnap
        }
    }
    /// The words a leader shows (its properties dialog's, in KiCad)
    @Published var leaderText = "Leader"
    @Published private(set) var tool: GraphicTool?
    @Published private(set) var dimensionTool: DimensionTool?
    @Published private(set) var ruler = Ruler()
    /// The graphic selected alone, its edit points shown
    @Published private(set) var editor: (uuid: String, editor: ShapePointEditor)?
    @Published private(set) var draggedHandle: ShapePointEditor.Handle?
    /// Where the pointer is, snapped (mm)
    @Published private(set) var pointer: KiCadPoint?

    private var widths = LineWidths()
    private var texts = TextDefaults(project: nil)
    private var dimensionDefaults = DimensionDefaults()
    /// The view's scale (points a millimetre), for snapping within a few points
    var scale: Double = 10
    /// The board as the view draws it
    var picture: KiCadBoardPicture? { editing?.controller?.picture }
    private var currentTool = PCBEditing.Tool.select

    init() {}

    static func nm(_ p: KiCadPoint) -> IPoint { IPoint(Int((p.x * 1e6).rounded()), Int((p.y * 1e6).rounded())) }
    static func mm(_ p: IPoint) -> KiCadPoint { KiCadPoint(Double(p.x) / 1e6, Double(p.y) / 1e6) }

    // MARK: - Tools

    /// The editor's tool changed: a new drawing, dimension or measure tool (the project's pens and defaults)
    func toolChanged(_ tool: PCBEditing.Tool) {
        currentTool = tool
        self.tool = nil
        dimensionTool = nil
        ruler = Ruler()
        guard tool == .draw || tool == .dimension else { return }
        Task {
            if let (w, t, d) = await editing?.withSession({ ($0.lineWidths, $0.textDefaults, $0.dimensionDefaults) }) {
                widths = w
                texts = t
                dimensionDefaults = d
            }
            restart()
        }
    }

    /// The tool made anew (its kind, its layer)
    private func restart() {
        tool = nil
        dimensionTool = nil
        switch currentTool {
        case .draw:
            tool = GraphicTool(kind.tool, layer: layer, widths: widths, angleSnap: angleSnap)
        case .dimension:
            var d = DimensionTool(dimensionKind, layer: layer, defaults: dimensionDefaults, widths: widths, texts: texts, angleSnap: angleSnap)
            d.leaderText = leaderText
            dimensionTool = d
        default:
            break
        }
    }

    /// Where the pointer goes: to a graphic's point near it (not with Shift, as KiCad's magnetic snapping), else to the
    /// grid (not with Ctrl, as KiCad 10's, nor for an aligned dimension's height off x and y)
    private func snapped(_ p: KiCadPoint) -> (point: KiCadPoint, onGraphic: Bool) {
        let flags = NSEvent.modifierFlags
        if !flags.contains(.shift), let picture {
            let reach = 6 / max(scale, 0.01)
            var best: (KiCadPoint, Double)?
            for g in picture.graphics where g.line.layer == layer || currentTool == .measure {
                let pts = g.line.closed ? g.line.points : [g.line.points.first, g.line.points.last].compactMap { $0 }
                for q in pts {
                    let d = q.distance(to: p)
                    if d < reach && d < (best?.1 ?? .infinity) { best = (q, d) }
                }
            }
            if let (q, _) = best { return (q, true) }
        }
        let grid = !flags.contains(.control) && (currentTool != .dimension || dimensionTool?.snapsToGrid ?? true)
        return (grid ? PCBEditing.onGrid(p) : p, false)
    }

    /// The pointer at `p` (mm): what is being drawn follows it; whether a tool of these took it
    @discardableResult
    func pointerMoved(_ p: KiCadPoint) -> Bool {
        let ctrl = NSEvent.modifierFlags.contains(.control), shift = NSEvent.modifierFlags.contains(.shift)
        switch currentTool {
        case .draw:
            let (q, _) = snapped(p)
            pointer = q
            tool?.move(to: Self.nm(q), ctrl: ctrl)
        case .dimension:
            let (q, _) = snapped(p)
            pointer = q
            dimensionTool?.move(to: Self.nm(q), ctrl: ctrl)
        case .measure:
            // (Shift holds the ruler to 45°, as KiCad's measure tool does, and lets it off graphics' points)
            let (q, _) = snapped(p)
            pointer = q
            ruler.move(to: Self.nm(q), shift: shift)
        default:
            return false
        }
        return true
    }

    /// A click at `p` with one of these tools (`double`: a double click): what it finishes, each as one change
    func click(at p: KiCadPoint, double: Bool) {
        let ctrl = NSEvent.modifierFlags.contains(.control)
        let (q, onGraphic) = snapped(p)
        let at = Self.nm(q)
        switch currentTool {
        case .draw:
            guard var t = tool else { return }
            t.move(to: at, ctrl: ctrl)
            var made = t.click(at: at, ctrl: ctrl, onGraphicEnd: onGraphic)
            // (a double click: KiCad's first click, then its double click)
            if double { made += t.click(at: at, double: true, ctrl: ctrl) }
            tool = t
            commit(made)
        case .dimension:
            guard var t = dimensionTool else { return }
            t.leaderText = leaderText
            t.move(to: at, ctrl: ctrl)
            let made = t.click(at: at, double: double)
            dimensionTool = t
            if let made {
                Task { _ = await editing?.place { $0.addDimension(made) } }
            }
        case .measure:
            ruler.click(at: at)
        default:
            break
        }
    }

    private func commit(_ shapes: [BoardShape]) {
        guard !shapes.isEmpty else { return }
        Task {
            for s in shapes { _ = await editing?.place { $0.addShape(s) } }
        }
    }

    /// Esc: what is being drawn dropped, or the ruler taken away; whether there was something
    func escape() -> Bool {
        switch currentTool {
        case .draw: return tool?.cancel() ?? false
        case .dimension: return dimensionTool?.cancel() ?? false
        case .measure: return ruler.cancel()
        default: return false
        }
    }

    /// ⌫: the last point taken back (a line's last line undone, to be drawn again); whether there was one
    func back() -> Bool {
        guard currentTool == .draw, var t = tool else { return false }
        let done = t.deleteLastPoint()
        tool = t
        switch done {
        case .nothing: return false
        case .undoLine: editing?.undo()
        case .point, .dropped: break
        }
        return true
    }

    /// W and Shift-W (KiCad's Ctrl++ and Ctrl+-): the pen wider or narrower by 0.1 mm
    func stepWidth(_ up: Bool) {
        tool?.stepWidth(up)
    }

    // MARK: - The point editor

    /// The selection changed: the graphic selected alone, if there is one, shows its edit points
    func selectionChanged(_ selection: Set<String>) {
        guard selection.count == 1, let uuid = selection.first, picture?.graphics.contains(where: { $0.uuid == uuid }) ?? false else {
            editor = nil
            return
        }
        if editor?.uuid == uuid { return }
        Task {
            guard let shape = await editing?.withSession({ $0.shape(uuid) }) else { return }
            editor = (uuid, makeEditor(shape))
        }
    }

    /// The board changed: the graphic being edited as it now is
    func boardTaken() {
        guard let uuid = editor?.uuid, draggedHandle == nil else { return }
        Task {
            if let shape = await editing?.withSession({ $0.shape(uuid) }) {
                editor = (uuid, makeEditor(shape))
            } else {
                editor = nil
            }
        }
    }

    private func makeEditor(_ shape: BoardShape) -> ShapePointEditor {
        var e = ShapePointEditor(shape)
        e.angleSnap = angleSnap
        return e
    }

    /// The edit point a drag from `p` takes: as KiCad's, the first within eight points of it
    func handle(at p: KiCadPoint) -> ShapePointEditor.Handle? {
        editor?.editor.handle(at: Self.nm(p), size: Int((8 / max(scale, 0.01) * 1e6).rounded()))
    }

    /// A drag with the select tool from `start` to `now`: an edit point under `start` dragged; whether one is
    func dragChanged(from start: KiCadPoint, to now: KiCadPoint) -> Bool {
        guard currentTool == .select, var e = editor else { return false }
        if draggedHandle == nil {
            guard let h = handle(at: start) else { return false }
            draggedHandle = h
            e.editor.beginDrag(h)
        }
        guard let h = draggedHandle else { return false }
        let flags = NSEvent.modifierFlags
        e.editor.drag(h, to: Self.nm(now), grid: PointGrid(size: IPoint(50_000, 50_000)), stickyLimit: Int(5 / max(scale, 0.01) * 1e6),
                      free: flags.contains(.shift), ctrl: flags.contains(.control))
        editor = e
        return true
    }

    /// The drag let go: the graphic as its edit point left it, as one change (Move Point); whether one was dragged
    func dragEnded() -> Bool {
        guard draggedHandle != nil, var e = editor else { return false }
        draggedHandle = nil
        e.editor.endDrag()
        editor = e
        let (uuid, shape) = (e.uuid, e.editor.shape)
        Task { _ = await editing?.place { $0.setShape(uuid, to: shape) } }
        return true
    }

    /// A corner added to the polygon selected, on its side nearest `p` (or the line or arc selected split there)
    func addCorner(at p: KiCadPoint) {
        guard let uuid = editor?.uuid else { return }
        Task { _ = await editing?.place { $0.addCorner(uuid, at: p) } }
    }

    /// The polygon selected's corner nearest `p` taken away
    func removeCorner(near p: KiCadPoint) {
        guard let (uuid, e) = editor, e.shape.kind == .polygon,
              let i = e.shape.points.indices.min(by: { Self.mm(e.shape.points[$0]).distance(to: p) < Self.mm(e.shape.points[$1]).distance(to: p) })
        else { return }
        Task { _ = await editing?.place { $0.removeCorner(uuid, index: i) } }
    }

    /// The board's own graphic or dimension under `p` (the last drawn first), for selecting and moving
    func item(at p: KiCadPoint) -> String? {
        guard let picture else { return nil }
        let slop = 4 / max(scale, 0.01)
        for g in picture.graphics.reversed() {
            let pts = g.line.points
            let n = g.line.closed ? pts.count : pts.count - 1
            guard n > 0 else { continue }
            let reach = slop + g.line.width / 2
            for i in 0..<n where Self.distance(p, pts[i], pts[(i + 1) % pts.count]) <= reach { return g.uuid }
            if g.line.filled && KiCadPolygon.contains(pts, p) { return g.uuid }
        }
        for d in picture.dimensions.reversed() {
            guard let made = PCBDimensionCache.shared.dimension(d) else { continue }
            for line in made.lines {
                let pts = line.map(Self.mm)
                for i in 0..<max(0, pts.count - 1) where Self.distance(p, pts[i], pts[i + 1]) <= slop { return d.uuid }
            }
        }
        return nil
    }

    static func distance(_ p: KiCadPoint, _ a: KiCadPoint, _ b: KiCadPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// The board's dimensions as KiCad makes them (BoardDimension), each made once from its s-expression
final class PCBDimensionCache: @unchecked Sendable {
    static let shared = PCBDimensionCache()
    private var cache: [String: BoardDimension] = [:]
    private let lock = NSLock()

    func dimension(_ d: KiCadBoardPicture.Text) -> BoardDimension? {
        lock.lock()
        defer { lock.unlock() }
        if let made = cache[d.source] { return made }
        guard let node = try? SExpr.parse(d.source), let made = BoardDimension(node) else { return nil }
        if cache.count > 2000 { cache = [:] }
        cache[d.source] = made
        return made
    }
}

/// The graphics of the board's own not drawn by the board's painter (on layers other than the silkscreen and the
/// outline), its dimensions with their texts in KiCad's font, and what the graphics tools are doing: the graphic or
/// dimension being drawn, the ruler and its readout, the graphic selected and its edit points
struct PCBGraphicsPainter {
    let picture: KiCadBoardPicture
    let view: PCBTransform
    @ObservedObject var graphics: PCBGraphicsEditing
    let selection: Set<String>
    /// The drawings being dragged with the select tool, and how far
    var dragging: (uuids: Set<String>, delta: KiCadPoint)?

    static func color(_ layer: String) -> Color {
        if layer.hasSuffix(".Cu") { return PCBPainter.color(layer) }
        switch layer {
        case "F.SilkS": return PCBPainter.frontSilk
        case "B.SilkS": return PCBPainter.backSilk
        case "Edge.Cuts": return PCBPainter.edge
        case "F.CrtYd", "B.CrtYd": return Color(red: 1, green: 0.15, blue: 0.9)
        case "F.Fab", "B.Fab": return Color(red: 0.69, green: 0.69, blue: 0.69)
        case "Dwgs.User": return Color(white: 0.8)
        case "Cmts.User": return Color(red: 0.35, green: 0.6, blue: 0.9)
        default: return Color(red: 0.85, green: 0.8, blue: 0.4)
        }
    }

    private func stroke(_ points: [KiCadPoint], closed: Bool, width: Double, color: Color, in context: GraphicsContext,
                        filled: Bool = false) {
        let path = view.path(points, closed: closed)
        if filled { context.fill(path, with: .color(color.opacity(0.55))) }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: max(1, width * view.scale), lineCap: .round, lineJoin: .round))
    }

    private func shapeLines(_ s: BoardShape) -> (points: [KiCadPoint], closed: Bool) {
        func mm(_ p: IPoint) -> KiCadPoint { PCBGraphicsEditing.mm(p) }
        switch s.kind {
        case .segment: return ([mm(s.start), mm(s.end)], false)
        case .rectangle:
            return ([mm(s.start), mm(IPoint(s.end.x, s.start.y)), mm(s.end), mm(IPoint(s.start.x, s.end.y))], true)
        case .circle:
            return (KiCadPolygon.circle(center: mm(s.start), radius: Double(s.radius) / 1e6, segments: 48), true)
        case .arc:
            return (KiCadPolygon.arc(start: mm(s.start), mid: mm(s.arcMidPoint), end: mm(s.end)), false)
        case .polygon: return (s.points.map(mm), true)
        }
    }

    private func drawDimension(_ d: BoardDimension, color: Color, in context: GraphicsContext, offset: KiCadPoint = .zero) {
        for line in d.lines {
            let pts = line.map { KiCadPoint(Double($0.x) / 1e6 + offset.x, Double($0.y) / 1e6 + offset.y) }
            stroke(pts, closed: false, width: Double(d.lineThickness) / 1e6, color: color, in: context)
        }
        guard d.kind != .center else { return }
        let text = KiCadBoardPicture.Text(source: d.textNode(uuid: "").compact, layer: d.layer, uuid: "")
        PCBPainter.drawText(text, in: context, view: view, color: color, offset: offset)
    }

    func draw(_ context: GraphicsContext) {
        let moving = dragging?.uuids ?? []
        let delta = dragging?.delta ?? .zero
        // the board's graphics the painter leaves out, and every graphic selected, highlighted
        for g in picture.graphics {
            let layer = g.line.layer
            let shown = !layer.hasSuffix("SilkS") && layer != "Edge.Cuts"
            let pts = moving.contains(g.uuid) ? g.line.points.map { KiCadPoint($0.x + delta.x, $0.y + delta.y) } : g.line.points
            if shown || moving.contains(g.uuid) {
                stroke(pts, closed: g.line.closed, width: g.line.width, color: Self.color(layer), in: context, filled: g.line.filled)
            }
            if selection.contains(g.uuid) {
                context.stroke(view.path(pts, closed: g.line.closed), with: .color(.accentColor),
                               style: StrokeStyle(lineWidth: max(2, g.line.width * view.scale + 2), lineCap: .round, lineJoin: .round, dash: [5, 3]))
            }
        }
        for d in picture.dimensions {
            guard let made = PCBDimensionCache.shared.dimension(d) else { continue }
            let color = selection.contains(d.uuid) ? Color.accentColor : Self.color(d.layer)
            drawDimension(made, color: color, in: context, offset: moving.contains(d.uuid) ? delta : .zero)
        }
        // what is being drawn
        if let tool = graphics.tool, let s = tool.drawing {
            let (pts, closed) = shapeLines(s)
            stroke(pts, closed: closed, width: Double(s.width) / 1e6, color: .white.opacity(0.85), in: context, filled: s.filled)
        }
        if let tool = graphics.tool, let (c, r) = tool.arcCircle {
            let circle = KiCadPolygon.circle(center: PCBGraphicsEditing.mm(c), radius: Double(r) / 1e6, segments: 64)
            context.stroke(view.path(circle, closed: true), with: .color(.white.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        if let d = graphics.dimensionTool?.dimension {
            drawDimension(d, color: .white.opacity(0.85), in: context)
        }
        // the ruler and its readout
        let ruler = graphics.ruler
        if ruler.visible {
            let a = view.point(PCBGraphicsEditing.mm(ruler.origin)), b = view.point(PCBGraphicsEditing.mm(ruler.end))
            var line = Path()
            line.move(to: a)
            line.addLine(to: b)
            context.stroke(line, with: .color(.white), lineWidth: 1.5)
            for p in [a, b] { context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.white)) }
            let readout = ruler.readout().joined(separator: "\n")
            context.draw(Text(readout).font(.system(size: 11, design: .monospaced)).foregroundColor(.white),
                         at: CGPoint(x: b.x + 12, y: b.y + 12), anchor: .topLeading)
        }
        // the graphic selected's edit points
        if let (_, e) = graphics.editor {
            for h in e.handles {
                let p = view.point(PCBGraphicsEditing.mm(e.position(h)))
                let r: CGFloat = 4
                let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
                let path = { if case .line = h { return Path(ellipseIn: rect) } else { return Path(rect) } }()
                context.fill(path, with: .color(graphics.draggedHandle == h ? .accentColor : .white))
                context.stroke(path, with: .color(.black), lineWidth: 1)
            }
            if graphics.draggedHandle != nil {
                let (pts, closed) = shapeLines(e.shape)
                stroke(pts, closed: closed, width: Double(e.shape.width) / 1e6, color: .accentColor, in: context)
            }
        }
    }
}

/// The edit bar's controls for the draw, dimension and measure tools
struct PCBGraphicsBar: View {
    @ObservedObject var editing: PCBEditing
    @ObservedObject var graphics: PCBGraphicsEditing

    static func layerTitle(_ layer: String) -> String {
        switch layer {
        case "F.CrtYd": return "Top Courtyard"
        case "B.CrtYd": return "Bottom Courtyard"
        case "Edge.Cuts": return "Board Outline"
        case "Eco1.User", "Eco2.User", "Margin": return layer
        default:
            if layer.hasPrefix("User.") { return layer }
            return PCBEditBar.textLayerTitle(layer)
        }
    }

    var body: some View {
        if editing.tool == .draw {
            Picker("Draw", selection: $graphics.kind) {
                ForEach(PCBGraphicsEditing.Kind.allCases) { k in Image(systemName: k.symbol).help("Draw " + k.title).tag(k) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        if editing.tool == .dimension {
            Picker("Dimension", selection: $graphics.dimensionKind) {
                Text("Aligned").tag(BoardDimension.Kind.aligned)
                Text("Orthogonal").tag(BoardDimension.Kind.orthogonal)
                Text("Center").tag(BoardDimension.Kind.center)
                Text("Radial").tag(BoardDimension.Kind.radial)
                Text("Leader").tag(BoardDimension.Kind.leader)
            }
            .labelsHidden()
            .fixedSize()
            .help("The kind of dimension, as KiCad's Draw Dimensions has them")
            if graphics.dimensionKind == .leader {
                TextField("Leader", text: $graphics.leaderText).frame(width: 120).help("The words the leader points with")
            }
        }
        if editing.tool == .draw || editing.tool == .dimension {
            Picker("Layer", selection: $graphics.layer) {
                ForEach(PCBGraphicsEditing.otherLayers.prefix(2) + editing.layers + PCBGraphicsEditing.otherLayers.dropFirst(2), id: \.self) { layer in
                    Text(Self.layerTitle(layer)).tag(layer)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("The layer it goes on (Board Outline: the board's edge, drawn as KiCad's Edge.Cuts)")
            Picker("Angles", selection: $graphics.angleSnap) {
                Text("Any Angle").tag(LeaderMode.direct)
                Text("45°").tag(LeaderMode.deg45)
                Text("90°").tag(LeaderMode.deg90)
            }
            .labelsHidden()
            .fixedSize()
            .help("Lines, polygons and dimensions held to 45° or 90° (KiCad's angle snap mode); ⌃ lets them go free, and holds a rectangle square")
        }
        if editing.tool == .draw, let width = graphics.tool?.width {
            Text(String(format: "%.2f mm", Double(width) / 1e6)).monospacedDigit().foregroundStyle(.secondary)
                .help("The pen, the layer's (the board's design settings); W and ⇧W make it 0.1 mm wider or narrower")
        }
        if editing.tool == .measure {
            Text(graphics.ruler.visible ? graphics.ruler.readout().joined(separator: "  ") : "Click two points to measure")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        if editing.tool == .select, let (_, e) = graphics.editor, e.shape.kind == .polygon || e.shape.kind == .segment || e.shape.kind == .arc {
            Button(e.shape.kind == .polygon ? "Add Corner" : "Split") {
                if let p = editing.pointer { graphics.addCorner(at: p) }
            }
            .help("A corner added on the side nearest the pointer (a line or arc split there), as KiCad's point editor adds one")
            if e.shape.kind == .polygon {
                Button("Remove Corner") {
                    if let p = editing.pointer { graphics.removeCorner(near: p) }
                }
                .help("The corner nearest the pointer taken away (the polygon, where it has three)")
            }
        }
    }
}
