// After KiCad 10.0.7: pcbnew/tools/pcb_selection_tool.cpp (Selectable: what the display's visibility leaves the
// pointer), pcbnew/pcb_painter.cpp (PCB_RENDER_SETTINGS::GetColor: highlighted nets, the high contrast mode's dimming)
// and pcbnew/widgets/appearance_controls.cpp (the Appearance panel's rows, objects and presets).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import SwiftUI
import AppKit
import KiCadLink
import KiCadKit
import KiCadRouter

/// The board's appearance as KiCad's Appearance panel sets it (APPEARANCE_CONTROLS, through KiCadKit's
/// KiCadAppearanceControls): which layers and objects are shown, their opacity, how inactive layers look, the layer
/// worked on, kept for each board in its project's local settings (the .kicad_prl) as KiCad keeps them, so that
/// KiCad's PCB editor and JSpice share them; and the nets highlighted (KiCad's Highlight Net, NetHighlight) and the
/// board's nets as KiCad's Net Inspector lists them (NetInspector), worked out again as the board changes.
@MainActor
final class PCBAppearance: ObservableObject {
    /// The panel's state: the appearance, the board's layers, the preset chosen
    @Published private(set) var controls = KiCadAppearanceControls(opening: KiCadBoardAppearance(), boardLayers: [0, 2])
    /// The board's layers in the Appearance panel's order: id, the board's name for it, tooltip
    @Published private(set) var layers: [(id: Int, name: String, tooltip: String)] = []
    /// The nets highlighted (BOARD::GetHighLightNetCodes), by name
    @Published private(set) var highlighted: Set<String> = []
    /// The board's nets as KiCad's Net Inspector lists them, once worked out
    @Published private(set) var inspector: NetInspector?
    /// The net inspector's own settings (filter, grouping, sorting), kept in the local settings too
    @Published var inspectorSettings = NetInspector.Settings() {
        didSet { if inspectorSettings != oldValue { save() } }
    }
    /// A box of the board (mm) the view is asked to show (a net picked in the net inspector)
    @Published var zoomRequest: KiCadBox?
    /// How many times it has been asked (each a new request, even of the same box)
    @Published private(set) var zoomCount = 0
    /// The highlight tool chosen: a click highlights the net there (KiCad's Highlight Net tool)
    @Published var highlightTool = false

    weak var controller: BoardController?
    /// The local settings file as read (the rest of it kept as it was), which the board's are written into
    private var original = KiCadLocalSettings()
    private var picker: NetHighlight?
    private var generation = 0
    private var saving: Task<Void, Never>?
    /// The board file whose local settings were read
    private var readFor: URL??

    var board: KiCadBoardAppearance { controls.appearance }

    /// What the display shows and how, for drawing the board and picking from it
    var display: PCBDisplay {
        PCBDisplay(appearance: controls.appearance, enabled: controls.boardLayers, highlighted: highlighted)
    }

    // MARK: - Following the board

