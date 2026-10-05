import Foundation

/// A Model Context Protocol server: JSON-RPC 2.0 messages, one per line, answered with the tools of a `CircuitSession`.
///
/// `handle(_:)` takes one message and returns the reply line (nil for notifications), so the same server runs over
/// standard input and output (`jspice-mcp`) or over the app's local socket.
public final class MCPServer {
    public let session: CircuitSession
    public var serverName = "jspice"
    public var serverVersion = "1.0"
    /// Runs each tool call, for example on the main thread when the session drives an open document
    public var perform: (@escaping () -> Any) -> Any = { $0() }

    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public init(session: CircuitSession) {
        self.session = session
    }

    /// Answers one JSON-RPC message
    public func handle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8), !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        if let batch = object as? [Any] {
            guard !batch.isEmpty else { return encode(Self.invalidRequest(id: NSNull())) }
            let replies = batch.compactMap { entry -> [String: Any]? in
                guard let message = entry as? [String: Any] else { return Self.invalidRequest(id: NSNull()) }
                return reply(to: message)
            }
            return replies.isEmpty ? nil : encode(replies)
        }
        guard let message = object as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid request"]])
        }
        return reply(to: message).flatMap { encode($0) }
    }

    private static func invalidRequest(id: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": -32600, "message": "Invalid request"]]
    }

    private func reply(to message: [String: Any]) -> [String: Any]? {
        // notifications have no id and get no reply; a request without a method is answered with an error
        guard let id = message["id"] else { return nil }
        guard let method = message["method"] as? String else { return Self.invalidRequest(id: id) }
        let params = message["params"] as? [String: Any] ?? [:]
        func result(_ value: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
        func failure(_ code: Int, _ text: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]
        }
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? Self.supportedVersions[0]
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            return result([
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": serverName, "version": serverVersion],
                "instructions": CircuitSession.instructions,
            ])
        case "ping":
            return result([String: Any]())
        case "tools/list":
            let tools = CircuitSession.tools.map { tool -> [String: Any] in
                ["name": tool.name, "description": tool.description, "inputSchema": tool.inputSchema]
            }
            return result(["tools": tools])
        case "tools/call":
            guard let name = params["name"] as? String else { return failure(-32602, "tools/call needs a tool name") }
            guard CircuitSession.tools.contains(where: { $0.name == name }) else { return failure(-32602, "Unknown tool \(name)") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let session = session
            let outcome = perform {
                do {
                    return Result<Any, Error>.success(try session.call(name, arguments: arguments))
                } catch {
                    return Result<Any, Error>.failure(error)
                }
            } as? Result<Any, Error>
            switch outcome {
            case .success(let value)?:
                return result(["content": [["type": "text", "text": encode(value) ?? "null"]], "isError": false])
            case .failure(let error)?:
                return result(["content": [["type": "text", "text": "\(error)"]], "isError": true])
            case nil:
                return failure(-32603, "Internal error")
            }
        default:
            return failure(-32601, "Method not found: \(method)")
        }
    }

    private func encode(_ value: Any) -> String? {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        guard let data = try? JSONSerialization.data(withJSONObject: Self.jsonSafe(value), options: options) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces values JSON cannot hold (infinity, NaN) with null
    static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let number as Double:
            return number.isFinite ? number : NSNull()
        case let dictionary as [String: Any]:
            return dictionary.mapValues(jsonSafe)
        case let array as [Any]:
            return array.map(jsonSafe)
        default:
            return value
        }
    }

    /// Serves standard input and output until input ends
    public func runOnStandardIO() {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            if let reply = handle(line) {
                FileHandle.standardOutput.write((reply + "\n").data(using: .utf8)!)
            }
        }
    }
}
