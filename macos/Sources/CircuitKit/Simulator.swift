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
    /// Steps at which Newton-Raphson did not converge (the step is accepted anyway)
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
    /// The main current of each element: from `a` to `b` for two-terminal parts, into the drain or collector for
    /// transistors, out of the output for op-amps, from `a` to the wiper for potentiometers
    public private(set) var currents: [Double] = []

    private var baseMatrix: [Double] = []
    private var baseLU: LUSolver?
    private var matrixIsCurrent = false
    private var hasNonlinear = false
    private var hasMemristor = false
    private var stepCarry = 0.0
    private var traces: [UUID: ScopeTrace] = [:]

    static let thermalVoltage = 0.025852
    static let gmin = 1e-12
    static let maxNewtonIterations = 80
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
        var cv, cvp, ci, lv, li, lip, m, l1, l2: Double
    }

    /// Switches to a changed circuit, keeping the state (charge, current, memristor state) of elements that remain
    public func load(_ newCircuit: Circuit) {
        var previous: [UUID: SavedState] = [:]
        for (i, element) in circuit.elements.enumerated() where i < capacitorVoltage.count {
            previous[element.id] = SavedState(
                cv: capacitorVoltage[i], cvp: capacitorVoltagePrevious[i], ci: capacitorCurrent[i], lv: inductorVoltage[i],
                li: inductorCurrent[i], lip: inductorCurrentPrevious[i], m: memristorStates[i], l1: limitedVoltage[i],
                l2: limitedVoltage2[i])
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
            } else {
                initialiseState(i)
            }
        }
        x = Array(repeating: 0, count: topology.matrixSize)
        hasNonlinear = newCircuit.elements.contains {
            switch $0.kind {
            case .diode, .zener, .led, .npn, .pnp, .nmos, .pmos, .opAmp: return true
            default: return false
            }
        }
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
            if steps & 7 == 0 && ProcessInfo.processInfo.systemUptime > deadline {
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
        let m = topology.matrixSize
        let t = time + timeStep
        if m > 0 {
            if !matrixIsCurrent { buildBaseMatrix() }
            if isFailed { return }
            let rhs = buildRightHandSide(at: t)
            if !hasNonlinear && !hasMemristor {
                guard let lu = baseLU else { fail(); return }
                x = lu.solve(rhs)
            } else {
                var converged = false
                for iteration in 0..<Self.maxNewtonIterations {
                    var matrix = baseMatrix
                    var b = rhs
                    stampMemristors(&matrix, m)
                    if hasNonlinear { stampNonlinear(&matrix, &b, m) }
                    guard let lu = LUSolver(matrix: matrix, size: m) else { fail(); return }
                    let next = lu.solve(b)
                    if !hasNonlinear {
                        x = next
                        converged = true
                        break
                    }
                    var change = 0.0
                    for k in 0..<m {
                        change = max(change, abs(next[k] - x[k]) / (1 + abs(next[k])))
                    }
                    x = next
                    if iteration > 0 && change < 1e-9 {
                        converged = true
                        break
                    }
                }
                if !converged { convergenceFailures += 1 }
            }
            if x.contains(where: { !$0.isFinite }) { fail(); return }
        }
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

    func diodeCurrent(_ vd: Double, saturation: Double, nvt: Double) -> (current: Double, conductance: Double) {
        let e = exp(min(vd / nvt, 700))
        return (saturation * (e - 1), saturation * e / nvt + Self.gmin)
    }

    /// A Zener diode: an ordinary forward junction, plus a reverse current that rises steeply past the breakdown voltage
    func zenerCurrent(_ vd: Double, breakdown: Double) -> (current: Double, conductance: Double) {
        let forward = diodeCurrent(vd, saturation: 1e-14, nvt: Self.thermalVoltage)
        let e = exp(min(-(vd + breakdown) / Self.thermalVoltage, 700))
        let reverse = Self.zenerKneeCurrent * e
        return (forward.current - reverse, forward.conductance + reverse / Self.thermalVoltage)
    }

    /// Level-1 (Shichman-Hodges) MOSFET for positive vgs/vds: drain current and its derivatives
    func mosfetCurrent(vgs: Double, vds: Double, threshold: Double, beta: Double) -> (id: Double, gm: Double, gds: Double) {
        let lambda = 0.01
        let overdrive = vgs - threshold
        if overdrive <= 0 { return (0, 0, 1e-9) }
        if vds < overdrive {
            return (beta * (overdrive * vds - vds * vds / 2), beta * vds, beta * (overdrive - vds) + 1e-9)
        }
        let id = beta / 2 * overdrive * overdrive * (1 + lambda * vds)
        return (id, beta * overdrive * (1 + lambda * vds), beta / 2 * overdrive * overdrive * lambda + 1e-9)
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
            dibVbe: saturation / beta * f / vt + Self.gmin, dibVbc: saturation / reverseBeta * r / vt + Self.gmin)
    }

    /// The op-amp's output for a differential input: the gain, levelling off smoothly at the output limit
    func opAmpOutput(_ element: Element, differential vd: Double) -> (voltage: Double, slope: Double) {
        let gain = max(element[param: "gain"], 1)
        let limit = max(element[param: "limit"], 0.01)
        let t = tanh(gain * vd / limit)
        return (limit * t, gain * (1 - t * t))
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
                let (id, gd) = diodeCurrent(vd, saturation: saturation, nvt: nvt)
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
                let (id, gd) = zenerCurrent(vd, breakdown: breakdown)
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
                let model = bipolarCurrents(vbe: vbe, vbc: vbc, beta: max(element[param: "beta"], 1))
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

            case .nmos, .pmos:
                let polarity: Double = element.kind == .nmos ? 1 : -1
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
                let model = mosfetCurrent(vgs: polarity * vgs, vds: polarity * vds,
                                          threshold: element[param: "threshold"], beta: element[param: "beta"])
                let ids = polarity * model.id
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
                let vd = voltage(plus) - voltage(minus)
                let (output, slope) = opAmpOutput(element, differential: vd)
                // v(out) = output + slope (vd' - vd), linearised around the present inputs
                add(&matrix, m, row, plus - 1, -slope)
                add(&matrix, m, row, minus - 1, slope)
                rhs[row] = output - slope * vd
            default:
                break
            }
        }
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
        case .nmos, .pmos:
            let polarity: Double = element.kind == .nmos ? 1 : -1
            var vgs = v(nodes[0]) - v(nodes[2])
            var vds = v(nodes[1]) - v(nodes[2])
            var sign = 1.0
            if polarity * vds < 0 {
                vgs -= vds
                vds = -vds
                sign = -1
            }
            let model = mosfetCurrent(vgs: polarity * vgs, vds: polarity * vds,
                                      threshold: element[param: "threshold"], beta: element[param: "beta"])
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
        guard v.count >= 2 else { return 0 }
        let kind = circuit.elements[index].kind
        if kind.isTransistor { return v[1] - v[2] }
        if kind == .opAmp { return v[2] }
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

    /// 0 (fully off) to 1 (fully on)
    public func memristorState(_ index: Int) -> Double {
        index < memristorStates.count ? memristorStates[index] : 0
    }

    public var nodeCount: Int { topology.nodeCount }

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
