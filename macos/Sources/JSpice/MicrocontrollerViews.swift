import SwiftUI
import CircuitKit

/// Where a microcontroller's last upload got to
enum SketchStatus: Equatable {
    case building
    case uploaded(bytes: Int)
    case failed(errors: [SketchBuilder.Diagnostic], log: String)
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

/// The microcontroller's part of the inspector: its program, uploading, and its serial monitor
struct MicrocontrollerSection: View {
    @ObservedObject var editor: EditorState
    let element: Element

    var body: some View {
        Section {
            HStack {
                Image(systemName: element.firmware == nil ? "cpu" : "cpu.fill")
                    .foregroundStyle(element.firmware == nil ? Color.secondary : Color.accentColor)
                Text(statusText).font(.callout)
                Spacer()
            }
            if case .failed(let errors, _)? = editor.sketchStatus[element.id] {
                ForEach(Array(errors.prefix(4).enumerated()), id: \.offset) { _, error in
                    Text("Line \(error.line): \(error.message)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
            HStack {
                Button("Edit Sketch…") { editor.editingSketch = element.id }
                Button("Upload") { editor.uploadSketch(element.id, code: element.code ?? blinkTemplate) }
                    .disabled(editor.sketchStatus[element.id] == .building)
                    .help("Compile the sketch and load it into the chip (⌘U)")
                Button("Restart") { editor.simulation.reset() }
                    .help("Start the circuit, and the chip, from the beginning")
            }
            if !ChipSupport.isAvailable(.avr) {
                Text("Compiling sketches needs AVR chip support: avr-gcc and the Arduino core, about 40 MB from Arduino.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Install Chip Support…") { editor.showChipSupport = true }
            }
        } header: {
            Text("Program")
        }
        if let index = editor.circuit.index(of: element.id) {
            SerialMonitor(simulation: editor.simulation, index: index)
        }
    }

    private var statusText: String {
        switch editor.sketchStatus[element.id] {
        case .building?: return "Compiling…"
        case .uploaded(let bytes)?: return "Uploaded: \(bytes.formatted()) of 32,256 bytes"
        case .failed(let errors, _)?: return errors.isEmpty ? "The sketch did not build" : "\(errors.count) error\(errors.count == 1 ? "" : "s")"
        case nil:
            if let firmware = element.firmware { return "Running its sketch (\(firmware.count.formatted()) bytes)" }
            return "No sketch yet: edit one and upload it"
        }
    }
}

/// What the chip's USART has sent, and a field to send it text
struct SerialMonitor: View {
    @ObservedObject var simulation: SimulationController
    let index: Int
    @State private var input = ""

    var body: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                let text = simulation.serialOutput(index)
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(text.isEmpty ? "Nothing yet. Serial.begin(9600) and Serial.println() write here." : text)
                            .font(.caption.monospaced())
                            .foregroundStyle(text.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(height: 140)
                    .onChange(of: text) { _, _ in proxy.scrollTo("end") }
                }
            }
            HStack {
                TextField("Send", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send).disabled(input.isEmpty)
            }
        } header: {
            Text("Serial Monitor")
        }
    }

    private func send() {
        simulation.sendSerial(index, input + "\n")
        input = ""
    }
}

// MARK: - Sketch editor

/// A larger editor for a microcontroller's sketch, with Upload and the compiler's messages
struct SketchEditorSheet: View {
    @ObservedObject var editor: EditorState
    let elementID: UUID
    @State private var code = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editor.circuit[elementID]?.name ?? "Sketch").font(.headline)
                Text("ATmega328P · Arduino Uno").foregroundStyle(.secondary)
                Spacer()
                if editor.sketchStatus[elementID] == .building { ProgressView().controlSize(.small) }
                Button("Upload") { upload() }
                    .keyboardShortcut("u", modifiers: .command)
                    .disabled(editor.sketchStatus[elementID] == .building)
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
                .frame(height: 110)
        }
        .frame(minWidth: 640, minHeight: 520)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            code = editor.circuit[elementID]?.code ?? blinkTemplate
        }
    }

    @ViewBuilder
    private var messages: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                switch editor.sketchStatus[elementID] {
                case .building?:
                    Text("Compiling…").foregroundStyle(.secondary)
                case .uploaded(let bytes)?:
                    Label("Uploaded: \(bytes.formatted()) of 32,256 bytes. The chip restarted with the new sketch.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed(let errors, let log)?:
                    if errors.isEmpty {
                        Text(log).font(.caption.monospaced()).foregroundStyle(.red)
                    }
                    ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                        Text("Line \(error.line):\(error.column): \(error.message)")
                            .font(.caption.monospaced())
                            .foregroundStyle(error.isError ? .red : .orange)
                    }
                case nil:
                    if ChipSupport.isAvailable(.avr) {
                        Text("Write a sketch as in the Arduino IDE, then Upload (⌘U).").foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text("Compiling needs AVR chip support (about 40 MB from Arduino).").foregroundStyle(.secondary)
                            Button("Install…") { editor.showChipSupport = true }
                        }
                    }
                }
            }
            .textSelection(.enabled)
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

/// Installs and removes what compiling for each chip family takes, like the Arduino IDE's boards manager
struct ChipSupportSheet: View {
    @ObservedObject var editor: EditorState
    @State private var progress: [ChipFamily: ChipSupport.Progress] = [:]
    @State private var failure: [ChipFamily: String] = [:]
    @State private var refresh = 0

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
                Text("Microcontrollers run real firmware compiled from your sketch. The compiler and the Arduino core come from Arduino's own package index; JSpice downloads them once and keeps them in its Application Support folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(ChipFamily.allCases) { family in
                    row(family)
                }
            }
            .padding(20)
            .id(refresh)
            Spacer(minLength: 0)
        }
        .frame(width: 560, height: 340)
    }

    @ViewBuilder
    private func row(_ family: ChipFamily) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cpu").font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(family.title).font(.headline)
                Text(family.summary).font(.caption).foregroundStyle(.secondary)
                if let current = progress[family] {
                    ProgressView(value: current.fraction)
                    Text(current.message).font(.caption).foregroundStyle(.secondary)
                } else if let message = failure[family] {
                    Text(message).font(.caption).foregroundStyle(.red)
                } else if let versions = ChipSupport.installedVersions(family) {
                    Text("Installed: avr-gcc \(versions.compiler), Arduino AVR core \(versions.core)").font(.caption)
                } else if ChipSupport.isAvailable(family) {
                    Text("Using the toolchain of an Arduino IDE installed on this Mac").font(.caption)
                }
            }
            Spacer()
            if progress[family] == nil {
                if ChipSupport.installedVersions(family) != nil {
                    Button("Remove") {
                        try? ChipSupport.uninstall(family)
                        refresh += 1
                    }
                } else {
                    Button("Install") { install(family) }
                }
            }
        }
    }

    private func install(_ family: ChipFamily) {
        failure[family] = nil
        progress[family] = ChipSupport.Progress(fraction: 0, message: "Starting…")
        Task {
            do {
                try await ChipSupport.install(family) { update in
                    Task { @MainActor in progress[family] = update }
                }
            } catch {
                failure[family] = "\(error)"
            }
            progress[family] = nil
            refresh += 1
        }
    }
}
