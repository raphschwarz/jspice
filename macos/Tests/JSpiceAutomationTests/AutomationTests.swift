import XCTest
import CircuitKit
@testable import JSpiceAutomation

final class AutomationTests: XCTestCase {
    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: text.data(using: .utf8)!)) as? [String: Any] ?? [:]
    }

    /// A tool call through the MCP server, returning the decoded tool result
    private func call(_ server: MCPServer, _ name: String, _ arguments: [String: Any], id: Int = 1) throws -> (Any, Bool) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
        let line = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
        let reply = json(try XCTUnwrap(server.handle(line)))
        let result = try XCTUnwrap(reply["result"] as? [String: Any], "\(reply)")
        let content = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        let isError = result["isError"] as? Bool ?? false
        let value = isError ? content : (try JSONSerialization.jsonObject(with: content.data(using: .utf8)!, options: [.fragmentsAllowed]))
        return (value, isError)
    }

    private let lowPass: [[String: Any]] = [
        ["kind": "acVoltage", "name": "V1", "params": ["amplitude": 1, "frequency": 1000], "connections": ["plus": "in", "minus": "GND"]],
        ["kind": "resistor", "name": "R1", "params": ["resistance": "1k"], "connections": ["a": "in", "b": "out"]],
        ["kind": "capacitor", "name": "C1", "params": ["capacitance": 1 / (2 * Double.pi * 1000 * 1000)], "connections": ["1": "out", "2": "GND"]],
    ]

    func testProtocolHandshake() throws {
        let server = MCPServer(session: CircuitSession())
        let initialize = json(try XCTUnwrap(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)))
        let result = try XCTUnwrap(initialize["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertNil(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), "notifications get no reply")
        let list = json(try XCTUnwrap(server.handle(#"{"jsonrpc":"2.0","id":"two","method":"tools/list"}"#)))
        XCTAssertEqual(list["id"] as? String, "two")
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        for name in ["build_circuit", "simulate", "frequency_response", "list_parts", "set_model"] {
            XCTAssertTrue(names.contains(name), name)
        }
        XCTAssertTrue(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })
        let unknown = json(try XCTUnwrap(server.handle(#"{"jsonrpc":"2.0","id":3,"method":"nonsense"}"#)))
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
        let garbage = json(try XCTUnwrap(server.handle("{not json")))
        XCTAssertEqual((garbage["error"] as? [String: Any])?["code"] as? Int, -32700)
    }

    func testListPartsDescribesModelsAndTerminals() throws {
        let server = MCPServer(session: CircuitSession())
        let (value, isError) = try call(server, "list_parts", [:])
        XCTAssertFalse(isError)
        let parts = try XCTUnwrap(value as? [[String: Any]])
        let opAmp = try XCTUnwrap(parts.first { $0["kind"] as? String == "opAmp" })
        XCTAssertEqual(opAmp["terminals"] as? [String], ["minus", "plus", "out"])
        XCTAssertTrue((opAmp["models"] as? [[String: Any]])?.contains { $0["name"] as? String == "TL072" } ?? false)
        let ota = try XCTUnwrap(parts.first { $0["kind"] as? String == "ota" })
        XCTAssertTrue((ota["models"] as? [[String: Any]])?.contains { $0["name"] as? String == "LM13700" } ?? false)
    }

    func testFrequencyResponseOfAnRCLowPass() throws {
        let server = MCPServer(session: CircuitSession())
        let (_, buildError) = try call(server, "build_circuit", ["parts": lowPass])
        XCTAssertFalse(buildError)
        let (value, isError) = try call(server, "frequency_response",
                                        ["source": "V1", "output": "V(out)", "frequencies": [100, 1000, 10_000]])
        XCTAssertFalse(isError, "\(value)")
        let points = try XCTUnwrap((value as? [String: Any])?["points"] as? [[String: Any]])
        XCTAssertEqual(points.count, 3)
        let gains = points.compactMap { $0["gain"] as? Double }
        let phases = points.compactMap { $0["phase_deg"] as? Double }
        // first order: |H| = 1 / sqrt(1 + (f / fc)²), phase = -atan(f / fc)
        for (k, f) in [100.0, 1000, 10_000].enumerated() {
            XCTAssertEqual(gains[k], 1 / (1 + (f / 1000) * (f / 1000)).squareRoot(), accuracy: 0.01, "gain at \(f) Hz")
            XCTAssertEqual(phases[k], -atan(f / 1000) * 180 / .pi, accuracy: 2, "phase at \(f) Hz")
        }
    }

    func testSimulateChargesACapacitor() throws {
        let session = CircuitSession()
        _ = try session.call("build_circuit", arguments: ["parts": [
            ["kind": "dcVoltage", "name": "V1", "params": ["voltage": 5], "connections": ["plus": "supply", "minus": "gnd"]],
            ["kind": "resistor", "name": "R1", "params": ["resistance": 1000], "connections": ["a": "supply", "b": "out"]],
            ["kind": "capacitor", "name": "C1", "params": ["capacitance": "1u"], "connections": ["a": "out", "b": "GND"]],
        ]])
        let result = try XCTUnwrap(session.call("simulate", arguments: ["duration": "5m", "probes": ["V(out)", "I(R1)"], "points": 50]) as? [String: Any])
        let probes = try XCTUnwrap(result["probes"] as? [String: Any])
        let out = try XCTUnwrap(probes["V(out)"] as? [String: Any])
        XCTAssertEqual(out["final"] as? Double ?? 0, 5 * (1 - exp(-5)), accuracy: 0.01)
        XCTAssertEqual((out["value"] as? [Double])?.count ?? 0, 50, accuracy: 2)
        let current = try XCTUnwrap(probes["I(R1)"] as? [String: Any])
        XCTAssertEqual(current["max"] as? Double ?? 0, 5e-3, accuracy: 2e-4)
        // continuing picks up where it stopped
        let more = try XCTUnwrap(session.call("simulate", arguments: ["duration": "5m", "probes": ["V(out)"], "continue": true]) as? [String: Any])
        XCTAssertEqual(more["start_time"] as? Double ?? 0, 5e-3, accuracy: 1e-5)
        let measured = try XCTUnwrap(session.call("measure", arguments: [:]) as? [String: Any])
        XCTAssertEqual((measured["nets"] as? [String: Double])?["out"] ?? 0, 5 * (1 - exp(-10)), accuracy: 0.01)
    }

    func testAnAgentCanPlayTheKeyboard() throws {
        let session = CircuitSession()
        _ = try session.call("load_example", arguments: ["id": "synth"])
        // a key held from 0.1 s to 0.4 s: an A4 that sounds while held and dies away after
        let result = try XCTUnwrap(session.call("simulate", arguments: [
            "duration": 0.4, "time_step": 1.0 / 192_000, "probes": ["V(SPK1)"], "points": 100,
            "keyboard": [["at": 0.1, "note": "A4"], ["at": 0.3, "off": true]],
        ]) as? [String: Any])
        let speaker = try XCTUnwrap((result["probes"] as? [String: Any])?["V(SPK1)"] as? [String: Any])
        XCTAssertGreaterThan(speaker["max"] as? Double ?? 0, 0.3)
        let held = try XCTUnwrap(session.call("simulate", arguments: [
            "duration": 0.2, "time_step": 1.0 / 192_000, "probes": ["V(SPK1)"], "continue": true,
            "keyboard": [["at": 0, "note": 72]],
        ]) as? [String: Any])
        let tone = try XCTUnwrap((held["probes"] as? [String: Any])?["V(SPK1)"] as? [String: Any])
        XCTAssertEqual(tone["frequency"] as? Double ?? 0, 523.25, accuracy: 523.25 * 0.06, "C5")
        XCTAssertEqual(CircuitSession.noteNumber("C4"), 60)
        XCTAssertEqual(CircuitSession.noteNumber("F#3"), 54)
        XCTAssertEqual(CircuitSession.noteNumber("Bb2"), 46)
        XCTAssertThrowsError(try session.call("simulate", arguments: ["duration": 0.01, "probes": ["V(SPK1)"], "keyboard": [["at": 0, "note": "H2"]]]))
    }

    func testOpAmpAmplifierFromANetlist() throws {
        let session = CircuitSession()
        _ = try session.call("build_circuit", arguments: ["parts": [
            ["kind": "acVoltage", "name": "VIN", "params": ["amplitude": "100m", "frequency": 1000], "connections": ["plus": "in", "minus": "GND"]],
            ["kind": "resistor", "name": "RI", "params": ["resistance": "10k"], "connections": ["a": "in", "b": "inv"]],
            ["kind": "resistor", "name": "RF", "params": ["resistance": "100k"], "connections": ["a": "inv", "b": "out"]],
            ["kind": "opAmp", "name": "U1", "model": "TL072", "connections": ["minus": "inv", "plus": "GND", "out": "out"]],
        ]])
        let description = session.describe()
        let parts = try XCTUnwrap(description["parts"] as? [[String: Any]])
        let opAmp = try XCTUnwrap(parts.first { $0["name"] as? String == "U1" })
        XCTAssertEqual(opAmp["model"] as? String, "TL072")
        XCTAssertEqual((opAmp["connections"] as? [String: String])?["out"], "out")
        XCTAssertTrue((description["problems"] as? [String])?.isEmpty ?? false)
        let response = try XCTUnwrap(session.call("frequency_response", arguments: ["source": "VIN", "output": "V(out)", "frequencies": [1000]]) as? [String: Any])
        let point = try XCTUnwrap((response["points"] as? [[String: Any]])?.first)
        XCTAssertEqual(point["gain"] as? Double ?? 0, 10, accuracy: 0.1)
        XCTAssertEqual(abs(point["phase_deg"] as? Double ?? 0), 180, accuracy: 3, "an inverting amplifier")
        // swapping in a slow op-amp is one call
        _ = try session.call("set_model", arguments: ["part": "U1", "model": "LM358"])
        XCTAssertEqual(session.circuit.elements.first { $0.name == "U1" }?.model?.name, "LM358")
    }

    func testErrorsExplainWhatToFix() throws {
        let server = MCPServer(session: CircuitSession())
        let (message, isError) = try call(server, "build_circuit", ["parts": [
            ["kind": "resistor", "name": "R1", "connections": ["gate": "x"]],
        ]])
        XCTAssertTrue(isError)
        XCTAssertTrue((message as? String)?.contains("terminals are a, b") ?? false, "\(message)")
        let (unknown, unknownError) = try call(server, "set_parameter", ["part": "R9", "parameter": "resistance", "value": 1])
        XCTAssertTrue(unknownError)
        XCTAssertTrue((unknown as? String)?.contains("No part named R9") ?? false)
        let (kind, kindError) = try call(server, "add_part", ["kind": "flux capacitor"])
        XCTAssertTrue(kindError)
        XCTAssertTrue((kind as? String)?.contains("Unknown kind") ?? false)
    }

    func testBuiltCircuitsAreDrawableAndConnected() throws {
        let session = CircuitSession()
        _ = try session.call("build_circuit", arguments: ["parts": lowPass])
        // drawn like a person would: wires for the signal, ground symbols, no labels needed
        let circuit = session.circuit
        XCTAssertEqual(circuit.elements.filter { $0.kind == .netLabel }.count, 0)
        XCTAssertEqual(circuit.elements.filter { $0.kind == .ground }.count, 2)
        XCTAssertGreaterThan(circuit.elements.filter { $0.kind == .wire }.count, 0)
        let parts = circuit.elements.filter { ![.wire, .ground, .netLabel].contains($0.kind) }
        XCTAssertEqual(Set(parts.map { $0.a }).count, parts.count)
        // appending a part connects it to an existing net by name, though that net is wires now
        _ = try session.call("add_part", arguments: ["kind": "resistor", "name": "RL", "params": ["resistance": "10k"],
                                                     "connections": ["a": "out", "b": "GND"]])
        let described = session.describe()
        let load = (described["parts"] as? [[String: Any]])?.first { $0["name"] as? String == "RL" }
        XCTAssertEqual((load?["connections"] as? [String: String])?["a"], "out")
        XCTAssertEqual(session.circuit.elements.filter { $0.kind == .netLabel }.count, 0)
        let tidied = try XCTUnwrap(session.call("tidy_up", arguments: [:]) as? [String: Any])
        XCTAssertEqual((tidied["parts"] as? [[String: Any]])?.count, 4)
        // the file round-trips
        let circuitBeforeSave = session.circuit
        let path = NSTemporaryDirectory() + "automation-test.jspice"
        _ = try session.call("save_circuit", arguments: ["path": path])
        let other = CircuitSession()
        _ = try other.call("open_circuit", arguments: ["path": path])
        XCTAssertEqual(other.circuit, circuitBeforeSave)
    }
}
