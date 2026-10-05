import AppKit
import SwiftUI
import UniformTypeIdentifiers
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
    @Published var selection: Set<UUID> = []
    @Published var hovered: UUID?
    @Published var zoom: CGFloat = 1.25
    @Published var pan = CGPoint(x: 120, y: 120)
    @Published var showValues = true
    @Published var showCurrent = true
    @Published var showInspector = true
    /// The front panel of knobs and switches below the schematic
    @Published var showPanel = true
    /// The quick-add palette (⌘K or /): type a part's name to place it
    @Published var showQuickAdd = false
    /// The keyboard shortcuts sheet (⌘/ or ?)
    @Published var showShortcuts = false
    @Published var showChipSupport = false
    /// The microcontroller whose sketch is open in the sketch editor
    @Published var editingSketch: UUID?
    /// How each microcontroller's last upload went
    @Published var sketchStatus: [UUID: SketchStatus] = [:]
    /// Incremented to ask the canvas to fit the circuit in view
    @Published private(set) var fitRequest = 1

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
        tool = kind
        showQuickAdd = false
        if let canvas { canvas.window?.makeFirstResponder(canvas) }
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

    /// Makes a generic symbol behave like a real part: sets all of the model's parameters as one undo step
    func applyModel(_ id: UUID, _ model: PartModel) {
        edit("Use \(model.name)") { circuit in
            circuit.update(id) { element in
                for (key, value) in model.values { element[param: key] = value }
            }
        }
    }

    /// Potentiometers are turned while simulating, like a knob, so this is not an undoable edit
    func turnPotentiometer(_ id: UUID, by delta: Double) {
        var next = circuit
        next.update(id) { $0[param: "position"] = min(1, max(0, $0[param: "position"] + delta)) }
        if next != circuit { document.circuit = next }
    }

    // MARK: - Microcontrollers

    func setSketchCode(_ id: UUID, _ code: String) {
        edit("Edit Sketch") { $0.update(id) { $0.code = code } }
    }

    /// Compiles the sketch off the main thread and, if it builds, loads it into the chip, which restarts
    func uploadSketch(_ id: UUID, code: String) {
        let board = circuit[id]?.kind.board ?? .uno
        guard ChipSupport.isAvailable(board.family) else {
            showChipSupport = true
            return
        }
        sketchStatus[id] = .building
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                SketchBuilder.build(code, board: board)
            }.value
            self?.finishUpload(id, code: code, result: result)
        }
    }

    private func finishUpload(_ id: UUID, code: String, result: SketchBuilder.Result) {
        guard let firmware = result.firmware else {
            sketchStatus[id] = .failed(errors: result.errors, log: result.log)
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
        sketchStatus[id] = .uploaded(bytes: firmware.count)
    }

    /// The selected part, if it is a microcontroller
    var selectedMicrocontroller: Element? {
        selectedElement.flatMap { $0.kind.isMicrocontroller ? $0 : nil }
    }

    func setParameter(_ id: UUID, _ spec: ParamSpec, to value: Double) {
        edit("Change \(spec.name)") { $0.update(id) { $0[param: spec.key] = value } }
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

    func load(_ example: Example) {
        edit("Open \(example.title)") { $0 = example.circuit }
        selection = []
        tool = nil
        simulation.load(example.circuit)
        simulation.reset()
        simulation.setRunning(true)
        requestFit()
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
                } catch {
                    NSAlert(error: error).beginSheetModal(for: window)
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

    func paste() {
        guard let data = NSPasteboard.general.data(forType: Self.pasteboardType),
              let elements = try? JSONDecoder().decode([Element].self, from: data) else { return }
        var ids = Set<UUID>()
        edit("Paste") { circuit in
            for var element in elements {
                element.id = UUID()
                element.a = element.a + GridPoint(2, 2)
                element.b = element.b + GridPoint(2, 2)
                // a net label's name is its connection, so it keeps it
                if element.kind != .netLabel && circuit.elements.contains(where: { $0.name == element.name }) { element.name = "" }
                ids.insert(circuit.add(element))
            }
        }
        selection = ids
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
