import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import CircuitKit

/// Everything about one open circuit window: the selected tool and parts, the view's zoom and scroll position, and
/// every edit, so each one can be undone.
@MainActor
final class EditorState: ObservableObject {
    let document: CircuitDocument
    let simulation: SimulationController
    weak var undoManager: UndoManager?
    /// The schematic view, for exporting it as an image
    weak var canvas: NSView?

    /// The part being placed, or nil for selecting and moving
    @Published var tool: ElementKind?
    /// The block placed while the tool is `.block`
    @Published var blockToPlace: BlockDefinition?
    /// Op-amps whose maker's models are being downloaded
    @Published var makerModelLoading: Set<UUID> = []
    /// The blocks saved in the block library, read again when one is saved
    @Published private(set) var libraryBlocks: [BlockDefinition] = BlockLibrary.all()
    @Published var selection: Set<UUID> = []
    @Published var hovered: UUID?
    @Published var zoom: CGFloat = 1.25
    @Published var pan = CGPoint(x: 120, y: 120)
    // What the window shows is remembered for the next window and launch (see `ViewPreferences`, which keeps the
    // automated modes on the built-in defaults)
    @Published var showValues = ViewPreferences.bool(.showValues, default: true) {
        didSet { ViewPreferences.set(showValues, for: .showValues) }
    }
    @Published var showCurrent = ViewPreferences.bool(.showCurrent, default: true) {
        didSet { ViewPreferences.set(showCurrent, for: .showCurrent) }
    }
    @Published var showInspector = ViewPreferences.bool(.showInspector, default: true) {
        didSet { ViewPreferences.set(showInspector, for: .showInspector) }
    }
    /// The bottom dock's tab (scopes, front panel, chip, problems): the one chosen last, shown when the circuit has it
    @Published var dockTab: DockTab = ViewPreferences.dockTab() {
        didSet { ViewPreferences.set(dockTab.rawValue, for: .dockTab) }
    }
    /// The bottom dock folded down to its tab bar
    @Published var dockCollapsed = ViewPreferences.bool(.dockCollapsed, default: false) {
        didSet { ViewPreferences.set(dockCollapsed, for: .dockCollapsed) }
    }
    /// The height of the bottom dock's contents, below its tab bar
    @Published var dockHeight: CGFloat = ViewPreferences.dockHeight() {
        didSet { ViewPreferences.set(Double(dockHeight), for: .dockHeight) }
    }
    /// The front panel of knobs and switches open in the bottom dock
    var showPanel: Bool {
        get { dockTab == .panel && !dockCollapsed }
        set {
            if newValue {
                showDock(.panel)
            } else if dockTab == .panel {
                dockCollapsed = true
            }
        }
    }
    /// Opens the bottom dock on a tab
    func showDock(_ tab: DockTab) {
        if dockTab != tab { dockTab = tab }
        if dockCollapsed { dockCollapsed = false }
    }
    /// What the window shows: the schematic, or the circuit as built on a breadboard or stripboard
    @Published var board: BoardKind = .schematic
    /// The quick-add palette (⌘K or /): type a part's name to place it
    @Published var showQuickAdd = false
    /// The keyboard shortcuts sheet (⌘/ or ?)
    @Published var showShortcuts = false
    @Published var showChipSupport = false
    /// The microcontroller whose sketch is open in the sketch editor
    @Published var editingSketch: UUID?
    /// How each microcontroller's last upload went
    @Published var sketchStatus: [UUID: SketchStatus] = [:]
    /// The control waiting for a MIDI controller to be moved (MIDI Learn): a part, or a part inside a block part
    @Published var midiLearning: MIDITarget?
    /// What reading a schematic drawing is doing, while it does
    @Published var captureStatus: String?
    var captureTask: Task<Void, Never>?
    /// Incremented to ask the canvas to fit the circuit in view
    @Published private(set) var fitRequest = 1
    /// What operations told the user, shown as toasts over the canvas, oldest first (see Notices.swift)
    @Published var notices: [Notice] = []
    /// The notice whose report is open in a sheet
    @Published var noticeReport: Notice?
    /// Each fading notice's timer
    var noticeTimers: [UUID: Task<Void, Never>] = [:]
    /// The pointer is over the toasts, so none fades
    var noticesHeld = false

    var viewSize: CGSize = .zero
    /// True once the user has zoomed or scrolled; until then the canvas keeps the circuit fitted as it resizes
    var viewAdjusted = false
    private var interactionStart: Circuit?

    static let gridSize: CGFloat = 16
    static let pasteboardType = NSPasteboard.PasteboardType("org.knowm.jspice.elements")

    init(document: CircuitDocument) {
        self.document = document
        simulation = SimulationController(circuit: document.circuit)
    }

    var circuit: Circuit { document.circuit }

    /// Points per grid unit
    var unit: CGFloat { Self.gridSize * zoom }

