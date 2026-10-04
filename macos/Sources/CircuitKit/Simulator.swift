import Foundation

/// Steps a circuit through time with modified nodal analysis.
///
/// Capacitors and inductors use second-order Gear (BDF2) companion models: accurate enough to keep LC circuits
/// oscillating, and stable on sudden changes (a switch closing straight onto a capacitor does not make its current ring
/// from step to step, as the trapezoidal rule does). Diodes, transistors and op-amps are solved with Newton-Raphson at
/// every step, and memristors update their internal state after each step. The simulation starts from rest: capacitors at
/// their initial voltage, inductors without current.
public final class Simulator {
    public private(set) var circuit: Circuit
    public private(set) var time: Double = 0
    public private(set) var timeStep: Double
    /// Problems that keep the circuit from being simulated, or parts of it from working
    public private(set) var problems: [String] = []
    /// True when the equations cannot be solved; stepping stops until the circuit changes
    public private(set) var isFailed = false
    /// Steps at which Newton-Raphson did not converge, even with gmin stepping (the step is accepted anyway)
    public private(set) var convergenceFailures = 0

    var topology = Topology()
    /// Unknowns: node voltages 1..<nodeCount, then source and op-amp output currents
    var x: [Double] = []

    // per-element state, indexed like circuit.elements
    var capacitorVoltage: [Double] = []
    var capacitorVoltagePrevious: [Double] = []
    var capacitorCurrent: [Double] = []
    var inductorVoltage: [Double] = []
    var inductorCurrent: [Double] = []
    var inductorCurrentPrevious: [Double] = []
    var memristorStates: [Double] = []
    /// Newton limiting: the junction voltages last used for linearisation (diode; base-emitter and base-collector;
    /// gate-source and drain-source)
    var limitedVoltage: [Double] = []
    var limitedVoltage2: [Double] = []
    var limitedVoltage3: [Double] = []
    /// On/off state of 555s (output high) and Schmitt inverters (output high)
    var digitalState: [Bool] = []
    /// Op-amps: how often the input has been pulled back to the linear range in the present Newton solve
    private var opAmpCrossings: [Int] = []
    /// The main current of each element: from `a` to `b` for two-terminal parts, into the drain or collector for
    /// transistors, out of the output for op-amps, from `a` to the wiper for potentiometers
    public private(set) var currents: [Double] = []

    private var baseMatrix: [Double] = []
    private var baseLU: LUSolver?
    private var matrixIsCurrent = false
    private var hasNonlinear = false
    private var hasMemristor = false
    private var hasDigital = false
    private var stepCarry = 0.0
    /// Extra conductance across every junction while gmin stepping, otherwise zero
    private var junctionConductance = 0.0
    private var traces: [UUID: ScopeTrace] = [:]

    static let thermalVoltage = 0.025852
    static let gmin = 1e-12
    static let maxNewtonIterations = 80
    /// Junction shunts for gmin stepping, strongest first, ending without any
    static let steppedConductances: [Double] = [1e-2, 1e-4, 1e-6, 1e-8, 1e-10, 0]
    static let steppedIterations = 40
    static let transistorSaturationCurrent = 1e-14
    /// Reverse current of a Zener diode at its breakdown voltage
    static let zenerKneeCurrent = 5e-3

    public init(circuit: Circuit = Circuit(), timeStep: Double = 1e-5) {
        self.circuit = Circuit()
        self.timeStep = timeStep
        load(circuit)
    }

    // MARK: - Loading and settings

    private struct SavedState {
        var cv, cvp, ci, lv, li, lip, m, l1, l2, l3: Double
        var digital: Bool
    }

    /// Switches to a changed circuit, keeping the state (charge, current, memristor state) of elements that remain
    public func load(_ newCircuit: Circuit) {
        var previous: [UUID: SavedState] = [:]
        for (i, element) in circuit.elements.enumerated() where i < capacitorVoltage.count {
            previous[element.id] = SavedState(
                cv: capacitorVoltage[i], cvp: capacitorVoltagePrevious[i], ci: capacitorCurrent[i], lv: inductorVoltage[i],
                li: inductorCurrent[i], lip: inductorCurrentPrevious[i], m: memristorStates[i], l1: limitedVoltage[i],
                l2: limitedVoltage2[i], l3: limitedVoltage3[i], digital: digitalState[i])
        }
        circuit = newCircuit
        topology = Topology(circuit: newCircuit)
        let count = newCircuit.elements.count
        capacitorVoltage = Array(repeating: 0, count: count)
        capacitorVoltagePrevious = Array(repeating: 0, count: count)
        capacitorCurrent = Array(repeating: 0, count: count)
        inductorVoltage = Array(repeating: 0, count: count)
        inductorCurrent = Array(repeating: 0, count: count)
        inductorCurrentPrevious = Array(repeating: 0, count: count)
        memristorStates = Array(repeating: 0, count: count)
        limitedVoltage = Array(repeating: 0, count: count)
        limitedVoltage2 = Array(repeating: 0, count: count)
        limitedVoltage3 = Array(repeating: 0, count: count)
        digitalState = Array(repeating: false, count: count)
        opAmpCrossings = Array(repeating: 0, count: count)
        currents = Array(repeating: 0, count: count)
        for (i, element) in newCircuit.elements.enumerated() {
            if let state = previous[element.id] {
                capacitorVoltage[i] = state.cv
                capacitorVoltagePrevious[i] = state.cvp
                capacitorCurrent[i] = state.ci
                inductorVoltage[i] = state.lv
                inductorCurrent[i] = state.li
                inductorCurrentPrevious[i] = state.lip
                memristorStates[i] = state.m
                limitedVoltage[i] = state.l1
                limitedVoltage2[i] = state.l2
                limitedVoltage3[i] = state.l3
                digitalState[i] = state.digital
            } else {
                initialiseState(i)
            }
        }
        x = Array(repeating: 0, count: topology.matrixSize)
        hasNonlinear = newCircuit.elements.contains {
            switch $0.kind {
            case .diode, .zener, .led, .npn, .pnp, .nmos, .pmos, .njfet, .opAmp, .ota, .analogSwitch: return true
            default: return false
            }
        }
        hasDigital = newCircuit.elements.contains { $0.kind.isDigital }
        hasMemristor = newCircuit.elements.contains { $0.kind == .memristor }
        matrixIsCurrent = false
        isFailed = false
        problems = topology.problems
        configureScopes(window: traces.values.first?.window ?? 1)
        computeCurrents()
    }

    private func initialiseState(_ i: Int) {
        let element = circuit.elements[i]
        let v0 = element.kind == .capacitor ? element[param: "initialVoltage"] : 0
        capacitorVoltage[i] = v0
        capacitorVoltagePrevious[i] = v0
        capacitorCurrent[i] = 0
        inductorVoltage[i] = 0
        inductorCurrent[i] = 0
        inductorCurrentPrevious[i] = 0
        memristorStates[i] = element.kind == .memristor ? min(1, max(0, element[param: "initialState"])) : 0
        limitedVoltage[i] = 0
        limitedVoltage2[i] = 0
        limitedVoltage3[i] = 0
        // a Schmitt inverter's input starts low, so its output starts high; a 555 decides from its trigger
        digitalState[i] = element.kind == .schmittInverter
    }

