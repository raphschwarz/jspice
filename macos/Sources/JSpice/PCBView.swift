import SwiftUI
import AppKit
import CircuitKit
import KiCadKit
import KiCadRouter

/// The circuit's printed circuit board as KiCad has it: copper, pads, holes, silkscreen and the connections still to
/// route, kept up to date as the board changes in KiCad's PCB editor and as the schematic changes here. Clicking a
/// part selects it in the schematic and in KiCad. Tracks are routed here with the Route tool (KiCad's router, brought
/// over: it walks round what is in the way and keeps the board's clearances), or in KiCad's editor (Edit in KiCad),
/// where the board is also laid out.
struct PCBView: View {
    @ObservedObject var editor: EditorState
    @ObservedObject var board: BoardController
    let circuit: Circuit
    /// Points per millimetre, or nil to fit the board in the window
    @State private var scale: CGFloat?
    @AppStorage("pcbSide") private var sideName = PCBSide.front.rawValue
    private var side: PCBSide { PCBSide(rawValue: sideName) ?? .front }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                bar
                Divider()
                content
            }
            Divider()
            PCBSidePanel(editor: editor, board: board).frame(width: 300)
        }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            if board.availability == .board {
                PCBEditBar(editing: board.editing)
                Divider().frame(height: 18)
                Picker("Side", selection: $sideName) {
                    ForEach(PCBSide.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Look at the board from the top, or from underneath (mirrored)")
                Button { zoom(by: 0.8) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out")
                Button { zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in")
                Button { scale = nil } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                    .help("Fit the board in the window")
            }
            if let busy = board.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if board.availability == .board {
                Button("Edit in KiCad", systemImage: "square.and.pencil") { board.openInKiCad() }
                    .help("Lay out and route the board in KiCad's PCB editor: what you change there comes back here, and what you change in the schematic goes there")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    @ViewBuilder private var content: some View {
        switch board.availability {
        case .noKiCad(let problem):
            PCBEmptyState(symbol: "exclamationmark.triangle", title: "JSpice lays out boards with KiCad", text: problem) {
                HStack {
                    Link("Download KiCad", destination: URL(string: "https://www.kicad.org/download/")!)
                    Button("Look Again") { board.lookAgain() }
                        .help("Look for KiCad again, once it is installed")
                }
            }
        case .unsaved:
            PCBEmptyState(symbol: "doc.badge.plus", title: "Save the circuit first",
                          text: "Its board is kept beside it, a KiCad project with the circuit's name.") {
                Button("Save…") { NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil) }
            }
        case .noBoard:
            NewBoardPanel(editor: editor, board: board, design: circuit.pcb ?? PCBDesign())
        case .board:
            if let picture = board.picture {
                canvas(picture)
            } else {
                ProgressView("Reading the board…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func zoom(by factor: CGFloat) {
        let current = scale ?? fitted ?? 8
        scale = min(80, max(1, current * factor))
    }

    @State private var fitted: CGFloat?

    private func canvas(_ picture: KiCadBoardPicture) -> some View {
        GeometryReader { geometry in
            let fit = max(1, min((geometry.size.width - 40) / picture.bounds.width, (geometry.size.height - 40) / picture.bounds.height))
            let s = scale ?? fit
            let view = PCBTransform(bounds: picture.bounds, scale: s, mirrored: side == .back)
            ScrollView([.horizontal, .vertical]) {
                PCBBoardCanvas(board: board, editing: board.editing, picture: picture, view: view, side: side,
                               selected: selectedFootprints(picture)) { readout(picture, view, at: $0) }
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
            .onAppear { fitted = fit }
            .onChange(of: fit) { _, value in fitted = value }
        }
        .background(PCBPainter.background)
        .overlay(alignment: .bottomLeading) { PCBEditMessage(editing: board.editing) }
    }

    private func selectedFootprints(_ picture: KiCadBoardPicture) -> Set<String> {
        guard !editor.selection.isEmpty else { return [] }
        return Set(board.partsOfFootprint.filter { !editor.selection.isDisjoint(with: $0.value) }.keys)
    }

    private func readout(_ picture: KiCadBoardPicture, _ view: PCBTransform, at pointer: CGPoint) -> String? {
        let p = view.board(pointer)
        let position = String(format: "%.2f, %.2f mm", p.x, p.y)
        if let pair = board.editing.pairPreview {
            return "Routing \(pair.positiveNet) and \(pair.negativeNet)  ·  \(String(format: "%.2f mm, gap %.2f mm", pair.width, pair.gap))  ·  \(PCBEditBar.title(pair.layer))  ·  \(position)"
        }
        if let preview = board.editing.preview {
            return "Routing \(preview.net ?? "no net")  ·  \(String(format: "%.2f mm", preview.width))  ·  \(PCBEditBar.title(preview.layer))  ·  \(position)"
        }
        if let wire = board.editing.hoveredAirwire, board.editing.tool == .select {
            return "Click to route \(wire.net)\(wire.ends.isEmpty ? "" : ": " + wire.ends.joined(separator: " to "))"
        }
        if let pad = picture.pad(at: p), let footprint = picture.footprints.first(where: { $0.uuid == pad.footprint }) {
            return "\(footprint.reference) pad \(pad.number)  ·  \(pad.net ?? "no net")  ·  \(position)"
        }
        if let footprint = picture.footprint(at: p) {
            return "\(footprint.reference)  ·  \(footprint.value)  ·  \(footprint.libID)\(footprint.isOnBack ? "  ·  underneath" : "")"
        }
        return position
    }
}

enum PCBSide: String, CaseIterable, Identifiable {
    case front, back
    var id: Self { self }
    var title: String { self == .front ? "Top" : "Bottom" }
}

/// Where a point of the board is drawn
struct PCBTransform {
    var bounds: KiCadBox
    var scale: CGFloat
    /// Seen from underneath
    var mirrored: Bool

    var size: CGSize { CGSize(width: bounds.width * scale, height: bounds.height * scale) }

    func point(_ p: KiCadPoint) -> CGPoint {
        CGPoint(x: (mirrored ? bounds.maxX - p.x : p.x - bounds.minX) * scale, y: (p.y - bounds.minY) * scale)
    }

    func board(_ p: CGPoint) -> KiCadPoint {
        KiCadPoint(mirrored ? bounds.maxX - p.x / scale : bounds.minX + p.x / scale, bounds.minY + p.y / scale)
    }

    func path(_ points: [KiCadPoint], closed: Bool) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: point(first))
        for p in points.dropFirst() { path.addLine(to: point(p)) }
        if closed { path.closeSubpath() }
        return path
    }
}

/// The board drawn as KiCad's PCB editor draws it, in its colours
struct PCBPainter {
    let picture: KiCadBoardPicture
    let view: PCBTransform
    let side: PCBSide
    let selected: Set<String>
    let drc: KiCadFabrication.DRCReport?
    /// Tracks and vias not drawn, by id (those the track being routed has shoved aside, drawn where they now go)
    var hidden: Set<String> = []

    static let background = Color(red: 0, green: 0.063, blue: 0.137)
    static let substrate = Color(red: 0.05, green: 0.16, blue: 0.13)
    static let front = Color(red: 0.784, green: 0.204, blue: 0.204)
    static let back = Color(red: 0.302, green: 0.498, blue: 0.769)
    static let inner: [Color] = [Color(red: 0.5, green: 0.78, blue: 0.5), Color(red: 0.81, green: 0.49, blue: 0.17),
                                 Color(red: 0.31, green: 0.8, blue: 0.8), Color(red: 0.86, green: 0.38, blue: 0.55)]
    static let plated = Color(red: 0.89, green: 0.72, blue: 0.18)
    static let via = Color(white: 0.85)
    static let hole = Color(white: 0.1)
    static let frontSilk = Color(red: 0.95, green: 0.93, blue: 0.63)
    static let backSilk = Color(red: 0.91, green: 0.7, blue: 0.65)
    static let edge = Color(red: 0.82, green: 0.82, blue: 0.8)

    func color(_ layer: String) -> Color { Self.color(layer) }

    static func color(_ layer: String) -> Color {
        switch layer {
        case "F.Cu": return front
        case "B.Cu": return back
        default:
            let n = Int(layer.dropFirst(2).prefix { $0.isNumber }) ?? 1
            return inner[(n - 1) % inner.count]
        }
    }

    func draw(_ context: GraphicsContext) {
        let s = view.scale
        // the board itself
        let closed = picture.outline.filter(\.closed)
        if !closed.isEmpty {
            var shape = Path()
            for line in closed { shape.addPath(view.path(line.points, closed: true)) }
            context.fill(shape, with: .color(Self.substrate), style: FillStyle(eoFill: true))
        } else if let box = KiCadBox(picture.outline.flatMap(\.points)) {
            context.fill(view.path([KiCadPoint(box.minX, box.minY), KiCadPoint(box.maxX, box.minY), KiCadPoint(box.maxX, box.maxY),
                                    KiCadPoint(box.minX, box.maxY)], closed: true), with: .color(Self.substrate))
        }

        // copper, the far side first, dimmed
        let near = side == .front ? "F.Cu" : "B.Cu"
        var layers = picture.copperLayers
        if side == .front { layers.reverse() }
        for layer in layers {
            let dim = layer != near
            let tint = color(layer).opacity(dim ? 0.45 : 0.9)
            for zone in picture.zones where zone.layer == layer && !zone.isRuleArea {
                if zone.fills.isEmpty {
                    context.stroke(view.path(zone.outline, closed: true), with: .color(tint), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else {
                    var fill = Path()
                    for polygon in zone.fills { fill.addPath(view.path(polygon, closed: true)) }
                    context.fill(fill, with: .color(color(layer).opacity(dim ? 0.25 : 0.5)))
                }
            }
            for track in picture.tracks where track.layer == layer && !hidden.contains(track.uuid) {
                context.stroke(view.path(track.points, closed: false), with: .color(tint),
                               style: StrokeStyle(lineWidth: max(0.5, track.width * s), lineCap: .round, lineJoin: .round))
            }
            let padSide = layer == "F.Cu" ? "F" : layer == "B.Cu" ? "B" : nil
            if let padSide {
                var pads = Path()
                for pad in picture.pads where pad.sides == padSide { pads.addPath(view.path(pad.outline, closed: true)) }
                context.fill(pads, with: .color(tint))
            }
        }
        // plated through the board
        var plated = Path()
        for pad in picture.pads where pad.sides == "FB" { plated.addPath(view.path(pad.outline, closed: true)) }
        context.fill(plated, with: .color(Self.plated))
        for via in picture.vias where !hidden.contains(via.uuid) {
            let c = view.point(via.center), r = via.size * s / 2
            context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(Self.via))
        }
        // holes
        var holes = Path()
        for pad in picture.pads {
            guard let drill = pad.drill else { continue }
            let c = view.point(pad.center)
            let (w, h) = (drill.width * s, drill.height * s)
            if abs(w - h) < 0.01 {
                holes.addEllipse(in: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h))
            } else {
                // an oval hole, turned with its pad
                let slot = Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: min(w, h) / 2)
                let angle = view.mirrored ? pad.angle : -pad.angle
                holes.addPath(slot.applying(CGAffineTransform(rotationAngle: angle * .pi / 180).concatenating(CGAffineTransform(translationX: c.x, y: c.y))))
            }
        }
        for via in picture.vias where !hidden.contains(via.uuid) {
            let c = view.point(via.center), r = via.drill * s / 2
            holes.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        context.fill(holes, with: .color(Self.hole))

        // silkscreen, this side's
        let silkLayer = side == .front ? "F.SilkS" : "B.SilkS"
        let silk = side == .front ? Self.frontSilk : Self.backSilk
        for line in picture.silkscreen where line.layer == silkLayer {
            let path = view.path(line.points, closed: line.closed)
            if line.filled { context.fill(path, with: .color(silk.opacity(0.85))) }
            context.stroke(path, with: .color(silk.opacity(0.85)), style: StrokeStyle(lineWidth: max(0.5, line.width * s), lineCap: .round, lineJoin: .round))
        }
        // the edge
        for line in picture.outline {
            context.stroke(view.path(line.points, closed: line.closed), with: .color(Self.edge),
                           style: StrokeStyle(lineWidth: max(1, line.width * s), lineCap: .round, lineJoin: .round))
        }

        // references, on this side's parts (the other side's dimmed), kept upright
        for footprint in picture.footprints {
            guard let label = footprint.label else { continue }
            let mine = footprint.isOnBack == (side == .back)
            let height = max(7, label.height * s)
            var angle = label.angle.truncatingRemainder(dividingBy: 360)
            if angle < 0 { angle += 360 }
            if angle > 90 && angle <= 270 { angle -= 180 }
            var text = context
            let at = view.point(label.visible ? label.at : footprint.box.center)
            text.translateBy(x: at.x, y: at.y)
            text.rotate(by: .degrees(view.mirrored ? angle : -angle))
            text.draw(Text(footprint.reference).font(.system(size: height, weight: .medium)).foregroundStyle((mine ? silk : Color.white).opacity(mine ? 1 : 0.4)),
                      at: .zero)
        }

        // the parts selected, here and in the schematic
        for footprint in picture.footprints where selected.contains(footprint.uuid) {
            let box = footprint.box
            let a = view.point(KiCadPoint(box.minX, box.minY)), b = view.point(KiCadPoint(box.maxX, box.maxY))
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).insetBy(dx: -2, dy: -2)
            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color.accentColor.opacity(0.18)))
            context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color.accentColor), lineWidth: 1.5)
        }

        // the connections still to route
        var airwires = Path()
        for wire in picture.airwires {
            airwires.move(to: view.point(wire.from))
            airwires.addLine(to: view.point(wire.to))
        }
        context.stroke(airwires, with: .color(Color.white.opacity(0.7)), lineWidth: 0.8)

        // what the design rules check found
        if let drc {
            for violation in drc.violations + drc.unconnected {
                guard let position = violation.items.compactMap(\.position).first else { continue }
                let c = view.point(position)
                let mark = Path { p in
                    p.move(to: CGPoint(x: c.x, y: c.y - 7))
                    p.addLine(to: CGPoint(x: c.x + 6, y: c.y + 5))
                    p.addLine(to: CGPoint(x: c.x - 6, y: c.y + 5))
                    p.closeSubpath()
                }
                let tint: Color = violation.severity == "error" ? .red : .orange
                context.fill(mark, with: .color(tint.opacity(0.85)))
                context.stroke(mark, with: .color(.white), lineWidth: 0.8)
            }
        }
    }
}

