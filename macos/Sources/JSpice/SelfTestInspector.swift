import AppKit
import SwiftUI
import CircuitKit

extension InteractionTest {
    /// The inspector with several parts selected: a value set for all of them is one undo step, choosing a model gives
    /// it to all, parts of different kinds offer only what they have in common; and the arrow keys' E-series steps.
    /// (Each edit here is an undo step of its own.)
    static func checkInspector(editor: EditorState, document: CircuitDocument) async {
        // the editor holds its undo manager weakly: this keeps it. The self-test's does not group by event, so each
        // edit here is an undo step of its own (see `EditorState.registerUndo`).
        let undo: UndoManager
        if let existing = editor.undoManager {
            undo = existing
        } else {
            undo = UndoManager()
            undo.groupsByEvent = false
            editor.undoManager = undo
        }
        // (whichever the editor registers with, should the window hand it its own meanwhile)
        func undoLast() { (editor.undoManager ?? undo).undo() }
        func undoName() -> String { (editor.undoManager ?? undo).undoActionName }
        guard let resistance = ElementKind.resistor.params.first(where: { $0.key == "resistance" }) else {
            check(false, "a resistor has a resistance")
            return
        }

        // three resistors of different values, a capacitor and two op-amps on different models
        var circuit = Circuit()
        let values: [Double] = [1000, 2200, 4700]
        let resistors = values.enumerated().map { i, value in
            circuit.add(Element(kind: .resistor, name: "R\(i + 1)", a: GridPoint(0, 4 * i), b: GridPoint(4, 4 * i),
                                params: ["resistance": value]))
        }
        let capacitor = circuit.add(Element(kind: .capacitor, name: "C1", a: GridPoint(8, 0), b: GridPoint(8, 4),
                                            params: ["capacitance": 1e-6]))
        let models = ElementKind.opAmp.models
        var opAmps: [UUID] = []
        if models.count >= 2 {
            for (i, model) in models.prefix(2).enumerated() {
                opAmps.append(circuit.add(Element(kind: .opAmp, name: "U\(i + 1)", a: GridPoint(12, 6 * i), b: GridPoint(16, 6 * i),
                                                  params: model.values)))
            }
        }
        editor.edit("Inspector Check") { $0 = circuit }
        editor.selection = Set(resistors)
        await pause(0.4)

        let parts = MultiEdit.parts(editor.selection, in: document.circuit)
        check(parts.count == 3 && MultiEdit.kinds(of: parts) == [.resistor] && MultiEdit.commonValue(parts, "resistance") == nil,
              "three resistors of different values are edited together, their resistance shown as mixed")
        check(MultiEdit.summary(editor.selection, in: document.circuit) == "3 resistors", "the inspector counts the selection by kind")

        // one value for all three, as one undo step
        editor.setParameter(editor.selection, resistance, to: 10_000)
        await pause(0.2)
        check(resistors.allSatisfy { document.circuit[$0]?[param: "resistance"] == 10_000 },
              "a resistance set with three resistors selected is given to all three")
        check(undoName() == "Change Resistance", "and named as one change (\(undoName()))")
        undoLast()
        await pause(0.2)
        check(zip(resistors, values).allSatisfy { document.circuit[$0.0]?[param: "resistance"] == $0.1 },
              "one undo gives all three their own values back")

        // a model chosen for several op-amps
        if opAmps.count == 2, let model = models.first {
            editor.selection = Set(opAmps)
            await pause(0.2)
            check(MultiEdit.commonModel(MultiEdit.parts(editor.selection, in: document.circuit)).mixed,
                  "op-amps on different models show their model as mixed")
            editor.applyModel(editor.selection, model)
            await pause(0.2)
            check(opAmps.allSatisfy { document.circuit[$0]?.model?.name == model.name }, "a model chosen for two op-amps is given to both")
            undoLast()
            await pause(0.2)
            check(document.circuit[opAmps[1]]?.model?.name == models[1].name, "one undo puts the second op-amp's model back")
        }

        // different kinds: only what they have in common
        editor.selection = Set(resistors + [capacitor])
        await pause(0.3)
        let kinds = MultiEdit.kinds(of: MultiEdit.parts(editor.selection, in: document.circuit))
        check(kinds == [.resistor, .capacitor] && MultiEdit.commonParams(kinds).isEmpty,
              "resistors with a capacitor have no values in common to edit")
        check(MultiEdit.summary(editor.selection, in: document.circuit) == "3 resistors, 1 capacitor",
              "a mixed selection is counted by kind (\(MultiEdit.summary(editor.selection, in: document.circuit)))")
        check(MultiEdit.commonParams([.resistor, .potentiometer]).map(\.key) == ["resistance"],
              "a resistor and a potentiometer share their resistance, and nothing else")

        // the arrow keys in a resistance's field
        check(ParameterStepping.step(4700, resistance, up: true) == 5600 && ParameterStepping.step(5600, resistance, up: false) == 4700,
              "↑ steps 4.7k up to 5.6k in E12, and ↓ back")
        check(ParameterStepping.step(4700, resistance, up: true, finer: true) == 5100, "with ⌥, the E24 value 5.1k")

        editor.selection = []
        await pause(0.2)
    }
}