    public func setTimeStep(_ dt: Double) {
        guard dt > 0, dt.isFinite, dt != timeStep else { return }
        timeStep = dt
        matrixIsCurrent = false
        // the history of the two-step method assumes equal steps: rebuild it from the present slope
        for (i, element) in circuit.elements.enumerated() {
            if element.kind == .capacitor {
                let c = max(element[param: "capacitance"], 1e-30)
                capacitorVoltagePrevious[i] = capacitorVoltage[i] - capacitorCurrent[i] * dt / c
            } else if element.kind == .inductor {
                let l = max(element[param: "inductance"], 1e-15)
                inductorCurrentPrevious[i] = inductorCurrent[i] - inductorVoltage[i] * dt / l
            } else if element.kind == .opAmp {
                capacitorVoltagePrevious[i] = capacitorVoltage[i]
            }
        }
    }

    /// Back to time zero with every element at rest
    public func reset() {
        time = 0
        stepCarry = 0
        convergenceFailures = 0
        for i in circuit.elements.indices { initialiseState(i) }
        x = Array(repeating: 0, count: topology.matrixSize)
        isFailed = false
        problems = topology.problems
        for trace in traces.values { trace.clear() }
        computeCurrents()
    }

    // MARK: - Running

    public struct Progress {
        public var simulatedTime: Double
        public var steps: Int
        /// True when the time budget ran out before the requested simulated time was reached
        public var fellBehind: Bool
    }

    /// Advances by `simulatedTime` seconds of circuit time, but stops at `deadline` (a `ProcessInfo.systemUptime` value)
    /// so the display stays responsive; time that could not be simulated is dropped rather than accumulated.
    @discardableResult
    public func advance(by simulatedTime: Double, deadline: TimeInterval) -> Progress {
        guard !isFailed else {
            stepCarry = 0
            return Progress(simulatedTime: 0, steps: 0, fellBehind: false)
        }
        stepCarry += simulatedTime / timeStep
        var steps = 0
        var fellBehind = false
        while stepCarry >= 1 && !isFailed {
            step()
            steps += 1
            stepCarry -= 1
            if ProcessInfo.processInfo.systemUptime > deadline {
                fellBehind = stepCarry >= 1
                stepCarry = 0
                break
            }
        }
        if isFailed { stepCarry = 0 }
        return Progress(simulatedTime: Double(steps) * timeStep, steps: steps, fellBehind: fellBehind)
    }

    /// One time step
    public func step() {
        guard !isFailed else { return }
        let t = time + timeStep
        var converged = solve(at: t)
        if isFailed { return }
        // a 555 or Schmitt trigger that switches during the step changes the circuit: solve the step again
        if hasDigital {
            for _ in 0..<4 {
                guard updateDigitalStates() else { break }
                converged = solve(at: t)
                if isFailed { return }
            }
        }
        if !converged { convergenceFailures += 1 }
        finishStep(at: t)
    }

    /// Solves the circuit equations for time `t` into `x`; false if Newton-Raphson did not converge.
    ///
    /// When it does not converge, the circuit has usually snapped from one state to another, like the two transistors of
    /// a flip-flop changing over: the solution has jumped far from the last one, out of Newton's reach. Then the
    /// junctions are temporarily shunted with conductances strong enough to leave the circuit a single, easily found
    /// solution, and the shunts are stepped down to nothing, each solution leading Newton to the next (gmin stepping).
    private func solve(at t: Double) -> Bool {
        let m = topology.matrixSize
        guard m > 0 else { return true }
        if !matrixIsCurrent { buildBaseMatrix() }
        if isFailed { return false }
        let rhs = buildRightHandSide(at: t)
        if !hasNonlinear && !hasMemristor {
            guard let lu = baseLU else { fail(); return false }
            x = lu.solve(rhs)
            if x.contains(where: { !$0.isFinite }) { fail(); return false }
            return true
        }
        let start = (x, limitedVoltage, limitedVoltage2)
        junctionConductance = 0
        if newton(rhs, iterations: Self.maxNewtonIterations) || isFailed || !hasNonlinear { return !isFailed }
        let firstTry = (x, limitedVoltage, limitedVoltage2)
        (x, limitedVoltage, limitedVoltage2) = start
        var converged = false
        for conductance in Self.steppedConductances {
            junctionConductance = conductance
            converged = newton(rhs, iterations: Self.steppedIterations)
            if isFailed { break }
        }
        junctionConductance = 0
        // if that failed too, the first try is the better guess to carry on from
        if !converged && !isFailed { (x, limitedVoltage, limitedVoltage2) = firstTry }
        return converged && !isFailed
    }

    /// Newton-Raphson from the present `x`; true when it converged
    private func newton(_ rhs: [Double], iterations: Int) -> Bool {
        let m = topology.matrixSize
        for i in opAmpCrossings.indices { opAmpCrossings[i] = 0 }
        for iteration in 0..<iterations {
            var matrix = baseMatrix
            var b = rhs
            stampMemristors(&matrix, m)
            if hasNonlinear { stampNonlinear(&matrix, &b, m) }
            guard let lu = LUSolver(matrix: matrix, size: m) else { fail(); return false }
            let next = lu.solve(b)
            if next.contains(where: { !$0.isFinite }) { fail(); return false }
            if !hasNonlinear {
                x = next
                return true
            }
            var change = 0.0
            for k in 0..<m {
                change = max(change, abs(next[k] - x[k]) / (1 + abs(next[k])))
            }
            x = next
            if iteration > 0 && change < 1e-9 { return true }
        }
        return false
    }

    private func finishStep(at t: Double) {
        time = t
        updateStates()
        computeCurrents()
        for trace in traces.values { record(trace) }
    }

    private func fail() {
        isFailed = true
        problems = topology.problems + ["The circuit can't be solved. Look for voltage sources in parallel, a loop of sources and wires, or a current source with nowhere to go."]
    }

    // MARK: - Equations

    @inline(__always) private func voltage(_ node: Int) -> Double {
        node == 0 ? 0 : x[node - 1]
    }

    /// Conductance g between nodes a and b
    @inline(__always) private func stampConductance(_ matrix: inout [Double], _ m: Int, _ a: Int, _ b: Int, _ g: Double) {
        if a > 0 { matrix[(a - 1) * m + a - 1] += g }
        if b > 0 { matrix[(b - 1) * m + b - 1] += g }
        if a > 0 && b > 0 {
            matrix[(a - 1) * m + b - 1] -= g
            matrix[(b - 1) * m + a - 1] -= g
        }
    }

    /// A current i flowing through the element from node a to node b
    @inline(__always) private func stampCurrent(_ rhs: inout [Double], _ a: Int, _ b: Int, _ i: Double) {
        if a > 0 { rhs[a - 1] -= i }
        if b > 0 { rhs[b - 1] += i }
    }

