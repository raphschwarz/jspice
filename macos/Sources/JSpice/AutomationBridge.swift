import AppKit
import SwiftUI
import CircuitKit
import JSpiceAutomation

/// The circuit window the user worked with last: where AI agents' changes go
@MainActor
enum EditorRegistry {
    static weak var active: EditorState?
}

/// Whether AI agents may drive the app: Circuit ▸ AI Control (MCP)
enum AIControlMode: String, CaseIterable {
    /// No listening at all
    case off
    /// The first agent to connect in each run of the app asks the user
    case ask
    /// Any agent gets control without asking
    case always

    static let defaultsKey = "aiControl"
    /// Before there were three choices: a switch, on unless turned off
    private static let legacyKey = "allowAIControl"

    /// The choice made, Ask if none was. A switch turned off before stays off; one left on (it was the default) or
    /// turned on becomes Ask, so that no agent gets control without the user's say.
    static var current: AIControlMode {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: defaultsKey), let mode = AIControlMode(rawValue: raw) { return mode }
        if let allowed = defaults.object(forKey: legacyKey) as? Bool, !allowed { return .off }
        return .ask
    }

    /// Writes the choice from the old switch under the new key, so the menu shows it
    static func migrate() {
        guard UserDefaults.standard.string(forKey: defaultsKey) == nil else { return }
        UserDefaults.standard.set(current.rawValue, forKey: defaultsKey)
    }
}

/// What the user said, this run of the app, to agents connecting while AI control is on Ask. Clients are served on
/// threads of their own, so this is guarded by a lock rather than the main actor; the prompt itself runs on the main
/// thread, which never waits for a client.
final class AIControlConsent: @unchecked Sendable {
    static let shared = AIControlConsent()

    private enum Decision { case undecided, asking, allowed, denied }

    private let condition = NSCondition()
    private var decision = Decision.undecided
    /// The self-test drives the app over a socket of its own: it is never asked about, nor refused
    private var trusted = false
    /// How long a tool call waits for the user to answer the prompt before it is refused
    private let patience: TimeInterval = 30

    /// Modes in which the app runs itself (self-test, screenshots): no prompt, ever
    private static let automated = CommandLine.arguments.contains { ["--self-test", "--screenshots", "--render-drawings", "--render-icon"].contains($0) }

    static let offMessage = "AI control is off in JSpice. To let this agent work on the circuit, the user can choose "
        + "Circuit ▸ AI Control (MCP) ▸ Ask or Always Allow in JSpice; then call the tool again."
    static let deniedMessage = "The user chose Don't Allow when JSpice asked whether to let an AI agent control it. To allow "
        + "it, they can choose Circuit ▸ AI Control (MCP) ▸ Always Allow in JSpice, or Ask to be asked again; then call the tool again."
    static let waitingMessage = "JSpice is asking the user whether to let an AI agent control it, and has no answer yet. "
        + "Ask them to choose Allow in the JSpice window, then call the tool again."

    func trust() {
        condition.lock()
        trusted = true
        condition.unlock()
    }

    /// Forgets this run's answer, so the next agent asks again (choosing Ask in the menu)
    func reset() {
        condition.lock()
        if decision != .asking { decision = .undecided }
        condition.unlock()
    }

    func decide(_ allowed: Bool) {
        condition.lock()
        decision = allowed ? .allowed : .denied
        condition.broadcast()
        condition.unlock()
    }

    /// Shows the prompt if AI control is on Ask and nobody has been asked yet this run; returns at once
    func askIfNeeded() {
        guard !Self.automated, AIControlMode.current == .ask else { return }
        condition.lock()
        let ask = !trusted && decision == .undecided
        if ask { decision = .asking }
        condition.unlock()
        guard ask else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AutomationBridge.shared.askForConsent() }
        }
    }

    /// Nil if a tool call may run; otherwise why not, for the agent to tell its user. On Ask with the prompt showing,
    /// waits a while for the answer (on the client's thread, never the main thread's).
    func refusal() -> String? {
        condition.lock()
        let isTrusted = trusted
        condition.unlock()
        if isTrusted { return nil }
        switch AIControlMode.current {
        case .off: return Self.offMessage
        case .always: return nil
        case .ask: break
        }
        if Self.automated { return Self.waitingMessage }
        askIfNeeded()
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(patience)
        while decision == .asking {
            if !condition.wait(until: deadline) { break }
        }
        switch decision {
        case .allowed: return nil
        case .denied: return Self.deniedMessage
        case .undecided, .asking: return Self.waitingMessage
        }
    }
}

/// Circuit ▸ AI Control (MCP), kept up to date when the prompt's Always Allow changes the choice
struct AIControlMenu: View {
    @AppStorage(AIControlMode.defaultsKey) private var mode: AIControlMode = .ask

