import Foundation

// MARK: - Simulation Result

struct SimulationResult: Sendable {
    let analysisType: AnalysisType
    let nodeVoltages: [String: [Double]]
    let branchCurrents: [String: [Double]]
    let timePoints: [Double]?
    let frequencyPoints: [Double]?
    let timestamp: Date

    enum AnalysisType: String, Sendable {
        case dcOperatingPoint
        case dcSweep
        case transient
        case acAnalysis
    }

    // MARK: - Convenience accessors

    var allSignalNames: [String] {
        Array(nodeVoltages.keys) + Array(branchCurrents.keys)
    }

    func voltage(atNode node: String) -> [Double]? {
        nodeVoltages[node]
    }

    func current(inBranch branch: String) -> [Double]? {
        branchCurrents[branch]
    }

    /// DC operating point: single-value results
    var dcVoltages: [String: Double] {
        nodeVoltages.compactMapValues { $0.first }
    }

    var dcCurrents: [String: Double] {
        branchCurrents.compactMapValues { $0.first }
    }
}

// MARK: - AC Result (complex values)

struct ACSimulationResult: Sendable {
    let frequencies: [Double]
    let magnitude: [String: [Double]]  // dB
    let phase: [String: [Double]]      // degrees
    let timestamp: Date

    var allSignalNames: [String] {
        Array(magnitude.keys)
    }
}

// MARK: - Waveform Data for Display

struct WaveformData: Identifiable {
    let id = UUID()
    let name: String
    let xValues: [Double]
    let yValues: [Double]
    let xLabel: String
    let yLabel: String
    let color: WaveformColor

    enum WaveformColor: CaseIterable {
        case blue, green, red, orange, purple, cyan, yellow, pink

        var hue: Double {
            switch self {
            case .blue: return 0.6
            case .green: return 0.33
            case .red: return 0.0
            case .orange: return 0.08
            case .purple: return 0.75
            case .cyan: return 0.5
            case .yellow: return 0.15
            case .pink: return 0.9
            }
        }
    }
}

extension SimulationResult {
    func waveforms(forNodes nodes: [String]? = nil) -> [WaveformData] {
        guard let time = timePoints else { return [] }
        let colors = WaveformData.WaveformColor.allCases
        var result: [WaveformData] = []
        let targetNodes = nodes ?? Array(nodeVoltages.keys.sorted())

        for (index, node) in targetNodes.enumerated() {
            if let values = nodeVoltages[node] {
                result.append(WaveformData(
                    name: "V(\(node))",
                    xValues: time,
                    yValues: values,
                    xLabel: "Time (s)",
                    yLabel: "Voltage (V)",
                    color: colors[index % colors.count]
                ))
            }
        }
        return result
    }
}
