import XCTest
@testable import CircuitKit

/// Sound in and out: WAV files, the audio input part and the offline render
final class AudioTests: XCTestCase {
    /// A WAV file's bytes: a format chunk, a chunk to skip, then the samples as given
    private func wav(format: Int, channels: Int, rate: Int, bits: Int, body: [UInt8], extensible: Bool = false) -> Data {
        var data = Data()
        func text(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        let fmtSize = extensible ? 40 : 16
        text("RIFF")
        u32(4 + 8 + fmtSize + 8 + 3 + 1 + 8 + body.count)
        text("WAVE")
        text("fmt ")
        u32(fmtSize)
        u16(extensible ? 0xFFFE : format)
        u16(channels)
        u32(rate)
        u32(rate * channels * bits / 8)
        u16(channels * bits / 8)
        u16(bits)
        if extensible {
            u16(22)
            u16(bits)
            u32(0)
            u16(format)
            data.append(contentsOf: [UInt8](repeating: 0, count: 14))
        }
        // an odd-sized chunk, padded, before the data
        text("LIST")
        u32(3)
        data.append(contentsOf: [1, 2, 3, 0])
        text("data")
        u32(body.count)
        data.append(contentsOf: body)
        return data
    }

    func testWAVRoundTrip() throws {
        let samples: [Float] = (0..<1000).map { Float(sin(Double($0) * 0.05)) * 0.9 }
        let decoded = try WAV.decode(WAV.encode(samples, sampleRate: 44_100))
        XCTAssertEqual(decoded.sampleRate, 44_100)
        XCTAssertEqual(decoded.samples.count, samples.count)
        for (a, b) in zip(decoded.samples, samples) { XCTAssertEqual(a, b, accuracy: 2e-7) }
        // beyond full scale is clipped
        XCTAssertEqual(try WAV.decode(WAV.encode([2, -2], sampleRate: 8000)).samples, [8_388_607 / 8_388_608, -8_388_607 / 8_388_608])
    }

    func testWAVFormats() throws {
        // 16-bit stereo, mixed down to the channels' average
        let stereo = wav(format: 1, channels: 2, rate: 22_050, bits: 16, body: [0x00, 0x40, 0x00, 0x20, 0x00, 0xC0, 0x00, 0xC0])
        let mixed = try WAV.decode(stereo)
        XCTAssertEqual(mixed.sampleRate, 22_050)
        XCTAssertEqual(mixed.samples, [0.375, -0.5])
        // 8-bit is unsigned
        XCTAssertEqual(try WAV.decode(wav(format: 1, channels: 1, rate: 8000, bits: 8, body: [128, 192, 0])).samples, [0, 0.5, -1])
        // 32-bit float, in an extensible header
        var floats: [UInt8] = []
        for value: Float in [0.25, -0.75] { withUnsafeBytes(of: value.bitPattern.littleEndian) { floats.append(contentsOf: $0) } }
        XCTAssertEqual(try WAV.decode(wav(format: 3, channels: 1, rate: 48_000, bits: 32, body: floats, extensible: true)).samples, [0.25, -0.75])
        // 24-bit, negative
        XCTAssertEqual(try WAV.decode(wav(format: 1, channels: 1, rate: 48_000, bits: 24, body: [0x00, 0x00, 0xC0])).samples, [-0.5])
        XCTAssertThrowsError(try WAV.decode(Data("not a sound".utf8)))
        XCTAssertThrowsError(try WAV.decode(wav(format: 2, channels: 1, rate: 8000, bits: 4, body: [0])))
    }

    func testClipKeepsItsSamplesInTheCircuitFile() throws {
        let samples: [Float] = (0..<500).map { Float($0 % 50) / 50 - 0.5 }
        let clip = AudioClip(name: "saw", sampleRate: 1000, samples: samples)
        XCTAssertEqual(clip.duration, 0.5, accuracy: 1e-12)
        var circuit = try SchematicLayout.layout([
            NetlistPart(kind: .audioInput, name: "IN1", connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 1000], connections: ["a": "in", "b": "GND"]),
        ])
        let id = try XCTUnwrap(circuit.elements.first { $0.name == "IN1" }).id
        circuit.update(id) { $0.audio = clip }
        let reloaded = try JSONDecoder().decode(Circuit.self, from: JSONEncoder().encode(circuit))
        let kept = try XCTUnwrap(reloaded.elements.first { $0.id == id }?.audio)
        XCTAssertEqual(kept.name, "saw")
        XCTAssertEqual(kept.sampleRate, 1000)
        for (a, b) in zip(kept.samples, samples) { XCTAssertEqual(a, b, accuracy: 1.0 / 32767) }
        // a long sound is cut to a minute
        XCTAssertEqual(AudioClip(name: "long", sampleRate: 100, samples: [Float](repeating: 0, count: 10_000)).duration, 60)
        // the riff is a few seconds of sound, near full scale
        let riff = AudioClip.guitarRiff
        XCTAssertGreaterThan(riff.duration, 3)
        XCTAssertGreaterThan(riff.samples.map(abs).max() ?? 0, 0.5)
    }

