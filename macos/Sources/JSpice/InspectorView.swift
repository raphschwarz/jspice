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
            // (a new selection starts with fresh fields)
            MultiSelectionInspector(editor: editor, ids: editor.selection, circuit: document.circuit)
                .id(editor.selection)
        } else {
            CircuitInspector(editor: editor, simulation: editor.simulation, settings: document.circuit.settings,
                             partCount: document.circuit.elements.count)
        }
    }
}

/// Parameter values are shown with SI prefixes in plain SI units, and as plain numbers otherwise (a duty cycle, an
/// angle, a slew rate in V/µs)
func formatParameter(_ value: Double, _ spec: ParamSpec) -> String {
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
            ElementProblemsSection(simulation: editor.simulation, id: element.id)

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
                    Spacer(minLength: 4)
                    PartActions(editor: editor, canFlip: element.kind.canFlip)
                }
            }

            // the order: what the part is, its values, playing it, what it reads (and plotting that), what only some
            // kinds have, and last the groups few need, folded
            ModelSections(editor: editor, element: element)
            PropertiesSection(editor: editor, element: element)
            PlayingSections(editor: editor, element: element)
            if element.kind != .ground {
                MeasurementsSection(editor: editor, element: element)
            }
            KindSections(editor: editor, element: element)
            FoldedSections(editor: editor, element: element)
        }
        .formStyle(.grouped)
        .onAppear { name = element.name }
        .onChange(of: element.name) { _, newName in name = newName }
    }
}

/// Rotate, Flip and Delete as a row of small buttons, beside the part's name (or the selection's count)
struct PartActions: View {
    let editor: EditorState
    let canFlip: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button { editor.rotateSelection() } label: { Label("Rotate", systemImage: "rotate.right") }
                .help("Rotate a quarter turn")
            if canFlip {
                Button { editor.flipSelection() } label: {
                    Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .help("Flip across its axis")
            }
            Button(role: .destructive) { editor.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                .help("Delete")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .fixedSize()
    }
}

/// The real part a generic symbol behaves as, and an op-amp's maker's model
private struct ModelSections: View {
    @ObservedObject var editor: EditorState
    let element: Element

    var body: some View {
        if !element.kind.models.isEmpty {
            Section {
                Picker("Model", selection: Binding(
                    get: { element.model?.name ?? "" },
                    set: { name in
                        if let model = element.kind.models.first(where: { $0.name == name }) { editor.applyModel(element.id, model) }
                    }
                )) {
                    ForEach(element.kind.models, id: \.name) { model in
                        Text(model.title).tag(model.name)
                    }
                    if element.model == nil {
                        Text("Custom").tag("")
                    }
                }
            } footer: {
                Text(element.model?.summary ?? "Values changed from the chosen model.")
            }
        }

        if element.kind == .opAmp, let name = element.model?.name, let maker = MakerModelCatalog.model(forBuiltIn: name) {
            MakerModelSection(editor: editor, element: element, model: maker)
        }
    }
}

/// The part's values (not the rest of its SPICE model card, which `FoldedSections` keeps out of the way)
private struct PropertiesSection: View {
    @ObservedObject var editor: EditorState
    let element: Element

    var body: some View {
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
                ForEach(element.kind.params.filter { !$0.advanced }, id: \.key) { spec in
                    if spec.choices.isEmpty {
                        ParameterRow(editor: editor, elementID: element.id, spec: spec, value: element[param: spec.key])
                    } else {
                        ChoiceRow(editor: editor, element: element, spec: spec)
                    }
                }
            }
        }
    }
}

/// A parameter that picks one of a few settings
private struct ChoiceRow: View {
    @ObservedObject var editor: EditorState
    let element: Element
    let spec: ParamSpec

    var body: some View {
        let value = element[param: spec.key]
        Picker(spec.name, selection: Binding(
            get: { value },
            set: { editor.setParameter(element.id, spec, to: $0) }
        )) {
            ForEach(spec.choices, id: \.value) { choice in
                Text(choice.name).tag(choice.value)
            }
            if !spec.choices.contains(where: { $0.value == value }) {
                Text(formatParameter(value, spec)).tag(value)
            }
        }
    }
}

/// What is played rather than edited: a switch's state, and the sound a microphone or audio input plays
private struct PlayingSections: View {
    @ObservedObject var editor: EditorState
    let element: Element

