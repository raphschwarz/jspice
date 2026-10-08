import Foundation

/// A circuit as an audio processor, a block of samples at a time, as a plugin runs it: the host's sound goes into its
/// audio input parts, what its speaker hears comes out, its knobs and switches are the plugin's parameters, and notes
/// play its keyboard sources (the last note held sounds, as on a monophonic synth).
///
/// Not thread-safe: the host's audio thread calls `process`; parameters and notes are set between blocks.
public final class CircuitProcessor {
    /// A knob or switch of the circuit, at the top level or inside a block
    public struct Control: Sendable, Equatable {
        public var name: String
        /// A pot's position, or a switch's state (1 closed)
        public var value: Double
        public var isSwitch: Bool
        /// The part, or the block part that holds it
        public var part: UUID
        /// For a control inside a block: its id in the block's circuit
        public var inner: UUID?
    }

    public private(set) var circuit: Circuit
    public private(set) var controls: [Control]
    public let sampleRate: Double
    /// Whether the circuit takes the host's sound (an effect) and plays notes (an instrument)
    public let hasInput: Bool
    public let hasKeyboard: Bool

    private let simulator: Simulator
    private let speaker: Int
    private let fullScale: Double
    private let oversampling: Int
    private var input: [Float] = []
    private var blockerInput = 0.0
    private var blockerOutput = 0.0
    private let blockerPole: Double
    private var held: [Double] = []
    private var pendingParameters = false

    /// Nil when the circuit has no speaker to listen to
    public init?(circuit: Circuit, sampleRate: Double, oversampling: Int = 2) {
        var circuit = circuit
        guard let speaker = circuit.elements.firstIndex(where: { $0.kind == .speaker }) else { return nil }
        // every audio input part plays the host's sound
        func live(_ elements: inout [Element]) {
            for i in elements.indices {
                if elements[i].kind == .audioInput { elements[i][param: "input"] = 1 }
                if var block = elements[i].block {
                    live(&block.circuit.elements)
                    elements[i].block = block
                }
            }
        }
        live(&circuit.elements)
        let flat = circuit.flattened()
        hasInput = flat.elements.contains { $0.kind == .audioInput }
        hasKeyboard = flat.elements.contains { $0.kind == .keyboardPitch || $0.kind == .keyboardGate }
        self.circuit = circuit
        self.sampleRate = sampleRate
        self.speaker = speaker
        self.oversampling = max(1, oversampling)
        fullScale = max(circuit.elements[speaker][param: "fullScale"], 1e-3)
        blockerPole = exp(-2 * .pi * 4 / sampleRate)
        controls = Self.controls(of: circuit)
        simulator = Simulator(circuit: circuit, timeStep: 1 / (sampleRate * Double(max(1, oversampling))))
        simulator.errorControl = false
        // start from where the circuit rests, its coupling capacitors charged
        for _ in 0..<Int(min(Simulator.settling(circuit).duration, 1) * sampleRate * Double(self.oversampling)) where !simulator.isFailed {
            simulator.step()
        }
    }

    /// The circuit's knobs and switches, in the order of the front panel
    public static func controls(of circuit: Circuit) -> [Control] {
        func control(_ element: Element, name: String, part: UUID, inner: UUID?) -> Control? {
            switch element.kind {
            case .potentiometer:
                return Control(name: name, value: element[param: "position"], isSwitch: false, part: part, inner: inner)
            case .toggleSwitch, .pushButton:
                return Control(name: name, value: element.closed ? 1 : 0, isSwitch: true, part: part, inner: inner)
            default:
                return nil
            }
        }
        var found: [(place: (Int, Int), control: Control)] = []
        for element in circuit.elements {
            let place = (min(element.a.x, element.b.x), min(element.a.y, element.b.y))
            if let c = control(element, name: element.name, part: element.id, inner: nil) { found.append((place, c)) }
            for inner in element.block?.circuit.elements ?? [] {
                if let c = control(inner, name: "\(element.name) \(inner.name)", part: element.id, inner: inner.id) { found.append((place, c)) }
            }
        }
        return found.sorted { $0.place < $1.place }.map(\.control)
    }

