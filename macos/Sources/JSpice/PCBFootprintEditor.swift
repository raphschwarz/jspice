import SwiftUI
import AppKit
import KiCadKit
import KiCadRouter

/// The footprint editor, as KiCad's Footprint Editor works (KiCadRouter's FootprintEditor): a footprint of KiCad's
/// libraries, or one of the board's (Edit Footprint), on a board of its own, its pads placed and renumbered, its
/// drawings and texts drawn, its items moved, turned and deleted, its pads' and its own properties set, checked as
/// KiCad's footprint checker checks it, and saved into its library as KiCad writes it, as another footprint, or back
/// onto the board (Update Footprint on Board). The board's footprints are updated from their libraries with Update
/// from Library (KiCad's Update Footprints from Library).
@MainActor
final class PCBFootprintEditorModel: ObservableObject, Identifiable {
    enum Tool: String, CaseIterable, Identifiable {
        case select, pad, line, rectangle, circle, text, renumber
        var id: String { rawValue }

        var title: String {
            switch self {
            case .select: return "Select"
            case .pad: return "Pad"
            case .line: return "Line"
            case .rectangle: return "Rectangle"
            case .circle: return "Circle"
            case .text: return "Text"
            case .renumber: return "Renumber"
            }
        }

        var symbol: String {
            switch self {
            case .select: return "cursorarrow"
            case .pad: return "circle.circle"
            case .line: return "line.diagonal"
            case .rectangle: return "rectangle"
            case .circle: return "circle"
            case .text: return "textformat"
            case .renumber: return "number"
            }
        }
    }

    /// The footprint being edited (none yet: one is to be opened from a library)
    @Published private(set) var editor: FootprintEditor?
    @Published private(set) var picture = KiCadBoardPicture()
    @Published var selection: Set<String> = []
    @Published var tool = Tool.select {
        didSet { finishTool() }
    }
    @Published var layer = "F.SilkS"
    @Published var textToPlace = "Text"
    @Published var renumberStart = 1
    @Published var renumberStep = 1
    @Published var renumberPrefix = ""
    @Published var message: String?
    @Published var violations: [FootprintChecks.Violation]?
    @Published var query = ""
    @Published private(set) var matches: [String] = []
    /// A shape's first point, while its second is to be clicked
    @Published private(set) var started: KiCadPoint?
    @Published var saveAsLibrary = ""
    @Published var saveAsName = ""

    let library: KiCadFootprintLibrary?
    weak var editing: PCBEditing?
    private var renumbered: [String] = []

    static let layers = ["F.Cu", "B.Cu", "F.SilkS", "B.SilkS", "F.Fab", "B.Fab", "F.CrtYd", "B.CrtYd", "F.Mask", "B.Mask",
                         "F.Paste", "B.Paste", "Dwgs.User", "Cmts.User", "Edge.Cuts"]
    /// The grid points are put on (the footprint editor's 0.05 mm)
    static let grid = 0.05

    init(editor: FootprintEditor?, library: KiCadFootprintLibrary?, editing: PCBEditing?) {
        self.editor = editor
        self.library = library
        self.editing = editing
        saveAsLibrary = library?.libraries.keys.sorted().first ?? ""
        refresh()
    }

    var title: String {
        guard let editor else { return "Footprint Editor" }
        return editor.link != nil ? "\(editor.name) (from the board)" : editor.libID
    }

    func refresh() {
        guard let editor else { return }
        picture = KiCadBoardPicture(editor.board)
        let box = picture.bounds
        if box.width < 1 || box.height < 1 { picture.bounds = KiCadBox(minX: -5, minY: -5, maxX: 5, maxY: 5) }
        saveAsName = editor.name
        objectWillChange.send()
    }

    static func snapped(_ p: KiCadPoint) -> KiCadPoint {
        KiCadPoint((p.x / grid).rounded() * grid, (p.y / grid).rounded() * grid)
    }

    // MARK: - Opening

    func search() {
        let q = query
        matches = library?.search(q, limit: 40) ?? []
    }

