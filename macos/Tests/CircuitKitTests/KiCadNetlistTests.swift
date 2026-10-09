import XCTest
@testable import CircuitKit

/// The KiCad netlist: a well-formed S-expression, each part on its footprint with its pads on the nets the schematic
/// puts them on
final class KiCadNetlistTests: XCTestCase {
    /// An S-expression: an atom (a quoted string unquoted) or a list
    indirect enum S: Equatable {
        case atom(String)
        case list([S])

        var items: [S] { if case .list(let items) = self { return items } else { return [] } }
        var text: String? { if case .atom(let text) = self { return text } else { return nil } }
        /// The first list in this one headed `name`
        func child(_ name: String) -> S? { items.first { $0.items.first?.text == name } }
        func children(_ name: String) -> [S] { items.filter { $0.items.first?.text == name } }
        /// The atom after `name` in the first list headed `name`
        func value(_ name: String) -> String? { child(name)?.items.dropFirst().first?.text }
    }

    static func parse(_ text: String) throws -> S {
        let characters = Array(text)
        var k = 0
        func skip() { while k < characters.count, characters[k].isWhitespace { k += 1 } }
        func expression() throws -> S {
            skip()
            guard k < characters.count else { throw NSError(domain: "end of text", code: 1) }
            if characters[k] == "(" {
                k += 1
                var items: [S] = []
                while true {
                    skip()
                    guard k < characters.count else { throw NSError(domain: "unclosed (", code: 2) }
                    if characters[k] == ")" {
                        k += 1
                        return .list(items)
                    }
                    items.append(try expression())
                }
            }
            if characters[k] == "\"" {
                k += 1
                var atom = ""
                while k < characters.count, characters[k] != "\"" {
                    if characters[k] == "\\", k + 1 < characters.count { k += 1 }
                    atom.append(characters[k])
                    k += 1
                }
                guard k < characters.count else { throw NSError(domain: "unclosed string", code: 3) }
                k += 1
                return .atom(atom)
            }
            guard characters[k] != ")" else { throw NSError(domain: "stray )", code: 4) }
            var atom = ""
            while k < characters.count, !characters[k].isWhitespace, characters[k] != "(", characters[k] != ")" {
                atom.append(characters[k])
                k += 1
            }
            return .atom(atom)
        }
        let root = try expression()
        skip()
        guard k == characters.count else { throw NSError(domain: "text after the end", code: 5) }
        return root
    }

