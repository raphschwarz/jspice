import AppKit
import Combine
import SwiftUI
import CircuitKit

/// The tabs of the dock under the canvas
enum DockTab: String, CaseIterable, Identifiable {
    case scopes, panel, chip, problems

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scopes: return "Scopes"
        case .panel: return "Panel"
        case .chip: return "Chip"
        case .problems: return "Problems"
        }
    }

    var symbol: String {
        switch self {
        case .scopes: return "waveform.path.ecg"
        case .panel: return "slider.horizontal.3"
        case .chip: return "cpu"
        case .problems: return "exclamationmark.triangle"
        }
    }
}

/// How each window shows the circuit, remembered in the user defaults for the next window and launch. The automated
/// modes (`--self-test`, `--screenshots`, `--render-drawings`) always start from the built-in defaults and never write
/// them, so what a person last chose cannot change a test run, nor a test run what the person sees.
enum ViewPreferences {
    enum Key: String, CaseIterable {
        case showValues, showCurrent, showInspector, dockTab, dockCollapsed, dockHeight

        var defaultsName: String { "view.\(rawValue)" }
    }

    static let isAutomated: Bool = {
        let arguments = CommandLine.arguments
        return arguments.contains("--self-test") || arguments.contains("--screenshots") || arguments.contains("--render-drawings")
    }()

    static let defaultDockHeight: CGFloat = 240
    static let minDockHeight: CGFloat = 130
    static let maxDockHeight: CGFloat = 600

    static func clampDockHeight(_ height: CGFloat) -> CGFloat { min(max(height, minDockHeight), maxDockHeight) }

    static func bool(_ key: Key, default value: Bool) -> Bool {
        guard !isAutomated, let stored = UserDefaults.standard.object(forKey: key.defaultsName) as? Bool else { return value }
        return stored
    }

    static func dockTab() -> DockTab {
        guard !isAutomated, let stored = UserDefaults.standard.string(forKey: Key.dockTab.defaultsName),
              let tab = DockTab(rawValue: stored) else { return .scopes }
        return tab
    }

    static func dockHeight() -> CGFloat {
        guard !isAutomated, let stored = UserDefaults.standard.object(forKey: Key.dockHeight.defaultsName) as? Double else {
            return defaultDockHeight
        }
        return clampDockHeight(CGFloat(stored))
    }

    static func set(_ value: Bool, for key: Key) {
        guard !isAutomated else { return }
        UserDefaults.standard.set(value, forKey: key.defaultsName)
    }

    static func set(_ value: Double, for key: Key) {
        guard !isAutomated else { return }
        UserDefaults.standard.set(value, forKey: key.defaultsName)
    }

    static func set(_ value: String, for key: Key) {
        guard !isAutomated else { return }
        UserDefaults.standard.set(value, forKey: key.defaultsName)
    }

    /// What is stored for each key, to tell whether anything was written
    static func storedValues() -> [String] {
        Key.allCases.map { key in
            UserDefaults.standard.object(forKey: key.defaultsName).map { String(describing: $0) } ?? "-"
        }
    }
}

/// The dock between the canvas and the status bar: the scopes, the front panel, a microcontroller's serial monitor,
/// bus trace and pins, and the circuit's problems, one tab at a time. A tab is there only when it has something to
/// show, and the dock only when one is. Drag its top edge to resize it; it folds down to its tab bar.
struct BottomDock: View {
    @ObservedObject var editor: EditorState
    let simulation: SimulationController
    let circuit: Circuit
    /// The simulation's problems, followed here rather than the whole status, which changes on every frame
    @State private var problems: [String] = []

    /// The microcontrollers that have something to show in the Chip tab: a serial monitor, or an STM32's bus trace
    /// and pins
    static func chips(in circuit: Circuit) -> [Element] {
        circuit.elements.filter { element in
            guard element.kind.isMicrocontroller else { return false }
            return (element.kind.board?.hasSerial ?? true) || element.kind.board?.compilesSketches == false
        }
    }

