import AppKit
import SwiftUI
import CircuitKit

// MARK: - The model

/// A longer account of what an operation did (what was left out, what was measured), to read and copy in a sheet.
/// Tabular sections (measurements, a file's header) are shown in a monospaced font.
struct NoticeReport: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        var heading: String?
        var lines: [String]
        var tabular = false
    }

    var sections: [Section]

    init(_ sections: [Section]) {
        self.sections = sections.filter { !$0.lines.isEmpty || $0.heading != nil }
    }

    /// A report of plain text, one section
    init(text: String) {
        self.init([Section(heading: nil, lines: [text])])
    }

    /// The report as plain text, as copied
    var text: String {
        sections.map { section in
            ([section.heading].compactMap { $0 } + section.lines).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    var isEmpty: Bool { sections.isEmpty }
}

/// What an operation tells the user it did, shown as a toast over the canvas instead of a dialog that stops them
struct Notice: Identifiable {
    enum Kind: String, CaseIterable {
        case success, info, warning, failure

        var symbol: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .failure: return "xmark.octagon.fill"
            }
        }

        var tint: Color {
            switch self {
            case .success: return .green
            case .info: return .accentColor
            case .warning: return .orange
            case .failure: return .red
            }
        }

        /// What VoiceOver says before the title
        var spoken: String {
            switch self {
            case .success: return "Done"
            case .info: return "Note"
            case .warning: return "Warning"
            case .failure: return "Failed"
            }
        }

        /// Successes and notes fade by themselves; warnings and failures stay until dismissed
        var expires: Bool { self == .success || self == .info }
    }

    /// A button on the toast; pressing it also dismisses the notice
    struct Action: Identifiable {
        let id = UUID()
        let title: String
        let perform: @MainActor () -> Void

        init(_ title: String, perform: @escaping @MainActor () -> Void) {
            self.title = title
            self.perform = perform
        }

        /// Shows a file just written in the Finder
        static func showInFinder(_ url: URL) -> Action {
            Action("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    let id = UUID()
    let kind: Kind
    let title: String
    var detail: String?
    var report: NoticeReport?
    var actions: [Action]

    init(_ kind: Kind, _ title: String, detail: String? = nil, report: NoticeReport? = nil, actions: [Action] = []) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.report = report.flatMap { $0.isEmpty ? nil : $0 }
        self.actions = actions
    }

    /// The whole notice as plain text, as the report sheet copies it
    var text: String {
        ([title, detail].compactMap { $0 } + [report?.text].compactMap { $0 }).joined(separator: "\n\n")
    }
}

extension EditorState {
    /// How long a success or a note stays, in seconds (shortened by the self-test)
    static var noticeLifetime: TimeInterval = 6
    /// The most toasts shown at once: a newer one pushes the oldest out
    static let maxVisibleNotices = 3

    /// Tells the user what an operation did, without stopping them
    @discardableResult
    func notify(_ kind: Notice.Kind, _ title: String, detail: String? = nil, report: NoticeReport? = nil,
                actions: [Notice.Action] = []) -> UUID {
        post(Notice(kind, title, detail: detail, report: report, actions: actions))
    }

    @discardableResult
    func post(_ notice: Notice) -> UUID {
        notices.append(notice)
        while notices.count > Self.maxVisibleNotices {
            let oldest = notices.removeFirst()
            noticeTimers.removeValue(forKey: oldest.id)?.cancel()
        }
        if notice.kind.expires { scheduleNoticeExpiry(notice.id) }
        // VoiceOver hears it as it appears
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "\(notice.kind.spoken): \(notice.title)",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        return notice.id
    }

    func dismissNotice(_ id: UUID) {
        noticeTimers.removeValue(forKey: id)?.cancel()
        notices.removeAll { $0.id == id }
        // (the pointer can't be over a toast that is no longer there)
        if notices.isEmpty { noticesHeld = false }
    }

    func dismissAllNotices() {
        for timer in noticeTimers.values { timer.cancel() }
        noticeTimers = [:]
        notices = []
        noticesHeld = false
    }

    /// Runs a toast's button, dismissing the toast
    func perform(_ action: Notice.Action, from notice: Notice) {
        dismissNotice(notice.id)
        action.perform()
    }

    /// Opens a notice's report in a sheet
    func showReport(of notice: Notice) {
        guard notice.report != nil else { return }
        noticeReport = notice
    }

    /// While the pointer is over the toasts they stay; when it leaves, each starts its time again
    func holdNotices(_ held: Bool) {
        guard held != noticesHeld else { return }
        noticesHeld = held
        if !held {
            for notice in notices where notice.kind.expires { scheduleNoticeExpiry(notice.id) }
        }
    }

    private func scheduleNoticeExpiry(_ id: UUID) {
        noticeTimers.removeValue(forKey: id)?.cancel()
        let lifetime = Self.noticeLifetime
        noticeTimers[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, lifetime) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.noticesHeld {
                self.scheduleNoticeExpiry(id)
            } else {
                self.dismissNotice(id)
            }
        }
    }

    /// A toast's Undo for an edit that replaced the circuit: it undoes only while that edit is still the last one,
    /// the circuit as it left it
    func undoAction(_ actionName: String, leaving result: Circuit) -> Notice.Action {
        Notice.Action("Undo") { [weak self] in
            guard let self else { return }
            if self.circuit == result, let undoManager = self.undoManager, undoManager.canUndo,
               undoManager.undoActionName == actionName {
                undoManager.undo()
            } else {
                self.notify(.info, "\(actionName) can't be undone from here",
                            detail: "The circuit has changed since. Use Edit ▸ Undo to step back to before it.")
            }
        }
    }

    /// A few notices of each kind, for a screenshot of the toasts (and the self-test)
    static func postSampleNotices(on editor: EditorState) {
        editor.dismissAllNotices()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Fuzz Face.wav")
        editor.notify(.success, "Sound exported", detail: "10.0 seconds written to Fuzz Face.wav.",
                      actions: [.showInFinder(file)])
        editor.notify(.warning, "Some of the netlist was left out",
                      detail: "fuzz.cir was drawn without 3 things in it.",
                      report: NoticeReport([NoticeReport.Section(heading: "Left out", lines: [
                          "Line 14: .tran 1u 10m (analyses are set in JSpice's own settings)",
                          "Line 22: B1 out 0 V=v(in)*2 (behavioural sources aren't drawn)",
                          "Line 30: .meas tran vmax MAX v(out)",
                      ])]),
                      actions: [Notice.Action("Undo") {}])
        editor.notify(.failure, "LM741 can't be downloaded",
                      detail: "The Internet connection appears to be offline.",
                      report: NoticeReport([NoticeReport.Section(heading: "What to try", lines: [
                          "Check the Internet connection, then try again: the model is downloaded once and then kept.",
                      ])]),
                      actions: [Notice.Action("Try Again") {}])
    }
}