    /// The board was read again: its layers, its net picker and its nets' lengths made again from it; its local
    /// settings read where they have not been yet (as KiCad takes them as it opens a board)
    func boardChanged() {
        generation += 1
        let mine = generation
        Task {
            guard let controller, let (board, project) = await controller.boardForEditing() else { return }
            let enabled = KiCadLayers.enabled(board)
            let ids = Set(enabled.map(\.id))
            if readFor != .some(controller.boardFile) {
                readFor = .some(controller.boardFile)
                original = KiCadLocalSettings(text: await controller.localSettingsText())
                controls = KiCadAppearanceControls(opening: original.board, boardLayers: ids)
                inspectorSettings = NetInspector.Settings(localSettings: original.original)
            } else if ids != controls.boardLayers {
                controls = KiCadAppearanceControls(opening: controls.closed, boardLayers: ids)
            }
            let names = Dictionary(enabled.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            layers = KiCadLayers.appearanceOrder(enabled.map(\.id)).map { ($0.id, names[$0.id] ?? "", $0.tooltip) }
            syncEditingLayer()
            let (made, picked) = await Task.detached { () -> (NetInspector, NetHighlight) in
                (NetInspector(board: board, project: project), NetHighlight(board: board, project: project))
            }.value
            guard mine == generation else { return }
            inspector = made
            picker = picked
        }
    }

    /// The board closed: its settings forgotten
    func close() {
        readFor = nil
        inspector = nil
        picker = nil
        highlighted = []
    }

    // MARK: - Changing it

    func toggleLayer(_ id: Int) {
        controls.toggleLayer(id)
        save()
    }

    func setVisible(_ item: KiCadBoardAppearance.Item, _ on: Bool) {
        controls.setVisible(item, on)
        save()
    }

    /// An object's opacity slider (0 to 100)
    func setOpacity(_ item: KiCadBoardAppearance.Item, percent: Int) {
        controls.setOpacity(item, slider: percent)
        save()
    }

    func opacity(_ item: KiCadBoardAppearance.Item) -> Double {
        switch item {
        case .tracks: return board.trackOpacity
        case .vias: return board.viaOpacity
        case .pads: return board.padOpacity
        case .zones: return board.zoneOpacity
        case .bitmaps: return board.imageOpacity
        case .shapes: return board.shapeOpacity
        default: return 1
        }
    }

    func setHighContrast(_ mode: KiCadBoardAppearance.HighContrast) {
        controls.setHighContrast(mode)
        save()
    }

    /// The H key (PCB_CONTROL::HighContrastMode): inactive layers dimmed, or shown as they are again
    func toggleHighContrast() {
        setHighContrast(board.highContrast == .normal ? .dimmed : .normal)
    }

    /// The layer worked on (a click on a layer's name); a copper one is the routing tools' layer too
    func setActiveLayer(_ id: Int) {
        guard id != board.activeLayer else { return }
        controls.setActiveLayer(id)
        save()
        syncEditingLayer()
    }

    /// The routing tools' layer changed (their layer picker, Page Up and Down): the active layer too
    func editingLayerChanged(_ name: String) {
        guard let id = KiCadLayers.ids[name], id != board.activeLayer, controls.boardLayers.contains(id) else { return }
        controls.setActiveLayer(id)
        save()
    }

    private func syncEditingLayer() {
        guard KiCadLayers.isCopper(board.activeLayer), let name = KiCadLayers.names[board.activeLayer],
              let editing = controller?.editing, editing.layers.contains(name), editing.layer != name else { return }
        editing.layer = name
    }

    /// A built-in layer preset; whether it shows the board from underneath
    @discardableResult
    func apply(_ preset: KiCadBoardAppearance.Preset) -> Bool {
        controls.applyPreset(preset.name)
        save()
        syncEditingLayer()
        return controls.flipped
    }

    /// The local settings written to the board's .kicad_prl as KiCad writes them, a moment after the last change
    private func save() {
        saving?.cancel()
        var settings = original
        settings.board = controls.closed
        inspectorSettings.write(into: &settings.original)
        let target = controller
        saving = Task { [weak target] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await target?.saveLocalSettings(settings)
        }
    }

    // MARK: - Highlighting nets

    /// KiCad's Highlight Net at a point (the ` key, or a click with the highlight tool): the net of what is there
    /// (pads, tracks, vias, copper drawings, else zones; else a line of the ratsnest) highlighted, or its highlight
    /// taken off if it was the one highlighted; nothing highlighted where nothing is. `scale`: the view's points to
    /// the millimetre (the pick's accuracy is five of them)
    func highlightNet(at p: KiCadPoint, scale: Double, picture: KiCadBoardPicture) {
        let point = IPoint(KiMath.round(p.x * 1e6), KiMath.round(p.y * 1e6))
        var name: String?
        if picker != nil {
            let guide = NetHighlight.Guide(appearance: board, accuracy: NetHighlight.Guide.accuracy(pointsPerMillimetre: scale))
            name = picker!.pick(at: point, guide: guide)?.name
        }
        if name == nil, board.isVisible(.ratsnest), let wire = picture.airwire(at: p, slop: 5 / scale) { name = wire.net }
        guard let name, !name.isEmpty else {
            clearHighlight()
            return
        }
        if highlighted == [name] { clearHighlight() } else { highlight(name) }
    }

    func highlight(_ name: String) {
        highlighted = [name]
        controller?.netHighlighted(name)
    }

    /// KiCad's Clear Net Highlighting (~)
    func clearHighlight() {
        guard !highlighted.isEmpty else { return }
        highlighted = []
        controller?.netHighlighted(nil)
    }

    /// A net picked in the net inspector: highlighted, and the view zoomed to its copper
    func show(_ net: NetInspector.Net, in picture: KiCadBoardPicture) {
        highlight(net.name)
        var points: [KiCadPoint] = []
        for t in picture.tracks where t.net == net.name { points += t.points }
        for v in picture.vias where v.net == net.name { points.append(v.center) }
        for p in picture.pads where p.net == net.name { points += p.outline }
        if let box = KiCadBox(points) {
            zoomRequest = box.inflated(max(1, max(box.width, box.height) * 0.15))
            zoomCount += 1
        }
    }
}

/// What the display shows and how (the board's appearance, its layers, the nets highlighted), for drawing the board
/// and finding what is under the pointer as KiCad's display does: a hidden layer's items, hidden objects and, in high
/// contrast's hide mode, everything off the active layer are neither drawn nor picked (as PCB_SELECTION_TOOL::
/// Selectable leaves them out); inactive layers dimmed; with a net highlighted, the rest darkened by half and the net
/// brightened by half (PCB_RENDER_SETTINGS::GetColor)
struct PCBDisplay {
    var appearance = KiCadBoardAppearance()
    /// The board's layers, by id (none: every one)
    var enabled: Set<Int> = []
    var highlighted: Set<String> = []

