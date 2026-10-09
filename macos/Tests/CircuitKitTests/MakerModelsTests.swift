import XCTest
@testable import CircuitKit

/// Makers' model files: a subcircuit imported as a block with its provenance, and an op-amp model measured for its
/// datasheet's figures
final class MakerModelsTests: XCTestCase {
    /// A test model file (not a maker's): a single-pole op-amp whose figures follow from its values. Gain 1 mS × 100 MΩ
    /// = 100 dB with its pole at 1 Hz, so unity gain at 100 kHz with 90° of margin; the input stage's current limited to
    /// 1.59155 mA into 1.59155 nF, 1 V/µs; a 1 mV offset; 1 mA from the supplies; the output 1 V short of each.
    static let file = """
    * TESTAMP - a test op-amp model, not a maker's
    * Rev. 1, for JSpice's tests
    *$
    .subckt TESTAMP inp inn vcc vee out
    G1 0 n1 VALUE={1m*max(min(V(inp,inn)+1m, 1.59155), -1.59155)}
    R1 n1 0 100meg
    C1 n1 0 1.59155n
    E1 out 0 VALUE={max(min(V(n1), V(vcc)-1), V(vee)+1)}
    IQ vcc vee DC 1m
    .ends TESTAMP
    .subckt OTHER a b
    R1 a b 1k
    .ends
    .end
    """

    func testASubcircuitBecomesABlockWithItsSource() throws {
        let data = Data(Self.file.utf8)
        XCTAssertEqual(MakerModels.subcircuits(in: Self.file).map(\.name), ["TESTAMP", "OTHER"])
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        let (block, warnings) = try MakerModels.block(from: data, file: "testamp.lib", now: when)
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
        XCTAssertEqual(block.name, "TESTAMP")
        XCTAssertEqual(block.terminalNames.sorted(), ["inn", "inp", "out", "vcc", "vee"])
        let source = try XCTUnwrap(block.source)
        XCTAssertEqual(source.pins, ["inp", "inn", "vcc", "vee", "out"], "the file's order")
        XCTAssertEqual(source.header, ["TESTAMP - a test op-amp model, not a maker's", "Rev. 1, for JSpice's tests"])
        XCTAssertEqual(source.sha256, MakerModels.sha256(data))
        XCTAssertEqual(source.sha256.count, 64)
        XCTAssertEqual(source.imported, when)
        // the source is kept with the block, and a block saved before there were sources still reads
        let decoded = try JSONDecoder().decode(BlockDefinition.self, from: JSONEncoder().encode(block))
        XCTAssertEqual(decoded.source, source)
        let plain = try JSONDecoder().decode(BlockDefinition.self, from: JSONEncoder().encode(BlockDefinition(name: "x", circuit: block.circuit)))
        XCTAssertNil(plain.source)
        // another subcircuit by name, and one the file does not have
        XCTAssertEqual(try MakerModels.block(from: data, file: "testamp.lib", subcircuit: "other").block.source?.pins, ["a", "b"])
        XCTAssertThrowsError(try MakerModels.block(from: data, file: "testamp.lib", subcircuit: "NE5532"))
        XCTAssertThrowsError(try MakerModels.block(from: Data("* nothing\nR1 a b 1k\n".utf8), file: "x.lib"))
        // a deck that uses the block says where it came from
        var part = NetlistPart(kind: .block, name: "U1", connections: ["inp": "a", "inn": "out", "vcc": "p", "vee": "n", "out": "out"])
        part.block = block
        let deck = SpiceNetlist.export(try SchematicLayout.layout([part]))
        XCTAssertTrue(deck.contains("from testamp.lib, SHA-256 \(source.sha256)"), deck)
    }

