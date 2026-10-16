import SwiftUI
import CircuitKit
import KiCadKit

/// A part as its board has it: its reference, its footprint (JSpice's choice, or one chosen from KiCad's libraries),
/// whether it is on the board and fitted, and a transistor's pinout
struct PCBPartSection: View {
    @ObservedObject var editor: EditorState
    @ObservedObject var board: BoardController
    let element: Element
    @State private var footprint = ""
    @State private var pinout = ""
    @State private var choosing = false
    @FocusState private var footprintFocused: Bool

    private static let transistors: Set<ElementKind> = [.npn, .pnp, .nmos, .pmos, .njfet, .pjfet]

    var body: some View {
        let id = element.id.uuidString
        let design = editor.circuit.pcb ?? PCBDesign()
        let part = board.onBoard[element.id]
        if part != nil || design.offBoard.contains(id) {
            Section {
                Toggle("On the board", isOn: Binding(get: { !design.offBoard.contains(id) }, set: { on in
                    editor.editBoard(on ? "Put on the Board" : "Take off the Board") { if on { _ = $0.offBoard.remove(id) } else { _ = $0.offBoard.insert(id) } }
                }))
                .help("A part left off the board is wired to it from elsewhere: a supply, a speaker, a sensor")
                if let part {
                    LabeledContent("Reference", value: part.reference)
                    LabeledContent("Value", value: part.value)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Footprint")
                        TextField("Footprint", text: $footprint, prompt: Text("Library:Footprint"))
                            .labelsHidden()
                            .font(.callout.monospaced())
                            .focused($footprintFocused)
                            .onSubmit { setFootprint(footprint) }
                            .onChange(of: footprintFocused) { _, focused in
                                if !focused && footprint != part.footprint { setFootprint(footprint) }
                            }
                        HStack {
                            Button("Choose…") { choosing = true }
                            if design.footprints[id] != nil {
                                Button("Use JSpice's Choice") { setFootprint("") }
                                    .help("The footprint JSpice gives the part for the board's style (through-hole or surface-mount)")
                            }
                        }
                        .controlSize(.small)
                    }
                    Toggle("Fitted", isOn: Binding(get: { !design.doNotPopulate.contains(id) }, set: { fitted in
                        editor.editBoard(fitted ? "Fit on the Board" : "Do Not Fit") { if fitted { _ = $0.doNotPopulate.remove(id) } else { _ = $0.doNotPopulate.insert(id) } }
                    }))
                    .help("A part not fitted keeps its place on the board but is left out of the assembly files")
                    if let plus = part.plus {
                        LabeledContent("Polarity") {
                            Button("Turn Round") {
                                let terminals = element.terminalNames
                                editor.editBoard("Turn Round") { design in design.polarity[id] = terminals.first { $0 != plus } }
                            }
                        }
                        .help("Which way round the electrolytic goes on the board: settled by the circuit's resting voltages when it first went on, and kept as the circuit changes")
                    }
                    if Self.transistors.contains(element.kind) {
                        LabeledContent("Pinout") {
                            TextField("Pinout", text: $pinout, prompt: Text(element.kind == .npn || element.kind == .pnp ? "EBC" : "GDS"))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 80)
                                .onSubmit {
                                    let legs = pinout.uppercased().trimmingCharacters(in: .whitespaces)
                                    editor.editBoard("Change Pinout") { $0.pinouts[id] = legs.isEmpty ? nil : legs }
                                }
                        }
                        .help("The legs in the order of the footprint's pads, where the transistor's own order is not its footprint's: EBC, CBE, BCE; GDS, DGS")
                    }
                }
            } header: {
                Text("Board")
            } footer: {
                if part == nil { Text("Wired to the board from elsewhere.") }
            }
            .sheet(isPresented: $choosing) {
                FootprintPicker(board: board, current: part?.footprint ?? "") { setFootprint($0) }
            }
            .onAppear {
                footprint = part?.footprint ?? ""
                pinout = design.pinouts[id] ?? ""
            }
            .onChange(of: part?.footprint) { _, value in if !footprintFocused { footprint = value ?? "" } }
        }
    }

    private func setFootprint(_ text: String) {
        let id = element.id.uuidString
        let libID = text.trimmingCharacters(in: .whitespacesAndNewlines)
        editor.editBoard("Change Footprint") { $0.footprints[id] = libID.isEmpty ? nil : libID }
    }
}

/// The board's own settings, with no part selected: its parts' style and copper layers, and where it is
struct PCBDesignSection: View {
    @ObservedObject var editor: EditorState
    @ObservedObject var board: BoardController

