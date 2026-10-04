import AppKit
import SwiftUI
import CircuitKit

@main
enum Launcher {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if let i = arguments.firstIndex(of: "--screenshots"), i + 1 < arguments.count {
            ScreenshotRunner.run(outputDirectory: arguments[i + 1], selfTest: false)
            return
        }
        if let i = arguments.firstIndex(of: "--self-test"), i + 1 < arguments.count {
            ScreenshotRunner.run(outputDirectory: arguments[i + 1], selfTest: true)
            return
        }
        if let i = arguments.firstIndex(of: "--render-icon"), i + 1 < arguments.count {
            IconRenderer.writeIconSet(to: arguments[i + 1])
            return
        }
        AutomationBridge.shared.start()
        MIDIInput.shared.start()
        JSpiceApp.main()
    }
}

struct JSpiceApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { CircuitDocument() }) { file in
            EditorView(document: file.document)
        }
        .defaultSize(width: 1320, height: 840)
        .commands { CircuitCommands() }
    }
}

struct CircuitCommands: Commands {
    @FocusedObject private var editor: EditorState?

    var body: some Commands {
        CommandMenu("Simulation") {
            Button("Run or Pause") { editor?.simulation.toggleRunning() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(editor == nil)
            Button("Reset") { editor?.simulation.reset() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(editor == nil)
        }
        CommandMenu("Circuit") {
            Button("Rotate") { editor?.rotateSelection() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(editor?.selection.isEmpty ?? true)
            Button("Flip") { editor?.flipSelection() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!(editor?.canFlipSelection ?? false))
            Button("Delete") { editor?.deleteSelection() }
            Button("Tidy Up") { editor?.tidyUp() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(editor?.circuit.elements.isEmpty ?? true)
                .disabled(editor?.selection.isEmpty ?? true)
            Divider()
            Toggle("Allow AI Control (MCP)", isOn: Binding(
                get: { AutomationBridge.shared.isEnabled },
                set: { AutomationBridge.shared.isEnabled = $0 }
            ))
            Button("Copy MCP Server Configuration") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(AutomationBridge.clientConfiguration, forType: .string)
            }
            Divider()
            Button("Export Image…") { editor?.exportImage() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Divider()
            Menu("Examples") {
                ForEach(Examples.all) { example in
                    Button(example.title) { editor?.load(example) }
                }
            }
            .disabled(editor == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { editor?.changeZoom(by: 1.25) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { editor?.changeZoom(by: 0.8) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Zoom to Fit") { editor?.requestFit() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }
    }
}
