import XCTest
@testable import CircuitKit

/// Loop gain at a loop probe (Middlebrook's double injection), stability margins, and impedance against frequency, each
/// against what its circuit works out to on paper
final class LoopGainTests: XCTestCase {
    /// A circuit from SPICE lines and parts, with a loop probe LP1 from `from` (the side that drives) to `to`
    private func circuit(_ netlist: String, parts: [NetlistPart] = [], probe: (from: String, to: String)? = nil) throws -> Circuit {
        var all = SpiceNetlist.parse(netlist).parts + parts
        if let probe { all.append(NetlistPart(kind: .loopProbe, name: "LP1", params: [:], connections: ["in": probe.from, "out": probe.to])) }
        return try SchematicLayout.layout(all)
    }

    private func linearised(_ circuit: Circuit) throws -> (simulator: Simulator, model: SmallSignalModel) {
        let simulator = Simulator.settled(circuit, holding: nil, duration: 1e-3)
        XCTAssertFalse(simulator.isFailed, "\(simulator.problems)")
        return (simulator, try XCTUnwrap(simulator.smallSignalModel()))
    }

    private func index(_ circuit: Circuit, _ name: String) throws -> Int {
        try XCTUnwrap(circuit.elements.firstIndex { $0.name == name }, name)
    }

    /// A transconductance driving its own input, with resistors on both sides of the break: T = gm (Rx ‖ Ry) = 1.5,
    /// where a voltage injection alone reads gm Rx + Rx / Ry = 2.33 and a current injection alone gm Ry + Ry / Rx = 9
    func testDoubleInjectionGivesTheReturnRatioWithLoadingOnBothSides() throws {
        let c = try circuit("""
        gm loop
        G1 x 0 y 0 2m
        RX x 0 1k
        RY y 0 3k
        """, probe: ("x", "y"))
        let model = try linearised(c).model
        let probe = try index(c, "LP1")
        XCTAssertTrue(model.canBreakLoop(at: probe))
        let t = try XCTUnwrap(model.loopGain(probe: probe, frequencies: [10, 1000, 100_000]))
        for value in t {
            XCTAssertEqual(value.re, 1.5, accuracy: 1e-6)
            XCTAssertEqual(value.im, 0, accuracy: 1e-6)
        }
        // the probe is a link in the built circuit, and 0 V from in to out in SPICE
        let deck = SpiceNetlist.export(c)
        XCTAssertTrue(deck.contains("V_LP1 ") && deck.contains("DC 0  ; loop probe, driven from in to out"), deck)
    }

