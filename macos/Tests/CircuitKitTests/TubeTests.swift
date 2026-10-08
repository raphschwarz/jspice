import XCTest
@testable import CircuitKit

/// Tubes (Koren's equations) and transformers (coupled windings)
final class TubeTests: XCTestCase {
    func testTriodeCurrentAndSlopes() {
        let tube = TubeModel()   // the 12AX7
        // the same as ngspice evaluates the same equation at 200 V and −1.5 V
        XCTAssertEqual(tube.triode(vgk: -1.5, vpk: 200).current, 8.62539e-4, accuracy: 1e-9)
        // cut off below the plate and far below the grid
        XCTAssertEqual(tube.triode(vgk: -1, vpk: -5).current, 0)
        XCTAssertLessThan(tube.triode(vgk: -10, vpk: 200).current, 1e-7)
        for (vg, vp) in [(-1.5, 200.0), (-0.3, 80), (-3, 300), (0.5, 50), (-1, 5)] {
            let t = tube.triode(vgk: vg, vpk: vp)
            let d = 1e-6
            let dg = (tube.triode(vgk: vg + d, vpk: vp).current - tube.triode(vgk: vg - d, vpk: vp).current) / (2 * d)
            let dp = (tube.triode(vgk: vg, vpk: vp + d).current - tube.triode(vgk: vg, vpk: vp - d).current) / (2 * d)
            XCTAssertEqual(t.dGrid, dg, accuracy: 1e-6 * max(abs(dg), 1e-6), "gm at \(vg), \(vp)")
            XCTAssertEqual(t.dPlate, dp, accuracy: 1e-6 * max(abs(dp), 1e-6), "plate slope at \(vg), \(vp)")
        }
        // a 12AX7's gain, µ, is the ratio of its slopes
        let t = tube.triode(vgk: -1.5, vpk: 200)
        XCTAssertEqual(t.dGrid / t.dPlate, 100, accuracy: 15)
        // grid current once the grid is above the cathode
        XCTAssertEqual(tube.grid(vgk: -0.5).current, 0)
        XCTAssertEqual(tube.grid(vgk: 1).current, 1.0 / 2000, accuracy: 1e-12)
    }

    func testPentodeCurrentsAndSlopes() {
        let el = ElementKind.pentode.models[0].values
        let tube = TubeModel(mu: el["mu"]!, ex: el["ex"]!, kg1: el["kg1"]!, kg2: el["kg2"]!, kp: el["kp"]!, kvb: el["kvb"]!, rgi: el["rgi"]!)
        // a 6L6GC at 250 V on plate and screen and −14 V on the grid: about 70 mA, its screen a few mA
        let t = tube.pentode(vgk: -14, vsk: 250, vpk: 250)
        XCTAssertEqual(t.plate, 0.075, accuracy: 0.015)
        XCTAssertGreaterThan(t.screen, 1e-3)
        XCTAssertLessThan(t.screen, 15e-3)
        // a pentode's plate barely matters once above the knee
        XCTAssertEqual(tube.pentode(vgk: -14, vsk: 250, vpk: 400).plate / t.plate, 1, accuracy: 0.03)
        for (vg, vs, vp) in [(-14.0, 250.0, 250.0), (-5, 200, 50), (-20, 300, 400), (-8, 250, 10)] {
            let p = tube.pentode(vgk: vg, vsk: vs, vpk: vp)
            let d = 1e-5
            func plate(_ g: Double, _ s: Double, _ q: Double) -> Double { tube.pentode(vgk: g, vsk: s, vpk: q).plate }
            func screen(_ g: Double, _ s: Double) -> Double { tube.pentode(vgk: g, vsk: s, vpk: vp).screen }
            XCTAssertEqual(p.plateGrid, (plate(vg + d, vs, vp) - plate(vg - d, vs, vp)) / (2 * d), accuracy: 1e-5 * max(abs(p.plateGrid), 1e-6))
            XCTAssertEqual(p.plateScreen, (plate(vg, vs + d, vp) - plate(vg, vs - d, vp)) / (2 * d), accuracy: 1e-5 * max(abs(p.plateScreen), 1e-6))
            XCTAssertEqual(p.platePlate, (plate(vg, vs, vp + d) - plate(vg, vs, vp - d)) / (2 * d), accuracy: 1e-5 * max(abs(p.platePlate), 1e-7))
            XCTAssertEqual(p.screenGrid, (screen(vg + d, vs) - screen(vg - d, vs)) / (2 * d), accuracy: 1e-5 * max(abs(p.screenGrid), 1e-7))
            XCTAssertEqual(p.screenScreen, (screen(vg, vs + d) - screen(vg, vs - d)) / (2 * d), accuracy: 1e-5 * max(abs(p.screenScreen), 1e-8))
        }
    }

    private func value(_ simulator: Simulator, _ circuit: Circuit, _ part: String, _ terminal: String) throws -> Double {
        let index = try XCTUnwrap(circuit.elements.firstIndex { $0.name == part })
        let k = try XCTUnwrap(circuit.elements[index].kind.terminalNames.firstIndex(of: terminal))
        return simulator.terminalVoltages(index)[k]
    }