    /// Adds `value` at (row, column) given as 0-based matrix indices; negative indices (ground) are skipped
    @inline(__always) private func add(_ matrix: inout [Double], _ m: Int, _ row: Int, _ column: Int, _ value: Double) {
        if row >= 0 && column >= 0 { matrix[row * m + column] += value }
    }

    /// Conductances of a potentiometer's two halves: a to wiper, wiper to b
    func potentiometerResistances(_ element: Element) -> (Double, Double) {
        let total = max(element[param: "resistance"], 1e-3)
        let position = min(1, max(0, element[param: "position"]))
        let floor = total * 1e-4 + 1e-3
        return (max(total * position, floor), max(total * (1 - position), floor))
    }

    /// The part of the matrix that only changes with the circuit or the time step
    private func buildBaseMatrix() {
        let m = topology.matrixSize
        var matrix = [Double](repeating: 0, count: m * m)
        for node in 1..<max(1, topology.nodeCount) {
            matrix[(node - 1) * m + node - 1] += Self.gmin
        }
        for (i, element) in circuit.elements.enumerated() {
            let nodes = topology.elementNodes[i]
            switch element.kind {
            case .resistor, .lamp:
                stampConductance(&matrix, m, nodes[0], nodes[1], 1 / max(element[param: "resistance"], 1e-9))
            case .potentiometer:
                let (upper, lower) = potentiometerResistances(element)
                stampConductance(&matrix, m, nodes[0], nodes[2], 1 / upper)
                stampConductance(&matrix, m, nodes[2], nodes[1], 1 / lower)
            case .capacitor:
                stampConductance(&matrix, m, nodes[0], nodes[1], 1.5 * element[param: "capacitance"] / timeStep)
            case .inductor:
                stampConductance(&matrix, m, nodes[0], nodes[1], 2 * timeStep / (3 * max(element[param: "inductance"], 1e-15)))
            case .dcVoltage, .acVoltage, .squareVoltage:
                let row = topology.sourceRow[i]
                guard row >= 0 else { continue }
                let minus = nodes[0] - 1
                let plus = nodes[1] - 1
                // the source delivers its current out of the + terminal (b) and takes it back at the - terminal (a)
                add(&matrix, m, plus, row, -1)
                add(&matrix, m, minus, row, 1)
                add(&matrix, m, row, plus, 1)
                add(&matrix, m, row, minus, -1)
            case .opAmp:
                // output: a voltage source to ground, whose voltage the nonlinear stage sets from the inputs
                let row = topology.sourceRow[i]
                guard row >= 0 else { continue }
                add(&matrix, m, nodes[2] - 1, row, -1)
                add(&matrix, m, row, nodes[2] - 1, 1)
            case .timer555:
                // pins: GND, TRIG, OUT, RESET, CTRL, THR, DIS, VCC. The internal divider sets CTRL to 2/3 of the supply
                // (the trigger compares with half of CTRL); the output drives towards VCC or GND; DIS shorts to GND
                // while the output is low
                let (ground, output, control, discharge, supply) = (nodes[0], nodes[2], nodes[4], nodes[6], nodes[7])
                stampConductance(&matrix, m, supply, control, 1 / 5000.0)
                stampConductance(&matrix, m, control, ground, 1 / 10_000.0)
                let high = digitalState[i]
                stampConductance(&matrix, m, output, high ? supply : ground, 1 / max(element[param: "outputResistance"], 0.1))
                stampConductance(&matrix, m, discharge, ground, high ? 1e-9 : 1 / max(element[param: "dischargeResistance"], 0.1))
            case .schmittInverter:
                // output drives towards the hidden supply or ground through its output resistance
                stampConductance(&matrix, m, nodes[1], 0, 1 / max(element[param: "outputResistance"], 0.1))
            default:
                break
            }
        }
        baseMatrix = matrix
        matrixIsCurrent = true
        if !hasNonlinear && !hasMemristor {
            baseLU = LUSolver(matrix: matrix, size: m)
            if baseLU == nil { fail() }
        } else {
            baseLU = nil
        }
    }

    func sourceVoltage(_ element: Element, at t: Double) -> Double {
        switch element.kind {
        case .dcVoltage:
            return element[param: "voltage"]
        case .acVoltage:
            let phase = element[param: "phase"] * .pi / 180
            return element[param: "offset"] + element[param: "amplitude"] * sin(2 * .pi * element[param: "frequency"] * t + phase)
        case .squareVoltage:
            let cycle = (t * element[param: "frequency"]).truncatingRemainder(dividingBy: 1)
            return cycle < element[param: "duty"] ? element[param: "high"] : element[param: "low"]
        default:
            return 0
        }
    }

    private func buildRightHandSide(at t: Double) -> [Double] {
        var rhs = [Double](repeating: 0, count: topology.matrixSize)
        for (i, element) in circuit.elements.enumerated() {
            let nodes = topology.elementNodes[i]
            switch element.kind {
            case .dcVoltage, .acVoltage, .squareVoltage:
                let row = topology.sourceRow[i]
                if row >= 0 { rhs[row] = sourceVoltage(element, at: t) }
            case .currentSource:
                stampCurrent(&rhs, nodes[0], nodes[1], element[param: "current"])
            case .capacitor:
                // BDF2: i(n) = C/dt (3/2 v(n) - 2 v(n-1) + 1/2 v(n-2))
                let c = element[param: "capacitance"]
                let history = c / timeStep * (2 * capacitorVoltage[i] - 0.5 * capacitorVoltagePrevious[i])
                stampCurrent(&rhs, nodes[0], nodes[1], -history)
            case .inductor:
                // BDF2: i(n) = 2 dt / (3 L) v(n) + (4 i(n-1) - i(n-2)) / 3
                let history = (4 * inductorCurrent[i] - inductorCurrentPrevious[i]) / 3
                stampCurrent(&rhs, nodes[0], nodes[1], history)
            case .timer555:
                let g = 1 / max(element[param: "outputResistance"], 0.1)
                if digitalState[i] {
                    // high: VCC minus the output stage's drop
                    stampCurrent(&rhs, nodes[2], nodes[7], g * element[param: "highDrop"])
                } else {
                    // low: 0.1 V above GND
                    stampCurrent(&rhs, nodes[0], nodes[2], g * 0.1)
                }
            case .schmittInverter:
                if digitalState[i] {
                    stampCurrent(&rhs, 0, nodes[1], element[param: "supply"] / max(element[param: "outputResistance"], 0.1))
                }
            default:
                break
            }
        }
        return rhs
    }

    func memristorConductance(_ element: Element, state: Double) -> Double {
        state / max(element[param: "ron"], 1e-9) + (1 - state) / max(element[param: "roff"], 1e-9)
    }

    private func stampMemristors(_ matrix: inout [Double], _ m: Int) {
        guard hasMemristor else { return }
        for (i, element) in circuit.elements.enumerated() where element.kind == .memristor {
            let nodes = topology.elementNodes[i]
            stampConductance(&matrix, m, nodes[0], nodes[1], memristorConductance(element, state: memristorStates[i]))
        }
    }