    /// An audio input across a resistor, playing a ramp at 1 kHz: 0, 0.1, 0.2… one step a millisecond
    private func ramp(loop: Bool, live: Bool = false) throws -> (Simulator, Int) {
        var circuit = try SchematicLayout.layout([
            NetlistPart(kind: .audioInput, name: "IN1", params: ["level": 2, "offset": 0.5, "loop": loop ? 1 : 0, "input": live ? 1 : 0],
                        connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 1000], connections: ["a": "in", "b": "GND"]),
        ])
        let index = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "IN1" })
        circuit.elements[index].audio = AudioClip(name: "ramp", sampleRate: 1000, samples: (0..<10).map { Float($0) / 10 })
        let simulator = Simulator(circuit: circuit, timeStep: 1e-4)
        simulator.errorControl = false
        return (simulator, try XCTUnwrap(circuit.elements.firstIndex { $0.name == "R1" }))
    }

    private func run(_ simulator: Simulator, to time: Double) {
        while simulator.time < time - 1e-9 { simulator.step() }
    }

    func testAudioInputPlaysItsSound() throws {
        let (simulator, r) = try ramp(loop: false)
        XCTAssertTrue(simulator.problems.isEmpty, "\(simulator.problems)")
        // offset + level × sample, between samples on a straight line
        for (time, sample) in [(0.002, 0.2), (0.0035, 0.35), (0.0071, 0.71)] {
            run(simulator, to: time)
            XCTAssertEqual(abs(simulator.voltageAcross(r)), 0.5 + 2 * sample, accuracy: 1e-3, "at \(time) s")
        }
        // played once: silence (the offset) after its end
        run(simulator, to: 0.012)
        XCTAssertEqual(abs(simulator.voltageAcross(r)), 0.5, accuracy: 1e-6)
    }

    func testAudioInputLoops() throws {
        let (simulator, r) = try ramp(loop: true)
        run(simulator, to: 0.0123)
        XCTAssertEqual(abs(simulator.voltageAcross(r)), 0.5 + 2 * 0.23, accuracy: 1e-3)
        run(simulator, to: 0.0251)
        XCTAssertEqual(abs(simulator.voltageAcross(r)), 0.5 + 2 * 0.51, accuracy: 1e-3)
    }

    func testLiveInputPlaysWhatItIsGiven() throws {
        let (simulator, r) = try ramp(loop: false, live: true)
        // nothing given yet: the offset alone
        run(simulator, to: 0.001)
        XCTAssertEqual(abs(simulator.voltageAcross(r)), 0.5, accuracy: 1e-6)
        // a chunk of input, from now on, at 10 kHz: one sample a step
        simulator.liveInput = Simulator.LiveInput(samples: (0..<20).map { Float($0) / 40 }, sampleRate: 10_000, startTime: simulator.time)
        for k in 1...10 {
            simulator.step()
            XCTAssertEqual(abs(simulator.voltageAcross(r)), 0.5 + 2 * Double(k) / 40, accuracy: 1e-6, "step \(k)")
        }
        // past the chunk's end it holds its last sample until the next chunk comes
        run(simulator, to: simulator.time + 0.01)
        XCTAssertEqual(abs(simulator.voltageAcross(r)), 0.5 + 2 * 19.0 / 40, accuracy: 1e-6)
    }

    func testAudioInputIsQuietForTheOperatingPoint() throws {
        // small-signal analysis holds sound sources at their offset
        let (simulator, _) = try ramp(loop: true)
        let quiet = Simulator.quiet(simulator.circuit, holding: nil)
        let index = try XCTUnwrap(quiet.elements.firstIndex { $0.kind == .audioInput })
        XCTAssertEqual(quiet.elements[index][param: "level"], 0)
    }

    func testRenderThroughAFilter() throws {
        // a 1 kHz tone through an RC low-pass at 1 kHz: 3 dB down and DC-free at the speaker
        let tone = (0..<48_000).map { Float(sin(2 * .pi * 1000 * Double($0) / 48_000)) }
        var circuit = try SchematicLayout.layout([
            NetlistPart(kind: .audioInput, name: "IN1", params: ["level": 1, "offset": 0.2, "loop": 1], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 1000], connections: ["a": "in", "b": "out"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 1 / (2 * .pi * 1000 * 1000)], connections: ["a": "out", "b": "GND"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 1], connections: ["plus": "out", "minus": "GND"]),
        ])
        let input = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "IN1" })
        circuit.elements[input].audio = AudioClip(name: "tone", sampleRate: 48_000, samples: tone)
        let speaker = try XCTUnwrap(circuit.elements.firstIndex { $0.kind == .speaker })
        let result = AudioRender.render(circuit, output: speaker, duration: 2)
        XCTAssertEqual(result.samples.count, 96_000)
        XCTAssertEqual(result.sampleRate, 48_000)
        XCTAssertTrue(result.problems.isEmpty, "\(result.problems)")
        // the last half second: settled, centred on zero, at 1/√2
        let tail = result.samples.suffix(24_000).map(Double.init)
        let mean = tail.reduce(0, +) / Double(tail.count)
        XCTAssertEqual(mean, 0, accuracy: 0.01)
        let rms = (tail.map { $0 * $0 }.reduce(0, +) / Double(tail.count)).squareRoot()
        XCTAssertEqual(rms * 2.0.squareRoot(), 1 / 2.0.squareRoot(), accuracy: 0.02)
        XCTAssertEqual(result.clipped, 0)
        XCTAssertGreaterThan(result.peak, 0.7)
        XCTAssertLessThan(result.peak, 1)
        // and a file of it reads back the same
        let decoded = try WAV.decode(WAV.encode(result.samples, sampleRate: result.sampleRate))
        XCTAssertEqual(decoded.samples.count, result.samples.count)
    }

    func testGuitarFuzzExampleMakesSound() throws {
        let example = try XCTUnwrap(Examples.all.first { $0.id == "guitar-fuzz" })
        let speaker = try XCTUnwrap(example.circuit.elements.firstIndex { $0.kind == .speaker })
        let result = AudioRender.render(example.circuit, output: speaker, duration: 1, sampleRate: 24_000, oversampling: 2)
        XCTAssertTrue(result.problems.isEmpty, "\(result.problems)")
        XCTAssertEqual(result.samples.count, 24_000)
        XCTAssertGreaterThan(result.peak, 0.1)
        XCTAssertFalse(result.samples.contains { !$0.isFinite })
    }
}