/// The board drawn, and what is being done to it here: the track being routed, the tracks and vias selected. The
/// pointer and the keys drive the tool chosen (KiCad's keys: V via, / posture, ⌫ back a step, Esc stop, End finish,
/// W width, Page Up and Down the layer).
struct PCBBoardCanvas: View {
    @ObservedObject var board: BoardController
    @ObservedObject var editing: PCBEditing
    let picture: KiCadBoardPicture
    let view: PCBTransform
    let side: PCBSide
    let selected: Set<String>
    let readout: (CGPoint) -> String?
    @FocusState private var focused: Bool

    /// The footprints selected: those of the parts selected in the schematic, and those selected here
    private var footprints: Set<String> { selected.union(editing.footprintSelection) }

    var body: some View {
        Canvas { context, _ in
            PCBPainter(picture: picture, view: view, side: side, selected: footprints, drc: board.drc ?? editing.quickDRC,
                       hidden: (editing.preview?.moved ?? []).union(editing.dragPreview?.moved ?? []).union(editing.pairPreview?.moved ?? []))
                .draw(context)
            PCBEditPainter(picture: picture, view: view, preview: editing.preview, drag: editing.dragPreview, pair: editing.pairPreview,
                           selection: editing.selection,
                           dragging: editing.dragging, airwire: editing.tool == .select ? editing.hoveredAirwire : nil).draw(context)
        }
        .frame(width: view.size.width, height: view.size.height)
        .overlay {
            BoardHoverReadout(text: readout) { pointer in
                guard let pointer else {
                    if editing.hoveredAirwire != nil { editing.hoveredAirwire = nil }
                    return
                }
                let p = view.board(pointer)
                editing.pointerMoved(p)
                // (a line of the ratsnest under the pointer, where a click routes it: not over a track, which it selects)
                let wire = editing.tool == .select && picture.copper(at: p, layers: picture.copperLayers, slop: 3 / view.scale) == nil
                    ? picture.airwire(at: p, slop: 3 / view.scale) : nil
                if wire != editing.hoveredAirwire { editing.hoveredAirwire = wire }
            }
        }
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { drag in
                editing.dragChanged(from: view.board(drag.startLocation), to: view.board(drag.location), in: picture,
                                    selected: footprints)
            }
            .onEnded { drag in editing.dragEnded(at: view.board(drag.location)) })
        .onTapGesture(coordinateSpace: .local) { location in
            focused = true
            let p = view.board(location)
            let flags = NSEvent.modifierFlags
            let extending = flags.contains(.command) || flags.contains(.shift)
            // (a track or via being dragged with the pointer: kept there)
            if editing.isDragging {
                Task { await editing.fixDrag(at: p) }
                return
            }
            switch editing.tool {
            case .route, .pair:
                editing.click(at: p, double: (NSApp.currentEvent?.clickCount ?? 1) >= 2)
            case .select:
                // a track or via, else a connection still to route (routed), else a part
                if editing.select(at: p, in: picture, slop: 3 / view.scale, extending: extending) {
                    if !extending {
                        board.select(footprint: nil, extending: false)
                        editing.footprintSelection = []
                    }
                } else if !extending, let wire = picture.airwire(at: p, slop: 3 / view.scale) {
                    editing.routeConnection(wire)
                } else {
                    let footprint = picture.footprint(at: p)
                    board.select(footprint: footprint?.uuid, extending: extending)
                    if let uuid = footprint?.uuid {
                        if extending { editing.footprintSelection.formSymmetricDifference([uuid]) } else { editing.footprintSelection = [uuid] }
                    } else if !extending {
                        editing.footprintSelection = []
                    }
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in key(press) ? .handled : .ignored }
        .onDeleteCommand { editing.isRouting ? editing.undoSegment() : editing.deleteSelection() }
        .onChange(of: editing.tool) { _, _ in focused = true }
        .onAppear { if editing.tool.routes { focused = true } }
    }

    private func key(_ press: KeyPress) -> Bool {
        // the menus' keys (⌘ and ⌥) left to them
        guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return false }
        switch press.key {
        case .escape:
            if editing.isDragging {
                editing.cancelDrag()
            } else if editing.isRouting {
                editing.stop()
            } else if editing.tool.routes {
                editing.tool = .select
            } else {
                editing.selection = []
                editing.footprintSelection = []
                board.select(footprint: nil, extending: false)
            }
            return true
        case .delete, .deleteForward:
            if editing.isRouting { editing.undoSegment() } else { editing.deleteSelection() }
            return true
        case .return, .end:
            guard editing.isRouting else { return false }
            editing.finishToRatsnest()
            return true
        case .pageUp:
            editing.stepLayer(-1)
            return true
        case .pageDown:
            editing.stepLayer(1)
            return true
        default:
            break
        }
        switch press.characters.lowercased() {
        case "x": editing.tool = .route
        case "6": editing.tool = .pair
        case "d" where !editing.isRouting: editing.dragAtPointer(freeAngle: false)
        case "g" where !editing.isRouting: editing.dragAtPointer(freeAngle: true)
        case "v": editing.placeVia()
        case "/": editing.flipPosture()
        case "w": editing.stepWidth(press.modifiers.contains(.shift) ? -1 : 1)
        case "b": editing.fillZones()
        case "i", "u": editing.selectNets(in: picture)
        case "r" where editing.tool == .select: editing.rotate(footprints)
        case "f" where editing.tool == .select: editing.flip(footprints)
        case "+", "=": editing.stepLayer(1)
        case "-": editing.stepLayer(-1)
        default: return false
        }
        return true
    }
}

