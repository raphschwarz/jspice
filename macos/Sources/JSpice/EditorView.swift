import SwiftUI
import CircuitKit

/// One circuit window: library | canvas (or a board), the dock of scopes, panel, chip and problems, and the status bar |
/// inspector.
struct EditorView: View {
    @ObservedObject var document: CircuitDocument
    @StateObject private var editor: EditorState
    @Environment(\.undoManager) private var undoManager

    init(document: CircuitDocument) {
        self.document = document
        _editor = StateObject(wrappedValue: EditorState(document: document))
    }

    init(document: CircuitDocument, editor: EditorState) {
        self.document = document
        _editor = StateObject(wrappedValue: editor)
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(editor: editor)
                .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 320)
        } detail: {
            VStack(spacing: 0) {
                switch document.circuit.elements.isEmpty ? .schematic : editor.board {
                case .schematic: schematic
                case .breadboard: BreadboardView(editor: editor, circuit: document.circuit)
                case .stripboard: StripboardView(editor: editor, circuit: document.circuit)
                case .perfboard: PerfboardView(editor: editor, circuit: document.circuit)
                }
                // the scopes, panel, chip and problems, under the schematic and the boards alike (shown only when the
                // circuit has one of them)
                BottomDock(editor: editor, simulation: editor.simulation, circuit: document.circuit)
                Divider()
                StatusBar(editor: editor, simulation: editor.simulation)
                    .sheet(isPresented: $editor.showChipSupport) { ChipSupportSheet(editor: editor) }
                    .sheet(isPresented: Binding(get: { editor.editingSketch != nil },
                                                set: { if !$0 { editor.editingSketch = nil } })) {
                        if let id = editor.editingSketch { SketchEditorSheet(editor: editor, elementID: id) }
                    }
            }
            // a scope just added is shown
            .onChange(of: document.circuit.scopes.count) { old, new in
                if new > old { editor.showDock(.scopes) }
            }
            .toolbar { EditorToolbar(editor: editor, simulation: editor.simulation) }
            .inspector(isPresented: $editor.showInspector) {
                InspectorView(editor: editor, document: document)
                    .inspectorColumnWidth(min: 250, ideal: 290, max: 400)
            }
        }
        .sheet(isPresented: $editor.showShortcuts) { ShortcutsSheet(editor: editor) }
        .focusedSceneObject(editor)
        .onAppear { editor.undoManager = undoManager }
        // closing the window silences it
        .onDisappear { editor.simulation.setSound(false) }
        .onChange(of: undoManager) { _, manager in editor.undoManager = manager }
        .onChange(of: document.circuit) { _, circuit in editor.simulation.load(circuit) }
    }

    /// The schematic, with its welcome, tool and zoom overlays
    private var schematic: some View {
        CircuitCanvas(editor: editor, circuit: document.circuit)
            .overlay {
                if document.circuit.elements.isEmpty { WelcomeView(editor: editor) }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    ToolHUD(editor: editor)
                    ProblemBanner(editor: editor, simulation: editor.simulation, notes: document.circuit.loadNotes.count)
                    CaptureBanner(editor: editor)
                }
                .padding(.top, 12)
                .reduceMotionAnimation(.snappy(duration: 0.2), value: editor.tool)
            }
            .overlay(alignment: .bottomTrailing) {
                if !document.circuit.elements.isEmpty {
                    ZoomControl(editor: editor).padding(12)
                }
            }
            // what the app has to say about what it just did: toasts, out of the way of the drawing
            .overlay(alignment: .topTrailing) { NoticeOverlay(editor: editor) }
            .overlay(alignment: .top) {
                if editor.showQuickAdd {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.06)
                            .contentShape(Rectangle())
                            .onTapGesture { editor.choose(editor.tool) }
                        QuickAddPalette(editor: editor).padding(.top, 56)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: editor.showQuickAdd)
    }
}

struct StatusBar: View {
    @ObservedObject var editor: EditorState
    @ObservedObject var simulation: SimulationController

    var body: some View {
        let status = simulation.status
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.failed ? Color.red : simulation.isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(status.failed ? "Stopped" : simulation.isRunning ? "Running" : "Paused")
            }
            .simulationStatusAccessibility(status, running: simulation.isRunning)
            Text("t = \(SI.format(status.time, unit: "s", digits: 4))")
                .monospacedDigit()
                .frame(minWidth: 90, alignment: .leading)
                .accessibilityHidden(true)
            Text(status.audio ? "Real time, sound on" : Pacing.describe(speed: status.speed) + (status.automatic ? " (automatic)" : ""))
                .foregroundStyle(.secondary)
            if let problem = simulation.soundProblem {
                Label(problem, systemImage: "speaker.slash").foregroundStyle(.orange)
            }
            if simulation.playsComputerKeyboard {
                // A plays C of the octave shown: MIDI note 60 is C4
                Label("Play with A–; (A is C\(simulation.keyboardBase / 12 - 1)), Z and X change octave",
                      systemImage: "pianokeys")
                    .foregroundStyle(.secondary)
            }
            if simulation.isRunning && !status.failed && status.achieved < 0.85 {
                Label("Running at \(Int(status.achieved * 100)) % of that speed: the circuit is too complex for it",
                      systemImage: "tortoise.fill")
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            if let text = hoverDescription {
                Text(text).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            } else if let tool = editor.tool {
                Text("Click or drag to place a \(tool.displayName.lowercased()). Esc to stop.").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
    }

    /// The hovered part, its voltage and current, and what is wrong with it when a problem names it
    private var hoverDescription: String? {
        guard let id = editor.hovered else { return nil }
        let simulator = simulation.simulator
        guard let index = simulator.circuit.index(of: id) else { return nil }
        let element = simulator.circuit.elements[index]
        let name = element.name.isEmpty ? element.kind.displayName : "\(element.name) · \(element.kind.displayName)"
        let description: String
        if element.kind == .wire {
            let nodeVoltage = simulator.terminalVoltages(index).first ?? 0
            description = "\(name) at \(SI.format(nodeVoltage, unit: "V")) · \(SI.format(simulator.current(index), unit: "A"))"
        } else if element.kind == .ground {
            description = name
        } else {
            description = "\(name) · \(SI.format(simulator.voltageAcross(index), unit: "V")) · \(SI.format(simulator.current(index), unit: "A"))"
        }
        guard let problem = simulation.diagnostics(for: id).first else { return description }
        return "\(description) · \(problem.message)"
    }
}

/// The circuit's most severe problem over the schematic (red for an error, orange for a warning; notes alone show no
/// banner), and how many more there are; click it to see them all in the dock
struct ProblemBanner: View {
    let editor: EditorState
    @ObservedObject var simulation: SimulationController
    /// What was left out when the circuit's file was read, also listed with the problems
    let notes: Int

    var body: some View {
        let diagnostics = simulation.status.diagnostics
        if let problem = diagnostics.filter({ $0.severity != .note }).min(by: { $0.severity < $1.severity }) {
            let more = diagnostics.count - 1 + notes
            let isError = problem.severity == .error
            Button {
                editor.showDock(.problems)
            } label: {
                HStack(spacing: 8) {
                    Label(problem.message, systemImage: isError ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    if more > 0 {
                        Text("+\(more) more")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.22), in: Capsule())
                    }
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background((isError ? Color.red : Color.orange).opacity(0.88), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(more > 0 ? "Show all \(more + 1) problems in the dock" : "Show the problem in the dock")
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .padding(.horizontal, 24)
        }
    }
}
