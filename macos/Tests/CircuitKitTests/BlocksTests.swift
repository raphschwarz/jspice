import XCTest
@testable import CircuitKit

/// Blocks: circuits used as parts. A block must simulate exactly as its parts drawn in its place would.
final class BlocksTests: XCTestCase {
    private func port(_ name: String, _ net: String, right: Bool) -> NetlistPart {
        NetlistPart(kind: .port, name: name, params: ["side": right ? 2 : 1], connections: ["net": net])
    }

    private func resistor(_ name: String, _ a: String, _ b: String, _ ohms: Double) -> NetlistPart {
        NetlistPart(kind: .resistor, name: name, params: ["resistance": ohms], connections: ["a": a, "b": b])
    }

    private func capacitor(_ name: String, _ a: String, _ b: String, _ farads: Double) -> NetlistPart {
        NetlistPart(kind: .capacitor, name: name, params: ["capacitance": farads], connections: ["a": a, "b": b])
    }

    private func use(_ block: BlockDefinition, _ name: String, _ connections: [String: String]) -> NetlistPart {
        var part = NetlistPart(kind: .block, name: name, connections: connections)
        part.block = block
        return part
    }

    private func source(_ net: String, volts: Double = 1) -> NetlistPart {
        NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": volts, "frequency": 200],
                    connections: ["plus": net, "minus": "GND"])
    }

    /// An RC low-pass, 1 kΩ and 1 µF: in on the left, out on the right
    private func lowPass() throws -> BlockDefinition {
        try SchematicLayout.layout([
            port("in", "in", right: false), resistor("R1", "in", "out", 1000), capacitor("C1", "out", "GND", 1e-6),
            port("out", "out", right: true),
        ]).asBlock(named: "RC")
    }

    /// Steps both circuits and compares the voltage at a net in each, step by step
    private func assertSameWaveform(_ a: Circuit, _ netA: (part: String, terminal: String), _ b: Circuit,
                                    _ netB: (part: String, terminal: String), steps: Int = 2000,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        func reader(_ circuit: Circuit, _ net: (part: String, terminal: String)) throws -> (Simulator) -> Double {
            let index = try XCTUnwrap(circuit.elements.firstIndex { $0.name == net.part }, file: file, line: line)
            let terminal = try XCTUnwrap(circuit.elements[index].terminalNames.firstIndex(of: net.terminal), file: file, line: line)
            return { $0.terminalVoltage(index, terminal) }
        }
        let simA = Simulator(circuit: a, timeStep: 1e-5)
        let simB = Simulator(circuit: b, timeStep: 1e-5)
        let readA = try reader(a, netA), readB = try reader(b, netB)
        XCTAssertTrue(simA.problems.isEmpty, "\(simA.problems)", file: file, line: line)
        var largest = 0.0, worst = 0.0
        for _ in 0..<steps {
            simA.step()
            simB.step()
            worst = max(worst, abs(readA(simA) - readB(simB)))
            largest = max(largest, abs(readB(simB)))
        }
        XCTAssertGreaterThan(largest, 0.01, "the waveform should move", file: file, line: line)
        XCTAssertLessThan(worst, 1e-9, file: file, line: line)
    }

    func testABlockSimulatesAsItsPartsDrawnInPlace() throws {
        let rc = try lowPass()
        XCTAssertEqual(rc.terminalNames, ["in", "out"])
        let withBlocks = try SchematicLayout.layout([
            source("in"), use(rc, "X1", ["in": "in", "out": "mid"]), use(rc, "X2", ["in": "mid", "out": "out"]),
            resistor("RL", "out", "GND", 10_000),
        ])
        let drawnOut = try SchematicLayout.layout([
            source("in"), resistor("R1", "in", "mid", 1000), capacitor("C1", "mid", "GND", 1e-6),
            resistor("R2", "mid", "out", 1000), capacitor("C2", "out", "GND", 1e-6), resistor("RL", "out", "GND", 10_000),
        ])
        try assertSameWaveform(withBlocks, ("RL", "a"), drawnOut, ("RL", "a"))
        try assertSameWaveform(withBlocks, ("X2", "in"), drawnOut, ("R2", "a"))
        // the parts inside have names of their own in the simulation, and the same ids each time
        let flat = withBlocks.flattened()
        XCTAssertTrue(flat.elements.contains { $0.name == "X1.R1" } && flat.elements.contains { $0.name == "X2.C1" })
        XCTAssertEqual(flat.elements.map(\.id), withBlocks.flattened().elements.map(\.id))
        XCTAssertEqual(Set(flat.elements.map(\.id)).count, flat.elements.count, "ids are unique")
        XCTAssertEqual(Array(flat.elements.prefix(withBlocks.elements.count)), withBlocks.elements, "the circuit's own parts come first")
    }

    func testNetLabelsInsideABlockAreItsOwn() throws {
        // the block joins its resistor and capacitor through a label "node"; two copies must not join at it
        var inner = try SchematicLayout.layout([
            port("in", "in", right: false), resistor("R1", "in", "x", 1000), capacitor("C1", "y", "GND", 1e-6),
            port("out", "y", right: true),
        ])
        for (name, net) in [("R1", "b"), ("C1", "a")] {
            let element = try XCTUnwrap(inner.elements.first { $0.name == name })
            let index = try XCTUnwrap(element.terminalNames.firstIndex(of: net))
            let post = element.posts[index]
            inner.elements.append(Element(kind: .netLabel, name: "node", a: post + GridPoint(0, -3), b: post + GridPoint(1, -3)))
            inner.elements.append(Element(kind: .wire, a: post, b: post + GridPoint(0, -3)))
        }
        let block = inner.asBlock(named: "Labelled")
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .dcVoltage, name: "VA", params: ["voltage": 5], connections: ["plus": "a", "minus": "GND"]),
            use(block, "X1", ["in": "a", "out": "outa"]),
            use(block, "X2", ["in": "GND", "out": "outb"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1e-4)
        for _ in 0..<1000 { simulator.step() }
        let x1 = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "X1" })
        let x2 = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "X2" })
        XCTAssertEqual(simulator.terminalVoltage(x1, 1), 5, accuracy: 0.01, "X1 charges through its own label")
        XCTAssertEqual(simulator.terminalVoltage(x2, 1), 0, accuracy: 0.01, "X2's label is not X1's")
    }

    func testBlocksInsideBlocks() throws {
        let rc = try lowPass()
        let twice = try SchematicLayout.layout([
            port("in", "in", right: false), use(rc, "A", ["in": "in", "out": "mid"]), use(rc, "B", ["in": "mid", "out": "out"]),
            port("out", "out", right: true),
        ]).asBlock(named: "RC twice")
        XCTAssertTrue(twice.uses("RC"))
        XCTAssertFalse(rc.uses("RC twice"))
        let nested = try SchematicLayout.layout([source("in"), use(twice, "X1", ["in": "in", "out": "out"]), resistor("RL", "out", "GND", 10_000)])
        let drawnOut = try SchematicLayout.layout([
            source("in"), resistor("R1", "in", "mid", 1000), capacitor("C1", "mid", "GND", 1e-6),
            resistor("R2", "mid", "out", 1000), capacitor("C2", "out", "GND", 1e-6), resistor("RL", "out", "GND", 10_000),
        ])
        try assertSameWaveform(nested, ("RL", "a"), drawnOut, ("RL", "a"))
        XCTAssertTrue(nested.flattened().elements.contains { $0.name == "X1.B.C1" })
    }

    func testPortsArePinsInOrder() throws {
        // ports set to a side, and ports placed by where they are drawn; each side from the top
        var circuit = Circuit()
        circuit.elements = [
            Element(kind: .port, name: "b", a: GridPoint(0, 4), b: GridPoint(1, 4)),
            Element(kind: .port, name: "a", a: GridPoint(0, 0), b: GridPoint(1, 0)),
            Element(kind: .port, name: "q", a: GridPoint(20, 2), b: GridPoint(21, 2)),
            Element(kind: .port, name: "forced", a: GridPoint(20, 8), b: GridPoint(21, 8), params: ["side": 1]),
            Element(kind: .resistor, a: GridPoint(2, 0), b: GridPoint(18, 0)),
        ]
        let block = circuit.asBlock(named: "Pins")
        XCTAssertEqual(block.terminalNames, ["a", "b", "forced", "q"])
        let package = block.chipPackage
        XCTAssertEqual(package.pinPlaces.map(\.second), [true, true, true, false], "inputs on one side, outputs on the other")
        XCTAssertEqual(package.pinPlaces.map(\.offset), [0, 1, 2, 0])
        XCTAssertEqual(package.length, 2)
        // the part's pins follow
        var part = Element(kind: .block, name: "X1", a: GridPoint(10, 10), b: GridPoint(10, 12))
        part.block = block
        XCTAssertEqual(part.terminalNames, ["a", "b", "forced", "q"])
        XCTAssertEqual(part.posts.count, 4)
        XCTAssertEqual(Set(part.posts).count, 4)
        XCTAssertEqual(NetlistLayout.terminalIndex("Q", of: part), 3)
    }

    func testABlockIsSavedWithTheCircuit() throws {
        let rc = try lowPass()
        let circuit = try SchematicLayout.layout([source("in"), use(rc, "X1", ["in": "in", "out": "out"])])
        let data = try JSONEncoder().encode(circuit)
        let decoded = try JSONDecoder().decode(Circuit.self, from: data)
        XCTAssertEqual(decoded, circuit)
        XCTAssertEqual(decoded.elements.first { $0.kind == .block }?.block?.name, "RC")
        // and in the block library
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try BlockLibrary.save(rc, in: folder)
        try BlockLibrary.save(try lowPass().circuit.asBlock(named: "Other/Name"), in: folder)
        XCTAssertEqual(BlockLibrary.all(in: folder).map(\.name), ["Other/Name", "RC"])
        XCTAssertEqual(BlockLibrary.block(named: "rc", in: folder), rc)
        try BlockLibrary.delete(named: "RC", in: folder)
        XCTAssertEqual(BlockLibrary.all(in: folder).map(\.name), ["Other/Name"])
    }

    func testAKnobInsideABlockTurnsWithoutRestarting() throws {
        let block = Examples.toneStage
        let circuit = try SchematicLayout.layout([source("in"), use(block, "X1", ["in": "in", "out": "out"])])
        let simulator = Simulator(circuit: circuit, timeStep: 1e-5)
        for _ in 0..<500 { simulator.step() }
        let time = simulator.time
        var turned = circuit
        let x1 = try XCTUnwrap(turned.elements.firstIndex { $0.kind == .block })
        let pot = try XCTUnwrap(turned.elements[x1].block?.circuit.elements.firstIndex { $0.kind == .potentiometer })
        turned.elements[x1].block?.circuit.elements[pot][param: "position"] = 0.9
        XCTAssertTrue(simulator.updateParameters(turned), "a knob inside a block is a parameter like any other")
        XCTAssertEqual(simulator.time, time)
        XCTAssertNotNil(simulator.flatIndex(of: UUID.inBlock(circuit.elements[x1].id, part: block.circuit.elements[pot].id)))
    }

    func testSmallSignalAnalysisSeesInsideBlocks() throws {
        let rc = try lowPass()
        let circuit = try SchematicLayout.layout([source("in"), use(rc, "X1", ["in": "in", "out": "out"]), resistor("RL", "out", "GND", 1e9)])
        let input = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "VIN" })
        let block = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "X1" })
        let simulator = Simulator.settled(circuit, holding: input)
        let model = try XCTUnwrap(simulator.smallSignalModel())
        let corner = 1 / (2 * Double.pi * 1000 * 1e-6)
        let out = simulator.nodes(of: block)[1]
        let value = try XCTUnwrap(model.response(input: input, plus: out, minus: 0, frequencies: [corner])?.first)
        XCTAssertEqual(20 * log10(value.magnitude), -3.0103, accuracy: 0.001)
    }

    func testTheBlocksExampleRuns() throws {
        let example = try XCTUnwrap(Examples.example("blocks"))
        let blocks = example.circuit.elements.filter { $0.kind == .block }
        XCTAssertEqual(blocks.count, 2)
        let simulator = Simulator(circuit: example.circuit, timeStep: 1 / 48_000)
        XCTAssertTrue(simulator.problems.isEmpty, "\(simulator.problems)")
        let speaker = try XCTUnwrap(example.circuit.elements.firstIndex { $0.kind == .speaker })
        var swing = (low: 0.0, high: 0.0)
        for step in 0..<9600 {
            simulator.step()
            guard step > 4800 else { continue }
            let v = simulator.voltageAcross(speaker)
            swing = (min(swing.low, v), max(swing.high, v))
        }
        // a 110 Hz square wave of ±1 V, its edges rounded off but its swing kept
        XCTAssertGreaterThan(swing.high - swing.low, 1)
        XCTAssertLessThan(swing.high - swing.low, 2.05)
        // the two copies in series, at their own settings (530 Hz and 265 Hz): two poles, 12 dB an octave well above
        let source = try XCTUnwrap(example.circuit.elements.firstIndex { $0.name == "VIN" })
        let settled = Simulator.settled(example.circuit, holding: source)
        let model = try XCTUnwrap(settled.smallSignalModel())
        let out = settled.nodes(of: speaker)[0]
        let response = try XCTUnwrap(model.response(input: source, plus: out, minus: 0, frequencies: [20, 5000, 10_000]))
        XCTAssertEqual(response[0].magnitude, 1, accuracy: 0.01)
        let expected = 1 / ((1 + pow(5000 / 530.5, 2)).squareRoot() * (1 + pow(5000 / 265.3, 2)).squareRoot())
        XCTAssertEqual(response[1].magnitude, expected, accuracy: expected * 0.02)
        XCTAssertEqual(response[1].magnitude / response[2].magnitude, 4, accuracy: 0.1)
        XCTAssertEqual(simulator.convergenceFailures, 0)
    }
}
