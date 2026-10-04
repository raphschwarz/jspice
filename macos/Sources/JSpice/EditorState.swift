import AppKit
import SwiftUI
import CircuitKit

/// Everything about one open circuit window: the selected tool and parts, the view's zoom and scroll position, and
/// every edit, so each one can be undone.
@MainActor
final class EditorState: ObservableObject {
    let document: CircuitDocument
    let simulation: SimulationController
    weak var undoManager: UndoManager?

    /// The part being placed, or nil for selecting and moving
    @Published var tool: ElementKind?
    @Published var selection: Set<UUID> = []
    @Published var hovered: UUID?
    @Published var zoom: CGFloat = 1.25
    @Published var pan = CGPoint(x: 120, y: 120)
    @Published var showValues = true
    @Published var showCurrent = true
    @Published var showInspector = true
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
        document.circuit = circuit
        selection = selection.filter { circuit[$0] != nil }
        registerUndo(restoring: current, actionName: actionName)
    }

    // MARK: - Operations

    @discardableResult
    func add(_ element: Element) -> UUID {
        var id = element.id
        edit("Add \(element.kind.displayName)") { id = $0.add(element) }
        return id
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

    func selectAll() {
        selection = Set(circuit.elements.map(\.id))
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

    func setParameter(_ id: UUID, _ spec: ParamSpec, to value: Double) {
        edit("Change \(spec.name)") { $0.update(id) { $0[param: spec.key] = value } }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        edit("Rename") { $0.update(id) { $0.name = trimmed } }
    }

    func addScope(_ id: UUID, _ quantity: Quantity) {
        edit("Add Scope") { $0.scopes.append(ScopeSpec(elementID: id, quantity: quantity)) }
    }

    func removeScope(_ id: UUID) {
        edit("Remove Scope") { $0.scopes.removeAll { $0.id == id } }
    }

    func setScopeQuantity(_ id: UUID, _ quantity: Quantity) {
        edit("Change Scope") { circuit in
            if let i = circuit.scopes.firstIndex(where: { $0.id == id }) { circuit.scopes[i].quantity = quantity }
        }
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
                if circuit.elements.contains(where: { $0.name == element.name }) { element.name = "" }
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
