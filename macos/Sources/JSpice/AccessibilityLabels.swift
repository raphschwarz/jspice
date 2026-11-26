import AppKit
import SwiftUI
import CircuitKit

// What VoiceOver and other assistive technology hear from the SwiftUI parts of the window, as modifiers applied with
// one line where each control is made: labels for controls drawn as pictures, values for knobs and meters, actions for
// controls that only answered to the mouse, and Reduce Motion for the animations. (The schematic itself is in
// CanvasAccessibility.swift.)

/// Keyboard symbols as they are said: "⇧⌘B" is "Shift Command B"
func spokenShortcut(_ keys: String) -> String {
    let names: [Character: String] = ["⇧": "Shift", "⌘": "Command", "⌥": "Option", "⌃": "Control", "⌫": "Delete", "↩": "Return",
                                      "←": "Left Arrow", "→": "Right Arrow", "↑": "Up Arrow", "↓": "Down Arrow", "−": "Minus"]
    var words: [String] = []
    for character in keys where character != " " {
        words.append(names[character] ?? String(character))
    }
    return words.joined(separator: " ")
}

/// Posts a VoiceOver announcement
@MainActor
func announceForAccessibility(_ text: String, priority: NSAccessibilityPriorityLevel = .medium) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                         userInfo: [.announcement: text, .priority: priority.rawValue])
}

// MARK: - Reduce Motion

/// A transition that is a plain fade when Reduce Motion is on
struct ReduceMotionTransition: ViewModifier {
    let transition: AnyTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? AnyTransition.opacity : transition)
    }
}

/// An animation left out when Reduce Motion is on (the change happens at once)
struct ReduceMotionAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation?
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

// MARK: - Front panel

@MainActor
enum PanelAccessibility {
    static let step = 0.05

    static func turn(_ control: FrontPanel.Control, by delta: Double, _ editor: EditorState) {
        if let block = control.blockID {
            editor.playInsideBlock(block, control.element.id) { $0[param: "position"] = min(1, max(0, $0[param: "position"] + delta)) }
        } else {
            editor.turnPotentiometer(control.element.id, by: delta)
        }
    }

    static func toggle(_ control: FrontPanel.Control, _ editor: EditorState) {
        if let block = control.blockID {
            editor.playInsideBlock(block, control.element.id) { $0.closed.toggle() }
        } else {
            editor.toggleSwitch(control.element.id)
        }
    }

    static func press(_ control: FrontPanel.Control, _ pressed: Bool, _ editor: EditorState) {
        if let block = control.blockID {
            editor.playInsideBlock(block, control.element.id) { $0.closed = pressed }
        } else {
            editor.setPressed(control.element.id, pressed)
        }
    }

    static func name(_ control: FrontPanel.Control) -> String {
        let kind = CircuitDescription.spokenKind(control.element.kind)
        let label = control.label.trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? kind : "\(label), \(kind)"
    }

    /// The speaker's output level, a fraction of its full scale, in words
    static func level(_ level: Double) -> String {
        guard level > 0.001 else { return "silent" }
        return String(format: "%.0f dB", 20 * log10(level)) + (level > 1 ? ", clipping" : "")
    }
}

