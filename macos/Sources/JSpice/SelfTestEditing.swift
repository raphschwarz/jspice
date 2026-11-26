import AppKit
import CircuitKit

extension InteractionTest {
    /// Drawing and editing on the canvas with real events: a wire with a corner from the Wire tool, a wire from a free
    /// terminal, a connected end that still resizes, paste under the pointer, a value typed in place, Esc one step at
    /// a time and the empty canvas's menu
    static func checkEditing(editor: EditorState, document: CircuitDocument, window: NSWindow, canvas: CircuitCanvasView) async {
        guard let undo = editor.undoManager else {
            check(false, "the editor has an undo manager for the editing checks")
            return
        }
        /// An edit as one undo step: the undo manager here groups by event itself; one that does not needs a group
        func grouped(_ body: () -> Void) {
            if undo.groupsByEvent {
                body()
            } else {
                undo.beginUndoGrouping()
                body()
                undo.endUndoGrouping()
            }
        }
        func mouse(_ type: NSEvent.EventType, _ point: GridPoint, shift: Bool = false, clicks: Int = 1) -> NSEvent {
            let location = canvas.convert(canvas.screen(point), to: nil)
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: shift ? [.shift] : [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        func drag(_ from: GridPoint, _ to: GridPoint, shift: Bool = false) async {
            grouped {
                canvas.mouseDown(with: mouse(.leftMouseDown, from, shift: false))
                canvas.mouseDragged(with: mouse(.leftMouseDragged, to, shift: shift))
                canvas.mouseUp(with: mouse(.leftMouseUp, to, shift: shift))
            }
            await pause(0.05)
        }
        func key(_ code: UInt16, _ characters: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        func undoLast() async {
            await pause(0.05)
            undo.undo()
            await pause(0.1)
        }
        func elements(_ kind: ElementKind) -> [Element] { document.circuit.elements.filter { $0.kind == kind } }
        func ends(_ element: Element) -> Set<GridPoint> { [element.a, element.b] }

        // an empty circuit, centred in view
        grouped { editor.edit("Editing Check") { $0 = Circuit() } }
        editor.selection = []
        editor.tool = nil
        editor.requestFit()
        await pause(0.4)
        // and kept where it is: the canvas would otherwise fit itself to the parts drawn as it resizes
        editor.viewAdjusted = true

        // the Wire tool draws an elbow, joined at its corner, as one undo step
        editor.tool = .wire
        await drag(GridPoint(0, 0), GridPoint(4, 3))
        let elbow = elements(.wire)
        check(elbow.count == 2 && elbow.contains { ends($0) == [GridPoint(0, 0), GridPoint(4, 0)] }
                && elbow.contains { ends($0) == [GridPoint(4, 0), GridPoint(4, 3)] },
              "a slanting drag with the Wire tool draws two wires meeting at a corner (got \(elbow.map { "\($0.a)→\($0.b)" }))")
        check(undo.undoActionName == "Add Wire", "the elbow is one undo step, \"Undo Add Wire\" (got \(undo.undoActionName))")
        await undoLast()
        check(elements(.wire).isEmpty, "one undo takes both of the elbow's wires away")
        await drag(GridPoint(0, 0), GridPoint(4, 3), shift: true)
        check(elements(.wire).count == 1 && elements(.wire).first.map { ends($0) == [GridPoint(0, 0), GridPoint(4, 3)] } == true,
              "with ⇧ the Wire tool draws one straight wire at any angle")
        await undoLast()
        // in line: one wire, as before
        await drag(GridPoint(0, 0), GridPoint(0, 4))
        check(elements(.wire).count == 1, "an upright drag with the Wire tool draws one wire")
        await undoLast()

        // a drag from a free terminal draws a wire and leaves the part where it is
        editor.tool = .resistor
        await drag(GridPoint(0, 0), GridPoint(0, 0))
        editor.tool = nil
        guard let resistor = elements(.resistor).first, resistor.a == GridPoint(0, 0), resistor.b == GridPoint(4, 0) else {
            check(false, "the resistor tool places a resistor for the editing checks")
            return
        }
        let rid = resistor.id
        editor.selection = []
        check(document.circuit.isFreeTerminal(GridPoint(4, 0)), "a resistor on its own has free terminals")
        await drag(GridPoint(4, 0), GridPoint(8, 2))
        let fromTerminal = elements(.wire)
        check(document.circuit[rid]?.a == GridPoint(0, 0) && document.circuit[rid]?.b == GridPoint(4, 0),
              "a drag from a free terminal leaves its part unmoved")
        check(fromTerminal.count == 2 && fromTerminal.contains { ends($0) == [GridPoint(4, 0), GridPoint(8, 0)] }
                && fromTerminal.contains { ends($0) == [GridPoint(8, 0), GridPoint(8, 2)] },
              "a drag from a free terminal draws a wire from it (got \(fromTerminal.map { "\($0.a)→\($0.b)" }))")
        await undoLast()
        check(elements(.wire).isEmpty && document.circuit[rid] != nil, "one undo takes that wire away")
        // a click there, not a drag, selects the part as before
        await drag(GridPoint(4, 0), GridPoint(4, 0))
        check(editor.selection == [rid] && elements(.wire).isEmpty, "a click on a free terminal selects its part and draws nothing")

        // a connected end of the selected part still resizes it
        grouped { editor.addWire([WireSegment(GridPoint(4, 0), GridPoint(4, 4))]) }
        await pause(0.05)
        check(!document.circuit.isFreeTerminal(GridPoint(4, 0)), "a terminal a wire ends on is not free")
        editor.selection = [rid]
        await drag(GridPoint(4, 0), GridPoint(6, 0))
        check(document.circuit[rid]?.b == GridPoint(6, 0) && elements(.wire).count == 1,
              "dragging the selected part's connected end resizes it and draws no wire")
        check(undo.undoActionName == "Resize", "that is named \"Undo Resize\" (got \(undo.undoActionName))")
        await undoLast()
        check(document.circuit[rid]?.b == GridPoint(4, 0), "undo puts the resized end back")

        // paste lands under the pointer, keeping its shape
        editor.selection = [rid]
        editor.copySelection()
        canvas.mouseMoved(with: mouse(.mouseMoved, GridPoint(-6, 5)))
        grouped { canvas.paste(nil) }
        await pause(0.05)
        let pasted = editor.selection.compactMap { document.circuit[$0] }
        check(pasted.count == 1 && pasted.first?.kind == .resistor && pasted.first?.a == GridPoint(-8, 5) && pasted.first?.b == GridPoint(-4, 5),
              "paste puts the copy centred under the pointer (got \(pasted.map { "\($0.a)→\($0.b)" }))")
        check(undo.undoActionName == "Paste", "the paste is one undo step")
        await undoLast()
        check(elements(.resistor).count == 1, "undo takes the pasted part away")

        // the empty canvas has a menu of its own
        let menu = canvas.menu(for: mouse(.rightMouseDown, GridPoint(-6, -6)))
        let titles = menu?.items.map(\.title) ?? []
        check(["Paste", "Add Part…", "Select All", "Zoom to Fit", "Tidy Up"].allSatisfy { titles.contains($0) },
              "a right-click on the empty canvas offers Paste, Add Part…, Select All, Zoom to Fit and Tidy Up (got \(titles))")
        canvas.mouseMoved(with: mouse(.mouseMoved, GridPoint(2, 6)))

        // the value typed in place
        check(canvas.beginInlineEdit(rid) && canvas.inlineEditField != nil, "a resistor's value opens in a field over it")
        func enter(_ text: String) {
            guard let field = canvas.inlineEditField else { return }
            if let fieldEditor = field.currentEditor() { fieldEditor.string = text } else { field.stringValue = text }
        }
        // keys typed there are text, not part shortcuts or notes
        let toolBefore = editor.tool
        window.sendEvent(key(15, "r"))
        await pause(0.05)
        check(editor.tool == toolBefore && canvas.inlineEditField != nil, "typing in the value field does not pick a tool")
        enter("4k7")
        grouped { window.sendEvent(key(36, "\r")) }
        await pause(0.05)
        check(canvas.inlineEditField == nil, "Return in the value field closes it")
        if canvas.inlineEditField != nil {
            grouped { canvas.commitInlineEdit() }
            await pause(0.05)
        }
        check(canvas.inlineEditField == nil && document.circuit[rid]?[param: "resistance"] == 4700,
              "typing 4k7 and Return sets the resistance to 4.7 kΩ")
        check(undo.undoActionName == "Change Resistance", "the typed value is one undo step (got \(undo.undoActionName))")
        await undoLast()
        check(document.circuit[rid]?[param: "resistance"] == 1000, "undo puts the resistance back")
        canvas.beginInlineEdit(rid)
        enter("not a value")
        canvas.commitInlineEdit()
        check(canvas.inlineEditField != nil, "text that is not a value leaves the field open")
        enter("22k")
        window.sendEvent(key(53, "\u{1B}"))
        await pause(0.05)
        if canvas.inlineEditField != nil {
            check(false, "Esc in the value field closes it")
            canvas.cancelInlineEdit()
        }
        check(canvas.inlineEditField == nil && document.circuit[rid]?[param: "resistance"] == 1000, "Esc leaves the value as it was")
        if let wire = elements(.wire).first {
            check(!canvas.beginInlineEdit(wire.id), "a wire has no value to type in place")
        }
        editor.selection = [rid]
        canvas.keyDown(with: key(36, "\r"))
        check(canvas.inlineEditField != nil, "Return with a part selected opens its value")
        canvas.cancelInlineEdit()

        // Esc steps back: the tool first, then the selection
        editor.selection = [rid]
        editor.tool = .capacitor
        canvas.keyDown(with: key(53, "\u{1B}"))
        check(editor.tool == nil && editor.selection == [rid], "Esc puts the tool away and keeps the selection")
        canvas.keyDown(with: key(53, "\u{1B}"))
        check(editor.selection.isEmpty, "a second Esc clears the selection")

        editor.tool = nil
        editor.selection = []
        canvas.mouseExited(with: mouse(.mouseMoved, GridPoint(0, 0)))
        await pause(0.1)
    }
}
