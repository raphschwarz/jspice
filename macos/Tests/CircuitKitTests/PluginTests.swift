import XCTest
@testable import CircuitKit

/// A circuit as the Audio Unit runs it: a block at a time, the host's sound in, the speaker out
final class PluginTests: XCTestCase {
    func testTheLibraryOffersEffectsAndInstruments() throws {
        let effects = PluginLibrary.entries(instrument: false)
        let instruments = PluginLibrary.entries(instrument: true)
        XCTAssertTrue(effects.contains { $0.name.hasPrefix("Fuzz Face on a guitar riff") })
        // an example driven by one sine source becomes an effect, its source an audio input
        let overdrive = try XCTUnwrap(effects.first { $0.name.hasPrefix("Diode-clipper overdrive") })
        XCTAssertTrue(overdrive.circuit.elements.contains { $0.kind == .audioInput })
        XCTAssertFalse(overdrive.circuit.elements.contains { $0.kind == .acVoltage })
        XCTAssertTrue(instruments.contains { $0.name.hasPrefix("Mono synth") })
        XCTAssertTrue(instruments.allSatisfy { entry in entry.circuit.flattened().elements.contains { $0.kind == .keyboardGate || $0.kind == .keyboardPitch } })
        // a folder of exported circuits adds to them
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try JSONEncoder().encode(Examples.example("overdrive")!.circuit).write(to: folder.appendingPathComponent("My drive.jspice"))
        XCTAssertEqual(PluginLibrary.entries(instrument: false, folder: folder).last?.name, "My drive")
    }

    func testAnEffectProcessesTheHostsSound() throws {
        let entry = try XCTUnwrap(PluginLibrary.entries(instrument: false).first { $0.name.hasPrefix("Diode-clipper overdrive") })
        let processor = try XCTUnwrap(CircuitProcessor(circuit: entry.circuit, sampleRate: 48_000))
        XCTAssertTrue(processor.hasInput)
        let frames = 512
        var input = [Float](repeating: 0, count: frames)
        var output = [Float](repeating: 0, count: frames)
        var peakSilent = Float(0), peakLoud = Float(0)
        // silence in: (nearly) silence out
        for _ in 0..<20 {
            input.withUnsafeBufferPointer { i in output.withUnsafeMutableBufferPointer { o in
                processor.process(input: i.baseAddress, output: o.baseAddress!, frames: frames)
            } }
            peakSilent = max(peakSilent, output.map(abs).max()!)
        }
        // a 440 Hz tone in: sound out
        var phase = 0.0
        for _ in 0..<40 {
            for k in 0..<frames {
                input[k] = Float(sin(phase))
                phase += 2 * .pi * 440 / 48_000
            }
            input.withUnsafeBufferPointer { i in output.withUnsafeMutableBufferPointer { o in
                processor.process(input: i.baseAddress, output: o.baseAddress!, frames: frames)
            } }
            peakLoud = max(peakLoud, output.map(abs).max()!)
        }
        XCTAssertFalse(processor.isFailed)
        XCTAssertLessThan(peakSilent, 0.05)
        XCTAssertGreaterThan(peakLoud, 0.05)
        XCTAssertLessThanOrEqual(peakLoud, 1)
    }

    func testAnInstrumentPlaysNotes() throws {
        let entry = try XCTUnwrap(PluginLibrary.entries(instrument: true).first { $0.name.hasPrefix("Mono synth") })
        let processor = try XCTUnwrap(CircuitProcessor(circuit: entry.circuit, sampleRate: 48_000))
        XCTAssertTrue(processor.hasKeyboard)
        let quiet = level(processor, 40)
        processor.noteOn(57)
        let playing = level(processor, 60)
        XCTAssertGreaterThan(playing, max(quiet * 3, 0.02), "a held note sounds")
        processor.noteOff(57)
    }

    func testKnobsAreParameters() throws {
        let entry = try XCTUnwrap(PluginLibrary.entries(instrument: false).first { $0.name.hasPrefix("LM13700 filter") })
        let processor = try XCTUnwrap(CircuitProcessor(circuit: entry.circuit, sampleRate: 48_000))
        let k = try XCTUnwrap(processor.controls.firstIndex { $0.name == "CUTOFF" })
        XCTAssertFalse(processor.controls[k].isSwitch)
        XCTAssertEqual(processor.controls[k].value, 0.5)
        // moving a knob changes the circuit the next block runs
        processor.set(k, to: 0.9)
        _ = level(processor, 1)
        XCTAssertEqual(processor.controls[k].value, 0.9)
        let element = try XCTUnwrap(processor.circuit.elements.first { $0.id == processor.controls[k].part })
        XCTAssertEqual(element[param: "position"], 0.9)
        XCTAssertFalse(processor.isFailed)
        processor.set(99, to: 1)
    }

    private func level(_ processor: CircuitProcessor, _ blocks: Int) -> Float {
        var output = [Float](repeating: 0, count: 256)
        var peak = Float(0)
        for _ in 0..<blocks {
            output.withUnsafeMutableBufferPointer { processor.process(input: nil, output: $0.baseAddress!, frames: 256) }
            peak = max(peak, output.map(abs).max()!)
        }
        return peak
    }
}