    /// BOARD::IsLayerVisible of a layer by its name
    func layerVisible(_ name: String) -> Bool {
        guard let id = KiCadLayers.ids[name] else { return true }
        return (enabled.isEmpty || enabled.contains(id)) && appearance.visibleLayers.contains(id)
    }

    func isVisible(_ item: KiCadBoardAppearance.Item) -> Bool { appearance.isVisible(item) }

    /// Whether a layer is the active one (the high contrast layer)
    func isActive(_ layer: String) -> Bool { KiCadLayers.ids[layer] == appearance.activeLayer }

    /// How much of a layer's colour shows: a fifth off the active layer with inactive layers dimmed
    /// (COLOR4D::Mix( background, m_hiContrastFactor )), the board's edges at least 0.3 of it
    func alpha(_ layer: String) -> Double {
        guard appearance.highContrast == .dimmed, !isActive(layer) else { return 1 }
        return layer == "Edge.Cuts" ? max(KiCadColorTheme.hiContrastFactor, 0.3) : KiCadColorTheme.hiContrastFactor
    }

    /// The board as the display shows it: what is shown of it, which is also all the pointer can pick
    func visible(_ picture: KiCadBoardPicture) -> KiCadBoardPicture {
        var p = picture
        let hide = appearance.highContrast == .hidden
        func shown(_ layer: String) -> Bool { layerVisible(layer) && (!hide || isActive(layer)) }
        let back = Set(picture.footprints.filter(\.isOnBack).map(\.uuid))
        func footprintShown(_ uuid: String) -> Bool {
            back.contains(uuid) ? isVisible(.footprintsBack) : isVisible(.footprintsFront)
        }
        p.tracks = isVisible(.tracks) && appearance.trackOpacity > 0 ? picture.tracks.filter { shown($0.layer) } : []
        p.vias = isVisible(.vias) && appearance.viaOpacity > 0
            ? picture.vias.filter { v in (v.layers.isEmpty ? picture.copperLayers : v.layers).contains(where: shown) } : []
        let bottom = picture.copperLayers.last ?? "B.Cu"
        p.pads = isVisible(.pads) && appearance.padOpacity > 0 ? picture.pads.filter { pad in
            guard footprintShown(pad.footprint) else { return false }
            if pad.sides == "FB" { return picture.copperLayers.contains(where: shown) }
            return (pad.sides.contains("F") && shown("F.Cu")) || (pad.sides.contains("B") && shown(bottom))
        } : []
        p.zones = isVisible(.zones) && appearance.zoneOpacity > 0 ? picture.zones.filter { shown($0.layer) } : []
        p.texts = picture.texts.filter { shown($0.layer) }
        p.silkscreen = picture.silkscreen.filter { shown($0.layer) }
        // (the board's edges never hidden by high contrast: they help working on another layer)
        p.outline = layerVisible("Edge.Cuts") ? picture.outline : []
        let references = isVisible(.footprintReferences) && isVisible(.footprintText)
        p.footprints = picture.footprints.filter { footprintShown($0.uuid) }.map { f in
            var f = f
            if !references || !shown(f.isOnBack ? "B.SilkS" : "F.SilkS") { f.label = nil }
            return f
        }
        p.airwires = isVisible(.ratsnest) ? picture.airwires : []
        return p
    }

