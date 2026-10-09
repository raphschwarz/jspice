import Foundation

/// Parts run past their ratings over a simulation, as a smoke test finds them: each resistor's and lamp's average power
/// against its rated power (a resistor ¼ W unless set), each capacitor's voltage against its rated voltage (where one
/// is set), and each diode and LED reversed past its breakdown voltage (its model's BV); with every part's peaks and
/// average power, so the hottest parts show whatever their ratings. Ratings are what the parts are given: nothing is
/// assumed of a part that is not rated.
public struct PartStress: Sendable {
    /// One part checked against one of its ratings
    public struct Finding: Sendable {
        public var index: Int
        public var part: String
        /// What is checked: "power", "voltage" or "reverse voltage"
        public var quantity: String
        public var unit: String
        /// The worst over the run: the average for power (what heats a part), the largest magnitude otherwise
        public var value: Double
        public var rating: Double
        /// value / rating: over 1, past the rating
        public var load: Double { rating > 0 ? value / rating : 0 }
    }

    /// The extremes of one part over the run
    public struct Peaks: Sendable {
        /// The largest |voltage across| and |current|, and the largest power
        public var voltage = 0.0
        public var current = 0.0
        public var power = 0.0
        /// The lowest voltage across (most reversed, for a diode)
        public var lowestVoltage = Double.infinity
        /// The power integrated over the run
        public var energy = 0.0
    }

    public private(set) var peaks: [Int: Peaks] = [:]
    /// The time recorded
    public private(set) var duration = 0.0
    let circuit: Circuit

    public init(_ circuit: Circuit) {
        self.circuit = circuit
    }

    /// The parts whose readings mean something on their own (not wires, labels, instruments or blocks)
    static func watched(_ kind: ElementKind) -> Bool {
        ![.wire, .ground, .netLabel, .port, .block, .probe, .ammeter, .loopProbe].contains(kind) && !kind.isSwitch
    }

    /// Records the simulator's present readings, as held for `dt` seconds
    public mutating func record(_ simulator: Simulator, dt: Double) {
        guard dt > 0 else { return }
        duration += dt
        for (i, element) in circuit.elements.enumerated() where Self.watched(element.kind) {
            let v = simulator.voltageAcross(i), current = simulator.current(i)
            let power = v * current
            guard v.isFinite, current.isFinite else { continue }
            var peak = peaks[i] ?? Peaks()
            peak.voltage = max(peak.voltage, abs(v))
            peak.current = max(peak.current, abs(current))
            peak.power = max(peak.power, power)
            peak.lowestVoltage = min(peak.lowestVoltage, v)
            peak.energy += power * dt
            peaks[i] = peak
        }
    }

    /// The average power of the part at `index` over the run
    public func averagePower(_ index: Int) -> Double {
        duration > 0 ? (peaks[index]?.energy ?? 0) / duration : 0
    }

    /// Every rated part against its ratings, the most loaded first
    public var findings: [Finding] {
        var result: [Finding] = []
        for (i, peak) in peaks {
            let element = circuit.elements[i]
            let name = element.name.isEmpty ? element.kind.displayName : element.name
            switch element.kind {
            case .resistor, .lamp:
                let rated = element[param: "ratedPower"]
                if rated > 0 {
                    result.append(Finding(index: i, part: name, quantity: "power", unit: "W", value: averagePower(i), rating: rated))
                }
            case .capacitor:
                let rated = element[param: "ratedVoltage"]
                if rated > 0 {
                    result.append(Finding(index: i, part: name, quantity: "voltage", unit: "V", value: peak.voltage, rating: rated))
                }
            case .diode, .led:
                let breakdown = abs(element[param: "bv"])
                if breakdown > 0 {
                    result.append(Finding(index: i, part: name, quantity: "reverse voltage", unit: "V",
                                          value: max(0, -peak.lowestVoltage), rating: breakdown))
                }
            default:
                break
            }
        }
        return result.sorted { $0.load > $1.load }
    }

    /// The findings past their ratings
    public var overstressed: [Finding] { findings.filter { $0.load > 1 } }

    /// The parts that take the most power on average, the hottest first
    public func hottest(_ count: Int) -> [(index: Int, power: Double)] {
        peaks.keys.map { ($0, averagePower($0)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(count)
            .map { (index: $0.0, power: $0.1) }
    }

    /// Runs `circuit` from rest for `duration` seconds at its suggested step (at most `maxSteps` steps), recording every
    /// step from `skip` seconds on
    public static func run(_ circuit: Circuit, duration: Double, skip: Double = 0, maxSteps: Int = 1_000_000) -> (stress: PartStress, simulator: Simulator) {
        var timeStep = Pacing.suggest(for: circuit).timeStep
        if duration / timeStep > Double(maxSteps) { timeStep = duration / Double(maxSteps) }
        let simulator = Simulator(circuit: circuit, timeStep: timeStep)
        var stress = PartStress(circuit)
        let steps = max(1, Int((duration / timeStep).rounded(.up)))
        for _ in 0..<steps where !simulator.isFailed {
            simulator.step()
            if simulator.time > skip { stress.record(simulator, dt: timeStep) }
        }
        return (stress, simulator)
    }
}