    /// An op-amp (open-loop gain 10⁵, 100 kHz) closing its loop through two RC sections (1 kΩ, 1 nF): T = A(s) H(s), with
    /// A = ωu / (s + ωu / A0) and H = 1 / (s²τ² + 3sτ + 1). Its crossover, phase margin and gain margin are found where
    /// the formula puts them: 66.6 kHz, 33.3° and 13.6 dB.
    func testOpAmpLoopGainAndMarginsMatchTheFormula() throws {
        let opAmp = NetlistPart(kind: .opAmp, name: "U1", params: ["gain": 1e5, "gbw": 1e5, "limit": 15, "slewRate": 0, "offset": 0],
                                connections: ["minus": "fb", "plus": "0", "out": "out"])
        let c = try circuit("""
        op-amp and two RC sections
        R1 y n1 1k
        C1 n1 0 1n
        R2 n1 fb 1k
        C2 fb 0 1n
        """, parts: [opAmp], probe: ("out", "y"))
        let model = try linearised(c).model
        let probe = try index(c, "LP1")
        let frequencies = FrequencySweep.logarithmic(from: 100, to: 10e6, pointsPerDecade: 50)
        let t = try XCTUnwrap(model.loopGain(probe: probe, frequencies: frequencies))

        let (a0, wu, tau) = (1e5, 2 * Double.pi * 1e5, 1e-6)
        func expected(_ f: Double) -> Complex {
            let s = Complex(0, 2 * .pi * f)
            let a = Complex(wu) / (s + Complex(wu / a0))
            let h = Complex(1) / (Complex(tau * tau) * s * s + Complex(3 * tau) * s + Complex(1))
            return a * h
        }
        /// The phase of T, continuous: the op-amp's lag (0 to 90°) and the sections' (0 to 180°)
        func phase(_ f: Double) -> Double {
            let w = 2 * Double.pi * f
            return -(atan2(w, wu / a0) + atan2(3 * w * tau, 1 - w * w * tau * tau)) * 180 / .pi
        }
        for (k, f) in frequencies.enumerated() {
            let e = expected(f)
            XCTAssertEqual(t[k].re, e.re, accuracy: 1e-6 * e.magnitude, "\(f) Hz")
            XCTAssertEqual(t[k].im, e.im, accuracy: 1e-6 * e.magnitude, "\(f) Hz")
        }
        /// Where a falling function of the frequency crosses zero, by bisection on the log scale
        func root(_ g: (Double) -> Double) -> Double {
            var (lo, hi) = (100.0, 10e6)
            for _ in 0..<100 {
                let mid = (lo * hi).squareRoot()
                if g(mid) > 0 { lo = mid } else { hi = mid }
            }
            return lo
        }
        let crossover = root { expected($0).magnitude - 1 }
        let phaseCrossover = root { phase($0) + 180 }
        let margins = StabilityMargins(frequencies: frequencies, loopGain: t)
        XCTAssertEqual(margins.unityCrossings.count, 1)
        XCTAssertEqual(try XCTUnwrap(margins.crossover), crossover, accuracy: 0.003 * crossover)
        XCTAssertEqual(try XCTUnwrap(margins.phaseMargin), 180 + phase(crossover), accuracy: 0.2)
        XCTAssertEqual(try XCTUnwrap(margins.gainMargin), -20 * log10(expected(phaseCrossover).magnitude), accuracy: 0.05)
        print(String(format: "Op-amp loop: crossover %.4g Hz (formula %.4g), phase margin %.2f° (%.2f°), gain margin %.2f dB (%.2f dB)",
                     margins.crossover ?? 0, crossover, margins.phaseMargin ?? 0, 180 + phase(crossover), margins.gainMargin ?? 0,
                     -20 * log10(expected(phaseCrossover).magnitude)))

        // only a loop probe (or a 0 V source) can break a loop
        XCTAssertFalse(model.canBreakLoop(at: try index(c, "R1")))
        XCTAssertNil(model.loopGain(probe: try index(c, "R1"), frequencies: [1000]))
    }

    /// The example: a TL072 at a gain of 2 driving 100 nF through 100 Ω, its feedback from the cable, crosses over at
    /// 154 kHz with 5.9° of margin (T = A(s) β / (1 + s (100 Ω ‖ 20 kΩ) C)); with 1 nF, 53° at 1.19 MHz
    func testTheStabilityExampleHasLittleMargin() throws {
        var circuit = try XCTUnwrap(Examples.all.first { $0.id == "opamp-stability" }).circuit
        let frequencies = FrequencySweep.logarithmic(from: 1, to: 10e6, pointsPerDecade: 20)
        for (capacitance, margin, crossover) in [(100e-9, 5.94, 154_100.0), (1e-9, 53.2, 1_194_800)] {
            circuit.elements[try index(circuit, "CABLE")][param: "capacitance"] = capacitance
            let simulator = Simulator.settled(circuit, holding: try index(circuit, "VIN"))
            XCTAssertFalse(simulator.isFailed, "\(simulator.problems)")
            let model = try XCTUnwrap(simulator.smallSignalModel())
            let t = try XCTUnwrap(model.loopGain(probe: try index(circuit, "LP1"), frequencies: frequencies))
            let margins = StabilityMargins(frequencies: frequencies, loopGain: t)
            XCTAssertEqual(try XCTUnwrap(margins.phaseMargin), margin, accuracy: 0.3, "\(capacitance) F")
            XCTAssertEqual(try XCTUnwrap(margins.crossover), crossover, accuracy: 0.01 * crossover, "\(capacitance) F")
        }
    }