    // MARK: Semiconductors and op-amps

    func diodeParameters(_ element: Element) -> (saturation: Double, nvt: Double) {
        switch element.kind {
        case .led:
            // emission coefficient 2, saturation current chosen for the colour's forward voltage at 10 mA
            let color = LEDColor(rawValue: Int(element[param: "color"])) ?? .red
            let nvt = 2 * Self.thermalVoltage
            return (0.01 / exp(color.forwardVoltage / nvt), nvt)
        case .zener:
            return (1e-14, Self.thermalVoltage)
        default:
            return (max(element[param: "saturationCurrent"], 1e-30), max(element[param: "emission"], 0.1) * Self.thermalVoltage)
        }
    }

    /// Junction voltage limiting (as in SPICE's pnjlim), so Newton does not overshoot into exp() overflow
    private func limitJunction(_ new: Double, old: Double, nvt: Double, critical: Double) -> Double {
        guard new > critical && abs(new - old) > 2 * nvt else { return new }
        if old > 0 {
            let argument = 1 + (new - old) / nvt
            return argument > 0 ? old + nvt * log(argument) : critical
        }
        return nvt * log(new / nvt)
    }

    /// Current and conductance of a junction, with a tiny leak in parallel. The current must include the leak whenever the
    /// conductance does: if they disagree, Newton-Raphson only creeps towards the solution.
    func diodeCurrent(_ vd: Double, saturation: Double, nvt: Double) -> (current: Double, conductance: Double) {
        let e = exp(min(vd / nvt, 700))
        return (saturation * (e - 1) + Self.gmin * vd, saturation * e / nvt + Self.gmin)
    }

    /// A Zener diode: an ordinary forward junction, plus a reverse current that rises steeply past the breakdown voltage
    func zenerCurrent(_ vd: Double, breakdown: Double) -> (current: Double, conductance: Double) {
        let forward = diodeCurrent(vd, saturation: 1e-14, nvt: Self.thermalVoltage)
        let e = exp(min(-(vd + breakdown) / Self.thermalVoltage, 700))
        let reverse = Self.zenerKneeCurrent * e
        return (forward.current - reverse, forward.conductance + reverse / Self.thermalVoltage)
    }

    /// Level-1 (Shichman-Hodges) MOSFET for positive vgs/vds: drain current and its derivatives. A 1 nS leak from drain
    /// to source keeps a switched-off transistor's drain from floating; it is in the current as well as in its slope.
    func mosfetCurrent(vgs: Double, vds: Double, threshold: Double, beta: Double) -> (id: Double, gm: Double, gds: Double) {
        let lambda = 0.01
        let leak = 1e-9
        let overdrive = vgs - threshold
        if overdrive <= 0 { return (leak * vds, 0, leak) }
        if vds < overdrive {
            return (beta * (overdrive * vds - vds * vds / 2) + leak * vds, beta * vds, beta * (overdrive - vds) + leak)
        }
        let id = beta / 2 * overdrive * overdrive * (1 + lambda * vds) + leak * vds
        return (id, beta * overdrive * (1 + lambda * vds), beta / 2 * overdrive * overdrive * lambda + leak)
    }

    struct BipolarModel {
        /// Currents into the collector and the base
        var ic, ib: Double
        /// Their derivatives with respect to the base-emitter and base-collector voltages
        var dicVbe, dicVbc, dibVbe, dibVbc: Double
    }

    /// Ebers-Moll transport model of an NPN transistor (a PNP is the same with all voltages and currents negated)
    func bipolarCurrents(vbe: Double, vbc: Double, beta: Double) -> BipolarModel {
        let saturation = Self.transistorSaturationCurrent
        let vt = Self.thermalVoltage
        let reverseBeta = 1.0
        let f = exp(min(vbe / vt, 700))
        let r = exp(min(vbc / vt, 700))
        let ic = saturation * (f - r) - saturation / reverseBeta * (r - 1)
        let ib = saturation / beta * (f - 1) + saturation / reverseBeta * (r - 1)
        return BipolarModel(
            ic: ic, ib: ib,
            dicVbe: saturation * f / vt, dicVbc: -saturation * r / vt - saturation / reverseBeta * r / vt,
            dibVbe: saturation / beta * f / vt, dibVbc: saturation / reverseBeta * r / vt)
    }

    /// The op-amp's output for a differential input (plus the input offset), its slope, and the internal stage's voltage.
    ///
    /// The internal stage integrates the input: a single pole at gain-bandwidth / gain, so the gain falls with frequency
    /// as in a real op-amp, and its drive current saturates, which sets the slew rate. Its voltage is the element's
    /// state from step to step. The output follows it, levelling off smoothly at the output swing. A gain-bandwidth of
    /// zero gives an op-amp without dynamics.
    func opAmpOutput(_ element: Element, index i: Int, differential raw: Double) -> (voltage: Double, slope: Double, stage: Double) {
        let vd = raw + element[param: "offset"]
        let gain = max(element[param: "gain"], 1)
        let limit = max(element[param: "limit"], 0.01)
        let gbw = element[param: "gbw"]
        guard gbw > 0 else {
            let t = tanh(gain * vd / limit)
            return (limit * t, gain * (1 - t * t), limit * t)
        }
        let w = 2 * Double.pi * gbw
        let tau = gain / w
        let denominator = 1.5 / timeStep + 1 / tau
        let slew = element[param: "slewRate"] * 1e6
        var drive = w * vd
        var driveSlope = w
        if slew > 0 {
            let t = tanh(vd * w / slew)
            drive = slew * t
            driveSlope = w * (1 - t * t)
        }
        // BDF2 for d(internal)/dt = drive - internal / tau
        let stage = (drive + (2 * capacitorVoltage[i] - 0.5 * capacitorVoltagePrevious[i]) / timeStep) / denominator
        let t = tanh(stage / limit)
        return (limit * t, (1 - t * t) * driveSlope / denominator, stage)
    }

    /// Input voltage beyond which an op-amp's output is no longer in its linear range within one step
    private func opAmpLinearRange(_ element: Element) -> Double {
        let gain = max(element[param: "gain"], 1)
        let limit = max(element[param: "limit"], 0.01)
        let gbw = element[param: "gbw"]
        guard gbw > 0 else { return limit / gain }
        let w = 2 * Double.pi * gbw
        let stepGain = w / (1.5 / timeStep + w / gain)
        var range = limit / stepGain
        let slew = element[param: "slewRate"] * 1e6
        if slew > 0 { range = min(range, slew / w) }
        return range
    }