    /// The tabs the dock offers for a circuit with this many problems: Problems whenever there are problems, and
    /// otherwise alongside other tabs, to say there are none
    static func tabs(for circuit: Circuit, problemCount: Int) -> [DockTab] {
        var tabs: [DockTab] = []
        if !circuit.scopes.isEmpty { tabs.append(.scopes) }
        if FrontPanel.hasControls(circuit) { tabs.append(.panel) }
        if !chips(in: circuit).isEmpty { tabs.append(.chip) }
        if problemCount > 0 || !tabs.isEmpty { tabs.append(.problems) }
        return tabs
    }

    /// The tabs a window's dock offers now
    @MainActor
    static func tabs(of editor: EditorState) -> [DockTab] {
        Self.tabs(for: editor.circuit, problemCount: Self.problemCount(of: editor))
    }

    /// The simulation's problems and what was left out when the circuit's file was read
    @MainActor
    static func problemCount(of editor: EditorState) -> Int {
        editor.simulation.status.problems.count + editor.circuit.loadNotes.count
    }

    /// The chip the Chip tab shows: the selected one, or else the circuit's first
    @MainActor
    static func shownChip(_ editor: EditorState, in circuit: Circuit) -> Element? {
        let chips = Self.chips(in: circuit)
        if let selected = editor.selectedMicrocontroller, let chip = chips.first(where: { $0.id == selected.id }) { return chip }
        return chips.first
    }

    var body: some View {
        let notes = circuit.loadNotes
        let tabs = Self.tabs(for: circuit, problemCount: problems.count + notes.count)
        VStack(spacing: 0) {
            if let first = tabs.first {
                let active = tabs.contains(editor.dockTab) ? editor.dockTab : first
                DockResizeHandle(editor: editor)
                tabBar(tabs, active: active, problemCount: problems.count + notes.count)
                if !editor.dockCollapsed {
                    Divider()
                    content(active, notes: notes)
                        .frame(maxWidth: .infinity)
                        .frame(height: editor.dockHeight)
                        .clipped()
                }
            }
        }
        .onReceive(simulation.$status.map(\.problems).removeDuplicates()) { if problems != $0 { problems = $0 } }
    }

    private func tabBar(_ tabs: [DockTab], active: DockTab, problemCount: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                DockTabButton(tab: tab, selected: tab == active && !editor.dockCollapsed,
                              count: tab == .problems ? problemCount : 0) {
                    if tab == active && !editor.dockCollapsed {
                        editor.dockCollapsed = true
                    } else {
                        editor.showDock(tab)
                    }
                }
            }
            Spacer(minLength: 8)
            if active == .chip && !editor.dockCollapsed {
                chipChooser
            }
            Button {
                editor.dockCollapsed.toggle()
            } label: {
                Image(systemName: editor.dockCollapsed ? "chevron.up" : "chevron.down")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help(editor.dockCollapsed ? "Show the dock" : "Fold the dock down to its tabs")
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(.bar)
    }