    /// A footprint of the libraries opened (LoadFootprintFromLibrary)
    func open(_ libID: String) {
        guard let library else { return }
        do {
            editor = FootprintEditor(library: try library.footprint(libID), libID: libID)
            selection = []
            violations = nil
            message = nil
            refresh()
        } catch {
            message = "\(error)"
        }
    }

    // MARK: - Tools

    private func finishTool() {
        started = nil
        renumbered = []
    }

    func click(at point: KiCadPoint, slop: Double, extending: Bool) {
        guard let editor else { return }
        let p = Self.snapped(point)
        switch tool {
        case .select:
            if let id = editor.item(at: point, slop: slop) {
                if extending { selection.formSymmetricDifference([id]) } else { selection = [id] }
            } else if !extending {
                selection = []
            }
        case .pad:
            selection = [editor.placePad(at: p)]
        case .line, .rectangle, .circle:
            guard let start = started else {
                started = p
                return
            }
            started = nil
            let kind: BoardShape.Kind = tool == .line ? .segment : tool == .rectangle ? .rectangle : .circle
            var shape = BoardShape(kind: kind, layer: layer, width: editor.lineWidths.width(layer))
            shape.start = IPoint(Int((start.x * 1e6).rounded()), Int((start.y * 1e6).rounded()))
            shape.end = IPoint(Int((p.x * 1e6).rounded()), Int((p.y * 1e6).rounded()))
            guard shape.start != shape.end else { return }
            selection = [editor.addShape(shape)]
        case .text:
            selection = [editor.addText(textToPlace, at: p, layer: layer)]
        case .renumber:
            // (EnumeratePads: each pad clicked given the next number, the whole run one change)
            guard let id = editor.item(at: point, slop: slop), editor.padNumbers[id] != nil else { return }
            if !renumbered.isEmpty { editor.undo() }
            renumbered.append(id)
            editor.renumberPads(clicked: renumbered, start: renumberStart, step: renumberStep, prefix: renumberPrefix)
            selection = Set(renumbered)
        }
        refresh()
    }

    func moveSelection(by delta: KiCadPoint) {
        guard let editor, !selection.isEmpty else { return }
        let d = Self.snapped(delta)
        guard d != .zero else { return }
        editor.move(Array(selection), by: d)
        refresh()
    }

    /// The selection turned 90° counterclockwise about the first item's place (EDIT_TOOL's Rotate, R)
    func rotateSelection() {
        guard let editor, let first = selection.sorted().first, let node = editor.item(first) else { return }
        let at = node["at"] ?? node["start"] ?? node["center"]
        let c = KiCadPoint(at?.number(at: 0) ?? 0, at?.number(at: 1) ?? 0)
        editor.rotate(Array(selection), about: c, degrees: 90)
        refresh()
    }

    func deleteSelection() {
        guard let editor, !selection.isEmpty else { return }
        editor.delete(Array(selection))
        selection = []
        refresh()
    }

    func duplicateSelection() {
        guard let editor, !selection.isEmpty else { return }
        selection = Set(editor.duplicate(Array(selection), by: KiCadPoint(1, 1)))
        refresh()
    }

    func undo() { editor?.undo(); selection = []; refresh() }
    func redo() { editor?.redo(); selection = []; refresh() }

    func check() {
        violations = editor?.check()
    }

    // MARK: - Properties

    /// The pad selected, if one is alone
    var selectedPad: String? {
        guard selection.count == 1, let id = selection.first, editor?.padNumbers[id] != nil else { return nil }
        return id
    }

    func setPad(_ id: String, _ p: PadProperties) {
        guard let editor else { return }
        if !editor.setPadProperties(id, p) { message = "The pad's properties were not taken." }
        refresh()
    }

    func setLibraryProperties(name: String, description: String, keywords: String) {
        editor?.setLibraryProperties(name: name, description: description, keywords: keywords)
        refresh()
    }

    func setField(_ name: String, _ text: String) {
        guard let editor, var p = editor.footprintProperties, let i = p.fields.firstIndex(where: { $0.name == name }) else { return }
        p.fields[i].text = text
        editor.setFootprintProperties(p)
        refresh()
    }

    // MARK: - Saving