    /// The bias input of an OTA: one or two junctions down to the negative supply. Returns the bias current I_abc
    /// and its conductance at junction voltage `vj` (bias pin voltage plus the supply).
    func otaBias(_ element: Element, junction vj: Double) -> (current: Double, conductance: Double, nvt: Double, saturation: Double) {
        let drops = min(max(element[param: "biasDrop"].rounded(), 1), 2)
        let nvt = drops * Self.thermalVoltage
        // 1 mA at 0.6 V per junction
        let saturation = 1e-3 / exp(drops * 0.6 / nvt)
        let (current, conductance) = diodeCurrent(vj, saturation: saturation, nvt: nvt)
        return (current, conductance, nvt, saturation)
    }

    /// Voltage beyond which an OTA's output clamps: the supply minus the headroom, less a junction drop for the clamp
    func otaClampLevel(_ element: Element) -> Double {
        max(element[param: "supply"] - element[param: "headroom"] - 0.6, 0)
    }

    /// Threshold (V), threshold width (V) and conductances of an analog switch
    func analogSwitchConductance(_ element: Element, control: Double) -> (conductance: Double, slope: Double) {
        let supply = max(element[param: "supply"], 1)
        let width = 0.02 * supply
        let on = 1 / max(element[param: "onResistance"], 1e-3)
        let off = 1e-10
        let s = 1 / (1 + exp(-(control - supply / 2) / width))
        return (off + (on - off) * s, (on - off) * s * (1 - s) / width)
    }

    /// Polarity, threshold and beta of a field-effect transistor (a JFET is a depletion device with threshold at its
    /// pinch-off voltage and beta = 2 IDSS / Vp²)
    func fetParameters(_ element: Element) -> (polarity: Double, threshold: Double, beta: Double) {
        switch element.kind {
        case .njfet:
            let pinchOff = min(element[param: "pinchOff"], -0.01)
            return (1, pinchOff, 2 * max(element[param: "idss"], 1e-9) / (pinchOff * pinchOff))
        case .pmos:
            return (-1, element[param: "threshold"], element[param: "beta"])
        default:
            return (1, element[param: "threshold"], element[param: "beta"])
        }
    }

    private func stampNonlinear(_ matrix: inout [Double], _ rhs: inout [Double], _ m: Int) {
        for (i, element) in circuit.elements.enumerated() {
            let nodes = topology.elementNodes[i]
            switch element.kind {
            case .diode, .led:
                let (saturation, nvt) = diodeParameters(element)
                let critical = nvt * log(nvt / (sqrt(2) * saturation))
                let vd = limitJunction(voltage(nodes[0]) - voltage(nodes[1]), old: limitedVoltage[i], nvt: nvt, critical: critical)
                limitedVoltage[i] = vd
                var (id, gd) = diodeCurrent(vd, saturation: saturation, nvt: nvt)
                id += junctionConductance * vd
                gd += junctionConductance
                stampConductance(&matrix, m, nodes[0], nodes[1], gd)
                stampCurrent(&rhs, nodes[0], nodes[1], id - gd * vd)

            case .zener:
                let breakdown = abs(element[param: "breakdown"])
                let vt = Self.thermalVoltage
                let new = voltage(nodes[0]) - voltage(nodes[1])
                let old = limitedVoltage[i]
                var vd = new
                if new > -breakdown / 2 {
                    vd = limitJunction(new, old: old, nvt: vt, critical: vt * log(vt / (sqrt(2) * 1e-14)))
                } else {
                    // limit the reverse (breakdown) junction the same way
                    let reverse = limitJunction(-(new + breakdown), old: -(old + breakdown), nvt: vt,
                                                critical: vt * log(vt / (sqrt(2) * Self.zenerKneeCurrent)))
                    vd = -reverse - breakdown
                }
                limitedVoltage[i] = vd
                var (id, gd) = zenerCurrent(vd, breakdown: breakdown)
                id += junctionConductance * vd
                gd += junctionConductance
                stampConductance(&matrix, m, nodes[0], nodes[1], gd)
                stampCurrent(&rhs, nodes[0], nodes[1], id - gd * vd)

            case .npn, .pnp:
                let p: Double = element.kind == .npn ? 1 : -1
                let (base, collector, emitter) = (nodes[0], nodes[1], nodes[2])
                let vt = Self.thermalVoltage
                let critical = vt * log(vt / (sqrt(2) * Self.transistorSaturationCurrent))
                // limit the junctions in the transistor's own polarity
                let vbe = limitJunction(p * (voltage(base) - voltage(emitter)), old: limitedVoltage[i], nvt: vt, critical: critical)
                let vbc = limitJunction(p * (voltage(base) - voltage(collector)), old: limitedVoltage2[i], nvt: vt, critical: critical)
                limitedVoltage[i] = vbe
                limitedVoltage2[i] = vbc
                var model = bipolarCurrents(vbe: vbe, vbc: vbc, beta: max(element[param: "beta"], 1))
                if junctionConductance > 0 {
                    // shunts across both junctions: base to emitter and base to collector
                    let g = junctionConductance
                    model.ib += g * (vbe + vbc)
                    model.dibVbe += g
                    model.dibVbc += g
                    model.ic -= g * vbc
                    model.dicVbc -= g
                }
                // real currents and junction voltages: currents and voltages flip sign for PNP, derivatives do not
                let realVbe = p * vbe
                let realVbc = p * vbc
                let terminals: [(node: Int, current: Double, gbe: Double, gbc: Double)] = [
                    (collector, p * model.ic, model.dicVbe, model.dicVbc),
                    (base, p * model.ib, model.dibVbe, model.dibVbc),
                    (emitter, -p * (model.ic + model.ib), -(model.dicVbe + model.dibVbe), -(model.dicVbc + model.dibVbc)),
                ]
                for terminal in terminals where terminal.node > 0 {
                    // current into the device at this terminal, linear in vbe and vbc around the limited point
                    let row = terminal.node - 1
                    add(&matrix, m, row, base - 1, terminal.gbe + terminal.gbc)
                    add(&matrix, m, row, emitter - 1, -terminal.gbe)
                    add(&matrix, m, row, collector - 1, -terminal.gbc)
                    rhs[row] -= terminal.current - terminal.gbe * realVbe - terminal.gbc * realVbc
                }

            case .nmos, .pmos, .njfet:
                let (polarity, threshold, beta) = fetParameters(element)
                let gate = nodes[0]
                var drain = nodes[1]
                var source = nodes[2]
                var vgs = voltage(gate) - voltage(source)
                var vds = voltage(drain) - voltage(source)
                // limit the gate voltage change per iteration
                vgs = limitedVoltage[i] + max(-0.5, min(0.5, vgs - limitedVoltage[i]))
                vds = limitedVoltage2[i] + max(-2, min(2, vds - limitedVoltage2[i]))
                limitedVoltage[i] = vgs
                limitedVoltage2[i] = vds
                // the device is symmetric: the terminal at the lower potential (for NMOS) acts as the source
                if polarity * vds < 0 {
                    swap(&drain, &source)
                    vgs = vgs - vds
                    vds = -vds
                }
                let mosfetModel = mosfetCurrent(vgs: polarity * vgs, vds: polarity * vds, threshold: threshold, beta: beta)
                var model = mosfetModel
                // a shunt from drain to source while gmin stepping
                model.gds += junctionConductance
                let ids = polarity * mosfetModel.id + junctionConductance * vds
                let equivalent = ids - model.gm * vgs - model.gds * vds
                let d = drain - 1
                let s = source - 1
                let g = gate - 1
                add(&matrix, m, d, d, model.gds)
                add(&matrix, m, d, s, -model.gds - model.gm)
                add(&matrix, m, d, g, model.gm)
                add(&matrix, m, s, d, -model.gds)
                add(&matrix, m, s, s, model.gds + model.gm)
                add(&matrix, m, s, g, -model.gm)
                stampCurrent(&rhs, drain, source, equivalent)

            case .opAmp:
                let row = topology.sourceRow[i]
                guard row >= 0 else { continue }
                let (minus, plus) = (nodes[0], nodes[1])
                var vd = voltage(plus) - voltage(minus)
                // Newton limiting: where the output has levelled off at its swing, its linearisation is flat and points
                // the next guess far past the other side, so guesses could swing from limit to limit. The first few
                // times a guess crosses over, it is brought back to the edge of the linear range; after that it may
                // cross, as it must when positive feedback snaps the output to the other limit (a comparator).
                let range = opAmpLinearRange(element)
                if vd * limitedVoltage[i] < 0 && abs(vd) > range && opAmpCrossings[i] < 3 {
                    opAmpCrossings[i] += 1
                    vd = vd > 0 ? range : -range
                }
                limitedVoltage[i] = vd
                let (output, slope, _) = opAmpOutput(element, index: i, differential: vd)
                // v(out) = output + slope (vd' - vd), linearised around the present inputs
                add(&matrix, m, row, plus - 1, -slope)
                add(&matrix, m, row, minus - 1, slope)
                rhs[row] = output - slope * vd

            case .ota:
                let (minus, plus, output, bias) = (nodes[0], nodes[1], nodes[2], nodes[3])
                let supply = element[param: "supply"]
                let vt = Self.thermalVoltage
                // bias input
                let probe = otaBias(element, junction: 0.6)
                let vj = limitJunction(voltage(bias) + supply, old: limitedVoltage[i], nvt: probe.nvt,
                                       critical: probe.nvt * log(probe.nvt / (sqrt(2) * probe.saturation)))
                limitedVoltage[i] = vj
                var (ib, gb, _, _) = otaBias(element, junction: vj)
                ib += junctionConductance * vj
                gb += junctionConductance
                if bias > 0 {
                    add(&matrix, m, bias - 1, bias - 1, gb)
                    rhs[bias - 1] -= ib - gb * vj + gb * supply
                }
                // output current I_abc tanh(vd / 2 Vt), linear in the inputs and the bias pin around this point
                let vd = voltage(plus) - voltage(minus)
                let th = tanh(vd / (2 * vt))
                let iout = ib * th
                let gd = ib * (1 - th * th) / (2 * vt)
                let gbias = gb * th
                let vb = vj - supply
                if output > 0 {
                    let row = output - 1
                    add(&matrix, m, row, plus - 1, -gd)
                    add(&matrix, m, row, minus - 1, gd)
                    add(&matrix, m, row, bias - 1, -gbias)
                    rhs[row] += iout - gd * vd - gbias * vb
                }
                // clamps that keep the output within the supply less the headroom
                let level = otaClampLevel(element)
                let critical = vt * log(vt / (sqrt(2) * 1e-14))
                let vu = limitJunction(voltage(output) - level, old: limitedVoltage2[i], nvt: vt, critical: critical)
                limitedVoltage2[i] = vu
                var (iu, gu) = diodeCurrent(vu, saturation: 1e-14, nvt: vt)
                iu += junctionConductance * vu
                gu += junctionConductance
                let vl = limitJunction(-level - voltage(output), old: limitedVoltage3[i], nvt: vt, critical: critical)
                limitedVoltage3[i] = vl
                var (il, gl) = diodeCurrent(vl, saturation: 1e-14, nvt: vt)
                il += junctionConductance * vl
                gl += junctionConductance
                if output > 0 {
                    let row = output - 1
                    add(&matrix, m, row, row, gu + gl)
                    rhs[row] -= iu - gu * vu - gu * level
                    rhs[row] -= -il - gl * (-level) + gl * vl
                }

            case .analogSwitch:
                let (a, b, control) = (nodes[0], nodes[1], nodes[2])
                let vc = voltage(control)
                let (g, slope) = analogSwitchConductance(element, control: vc)
                let k = slope * (voltage(a) - voltage(b))
                stampConductance(&matrix, m, a, b, g)
                add(&matrix, m, a - 1, control - 1, k)
                add(&matrix, m, b - 1, control - 1, -k)
                if a > 0 { rhs[a - 1] += k * vc }
                if b > 0 { rhs[b - 1] -= k * vc }
            default:
                break
            }
        }
    }