/// The track being routed (its fixed part, the part following the pointer, the via to be placed at its end, the line
/// on to where it should go next, its net's pads), and the tracks and vias selected
struct PCBEditPainter {
    let picture: KiCadBoardPicture
    let view: PCBTransform
    let preview: BoardEditing.Preview?
    /// A track or via being dragged, as it now goes
    var drag: BoardEditing.DragPreview?
    /// A differential pair being routed, as it now goes
    var pair: BoardEditing.PairPreview?
    let selection: Set<String>
    var dragging: (uuids: [String], delta: KiCadPoint)?
    /// The connection still to route under the pointer, which a click routes
    var airwire: KiCadConnectivity.Airwire?

    func draw(_ context: GraphicsContext) {
        let s = view.scale
        if let airwire {
            var line = Path()
            line.move(to: view.point(airwire.from))
            line.addLine(to: view.point(airwire.to))
            context.stroke(line, with: .color(.yellow), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            for end in [airwire.from, airwire.to] {
                let c = view.point(end)
                context.stroke(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(.yellow), lineWidth: 1.5)
            }
        }
        // footprints being dragged: their pads and outline where they would go
        if let (uuids, d) = dragging {
            let moving = Set(uuids)
            func moved(_ points: [KiCadPoint]) -> [KiCadPoint] { points.map { KiCadPoint($0.x + d.x, $0.y + d.y) } }
            var pads = Path()
            for pad in picture.pads where moving.contains(pad.footprint) { pads.addPath(view.path(moved(pad.outline), closed: true)) }
            context.fill(pads, with: .color(Color.white.opacity(0.35)))
            context.stroke(pads, with: .color(.white), lineWidth: 1)
            for footprint in picture.footprints where moving.contains(footprint.uuid) {
                let b = footprint.box
                let corners = moved([KiCadPoint(b.minX, b.minY), KiCadPoint(b.maxX, b.minY), KiCadPoint(b.maxX, b.maxY), KiCadPoint(b.minX, b.maxY)])
                context.stroke(view.path(corners, closed: true), with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        if !selection.isEmpty {
            for track in picture.tracks where selection.contains(track.uuid) {
                let path = view.path(track.points, closed: false)
                let w = max(0.5, track.width * s)
                context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: w + 3, lineCap: .round, lineJoin: .round))
                context.stroke(path, with: .color(PCBPainter.color(track.layer)), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
            }
            for via in picture.vias where selection.contains(via.uuid) {
                let c = view.point(via.center), r = via.size * s / 2 + 1.5
                context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.white), lineWidth: 2)
            }
        }
        if let drag {
            // what is dragged, and what it has shoved aside, where it now goes; outlined in red where it is in the way
            for track in drag.tracks {
                let path = view.path(track.points, closed: false)
                let w = max(0.5, track.width * s)
                if drag.violates {
                    context.stroke(path, with: .color(Color.red.opacity(0.8)), style: StrokeStyle(lineWidth: w + 3, lineCap: .round, lineJoin: .round))
                }
                context.stroke(path, with: .color(PCBPainter.color(track.layer)), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
            }
            for via in drag.vias {
                let c = view.point(via.center), r = via.size * s / 2
                let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                context.fill(ring, with: .color(PCBPainter.via))
                context.stroke(ring, with: .color(drag.violates ? Color.red : Color.white), lineWidth: 1)
            }
        }
        if let pair {
            // the pair's nets' pads, to see where it goes; what it has shoved aside; its two lines and their vias
            var pads = Path()
            for pad in picture.pads where pad.net == pair.positiveNet || pad.net == pair.negativeNet {
                pads.addPath(view.path(pad.outline, closed: true))
            }
            context.stroke(pads, with: .color(Color.white.opacity(0.9)), lineWidth: 1.2)
            for track in pair.shovedTracks {
                context.stroke(view.path(track.points, closed: false), with: .color(PCBPainter.color(track.layer).opacity(0.9)),
                               style: StrokeStyle(lineWidth: max(0.5, track.width * s), lineCap: .round, lineJoin: .round))
            }
            for via in pair.shovedVias {
                let c = view.point(via.center), r = via.size * s / 2
                context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(PCBPainter.via))
            }
            let w = max(0.5, pair.width * s)
            for line in [pair.positive, pair.negative] where line.count > 1 {
                let path = view.path(line, closed: false)
                context.stroke(path, with: .color(pair.clear ? Color.white.opacity(0.35) : Color.red.opacity(0.7)),
                               style: StrokeStyle(lineWidth: w + 2, lineCap: .round, lineJoin: .round))
                context.stroke(path, with: .color(PCBPainter.color(pair.layer)), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
            }
            for via in [pair.positiveVia, pair.negativeVia].compactMap({ $0 }) {
                let c = view.point(via), r = pair.viaSize * s / 2
                let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                context.fill(ring, with: .color(PCBPainter.via))
                context.stroke(ring, with: .color(Color.white), lineWidth: 1)
            }
        }
        guard let preview else { return }
        // what the track has shoved aside, where it now goes
        for track in preview.shovedTracks {
            context.stroke(view.path(track.points, closed: false), with: .color(PCBPainter.color(track.layer).opacity(0.9)),
                           style: StrokeStyle(lineWidth: max(0.5, track.width * s), lineCap: .round, lineJoin: .round))
        }
        for via in preview.shovedVias {
            let c = view.point(via.center), r = via.size * s / 2
            context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(PCBPainter.via))
        }
        let color = PCBPainter.color(preview.layer)
        // the net's pads, to see where it goes
        if let net = preview.net {
            var pads = Path()
            for pad in picture.pads where pad.net == net { pads.addPath(view.path(pad.outline, closed: true)) }
            context.stroke(pads, with: .color(Color.white.opacity(0.9)), lineWidth: 1.2)
        }
        let w = max(0.5, preview.width * s)
        let style = StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round)
        if preview.tail.count > 1 { context.stroke(view.path(preview.tail, closed: false), with: .color(color), style: style) }
        if preview.head.count > 1 {
            let head = view.path(preview.head, closed: false)
            context.stroke(head, with: .color(Color.white.opacity(0.35)), style: StrokeStyle(lineWidth: w + 2, lineCap: .round, lineJoin: .round))
            context.stroke(head, with: .color(color), style: style)
        }
        if let via = preview.via {
            let c = view.point(via), r = preview.viaSize * s / 2
            let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            context.fill(ring, with: .color(PCBPainter.via))
            context.stroke(ring, with: .color(.white), lineWidth: 1)
        }
        if let target = preview.target, let end = preview.head.last ?? preview.tail.last {
            var line = Path()
            line.move(to: view.point(end))
            line.addLine(to: view.point(target))
            context.stroke(line, with: .color(Color.yellow.opacity(0.9)), style: StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
        }
    }
}

/// The tools of the PCB view, and the routing tool's layer and width; undo and redo of what was done here
struct PCBEditBar: View {
    @ObservedObject var editing: PCBEditing

