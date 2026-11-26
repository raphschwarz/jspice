import AppKit
import Combine
import CircuitKit

// The schematic for VoiceOver and other assistive technology. The canvas draws everything itself, so on its own it is
// one blank view; here it becomes a group ("Schematic: 21 parts, running") with a child element for each part (wires and
// grounds are not children: what they join is told in each part's help, "between +9V and the base of Q1").
//
// Nothing here runs until an assistive app first asks the canvas for its children. The children are rebuilt only when
// the circuit's connections change (a signature of each element's kind, place, name and switch state) and are reused by
// id across rebuilds, so VoiceOver keeps its place; values (and live readings) are worked out when asked, and frames
// from the current pan and zoom each time they are asked, in screen coordinates.

/// One part of the schematic as an accessibility element
final class CanvasPartElement: NSAccessibilityElement {
    let partID: UUID
    let kind: ElementKind
    weak var canvas: CircuitCanvasView?

    init(partID: UUID, kind: ElementKind, canvas: CircuitCanvasView) {
        self.partID = partID
        self.kind = kind
        self.canvas = canvas
        super.init()
        setAccessibilityElement(true)
        setAccessibilityParent(canvas)
        setAccessibilityRole(CanvasAccessibility.role(for: kind))
        if kind == .toggleSwitch || kind == .footswitch || kind == .jack || kind == .pushButton {
            setAccessibilitySubrole(.toggle)
        }
        if kind == .potentiometer {
            setAccessibilityMinValue(NSNumber(value: 0))
            setAccessibilityMaxValue(NSNumber(value: 100))
        }
    }

    /// Where the part is on screen: the box round its terminals (thin two-terminal parts given their symbol's width)
    override func accessibilityFrame() -> NSRect {
        MainActor.assumeIsolated { () -> NSRect in
            guard let canvas, let window = canvas.window, let rect = canvas.accessibilityRect(of: partID) else { return .zero }
            // (the canvas is flipped: converting to the window's coordinates turns it the right way up)
            return window.convertToScreen(canvas.convert(rect, to: nil))
        }
    }

    override func accessibilityValue() -> Any? {
        let value = MainActor.assumeIsolated { () -> (number: Double?, text: String) in
            guard let canvas, let element = canvas.editor.circuit[partID] else { return (nil, "") }
            let text = canvas.accessibilityValueText(of: element)
            switch kind {
            case .potentiometer: return ((element[param: "position"] * 100).rounded(), text)
            case .toggleSwitch, .footswitch, .jack, .pushButton: return (element.closed ? 1 : 0, text)
            default: return (nil, text)
            }
        }
        if let number = value.number { return NSNumber(value: number) }
        return value.text
    }

    /// For the knob and the switches, whose value is a number: what it means, with the part's value and readings
    override func accessibilityValueDescription() -> String? {
        MainActor.assumeIsolated { () -> String? in
            guard let canvas, let element = canvas.editor.circuit[partID] else { return nil }
            switch kind {
            case .potentiometer, .toggleSwitch, .footswitch, .jack, .pushButton: return canvas.accessibilityValueText(of: element)
            default: return nil
            }
        }
    }

    /// Flips a switch, holds or lets go of a push button (it stays down until pressed again, so its effect can be
    /// heard and read), and selects any other part, so that the inspector edits it
    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated { () -> Bool in
            guard let canvas, let element = canvas.editor.circuit[partID] else { return false }
            let editor = canvas.editor
            switch element.kind {
            case .toggleSwitch, .footswitch, .jack:
                editor.toggleSwitch(partID)
            case .pushButton:
                editor.setPressed(partID, !element.closed)
            default:
                editor.selection = [partID]
                editor.showInspector = true
            }
            canvas.needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
            return true
        }
    }

    override func accessibilityPerformIncrement() -> Bool { turn(by: CanvasAccessibility.potentiometerStep) }

    override func accessibilityPerformDecrement() -> Bool { turn(by: -CanvasAccessibility.potentiometerStep) }

    private func turn(by delta: Double) -> Bool {
        MainActor.assumeIsolated { () -> Bool in
            guard kind == .potentiometer, let canvas else { return false }
            canvas.editor.turnPotentiometer(partID, by: delta)
            canvas.needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
            return true
        }
    }
}

