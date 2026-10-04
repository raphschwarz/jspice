import Foundation

/// A ready-made circuit for the library.
public struct Example: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    /// SF Symbol name for the library
    public let symbol: String
    public let circuit: Circuit
}

/// Builds circuits from grid coordinates.
struct CircuitBuilder {
    var circuit = Circuit()

    @discardableResult
    mutating func add(_ kind: ElementKind, _ a: (Int, Int), _ b: (Int, Int), _ params: [String: Double] = [:],
                      closed: Bool = false, flipped: Bool = false, name: String = "") -> UUID {
        circuit.add(Element(kind: kind, name: name, a: GridPoint(a.0, a.1), b: GridPoint(b.0, b.1), params: params,
                            closed: closed, flipped: flipped))
    }

    /// Wires along a polyline
    mutating func wire(_ points: (Int, Int)...) {
        for i in 0..<(points.count - 1) {
            add(.wire, points[i], points[i + 1])
        }
    }

    mutating func ground(_ p: (Int, Int)) {
        add(.ground, p, (p.0, p.1 + 1))
    }

    mutating func scope(_ id: UUID, _ quantity: Quantity, plot: ScopePlot = .time) {
        circuit.scopes.append(ScopeSpec(elementID: id, quantity: quantity, plot: plot))
    }
}

public enum Examples {
    public static let all: [Example] = [
        ledSwitch, voltageDivider, rcCharging, lowPass, lcOscillator, rectifier, zenerRegulator, dimmer, blinker,
        transistorSwitch, cmosInverter, opAmpAmplifier, lfo, vca, timerFlasher, schmittOscillator, sampleAndHold,
        memristorHysteresis, memristorPulses,
    ]

    /// Parameter values of one of the part's models, by name
    static func model(_ kind: ElementKind, _ name: String) -> [String: Double] {
        kind.models.first { $0.name == name }?.values ?? [:]
    }

    public static func example(_ id: String) -> Example? {
        all.first { $0.id == id }
    }

