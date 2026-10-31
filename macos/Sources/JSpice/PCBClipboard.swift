import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KiCadKit
import KiCadRouter

/// The editor's sheets: Paste Special's choices (for the clipboard's text), Create Array's (for the items selected),
/// the rules editor (on the rules file's text) and the stackup's (on the stackup as Board Setup shows it)
enum PCBEditorSheet: Identifiable {
    case pasteSpecial(String)
    case array(ArrayOptions, items: [String])
    case rules(String)
    case stackup(BoardStackup)

    var id: String {
        switch self {
        case .pasteSpecial: return "paste"
        case .array: return "array"
        case .rules: return "rules"
        case .stackup: return "stackup"
        }
    }
}

extension BoardController {
    /// The footprints selected: those selected in the PCB view, and those of the parts selected in the schematic
    var selectedFootprints: Set<String> {
        let parts = editor?.selection ?? []
        let linked = parts.isEmpty ? [] : partsOfFootprint.filter { !parts.isDisjoint(with: $0.value) }.map(\.key)
        return editing.footprintSelection.union(linked)
    }
}

/// What the engine made of a change besides the change: a cut's text, a paste's or duplicate's new items
private final class PCBMade: @unchecked Sendable {
    var text: String?
    var footprints: [String] = []
    var items: [String] = []
}

// MARK: - Copy, cut, paste and duplicate

extension PCBEditing {
    /// Everything selected on the board, by id, in a steady order: its tracks, vias and texts, the footprints
    /// (`footprints`, those of the parts selected in the schematic with them), the zone and the tuning pattern
    func selectedItems(footprints: Set<String>) -> [String] {
        var items = selection.union(footprints)
        if let zoneSelection { items.insert(zoneSelection) }
        if let patternSelection { items.insert(patternSelection) }
        return items.sorted()
    }

    /// KiCad's 50 pixels (a copy's reference point snaps to a corner no farther), in mm at the view's scale
    private var snapDistance: Double { 50 / max(viewScale, 0.01) }

    /// Copy (⌘C, KiCad's Ctrl+C): the items selected put on the pasteboard as KiCad's own clipboard text
    /// (CLIPBOARD_IO), so that KiCad's editor pastes them and this one pastes KiCad's; about the point KiCad picks
    /// them up by with the pointer where it is (BestDragOrigin)
    func copySelection(footprints: Set<String>) {
        let uuids = selectedItems(footprints: footprints)
        guard !uuids.isEmpty, !isRouting else { return NSSound.beep() }
        let cursor = pointer ?? .zero, snap = snapDistance
        Task {
            await settled()
            if !isReady { await prepareNow() }
            let text = await engine.run { s in s.copy(uuids, reference: s.dragOrigin(uuids, cursor: cursor, snapDistance: snap)) }
            guard let text else { return NSSound.beep() }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// Cut (⌘X): the items copied as Copy copies them, then taken away, as one change ("Cut")
    func cutSelection(footprints: Set<String>) {
        let uuids = selectedItems(footprints: footprints)
        guard !uuids.isEmpty, !isRouting, !isDragging else { return NSSound.beep() }
        let cursor = pointer ?? .zero, snap = snapDistance
        let made = PCBMade()
        Task {
            let cut = await place { s in
                guard let r = s.cut(uuids, reference: s.dragOrigin(uuids, cursor: cursor, snapDistance: snap)) else { return nil }
                made.text = r.text
                return r.edit
            }
            guard cut, let text = made.text else { return NSSound.beep() }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            selection = []
            footprintSelection = []
            zoneSelection = nil
            patternSelection = nil
        }
    }

    /// Paste (⌘V): the pasteboard's text placed with its reference point at the pointer (on the grid), as KiCad
    /// places a paste where it is clicked: KiCad's clipboard text (a board's items, or a footprint) with its nets
    /// mapped by name, new ids, references kept; any other text a text of its own on the layer being routed on
    func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return NSSound.beep() }
        paste(text, annotations: .keep, clearNets: false)
    }

