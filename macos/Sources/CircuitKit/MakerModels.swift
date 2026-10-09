import CryptoKit
import Foundation

/// Where a block made from a maker's model file came from: the file (its name and SHA-256, so the very file can be
/// found again and told from another revision of it), the subcircuit and its pins in the file's order, the comment
/// lines the file starts with (where makers name the part, the model's revision and its terms), when it was imported,
/// and where it was downloaded from, when that is known.
public struct ModelSource: Codable, Hashable, Sendable {
    public var file: String
    public var sha256: String
    public var subcircuit: String
    public var pins: [String]
    public var header: [String]
    public var imported: Date
    public var url: String?

    public init(file: String, sha256: String, subcircuit: String, pins: [String], header: [String], imported: Date,
                url: String? = nil) {
        self.file = file
        self.sha256 = sha256
        self.subcircuit = subcircuit
        self.pins = pins
        self.header = header
        self.imported = imported
        self.url = url
    }
}

/// Makers' model files: a subcircuit of one becomes a block (with the file's provenance), and an op-amp's model can be
/// measured for the figures its datasheet gives, to be set side by side with them.
public enum MakerModels {
    /// A subcircuit a model file defines: its name and pins, in the file's order
    public struct Subcircuit: Sendable, Equatable {
        public var name: String
        public var pins: [String]
    }

    public enum ImportError: Error, CustomStringConvertible {
        case unreadable
        case noSubcircuit
        case unknownSubcircuit(String, [String])
        case notDrawn([String])

        public var description: String {
            switch self {
            case .unreadable: return "The file is not text"
            case .noSubcircuit: return "The file defines no subcircuit (.subckt)"
            case let .unknownSubcircuit(name, known): return "No subcircuit \(name); the file has \(known.joined(separator: ", "))"
            case let .notDrawn(warnings): return "The subcircuit can't be read: \(warnings.joined(separator: "; "))"
            }
        }
    }

    /// The file's text, as UTF-8, UTF-16 or Windows-1252 (as makers write them)
    public static func text(of data: Data) -> String? {
        [String.Encoding.utf8, .utf16, .windowsCP1252].lazy.compactMap { String(data: data, encoding: $0) }.first
    }

    /// The subcircuits a model file defines, in order
    public static func subcircuits(in text: String) -> [Subcircuit] {
        SpiceNetlist.logicalLines(text, titled: false).compactMap { line in
            let words = SpiceNetlist.tokens(line)
            guard words.first?.lowercased() == ".subckt", words.count >= 2 else { return nil }
            return Subcircuit(name: words[1], pins: Array(SpiceNetlist.splitParameters(line).words.dropFirst(2)))
        }
    }