    /// Save: a board's footprint back onto the board (Update Footprint on Board), else into its library
    func save() {
        guard let editor else { return }
        if editor.link != nil {
            guard let editing else { return }
            Task {
                let done = await editing.place { session in session.updateFootprint(from: editor) }
                message = done ? "The board's footprint was updated." : "The footprint is no longer on the board."
            }
            return
        }
        guard let library else { return }
        do {
            try editor.save(in: library)
            message = "Saved \(editor.libID)."
        } catch {
            message = "\(error)"
        }
        refresh()
    }

    /// Save As: into `saveAsLibrary` as `saveAsName`
    func saveAs() {
        guard let editor, let library else { return }
        do {
            try editor.saveAs(library: saveAsLibrary, name: saveAsName, in: library)
            message = "Footprint '\(editor.name)' added to '\(saveAsLibrary)'."
        } catch {
            message = "\(error)"
        }
        refresh()
    }
}

extension PCBEditing {
    /// The footprint editor opened on the board's footprint `uuid` (Edit Footprint: LoadFootprintFromBoard)
    func footprintEditor(for uuid: String) async -> PCBFootprintEditorModel? {
        if !isReady { await prepareNow() }
        let editor = await withSession { session in FootprintEditor(board: session.board.copy(), footprint: uuid) }
        let library = await controller?.footprintLibrary()
        guard let editor else { return nil }
        return PCBFootprintEditorModel(editor: editor, library: library, editing: self)
    }

    /// The footprint editor opened with no footprint yet, to open one of the libraries
    func footprintEditor() async -> PCBFootprintEditorModel {
        PCBFootprintEditorModel(editor: nil, library: await controller?.footprintLibrary(), editing: self)
    }

    /// The footprints `uuids` (all the board's, empty) updated from their libraries as KiCad's Update Footprints from
    /// Library updates them, with its own options, as one change; what it reports
    func updateFootprintsFromLibrary(_ uuids: Set<String>) async -> [String] {
        guard let library = await controller?.footprintLibrary() else { return [] }
        let report = ReportBox()
        _ = await place { session in
            let (edit, lines) = session.updateFootprintsFromLibrary(library, uuids: uuids.isEmpty ? nil : uuids)
            report.lines = lines.lines
            return edit
        }
        return report.lines
    }
}

/// What a change made on the router's queue reports back
private final class ReportBox: @unchecked Sendable {
    var lines: [String] = []
}

