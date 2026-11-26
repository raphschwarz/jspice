import AppKit
import Security
import SwiftUI
import UniformTypeIdentifiers
import CircuitKit
import JSpiceAutomation

/// The Anthropic API key schematic capture uses: ANTHROPIC_API_KEY if set, else the one kept in the login keychain
enum APIKeyStore {
    private static let service = "org.knowm.jspice.anthropic-api-key"

    static var key: String? {
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty { return key }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether the login keychain holds a stored key (the ANTHROPIC_API_KEY variable aside). Only the item's attributes
    /// are asked for, never its data, so that looking brings up no keychain prompt.
    static var hasStoredKey: Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    static func save(_ key: String) {
        remove()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "default", kSecValueData as String: Data(key.utf8)]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func remove() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }

    /// The key, asking for one (and keeping it in the keychain) the first time
    @MainActor
    static func ask() -> String? {
        if let key { return key }
        let alert = NSAlert()
        alert.messageText = "Anthropic API key"
        alert.informativeText = "Reading a schematic drawing uses Claude through the Anthropic API, billed to your API account. Paste a key from console.anthropic.com; it is kept in your login keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        save(key)
        return key
    }
}

extension EditorState {
    /// Reads a schematic drawing into the window (File ▸ Import ▸ Schematic from Image or PDF…)
    func importSchematic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .png, .jpeg, .heic, .tiff, .image]
        panel.message = "Choose a schematic: a photo or scan of a drawing, or a PDF. Claude reads it into a circuit you can simulate."
        guard panel.runModal() == .OK, let url = panel.url, let key = APIKeyStore.ask() else { return }
        // a new drawing replaces one still being read
        captureTask?.cancel()
        captureStatus = "Reading the page…"
        let status: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in if self?.captureTask != nil { self?.captureStatus = text } }
        }
        captureTask = Task { [weak self] in
            do {
                let capture = try await SchematicCapture.capture(url, key: key, progress: status)
                guard let self, !Task.isCancelled else { return }
                self.finishCapture(capture, from: url)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.captureStatus = nil
                self.captureTask = nil
                var advice = ["Check that the drawing is legible: a sharp, straight scan or the PDF itself reads best. Then choose File ▸ Import ▸ Schematic from Image or PDF… again."]
                var detail = "\(url.lastPathComponent): \(error)"
                if let failure = error as? SchematicCapture.CaptureError, case .api(let message) = failure, message.contains("401") {
                    let forgotten = "The API key was not accepted: it has been forgotten, so you can enter another."
                    detail += " " + forgotten
                    advice = [forgotten, "Paste a key from console.anthropic.com when JSpice asks for one."]
                    APIKeyStore.remove()
                }
                self.notify(.failure, "The schematic couldn't be read", detail: detail,
                            report: NoticeReport([
                                NoticeReport.Section(heading: "What went wrong", lines: ["\(error)"]),
                                NoticeReport.Section(heading: "What to try", lines: advice),
                            ]),
                            actions: [Notice.Action("Try Again") { [weak self] in self?.importSchematic() }])
            }
        }
    }

    func cancelCapture() {
        captureTask?.cancel()
        captureTask = nil
        captureStatus = nil
    }

    private func finishCapture(_ capture: SchematicCapture.Capture, from url: URL) {
        captureStatus = nil
        captureTask = nil
        edit("Import Schematic") { $0 = capture.circuit }
        selection = []
        requestFit()
        let parts = capture.circuit.elements.filter { ![.wire, .ground, .netLabel].contains($0.kind) }.count
        let check = "Check the circuit against the drawing before trusting a simulation of it."
        var sections = [NoticeReport.Section(heading: nil, lines: [check])]
        if !capture.uncertain.isEmpty {
            sections.append(NoticeReport.Section(heading: "Read with doubt:", lines: capture.uncertain.map { "• " + $0 }))
        }
        if !capture.notes.isEmpty {
            sections.append(NoticeReport.Section(heading: "Notes:", lines: capture.notes.map { "• " + $0 }))
        }
        let doubts = capture.uncertain.count
        // values read with doubt, or notes on the drawing, keep the notice until it is dismissed
        notify(doubts > 0 || !capture.notes.isEmpty ? .warning : .success, "Read \(parts) parts from \(url.lastPathComponent)",
               detail: doubts > 0 ? "\(doubts == 1 ? "One value was" : "\(doubts) values were") read with doubt. " + check : check,
               report: sections.count > 1 ? NoticeReport(sections) : nil,
               actions: [undoAction("Import Schematic", leaving: circuit)])
    }
}

/// Shown over the canvas while a drawing is being read
struct CaptureBanner: View {
    @ObservedObject var editor: EditorState

    var body: some View {
        if let status = editor.captureStatus {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(status).font(.callout)
                Button("Cancel") { editor.cancelCapture() }.controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
        }
    }
}