    /// Paste Special (⌘⇧V): the sheet of KiCad's choices for the pasteboard's text
    func pasteSpecial() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return NSSound.beep() }
        editorSheet = .pasteSpecial(text)
    }

    func paste(_ text: String, annotations: BoardClipboard.Annotations, clearNets: Bool) {
        guard let p = pointer, !isRouting else { return NSSound.beep() }
        let at = Self.onGrid(p), layer = self.layer
        let made = PCBMade()
        Task {
            let pasted = await place { s in
                guard let edit = s.paste(text, at: at, annotations: annotations, clearNets: clearNets, layer: layer) else { return nil }
                made.footprints = edit.footprints
                made.items = edit.added + edit.changed + edit.drawings + edit.zones
                return edit
            }
            guard pasted else { return NSSound.beep() }
            selectMade(made)
        }
    }

    /// Duplicate (⌘D, KiCad's Ctrl+D, and its Duplicate and Increment, the same in the board's editor): the items
    /// selected copied, the copies placed as KiCad's move after it places them at its first click with the pointer
    /// where it is: their pick-up point (BestDragOrigin as a move has it) on the pointer, on the grid; as one change
    func duplicateSelection(footprints: Set<String>) {
        let uuids = selectedItems(footprints: footprints)
        guard !uuids.isEmpty, let p = pointer, !isRouting else { return NSSound.beep() }
        let at = Self.onGrid(p), snap = snapDistance
        let made = PCBMade()
        Task {
            let duplicated = await place { s in
                let origin = s.dragOrigin(uuids, cursor: p, snapDistance: snap, moving: true)
                guard let edit = s.duplicate(uuids, by: KiCadPoint(at.x - origin.x, at.y - origin.y)) else { return nil }
                made.footprints = edit.footprints
                made.items = edit.added + edit.changed + edit.drawings + edit.zones
                return edit
            }
            guard duplicated else { return NSSound.beep() }
            selectMade(made)
        }
    }

    /// What a paste or duplicate made selected (KiCad selects it), and nothing else
    private func selectMade(_ made: PCBMade) {
        controller?.select(footprints: [])
        footprintSelection = Set(made.footprints)
        selection = Set(made.items).subtracting(made.footprints)
        zoneSelection = nil
        patternSelection = nil
    }

    // MARK: - Align and distribute

    /// The items selected aligned or distributed (KiCad's Align and Distribute), with the pointer where it is (its
    /// item, where it is over one, is what the others are aligned to), as one change
    func align(_ how: BoardEditing.Alignment, footprints: Set<String>) {
        let uuids = selectedItems(footprints: footprints)
        guard uuids.count >= (how.distributes ? 3 : 2), !isRouting else { return NSSound.beep() }
        let cursor = pointer ?? .zero
        Task { if await place({ $0.align(uuids, how, cursor: cursor) }) == false { NSSound.beep() } }
    }
}

// MARK: - The view's side

/// The Edit menu's Copy, Cut and Paste on the board's canvas while it has the focus, the view's scale kept for
/// KiCad's distances in pixels, and the editor's sheets
struct PCBClipboardCommands: ViewModifier {
    @ObservedObject var board: BoardController
    @ObservedObject var editing: PCBEditing
    let footprints: Set<String>
    let scale: Double

    func body(content: Content) -> some View {
        content
            .background(PCBEditorSheets(board: board, editing: editing))
            .onCopyCommand {
                editing.copySelection(footprints: footprints)
                return []
            }
            .onCutCommand {
                editing.cutSelection(footprints: footprints)
                return []
            }
            .onPasteCommand(of: [.plainText, .utf8PlainText]) { _ in editing.paste() }
            .onAppear { editing.viewScale = scale }
            .onChange(of: scale) { _, s in editing.viewScale = s }
    }
}

/// The editor's sheets, opened by `editing.editorSheet`
struct PCBEditorSheets: View {
    @ObservedObject var board: BoardController
    @ObservedObject var editing: PCBEditing

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(item: $editing.editorSheet) { sheet in
                switch sheet {
                case .pasteSpecial(let text): PCBPasteSpecialSheet(editing: editing, text: text)
                case .array(let options, let items): PCBArraySheet(editing: editing, options: options, items: items)
                case .rules(let text): PCBRulesEditorSheet(board: board, editing: editing, text: text)
                case .stackup(let stackup): PCBStackupSheet(editing: editing, stackup: stackup)
                }
            }
    }
}

/// Paste Special, as KiCad's dialog asks: the references kept, made unique or taken off, and the nets kept or
/// cleared
struct PCBPasteSpecialSheet: View {
    @ObservedObject var editing: PCBEditing
    let text: String
    @State private var annotations = 0
    @State private var clearNets = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste Special").font(.headline)
            Picker("", selection: $annotations) {
                Text("Keep existing reference designators").tag(0)
                Text("Assign unique reference designators").tag(1)
                Text("Remove annotations").tag(2)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Toggle("Clear net assignments", isOn: $clearNets)
            HStack {
                Spacer()
                Button("Cancel") { editing.editorSheet = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    let how: BoardClipboard.Annotations = annotations == 1 ? .unique : annotations == 2 ? .remove : .keep
                    editing.editorSheet = nil
                    dismiss()
                    editing.paste(text, annotations: how, clearNets: clearNets)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
