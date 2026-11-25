import AppKit

/// The menus JSpiceApp promises, checked through the menu bar AppKit was given. The self-test runs its own NSApplication
/// with a window from NSHostingController, without the SwiftUI App, so no `Commands` are installed there: the check
/// only asserts when the menu bar has the app's menus, and otherwise says it skipped.
extension InteractionTest {
    static func checkMenus() async {
        guard let bar = NSApp.mainMenu, item(in: bar, "Circuit") != nil else {
            print("SKIP  the menus (the SwiftUI app's commands are not installed in this mode)")
            return
        }
        // SwiftUI fills its menus as it updates them: give it a moment
        await pause(0.2)

        let file = submenu(of: bar, "File")
        check(item(in: file, "New from Example…") != nil, "File ▸ New from Example…")
        let fileImport = submenu(of: file, "Import")
        for title in ["SPICE Netlist…", "Schematic from Image or PDF…", "Maker's Model…", "Download Maker's Model"] {
            check(item(in: fileImport, title) != nil, "File ▸ Import ▸ \(title)")
        }
        let fileExport = submenu(of: file, "Export")
        for title in ["Image…", "Sound…", "SPICE Netlist…", "KiCad Netlist…", "Audio Unit…"] {
            check(item(in: fileExport, title) != nil, "File ▸ Export ▸ \(title)")
        }
        let image = item(in: fileExport, "Image…")
        check(image?.keyEquivalent.lowercased() == "e" && image?.keyEquivalentModifierMask.contains([.command, .shift]) == true,
              "File ▸ Export ▸ Image… is ⇧⌘E")

        let circuit = submenu(of: bar, "Circuit")
        for title in ["Add Part…", "Rotate", "Flip", "Delete", "Tidy Up", "Save as Block…"] {
            check(item(in: circuit, title) != nil, "Circuit ▸ \(title)")
        }
        for gone in ["Examples", "Copy MCP Server Configuration", "Forget Anthropic API Key", "Export Image…"] {
            check(item(in: circuit, gone) == nil, "the Circuit menu no longer has \(gone)")
        }

        let simulation = submenu(of: bar, "Simulation")
        for title in ["Run or Pause", "Reset"] {
            check(item(in: simulation, title) != nil, "Simulation ▸ \(title)")
        }

        let microcontroller = submenu(of: bar, "Microcontroller")
        for title in ["Edit Sketch…", "Upload Sketch", "Load Firmware…", "Chip Support…"] {
            check(item(in: microcontroller, title) != nil, "Microcontroller ▸ \(title)")
        }
        let upload = item(in: microcontroller, "Upload Sketch")
        check(upload?.keyEquivalent.lowercased() == "u" && upload?.keyEquivalentModifierMask.contains(.command) == true,
              "Microcontroller ▸ Upload Sketch is ⌘U")

        let help = submenu(of: bar, "Help")
        for title in ["Keyboard Shortcuts", "Example Gallery"] {
            check(item(in: help, title) != nil, "Help ▸ \(title)")
        }

        let app = bar.items.first?.submenu
        check(item(in: app, "Settings…") != nil, "JSpice ▸ Settings…")
        check(item(in: app, "AI Control (MCP)") != nil, "JSpice ▸ AI Control (MCP)")
    }

    /// The item of a menu with this title, if there is one
    private static func item(in menu: NSMenu?, _ title: String) -> NSMenuItem? {
        menu?.items.first { $0.title == title }
    }

    private static func submenu(of menu: NSMenu?, _ title: String) -> NSMenu? {
        item(in: menu, title)?.submenu
    }
}
