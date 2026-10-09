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

    func testRequestsWithoutAMethodGetAnError() throws {
        let server = MCPServer(session: CircuitSession())
        let reply = json(try XCTUnwrap(server.handle(#"{"jsonrpc":"2.0","id":7}"#)))
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertNotNil(server.handle("[]"), "an empty batch is an invalid request")
    }

    func testReadsAMicrocontrollersSerialOutput() throws {
        let session = CircuitSession()
        _ = try session.call("load_example", arguments: ["id": "arduino-knob"])
        _ = try session.call("simulate", arguments: ["duration": 0.2, "probes": ["I(D1)"]])
        let serial = try XCTUnwrap(try session.call("read_serial", arguments: ["part": "U1", "send": "hi"]) as? [String: Any])
        XCTAssertTrue((serial["output"] as? String ?? "").hasPrefix("A0 = 614"), "\(serial)")
        XCTAssertThrowsError(try session.call("read_serial", arguments: ["part": "R1"]), "not a microcontroller")
    }

    func testSimulateRefusesStepCountsItCannotCount() throws {
        let session = CircuitSession()
        _ = try session.call("load_example", arguments: ["id": "rc"])
        XCTAssertThrowsError(try session.call("simulate", arguments: ["duration": 1e30, "probes": ["V(GND)"]]))
        XCTAssertThrowsError(try session.call("simulate", arguments: ["duration": 1e4, "time_step": "1f", "probes": ["V(GND)"]]))
        XCTAssertThrowsError(try session.call("set_sequence", arguments: ["steps": ["inf"]]))
    }

    func testFrequencyResponseOfAnRCLowPass() throws {
        let server = MCPServer(session: CircuitSession())
        let (_, buildError) = try call(server, "build_circuit", ["parts": lowPass])
        XCTAssertFalse(buildError)
        // small-signal analysis (the default) is exact; the transient measurement within its sampling
        for (method, gainAccuracy, phaseAccuracy) in [("ac", 1e-6, 1e-4), ("transient", 0.01, 2.0)] {
            let (value, isError) = try call(server, "frequency_response",
                                            ["source": "V1", "output": "V(out)", "frequencies": [100, 1000, 10_000], "method": method])
            XCTAssertFalse(isError, "\(value)")
            XCTAssertEqual((value as? [String: Any])?["method"] as? String, method)
            let points = try XCTUnwrap((value as? [String: Any])?["points"] as? [[String: Any]])
            XCTAssertEqual(points.count, 3)
            let gains = points.compactMap { $0["gain"] as? Double }
            let phases = points.compactMap { $0["phase_deg"] as? Double }
            // first order: |H| = 1 / sqrt(1 + (f / fc)²), phase = -atan(f / fc)
            for (k, f) in [100.0, 1000, 10_000].enumerated() {
                XCTAssertEqual(gains[k], 1 / (1 + (f / 1000) * (f / 1000)).squareRoot(), accuracy: gainAccuracy, "\(method) gain at \(f) Hz")
                XCTAssertEqual(phases[k], -atan(f / 1000) * 180 / .pi, accuracy: phaseAccuracy, "\(method) phase at \(f) Hz")
            }
        }
        // a sweep finds the corner
        let (sweep, sweepError) = try call(server, "frequency_response", ["source": "V1", "output": "V(out)", "start": 10, "stop": "100k"])
        XCTAssertFalse(sweepError, "\(sweep)")
        let result = try XCTUnwrap(sweep as? [String: Any])
        XCTAssertEqual((result["points"] as? [[String: Any]])?.count, 81)
        let corners = try XCTUnwrap(result["minus_3db"] as? [Double])
        XCTAssertEqual(corners.count, 1)
        XCTAssertEqual(corners.first ?? 0, 1000, accuracy: 10)
        let (_, currentError) = try call(server, "frequency_response", ["source": "V1", "output": "I(R1)"])
        XCTAssertTrue(currentError, "ac takes voltages only")
    }

    /// An agent makes an RC low-pass into a block, uses it twice, and measures the pair
    func testAnAgentCanMakeAndUseBlocks() throws {
        setenv("JSPICE_BLOCKS", FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path, 1)
        defer { unsetenv("JSPICE_BLOCKS") }
        let session = CircuitSession()
        let defined = try XCTUnwrap(session.call("define_block", arguments: [
            "name": "RC", "save": true,
            "parts": [
                ["kind": "port", "name": "in", "connections": ["net": "in"]],
                ["kind": "resistor", "name": "R1", "params": ["resistance": "1k"], "connections": ["a": "in", "b": "out"]],
                ["kind": "capacitor", "name": "C1", "params": ["capacitance": "1u"], "connections": ["a": "out", "b": "GND"]],
                ["kind": "port", "name": "out", "connections": ["net": "out"]],
            ],
        ]) as? [String: Any])
        // neither port says its side: out goes on the right by its name
        XCTAssertEqual(defined["inputs"] as? [String], ["in"])
        XCTAssertEqual(defined["outputs"] as? [String], ["out"])
        XCTAssertEqual(BlockLibrary.all().map(\.name), ["RC"], "saved in the library")
        _ = try session.call("build_circuit", arguments: ["parts": [
            ["kind": "acVoltage", "name": "VIN", "params": ["amplitude": 1, "frequency": 100], "connections": ["plus": "in", "minus": "GND"]],
            ["kind": "block", "block": "RC", "name": "X1", "connections": ["in": "in", "out": "mid"]],
            ["kind": "block", "block": "rc", "name": "X2", "connections": ["in": "mid", "out": "out"]],
        ]])
        let described = session.describe()
        let parts = try XCTUnwrap(described["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.filter { $0["block"] as? String == "RC" }.count, 2)
        XCTAssertTrue((described["problems"] as? [String])?.isEmpty ?? false)
        // two first-order stages of 159 Hz: at 159 Hz each is 3 dB down and 45° behind
        let corner = 1 / (2 * Double.pi * 1000 * 1e-6)
        let response = try XCTUnwrap(session.call("frequency_response", arguments: [
            "source": "VIN", "output": "V(X2.out)", "frequencies": [corner],
        ]) as? [String: Any])
        let point = try XCTUnwrap((response["points"] as? [[String: Any]])?.first)
        // the second stage loads the first, so not quite -6 dB: |1 / (1 + 3jw + (jw)^2)| at w = 1 is 1/3
        XCTAssertEqual(point["gain"] as? Double ?? 0, 1.0 / 3, accuracy: 1e-6)
        XCTAssertEqual(point["phase_deg"] as? Double ?? 0, -90, accuracy: 1e-4)
        // and in time: the output follows the input through both stages
        let simulated = try XCTUnwrap(session.call("simulate", arguments: ["duration": 0.05, "probes": ["V(out)", "V(X1.out)"]]) as? [String: Any])
        let out = try XCTUnwrap((simulated["probes"] as? [String: Any])?["V(out)"] as? [String: Any])
        XCTAssertGreaterThan(out["max"] as? Double ?? 0, 0.3)
        XCTAssertEqual((session.listBlocks() as? [[String: Any]])?.first?["name"] as? String, "RC")
        XCTAssertThrowsError(try session.call("build_circuit", arguments: ["parts": [["kind": "block", "block": "nope"]]]))
        XCTAssertThrowsError(try session.call("define_block", arguments: ["name": "Empty", "parts": [["kind": "resistor"]]]),
                             "a block needs ports")
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

    /// The LM13700 filter measured as an agent would: flat in the passband, a peak of about Q at the cutoff (2 kHz with
    /// the pot centred, Q about 2.35), and 12 dB per octave above it
    func testFilterResponseMatchesItsDesign() throws {
        let session = CircuitSession()
        session.circuit = try SchematicLayout.layout(Examples.filterParts(input: NetlistPart(
            kind: .acVoltage, name: "VIN", params: ["amplitude": 1, "frequency": 1000], connections: ["plus": "in", "minus": "GND"])))
        let f0 = 1993.0
        let result = try XCTUnwrap(session.call("frequency_response", arguments: [
            "source": "VIN", "output": "V(lp)", "frequencies": [f0 / 20, f0, 4 * f0],
        ]) as? [String: Any])
        let points = try XCTUnwrap(result["points"] as? [[String: Any]])
        XCTAssertEqual(points.count, 3)
        let gains = points.map { $0["gain"] as? Double ?? 0 }
        let phases = points.map { $0["phase_deg"] as? Double ?? 0 }
        XCTAssertEqual(gains[0], 1, accuracy: 0.05, "passband")
        XCTAssertEqual(gains[1], 2.35, accuracy: 0.5, "resonant peak at the cutoff")
        XCTAssertEqual(phases[1], -90, accuracy: 20, "a quarter cycle behind at the cutoff")
        XCTAssertEqual(gains[2], 1 / 15.1, accuracy: 0.025, "12 dB per octave: about 1/15 two octaves up")
    }

    func testAnAgentCanSequenceTheSynth() throws {
        let session = CircuitSession()
        _ = try session.call("load_example", arguments: ["id": "synth"])
        let set = try XCTUnwrap(session.call("set_sequence", arguments: [
            "steps": ["A3", NSNull(), "A4", "-"], "tempo": 150, "gate": 0.75,
        ]) as? [String: Any])
        XCTAssertEqual(set["step_seconds"] as? Double ?? 0, 0.1, accuracy: 1e-9)
        let described = try XCTUnwrap(session.call("describe_circuit", arguments: [:]) as? [String: Any])
        XCTAssertNotNil(described["sequence"])
        // the second bar, after the envelope has settled: A3 then A4 each sound for 75 ms of every 400
        let result = try XCTUnwrap(session.call("simulate", arguments: [
            "duration": 0.8, "time_step": 1.0 / 96_000, "probes": ["V(SPK1)"], "points": 400,
        ]) as? [String: Any])
        let speaker = try XCTUnwrap((result["probes"] as? [String: Any])?["V(SPK1)"] as? [String: Any])
        XCTAssertGreaterThan(speaker["max"] as? Double ?? 0, 0.5)
        XCTAssertThrowsError(try session.call("set_sequence", arguments: ["steps": ["H9"]]))
        _ = try session.call("set_sequence", arguments: ["steps": ["A3"], "playing": false])
        XCTAssertEqual(session.circuit.sequence?.playing, false)
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

    /// An agent plays a WAV file through a fuzz and renders what the speaker hears to another
    func testAnAgentCanRenderSound() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tone = (0..<24_000).map { Float(sin(2 * .pi * 220 * Double($0) / 24_000)) }
        let input = folder.appendingPathComponent("tone.wav")
        try WAV.encode(tone, sampleRate: 24_000).write(to: input)

        let session = CircuitSession()
        _ = try session.call("build_circuit", arguments: ["parts": [
            ["kind": "audioInput", "name": "GTR", "connections": ["plus": "in", "minus": "GND"]],
            ["kind": "resistor", "name": "R1", "params": ["resistance": "1k"], "connections": ["a": "in", "b": "clip"]],
            ["kind": "diode", "name": "D1", "model": "1N4148", "connections": ["anode": "clip", "cathode": "GND"]],
            ["kind": "diode", "name": "D2", "model": "1N4148", "connections": ["anode": "GND", "cathode": "clip"]],
            ["kind": "speaker", "name": "SPK1", "params": ["fullScale": 1], "connections": ["plus": "clip", "minus": "GND"]],
        ]])
        let chosen = try XCTUnwrap(session.call("set_audio_input", arguments: ["part": "GTR", "path": input.path, "level": 2]) as? [String: Any])
        XCTAssertEqual(chosen["sound"] as? String, "tone")
        XCTAssertEqual(chosen["seconds"] as? Double ?? 0, 1, accuracy: 1e-9)
        let audio = try XCTUnwrap(session.circuit.elements.first { $0.name == "GTR" }?.audio)
        XCTAssertEqual(audio.sampleRate, 24_000)

        let output = folder.appendingPathComponent("out.wav")
        let rendered = try XCTUnwrap(session.call("render_audio", arguments: ["path": output.path, "duration": 0.5, "sample_rate": 24_000]) as? [String: Any])
        XCTAssertEqual(rendered["seconds"] as? Double ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(rendered["truncated"] as? Bool, false)
        // ±2 V into two diodes: clipped at about ±0.7 V
        XCTAssertEqual(rendered["peak"] as? Double ?? 0, 0.7, accuracy: 0.15)
        let written = try WAV.decode(Data(contentsOf: output))
        XCTAssertEqual(written.samples.count, 12_000)
        XCTAssertEqual(written.sampleRate, 24_000)

        let server = MCPServer(session: session)
        let (message, isError) = try call(server, "set_audio_input", ["part": "R1"])
        XCTAssertTrue(isError)
        XCTAssertTrue((message as? String)?.contains("not an audio input") ?? false, "\(message)")
    }

    func testAnAgentCanMeasureDistortion() throws {
        let session = CircuitSession()
        _ = try session.call("load_example", arguments: ["id": "overdrive"])
        let result = try XCTUnwrap(session.call("spectrum", arguments: ["probe": "V(D1)", "duration": 0.2, "settle": 0.1]) as? [String: Any])
        // the example's 220 Hz input, clipped by the diodes: well above 10 % THD, odd harmonics first
        XCTAssertEqual(result["fundamental_hz"] as? Double ?? 0, 220, accuracy: 1)
        XCTAssertGreaterThan(result["thd_percent"] as? Double ?? 0, 10)
        let harmonics = try XCTUnwrap(result["harmonics"] as? [[String: Any]])
        XCTAssertEqual(harmonics.count, 10)
        let third = harmonics[2]["relative_db"] as? Double ?? -999
        let second = harmonics[1]["relative_db"] as? Double ?? 0
        XCTAssertGreaterThan(third, second + 10)
        XCTAssertEqual(result["resolution_hz"] as? Double ?? 0, 1 / 0.2, accuracy: 0.1)
        XCTAssertThrowsError(try session.call("spectrum", arguments: ["probe": "V(nowhere)"]))
    }

    func testAnAgentCanSweepAndCheckTolerances() throws {
        let session = CircuitSession()
        _ = try session.call("build_circuit", arguments: ["parts": [
            ["kind": "acVoltage", "name": "VIN", "params": ["amplitude": 1, "offset": 10, "frequency": 1000], "connections": ["plus": "in", "minus": "GND"]],
            ["kind": "resistor", "name": "R1", "params": ["resistance": "1k"], "connections": ["a": "in", "b": "out"]],
            ["kind": "resistor", "name": "R2", "params": ["resistance": "1k"], "connections": ["a": "out", "b": "GND"]],
            ["kind": "capacitor", "name": "C1", "params": ["capacitance": "100n"], "connections": ["a": "out", "b": "GND"]],
        ]])
        // the corner of R1 ∥ R2 with C1 follows C1: 1 / (2π 500 Ω C)
        let sweep = try XCTUnwrap(session.call("sweep", arguments: [
            "part": "C1", "parameter": "capacitance", "values": ["100n", "1u"],
            "measure": ["type": "ac", "source": "VIN", "output": "V(out)", "frequencies": FrequencySweep.logarithmic(from: 10, to: 100_000, pointsPerDecade: 50)],
        ]) as? [String: Any])
        let rows = try XCTUnwrap(sweep["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["corner_hz"] as? Double ?? 0, 1 / (2 * .pi * 500 * 100e-9), accuracy: 30)
        XCTAssertEqual(rows[1]["corner_hz"] as? Double ?? 0, 1 / (2 * .pi * 500 * 1e-6), accuracy: 3)
        XCTAssertEqual(rows[0]["peak_db"] as? Double ?? 0, 20 * log10(0.5), accuracy: 0.01)
        // 1 % resistors: the divider's 5 V spread by about 5 V × 1 % / 3 / √2
        let tolerance = try XCTUnwrap(session.call("monte_carlo", arguments: [
            "runs": 200, "tolerances": ["resistors": 0.01], "measure": ["type": "op", "probes": ["V(out)"]],
        ]) as? [String: Any])
        XCTAssertEqual(tolerance["runs"] as? Int, 200)
        let entry = try XCTUnwrap((tolerance["metrics"] as? [String: Any])?["V(out)"] as? [String: Any])
        let metric = entry.compactMapValues { $0 as? Double }
        XCTAssertNotNil(entry["min_run"] as? Int)
        XCTAssertEqual(metric["nominal"] ?? 0, 5, accuracy: 1e-3)
        XCTAssertEqual(metric["mean"] ?? 0, 5, accuracy: 0.01)
        XCTAssertEqual(metric["std"] ?? 0, 5 * 0.01 / 3 / 2.0.squareRoot(), accuracy: 0.004)
        XCTAssertLessThan(metric["max"] ?? 99, 5.08)
        XCTAssertGreaterThan(metric["min"] ?? 0, 4.92)
        XCTAssertThrowsError(try session.call("sweep", arguments: ["part": "C1", "parameter": "voltage", "values": [1], "measure": ["type": "op", "probes": ["V(out)"]]]))
    }

    func testAnAgentCanImportAndExportSpice() throws {
        let session = CircuitSession()
        let imported = try XCTUnwrap(session.call("import_spice", arguments: ["netlist": """
        divider
        V1 in 0 DC 9
        R1 in out 10k
        R2 out 0 20k
        T1 a 0 b 0 Z0=50 TD=1n
        .end
        """]) as? [String: Any])
        XCTAssertEqual((imported["parts"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual((imported["left_out"] as? [String])?.count, 1)
        let measured = try XCTUnwrap(session.call("measure", arguments: [:]) as? [String: Any])
        XCTAssertNotNil(measured)
        let exported = try XCTUnwrap(session.call("export_spice", arguments: [:]) as? [String: Any])
        let deck = try XCTUnwrap(exported["netlist"] as? String)
        XCTAssertTrue(deck.contains("R1 in out 10000"), deck)
        XCTAssertTrue(deck.contains("V1 in 0 DC 9"), deck)
    }

    func testAnAgentCanOptimizeAFilter() throws {
        let session = CircuitSession()
        _ = try session.call("build_circuit", arguments: ["parts": [
            ["kind": "acVoltage", "name": "VIN", "params": ["amplitude": 1, "frequency": 1000], "connections": ["plus": "in", "minus": "GND"]],
            ["kind": "resistor", "name": "R1", "params": ["resistance": "1k"], "connections": ["a": "in", "b": "out"]],
            ["kind": "capacitor", "name": "C1", "params": ["capacitance": "10n"], "connections": ["a": "out", "b": "GND"]],
        ]])
        let measure: [String: Any] = ["type": "ac", "source": "VIN", "output": "V(out)",
                                      "frequencies": FrequencySweep.logarithmic(from: 10, to: 100_000, pointsPerDecade: 40)]
        // a 1 kHz corner with R1 at 1 kΩ: C1 = 159 nF
        let result = try XCTUnwrap(session.call("optimize", arguments: [
            "parameters": [["part": "C1", "parameter": "capacitance", "min": "1n", "max": "10u"]],
            "measure": measure, "targets": [["metric": "corner_hz", "value": 1000]], "apply": false,
        ]) as? [String: Any])
        let value = try XCTUnwrap((result["values"] as? [[String: Any]])?.first?["value"] as? Double)
        XCTAssertEqual(value, 1 / (2 * .pi * 1000 * 1000), accuracy: 3e-9)
        XCTAssertEqual(session.circuit.elements.first { $0.name == "C1" }?[param: "capacitance"], 10e-9, "not applied")
        // on E12 values, and applied: 150 nF (1.06 kHz) is nearer than 180 nF (884 Hz)
        let snapped = try XCTUnwrap(session.call("optimize", arguments: [
            "parameters": [["part": "C1", "parameter": "capacitance", "min": "1n", "max": "10u"]],
            "measure": measure, "targets": [["metric": "corner_hz", "value": 1000]], "series": 12,
        ]) as? [String: Any])
        XCTAssertNotNil(snapped["metrics"])
        XCTAssertEqual(session.circuit.elements.first { $0.name == "C1" }?[param: "capacitance"] ?? 0, 150e-9, accuracy: 1e-15)
        XCTAssertThrowsError(try session.call("optimize", arguments: [
            "parameters": [["part": "C1", "parameter": "capacitance"]], "measure": measure, "targets": [["metric": "nothing", "value": 1]],
        ]))
    }

    func testAnAgentCanLayOutABreadboard() throws {
        let session = CircuitSession()
        _ = try session.call("load_example", arguments: ["id": "fuzz"])
        let board = try XCTUnwrap(session.call("breadboard", arguments: [:]) as? [String: Any])
        XCTAssertEqual((board["problems"] as? [String])?.isEmpty, true, "\(board["problems"] ?? "")")
        let parts = try XCTUnwrap(board["parts"] as? [[String: Any]])
        XCTAssertFalse(parts.isEmpty)
        XCTAssertTrue(parts.allSatisfy { ($0["legs"] as? [[String: Any]])?.isEmpty == false })
        XCTAssertNotNil(board["jumpers"] as? [[String: Any]])
        let bom = try XCTUnwrap((session.call("bom", arguments: [:]) as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertTrue(bom.contains { ($0["part"] as? String)?.contains("resistor") == true })
        let strip = try XCTUnwrap(session.call("stripboard", arguments: [:]) as? [String: Any])
        XCTAssertEqual((strip["problems"] as? [String])?.isEmpty, true, "\(strip["problems"] ?? "")")
        XCTAssertFalse((strip["cuts"] as? [String])?.isEmpty ?? true)
        let stripBOM = try XCTUnwrap((session.call("bom", arguments: ["board": "stripboard"]) as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertTrue(stripBOM.contains { ($0["part"] as? String)?.hasPrefix("stripboard") == true })
        XCTAssertThrowsError(try session.call("bom", arguments: ["board": "perfboard"]))
    }

    func testAnAgentCanMapMIDIControllers() throws {
        let session = CircuitSession()
        _ = try session.call("build_circuit", arguments: ["parts": [
            ["kind": "dcVoltage", "name": "V1", "params": ["voltage": 9], "connections": ["plus": "vcc", "minus": "GND"]],
            ["kind": "potentiometer", "name": "GAIN", "connections": ["a": "vcc", "b": "GND", "wiper": "w"]],
            ["kind": "resistor", "name": "R1", "connections": ["a": "w", "b": "GND"]],
        ]])
        let mapped = try XCTUnwrap(session.call("map_midi", arguments: ["part": "GAIN", "controller": 21, "channel": 1]) as? [String: Any])
        XCTAssertEqual(mapped["midi"] as? String, "CC 21 · ch 1")
        XCTAssertEqual(session.circuit.midiMappings.first?.channel, 0)
        let parts = try XCTUnwrap(session.describe()["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.first { $0["name"] as? String == "GAIN" }?["midi"] as? String, "CC 21 · ch 1")
        XCTAssertThrowsError(try session.call("map_midi", arguments: ["part": "R1", "controller": 21]))
        XCTAssertThrowsError(try session.call("map_midi", arguments: ["part": "GAIN", "controller": 123]))
        _ = try session.call("map_midi", arguments: ["part": "GAIN", "remove": true])
        XCTAssertTrue(session.circuit.midiMappings.isEmpty)
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