    /// Updates the 555s' flip-flops and the Schmitt inverters from the present solution; true if any switched
    private func updateDigitalStates() -> Bool {
        var changed = false
        for (i, element) in circuit.elements.enumerated() where element.kind.isDigital {
            let nodes = topology.elementNodes[i]
            var high = digitalState[i]
            switch element.kind {
            case .timer555:
                let ground = voltage(nodes[0])
                let control = voltage(nodes[4]) - ground
                if voltage(nodes[3]) - ground < 0.7 {
                    high = false
                } else if voltage(nodes[1]) - ground < control / 2 {
                    high = true
                } else if voltage(nodes[5]) - ground > control {
                    high = false
                }
            case .schmittInverter:
                let supply = element[param: "supply"]
                let input = voltage(nodes[0])
                if input > element[param: "upper"] * supply {
                    high = false
                } else if input < element[param: "lower"] * supply {
                    high = true
                }
            default:
                break
            }
            if high != digitalState[i] {
                digitalState[i] = high
                changed = true
            }
        }
        if changed { matrixIsCurrent = false }
        return changed
    }

    // MARK: - After each step

    private func updateStates() {
        for (i, element) in circuit.elements.enumerated() {
            let nodes = topology.elementNodes[i]
            switch element.kind {
            case .capacitor:
                let v = voltage(nodes[0]) - voltage(nodes[1])
                let c = element[param: "capacitance"]
                capacitorCurrent[i] = c / timeStep * (1.5 * v - 2 * capacitorVoltage[i] + 0.5 * capacitorVoltagePrevious[i])
                capacitorVoltagePrevious[i] = capacitorVoltage[i]
                capacitorVoltage[i] = v
            case .inductor:
                let v = voltage(nodes[0]) - voltage(nodes[1])
                let g = 2 * timeStep / (3 * max(element[param: "inductance"], 1e-15))
                let next = g * v + (4 * inductorCurrent[i] - inductorCurrentPrevious[i]) / 3
                inductorCurrentPrevious[i] = inductorCurrent[i]
                inductorCurrent[i] = next
                inductorVoltage[i] = v
            case .opAmp where element[param: "gbw"] > 0:
                let (_, _, stage) = opAmpOutput(element, index: i, differential: voltage(nodes[1]) - voltage(nodes[0]))
                // the internal stage cannot wind up far beyond the output swing
                let bound = 3 * max(element[param: "limit"], 0.01)
                capacitorVoltagePrevious[i] = capacitorVoltage[i]
                capacitorVoltage[i] = min(bound, max(-bound, stage))
            case .memristor:
                // threshold switching: the state relaxes towards "on" above the on threshold and towards "off" below
                // minus the off threshold, with the given switching time
                let v = voltage(nodes[0]) - voltage(nodes[1])
                let sharpness = 0.02
                let tau = max(element[param: "tau"], 1e-12)
                let towardsOn = 1 / (1 + exp(-(v - element[param: "von"]) / sharpness)) / tau
                let towardsOff = 1 / (1 + exp((v + element[param: "voff"]) / sharpness)) / tau
                let rate = towardsOn + towardsOff
                if rate > 1e-12 {
                    let target = towardsOn / rate
                    memristorStates[i] = target + (memristorStates[i] - target) * exp(-rate * timeStep)
                }
            default:
                break
            }
        }
    }

