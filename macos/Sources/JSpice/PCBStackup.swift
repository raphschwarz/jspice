import AppKit
import SwiftUI
import KiCadKit
import KiCadRouter

extension PCBEditing {
    /// The stackup editor (KiCad's Board Setup ▸ Physical Stackup and Board Finish) opened on the board's stackup as
    /// the page shows it
    func openStackup() {
        guard !isRouting, !isDragging else { return NSSound.beep() }
        Task {
            await settled()
            if !isReady { await prepareNow() }
            guard let stackup = await engine.run({ $0.boardSetupStackup }) else { return NSSound.beep() }
            editorSheet = .stackup(stackup)
        }
    }

    /// The stackup edited taken as the dialog's OK takes it, as one change ("Edit Board Stackup"): the board's
    /// thickness the stackup's, the heights between its layers (which a length tuning counts for a via) from it
    func setStackup(_ stackup: BoardStackup) {
        Task { if await place({ $0.setStackup(stackup) }) == false { NSSound.beep() } }
    }
}

/// The board's stackup as Board Setup's Physical Stackup page edits it: a row for each of the board's layers (each
/// sublayer of a dielectric), its thickness (a dielectric's lockable), its material from KiCad's lists or typed in
/// (its epsilon R and loss tangent with it), and its colour; a dielectric's type and sublayers; the board's thickness
/// as the layers add up; and the Board Finish page's finish, impedance control and edges
struct PCBStackupSheet: View {
    @ObservedObject var editing: PCBEditing
    @State private var stackup: BoardStackup
    @Environment(\.dismiss) private var dismiss

    init(editing: PCBEditing, stackup: BoardStackup) {
        self.editing = editing
        _stackup = State(initialValue: stackup)
    }

    /// The board's thickness as the page adds it up (computeBoardThickness: the layers shown)
    private var thickness: Int { stackup.items.filter(\.enabled).reduce(0) { $0 + $1.thickness } }

