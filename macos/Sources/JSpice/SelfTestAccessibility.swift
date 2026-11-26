import AppKit
import CircuitKit

/// The schematic as assistive technology sees it (CanvasAccessibility.swift): a child element for each part, with a
/// name and kind, a frame on the canvas, and actions that operate switches and knobs as the mouse does.
extension InteractionTest {
    static func checkAccessibility(editor: EditorState, document: CircuitDocument, canvas: CircuitCanvasView) async {
        // every edit in its own undo group, whether or not the undo manager groups by event
        func grouped(_ change: () -> Void) {
            let undo = editor.undoManager
            undo?.beginUndoGrouping()
            change()
            undo?.endUndoGrouping()
        }
        func parts() -> [CanvasPartElement] {
            (canvas.accessibilityChildren() ?? []).compactMap { $0 as? CanvasPartElement }
        }
        func child(_ kind: ElementKind) -> CanvasPartElement? { parts().first { $0.kind == kind } }

        grouped { editor.load(Examples.example("led")!) }
        await pause(0.6)
        let described = document.circuit.elements.filter(CircuitDescription.isDescribed)
        let children = parts()
        check(canvas.isAccessibilityElement() && canvas.accessibilityRole() == .group
                && canvas.accessibilityLabel()?.hasPrefix("Schematic: ") == true,
              "the canvas is an accessibility group labelled with its summary (\(canvas.accessibilityLabel() ?? "no label"))")
        check(children.count == described.count && !children.isEmpty,
              "the canvas has a child for each part but its wires and ground (\(children.count) of \(described.count))")
        check(children.allSatisfy { !($0.accessibilityLabel() ?? "").isEmpty },
              "every part's child has a label (\(children.compactMap { $0.accessibilityLabel() }.joined(separator: "; ")))")
        let resistor = child(.resistor)
        check(resistor?.accessibilityLabel() == "R1, resistor", "a part's label is its name and kind (\(resistor?.accessibilityLabel() ?? "none"))")
        check((resistor?.accessibilityHelp() ?? "").hasPrefix("Between "),
              "its help says what it connects (\(resistor?.accessibilityHelp() ?? "none"))")
        check(((resistor?.accessibilityValue() as? String) ?? "").contains("Ω"),
              "its value is the one the canvas writes beside it (\((resistor?.accessibilityValue() as? String) ?? "none"))")

        // frames: on screen, inside the canvas
        if let window = canvas.window {
            let bounds = window.convertToScreen(canvas.convert(canvas.bounds, to: nil)).insetBy(dx: -1, dy: -1)
            let frames = children.map { $0.accessibilityFrame() }
            check(frames.allSatisfy { $0.width > 0 && $0.height > 0 }, "every part's frame has a size")
            check(frames.allSatisfy { bounds.contains($0) }, "and lies inside the canvas (\(frames.filter { !bounds.contains($0) }.count) outside)")
            if let toggle = child(.toggleSwitch) {
                let frame = toggle.accessibilityFrame()
                let hit = canvas.accessibilityHitTest(NSPoint(x: frame.midX, y: frame.midY)) as? CanvasPartElement
                check(hit === toggle, "hit-testing the middle of the switch's frame finds the switch")
            }
        } else {
            check(false, "the canvas is in a window")
        }

        // the switch's press flips it, as a click does
        if let toggle = child(.toggleSwitch), let before = document.circuit[toggle.partID]?.closed {
            check(toggle.accessibilityRole() == .checkBox, "a switch is a toggle")
            grouped { _ = toggle.accessibilityPerformPress() }
            await pause(0.1)
            check(document.circuit[toggle.partID]?.closed == !before, "pressing the switch's element flips the switch")
            check((toggle.accessibilityValue() as? NSNumber)?.boolValue == !before, "and its value follows")
            grouped { _ = toggle.accessibilityPerformPress() }
            check(document.circuit[toggle.partID]?.closed == before, "pressing it again flips it back")
        } else {
            check(false, "the LED example's switch has an element")
        }
        // another part's press selects it, for the inspector to edit
        if let resistor {
            grouped { _ = resistor.accessibilityPerformPress() }
            check(editor.selection == [resistor.partID], "pressing another part's element selects it")
            await pause(0.4)
            _ = parts()
            check(resistor.isAccessibilitySelected(), "and its element is selected")
            check((canvas.accessibilitySelectedChildren() ?? []).count == 1, "the canvas reports one selected child")
        }

        // a potentiometer turns with increment and decrement
        grouped { editor.load(Examples.example("dimmer")!) }
        await pause(0.6)
        if let pot = child(.potentiometer), let start = document.circuit[pot.partID]?[param: "position"] {
            check(pot.accessibilityRole() == .slider, "a potentiometer is a slider")
            grouped { _ = pot.accessibilityPerformIncrement() }
            let up = document.circuit[pot.partID]?[param: "position"] ?? start
            check(abs(up - start - CanvasAccessibility.potentiometerStep) < 1e-9,
                  "incrementing the potentiometer's element turns it up (\(start) to \(up))")
            grouped { _ = pot.accessibilityPerformDecrement() }
            check(abs((document.circuit[pot.partID]?[param: "position"] ?? 0) - start) < 1e-9, "and decrementing turns it back")
            check((pot.accessibilityValue() as? NSNumber)?.intValue == Int((start * 100).rounded()), "its value is its position in percent")
            check(child(.npn).flatMap { $0.accessibilityHelp() }?.contains("base to") == true,
                  "a transistor's help names what its base connects to (\(child(.npn)?.accessibilityHelp() ?? "none"))")
        } else {
            check(false, "the dimmer's potentiometer has an element")
        }
        grouped { editor.selection = [] }
    }
}