    /// The element's main current and the current flowing out of it into each of its terminals
    private func elementCurrents(_ i: Int, _ element: Element, _ v: (Int) -> Double) -> (main: Double, out: [Double]) {
        let nodes = topology.elementNodes[i]
        func twoTerminal(_ current: Double) -> (Double, [Double]) { (current, [-current, current]) }
        switch element.kind {
        case .resistor, .lamp:
            return twoTerminal((v(nodes[0]) - v(nodes[1])) / max(element[param: "resistance"], 1e-9))
        case .potentiometer:
            let (upper, lower) = potentiometerResistances(element)
            let first = (v(nodes[0]) - v(nodes[2])) / upper
            let second = (v(nodes[2]) - v(nodes[1])) / lower
            return (first, [-first, second, first - second])
        case .capacitor:
            return twoTerminal(capacitorCurrent[i])
        case .inductor:
            return twoTerminal(inductorCurrent[i])
        case .dcVoltage, .acVoltage, .squareVoltage:
            let row = topology.sourceRow[i]
            return twoTerminal(row >= 0 && row < x.count ? x[row] : 0)
        case .currentSource:
            return twoTerminal(element[param: "current"])
        case .diode, .led:
            let (saturation, nvt) = diodeParameters(element)
            return twoTerminal(diodeCurrent(v(nodes[0]) - v(nodes[1]), saturation: saturation, nvt: nvt).current)
        case .zener:
            return twoTerminal(zenerCurrent(v(nodes[0]) - v(nodes[1]), breakdown: abs(element[param: "breakdown"])).current)
        case .memristor:
            return twoTerminal((v(nodes[0]) - v(nodes[1])) * memristorConductance(element, state: memristorStates[i]))
        case .nmos, .pmos, .njfet:
            let (polarity, threshold, beta) = fetParameters(element)
            var vgs = v(nodes[0]) - v(nodes[2])
            var vds = v(nodes[1]) - v(nodes[2])
            var sign = 1.0
            if polarity * vds < 0 {
                vgs -= vds
                vds = -vds
                sign = -1
            }
            let model = mosfetCurrent(vgs: polarity * vgs, vds: polarity * vds, threshold: threshold, beta: beta)
            let current = sign * polarity * model.id
            return (current, [0, -current, current])
        case .npn, .pnp:
            let p: Double = element.kind == .npn ? 1 : -1
            let model = bipolarCurrents(vbe: p * (v(nodes[0]) - v(nodes[2])), vbc: p * (v(nodes[0]) - v(nodes[1])),
                                        beta: max(element[param: "beta"], 1))
            let (ic, ib) = (p * model.ic, p * model.ib)
            return (ic, [-ib, -ic, ic + ib])
        case .opAmp:
            let row = topology.sourceRow[i]
            let current = row >= 0 && row < x.count ? x[row] : 0
            return (current, [0, 0, current])
        case .ota:
            let supply = element[param: "supply"]
            let bias = otaBias(element, junction: v(nodes[3]) + supply).current
            let level = otaClampLevel(element)
            let vt = Self.thermalVoltage
            let clampUp = diodeCurrent(v(nodes[2]) - level, saturation: 1e-14, nvt: vt).current
            let clampDown = diodeCurrent(-level - v(nodes[2]), saturation: 1e-14, nvt: vt).current
            let output = bias * tanh((v(nodes[1]) - v(nodes[0])) / (2 * vt)) - clampUp + clampDown
            return (output, [0, 0, output, -bias])
        case .analogSwitch:
            let g = analogSwitchConductance(element, control: v(nodes[2])).conductance
            let current = g * (v(nodes[0]) - v(nodes[1]))
            return (current, [-current, current, 0])
        case .schmittInverter:
            let target = digitalState[i] ? element[param: "supply"] : 0
            let current = (target - v(nodes[1])) / max(element[param: "outputResistance"], 0.1)
            return (current, [0, current])
        case .timer555:
            let (ground, output, control, discharge, supply) = (nodes[0], nodes[2], nodes[4], nodes[6], nodes[7])
            let high = digitalState[i]
            let upper = (v(supply) - v(control)) / 5000
            let lower = (v(control) - v(ground)) / 10_000
            let target = high ? v(supply) - element[param: "highDrop"] : v(ground) + 0.1
            let out = (target - v(output)) / max(element[param: "outputResistance"], 0.1)
            let dischargeIn = (v(discharge) - v(ground)) * (high ? 1e-9 : 1 / max(element[param: "dischargeResistance"], 0.1))
            var flows = [Double](repeating: 0, count: 8)
            flows[2] = out
            flows[6] = -dischargeIn
            flows[4] = upper - lower
            flows[7] = -upper - (high ? out : 0)
            flows[0] = lower + dischargeIn - (high ? 0 : out)
            return (out, flows)
        default:
            return (0, Array(repeating: 0, count: nodes.count))
        }
    }

    private func computeCurrents() {
        let elements = circuit.elements
        guard currents.count == elements.count else { return }
        let hasSolution = x.count == topology.matrixSize
        func v(_ node: Int) -> Double { hasSolution ? voltage(node) : 0 }

        var injection = [Double](repeating: 0, count: topology.points.count)
        for (i, element) in elements.enumerated() {
            if element.isConductor {
                currents[i] = 0
                continue
            }
            let (main, out) = elementCurrents(i, element, v)
            currents[i] = main
            for (point, current) in zip(topology.elementPoints[i], out) {
                injection[point] += current
            }
        }
        // wires and other conductors carry what flows into them from the leaves of the wire network inwards
        for step in topology.flowOrder {
            let flow = injection[step.from]
            injection[step.to] += flow
            currents[step.element] = topology.elementPoints[step.element][0] == step.from ? flow : -flow
        }
    }

    // MARK: - Readings