    static let ledSwitch: Example = {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 6), (0, 2), ["voltage": 9])
        b.wire((0, 2), (0, 0), (2, 0))
        b.add(.toggleSwitch, (2, 0), (6, 0), closed: true)
        b.add(.resistor, (6, 0), (10, 0), ["resistance": 330])
        b.wire((10, 0), (12, 0), (12, 2))
        b.add(.led, (12, 2), (12, 6), ["color": 0])
        b.wire((12, 6), (12, 8), (0, 8), (0, 6))
        b.ground((0, 8))
        return Example(id: "led", title: "LED and switch", summary: "Click the switch to turn the LED on and off.",
                       symbol: "lightbulb", circuit: b.circuit)
    }()

    static let voltageDivider: Example = {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 6), (0, 2), ["voltage": 10])
        b.wire((0, 2), (0, 0), (6, 0))
        b.add(.resistor, (6, 0), (6, 4), ["resistance": 1000])
        b.add(.resistor, (6, 4), (6, 8), ["resistance": 2000])
        b.wire((6, 8), (0, 8), (0, 6))
        b.wire((6, 4), (10, 4))
        b.wire((6, 8), (10, 8))
        b.add(.probe, (10, 4), (10, 8))
        b.ground((0, 8))
        return Example(id: "divider", title: "Voltage divider", summary: "Two resistors split 10 V in the ratio 1 : 2.",
                       symbol: "divide", circuit: b.circuit)
    }()

    static let rcCharging: Example = {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 6), (0, 2), ["voltage": 5])
        b.wire((0, 2), (0, 0), (2, 0))
        b.add(.toggleSwitch, (2, 0), (6, 0), closed: false)
        b.add(.resistor, (6, 0), (10, 0), ["resistance": 10_000])
        b.wire((10, 0), (12, 0), (12, 2))
        let c = b.add(.capacitor, (12, 2), (12, 6), ["capacitance": 100e-6])
        b.wire((12, 0), (16, 0), (16, 2))
        b.add(.resistor, (16, 2), (16, 6), ["resistance": 10_000])
        b.wire((16, 6), (16, 8), (12, 8))
        b.wire((12, 6), (12, 8), (0, 8), (0, 6))
        b.ground((0, 8))
        b.scope(c, .voltage)
        return Example(id: "rc", title: "Capacitor charging", summary: "Close the switch and watch the capacitor charge, in real time.",
                       symbol: "battery.50percent", circuit: b.circuit)
    }()

    static let lowPass: Example = {
        var b = CircuitBuilder()
        let source = b.add(.squareVoltage, (0, 6), (0, 2), ["high": 5, "low": 0, "frequency": 100, "duty": 0.5])
        b.wire((0, 2), (0, 0), (2, 0))
        b.add(.resistor, (2, 0), (6, 0), ["resistance": 1000])
        b.wire((6, 0), (8, 0), (8, 2))
        let c = b.add(.capacitor, (8, 2), (8, 6), ["capacitance": 1e-6])
        b.wire((8, 6), (8, 8), (0, 8), (0, 6))
        b.ground((0, 8))
        b.scope(source, .voltage)
        b.scope(c, .voltage)
        return Example(id: "lowpass", title: "RC low-pass filter", summary: "A 100 Hz square wave rounded off by an RC filter, in slow motion.",
                       symbol: "waveform.path", circuit: b.circuit)
    }()

    static let lcOscillator: Example = {
        var b = CircuitBuilder()
        let c = b.add(.capacitor, (0, 2), (0, 6), ["capacitance": 10e-6, "initialVoltage": 5])
        b.wire((0, 2), (0, 0), (2, 0))
        b.add(.toggleSwitch, (2, 0), (6, 0), closed: false)
        b.wire((6, 0), (8, 0), (8, 2))
        let l = b.add(.inductor, (8, 2), (8, 6), ["inductance": 1])
        b.wire((8, 6), (8, 8), (0, 8), (0, 6))
        b.ground((0, 8))
        b.scope(c, .voltage)
        b.scope(l, .current)
        return Example(id: "lc", title: "LC oscillator", summary: "Close the switch: a charged capacitor and a coil swap energy at 50 Hz.",
                       symbol: "waveform", circuit: b.circuit)
    }()

    static let rectifier: Example = {
        var b = CircuitBuilder()
        let source = b.add(.acVoltage, (0, 6), (0, 2), ["amplitude": 10, "frequency": 60])
        b.wire((0, 2), (0, 0), (2, 0))
        b.add(.diode, (2, 0), (6, 0))
        b.wire((6, 0), (8, 0), (8, 2))
        let c = b.add(.capacitor, (8, 2), (8, 6), ["capacitance": 100e-6])
        b.wire((8, 0), (12, 0), (12, 2))
        b.add(.resistor, (12, 2), (12, 6), ["resistance": 1000])
        b.wire((12, 6), (12, 8), (8, 8), (0, 8), (0, 6))
        b.wire((8, 6), (8, 8))
        b.ground((0, 8))
        b.scope(source, .voltage)
        b.scope(c, .voltage)
        return Example(id: "rectifier", title: "Half-wave rectifier", summary: "A diode and a capacitor turn 60 Hz AC into DC.",
                       symbol: "arrow.right.to.line", circuit: b.circuit)
    }()

    static let transistorSwitch: Example = {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 10), (0, 6), ["voltage": 5])
        b.wire((0, 6), (0, 0))
        b.wire((0, 0), (4, 0))
        b.wire((4, 0), (10, 0))
        b.add(.resistor, (10, 0), (10, 4), ["resistance": 220])
        b.add(.led, (10, 4), (10, 8), ["color": 1])
        b.add(.nmos, (8, 10), (10, 10))
        b.wire((10, 12), (10, 14))
        b.wire((10, 14), (4, 14))
        b.wire((4, 14), (0, 14))
        b.wire((0, 14), (0, 10))
        b.add(.toggleSwitch, (4, 0), (4, 4), closed: false)
        b.wire((4, 4), (4, 10))
        b.wire((4, 10), (8, 10))
        b.add(.resistor, (4, 10), (4, 14), ["resistance": 10_000])
        b.ground((0, 14))
        return Example(id: "nmos", title: "Transistor switch", summary: "A MOSFET lets a small switch current control an LED.",
                       symbol: "switch.2", circuit: b.circuit)
    }()

    static let cmosInverter: Example = {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 10), (0, 6), ["voltage": 5])
        b.wire((0, 6), (0, 0))
        b.wire((0, 0), (2, 0))
        b.wire((2, 0), (8, 0))
        b.wire((8, 0), (8, 4))
        b.add(.pmos, (6, 6), (8, 6))
        b.add(.nmos, (6, 10), (8, 10))
        b.wire((6, 6), (6, 8))
        b.wire((6, 8), (6, 10))
        b.wire((8, 12), (8, 16))
        b.add(.toggleSwitch, (2, 0), (2, 4), closed: false)
        b.wire((2, 4), (2, 8))
        b.wire((2, 8), (6, 8))
        b.add(.resistor, (2, 8), (2, 12), ["resistance": 10_000])
        b.wire((2, 12), (2, 16))
        b.wire((8, 8), (12, 8))
        b.add(.resistor, (12, 8), (12, 12), ["resistance": 330])
        b.add(.led, (12, 12), (12, 16), ["color": 3])
        b.wire((12, 8), (16, 8))
        let probe = b.add(.probe, (16, 8), (16, 16))
        b.wire((0, 10), (0, 16))
        b.wire((0, 16), (2, 16))
        b.wire((2, 16), (8, 16))
        b.wire((8, 16), (12, 16))
        b.wire((12, 16), (16, 16))
        b.ground((0, 16))
        _ = probe
        return Example(id: "cmos", title: "CMOS inverter", summary: "Two transistors invert the input: switch on, LED off.",
                       symbol: "arrow.left.arrow.right", circuit: b.circuit)
    }()

    static let memristorHysteresis: Example = {
        var b = CircuitBuilder()
        let source = b.add(.acVoltage, (0, 6), (0, 2), ["amplitude": 1, "frequency": 1])
        b.wire((0, 2), (0, 0), (2, 0))
        let memristor = b.add(.memristor, (2, 0), (6, 0), ["ron": 1000, "roff": 10_000, "von": 0.3, "voff": 0.3, "tau": 0.05])
        b.add(.resistor, (6, 0), (10, 0), ["resistance": 100])
        b.wire((10, 0), (12, 0), (12, 8), (0, 8), (0, 6))
        b.ground((0, 8))
        b.scope(source, .voltage)
        b.scope(memristor, .resistance)
        b.scope(memristor, .current, plot: .currentVersusVoltage)
        return Example(id: "memristor", title: "Memristor hysteresis", summary: "A 1 Hz sine switches a memristor on and off, tracing its pinched I–V loop.",
                       symbol: "memorychip", circuit: b.circuit)
    }()

    static let zenerRegulator: Example = {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 6), (0, 2), ["voltage": 12])
        b.wire((0, 2), (0, 0), (2, 0))
        b.add(.resistor, (2, 0), (6, 0), ["resistance": 470])
        b.wire((6, 0), (8, 0), (8, 2))
        b.add(.zener, (8, 6), (8, 2), ["breakdown": 5.1])
        b.wire((8, 0), (12, 0), (12, 2))
        b.add(.resistor, (12, 2), (12, 6), ["resistance": 1000])
        b.wire((12, 0), (16, 0), (16, 2))
        b.add(.probe, (16, 2), (16, 6))
        b.wire((16, 6), (16, 8))
        b.wire((0, 6), (0, 8), (8, 8), (12, 8), (16, 8))
        b.wire((8, 6), (8, 8))
        b.wire((12, 6), (12, 8))
        b.ground((0, 8))
        return Example(id: "zener", title: "Zener regulator", summary: "A Zener diode holds the output at 5.1 V. Try changing the 12 V supply.",
                       symbol: "bolt.badge.checkmark", circuit: b.circuit)
    }()

    static let dimmer: Example = {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 10), (0, 6), ["voltage": 9])
        b.wire((0, 6), (0, 0), (6, 0))
        b.wire((6, 0), (16, 0))
        b.wire((6, 0), (6, 2))
        b.add(.potentiometer, (6, 2), (6, 6), ["resistance": 10_000, "position": 0.5])
        b.wire((8, 4), (8, 10))
        b.add(.resistor, (8, 10), (12, 10), ["resistance": 47_000])
        b.wire((12, 10), (14, 10))
        b.add(.npn, (14, 10), (16, 10))
        b.add(.resistor, (16, 0), (16, 4), ["resistance": 330])
        b.add(.led, (16, 4), (16, 8), ["color": 3])
        b.wire((16, 12), (16, 14))
        b.wire((6, 6), (6, 14))
        b.wire((0, 10), (0, 14), (6, 14), (16, 14))
        b.ground((0, 14))
        return Example(id: "dimmer", title: "Light dimmer", summary: "Turn the potentiometer (scroll over it) to dim the LED through a transistor.",
                       symbol: "dial.medium", circuit: b.circuit)
    }()

    static let blinker: Example = {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 10), (0, 6), ["voltage": 9])
        b.wire((0, 6), (0, 0))
        b.wire((0, 0), (4, 0), (8, 0), (12, 0), (16, 0))
        // each side: resistor, LED, transistor
        b.add(.resistor, (4, 0), (4, 3), ["resistance": 470])
        let led1 = b.add(.led, (4, 3), (4, 6), ["color": 0])
        b.wire((4, 6), (4, 9), (4, 10))
        b.add(.npn, (6, 12), (4, 12), flipped: true)
        b.add(.resistor, (16, 0), (16, 3), ["resistance": 470])
        b.add(.led, (16, 3), (16, 6), ["color": 1])
        b.wire((16, 6), (16, 10))
        b.add(.npn, (14, 12), (16, 12))
        // base resistors, slightly unequal so the circuit starts oscillating by itself
        b.add(.resistor, (8, 0), (8, 4), ["resistance": 47_000])
        b.wire((8, 4), (8, 6), (8, 12), (6, 12))
        b.add(.resistor, (12, 0), (12, 4), ["resistance": 51_000])
        b.wire((12, 4), (12, 9), (12, 12), (14, 12))
        // cross-coupling capacitors: each collector drives the other transistor's base (the wires cross unconnected)
        b.wire((4, 9), (9, 9))
        let c1 = b.add(.capacitor, (9, 9), (12, 9), ["capacitance": 10e-6])
        b.wire((16, 6), (11, 6))
        b.add(.capacitor, (11, 6), (8, 6), ["capacitance": 10e-6])
        b.wire((4, 14), (4, 16))
        b.wire((16, 14), (16, 16))
        b.wire((0, 10), (0, 16), (4, 16), (16, 16))
        b.ground((0, 16))
        b.scope(led1, .current)
        b.scope(c1, .voltage)
        return Example(id: "blinker", title: "Blinking LEDs", summary: "Two transistors take turns, flashing the LEDs about once a second.",
                       symbol: "light.beacon.max", circuit: b.circuit)
    }()

    static let opAmpAmplifier: Example = {
        var b = CircuitBuilder()
        let source = b.add(.acVoltage, (0, 9), (0, 5), ["amplitude": 0.5, "frequency": 50])
        b.add(.resistor, (0, 5), (4, 5), ["resistance": 1000])
        b.wire((4, 5), (8, 5))
        let amplifier = b.add(.opAmp, (8, 6), (12, 6))
        b.wire((4, 5), (4, 2))
        b.add(.resistor, (4, 2), (12, 2), ["resistance": 10_000])
        b.wire((12, 2), (12, 6))
        b.wire((12, 6), (16, 6))
        b.add(.probe, (16, 6), (16, 10))
        b.wire((8, 7), (8, 10))
        b.wire((0, 9), (0, 10), (8, 10), (16, 10))
        b.ground((0, 10))
        b.scope(source, .voltage)
        b.scope(amplifier, .voltage)
        return Example(id: "opamp", title: "Op-amp amplifier", summary: "An inverting amplifier with a gain of −10. Raise the input past 1.5 V to see it clip.",
                       symbol: "triangle", circuit: b.circuit)
    }()

    static let lfo: Example = {
        var b = CircuitBuilder()
        let tl072 = model(.opAmp, "TL072")
        // integrator
        let integrator = b.add(.opAmp, (10, 4), (14, 4), tl072)
        b.ground((10, 5))
        b.wire((10, 3), (10, -1))
        b.add(.capacitor, (10, -1), (14, -1), ["capacitance": 1e-6])
        b.wire((14, -1), (14, 4))
        // comparator with hysteresis (a Schmitt trigger): + input from a divider between the triangle and the square
        b.wire((14, 4), (16, 4), (16, 5))
        b.add(.resistor, (16, 5), (20, 5), ["resistance": 10_000])
        let comparator = b.add(.opAmp, (20, 6), (24, 6), tl072, flipped: true)
        b.ground((20, 7))
        b.wire((20, 5), (20, 2))
        b.add(.resistor, (20, 2), (24, 2), ["resistance": 20_000])
        b.wire((24, 2), (26, 2), (26, 6))
        b.wire((24, 6), (26, 6))
        // the square drives the integrator
        b.wire((26, 6), (26, 10), (18, 10))
        b.add(.resistor, (18, 10), (14, 10), ["resistance": 220_000])
        b.wire((14, 10), (8, 10), (8, 3), (10, 3))
        b.scope(integrator, .voltage)
        b.scope(comparator, .voltage)
        return Example(id: "lfo", title: "Triangle and square LFO",
                       summary: "Two TL072 op-amps: an integrator and a Schmitt trigger chase each other at about 2 Hz.",
                       symbol: "waveform.path", circuit: b.circuit)
    }()

    static let vca: Example = {
        var b = CircuitBuilder()
        // audio in, attenuated to a few tens of millivolts for the OTA's inputs
        b.add(.acVoltage, (0, 8), (0, 4), ["amplitude": 5, "frequency": 20])
        b.ground((0, 8))
        b.wire((0, 4), (0, 2), (2, 2))
        b.add(.resistor, (2, 2), (6, 2), ["resistance": 100_000])
        b.add(.resistor, (6, 2), (6, 6), ["resistance": 330])
        b.ground((6, 6))
        b.wire((6, 2), (8, 2))
        b.add(.ota, (8, 3), (12, 3), model(.ota, "LM13700"))
        b.ground((8, 4))
        // control voltage: sets the bias current, and with it the gain
        b.wire((10, 5), (10, 8))
        b.add(.resistor, (10, 8), (14, 8), ["resistance": 15_000])
        b.wire((14, 8), (16, 8))
        let cv = b.add(.acVoltage, (16, 12), (16, 8), ["amplitude": 7, "frequency": 0.5, "offset": -6.8])
        b.ground((16, 12))
        // the output current into a load resistor
        b.wire((12, 3), (18, 3))
        let load = b.add(.resistor, (18, 3), (18, 7), ["resistance": 10_000])
        b.ground((18, 7))
        b.scope(cv, .voltage)
        b.scope(load, .voltage)
        return Example(id: "vca", title: "OTA voltage-controlled amplifier",
                       summary: "An LM13700 OTA: a slow control voltage sets the bias current, so the 20 Hz signal swells and fades.",
                       symbol: "dial.medium", circuit: b.circuit)
    }()

    static let timerFlasher: Example = {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 12), (0, 8), ["voltage": 9])
        b.ground((0, 12))
        b.wire((0, 8), (0, 0), (7, 0), (17, 0))
        let timer = b.add(.timer555, (12, 3), (12, 8), model(.timer555, "NE555"), flipped: true)
        // VCC and RESET to the supply, GND to ground
        b.wire((7, 0), (7, 4), (9, 4))
        b.wire((7, 4), (7, 5), (9, 5))
        b.wire((9, 7), (8, 7), (8, 12))
        b.wire((0, 12), (4, 12), (8, 12), (17, 12))
        // timing: RA from VCC to DIS, RB from DIS to THR and TRIG, C to ground
        b.add(.resistor, (17, 0), (17, 4), ["resistance": 1000])
        b.wire((15, 4), (17, 4))
        b.add(.resistor, (17, 4), (17, 8), ["resistance": 68_000])
        b.wire((15, 5), (16, 5), (16, 6), (16, 8), (17, 8))
        b.wire((15, 6), (16, 6))
        let c = b.add(.capacitor, (17, 8), (17, 12), ["capacitance": 10e-6])
        // the output lights an LED
        b.wire((9, 6), (4, 6))
        b.add(.resistor, (4, 6), (4, 9), ["resistance": 470])
        b.add(.led, (4, 9), (4, 12), ["color": 0])
        b.scope(c, .voltage)
        b.scope(timer, .voltage)
        return Example(id: "555", title: "555 LED flasher",
                       summary: "The classic astable 555: the capacitor charges through RA and RB and discharges through RB, about once a second.",
                       symbol: "timer", circuit: b.circuit)
    }()

    static let schmittOscillator: Example = {
        var b = CircuitBuilder()
        let inverter = b.add(.schmittInverter, (6, 4), (10, 4), model(.schmittInverter, "CD40106"))
        b.wire((10, 4), (10, 1))
        b.add(.resistor, (10, 1), (6, 1), ["resistance": 100_000])
        b.wire((6, 1), (6, 4))
        let c = b.add(.capacitor, (6, 4), (6, 8), ["capacitance": 4.7e-6])
        b.ground((6, 8))
        b.add(.resistor, (10, 4), (14, 4), ["resistance": 680])
        b.add(.led, (14, 4), (14, 8), ["color": 1])
        b.ground((14, 8))
        b.scope(c, .voltage)
        b.scope(inverter, .voltage)
        return Example(id: "schmitt", title: "Schmitt trigger oscillator",
                       summary: "One gate of a 40106 with a resistor and a capacitor: the simplest synth oscillator, here blinking an LED.",
                       symbol: "square.on.square", circuit: b.circuit)
    }()

    static let sampleAndHold: Example = {
        var b = CircuitBuilder()
        let input = b.add(.acVoltage, (0, 8), (0, 4), ["amplitude": 5, "frequency": 0.5])
        b.ground((0, 8))
        b.wire((0, 4), (0, 2), (2, 2))
        b.add(.resistor, (2, 2), (6, 2), ["resistance": 10_000])
        b.add(.analogSwitch, (6, 2), (10, 2), model(.analogSwitch, "CD4066"))
        // a short clock pulse closes the switch four times a second
        b.add(.squareVoltage, (4, -2), (4, -6), ["high": 12, "low": 0, "frequency": 4, "duty": 0.1])
        b.ground((4, -2))
        b.wire((4, -6), (8, -6), (8, 0))
        b.add(.capacitor, (10, 2), (10, 6), ["capacitance": 1e-6])
        b.ground((10, 6))
        // a TL072 buffer reads the held voltage without draining it
        b.wire((10, 2), (12, 2))
        let buffer = b.add(.opAmp, (12, 3), (16, 3), model(.opAmp, "TL072"), flipped: true)
        b.wire((12, 4), (12, 6), (17, 6), (17, 3), (16, 3))
        b.scope(input, .voltage)
        b.scope(buffer, .voltage)
        return Example(id: "sh", title: "Sample and hold",
                       summary: "A CD4066 switch samples a slow sine into a capacitor on each clock pulse; a TL072 buffers the held steps.",
                       symbol: "stairs", circuit: b.circuit)
    }()

    static let memristorPulses: Example = {
        var b = CircuitBuilder()
        b.add(.squareVoltage, (0, 6), (0, 2), ["high": 1, "low": 0, "frequency": 5, "duty": 0.2])
        b.wire((0, 2), (0, 0), (2, 0))
        let memristor = b.add(.memristor, (2, 0), (6, 0), ["ron": 1000, "roff": 10_000, "von": 0.3, "voff": 0.3, "tau": 0.2])
        b.add(.resistor, (6, 0), (10, 0), ["resistance": 100])
        b.wire((10, 0), (12, 0), (12, 8), (0, 8), (0, 6))
        b.ground((0, 8))
        b.scope(memristor, .resistance)
        b.scope(memristor, .current)
        return Example(id: "memristor-pulses", title: "Memristor programming", summary: "Each pulse lowers the memristor's resistance a little.",
                       symbol: "square.stack.3d.up", circuit: b.circuit)
    }()
}