/// The footprint editor's sheet
struct PCBFootprintEditorSheet: View {
    @ObservedObject var model: PCBFootprintEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 40
    @State private var dragStart: KiCadPoint?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                if model.editor == nil {
                    opener
                } else {
                    canvas
                    Divider()
                    PCBFootprintEditorPanel(model: model).frame(width: 300)
                }
            }
            if let message = model.message {
                Divider()
                Text(message).font(.callout).foregroundStyle(.secondary).padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 1000, minHeight: 680)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(model.title).font(.headline)
            if model.editor != nil {
                Divider().frame(height: 18)
                Picker("Tool", selection: $model.tool) {
                    ForEach(PCBFootprintEditorModel.Tool.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .labelsHidden().fixedSize()
                .help("Select and drag items; place pads (from the last pad placed, numbered on); draw lines, rectangles and circles on the layer chosen; place texts; renumber pads by clicking them in order")
                Picker("Layer", selection: $model.layer) {
                    ForEach(PCBFootprintEditorModel.layers, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize()
                if model.tool == .text {
                    TextField("Text", text: $model.textToPlace).frame(width: 120)
                }
                if model.tool == .renumber {
                    TextField("Prefix", text: $model.renumberPrefix).frame(width: 50)
                    Stepper("From \(model.renumberStart)", value: $model.renumberStart, in: 0...9999)
                    Stepper("By \(model.renumberStep)", value: $model.renumberStep, in: 1...100)
                }
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!(model.editor?.canUndo ?? false)).help("Undo")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!(model.editor?.canRedo ?? false)).help("Redo")
                Button { model.rotateSelection() } label: { Image(systemName: "rotate.left") }
                    .disabled(model.selection.isEmpty).help("Rotate the selection 90° (R)")
                Button { model.duplicateSelection() } label: { Image(systemName: "plus.square.on.square") }
                    .disabled(model.selection.isEmpty).help("Duplicate the selection")
                Button { model.deleteSelection() } label: { Image(systemName: "trash") }
                    .disabled(model.selection.isEmpty).help("Delete the selection (⌫)")
                Button { scale = max(5, scale * 0.8) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { scale = min(400, scale * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
            }
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private var opener: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open a footprint of KiCad's libraries").font(.headline)
            HStack {
                TextField("Search the libraries", text: $model.query).onSubmit { model.search() }
                Button("Search") { model.search() }
            }
            List(model.matches, id: \.self) { id in
                Button(id) { model.open(id) }.buttonStyle(.borderless)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let bounds = model.picture.bounds
            let margin = 4.0
            let box = KiCadBox(minX: bounds.minX - margin, minY: bounds.minY - margin, maxX: bounds.maxX + margin, maxY: bounds.maxY + margin)
            let view = PCBTransform(bounds: box, scale: scale, mirrored: false)
            ScrollView([.horizontal, .vertical]) {
                Canvas { context, _ in
                    PCBPainter(picture: model.picture, view: view, side: .front, selected: [], drc: nil).draw(context)
                    drawSelection(context, view)
                    if let start = model.started {
                        let p = view.point(start)
                        context.stroke(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.accentColor), lineWidth: 1.5)
                    }
                    // (the footprint's anchor)
                    let o = view.point(.zero)
                    var cross = Path()
                    cross.move(to: CGPoint(x: o.x - 8, y: o.y))
                    cross.addLine(to: CGPoint(x: o.x + 8, y: o.y))
                    cross.move(to: CGPoint(x: o.x, y: o.y - 8))
                    cross.addLine(to: CGPoint(x: o.x, y: o.y + 8))
                    context.stroke(cross, with: .color(.white.opacity(0.6)), lineWidth: 1)
                }
                .frame(width: max(view.size.width, geometry.size.width), height: max(view.size.height, geometry.size.height))
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .local)
                    .onEnded { drag in
                        guard model.tool == .select else { return }
                        let a = view.board(drag.startLocation), b = view.board(drag.location)
                        if model.selection.isEmpty || model.editor?.item(at: a, slop: 4 / Double(scale)).map({ model.selection.contains($0) }) != true {
                            model.click(at: a, slop: 4 / Double(scale), extending: false)
                        }
                        model.moveSelection(by: KiCadPoint(b.x - a.x, b.y - a.y))
                    })
                .onTapGesture(coordinateSpace: .local) { location in
                    focused = true
                    let flags = NSEvent.modifierFlags
                    model.click(at: view.board(location), slop: 4 / Double(scale), extending: flags.contains(.shift) || flags.contains(.command))
                }
            }
            .background(PCBPainter.background)
            .focusable()
            .focused($focused)
            .onKeyPress(phases: .down) { press in
                switch press.characters {
                case "r", "R": model.rotateSelection(); return .handled
                case "\u{7F}", "\u{8}": model.deleteSelection(); return .handled
                default:
                    if press.key == .escape {
                        model.tool = .select
                        model.selection = []
                        return .handled
                    }
                    return .ignored
                }
            }
        }
    }

    /// The items selected outlined
    private func drawSelection(_ context: GraphicsContext, _ view: PCBTransform) {
        guard let editor = model.editor, !model.selection.isEmpty else { return }
        let fp = KiCadFootprint(editor.footprint, board: editor.board)
        for pad in fp.pads where model.selection.contains(pad.uuid) {
            context.stroke(view.path(pad.outline, closed: true), with: .color(.accentColor), lineWidth: 2)
        }
        for drawing in fp.drawings where model.selection.contains(drawing.node.value("uuid") ?? "") {
            let closed = ["rect", "circle", "poly"].contains(drawing.kind)
            context.stroke(view.path(drawing.points, closed: closed), with: .color(.accentColor), lineWidth: 2)
        }
        for text in editor.footprint.items where (text.head == "fp_text" || text.head == "property") && model.selection.contains(text.value("uuid") ?? "") {
            guard let at = text["at"] else { continue }
            let p = view.point(KiCadPoint(at.number(at: 0) ?? 0, at.number(at: 1) ?? 0))
            context.stroke(Path(CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.accentColor), lineWidth: 1.5)
        }
    }
}

