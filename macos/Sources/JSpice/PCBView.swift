import SwiftUI
import AppKit
import CircuitKit
import KiCadKit

/// The circuit's printed circuit board as KiCad has it: copper, pads, holes, silkscreen and the connections still to
/// route, kept up to date as the board changes in KiCad's PCB editor and as the schematic changes here. Clicking a
/// part selects it in the schematic and in KiCad. The board is laid out and routed in KiCad's editor (Edit in KiCad).
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
                Link("Download KiCad", destination: URL(string: "https://www.kicad.org/download/")!)
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
                Canvas { context, _ in
                    PCBPainter(picture: picture, view: view, side: side, selected: selectedFootprints(picture),
                               drc: board.drc).draw(context)
                }
                .frame(width: view.size.width, height: view.size.height)
                .overlay { BoardHoverReadout { readout(picture, view, at: $0) } }
                .onTapGesture(coordinateSpace: .local) { location in
                    let footprint = picture.footprint(at: view.board(location))
                    board.select(footprint: footprint?.uuid, extending: NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift))
                }
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
            .onAppear { fitted = fit }
            .onChange(of: fit) { _, value in fitted = value }
        }
        .background(PCBPainter.background)
    }

    private func selectedFootprints(_ picture: KiCadBoardPicture) -> Set<String> {
        guard !editor.selection.isEmpty else { return [] }
        return Set(board.partsOfFootprint.filter { !editor.selection.isDisjoint(with: $0.value) }.keys)
    }

    private func readout(_ picture: KiCadBoardPicture, _ view: PCBTransform, at pointer: CGPoint) -> String? {
        let p = view.board(pointer)
        let position = String(format: "%.2f, %.2f mm", p.x, p.y)
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

    func color(_ layer: String) -> Color {
        switch layer {
        case "F.Cu": return Self.front
        case "B.Cu": return Self.back
        default:
            let n = Int(layer.dropFirst(2).prefix { $0.isNumber }) ?? 1
            return Self.inner[(n - 1) % Self.inner.count]
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
            for track in picture.tracks where track.layer == layer {
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
        for via in picture.vias {
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
        for via in picture.vias {
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
            if let drc = board.drc { drcSection(drc) }
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
                    LabeledContent("Board", value: String(format: "%.1f × %.1f mm, %d layers", size.width, size.height, picture.copperLayers.count))
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
            .disabled(board.busy != nil)
        }
        .buttonStyle(.borderless)
    }

    private func drcSection(_ drc: KiCadFabrication.DRCReport) -> some View {
        Section("Design rules check") {
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
        }
    }

    private func parts(_ picture: KiCadBoardPicture) -> some View {
        Section("Parts") {
            ForEach(picture.footprints.sorted { $0.reference.localizedStandardCompare($1.reference) == .orderedAscending }, id: \.uuid) { footprint in
                let parts = board.partsOfFootprint[footprint.uuid] ?? []
                Button {
                    board.select(footprint: footprint.uuid, extending: false)
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(footprint.reference).font(.callout.weight(.medium)).frame(width: 44, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(footprint.value + (footprint.isDNP ? "  (not fitted)" : "")).font(.callout)
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
