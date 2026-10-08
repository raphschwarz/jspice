import Foundation

/// A sound an audio input part plays into the circuit: mono, at its own sample rate, kept in the circuit file as
/// 16-bit samples so the file is complete in itself
public struct AudioClip: Codable, Hashable, Sendable {
    public var name: String
    public var sampleRate: Double
    /// Little-endian 16-bit samples
    public var pcm: Data

    /// The longest clip kept, in seconds; longer sounds are cut
    public static let longest = 60.0

    public init(name: String, sampleRate: Double, samples: [Float]) {
        self.name = name
        self.sampleRate = sampleRate
        let count = min(samples.count, Int(Self.longest * sampleRate))
        var pcm = Data(count: count * 2)
        pcm.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for k in 0..<count {
                let s = max(-1, min(1, samples[k]))
                out[k] = Int16(littleEndian: Int16((s * 32767).rounded()))
            }
        }
        self.pcm = pcm
    }

    /// The samples, from −1 to 1
    public var samples: [Float] {
        pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32767 }
        }
    }

    public var duration: Double { Double(pcm.count / 2) / sampleRate }

    /// A clip from a WAV file's contents
    public init(name: String, wav: Data) throws {
        let decoded = try WAV.decode(wav)
        self.init(name: name, sampleRate: decoded.sampleRate, samples: decoded.samples)
    }

    /// A guitar riff to try circuits with: plucked strings (Karplus-Strong), a few notes then a chord, about four
    /// seconds at 48 kHz, peaking near full scale, the same every time
    public static let guitarRiff: AudioClip = {
        let rate = 48_000.0
        // (start in beats, MIDI notes, length in beats) at 100 beats a minute
        let notes: [(Double, [Double], Double)] = [
            (0, [40], 0.5), (0.5, [43], 0.5), (1, [45], 0.5), (1.5, [47], 0.25), (1.75, [45], 0.25),
            (2, [40, 47, 52], 1.5), (3.5, [45, 52, 57], 1.5), (5, [43, 50, 55], 1.75),
        ]
        let beat = 60.0 / 100
        let total = Int(rate * 7 * beat)
        var out = [Double](repeating: 0, count: total)
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func noise() -> Double {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Double(seed >> 11) / Double(1 << 53) * 2 - 1
        }
        for (start, pitches, length) in notes {
            for (k, note) in pitches.enumerated() {
                let frequency = 440 * pow(2, (note - 69) / 12)
                let period = rate / frequency
                let n = max(2, Int(period))
                var line = (0..<n).map { _ in noise() }
                // a strum: each string a little after the last
                let first = Int((start * beat + Double(k) * 0.012) * rate)
                let last = min(total, first + Int(length * beat * rate))
                var index = 0
                for t in first..<last {
                    let next = (index + 1) % n
                    let value = line[index]
                    line[index] = 0.4985 * (value + line[next])
                    index = next
                    // a short fade at the end of the note, as a hand mutes it
                    let fade = min(1, Double(last - t) / (0.02 * rate))
                    out[t] += value * fade * 0.35
                }
            }
        }
        let peak = out.map(abs).max() ?? 1
        return AudioClip(name: "Guitar riff", sampleRate: rate, samples: out.map { Float($0 / peak * 0.95) })
    }()
}

/// Reading and writing WAV files: PCM at 8, 16, 24 or 32 bits, or 32- and 64-bit floating point, any number of
/// channels (mixed down to one when read)
public enum WAV {
    public enum Failure: Error, CustomStringConvertible {
        case notWAV
        case unsupported(String)

        public var description: String {
            switch self {
            case .notWAV: return "That is not a WAV file."
            case .unsupported(let what): return "That WAV file's format is not supported (\(what))."
            }
        }
    }

    public static func decode(_ data: Data) throws -> (sampleRate: Double, samples: [Float]) {
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        guard bytes.count >= 12, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else { throw Failure.notWAV }
        var format = 0, channels = 0, rate = 0, bits = 0
        var dataRange: Range<Int>?
        var i = 12
        while i + 8 <= bytes.count {
            let id = String(bytes: bytes[i..<i + 4], encoding: .ascii) ?? ""
            let size = u32(i + 4)
            let body = i + 8
            guard body + size <= bytes.count || id == "data" else { break }
            if id == "fmt ", size >= 16 {
                format = u16(body)
                channels = u16(body + 2)
                rate = u32(body + 4)
                bits = u16(body + 14)
                // WAVE_FORMAT_EXTENSIBLE: the real format is in the sub-format's first two bytes
                if format == 0xFFFE, size >= 26 { format = u16(body + 24) }
            } else if id == "data" {
                dataRange = body..<min(body + size, bytes.count)
                break
            }
            i = body + size + (size & 1)
        }
        guard let range = dataRange, channels > 0, rate > 0 else { throw Failure.notWAV }
        let width = bits / 8
        guard [1, 3].contains(format), width > 0 else { throw Failure.unsupported("format \(format)") }
        guard format == 1 ? [1, 2, 3, 4].contains(width) : [4, 8].contains(width) else {
            throw Failure.unsupported("\(bits) bits")
        }
        let frame = width * channels
        let frames = range.count / frame
        var samples = [Float](repeating: 0, count: frames)
        bytes.withUnsafeBufferPointer { buffer in
            for f in 0..<frames {
                var sum = 0.0
                for c in 0..<channels {
                    let at = range.lowerBound + f * frame + c * width
                    let value: Double
                    switch (format, width) {
                    case (1, 1): value = (Double(buffer[at]) - 128) / 128
                    case (1, 2): value = Double(Int16(bitPattern: UInt16(buffer[at]) | UInt16(buffer[at + 1]) << 8)) / 32768
                    case (1, 3):
                        let raw = Int32(buffer[at]) | Int32(buffer[at + 1]) << 8 | Int32(buffer[at + 2]) << 16
                        value = Double((raw << 8) >> 8) / 8_388_608
                    case (1, 4):
                        let raw = UInt32(buffer[at]) | UInt32(buffer[at + 1]) << 8 | UInt32(buffer[at + 2]) << 16 | UInt32(buffer[at + 3]) << 24
                        value = Double(Int32(bitPattern: raw)) / 2_147_483_648
                    case (3, 4):
                        let raw = UInt32(buffer[at]) | UInt32(buffer[at + 1]) << 8 | UInt32(buffer[at + 2]) << 16 | UInt32(buffer[at + 3]) << 24
                        value = Double(Float(bitPattern: raw))
                    default:
                        var raw: UInt64 = 0
                        for b in 0..<8 { raw |= UInt64(buffer[at + b]) << (8 * b) }
                        value = Double(bitPattern: raw)
                    }
                    sum += value
                }
                samples[f] = Float(sum / Double(channels))
            }
        }
        return (Double(rate), samples)
    }

