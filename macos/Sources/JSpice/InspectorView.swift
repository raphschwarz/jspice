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
    @FocusState private var nameFocused: Bool

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
                                .focused($nameFocused)
                                .onSubmit { editor.rename(element.id, to: name) }
                                // a name typed and left (clicking elsewhere, Tab) is kept too
                                .onChange(of: nameFocused) { _, focused in
                                    if !focused && name != element.name { editor.rename(element.id, to: name) }
                                }
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
                        if spec.choices.isEmpty {
                            ParameterRow(editor: editor, elementID: element.id, spec: spec, value: element[param: spec.key])
                        } else {
                            Picker(spec.name, selection: Binding(
                                get: { element[param: spec.key] },
                                set: { editor.setParameter(element.id, spec, to: $0) }
                            )) {
                                ForEach(spec.choices, id: \.value) { choice in
                                    Text(choice.name).tag(choice.value)
                                }
                                if !spec.choices.contains(where: { $0.value == element[param: spec.key] }) {
                                    Text(formatParameter(element[param: spec.key], spec)).tag(element[param: spec.key])
                                }
                            }
                        }
                    }
                }
            }

            if element.kind.isKeyboard {
                SequencerSection(editor: editor, sequence: editor.sequence)
            }

            if element.kind.isMicrocontroller {
                MicrocontrollerSection(editor: editor, element: element)
            }

            if element.kind == .block {
                BlockSection(editor: editor, element: element)
            }

            if MIDIMapping.mappable.contains(element.kind) {
                Section("MIDI") {
                    let learning = editor.midiLearning == EditorState.MIDITarget(part: element.id, inner: nil)
                    if let mapping = editor.circuit.midiMapping(part: element.id) {
                        LabeledContent("Controller", value: mapping.label)
                    }
                    HStack {
                        Button(learning ? "Move a MIDI Control…" : "MIDI Learn", systemImage: "pianokeys") {
                            editor.learnMIDI(part: element.id)
                        }
                        .foregroundStyle(learning ? Color.orange : Color.primary)
                        if editor.circuit.midiMapping(part: element.id) != nil {
                            Button("Forget") { editor.forgetMIDI(part: element.id) }
                        }
                    }
                }
            }

            if element.kind.playsClip && element[param: "input"] < 0.5 {
                // microphones play a voice unless given a sound; the audio input and the pickup, the guitar riff
                let voice = element.kind == .microphone || element.kind == .electretMic
                Section("Sound") {
                    let clip = element.audio ?? (voice ? AudioClip.speech : AudioClip.guitarRiff)
                    LabeledContent(clip.name, value: String(format: "%.1f s", clip.duration))
                    Button("Choose Sound File…", systemImage: "waveform") { editor.chooseSound(for: element.id) }
                    if element.audio != nil {
                        Button(voice ? "Use the Voice" : "Use the Guitar Riff", systemImage: voice ? "mouth" : "guitars") {
                            editor.useGuitarRiff(for: element.id)
                        }
                    }
                }
            }

            if element.kind.isSwitch {
                Section {
                    Toggle(element.kind == .footswitch ? "Effect on (pressed)" : "Closed",
                           isOn: Binding(get: { element.closed }, set: { _ in editor.toggleSwitch(element.id) }))
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
                if canPlotResponse(element.kind) {
                    Button("Add Frequency Response", systemImage: "chart.line.downtrend.xyaxis") {
                        editor.addScope(element.id, .voltage, plot: .frequencyResponse)
                    }
                }
                if let quantity = quantities.first, canPlotSpectrum(element.kind) {
                    Button("Add Spectrum", systemImage: "chart.bar.xaxis") {
                        editor.addScope(element.id, quantity, plot: .spectrum)
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

/// A block part: which block it is, its pins, and the knobs and switches inside this copy of it
struct BlockSection: View {
    @ObservedObject var editor: EditorState
    let element: Element

    var body: some View {
        if let block = element.block {
            let ports = block.ports
            Section {
                LabeledContent("Block", value: block.name)
                LabeledContent("Inputs", value: names(ports.filter { !$0.right }))
                LabeledContent("Outputs", value: names(ports.filter(\.right)))
                Button("Open Block", systemImage: "square.and.pencil") { editor.openBlock(element.id) }
                if editor.libraryBlocks.contains(where: { $0.name == block.name }) {
                    Button("Update from Library", systemImage: "arrow.triangle.2.circlepath") { editor.updateBlockFromLibrary(element.id) }
                }
            } footer: {
                Text("To change the block, open it, edit it and save it again with Circuit ▸ Save as Block, then update its copies from the library.")
            }
            let controls = block.circuit.elements.filter { $0.kind == .potentiometer || $0.kind == .toggleSwitch }
            if !controls.isEmpty {
                Section("Controls Inside") {
                    ForEach(controls) { inner in
                        if inner.kind == .potentiometer {
                            LabeledContent(inner.name) {
                                Slider(value: Binding(
                                    get: { inner[param: "position"] },
                                    set: { value in editor.updateInsideBlock(element.id, inner.id, actionName: nil) { $0[param: "position"] = value } }
                                ), in: 0...1, onEditingChanged: { editing in
                                    if editing { editor.beginInteraction() } else { editor.endInteraction("Turn \(inner.name)") }
                                })
                                .controlSize(.small)
                            }
                        } else {
                            Toggle(inner.name, isOn: Binding(
                                get: { inner.closed },
                                set: { closed in
                                    editor.updateInsideBlock(element.id, inner.id, actionName: closed ? "Close \(inner.name)" : "Open \(inner.name)") {
                                        $0.closed = closed
                                    }
                                }
                            ))
                        }
                    }
                }
            }
        }
    }

    private func names(_ ports: [BlockDefinition.Port]) -> String {
        ports.isEmpty ? "None" : ports.map(\.name).joined(separator: ", ")
    }
}

/// A typed value plus a slider; dragging the slider changes the circuit live and becomes one undo step.
/// The step sequencer that plays the keyboard sources: one note or rest per sixteenth note, repeating
struct SequencerSection: View {
    @ObservedObject var editor: EditorState
    let sequence: StepSequence

    var body: some View {
        Section {
            Toggle("Play", isOn: Binding(get: { sequence.playing }, set: { playing in
                editor.updateSequence(playing ? "Play Sequence" : "Stop Sequence") { $0.playing = playing }
            }))
            LabeledContent("Tempo") {
                HStack {
                    Slider(value: Binding(get: { sequence.tempo }, set: { tempo in
                        editor.updateSequenceDuringInteraction { $0.tempo = tempo.rounded() }
                    }), in: 40...240, onEditingChanged: { editing in
                        if !editing { editor.endInteraction("Change Tempo") }
                    })
                    .controlSize(.small)
                    Text("\(Int(sequence.tempo)) BPM").monospacedDigit().frame(width: 64, alignment: .trailing)
                }
            }
            LabeledContent("Gate length") {
                HStack {
                    Slider(value: Binding(get: { sequence.gateLength }, set: { gate in
                        editor.updateSequenceDuringInteraction { $0.gateLength = (gate * 20).rounded() / 20 }
                    }), in: 0.05...1, onEditingChanged: { editing in
                        if !editing { editor.endInteraction("Change Gate Length") }
                    })
                    .controlSize(.small)
                    Text("\(Int((sequence.gateLength * 100).rounded())) %").monospacedDigit().frame(width: 64, alignment: .trailing)
                }
            }
            Stepper("\(sequence.steps.count) steps", value: Binding(get: { sequence.steps.count }, set: { count in
                editor.updateSequence("Change Steps") { sequence in
                    if count > sequence.steps.count {
                        sequence.steps += Array(repeating: nil, count: count - sequence.steps.count)
                    } else {
                        sequence.steps = Array(sequence.steps.prefix(count))
                    }
                }
            }), in: 1...32)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(sequence.steps.indices, id: \.self) { index in
                    StepField(note: sequence.steps[index]) { note in
                        editor.updateSequence("Change Step") { sequence in
                            if index < sequence.steps.count { sequence.steps[index] = note }
                        }
                    }
                }
            }
        } header: {
            Text("Sequencer")
        } footer: {
            Text("Plays the keyboard sources by itself, one step per sixteenth note: type a note such as C3 or A#2, or leave a step blank for a rest. It keeps time with the circuit, so turn on sound to hear it in real time.")
        }
    }
}

/// One step of the sequencer: a note name, or blank for a rest
private struct StepField: View {
    let note: Double?
    let commit: (Double?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Step", text: $text, prompt: Text("–"))
            .labelsHidden()
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospacedDigit())
            .frame(minWidth: 44)
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { save() }
            }
            .onAppear { text = note.map(NoteName.name) ?? "" }
            .onChange(of: note) { _, newValue in
                if !focused { text = newValue.map(NoteName.name) ?? "" }
            }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parsed = trimmed.isEmpty || trimmed == "-" || trimmed == "–" ? nil : NoteName.number(trimmed)
        if trimmed.isEmpty || parsed != nil {
            if parsed != note { commit(parsed) }
            text = parsed.map(NoteName.name) ?? ""
        } else {
            text = note.map(NoteName.name) ?? ""
        }
    }
}

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
                let element = simulator.circuit.elements[index]
                let kind = element.kind
                if kind == .block {
                    // each pin's voltage
                    let voltages = simulator.terminalVoltages(index)
                    ForEach(Array(zip(element.terminalNames, voltages).enumerated()), id: \.offset) { entry in
                        reading(entry.element.0, SI.format(entry.element.1, unit: "V"))
                    }
                } else if kind == .port {
                    reading("Voltage", SI.format(simulator.terminalVoltages(index).first ?? 0, unit: "V"))
                } else if kind == .wire {
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
                } else if kind == .logicGate {
                    reading("Output", simulator.isHigh(index) ? "High" : "Low")
                    reading("Output voltage", SI.format(simulator.voltageAcross(index), unit: "V"))
                    reading("Output current", SI.format(simulator.current(index), unit: "A"))
                } else if kind == .digitalDelay {
                    reading("Delay", SI.format(simulator.echoDelaySeconds(index), unit: "s"))
                    reading("Output voltage", SI.format(simulator.voltageAcross(index), unit: "V"))
                } else if kind == .unbufferedInverter {
                    reading("Input voltage", SI.format(simulator.terminalVoltages(index).first ?? 0, unit: "V"))
                    reading("Output voltage", SI.format(simulator.voltageAcross(index), unit: "V"))
                    reading("Output current", SI.format(simulator.current(index), unit: "A"))
                } else if kind == .dac {
                    let word = simulator.logicCount(index)
                    reading("Code", word & 0x1000 == 0 ? "Shut down" : "\(word & 0xFFF) of 4095")
                    reading("Output voltage", SI.format(simulator.terminalVoltages(index).last ?? 0, unit: "V"))
                } else if kind == .dualDac {
                    let words = simulator.logicCount(index)
                    let voltages = simulator.terminalVoltages(index)
                    ForEach([0, 1], id: \.self) { channel in
                        let word = words >> (16 * channel) & 0xFFFF
                        let name = channel == 0 ? "A" : "B"
                        reading("Code \(name)", word & 0x1000 == 0 ? "Shut down" : "\(word & 0xFFF) of 4095")
                        reading("Output \(name)", SI.format(voltages.count > 4 + channel ? voltages[4 + channel] : 0, unit: "V"))
                    }
                } else if kind == .spiAdc {
                    reading("Last conversion", "\(simulator.adcReading(index)) of 1023")
                } else if kind == .i2cDac {
                    let register = simulator.logicCount(index)
                    reading("Code", register >> 12 & 0x3 != 0 ? "Powered down" : "\(register & 0xFFF) of 4095")
                    reading("Output voltage", SI.format(simulator.terminalVoltages(index).last ?? 0, unit: "V"))
                } else if kind == .i2sDac {
                    let voltages = simulator.terminalVoltages(index)
                    if voltages.count == 5 {
                        reading("Left", SI.format(voltages[3], unit: "V"))
                        reading("Right", SI.format(voltages[4], unit: "V"))
                    }
                } else if kind == .pll {
                    let outputs = simulator.logicOutputs(index)
                    reading("VCO", outputs.first == true ? "High" : "Low")
                    let pump = simulator.logicCount(index)
                    reading("Phase comparator 2", pump > 0 ? "Pumping up" : pump < 0 ? "Pumping down" : "Off (locked)")
                } else if kind == .decadeCounter || kind == .binaryCounter {
                    reading("Count", "\(simulator.logicCount(index))")
                } else if kind == .shiftRegister {
                    // the outputs, first stage on the right
                    let bits = String(simulator.logicCount(index), radix: 2)
                    reading("Outputs", String(repeating: "0", count: max(0, (element.model?.name == "74HC595" ? 8 : 4) - bits.count)) + bits)
                } else if kind == .flipFlop {
                    reading("Q", simulator.logicCount(index) == 1 ? "High" : "Low")
                } else if kind == .analogMux || kind == .analogSelector {
                    let channel = simulator.logicCount(index)
                    reading("Channel on", channel < 0 ? "None (inhibited)" : "X\(channel)")
                    reading("Current", SI.format(simulator.current(index), unit: "A"))
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
                    reading(kind.isTransistor ? "Drain–source voltage" : kind.isTube ? "Plate–cathode voltage"
                                : kind == .transformer ? "Secondary voltage" : "Voltage",
                            SI.format(simulator.voltageAcross(index), unit: "V"))
                    if kind.isTube {
                        let v = simulator.terminalVoltages(index)
                        if v.count >= 3 { reading("Grid–cathode voltage", SI.format(v[0] - v[2], unit: "V")) }
                    }
                    if kind != .transformer {
                        reading(kind.isTransistor ? "Drain current" : kind.isTube ? "Plate current" : "Current",
                                SI.format(simulator.current(index), unit: "A"))
                    }
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
                                    timeStepText = SI.format(value, unit: "s")
                                } else {
                                    timeStepText = SI.format(settings.timeStep, unit: "s")
                                }
                            }
                    }
                }
                LabeledContent("Temperature") {
                    HStack(spacing: 4) {
                        Slider(value: Binding(get: { settings.temperature }, set: { celsius in
                            editor.updateSettingsDuringInteraction { $0.temperature = celsius.rounded() }
                        }), in: -40...125, onEditingChanged: { editing in
                            if !editing { editor.endInteraction("Change Temperature") }
                        })
                        .frame(maxWidth: 110)
                        Text(String(format: "%.0f °C", settings.temperature))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                .help("The temperature the diodes and transistors work at: hotter, their junctions drop about 2 mV less per degree")
                LabeledContent("Circuit time", value: SI.format(simulation.status.time, unit: "s", digits: 4))
            } header: {
                Text("Simulation")
            } footer: {
                Text("Automatic speed runs in real time when the circuit changes slowly enough to watch, and in slow motion when it changes faster.")
            }
            if simulation.hasKeyboard {
                SequencerSection(editor: editor, sequence: editor.sequence)
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
        .onChange(of: settings.timeStep) { _, value in timeStepText = SI.format(value, unit: "s") }
    }
}
