import AppKit
import SwiftUI
import CircuitKit

extension InteractionTest {
    /// The window's layout: the dock under the canvas opens on a scope just added, offers Problems for a broken circuit,
    /// folds and unfolds, and the self-test's view choices are not remembered in the user defaults
    static func checkLayout(editor: EditorState, document: CircuitDocument, window: NSWindow) async {
        // (the self-test's undo manager does not group by event: an edit made outside a group, as these are, is given
        // one of its own by the editor)
        let stored = ViewPreferences.storedValues()
        check(ViewPreferences.isAutomated, "the self-test runs with the built-in view settings, not the user's")

        // a circuit without scopes, the dock folded on another tab: adding a scope opens it on Scopes
        guard var circuit = Examples.example("led")?.circuit else {
            check(false, "the LED example is there for the layout checks")
            return
        }
        circuit.scopes = []
        editor.edit("Layout Check") { $0 = circuit }
        editor.selection = []
        editor.showDock(.panel)
        editor.dockCollapsed = true
        await pause(0.4)
        check(!BottomDock.tabs(of: editor).contains(.scopes), "a circuit without scopes has no Scopes tab")
        if let resistor = document.circuit.elements.first(where: { $0.kind == .resistor }) {
            editor.addScope(resistor.id, .voltage)
            await pause(0.5)
            check(BottomDock.tabs(of: editor).contains(.scopes), "adding a scope gives the dock a Scopes tab")
            check(editor.dockTab == .scopes && !editor.dockCollapsed, "adding a scope opens the dock on the Scopes tab")
        } else {
            check(false, "the LED example has a resistor to scope")
        }

        // folding and unfolding
        editor.dockCollapsed = true
        await pause(0.2)
        check(editor.dockCollapsed && !editor.showPanel, "the dock folds down to its tabs")
        editor.showPanel = true
        await pause(0.2)
        check(!editor.dockCollapsed && editor.dockTab == .panel, "showing the panel unfolds the dock on the Panel tab")
        editor.showDock(.scopes)
        check(editor.dockTab == .scopes && !editor.dockCollapsed, "the dock opens again on the tab asked for")

        // a broken circuit: its problems are counted and the dock offers them
        editor.edit("Layout Check") { $0 = ScreenshotRunner.brokenDemo() }
        await pause(0.8)
        let problems = BottomDock.problemCount(of: editor)
        check(problems > 0, "a circuit with shorted batteries has problems (\(problems): \(editor.simulation.status.problems.joined(separator: " ")))")
        check(BottomDock.tabs(of: editor).contains(.problems), "the dock offers the Problems tab for them")
        editor.showDock(.problems)
        await pause(0.4)
        capture(window, to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jspice-layout-problems.png"))

        // view choices made during the self-test are not written to the user defaults
        let values = editor.showValues, current = editor.showCurrent, inspector = editor.showInspector
        let height = editor.dockHeight
        editor.showValues.toggle()
        editor.showCurrent.toggle()
        editor.showInspector.toggle()
        editor.dockHeight = height + 40
        editor.dockCollapsed.toggle()
        editor.showDock(.scopes)
        await pause(0.3)
        check(ViewPreferences.storedValues() == stored, "the self-test's view choices are not saved as the user's")
        editor.showValues = values
        editor.showCurrent = current
        editor.showInspector = inspector
        editor.dockHeight = height
        await pause(0.2)
    }
}