    func testTriodeStageAmplifies() throws {
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .dcVoltage, name: "VB", params: ["voltage": 250], connections: ["plus": "bplus", "minus": "GND"]),
            NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": 0.05, "frequency": 1000], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .capacitor, name: "CIN", params: ["capacitance": 100e-9], connections: ["a": "in", "b": "grid"]),
            NetlistPart(kind: .resistor, name: "RG", params: ["resistance": 1e6], connections: ["a": "grid", "b": "GND"]),
            NetlistPart(kind: .triode, name: "V1", connections: ["grid": "grid", "plate": "plate", "cathode": "cath"]),
            NetlistPart(kind: .resistor, name: "RP", params: ["resistance": 100_000], connections: ["a": "bplus", "b": "plate"]),
            NetlistPart(kind: .resistor, name: "RK", params: ["resistance": 1500], connections: ["a": "cath", "b": "GND"]),
            NetlistPart(kind: .capacitor, name: "CK", params: ["capacitance": 22e-6], connections: ["a": "cath", "b": "GND"]),
        ])
        // the electrode capacitances are put in as parts of their own
        let flat = circuit.flattened()
        XCTAssertEqual(flat.elements.filter { $0.kind == .capacitor }.count, 5)
        XCTAssertEqual(flat.flattened().elements.count, flat.elements.count, "flattening twice adds nothing")
        let index = try XCTUnwrap(circuit.elements.firstIndex { $0.kind == .acVoltage })
        let simulator = Simulator.settled(circuit, holding: index, duration: 1)
        XCTAssertTrue(simulator.problems.isEmpty, "\(simulator.problems)")
        // biased about a volt and a half up its cathode, the plate well inside its swing
        let cathode = try value(simulator, circuit, "V1", "cathode")
        let plate = try value(simulator, circuit, "V1", "plate")
        XCTAssertEqual(cathode, 1.2, accuracy: 0.5)
        XCTAssertGreaterThan(plate, 100)
        XCTAssertLessThan(plate, 200)
        // a 12AX7 stage with its cathode bypassed: a gain of about 60, inverting
        let model = try XCTUnwrap(simulator.smallSignalModel())
        let node = simulator.nodes(of: try XCTUnwrap(circuit.elements.firstIndex { $0.name == "V1" }))[1]
        let gain = try XCTUnwrap(model.solve(input: index, frequencies: [1000])?.first?[node])
        XCTAssertEqual(gain.magnitude, 60, accuracy: 15)
        XCTAssertEqual(abs(gain.phase * 180 / .pi), 180, accuracy: 5)
    }

    func testTransformerSteps() throws {
        // 1 : 2, tightly coupled, windings of no resistance, into 1 kΩ: twice the voltage, twice the current at the primary
        var circuit = try SchematicLayout.layout([
            NetlistPart(kind: .acVoltage, name: "V1", params: ["amplitude": 1, "frequency": 1000], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "RS", params: ["resistance": 1], connections: ["a": "in", "b": "p"]),
            NetlistPart(kind: .transformer, name: "T1", params: ["inductance": 10, "ratio": 2, "coupling": 0.99999, "rp": 0, "rs": 0],
                        connections: ["p1": "p", "p2": "GND", "s1": "s", "s2": "GND"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 1000], connections: ["a": "s", "b": "GND"]),
        ])
        circuit.scopes = []
        let simulator = Simulator(circuit: circuit, timeStep: 1e-6)
        let rl = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "RL" })
        let rs = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "RS" })
        var secondary = 0.0, primary = 0.0
        while simulator.time < 0.02 {
            simulator.step()
            if simulator.time > 0.01 {
                secondary = max(secondary, abs(simulator.voltageAcross(rl)))
                primary = max(primary, abs(simulator.current(rs)))
            }
        }
        // the 1 Ω source resistance drops a little of the 1 V
        XCTAssertEqual(secondary, 2 * 1000 / (1000 + 4), accuracy: 0.01)
        XCTAssertEqual(primary, 2 * secondary / 1000, accuracy: 1e-4)
    }

    func testTransformerBlocksDCAndMatchesCoupledInductors() throws {
        // a DC step into the primary: the secondary sees a pulse that dies away as the magnetising current builds up,
        // with time constant Lm / R on the primary side: L k² / R
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 10], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 100], connections: ["a": "in", "b": "p"]),
            NetlistPart(kind: .transformer, name: "T1", params: ["inductance": 1, "ratio": 1, "coupling": 0.999, "rp": 0, "rs": 0],
                        connections: ["p1": "p", "p2": "GND", "s1": "s", "s2": "GND"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 1e6], connections: ["a": "s", "b": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1e-5)
        let t1 = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "T1" })
        simulator.step()
        XCTAssertEqual(abs(simulator.voltageAcross(t1)), 10, accuracy: 0.3)
        while simulator.time < 0.01 { simulator.step() }
        // after one time constant (10 ms): e⁻¹ of it
        XCTAssertEqual(abs(simulator.voltageAcross(t1)), 10 * exp(-1), accuracy: 0.1)
        while simulator.time < 0.1 { simulator.step() }
        XCTAssertLessThan(abs(simulator.voltageAcross(t1)), 1e-3)
    }

    func testTubeAmpExamplePlays() throws {
        let example = try XCTUnwrap(Examples.all.first { $0.id == "tube-amp" })
        let speaker = try XCTUnwrap(example.circuit.elements.firstIndex { $0.kind == .speaker })
        let result = AudioRender.render(example.circuit, output: speaker, duration: 0.5, sampleRate: 24_000, oversampling: 2)
        XCTAssertTrue(result.problems.isEmpty, "\(result.problems)")
        XCTAssertEqual(result.samples.count, 12_000)
        XCTAssertGreaterThan(result.peak, 0.05)
        XCTAssertFalse(result.samples.contains { !$0.isFinite })
    }
}
