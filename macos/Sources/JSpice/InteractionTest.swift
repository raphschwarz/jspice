import AppKit
import SwiftUI
import CircuitKit

/// `JSpice --self-test <directory>` drives a real window with synthesized mouse and keyboard events: it draws a circuit by
/// hand, checks that it simulates, moves, deletes and undoes, and operates a switch. It exits with status 1 on any failure.
@MainActor
enum InteractionTest {
    private static var failures: [String] = []

    private static func check(_ condition: Bool, _ description: String) {
        print(condition ? "PASS  \(description)" : "FAIL  \(description)")
        if !condition { failures.append(description) }
    }

    static func run(screenshots directory: URL) async -> Bool {
        failures = []
        NSApp.appearance = NSAppearance(named: .aqua)
        let document = CircuitDocument()
        let editor = EditorState(document: document)

        let controller = NSHostingController(rootView: EditorView(document: document, editor: editor))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "Drawn by hand"
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        await pause(0.8)

        guard let canvas = findCanvas(in: window.contentView) else {
            check(false, "the window contains the circuit canvas")
            return false
        }
        check(editor.undoManager != nil, "the window gives the editor an undo manager")
        // From here on, an undo manager of the test's own, with one undo group per action, as AppKit makes one per
        // event in the app. (Set after the window appeared, so SwiftUI does not replace it.)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo

        func mouse(_ type: NSEvent.EventType, _ point: GridPoint) -> NSEvent {
            let location = canvas.convert(canvas.screen(point), to: nil)
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func drag(_ from: GridPoint, _ to: GridPoint) async {
            undo.beginUndoGrouping()
            canvas.mouseDown(with: mouse(.leftMouseDown, from))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, to))
            canvas.mouseUp(with: mouse(.leftMouseUp, to))
            undo.endUndoGrouping()
            await pause(0.05)
        }
        func click(_ point: GridPoint) async { await drag(point, point) }
        func undoLast() async {
            undo.undo()
            await pause(0.1)
        }
        func elements(_ kind: ElementKind) -> [Element] { document.circuit.elements.filter { $0.kind == kind } }
        func index(of id: UUID) -> Int? { editor.simulation.simulator.circuit.index(of: id) }

        // draw a circuit: battery, resistor, two wires, ground
        editor.tool = .dcVoltage
        await drag(GridPoint(0, 4), GridPoint(0, 0))
        check(elements(.dcVoltage).first.map { $0.a == GridPoint(0, 4) && $0.b == GridPoint(0, 0) } ?? false,
              "dragging places a voltage source between the two points")
        editor.tool = .resistor
        await click(GridPoint(0, 0))
        let resistor = elements(.resistor).first
        check(resistor.map { $0.a == GridPoint(0, 0) && $0.b == GridPoint(4, 0) } ?? false,
              "clicking places a resistor of the default length")
        editor.tool = .wire
        await drag(GridPoint(4, 0), GridPoint(4, 4))
        await drag(GridPoint(4, 4), GridPoint(0, 4))
        check(elements(.wire).count == 2, "dragging draws wires")
        editor.tool = .ground
        await click(GridPoint(0, 4))
        check(elements(.ground).first?.a == GridPoint(0, 4), "clicking places a ground")
        editor.tool = nil
        await pause(0.6)

        guard let resistorID = resistor?.id else { return finish(window) }
        let current = index(of: resistorID).map { editor.simulation.simulator.current($0) } ?? 0
        check(abs(current - 0.005) < 1e-6, "the hand-drawn circuit simulates: 5 V across 1 kΩ gives 5 mA (got \(SI.format(current, unit: "A")))")
        editor.selection = []
        await pause(0.3)
        capture(window, to: directory.appendingPathComponent("8-drawn-by-hand.png"))

