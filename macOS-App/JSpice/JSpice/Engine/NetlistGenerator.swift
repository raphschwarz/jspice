import Foundation

// MARK: - Netlist Generator

/// Converts a CircuitDocument (visual schematic) into an MNA netlist for simulation.
enum NetlistGenerator {

    /// Generate a netlist for DC analysis (no time-varying sources)
    static func generate(from document: CircuitDocument) -> MNASolver.Netlist {
        generate(from: document, time: 0, timeStep: 1e-6, capacitorStates: [:], inductorStates: [:])
    }

    /// Generate a netlist for transient analysis at a specific time point
    static func generate(
        from document: CircuitDocument,
        time: Double,
        timeStep: Double,
        capacitorStates: [String: (voltage: Double, current: Double)],
        inductorStates: [String: (voltage: Double, current: Double)]
    ) -> MNASolver.Netlist {

        // 1. Build connectivity graph (which components share nodes)
        let connectivity = buildConnectivity(document: document)

        // 2. Convert each schematic component to an MNA component
        var mnaComponents: [MNAComponent] = []

        for component in document.components {
            let nodes = connectivity.nodesForComponent(component.id, pinCount: component.type.pinCount)

            switch component.type {
            case .resistor:
                let r = component.parameters["resistance"]?.value ?? 1000
                mnaComponents.append(MNAResistor(
                    name: component.label,
                    nodes: nodes,
                    resistance: r
                ))

            case .capacitor:
                let c = component.parameters["capacitance"]?.value ?? 1e-6
                let state = capacitorStates[component.label]
                var cap = MNACapacitor(
                    name: component.label,
                    nodes: nodes,
                    capacitance: c
                )
                cap.timeStep = timeStep
                cap.previousVoltage = state?.voltage ?? (component.parameters["initialVoltage"]?.value ?? 0)
                cap.previousCurrent = state?.current ?? 0
                mnaComponents.append(cap)

            case .inductor:
                let l = component.parameters["inductance"]?.value ?? 1e-3
                let state = inductorStates[component.label]
                var ind = MNAInductor(
                    name: component.label,
                    nodes: nodes,
                    inductance: l
                )
                ind.timeStep = timeStep
                ind.previousVoltage = state?.voltage ?? 0
                ind.previousCurrent = state?.current ?? (component.parameters["initialCurrent"]?.value ?? 0)
                mnaComponents.append(ind)

            case .diode:
                let is_ = component.parameters["saturationCurrent"]?.value ?? 1e-14
                let n = component.parameters["emissionCoefficient"]?.value ?? 1.0
                mnaComponents.append(MNADiode(
                    name: component.label,
                    nodes: nodes,
                    saturationCurrent: is_,
                    emissionCoefficient: n
                ))

            case .npnBJT:
                let beta = component.parameters["beta"]?.value ?? 100
                let is_ = component.parameters["saturationCurrent"]?.value ?? 1e-14
                mnaComponents.append(MNANJPNBJT(
                    name: component.label,
                    nodes: nodes,
                    beta: beta,
                    saturationCurrent: is_
                ))

            case .nmosFET:
                let vth = component.parameters["threshold"]?.value ?? 0.7
                let kp = component.parameters["kp"]?.value ?? 110e-6
                let l = component.parameters["channelLength"]?.value ?? 1e-6
                let w = component.parameters["channelWidth"]?.value ?? 10e-6
                mnaComponents.append(MNANMOS(
                    name: component.label,
                    nodes: nodes,
                    vth: vth,
                    kp: kp,
                    channelLength: l,
                    channelWidth: w
                ))

            case .pmosFET:
                let vth = component.parameters["threshold"]?.value ?? -0.7
                let kp = component.parameters["kp"]?.value ?? 50e-6
                let l = component.parameters["channelLength"]?.value ?? 1e-6
                let w = component.parameters["channelWidth"]?.value ?? 20e-6
                mnaComponents.append(MNAPMOS(
                    name: component.label,
                    nodes: nodes,
                    vth: vth,
                    kp: kp,
                    channelLength: l,
                    channelWidth: w
                ))

            case .dcVoltageSource:
                let v = component.parameters["voltage"]?.value ?? 5.0
                mnaComponents.append(MNADCVoltageSource(
                    name: component.label,
                    nodes: nodes,
                    voltage: v
                ))

            case .dcCurrentSource:
                let i = component.parameters["current"]?.value ?? 0.001
                mnaComponents.append(MNADCCurrentSource(
                    name: component.label,
                    nodes: nodes,
                    current: i
                ))

            case .acVoltageSource:
                let amp = component.parameters["amplitude"]?.value ?? 1.0
                let freq = component.parameters["frequency"]?.value ?? 1000
                let phase = (component.parameters["phase"]?.value ?? 0) * .pi / 180
                let dc = component.parameters["dcOffset"]?.value ?? 0
                var src = MNAACVoltageSource(
                    name: component.label,
                    nodes: nodes,
                    dcOffset: dc,
                    amplitude: amp,
                    frequency: freq,
                    phase: phase
                )
                src.currentTime = time
                mnaComponents.append(src)

            case .signalGenerator:
                let waveformType = Int(component.parameters["waveform"]?.value ?? 0)
                let amp = component.parameters["amplitude"]?.value ?? 1.0
                let freq = component.parameters["frequency"]?.value ?? 1000
                let phase = (component.parameters["phase"]?.value ?? 0) * .pi / 180
                let dc = component.parameters["dcOffset"]?.value ?? 0
                let duty = component.parameters["dutyCycle"]?.value ?? 0.5

                let voltage = dc + generateWaveform(
                    type: waveformType,
                    amplitude: amp,
                    frequency: freq,
                    phase: phase,
                    dutyCycle: duty,
                    time: time
                )

                mnaComponents.append(MNADCVoltageSource(
                    name: component.label,
                    nodes: nodes,
                    voltage: voltage
                ))

            case .vcvs:
                let gain = component.parameters["gain"]?.value ?? 1.0
                mnaComponents.append(MNAVCVS(
                    name: component.label,
                    nodes: nodes,
                    gain: gain
                ))

            case .vccs:
                let gm = component.parameters["gain"]?.value ?? 1.0
                mnaComponents.append(MNAVCCS(
                    name: component.label,
                    nodes: nodes,
                    transconductance: gm
                ))

            case .ground, .opAmp, .pnpBJT, .ccvs, .cccs:
                break  // Handled differently or not yet implemented
            }
        }

        return MNASolver.Netlist(components: mnaComponents, groundNodeName: "0")
    }

