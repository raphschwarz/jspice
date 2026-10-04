import Foundation
import JSpiceAutomation

// `jspice-mcp`: a Model Context Protocol server on standard input and output, so an AI agent can build, simulate and
// measure circuits with the JSpice engine. Add it to an MCP client (Claude Desktop, Claude Code) as a stdio server.
//
// If the JSpice app is running (with Allow AI Control on), requests go to the circuit in its frontmost window, so you
// can watch the agent work and undo its changes; otherwise, or with --headless, the server simulates on its own.
// --app insists on the app.

let arguments = CommandLine.arguments
let path = ProcessInfo.processInfo.environment["JSPICE_SOCKET"] ?? LocalSocket.defaultPath

func log(_ message: String) {
    FileHandle.standardError.write(("jspice-mcp: " + message + "\n").data(using: .utf8)!)
}

if !arguments.contains("--headless"), let fd = LocalSocket.connect(to: path) {
    log("connected to the JSpice app")
    // replies (and anything else the app sends) go straight to the client
    Thread.detachNewThread {
        LocalSocket.readLines(fd) { line in
            FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
        }
        log("the JSpice app closed the connection")
        exit(0)
    }
    while let line = readLine(strippingNewline: true) {
        guard LocalSocket.write(fd, line) else {
            log("lost the connection to the JSpice app")
            exit(1)
        }
    }
    exit(0)
} else if arguments.contains("--app") {
    log("the JSpice app is not running, or Allow AI Control is off")
    exit(1)
} else {
    log("simulating on its own (the JSpice app is not running)")
    MCPServer(session: CircuitSession()).runOnStandardIO()
}
