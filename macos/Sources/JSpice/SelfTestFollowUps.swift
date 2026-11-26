import AppKit
import CircuitKit

extension InteractionTest {
    /// A paste holding a part this version cannot read, the selected part's commands in the Circuit menu (the same
    /// as a right-click's), operating a selected switch, push button and pot from the keyboard, and a push button
    /// pressed by a click on its body or on a free terminal
    static func checkFollowUps(editor: EditorState, document: CircuitDocument, window: NSWindow, canvas: CircuitCanvasView) async {
        func mouse(_ type: NSEvent.EventType, _ point: GridPoint) -> NSEvent {
            let location = canvas.convert(canvas.screen(point), to: nil)
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func key(_ type: NSEvent.EventType, _ code: UInt16, _ characters: String, shift: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shift ? [.shift] : [],
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        func elements(_ kind: ElementKind) -> [Element] { document.circuit.elements.filter { $0.kind == kind } }

        // a toggle switch, a push button and a potentiometer on their own, apart
        let toggle = Element(kind: .toggleSwitch, name: "S1", a: GridPoint(0, 0), b: GridPoint(4, 0))
        let button = Element(kind: .pushButton, name: "B1", a: GridPoint(0, 4), b: GridPoint(4, 4))
        let pot = Element(kind: .potentiometer, name: "P1", a: GridPoint(0, 8), b: GridPoint(4, 8))
        let resistor = Element(kind: .resistor, name: "R1", a: GridPoint(0, 12), b: GridPoint(4, 12))
        editor.edit("Follow-up Check") { $0 = Circuit(elements: [toggle, button, pot, resistor]) }
        editor.selection = []
        editor.tool = nil
        editor.requestFit()
        await pause(0.4)
        editor.viewAdjusted = true
        window.makeFirstResponder(canvas)

        // MARK: a paste with a part from a newer JSpice
        if let known = try? JSONEncoder().encode(resistor),
           let knownValue = try? JSONDecoder().decode(JSONValue.self, from: known) {
            let future: JSONValue = .object([
                "id": .string(UUID().uuidString), "kind": .string("quantumFluxCapacitor"), "name": .string("Q1"),
                "a": .object(["x": .number(0), "y": .number(0)]), "b": .object(["x": .number(4), "y": .number(0)]),
            ])
            if let data = try? JSONEncoder().encode(JSONValue.array([knownValue, future])) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setData(data, forType: EditorState.pasteboardType)
                editor.notices = []
                let before = elements(.resistor).count
                editor.paste(at: GridPoint(12, 12))
                await pause(0.05)
                check(elements(.resistor).count == before + 1 && editor.selection.count == 1,
                      "a paste with a part this version cannot read pastes the others")
                check(editor.notices.contains { $0.kind == .warning && $0.title == "1 part was left out of the paste" },
                      "and a notice says one part was left out (got \(editor.notices.map(\.title)))")
                check(editor.notices.contains { ($0.detail ?? "").contains("quantumFluxCapacitor") },
                      "naming its kind")
                editor.notices = []
                editor.deleteSelection()
                await pause(0.05)
            }
        }

        // MARK: the Circuit menu's part commands, as a right-click offers them
        let resistorMeasures = PartMeasure.all(for: .resistor).map(\.title)
        for title in ["Add I\u{2013}V Curve Scope", "Add Frequency Response", "Add Spectrum"] {
            check(resistorMeasures.contains(title), "Circuit \u{25B8} Measure offers \(title) for a resistor")
        }
        check(!PartMeasure.all(for: .dcVoltage).map(\.title).contains("Add Frequency Response"),
              "a source that drives the circuit has no frequency response to measure")
        check(PartMeasure.all(for: .loopProbe).map(\.title).contains("Add Loop Gain"), "a loop probe's response is its loop gain")
        check(PartMeasure.all(for: .ground).isEmpty, "a ground has nothing to measure")
        let menu = canvas.menu(for: mouse(.rightMouseDown, GridPoint(2, 12)))
        let titles = menu?.items.map(\.title) ?? []
        check(resistorMeasures.allSatisfy { titles.contains($0) }, "a right-click on the resistor offers the same measurements (got \(titles))")
        if let id = elements(.resistor).first?.id, let measure = PartMeasure.all(for: .resistor).first(where: { $0.plot == .spectrum }) {
            let scopes = document.circuit.scopes.count
            editor.addMeasure(measure, to: id)
            check(document.circuit.scopes.count == scopes + 1 && document.circuit.scopes.last?.plot == .spectrum,
                  "Measure \u{25B8} Add Spectrum adds a spectrum scope of the part")
        }
        if let live = document.circuit[pot.id] {
            check(PartCommands.canLearnMIDI(live) && PartCommands.learnTitle(live, editor) == "MIDI Learn",
                  "a potentiometer can learn a MIDI controller")
            check(PartCommands.forgetTitle(live, editor) == nil, "with none mapped, there is nothing to forget")
            editor.edit("Map MIDI") { $0.learnMIDI(controller: 7, channel: nil, part: pot.id) }
            if let mapped = document.circuit[pot.id], let title = PartCommands.forgetTitle(mapped, editor) {
                let potMenu = canvas.menu(for: mouse(.rightMouseDown, GridPoint(2, 8)))?.items.map(\.title) ?? []
                check(potMenu.contains(title), "Forget is offered for the mapped pot in both menus (\(title))")
            } else {
                check(false, "once mapped, the pot's controller can be forgotten")
            }
            editor.forgetMIDI(part: pot.id)
        }
        if let live = document.circuit[resistor.id] {
            check(!PartCommands.canLearnMIDI(live) && !PartCommands.canOpenBlock(live) && !PartCommands.canUpdateFromLibrary(live),
                  "a resistor has no MIDI Learn or block commands")
        }

        // MARK: the selected part operated from the keyboard
        editor.selection = [toggle.id]
        let wasClosed = document.circuit[toggle.id]?.closed ?? false
        canvas.keyDown(with: key(.keyDown, 47, "."))
        check(document.circuit[toggle.id]?.closed == !wasClosed, "\".\" flips the selected switch")
        canvas.keyDown(with: key(.keyDown, 47, "."))
        check(document.circuit[toggle.id]?.closed == wasClosed, "and \".\" again flips it back")

        editor.selection = [button.id]
        canvas.keyDown(with: key(.keyDown, 47, "."))
        check(document.circuit[button.id]?.closed == true, "\".\" holds the selected push button down")
        canvas.keyUp(with: key(.keyUp, 47, "."))
        check(document.circuit[button.id]?.closed == false, "and letting go of the key lets it go")

        editor.selection = [pot.id]
        let start = document.circuit[pot.id]?[param: "position"] ?? 0
        canvas.keyDown(with: key(.keyDown, 30, "]"))
        let up = document.circuit[pot.id]?[param: "position"] ?? 0
        check(abs(up - min(1, start + 0.05)) < 1e-9, "\"]\" turns the selected pot up 5 % (\(start) to \(up))")
        canvas.keyDown(with: key(.keyDown, 33, "{", shift: true))
        let fine = document.circuit[pot.id]?[param: "position"] ?? 0
        check(abs(fine - (up - 0.01)) < 1e-9, "\"⇧[\" turns it down 1 % (to \(fine))")
        canvas.keyDown(with: key(.keyDown, 33, "["))
        check(abs((document.circuit[pot.id]?[param: "position"] ?? 0) - (fine - 0.05)) < 1e-9, "\"[\" turns it down 5 %")
        // and the keys leave other parts and the tools alone
        editor.selection = [resistor.id]
        let toolBefore = editor.tool
        canvas.keyDown(with: key(.keyDown, 47, "."))
        check(editor.tool == toolBefore && document.circuit[resistor.id] == resistor, "\".\" does nothing to a resistor")

        // MARK: a push button pressed by its body, and by a click on its free terminal
        editor.selection = []
        canvas.mouseDown(with: mouse(.leftMouseDown, GridPoint(2, 4)))
        check(document.circuit[button.id]?.closed == true, "pressing the push button's body presses it")
        canvas.mouseUp(with: mouse(.leftMouseUp, GridPoint(2, 4)))
        check(document.circuit[button.id]?.closed == false, "and it lets go with the mouse")

        editor.selection = []
        check(document.circuit.isFreeTerminal(GridPoint(0, 4)), "the push button's terminals are free")
        let wires = elements(.wire).count
        canvas.mouseDown(with: mouse(.leftMouseDown, GridPoint(0, 4)))
        check(document.circuit[button.id]?.closed == true, "the mouse going down on its free terminal presses it too")
        canvas.mouseUp(with: mouse(.leftMouseUp, GridPoint(0, 4)))
        check(document.circuit[button.id]?.closed == false && elements(.wire).count == wires,
              "a click there lets it go and draws no wire")

        editor.selection = []
        canvas.mouseDown(with: mouse(.leftMouseDown, GridPoint(0, 4)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, GridPoint(-4, 6)))
        check(document.circuit[button.id]?.closed == false, "a drag away from the terminal lets the button go")
        canvas.mouseUp(with: mouse(.leftMouseUp, GridPoint(-4, 6)))
        check(elements(.wire).count > wires && document.circuit[button.id]?.closed == false,
              "and draws a wire from it, the button left released")

        editor.selection = []
        editor.tool = nil
        canvas.mouseExited(with: mouse(.mouseMoved, GridPoint(0, 0)))
        await pause(0.1)
    }
}
