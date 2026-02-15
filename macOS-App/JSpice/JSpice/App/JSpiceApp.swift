import SwiftUI

@main
struct JSpiceApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        DocumentGroup(newDocument: CircuitDocument()) { file in
            ContentView(document: file.$document)
                .environmentObject(appState)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New from Template...") {
                    appState.showTemplateSheet = true
                }
                .keyboardShortcut("N", modifiers: [.command, .shift])
            }
            SimulationCommands()
            AnalysisCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    @Published var showTemplateSheet = false
    @Published var selectedTheme: AppTheme = .system

    enum AppTheme: String, CaseIterable {
        case light, dark, system
    }
}

// MARK: - Menu Commands

struct SimulationCommands: Commands {
    var body: some Commands {
        CommandMenu("Simulate") {
            Button("Run DC Operating Point") {}
                .keyboardShortcut("R", modifiers: [.command])
            Button("Run Transient Analysis") {}
                .keyboardShortcut("T", modifiers: [.command, .shift])
            Button("Run AC Analysis") {}
                .keyboardShortcut("A", modifiers: [.command, .shift])
            Divider()
            Button("Stop Simulation") {}
                .keyboardShortcut(".", modifiers: [.command])
        }
    }
}

struct AnalysisCommands: Commands {
    var body: some Commands {
        CommandMenu("Analysis") {
            Button("Show Waveform Viewer") {}
                .keyboardShortcut("W", modifiers: [.command, .option])
            Button("Show Spectrum Analyzer") {}
                .keyboardShortcut("F", modifiers: [.command, .option])
            Button("Show Bode Plot") {}
                .keyboardShortcut("B", modifiers: [.command, .option])
            Divider()
            Button("Export Plot as PDF...") {}
            Button("Export Data as CSV...") {}
        }
    }
}