/// What the canvas keeps for assistive apps, made the first time one asks
@MainActor
final class CanvasAccessibilityModel {
    var signature: Int?
    var children: [CanvasPartElement] = []
    var byID: [UUID: CanvasPartElement] = [:]
    var partIDs: Set<UUID> = []
    var subscriptions: Set<AnyCancellable> = []
}

/// The key the canvas's model is kept under (as an associated object: an extension cannot add a stored property)
private let canvasAccessibilityModelKey = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

/// (Pure functions, usable from the elements whatever actor AppKit puts them on)
enum CanvasAccessibility {
    /// How far one increment turns a potentiometer
    static let potentiometerStep = 0.05

    static func role(for kind: ElementKind) -> NSAccessibility.Role {
        switch kind {
        // switches are toggles (a check box with the toggle subrole, as a push-on push-off button is): VoiceOver says
        // whether they are on
        case .toggleSwitch, .footswitch, .jack, .pushButton: return .checkBox
        case .potentiometer: return .slider
        default: return .staticText
        }
    }

    /// Changes when what the parts are, where, or how they connect changes; not when a value or knob does
    static func structure(of circuit: Circuit) -> Int {
        var hasher = Hasher()
        hasher.combine(circuit.elements.count)
        for element in circuit.elements {
            hasher.combine(element.id)
            hasher.combine(element.kind)
            hasher.combine(element.a)
            hasher.combine(element.b)
            hasher.combine(element.name)
            hasher.combine(element.closed)
            hasher.combine(element.flipped)
            hasher.combine(element.block?.name)
        }
        return hasher.finalize()
    }

    /// The parts in reading order (top to bottom, then left to right), as Tab steps through them
    static func readingOrder(_ elements: [Element]) -> [Element] {
        elements.sorted { (min($0.a.y, $0.b.y), min($0.a.x, $0.b.x)) < (min($1.a.y, $1.b.y), min($1.a.x, $1.b.x)) }
    }
}

extension CircuitCanvasView {
    // MARK: - The canvas as a group

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityRoleDescription() -> String? { "schematic" }

    override func accessibilityLabel() -> String? {
        let status = editor.simulation.status
        let state = status.failed ? "stopped" : editor.simulation.isRunning ? "running" : "paused"
        return CircuitDescription.summary(of: editor.circuit, state: state)
    }

    override func accessibilityHelp() -> String? {
        "Each part is an element inside. Tab selects the next part, arrows move it; switches and knobs work with VoiceOver's press and adjust commands."
    }

    override func accessibilityChildren() -> [Any]? {
        accessibilityPartElements()
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        accessibilityPartElements().filter { editor.selection.contains($0.partID) }
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let window else { return self }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        guard let hit = element(at: local), CircuitDescription.isDescribed(hit) else { return self }
        _ = accessibilityPartElements()
        return accessibilityModel.byID[hit.id] ?? self
    }

    // MARK: - Children

