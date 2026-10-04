import AppKit
import CircuitKit
import JSpiceAutomation

/// The circuit window the user worked with last: where AI agents' changes go
@MainActor
enum EditorRegistry {
    static weak var active: EditorState?
}

/// Lets AI agents drive the open circuit through the Model Context Protocol. The app listens on a local socket; the
/// bundled `jspice-mcp` server connects to it, so every tool call (build a circuit, change a value, simulate…) acts on
/// the frontmost window as an undoable edit.
@MainActor
final class AutomationBridge {
    static let shared = AutomationBridge()
    private static let defaultsKey = "allowAIControl"
    private var listener: Int32?
    private let path = LocalSocket.defaultPath

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
            newValue ? start() : stop()
        }
    }

    var isListening: Bool { listener != nil }

    func start() {
        guard isEnabled, listener == nil else { return }
        listener = LocalSocket.listen(at: path) { fd in AutomationBridge.serve(fd) }
    }

    func stop() {
        guard let listener else { return }
        LocalSocket.stop(listener, path: path)
        self.listener = nil
    }

    /// The command an MCP client runs, and a configuration snippet for Claude Desktop or Claude Code
    static var serverCommand: String { Bundle.main.bundlePath + "/Contents/MacOS/jspice-mcp" }

    static var clientConfiguration: String {
        """
        {
          "mcpServers": {
            "jspice": {
              "command": "\(serverCommand)"
            }
          }
        }
        """
    }

    /// One client connection, on its own thread: each request is handled on the main thread against the active window
    nonisolated private static func serve(_ fd: Int32) {
        let session = CircuitSession()
        let server = MCPServer(session: session)
        server.serverName = "jspice-app"
        server.perform = { body in
            var outcome: Any = ()
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { outcome = AutomationBridge.run(session, body) }
            }
            return outcome
        }
        LocalSocket.readLines(fd) { line in
            if let reply = server.handle(line) { LocalSocket.write(fd, reply) }
        }
        close(fd)
    }

    private static func run(_ session: CircuitSession, _ body: () -> Any) -> Any {
        guard let editor = EditorRegistry.active else {
            return Result<Any, Error>.failure(ToolError("No circuit window is open in JSpice. Open or create one (File ▸ New), then try again."))
        }
        // keep the session's simulation if the window's circuit has not changed since the last call
        if session.circuit != editor.document.circuit { session.circuit = editor.document.circuit }
        session.onChange = { [weak editor] circuit, action in
            editor?.applyAutomation(circuit, action)
        }
        return body()
    }
}