    /// The highlighted nets drawn over what is drawn: everything darkened by half first, then the nets' copper in its
    /// layers' colours brightened by half
    func drawHighlight(_ context: GraphicsContext, _ picture: KiCadBoardPicture, _ view: PCBTransform) {
        guard !highlighted.isEmpty else { return }
        let size = view.size
        context.fill(Path(CGRect(x: -size.width, y: -size.height, width: 3 * size.width, height: 3 * size.height)),
                     with: .color(.black.opacity(1 - KiCadColorTheme.highlightFactor)))
        func color(_ layer: String, _ opacity: Double) -> Color {
            let c = KiCadColorTheme.brightened(KiCadColorTheme.layer(KiCadLayers.ids[layer] ?? 0), KiCadColorTheme.highlightFactor)
            return Color(red: c.r, green: c.g, blue: c.b, opacity: opacity * alpha(layer))
        }
        let s = view.scale
        for layer in picture.copperLayers.reversed() {
            for zone in picture.zones where zone.layer == layer && !zone.isRuleArea && zone.net.map(highlighted.contains) == true {
                var fill = Path()
                for polygon in zone.fills { fill.addPath(view.path(polygon, closed: true)) }
                context.fill(fill, with: .color(color(layer, appearance.zoneOpacity)))
            }
            for track in picture.tracks where track.layer == layer && track.net.map(highlighted.contains) == true {
                context.stroke(view.path(track.points, closed: false), with: .color(color(layer, appearance.trackOpacity)),
                               style: StrokeStyle(lineWidth: max(0.5, track.width * s), lineCap: .round, lineJoin: .round))
            }
        }
        for pad in picture.pads where pad.net.map(highlighted.contains) == true {
            let layer = pad.sides == "B" ? (picture.copperLayers.last ?? "B.Cu") : "F.Cu"
            context.fill(view.path(pad.outline, closed: true), with: .color(color(layer, appearance.padOpacity)))
        }
        for via in picture.vias where via.net.map(highlighted.contains) == true {
            let c = view.point(via.center), r = via.size * s / 2
            let w = KiCadColorTheme.brightened(KiCadColorTheme.viaHoleWalls, KiCadColorTheme.highlightFactor)
            context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(Color(red: w.r, green: w.g, blue: w.b, opacity: appearance.viaOpacity)))
            let h = via.drill * s / 2
            context.fill(Path(ellipseIn: CGRect(x: c.x - h, y: c.y - h, width: 2 * h, height: 2 * h)), with: .color(PCBPainter.hole))
        }
        for wire in picture.airwires where highlighted.contains(wire.net) {
            var line = Path()
            line.move(to: view.point(wire.from))
            line.addLine(to: view.point(wire.to))
            context.stroke(line, with: .color(.white), lineWidth: 1.2)
        }
    }
}

/// Where the board view is to be scrolled to: the middle of the box the net inspector asked to be shown
struct PCBZoomAnchor: View {
    @ObservedObject var appearance: PCBAppearance
    let view: PCBTransform

    var body: some View {
        if let box = appearance.zoomRequest {
            let c = view.point(box.center)
            Color.clear.frame(width: 1, height: 1).offset(x: c.x, y: c.y).id("zoom")
        }
    }
}

/// The board view zoomed and scrolled to the box the net inspector asks to be shown
struct PCBZoomFollower: ViewModifier {
    @ObservedObject var appearance: PCBAppearance
    @Binding var scale: CGFloat?
    let size: CGSize
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        content.onChange(of: appearance.zoomCount) { _, _ in
            guard let box = appearance.zoomRequest else { return }
            scale = min(80, max(1, min((size.width - 40) / max(box.width, 0.1), (size.height - 40) / max(box.height, 0.1))))
            // (once the board is drawn at that scale)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                proxy.scrollTo("zoom", anchor: .center)
            }
        }
    }
}

extension BoardController {
    /// The board's project's local settings file (beside the board, the project's name with .kicad_prl)
    var localSettingsFile: URL? { boardFile.map { $0.deletingPathExtension().appendingPathExtension("kicad_prl") } }

    /// The local settings' text as the file has it, if there is one
    func localSettingsText() async -> String? {
        guard let file = localSettingsFile else { return nil }
        return await Task.detached { try? String(contentsOf: file, encoding: .utf8) }.value
    }

    /// The local settings written as KiCad writes them (KiCad's editor, open on the board, writes its own as it closes)
    func saveLocalSettings(_ settings: KiCadLocalSettings) async {
        guard let file = localSettingsFile else { return }
        let text = settings.text(projectName: file.deletingPathExtension().lastPathComponent)
        await Task.detached {
            if (try? String(contentsOf: file, encoding: .utf8)) != text { try? text.write(to: file, atomically: true, encoding: .utf8) }
        }.value
    }

    /// A net highlighted here (or none): highlighted in KiCad's editor too, where it is open (cross-probing)
    func netHighlighted(_ net: String?) {
        guard isOpenInKiCad || isLive else { return }
        Task.detached { KiCadCrossProbe.highlight(net: net) }
    }
}