/// The footprint editor's side panel: its properties, the pad selected, its checks, and saving it
private struct PCBFootprintEditorPanel: View {
    @ObservedObject var model: PCBFootprintEditorModel
    @State private var name = ""
    @State private var description = ""
    @State private var keywords = ""
    @State private var reference = ""
    @State private var value = ""
    @State private var pad: PadProperties?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                footprint
                Divider()
                padSection
                Divider()
                checks
                Divider()
                saving
            }
            .padding(12)
        }
        .onAppear(perform: load)
        .onChange(of: model.picture.footprints.first?.reference) { _, _ in load() }
        .onChange(of: model.selection) { _, _ in loadPad() }
    }

    private func load() {
        guard let editor = model.editor else { return }
        name = editor.name
        description = editor.footprint.value("descr") ?? ""
        keywords = editor.footprint.value("tags") ?? ""
        let fp = KiCadFootprint(editor.footprint, board: editor.board)
        reference = fp.reference
        value = fp.value
        loadPad()
    }

    private func loadPad() {
        pad = model.selectedPad.flatMap { model.editor?.padProperties($0) }
    }

    private var footprint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Footprint").font(.headline)
            TextField("Name", text: $name)
            TextField("Description", text: $description)
            TextField("Keywords", text: $keywords)
            Button("Set") { model.setLibraryProperties(name: name, description: description, keywords: keywords) }
            TextField("Reference", text: $reference).onSubmit { model.setField("Reference", reference) }
            TextField("Value", text: $value).onSubmit { model.setField("Value", value) }
        }
    }

    @ViewBuilder private var padSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pad").font(.headline)
            if let id = model.selectedPad, pad != nil {
                let p = Binding(get: { pad ?? PadProperties() }, set: { pad = $0 })
                TextField("Number", text: p.number)
                Picker("Type", selection: p.type) {
                    ForEach(PadProperties.PadType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Shape", selection: p.shape) {
                    ForEach(PadProperties.Shape.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                HStack {
                    TextField("Width", value: p.size.x, format: .number.precision(.fractionLength(0...4)))
                    TextField("Height", value: p.size.y, format: .number.precision(.fractionLength(0...4)))
                }
                TextField("Hole", value: p.drill.x, format: .number.precision(.fractionLength(0...4)))
                Button("Set Pad") { if let pad { model.setPad(id, pad) } }
            } else {
                Text("Select a pad to set its properties.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Checks").font(.headline)
                Spacer()
                Button("Check Footprint") { model.check() }
                    .help("The checks KiCad's footprint checker makes: courtyards, attributes, pads, shorting pads, net ties")
            }
            if let violations = model.violations {
                if violations.isEmpty {
                    Text("No problems found.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(violations.indices, id: \.self) { i in
                    let v = violations[i]
                    Button {
                        model.selection = Set(v.items)
                    } label: {
                        Text((FootprintChecks.titles[v.type] ?? v.type) + (v.detail.isEmpty ? "" : " " + v.detail))
                            .font(.callout).multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder private var saving: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Save").font(.headline)
            if model.editor?.link != nil {
                Button("Update Footprint on Board") { model.save() }
                    .help("The board's footprint exchanged for this one, as KiCad's footprint editor saves a footprint from the board")
            } else {
                Button("Save to \(model.editor?.libraryName ?? "its library")") { model.save() }
                    .disabled(model.library?.libraries[model.editor?.libraryName ?? ""] == nil)
                    .help("The footprint written into its library as KiCad writes it")
            }
            if let library = model.library {
                Picker("Library", selection: $model.saveAsLibrary) {
                    ForEach(library.libraries.keys.sorted(), id: \.self) { Text($0).tag($0) }
                }
                TextField("Name", text: $model.saveAsName)
                Button("Save As") { model.saveAs() }
                    .help("The footprint saved into the library chosen under the name given (its value too, where it was its name)")
            }
        }
    }
}
