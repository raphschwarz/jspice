import AppKit
import SwiftUI
import KiCadKit
import KiCadRouter
import JSpiceAutomation

extension BoardController {
    /// The board's rules file's text (its .kicad_dru beside the project), or KiCad's for a board with none, as
    /// Board Setup's Custom Rules page opens it ("(version 1)")
    func rulesFileText() async -> String {
        let text = try? await worker.run { w -> String? in w.link?.designRules() }
        return (text ?? nil) ?? "(version 1)\n"
    }

    /// The board's rules file written (as KiCad's Board Setup writes it); what went wrong, or nil
    func saveRulesFile(_ text: String) async -> String? {
        do {
            try await worker.run { (w: BoardWorker) throws -> Void in
                guard let link = w.link else { throw BoardLink.Failure.noBoard }
                try link.setDesignRules(text)
            }
            return nil
        } catch {
            return "\(error)"
        }
    }
}

extension PCBEditing {
    /// The rules editor (KiCad's Board Setup ▸ Custom Rules) opened on the board's rules file
    func openRulesEditor() {
        guard !isRouting else { return NSSound.beep() }
        Task {
            guard let text = await controller?.rulesFileText() else { return }
            editorSheet = .rules(text)
        }
    }

    /// What KiCad's "Check rule syntax" says of `text` for this board and its project
    func checkRules(_ text: String) async -> [RulesMessage] {
        await settled()
        if !isReady { await prepareNow() }
        return await engine.run { $0.checkDesignRules(text) } ?? DesignRulesCheck.check(text)
    }

    /// The rules file saved beside the project, and the board taken up again with it: the router, the checks and the
    /// filler go by the rules as saved (as KiCad's DRC engine takes them up as the dialog closes); what went wrong,
    /// or nil
    func saveRules(_ text: String) async -> String? {
        guard let controller else { return "The circuit has no board yet." }
        if let failure = await controller.saveRulesFile(text) { return failure }
        await settled()
        await prepareNow()
        return nil
    }
}

/// The rules file edited as on KiCad's Custom Rules page: its text, checked as the page's "Check rule syntax" checks
/// it (each error's line marked, a click on an error taking the editor to its line and column), and saved beside the
/// project as the dialog's OK saves it (the rules then the board's)
struct PCBRulesEditorSheet: View {
    @ObservedObject var board: BoardController
    @ObservedObject var editing: PCBEditing
    @State private var text: String
    @State private var messages: [RulesMessage] = []
    @State private var checked: String?
    @State private var jump: (line: Int, column: Int, serial: Int)?
    @State private var failure: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    init(board: BoardController, editing: PCBEditing, text: String) {
        self.board = board
        self.editing = editing
        _text = State(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom Rules").font(.headline)
            PCBRulesTextView(text: $text, marks: checked == text ? Set(messages.compactMap { $0.severity == .error ? $0.line : nil }) : [],
                             jump: jump)
                .frame(minHeight: 320)
                .border(Color(nsColor: .separatorColor))
            HStack {
                Button("Check Rule Syntax") { check() }
                    .help("The rules checked as KiCad's Custom Rules page checks them: the parser's errors where they are, then rules sharing a condition, net classes and layers the board has not")
                Spacer()
                if checked != nil && checked != text {
                    Text("Changed since checked").font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(messages.enumerated()), id: \.offset) { i, m in
                        Button { go(m, serial: i) } label: { messageRow(m) }
                            .buttonStyle(.plain)
                            .disabled(m.line == nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 110)
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { editing.editorSheet = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
                    .help("Saved beside the project as its .kicad_dru (as KiCad's Board Setup saves it, errors or not), and the board's routing, checks and fills go by it from then on")
            }
        }
        .padding(20)
        .frame(width: 640, height: 600)
        .task { check() }
    }

    @ViewBuilder
    private func messageRow(_ m: RulesMessage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch m.severity {
            case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            case .info: Image(systemName: "checkmark.circle").foregroundStyle(.green)
            }
            if let line = m.line {
                Text("\(line):\(m.column ?? 0)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(m.text).underline(m.line != nil) + Text(m.rest)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func check() {
        let now = text
        Task {
            messages = await editing.checkRules(now)
            checked = now
        }
    }

    private func go(_ m: RulesMessage, serial: Int) {
        guard let line = m.line else { return }
        jump = (line, m.column ?? 1, (jump?.serial ?? 0) + 1 + serial)
    }

    private func save() {
        saving = true
        let now = text
        Task {
            failure = await editing.saveRules(now)
            saving = false
            if failure == nil {
                editing.editorSheet = nil
                dismiss()
            }
        }
    }
}

/// The rules' text in a text view of their own: plain, in a fixed-width font, no quotes or dashes made typographic
/// (KiCad's page turns them back), the lines of errors marked, and the caret taken to a line and column
struct PCBRulesTextView: NSViewRepresentable {
    @Binding var text: String
    /// The lines (from 1) errors are on
    let marks: Set<Int>
    /// Where to take the caret (line and column from 1), once for each serial
    let jump: (line: Int, column: Int, serial: Int)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.string = text
        view.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView, let layout = view.layoutManager else { return }
        if view.string != text { view.string = text }
        let s = view.string as NSString
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: s.length))
        for line in marks {
            guard let r = Self.range(ofLine: line, in: s) else { continue }
            layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.2), forCharacterRange: r)
        }
        if let jump, jump.serial != context.coordinator.jumped, let r = Self.range(ofLine: jump.line, in: s) {
            context.coordinator.jumped = jump.serial
            let at = NSRange(location: min(r.location + max(jump.column - 1, 0), NSMaxRange(r)), length: 0)
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(at)
            view.scrollRangeToVisible(at)
        }
    }

    /// A line's characters (from 1), its line end left out
    static func range(ofLine line: Int, in s: NSString) -> NSRange? {
        var n = 1, at = 0
        while at < s.length || (at == s.length && n == line) {
            let r = s.lineRange(for: NSRange(location: at, length: 0))
            if n == line {
                var content = r
                while content.length > 0, let c = Unicode.Scalar(s.character(at: NSMaxRange(content) - 1)),
                      CharacterSet.newlines.contains(c) {
                    content.length -= 1
                }
                return content
            }
            guard NSMaxRange(r) > at else { break }
            at = NSMaxRange(r)
            n += 1
        }
        return nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PCBRulesTextView
        var jumped = 0

        init(_ parent: PCBRulesTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}
