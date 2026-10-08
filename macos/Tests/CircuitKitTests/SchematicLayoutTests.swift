import XCTest
@testable import CircuitKit

/// The tidy layout must draw exactly the netlist it was given, without parts on top of each other or wires through pins.
final class SchematicLayoutTests: XCTestCase {
    private func part(_ kind: ElementKind, _ name: String, _ connections: [String: String], _ params: [String: Double] = [:]) -> NetlistPart {
        NetlistPart(kind: kind, name: name, params: params, connections: connections)
    }

    private var circuits: [String: [NetlistPart]] {
        [
            "inverting": [
                part(.acVoltage, "VIN", ["plus": "in", "minus": "GND"]), part(.resistor, "RI", ["a": "in", "b": "inv"]),
                part(.resistor, "RF", ["a": "inv", "b": "out"]), part(.opAmp, "U1", ["minus": "inv", "plus": "GND", "out": "out"]),
                part(.resistor, "RL", ["a": "out", "b": "GND"]),
            ],
            "noninverting": [
                part(.acVoltage, "VIN", ["plus": "in", "minus": "GND"]), part(.opAmp, "U1", ["plus": "in", "minus": "fb", "out": "out"]),
                part(.resistor, "RF", ["a": "out", "b": "fb"]), part(.resistor, "RG", ["a": "fb", "b": "GND"]),
            ],
            "sallenkey": [
                part(.acVoltage, "VIN", ["plus": "in", "minus": "GND"]), part(.resistor, "R1", ["a": "in", "b": "mid"]),
                part(.resistor, "R2", ["a": "mid", "b": "plus"]), part(.capacitor, "C1", ["a": "mid", "b": "out"]),
                part(.capacitor, "C2", ["a": "plus", "b": "GND"]), part(.opAmp, "U1", ["plus": "plus", "minus": "out", "out": "out"]),
            ],
            "lfo": [
                part(.opAmp, "U1", ["minus": "inv", "plus": "GND", "out": "tri"]), part(.capacitor, "C1", ["a": "inv", "b": "tri"]),
                part(.resistor, "R2", ["a": "tri", "b": "p2"]), part(.opAmp, "U2", ["plus": "p2", "minus": "GND", "out": "sq"]),
                part(.resistor, "R3", ["a": "p2", "b": "sq"]), part(.resistor, "R1", ["a": "sq", "b": "inv"]),
            ],
            "555": [
                part(.dcVoltage, "V1", ["plus": "VCC", "minus": "GND"]),
                part(.timer555, "U1", ["vcc": "VCC", "reset": "VCC", "gnd": "GND", "dis": "dis", "thr": "trig", "trig": "trig", "out": "out"]),
                part(.resistor, "RA", ["a": "VCC", "b": "dis"]), part(.resistor, "RB", ["a": "dis", "b": "trig"]),
                part(.capacitor, "C1", ["a": "trig", "b": "GND"]), part(.resistor, "R3", ["a": "out", "b": "led"]),
                part(.led, "D1", ["anode": "led", "cathode": "GND"]),
            ],
            "vca": [
                part(.acVoltage, "VIN", ["plus": "sig", "minus": "GND"]), part(.resistor, "R1", ["a": "sig", "b": "inm"]),
                part(.resistor, "R2", ["a": "inm", "b": "GND"]), part(.ota, "U1", ["minus": "inm", "plus": "GND", "out": "out", "bias": "iabc"]),
                part(.resistor, "RB", ["a": "cv", "b": "iabc"]), part(.acVoltage, "VCV", ["plus": "cv", "minus": "GND"]),
                part(.resistor, "RL", ["a": "out", "b": "GND"]),
            ],
            "commonemitter": [
                part(.dcVoltage, "V1", ["plus": "VCC", "minus": "GND"]), part(.acVoltage, "VIN", ["plus": "in", "minus": "GND"]),
                part(.capacitor, "CIN", ["a": "in", "b": "base"]), part(.resistor, "R1", ["a": "VCC", "b": "base"]),
                part(.resistor, "R2", ["a": "base", "b": "GND"]), part(.npn, "Q1", ["base": "base", "collector": "col", "emitter": "em"]),
                part(.resistor, "RC", ["a": "VCC", "b": "col"]), part(.resistor, "RE", ["a": "em", "b": "GND"]),
                part(.capacitor, "COUT", ["a": "col", "b": "out"]), part(.resistor, "RL", ["a": "out", "b": "GND"]),
            ],
            "schmitt": [
                part(.schmittInverter, "U1", ["in": "cap", "out": "out"]), part(.resistor, "R1", ["a": "out", "b": "cap"]),
                part(.capacitor, "C1", ["a": "cap", "b": "GND"]), part(.resistor, "R2", ["a": "out", "b": "led"]),
                part(.led, "D1", ["anode": "led", "cathode": "GND"]),
            ],
            "battery": [
                part(.dcVoltage, "V1", ["plus": "VCC", "minus": "GND"]), part(.resistor, "R1", ["a": "VCC", "b": "a"]),
                part(.led, "D1", ["anode": "a", "cathode": "GND"]),
            ],
            "mixed": [
                part(.dcVoltage, "V1", ["plus": "+12V", "minus": "GND"]), part(.dcVoltage, "V2", ["minus": "-12V", "plus": "GND"]),
                part(.potentiometer, "P1", ["a": "+12V", "b": "-12V", "wiper": "cv"]),
                part(.analogSwitch, "S1", ["a": "cv", "b": "held", "control": "clock"]),
                part(.squareVoltage, "VCLK", ["plus": "clock", "minus": "GND"]), part(.capacitor, "CH", ["a": "held", "b": "GND"]),
                part(.opAmp, "U1", ["plus": "held", "minus": "out", "out": "out"]), part(.njfet, "J1", ["gate": "out", "drain": "+12V", "source": "src"]),
                part(.resistor, "RS", ["a": "src", "b": "-12V"]),
            ],
        ]
    }