@MainActor
extension View {
    /// A front-panel control as VoiceOver and the keyboard use it: a knob is adjustable (and turns with the arrow keys
    /// when it has the keyboard focus), a switch is a toggle (Space flips it), a push button is held while Space is
    /// (VoiceOver's press holds it down until pressed again); lamps and meters read their state
    @ViewBuilder
    func panelControlAccessibility(_ control: FrontPanel.Control, editor: EditorState) -> some View {
        let element = control.element
        let name = PanelAccessibility.name(control)
        switch element.kind {
        case .potentiometer:
            let position = element[param: "position"]
            self.accessibilityElement(children: .ignore)
                .accessibilityLabel(name)
                .accessibilityValue("\(Int((position * 100).rounded())) percent")
                .accessibilityHint("Adjust to turn")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: PanelAccessibility.turn(control, by: PanelAccessibility.step, editor)
                    case .decrement: PanelAccessibility.turn(control, by: -PanelAccessibility.step, editor)
                    @unknown default: break
                    }
                }
                .focusable()
                .onKeyPress(keys: [.upArrow, .rightArrow, .downArrow, .leftArrow]) { press in
                    let up = press.key == .upArrow || press.key == .rightArrow
                    PanelAccessibility.turn(control, by: up ? PanelAccessibility.step : -PanelAccessibility.step, editor)
                    return .handled
                }
        case .toggleSwitch:
            self.accessibilityElement(children: .ignore)
                .accessibilityLabel(name)
                .accessibilityValue(element.closed ? "on" : "off")
                .accessibilityAddTraits(.isToggle)
                .accessibilityAction { PanelAccessibility.toggle(control, editor) }
                .focusable()
                .onKeyPress(keys: [.space, .return]) { _ in
                    PanelAccessibility.toggle(control, editor)
                    return .handled
                }
        case .pushButton:
            self.accessibilityElement(children: .ignore)
                .accessibilityLabel(name)
                .accessibilityValue(element.closed ? "held down" : "released")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Press to hold down, press again to let go")
                .accessibilityAction { PanelAccessibility.press(control, !element.closed, editor) }
                .focusable()
                .onKeyPress(.space, phases: [.down, .up]) { press in
                    PanelAccessibility.press(control, press.phase == .down, editor)
                    return .handled
                }
        case .speaker:
            self.accessibilityElement(children: .combine)
                .accessibilityLabel("Output level")
        default:
            // an LED or VU meter: its name here, its reading from the view that draws it (`readingAccessibility`)
            self.accessibilityElement(children: .combine)
                .accessibilityLabel(name)
        }
    }

    /// A lamp's or meter's present reading, given inside the view that redraws with the simulation, so it stays current
    func readingAccessibility(_ text: String) -> some View {
        self.accessibilityElement(children: .ignore)
            .accessibilityValue(text)
            .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Scopes

    /// A scope's plot in words: what it shows, the present value and the range over the window
    func scopePlotAccessibility(_ trace: ScopeTrace?, spec: ScopeSpec, partName: String) -> some View {
        let unit = spec.quantity.unit
        var value = "no reading yet"
        if let trace {
            if spec.plot == .currentVersusVoltage {
                value = "now \(SI.format(trace.lastVoltage, unit: "V")), \(SI.format(trace.lastValue, unit: "A"))"
            } else if let low = trace.minimums.min(), let high = trace.maximums.max() {
                value = "now \(SI.format(trace.lastValue, unit: unit)), from \(SI.format(low, unit: unit)) to \(SI.format(high, unit: unit))"
                    + " over the last \(SI.format(trace.window, unit: "s"))"
            }
        }
        let label = spec.plot == .currentVersusVoltage ? "Current against voltage of \(partName)" : "\(spec.quantity.name) of \(partName)"
        return self.accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityAddTraits(.updatesFrequently)
    }

    /// A frequency response's or spectrum's plot: its figures are the text beside it
    func plotAccessibility(_ label: String) -> some View {
        self.accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityHint("Its figures are beside it")
    }

    // MARK: - Dock

    /// A tab of the dock: its name, whether it is the one shown, and for Problems how many there are
    func dockTabAccessibility(_ tab: DockTab, selected: Bool, count: Int) -> some View {
        self.accessibilityLabel(tab.title)
            .accessibilityValue(tab == .problems ? (count == 0 ? "none" : count == 1 ? "1 problem" : "\(count) problems") : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(selected ? "Folds the dock down" : "Shows \(tab.title.lowercased()) in the dock")
    }

    /// The dock's top edge: adjustable, a step at a time, down to folded
    func dockResizeAccessibility(_ editor: EditorState) -> some View {
        self.accessibilityElement(children: .ignore)
            .accessibilityLabel("Dock height")
            .accessibilityValue(editor.dockCollapsed ? "folded" : "\(Int(editor.dockHeight.rounded())) points")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = 40
                switch direction {
                case .increment:
                    if editor.dockCollapsed {
                        editor.dockCollapsed = false
                    } else {
                        editor.dockHeight = ViewPreferences.clampDockHeight(editor.dockHeight + step)
                    }
                case .decrement:
                    if editor.dockHeight - step < ViewPreferences.minDockHeight {
                        editor.dockCollapsed = true
                    } else {
                        editor.dockHeight = ViewPreferences.clampDockHeight(editor.dockHeight - step)
                    }
                @unknown default:
                    break
                }
            }
    }

    // MARK: - Library and palette

    /// A library row: the part, its shortcut, and whether it is the tool chosen
    func toolRowAccessibility(title: String, shortcut: String?, isActive: Bool) -> some View {
        self.accessibilityLabel(title)
            .accessibilityValue(isActive ? "selected tool" : "")
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityHint(shortcut.map { "Shortcut \(spokenShortcut($0))" } ?? "")
    }

    /// A row of the ⌘K palette, which is clicked rather than a button: a button VoiceOver can press
    func paletteRowAccessibility(highlighted: Bool, action: @escaping () -> Void) -> some View {
        self.accessibilityElement(children: .combine)
            .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { action() }
    }

    /// Says the palette's highlighted row as the arrow keys move it (the keyboard focus stays in the search field)
    func paletteHighlightAnnouncements(_ highlighted: String?) -> some View {
        self.onChange(of: highlighted) { _, text in
            if let text { announceForAccessibility(text) }
        }
    }

    // MARK: - Welcome and gallery

    /// An example on the welcome card: its title, and that it makes sound
    func welcomeExampleAccessibility(_ example: Example) -> some View {
        self.accessibilityLabel(WelcomeView.shortTitle(example) + (example.quickFeatures.contains(.sound) ? ", makes sound" : ""))
            .accessibilityHint(example.summary)
    }

    /// A gallery card: title, category and badges, then the summary as its hint
    func exampleCardAccessibility(_ example: Example, features: ExampleFeatures) -> some View {
        var words = [WelcomeView.shortTitle(example), example.category.displayName]
        if features.contains(.sound) { words.append("makes sound") }
        if features.contains(.keyboard) { words.append("playable") }
        if features.contains(.knobs) { words.append("has knobs") }
        if features.contains(.microcontroller) { words.append("runs code") }
        return self.accessibilityLabel(words.joined(separator: ", "))
            .accessibilityHint(example.summary + " Opens in a new window.")
    }

    /// A heading (a gallery category, the welcome card's title)
    func headingAccessibility() -> some View {
        self.accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Toolbar and status bar

    func speedMenuAccessibility(_ status: SimulationController.Status) -> some View {
        self.accessibilityLabel("Speed")
            .accessibilityValue(status.audio ? "real time, sound on" : Pacing.describe(speed: status.speed) + (status.automatic ? ", automatic" : ""))
    }

    func soundToggleAccessibility(hasSpeaker: Bool, problem: String?) -> some View {
        self.accessibilityLabel("Sound")
            .accessibilityHint(hasSpeaker ? (problem ?? "Listen to the speaker: runs the circuit in real time")
                                          : "Unavailable: add a speaker to the circuit to listen to it")
    }

    func inspectorButtonAccessibility(shown: Bool) -> some View {
        self.accessibilityLabel("Inspector")
            .accessibilityValue(shown ? "shown" : "hidden")
    }

    /// The status bar's state and time, read as one element
    func simulationStatusAccessibility(_ status: SimulationController.Status, running: Bool) -> some View {
        let state = status.failed ? "Stopped" : running ? "Running" : "Paused"
        return self.accessibilityElement(children: .ignore)
            .accessibilityLabel("Simulation")
            .accessibilityValue("\(state), time \(SI.format(status.time, unit: "s", digits: 4))")
            .accessibilityAddTraits(.updatesFrequently)
    }

    func reduceMotionTransition(_ transition: AnyTransition) -> some View {
        modifier(ReduceMotionTransition(transition: transition))
    }

    func reduceMotionAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(ReduceMotionAnimation(animation: animation, value: value))
    }
}

extension QuickAddPalette {
    /// A palette item as it is said when highlighted
    @MainActor
    static func spokenName(_ item: Item, editor: EditorState) -> String {
        switch item {
        case .part(let kind):
            return kind.displayName + (kind.shortcutLabel.map { ", shortcut \(spokenShortcut($0))" } ?? "")
        case .command(let command):
            return command.title(for: editor) + ", command" + (command.shortcut.map { ", \(spokenShortcut($0))" } ?? "")
        case .example(let id):
            return (Examples.example(id)?.title ?? id) + ", example"
        }
    }
}
