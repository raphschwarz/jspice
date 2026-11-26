import AppKit
import Combine
import SwiftUI
import CircuitKit

/// Where a microcontroller's last upload got to
enum SketchStatus: Equatable {
    /// Compiling: the step it is at ("Compiling the Arduino AVR core (first build only): 37 of 112 files")
    case building(step: String, fraction: Double?)
    /// Loaded into the chip (the sketch's warnings, if it was compiled here)
    case uploaded(bytes: Int, warnings: [SketchBuilder.Diagnostic])
    case failed(SketchFailure)
    case cancelled

    var isBuilding: Bool {
        if case .building = self { return true }
        return false
    }
}

/// Why a sketch did not build: errors on its lines, or a problem no line explains, and all the compiler said
struct SketchFailure: Equatable {
    var errors: [SketchBuilder.Diagnostic] = []
    var warnings: [SketchBuilder.Diagnostic] = []
    /// What went wrong outside the sketch's lines (the core, a library, linking, size, a missing compiler)
    var problem: String?
    var log: String = ""

    var headline: String {
        if !errors.isEmpty { return "\(errors.count) error\(errors.count == 1 ? "" : "s") in the sketch" }
        return "The sketch did not build"
    }
}

extension SketchBuilder.Diagnostic {
    /// "Line 12: 'foo' was not declared in this scope"
    var lineText: String { "Line \(line)\(column > 0 ? ":\(column)" : ""): \(message)" }
}

// MARK: - Chip support activity

/// What chip support is doing for each family, for the app as a whole: it outlives the sheet or Settings tab that
/// started an install, keeps one install at a time per family, and can cancel it
@MainActor
final class ChipSupportModel: ObservableObject {
    static let shared = ChipSupportModel()

    @Published private(set) var states: [ChipFamily: ChipSupport.State] = [:]
    private var installs: [ChipFamily: (id: UUID, task: Task<Void, Never>)] = [:]

    private init() { refresh() }

    func state(_ family: ChipFamily) -> ChipSupport.State {
        states[family] ?? ChipSupport.installedState(family)
    }

    func isBusy(_ family: ChipFamily) -> Bool { installs[family] != nil }

    /// Reads what is installed again (an Arduino IDE may have been installed meanwhile); a family installing, or one
    /// whose install failed, keeps its state
    func refresh() {
        for family in ChipFamily.allCases where installs[family] == nil {
            if case .failed? = states[family] { continue }
            states[family] = ChipSupport.installedState(family)
        }
    }

    func install(_ family: ChipFamily) {
        guard installs[family] == nil else { return }
        let id = UUID()
        states[family] = .downloading(fraction: 0, message: "Starting…")
        // (the model is the app's one, so the tasks name it rather than capture it)
        let task = Task { @MainActor in
            do {
                try await ChipSupport.install(family) { progress in
                    Task { @MainActor in ChipSupportModel.shared.update(family, id, progress) }
                }
                ChipSupportModel.shared.finish(family, id, nil)
            } catch {
                ChipSupportModel.shared.finish(family, id, error)
            }
        }
        installs[family] = (id, task)
    }

    func cancel(_ family: ChipFamily) {
        installs[family]?.task.cancel()
    }

    func remove(_ family: ChipFamily) {
        guard installs[family] == nil else { return }
        do {
            try ChipSupport.uninstall(family)
            states[family] = ChipSupport.installedState(family)
        } catch {
            states[family] = .failed("Could not remove it: \(error.localizedDescription)")
        }
    }

    /// Clears a failure's message
    func dismissFailure(_ family: ChipFamily) {
        guard installs[family] == nil else { return }
        states[family] = ChipSupport.installedState(family)
    }

    private func update(_ family: ChipFamily, _ id: UUID, _ progress: ChipSupport.Progress) {
        // (a report that arrives after the install ended, or from an earlier one, is old news)
        guard installs[family]?.id == id, progress.stage != .installed else { return }
        states[family] = ChipSupport.State(progress)
    }

    /// The install ended: done (no error), cancelled, or failed
    private func finish(_ family: ChipFamily, _ id: UUID, _ error: Error?) {
        guard installs[family]?.id == id else { return }
        installs[family] = nil
        if let error, !(error is CancellationError), (error as? URLError)?.code != .cancelled {
            states[family] = .failed((error as? ChipSupport.InstallError)?.description ?? error.localizedDescription)
        } else {
            states[family] = ChipSupport.installedState(family)
        }
    }
}