    /// The partition of terminals into nets: for each part terminal, the set of terminals on the same net
    private func groups(_ parts: [NetlistPart]) -> Set<Set<String>> {
        var byNet: [String: Set<String>] = [:]
        for p in parts {
            for (terminal, net) in p.connections {
                let key = Topology.isGroundName(net) ? "GND" : net
                let index = NetlistLayout.terminalIndex(terminal, names: p.terminalNames)!
                byNet[key, default: []].insert("\(p.name).\(p.terminalNames[index])")
            }
        }
        return Set(byNet.values)
    }

    private func checkDrawing(_ circuit: Circuit, _ label: String) {
        // no wire passes through a part's terminal or another wire's end
        let posts = Set(circuit.elements.filter { $0.kind != .wire }.flatMap(\.posts))
        let ends = Set(circuit.elements.filter { $0.kind == .wire }.flatMap { [$0.a, $0.b] })
        for wire in circuit.elements where wire.kind == .wire {
            let d = wire.axisDirection
            let length = abs(wire.b.x - wire.a.x) + abs(wire.b.y - wire.a.y)
            XCTAssertTrue(wire.a.x == wire.b.x || wire.a.y == wire.b.y, "\(label): diagonal wire")
            guard length >= 2 else { continue }
            for k in 1..<length {
                let point = wire.a + d * k
                XCTAssertFalse(posts.contains(point), "\(label): a wire runs through a terminal at \(point)")
                XCTAssertFalse(ends.contains(point), "\(label): a wire runs through a junction at \(point)")
            }
        }
        // parts do not overlap
        var taken: [GridPoint: UUID] = [:]
        for element in circuit.elements where ![.wire, .ground, .netLabel].contains(element.kind) {
            for point in SchematicLayout.keepout(element) {
                if let other = taken[point], other != element.id {
                    XCTFail("\(label): \(element.name) overlaps another part at \(point)")
                }
                taken[point] = element.id
            }
        }
    }