    /// A mono WAV file of 24-bit samples (values beyond ±1 are clipped)
    public static func encode(_ samples: [Float], sampleRate: Double) -> Data {
        var data = Data()
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        let rate = Int(sampleRate.rounded())
        append("RIFF")
        append32(36 + samples.count * 3)
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1)
        append16(1)
        append32(rate)
        append32(rate * 3)
        append16(3)
        append16(24)
        append("data")
        append32(samples.count * 3)
        var body = [UInt8](repeating: 0, count: samples.count * 3)
        for (k, sample) in samples.enumerated() {
            let value = Int32((Double(max(-1, min(1, sample))) * 8_388_607).rounded())
            body[3 * k] = UInt8(truncatingIfNeeded: value)
            body[3 * k + 1] = UInt8(truncatingIfNeeded: value >> 8)
            body[3 * k + 2] = UInt8(truncatingIfNeeded: value >> 16)
        }
        data.append(contentsOf: body)
        return data
    }
}

/// What the speaker does to the circuit's voltage before it is heard: scaled to its full scale, with the constant part
/// taken away (a one-pole high-pass at about 4 Hz) and a soft limit above 0.7 of full scale instead of a hard clip. The
/// sound and the offline render share it, so a render sounds like what was heard.
public struct SpeakerShaping {
    private var input = 0.0
    private var output = 0.0
    private let pole: Double
    public let fullScale: Double

    public init(sampleRate: Double, fullScale: Double) {
        pole = exp(-2 * .pi * 4 / sampleRate)
        self.fullScale = max(fullScale, 1e-3)
    }

    /// The sample to play for a voltage, and its level before the limit (above 1 clips)
    public mutating func shape(_ volts: Double) -> (sample: Double, level: Double) {
        let x = volts / fullScale
        let y = x - input + pole * output
        input = x
        output = y
        return (Self.limit(y), abs(y))
    }

    /// Above 0.7 of full scale the output bends softly towards 1 instead of clipping; below it passes unchanged
    public static func limit(_ y: Double) -> Double {
        let magnitude = abs(y)
        guard magnitude > 0.7 else { return y }
        let bent = 0.7 + 0.3 * tanh((magnitude - 0.7) / 0.3)
        return y < 0 ? -bent : bent
    }
}

/// Renders a circuit's sound offline, faster or slower than real time as it takes: the voltage across a part (a
/// speaker), averaged over `oversampling` steps a sample as the live sound does, through the speaker's shaping
public enum AudioRender {
    public struct Result: Sendable {
        public var samples: [Float]
        public var sampleRate: Double
        /// Fraction of samples above full scale (softly limited)
        public var clipped: Double
        public var peak: Double
        public var problems: [String]
    }

    public static func render(_ circuit: Circuit, output index: Int, duration: Double, sampleRate: Double = 48_000,
                              oversampling: Int = 4, fullScale: Double? = nil, keyboard: [(at: Double, note: Double?)] = [],
                              deadline: Date = .distantFuture) -> Result {
        let steps = max(1, oversampling)
        let simulator = Simulator(circuit: circuit, timeStep: 1 / (sampleRate * Double(steps)))
        simulator.errorControl = false
        let scale = fullScale ?? (circuit.elements[index].kind == .speaker ? circuit.elements[index][param: "fullScale"] : 1)
        var shaping = SpeakerShaping(sampleRate: sampleRate, fullScale: scale)
        let count = max(0, Int((duration * sampleRate).rounded()))
        var samples = [Float]()
        samples.reserveCapacity(count)
        var clipped = 0
        var peak = 0.0
        var nextEvent = 0
        for n in 0..<count {
            while nextEvent < keyboard.count && keyboard[nextEvent].at <= Double(n) / sampleRate {
                let event = keyboard[nextEvent]
                simulator.keyboard = Simulator.KeyboardState(note: event.note ?? simulator.keyboard.note, gate: event.note != nil)
                nextEvent += 1
            }
            var sum = 0.0
            for _ in 0..<steps {
                simulator.step()
                sum += simulator.voltageAcross(index)
            }
            if simulator.isFailed { break }
            let (sample, level) = shaping.shape(sum / Double(steps))
            if level > 1 { clipped += 1 }
            peak = max(peak, level)
            samples.append(Float(sample))
            if n % 4800 == 0 && Date() > deadline { break }
        }
        return Result(samples: samples, sampleRate: sampleRate, clipped: samples.isEmpty ? 0 : Double(clipped) / Double(samples.count),
                      peak: peak, problems: simulator.problems)
    }
}
