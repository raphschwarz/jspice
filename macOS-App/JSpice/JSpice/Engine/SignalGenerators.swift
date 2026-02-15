import Foundation

// MARK: - Waveform Type

enum WaveformType: Int, Codable, CaseIterable, Identifiable {
    case sine = 0
    case square = 1
    case triangle = 2
    case sawtooth = 3
    case pulse = 4

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .sine: return "Sine"
        case .square: return "Square"
        case .triangle: return "Triangle"
        case .sawtooth: return "Sawtooth"
        case .pulse: return "Pulse"
        }
    }
}

// MARK: - Signal Generator

/// Generates time-varying signals for use as SPICE excitation sources.
/// Matches the driver system in JSpice (Sine, Square, Triangle, Sawtooth, Pulse drivers).
struct SignalGenerator: Sendable {
    let waveform: WaveformType
    let amplitude: Double
    let frequency: Double
    let phase: Double       // radians
    let dcOffset: Double
    let dutyCycle: Double   // 0...1, for square/pulse

    init(
        waveform: WaveformType = .sine,
        amplitude: Double = 1.0,
        frequency: Double = 1000,
        phase: Double = 0,
        dcOffset: Double = 0,
        dutyCycle: Double = 0.5
    ) {
        self.waveform = waveform
        self.amplitude = amplitude
        self.frequency = frequency
        self.phase = phase
        self.dcOffset = dcOffset
        self.dutyCycle = dutyCycle
    }

    /// Compute instantaneous value at time t
    func value(at t: Double) -> Double {
        let period = 1.0 / frequency
        let phaseOffset = phase / (2.0 * .pi) * period
        let adjustedT = t + phaseOffset

        // Normalized position in cycle [0, 1)
        let cyclePos = (adjustedT / period).truncatingRemainder(dividingBy: 1.0)
        let normalizedPos = cyclePos < 0 ? cyclePos + 1.0 : cyclePos

        let rawValue: Double
        switch waveform {
        case .sine:
            rawValue = sin(2.0 * .pi * normalizedPos)

        case .square:
            rawValue = normalizedPos < dutyCycle ? 1.0 : -1.0

        case .triangle:
            if normalizedPos < 0.25 {
                rawValue = 4.0 * normalizedPos
            } else if normalizedPos < 0.75 {
                rawValue = 2.0 - 4.0 * normalizedPos
            } else {
                rawValue = -4.0 + 4.0 * normalizedPos
            }

        case .sawtooth:
            rawValue = 2.0 * normalizedPos - 1.0

        case .pulse:
            rawValue = normalizedPos < dutyCycle ? 1.0 : 0.0
        }

        return dcOffset + amplitude * rawValue
    }

    /// Generate an array of samples
    func generate(startTime: Double, duration: Double, sampleRate: Double) -> [Double] {
        let count = Int(duration * sampleRate)
        let dt = 1.0 / sampleRate
        return (0..<count).map { i in
            value(at: startTime + Double(i) * dt)
        }
    }
}

// MARK: - Signal Generator as MNA Component

struct MNASignalGenerator: MNAComponent {
    let name: String
    let nodes: [String]
    let isNonlinear = false
    let requiresExtraEquation = true

    var generator: SignalGenerator
    var currentTime: Double = 0

    var positiveNode: String { nodes[0] }
    var negativeNode: String { nodes[1] }

    func stamp(matrix: inout Matrix, rhs: inout Vector, solution: Vector,
               nodeMap: [String: Int], vsMap: [String: Int]) {
        guard let vsIndex = vsMap[name] else { return }
        let ni = nodeIndex(positiveNode, nodeMap: nodeMap)
        let nj = nodeIndex(negativeNode, nodeMap: nodeMap)

        if let ni = ni {
            matrix[ni, vsIndex] += 1
            matrix[vsIndex, ni] += 1
        }
        if let nj = nj {
            matrix[nj, vsIndex] -= 1
            matrix[vsIndex, nj] -= 1
        }

        rhs[vsIndex] = generator.value(at: currentTime)
    }
}
