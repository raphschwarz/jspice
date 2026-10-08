import SwiftUI
import CircuitKit

/// One circuit window: library | canvas, scopes and status bar | inspector.
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
                }
                // a board is for building: the panel and scopes give it their room
                let onBoard = editor.board != .schematic && !document.circuit.elements.isEmpty
                if editor.showPanel && FrontPanel.hasControls(document.circuit) && !onBoard {
                    FrontPanel(editor: editor, circuit: document.circuit)
                }
                if !document.circuit.scopes.isEmpty && !onBoard {
                    Divider()
                    ScopePanel(editor: editor, circuit: document.circuit)
                }
                Divider()
                StatusBar(editor: editor, simulation: editor.simulation)
                    .sheet(isPresented: $editor.showChipSupport) { ChipSupportSheet(editor: editor) }
                    .sheet(isPresented: Binding(get: { editor.editingSketch != nil },
                                                set: { if !$0 { editor.editingSketch = nil } })) {
                        if let id = editor.editingSketch { SketchEditorSheet(editor: editor, elementID: id) }
                    }
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
                    ProblemBanner(simulation: editor.simulation)
                }
                .padding(.top, 12)
                .animation(.snappy(duration: 0.2), value: editor.tool)
            }
            .overlay(alignment: .bottomTrailing) {
                if !document.circuit.elements.isEmpty {
                    ZoomControl(editor: editor).padding(12)
                }
            }
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

let speedPresets: [Double] = [1, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01, 5e-3, 2e-3, 1e-3, 5e-4, 2e-4, 1e-4, 1e-5, 1e-6]

struct EditorToolbar: ToolbarContent {
    @ObservedObject var editor: EditorState
    @ObservedObject var simulation: SimulationController

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                simulation.toggleRunning()
            } label: {
                Label(simulation.isRunning ? "Pause" : "Run", systemImage: simulation.isRunning ? "pause.fill" : "play.fill")
            }
            .help(simulation.isRunning ? "Pause the simulation (Space)" : "Run the simulation (Space)")
            Button {
                simulation.reset()
            } label: {
                Label("Reset", systemImage: "backward.end.fill")
            }
            .help("Restart from time zero, with capacitors discharged")
        }
        ToolbarItem(placement: .principal) {
            Menu {
                Button("Automatic") { editor.updateSettings { $0.autoSpeed = true } }
                Divider()
                ForEach(speedPresets, id: \.self) { speed in
                    Button(Pacing.describe(speed: speed)) {
                        editor.updateSettings {
                            $0.autoSpeed = false
                            $0.speed = speed
                        }
                    }
                }
            } label: {
                Label(Pacing.describe(speed: simulation.status.speed), systemImage: "speedometer")
                    .labelStyle(.titleAndIcon)
            }
            .help("How fast circuit time runs compared with real time")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { simulation.soundOn }, set: { simulation.setSound($0) })) {
                Label("Sound", systemImage: simulation.soundOn ? "speaker.wave.2.fill" : "speaker.slash")
            }
            .disabled(!simulation.hasSpeaker)
            .help(simulation.hasSpeaker ? "Listen to the speaker: runs the circuit in real time at audio rate"
                                        : "Add a speaker to the circuit to listen to it")
            Picker("View", selection: $editor.board) {
                Label("Schematic", systemImage: "point.3.connected.trianglepath.dotted").tag(BoardKind.schematic)
                Label("Breadboard", systemImage: "circle.grid.3x3").tag(BoardKind.breadboard)
                Label("Stripboard", systemImage: "line.3.horizontal").tag(BoardKind.stripboard)
            }
            .pickerStyle(.segmented)
            .help("Show the schematic, or the circuit built on a breadboard or stripboard with its bill of materials")
            Toggle(isOn: $editor.showPanel) {
                Label("Panel", systemImage: "slider.horizontal.3")
            }
            .help("Show the front panel: knobs and switches for the circuit's potentiometers and switches")
            Toggle(isOn: $editor.showCurrent) {
                Label("Current", systemImage: "bolt.fill")
            }
            .help("Show current flow as moving dots")
            Toggle(isOn: $editor.showValues) {
                Label("Values", systemImage: "textformat.123")
            }
            .help("Show part names and values")
            Button { editor.changeZoom(by: 0.8) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
            Button { editor.changeZoom(by: 1.25) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
            Button { editor.requestFit() } label: { Label("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
            Button {
                editor.showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector")
        }
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
            Text("t = \(SI.format(status.time, unit: "s", digits: 4))")
                .monospacedDigit()
                .frame(minWidth: 90, alignment: .leading)
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

    private var hoverDescription: String? {
        guard let id = editor.hovered else { return nil }
        let simulator = simulation.simulator
        guard let index = simulator.circuit.index(of: id) else { return nil }
        let element = simulator.circuit.elements[index]
        let name = element.name.isEmpty ? element.kind.displayName : "\(element.name) · \(element.kind.displayName)"
        if element.kind == .wire {
            let nodeVoltage = simulator.terminalVoltages(index).first ?? 0
            return "\(name) at \(SI.format(nodeVoltage, unit: "V")) · \(SI.format(simulator.current(index), unit: "A"))"
        }
        if element.kind == .ground { return name }
        return "\(name) · \(SI.format(simulator.voltageAcross(index), unit: "V")) · \(SI.format(simulator.current(index), unit: "A"))"
    }
}

struct ProblemBanner: View {
    @ObservedObject var simulation: SimulationController

    var body: some View {
        if let problem = simulation.status.problems.first {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.88), in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                .padding(.horizontal, 24)
        }
    }
}

struct WelcomeView: View {
    @ObservedObject var editor: EditorState
    private let featured = ["led", "rc", "lc", "memristor"].compactMap { Examples.example($0) }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Draw a circuit")
                .font(.title2.weight(.semibold))
            Text("Pick a part in the library, then click or drag on the canvas to place it. Join parts with wires (W). The circuit simulates live as you draw.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Text("Or start from an example")
                .font(.headline)
                .padding(.top, 6)
            LazyVGrid(columns: [GridItem(.fixed(150)), GridItem(.fixed(150))], spacing: 10) {
                ForEach(featured) { example in
                    Button {
                        editor.load(example)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: example.symbol).font(.title2)
                            Text(example.title).font(.callout).multilineTextAlignment(.center)
                        }
                        .frame(width: 136, height: 64)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
