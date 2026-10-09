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

    /// What a datasheet gives for an op-amp, measured on its model with the supplies at ± the supply voltage, at 27 °C
    public struct OpAmpFigures: Sendable, Equatable {
        /// The output of a follower with its input at 0 V: the model's input offset voltage
        public var offset: Double
        /// From the positive supply, the output at 0 V into 10 kΩ
        public var supplyCurrent: Double
        /// Open-loop gain at 0.1 Hz (dB)
        public var openLoopGain: Double
        /// Where the open-loop gain falls to 1 (Hz), and the phase margin there (degrees)
        public var unityGain: Double?
        public var phaseMargin: Double?
        /// A follower's 10 V step through 10 % to 90 %, rising and falling (V/s)
        public var slewRise: Double?
        public var slewFall: Double?
        /// The output driven to each side open loop, into 10 kΩ
        public var swingHigh: Double
        public var swingLow: Double

        /// The figures as a datasheet lists them
        public var lines: [String] {
            func slew(_ v: Double?) -> String { v.map { String(format: "%.3g V/µs", $0 / 1e6) } ?? "—" }
            return [
                "Input offset voltage: " + SI.format(offset, unit: "V"),
                "Supply current: " + SI.format(supplyCurrent, unit: "A"),
                String(format: "Open-loop gain (0.1 Hz): %.1f dB", openLoopGain),
                "Unity-gain frequency: " + (unityGain.map { SI.format($0, unit: "Hz") } ?? "—")
                    + (phaseMargin.map { String(format: ", phase margin %.0f°", $0) } ?? ""),
                "Slew rate (10 V step, 10–90 %): " + slew(slewRise) + " rising, " + slew(slewFall) + " falling",
                String(format: "Output swing into 10 kΩ: %+.2f V to %+.2f V", swingHigh, swingLow),
            ]
        }
    }

    public struct MeasurementError: Error, CustomStringConvertible {
        public var description: String
    }

    /// The op-amp `block`'s figures, its pins given in the usual order of a model: non-inverting input, inverting input,
    /// positive supply, negative supply, output. Open-loop gain and phase are worked out from a follower's small-signal
    /// response H as H / (1 − H), so the model is measured where it is biased as in use.
    public static func measureOpAmp(_ block: BlockDefinition, pins: [String], supply: Double = 15) throws -> OpAmpFigures {
        guard pins.count == 5 else { throw MeasurementError(description: "An op-amp has five pins: +in, −in, V+, V−, out") }
        let load = 10_000.0
        /// The op-amp with its supplies and load, `input` at its + input, its − input at its output or grounded
        func circuit(_ input: NetlistPart, follower: Bool) throws -> Circuit {
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
        func index(_ c: Circuit, _ name: String) throws -> Int {
            guard let k = c.elements.firstIndex(where: { $0.name == name }) else {
                throw MeasurementError(description: "no \(name) in the test circuit")
            }
            return k
        }
        func dc(_ volts: Double) -> NetlistPart {
            NetlistPart(kind: .dcVoltage, name: "VI", params: ["voltage": volts], connections: ["plus": "inp", "minus": "GND"])
        }

        // a follower at rest: offset and supply current, then its small-signal response
        let follower = try circuit(dc(0), follower: true)
        let vi = try index(follower, "VI"), rl = try index(follower, "RL"), vp = try index(follower, "VP")
        let rest = Simulator.settled(follower, holding: vi, duration: 0.01, maxSteps: 100_000)
        guard !rest.isFailed else { throw MeasurementError(description: "As a follower it fails: \(rest.problems.joined(separator: "; "))") }
        let offset = rest.terminalVoltage(rl, 0)
        let supplyCurrent = rest.current(vp)
        let out = rest.nodes(of: rl)[0]
        let frequencies = (0...100).map { pow(10, -1 + Double($0) / 10) }
        guard let model = rest.smallSignalModel(), let response = model.solve(input: vi, frequencies: frequencies) else {
            throw MeasurementError(description: "Its small-signal response can't be worked out")
        }
        let openLoop = response.map { h in h[out] / (Complex(1) - h[out]) }
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

        // a follower's 10 V steps: slew rate through 10 % to 90 %, at the highest of 10 kHz, 1 kHz and 100 Hz at which
        // the output gets there within half a period
        var slewRise: Double?, slewFall: Double?
        let (low, high) = (-5.0, 5.0)
        let (from, to) = (low + 0.1 * (high - low), low + 0.9 * (high - low))
        for frequency in [10_000.0, 1_000, 100] where slewRise == nil {
            let square = NetlistPart(kind: .squareVoltage, name: "VI", params: ["low": low, "high": high, "frequency": frequency, "duty": 0.5],
                                     connections: ["plus": "inp", "minus": "GND"])
            let c = try circuit(square, follower: true)
            let input = try index(c, "VI"), output = try index(c, "RL")
            let period = 1 / frequency
            let simulator = Simulator(circuit: c, timeStep: period / 20_000)
            var times: [Double] = [], ins: [Double] = [], outs: [Double] = []
            while simulator.time < 2.5 * period && !simulator.isFailed {
                simulator.step()
                times.append(simulator.time)
                ins.append(simulator.terminalVoltage(input, 1))  // (its plus terminal)
                outs.append(simulator.terminalVoltage(output, 0))
            }
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
            // the edges after the first period, when the op-amp has powered up
            let span = to - from
            if let edge = crossing(ins, 0, rising: true, after: period), let a = crossing(outs, from, rising: true, after: edge),
               let b = crossing(outs, to, rising: true, after: a), b < edge + period / 2 {
                slewRise = span / (b - a)
            }
            if let edge = crossing(ins, 0, rising: false, after: period), let a = crossing(outs, to, rising: false, after: edge),
               let b = crossing(outs, from, rising: false, after: a), b < edge + period / 2 {
                slewFall = span / (b - a)
            }
        }

        // open loop, driven to each side
        func swing(_ volts: Double) throws -> Double {
            let c = try circuit(dc(volts), follower: false)
            let s = Simulator.settled(c, holding: try index(c, "VI"), duration: 0.01, maxSteps: 100_000)
            guard !s.isFailed else { throw MeasurementError(description: "Driven open loop it fails: \(s.problems.joined(separator: "; "))") }
            return s.terminalVoltage(try index(c, "RL"), 0)
        }
        return OpAmpFigures(offset: offset, supplyCurrent: supplyCurrent,
                            openLoopGain: 20 * log10(openLoop[0].magnitude), unityGain: unityGain, phaseMargin: phaseMargin,
                            slewRise: slewRise, slewFall: slewFall, swingHigh: try swing(0.1), swingLow: try swing(-0.1))
    }
}