/// The sketch new microcontrollers start with
let blinkTemplate = """
    // Runs once when the chip starts
    void setup() {
      pinMode(13, OUTPUT);
    }

    // Runs over and over
    void loop() {
      digitalWrite(13, HIGH);
      delay(500);
      digitalWrite(13, LOW);
      delay(500);
    }
    """

// MARK: - Inspector

/// The microcontroller's part of the inspector: its program, uploading, and (for an STM32) its debugger. Its serial
/// monitor, bus trace and pins are in the Chip tab of the dock under the canvas, where they have room and stay open
/// while other parts are selected.
struct MicrocontrollerSection: View {
    @ObservedObject var editor: EditorState
    @ObservedObject private var chipSupport = ChipSupportModel.shared
    let element: Element

    init(editor: EditorState, element: Element) {
        _editor = ObservedObject(wrappedValue: editor)
        self.element = element
    }

    private var status: SketchStatus? { editor.sketchStatus[element.id] }

    var body: some View {
        Section {
            HStack {
                Image(systemName: element.firmware == nil ? "cpu" : "cpu.fill")
                    .foregroundStyle(element.firmware == nil ? Color.secondary : Color.accentColor)
                Text(statusText).font(.callout)
                Spacer()
            }
            SketchStatusDetails(status: status, errorLimit: 4)
            if element.kind.board?.compilesSketches ?? true {
                HStack {
                    Button("Edit Sketch…") { editor.editingSketch = element.id }
                    if status?.isBuilding == true {
                        Button("Cancel") { editor.cancelUpload(element.id) }
                            .help("Stop compiling")
                    } else {
                        Button("Upload") { editor.uploadSketch(element.id, code: element.code ?? element.kind.board?.blinkSketch ?? blinkTemplate) }
                            .help("Compile the sketch and load it into the chip (⌘U)")
                    }
                    Button("Restart") { editor.simulation.reset() }
                        .help("Start the circuit, and the chip, from the beginning")
                }
            } else {
                Text(element.firmware == nil ? "Runs firmware built with its maker's tools: load the .hex or .bin file."
                                             : "Runs the firmware loaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Restart") { editor.simulation.reset() }
                    .help("Start the circuit, and the chip, from the beginning")
            }
            Button("Load Firmware…") { editor.loadFirmware(element.id) }
                .help("Load a firmware file built elsewhere (Intel HEX or a raw image), as a programmer flashes it")
            if let family = element.kind.board?.sketchFamily {
                switch chipSupport.state(family) {
                case .installed:
                    EmptyView()
                case .downloading(let fraction, let message):
                    ProgressView(value: fraction) { Text("Installing chip support").font(.caption) } currentValueLabel: {
                        Text(message).font(.caption)
                    }
                    Button("Cancel Install") { chipSupport.cancel(family) }
                case .unpacking(let message):
                    ProgressView { Text(message).font(.caption) }
                    Button("Cancel Install") { chipSupport.cancel(family) }
                case .notInstalled, .failed:
                    Text("Compiling sketches needs chip support: \(family.summary).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Install Chip Support…") { editor.showChipSupport = true }
                }
            }
            if BottomDock.chips(in: editor.circuit).contains(where: { $0.id == element.id }) {
                let isSTM32 = element.kind.board?.compilesSketches == false
                Button {
                    editor.showDock(.chip)
                } label: {
                    Label(isSTM32 ? "Show Serial, Bus Trace and Pins" : "Show Serial Monitor", systemImage: "terminal")
                }
                .help(isSTM32 ? "Open the chip's serial monitor, bus trace and pins in the dock under the canvas"
                              : "Open the chip's serial monitor in the dock under the canvas")
            }
        } header: {
            Text("Program")
        }
        if element.kind.board?.compilesSketches == false, let index = editor.circuit.index(of: element.id) {
            DebuggerSection(simulation: editor.simulation, index: index, id: element.id)
        }
    }

    private var statusText: String {
        let board = element.kind.board
        let noun = board?.programNoun ?? "sketch"
        switch status {
        case .building(let step, _)?: return step + "…"
        case .uploaded(let bytes, _)?:
            return "Loaded: \(bytes.formatted()) of \((board?.flashSize(for: element) ?? 32_256).formatted()) bytes"
        case .failed(let failure)?: return failure.headline
        case .cancelled?: return "Compiling was cancelled"
        case nil:
            if let firmware = element.firmware { return "Running its \(noun) (\(firmware.count.formatted()) bytes)" }
            return board?.compilesSketches ?? true ? "No sketch yet: edit one and upload it"
                                                   : "No firmware yet: load a .hex or .bin file"
        }
    }
}