    /// The comment lines a model file starts with, without their stars (PSpice's `*$` too), up to its first statement
    public static func header(of text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard line.hasPrefix("*") else { break }
            let comment = String(line.drop { $0 == "*" || $0 == "$" }).trimmingCharacters(in: .whitespaces)
            if !comment.isEmpty { lines.append(comment) }
            if lines.count >= 60 { break }
        }
        return lines
    }

    /// A file's SHA-256, in hex
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The block of a model file's subcircuit (`subcircuit`, or the file's first), its pins named as the file names them,
    /// with the file's provenance; and what the import left out. The files it includes are read with `include`.
    public static func block(from data: Data, file: String, subcircuit: String? = nil, url: String? = nil,
                             include: SpiceNetlist.Includer? = nil, now: Date = Date()) throws -> (block: BlockDefinition, warnings: [String]) {
        guard let content = Self.text(of: data) else { throw ImportError.unreadable }
        let all = subcircuits(in: content)
        guard let first = all.first else { throw ImportError.noSubcircuit }
        var chosen = first
        if let subcircuit {
            guard let found = all.first(where: { $0.name.lowercased() == subcircuit.lowercased() }) else {
                throw ImportError.unknownSubcircuit(subcircuit, all.map(\.name))
            }
            chosen = found
        }
        // an instance of it, its nets named after its pins, ahead of the file's text (which may end with .end)
        let deck = "maker's model\nX_MODEL \(chosen.pins.joined(separator: " ")) \(chosen.name)\n" + content
        let imported = SpiceNetlist.parse(deck, include: include)
        guard var block = imported.parts.first(where: { $0.name == "X_MODEL" })?.block else {
            throw ImportError.notDrawn(imported.warnings)
        }
        block.name = chosen.name
        block.source = ModelSource(file: file, sha256: sha256(data), subcircuit: chosen.name, pins: chosen.pins,
                                   header: header(of: content), imported: now, url: url)
        return (block, imported.warnings)
    }

    // MARK: - An op-amp's figures

    /// What a datasheet gives for an op-amp, measured on its model with the supplies at ± the supply voltage and the
    /// output loaded (10 kΩ unless given), at 27 °C
    public struct OpAmpFigures: Sendable, Equatable {
        /// The output of a follower with its input at 0 V: the model's input offset voltage
        public var offset: Double
        /// From the positive supply, the output at 0 V
        public var supplyCurrent: Double
        /// Open-loop gain at 0.1 Hz (dB)
        public var openLoopGain: Double
        /// Gain-bandwidth product as datasheets give it: the frequency at which the open-loop gain falls to 40 dB, times
        /// 100 (Hz), where the gain falls at 20 dB a decade
        public var gainBandwidth: Double?
        /// Where the open-loop gain falls to 1 (Hz), and the phase margin there (degrees)
        public var unityGain: Double?
        public var phaseMargin: Double?
        /// A follower's 10 V step through 10 % to 90 %, rising and falling (V/s)
        public var slewRise: Double?
        public var slewFall: Double?
        /// The output driven to each side open loop
        public var swingHigh: Double
        public var swingLow: Double

        /// The figures as a datasheet lists them
        public var lines: [String] {
            func slew(_ v: Double?) -> String { v.map { String(format: "%.3g V/µs", $0 / 1e6) } ?? "—" }
            return [
                "Input offset voltage: " + SI.format(offset, unit: "V"),
                "Supply current: " + SI.format(supplyCurrent, unit: "A"),
                String(format: "Open-loop gain (0.1 Hz): %.1f dB", openLoopGain),
                "Gain-bandwidth product (at 40 dB): " + (gainBandwidth.map { SI.format($0, unit: "Hz") } ?? "—"),
                "Unity-gain frequency: " + (unityGain.map { SI.format($0, unit: "Hz") } ?? "—")
                    + (phaseMargin.map { String(format: ", phase margin %.0f°", $0) } ?? ""),
                "Slew rate (10 V step, 10–90 %): " + slew(slewRise) + " rising, " + slew(slewFall) + " falling",
                String(format: "Output swing: %+.2f V to %+.2f V", swingHigh, swingLow),
            ]
        }
    }

    /// The op-amp `block` with its supplies at ± `supply` and `load` on its output, `input` at its + input, its − input
    /// at its output (a follower) or grounded through a 0 V source
    static func bench(_ block: BlockDefinition, pins: [String], supply: Double, load: Double, input: NetlistPart,
                      follower: Bool) throws -> Circuit {
        var u = NetlistPart(kind: .block, name: "U1")
        u.block = block
        u.connections = [pins[0]: "inp", pins[1]: follower ? "out" : "inn", pins[2]: "vcc", pins[3]: "vee", pins[4]: "out"]
        var parts = [
            u, input,
            NetlistPart(kind: .dcVoltage, name: "VP", params: ["voltage": supply], connections: ["plus": "vcc", "minus": "GND"]),
            NetlistPart(kind: .dcVoltage, name: "VN", params: ["voltage": supply], connections: ["plus": "GND", "minus": "vee"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": load], connections: ["a": "out", "b": "GND"]),
        ]
        if !follower {
            parts.append(NetlistPart(kind: .dcVoltage, name: "VM", params: ["voltage": 0], connections: ["plus": "inn", "minus": "GND"]))
        }
        return try SchematicLayout.layout(parts)
    }

    /// Steps to settle each test circuit in: long steps reach the operating point as surely (the step's error control
    /// shortens them while anything moves), and a maker's model has hundreds of nodes
    static let settlingSteps = 2_000

    public struct MeasurementError: Error, CustomStringConvertible {
        public var description: String
    }

    /// The op-amp `block`'s figures, its pins given in the usual order of a model: non-inverting input, inverting input,
    /// positive supply, negative supply, output. Open-loop gain and phase are measured as datasheets measure them, at a
    /// fixed common-mode voltage: in an inverting stage of gain −1 with the + input grounded, the output over the −
    /// input's small signal (a follower's response would fold the common-mode rejection in).
    public static func measureOpAmp(_ block: BlockDefinition, pins: [String], supply: Double = 15,
                                    load: Double = 10_000, slewGain: Double = 1, stageBudget: TimeInterval? = nil,
                                    report: ((String) -> Void)? = nil) throws -> OpAmpFigures {
        guard pins.count == 5 else { throw MeasurementError(description: "An op-amp has five pins: +in, −in, V+, V−, out") }
        let started = Date()
        /// What each stage cost, for `report`
        func done(_ stage: String, _ simulator: Simulator) {
            guard let report else { return }
            report(String(format: "%@ %@ at %.1f s: %ld steps of %ld substeps (%ld rejected), %ld Newton iterations "
                       + "(%ld damped), %ld solves again for comparators (%ld chattering), %ld convergence failures, "
                       + "%ld plans (%.2f s)", stage, simulator.stopRequested ? "STOPPED" : "done",
                       Date().timeIntervalSince(started), Int((simulator.time / simulator.timeStep).rounded()),
                       simulator.substeps, simulator.rejectedSubsteps, simulator.newtonIterations, simulator.dampedIterations,
                       simulator.decisionSolves, simulator.chatteringSolves, simulator.convergenceFailures, simulator.plans,
                       simulator.planningSeconds))
        }
        /// Steps `simulator` while `going` holds, giving up when the stage has taken `stageBudget`
        func run(_ simulator: Simulator, while going: () -> Bool, each: () -> Void = {}) {
            let stageStarted = Date()
            while going() && !simulator.isFailed {
                if let stageBudget, Date().timeIntervalSince(stageStarted) > stageBudget { simulator.stopRequested = true }
                simulator.step()
                each()
            }
        }
        func circuit(_ input: NetlistPart, follower: Bool) throws -> Circuit {
            try bench(block, pins: pins, supply: supply, load: load, input: input, follower: follower)
        }
        func index(_ c: Circuit, _ name: String) throws -> Int {
            guard let k = c.elements.firstIndex(where: { $0.name == name }) else {
                throw MeasurementError(description: "no \(name) in the test circuit")
            }
            return k
        }
        func dc(_ volts: Double) -> NetlistPart {
            NetlistPart(kind: .dcVoltage, name: "VI", params: ["voltage": volts], connections: ["plus": "inp", "minus": "GND"])
        }

        // a follower at rest: offset and supply current
        let follower = try circuit(dc(0), follower: true)
        let vi = try index(follower, "VI"), rl = try index(follower, "RL"), vp = try index(follower, "VP")
        let rest = Simulator.settled(follower, holding: vi, duration: 0.01, maxSteps: Self.settlingSteps, budget: stageBudget)
        done("follower at rest", rest)
        guard !rest.isFailed else { throw MeasurementError(description: "As a follower it fails: \(rest.problems.joined(separator: "; "))") }
        let offset = rest.terminalVoltage(rl, 0)
        let supplyCurrent = rest.current(vp)

        /// An inverting stage of gain −1 (10 kΩ in, 10 kΩ back) with its + input grounded, `input` (VI) driving it
        func invertingStage(_ input: NetlistPart) throws -> Circuit {
            var u = NetlistPart(kind: .block, name: "U1")
            u.block = block
            u.connections = [pins[0]: "GND", pins[1]: "inn", pins[2]: "vcc", pins[3]: "vee", pins[4]: "out"]
            return try SchematicLayout.layout([
                u, input,
                NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 10_000], connections: ["a": "in", "b": "inn"]),
                NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 10_000], connections: ["a": "inn", "b": "out"]),
                NetlistPart(kind: .dcVoltage, name: "VP", params: ["voltage": supply], connections: ["plus": "vcc", "minus": "GND"]),
                NetlistPart(kind: .dcVoltage, name: "VN", params: ["voltage": supply], connections: ["plus": "GND", "minus": "vee"]),
                NetlistPart(kind: .resistor, name: "RL", params: ["resistance": load], connections: ["a": "out", "b": "GND"]),
            ])
        }

        // the inverting stage at rest, and its small-signal response: the open-loop gain is the output over the − input
        let inverting = try invertingStage(NetlistPart(kind: .dcVoltage, name: "VI", params: ["voltage": 0],
                                                       connections: ["plus": "in", "minus": "GND"]))
        let source = try index(inverting, "VI"), r2 = try index(inverting, "R2")
        let stage = Simulator.settled(inverting, holding: source, duration: 0.01, maxSteps: Self.settlingSteps, budget: stageBudget)
        done("inverting stage at rest", stage)
        guard !stage.isFailed else { throw MeasurementError(description: "As an inverting stage it fails: \(stage.problems.joined(separator: "; "))") }
        let (minus, out) = (stage.nodes(of: r2)[0], stage.nodes(of: r2)[1])
        let frequencies = (0...100).map { pow(10, -1 + Double($0) / 10) }
        guard let model = stage.smallSignalModel(), let response = model.solve(input: source, frequencies: frequencies) else {
            throw MeasurementError(description: "Its small-signal response can't be worked out")
        }
        let openLoop = response.map { v in Complex(0) - v[out] / v[minus] }
        /// Where the gain falls through `level`, log-log between the two points either side, and the fraction between them
        func falls(through level: Double) -> (frequency: Double, k: Int, t: Double)? {
            for k in 1..<openLoop.count where openLoop[k - 1].magnitude >= level && openLoop[k].magnitude < level {
                let (a, b) = (log(openLoop[k - 1].magnitude / level), log(openLoop[k].magnitude / level))
                let t = a / (a - b)
                return (exp(log(frequencies[k - 1]) + t * (log(frequencies[k]) - log(frequencies[k - 1]))), k, t)
            }
            return nil
        }
        let gainBandwidth = falls(through: 100).map { 100 * $0.frequency }
        var unityGain: Double?, phaseMargin: Double?
        for k in 1..<openLoop.count where openLoop[k - 1].magnitude >= 1 && openLoop[k].magnitude < 1 {
            // log-log between the two points
            let (a, b) = (log(openLoop[k - 1].magnitude), log(openLoop[k].magnitude))
            let t = a / (a - b)
            unityGain = exp(log(frequencies[k - 1]) + t * (log(frequencies[k]) - log(frequencies[k - 1])))
            var (pa, pb) = (openLoop[k - 1].phase, openLoop[k].phase)
            if pb - pa > Double.pi { pb -= 2 * Double.pi } else if pa - pb > Double.pi { pb += 2 * Double.pi }
            phaseMargin = 180 + (pa + t * (pb - pa)) * 180 / Double.pi
            break
        }

        // 10 V steps, into a follower or the inverting stage as the datasheet measures (`slewGain` +1 or −1): slew rate
        // through 10 % to 90 % of the output's swing, at the highest of 10 kHz, 1 kHz and 100 Hz at which the output gets
        // there within half a period
        var slewRise: Double?, slewFall: Double?
        let (low, high) = (-5.0, 5.0)
        let (from, to) = (low + 0.1 * (high - low), low + 0.9 * (high - low))
        let inverts = slewGain < 0
        for frequency in [10_000.0, 1_000, 100] where slewRise == nil {
            let square = NetlistPart(kind: .squareVoltage, name: "VI", params: ["low": low, "high": high, "frequency": frequency, "duty": 0.5],
                                     connections: ["plus": inverts ? "in" : "inp", "minus": "GND"])
            let c = try inverts ? invertingStage(square) : circuit(square, follower: true)
            let input = try index(c, "VI"), output = try index(c, "RL")
            let period = 1 / frequency
            // (a slewing edge is straight: its 10 % and 90 % crossings come out of a few points on it exactly)
            let simulator = Simulator(circuit: c, timeStep: period / 4_000)
            var times: [Double] = [], ins: [Double] = [], outs: [Double] = []
            run(simulator, while: { simulator.time < 2 * period }) {
                times.append(simulator.time)
                ins.append(simulator.terminalVoltage(input, 1))  // (its plus terminal)
                outs.append(simulator.terminalVoltage(output, 0))
            }
            done(String(format: "slewing at %g Hz", frequency), simulator)
            if simulator.stopRequested { break }
            guard !simulator.isFailed else { continue }
            /// The time `values` cross `level` going the way `rising` says, after `start`
            func crossing(_ values: [Double], _ level: Double, rising: Bool, after start: Double) -> Double? {
                for k in 1..<values.count where times[k] > start {
                    let (a, b) = (values[k - 1], values[k])
                    if rising ? (a < level && b >= level) : (a > level && b <= level) {
                        return times[k - 1] + (level - a) / (b - a) * (times[k] - times[k - 1])
                    }
                }
                return nil
            }
            // the edges after the first period, when the op-amp has powered up; the output's crossings looked for from a
            // little before the input's (it can jump at the step's instant, through the inputs' clamp diodes)
            let span = to - from
            if let edge = crossing(ins, 0, rising: !inverts, after: period),
               let a = crossing(outs, from, rising: true, after: edge - period / 100),
               let b = crossing(outs, to, rising: true, after: a), b < edge + period / 2 {
                slewRise = span / (b - a)
            }
            if let edge = crossing(ins, 0, rising: inverts, after: period),
               let a = crossing(outs, to, rising: false, after: edge - period / 100),
               let b = crossing(outs, from, rising: false, after: a), b < edge + period / 2 {
                slewFall = span / (b - a)
            }
        }

        // open loop, from rest, its input rising as a quarter of a sine to ±0.1 V over 2.5 ms: the output driven to each
        // side gently (a step at long steps throws a maker's model's clamps into a fight)
        func swing(_ sign: Double) throws -> Double {
            let sine = NetlistPart(kind: .acVoltage, name: "VI", params: ["offset": 0, "amplitude": sign * 0.1, "frequency": 100],
                                   connections: ["plus": "inp", "minus": "GND"])
            let open = try circuit(sine, follower: false)
            let output = try index(open, "RL")
            let driven = Simulator(circuit: open, timeStep: 2e-6)
            run(driven, while: { driven.time < 0.0025 })
            done(sign > 0 ? "swinging high" : "swinging low", driven)
            guard !driven.isFailed else {
                throw MeasurementError(description: "Driven open loop it fails: \(driven.problems.joined(separator: "; "))")
            }
            return driven.terminalVoltage(output, 0)
        }
        let (swingHigh, swingLow) = (try swing(1), try swing(-1))
        return OpAmpFigures(offset: offset, supplyCurrent: supplyCurrent,
                            openLoopGain: 20 * log10(openLoop[0].magnitude), gainBandwidth: gainBandwidth,
                            unityGain: unityGain, phaseMargin: phaseMargin,
                            slewRise: slewRise, slewFall: slewFall, swingHigh: swingHigh, swingLow: swingLow)
    }
}
