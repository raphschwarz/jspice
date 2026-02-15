import SwiftUI

struct ContentView: View {
    @Binding var document: CircuitDocument
    @EnvironmentObject var appState: AppState
    @StateObject private var editorState = SchematicEditorState()
    @StateObject private var simulationController = SimulationController()
    @State private var showWaveformViewer = true
    @State private var sidebarWidth: CGFloat = 240
    @State private var inspectorWidth: CGFloat = 280
    @State private var waveformHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            SimulationToolbar(
                controller: simulationController,
                document: $document
            )

            // Main content
            HSplitView {
                // Left: Component Library
                ComponentLibraryView(
                    editorState: editorState,
                    document: $document
                )
                .frame(minWidth: 180, idealWidth: sidebarWidth, maxWidth: 320)

                // Center: Schematic + Waveform (takes priority for space)
                VStack(spacing: 0) {
                    // Schematic Canvas
                    SchematicEditorView(
                        document: $document,
                        editorState: editorState
                    )

                    if showWaveformViewer {
                        Divider()

                        // Bottom: Waveform Viewer
                        WaveformViewerContainer(
                            simulationResult: simulationController.latestResult
                        )
                        .frame(minHeight: 120, idealHeight: waveformHeight, maxHeight: 400)
                    }
                }
                .layoutPriority(1)

                // Right: Inspector
                InspectorPanelView(
                    document: $document,
                    editorState: editorState
                )
                .frame(minWidth: 220, idealWidth: inspectorWidth, maxWidth: 360)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $showWaveformViewer) {
                    Label("Waveforms", systemImage: "waveform.path.ecg")
                }
                .help("Toggle Waveform Viewer")
            }
        }
        .onChange(of: document) { _, newDocument in
            simulationController.documentDidChange(newDocument)
        }
    }
}

// MARK: - Simulation Toolbar

struct SimulationToolbar: View {
    @ObservedObject var controller: SimulationController
    @Binding var document: CircuitDocument

    var body: some View {
        HStack(spacing: 12) {
            // Simulation controls
            Button(action: {
                Task {
                    await controller.runDCOperatingPoint(document: document)
                }
            }) {
                Label("DC Op", systemImage: "bolt.fill")
            }
            .buttonStyle(.bordered)
            .disabled(controller.isRunning)
            .help("Run DC Operating Point Analysis")

            Button(action: {
                Task {
                    await controller.runTransientAnalysis(document: document)
                }
            }) {
                Label("Transient", systemImage: "waveform")
            }
            .buttonStyle(.bordered)
            .disabled(controller.isRunning)
            .help("Run Transient Analysis")

            Button(action: {
                Task {
                    await controller.runACAnalysis(document: document)
                }
            }) {
                Label("AC", systemImage: "waveform.path")
            }
            .buttonStyle(.bordered)
            .disabled(controller.isRunning)
            .help("Run AC Analysis")

            if controller.isRunning {
                ProgressView()
                    .scaleEffect(0.7)
                Button("Stop", systemImage: "stop.fill") {
                    controller.stopSimulation()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

            Spacer()

            // Status
            if let status = controller.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Audio toggle
            Toggle(isOn: Binding(
                get: { controller.audioEnabled },
                set: { controller.setAudioEnabled($0) }
            )) {
                Label("Audio", systemImage: controller.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .toggleStyle(.button)
            .help("Toggle Audio Output")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}