    var selectedElement: Element? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return circuit[id]
    }

    // MARK: - Undoable edits

    func edit(_ actionName: String, _ change: (inout Circuit) -> Void) {
        var next = document.circuit
        change(&next)
        guard next != document.circuit else { return }
        let previous = document.circuit
        document.circuit = next
        registerUndo(restoring: previous, actionName: actionName)
    }

    /// Starts a change made over several events (dragging, sliders); it becomes one undo step in `endInteraction`
    func beginInteraction() {
        if interactionStart == nil { interactionStart = document.circuit }
    }

    func setDuringInteraction(_ circuit: Circuit) {
        if circuit != document.circuit { document.circuit = circuit }
    }

    func endInteraction(_ actionName: String) {
        guard let start = interactionStart else { return }
        interactionStart = nil
        if start != document.circuit { registerUndo(restoring: start, actionName: actionName) }
    }

    /// Abandons a change in progress (Esc during a drag), going back to where it started
    func cancelInteraction() {
        guard let start = interactionStart else { return }
        interactionStart = nil
        if start != document.circuit { document.circuit = start }
    }

    private func registerUndo(restoring previous: Circuit, actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.restore(previous, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func restore(_ circuit: Circuit, actionName: String) {
        let current = document.circuit
        // switches and knobs are played, not edited: undo leaves them as they are now (except when undoing a value
        // typed into the inspector)
        var restored = circuit
        let typedWiper = actionName.hasSuffix("Wiper position")
        for i in restored.elements.indices {
            guard let live = current[restored.elements[i].id] else { continue }
            if restored.elements[i].kind.isSwitch { restored.elements[i].closed = live.closed }
            if restored.elements[i].kind == .potentiometer && !typedWiper {
                restored.elements[i][param: "position"] = live[param: "position"]
            }
        }
        let circuit = restored
        document.circuit = circuit
        selection = selection.filter { circuit[$0] != nil }
        registerUndo(restoring: current, actionName: actionName)
    }

    // MARK: - Operations

    @discardableResult
    func add(_ element: Element) -> UUID {
        RecentParts.shared.record(element.kind)
        var id = element.id
        edit("Add \(element.kind.displayName)") { circuit in
            id = circuit.add(element)
            // a terminal placed on the middle of a wire joins it
            circuit.connectTerminals(of: [id])
        }
        return id
    }

    /// Joins the terminals of the dragged parts to wires they were dropped on, as part of the ongoing interaction
    func connectDuringInteraction(_ ids: Set<UUID>) {
        var next = circuit
        next.connectTerminals(of: ids)
        setDuringInteraction(next)
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        edit(ids.count == 1 ? "Delete" : "Delete \(ids.count) Parts") { $0.remove(ids) }
        selection = []
    }

    func rotateSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        edit("Rotate") { $0.rotate(ids) }
    }

    var canFlipSelection: Bool {
        selection.contains { circuit[$0]?.kind.canFlip == true }
    }

    func flipSelection() {
        guard canFlipSelection else { return }
        let ids = selection
        edit("Flip") { $0.flip(ids) }
    }

    func selectAll() {
        selection = Set(circuit.elements.map(\.id))
    }

    /// Picks a tool from the keyboard or the palette, and gives the schematic the keyboard back
    func choose(_ kind: ElementKind?) {
        if let kind { RecentParts.shared.record(kind) }
        tool = kind
        if kind != .block { blockToPlace = nil }
        showQuickAdd = false
        if let canvas { canvas.window?.makeFirstResponder(canvas) }
    }

    /// Picks a block from the library to place, or puts the block tool away when it is the one already chosen
    func choose(block: BlockDefinition) {
        if tool == .block && blockToPlace?.name == block.name {
            choose(nil)
            return
        }
        blockToPlace = block
        choose(.block)
    }

    // MARK: - Blocks

    func reloadBlockLibrary() {
        libraryBlocks = BlockLibrary.all()
    }

    /// Saves the circuit in the block library as a block named `name` (replacing one of the same name); its ports are
    /// its pins. Nil when it is saved, otherwise what keeps it from being saved.
    func saveCircuitAsBlock(named name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "The block needs a name." }
        guard circuit.elements.contains(where: { $0.kind == .port }) else {
            return "A block's pins are its Port parts (in the library's Blocks section). Add one for each input and output, wired to where it connects, then save it again."
        }
        if let inner = circuit.elements.first(where: { $0.block?.uses(name) ?? false }) {
            return "\(inner.name) is the block \(name) or contains it, and a block cannot contain itself."
        }
        do {
            try BlockLibrary.save(circuit.asBlock(named: name))
        } catch {
            return error.localizedDescription
        }
        reloadBlockLibrary()
        return nil
    }

    /// Asks for a name and saves the circuit in the block library (Circuit ▸ Save as Block)
    func promptSaveAsBlock() {
        let alert = NSAlert()
        alert.messageText = "Save as Block"
        alert.informativeText = "The circuit goes into the block library, to be used as one part in other circuits. Its Port parts are the block's pins: those set to Left (or drawn on the left) are its inputs, the others its outputs. A block of the same name is replaced."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let title = canvas?.window?.title ?? ""
        field.stringValue = title.isEmpty || title == "Untitled" ? "Block" : (title as NSString).deletingPathExtension
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        // a sheet on the window when there is one
        if let window = canvas?.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                MainActor.assumeIsolated {
                    self?.finishSaveAsBlock(response, name: field.stringValue)
                }
            }
        } else {
            finishSaveAsBlock(alert.runModal(), name: field.stringValue)
        }
    }

    private func finishSaveAsBlock(_ response: NSApplication.ModalResponse, name: String) {
        guard response == .alertFirstButtonReturn else { return }
        if let problem = saveCircuitAsBlock(named: name) {
            notify(.failure, "The block wasn't saved", detail: problem)
        } else {
            notify(.success, "Saved “\(name.trimmingCharacters(in: .whitespaces))” as a block",
                   detail: "It is in the library's Blocks, to be used as one part in other circuits.")
        }
    }

    /// Changes a part inside a block part: a knob or switch of this copy of the block. With an action name it is one
    /// undo step; without, part of the interaction in progress (a slider being dragged).
    func updateInsideBlock(_ blockID: UUID, _ innerID: UUID, actionName: String?, _ change: @escaping (inout Element) -> Void) {
        var next = circuit
        next.update(blockID) { element in
            guard var block = element.block, let i = block.circuit.elements.firstIndex(where: { $0.id == innerID }) else { return }
            change(&block.circuit.elements[i])
            element.block = block
        }
        if let actionName {
            edit(actionName) { $0 = next }
        } else {
            setDuringInteraction(next)
        }
    }

    /// Plays a knob, switch or button inside a block part, as on the front panel: played, not an edit to undo
    func playInsideBlock(_ blockID: UUID, _ innerID: UUID, _ change: (inout Element) -> Void) {
        var next = circuit
        next.update(blockID) { element in
            guard var block = element.block, let i = block.circuit.elements.firstIndex(where: { $0.id == innerID }) else { return }
            change(&block.circuit.elements[i])
            element.block = block
        }
        if next != circuit { document.circuit = next }
    }

    /// Replaces a block part's circuit with the library's block of the same name, keeping the settings of the knobs and
    /// switches that are still in it
    func updateBlockFromLibrary(_ id: UUID) {
        guard let element = circuit[id], let old = element.block,
              var fresh = BlockLibrary.block(named: old.name) else { return }
        for i in fresh.circuit.elements.indices {
            guard let previous = old.circuit[fresh.circuit.elements[i].id] else { continue }
            if previous.kind == .potentiometer { fresh.circuit.elements[i][param: "position"] = previous[param: "position"] }
            if previous.kind.isSwitch { fresh.circuit.elements[i].closed = previous.closed }
        }
        edit("Update Block") { circuit in
            circuit.update(id) { $0.block = fresh }
        }
    }

    /// Opens a block part's circuit in a window of its own, to change it and save it as a block again
    func openBlock(_ id: UUID) {
        guard let block = circuit[id]?.block else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("JSpice Blocks", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(block.name.replacingOccurrences(of: "/", with: "-")).appendingPathExtension("jspice")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(block.circuit), (try? data.write(to: file)) != nil else { return }
        NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { _, _, _ in }
    }

    // MARK: - Sound files

    /// Asks for a sound file (any format macOS reads: WAV, AIFF, MP3, AAC…) and gives it to an audio input part
    func chooseSound(for id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose a sound for the audio input to play (up to a minute is kept)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let clip = try Self.readSound(url)
            edit("Choose Sound") { $0.update(id) { $0.audio = clip } }
        } catch {
            notify(.failure, "That sound can't be read",
                   detail: "\(url.lastPathComponent): \(error.localizedDescription)",
                   report: NoticeReport([
                       NoticeReport.Section(heading: "What went wrong", lines: [error.localizedDescription]),
                       NoticeReport.Section(heading: "What to try", lines: [
                           "Choose a sound file macOS can play, such as WAV, AIFF, MP3 or AAC (M4A).",
                       ]),
                   ]))
        }
    }

    func useGuitarRiff(for id: UUID) {
        edit("Choose Sound") { $0.update(id) { $0.audio = nil } }
    }

    /// A sound file as a clip: its channels mixed to one, at its own sample rate
    static func readSound(_ url: URL) throws -> AudioClip {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(min(Double(file.length), AudioClip.longest * format.sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer, frameCount: frames)
        guard let channels = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
        let count = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var samples = [Float](repeating: 0, count: count)
        for c in 0..<channelCount {
            for k in 0..<count { samples[k] += channels[c][k] / Float(channelCount) }
        }
        return AudioClip(name: url.deletingPathExtension().lastPathComponent, sampleRate: format.sampleRate, samples: samples)
    }

    // MARK: - SPICE

    /// Replaces the circuit with a SPICE netlist, drawn as a schematic (File ▸ Import ▸ SPICE Netlist…)
    func importSpice() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["cir", "net", "sp", "spi", "spice", "ckt"].compactMap { UTType(filenameExtension: $0) } + [.plainText]
        panel.message = "Choose a SPICE netlist: R, C, L, sources, diodes, transistors, controlled sources, coupled inductors and subcircuits are drawn (with the model files it includes)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let (imported, warnings) = try SpiceNetlist.circuit(from: text, include: SpiceNetlist.fileIncluder(deck: url))
            edit("Import SPICE Netlist") { $0 = imported }
            selection = []
            requestFit()
            let undo = undoAction("Import SPICE Netlist", leaving: circuit)
            if !warnings.isEmpty {
                notify(.warning, "Some of the netlist was left out",
                       detail: "\(url.lastPathComponent) was drawn without \(warnings.count == 1 ? "one thing" : "\(warnings.count) things") in it.",
                       report: NoticeReport([NoticeReport.Section(heading: "Left out", lines: warnings)]),
                       actions: [undo])
            } else {
                let parts = imported.elements.filter { ![.wire, .ground, .netLabel].contains($0.kind) }.count
                notify(.success, "Imported \(url.lastPathComponent)",
                       detail: "\(parts) \(parts == 1 ? "part" : "parts"), drawn as a schematic.", actions: [undo])
            }
        } catch {
            notify(.failure, "That netlist can't be imported", detail: "\(url.lastPathComponent): \(error)",
                   report: NoticeReport([
                       NoticeReport.Section(heading: "What went wrong", lines: ["\(error)"]),
                       NoticeReport.Section(heading: "What to try", lines: [
                           "Check that the file is a SPICE netlist, one part or command per line, saved as plain text (UTF-8).",
                           "Files it includes (.include, .lib) by a relative path are looked for in its folder: keep them beside it.",
                           "A maker's model file on its own goes into the library with File ▸ Import ▸ Maker's Model….",
                       ]),
                   ]))
        }
    }

    /// Imports a subcircuit of a maker's model file into the block library with the file's provenance (File ▸ Import ▸
    /// Maker's Model); an op-amp's (five pins, in a model's usual order) figures are measured, to be set beside its
    /// datasheet's
    func importMakerModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["lib", "mod", "cir", "sub", "inc", "sp", "spi", "spice", "ckt", "txt"]
            .compactMap { UTType(filenameExtension: $0) } + [.plainText]
        panel.message = "Choose a maker's SPICE model file (.lib, .mod, .cir): one of its subcircuits becomes a block in the library"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let text = MakerModels.text(of: data) else { throw MakerModels.ImportError.unreadable }
            let subcircuits = MakerModels.subcircuits(in: text)
            guard let first = subcircuits.first else { throw MakerModels.ImportError.noSubcircuit }
            var chosen = first.name
            if subcircuits.count > 1 {
                let alert = NSAlert()
                alert.messageText = "Which subcircuit?"
                alert.informativeText = "\(url.lastPathComponent) defines \(subcircuits.count) subcircuits."
                let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
                popup.addItems(withTitles: subcircuits.map { "\($0.name) (\($0.pins.joined(separator: " ")))" })
                alert.accessoryView = popup
                alert.addButton(withTitle: "Import")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                chosen = subcircuits[popup.indexOfSelectedItem].name
            }
            let (block, warnings) = try MakerModels.block(from: data, file: url.lastPathComponent, subcircuit: chosen,
                                                           include: SpiceNetlist.fileIncluder(deck: url))
            try BlockLibrary.save(block)
            reloadBlockLibrary()
            let summary = "\(block.name) is in the library's Blocks, its pins \((block.source?.pins ?? []).joined(separator: ", "))."
            var sections = [NoticeReport.Section(heading: nil, lines: [summary])]
            if let header = block.source?.header, !header.isEmpty {
                sections.append(NoticeReport.Section(heading: "From the file's header", lines: Array(header.prefix(6)), tabular: true))
            }
            if let pins = block.source?.pins, pins.count == 5, let figures = try? MakerModels.measureOpAmp(block, pins: pins) {
                sections.append(NoticeReport.Section(heading: "Measured as an op-amp at ±15 V, to set beside its datasheet:",
                                                     lines: figures.lines, tabular: true))
            }
            if !warnings.isEmpty { sections.append(NoticeReport.Section(heading: "Left out:", lines: warnings)) }
            notify(warnings.isEmpty ? .success : .warning, "Imported \(block.name)",
                   detail: summary + (warnings.isEmpty ? "" : " Some of the model was left out."),
                   report: NoticeReport(sections))
        } catch {
            notify(.failure, "That model can't be imported", detail: "\(url.lastPathComponent): \(error)",
                   report: NoticeReport([
                       NoticeReport.Section(heading: "What went wrong", lines: ["\(error)"]),
                       NoticeReport.Section(heading: "What to try", lines: [
                           "Choose the maker's SPICE model file itself (.lib, .mod, .cir, saved as text): it should define a subcircuit with .SUBCKT … .ENDS.",
                           "Files it includes by a relative path are looked for in its folder: keep them beside it.",
                       ]),
                   ]))
        }
    }

    /// Downloads a part's model from its maker (File ▸ Import ▸ Download Maker's Model), saves it in the block library and shows
    /// its figures beside its datasheet's
    func downloadMakerModel(_ model: MakerModelCatalog.Model) {
        Task.detached(priority: .userInitiated) {
            var sections: [NoticeReport.Section] = []
            var summary = ""
            var leftOut = false
            var failure: String?
            do {
                let (block, warnings) = try MakerModelCatalog.download(model)
                try BlockLibrary.save(block)
                summary = "\(model.part) from \(model.maker), \(model.revision), is in the library's Blocks, its pins \((block.source?.pins ?? []).joined(separator: ", "))."
                sections.append(NoticeReport.Section(heading: nil, lines: [summary]))
                if let pins = block.source?.pins,
                   let figures = try? MakerModels.measureOpAmp(block, pins: pins, supply: model.supply, load: model.load,
                                                              slewGain: model.slewGain) {
                    sections.append(NoticeReport.Section(
                        heading: "Measured at ±\(Int(model.supply)) V into \(SI.format(model.load, unit: "Ω")), beside \(model.datasheet):",
                        lines: MakerModelCatalog.comparison(model, figures), tabular: true))
                }
                if !model.notes.isEmpty { sections.append(NoticeReport.Section(heading: nil, lines: model.notes)) }
                if !warnings.isEmpty {
                    sections.append(NoticeReport.Section(heading: "Left out:", lines: warnings))
                    leftOut = true
                }
            } catch {
                failure = "\(error)"
            }
            // (the main actor gets copies: a closure run elsewhere can't read these variables)
            let report = NoticeReport(sections)
            let message = failure, done = summary, omitted = leftOut
            await MainActor.run {
                self.reloadBlockLibrary()
                if let failure = message {
                    self.notify(.failure, "\(model.part) can't be downloaded", detail: failure,
                                report: NoticeReport([
                                    NoticeReport.Section(heading: "What went wrong", lines: [failure]),
                                    NoticeReport.Section(heading: "What to try", lines: [
                                        "The model is downloaded from \(model.maker)'s website: check the Internet connection and try again. Once downloaded it is kept, so this is needed only once.",
                                    ]),
                                ]),
                                actions: [Notice.Action("Try Again") { [weak self] in self?.downloadMakerModel(model) }])
                } else {
                    self.notify(omitted ? .warning : .success, "Downloaded \(model.part)",
                                detail: done + (omitted ? " Some of the model was left out." : ""), report: report)
                }
            }
        }
    }

    /// Writes the circuit as a SPICE deck (File ▸ Export ▸ SPICE Netlist…)
    func exportSpice() {
        let save = NSSavePanel()
        save.allowedContentTypes = [UTType(filenameExtension: "cir") ?? .plainText]
        let title = canvas?.window?.title ?? "Circuit"
        save.nameFieldStringValue = title + ".cir"
        guard save.runModal() == .OK, let url = save.url else { return }
        do {
            try SpiceNetlist.export(circuit, title: title).write(to: url, atomically: true, encoding: .utf8)
            notify(.success, "Exported \(url.lastPathComponent)", detail: "A SPICE netlist of the circuit.",
                   actions: [.showInFinder(url)])
        } catch {
            notify(.failure, "The netlist couldn't be written", detail: error.localizedDescription)
        }
    }

    /// Saves a board's printable sheet: an SVG at true size, which `make` draws with the window's title
    func exportBoardSheet(_ make: (String) -> String, board: String) {
        let save = NSSavePanel()
        save.allowedContentTypes = [UTType(filenameExtension: "svg") ?? .plainText]
        let title = canvas?.window?.title ?? "Circuit"
        save.nameFieldStringValue = "\(title) \(board).svg"
        guard save.runModal() == .OK, let url = save.url else { return }
        do {
            try make(title).write(to: url, atomically: true, encoding: .utf8)
            notify(.success, "Exported \(url.lastPathComponent)", detail: "The \(board) sheet, at true size to print.",
                   actions: [.showInFinder(url)])
        } catch {
            notify(.failure, "The sheet couldn't be written", detail: error.localizedDescription)
        }
    }

    /// Writes the circuit as a KiCad netlist, for a printed circuit board (File ▸ Export ▸ KiCad Netlist…)
    func exportKiCad() {
        let save = NSSavePanel()
        save.allowedContentTypes = [UTType(filenameExtension: "net") ?? .plainText]
        let title = canvas?.window?.title ?? "Circuit"
        save.nameFieldStringValue = title + ".net"
        guard save.runModal() == .OK, let url = save.url else { return }
        let export = KiCadNetlist.export(circuit, title: title)
        do {
            try export.text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            notify(.failure, "The netlist couldn't be written", detail: error.localizedDescription)
            return
        }
        guard !export.unassigned.isEmpty || !export.notes.isEmpty else {
            notify(.success, "Exported \(url.lastPathComponent)", detail: "A KiCad netlist, for a printed circuit board.",
                   actions: [.showInFinder(url)])
            return
        }
        let footprints = export.unassigned.isEmpty ? [] : ["JSpice doesn't know a footprint for \(export.unassigned.joined(separator: ", ")). Assign them in KiCad's PCB editor after importing the netlist."]
        notify(.warning, export.unassigned.isEmpty ? "Before laying out the board" : "Some parts need footprints",
               detail: "\(url.lastPathComponent) was written. " + (footprints.first ?? "Read the notes before laying out the board."),
               report: NoticeReport((footprints + export.notes).map { NoticeReport.Section(heading: nil, lines: [$0]) }),
               actions: [.showInFinder(url)])
    }

    /// Saves the circuit where the JSpice Audio Unit finds it, as a preset of its effect or instrument
    /// (File ▸ Export ▸ Audio Unit…)
    func exportAudioUnit() {
        let effect = PluginLibrary.effect(circuit) != nil, instrument = PluginLibrary.instrument(circuit) != nil
        guard effect || instrument else {
            notify(.warning, "This circuit can't play in a music app yet",
                   detail: "An Audio Unit needs a speaker to listen to, and an Audio In part (or one sine source) to take the track's sound as an effect, or keyboard sources to play notes as an instrument.")
            return
        }
        let ask = NSAlert()
        ask.messageText = "Export as Audio Unit"
        ask.informativeText = "The circuit appears in your music app as a preset of “JSpice: Circuit \(instrument ? "Instrument" : "Effect")”, its knobs and switches as the plugin's parameters. Name:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = canvas?.window?.title ?? "Circuit"
        ask.accessoryView = field
        ask.addButton(withTitle: "Export")
        ask.addButton(withTitle: "Cancel")
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(PluginLibrary.folder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent((name.isEmpty ? "Circuit" : name) + ".jspice")
            try JSONEncoder().encode(circuit).write(to: url)
            // let the system know about the extension inside this copy of the app
            if let plugIn = Bundle.main.builtInPlugInsURL?.appendingPathComponent("JSpiceAudioUnit.appex"),
               FileManager.default.fileExists(atPath: plugIn.path) {
                let register = Process()
                register.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
                register.arguments = ["-a", plugIn.path]
                try? register.run()
            }
            let plugin = "JSpice: Circuit \(instrument ? "Instrument" : "Effect")"
            notify(.success, "Exported “\(url.deletingPathExtension().lastPathComponent)”",
                   detail: "In your music app, add the Audio Unit “\(plugin)” and choose this circuit from its presets.",
                   report: NoticeReport(text: "In your music app (Logic, GarageBand, Ableton Live, …), add the Audio Unit “\(plugin)” and choose this circuit from its presets or its window. Circuits are kept in ~/\(PluginLibrary.folder)."),
                   actions: [.showInFinder(url)])
        } catch {
            notify(.failure, "The circuit couldn't be exported", detail: error.localizedDescription)
        }
    }

    /// Renders the circuit's speaker to a WAV file, offline, for as long as asked (File ▸ Export ▸ Sound…)
    func exportSound() {
        guard let speaker = circuit.elements.firstIndex(where: { $0.kind == .speaker }) else {
            notify(.warning, "There is no speaker to record",
                   detail: "Put a speaker across the output you want to hear, then export again.")
            return
        }
        let ask = NSAlert()
        ask.messageText = "Export Sound"
        ask.informativeText = "Renders the speaker's sound to a WAV file (48 kHz, 24 bits), simulating as long as it takes. Seconds of sound:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = "10"
        ask.accessoryView = field
        ask.addButton(withTitle: "Export…")
        ask.addButton(withTitle: "Cancel")
        guard ask.runModal() == .alertFirstButtonReturn, let seconds = SI.parse(field.stringValue), seconds > 0, seconds <= 600 else { return }
        let save = NSSavePanel()
        save.allowedContentTypes = [.wav]
        save.nameFieldStringValue = (canvas?.window?.title ?? "Circuit") + ".wav"
        guard save.runModal() == .OK, let url = save.url else { return }
        let circuit = self.circuit
        // knobs moving by themselves move in the sound too
        let knobs = knobMotionsFromHere
        Task.detached(priority: .userInitiated) {
            let result = AudioRender.render(circuit, output: speaker, duration: seconds, knobs: knobs)
            let problem: String?
            do {
                try WAV.encode(result.samples, sampleRate: result.sampleRate).write(to: url)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
            let length = Double(result.samples.count) / result.sampleRate, clipped = result.clipped
            await MainActor.run {
                if let problem {
                    self.notify(.failure, "The sound couldn't be written",
                                detail: "\(url.lastPathComponent): \(problem) Check that the folder can be written to and the disk has room, then export again.")
                } else {
                    let limited = clipped > 0 ? String(format: " %.1f %% of it went over the speaker's full scale and was softly limited.", clipped * 100) : ""
                    self.notify(clipped > 0 ? .warning : .success, "Sound exported",
                                detail: String(format: "%.1f seconds written to %@.", length, url.lastPathComponent) + limited,
                                actions: [.showInFinder(url)])
                }
            }
        }
    }

    /// Moves the selection by whole grid units (arrow keys)
    func nudgeSelection(by delta: GridPoint) {
        guard !selection.isEmpty else { return }
        let ids = selection
        edit("Move") { $0.move(ids, by: delta) }
    }

    /// Copies the selection a little down and to the right, and selects the copies
    func duplicateSelection() {
        let elements = circuit.elements.filter { selection.contains($0.id) }
        guard !elements.isEmpty else { return }
        var ids = Set<UUID>()
        edit(elements.count == 1 ? "Duplicate" : "Duplicate \(elements.count) Parts") { circuit in
            for var element in elements {
                element.id = UUID()
                element.a = element.a + GridPoint(2, 2)
                element.b = element.b + GridPoint(2, 2)
                // a net label's name is its connection, so it keeps it; parts get a new name
                if element.kind != .netLabel { element.name = "" }
                ids.insert(circuit.add(element))
            }
        }
        selection = ids
    }

    /// Selects the next part (or the previous one) in reading order: Tab and ⇧Tab
    func selectNext(backward: Bool) {
        let parts = circuit.elements
            .filter { $0.kind != .wire }
            .sorted { (min($0.a.y, $0.b.y), min($0.a.x, $0.b.x)) < (min($1.a.y, $1.b.y), min($1.a.x, $1.b.x)) }
        guard !parts.isEmpty else { return }
        let current = selection.count == 1 ? parts.firstIndex { selection.contains($0.id) } : nil
        let next: Int
        if let current {
            next = (current + (backward ? -1 : 1) + parts.count) % parts.count
        } else {
            next = backward ? parts.count - 1 : 0
        }
        selection = [parts[next].id]
    }

    /// Switches are operated while simulating, like the real thing, so this is not an undoable edit
    func toggleSwitch(_ id: UUID) {
        var next = circuit
        next.update(id) { $0.closed.toggle() }
        document.circuit = next
    }

    func setPressed(_ id: UUID, _ pressed: Bool) {
        var next = circuit
        next.update(id) { $0.closed = pressed }
        if next != circuit { document.circuit = next }
    }

    /// Makes a generic symbol behave like a real part: sets all of the model's parameters as one undo step (an op-amp
    /// running another part's maker's model goes back to JSpice's own)
    func applyModel(_ id: UUID, _ model: PartModel) {
        edit("Use \(model.name)") { circuit in
            circuit.update(id) { element in
                for (key, value) in model.values { element[param: key] = value }
                if element.kind == .opAmp && element.block != nil {
                    element.params["makerModel"] = nil
                    element.block = nil
                }
            }
        }
    }

    /// Gives each of several parts `model` (those of a kind that has it), as one undo step, as `applyModel(_:_:)` does
    /// for one
    func applyModel(_ ids: Set<UUID>, _ model: PartModel) {
        let targets = MultiEdit.parts(ids, in: circuit).filter { part in part.kind.models.contains { $0.name == model.name } }
        guard !targets.isEmpty else { return }
        edit(targets.count == 1 ? "Use \(model.name)" : "Use \(model.name) for \(targets.count) Parts") { circuit in
            for target in targets {
                circuit.update(target.id) { element in
                    for (key, value) in model.values { element[param: key] = value }
                    if element.kind == .opAmp && element.block != nil {
                        element.params["makerModel"] = nil
                        element.block = nil
                    }
                }
            }
        }
    }

    /// Runs an op-amp on its maker's model (`MakerModelCatalog`, downloaded from the maker once), or back on JSpice's own
    func useMakerModel(_ id: UUID, _ on: Bool) {
        guard let element = circuit.elements.first(where: { $0.id == id }), element.kind == .opAmp else { return }
        guard on else {
            edit("Use JSpice's Op-Amp Model") { circuit in
                circuit.update(id) { element in
                    element.params["makerModel"] = nil
                    element.block = nil
                }
            }
            return
        }
        guard let name = element.model?.name, let model = MakerModelCatalog.model(forBuiltIn: name) else { return }
        makerModelLoading.insert(id)
        Task.detached(priority: .userInitiated) {
            let result = Result { try MakerModelCatalog.download(model).block }
            await MainActor.run {
                self.makerModelLoading.remove(id)
                switch result {
                case let .success(block):
                    self.edit("Use \(model.maker)'s \(model.part) Model") { circuit in
                        circuit.update(id) { element in
                            element.block = block
                            element[param: "makerModel"] = 1
                        }
                    }
                case let .failure(error):
                    self.notify(.failure, "\(model.part)'s model can't be downloaded from \(model.maker)", detail: "\(error)",
                                report: NoticeReport([
                                    NoticeReport.Section(heading: "What went wrong", lines: ["\(error)"]),
                                    NoticeReport.Section(heading: "What to try", lines: [
                                        "Check the Internet connection and try again: once downloaded the model is kept. Until then the op-amp runs on JSpice's own model.",
                                    ]),
                                ]),
                                actions: [Notice.Action("Try Again") { [weak self] in self?.useMakerModel(id, true) }])
                }
            }
        }
    }

    /// Potentiometers are turned while simulating, like a knob, so this is not an undoable edit
    func turnPotentiometer(_ id: UUID, by delta: Double) {
        var next = circuit
        next.update(id) { $0[param: "position"] = min(1, max(0, $0[param: "position"] + delta)) }
        if next != circuit { document.circuit = next }
    }

    // MARK: - Knobs moving by themselves

    /// Knobs moving back and forth by themselves, as a foot rocks a wah pedal: live, like a knob turned by hand or by
    /// MIDI, so not undoable edits. Each goes back where it was when it stops.
    @Published private(set) var knobMotions: [KnobMotion] = []
    private var motionStarts: [KnobID: Date] = [:]
    private var motionRests: [KnobID: Double] = [:]
    private var motionTimer: Timer?

    func motion(of knob: KnobID) -> KnobMotion? { knobMotions.first { $0.knob == knob } }

    /// Starts a knob moving from where it is, or changes how it moves
    func startMoving(_ knob: KnobID, period: Double, low: Double = 0, high: Double = 1) {
        guard let position = circuit.position(of: knob) else { return }
        if motionRests[knob] == nil { motionRests[knob] = position }
        knobMotions.removeAll { $0.knob == knob }
        knobMotions.append(KnobMotion(knob: knob, period: period, low: low, high: high, from: position))
        motionStarts[knob] = Date()
        if motionTimer == nil {
            // 30 moves a second, also while a menu is open or a slider dragged
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                MainActor.assumeIsolated { self.moveKnobs() }
            }
            RunLoop.main.add(timer, forMode: .common)
            motionTimer = timer
        }
    }

    /// Stops a knob, back where it was before it started
    func stopMoving(_ knob: KnobID) {
        knobMotions.removeAll { $0.knob == knob }
        motionStarts[knob] = nil
        if let rest = motionRests.removeValue(forKey: knob) {
            var next = circuit
            if next.turn(knob, to: rest) { document.circuit = next }
        }
        if knobMotions.isEmpty {
            motionTimer?.invalidate()
            motionTimer = nil
        }
    }

    /// The moving knobs as they would move from now: from where each is, for an offline render
    var knobMotionsFromHere: [KnobMotion] {
        knobMotions.compactMap { motion in
            circuit.position(of: motion.knob).map {
                KnobMotion(knob: motion.knob, period: motion.period, low: motion.low, high: motion.high, from: $0)
            }
        }
    }

    private func moveKnobs() {
        // a knob deleted with its part stops
        for motion in knobMotions where circuit.position(of: motion.knob) == nil { stopMoving(motion.knob) }
        var next = circuit
        let now = Date()
        var moved = false
        for motion in knobMotions {
            guard let start = motionStarts[motion.knob] else { continue }
            if next.turn(motion.knob, to: motion.position(at: now.timeIntervalSince(start))) { moved = true }
        }
        if moved { document.circuit = next }
    }

    // MARK: - MIDI

    struct MIDITarget: Hashable {
        var part: UUID
        var inner: UUID?
    }

    /// Waits for the next MIDI controller moved, to map it to this control; asked again, stops waiting
    func learnMIDI(part: UUID, inner: UUID? = nil) {
        let target = MIDITarget(part: part, inner: inner)
        midiLearning = midiLearning == target ? nil : target
    }

    func forgetMIDI(part: UUID, inner: UUID? = nil) {
        edit("Forget MIDI Controller") { $0.forgetMIDI(part: part, inner: inner) }
    }

    /// A control change from a MIDI device: learned by the control waiting for one, or moving the controls mapped to it
    /// (live, like turning a knob by hand, so not an undoable edit)
    func midiControlChange(channel: Int, controller: Int, value: Int) {
        if let target = midiLearning {
            midiLearning = nil
            edit("Learn MIDI Controller") {
                $0.learnMIDI(controller: controller, channel: nil, part: target.part, inner: target.inner)
                $0.applyControlChange(controller: controller, channel: channel, value: value)
            }
            return
        }
        // a controller sweeping sends dozens of changes a second: they are applied together, once per turn of the run
        // loop, so the circuit is copied and the simulation updated once for all of them
        if pendingControlChanges.isEmpty {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.applyPendingControlChanges() }
            }
        }
        pendingControlChanges.append((channel, controller, value))
    }

    private var pendingControlChanges: [(channel: Int, controller: Int, value: Int)] = []

    private func applyPendingControlChanges() {
        let changes = pendingControlChanges
        pendingControlChanges = []
        var next = circuit
        var changed = false
        for change in changes {
            if next.applyControlChange(controller: change.controller, channel: change.channel, value: change.value) { changed = true }
        }
        if changed && next != circuit { document.circuit = next }
    }

    // MARK: - Microcontrollers

    func setSketchCode(_ id: UUID, _ code: String) {
        edit("Edit Sketch") { $0.update(id) { $0.code = code } }
    }

    /// The sketch builds running, by part: each one's monitor (to cancel it), and an id that tells its reports and
    /// result from those of a build started later
    private var sketchBuilds: [UUID: (id: UUID, monitor: SketchBuilder.BuildMonitor)] = [:]

    /// Compiles the sketch off the main thread and, if it builds, loads it into the chip, which restarts. The status
    /// follows the build's steps; `cancelUpload` stops it.
    func uploadSketch(_ id: UUID, code: String) {
        let board = circuit[id]?.kind.board ?? .uno
        // (an STM32 compiles nothing here: its firmware is built elsewhere, and loaded)
        guard let family = board.sketchFamily else {
            loadFirmware(id)
            return
        }
        // (one build at a time for each part: ⌘U while one runs does nothing)
        guard sketchBuilds[id] == nil else { return }
        guard ChipSupport.isAvailable(family) else {
            let problem = ChipSupportModel.shared.isBusy(family)
                ? "Chip support for the \(board.chip) is still installing: Upload again once it is done."
                : SketchBuilder.missingToolchainMessage(board)
            sketchStatus[id] = .failed(SketchFailure(problem: problem))
            if circuit[id]?.code != code { setSketchCode(id, code) }
            // (the sketch editor installs it itself: a second sheet cannot open over it)
            if editingSketch == nil { showChipSupport = true }
            return
        }
        let chip = circuit[id].flatMap { board.avrVariant(for: $0) }
        let build = UUID()
        let monitor = SketchBuilder.BuildMonitor { [weak self] step in
            Task { @MainActor in self?.sketchBuildProgressed(id, build, step) }
        }
        sketchBuilds[id] = (build, monitor)
        sketchStatus[id] = .building(step: "Starting", fraction: nil)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                SketchBuilder.build(code, board: board, chip: chip, monitor: monitor)
            }.value
            self?.finishUpload(id, build: build, code: code, result: result)
        }
    }

    /// Stops the part's sketch build, if one is running
    func cancelUpload(_ id: UUID) {
        sketchBuilds[id]?.monitor.cancel()
    }

    private func sketchBuildProgressed(_ id: UUID, _ build: UUID, _ step: SketchBuilder.BuildProgress) {
        guard sketchBuilds[id]?.id == build else { return }
        sketchStatus[id] = .building(step: step.message, fraction: step.fraction)
    }

    private func finishUpload(_ id: UUID, build: UUID, code: String, result: SketchBuilder.Result) {
        guard sketchBuilds[id]?.id == build else { return }
        sketchBuilds[id] = nil
        guard let firmware = result.firmware else {
            let status: SketchStatus = result.wasCancelled ? .cancelled
                : .failed(SketchFailure(errors: result.errors, warnings: result.warnings, problem: result.problem, log: result.log))
            sketchStatus[id] = status
            if circuit[id]?.code != code { setSketchCode(id, code) }
            return
        }
        let unchanged = circuit[id]?.firmware == firmware
        edit("Upload Sketch") { $0.update(id) { element in
            element.code = code
            element.firmware = firmware
        } }
        // the same firmware again: restart the chip, as uploading to a board does
        if unchanged, let index = circuit.index(of: id) { simulation.resetChip(index) }
        sketchStatus[id] = .uploaded(bytes: firmware.count, warnings: result.warnings)
    }

    /// Loads a firmware file a toolchain built (Intel HEX, or a raw image) into a microcontroller part, which restarts
    func loadFirmware(_ id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["hex", "ihex", "bin"].compactMap { UTType(filenameExtension: $0) } + [.data]
        panel.message = "Choose firmware: an Intel HEX file (.hex) or a raw flash image (.bin)"
        guard panel.runModal() == .OK, let url = panel.url, let element = circuit[id] else { return }
        do {
            // (the decoder refuses a file that is not Intel HEX it can read, or whose records span far more than any
            // flash, before making an image of it)
            let firmware = try FirmwareFile.decode(try Data(contentsOf: url))
            let room = element.kind.board?.flashSize(for: element) ?? firmware.count
            guard firmware.count <= room else {
                throw FirmwareTooLarge(bytes: firmware.count, room: room, chip: element.kind.board?.chip ?? "chip")
            }
            let unchanged = element.firmware == firmware
            edit("Load Firmware") { $0.update(id) { $0.firmware = firmware } }
            if unchanged, let index = circuit.index(of: id) { simulation.resetChip(index) }
            sketchStatus[id] = .uploaded(bytes: firmware.count, warnings: [])
        } catch {
            let alert = NSAlert()
            alert.messageText = "\(url.lastPathComponent) can't be loaded"
            alert.informativeText = Self.firmwareProblem(error)
            alert.runModal()
        }
    }

    /// What went wrong loading a firmware file, as a sentence
    private static func firmwareProblem(_ error: Error) -> String {
        let text: String
        switch error {
        case let error as FirmwareFile.DecodeError: text = error.description
        case let error as FirmwareTooLarge: text = error.description
        default: text = error.localizedDescription
        }
        guard let first = text.first else { return "" }
        let sentence = first.uppercased() + text.dropFirst()
        return sentence.hasSuffix(".") ? sentence : sentence + "."
    }

    private struct FirmwareTooLarge: Error, CustomStringConvertible {
        let bytes: Int, room: Int, chip: String
        var description: String { "It takes \(bytes) bytes; the \(chip)'s flash has room for \(room)." }
    }

    /// The selected part, if it is a microcontroller
    var selectedMicrocontroller: Element? {
        selectedElement.flatMap { $0.kind.isMicrocontroller ? $0 : nil }
    }

    func setParameter(_ id: UUID, _ spec: ParamSpec, to value: Double) {
        edit("Change \(spec.name)") { $0.update(id) { $0[param: spec.key] = value } }
    }

    /// Sets one parameter of several parts at once (those of a kind that has it: the inspector's multi-selection), as
    /// one undo step, named as for one part (`restore` reads "Wiper position" at the end of the name)
    func setParameter(_ ids: Set<UUID>, _ spec: ParamSpec, to value: Double) {
        edit("Change \(spec.name)") { MultiEdit.set(spec.key, to: value, of: ids, in: &$0) }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        edit("Rename") { $0.update(id) { $0.name = trimmed } }
    }

    func addScope(_ id: UUID, _ quantity: Quantity, plot: ScopePlot = .time) {
        edit("Add Scope") { $0.scopes.append(ScopeSpec(elementID: id, quantity: quantity, plot: plot)) }
    }

    func setScopePlot(_ id: UUID, _ plot: ScopePlot) {
        edit("Change Scope") { circuit in
            if let i = circuit.scopes.firstIndex(where: { $0.id == id }) { circuit.scopes[i].plot = plot }
        }
    }

    func setScopeSource(_ id: UUID, _ sourceID: UUID?) {
        edit("Change Scope") { circuit in
            if let i = circuit.scopes.firstIndex(where: { $0.id == id }) { circuit.scopes[i].sourceID = sourceID }
        }
    }

    func removeScope(_ id: UUID) {
        edit("Remove Scope") { $0.scopes.removeAll { $0.id == id } }
    }

    func setScopeQuantity(_ id: UUID, _ quantity: Quantity) {
        edit("Change Scope") { circuit in
            if let i = circuit.scopes.firstIndex(where: { $0.id == id }) { circuit.scopes[i].quantity = quantity }
        }
    }

    /// The step sequence as it is, or an empty eight-step one, stopped
    var sequence: StepSequence {
        circuit.sequence ?? StepSequence(steps: Array(repeating: nil, count: 8), playing: false)
    }

    func updateSequence(_ actionName: String, _ change: (inout StepSequence) -> Void) {
        var next = sequence
        change(&next)
        edit(actionName) { $0.sequence = next }
    }

    /// A change made while dragging a slider: one undo step when the drag ends
    func updateSequenceDuringInteraction(_ change: (inout StepSequence) -> Void) {
        beginInteraction()
        var next = circuit
        var sequence = self.sequence
        change(&sequence)
        next.sequence = sequence
        setDuringInteraction(next)
    }

    func updateSettings(_ change: (inout SimulationSettings) -> Void) {
        edit("Change Simulation Settings") { change(&$0.settings) }
    }

    /// Changes a setting from a slider: the whole drag becomes one undo step in `endInteraction`
    func updateSettingsDuringInteraction(_ change: (inout SimulationSettings) -> Void) {
        beginInteraction()
        var next = circuit
        change(&next.settings)
        setDuringInteraction(next)
    }

    func load(_ example: Example) {
        edit("Open \(example.title)") { $0 = example.circuit }
        selection = []
        tool = nil
        simulation.load(example.circuit)
        simulation.reset()
        simulation.setRunning(true)
        requestFit()
    }

    /// Opens an example without losing work: in this window when it is empty (as from the welcome view), otherwise in
    /// a new document window, which starts running and fitted to the circuit as every newly opened window does
    func open(_ example: Example, newDocument: NewDocumentAction) {
        if circuit.elements.isEmpty {
            load(example)
        } else {
            ExampleGalleryView.openInNewWindow(example, newDocument: newDocument)
        }
    }

    func requestFit() {
        viewAdjusted = false
        fitRequest += 1
    }

    /// Redraws the circuit as a tidy schematic, keeping every connection
    func tidyUp() {
        guard let next = try? SchematicLayout.tidy(circuit) else { return }
        edit("Tidy Up") { $0 = next }
        selection = []
        requestFit()
    }

    // MARK: - AI control

    /// A change made by an AI agent through the MCP bridge: one undoable step, shown running
    func applyAutomation(_ next: Circuit, _ action: String) {
        let wasEmpty = circuit.elements.isEmpty
        let rebuilt = Set(next.elements.map(\.id)).isDisjoint(with: circuit.elements.map(\.id))
        edit(action) { $0 = next }
        selection = selection.filter { next[$0] != nil }
        if wasEmpty || rebuilt { requestFit() }
        simulation.setRunning(true)
    }

    // MARK: - Export

    /// Saves the schematic as it appears now, as a PNG picture or a PDF drawing
    func exportImage() {
        guard let canvas, let window = canvas.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .pdf]
        panel.nameFieldStringValue = (window.title as NSString).deletingPathExtension + ".png"
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                let data: Data?
                if url.pathExtension.lowercased() == "pdf" {
                    data = canvas.dataWithPDF(inside: canvas.bounds)
                } else if let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) {
                    canvas.cacheDisplay(in: canvas.bounds, to: rep)
                    data = rep.representation(using: .png, properties: [:])
                } else {
                    data = nil
                }
                do {
                    guard let data else { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: url)
                    self.notify(.success, "Exported \(url.lastPathComponent)",
                                detail: url.pathExtension.lowercased() == "pdf" ? "The schematic as a PDF drawing." : "The schematic as a PNG picture.",
                                actions: [.showInFinder(url)])
                } catch {
                    self.notify(.failure, "The image couldn't be saved", detail: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Clipboard

    func copySelection() {
        let elements = circuit.elements.filter { selection.contains($0.id) }
        guard !elements.isEmpty, let data = try? JSONEncoder().encode(elements) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.pasteboardType)
    }

    func cutSelection() {
        copySelection()
        deleteSelection()
    }

    /// True when the pasteboard holds parts copied from a circuit
    var canPaste: Bool {
        NSPasteboard.general.availableType(from: [Self.pasteboardType]) != nil
    }

    /// Pastes under the pointer when it is over the canvas, else in the middle of what the canvas shows
    func paste() {
        paste(at: (canvas as? CircuitCanvasView)?.pasteTarget)
    }

    /// Pastes the copied parts centred on `target` (a grid point), keeping their places relative to each other; with no
    /// target, a little down and to the right of where they were copied from
    func paste(at target: GridPoint?) {
        guard let data = NSPasteboard.general.data(forType: Self.pasteboardType),
              let copied = try? JSONDecoder().decode([Element].self, from: data), !copied.isEmpty else { return }
        var elements = copied
        if let target {
            elements = CanvasGeometry.placed(copied, centredAt: target)
        } else {
            for i in elements.indices {
                elements[i].a = elements[i].a + GridPoint(2, 2)
                elements[i].b = elements[i].b + GridPoint(2, 2)
            }
        }
        var ids = Set<UUID>()
        edit("Paste") { circuit in
            for var element in elements {
                element.id = UUID()
                // a net label's name is its connection, so it keeps it
                if element.kind != .netLabel && circuit.elements.contains(where: { $0.name == element.name }) { element.name = "" }
                ids.insert(circuit.add(element))
            }
        }
        selection = ids
    }

    // MARK: - Wiring and values on the canvas

    /// Draws a wire of one or two segments (an elbow) as one undo step, joining its ends to wires they land on
    @discardableResult
    func addWire(_ segments: [WireSegment]) -> [UUID] {
        var ids: [UUID] = []
        edit("Add Wire") { ids = $0.addWire(segments) }
        if !ids.isEmpty { RecentParts.shared.record(.wire) }
        return ids
    }

    /// The value a part shows on the canvas and can have typed in place there, if it has one
    func inlineValueSpec(of id: UUID) -> ParamSpec? {
        circuit[id]?.kind.inlineValueParam
    }

    /// Sets a part's in-place value from typed text, as the inspector reads it ("4k7", "10u", "2.2 MΩ"): one undo step.
    /// False when the text is not a value.
    @discardableResult
    func setInlineValue(_ id: UUID, from text: String) -> Bool {
        guard let spec = inlineValueSpec(of: id), let value = SI.parse(text) else { return false }
        if circuit[id]?[param: spec.key] != value { setParameter(id, spec, to: value) }
        return true
    }

    // MARK: - Zoom

    func changeZoom(by factor: CGFloat, around point: CGPoint? = nil) {
        viewAdjusted = true
        let anchor = point ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let newZoom = min(4, max(0.3, zoom * factor))
        let applied = newZoom / zoom
        pan = CGPoint(x: anchor.x - (anchor.x - pan.x) * applied, y: anchor.y - (anchor.y - pan.y) * applied)
        zoom = newZoom
    }
}

/// The circuit drawn as a schematic, or as it would be built
enum BoardKind: String, CaseIterable, Identifiable {
    case schematic = "Schematic", breadboard = "Breadboard", stripboard = "Stripboard", perfboard = "Perfboard"
    var id: Self { self }
}