    var accessibilityModel: CanvasAccessibilityModel {
        if let model = objc_getAssociatedObject(self, canvasAccessibilityModelKey) as? CanvasAccessibilityModel { return model }
        let model = CanvasAccessibilityModel()
        objc_setAssociatedObject(self, canvasAccessibilityModelKey, model, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        observeForAccessibility(model)
        return model
    }

    /// The parts' elements, rebuilt when the circuit's structure has changed since they were last asked for
    func accessibilityPartElements() -> [CanvasPartElement] {
        let model = accessibilityModel
        let circuit = editor.circuit
        let signature = CanvasAccessibility.structure(of: circuit)
        if model.signature != signature {
            model.signature = signature
            let words = CircuitDescription.connections(in: circuit)
            var byID: [UUID: CanvasPartElement] = [:]
            var children: [CanvasPartElement] = []
            for element in CanvasAccessibility.readingOrder(circuit.elements.filter(CircuitDescription.isDescribed)) {
                let child: CanvasPartElement
                if let existing = model.byID[element.id], existing.kind == element.kind {
                    child = existing
                } else {
                    child = CanvasPartElement(partID: element.id, kind: element.kind, canvas: self)
                }
                child.setAccessibilityLabel(CircuitDescription.spokenName(element))
                child.setAccessibilityHelp(words[element.id].map { String($0.prefix(1)).uppercased() + String($0.dropFirst()) })
                child.setAccessibilityCustomActions(accessibilityActions(for: element))
                byID[element.id] = child
                children.append(child)
            }
            model.byID = byID
            model.children = children
            model.partIDs = Set(byID.keys)
        }
        for child in model.children { child.setAccessibilitySelected(editor.selection.contains(child.partID)) }
        return model.children
    }

    /// What the part's menu offers besides operating it, for VoiceOver's actions menu
    private func accessibilityActions(for element: Element) -> [NSAccessibilityCustomAction] {
        let id = element.id
        var actions: [NSAccessibilityCustomAction] = []
        func add(_ name: String, _ action: @escaping (EditorState) -> Void) {
            actions.append(NSAccessibilityCustomAction(name: name) { [weak self] in
                MainActor.assumeIsolated { () -> Bool in
                    guard let self, self.editor.circuit[id] != nil else { return false }
                    action(self.editor)
                    self.needsDisplay = true
                    return true
                }
            })
        }
        if element.kind.isSwitch || element.kind == .potentiometer {
            add("Select") { editor in
                editor.selection = [id]
                editor.showInspector = true
            }
        }
        for quantity in scopeQuantities(for: element.kind) {
            add("Add \(quantity.name) Scope") { $0.addScope(id, quantity) }
        }
        if MIDIMapping.mappable.contains(element.kind) {
            add("MIDI Learn") { $0.learnMIDI(part: id) }
        }
        if element.kind == .block {
            add("Open Block") { $0.openBlock(id) }
        }
        add("Rotate") { editor in
            editor.selection = [id]
            editor.rotateSelection()
        }
        if element.kind.canFlip {
            add("Flip") { editor in
                editor.selection = [id]
                editor.flipSelection()
            }
        }
        add("Delete") { editor in
            editor.selection = [id]
            editor.deleteSelection()
        }
        return actions
    }

    /// The box round a part's terminals and ends, in the canvas's own (flipped) coordinates
    func accessibilityRect(of id: UUID) -> CGRect? {
        guard let element = editor.circuit[id] else { return nil }
        let extent = element.extentPoints.map(screen)
        guard let minX = extent.map(\.x).min(), let maxX = extent.map(\.x).max(),
              let minY = extent.map(\.y).min(), let maxY = extent.map(\.y).max() else { return nil }
        let unit = editor.unit
        var rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        // a two-terminal part is a line: give it its symbol's width
        if rect.width < unit { rect = rect.insetBy(dx: -0.45 * unit, dy: 0) }
        if rect.height < unit { rect = rect.insetBy(dx: 0, dy: -0.45 * unit) }
        return rect
    }

    // MARK: - Values

    /// What a listener hears as the part's value: its state, what the canvas writes beside it and, once the
    /// simulation has run, its present voltage and current
    func accessibilityValueText(of element: Element) -> String {
        let simulator = editor.simulation.simulator
        // the simulator may still hold the previous circuit for a moment after an edit
        let index = editor.circuit.index(of: element.id)
        let live = index != nil && simulator.circuit.elements.count == editor.circuit.elements.count
            && simulator.circuit.index(of: element.id) == index
        var parts: [String] = []
        switch element.kind {
        case .toggleSwitch: parts.append(element.closed ? "closed" : "open")
        case .pushButton: parts.append(element.closed ? "held down" : "released")
        default: break
        }
        if let index, let text = accessibilityValueLabel(element, index: index, live: live) { parts.append(text) }
        if live, let index, simulator.time > 0 {
            parts.append(contentsOf: liveReadings(element, index: index, simulator: simulator))
        }
        return parts.joined(separator: ", ")
    }

    private func liveReadings(_ element: Element, index: Int, simulator: Simulator) -> [String] {
        let kind = element.kind
        if kind == .probe || kind == .ammeter || kind == .vuMeter || kind == .loopProbe || kind == .keyboardPitch { return [] }
        if kind == .netLabel || kind == .port {
            return ["at " + SI.format(simulator.terminalVoltages(index).first ?? 0, unit: "V")]
        }
        if kind.isMicrocontroller || kind.hasChipPackage || kind == .block || kind == .timer555 { return [] }
        let voltage = SI.format(simulator.voltageAcross(index), unit: "V")
        let current = SI.format(simulator.current(index), unit: "A")
        if kind == .led || kind == .lamp {
            let brightness = simulator.brightness(index)
            return [brightness > 0.02 ? "lit \(Int((brightness * 100).rounded())) %" : "dark", current + " through"]
        }
        if kind.isSwitch { return [current + " through"] }
        if kind.drivesOutput || kind == .ota || kind == .logicGate || kind == .schmittInverter || kind == .unbufferedInverter {
            return ["output at " + voltage]
        }
        if kind.isTransistor || kind.isTube { return [voltage + " across", current + " through"] }
        if kind == .potentiometer { return [voltage + " across the track"] }
        if kind.isVoltageSource || kind == .currentSource { return [voltage, current + " supplied"] }
        return [voltage + " across", current + " through"]
    }

    /// The text the canvas draws beside a part (`valueLabel`), as it is spoken: a reading not made yet ("— V") and the
    /// loop probe's letter say nothing, and the canvas's dots are pauses
    private func accessibilityValueLabel(_ element: Element, index: Int, live: Bool) -> String? {
        guard let text = valueLabel(element, index: index, live: live), !text.hasPrefix("\u{2014} "),
              element.kind != .loopProbe else { return nil }
        return text.replacingOccurrences(of: " \u{00B7} ", with: ", ")
    }

    // MARK: - Notifications

    /// Tells assistive apps when the selection or the parts change, at most a few times a second
    private func observeForAccessibility(_ model: CanvasAccessibilityModel) {
        let editor = self.editor
        editor.$selection
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] selection in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    _ = self.accessibilityPartElements()
                    NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
                    // the canvas keeps the keyboard focus as Tab moves the selection: say what was selected
                    if selection.count == 1, let id = selection.first, let element = self.editor.circuit[id],
                       self.window?.firstResponder === self {
                        CircuitCanvasView.announce("Selected " + CircuitDescription.spokenName(element))
                    }
                }
            }
            .store(in: &model.subscriptions)
        editor.document.$circuit
            .dropFirst()
            .map { CanvasAccessibility.structure(of: $0) }
            .removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let before = self.accessibilityModel.partIDs
                    let children = self.accessibilityPartElements()
                    let after = self.accessibilityModel.partIDs
                    NSAccessibility.post(element: self, notification: .layoutChanged)
                    let added = children.filter { !before.contains($0.partID) }
                    let removed = before.subtracting(after).count
                    if added.count == 1, removed == 0, let label = added[0].accessibilityLabel() {
                        CircuitCanvasView.announce("Added " + label)
                    } else if added.isEmpty, removed > 0 {
                        CircuitCanvasView.announce(removed == 1 ? "Removed a part" : "Removed \(removed) parts")
                    }
                }
            }
            .store(in: &model.subscriptions)
    }

    static func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