    /// Margins of a loop with an AC-coupled band: |T| rises through 1 below its band (where T leads) and falls through 1
    /// above it (where it lags); each margin is measured from −1 the way its crossing approaches it
    func testMarginsOfABandPassLoop() {
        // T = 10 (s/wl) / ((1 + s/wl)(1 + s/wh)³): 10 in its band, from 100 Hz to 10 kHz
        let (wl, wh) = (2 * Double.pi * 100, 2 * Double.pi * 10_000)
        let frequencies = FrequencySweep.logarithmic(from: 1, to: 1e6, pointsPerDecade: 100)
        let t = frequencies.map { f -> Complex in
            let s = Complex(0, 2 * .pi * f)
            let pole = Complex(1) + Complex(1 / wh) * s
            return Complex(10 / wl) * s / ((Complex(1) + Complex(1 / wl) * s) * pole * pole * pole)
        }
        let margins = StabilityMargins(frequencies: frequencies, loopGain: t)
        XCTAssertEqual(margins.unityCrossings.count, 2)
        // below the band: at 10.05 Hz, leading by 84.1°
        let low = margins.unityCrossings[0]
        XCTAssertEqual(low.frequency, 10.05, accuracy: 0.05)
        XCTAssertEqual(low.margin, 95.9, accuracy: 0.2)
        // above it, at 19.1 kHz, lagging by 186.7°: unstable
        let high = margins.unityCrossings[1]
        XCTAssertEqual(high.frequency, 19_080, accuracy: 100)
        XCTAssertEqual(high.margin, -6.7, accuracy: 0.3)
        XCTAssertEqual(margins.phaseMargin ?? 0, high.margin)
        XCTAssertEqual(margins.crossover ?? 0, high.frequency)
        // its phase reaches −180° at 17.4 kHz, below crossover, where |T| is 1.24: 1.85 dB too much gain
        XCTAssertEqual(margins.phaseCrossings.count, 1)
        XCTAssertEqual(margins.phaseCrossings[0].frequency, 17_400, accuracy: 100)
        XCTAssertEqual(margins.gainMargin ?? 0, -1.85, accuracy: 0.1)
    }

    /// A resistor and capacitor in parallel: Z = R / (1 + jωRC); a source driving a resistor and a capacitor in series
    /// sees R + 1 / jωC
    func testImpedanceAgainstFrequency() throws {
        let c = try circuit("""
        impedances
        V1 in 0 DC 1
        R1 in mid 1k
        C1 mid 0 1u
        R2 node 0 10k
        C2 node 0 10n
        """)
        let (simulator, model) = try linearised(c)
        let frequencies = [10.0, 1591.55, 100_000]
        let node = simulator.nodes(of: try index(c, "R2"))[0]
        let z = try XCTUnwrap(model.impedance(plus: node, minus: 0, frequencies: frequencies))
        let zin = try XCTUnwrap(model.loadImpedance(input: try index(c, "V1"), frequencies: frequencies))
        for (k, f) in frequencies.enumerated() {
            let w = 2 * Double.pi * f
            let parallel = Complex(10_000) / Complex(1, w * 10_000 * 10e-9)
            XCTAssertEqual(z[k].re, parallel.re, accuracy: 1e-6 * parallel.magnitude, "\(f) Hz")
            XCTAssertEqual(z[k].im, parallel.im, accuracy: 1e-6 * parallel.magnitude, "\(f) Hz")
            XCTAssertEqual(zin[k].re, 1000, accuracy: 1e-6 * zin[k].magnitude, "\(f) Hz")
            XCTAssertEqual(zin[k].im, -1 / (w * 1e-6), accuracy: 1e-6 * zin[k].magnitude, "\(f) Hz")
        }
    }
}
