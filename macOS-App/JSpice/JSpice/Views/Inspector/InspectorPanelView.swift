import SwiftUI

// MARK: - Inspector Panel (Right Sidebar)

struct InspectorPanelView: View {
    @Binding var document: CircuitDocument
    @ObservedObject var editorState: SchematicEditorState

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Inspector", systemImage: "sidebar.right")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let selectedID = editorState.selectedComponentID,
                       let componentIndex = document.components.firstIndex(where: { $0.id == selectedID }) {
                        ComponentInspector(
                            component: $document.components[componentIndex]
                        )
                    } else if !editorState.selectedComponentIDs.isEmpty {
                        MultiSelectionInspector(
                            count: editorState.selectedComponentIDs.count
                        )
                    } else {
                        CircuitInspector(document: $document)
                    }
                }
                .padding(12)
            }
        }
        .background(.ultraThinMaterial)
    }
}

// MARK: - Component Inspector

struct ComponentInspector: View {
    @Binding var component: SchematicComponent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Component info header
            HStack(spacing: 8) {
                Image(systemName: component.type.symbolName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(.quaternary)
                    .cornerRadius(6)

                VStack(alignment: .leading) {
                    Text(component.type.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(component.type.category.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Label
            InspectorField(label: "Label") {
                TextField("Label", text: $component.label)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            // Model name (if applicable)
            if component.type.category == .semiconductor {
                InspectorField(label: "Model") {
                    TextField("e.g., 2N3904", text: Binding(
                        get: { component.modelName ?? "" },
                        set: { component.modelName = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                }
            }

            Divider()

            // Parameters
            Text("Parameters")
                .font(.subheadline.weight(.semibold))

            ForEach(Array(component.parameters.keys.sorted()), id: \.self) { key in
                if let param = component.parameters[key] {
                    ParameterEditor(
                        key: key,
                        parameter: Binding(
                            get: { component.parameters[key] ?? param },
                            set: { component.parameters[key] = $0 }
                        )
                    )
                }
            }

            Divider()

            // Transform
            Text("Transform")
                .font(.subheadline.weight(.semibold))

            InspectorField(label: "Rotation") {
                Picker("", selection: $component.rotation) {
                    Text("0°").tag(0.0)
                    Text("90°").tag(90.0)
                    Text("180°").tag(180.0)
                    Text("270°").tag(270.0)
                }
                .pickerStyle(.segmented)
            }

            Toggle("Mirror", isOn: $component.isMirrored)

            InspectorField(label: "Position") {
                HStack {
                    Text("X:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("", value: Binding(
                        get: { component.position.x },
                        set: { component.position.x = $0 }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)

                    Text("Y:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("", value: Binding(
                        get: { component.position.y },
                        set: { component.position.y = $0 }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                }
            }
        }
    }
}

// MARK: - Parameter Editor

struct ParameterEditor: View {
    let key: String
    @Binding var parameter: ComponentParameter

    @State private var textValue: String = ""
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(parameter.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(parameter.unit.symbol)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                // Use @State textValue to avoid infinite update loops
                // Only sync from parameter -> text when not actively editing
                TextField(parameter.name, text: $textValue, onEditingChanged: { editing in
                    isEditing = editing
                    if editing {
                        // Starting edit: show current formatted value
                        textValue = formatValue(parameter.value)
                    }
                })
                .onSubmit {
                    if let parsed = parseEngineering(textValue) {
                        parameter.value = max(parameter.min, min(parameter.max, parsed))
                    }
                    textValue = formatValue(parameter.value)
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onChange(of: parameter.value) { _, newValue in
                    if !isEditing {
                        textValue = formatValue(newValue)
                    }
                }
                .onAppear {
                    textValue = formatValue(parameter.value)
                }

                // Quick adjustment buttons
                Button(action: {
                    parameter.value = max(parameter.min, parameter.value / 10)
                }) {
                    Image(systemName: "minus")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)

                Button(action: {
                    parameter.value = min(parameter.max, parameter.value * 10)
                }) {
                    Image(systemName: "plus")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
            }

            // Logarithmic slider — only show when range is valid for log scale
            if sliderRange != nil {
                Slider(
                    value: Binding(
                        get: { log10(max(abs(parameter.value), 1e-18)) },
                        set: { parameter.value = pow(10, $0) * (parameter.value < 0 ? -1 : 1) }
                    ),
                    in: sliderRange!
                )
            }
        }
        .padding(.vertical, 2)
    }

    /// Compute safe slider range, returning nil if range is degenerate
    private var sliderRange: ClosedRange<Double>? {
        let absMin = max(abs(parameter.min), 1e-18)
        let absMax = max(abs(parameter.max), 1e-18)
        let logMin = log10(min(absMin, absMax))
        let logMax = log10(max(absMin, absMax))
        guard logMax > logMin + 0.01 else { return nil }
        return logMin...logMax
    }

    private func formatValue(_ value: Double) -> String {
        let absValue = abs(value)
        let sign = value < 0 ? "-" : ""
        if absValue >= 1e9 { return "\(sign)\(String(format: "%.3f", absValue / 1e9))G" }
        if absValue >= 1e6 { return "\(sign)\(String(format: "%.3f", absValue / 1e6))M" }
        if absValue >= 1e3 { return "\(sign)\(String(format: "%.3f", absValue / 1e3))k" }
        if absValue >= 1 { return "\(sign)\(String(format: "%.3f", absValue))" }
        if absValue >= 1e-3 { return "\(sign)\(String(format: "%.3f", absValue * 1e3))m" }
        if absValue >= 1e-6 { return "\(sign)\(String(format: "%.3f", absValue * 1e6))u" }
        if absValue >= 1e-9 { return "\(sign)\(String(format: "%.3f", absValue * 1e9))n" }
        if absValue >= 1e-12 { return "\(sign)\(String(format: "%.3f", absValue * 1e12))p" }
        return String(format: "%e", value)
    }

    private func parseEngineering(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let multipliers: [(String, Double)] = [
            ("G", 1e9), ("M", 1e6), ("k", 1e3), ("K", 1e3),
            ("m", 1e-3), ("u", 1e-6), ("μ", 1e-6), ("n", 1e-9), ("p", 1e-12), ("f", 1e-15)
        ]

        for (suffix, multiplier) in multipliers {
            if trimmed.hasSuffix(suffix) {
                let numStr = String(trimmed.dropLast(suffix.count))
                if let num = Double(numStr) {
                    return num * multiplier
                }
            }
        }

        return Double(trimmed)
    }
}

// MARK: - Inspector Field

struct InspectorField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
    }
}

// MARK: - Multi-Selection Inspector

struct MultiSelectionInspector: View {
    let count: Int

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.3.group")
                .font(.title)
                .foregroundStyle(.secondary)

            Text("\(count) components selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

// MARK: - Circuit Inspector (when nothing selected)

struct CircuitInspector: View {
    @Binding var document: CircuitDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Project info
            Text("Project")
                .font(.subheadline.weight(.semibold))

            InspectorField(label: "Name") {
                TextField("Circuit name", text: $document.metadata.name)
                    .textFieldStyle(.roundedBorder)
            }

            InspectorField(label: "Description") {
                TextEditor(text: $document.metadata.description)
                    .frame(height: 60)
                    .font(.body)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.quaternary)
                    )
            }

            Divider()

            // Circuit stats
            Text("Statistics")
                .font(.subheadline.weight(.semibold))

            StatRow(label: "Components", value: "\(document.components.count)")
            StatRow(label: "Wires", value: "\(document.wires.count)")
            StatRow(label: "Nodes", value: "\(countNodes())")

            Divider()

            // Simulation config
            Text("Transient Config")
                .font(.subheadline.weight(.semibold))

            InspectorField(label: "Stop Time") {
                TextField("", value: $document.simulationConfig.transient.stopTime, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            InspectorField(label: "Time Step") {
                TextField("", value: $document.simulationConfig.transient.timeStep, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    private func countNodes() -> Int {
        var nodes = Set<String>()
        for wire in document.wires {
            nodes.insert("\(wire.startComponentID)_\(wire.startPinIndex)")
            nodes.insert("\(wire.endComponentID)_\(wire.endPinIndex)")
        }
        return max(nodes.count / 2, 0)
    }
}

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
        }
    }
}