    public func voltage(at point: GridPoint) -> Double {
        guard let p = topology.pointIndex[point], x.count == topology.matrixSize else { return 0 }
        return voltage(topology.nodeOfPoint[p])
    }

    /// Voltage of each terminal of the element at `index`
    public func terminalVoltages(_ index: Int) -> [Double] {
        guard index < topology.elementNodes.count, x.count == topology.matrixSize else { return [] }
        return topology.elementNodes[index].map { voltage($0) }
    }

    /// Voltage across the element: a minus b; for voltage sources + (b) minus - (a), so a 5 V source reads 5 V;
    /// drain minus source (collector minus emitter) for transistors; the output voltage for op-amps
    public func voltageAcross(_ index: Int) -> Double {
        let v = terminalVoltages(index)
        if v.count == 1 { return v[0] }
        guard v.count >= 2 else { return 0 }
        let kind = circuit.elements[index].kind
        if kind.isTransistor { return v[1] - v[2] }
        if kind == .opAmp || kind == .ota { return v[2] }
        if kind == .timer555 { return v[2] - v[0] }
        if kind == .schmittInverter { return v[1] }
        return kind.isVoltageSource ? v[1] - v[0] : v[0] - v[1]
    }

    public func current(_ index: Int) -> Double {
        index < currents.count ? currents[index] : 0
    }

    public func value(_ quantity: Quantity, of index: Int) -> Double {
        switch quantity {
        case .voltage: return voltageAcross(index)
        case .current: return current(index)
        case .power: return voltageAcross(index) * current(index)
        case .resistance:
            let element = circuit.elements[index]
            if element.kind == .memristor { return 1 / memristorConductance(element, state: memristorStates[index]) }
            if element.kind == .resistor || element.kind == .lamp || element.kind == .potentiometer {
                return element[param: "resistance"]
            }
            let i = current(index)
            return abs(i) > 1e-15 ? voltageAcross(index) / i : .infinity
        }
    }

    /// 0 (dark) to 1 (full brightness) for LEDs and lamps
    public func brightness(_ index: Int) -> Double {
        let element = circuit.elements[index]
        switch element.kind {
        case .led:
            return min(1, max(0, current(index) / 0.015))
        case .lamp:
            let power = abs(voltageAcross(index) * current(index))
            return min(1, power / max(element[param: "ratedPower"], 1e-9))
        default:
            return 0
        }
    }

    /// True while a 555's or Schmitt inverter's output is high
    public func isHigh(_ index: Int) -> Bool {
        index < digitalState.count ? digitalState[index] : false
    }

    /// 0 (open) to 1 (closed) for analog switches
    public func switchConduction(_ index: Int) -> Double {
        guard index < circuit.elements.count, circuit.elements[index].kind == .analogSwitch else { return 0 }
        let v = terminalVoltages(index)
        guard v.count == 3 else { return 0 }
        let element = circuit.elements[index]
        let g = analogSwitchConductance(element, control: v[2]).conductance
        return min(1, g * max(element[param: "onResistance"], 1e-3))
    }

    /// 0 (fully off) to 1 (fully on)
    public func memristorState(_ index: Int) -> Double {
        index < memristorStates.count ? memristorStates[index] : 0
    }

    public var nodeCount: Int { topology.nodeCount }

    /// Node number of each terminal of the element at `index` (0 is ground)
    public func nodes(of index: Int) -> [Int] {
        index < topology.elementNodes.count ? topology.elementNodes[index] : []
    }

    /// The voltage of node `node` (0 is ground)
    public func nodeVoltage(_ node: Int) -> Double {
        node > 0 && node - 1 < x.count && x.count == topology.matrixSize ? x[node - 1] : 0
    }

    /// The largest node voltage magnitude, for scaling voltage colours
    public var maxNodeVoltage: Double {
        guard x.count == topology.matrixSize else { return 0 }
        var result = 0.0
        for node in 1..<max(1, topology.nodeCount) { result = max(result, abs(x[node - 1])) }
        return result
    }

    // MARK: - Scopes

    /// Keeps a trace for every scope of the circuit, each showing the last `window` seconds of circuit time
    public func configureScopes(window: Double) {
        var next: [UUID: ScopeTrace] = [:]
        for spec in circuit.scopes {
            if let existing = traces[spec.id], existing.spec == spec, existing.window == window {
                next[spec.id] = existing
            } else {
                next[spec.id] = ScopeTrace(spec: spec, window: window)
            }
        }
        traces = next
    }

    public func trace(_ id: UUID) -> ScopeTrace? { traces[id] }

    private func record(_ trace: ScopeTrace) {
        guard let index = circuit.index(of: trace.spec.elementID) else { return }
        switch trace.spec.plot {
        case .time:
            trace.add(value(trace.spec.quantity, of: index), at: time)
        case .currentVersusVoltage:
            trace.addPoint(voltage: voltageAcross(index), current: current(index), at: time)
        }
    }
}

/// Recent history of one scope: min/max buckets of a quantity over time (so fast signals still show their envelope),
/// or voltage-current points for an I–V curve.
public final class ScopeTrace {
    public let spec: ScopeSpec
    public let window: Double
    public static let capacity = 600

    public private(set) var minimums: [Double] = []
    public private(set) var maximums: [Double] = []
    public private(set) var lastValue: Double = 0
    /// I–V curve points, oldest first
    public private(set) var voltages: [Double] = []
    public private(set) var currents: [Double] = []
    public private(set) var lastVoltage: Double = 0
    private var bucketStart = 0.0
    private var bucketMin = Double.infinity
    private var bucketMax = -Double.infinity

    init(spec: ScopeSpec, window: Double) {
        self.spec = spec
        self.window = max(window, 1e-12)
    }

    var interval: Double { window / Double(Self.capacity) }

    func clear() {
        minimums.removeAll()
        maximums.removeAll()
        voltages.removeAll()
        currents.removeAll()
        lastValue = 0
        lastVoltage = 0
        bucketStart = 0
        bucketMin = .infinity
        bucketMax = -.infinity
    }

    func add(_ value: Double, at time: Double) {
        guard value.isFinite else { return }
        lastValue = value
        bucketMin = min(bucketMin, value)
        bucketMax = max(bucketMax, value)
        if time - bucketStart >= interval {
            minimums.append(bucketMin)
            maximums.append(bucketMax)
            if minimums.count > Self.capacity {
                minimums.removeFirst(minimums.count - Self.capacity)
                maximums.removeFirst(maximums.count - Self.capacity)
            }
            bucketStart = time
            bucketMin = .infinity
            bucketMax = -.infinity
        }
    }

    func addPoint(voltage: Double, current: Double, at time: Double) {
        guard voltage.isFinite, current.isFinite else { return }
        lastValue = current
        lastVoltage = voltage
        if time - bucketStart >= interval {
            voltages.append(voltage)
            currents.append(current)
            if voltages.count > Self.capacity {
                voltages.removeFirst(voltages.count - Self.capacity)
                currents.removeFirst(currents.count - Self.capacity)
            }
            bucketStart = time
        }
    }
}
