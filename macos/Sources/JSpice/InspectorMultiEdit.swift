import SwiftUI
import CircuitKit

/// Several parts selected: what they are, counted by kind; the model and the parameters they share, edited for all of
/// them at once (each change one undo step); and Rotate, Flip and Delete. Wires, grounds and net labels in the selection
/// are counted but have nothing to edit (`MultiEdit`).
struct MultiSelectionInspector: View {
    @ObservedObject var editor: EditorState
    let ids: Set<UUID>
    /// (passed in, so that the view follows each edit of the document)
    let circuit: Circuit

    var body: some View {
        let parts = MultiEdit.parts(ids, in: circuit)
        let kinds = MultiEdit.kinds(of: parts)
        Form {
            Section {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(MultiEdit.summary(ids, in: circuit))
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(circuit.elements.filter { ids.contains($0.id) }.count) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    PartActions(editor: editor, canFlip: editor.canFlipSelection)
                }
            }
            if kinds.count == 1, let kind = kinds.first, !kind.models.isEmpty {
                MultiModelSection(editor: editor, ids: ids, kind: kind, parts: parts)
            }
            MultiPropertiesSection(editor: editor, ids: ids, kinds: kinds, parts: parts)
        }
        .formStyle(.grouped)
    }
}

/// The model of parts of one kind: the one they share, or Mixed; choosing one gives it to them all
private struct MultiModelSection: View {
    let editor: EditorState
    let ids: Set<UUID>
    let kind: ElementKind
    let parts: [Element]

    private static let mixedTag = "\u{1}mixed"

    var body: some View {
        let common = MultiEdit.commonModel(parts)
        Section {
            Picker("Model", selection: Binding(
                get: { common.mixed ? Self.mixedTag : common.model?.name ?? "" },
                set: { name in
                    if let model = kind.models.first(where: { $0.name == name }) { editor.applyModel(ids, model) }
                }
            )) {
                ForEach(kind.models, id: \.name) { model in
                    Text(model.title).tag(model.name)
                }
                if common.mixed {
                    Text("Mixed").tag(Self.mixedTag)
                } else if common.model == nil {
                    Text("Custom").tag("")
                }
            }
        } footer: {
            Text(common.mixed ? "The parts have different models. One chosen here is given to all \(parts.count)."
                    : common.model?.summary ?? "Values changed from the chosen model.")
        }
    }
}

/// The parameters the parts have in common, each showing the value they share or Mixed
private struct MultiPropertiesSection: View {
    let editor: EditorState
    let ids: Set<UUID>
    let kinds: [ElementKind]
    let parts: [Element]

    var body: some View {
        let common = MultiEdit.commonParams(kinds)
        if !common.isEmpty {
            Section {
                ForEach(common, id: \.key) { spec in
                    MultiParameterControl(editor: editor, ids: ids, spec: spec, ledColor: kinds == [.led] && spec.key == "color",
                                          value: MultiEdit.commonValue(parts, spec.key))
                }
            } header: {
                Text(kinds.count == 1 ? "Properties" : "Properties in Common")
            } footer: {
                Text(kinds.count == 1 ? "A value set here is given to all \(MultiEdit.counted(parts.count, kinds[0]))."
                        : "A value set here is given to each selected part (they all have it).")
            }
        } else if kinds.count > 1 {
            Section {
                Text("These parts have no values in common. Select parts of one kind to set their values together.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One shared parameter: a typed value, a setting, or an LED's color
private struct MultiParameterControl: View {
    let editor: EditorState
    let ids: Set<UUID>
    let spec: ParamSpec
    let ledColor: Bool
    let value: Double?

    var body: some View {
        if ledColor {
            Picker(spec.name, selection: Binding(
                get: { value.map { Int($0) } ?? -1 },
                set: { if $0 >= 0 { editor.setParameter(ids, spec, to: Double($0)) } }
            )) {
                ForEach(LEDColor.allCases, id: \.rawValue) { color in
                    Text(color.name).tag(color.rawValue)
                }
                if value == nil { Text("Mixed").tag(-1) }
            }
        } else if !spec.choices.isEmpty {
            Picker(spec.name, selection: Binding(
                get: { value ?? -Double.infinity },
                set: { if $0.isFinite { editor.setParameter(ids, spec, to: $0) } }
            )) {
                ForEach(spec.choices, id: \.value) { choice in
                    Text(choice.name).tag(choice.value)
                }
                if let value, !spec.choices.contains(where: { $0.value == value }) {
                    Text(formatParameter(value, spec)).tag(value)
                }
                if value == nil { Text("Mixed").tag(-Double.infinity) }
            }
        } else {
            MultiParameterRow(editor: editor, ids: ids, spec: spec, value: value)
        }
    }
}

/// A typed value for several parts (no slider: from different values, a slider would have no one place to start)
private struct MultiParameterRow: View {
    let editor: EditorState
    let ids: Set<UUID>
    let spec: ParamSpec
    let value: Double?
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(spec.name) {
                ParameterField(spec: spec, value: value, text: $text, invalid: $invalid) { parsed in
                    editor.setParameter(ids, spec, to: parsed)
                }
            }
            if invalid { InvalidValueNote() }
        }
    }
}
