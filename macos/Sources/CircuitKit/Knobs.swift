import Foundation

/// A potentiometer to turn: on the schematic, or (`inner`) inside a block part
public struct KnobID: Hashable, Sendable, Codable {
    /// The pot, or the block part that holds it
    public var part: UUID
    /// For a pot inside a block: its id in the block's circuit
    public var inner: UUID?

    public init(part: UUID, inner: UUID? = nil) {
        self.part = part
        self.inner = inner
    }
}

extension Circuit {
    /// The knobs that can be turned: its potentiometers and those inside its blocks, in the front panel's order, each
    /// with its name (one inside a block after the block's) and its position
    public var knobs: [(id: KnobID, name: String, position: Double)] {
        CircuitProcessor.controls(of: self).filter { !$0.isSwitch }.map { control in
            (id: KnobID(part: control.part, inner: control.inner), name: control.name, position: control.value)
        }
    }

    /// A knob's position, 0 to 1; nil where there is no such potentiometer
    public func position(of knob: KnobID) -> Double? {
        guard let i = index(of: knob.part) else { return nil }
        if let inner = knob.inner {
            guard let block = elements[i].block, let j = block.circuit.index(of: inner),
                  block.circuit.elements[j].kind == .potentiometer else { return nil }
            return block.circuit.elements[j][param: "position"]
        }
        return elements[i].kind == .potentiometer ? elements[i][param: "position"] : nil
    }

    /// Turns a knob to `position` (held within 0 to 1); true if it moved
    @discardableResult
    public mutating func turn(_ knob: KnobID, to position: Double) -> Bool {
        let value = min(1, max(0, position))
        guard value.isFinite, let i = index(of: knob.part) else { return false }
        if let inner = knob.inner {
            guard var block = elements[i].block, let j = block.circuit.index(of: inner),
                  block.circuit.elements[j].kind == .potentiometer,
                  block.circuit.elements[j][param: "position"] != value else { return false }
            block.circuit.elements[j][param: "position"] = value
            elements[i].block = block
            return true
        }
        guard elements[i].kind == .potentiometer, elements[i][param: "position"] != value else { return false }
        elements[i][param: "position"] = value
        return true
    }
}

/// What a knob does to a frequency response: the response worked out with the knob at several positions, as it would
/// be turned from one end to the other. At each position a copy of the circuit settles from rest with the knob there
/// (so a knob that sets a bias moves the operating point too) and is linearised, as the live response is.
public enum KnobSweep {
    public struct Curve: Sendable {
        /// The knob's position, 0 to 1
        public var position: Double
        /// Gain in dB and phase in degrees at each frequency
        public var gains: [Double]
        public var phases: [Double]
        /// A loop probe's: its loop gain's margins
        public var margins: StabilityMargins?
    }

    /// `count` positions from one end to the other, evenly spaced
    public static func positions(_ count: Int) -> [Double] {
        count <= 1 ? [0.5] : (0..<count).map { Double($0) / Double(count - 1) }
    }

    /// The response across the element at `element`, driven from the source at `input` (or, for a loop probe, its
    /// loop gain), with the knob at each of `positions`. A position where the circuit can't be solved has no curve.
    public static func responses(_ circuit: Circuit, knob: KnobID, positions: [Double], element: Int, input: Int?,
                                 frequencies: [Double], maxSteps: Int = 200_000,
                                 isCancelled: () -> Bool = { false }) -> [Curve] {
        guard circuit.elements.indices.contains(element) else { return [] }
        let loop = circuit.elements[element].kind == .loopProbe
        guard loop || input != nil else { return [] }
        func decibels(_ magnitude: Double) -> Double { 20 * log10(max(magnitude, 1e-12)) }
        var curves: [Curve] = []
        for position in positions {
            if isCancelled() { break }
            var turned = circuit
            turned.turn(knob, to: position)
            let simulator = Simulator.settled(turned, holding: loop ? nil : input, maxSteps: maxSteps)
            guard !simulator.isFailed, let model = simulator.smallSignalModel() else { continue }
            if loop {
                guard let t = model.loopGain(probe: element, frequencies: frequencies) else { continue }
                curves.append(Curve(position: position, gains: t.map { decibels($0.magnitude) }, phases: FrequencySweep.unwrappedPhases(t),
                                    margins: StabilityMargins(frequencies: frequencies, loopGain: t)))
            } else {
                guard let input, let (plus, minus) = simulator.acrossNodes(element),
                      let values = model.response(input: input, plus: plus, minus: minus, frequencies: frequencies) else { continue }
                curves.append(Curve(position: position, gains: values.map { decibels($0.magnitude) },
                                    phases: FrequencySweep.unwrappedPhases(values)))
            }
        }
        return curves
    }
}

/// A knob moved back and forth by itself, as a foot rocks a wah pedal or a hand sweeps a filter: from `low` to `high`
/// and back once every `period` seconds, slowing at each end (a raised cosine), `offset` seconds into its cycle at
/// time 0
public struct KnobMotion: Hashable, Sendable, Codable {
    public var knob: KnobID
    public var period: Double
    public var low: Double
    public var high: Double
    public var offset: Double

    /// How often, in circuit time, a simulation moves the knobs: each move then is far too small to hear
    public static let interval = 1e-3

    public init(knob: KnobID, period: Double = 2, low: Double = 0, high: Double = 1, offset: Double = 0) {
        self.knob = knob
        self.period = period
        self.low = low
        self.high = high
        self.offset = offset
    }

    /// One that starts from `position`, on its way up (from outside its range, at the nearer end)
    public init(knob: KnobID, period: Double = 2, low: Double = 0, high: Double = 1, from position: Double) {
        self.init(knob: knob, period: period, low: low, high: high)
        let span = high - low
        let fraction = span != 0 ? min(1, max(0, (position - low) / span)) : 0
        // (1 − cos 2πφ) / 2 rises from 0 to 1 as φ goes from 0 to ½
        offset = acos(1 - 2 * fraction) / (2 * .pi) * period
    }

    /// Where the knob is `time` seconds in
    public func position(at time: Double) -> Double {
        guard period > 0 else { return low }
        let cycles = (time + offset) / period
        let phase = cycles - cycles.rounded(.down)
        return low + (high - low) * (1 - cos(2 * .pi * phase)) / 2
    }
}

extension Simulator {
    /// Moves knobs to where their motions have them `time` seconds in; true if any moved. The parts take on their new
    /// values as when a knob is turned by hand: the circuit's state stays.
    @discardableResult
    public func move(_ motions: [KnobMotion], at time: Double) -> Bool {
        var next = circuit
        var moved = false
        for motion in motions {
            if next.turn(motion.knob, to: motion.position(at: time)) { moved = true }
        }
        guard moved else { return false }
        if !updateParameters(next) { load(next) }
        return true
    }
}
