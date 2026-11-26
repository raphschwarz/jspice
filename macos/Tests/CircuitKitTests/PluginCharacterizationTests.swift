import XCTest
@testable import CircuitKit

/// What `CircuitProcessor` puts out for a fixed circuit, input and script of knob moves and notes, block by block. The
/// figures were recorded from the processor before the Audio Unit's render thread was made real-time safe, so they
/// show that the processor still sounds the same. (Blocks of odd sizes are mixed in: the Audio Unit splits a host's
/// buffer at each event.)
final class PluginCharacterizationTests: XCTestCase {
    /// One step of a script: at the start of block `block`
    enum Action {
        case knob(Int, Double)
        case noteOn(Int)
        case noteOff(Int)
    }

    static let blockSizes = [256, 100, 37, 256, 1, 512]

    /// The RMS of each block, as the processor plays `blocks` blocks of a 220 Hz tone (for an effect) or silence
    static func fingerprint(_ processor: CircuitProcessor, blocks: Int, script: [Int: [Action]]) -> [Double] {
        var phase = 0.0
        var levels: [Double] = []
        for b in 0..<blocks {
            for action in script[b] ?? [] {
                switch action {
                case .knob(let k, let v): processor.set(k, to: v)
                case .noteOn(let n): processor.noteOn(n)
                case .noteOff(let n): processor.noteOff(n)
                }
            }
            let frames = blockSizes[b % blockSizes.count]
            var input = [Float](repeating: 0, count: frames)
            for k in 0..<frames {
                input[k] = Float(0.5 * sin(phase))
                phase += 2 * .pi * 220 / 48_000
            }
            var output = [Float](repeating: 0, count: frames)
            input.withUnsafeBufferPointer { i in
                output.withUnsafeMutableBufferPointer { o in
                    processor.process(input: processor.hasInput ? i.baseAddress : nil, output: o.baseAddress!, frames: frames)
                }
            }
            levels.append((output.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(frames)).squareRoot())
        }
        return levels
    }

    static let effectScript: [Int: [Action]] = [6: [.knob(0, 0.85)], 14: [.knob(1, 0.2)], 20: [.knob(0, 0.3), .knob(1, 0.9)]]
    static let instrumentScript: [Int: [Action]] = [
        2: [.noteOn(57)], 9: [.noteOn(64)], 13: [.knob(0, 0.8)], 16: [.noteOff(64)], 22: [.noteOff(57)], 26: [.noteOn(45)],
    ]

    static func circuit(_ name: String, instrument: Bool = false) throws -> Circuit {
        try XCTUnwrap(PluginLibrary.entries(instrument: instrument).first { $0.name.hasPrefix(name) }).circuit
    }

    /// Fuzz Face: two knobs; PT2399 echo: knobs and a delay line's history; Synth voice: notes and a resonance knob
    static func effect() throws -> CircuitProcessor {
        try XCTUnwrap(CircuitProcessor(circuit: circuit("Fuzz Face on a guitar riff"), sampleRate: 48_000))
    }

    static func echo() throws -> CircuitProcessor {
        try XCTUnwrap(CircuitProcessor(circuit: circuit("PT2399 echo"), sampleRate: 48_000))
    }

    static func instrument() throws -> CircuitProcessor {
        try XCTUnwrap(CircuitProcessor(circuit: circuit("Synth voice", instrument: true), sampleRate: 48_000))
    }

    static func assertMatches(_ levels: [Double], _ recorded: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(levels.count, recorded.count, file: file, line: line)
        for (k, (a, b)) in zip(levels, recorded).enumerated() {
            XCTAssertEqual(a, b, accuracy: 1e-5 + 1e-4 * abs(b), "block \(k)", file: file, line: line)
        }
    }

    func testAnEffectSoundsAsRecorded() throws {
        let processor = try Self.effect()
        XCTAssertGreaterThanOrEqual(processor.controls.count, 2)
        let levels = Self.fingerprint(processor, blocks: 30, script: Self.effectScript)
        print("effect fingerprint:", levels.map { String(format: "%.9f", $0) }.joined(separator: ", "))
        Self.assertMatches(levels, Self.recordedEffect)
    }

    func testAnEchoSoundsAsRecorded() throws {
        let processor = try Self.echo()
        XCTAssertGreaterThanOrEqual(processor.controls.count, 2)
        let levels = Self.fingerprint(processor, blocks: 30, script: Self.effectScript)
        print("echo fingerprint:", levels.map { String(format: "%.9f", $0) }.joined(separator: ", "))
        Self.assertMatches(levels, Self.recordedEcho)
    }

    func testAnInstrumentSoundsAsRecorded() throws {
        let processor = try Self.instrument()
        XCTAssertGreaterThanOrEqual(processor.controls.count, 1)
        let levels = Self.fingerprint(processor, blocks: 32, script: Self.instrumentScript)
        print("instrument fingerprint:", levels.map { String(format: "%.9f", $0) }.joined(separator: ", "))
        Self.assertMatches(levels, Self.recordedInstrument)
    }

    // recorded on Linux from the processor as it was before the real-time work (commit 8e40e29)
    static let recordedEffect: [Double] = [
        0.269000787, 0.281904638, 0.133222209, 0.203842996, 0.076412492, 0.242668503, 0.210813465, 0.095312050, 0.065118332,
        0.270953930, 0.459341168, 0.214402781, 0.209690231, 0.275667596, 0.025472835, 0.021669329, 0.012340491, 0.021420185,
        0.021283728, 0.031781612, 0.282529155, 0.554154450, 0.345870495, 0.626886829, 0.591684685, 0.429848317, 0.307966536,
        0.626635382, 0.999802589, 0.569777850,
    ]
    static let recordedEcho: [Double] = [
        0.003525623, 0.006698731, 0.011332320, 0.010018662, 0.011874489, 0.007966474, 0.007030583, 0.008607993, 0.007704000,
        0.006070987, 0.000544000, 0.005687721, 0.005213303, 0.005335232, 0.001782323, 0.004547786, 0.005962444, 0.004270188,
        0.003477165, 0.001971785, 0.005891238, 0.005325334, 0.006900955, 0.004877195, 0.003876517, 0.004075852, 0.006574908,
        0.020690637, 0.026884332, 0.019292472,
    ]
    static let recordedInstrument: [Double] = [
        0.000000000, 0.000000000, 0.000030086, 0.110957975, 0.141668558, 0.261576208, 0.318362524, 0.338158663, 0.361679320,
        0.352060560, 0.333985567, 0.361665261, 0.362852384, 0.383441102, 0.364336211, 0.379077981, 0.093879744, 0.364443965,
        0.371729014, 0.349336778, 0.411440161, 0.363761224, 0.354145437, 0.334501575, 0.282265963, 0.265071145, 0.250137313,
        0.279720094, 0.279474705, 0.328900932, 0.343707748, 0.333723624,
    ]
}