    var body: some View {
        if element.kind.isSwitch {
            Section {
                Toggle(element.kind == .footswitch ? "Effect on (pressed)" : element.kind == .jack ? "Cable plugged in" : "Closed",
                       isOn: Binding(get: { element.closed }, set: { _ in editor.toggleSwitch(element.id) }))
            } footer: {
                Text("You can also click the switch on the canvas.")
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
    }
}

/// The part's live readings, with the ways to plot them in the section's header. (The readings redraw on their own
/// timeline; nothing here follows the simulation.)
private struct MeasurementsSection: View {
    let editor: EditorState
    let element: Element

    var body: some View {
        Section {
            LiveReadings(simulation: editor.simulation, elementID: element.id)
        } header: {
            HStack(spacing: 6) {
                Text("Measurements")
                Spacer(minLength: 4)
                MeasurementActions(editor: editor, elementID: element.id, kind: element.kind)
            }
        }
    }
}

/// Add to Scope ▸ (each quantity), and the I–V curve, frequency response and spectrum scopes, as small buttons
struct MeasurementActions: View {
    let editor: EditorState
    let elementID: UUID
    let kind: ElementKind

    var body: some View {
        let quantities = scopeQuantities(for: kind)
        HStack(spacing: 10) {
            if !quantities.isEmpty {
                Menu {
                    ForEach(quantities) { quantity in
                        Button(quantity.name) { editor.addScope(elementID, quantity) }
                    }
                } label: {
                    Label("Add to Scope", systemImage: "waveform.path.ecg")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .help("Add to Scope: plot this part's " + quantities.map { $0.name.lowercased() }.joined(separator: ", ") + " over time")
            }
            if canPlotCurve(kind) {
                Button { editor.addScope(elementID, .current, plot: .currentVersusVoltage) } label: {
                    Label("Add I–V Curve Scope", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                .help("Add I–V Curve Scope: its current against its voltage")
            }
            if canPlotResponse(kind) {
                let title = kind == .loopProbe ? "Add Loop Gain" : "Add Frequency Response"
                Button { editor.addScope(elementID, .voltage, plot: .frequencyResponse) } label: {
                    Label(title, systemImage: "chart.line.downtrend.xyaxis")
                }
                .help(title)
            }
            if let quantity = quantities.first, canPlotSpectrum(kind) {
                Button { editor.addScope(elementID, quantity, plot: .spectrum) } label: {
                    Label("Add Spectrum", systemImage: "chart.bar.xaxis")
                }
                .help("Add Spectrum: the frequencies in its " + quantity.name.lowercased())
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .fixedSize()
    }
}

/// What only some kinds have: the sequencer of the keyboard sources, a microcontroller's program, a block's insides
private struct KindSections: View {
    @ObservedObject var editor: EditorState
    let element: Element

    var body: some View {
        if element.kind.isKeyboard {
            SequencerSection(editor: editor, sequence: editor.sequence)
        }

        if element.kind.isMicrocontroller {
            MicrocontrollerSection(editor: editor, element: element)
        }

        if element.kind == .block {
            BlockSection(editor: editor, element: element)
        }
    }
}

/// The groups few parts need edited, folded until opened (and kept open or folded, across parts and launches): the rest
/// of the SPICE model card, MIDI learn, and a knob's movement
private struct FoldedSections: View {
    @ObservedObject var editor: EditorState
    let element: Element
    @AppStorage("InspectorSPICEParametersExpanded") private var spiceExpanded = false

    var body: some View {
        if element.kind.params.contains(where: \.advanced) {
            // the rest of the part's SPICE model card, which a manufacturer's model sets
            Section {
                DisclosureGroup("SPICE Model Parameters", isExpanded: $spiceExpanded) {
                    ForEach(element.kind.params.filter(\.advanced), id: \.key) { spec in
                        ParameterRow(editor: editor, elementID: element.id, spec: spec, value: element[param: spec.key])
                    }
                }
            }
        }

        if MIDIMapping.mappable.contains(element.kind) {
            MIDISection(editor: editor, element: element)
        }

        if element.kind == .potentiometer {
            KnobMotionSection(editor: editor, knob: KnobID(part: element.id))
        }
    }
}

/// A knob or switch played from a MIDI controller: learn it by moving the control, or forget it
private struct MIDISection: View {
    @ObservedObject var editor: EditorState
    let element: Element
    @AppStorage("InspectorMIDIExpanded") private var expanded = false

    var body: some View {
        let learning = editor.midiLearning == EditorState.MIDITarget(part: element.id, inner: nil)
        let mapping = editor.circuit.midiMapping(part: element.id)
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                if let mapping {
                    LabeledContent("Controller", value: mapping.label)
                }
                HStack {
                    Button(learning ? "Move a MIDI Control…" : "MIDI Learn", systemImage: "pianokeys") {
                        editor.learnMIDI(part: element.id)
                    }
                    .foregroundStyle(learning ? Color.orange : Color.primary)
                    if mapping != nil {
                        Button("Forget") { editor.forgetMIDI(part: element.id) }
                    }
                }
            } label: {
                // what it is set to, seen while folded
                LabeledContent("MIDI") {
                    if learning {
                        Text("Learning…").foregroundStyle(.orange)
                    } else if let mapping {
                        Text(mapping.label).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// A block part: which block it is, its pins, and the knobs and switches inside this copy of it
/// The problems that name the selected part, at the top of its inspector: what is wrong, and what to do about it
struct ElementProblemsSection: View {
    @ObservedObject var simulation: SimulationController
    let id: UUID

    var body: some View {
        let problems = simulation.diagnostics(for: id)
        if !problems.isEmpty {
            Section {
                ForEach(problems) { problem in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(problem.message).fixedSize(horizontal: false, vertical: true)
                            if let hint = problem.hint, !hint.isEmpty {
                                Text(hint)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } icon: {
                        Image(systemName: problem.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(problem.severity == .error ? Color.red : Color.orange)
                    }
                }
            }
        }
    }
}

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

/// A knob moving back and forth by itself, as a foot rocks a wah pedal: how often, and between which positions
struct KnobMotionSection: View {
    @ObservedObject var editor: EditorState
    let knob: KnobID
    @AppStorage("knobMotionPeriod") private var period = 2.0
    @AppStorage("InspectorMovementExpanded") private var expanded = false
    @State private var low = 0.0
    @State private var high = 1.0

    private static let periods: [Double] = [0.25, 0.5, 1, 2, 4, 8, 16]

    var body: some View {
        let moving = editor.motion(of: knob) != nil
        Section {
            // folded until opened, as few knobs are set moving; the label says when this one is
            DisclosureGroup(isExpanded: $expanded) {
                Toggle("Move back and forth", isOn: Binding(
                    get: { moving },
                    set: { on in
                        if on { editor.startMoving(knob, period: period, low: min(low, high), high: max(low, high)) } else { editor.stopMoving(knob) }
                    }
                ))
                Picker("Once every", selection: $period) {
                    ForEach(Self.periods, id: \.self) { seconds in
                        Text(seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.0f s", seconds)).tag(seconds)
                    }
                }
                LabeledContent("From") { Slider(value: $low, in: 0...1, onEditingChanged: { editing in if !editing { restart() } }).controlSize(.small) }
                LabeledContent("To") { Slider(value: $high, in: 0...1, onEditingChanged: { editing in if !editing { restart() } }).controlSize(.small) }
                Text("Turns the knob from one position to the other and back by itself, slowing at each end, while you listen and watch the scopes. It goes back where it was when it stops; File ▸ Export Sound records it moving.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } label: {
                LabeledContent("Movement") {
                    if moving { Text("Moving").foregroundStyle(.secondary) }
                }
            }
        }
        .onChange(of: period) { _, _ in restart() }
        .onAppear {
            if let motion = editor.motion(of: knob) {
                low = motion.low
                high = motion.high
            }
        }
    }

    /// A moving knob takes on the new settings from where it is
    private func restart() {
        guard editor.motion(of: knob) != nil else { return }
        editor.startMoving(knob, period: period, low: min(low, high), high: max(low, high))
    }
}

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

/// An op-amp's maker's model: TI's own PSpice model of the part, run in place of JSpice's equations
struct MakerModelSection: View {
    @ObservedObject var editor: EditorState
    let element: Element
    let model: MakerModelCatalog.Model

    static let supply = ParamSpec("supply", "Supply (±, 0 for automatic)", unit: "V", default: 0, range: 0...25, log: false)

    var body: some View {
        Section {
            if editor.makerModelLoading.contains(element.id) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Downloading \(model.part) from \(model.maker)…")
                }
            } else {
                Toggle("\(model.maker)'s \(model.part) model", isOn: Binding(
                    get: { element.runsMakerModel },
                    set: { editor.useMakerModel(element.id, $0) }
                ))
            }
            if element.runsMakerModel {
                ParameterRow(editor: editor, elementID: element.id, spec: Self.supply, value: element[param: "supply"])
                let rails = MakerModels.rails(midpoint: element[param: "midpoint"], supply: element[param: "supply"],
                                              limit: element[param: "limit"])
                LabeledContent("Supplies", value: SI.format(rails.positive, unit: "V") + " and " + SI.format(rails.negative, unit: "V"))
            }
        } header: {
            Text("Maker's Model")
        } footer: {
            if element.runsMakerModel {
                Text("\(model.revision), from \(model.archive.host ?? model.maker), on ideal supplies. Slower to simulate than JSpice's own model: the sound may not keep up.")
            } else {
                Text("Runs \(model.maker)'s own PSpice model of the \(model.part) in place of JSpice's equations: closer to the part, slower to simulate. Downloaded from \(model.maker) once.")
            }
        }
    }
}

/// A typed value plus a slider; dragging the slider changes the circuit live and becomes one undo step.
struct ParameterRow: View {
    @ObservedObject var editor: EditorState
    let elementID: UUID
    let spec: ParamSpec
    let value: Double
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(spec.name) {
                ParameterField(spec: spec, value: value, text: $text, invalid: $invalid) { parsed in
                    editor.setParameter(elementID, spec, to: parsed)
                }
            }
            if invalid { InvalidValueNote() }
            Slider(value: Binding(get: { position(of: value) }, set: { slide(to: $0) }), in: 0...1, onEditingChanged: { editing in
                if editing {
                    editor.beginInteraction()
                } else {
                    editor.endInteraction("Change \(spec.name)")
                }
            })
            .controlSize(.small)
        }
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
        invalid = false
    }
}

/// A parameter's typed value, with SI prefixes ("4.7k", "100n", "2M2"). Return or leaving the field sets it; ↑ and ↓
/// step it (`ParameterStepping`: the next E12 value of a resistance, capacitance or inductance, E24 with ⌥) and Esc
/// puts back the value it has. Text that is not a value stays, marked, for correcting. `value` nil: the selected parts
/// differ, and the field shows "Mixed" until a value is typed.
struct ParameterField: View {
    let spec: ParamSpec
    let value: Double?
    @Binding var text: String
    @Binding var invalid: Bool
    let commit: (Double) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField(spec.name, text: $text, prompt: value == nil ? Text("Mixed") : nil)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 120)
            .focused($focused)
            .onSubmit(save)
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                step(up: press.key == .upArrow, finer: press.modifiers.contains(.option)) ? .handled : .ignored
            }
            .onExitCommand(perform: revert)
            .overlay {
                if invalid {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(Color.red, lineWidth: 1.5).allowsHitTesting(false)
                }
            }
            .help(helpText)
            .onAppear { text = shown(value) }
            .onChange(of: value) { _, newValue in
                if !focused {
                    text = shown(newValue)
                    invalid = false
                }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { save() }
            }
    }

    private func shown(_ value: Double?) -> String {
        value.map { formatParameter($0, spec) } ?? ""
    }

    /// What the field's help tag says: its usual range, and its keys
    private var helpText: String {
        let range = "\(formatParameter(spec.range.lowerBound, spec)) to \(formatParameter(spec.range.upperBound, spec))"
        return "\(spec.name): usually \(range) (the slider's range); other values can be typed, with SI prefixes such as 4.7k, 10u or 2M2. "
            + ParameterStepping.hint(spec) + "; Esc puts the value back."
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // a mixed field left empty changes nothing
        if value == nil && trimmed.isEmpty {
            invalid = false
            return
        }
        guard let parsed = SI.parse(trimmed) else {
            // kept, and marked, rather than put back without a word
            invalid = true
            return
        }
        invalid = false
        if parsed != value { commit(parsed) }
        text = formatParameter(parsed, spec)
    }

    private func revert() {
        text = shown(value)
        invalid = false
    }

    /// One step from the value typed (or the part's, when what is typed is not a value); false when there is none
    /// (a mixed field), so the key goes on to the field
    private func step(up: Bool, finer: Bool) -> Bool {
        guard let base = SI.parse(text) ?? value else { return false }
        let next = ParameterStepping.step(base, spec, up: up, finer: finer)
        invalid = false
        text = formatParameter(next, spec)
        if next != value { commit(next) }
        return true
    }
}

/// Under a field whose text is not a value: what it takes
struct InvalidValueNote: View {
    var body: some View {
        Text(ParameterStepping.parseHint)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
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
                } else if kind == .ammeter || kind == .loopProbe {
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
                } else if kind == .shiftIn {
                    // the stages, QH (D7 as loaded) on the left
                    let bits = String(simulator.logicCount(index), radix: 2)
                    reading("Stages", String(repeating: "0", count: max(0, 8 - bits.count)) + bits)
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
                    // against its rating (see PartStress, which checks the average over a run)
                    if kind == .resistor || kind == .lamp, element[param: "ratedPower"] > 0 {
                        rated(abs(simulator.value(.power, of: index)) / element[param: "ratedPower"],
                              of: SI.format(element[param: "ratedPower"], unit: "W"))
                    }
                    if kind == .capacitor, element[param: "ratedVoltage"] > 0 {
                        rated(abs(simulator.voltageAcross(index)) / element[param: "ratedVoltage"],
                              of: SI.format(element[param: "ratedVoltage"], unit: "V"))
                    }
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

    /// The share of its rating a part runs at, red past it
    private func rated(_ load: Double, of rating: String) -> some View {
        LabeledContent("Of its \(rating) rating") {
            Text("\(Int((load * 100).rounded())) %").monospacedDigit()
                .foregroundStyle(load > 1 ? Color.red : load > 0.5 ? Color.orange : Color.primary)
        }
        .help(load > 1 ? "Past its rating: it would overheat or break down. Choose a part rated higher." : "")
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
