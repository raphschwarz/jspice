import Foundation

/// Steps a circuit through time with modified nodal analysis.
///
/// Capacitors and inductors use trapezoidal companion models (which keep LC circuits ringing instead of damping them),
/// diodes, LEDs and MOSFETs are solved with Newton-Raphson at every step, and memristors update their internal state after
/// each step. The simulation starts from rest: capacitors at their initial voltage, inductors without current.
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
    /// Unknowns: node voltages 1..<nodeCount, then voltage source currents
    var x: [Double] = []

    // per-element state, indexed like circuit.elements
    var capacitorVoltage: [Double] = []
    var capacitorCurrent: [Double] = []
    var inductorVoltage: [Double] = []
    var inductorCurrent: [Double] = []
    var memristorStates: [Double] = []
    /// Newton limiting: last junction voltage (diodes) or gate-source voltage (MOSFETs) used for linearisation
    var limitedVoltage: [Double] = []
    var limitedVoltage2: [Double] = []
    /// Current through each element from its `a` side to its `b` side (drain to source for MOSFETs)
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
    static let maxNewtonIterations = 60

    public init(circuit: Circuit = Circuit(), timeStep: Double = 1e-5) {
        self.circuit = Circuit()
        self.timeStep = timeStep
        load(circuit)
    }

    // MARK: - Loading and settings

    /// Switches to a changed circuit, keeping the state (charge, current, memristor state) of elements that remain
    public func load(_ newCircuit: Circuit) {
        var previous: [UUID: (cv: Double, ci: Double, lv: Double, li: Double, m: Double, l1: Double, l2: Double)] = [:]
        for (i, element) in circuit.elements.enumerated() where i < capacitorVoltage.count {
            previous[element.id] = (capacitorVoltage[i], capacitorCurrent[i], inductorVoltage[i], inductorCurrent[i],
                                    memristorStates[i], limitedVoltage[i], limitedVoltage2[i])
        }
        circuit = newCircuit
        topology = Topology(circuit: newCircuit)
        let count = newCircuit.elements.count
        capacitorVoltage = Array(repeating: 0, count: count)
        capacitorCurrent = Array(repeating: 0, count: count)
        inductorVoltage = Array(repeating: 0, count: count)
        inductorCurrent = Array(repeating: 0, count: count)
        memristorStates = Array(repeating: 0, count: count)
        limitedVoltage = Array(repeating: 0, count: count)
        limitedVoltage2 = Array(repeating: 0, count: count)
        currents = Array(repeating: 0, count: count)
        for (i, element) in newCircuit.elements.enumerated() {
            if let state = previous[element.id] {
                capacitorVoltage[i] = state.cv
                capacitorCurrent[i] = state.ci
                inductorVoltage[i] = state.lv
                inductorCurrent[i] = state.li
                memristorStates[i] = state.m
                limitedVoltage[i] = state.l1
                limitedVoltage2[i] = state.l2
            } else {
                initialiseState(i)
            }
        }
        x = Array(repeating: 0, count: topology.matrixSize)
        hasNonlinear = newCircuit.elements.contains { $0.kind == .diode || $0.kind == .led || $0.kind.isTransistor }
        hasMemristor = newCircuit.elements.contains { $0.kind == .memristor }
        matrixIsCurrent = false
        isFailed = false
        problems = topology.problems
        configureScopes(window: traces.values.first?.window ?? 1)
        computeCurrents()
    }

    private func initialiseState(_ i: Int) {
        let element = circuit.elements[i]
        capacitorVoltage[i] = element.kind == .capacitor ? element[param: "initialVoltage"] : 0
        capacitorCurrent[i] = 0
        inductorVoltage[i] = 0
        inductorCurrent[i] = 0
        memristorStates[i] = element.kind == .memristor ? min(1, max(0, element[param: "initialState"])) : 0
        limitedVoltage[i] = 0
        limitedVoltage2[i] = 0
    }

    public func setTimeStep(_ dt: Double) {
        guard dt > 0, dt.isFinite, dt != timeStep else { return }
        timeStep = dt
        matrixIsCurrent = false
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
        return Progress(simulatedTime: Double(steps) * timeStep, steps: steps, fellBehind: fellBehind)
    }

    /// One time step
    public func step() {
        guard !isFailed else { return }
        let m = topology.matrixSize
        let t = time + timeStep
        if m > 0 {
            if !matrixIsCurrent { buildBaseMatrix() }
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
            case .capacitor:
                stampConductance(&matrix, m, nodes[0], nodes[1], 2 * element[param: "capacitance"] / timeStep)
            case .inductor:
                stampConductance(&matrix, m, nodes[0], nodes[1], timeStep / (2 * max(element[param: "inductance"], 1e-15)))
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
            default:
                break
            }
        }
        baseMatrix = matrix
        baseLU = (hasNonlinear || hasMemristor) ? nil : LUSolver(matrix: matrix, size: m)
        matrixIsCurrent = true
        if !hasNonlinear && !hasMemristor && baseLU == nil { fail() }
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
                // trapezoidal: i(n) = G v(n) - (G v(n-1) + i(n-1))
                let g = 2 * element[param: "capacitance"] / timeStep
                let history = g * capacitorVoltage[i] + capacitorCurrent[i]
                stampCurrent(&rhs, nodes[0], nodes[1], -history)
            case .inductor:
                // trapezoidal: i(n) = G v(n) + (i(n-1) + G v(n-1))
                let g = timeStep / (2 * max(element[param: "inductance"], 1e-15))
                let history = inductorCurrent[i] + g * inductorVoltage[i]
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

    // MARK: Semiconductors

    func diodeParameters(_ element: Element) -> (saturation: Double, nvt: Double) {
        if element.kind == .led {
            // emission coefficient 2, saturation current chosen for the colour's forward voltage at 10 mA
            let color = LEDColor(rawValue: Int(element[param: "color"])) ?? .red
            let nvt = 2 * Self.thermalVoltage
            return (0.01 / exp(color.forwardVoltage / nvt), nvt)
        }
        return (max(element[param: "saturationCurrent"], 1e-30), max(element[param: "emission"], 0.1) * Self.thermalVoltage)
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
                let g = 2 * element[param: "capacitance"] / timeStep
                capacitorCurrent[i] = g * v - (g * capacitorVoltage[i] + capacitorCurrent[i])
                capacitorVoltage[i] = v
            case .inductor:
                let v = voltage(nodes[0]) - voltage(nodes[1])
                let g = timeStep / (2 * max(element[param: "inductance"], 1e-15))
                inductorCurrent[i] = g * v + inductorCurrent[i] + g * inductorVoltage[i]
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

    private func computeCurrents() {
        let elements = circuit.elements
        guard currents.count == elements.count else { return }
        let hasSolution = x.count == topology.matrixSize
        func v(_ node: Int) -> Double { hasSolution ? voltage(node) : 0 }

        var injection = [Double](repeating: 0, count: topology.points.count)
        for (i, element) in elements.enumerated() {
            let nodes = topology.elementNodes[i]
            var current = 0.0
            switch element.kind {
            case .resistor, .lamp:
                current = (v(nodes[0]) - v(nodes[1])) / max(element[param: "resistance"], 1e-9)
            case .capacitor:
                current = capacitorCurrent[i]
            case .inductor:
                current = inductorCurrent[i]
            case .dcVoltage, .acVoltage, .squareVoltage:
                let row = topology.sourceRow[i]
                current = row >= 0 && hasSolution ? x[row] : 0
            case .currentSource:
                current = element[param: "current"]
            case .diode, .led:
                let (saturation, nvt) = diodeParameters(element)
                current = diodeCurrent(v(nodes[0]) - v(nodes[1]), saturation: saturation, nvt: nvt).current
            case .memristor:
                current = (v(nodes[0]) - v(nodes[1])) * memristorConductance(element, state: memristorStates[i])
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
                current = sign * polarity * model.id
            default:
                current = 0
            }
            currents[i] = current
            if element.isConductor || element.kind == .ground || element.kind == .probe { continue }
            // current leaving the element into the terminal point
            let points = topology.elementPoints[i]
            if element.kind.isTransistor {
                injection[points[1]] -= current
                injection[points[2]] += current
            } else if points.count == 2 {
                injection[points[0]] -= current
                injection[points[1]] += current
            }
        }

        for i in elements.indices where elements[i].isConductor { currents[i] = 0 }
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

    /// Voltage across the element (a minus b; drain minus source for transistors)
    public func voltageAcross(_ index: Int) -> Double {
        let v = terminalVoltages(index)
        guard v.count >= 2 else { return 0 }
        return circuit.elements[index].kind.isTransistor ? v[1] - v[2] : v[0] - v[1]
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
            if element.kind == .resistor || element.kind == .lamp { return element[param: "resistance"] }
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
        trace.add(value(trace.spec.quantity, of: index), at: time)
    }
}

/// Recent history of one scope quantity, kept as min/max buckets so fast signals still show their envelope.
public final class ScopeTrace {
    public let spec: ScopeSpec
    public let window: Double
    public static let capacity = 600

    public private(set) var minimums: [Double] = []
    public private(set) var maximums: [Double] = []
    public private(set) var lastValue: Double = 0
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
}
