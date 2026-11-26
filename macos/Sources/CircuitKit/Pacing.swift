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
        // the parts inside blocks count as much as any
        let elements = circuit.flattened().elements
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
            case .atmega328p, .atmega2560:
                // sketches blink and fade in real time; PWM runs at 490 and 980 Hz
                scales.append(contentsOf: [1, 2e-3])
            case .attiny85:
                // timer 1's PWM (D4) runs at 7.8 kHz
                scales.append(contentsOf: [1, 1.28e-4])
            case .rp2040:
                // arduino-pico's PWM runs at 1 kHz
                scales.append(contentsOf: [1, 1e-3])
            case .stm32f405, .stm32f373, .stm32f103:
                // a module's firmware: its audio at the codec's rate, its controls at a kilohertz
                scales.append(contentsOf: [1, 1e-3])
            case .digitalDelay:
                scales.append(element[param: "shortest"])
            case .audioInput:
                // sound: a millisecond resolves its notes' fundamentals
                scales.append(1e-3)
            case .pll:
                // its VCO at its fastest
                scales.append(1 / max(element[param: "fMax"], 1))
            case .levelDetector:
                scales.append(contentsOf: [element[param: "attack"], element[param: "release"]])
            case .springReverb:
                // the springs' delay: their echoes (their decay of seconds would hold every reverb to real time)
                scales.append(element[param: "delay"])
            case .agcPreamp:
                scales.append(element[param: "averaging"])
            default:
                // (`role(of:)` says which kinds have a time of their own: a test checks this switch against it)
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

    /// What a part adds to the circuit's time scales (`timeScales`)
    public enum Role: Sendable, Equatable {
        /// A resistance the capacitors and inductors may charge through
        case resistance
        /// A time constant or period of its own, read from its parameters
        case own
        /// Both: a memristor's two resistances and its switching time
        case resistanceAndOwn
        /// Through the parts it is simulated as (see `Circuit.flattened`): a tube's capacitances, a microphone's
        case throughItsParts
        /// None: it changes only as its inputs do, or as fast as it is driven
        case none
    }

    /// What each kind adds to the time scales. Every kind is listed, so a new part is decided on: a part with a time
    /// of its own (an oscillator, an envelope, a delay) that is left out runs at a pace that hides it.
    public static func role(of kind: ElementKind) -> Role {
        switch kind {
        case .resistor, .lamp, .potentiometer:
            return .resistance
        case .memristor:
            return .resistanceAndOwn
        case .capacitor, .inductor, .acVoltage, .squareVoltage, .vactrol, .delayLine, .vco, .vcf, .envelope, .atmega328p,
             .atmega2560, .attiny85, .rp2040, .stm32f405, .stm32f373, .stm32f103, .digitalDelay, .audioInput, .pll,
             .levelDetector, .springReverb, .agcPreamp:
            return .own
        case .triode, .pentode, .transformer, .block, .speaker, .microphone, .electretMic, .pickup, .instrumentationAmp,
             .lineReceiver, .lineDriver, .audioPowerAmp, .compander, .toneControl, .barGraphDriver, .balancedCable,
             .balancedModulator, .mixerOscillator, .tappedTransformer, .functionGenerator, .nortonAmp, .bbdClock,
             .multiTapDelay, .reverbBrick, .analogEngine, .regulator:
            return .throughItsParts
        // drawing parts and instruments
        case .wire, .ground, .netLabel, .port, .probe, .ammeter, .loopProbe, .vuMeter:
            return .none
        // DC, noise and played sources, switches: a step or noise has no time of its own
        case .dcVoltage, .noiseVoltage, .currentSource, .keyboardPitch, .keyboardGate, .toggleSwitch, .pushButton,
             .footswitch, .jack, .behavioralSource:
            return .none
        // semiconductors and amplifiers: as fast as they are driven (their capacitances are far faster than anything shown)
        case .diode, .zener, .led, .npn, .pnp, .nmos, .pmos, .njfet, .pjfet, .opAmp, .ota, .multiplier, .comparator, .vca:
            return .none
        // clocked and logic parts: paced by what clocks them (a 555 by its capacitor, a sketch by its microcontroller)
        case .sampleHold, .divider, .timer555, .schmittInverter, .unbufferedInverter, .analogSwitch, .logicGate, .flipFlop,
             .decadeCounter, .binaryCounter, .analogMux, .analogSelector, .dac, .shiftRegister, .shiftIn, .ledDriver, .ledSink,
             .i2cEeprom, .dualDac, .spiAdc, .i2cDac, .i2sDac, .codec, .cvDac, .effectsProcessor:
            return .none
        }
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
