import AppKit
import SwiftUI
import CircuitKit

extension InteractionTest {
    /// The circuit's problems name their parts: a broken circuit's errors name parts that are in it, the parts are
    /// marked on the canvas, and clicking a problem in the dock selects them and shows the schematic
    static func checkProblems(editor: EditorState, document: CircuitDocument) async {
        editor.edit("Problems Check") { $0 = ScreenshotRunner.brokenDemo() }
        editor.selection = []
        editor.simulation.setRunning(true)
        await pause(1.0)

        let diagnostics = editor.simulation.status.diagnostics
        let errors = diagnostics.filter { $0.severity == .error }
        check(!errors.isEmpty, "a circuit with shorted batteries has errors (\(diagnostics.map(\.message).joined(separator: " ")))")
        check(diagnostics.first?.severity == .error || errors.isEmpty, "errors are listed first")
        guard let problem = errors.first(where: { !$0.elements.isEmpty }) else {
            check(false, "an error names the parts it concerns")
            return
        }
        let ids = Set(problem.elements)
        check(ids.allSatisfy { document.circuit[$0] != nil }, "the parts an error names are in the circuit")
        check(ids.allSatisfy { editor.simulation.severityByElement[$0] == .error }, "the canvas marks those parts as in error")
        check(!editor.simulation.diagnostics(for: problem.elements[0]).isEmpty, "the inspector finds the problem of a part it names")
        let badge = BottomDock.badge(for: diagnostics)
        check(badge.count >= errors.count && badge.isError, "the Problems tab's badge counts the errors, in red")

        // clicking the problem from a board view: its parts are selected, on the schematic
        editor.showDock(.problems)
        editor.board = .breadboard
        await pause(0.4)
        editor.reveal(problem)
        await pause(0.6)
        check(editor.selection == ids, "clicking a problem selects the parts it names")
        check(editor.board == .schematic, "clicking a problem shows the schematic")
        check(editor.pendingReveal == nil, "the schematic brings the parts into view")

        // parts already in view: clicking again moves nothing
        let pan = editor.pan, zoom = editor.zoom
        editor.reveal(problem)
        await pause(0.3)
        check(editor.pan == pan && editor.zoom == zoom, "clicking a problem whose parts are in view leaves the view as it is")
        editor.selection = []
        await pause(0.2)
    }
}