        // select and move; the attached wire stretches
        await click(GridPoint(2, 0))
        check(editor.selection == [resistorID], "clicking a part selects it")
        await drag(GridPoint(2, 0), GridPoint(2, -2))
        let moved = document.circuit[resistorID]
        check(moved?.a == GridPoint(0, -2) && moved?.b == GridPoint(4, -2), "dragging moves the selected part")
        check(elements(.wire).contains { $0.a == GridPoint(4, -2) && $0.b == GridPoint(4, 4) }, "a wire attached to a moved part stretches")
        check(undo.undoActionName == "Move", "the move is named in the Edit menu (\"Undo Move\")")
        await undoLast()
        check(document.circuit[resistorID]?.a == GridPoint(0, 0), "undo puts the part back")
        check(document.circuit.elements.contains { $0.kind == .wire && $0.a == GridPoint(4, 0) && $0.b == GridPoint(4, 4) },
              "undo puts the stretched wire back too")
        undo.redo()
        await pause(0.05)
        check(document.circuit[resistorID]?.a == GridPoint(0, -2), "redo moves it again")
        await undoLast()

        // delete with the keyboard, then undo
        editor.selection = [resistorID]
        undo.beginUndoGrouping()
        canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, characters: "\u{7F}",
                                              charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51)!)
        undo.endUndoGrouping()
        await pause(0.05)
        check(document.circuit[resistorID] == nil, "the Delete key removes the selection")
        await undoLast()
        check(document.circuit[resistorID] != nil, "undo restores the deleted part")

        // a part dropped onto the middle of a wire joins it with a T-junction
        editor.tool = .resistor
        await drag(GridPoint(2, 4), GridPoint(2, 8))
        editor.tool = nil
        let wires = elements(.wire)
        check(wires.count == 3 && wires.contains { Set([$0.a, $0.b]) == [GridPoint(4, 4), GridPoint(2, 4)] }
                && wires.contains { Set([$0.a, $0.b]) == [GridPoint(2, 4), GridPoint(0, 4)] },
              "a terminal placed on a wire splits it into a junction")
        await undoLast()
        check(elements(.wire).count == 2 && elements(.resistor).count == 1, "undo removes the part and rejoins the wire")

        // turning a potentiometer is live, not an undo step
        editor.tool = .potentiometer
        await drag(GridPoint(8, 0), GridPoint(12, 0))
        editor.tool = nil
        if let pot = elements(.potentiometer).first {
            let undoName = undo.undoActionName
            editor.turnPotentiometer(pot.id, by: 0.3)
            check(abs((document.circuit[pot.id]?[param: "position"] ?? 0) - 0.8) < 1e-9 && undo.undoActionName == undoName,
                  "turning a potentiometer moves its wiper without an undo step")
            editor.turnPotentiometer(pot.id, by: 5)
            check(document.circuit[pot.id]?[param: "position"] == 1, "a potentiometer stops at the end of its track")
        } else {
            check(false, "the potentiometer tool places a potentiometer")
        }

        // operate a switch while simulating
        undo.beginUndoGrouping()
        editor.load(Examples.example("led")!)
        undo.endUndoGrouping()
        await pause(0.8)
        let led = elements(.led).first!.id
        let switchElement = elements(.toggleSwitch).first!
        let brightnessBefore = index(of: led).map { editor.simulation.simulator.brightness($0) } ?? 0
        check(brightnessBefore > 0.9, "the LED example lights its LED")
        let middle = GridPoint((switchElement.a.x + switchElement.b.x) / 2, (switchElement.a.y + switchElement.b.y) / 2)
        await click(middle)
        await pause(0.4)
        check(document.circuit[switchElement.id]?.closed == false, "clicking a switch opens it")
        let brightnessAfter = index(of: led).map { editor.simulation.simulator.brightness($0) } ?? 1
        check(brightnessAfter < 0.01, "opening the switch turns the LED off")

        return finish(window)
    }

    private static func finish(_ window: NSWindow) -> Bool {
        window.orderOut(nil)
        window.close()
        print(failures.isEmpty ? "All interaction checks passed." : "\(failures.count) interaction check(s) failed.")
        return failures.isEmpty
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func findCanvas(in view: NSView?) -> CircuitCanvasView? {
        guard let view else { return nil }
        if let canvas = view as? CircuitCanvasView { return canvas }
        for subview in view.subviews {
            if let canvas = findCanvas(in: subview) { return canvas }
        }
        return nil
    }

    static func capture(_ window: NSWindow, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.path]
        try? process.run()
        process.waitUntilExit()
    }
}
