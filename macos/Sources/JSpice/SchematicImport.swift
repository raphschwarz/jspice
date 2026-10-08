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
    /// Reads a schematic drawing into the window (File ▸ Import Schematic from Image or PDF)
    func importSchematic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .png, .jpeg, .heic, .tiff, .image]
        panel.message = "Choose a schematic: a photo or scan of a drawing, or a PDF. Claude reads it into a circuit you can simulate."
        guard panel.runModal() == .OK, let url = panel.url, let key = APIKeyStore.ask() else { return }
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
                let alert = NSAlert()
                alert.messageText = "The schematic couldn't be read"
                alert.informativeText = "\(error)"
                if let failure = error as? SchematicCapture.CaptureError, case .api(let message) = failure, message.contains("401") {
                    alert.informativeText += "\n\nThe API key was not accepted: it has been forgotten, so you can enter another."
                    APIKeyStore.remove()
                }
                alert.runModal()
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
        let alert = NSAlert()
        alert.messageText = "Read \(parts) parts from \(url.lastPathComponent)"
        var text = "Check the circuit against the drawing before trusting a simulation of it."
        if !capture.uncertain.isEmpty {
            text += "\n\nRead with doubt:\n" + capture.uncertain.prefix(10).map { "• " + $0 }.joined(separator: "\n")
        }
        if !capture.notes.isEmpty {
            text += "\n\nNotes:\n" + capture.notes.prefix(10).map { "• " + $0 }.joined(separator: "\n")
        }
        alert.informativeText = text
        alert.runModal()
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
