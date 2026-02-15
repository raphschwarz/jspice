import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            SimulationSettingsView()
                .tabItem {
                    Label("Simulation", systemImage: "bolt")
                }

            AudioSettingsView()
                .tabItem {
                    Label("Audio", systemImage: "speaker.wave.2")
                }

            AppearanceSettingsView()
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }
        }
        .frame(width: 500, height: 400)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("snapToGrid") private var snapToGrid = true
    @AppStorage("gridSize") private var gridSize = 10.0
    @AppStorage("autoSave") private var autoSave = true
    @AppStorage("showNodeLabels") private var showNodeLabels = true

    var body: some View {
        Form {
            Section("Editor") {
                Toggle("Snap to Grid", isOn: $snapToGrid)
                Slider(value: $gridSize, in: 5...50, step: 5) {
                    Text("Grid Size: \(Int(gridSize))px")
                }
                Toggle("Show Node Labels", isOn: $showNodeLabels)
            }

            Section("Files") {
                Toggle("Auto-save", isOn: $autoSave)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct SimulationSettingsView: View {
    @AppStorage("maxIterations") private var maxIterations = 100
    @AppStorage("convergenceTolerance") private var convergenceTolerance = 1e-9
    @AppStorage("defaultTimeStep") private var defaultTimeStep = 1e-6
    @AppStorage("liveSimulation") private var liveSimulation = true

    var body: some View {
        Form {
            Section("Solver") {
                Stepper("Max Iterations: \(maxIterations)", value: $maxIterations, in: 10...1000, step: 10)
                TextField("Convergence Tolerance", value: $convergenceTolerance, format: .number)
            }

            Section("Transient Analysis") {
                TextField("Default Time Step (s)", value: $defaultTimeStep, format: .number)
            }

            Section("Interactive") {
                Toggle("Live Re-simulation on Parameter Change", isOn: $liveSimulation)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct AudioSettingsView: View {
    @AppStorage("audioSampleRate") private var audioSampleRate = 48000
    @AppStorage("audioBufferSize") private var audioBufferSize = 512
    @AppStorage("audioEnabled") private var audioEnabled = false

    var body: some View {
        Form {
            Section("Output") {
                Picker("Sample Rate", selection: $audioSampleRate) {
                    Text("44100 Hz").tag(44100)
                    Text("48000 Hz").tag(48000)
                    Text("96000 Hz").tag(96000)
                }

                Picker("Buffer Size", selection: $audioBufferSize) {
                    Text("128 samples (~2.7ms)").tag(128)
                    Text("256 samples (~5.3ms)").tag(256)
                    Text("512 samples (~10.7ms)").tag(512)
                    Text("1024 samples (~21.3ms)").tag(1024)
                }

                Toggle("Enable Audio Output by Default", isOn: $audioEnabled)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("wireStyle") private var wireStyle = "orthogonal"
    @AppStorage("showSignalFlow") private var showSignalFlow = false
    @AppStorage("componentStyle") private var componentStyle = "standard"

    var body: some View {
        Form {
            Section("Wires") {
                Picker("Wire Routing Style", selection: $wireStyle) {
                    Text("Orthogonal").tag("orthogonal")
                    Text("Curved").tag("curved")
                    Text("Direct").tag("direct")
                }
            }

            Section("Components") {
                Picker("Component Style", selection: $componentStyle) {
                    Text("Standard (US)").tag("standard")
                    Text("IEC (European)").tag("iec")
                }
                Toggle("Show Signal Flow on Wires", isOn: $showSignalFlow)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