/// The Appearance panel beside the board (APPEARANCE_CONTROLS): its Layers tab (each layer's colour, eye and name; a
/// click on the name makes it the active layer), its Objects tab (each object's eye, and opacity where KiCad has
/// it), the inactive layers' mode, the built-in layer presets, and the highlight tool
struct PCBAppearancePanel: View {
    @ObservedObject var appearance: PCBAppearance
    /// The side the board is seen from, which the back presets turn to
    @Binding var sideName: String
    @AppStorage("pcbAppearanceTab") private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Layers").tag(0)
                Text("Objects").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if tab == 0 { layerRows } else { objectRows }
                }
                .padding(.vertical, 4)
            }
            Divider()
            options.padding(8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var layerRows: some View {
        ForEach(appearance.layers, id: \.id) { layer in
            let active = appearance.board.activeLayer == layer.id
            let visible = appearance.board.visibleLayers.contains(layer.id)
            HStack(spacing: 6) {
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(active ? Color.primary : Color.clear)
                    .frame(width: 8)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.swiftUI(KiCadColorTheme.layer(layer.id)))
                    .frame(width: 14, height: 12)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.secondary.opacity(0.5), lineWidth: 0.5))
                Button { appearance.toggleLayer(layer.id) } label: {
                    Image(systemName: visible ? "eye" : "eye.slash").frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(visible ? "Hide \(layer.name)" : "Show \(layer.name)")
                Text(layer.name)
                    .font(.callout.weight(active ? .semibold : .regular))
                    .foregroundStyle(visible ? .primary : .secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(active ? Color.accentColor.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { appearance.setActiveLayer(layer.id) }
            .help(layer.tooltip + " (click to make it the active layer)")
        }
    }

    private var objectRows: some View {
        ForEach(Array(KiCadBoardAppearance.objectRows.enumerated()), id: \.offset) { _, row in
            if let item = row.item {
                HStack(spacing: 6) {
                    if let c = KiCadColorTheme.item(item) {
                        RoundedRectangle(cornerRadius: 2).fill(Self.swiftUI(c)).frame(width: 12, height: 10)
                    } else {
                        Color.clear.frame(width: 12, height: 10)
                    }
                    if row.eye {
                        let on = appearance.board.isVisible(item)
                        Button { appearance.setVisible(item, !on) } label: {
                            Image(systemName: on ? "eye" : "eye.slash").frame(width: 18)
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Color.clear.frame(width: 18, height: 10)
                    }
                    Text(row.title).font(.callout).frame(width: row.opacity ? 92 : nil, alignment: .leading)
                    if row.opacity {
                        Slider(value: Binding(get: { appearance.opacity(item) * 100 },
                                              set: { appearance.setOpacity(item, percent: Int($0.rounded())) }), in: 0...100)
                            .controlSize(.mini)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .help(row.tooltip)
            } else {
                Divider().padding(.vertical, 3)
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Inactive layers (H)").font(.caption).foregroundStyle(.secondary)
            Picker("Inactive layers", selection: Binding(get: { appearance.board.highContrast },
                                                         set: { appearance.setHighContrast($0) })) {
                Text("Normal").tag(KiCadBoardAppearance.HighContrast.normal)
                Text("Dim").tag(KiCadBoardAppearance.HighContrast.dimmed)
                Text("Hide").tag(KiCadBoardAppearance.HighContrast.hidden)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Layers other than the active one shown as they are, dimmed, or hidden (KiCad's high contrast mode)")
            HStack {
                Menu {
                    ForEach(KiCadBoardAppearance.presets, id: \.name) { preset in
                        Button(preset.name) {
                            sideName = (appearance.apply(preset) ? PCBSide.back : PCBSide.front).rawValue
                        }
                    }
                } label: {
                    Text(appearance.controls.preset ?? "Presets")
                }
                .help("KiCad's built-in layer presets: the layers each shows (the back's seen from underneath)")
                Toggle(isOn: $appearance.highlightTool) { Image(systemName: "highlighter") }
                    .toggleStyle(.button)
                    .help("Highlight Net: a click highlights the net of what is there, a click on it again or on nothing takes it off (or ` over it, ~ to clear)")
            }
        }
    }

    static func swiftUI(_ c: KiCadColorTheme.RGBA) -> Color { Color(red: c.r, green: c.g, blue: c.b, opacity: max(c.a, 0.2)) }
}