    /// The chip shown, and the others to choose from
    @ViewBuilder
    private var chipChooser: some View {
        let chips = Self.chips(in: circuit)
        if let shown = Self.shownChip(editor, in: circuit) {
            if chips.count > 1 {
                Menu {
                    ForEach(chips) { chip in
                        Button(Self.chipName(chip)) { editor.selection = [chip.id] }
                    }
                } label: {
                    Text(Self.chipName(shown)).font(.callout)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("The chip shown; choosing another selects it")
            } else {
                Text(Self.chipName(shown)).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    static func chipName(_ chip: Element) -> String {
        chip.name.isEmpty ? chip.kind.displayName : "\(chip.name) · \(chip.kind.displayName)"
    }

    @ViewBuilder
    private func content(_ tab: DockTab, notes: [String]) -> some View {
        switch tab {
        case .scopes:
            ScopesDock(editor: editor, circuit: circuit)
        case .panel:
            FrontPanel(editor: editor, circuit: circuit)
        case .chip:
            if let chip = Self.shownChip(editor, in: circuit) {
                ChipDock(editor: editor, chip: chip)
            }
        case .problems:
            ProblemsList(problems: problems, notes: notes)
        }
    }
}

/// One tab of the dock: its name, and for Problems how many there are
private struct DockTabButton: View {
    let tab: DockTab
    let selected: Bool
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                Text(tab.title)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.red, in: Capsule())
                }
            }
            .font(.callout)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(selected ? Color.primary.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(selected ? "Fold the dock down" : "Show \(tab.title.lowercased()) in the dock")
    }
}

/// The dock's top edge: drag it up or down to resize the dock, or all the way down to fold it to its tabs
private struct DockResizeHandle: View {
    @ObservedObject var editor: EditorState
    @State private var startHeight: CGFloat?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Color.clear.frame(height: 5)
        }
        .background(.bar)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside && !hovering { NSCursor.resizeUpDown.push() }
            if !inside && hovering { NSCursor.pop() }
            hovering = inside
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = startHeight ?? (editor.dockCollapsed ? 0 : editor.dockHeight)
                    if startHeight == nil { startHeight = start }
                    let proposed = start - value.translation.height
                    if proposed < ViewPreferences.minDockHeight / 2 {
                        if !editor.dockCollapsed { editor.dockCollapsed = true }
                    } else {
                        let height = ViewPreferences.clampDockHeight(proposed)
                        if editor.dockHeight != height { editor.dockHeight = height }
                        if editor.dockCollapsed { editor.dockCollapsed = false }
                    }
                }
                .onEnded { _ in startHeight = nil }
        )
        .help("Drag to resize the dock")
    }
}

/// The scopes, one row each, scrolling rather than taking room from the canvas; a scope just added is scrolled to
private struct ScopesDock: View {
    @ObservedObject var editor: EditorState
    let circuit: Circuit

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                ScopePanel(editor: editor, circuit: circuit)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .onChange(of: circuit.scopes.count) { old, new in
                if new > old, let last = circuit.scopes.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }
}

/// A microcontroller's live views: its serial monitor, and for an STM32 its bus trace and pins
private struct ChipDock: View {
    @ObservedObject var editor: EditorState
    let chip: Element

    var body: some View {
        let hasSerial = chip.kind.board?.hasSerial ?? true
        let isSTM32 = chip.kind.board?.compilesSketches == false
        if let index = editor.circuit.index(of: chip.id) {
            HStack(alignment: .top, spacing: 0) {
                if hasSerial {
                    SerialMonitor(simulation: editor.simulation, index: index)
                        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if hasSerial && isSTM32 {
                    Divider()
                }
                if isSTM32 {
                    BusTrace(simulation: editor.simulation, index: index)
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Divider()
                    PinFunctions(simulation: editor.simulation, index: index)
                        .frame(width: 280)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                }
            }
            // a chip of its own, a view of its own: what is typed to send, the bus picked
            .id(chip.id)
        }
    }
}

/// A titled column of the dock
struct DockColumn<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Every problem the simulation reports, and what was left out when the circuit's file was read
private struct ProblemsList: View {
    let problems: [String]
    let notes: [String]

    var body: some View {
        if problems.isEmpty && notes.isEmpty {
            VStack(spacing: 6) {
                Label("No problems", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text("The circuit has no problems: it simulates as drawn.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    if !problems.isEmpty {
                        Text("Simulation")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                            Label {
                                Text(problem).fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            }
                        }
                    }
                    if !notes.isEmpty {
                        Text("Opening the file")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, problems.isEmpty ? 0 : 6)
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                            Label {
                                Text(note).fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "doc.badge.ellipsis").foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
    }
}
