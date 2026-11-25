import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import JSpiceAutomation

/// The app's socket left alone while it listens, tool calls refused as the app's AI control setting says, and the
/// schematic capture's key found where the session is told to look
final class AIControlTests: XCTestCase {
    /// A short path: a Unix socket's path has to fit in about a hundred bytes
    private func socketPath() -> String {
        "/tmp/jspice-test-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8)).sock"
    }

    func testNothingThereIsNotLive() {
        XCTAssertFalse(LocalSocket.isLive(at: socketPath()))
    }

    func testListeningSocketIsLiveAndKept() throws {
        let path = socketPath()
        let first = try XCTUnwrap(LocalSocket.listen(at: path) { fd in _ = close(fd) })
        defer { LocalSocket.stop(first, path: path) }
        XCTAssertTrue(LocalSocket.isLive(at: path))
        XCTAssertNil(LocalSocket.listen(at: path) { fd in _ = close(fd) }, "a second listener takes a socket still in use")
        XCTAssertTrue(LocalSocket.isLive(at: path), "the first listener no longer answers")
    }

    func testStaleSocketIsReplaced() throws {
        let path = socketPath()
        // a socket bound and closed without being removed, as an app that crashed leaves it
        var address = try XCTUnwrap(LocalSocket.address(path))
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(LocalSocket.isLive(at: path))

        let listener = try XCTUnwrap(LocalSocket.listen(at: path) { fd in _ = close(fd) }, "a stale socket is in the way")
        defer { LocalSocket.stop(listener, path: path) }
        XCTAssertTrue(LocalSocket.isLive(at: path))
    }

    func testFileThatIsNotASocketIsLeftAlone() throws {
        let path = socketPath()
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data("keep".utf8)))
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertNil(LocalSocket.listen(at: path) { fd in _ = close(fd) })
        XCTAssertEqual(FileManager.default.contents(atPath: path), Data("keep".utf8))
    }

    func testRefusedToolCallIsAJSONRPCError() throws {
        let server = MCPServer(session: CircuitSession())
        server.authorize = { "Allow the agent in JSpice first" }
        let reply = try XCTUnwrap(server.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_parts","arguments":{}}}"#))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        XCTAssertNil(object["result"])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, MCPServer.refusedCode)
        XCTAssertEqual(error["message"] as? String, "Allow the agent in JSpice first")

        // the handshake and the list of tools are still answered
        let list = try XCTUnwrap(server.handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#))
        let listed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(list.utf8)) as? [String: Any])
        XCTAssertNotNil(listed["result"])
    }

    func testAllowedToolCallRuns() throws {
        let server = MCPServer(session: CircuitSession())
        var asked = 0
        server.authorize = {
            asked += 1
            return nil
        }
        let reply = try XCTUnwrap(server.handle(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_parts","arguments":{}}}"#))
        XCTAssertTrue(reply.contains("\"isError\":false"), reply)
        XCTAssertEqual(asked, 1)
    }

    func testCaptureSchematicAsksTheSessionForItsKey() throws {
        let drawing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        XCTAssertTrue(FileManager.default.createFile(atPath: drawing.path, contents: Data([0x89, 0x50, 0x4E, 0x47])))
        defer { try? FileManager.default.removeItem(at: drawing) }

        let session = CircuitSession()
        var asked = false
        session.apiKey = {
            asked = true
            return nil
        }
        session.apiKeySource = "enter one in the test's own place"
        XCTAssertThrowsError(try session.call("capture_schematic", arguments: ["path": drawing.path])) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("Anthropic API key"), message)
            XCTAssertTrue(message.contains("enter one in the test's own place"), message)
        }
        XCTAssertTrue(asked)
    }

    func testCaptureSchematicTreatsAnEmptyKeyAsNone() throws {
        let drawing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        XCTAssertTrue(FileManager.default.createFile(atPath: drawing.path, contents: Data([0x89, 0x50, 0x4E, 0x47])))
        defer { try? FileManager.default.removeItem(at: drawing) }

        let session = CircuitSession()
        session.apiKey = { "" }
        XCTAssertThrowsError(try session.call("capture_schematic", arguments: ["path": drawing.path])) { error in
            XCTAssertTrue("\(error)".contains("ANTHROPIC_API_KEY"), "\(error)")
        }
    }
}
