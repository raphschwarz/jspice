import SwiftUI
import CircuitKit

struct InspectorView: View {
    @ObservedObject var editor: EditorState
    @ObservedObject var document: CircuitDocument

    var body: some View {
        if let element = editor.selectedElement {
            ElementInspector(editor: editor, element: element)
                .id(element.id)
        } else if editor.selection.count > 1 {
            Form {
                Section {
                    Text("\(editor.selection.count) parts selected")
                    Button("Rotate", systemImage: "rotate.right") { editor.rotateSelection() }
                    if editor.canFlipSelection {
                        Button("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") { editor.flipSelection() }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { editor.deleteSelection() }
                }
            }
            .formStyle(.grouped)
        } else {
            CircuitInspector(editor: editor, simulation: editor.simulation, settings: document.circuit.settings,
                             partCount: document.circuit.elements.count)
        }
    }
}

/// Parameter values are shown with SI prefixes in plain SI units, and as plain numbers otherwise (a duty cycle, an
/// angle, a slew rate in V/µs)
private func formatParameter(_ value: Double, _ spec: ParamSpec) -> String {
    let siUnits: Set<String> = ["V", "A", "Ω", "F", "H", "Hz", "s", "W", "A/V²"]
    guard siUnits.contains(spec.unit) else {
        let number = SI.trimmed(value, digits: 3)
        return spec.unit.isEmpty || spec.unit == "°" ? number + spec.unit : number + " " + spec.unit
    }
    return SI.format(value, unit: spec.unit, digits: 4)
}

struct ElementInspector: View {
    @ObservedObject var editor: EditorState
    let element: Element
    @State private var name = ""

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(nsImage: SymbolIcons.image(element.kind))
                        .renderingMode(.template)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        if element.kind == .wire || element.kind == .ground {
                            Text(element.kind.displayName).font(.headline)
                        } else {
                            TextField("Name", text: $name)
                                .labelsHidden()
                                .textFieldStyle(.plain)
                                .font(.headline)
                                .onSubmit { editor.rename(element.id, to: name) }
                            Text(element.kind.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !element.kind.models.isEmpty {
                Section {
                    Picker("Model", selection: Binding(
                        get: { element.model?.name ?? "" },
                        set: { name in
                            if let model = element.kind.models.first(where: { $0.name == name }) { editor.applyModel(element.id, model) }
                        }
                    )) {
                        ForEach(element.kind.models, id: \.name) { model in
                            Text(model.name).tag(model.name)
                        }
                        if element.model == nil {
                            Text("Custom").tag("")
                        }
                    }
                } footer: {
                    Text(element.model?.summary ?? "Values changed from the chosen model.")
                }
            }

            if element.kind == .led {
                Section("Properties") {
                    Picker("Color", selection: Binding(
                        get: { Int(element[param: "color"]) },
                        set: { editor.setParameter(element.id, element.kind.params[0], to: Double($0)) }
                    )) {
                        ForEach(LEDColor.allCases, id: \.rawValue) { color in
                            Text(color.name).tag(color.rawValue)
                        }
                    }
                }
            } else if !element.kind.params.isEmpty {
                Section("Properties") {
                    ForEach(element.kind.params, id: \.key) { spec in
                        ParameterRow(editor: editor, elementID: element.id, spec: spec, value: element[param: spec.key])
                    }
                }
            }

            if element.kind.isSwitch {
                Section {
                    Toggle("Closed", isOn: Binding(get: { element.closed }, set: { _ in editor.toggleSwitch(element.id) }))
                } footer: {
                    Text("You can also click the switch on the canvas.")
                }
            }

            if element.kind != .ground {
                Section("Measurements") {
                    LiveReadings(simulation: editor.simulation, elementID: element.id)
                }
            }

            Section {
                let quantities = scopeQuantities(for: element.kind)
                if !quantities.isEmpty {
                    Menu {
                        ForEach(quantities) { quantity in
                            Button(quantity.name) { editor.addScope(element.id, quantity) }
                        }
                    } label: {
                        Label("Add to Scope", systemImage: "waveform.path.ecg")
                    }
                }
                if canPlotCurve(element.kind) {
                    Button("Add I–V Curve Scope", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                        editor.addScope(element.id, .current, plot: .currentVersusVoltage)
                    }
                }
                Button("Rotate", systemImage: "rotate.right") { editor.rotateSelection() }
                if element.kind.canFlip {
                    Button("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") { editor.flipSelection() }
                }
                Button("Delete", systemImage: "trash", role: .destructive) { editor.deleteSelection() }
            }
        }
        .formStyle(.grouped)
        .onAppear { name = element.name }
        .onChange(of: element.name) { _, newName in name = newName }
    }
}

/// A typed value plus a slider; dragging the slider changes the circuit live and becomes one undo step.
struct ParameterRow: View {
    @ObservedObject var editor: EditorState
    let elementID: UUID
    let spec: ParamSpec
    let value: Double
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(spec.name) {
                TextField(spec.name, text: $text)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
                    .focused($focused)
                    .onSubmit(commit)
            }
            Slider(value: Binding(get: { position(of: value) }, set: { slide(to: $0) }), in: 0...1, onEditingChanged: { editing in
                if editing {
                    editor.beginInteraction()
                } else {
                    editor.endInteraction("Change \(spec.name)")
                }
            })
            .controlSize(.small)
        }
        .onAppear { text = formatParameter(value, spec) }
        .onChange(of: value) { _, newValue in
            if !focused { text = formatParameter(newValue, spec) }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private func commit() {
        guard let parsed = SI.parse(text) else {
            text = formatParameter(value, spec)
            return
        }
        if parsed != value { editor.setParameter(elementID, spec, to: parsed) }
        text = formatParameter(parsed, spec)
    }

    private func position(of value: Double) -> Double {
        let lower = spec.range.lowerBound
        let upper = spec.range.upperBound
        if spec.logarithmic {
            guard value > 0, lower > 0 else { return 0 }
            return max(0, min(1, log(value / lower) / log(upper / lower)))
        }
        return max(0, min(1, (value - lower) / (upper - lower)))
    }

    private func slide(to position: Double) {
        let lower = spec.range.lowerBound
        let upper = spec.range.upperBound
        var newValue: Double
        if spec.logarithmic {
            newValue = lower * pow(upper / lower, position)
            // three significant digits
            let magnitude = pow(10, floor(log10(newValue)) - 2)
            newValue = (newValue / magnitude).rounded() * magnitude
        } else {
            newValue = lower + (upper - lower) * position
            let step = (upper - lower) / 200
            newValue = (newValue / step).rounded() * step
        }
        editor.beginInteraction()
        var next = editor.circuit
        next.update(elementID) { $0[param: spec.key] = newValue }
        editor.setDuringInteraction(next)
        text = formatParameter(newValue, spec)
    }
}

struct LiveReadings: View {
    let simulation: SimulationController
    let elementID: UUID

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let simulator = simulation.simulator
            if let index = simulator.circuit.index(of: elementID) {
                let kind = simulator.circuit.elements[index].kind
                if kind == .wire {
                    reading("Voltage", SI.format(simulator.terminalVoltages(index).first ?? 0, unit: "V"))
                    reading("Current", SI.format(simulator.current(index), unit: "A"))
                } else if kind == .probe || kind == .netLabel || kind == .speaker {
                    reading("Voltage", SI.format(simulator.voltageAcross(index), unit: "V"))
                } else if kind == .ammeter {
                    reading("Current", SI.format(simulator.current(index), unit: "A"))
                } else if kind == .ota {
                    let v = simulator.terminalVoltages(index)
                    if v.count == 4 {
                        reading("Input difference", SI.format(v[1] - v[0], unit: "V"))
                        reading("Bias pin", SI.format(v[3], unit: "V"))
                    }
                    reading("Output voltage", SI.format(simulator.voltageAcross(index), unit: "V"))
                    reading("Output current", SI.format(simulator.current(index), unit: "A"))
                } else if kind == .timer555 || kind == .schmittInverter {
                    reading("Output", simulator.isHigh(index) ? "High" : "Low")
                    reading("Output voltage", SI.format(simulator.voltageAcross(index), unit: "V"))
                    reading("Output current", SI.format(simulator.current(index), unit: "A"))
                } else if kind == .analogSwitch {
                    let conduction = simulator.switchConduction(index)
                    reading("Switch", conduction > 0.5 ? "Closed" : "Open")
                    reading("Voltage", SI.format(simulator.voltageAcross(index), unit: "V"))
                    reading("Current", SI.format(simulator.current(index), unit: "A"))
                } else if kind == .opAmp {
                    let v = simulator.terminalVoltages(index)
                    if v.count == 3 {
                        reading("Input difference", SI.format(v[1] - v[0], unit: "V"))
                    }
                    reading("Output voltage", SI.format(simulator.voltageAcross(index), unit: "V"))
                    reading("Output current", SI.format(simulator.current(index), unit: "A"))
                } else if kind.isBipolar {
                    let v = simulator.terminalVoltages(index)
                    reading("Collector–emitter voltage", SI.format(simulator.voltageAcross(index), unit: "V"))
                    if v.count == 3 {
                        reading("Base–emitter voltage", SI.format(v[0] - v[2], unit: "V"))
                    }
                    reading("Collector current", SI.format(simulator.current(index), unit: "A"))
                    reading("Power", SI.format(abs(simulator.value(.power, of: index)), unit: "W"))
                } else {
                    reading(kind.isTransistor ? "Drain–source voltage" : "Voltage", SI.format(simulator.voltageAcross(index), unit: "V"))
                    reading(kind.isTransistor ? "Drain current" : "Current", SI.format(simulator.current(index), unit: "A"))
                    reading("Power", SI.format(abs(simulator.value(.power, of: index)), unit: "W"))
                    if kind == .memristor {
                        reading("Resistance", SI.format(simulator.value(.resistance, of: index), unit: "Ω"))
                        reading("State", "\(Int((simulator.memristorState(index) * 100).rounded())) % on")
                    }
                    if kind == .potentiometer, let wiper = simulator.terminalVoltages(index).last {
                        reading("Wiper voltage", SI.format(wiper, unit: "V"))
                    }
                    if kind == .led || kind == .lamp {
                        reading("Brightness", "\(Int((simulator.brightness(index) * 100).rounded())) %")
                    }
                }
            }
        }
    }

    private func reading(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).monospacedDigit()
        }
    }
}