    var body: some View {
        Picker("AI Control (MCP)", selection: Binding(
            get: { mode },
            set: { AutomationBridge.shared.mode = $0 }
        )) {
            Text("Don't Allow").tag(AIControlMode.off)
            Text("Ask When an Agent Connects").tag(AIControlMode.ask)
            Text("Always Allow").tag(AIControlMode.always)
        }
    }
}

/// Lets AI agents drive the open circuit through the Model Context Protocol. The app listens on a local socket; the
/// bundled `jspice-mcp` server connects to it, so every tool call (build a circuit, change a value, simulate…) acts on
/// the frontmost window as an undoable edit. Agents get control only as Circuit ▸ AI Control (MCP) says: never, after
/// the user allows it in a prompt, or always.
@MainActor
final class AutomationBridge {
    static let shared = AutomationBridge()
    private var listener: Int32?
    private var path = LocalSocket.defaultPath

    private init() {
        AIControlMode.migrate()
    }

    var mode: AIControlMode {
        get { AIControlMode.current }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: AIControlMode.defaultsKey)
            if newValue == .ask { AIControlConsent.shared.reset() }
            newValue == .off ? stop() : start()
        }
    }

    var isListening: Bool { listener != nil }

    func start() {
        guard mode != .off, listener == nil else { return }
        listener = LocalSocket.listen(at: path) { fd in AutomationBridge.serve(fd) }
        if listener == nil {
            // most likely another copy of JSpice is running and serves agents itself: leave its socket alone
            NSLog("JSpice: not listening for AI agents at %@ (another JSpice may be serving them)", path)
        }
    }

    /// For the self-test: listens at a socket of its own, whatever AI control is set to, and never asks
    func startForSelfTest(at socketPath: String) {
        stop()
        AIControlConsent.shared.trust()
        path = socketPath
        listener = LocalSocket.listen(at: socketPath) { fd in AutomationBridge.serve(fd) }
    }

    func stop() {
        guard let listener else { return }
        LocalSocket.stop(listener, path: path)
        self.listener = nil
    }

    /// The prompt shown when an agent first connects in this run with AI control on Ask
    func askForConsent() {
        let alert = NSAlert()
        alert.messageText = "Allow an AI agent to control JSpice?"
        alert.informativeText = "A program on this Mac connected to JSpice through its MCP server (jspice-mcp), as an AI "
            + "agent such as Claude does. JSpice cannot tell which program it is.\n\nIf you allow it, it can change the "
            + "open circuit, read and write files anywhere your account can, install chip support (compilers), and open a "
            + "debugging port.\n\nAllow lets agents work until you quit JSpice. You can change this at any time in "
            + "Circuit ▸ AI Control (MCP)."
        alert.alertStyle = .warning
        // the default button (Return) is the safe answer
        alert.addButton(withTitle: "Don't Allow")
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Always Allow")
        NSApp.activate()
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            AIControlConsent.shared.decide(true)
        case .alertThirdButtonReturn:
            mode = .always
            AIControlConsent.shared.decide(true)
        default:
            AIControlConsent.shared.decide(false)
        }
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

    /// One client connection, on its own thread. Each request looks at the active window's circuit on the main thread,
    /// then runs here, so a long simulation or optimization does not freeze the window; what it changes goes to the
    /// window on the main thread, as an undoable edit.
    nonisolated private static func serve(_ fd: Int32) {
        let session = CircuitSession()
        // schematic capture finds the key the app keeps in the login keychain, as the app's own import does
        session.apiKey = { APIKeyStore.key }
        session.apiKeySource = "in JSpice, choose Circuit ▸ Import Schematic from Image or PDF… once and enter a key (it is kept in the login keychain), or set ANTHROPIC_API_KEY"
        let server = MCPServer(session: session)
        server.serverName = "jspice-app"
        server.authorize = { AIControlConsent.shared.refusal() }
        server.perform = { body in
            var current: Circuit?
            weak var window: EditorState?
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    window = EditorRegistry.active
                    current = window?.document.circuit
                }
            }
            guard let current else {
                return Result<Any, Error>.failure(ToolError("No circuit window is open in JSpice. Open or create one (File ▸ New), then try again."))
            }
            // keep the session's simulation if the window's circuit has not changed since the last call
            if session.circuit != current { session.circuit = current }
            session.onChange = { circuit, action in
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { window?.applyAutomation(circuit, action) }
                }
            }
            return body()
        }
        // the first message (an agent's initialize) asks the user, if AI control is on Ask; a connection that sends
        // nothing, such as another JSpice checking whether this one is listening, asks nothing
        var greeted = false
        LocalSocket.readLines(fd) { line in
            if !greeted, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                greeted = true
                AIControlConsent.shared.askIfNeeded()
            }
            if let reply = server.handle(line) { LocalSocket.write(fd, reply) }
        }
        close(fd)
    }
}