    /// A built-in op-amp running a maker's model in its place: the model on two ideal supplies, the op-amp's own
    /// equations left out, exported as the model's subcircuit
    func testAnOpAmpRunsItsMakersModel() throws {
        let (block, _) = try MakerModels.block(from: Data(Self.file.utf8), file: "testamp.lib")
        XCTAssertEqual(Set(try XCTUnwrap(MakerModels.opAmpRoles(block))), Set(0..<5))
        func stage(_ volts: Double, maker: Bool, supply: Double = 5) throws -> (circuit: Circuit, out: Double) {
            var u = NetlistPart(kind: .opAmp, name: "U1", params: ["makerModel": maker ? 1 : 0, "supply": supply],
                                connections: ["plus": "in", "minus": "fb", "out": "out"])
            u.block = block
            let circuit = try SchematicLayout.layout([
                u,
                NetlistPart(kind: .dcVoltage, name: "VI", params: ["voltage": volts], connections: ["plus": "in", "minus": "GND"]),
                NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 10_000], connections: ["a": "out", "b": "fb"]),
                NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 10_000], connections: ["a": "fb", "b": "GND"]),
            ])
            let index = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "U1" })
            let simulator = Simulator.settled(circuit, holding: nil, duration: 0.01)
            XCTAssertFalse(simulator.isFailed, "\(simulator.problems)")
            return (circuit, simulator.terminalVoltages(index)[2])
        }
        // a gain of 2, with the model's 1 mV of offset
        let (circuit, out) = try stage(1, maker: true)
        XCTAssertTrue(circuit.elements.first { $0.name == "U1" }?.runsMakerModel ?? false)
        XCTAssertEqual(out, 2.002, accuracy: 1e-3)
        let flat = circuit.flattened()
        XCTAssertEqual(flat.elements.first { $0.name == "U1.VCC" }?[param: "voltage"], 5)
        XCTAssertEqual(flat.elements.first { $0.name == "U1.VEE" }?[param: "voltage"], -5)
        XCTAssertTrue(flat.elements.contains { $0.name == "U1.G1" }, "the model's parts are in the op-amp's place")
        // driven past its supply: the model's output stops a volt short of its 5 V, where JSpice's own goes on to 6 V
        XCTAssertEqual(try stage(3, maker: true).out, 4, accuracy: 1e-3)
        XCTAssertEqual(try stage(3, maker: false).out, 6, accuracy: 1e-3)
        // the supplies by default: ± the swing and a volt and a half, rounded, or a single supply (a pedal's 9 V)
        XCTAssertEqual(MakerModels.rails(midpoint: 0, supply: 0, limit: 13.5).positive, 15)
        XCTAssertEqual(MakerModels.rails(midpoint: 4.5, supply: 0, limit: 4).positive, 9)
        XCTAssertEqual(MakerModels.rails(midpoint: 4.5, supply: 0, limit: 4).negative, 0)
        // exported as the model's subcircuit on its supplies
        let deck = SpiceNetlist.export(circuit)
        XCTAssertTrue(deck.contains(".subckt TESTAMP"), deck)
        XCTAssertTrue(deck.contains("V_X_U1_vcc X_U1_vcc 0 5"), deck)
        XCTAssertTrue(deck.contains("X_X_U1 "), deck)
    }

    func testAnOpAmpModelsFigures() throws {
        let (block, _) = try MakerModels.block(from: Data(Self.file.utf8), file: "testamp.lib")
        let pins = try XCTUnwrap(block.source?.pins)
        let f = try MakerModels.measureOpAmp(block, pins: pins)
        print(String(format: "TESTAMP: offset %.4f mV, supply %.4f mA, gain %.3f dB, unity %.4g Hz, margin %.2f°, slew %.4f/%.4f V/µs, swing %.3f/%.3f V",
                     f.offset * 1e3, f.supplyCurrent * 1e3, f.openLoopGain, f.unityGain ?? 0, f.phaseMargin ?? 0,
                     (f.slewRise ?? 0) / 1e6, (f.slewFall ?? 0) / 1e6, f.swingHigh, f.swingLow))
        XCTAssertEqual(f.offset, 1e-3, accuracy: 1e-6)
        XCTAssertEqual(f.supplyCurrent, 1e-3, accuracy: 1e-7)
        // 100 dB less the pole's 0.043 dB at 0.1 Hz
        XCTAssertEqual(f.openLoopGain, 100 - 10 * log10(1.01), accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(f.unityGain), 1e5, accuracy: 1e3)
        // 40 dB at 1 kHz: 100 kHz
        XCTAssertEqual(try XCTUnwrap(f.gainBandwidth), 1e5, accuracy: 1e3)
        XCTAssertEqual(try XCTUnwrap(f.phaseMargin), 90, accuracy: 0.5)
        // slew limited to 1 V/µs up to 3.41 V, then the last 0.59 V to 90 % in an exponential: 8 V in 8.148 µs
        XCTAssertEqual(try XCTUnwrap(f.slewRise) / 1e6, 0.9818, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(f.slewFall) / 1e6, 0.9818, accuracy: 0.01)
        XCTAssertEqual(f.swingHigh, 14, accuracy: 1e-3)
        XCTAssertEqual(f.swingLow, -14, accuracy: 1e-3)
    }
}