    static func help(_ tool: PCBEditing.Tool) -> String {
        switch tool {
        case .select:
            return "Select and move parts (drag; R rotates, F flips), select tracks and vias (⌫ deletes them); drag a track or via (or D, G at any angle) and the router moves it, as KiCad's drag"
        case .route:
            return "Route tracks (X): click a pad, click to fix, double-click to finish; V via, / posture, Esc stop"
        case .pair:
            return "Route differential pairs (6): click a pad of a pair's net (USB_P and USB_N, D+ and D-), both tracks follow at the net class's pair width and gap; V vias, / posture, Esc stop"
        }
    }

    static func title(_ layer: String) -> String {
        switch layer {
        case "F.Cu": return "Top"
        case "B.Cu": return "Bottom"
        default: return "Inner " + String(layer.dropFirst(2).prefix { $0.isNumber })
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Picker("Tool", selection: $editing.tool) {
                ForEach(PCBEditing.Tool.allCases) { tool in
                    Image(systemName: tool.symbol).help(Self.help(tool)).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if editing.tool.routes {
                Picker("Layer", selection: $editing.layer) {
                    ForEach(editing.layers, id: \.self) { layer in
                        Label { Text(Self.title(layer)) } icon: { Image(systemName: "square.fill").foregroundStyle(PCBPainter.color(layer)) }
                            .tag(layer)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("The copper layer to route on (Page Up, Page Down); changed while routing, a via takes the track there")
                Menu {
                    Button("Net Class's Width") { editing.width = nil }
                    Divider()
                    ForEach(PCBEditing.widths, id: \.self) { w in
                        Button(String(format: "%.2f mm", w)) { editing.width = w }
                    }
                } label: {
                    Text(editing.width.map { String(format: "%.2f mm", $0) } ?? "Net class width")
                }
                .fixedSize()
                .help("The width of new tracks (W, ⇧W): their net class's, or one chosen here")
                Picker("Obstacles", selection: $editing.shove) {
                    Text("Walk Around").tag(false)
                    Text("Shove").tag(true)
                }
                .labelsHidden()
                .fixedSize()
                .help("What a new track does with other nets' tracks and vias in its way: walks round them, or shoves them aside (KiCad's router modes)")
                Picker("Corners", selection: $editing.corners) {
                    Text("45°").tag(Direction45.CornerMode.mitered45)
                    Text("45° Rounded").tag(Direction45.CornerMode.rounded45)
                    Text("90°").tag(Direction45.CornerMode.mitered90)
                    Text("90° Rounded").tag(Direction45.CornerMode.rounded90)
                }
                .labelsHidden()
                .fixedSize()
                .help("The corners new tracks take: at 45° or 90°, mitred, or rounded into arcs (KiCad's track corner mode)")
            }
            Menu {
                Button("Route All Connections") { editing.routeAll() }
                Button("Route All but Ground (for a Pour)") { editing.routeAll(groundToo: false) }
            } label: {
                Image(systemName: "wand.and.rays")
            } primaryAction: {
                editing.routeAll()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(editing.isRouting)
            .help("Route every connection still to route with the router, one at a time as you would, in one change (undo takes it back)")
            Menu {
                if editing.layers.count > 2 {
                    Button("Ground Pour on Every Layer") { editing.addPour(layers: editing.layers) }
                }
                Button("Ground Pour on the Bottom") { editing.addPour(layers: [editing.layers.last ?? "B.Cu"]) }
                Button("Ground Pour on the Top") { editing.addPour(layers: [editing.layers.first ?? "F.Cu"]) }
                Button("Ground Pour on Both Sides") {
                    editing.addPour(layers: [editing.layers.first ?? "F.Cu", editing.layers.last ?? "B.Cu"])
                }
                Button("Stitch Ground Pours") { editing.stitchPours() }
                Divider()
                Button("Fill Zones") { editing.fillZones() }
                Button("Remove Pours") { editing.removePours() }
                Divider()
                Button("Fit Outline to Parts") { editing.fitOutline() }
                Menu("Mounting Holes") {
                    ForEach(BoardEditing.mountingHoles, id: \.screw) { hole in
                        Button(hole.screw) { editing.addMountingHoles(screw: hole.screw) }
                    }
                }
            } label: {
                Image(systemName: "square.on.square.dashed")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(editing.isRouting)
            .help("Pour ground copper over the board, filled as KiCad fills it round everything else (B fills the zones again after a change)")
            Button { editing.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(editing.undoName == nil || editing.isRouting)
                .help(editing.undoName.map { "Undo \($0)" } ?? "Undo")
            Button { editing.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(editing.redoName == nil || editing.isRouting)
                .help(editing.redoName.map { "Redo \($0)" } ?? "Redo")
        }
    }
}

/// How to go on with the tool, or what it could not do
struct PCBEditMessage: View {
    @ObservedObject var editing: PCBEditing

    var body: some View {
        if let message = editing.message {
            Text(message)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .padding(10)
                .allowsHitTesting(false)
        }
    }
}

/// A net class's widths and gaps (mm), and the nets it takes, edited where they are shown: the router takes them as
/// they are entered, and the board's KiCad project keeps them
struct PCBNetClassRow: View {
    @ObservedObject var board: BoardController
    let netClass: KiCadProject.NetClass
    @State private var edited: KiCadProject.NetClass
    @State private var nets: String

    init(board: BoardController, netClass: KiCadProject.NetClass) {
        self.board = board
        self.netClass = netClass
        _edited = State(initialValue: netClass)
        _nets = State(initialValue: netClass.patterns.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(netClass.name).font(.callout.weight(.medium))
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 3) {
                GridRow {
                    Text("Track").foregroundStyle(.secondary)
                    field(\.trackWidth, "The width of its tracks")
                    Text("Gap").foregroundStyle(.secondary)
                    field(\.clearance, "How far its copper keeps from other nets'")
                }
                GridRow {
                    Text("Via").foregroundStyle(.secondary)
                    field(\.viaDiameter, "Its vias' diameter")
                    Text("Drill").foregroundStyle(.secondary)
                    field(\.viaDrill, "Its vias' hole")
                }
            }
            .font(.caption)
            if netClass.name != "Default" {
                TextField("Nets", text: $nets, prompt: Text("Nets: GND, +*V"))
                    .font(.caption)
                    .onSubmit { commit() }
                    .help("The nets it takes: names, or patterns such as +*V, separated by commas")
            }
        }
        .onChange(of: netClass) { _, value in
            edited = value
            nets = value.patterns.joined(separator: ", ")
        }
    }

    private func field(_ key: WritableKeyPath<KiCadProject.NetClass, Double>, _ help: String) -> some View {
        TextField("", value: Binding(get: { edited[keyPath: key] }, set: { edited[keyPath: key] = $0 }),
                  format: .number.precision(.fractionLength(0...3)))
            .labelsHidden()
            .frame(width: 52)
            .onSubmit { commit() }
            .help(help + " (mm)")
    }

    private func commit() {
        var next = edited
        next.patterns = nets.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard next != netClass, next.trackWidth > 0, next.clearance >= 0, next.viaDiameter > next.viaDrill, next.viaDrill > 0 else {
            if next != netClass { NSSound.beep() }
            return
        }
        board.setNetClass(next)
    }
}

/// The board's size and its corners' radius, typed in beside it when its outline is one rectangle (as a new board's
/// is): the outline is drawn again from its top left corner
struct PCBOutlineRow: View {
    @ObservedObject var editing: PCBEditing
    let width: Double
    let height: Double
    /// nil: an outline other than one rectangle, shown as it is
    let radius: Double?
    let layers: Int
    @State private var edited: (width: Double, height: Double, radius: Double)

    init(editing: PCBEditing, width: Double, height: Double, radius: Double?, layers: Int) {
        self.editing = editing
        self.width = width
        self.height = height
        self.radius = radius
        self.layers = layers
        _edited = State(initialValue: (width, height, radius ?? 0))
    }

    var body: some View {
        if radius != nil {
            LabeledContent("Board") {
                HStack(spacing: 4) {
                    field(\.width, "Its width")
                    Text("×").foregroundStyle(.secondary)
                    field(\.height, "Its height")
                    Text("mm").foregroundStyle(.secondary)
                }
            }
            .onChange(of: width) { _, value in edited.width = value }
            .onChange(of: height) { _, value in edited.height = value }
            .onChange(of: radius) { _, value in edited.radius = value ?? 0 }
            LabeledContent("Corners") {
                HStack(spacing: 4) {
                    field(\.radius, "Its corners' radius, 0 for square corners")
                    Text("mm").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Copper layers", value: "\(layers)")
        } else {
            LabeledContent("Board", value: String(format: "%.1f × %.1f mm, %d layers", width, height, layers))
        }
    }

    private func field(_ key: WritableKeyPath<(width: Double, height: Double, radius: Double), Double>, _ help: String) -> some View {
        TextField("", value: Binding(get: { edited[keyPath: key] }, set: { edited[keyPath: key] = $0 }),
                  format: .number.precision(.fractionLength(0...2)))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 52)
            .onSubmit { commit() }
            .help(help + " (mm)")
    }

    private func commit() {
        let e = edited
        guard e.width != width || e.height != height || e.radius != (radius ?? 0) else { return }
        guard e.width > 0, e.height > 0, e.radius >= 0, e.radius <= min(e.width, e.height) / 2 else {
            NSSound.beep()
            edited = (width, height, radius ?? 0)
            return
        }
        editing.setOutline(width: e.width, height: e.height, radius: e.radius)
    }
}

/// What the PCB view shows where it has no board to show
struct PCBEmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let text: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            actions()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A new board for the circuit: its parts' style and its copper layers chosen, then made beside the circuit's file
struct NewBoardPanel: View {
    @ObservedObject var editor: EditorState
    @ObservedObject var board: BoardController
    let design: PCBDesign

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cpu").font(.system(size: 40)).foregroundStyle(.tint)
            Text("Make a printed circuit board").font(.title2.weight(.semibold))
            Text("The board is a KiCad project beside the circuit's file (\(board.boardName)), its parts placed in the schematic's order inside an outline round them. Lay it out and route it in KiCad's PCB editor: changes to the schematic go to the board, and changes to the board come back, as you make them.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            Form {
                Picker("Parts", selection: Binding(get: { design.style }, set: { style in
                    editor.editBoard("Board Parts' Style") { $0.style = style }
                })) {
                    ForEach(PCBDesign.Style.allCases) { Text($0.title).tag($0) }
                }
                .help("The footprints for parts that have none of their own: leaded parts through holes, or surface-mount parts (0805, SOT-23, SOIC)")
                Picker("Copper layers", selection: Binding(get: { design.copperLayers }, set: { layers in
                    editor.editBoard("Board Layers") { $0.copperLayers = layers }
                })) {
                    Text("2").tag(2)
                    Text("4").tag(4)
                    Text("6").tag(6)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 380, height: 130)
            if !board.unassigned.isEmpty {
                Label("No footprint for \(board.unassigned.joined(separator: ", ")): choose them in the inspector, or place them in KiCad.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 520)
            }
            Button {
                board.createBoard()
            } label: {
                Label("Make Board", systemImage: "plus.rectangle.on.rectangle").padding(.horizontal, 8)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(board.busy != nil)
            if let failure = board.failure {
                Text(failure).foregroundStyle(.red).frame(maxWidth: 520)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Beside the board: how it and the schematic stand, what is waiting for the user's word, what the updates did, the
/// design rules check, and the parts
struct PCBSidePanel: View {
    @ObservedObject var editor: EditorState
    @ObservedObject var board: BoardController

    var body: some View {
        List {
            if let failure = board.failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
                    if board.isOpenInKiCad && !board.isLive {
                        Button("Write the Board's File Anyway") { Task { await board.update(force: true) } }
                            .help("KiCad will not see the change until it reads the file again (File ▸ Revert)")
                    }
                }
            }
            if board.availability == .board { status }
            if board.availability == .board && !board.netClasses.isEmpty {
                Section("Net classes") {
                    ForEach(board.netClasses, id: \.name) { PCBNetClassRow(board: board, netClass: $0) }
                }
            }
            if !board.removed.isEmpty {
                Section("Deleted on the board") {
                    ForEach(board.removed, id: \.self) { change in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(change.description)
                            HStack {
                                Button("Delete from Schematic") { board.deleteFromSchematic(change) }
                                Button("Put Back") { board.putBack(change) }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            if !board.warnings.isEmpty || !board.unassigned.isEmpty {
                Section("To look at") {
                    ForEach(board.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    if !board.unassigned.isEmpty {
                        Label("No footprint for \(board.unassigned.joined(separator: ", ")): choose one in the inspector.", systemImage: "questionmark.square.dashed")
                            .foregroundStyle(.orange)
                    }
                }
            }
            if !board.notes.isEmpty {
                Section("Notes") {
                    ForEach(board.notes, id: \.self) { Text($0).font(.callout) }
                }
            }
            PCBDRCSection(board: board, editing: board.editing)
            if let picture = board.picture, !picture.footprints.isEmpty { parts(picture) }
            if !board.log.isEmpty {
                Section("Changes") {
                    ForEach(board.log.prefix(30)) { entry in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.text).font(.callout)
                            Text(entry.date, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private var status: some View {
        Section {
            if board.isLive {
                Label("Open in KiCad: changes go both ways as you make them", systemImage: "link").foregroundStyle(.green)
            } else if board.isOpenInKiCad {
                VStack(alignment: .leading, spacing: 6) {
                    Label("KiCad has the board open, but JSpice can't reach it: turn on KiCad's API in its Preferences ▸ Plugins (Enable KiCad API).",
                          systemImage: "link.badge.plus")
                        .foregroundStyle(.orange)
                    if !board.apiEnabled {
                        Button("Turn On KiCad's API") { board.enableAPI() }.controlSize(.small)
                    }
                }
            } else {
                Label(board.boardName, systemImage: "doc").foregroundStyle(.secondary)
            }
            if board.pending.isEmpty && board.removed.isEmpty {
                Label("The schematic and the board agree", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            } else if !board.pending.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(board.pending.count) change\(board.pending.count == 1 ? "" : "s") to take to the board", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                    ForEach(board.pending.prefix(6), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    Button("Update Board") { Task { await board.update() } }.controlSize(.small)
                }
            }
            if let picture = board.picture {
                let unrouted = picture.airwires.count
                Label(unrouted == 0 ? "Every connection routed" : "\(unrouted) connection\(unrouted == 1 ? "" : "s") to route",
                      systemImage: unrouted == 0 ? "checkmark.circle" : "point.topleft.down.to.point.bottomright.curvepath")
                if let size = picture.boardSize {
                    PCBOutlineRow(editing: board.editing, width: size.width, height: size.height, radius: picture.outlineCornerRadius,
                                  layers: picture.copperLayers.count)
                }
            }
        }
        Section {
            Button("Edit in KiCad", systemImage: "square.and.pencil") { board.openInKiCad() }
            Button("Check Design Rules", systemImage: "checklist") { board.checkDesignRules() }
                .disabled(board.busy != nil)
            Menu {
                ForEach(KiCadFabrication.Maker.allCases.filter { $0 != .generic }) { maker in
                    Button(maker.title + "…") { board.fabricate(maker) }
                }
                Divider()
                Button(KiCadFabrication.Maker.generic.title + "…") { board.fabricate(.generic) }
            } label: {
                Label("Fabrication Files", systemImage: "shippingbox")
            }
            // (a borderless pull-down, its title in the text colour as the buttons above: the default style drew it
            // white on the light side panel)
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .disabled(board.busy != nil)
        }
        .buttonStyle(.borderless)
    }

    private func parts(_ picture: KiCadBoardPicture) -> some View {
        Section("Parts") {
            ForEach(picture.footprints.sorted { $0.reference.localizedStandardCompare($1.reference) == .orderedAscending }, id: \.uuid) { footprint in
                let parts = board.partsOfFootprint[footprint.uuid] ?? []
                Button {
                    board.select(footprint: footprint.uuid, extending: false)
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(footprint.reference).font(.callout.weight(.medium)).foregroundStyle(.primary).frame(width: 44, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(footprint.value + (footprint.isDNP ? "  (not fitted)" : "")).font(.callout).foregroundStyle(.primary)
                            Text(footprint.libID.split(separator: ":").last.map(String.init) ?? footprint.libID)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if parts.isEmpty {
                            Text("board only").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(!parts.isEmpty && !editor.selection.isDisjoint(with: parts) ? Color.accentColor.opacity(0.2) : nil)
            }
        }
    }
}


/// What the design rules check found: KiCad's, when asked for and the board has not changed since, else JSpice's
/// own, made again as the board changes
struct PCBDRCSection: View {
    @ObservedObject var board: BoardController
    @ObservedObject var editing: PCBEditing

    var body: some View {
        if let drc = board.drc {
            section(drc, title: "Design rules check")
        } else if let drc = editing.quickDRC {
            section(drc, title: "Design rules, as you edit")
        }
    }

    private func section(_ drc: KiCadFabrication.DRCReport, title: String) -> some View {
        Section(title) {
            if drc.isClean {
                Label("No problems", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            } else {
                if !drc.violations.isEmpty {
                    Label("\(drc.errors.count) errors, \(drc.violations.count - drc.errors.count) warnings", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(drc.errors.isEmpty ? Color.orange : Color.red)
                }
                if !drc.unconnected.isEmpty {
                    Label("\(drc.unconnected.count) connections not yet routed", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                ForEach(Array(drc.violations.prefix(40).enumerated()), id: \.offset) { _, violation in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(violation.description).font(.callout).foregroundStyle(violation.severity == "error" ? Color.red : Color.primary)
                        ForEach(Array(violation.items.prefix(2).enumerated()), id: \.offset) { _, item in
                            Text(item.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            if board.drc == nil {
                Text("JSpice's own check: KiCad's checks of clearances, track widths, holes, the board's edges and connections. PCB ▸ Check Design Rules runs KiCad's full check.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
