import Foundation

/// Examples for the pedal op-amps, ring modulators and the other chips added with them
extension Examples {
    static let chipExamples: [Example] = [tubeScreamer, rat]

    private static func part(_ kind: ElementKind, _ name: String, _ params: [String: Double] = [:], _ connections: [String: String])
        -> NetlistPart {
        NetlistPart(kind: kind, name: name, params: params, connections: connections)
    }

    private static func r(_ name: String, _ ohms: Double, _ a: String, _ b: String) -> NetlistPart {
        part(.resistor, name, ["resistance": ohms], ["a": a, "b": b])
    }

    private static func c(_ name: String, _ farads: Double, _ a: String, _ b: String) -> NetlistPart {
        part(.capacitor, name, ["capacitance": farads], ["a": a, "b": b])
    }

    private static func diode(_ name: String, _ model: String, anode: String, cathode: String) -> NetlistPart {
        part(.diode, name, Examples.model(.diode, model), ["anode": anode, "cathode": cathode])
    }

    /// An op-amp on a single 9 V supply: swinging about the 4.5 V reference, a few volts each way
    private static func pedalOpAmp(_ name: String, _ model: String, swing: Double, plus: String, minus: String, out: String) -> NetlistPart {
        part(.opAmp, name, Examples.model(.opAmp, model).merging(["limit": swing, "midpoint": 4.5]) { $1 },
             ["plus": plus, "minus": minus, "out": out])
    }

    /// A pot wired as a variable resistor between `a` and `b` (the wiper joined to `b`)
    private static func rheostat(_ name: String, _ ohms: Double, position: Double, audio: Bool, _ a: String, _ b: String) -> NetlistPart {
        part(.potentiometer, name, ["resistance": ohms, "position": position, "taper": audio ? 1 : 0], ["a": a, "b": b, "wiper": b])
    }

    /// A 9 V battery and the half-supply reference a pedal's op-amps work about
    private static func pedalSupply(divider: Double, filter: Double) -> [NetlistPart] {
        [
            part(.dcVoltage, "VB", ["voltage": 9], ["plus": "+9V", "minus": "GND"]),
            r("RA", divider, "+9V", "vref"),
            r("RB", divider, "vref", "GND"),
            c("CREF", filter, "vref", "GND"),
        ]
    }

    private static func guitar(level: Double = 0.15) -> NetlistPart {
        part(.audioInput, "GTR", ["level": level, "loop": 1], ["plus": "gtr", "minus": "GND"])
    }

    // MARK: - Pedals

    /// The Tube Screamer's clipping stage and tone control: a JRC4558 with two diodes in its feedback, so the drive
    /// clips softly, and only above the 720 Hz its gain leg passes (the bass stays clean: the mid hump)
    static let tubeScreamer = Example(
        id: "tube-screamer", title: "Tube Screamer overdrive (sound)",
        summary: "The TS808's heart on a 9 V battery: one half of a JRC4558 amplifies by 1 + (51 kΩ + DRIVE) / 4.7 kΩ, but its 4.7 kΩ leg goes to the 4.5 V reference through 47 nF, so only the frequencies above about 720 Hz are amplified and clipped by the two 1N4148s in its feedback: the soft, mid-heavy overdrive. A 1 kΩ and 220 nF filter tames the fizz, and the other half is the active TONE control. Turn on sound and turn DRIVE and TONE.",
        symbol: "flame.fill",
        circuit: drawn(pedalSupply(divider: 10_000, filter: 47e-6) + [
            guitar(),
            c("C1", 47e-9, "gtr", "in"),
            r("R1", 1e6, "in", "vref"),
            pedalOpAmp("U1", "JRC4558", swing: 3.2, plus: "in", minus: "fb", out: "drv"),
            r("R2", 4700, "fb", "leg"),
            c("C2", 47e-9, "leg", "vref"),
            r("R3", 51_000, "drv", "f1"),
            rheostat("DRIVE", 500_000, position: 0.5, audio: true, "f1", "fb"),
            c("C3", 51e-12, "drv", "fb"),
            diode("D1", "1N4148", anode: "drv", cathode: "fb"),
            diode("D2", "1N4148", anode: "fb", cathode: "drv"),
            r("R4", 1000, "drv", "t1"),
            c("C4", 220e-9, "t1", "vref"),
            r("R5", 1000, "t1", "p2"),
            pedalOpAmp("U2", "JRC4558", swing: 3.2, plus: "p2", minus: "n2", out: "o2"),
            r("R6", 1000, "o2", "n2"),
            r("R7", 220, "p2", "ta"),
            r("R8", 1000, "n2", "tb"),
            part(.potentiometer, "TONE", ["resistance": 20_000, "position": 0.5, "taper": 0], ["a": "ta", "b": "tb", "wiper": "tw"]),
            c("C5", 220e-9, "tw", "vref"),
            r("R9", 1000, "o2", "o3"),
            c("C6", 10e-6, "o3", "o4"),
            part(.potentiometer, "LEVEL", ["resistance": 100_000, "position": 0.7, "taper": 1], ["a": "o4", "b": "GND", "wiper": "out"]),
            part(.speaker, "SPK1", ["fullScale": 1.5], ["plus": "out", "minus": "GND"]),
        ], scopes: [("GTR", .voltage), ("SPK1", .voltage)]))

    /// The RAT: an LM308 whose slow slewing (0.3 V/µs with its 30 pF) is part of the sound, two gain legs that boost
    /// the treble most, and hard clipping by two diodes to ground
    static let rat = Example(
        id: "rat", title: "RAT distortion (sound)",
        summary: "The ProCo RAT's circuit on 9 V: an LM308 with up to 100 kΩ of DISTORTION over two legs to ground (47 Ω with 2.2 µF, 560 Ω with 4.7 µF), a gain of over 2000 in the treble. At high gain the LM308 cannot slew fast enough (0.3 V/µs), which rounds and thickens the sound. Two 1N4148s to ground clip hard, and FILTER sweeps a low-pass from bright to dark. Turn on sound.",
        symbol: "bolt.fill",
        circuit: drawn(pedalSupply(divider: 100_000, filter: 10e-6) + [
            guitar(),
            c("C1", 22e-9, "gtr", "in"),
            r("R1", 1e6, "in", "vref"),
            pedalOpAmp("U1", "LM308", swing: 3.5, plus: "in", minus: "fb", out: "drv"),
            rheostat("DISTORTION", 100_000, position: 0.6, audio: true, "drv", "fb"),
            c("C2", 100e-12, "drv", "fb"),
            r("R2", 47, "fb", "l1"),
            c("C3", 2.2e-6, "l1", "GND"),
            r("R3", 560, "fb", "l2"),
            c("C4", 4.7e-6, "l2", "GND"),
            c("C5", 4.7e-6, "drv", "c1"),
            r("R4", 1000, "c1", "clip"),
            diode("D1", "1N4148", anode: "clip", cathode: "GND"),
            diode("D2", "1N4148", anode: "GND", cathode: "clip"),
            r("R5", 1500, "clip", "f1"),
            rheostat("FILTER", 100_000, position: 0.2, audio: false, "f1", "flt"),
            c("C6", 3.3e-9, "flt", "GND"),
            c("C7", 1e-6, "flt", "o1"),
            part(.potentiometer, "VOLUME", ["resistance": 100_000, "position": 0.7, "taper": 1], ["a": "o1", "b": "GND", "wiper": "out"]),
            part(.speaker, "SPK1", ["fullScale": 1], ["plus": "out", "minus": "GND"]),
        ], scopes: [("GTR", .voltage), ("SPK1", .voltage)]))
}
