import XCTest
import CoreGraphics
import CoreText
import PDFKit
@testable import JSpiceAutomation
@testable import CircuitKit

/// Schematic capture without the network: the request, the reply's stream, the netlist's checks, the page's text
final class SchematicCaptureTests: XCTestCase {
    func testTheOutputSchemaIsStrict() throws {
        // structured outputs need every object closed and every field required
        func walk(_ value: Any, _ path: String) {
            guard let object = value as? [String: Any] else {
                (value as? [Any])?.forEach { walk($0, path) }
                return
            }
            if object["type"] as? String == "object" {
                let properties = object["properties"] as? [String: Any] ?? [:]
                XCTAssertEqual(object["additionalProperties"] as? Bool, false, path)
                XCTAssertEqual(Set(object["required"] as? [String] ?? []), Set(properties.keys), path)
            }
            for (key, child) in object { walk(child, path + "." + key) }
        }
        walk(SchematicCapture.outputSchema, "$")
        let kinds = try XCTUnwrap(((((SchematicCapture.outputSchema["properties"] as? [String: Any])?["parts"] as? [String: Any])?["items"]
            as? [String: Any])?["properties"] as? [String: Any])?["kind"] as? [String: Any])?["enum"] as? [String]
        XCTAssertTrue(kinds?.contains("resistor") == true)
        XCTAssertFalse(kinds?.contains("block") == true)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: SchematicCapture.outputSchema))
    }

    func testTheRequestCarriesTheDrawingAndItsLabels() throws {
        let page = SchematicCapture.Page(image: Data([0x89, 0x50, 0x4E, 0x47]), mediaType: "image/png",
                                         labels: [.init(text: "R1 4k7", box: CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.02))],
                                         size: CGSize(width: 100, height: 100))
        let body = SchematicCapture.body(messages: [SchematicCapture.firstMessage(page, extra: "The op-amp is a TL072.")])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        let output = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual((output["format"] as? [String: Any])?["type"] as? String, "json_schema")
        let system = try XCTUnwrap((body["system"] as? [[String: Any]])?.first)
        XCTAssertNotNil(system["cache_control"])
        XCTAssertTrue((system["text"] as? String ?? "").contains("opAmp (Op-Amp): terminals"), "the part catalogue")
        let content = try XCTUnwrap(((body["messages"] as? [[String: Any]])?.first)?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "image")
        XCTAssertEqual((content.first?["source"] as? [String: Any])?["data"] as? String, "iVBORw==")
        XCTAssertTrue((content[1]["text"] as? String ?? "").contains("R1 4k7 @ (0.150, 0.210)"))
        XCTAssertTrue((content[2]["text"] as? String ?? "").contains("TL072"))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    func testTheStreamFoldsIntoTheReply() {
        let reply = SchematicCapture.reply(fromEvents: [
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg_1"}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"{\"title\":"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"\"Amp\"}"}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
        ])
        XCTAssertEqual(reply.text, #"{"title":"Amp"}"#)
        XCTAssertEqual(reply.stopReason, "end_turn")
        XCTAssertEqual(reply.content.count, 2)
        XCTAssertEqual(reply.content[0]["signature"] as? String, "abc", "the thinking block goes back as it came")
        XCTAssertNil(reply.error)
        let refused = SchematicCapture.reply(fromEvents: [
            #"data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"no"}}}"#,
        ])
        XCTAssertEqual(refused.stopReason, "refusal")
        XCTAssertEqual(refused.refusal, "no")
    }

    /// A common-emitter stage as the model would write it
    static let netlist: [String: Any] = [
        "title": "Common emitter",
        "notes": ["CE's value is smudged: read as 10u"],
        "parts": [
            ["kind": "dcVoltage", "name": "V1", "model": "", "params": [["key": "voltage", "value": "12"]],
             "connections": [["terminal": "plus", "net": "VCC"], ["terminal": "minus", "net": "GND"]], "reading": "+12V flag", "confidence": "high"],
            ["kind": "acVoltage", "name": "VIN", "model": "", "params": [["key": "amplitude", "value": "10m"]],
             "connections": [["terminal": "plus", "net": "in"], ["terminal": "minus", "net": "GND"]], "reading": "input", "confidence": "high"],
            ["kind": "capacitor", "name": "C1", "model": "", "params": [["key": "capacitance", "value": "1u"]],
             "connections": [["terminal": "a", "net": "in"], ["terminal": "b", "net": "base"]], "reading": "1µ", "confidence": "high"],
            ["kind": "resistor", "name": "R1", "model": "", "params": [["key": "resistance", "value": "47k"]],
             "connections": [["terminal": "a", "net": "VCC"], ["terminal": "b", "net": "base"]], "reading": "47k", "confidence": "high"],
            ["kind": "resistor", "name": "R2", "model": "", "params": [["key": "resistance", "value": "10k"]],
             "connections": [["terminal": "a", "net": "base"], ["terminal": "b", "net": "GND"]], "reading": "10k", "confidence": "high"],
            ["kind": "resistor", "name": "RC", "model": "", "params": [["key": "resistance", "value": "4k7"]],
             "connections": [["terminal": "a", "net": "VCC"], ["terminal": "b", "net": "out"]], "reading": "4k7", "confidence": "high"],
            ["kind": "resistor", "name": "RE", "model": "", "params": [["key": "resistance", "value": "1k"], ["key": "tolerance", "value": "5%"]],
             "connections": [["terminal": "a", "net": "emitter"], ["terminal": "b", "net": "GND"]], "reading": "1k", "confidence": "high"],
            ["kind": "capacitor", "name": "CE", "model": "", "params": [["key": "capacitance", "value": "10u"]],
             "connections": [["terminal": "a", "net": "emitter"], ["terminal": "b", "net": "GND"]], "reading": "10µ (smudged)", "confidence": "low"],
            ["kind": "npn", "name": "Q1", "model": "BC549", "params": [],
             "connections": [["terminal": "collector", "net": "out"], ["terminal": "base", "net": "base"], ["terminal": "emitter", "net": "emitter"]],
             "reading": "BC549", "confidence": "medium"],
            ["kind": "resistor", "name": "RL", "model": "", "params": [["key": "resistance", "value": "100k"]],
             "connections": [["terminal": "a", "net": "out"], ["terminal": "b", "net": "GND"]], "reading": "load", "confidence": "high"],
        ],
    ]

    func testANetlistBecomesACircuit() throws {
        let (parts, dropped) = try SchematicCapture.netlistParts(from: Self.netlist)
        XCTAssertEqual(parts.count, 10)
        // a model or parameter JSpice lacks is left out and said so, not a failure
        XCTAssertTrue(dropped.contains { $0.contains("BC549") }, "\(dropped)")
        XCTAssertTrue(dropped.contains { $0.contains("tolerance") }, "\(dropped)")
        XCTAssertNil(parts.first { $0["name"] as? String == "Q1" }?["model"])
        XCTAssertEqual(SchematicCapture.check(parts), [])
        let circuit = try SchematicCapture.build(parts).get()
        XCTAssertEqual(circuit.elements.first { $0.name == "RC" }?[param: "resistance"], 4700)
        XCTAssertEqual(circuit.elements.first { $0.name == "C1" }?[param: "capacitance"] ?? 0, 1e-6, accuracy: 1e-12)
        // and it simulates: the collector sits between the rails
        let q1 = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "Q1" })
        let source = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "VIN" })
        let simulator = Simulator.settled(circuit, holding: source, duration: 0.3)
        let collector = simulator.terminalVoltages(q1)[1]
        XCTAssertGreaterThan(collector, 2)
        XCTAssertLessThan(collector, 11)
    }

    func testMistakesAreFoundForAnotherLook() throws {
        var netlist = Self.netlist
        var entries = netlist["parts"] as! [[String: Any]]
        // a terminal named wrongly, and a net that goes nowhere
        entries[8]["connections"] = [["terminal": "c", "net": "out"], ["terminal": "base", "net": "base"], ["terminal": "emitter", "net": "emitter"]]
        entries[9]["connections"] = [["terminal": "a", "net": "output"], ["terminal": "b", "net": "GND"]]
        netlist["parts"] = entries
        let (parts, _) = try SchematicCapture.netlistParts(from: netlist)
        let problems = SchematicCapture.check(parts)
        XCTAssertTrue(problems.contains { $0.contains("Q1 has no net for collector") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("Q1 has no terminal c") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("output") }, "\(problems)")
        // an unknown kind fails to build, with a message for the model
        entries[0]["kind"] = "battery"
        netlist["parts"] = entries
        let (bad, _) = try SchematicCapture.netlistParts(from: netlist)
        guard case .failure(let error) = SchematicCapture.build(bad) else { return XCTFail("built an unknown kind") }
        XCTAssertTrue(error.description.contains("Unknown kind battery"))
        XCTAssertThrowsError(try SchematicCapture.netlistParts(from: ["parts": [Any]()]))
    }

    func testAPDFsTextIsReadWithItsPlace() throws {
        // a one-page PDF with a resistor's label near its top left
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var box = CGRect(x: 0, y: 0, width: 600, height: 400)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.stroke(CGRect(x: 100, y: 250, width: 120, height: 30))
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let text = NSAttributedString(string: "R7 220k", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        context.textPosition = CGPoint(x: 100, y: 300)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage()
        context.closePDF()

        let page = try SchematicCapture.page(from: url)
        XCTAssertEqual(page.mediaType, "image/png")
        XCTAssertEqual(max(page.size.width, page.size.height), CGFloat(SchematicCapture.maximumSide))
        let label = try XCTUnwrap(page.labels.first { $0.text.contains("220k") }, "\(page.labels)")
        XCTAssertEqual(label.box.midX, 0.24, accuracy: 0.1)
        XCTAssertEqual(label.box.midY, 0.24, accuracy: 0.1, "from the top")
    }

    func testTheToolExplainsWhatItNeeds() throws {
        let session = CircuitSession()
        XCTAssertThrowsError(try session.call("capture_schematic", arguments: ["path": "/nowhere.png"]))
        XCTAssertTrue(CircuitSession.tools.contains { $0.name == "capture_schematic" })
    }

    /// Reads a drawing for real when a key is set (never in CI): JSpice's own fuzz example, exported as a PDF
    func testLiveCaptureWhenAKeyIsSet() async throws {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty,
              let path = ProcessInfo.processInfo.environment["JSPICE_CAPTURE_SAMPLE"] else {
            throw XCTSkip("set ANTHROPIC_API_KEY and JSPICE_CAPTURE_SAMPLE to read a real drawing")
        }
        let capture = try await SchematicCapture.capture(URL(fileURLWithPath: path), key: key)
        XCTAssertFalse(capture.circuit.elements.isEmpty)
        print("Captured \(capture.circuit.elements.count) elements in \(capture.attempts) turns; notes: \(capture.notes)")
    }
}