// MARK: - The views

/// The toasts over the canvas, newest at the bottom, and the sheet a notice's report opens in
struct NoticeOverlay: View {
    @ObservedObject var editor: EditorState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(editor.notices) { notice in
                NoticeToast(editor: editor, notice: notice)
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(12)
        .onHover { inside in editor.holdNotices(inside && !editor.notices.isEmpty) }
        .animation(reduceMotion ? Animation.easeInOut(duration: 0.15) : Animation.snappy(duration: 0.25),
                   value: editor.notices.map(\.id))
        .sheet(item: $editor.noticeReport) { notice in
            NoticeReportSheet(notice: notice)
        }
    }
}

struct NoticeToast: View {
    @ObservedObject var editor: EditorState
    let notice: Notice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.kind.symbol)
                .font(.title3)
                .foregroundStyle(notice.kind.tint)
                .accessibilityLabel(notice.kind.spoken)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = notice.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if notice.report != nil || !notice.actions.isEmpty {
                    HStack(spacing: 8) {
                        if notice.report != nil {
                            Button("Show Report") { editor.showReport(of: notice) }
                        }
                        ForEach(notice.actions) { action in
                            Button(action.title) { editor.perform(action, from: notice) }
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 5)
                }
            }
            Spacer(minLength: 0)
            Button {
                editor.dismissNotice(notice.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(notice.kind.tint.opacity(notice.kind.expires ? 0.25 : 0.55), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
    }
}

/// A notice's report: scrollable, selectable, and copied whole with Copy
struct NoticeReportSheet: View {
    let notice: Notice
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: notice.kind.symbol)
                    .foregroundStyle(notice.kind.tint)
                    .accessibilityLabel(notice.kind.spoken)
                Text(notice.title).font(.headline)
            }
            if let detail = notice.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array((notice.report?.sections ?? []).enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 4) {
                            if let heading = section.heading {
                                Text(heading).font(.subheadline.weight(.semibold))
                            }
                            if !section.lines.isEmpty {
                                Text(section.lines.joined(separator: "\n"))
                                    .font(section.tabular ? Font.system(.callout, design: .monospaced) : Font.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)) }
            HStack {
                Spacer()
                Button("Copy") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(notice.text, forType: .string)
                }
                .help("Copy the whole report")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 580, minHeight: 300, idealHeight: 460)
    }
}