struct CircuitInspector: View {
    @ObservedObject var editor: EditorState
    @ObservedObject var simulation: SimulationController
    let settings: SimulationSettings
    let partCount: Int
    @State private var timeStepText = ""

    var body: some View {
        Form {
            Section {
                Toggle("Automatic speed", isOn: Binding(get: { settings.autoSpeed }, set: { automatic in
                    let current = simulation.status.speed
                    editor.updateSettings {
                        $0.autoSpeed = automatic
                        if !automatic { $0.speed = current }
                    }
                }))
                if settings.autoSpeed {
                    LabeledContent("Speed", value: Pacing.describe(speed: simulation.status.speed))
                } else {
                    Picker("Speed", selection: Binding(get: { settings.speed }, set: { speed in
                        editor.updateSettings { $0.speed = speed }
                    })) {
                        ForEach(speedPresets, id: \.self) { speed in
                            Text(Pacing.describe(speed: speed)).tag(speed)
                        }
                    }
                }
                Toggle("Automatic time step", isOn: Binding(get: { settings.autoTimeStep }, set: { automatic in
                    let current = simulation.status.timeStep
                    editor.updateSettings {
                        $0.autoTimeStep = automatic
                        if !automatic { $0.timeStep = current }
                    }
                }))
                if settings.autoTimeStep {
                    LabeledContent("Time step", value: SI.format(simulation.status.timeStep, unit: "s"))
                } else {
                    LabeledContent("Time step") {
                        TextField("Time step", text: $timeStepText)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 120)
                            .onSubmit {
                                if let value = SI.parse(timeStepText), value > 0 {
                                    editor.updateSettings { $0.timeStep = value }
                                }
                                timeStepText = SI.format(settings.timeStep, unit: "s")
                            }
                    }
                }
                LabeledContent("Circuit time", value: SI.format(simulation.status.time, unit: "s", digits: 4))
            } header: {
                Text("Simulation")
            } footer: {
                Text("Automatic speed runs in real time when the circuit changes slowly enough to watch, and in slow motion when it changes faster.")
            }
            Section("Circuit") {
                LabeledContent("Parts", value: "\(partCount)")
                LabeledContent("Nodes", value: "\(simulation.simulator.nodeCount)")
            }
            Section {
                Text("Select a part to edit it. To add one, pick it in the library and click or drag on the canvas.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { timeStepText = SI.format(settings.timeStep, unit: "s") }
    }
}
