import Foundation

// MARK: - Simulation Controller

@MainActor
final class SimulationController: ObservableObject {
    @Published var isRunning = false
    @Published var statusMessage: String?
    @Published var latestResult: SimulationResult?
    @Published var latestACResult: ACSimulationResult?
    @Published var audioEnabled = false
    @Published var progress: Double = 0

    private var currentTask: Task<Void, Never>?
    private let engine = SimulationEngine()
    private var audioEngine: AudioEngine?

    // MARK: - DC Operating Point

    func runDCOperatingPoint(document: CircuitDocument) async {
        isRunning = true
        statusMessage = "Running DC operating point..."
        progress = 0

        do {
            let netlist = NetlistGenerator.generate(from: document)
            let solution = try await engine.solveDCOperatingPoint(netlist: netlist)

            latestResult = SimulationResult(
                analysisType: .dcOperatingPoint,
                nodeVoltages: solution.nodeVoltages.mapValues { [$0] },
                branchCurrents: solution.branchCurrents.mapValues { [$0] },
                timePoints: nil,
                frequencyPoints: nil,
                timestamp: Date()
            )
            statusMessage = "DC operating point complete"
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }

        progress = 1
        isRunning = false
    }

    // MARK: - Transient Analysis

    func runTransientAnalysis(document: CircuitDocument) async {
        isRunning = true
        statusMessage = "Running transient analysis..."
        progress = 0

        currentTask = Task {
            do {
                let config = document.simulationConfig.transient
                let result = try await engine.runTransientAnalysis(
                    document: document,
                    startTime: config.startTime,
                    stopTime: config.stopTime,
                    timeStep: config.timeStep,
                    progressCallback: { [weak self] p in
                        Task { @MainActor in
                            self?.progress = p
                        }
                    }
                )

                if !Task.isCancelled {
                    await MainActor.run {
                        self.latestResult = result
                        self.statusMessage = "Transient analysis complete"

                        if self.audioEnabled {
                            self.routeToAudio(result: result)
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.statusMessage = "Error: \(error.localizedDescription)"
                    }
                }
            }

            await MainActor.run {
                self.progress = 1
                self.isRunning = false
            }
        }
    }

    // MARK: - AC Analysis

    func runACAnalysis(document: CircuitDocument) async {
        isRunning = true
        statusMessage = "Running AC analysis..."
        progress = 0

        do {
            let config = document.simulationConfig.acAnalysis
            let result = try await engine.runACAnalysis(
                document: document,
                startFreq: config.startFrequency,
                stopFreq: config.stopFrequency,
                pointsPerDecade: config.pointsPerDecade,
                progressCallback: { [weak self] p in
                    Task { @MainActor in
                        self?.progress = p
                    }
                }
            )

            latestACResult = result
            statusMessage = "AC analysis complete"
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }

        progress = 1
        isRunning = false
    }

    // MARK: - Control

    func stopSimulation() {
        currentTask?.cancel()
        currentTask = nil
        isRunning = false
        statusMessage = "Simulation stopped"
    }

    func documentDidChange(_ document: CircuitDocument) {
        // Could trigger live re-simulation here
    }

    func setAudioEnabled(_ enabled: Bool) {
        audioEnabled = enabled
        if !enabled {
            audioEngine?.stop()
            audioEngine = nil
        }
    }

    // MARK: - Audio Routing

    private func routeToAudio(result: SimulationResult) {
        guard let firstNode = result.nodeVoltages.keys.sorted().first,
              let samples = result.nodeVoltages[firstNode],
              let timePoints = result.timePoints,
              timePoints.count >= 2 else { return }

        let sampleRate = 1.0 / (timePoints[1] - timePoints[0])

        if audioEngine == nil {
            audioEngine = AudioEngine()
        }
        audioEngine?.loadSamples(samples, sampleRate: sampleRate)
        audioEngine?.play()
    }
}

// MARK: - Simulation Engine (runs off main thread)

actor SimulationEngine {
    private let solver = MNASolver()

    // MARK: - DC Operating Point

    func solveDCOperatingPoint(netlist: MNASolver.Netlist) throws -> MNASolution {
        try runBlockingSolve(netlist: netlist)
    }

    private func runBlockingSolve(netlist: MNASolver.Netlist) throws -> MNASolution {
        // We need to call the solver synchronously but it's an actor
        // Use a semaphore pattern for synchronous bridge
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<MNASolution, Error>!

        Task {
            do {
                let solution = try await solver.solve(netlist: netlist)
                result = .success(solution)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    // MARK: - Transient Analysis

    func runTransientAnalysis(
        document: CircuitDocument,
        startTime: Double,
        stopTime: Double,
        timeStep: Double,
        progressCallback: @Sendable @escaping (Double) -> Void
    ) throws -> SimulationResult {
        let totalSteps = Int((stopTime - startTime) / timeStep)
        var timePoints: [Double] = []
        var nodeVoltageHistory: [String: [Double]] = [:]
        var branchCurrentHistory: [String: [Double]] = [:]

        // Track companion model state
        var capacitorStates: [String: (voltage: Double, current: Double)] = [:]
        var inductorStates: [String: (voltage: Double, current: Double)] = [:]

        timePoints.reserveCapacity(totalSteps)

        for step in 0...totalSteps {
            try Task.checkCancellation()

            let currentTime = startTime + Double(step) * timeStep

            // Build netlist for this time step with updated companion models
            var netlist = NetlistGenerator.generate(
                from: document,
                time: currentTime,
                timeStep: timeStep,
                capacitorStates: capacitorStates,
                inductorStates: inductorStates
            )

            // Solve
            let solution = try runBlockingSolve(netlist: netlist)

            // Record results
            timePoints.append(currentTime)
            for (node, voltage) in solution.nodeVoltages {
                nodeVoltageHistory[node, default: []].append(voltage)
            }
            for (branch, current) in solution.branchCurrents {
                branchCurrentHistory[branch, default: []].append(current)
            }

            // Update companion model states for next step
            updateCompanionStates(
                document: document,
                solution: solution,
                capacitorStates: &capacitorStates,
                inductorStates: &inductorStates
            )

            // Progress update every 1%
            if step % max(totalSteps / 100, 1) == 0 {
                progressCallback(Double(step) / Double(totalSteps))
            }
        }

        return SimulationResult(
            analysisType: .transient,
            nodeVoltages: nodeVoltageHistory,
            branchCurrents: branchCurrentHistory,
            timePoints: timePoints,
            frequencyPoints: nil,
            timestamp: Date()
        )
    }

    // MARK: - AC Analysis

    func runACAnalysis(
        document: CircuitDocument,
        startFreq: Double,
        stopFreq: Double,
        pointsPerDecade: Int,
        progressCallback: @Sendable @escaping (Double) -> Void
    ) throws -> ACSimulationResult {
        // Generate frequency points (logarithmic)
        let decades = log10(stopFreq / startFreq)
        let totalPoints = Int(decades * Double(pointsPerDecade))
        var frequencies: [Double] = []
        var magnitudes: [String: [Double]] = [:]
        var phases: [String: [Double]] = [:]

        for i in 0...totalPoints {
            try Task.checkCancellation()

            let freq = startFreq * pow(10, Double(i) / Double(pointsPerDecade))
            frequencies.append(freq)

            // For AC analysis, we solve at the DC operating point,
            // then compute the small-signal response at each frequency.
            // Simplified: use transient with short burst and measure gain/phase
            let omega = 2.0 * .pi * freq
            let period = 1.0 / freq
            let simTime = 5 * period  // 5 cycles for steady state
            let dt = period / 100     // 100 points per cycle

            let result = try runTransientAnalysis(
                document: document,
                startTime: 0,
                stopTime: simTime,
                timeStep: dt,
                progressCallback: { _ in }
            )

            // Measure output amplitude and phase relative to input
            // Take last 2 cycles for measurement
            for (node, values) in result.nodeVoltages {
                let lastQuarter = Array(values.suffix(values.count / 4))
                let maxVal = lastQuarter.max() ?? 0
                let minVal = lastQuarter.min() ?? 0
                let amplitude = (maxVal - minVal) / 2.0

                magnitudes[node, default: []].append(20 * log10(max(amplitude, 1e-30)))
                phases[node, default: []].append(0)  // Simplified; full impl would use cross-correlation
            }

            progressCallback(Double(i) / Double(totalPoints))
        }

        return ACSimulationResult(
            frequencies: frequencies,
            magnitude: magnitudes,
            phase: phases,
            timestamp: Date()
        )
    }

    // MARK: - Helper

    private func updateCompanionStates(
        document: CircuitDocument,
        solution: MNASolution,
        capacitorStates: inout [String: (voltage: Double, current: Double)],
        inductorStates: inout [String: (voltage: Double, current: Double)]
    ) {
        for component in document.components {
            let label = component.label
            switch component.type {
            case .capacitor:
                let nodes = nodeNamesForComponent(component, in: document)
                let v1 = solution.voltage(at: nodes.0)
                let v2 = solution.voltage(at: nodes.1)
                let voltage = v1 - v2
                let cap = component.parameters["capacitance"]?.value ?? 1e-6
                let prevV = capacitorStates[label]?.voltage ?? 0
                let dt = document.simulationConfig.transient.timeStep
                let current = cap * (voltage - prevV) / dt
                capacitorStates[label] = (voltage: voltage, current: current)

            case .inductor:
                let nodes = nodeNamesForComponent(component, in: document)
                let v1 = solution.voltage(at: nodes.0)
                let v2 = solution.voltage(at: nodes.1)
                let voltage = v1 - v2
                let ind = component.parameters["inductance"]?.value ?? 1e-3
                let prevI = inductorStates[label]?.current ?? 0
                let dt = document.simulationConfig.transient.timeStep
                let current = prevI + voltage * dt / ind
                inductorStates[label] = (voltage: voltage, current: current)

            default:
                break
            }
        }
    }

    private func nodeNamesForComponent(_ component: SchematicComponent, in document: CircuitDocument) -> (String, String) {
        // Find wires connected to this component's pins
        let connectedWires = document.wires.filter {
            $0.startComponentID == component.id || $0.endComponentID == component.id
        }
        let node1 = "n\(component.id.uuidString.prefix(4))_0"
        let node2 = "n\(component.id.uuidString.prefix(4))_1"
        return (node1, node2)
    }
}