    /// Moves a knob or switch, 0 to 1; it takes effect at the next block
    public func set(_ index: Int, to value: Double) {
        guard controls.indices.contains(index) else { return }
        let value = min(max(value, 0), 1)
        guard controls[index].value != value else { return }
        controls[index].value = value
        let c = controls[index]
        func apply(_ element: inout Element) {
            if c.isSwitch { element.closed = value >= 0.5 } else { element[param: "position"] = value }
        }
        guard let i = circuit.index(of: c.part) else { return }
        if let inner = c.inner {
            guard var block = circuit.elements[i].block, let j = block.circuit.index(of: inner) else { return }
            apply(&block.circuit.elements[j])
            circuit.elements[i].block = block
        } else {
            apply(&circuit.elements[i])
        }
        pendingParameters = true
    }

    public func noteOn(_ note: Int) {
        held.removeAll { $0 == Double(note) }
        held.append(Double(note))
        simulator.keyboard = Simulator.KeyboardState(note: Double(note), gate: true)
    }

    public func noteOff(_ note: Int) {
        held.removeAll { $0 == Double(note) }
        // back to the last note still held, or the gate closes on the note that was playing
        simulator.keyboard = held.last.map { Simulator.KeyboardState(note: $0, gate: true) }
            ?? Simulator.KeyboardState(note: simulator.keyboard.note, gate: false)
    }

    public func allNotesOff() {
        held.removeAll()
        simulator.keyboard.gate = false
    }

    /// Starts again from rest, keeping the controls where they are
    public func reset() {
        simulator.reset()
        blockerInput = 0
        blockerOutput = 0
    }

    /// Whether the circuit has stopped converging (its output is then silence)
    public var isFailed: Bool { simulator.isFailed }

    /// Runs the circuit for `frames` samples: `input` (mono, or nil for silence) into its audio inputs, its speaker
    /// into `output`, scaled so the speaker's full scale is 1 and bent softly above 0.7 instead of clipping
    public func process(input samples: UnsafePointer<Float>?, output: UnsafeMutablePointer<Float>, frames: Int) {
        if pendingParameters {
            pendingParameters = false
            if !simulator.updateParameters(circuit) { simulator.load(circuit) }
        }
        if hasInput {
            // the simulator lets go of the last block's samples first, so they are written in place (sharing them
            // would make each block copy them on the render thread)
            simulator.liveInput = nil
            if input.count != frames + 1 { input = [Float](repeating: 0, count: frames + 1) }
            for k in 0..<frames { input[k] = samples?[k] ?? 0 }
            input[frames] = input[max(frames - 1, 0)]
            simulator.liveInput = Simulator.LiveInput(samples: input, sampleRate: sampleRate, startTime: simulator.time)
        }
        for n in 0..<frames {
            var sum = 0.0
            if !simulator.isFailed {
                for _ in 0..<oversampling {
                    simulator.step()
                    sum += simulator.voltageAcross(speaker)
                }
            }
            let x = sum / Double(oversampling) / fullScale
            // the speaker hears changes, not a constant offset
            let y = x - blockerInput + blockerPole * blockerOutput
            blockerInput = x
            blockerOutput = y
            output[n] = Float(Self.limit(y))
        }
    }

    /// Above 0.7 of full scale the output bends softly towards 1 instead of clipping
    static func limit(_ y: Double) -> Double {
        guard y.isFinite else { return 0 }
        let magnitude = abs(y)
        guard magnitude > 0.7 else { return y }
        let bent = 0.7 + 0.3 * tanh((magnitude - 0.7) / 0.3)
        return y < 0 ? -bent : bent
    }
}