    var body: some View {
        let design = editor.circuit.pcb ?? PCBDesign()
        Section {
            Picker("Parts", selection: Binding(get: { design.style }, set: { style in
                editor.editBoard("Board Parts' Style") { $0.style = style }
            })) {
                ForEach(PCBDesign.Style.allCases) { Text($0.title).tag($0) }
            }
            .help("The footprints for parts that have none of their own")
            if board.availability != .board {
                Picker("Copper layers", selection: Binding(get: { design.copperLayers }, set: { layers in
                    editor.editBoard("Board Layers") { $0.copperLayers = layers }
                })) {
                    Text("2").tag(2)
                    Text("4").tag(4)
                    Text("6").tag(6)
                }
            }
            switch board.availability {
            case .board:
                LabeledContent("File", value: board.boardName)
                LabeledContent("KiCad", value: board.isLive ? "Open, in step" : board.isOpenInKiCad ? "Open, out of reach" : "Not open")
            case .noBoard:
                Button("Make Board…") { editor.board = .pcb }
            case .unsaved:
                Text("Save the circuit to make its board.").foregroundStyle(.secondary)
            case .noKiCad:
                Text("Install KiCad 10 or later to make its board.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Printed circuit board")
        }
    }
}

/// A footprint chosen from KiCad's libraries: a library and one of its footprints, or a search of them all, with the
/// footprint drawn as it will be on the board
struct FootprintPicker: View {
    @ObservedObject var board: BoardController
    let current: String
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var library: KiCadFootprintLibrary?
    @State private var libraries: [String] = []
    @State private var selectedLibrary: String?
    @State private var names: [String] = []
    @State private var everything: [String]?
    @State private var search = ""
    @State private var picked: String?
    @State private var preview: KiCadBoardPicture?
    @State private var loaded = false

    /// What the list shows: the library's footprints, or every library's that the search finds
    private var shown: [String] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return names.map { (selectedLibrary ?? "") + ":" + $0 } }
        let pool = everything ?? names.map { (selectedLibrary ?? "") + ":" + $0 }
        return Array(pool.lazy.filter { id in let l = id.lowercased(); return words.allSatisfy { l.contains($0) } }.prefix(400))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose a Footprint").font(.headline)
                Spacer()
                TextField("Search every library", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
            }
            .padding(12)
            Divider()
            if !loaded {
                ProgressView("Reading KiCad's libraries…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if libraries.isEmpty {
                Text("KiCad's footprint libraries were not found.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(libraries, id: \.self, selection: $selectedLibrary) { Text($0).lineLimit(1) }
                        .frame(width: 210)
                        .opacity(search.isEmpty ? 1 : 0.5)
                    Divider()
                    List(shown, id: \.self, selection: $picked) { id in
                        Text(search.isEmpty ? (KiCadFootprintLibrary.split(id)?.name ?? id) : id).font(.callout).lineLimit(1)
                    }
                    Divider()
                    previewPane.frame(width: 220)
                }
            }
            Divider()
            HStack {
                Text(picked ?? current).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose") {
                    if let picked { choose(picked) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked == nil)
            }
            .padding(12)
        }
        .frame(width: 820, height: 520)
        .task {
            library = await board.footprintLibrary()
            libraries = library?.libraries.keys.sorted() ?? []
            loaded = true
            let split = KiCadFootprintLibrary.split(current)
            selectedLibrary = split.map { $0.library }.flatMap { libraries.contains($0) ? $0 : nil } ?? libraries.first
            if split != nil { picked = current }
        }
        .task(id: selectedLibrary) {
            guard let library, let name = selectedLibrary else { return }
            names = await Task.detached { library.footprints(in: name) }.value
        }
        .task(id: search.isEmpty) {
            // every library's footprints, read once, for searching them all
            guard !search.isEmpty, everything == nil, let library else { return }
            let all = libraries
            everything = await Task.detached { all.flatMap { lib in library.footprints(in: lib).map { lib + ":" + $0 } } }.value
        }
        .task(id: picked) {
            guard let library, let id = picked else { preview = nil; return }
            preview = await Task.detached { () -> KiCadBoardPicture? in
                guard let node = try? library.placeable(id, reference: "REF", value: "", at: KiCadPoint(0, 0)),
                      let board = try? KiCadBoard(text: "(kicad_pcb (version 20260206) (generator \"jspice\"))") else { return nil }
                board.add(node)
                return KiCadBoardPicture(board)
            }.value
        }
    }

    @ViewBuilder private var previewPane: some View {
        if let preview, let footprint = preview.footprints.first {
            GeometryReader { geometry in
                let box = footprint.box.inflated(1)
                let scale = min((geometry.size.width - 24) / box.width, (geometry.size.height - 60) / box.height)
                let view = PCBTransform(bounds: box, scale: max(1, scale), mirrored: false)
                VStack(spacing: 8) {
                    Canvas { context, _ in
                        PCBPainter(picture: preview, view: view, side: .front, selected: [], drc: nil).draw(context)
                    }
                    .frame(width: view.size.width, height: view.size.height)
                    Text(String(format: "%.2f × %.2f mm, %d pads", footprint.box.width, footprint.box.height, preview.pads.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(PCBPainter.background)
        } else {
            Text("Choose a footprint to see it").font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