    /// What the dialog's OK refuses ("A layer thickness is < 0")
    private var problem: String? {
        stackup.items.contains { $0.enabled && $0.sublayers.contains { $0.thickness < 0 } } ? "A layer thickness is < 0." : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Physical Stackup").font(.headline)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Layer")
                        Text("Type")
                        Text("Material")
                        Text("Thickness")
                        Text("")
                        Text("Color")
                        Text("εr")
                        Text("Loss tan")
                        Text("")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(stackup.items.indices, id: \.self) { i in
                        if stackup.items[i].enabled {
                            ForEach(stackup.items[i].sublayers.indices, id: \.self) { j in
                                row(i, j)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 280)
            HStack {
                Text("Board thickness")
                Text(String(format: "%.4f mm", Double(thickness) / 1e6)).monospacedDigit()
            }
            Divider()
            Text("Board Finish").font(.headline)
            Grid(alignment: .leading, verticalSpacing: 6) {
                GridRow {
                    Text("Copper finish")
                    Picker("", selection: $stackup.finish) {
                        ForEach(options(BoardStackup.finishes, current: stackup.finish), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                GridRow {
                    Text("")
                    Toggle("Impedance controlled", isOn: $stackup.dielectricConstraints)
                }
                GridRow {
                    Text("Edge card connectors")
                    Picker("", selection: $stackup.edgeConnector) {
                        Text("None").tag(0)
                        Text("Yes").tag(1)
                        Text("Yes, bevelled").tag(2)
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                GridRow {
                    Text("")
                    Toggle("Plated board edge", isOn: $stackup.edgePlating)
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { editing.editorSheet = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    guard problem == nil else { return NSSound.beep() }
                    let made = stackup
                    editing.editorSheet = nil
                    dismiss()
                    editing.setStackup(made)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 860, height: 640)
    }

    /// A list's choices, with the value it has where it is not one of them (a user's own)
    private func options(_ list: [String], current: String) -> [String] {
        list.contains(current) || current.isEmpty ? list : list + [current]
    }

    @ViewBuilder
    private func row(_ i: Int, _ j: Int) -> some View {
        let item = stackup.items[i]
        GridRow {
            Text(j == 0 ? item.layer ?? "Dielectric \(item.dielectricID)" : "").lineLimit(1)
            if item.kind == .dielectric && j == 0 {
                Picker("", selection: $stackup.items[i].typeName) {
                    Text("core").tag("core")
                    Text("prepreg").tag("prepreg")
                }
                .labelsHidden()
                .frame(width: 90)
            } else {
                Text(j == 0 ? item.typeName : "").foregroundStyle(.secondary)
            }
            if item.isMaterialEditable {
                material(i, j)
            } else {
                Text(item.kind == .copper ? "copper" : "").foregroundStyle(.secondary)
            }
            if item.isThicknessEditable {
                TextField("", value: Binding(get: { Double(stackup.items[i].sublayers[j].thickness) / 1e6 },
                                             set: { stackup.items[i].sublayers[j].thickness = Int(($0 * 1e6).rounded()) }),
                          format: .number.precision(.fractionLength(0...4)))
                    .frame(width: 80)
                if item.kind == .dielectric {
                    Toggle("Locked", isOn: $stackup.items[i].sublayers[j].thicknessLocked)
                        .help("Kept as it is when the board's layer count changes the others")
                } else {
                    Text("")
                }
            } else {
                Text("")
                Text("")
            }
            if item.isColorEditable {
                Picker("", selection: $stackup.items[i].sublayers[j].color) {
                    ForEach(options(BoardStackup.colors(item.kind), current: stackup.items[i].sublayers[j].color), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            } else {
                Text("")
            }
            if item.hasEpsilonR {
                TextField("", value: $stackup.items[i].sublayers[j].epsilonR, format: .number.precision(.fractionLength(0...4)))
                    .frame(width: 60)
                TextField("", value: $stackup.items[i].sublayers[j].lossTangent, format: .number.precision(.fractionLength(0...6)))
                    .frame(width: 70)
            } else {
                Text("")
                Text("")
            }
            if item.kind == .dielectric {
                HStack(spacing: 2) {
                    Button { stackup.addSublayer(item: i) } label: { Image(systemName: "plus.circle") }
                        .help("A sublayer added to the dielectric, after its last (Add Dielectric Layer)")
                    Button { stackup.removeSublayer(item: i, sublayer: j) } label: { Image(systemName: "minus.circle") }
                        .disabled(item.sublayers.count < 2)
                        .help("This sublayer taken out of the dielectric (Remove Dielectric Layer: never its last)")
                }
                .buttonStyle(.borderless)
            } else {
                Text("")
            }
        }
    }

    /// A layer's material: one of KiCad's for its kind (its epsilon R and loss tangent with it), or the user's own
    private func material(_ i: Int, _ j: Int) -> some View {
        let kind = stackup.items[i].kind
        let names = BoardStackup.materials(kind).map(\.name)
        return HStack(spacing: 2) {
            TextField("", text: Binding(get: { stackup.items[i].sublayers[j].material },
                                        set: { stackup.items[i].sublayers[j].material = $0 }))
                .frame(width: 110)
            Menu {
                ForEach(names, id: \.self) { name in
                    Button(name) { stackup.setMaterial(name, item: i, sublayer: j) }
                }
            } label: {
                Image(systemName: "list.bullet")
            }
            .frame(width: 28)
            .help("One of KiCad's materials, its epsilon R and loss tangent with it")
        }
    }
}

/// Board setup's editors of the stackup and of the rules file (Board Setup's Physical Stackup and Custom Rules pages)
struct PCBSetupEditorsRow: View {
    @ObservedObject var board: BoardController
    @ObservedObject var editing: PCBEditing

    var body: some View {
        HStack {
            Button("Physical Stackup…") { editing.openStackup() }
                .help("Each layer's thickness, material, epsilon R, loss tangent and colour, a dielectric's sublayers, and the board's finish and edges, as KiCad's Board Setup edits them: the board's thickness, and the heights a length tuning counts for vias, follow")
            Button("Custom Rules…") { editing.openRulesEditor() }
                .help("The board's rules file (its .kicad_dru), edited and checked as KiCad's Board Setup checks it, and saved beside the project: routing, checks and fills go by it")
        }
        .disabled(editing.isRouting || board.busy != nil)
    }
}