    func testAPedalBoardsParts() throws {
        let tl072 = ElementKind.opAmp.models.first { $0.name == "TL072" }?.values ?? [:]
        var amp = tl072
        amp["midpoint"] = 4.5
        let parts = [
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 9], connections: ["plus": "vcc", "minus": "GND"]),
            NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": 0.1, "frequency": 440, "offset": 4.5],
                        connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .opAmp, name: "A1", params: amp, connections: ["plus": "in", "minus": "fb1", "out": "o1"]),
            NetlistPart(kind: .opAmp, name: "A2", params: amp, connections: ["plus": "o1", "minus": "o2", "out": "o2"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 10_000], connections: ["a": "o1", "b": "fb1"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 10_000], connections: ["a": "fb1", "b": "bias"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 10e-6], connections: ["a": "GND", "b": "vcc"]),
            NetlistPart(kind: .capacitor, name: "C2", params: ["capacitance": 100e-9], connections: ["a": "bias", "b": "GND"]),
            NetlistPart(kind: .resistor, name: "R3", params: ["resistance": 10_000], connections: ["a": "vcc", "b": "bias"]),
            NetlistPart(kind: .resistor, name: "R4", params: ["resistance": 10_000], connections: ["a": "bias", "b": "GND"]),
            NetlistPart(kind: .npn, name: "Q1", params: ElementKind.npn.models.first { $0.name == "2N3904" }?.values ?? [:],
                        connections: ["base": "b", "collector": "led", "emitter": "GND"]),
            NetlistPart(kind: .resistor, name: "R6", params: ["resistance": 47_000], connections: ["a": "o2", "b": "b"]),
            NetlistPart(kind: .resistor, name: "R5", params: ["resistance": 1000], connections: ["a": "vcc", "b": "lr"]),
            NetlistPart(kind: .led, name: "D2", connections: ["anode": "lr", "cathode": "led"]),
            NetlistPart(kind: .diode, name: "D1", connections: ["anode": "o2", "cathode": "vcc"]),
            NetlistPart(kind: .potentiometer, name: "P1", params: ["resistance": 100_000],
                        connections: ["a": "o2", "b": "GND", "wiper": "out"]),
            NetlistPart(kind: .speaker, name: "OUT", connections: ["plus": "out", "minus": "GND"]),
        ]
        let circuit = try SchematicLayout.layout(parts)
        let export = KiCadNetlist.export(circuit, title: "Test pedal", date: Date(timeIntervalSince1970: 0))
        let root = try Self.parse(export.text)
        XCTAssertEqual(root.items.first?.text, "export")
        XCTAssertEqual(root.value("version"), "E")
        let components = try XCTUnwrap(root.child("components")).children("comp")
        let byRef = Dictionary(uniqueKeysWithValues: components.map { ($0.value("ref") ?? "", $0) })
        XCTAssertEqual(export.components, components.count)
        XCTAssertTrue(export.unassigned.isEmpty, "\(export.unassigned)")

        // the nets the schematic has (by the names the exporter gives them), and each pad's net in the file
        let schematic = Dictionary(uniqueKeysWithValues: NetlistExtractor.netlist(from: circuit.flattened(expandingModels: false))
            .map { ($0.name, $0.connections) })
        var padNet: [String: String] = [:]
        let nets = try XCTUnwrap(root.child("nets")).children("net")
        XCTAssertEqual(export.nets, nets.count)
        XCTAssertEqual(nets.first?.value("name"), "GND", "ground first")
        for net in nets {
            let name = try XCTUnwrap(net.value("name"))
            for node in net.children("node") {
                let key = "\(node.value("ref") ?? "").\(node.value("pin") ?? "")"
                XCTAssertNil(padNet[key], "\(key) on two nets")
                padNet[key] = name
            }
        }
        func net(_ part: String, _ terminal: String) throws -> String {
            let n = try XCTUnwrap(schematic[part]?[terminal], "\(part).\(terminal)")
            return Topology.isGroundName(n) ? "GND" : n
        }
        func footprint(_ ref: String) -> String? { byRef[ref]?.value("footprint") }

        // the two op-amps in one TL072: units A and B on pins 1-3 and 5-7, its supplies on 8 and 4
        XCTAssertNil(byRef["A1"])
        XCTAssertEqual(footprint("U1"), "Package_DIP:DIP-8_W7.62mm")
        XCTAssertEqual(padNet["U1.1"], try net("A1", "out"))
        XCTAssertEqual(padNet["U1.2"], try net("A1", "minus"))
        XCTAssertEqual(padNet["U1.3"], try net("A1", "plus"))
        XCTAssertEqual(padNet["U1.5"], try net("A2", "plus"))
        XCTAssertEqual(padNet["U1.6"], try net("A2", "minus"))
        XCTAssertEqual(padNet["U1.7"], try net("A2", "out"))
        XCTAssertEqual(padNet["U1.8"], try net("V1", "plus"))
        XCTAssertEqual(padNet["U1.4"], "GND")
        // the 2N3904's pads in its pinout's order, E B C
        XCTAssertEqual(footprint("Q1"), "Package_TO_SOT_THT:TO-92_Inline")
        XCTAssertEqual(padNet["Q1.1"], "GND")
        XCTAssertEqual(padNet["Q1.2"], try net("Q1", "base"))
        XCTAssertEqual(padNet["Q1.3"], try net("Q1", "collector"))
        // diodes and LEDs: the cathode on pad 1
        XCTAssertEqual(footprint("D1"), "Diode_THT:D_DO-35_SOD27_P7.62mm_Horizontal")
        XCTAssertEqual(padNet["D1.1"], try net("D1", "cathode"))
        XCTAssertEqual(footprint("D2"), "LED_THT:LED_D5.0mm")
        XCTAssertEqual(padNet["D2.1"], try net("D2", "cathode"))
        XCTAssertEqual(padNet["D2.2"], try net("D2", "anode"))
        // the electrolytic's + (pad 1) on the 9 V supply, though it is its second terminal
        XCTAssertEqual(footprint("C1"), "Capacitor_THT:CP_Radial_D5.0mm_P2.00mm")
        XCTAssertEqual(padNet["C1.1"], try net("V1", "plus"))
        XCTAssertEqual(padNet["C1.2"], "GND")
        XCTAssertEqual(footprint("C2"), "Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P5.00mm")
        XCTAssertEqual(footprint("R1"), "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal")
        // the pot's lugs: an end, the wiper, the other end
        XCTAssertEqual(padNet["P1.1"], try net("P1", "a"))
        XCTAssertEqual(padNet["P1.2"], try net("P1", "wiper"))
        XCTAssertEqual(padNet["P1.3"], "GND")
        // off the board on pin headers: the 9 V supply, the signal source, the output
        let headers = components.filter { $0.value("footprint")?.hasPrefix("Connector_PinHeader_2.54mm:PinHeader_1x02") == true }
        XCTAssertEqual(Set(headers.compactMap { $0.value("ref") }).isSuperset(of: ["VIN", "OUT"]), true, "\(headers)")
        XCTAssertTrue(headers.contains { $0.value("value") == "Power 9 V" })
        print(export.text)
    }
}
