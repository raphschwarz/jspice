import XCTest
@testable import CircuitKit

/// The spectrum analyser: the transform, the fundamental, harmonics and distortion, and the scope that records it
final class SpectrumTests: XCTestCase {
    func testFFTMatchesTheDefinition() {
        var seed: UInt64 = 7
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53) - 0.5
        }
        let n = 64
        let input = (0..<n).map { _ in random() }
        var re = input, im = [Double](repeating: 0, count: n)
        Spectrum.fft(&re, &im)
        for k in 0..<n {
            var sr = 0.0, si = 0.0
            for (j, x) in input.enumerated() {
                let angle = -2 * Double.pi * Double(j * k) / Double(n)
                sr += x * cos(angle)
                si += x * sin(angle)
            }
            XCTAssertEqual(re[k], sr, accuracy: 1e-9)
            XCTAssertEqual(im[k], si, accuracy: 1e-9)
        }
    }

    private func samples(_ count: Int = 16_384, rate: Double = 48_000, _ signal: (Double) -> Double) -> [Double] {
        (0..<count).map { signal(Double($0) / rate) }
    }

    func testASineBetweenBins() throws {
        let spectrum = try XCTUnwrap(Spectrum.analyze(samples { 0.8 * sin(2 * .pi * 1234.5 * $0) + 0.3 }, interval: 1 / 48_000.0))
        XCTAssertEqual(try XCTUnwrap(spectrum.fundamental), 1234.5, accuracy: 0.1)
        XCTAssertEqual(spectrum.harmonics[0].amplitude, 0.8, accuracy: 0.002)
        XCTAssertLessThan(try XCTUnwrap(spectrum.thd), 1e-4)
        XCTAssertEqual(spectrum.mean, 0.3, accuracy: 1e-3)
        XCTAssertEqual(spectrum.rms, 0.8 / 2.0.squareRoot(), accuracy: 0.002)
        XCTAssertEqual(spectrum.binWidth, 48_000.0 / 16_384, accuracy: 1e-9)
    }

    func testASquareWavesHarmonics() throws {
        let square = samples { sin(2 * .pi * 220.3 * $0 + 0.1) >= 0 ? 1 : -1 }
        let spectrum = try XCTUnwrap(Spectrum.analyze(square, interval: 1 / 48_000.0))
        XCTAssertEqual(try XCTUnwrap(spectrum.fundamental), 220.3, accuracy: 0.1)
        XCTAssertEqual(spectrum.harmonics.count, 10)
        // odd harmonics at 4/(πn), even ones absent
        for harmonic in spectrum.harmonics {
            let expected = harmonic.number % 2 == 1 ? 4 / (.pi * Double(harmonic.number)) : 0
            XCTAssertEqual(harmonic.amplitude, expected, accuracy: 0.01, "harmonic \(harmonic.number)")
        }
        let theory = (1.0 / 9 + 1.0 / 25 + 1.0 / 49 + 1.0 / 81).squareRoot()
        XCTAssertEqual(try XCTUnwrap(spectrum.thd), theory, accuracy: 0.003)
    }

    func testKnownDistortion() throws {
        let signal = samples { t in sin(2 * .pi * 440 * t) + 0.1 * sin(2 * .pi * 880 * t) + 0.05 * sin(2 * .pi * 1320 * t) }
        let spectrum = try XCTUnwrap(Spectrum.analyze(signal, interval: 1 / 48_000.0))
        XCTAssertEqual(try XCTUnwrap(spectrum.thd), (0.01 + 0.0025).squareRoot(), accuracy: 1e-3)
        // a harmonic stronger than its fundamental still has the fundamental found under it
        let octave = samples { t in 0.3 * sin(2 * .pi * 200 * t) + sin(2 * .pi * 400 * t) }
        XCTAssertEqual(try XCTUnwrap(Spectrum.analyze(octave, interval: 1 / 48_000.0)?.fundamental), 200, accuracy: 0.5)
        // harmonics stop below the highest frequency asked for
        let limited = try XCTUnwrap(Spectrum.analyze(signal, interval: 1 / 48_000.0, maxFrequency: 1000))
        XCTAssertEqual(limited.harmonics.count, 2)
        XCTAssertNil(Spectrum.analyze([1, 2, 3], interval: 1))
    }

    func testSpectrumScopeOfAClipper() throws {
        // a 1 kHz sine of 2 V through 1 kΩ into two diodes: clipped symmetrically, so odd harmonics only
        var circuit = try SchematicLayout.layout([
            NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": 2, "frequency": 1000], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 1000], connections: ["a": "in", "b": "clip"]),
            NetlistPart(kind: .diode, name: "D1", params: Examples.model(.diode, "1N4148"), connections: ["anode": "clip", "cathode": "GND"]),
            NetlistPart(kind: .diode, name: "D2", params: Examples.model(.diode, "1N4148"), connections: ["anode": "GND", "cathode": "clip"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 1000], connections: ["a": "in", "b": "GND"]),
        ])
        let d1 = try XCTUnwrap(circuit.elements.first { $0.name == "D1" })
        let r2 = try XCTUnwrap(circuit.elements.first { $0.name == "R2" })
        circuit.scopes = [ScopeSpec(elementID: d1.id, quantity: .voltage, plot: .spectrum),
                          ScopeSpec(elementID: r2.id, quantity: .voltage, plot: .spectrum)]
        let simulator = Simulator(circuit: circuit, timeStep: 1e-5)
        simulator.configureScopes(window: 0.01)
        while simulator.time < 0.1 { simulator.step() }

        let clean = try XCTUnwrap(simulator.trace(circuit.scopes[1].id))
        XCTAssertEqual(clean.evenSamples.count, ScopeTrace.spectrumLength)
        let sine = try XCTUnwrap(clean.spectrum())
        XCTAssertEqual(try XCTUnwrap(sine.fundamental), 1000, accuracy: 0.5)
        XCTAssertEqual(sine.harmonics[0].amplitude, 2, accuracy: 0.01)
        XCTAssertLessThan(try XCTUnwrap(sine.thd), 0.002)
        // nothing above what the simulation's steps can show
        XCTAssertLessThanOrEqual(sine.maxFrequency, 0.5 / 1e-5 + 1)

        let clipped = try XCTUnwrap(simulator.trace(circuit.scopes[0].id)?.spectrum())
        XCTAssertEqual(try XCTUnwrap(clipped.fundamental), 1000, accuracy: 0.5)
        XCTAssertGreaterThan(try XCTUnwrap(clipped.thd), 0.1)
        let levels = clipped.harmonics.map(\.amplitude)
        XCTAssertGreaterThan(levels[2], 20 * levels[1], "the third harmonic dominates the second")
    }
}
