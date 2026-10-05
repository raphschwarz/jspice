import Foundation

/// Chooses how fast to run a circuit and how finely to step it.
///
/// The goal is real time whenever the circuit changes slowly enough to watch. When it changes faster (a 1 kHz filter, a
/// 60 Hz rectifier) the simulation runs in slow motion, so its slowest interesting change takes about 1.5 seconds on screen.
public enum Pacing {
    /// Changes at least this slow are shown in real time
    static let realTimeThreshold = 0.15
    /// Seconds on screen for the slowest time constant or period when in slow motion
    static let slowMotionSpan = 1.5
    /// Limits on steps per second of wall-clock time
    static let minStepsPerSecond = 60.0
    static let maxStepsPerSecond = 20_000.0

    public struct Suggestion: Equatable {
        /// Simulated seconds per real second
        public var speed: Double
        public var timeStep: Double
    }

    /// The circuit's time constants and periods, estimated from its parts. Each capacitor or inductor is paired with the
    /// smallest and the largest resistance in the circuit, since either may be the one it charges through.
    static func timeScales(of circuit: Circuit) -> [Double] {
        let elements = circuit.elements
        var resistances: [Double] = []
        for element in elements {
            switch element.kind {
            case .resistor, .lamp, .potentiometer: resistances.append(element[param: "resistance"])
            case .memristor: resistances.append(contentsOf: [element[param: "ron"], element[param: "roff"]])
            default: break
            }
        }
        let positive = resistances.filter { $0 > 0 && $0.isFinite }
        let smallest = positive.min() ?? 1000
        let largest = positive.max() ?? 1000

        var scales: [Double] = []
        var capacitances: [Double] = []
        var inductances: [Double] = []
        for element in elements {
            switch element.kind {
            case .capacitor:
                let c = element[param: "capacitance"]
                capacitances.append(c)
                scales.append(contentsOf: [c * smallest, c * largest])
            case .inductor:
                let l = element[param: "inductance"]
                inductances.append(l)
                scales.append(contentsOf: [l / smallest, l / largest])
            case .acVoltage, .squareVoltage:
                let f = element[param: "frequency"]
                if f > 0 { scales.append(1 / f) }
            case .memristor:
                scales.append(element[param: "tau"])
            case .vactrol:
                scales.append(contentsOf: [element[param: "attack"], element[param: "decay"]])
            case .delayLine:
                scales.append(element[param: "stages"] / (2 * max(element[param: "clock"], 1)))
            case .vco:
                let f = element[param: "frequency"]
                if f > 0 { scales.append(1 / f) }
            case .vcf:
                scales.append(1 / (2 * .pi * max(element[param: "cutoff"], 0.01)))
            case .envelope:
                scales.append(contentsOf: [element[param: "attack"], element[param: "decay"], element[param: "release"]])
            case .atmega328p:
                // sketches blink and fade in real time; PWM runs at 490 and 980 Hz
                scales.append(contentsOf: [1, 2e-3])
            default:
                break
            }
        }
        for l in inductances.prefix(8) {
            for c in capacitances.prefix(8) {
                scales.append(2 * .pi * (l * c).squareRoot())
            }
        }
        return scales.filter { $0 > 0 && $0.isFinite }
    }

    /// The slowest of the circuit's time constants and periods, or nil if it has none
    public static func slowestTimeScale(of circuit: Circuit) -> Double? {
        timeScales(of: circuit).max()
    }

    public static func suggest(for circuit: Circuit) -> Suggestion {
        let scales = timeScales(of: circuit)
        guard let slowest = scales.max(), let fastest = scales.min() else {
            // nothing changes by itself: real time, stepped often enough to react to switches at once
            return Suggestion(speed: 1, timeStep: 1e-3)
        }
        let speed = slowest >= realTimeThreshold ? 1 : SI.niceFloor(slowest / slowMotionSpan)
        var timeStep = fastest / 40
        timeStep = min(timeStep, speed / minStepsPerSecond)
        timeStep = max(timeStep, speed / maxStepsPerSecond)
        return Suggestion(speed: speed, timeStep: SI.niceFloor(timeStep))
    }

    /// "Real time", or "1 ms per second" in slow motion
    public static func describe(speed: Double) -> String {
        if abs(speed - 1) < 1e-9 { return "Real time" }
        if speed > 1 { return "\(SI.trimmed(speed, digits: 3))× real time" }
        return "\(SI.format(speed, unit: "s")) per second"
    }
}