/// What a build said, under the inspector's status line and in the sketch editor: the sketch's errors and warnings
/// on their lines, a problem no line explains, and the compiler's whole output to open
struct SketchStatusDetails: View {
    let status: SketchStatus?
    /// How many errors and warnings to list (nil: all)
    var errorLimit: Int?

    var body: some View {
        switch status {
        case .building(_, let fraction?)?:
            ProgressView(value: fraction)
        case .building?:
            ProgressView().progressViewStyle(.linear)
        case .uploaded(_, let warnings)? where !warnings.isEmpty:
            diagnostics(warnings)
        case .failed(let failure)?:
            if let problem = failure.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            diagnostics(failure.errors + failure.warnings)
            if !failure.log.isEmpty {
                DisclosureGroup("Compiler Output") {
                    ScrollView {
                        Text(failure.log)
                            .font(.caption2.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 160)
                }
                .font(.caption)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func diagnostics(_ all: [SketchBuilder.Diagnostic]) -> some View {
        let shown = errorLimit.map { Array(all.prefix($0)) } ?? all
        ForEach(Array(shown.enumerated()), id: \.offset) { _, diagnostic in
            Label {
                Text(diagnostic.lineText)
                    .font(.caption.monospaced())
                    .lineLimit(errorLimit == nil ? nil : 3)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: diagnostic.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
            }
            .foregroundStyle(diagnostic.isError ? Color.red : Color.orange)
        }
        if shown.count < all.count {
            Text("and \(all.count - shown.count) more in the sketch editor").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// What the chip's USART has sent, and a field to send it text
struct SerialMonitor: View {
    @ObservedObject var simulation: SimulationController
    let index: Int
    /// The chip's board, for what to say before it has sent anything (when not given: an STM32 running is told apart
    /// by its chip)
    var board: Board? = nil
    @State private var input = ""

    private var placeholder: String {
        if let board { return board.serialMonitorPlaceholder }
        return simulation.stm32(index) != nil ? Board.stm32f405.serialMonitorPlaceholder
                                              : "Nothing yet. What the chip sends on its serial port appears here."
    }

    var body: some View {
        DockColumn("Serial Monitor") {
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                let text = simulation.serialOutput(index)
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(text.isEmpty ? placeholder : text)
                            .font(.caption.monospaced())
                            .foregroundStyle(text.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(minHeight: 40, maxHeight: .infinity)
                    .onChange(of: text) { _, _ in proxy.scrollTo("end") }
                }
            }
            HStack {
                TextField("Send", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send).disabled(input.isEmpty)
            }
        }
    }

    private func send() {
        simulation.sendSerial(index, input + "\n")
        input = ""
    }
}

/// What has gone over an STM32's buses, decoded as a logic analyzer would: its SPI and I²S frames, I²C transfers and
/// USART bytes, the latest last
struct BusTrace: View {
    @ObservedObject var simulation: SimulationController
    let index: Int
    @State private var tracing = false
    @State private var bus = "All"

    var body: some View {
        DockColumn("Bus Trace") {
            Toggle("Trace the buses", isOn: $tracing)
                .onChange(of: tracing) { _, on in simulation.stm32(index)?.tracesBuses = on }
                .onAppear { tracing = simulation.stm32(index)?.tracesBuses ?? false }
            if tracing {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let events = simulation.stm32(index)?.busEvents() ?? []
                    let buses = ["All"] + Set(events.map(\.bus)).sorted()
                    let shown = Array((bus == "All" ? events : events.filter { $0.bus == bus }).suffix(200))
                    VStack(alignment: .leading) {
                        Picker("Bus", selection: $bus) {
                            ForEach(buses, id: \.self) { Text($0).tag($0) }
                        }
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 1) {
                                    ForEach(Array(shown.enumerated()), id: \.offset) { _, event in
                                        Text(String(format: "%9.6f  ", event.time) + "\(event.bus)  \(event.summary)")
                                            .font(.caption2.monospaced())
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                Color.clear.frame(height: 1).id("end")
                            }
                            .frame(minHeight: 40, maxHeight: .infinity)
                            .onChange(of: shown.last?.time) { _, _ in proxy.scrollTo("end") }
                        }
                        if shown.isEmpty {
                            Text("Nothing yet: run the circuit.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// What each of an STM32's pins carries as its firmware has set it up, and what the chip says of itself
struct PinFunctions: View {
    @ObservedObject var simulation: SimulationController
    let index: Int

    var body: some View {
        DockColumn("Pins") {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let chip = simulation.stm32(index)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(chip?.notices ?? [], id: \.self) { notice in
                            Text(notice).font(.caption).foregroundStyle(.orange)
                        }
                        // (the pins the firmware has given a function, its plain inputs left out)
                        let pins = (chip?.pinFunctions ?? []).filter { $0.function != "a GPIO input" }
                        ForEach(Array(pins.enumerated()), id: \.offset) { _, pin in
                            HStack {
                                Text(pin.pin).font(.caption.monospaced()).frame(width: 44, alignment: .leading)
                                Text(pin.function).font(.caption)
                            }
                        }
                        if chip == nil {
                            Text("Run the circuit to see what the firmware makes of each pin.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// A GDB server for the chip: arm-none-eabi-gdb (or an IDE's debugger) connects to it as to a probe's server
struct DebuggerSection: View {
    @ObservedObject var simulation: SimulationController
    let index: Int
    let id: UUID
    @State private var port = 3333
    @State private var problem: String?

    var body: some View {
        Section {
            if let server = simulation.gdbServers[id] {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let chip = simulation.stm32(index)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.isConnected ? "GDB is connected on port \(server.port)." : "Listening on port \(server.port).")
                            .font(.callout)
                        if let chip, chip.isHalted {
                            Text(String(format: "Halted at 0x%08X", chip.programCounter)).font(.caption.monospaced())
                        }
                        Text("arm-none-eabi-gdb firmware.elf -ex \"target extended-remote localhost:\(server.port)\"")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    // (a chip made anew, the circuit rebuilt, keeps its debugger)
                    .onChange(of: chip.map { ObjectIdentifier($0) }) { _, _ in if let chip { server.retarget(chip) } }
                }
                Button("Stop GDB Server") { simulation.stopGDBServer(id) }
            } else {
                HStack {
                    TextField("Port", value: $port, format: .number.grouping(.never))
                        .frame(width: 70)
                    Button("Start GDB Server") {
                        problem = simulation.startGDBServer(id, index: index, port: UInt16(clamping: port))
                    }
                }
                Text("Debug the firmware as it runs in the circuit: breakpoints, stepping, registers, memory. While halted, the chip's clock and peripherals run on with the circuit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Debugger")
        }
    }
}

// MARK: - Sketch editor

/// A larger editor for a microcontroller's sketch, with Upload and the compiler's messages
struct SketchEditorSheet: View {
    @ObservedObject var editor: EditorState
    let elementID: UUID
    @State private var code = ""
    @State private var loaded = false

    @ObservedObject private var chipSupport = ChipSupportModel.shared

    init(editor: EditorState, elementID: UUID) {
        _editor = ObservedObject(wrappedValue: editor)
        self.elementID = elementID
    }

    private var board: Board? { editor.circuit[elementID]?.kind.board }
    private var status: SketchStatus? { editor.sketchStatus[elementID] }
    private var isBuilding: Bool { status?.isBuilding == true }
    private var isInstalled: Bool {
        guard let family = board?.sketchFamily else { return false }
        if case .installed = chipSupport.state(family) { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editor.circuit[elementID]?.name ?? "Sketch").font(.headline)
                Text(board.map { $0.title == $0.chip ? $0.chip : "\($0.chip) · \($0.title)" } ?? "").foregroundStyle(.secondary)
                Spacer()
                if isBuilding {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { editor.cancelUpload(elementID) }
                } else {
                    Button("Upload") { upload() }
                        .keyboardShortcut("u", modifiers: .command)
                }
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            TextEditor(text: $code)
                .font(.system(size: 13, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(8)
            Divider()
            messages
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .frame(height: 150)
        }
        .frame(minWidth: 640, minHeight: 520)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            code = editor.circuit[elementID]?.code ?? board?.blinkSketch ?? blinkTemplate
        }
    }

    @ViewBuilder
    private var messages: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                switch status {
                case .building(let step, _)?:
                    Text(step + "…").foregroundStyle(.secondary)
                    SketchStatusDetails(status: status)
                case .uploaded(let bytes, _)?:
                    let room = editor.circuit[elementID].flatMap { element in board?.flashSize(for: element) } ?? board?.flashSize ?? 32_256
                    Label("Uploaded: \(bytes.formatted()) of \(room.formatted()) bytes. The chip restarted with the new sketch.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    SketchStatusDetails(status: status)
                case .failed(let failure)?:
                    Text(failure.headline).font(.callout.weight(.semibold)).foregroundStyle(.red)
                    SketchStatusDetails(status: status)
                case .cancelled?:
                    Text("Compiling was cancelled.").foregroundStyle(.secondary)
                case nil:
                    if board?.compilesSketches == false {
                        Text("The \(board?.chip ?? "chip") runs firmware built with its maker's tools: load it with Load Firmware….")
                            .foregroundStyle(.secondary)
                    } else if isInstalled {
                        Text("Write a sketch as in the Arduino IDE, then Upload (⌘U).").foregroundStyle(.secondary)
                    }
                }
                // chip support, installed from here (a second sheet cannot open over this one)
                if let family = board?.sketchFamily {
                    switch chipSupport.state(family) {
                    case .installed:
                        EmptyView()
                    case .downloading(let fraction, let message):
                        HStack {
                            ProgressView(value: fraction) { Text("Installing chip support for the \(board?.chip ?? "chip")") }
                                currentValueLabel: { Text(message) }
                            Button("Cancel") { chipSupport.cancel(family) }
                        }
                    case .unpacking(let message):
                        HStack {
                            ProgressView { Text(message) }
                            Button("Cancel") { chipSupport.cancel(family) }
                        }
                    case .notInstalled, .failed:
                        if case .failed(let message) = chipSupport.state(family) {
                            Text(message).font(.caption).foregroundStyle(.red)
                        }
                        HStack {
                            Text("Compiling needs chip support for the \(board?.chip ?? "chip"): \(family.summary).")
                                .foregroundStyle(.secondary)
                            Button("Install") { chipSupport.install(family) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func upload() {
        editor.uploadSketch(elementID, code: code)
    }

    private func close() {
        // the code is kept with the part even if it was not uploaded
        if editor.circuit[elementID]?.code != code { editor.setSketchCode(elementID, code) }
        editor.editingSketch = nil
    }
}

// MARK: - Chip support

/// Each chip family's chip support, to install, cancel or remove, like the Arduino IDE's boards manager. It needs no
/// circuit window: its installs belong to `ChipSupportModel`, and go on when the list is closed.
struct ChipSupportList: View {
    @ObservedObject private var model = ChipSupportModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(ChipFamily.allCases) { family in
                row(family)
            }
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    @ViewBuilder
    private func row(_ family: ChipFamily) -> some View {
        let state = model.state(family)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cpu").font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(family.title).font(.headline)
                Text(family.summary).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                switch state {
                case .notInstalled:
                    Text("Not installed").font(.caption).foregroundStyle(.secondary)
                case .downloading(let fraction, let message):
                    ProgressView(value: fraction)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                case .unpacking(let message):
                    ProgressView().progressViewStyle(.linear)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                case .installed(let description):
                    Text(description).font(.caption)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if state.isBusy {
                Button("Cancel") { model.cancel(family) }
            } else if ChipSupport.installedVersions(family) != nil {
                Button("Remove") { model.remove(family) }
            } else if case .installed = state {
                // (an Arduino IDE's toolchain: JSpice has nothing of its own to remove)
                EmptyView()
            } else if case .failed = state {
                Button("Try Again") { model.install(family) }
            } else {
                Button("Install") { model.install(family) }
            }
        }
    }
}

/// Chip Support in a circuit window: the list, and Done
struct ChipSupportSheet: View {
    @ObservedObject var editor: EditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Chip Support").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { editor.showChipSupport = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text("Microcontrollers run real firmware compiled from your sketch. The compiler and the Arduino core come from their makers' package indexes (Arduino's, and arduino-pico's for the Pico); JSpice downloads them once and keeps them in its Application Support folder. An install goes on if this sheet is closed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ChipSupportList()
            }
            .padding(20)
            Spacer(minLength: 0)
        }
        .frame(width: 560, height: 420)
    }
}
