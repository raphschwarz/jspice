import AppKit
import CircuitKit

/// The notices that replace most dialogs: each kind is posted, successes fade and failures stay (also while the pointer
/// holds them), only a few are kept, a report's text is there to read and copy, and a toast's button runs and dismisses it.
extension InteractionTest {
    static func checkNotices(editor: EditorState) async {
        let lifetime = EditorState.noticeLifetime
        EditorState.noticeLifetime = 0.3
        defer { EditorState.noticeLifetime = lifetime }
        editor.dismissAllNotices()
        editor.holdNotices(false)

        // each kind is added to the model
        for kind in Notice.Kind.allCases {
            let id = editor.notify(kind, "A \(kind.rawValue) notice", detail: "Its detail")
            let posted = editor.notices.first { $0.id == id }
            check(posted?.kind == kind && posted?.title == "A \(kind.rawValue) notice" && posted?.detail == "Its detail",
                  "posting a \(kind.rawValue) notice adds it to the window's notices")
            editor.dismissNotice(id)
            check(!editor.notices.contains { $0.id == id }, "and dismissing it takes it away")
        }

        // a success fades, a failure stays
        let success = editor.notify(.success, "Sound exported")
        let failure = editor.notify(.failure, "The sound couldn't be written")
        await pause(0.9)
        check(!editor.notices.contains { $0.id == success }, "a success notice fades by itself")
        check(editor.notices.contains { $0.id == failure }, "a failure notice stays until dismissed")
        editor.dismissAllNotices()

        // while the pointer is over the toasts, a success stays; once it leaves, it fades
        editor.holdNotices(true)
        let held = editor.notify(.info, "Held under the pointer")
        await pause(0.9)
        check(editor.notices.contains { $0.id == held }, "a notice under the pointer doesn't fade")
        editor.holdNotices(false)
        await pause(0.9)
        check(!editor.notices.contains { $0.id == held }, "and fades once the pointer leaves")
        editor.dismissAllNotices()

        // only a few at once: newer ones push the oldest out
        let ids = (1...(EditorState.maxVisibleNotices + 2)).map { editor.notify(.warning, "Warning \($0)") }
        check(editor.notices.count == EditorState.maxVisibleNotices,
              "at most \(EditorState.maxVisibleNotices) notices are shown at once")
        check(editor.notices.map(\.id) == Array(ids.suffix(EditorState.maxVisibleNotices)),
              "the newest are kept, oldest first")
        editor.dismissAllNotices()

        // a report's text is there to read and copy
        let report = NoticeReport([
            NoticeReport.Section(heading: "Left out", lines: ["Line 14: .tran 1u 10m", "Line 22: B1 out 0 V=v(in)*2"]),
            NoticeReport.Section(heading: "Measured", lines: ["Supply current: 1.7 mA"], tabular: true),
        ])
        let reported = editor.notify(.warning, "Some of the netlist was left out", detail: "fuzz.cir", report: report)
        if let notice = editor.notices.first(where: { $0.id == reported }) {
            check(notice.report?.text.contains("Line 22: B1 out 0 V=v(in)*2") == true
                  && notice.report?.text.contains("Supply current: 1.7 mA") == true,
                  "a notice's report holds its text")
            check(notice.text.hasPrefix("Some of the netlist was left out") && notice.text.contains("Left out"),
                  "and copies with its title")
            editor.showReport(of: notice)
            check(editor.noticeReport?.id == reported, "Show Report opens it")
            editor.noticeReport = nil
        } else {
            check(false, "a notice with a report is posted")
        }
        let plain = editor.notify(.info, "No report")
        if let notice = editor.notices.first(where: { $0.id == plain }) {
            editor.showReport(of: notice)
            check(editor.noticeReport == nil, "a notice without a report opens no sheet")
        }
        editor.dismissAllNotices()

        // a toast's button runs and dismisses it
        let acted = editor.notify(.success, "Exported", actions: [
            Notice.Action("Try It") { [weak editor] in editor?.notify(.info, "The action ran") },
        ])
        if let notice = editor.notices.first(where: { $0.id == acted }), let action = notice.actions.first {
            editor.perform(action, from: notice)
        }
        check(editor.notices.contains { $0.title == "The action ran" } && !editor.notices.contains { $0.id == acted },
              "a notice's button runs its action and dismisses it")

        // the samples for a screenshot: one of each lasting kind and a success, within the cap
        EditorState.postSampleNotices(on: editor)
        check(editor.notices.count == 3 && editor.notices.contains { $0.report != nil },
              "the sample notices are posted")
        editor.dismissAllNotices()
    }
}