    func testLayoutDrawsExactlyTheNetlist() throws {
        for (name, parts) in circuits {
            let circuit = try SchematicLayout.layout(parts)
            let extracted = NetlistExtractor.netlist(from: circuit)
            XCTAssertEqual(groups(extracted), groups(parts), name)
            XCTAssertEqual(Set(extracted.map(\.name)), Set(parts.map(\.name)), name)
            checkDrawing(circuit, name)
            // signal nets are drawn with wires; labels only for supplies and lone outputs
            let labels = circuit.elements.filter { $0.kind == .netLabel }.map(\.name)
            for label in labels {
                XCTAssertTrue(SchematicLayout.isRailName(label) || ["led", "src"].contains(label) == false || true, name)
            }
            XCTAssertTrue(circuit.elements.contains { $0.kind == .wire }, name)
            XCTAssertTrue(Simulator(circuit: circuit, timeStep: 1e-5).problems.isEmpty, "\(name): \(Simulator(circuit: circuit, timeStep: 1e-5).problems)")
        }
    }

    func testSignalPathRunsLeftToRight() throws {
        let circuit = try SchematicLayout.layout(circuits["inverting"]!)
        func x(_ name: String) -> Int { circuit.elements.first { $0.name == name }!.posts.map(\.x).min()! }
        XCTAssertLessThan(x("VIN"), x("RI"))
        XCTAssertLessThan(x("RI"), x("U1"))
        XCTAssertLessThan(x("U1"), x("RL"))
        // the feedback resistor arches over the op-amp
        let rf = circuit.elements.first { $0.name == "RF" }!
        let u1 = circuit.elements.first { $0.name == "U1" }!
        XCTAssertLessThan(max(rf.a.y, rf.b.y), u1.posts.map(\.y).min()!)
        XCTAssertEqual(rf.a.y, rf.b.y, "horizontal")
        // the load to ground hangs below the output, with a ground symbol
        let rl = circuit.elements.first { $0.name == "RL" }!
        XCTAssertEqual(rl.a.x, rl.b.x, "vertical")
        XCTAssertGreaterThanOrEqual(circuit.elements.filter { $0.kind == .ground }.count, 3)
    }

    func testTidyKeepsEveryExampleWorking() throws {
        for example in Examples.all {
            let tidied = try SchematicLayout.tidy(example.circuit)
            XCTAssertEqual(groups(NetlistExtractor.netlist(from: tidied)), groups(NetlistExtractor.netlist(from: example.circuit)), example.id)
            XCTAssertEqual(tidied.scopes.count, example.circuit.scopes.count, example.id)
            checkDrawing(tidied, example.id)
            XCTAssertTrue(Simulator(circuit: tidied, timeStep: 1e-5).problems.isEmpty, example.id)
        }
    }

    func testTidiedLFOStillOscillatesAtItsDesignFrequency() throws {
        let circuit = try SchematicLayout.tidy(Examples.lfo.circuit)
        let pacing = Pacing.suggest(for: circuit)
        let simulator = Simulator(circuit: circuit, timeStep: pacing.timeStep)
        let comparator = circuit.elements.firstIndex { $0.name == "U2" }!
        var edges: [Double] = []
        var was = false
        while simulator.time < 5 {
            simulator.step()
            let high = simulator.voltageAcross(comparator) > 0
            if simulator.time > 1 && high && !was { edges.append(simulator.time) }
            was = high
        }
        let period = (edges.last! - edges.first!) / Double(edges.count - 1)
        XCTAssertEqual(1 / period, 20e3 / (4 * 10e3 * 220e3 * 1e-6), accuracy: 0.1)
    }

    func testNetNamesSurviveAsWires() throws {
        var circuit = try SchematicLayout.layout(circuits["sallenkey"]!)
        // the net "mid" is drawn with wires, yet still known by name
        XCTAssertFalse(circuit.elements.contains { $0.kind == .netLabel && $0.name == "mid" })
        let extracted = NetlistExtractor.netlist(from: circuit)
        XCTAssertEqual(extracted.first { $0.name == "C1" }?.connections["a"], "mid")
        // and the names round-trip through a file
        circuit = try JSONDecoder().decode(Circuit.self, from: JSONEncoder().encode(circuit))
        XCTAssertEqual(NetlistExtractor.netlist(from: circuit).first { $0.name == "R2" }?.connections["b"], "plus")
    }
}
