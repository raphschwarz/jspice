import SwiftUI
import CircuitKit

// MARK: - Tool HUD

/// While a part is being placed: which one, and how, in a pill at the top of the schematic
struct ToolHUD: View {
    @ObservedObject var editor: EditorState

    var body: some View {
        if let kind = editor.tool {
            HStack(spacing: 10) {
                Image(nsImage: SymbolIcons.image(kind))
                    .renderingMode(.template)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 20)
                Text(kind.displayName).fontWeight(.semibold)
                Text("Click to place · drag to set its length and direction")
                    .foregroundStyle(.secondary)
                KeyCap("esc")
                Text("done").foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// A key drawn as a keycap
struct KeyCap: View {
    let label: String

    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.caption.monospaced().weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .frame(minWidth: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 0.5))
    }
}

// MARK: - Zoom control

/// Zoom out, the zoom level (click to fit) and zoom in, floating in the schematic's corner
struct ZoomControl: View {
    @ObservedObject var editor: EditorState

    var body: some View {
        HStack(spacing: 0) {
            Button { editor.changeZoom(by: 0.8) } label: {
                Image(systemName: "minus").frame(width: 26, height: 24)
            }
            .help("Zoom out (⌘−)")
            Divider().frame(height: 14)
            Button { editor.requestFit() } label: {
                Text("\(Int((editor.zoom * 100).rounded())) %")
                    .monospacedDigit()
                    .frame(width: 52, height: 24)
            }
            .help("Zoom to fit (⌘0)")
            Divider().frame(height: 14)
            Button { editor.changeZoom(by: 1.25) } label: {
                Image(systemName: "plus").frame(width: 26, height: 24)
            }
            .help("Zoom in (⌘=)")
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
    }
}

// MARK: - Quick add

/// ⌘K or /: type to find a part (by name, category or the real part it models, such as "TL072") or an example, and
/// press Return to place it
struct QuickAddPalette: View {
    @ObservedObject var editor: EditorState
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private enum Item: Hashable {
        case part(ElementKind)
        case example(String)
    }

    private var items: [Item] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        let parts = ElementKind.allCases.filter(\.isPlaceable)
            .compactMap { kind -> (Item, Int)? in
                guard let score = Self.score(text, kind.searchTerms) else { return nil }
                return (.part(kind), score)
            }
        let examples = text.isEmpty ? [] : Examples.all.compactMap { example -> (Item, Int)? in
            guard let score = Self.score(text, [example.title]) else { return nil }
            return (.example(example.id), score + 10)
        }
        return (parts + examples).sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Lower is better: the name starts with the text, a word does, it contains it, or its letters appear in order
    private static func score(_ text: String, _ terms: [String]) -> Int? {
        guard !text.isEmpty else { return 0 }
        var best: Int?
        for (rank, term) in terms.enumerated() {
            let name = term.lowercased()
            let penalty = rank == 0 ? 0 : 3
            var score: Int?
            if name.hasPrefix(text) {
                score = 0
            } else if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(text) }) {
                score = 1
            } else if name.contains(text) {
                score = 2
            } else if isSubsequence(text, of: name) {
                score = 5
            }
            if let score { best = min(best ?? .max, score + penalty) }
        }
        return best
    }

    private static func isSubsequence(_ text: String, of name: String) -> Bool {
        var rest = Substring(name)
        for character in text {
            guard let found = rest.firstIndex(of: character) else { return false }
            rest = rest[rest.index(after: found)...]
        }
        return true
    }

    var body: some View {
        let items = self.items
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Add a part — try “resistor”, “TL072” or “vactrol”", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { choose(items.indices.contains(highlighted) ? items[highlighted] : nil) }
                    .onKeyPress(.downArrow) {
                        highlighted = min(highlighted + 1, max(items.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        highlighted = max(highlighted - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        close()
                        return .handled
                    }
                KeyCap("esc")
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element) { index, item in
                            row(item, active: index == highlighted)
                                .id(index)
                                .onTapGesture { choose(item) }
                                .onHover { inside in if inside { highlighted = index } }
                        }
                        if items.isEmpty {
                            Text("Nothing matches “\(query)”")
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
            }
            .frame(height: 330)
        }
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    @ViewBuilder
    private func row(_ item: Item, active: Bool) -> some View {
        HStack(spacing: 10) {
            switch item {
            case .part(let kind):
                Image(nsImage: SymbolIcons.image(kind))
                    .renderingMode(.template)
                    .frame(width: 34, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.displayName)
                    let models = kind.models.map(\.name).prefix(5).joined(separator: ", ")
                    Text(models.isEmpty ? kind.category.rawValue : models)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let shortcut = kind.shortcutLabel { KeyCap(shortcut) }
            case .example(let id):
                let example = Examples.example(id)
                Image(systemName: example?.symbol ?? "doc")
                    .frame(width: 34, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(example?.title ?? id)
                    Text("Example").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(active ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func choose(_ item: Item?) {
        switch item {
        case .part(let kind)?:
            editor.choose(kind)
        case .example(let id)?:
            if let example = Examples.example(id) { editor.load(example) }
            close()
        case nil:
            break
        }
    }

    private func close() {
        editor.showQuickAdd = false
        if let canvas = editor.canvas { canvas.window?.makeFirstResponder(canvas) }
    }
}

// MARK: - Shortcuts

/// Every keyboard shortcut, grouped (⌘/ or ?)
struct ShortcutsSheet: View {
    @ObservedObject var editor: EditorState

    private let general: [(String, [(String, String)])] = [
        ("Drawing", [
            ("⌘K  or  /", "Add a part by name"),
            ("Esc", "Back to selecting (or stop drawing)"),
            ("Click / drag", "Place the chosen part / set its length and direction"),
            ("Drag a part", "Move it; wires attached to it stretch"),
            ("Drag an end", "Resize or turn the selected part"),
        ]),
        ("Editing", [
            ("⌘Z  ⇧⌘Z", "Undo, redo"),
            ("⌫", "Delete the selection"),
            ("⌘D", "Duplicate the selection"),
            ("← → ↑ ↓", "Nudge the selection (⇧: five units)"),
            ("⌘R  F", "Rotate, flip"),
            ("Tab  ⇧Tab", "Select the next or previous part"),
            ("⌘A  ⌘C  ⌘X  ⌘V", "Select all, copy, cut, paste"),
            ("⌥⌘T", "Tidy up the drawing"),
        ]),
        ("View and simulation", [
            ("⌘=  ⌘−  ⌘0", "Zoom in, out, to fit"),
            ("Scroll, pinch", "Pan, zoom"),
            ("Space  ⌘↩", "Run or pause"),
            ("⇧⌘↩", "Reset to time zero"),
            ("Scroll over a pot", "Turn it"),
            ("⇧⌘E", "Export an image"),
        ]),
        ("Playing (sound on, with a keyboard source)", [
            ("A W S E D F T G Y H U J K O L P ;", "Notes from C, like a piano keyboard"),
            ("Z  X", "Octave down, up"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { editor.showShortcuts = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(general, id: \.0) { group in
                            section(group.0, group.1)
                        }
                    }
                    .frame(width: 400, alignment: .leading)
                    section("Parts", ElementKind.allCases.compactMap { kind in
                        kind.shortcutLabel.map { ($0, kind.displayName) }
                    })
                    .frame(width: 240, alignment: .leading)
                }
                .padding(20)
            }
        }
        .frame(width: 740, height: 600)
    }

    private func section(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(rows, id: \.0) { keys, action in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(keys)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 70, alignment: .leading)
                    Text(action).font(.callout)
                }
            }
        }
    }
}
