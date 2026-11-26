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
        if let i = arguments.firstIndex(of: "--render-drawings"), i + 1 < arguments.count {
            ScreenshotRunner.run(outputDirectory: arguments[i + 1], selfTest: false, drawings: true)
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
        .commands { AppCommands() }
        // File ▸ New from Example… and Help ▸ Example Gallery open it
        Window("Examples", id: ExampleGalleryView.windowID) {
            ExampleGalleryView()
        }
        // JSpice ▸ Settings… (⌘,)
        Settings {
            SettingsView()
        }
    }
}

/// The app's menus. Each menu is a `Commands` of its own, so that no builder holds more than ten items.
struct AppCommands: Commands {
    var body: some Commands {
        AppMenuCommands()
        FileCommands()
        EditCommands()
        ViewCommands()
        CircuitCommands()
        SimulationCommands()
        MicrocontrollerCommands()
        HelpCommands()
    }
}

/// JSpice ▸ AI Control (MCP), under Settings…: the choice Settings ▸ AI Control explains, one click away
struct AppMenuCommands: Commands {
    var body: some Commands {
        // About shows the version, build and commit; Check for Updates… asks GitHub, only when chosen
        CommandGroup(replacing: .appInfo) { AboutJSpiceButton() }
        CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
        CommandGroup(after: .appSettings) {
            AIControlMenu()
        }
    }
}

/// File ▸ New from Example…, File ▸ Import and File ▸ Export
struct FileCommands: Commands {
    @FocusedObject private var editor: EditorState?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New from Example…") { openWindow(id: ExampleGalleryView.windowID) }
        }
        CommandGroup(replacing: .importExport) {
            Menu("Import") {
                Button("SPICE Netlist…") { editor?.importSpice() }
                Button("Schematic from Image or PDF…") { editor?.importSchematic() }
                Divider()
                Button("Maker's Model…") { editor?.importMakerModel() }
                Menu("Download Maker's Model") {
                    ForEach(MakerModelCatalog.models) { model in
                        Button("\(model.part) — \(model.maker)") { editor?.downloadMakerModel(model) }
                    }
                }
            }
            .disabled(editor == nil)
            Menu("Export") {
                Button("Image…") { editor?.exportImage() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Sound…") { editor?.exportSound() }
                Divider()
                Button("SPICE Netlist…") { editor?.exportSpice() }
                Button("KiCad Netlist…") { editor?.exportKiCad() }
                Divider()
                Button("Audio Unit…") { editor?.exportAudioUnit() }
            }
            .disabled(editor == nil)
        }
    }
}

/// Edit ▸ Duplicate, after the pasteboard items
struct EditCommands: Commands {
    @FocusedObject private var editor: EditorState?

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Duplicate") { editor?.duplicateSelection() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(editor?.selection.isEmpty ?? true)
        }
    }
}

/// View ▸ Zoom In, Zoom Out, Zoom to Fit
struct ViewCommands: Commands {
    @FocusedObject private var editor: EditorState?

    var body: some Commands {
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

/// Circuit: what acts on the circuit itself
struct CircuitCommands: Commands {
    @FocusedObject private var editor: EditorState?

    var body: some Commands {
        CommandMenu("Circuit") {
            Button("Add Part…") { editor?.showQuickAdd = true }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(editor == nil)
            Divider()
            Button("Rotate") { editor?.rotateSelection() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(editor?.selection.isEmpty ?? true)
            Button("Flip") { editor?.flipSelection() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!(editor?.canFlipSelection ?? false))
            Button("Delete") { editor?.deleteSelection() }
                .disabled(editor?.selection.isEmpty ?? true)
            Divider()
            Button("Tidy Up") { editor?.tidyUp() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(editor?.circuit.elements.isEmpty ?? true)
            Button("Save as Block…") { editor?.promptSaveAsBlock() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(editor?.circuit.elements.isEmpty ?? true)
        }
    }
}

/// Simulation ▸ Run or Pause, Reset
struct SimulationCommands: Commands {
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
    }
}

/// Microcontroller: the selected chip's program, and the compilers chips need
struct MicrocontrollerCommands: Commands {
    @FocusedObject private var editor: EditorState?

    /// The selected microcontroller, if its program is a sketch compiled here (an STM32's firmware is built elsewhere)
    private var sketchChip: Element? {
        guard let chip = editor?.selectedMicrocontroller, chip.kind.board?.compilesSketches ?? true else { return nil }
        return chip
    }

    var body: some Commands {
        CommandMenu("Microcontroller") {
            Button("Edit Sketch…") {
                if let chip = sketchChip { editor?.editingSketch = chip.id }
            }
            .disabled(sketchChip == nil)
            Button("Upload Sketch") {
                // a chip with no sketch yet gets its own board's blink, as the inspector's Upload gives it
                if let chip = sketchChip {
                    editor?.uploadSketch(chip.id, code: chip.code ?? chip.kind.board?.blinkSketch ?? blinkTemplate)
                }
            }
            .keyboardShortcut("u", modifiers: .command)
            .disabled(sketchChip == nil)
            Button("Load Firmware…") {
                if let chip = editor?.selectedMicrocontroller { editor?.loadFirmware(chip.id) }
            }
            .disabled(editor?.selectedMicrocontroller == nil)
            Divider()
            Button("Chip Support…") { editor?.showChipSupport = true }
                .disabled(editor == nil)
        }
    }
}

/// Help ▸ Keyboard Shortcuts, Example Gallery
struct HelpCommands: Commands {
    @FocusedObject private var editor: EditorState?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { editor?.showShortcuts = true }
                .keyboardShortcut("/", modifiers: .command)
                .disabled(editor == nil)
            Button("Example Gallery") { openWindow(id: ExampleGalleryView.windowID) }
        }
    }
}