    // MARK: - Waveform Generation

    /// Normalize angle to [0, 1) cycle fraction, handling negative fmod results
    private static func normalizedPhase(_ t: Double) -> Double {
        let twoPi = 2.0 * Double.pi
        var result = fmod(t, twoPi)
        if result < 0 { result += twoPi }
        return result / twoPi
    }

    private static func generateWaveform(
        type: Int,
        amplitude: Double,
        frequency: Double,
        phase: Double,
        dutyCycle: Double,
        time: Double
    ) -> Double {
        let omega = 2.0 * .pi * frequency
        let t = omega * time + phase

        switch type {
        case 0: // Sine
            return amplitude * sin(t)

        case 1: // Square
            let normalized = normalizedPhase(t)
            return amplitude * (normalized < dutyCycle ? 1.0 : -1.0)

        case 2: // Triangle
            let normalized = normalizedPhase(t)
            if normalized < 0.25 {
                return amplitude * normalized * 4
            } else if normalized < 0.75 {
                return amplitude * (2 - normalized * 4)
            } else {
                return amplitude * (normalized * 4 - 4)
            }

        case 3: // Sawtooth
            let normalized = normalizedPhase(t)
            return amplitude * (2 * normalized - 1)

        case 4: // Pulse
            let normalized = normalizedPhase(t)
            return normalized < dutyCycle ? amplitude : 0

        default:
            return 0
        }
    }
}

// MARK: - Circuit Connectivity

struct CircuitConnectivity {
    /// Maps (componentID, pinIndex) -> node name
    private var pinToNode: [String: String] = [:]
    private var nextNodeIndex = 1

    mutating func connect(component1: UUID, pin1: Int, component2: UUID, pin2: Int) {
        let key1 = "\(component1)_\(pin1)"
        let key2 = "\(component2)_\(pin2)"

        if let existingNode = pinToNode[key1] {
            pinToNode[key2] = existingNode
        } else if let existingNode = pinToNode[key2] {
            pinToNode[key1] = existingNode
        } else {
            let nodeName = "n\(nextNodeIndex)"
            nextNodeIndex += 1
            pinToNode[key1] = nodeName
            pinToNode[key2] = nodeName
        }
    }

    func nodesForComponent(_ id: UUID, pinCount: Int) -> [String] {
        // Return nodes for all pins in order, defaulting unconnected pins to unique floating nodes
        var nodes: [String] = []
        for pin in 0..<pinCount {
            let key = "\(id)_\(pin)"
            nodes.append(pinToNode[key] ?? "float_\(id)_\(pin)")
        }
        return nodes
    }

    func nodeName(for componentID: UUID, pin: Int) -> String {
        let key = "\(componentID)_\(pin)"
        return pinToNode[key] ?? "float_\(componentID)_\(pin)"
    }

    /// Assign a ground node ("0") to a specific pin
    mutating func assignGround(component: UUID, pin: Int) {
        let key = "\(component)_\(pin)"
        pinToNode[key] = "0"
    }
}

extension NetlistGenerator {
    static func buildConnectivity(document: CircuitDocument) -> CircuitConnectivity {
        var connectivity = CircuitConnectivity()

        // First, register ground components — any pin connected to a ground component becomes node "0"
        let groundIDs = Set(document.components.filter { $0.type == .ground }.map { $0.id })

        for wire in document.wires {
            connectivity.connect(
                component1: wire.startComponentID,
                pin1: wire.startPinIndex,
                component2: wire.endComponentID,
                pin2: wire.endPinIndex
            )
        }

        // Now propagate ground: any pin connected to a ground component's pin becomes "0"
        for wire in document.wires {
            if groundIDs.contains(wire.startComponentID) {
                // The end component's pin is connected to ground
                connectivity.assignGround(component: wire.endComponentID, pin: wire.endPinIndex)
                // Also mark the ground component's own pin
                connectivity.assignGround(component: wire.startComponentID, pin: wire.startPinIndex)
            }
            if groundIDs.contains(wire.endComponentID) {
                // The start component's pin is connected to ground
                connectivity.assignGround(component: wire.startComponentID, pin: wire.startPinIndex)
                connectivity.assignGround(component: wire.endComponentID, pin: wire.endPinIndex)
            }
        }

        // Ensure all non-ground components have node assignments per pin
        for component in document.components where component.type != .ground {
            for pin in 0..<component.type.pinCount {
                let key = "\(component.id)_\(pin)"
                if connectivity.nodeName(for: component.id, pin: pin).hasPrefix("float_") {
                    // Unconnected pin — assign a unique floating node via self-connect
                    connectivity.connect(
                        component1: component.id,
                        pin1: pin,
                        component2: component.id,
                        pin2: pin
                    )
                }
            }
        }

        return connectivity
    }
}
