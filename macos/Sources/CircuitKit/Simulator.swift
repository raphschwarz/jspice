import Foundation

/// Steps a circuit through time with modified nodal analysis.
///
/// Capacitors and inductors use second-order Gear (BDF2) companion models: accurate enough to keep LC circuits
/// oscillating, and stable on sudden changes (a switch closing straight onto a capacitor does not make its current ring
/// from step to step, as the trapezoidal rule does). Each step is taken in substeps where it needs to be: where the
/// integration's estimated error would be too large (an edge, a diode turning on) or Newton-Raphson does not converge,
/// the step is solved again in halves, quarters, down to a 64th. Diodes, transistors and op-amps are solved with Newton-Raphson at
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
    /// Steps at which Newton-Raphson did not converge, even with gmin stepping and the finest substeps (the step is
    /// accepted anyway)
    public private(set) var convergenceFailures = 0
    /// Whether substeps also follow the integration's estimated error (they always follow Newton-Raphson's failures).
    /// The sound turns it off: it sets its own step by how fast the computer keeps up.
    public var errorControl = true
    /// Substeps solved and kept, and solved and thrown away for a finer one, since the start
    public private(set) var substeps = 0
    public private(set) var rejectedSubsteps = 0

    /// What is being played on the keyboard: the note keyboard pitch sources put out and whether a key is held, which
    /// keyboard gate sources put out
    public struct KeyboardState: Equatable, Sendable {
        /// MIDI note number (60 is middle C); fractions bend the pitch
        public var note: Double
        public var gate: Bool

        public init(note: Double = 60, gate: Bool = false) {
            self.note = note
            self.gate = gate
        }

        /// Pitch control voltage at one volt per octave, 0 V at C2 (MIDI note 36)
        public var pitchVoltage: Double { (note - 36) / 12 }
    }

    public var keyboard = KeyboardState()
    /// True while a playing sequence sets the keyboard
    private var sequenceOwnsKeyboard = false

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
    /// The values before those, for the error estimate
    var capacitorVoltageOlder: [Double] = []
    var inductorCurrentOlder: [Double] = []
    var memristorStates: [Double] = []
    /// Newton limiting: the junction voltages last used for linearisation (diode; base-emitter and base-collector;
    /// gate-source and drain-source)
    var limitedVoltage: [Double] = []
    var limitedVoltage2: [Double] = []
    var limitedVoltage3: [Double] = []
    /// Random number generator state of each noise source (xorshift), so a run can be repeated exactly
    var noiseState: [UInt64] = []
    /// What went into each delay line, one value per step, oldest overwritten first
    private var delayHistory: [Int: DelayHistory] = [:]

    struct DelayHistory {
        var values: [Double]
        var written = 0

        init(capacity: Int) { values = Array(repeating: 0, count: max(capacity, 4)) }

        mutating func append(_ value: Double) {
            values[written % values.count] = value
            written += 1
        }

        /// The value `steps` steps ago (fractions interpolate); before the line filled up, silence
        func value(stepsAgo steps: Double) -> Double {
            let back = min(max(steps, 0), Double(values.count - 2))
            let whole = Int(back.rounded(.down))
            let fraction = back - Double(whole)
            func at(_ k: Int) -> Double {
                let index = written - 1 - k
                return index < 0 ? 0 : values[index % values.count]
            }
            return at(whole) * (1 - fraction) + at(whole + 1) * fraction
        }

        /// The same history kept at another time step (each new step `stepRatio` old steps long) or with another length
        func resampled(stepRatio: Double, capacity: Int) -> DelayHistory {
            var next = DelayHistory(capacity: capacity)
            guard stepRatio > 0, stepRatio.isFinite else { return next }
            let available = Double(min(written, values.count - 2)) / stepRatio
            let count = min(Int(available), next.values.count - 2)
            guard count > 0 else { return next }
            for k in stride(from: count - 1, through: 0, by: -1) { next.append(value(stepsAgo: Double(k) * stepRatio)) }
            return next
        }
    }
    /// What each synth chip and comparator puts out, and what it remembers from step to step
    var moduleStates: [ModuleState] = []

    struct ModuleState: Equatable {
        /// The output voltage over the next step
        var output = 0.0
        /// An oscillator's phase (0 to 1), an envelope's level (0 to 1), a held sample
        var level = 0.0
        /// A filter's four stages
        var s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0
        /// An envelope's stage (0 release, 1 attack, 2 decay and sustain), a divider's count
        var stage = 0
        /// Whether the first and second logic inputs were high (with hysteresis), to find rising edges
        var high = false
        var high2 = false
    }
    /// Microcontrollers' chips by element index (none until a part has firmware), the pin setup the matrix was built
    /// for, and the fraction of a clock cycle carried to the next step
    private var chips: [Int: Microcontroller] = [:]
    private var chipPinStates: [Int: [PinState]] = [:]
    private var chipCycleCarry: [Int: Double] = [:]
    private var chipIndices: [Int] = []
    /// On/off state of 555s (output high) and Schmitt inverters (output high)
    var digitalState: [Bool] = []
    /// What each logic part remembers: its inputs' levels, its count
    var logicStates: [LogicState] = []
    /// Op-amps: how often the input has been pulled back to the linear range in the present Newton solve
    private var opAmpCrossings: [Int] = []
    /// The main current of each element: from `a` to `b` for two-terminal parts, into the drain or collector for
    /// transistors, out of the output for op-amps, from `a` to the wiper for potentiometers
    public var currents: [Double] {
        refreshCurrents()
        return storedCurrents
    }
    /// Currents are only for showing, so they are worked out when asked for rather than at every step
    private var storedCurrents: [Double] = []
    private var currentsAreStale = true

    /// Each element's kind and parameter values, read once when the circuit is loaded
    private var kinds: [ElementKind] = []
    var constants: [Constants] = []
    /// The elements each part of a step needs, so wires and resistors cost nothing once the base matrix is built
    private var nonlinearIndices: [Int] = []
    private var drivenIndices: [Int] = []
    private var statefulIndices: [Int] = []
    private var digitalIndices: [Int] = []
    private var memristorIndices: [Int] = []
    /// Elements whose state moves with each substep, those whose error is estimated, and those that move once a step
    private var dynamicIndices: [Int] = []
    private var reactiveIndices: [Int] = []
    private var stepIndices: [Int] = []
    /// Scopes with the index of the element each one shows
    private var recordedTraces: [(trace: ScopeTrace, index: Int)] = []

    /// Newton-Raphson's matrix and right-hand side, reused from one iteration to the next
    private var workMatrix: [Double] = []
    private var workVector: [Double] = []
    /// The pivots and non-zero entries of the last elimination, replayed while the matrix keeps its pattern
    private var eliminationPlan: EliminationPlan?
    /// Matrix entries written by the stamps of the present Newton iteration (the base matrix and the stamps' own
    /// values are the only things that change the pattern), and how many: more than the log holds means it overflowed
    private var stampLog: [Int] = []
    private var stampCount = 0
    private var loggingStamps = false
    /// Counts base matrix rebuilds, and which one the elimination plan was last checked against
    private var baseVersion = 0
    private var planBaseVersion = -1
    /// The solution and junction voltages at the start of a step, to go back to for gmin stepping
    private var savedX: [Double] = []
    private var savedLimited: [Double] = []
    private var savedLimited2: [Double] = []
    private var savedLimited3: [Double] = []

    private var baseMatrix: [Double] = []
    private var baseLU: LUSolver?
    private var matrixIsCurrent = false
    private var hasNonlinear = false
    private var hasMemristor = false
    private var hasDigital = false
    private var stepCarry = 0.0
    /// Substeps are timeStep / 2^level long: the level of the next one, of the last one kept and of the one before
    private var substepLevel = 0
    private var lastLevel = 0
    private var olderLevel = 0
    static let finestLevel = 6
    /// Allowed local error of a substep: relative, and absolute in volts (capacitors) and amps (inductors)
    static let relativeTolerance = 1e-3
    static let voltageTolerance = 1e-4
    static let currentTolerance = 1e-7
    /// The substep being solved, and BDF2's coefficients for it after a substep `h / ratio` long:
    /// dx/dt ≈ (a0 x(n+1) + a1 x(n) + a2 x(n-1)) / h
    private var h = 1e-5
    private var a0 = 1.5, a1 = -2.0, a2 = 0.5
    /// Base matrices by substep level and the last one's, while the circuit stays the same
    private var baseCache: [Int: (matrix: [Double], lu: LUSolver?, version: Int)] = [:]
    private var baseKey = -1
    private var baseVersionCount = 0
    /// What a substep changes, kept to go back to if it is thrown away
    private var rejectX: [Double] = []
    private var rejectLimited: [Double] = []
    private var rejectLimited2: [Double] = []
    private var rejectLimited3: [Double] = []
    private var rejectDigital: [Bool] = []
    private var rejectLogic: [LogicState] = []
    /// Extra conductance across every junction while gmin stepping, otherwise zero
    private var junctionConductance = 0.0
    /// Set when this Newton iteration held a junction, gate or op-amp input back from the solution: the iteration is then
    /// not a converged one, however little the node voltages changed (a junction with a tiny saturation current barely
    /// conducts while it is held back, so the voltages can look settled while the junction is still catching up)
    private var limiting = false
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
    /// How long a noise source holds each sample, at least
    static let noiseSampleTime = 1 / 48_000.0

    public init(circuit: Circuit = Circuit(), timeStep: Double = 1e-5) {
        self.circuit = Circuit()
        self.timeStep = timeStep
        h = timeStep
        load(circuit)
    }

    // MARK: - Loading and settings

    private struct SavedState {
        var cv, cvp, cvo, ci, lv, li, lip, lio, m, l1, l2, l3: Double
        var digital: Bool
        var logic: LogicState
        var module: ModuleState
        var noise: UInt64
        var delay: DelayHistory?
    }

    /// Switches to a changed circuit, keeping the state (charge, current, memristor state) of elements that remain
    public func load(_ newCircuit: Circuit) {
        var previous: [UUID: SavedState] = [:]
        for (i, element) in circuit.elements.enumerated() where i < capacitorVoltage.count {
            previous[element.id] = SavedState(
                cv: capacitorVoltage[i], cvp: capacitorVoltagePrevious[i], cvo: capacitorVoltageOlder[i],
                ci: capacitorCurrent[i], lv: inductorVoltage[i], li: inductorCurrent[i], lip: inductorCurrentPrevious[i],
                lio: inductorCurrentOlder[i], m: memristorStates[i], l1: limitedVoltage[i],
                l2: limitedVoltage2[i], l3: limitedVoltage3[i], digital: digitalState[i], logic: logicStates[i], module: moduleStates[i],
                noise: noiseState[i], delay: delayHistory[i])
        }
        // chips keep running through edits that leave their firmware alone
        var previousChips: [UUID: (firmware: Data?, chip: Microcontroller, carry: Double)] = [:]
        for (i, chip) in chips where i < circuit.elements.count {
            previousChips[circuit.elements[i].id] = (circuit.elements[i].firmware, chip, chipCycleCarry[i] ?? 0)
        }
        // node voltages by place, so an edit does not throw away the solution (a latch keeps its state, and a paused
        // circuit still shows its voltages)
        var previousVoltages: [GridPoint: Double] = [:]
        if x.count == topology.matrixSize {
            for (p, point) in topology.points.enumerated() { previousVoltages[point] = voltage(topology.nodeOfPoint[p]) }
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
        capacitorVoltageOlder = Array(repeating: 0, count: count)
        inductorCurrentOlder = Array(repeating: 0, count: count)
        memristorStates = Array(repeating: 0, count: count)
        limitedVoltage = Array(repeating: 0, count: count)
        limitedVoltage2 = Array(repeating: 0, count: count)
        limitedVoltage3 = Array(repeating: 0, count: count)
        digitalState = Array(repeating: false, count: count)
        logicStates = Array(repeating: LogicState(), count: count)
        moduleStates = Array(repeating: ModuleState(), count: count)
        noiseState = Array(repeating: 0, count: count)
        opAmpCrossings = Array(repeating: 0, count: count)
        storedCurrents = Array(repeating: 0, count: count)
        kinds = newCircuit.elements.map(\.kind)
        constants = newCircuit.elements.map { makeConstants($0) }
        func indices(_ include: (ElementKind) -> Bool) -> [Int] { kinds.indices.filter { include(kinds[$0]) } }
        nonlinearIndices = indices {
            switch $0 {
            case .diode, .zener, .led, .npn, .pnp, .nmos, .pmos, .njfet, .opAmp, .ota, .analogSwitch, .multiplier, .vactrol,
                 .unbufferedInverter, .pll: return true
            default: return false
            }
        }
        drivenIndices = indices {
            switch $0 {
            case .dcVoltage, .acVoltage, .squareVoltage, .noiseVoltage, .currentSource, .capacitor, .inductor, .timer555,
                 .schmittInverter, .keyboardPitch, .keyboardGate, .delayLine, .digitalDelay, .comparator, .vco, .vcf, .envelope, .vca,
                 .sampleHold, .divider, .atmega328p, .atmega2560, .attiny85, .rp2040, .logicGate, .flipFlop, .decadeCounter,
                 .binaryCounter, .pll: return true
            default: return false
            }
        }
        statefulIndices = indices {
            [.capacitor, .inductor, .opAmp, .memristor, .keyboardPitch, .noiseVoltage, .vactrol].contains($0)
                || $0.isModule || $0 == .comparator
        }
        dynamicIndices = statefulIndices.filter { [.capacitor, .inductor, .opAmp, .memristor, .vactrol].contains(kinds[$0]) }
            + indices { $0 == .pll }
        reactiveIndices = indices { $0 == .capacitor || $0 == .inductor }
        stepIndices = statefulIndices.filter { !dynamicIndices.contains($0) }
        delayHistory = [:]
        digitalIndices = indices { $0.isDigital }
        chipIndices = indices { $0.isMicrocontroller }
        chips = [:]
        chipPinStates = [:]
        chipCycleCarry = [:]
        for i in chipIndices {
            let element = newCircuit.elements[i]
            if let previous = previousChips[element.id], previous.firmware == element.firmware,
               previous.chip.pinCount == element.kind.board?.terminalNames.count {
                chips[i] = previous.chip
                chipCycleCarry[i] = previous.carry
            } else if let firmware = element.firmware, let board = element.kind.board {
                chips[i] = board.makeChip(firmware: [UInt8](firmware))
            }
            chips[i]?.supply = constants[i].supply
            chipPinStates[i] = chips[i]?.pinStates
        }
        memristorIndices = indices { $0 == .memristor }
        for (i, element) in newCircuit.elements.enumerated() {
            if let state = previous[element.id] {
                capacitorVoltage[i] = state.cv
                capacitorVoltagePrevious[i] = state.cvp
                capacitorVoltageOlder[i] = state.cvo
                capacitorCurrent[i] = state.ci
                inductorVoltage[i] = state.lv
                inductorCurrent[i] = state.li
                inductorCurrentPrevious[i] = state.lip
                inductorCurrentOlder[i] = state.lio
                memristorStates[i] = state.m
                limitedVoltage[i] = state.l1
                limitedVoltage2[i] = state.l2
                limitedVoltage3[i] = state.l3
                digitalState[i] = state.digital
                logicStates[i] = state.logic
                moduleStates[i] = state.module
                noiseState[i] = state.noise
                if let delay = state.delay, element.kind == .delayLine || element.kind == .digitalDelay {
                    // a delay line keeps what it holds, in a history long enough for its new settings
                    let capacity = delayCapacity(i, timeStep: timeStep)
                    delayHistory[i] = delay.values.count == capacity ? delay : delay.resampled(stepRatio: 1, capacity: capacity)
                }
            } else {
                initialiseState(i)
            }
        }
        x = Array(repeating: 0, count: topology.matrixSize)
        for (p, point) in topology.points.enumerated() {
            let node = topology.nodeOfPoint[p]
            if node > 0, let v = previousVoltages[point] { x[node - 1] = v }
        }
        hasNonlinear = !nonlinearIndices.isEmpty
        hasDigital = !digitalIndices.isEmpty
        hasMemristor = !memristorIndices.isEmpty
        matrixIsCurrent = false
        isFailed = false
        problems = topology.problems
        configureScopes(window: traces.values.first?.window ?? 1)
        currentsAreStale = true
    }

    private func initialiseState(_ i: Int) {
        let element = circuit.elements[i]
        let v0 = element.kind == .capacitor ? element[param: "initialVoltage"] : 0
        capacitorVoltage[i] = v0
        capacitorVoltagePrevious[i] = v0
        capacitorVoltageOlder[i] = v0
        capacitorCurrent[i] = 0
        inductorVoltage[i] = 0
        inductorCurrent[i] = 0
        inductorCurrentPrevious[i] = 0
        inductorCurrentOlder[i] = 0
        memristorStates[i] = element.kind == .memristor ? min(1, max(0, element[param: "initialState"])) : 0
        limitedVoltage[i] = 0
        limitedVoltage2[i] = 0
        limitedVoltage3[i] = 0
        // a Schmitt inverter's input starts low, so its output starts high; a 555 decides from its trigger
        digitalState[i] = element.kind == .schmittInverter
        logicStates[i] = LogicState()
        // a keyboard's pitch starts at the present note rather than gliding up from 0 V
        if element.kind == .keyboardPitch { capacitorVoltage[i] = keyboard.pitchVoltage }
        // each noise source has its own sequence, the same every run
        noiseState[i] = 0x9E37_79B9_7F4A_7C15 &* UInt64(i + 1) | 1
        delayHistory[i] = nil
        // a comparator starts low, a divider at the start of its count (output high)
        var module = ModuleState()
        switch element.kind {
        case .comparator: module.output = constants[i].low
        case .divider: module.output = constants[i].supply
        default: break
        }
        moduleStates[i] = module
    }

    public func setTimeStep(_ dt: Double) {
        guard dt > 0, dt.isFinite, dt != timeStep else { return }
        let previous = timeStep
        timeStep = dt
        matrixIsCurrent = false
        // a delay line's history is kept one value per step: resample it to the new step
        for (i, history) in delayHistory {
            delayHistory[i] = history.resampled(stepRatio: dt / previous, capacity: delayCapacity(i, timeStep: dt))
        }
        // rebuild the history at the new step from the present slope
        substepLevel = 0
        lastLevel = 0
        olderLevel = 0
        for (i, element) in circuit.elements.enumerated() {
            if element.kind == .capacitor {
                let c = max(element[param: "capacitance"], 1e-30)
                capacitorVoltagePrevious[i] = capacitorVoltage[i] - capacitorCurrent[i] * dt / c
                capacitorVoltageOlder[i] = 2 * capacitorVoltagePrevious[i] - capacitorVoltage[i]
            } else if element.kind == .inductor {
                let l = max(element[param: "inductance"], 1e-15)
                inductorCurrentPrevious[i] = inductorCurrent[i] - inductorVoltage[i] * dt / l
                inductorCurrentOlder[i] = 2 * inductorCurrentPrevious[i] - inductorCurrent[i]
            } else if element.kind == .opAmp {
                capacitorVoltagePrevious[i] = capacitorVoltage[i]
            }
        }
    }

    /// Takes on the state of another simulator running the same circuit: its time and time step, solution, every
    /// element's state and its scope traces. The app's sound runs a second simulator on its own thread, and the window's
    /// simulator follows it this way to show what it is doing.
    public func adoptState(of other: Simulator) {
        guard other.circuit.elements.count == circuit.elements.count, other.x.count == x.count else { return }
        time = other.time
        if timeStep != other.timeStep {
            timeStep = other.timeStep
            matrixIsCurrent = false
            delayHistory = [:]
        }
        if digitalState != other.digitalState { matrixIsCurrent = false }
        x = other.x
        capacitorVoltage = other.capacitorVoltage
        capacitorVoltagePrevious = other.capacitorVoltagePrevious
        capacitorVoltageOlder = other.capacitorVoltageOlder
        capacitorCurrent = other.capacitorCurrent
        inductorVoltage = other.inductorVoltage
        inductorCurrent = other.inductorCurrent
        inductorCurrentPrevious = other.inductorCurrentPrevious
        inductorCurrentOlder = other.inductorCurrentOlder
        (substepLevel, lastLevel, olderLevel) = (other.substepLevel, other.lastLevel, other.olderLevel)
        memristorStates = other.memristorStates
        limitedVoltage = other.limitedVoltage
        limitedVoltage2 = other.limitedVoltage2
        limitedVoltage3 = other.limitedVoltage3
        digitalState = other.digitalState
        if logicStates != other.logicStates { matrixIsCurrent = false }
        logicStates = other.logicStates
        moduleStates = other.moduleStates
        for (i, chip) in chips {
            guard let source = other.chips[i] else { continue }
            chip.adopt(source)
            if let states = other.chipPinStates[i] {
                if !Self.samePinSetup(states, chipPinStates[i]) { matrixIsCurrent = false }
                chipPinStates[i] = states
            }
            chipCycleCarry[i] = other.chipCycleCarry[i]
        }
        noiseState = other.noiseState
        convergenceFailures = other.convergenceFailures
        isFailed = other.isFailed
        problems = other.problems
        stepCarry = 0
        currentsAreStale = true
        for (id, trace) in traces {
            if let source = other.traces[id] { trace.adopt(source) }
        }
    }

    /// Back to time zero with every element at rest
    public func reset() {
        time = 0
        stepCarry = 0
        convergenceFailures = 0
        (substepLevel, lastLevel, olderLevel) = (0, 0, 0)
        for i in circuit.elements.indices { initialiseState(i) }
        x = Array(repeating: 0, count: topology.matrixSize)
        isFailed = false
        problems = topology.problems
        for trace in traces.values { trace.clear() }
        delayHistory = [:]
        // 555s start low again, and their state is part of the base matrix; so do the chips' pins
        for (i, chip) in chips {
            chip.reset()
            chipPinStates[i] = chip.pinStates
            chipCycleCarry[i] = 0
        }
        matrixIsCurrent = false
        sequenceOwnsKeyboard = false
        currentsAreStale = true
    }

    /// Takes on new parameter values when nothing else about the circuit has changed (a knob turned, a value typed):
    /// the topology, every element's state and the solution all stay. False when the circuit changed in another way,
    /// which needs `load`.
    public func updateParameters(_ newCircuit: Circuit) -> Bool {
        guard newCircuit.elements.count == circuit.elements.count, newCircuit.scopes == circuit.scopes else { return false }
        for (old, new) in zip(circuit.elements, newCircuit.elements) {
            var same = new
            same.params = old.params
            if same != old { return false }
        }
        circuit = newCircuit
        constants = newCircuit.elements.map { makeConstants($0) }
        for (i, chip) in chips { chip.supply = constants[i].supply }
        for (i, history) in delayHistory {
            let capacity = delayCapacity(i, timeStep: timeStep)
            if history.values.count != capacity { delayHistory[i] = history.resampled(stepRatio: 1, capacity: capacity) }
        }
        matrixIsCurrent = false
        currentsAreStale = true
        return true
    }

    /// Steps of history a delay line keeps: enough for the slowest clock its control is likely to set
    private func delayCapacity(_ i: Int, timeStep dt: Double) -> Int {
        let c = constants[i]
        let longest = kinds[i] == .digitalDelay ? Self.longestEcho : min(c.value / (2 * max(c.frequency * 0.05, 100)), 2)
        return min(Int(longest / dt) + 4, 4_000_000)
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

    /// One time step, in substeps where it needs them
    public func step() {
        guard !isFailed else { return }
        let end = time + timeStep
        // a playing sequence plays the keyboard; when it stops, it lets go of the key it was holding
        if let sequence = circuit.sequence, sequence.playing, let state = sequence.state(at: end) {
            keyboard = KeyboardState(note: state.note, gate: state.gate)
            sequenceOwnsKeyboard = true
        } else if sequenceOwnsKeyboard {
            keyboard.gate = false
            sequenceOwnsKeyboard = false
        }
        if !chips.isEmpty { runChips() }
        // without capacitors, inductors or op-amp dynamics, smaller steps would only give the same answer again
        let canSubdivide = !dynamicIndices.isEmpty
        if !canSubdivide { substepLevel = 0 }
        let whole = 1 << Self.finestLevel
        var position = 0
        while position < whole {
            let level = substepLevel
            let units = whole >> level
            h = timeStep / Double(1 << level)
            let ratio = Double(1 << lastLevel) / Double(1 << level)
            a0 = (1 + 2 * ratio) / (1 + ratio)
            a1 = -(1 + ratio)
            a2 = ratio * ratio / (1 + ratio)
            let t = position + units == whole ? end : time + timeStep * Double(position + units) / Double(whole)
            let mayReject = canSubdivide && level < Self.finestLevel
            if mayReject {
                Self.copy(x, into: &rejectX)
                Self.copy(limitedVoltage, into: &rejectLimited)
                Self.copy(limitedVoltage2, into: &rejectLimited2)
                Self.copy(limitedVoltage3, into: &rejectLimited3)
                rejectDigital = digitalState
                rejectLogic = logicStates
            }
            var converged = solve(at: t)
            if isFailed { return }
            // a 555 or Schmitt trigger that switches during the substep changes the circuit: solve it again
            if hasDigital {
                for _ in 0..<4 {
                    guard updateDigitalStates() else { break }
                    converged = solve(at: t)
                    if isFailed { return }
                }
            }
            let error = canSubdivide && errorControl && converged ? errorRatio() : 0
            if mayReject && (!converged || error > 1) {
                Self.copy(rejectX, into: &x)
                Self.copy(rejectLimited, into: &limitedVoltage)
                Self.copy(rejectLimited2, into: &limitedVoltage2)
                Self.copy(rejectLimited3, into: &limitedVoltage3)
                if digitalState != rejectDigital || logicStates != rejectLogic {
                    digitalState = rejectDigital
                    logicStates = rejectLogic
                    matrixIsCurrent = false
                }
                rejectedSubsteps += 1
                // each halving cuts the error about eightfold
                let halvings = converged && error.isFinite ? max(1, Int(min(log2(cbrt(error) / 0.9), 6).rounded(.up))) : 1
                substepLevel = min(Self.finestLevel, level + halvings)
                continue
            }
            if !converged { convergenceFailures += 1 }
            updateDynamicStates()
            (olderLevel, lastLevel) = (lastLevel, level)
            substeps += 1
            position += units
            // twice as long again where the error leaves room, and where a substep twice as long ends on the grid
            if level > 0 && error < 0.09 && position % (2 * units) == 0 { substepLevel = level - 1 }
        }
        finishStep(at: end)
    }

    /// The largest local error of the substep just solved, over its tolerance: estimated for each capacitor's voltage
    /// and inductor's current from the third divided difference through it and the three values before it
    private func errorRatio() -> Double {
        let h1 = timeStep / Double(1 << lastLevel)
        let h2 = timeStep / Double(1 << olderLevel)
        // BDF2's local error is h² (h + h1)² / (6 (2h + h1)) times the third derivative, which is about 6 times the
        // third divided difference
        let scale = h * h * (h + h1) * (h + h1) / (2 * h + h1)
        var worst = 0.0
        for i in reactiveIndices {
            let nodes = topology.elementNodes[i]
            let v = voltage(nodes[0]) - voltage(nodes[1])
            let x0, x1, x2, x3, absolute: Double
            if kinds[i] == .capacitor {
                x0 = v
                x1 = capacitorVoltage[i]
                x2 = capacitorVoltagePrevious[i]
                x3 = capacitorVoltageOlder[i]
                absolute = Self.voltageTolerance
            } else {
                x1 = inductorCurrent[i]
                x2 = inductorCurrentPrevious[i]
                x0 = h / (a0 * constants[i].value) * v - (a1 * x1 + a2 * x2) / a0
                x3 = inductorCurrentOlder[i]
                absolute = Self.currentTolerance
            }
            let d01 = (x0 - x1) / h, d12 = (x1 - x2) / h1, d23 = (x2 - x3) / h2
            let d3 = ((d01 - d12) / (h + h1) - (d12 - d23) / (h1 + h2)) / (h + h1 + h2)
            let tolerance = Self.relativeTolerance * max(abs(x0), abs(x1)) + absolute
            worst = max(worst, scale * abs(d3) / tolerance)
        }
        return worst
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
        prepareBaseMatrix()
        if isFailed { return false }
        buildRightHandSide(at: t)
        let rhs = self.rhs
        if !hasNonlinear && !hasMemristor {
            guard let lu = baseLU else { fail(); return false }
            lu.solve(rhs, into: &x)
            if x.contains(where: { !$0.isFinite }) { fail(); return false }
            return true
        }
        Self.copy(x, into: &savedX)
        Self.copy(limitedVoltage, into: &savedLimited)
        Self.copy(limitedVoltage2, into: &savedLimited2)
        Self.copy(limitedVoltage3, into: &savedLimited3)
        junctionConductance = 0
        if newton(rhs, iterations: Self.maxNewtonIterations) || isFailed || !hasNonlinear { return !isFailed }
        let firstTry = (x, limitedVoltage, limitedVoltage2, limitedVoltage3)
        (x, limitedVoltage, limitedVoltage2, limitedVoltage3) = (savedX, savedLimited, savedLimited2, savedLimited3)
        var converged = false
        for conductance in Self.steppedConductances {
            junctionConductance = conductance
            converged = newton(rhs, iterations: Self.steppedIterations)
            if isFailed { break }
        }
        junctionConductance = 0
        // if that failed too, the first try is the better guess to carry on from
        if !converged && !isFailed { (x, limitedVoltage, limitedVoltage2, limitedVoltage3) = firstTry }
        return converged && !isFailed
    }

    /// Newton-Raphson from the present `x`; true when it converged
    private func newton(_ rhs: [Double], iterations: Int) -> Bool {
        let m = topology.matrixSize
        for i in nonlinearIndices { opAmpCrossings[i] = 0 }
        if workMatrix.count != m * m { workMatrix = [Double](repeating: 0, count: m * m) }
        if workVector.count != m { workVector = [Double](repeating: 0, count: m) }
        for iteration in 0..<iterations {
            Self.copy(baseMatrix, into: &workMatrix)
            Self.copy(rhs, into: &workVector)
            stampCount = 0
            loggingStamps = true
            stampMemristors(&workMatrix, m)
            limiting = false
            if hasNonlinear { stampNonlinear(&workMatrix, &workVector, m) }
            loggingStamps = false
            guard solveWorkMatrix(m) else { fail(); return false }
            var change = 0.0
            for k in 0..<m {
                let next = workVector[k]
                guard next.isFinite else { fail(); return false }
                change = max(change, abs(next - x[k]) / (1 + abs(next)))
            }
            Self.copy(workVector, into: &x)
            if !hasNonlinear { return true }
            if iteration > 0 && change < 1e-9 && !limiting { return true }
        }
        return false
    }

    /// Solves the stamped matrix in place, replaying the elimination plan when it still fits. Only the entries stamped
    /// this iteration can have left the plan's pattern, as long as the base matrix is the one the plan was checked
    /// against; otherwise the whole matrix is checked.
    private func solveWorkMatrix(_ m: Int) -> Bool {
        let solved: Bool
        if stampCount > stampLog.count {
            // more stamps than the log holds: check everything this time, and keep a longer log
            stampLog = [Int](repeating: 0, count: 2 * stampCount)
            solved = LUSolver.solveInPlace(&workMatrix, &workVector, size: m, plan: &eliminationPlan, changed: nil)
        } else if planBaseVersion != baseVersion {
            solved = LUSolver.solveInPlace(&workMatrix, &workVector, size: m, plan: &eliminationPlan, changed: nil)
        } else {
            let count = stampCount
            solved = stampLog.withUnsafeBufferPointer { log in
                LUSolver.solveInPlace(&workMatrix, &workVector, size: m, plan: &eliminationPlan,
                                      changed: UnsafeBufferPointer(rebasing: log[0..<count]))
            }
        }
        // the plan now fits this base matrix: it was made from it, or checked against all of it
        planBaseVersion = baseVersion
        return solved
    }

    /// Copies element by element into an array of the same size, so the target keeps its storage
    @inline(__always) private static func copy(_ source: [Double], into target: inout [Double]) {
        guard target.count == source.count else {
            target = source
            return
        }
        for k in source.indices { target[k] = source[k] }
    }

    private func finishStep(at t: Double) {
        time = t
        updateStepStates()
        currentsAreStale = true
        for (trace, index) in recordedTraces { record(trace, index) }
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
        if a > 0 { stamp(&matrix, (a - 1) * m + a - 1, g) }
        if b > 0 { stamp(&matrix, (b - 1) * m + b - 1, g) }
        if a > 0 && b > 0 {
            stamp(&matrix, (a - 1) * m + b - 1, -g)
            stamp(&matrix, (b - 1) * m + a - 1, -g)
        }
    }

    /// Adds to one matrix entry, noting where during Newton-Raphson's stamping (see `stampLog`)
    @inline(__always) private func stamp(_ matrix: inout [Double], _ index: Int, _ value: Double) {
        matrix[index] += value
        if loggingStamps {
            if stampCount < stampLog.count { stampLog[stampCount] = index }
            stampCount += 1
        }
    }

    /// A current i flowing through the element from node a to node b
    @inline(__always) private func stampCurrent(_ rhs: inout [Double], _ a: Int, _ b: Int, _ i: Double) {
        if a > 0 { rhs[a - 1] -= i }
        if b > 0 { rhs[b - 1] += i }
    }

    /// Adds `value` at (row, column) given as 0-based matrix indices; negative indices (ground) are skipped
    @inline(__always) private func add(_ matrix: inout [Double], _ m: Int, _ row: Int, _ column: Int, _ value: Double) {
        if row >= 0 && column >= 0 { stamp(&matrix, row * m + column, value) }
    }

    /// Conductances of a potentiometer's two halves: a to wiper, wiper to b
    func potentiometerResistances(_ element: Element) -> (Double, Double) {
        let total = max(element[param: "resistance"], 1e-3)
        var position = min(1, max(0, element[param: "position"]))
        // audio (logarithmic) taper: a tenth of the resistance at half way, as an A-type pot
        if element[param: "taper"] >= 0.5 { position = (pow(10, 2 * position) - 1) / 99 }
        let floor = total * 1e-4 + 1e-3
        return (max(total * position, floor), max(total * (1 - position), floor))
    }

    /// Makes the base matrix the one for this substep's length: kept from the last time it had this length, or built
    private func prepareBaseMatrix() {
        let key = substepLevel << 4 | lastLevel
        if matrixIsCurrent {
            if key == baseKey { return }
            if let entry = baseCache[key] {
                (baseMatrix, baseLU, baseVersion) = (entry.matrix, entry.lu, entry.version)
                baseKey = key
                return
            }
        } else {
            baseCache.removeAll(keepingCapacity: true)
        }
        buildBaseMatrix()
        baseKey = key
        if !isFailed { baseCache[key] = (baseMatrix, baseLU, baseVersion) }
    }

    /// The part of the matrix that only changes with the circuit or the substep
    private func buildBaseMatrix() {
        baseVersionCount += 1
        baseVersion = baseVersionCount
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
                stampConductance(&matrix, m, nodes[0], nodes[1], a0 * element[param: "capacitance"] / h)
            case .inductor:
                stampConductance(&matrix, m, nodes[0], nodes[1], h / (a0 * max(element[param: "inductance"], 1e-15)))
            case .dcVoltage, .acVoltage, .squareVoltage, .noiseVoltage, .keyboardPitch, .keyboardGate:
                let row = topology.sourceRow[i]
                guard row >= 0 else { continue }
                let minus = nodes[0] - 1
                let plus = nodes[1] - 1
                // the source delivers its current out of the + terminal (b) and takes it back at the - terminal (a)
                add(&matrix, m, plus, row, -1)
                add(&matrix, m, minus, row, 1)
                add(&matrix, m, row, plus, 1)
                add(&matrix, m, row, minus, -1)
            case .opAmp, .multiplier, .comparator, .delayLine, .digitalDelay, .vco, .vcf, .envelope, .vca, .sampleHold, .divider:
                // output: a voltage source to ground, whose voltage the nonlinear stage (or the delay line, or the chip's
                // state) sets
                if element.kind == .digitalDelay {
                    // an echo chip's pin 6: its internal reference behind its internal resistance
                    stampConductance(&matrix, m, nodes[1], 0, 1 / constants[i].value)
                }
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
            case .logicGate, .flipFlop, .decadeCounter, .binaryCounter, .pll:
                // each output likewise; the inputs draw nothing
                for k in element.kind.logicOutputs where k < nodes.count {
                    stampConductance(&matrix, m, nodes[k], 0, constants[i].outputConductance)
                }
            case .analogMux, .analogSelector:
                // the channel the select inputs pick, connected to the common terminal
                if let channel = Logic.channel(element.kind, logicStates[i]), let common = nodes.last, channel < nodes.count {
                    stampConductance(&matrix, m, nodes[channel], common, constants[i].onConductance)
                }
            case .atmega328p, .atmega2560, .attiny85, .rp2040:
                // each output pin drives towards the supply or ground through its resistance; a pull-up is a resistor
                // to the supply, a pull-down one to ground; other inputs draw nothing
                guard let states = chipPinStates[i] else { continue }
                let c = constants[i]
                for (pin, state) in states.enumerated() where pin < nodes.count {
                    switch state {
                    case .output: stampConductance(&matrix, m, nodes[pin], 0, c.outputConductance)
                    case .input(pullUp: true), .inputPullDown: stampConductance(&matrix, m, nodes[pin], 0, c.onConductance)
                    case .input: break
                    }
                }
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

    func sourceVoltage(_ i: Int, at t: Double) -> Double {
        let c = constants[i]
        switch kinds[i] {
        case .dcVoltage:
            return c.value
        case .acVoltage:
            return c.offset + c.amplitude * sin(2 * .pi * c.frequency * t + c.phase)
        case .squareVoltage:
            let cycle = (t * c.frequency).truncatingRemainder(dividingBy: 1)
            return cycle < c.duty ? c.high : c.low
        case .keyboardPitch:
            // glide: the voltage follows the note with a time constant, starting from the last step's voltage
            let target = keyboard.pitchVoltage
            guard c.tau > 0 else { return target }
            let previous = capacitorVoltage[i]
            return previous + (target - previous) * (1 - exp(-timeStep / c.tau))
        case .keyboardGate:
            return keyboard.gate ? c.high : 0
        case .noiseVoltage:
            // this step's sample, drawn when the last step finished
            return c.amplitude * capacitorVoltage[i]
        default:
            return 0
        }
    }

    /// The next sample of a noise source: Gaussian with unit variance (Box-Muller from two uniform numbers)
    private func nextNoise(_ i: Int) -> Double {
        func uniform() -> Double {
            var s = noiseState[i]
            s ^= s << 13
            s ^= s >> 7
            s ^= s << 17
            noiseState[i] = s
            return (Double(s >> 11) + 0.5) / Double(1 << 53)
        }
        let u = uniform()
        let v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }

    /// The right-hand side of the equations, rebuilt in place at each step
    private var rhs: [Double] = []

    private func buildRightHandSide(at t: Double) {
        let m = topology.matrixSize
        if rhs.count != m {
            rhs = [Double](repeating: 0, count: m)
        } else {
            for k in 0..<m { rhs[k] = 0 }
        }
        for i in drivenIndices {
            let nodes = topology.elementNodes[i]
            let c = constants[i]
            switch kinds[i] {
            case .dcVoltage, .acVoltage, .squareVoltage, .noiseVoltage, .keyboardPitch, .keyboardGate:
                let row = topology.sourceRow[i]
                if row >= 0 { rhs[row] = sourceVoltage(i, at: t) }
            case .currentSource:
                stampCurrent(&rhs, nodes[0], nodes[1], c.value)
            case .capacitor:
                // BDF2: i(n+1) = C/h (a0 v(n+1) + a1 v(n) + a2 v(n-1))
                let history = -c.value / h * (a1 * capacitorVoltage[i] + a2 * capacitorVoltagePrevious[i])
                stampCurrent(&rhs, nodes[0], nodes[1], -history)
            case .inductor:
                // BDF2: i(n+1) = h / (a0 L) v(n+1) - (a1 i(n) + a2 i(n-1)) / a0
                let history = -(a1 * inductorCurrent[i] + a2 * inductorCurrentPrevious[i]) / a0
                stampCurrent(&rhs, nodes[0], nodes[1], history)
            case .timer555:
                if digitalState[i] {
                    // high: VCC minus the output stage's drop
                    stampCurrent(&rhs, nodes[2], nodes[7], c.outputConductance * c.highDrop)
                } else {
                    // low: 0.1 V above GND
                    stampCurrent(&rhs, nodes[0], nodes[2], c.outputConductance * 0.1)
                }
            case .schmittInverter:
                if digitalState[i] {
                    stampCurrent(&rhs, 0, nodes[1], c.supply * c.outputConductance)
                }
            case .logicGate, .flipFlop, .decadeCounter, .binaryCounter, .pll:
                let kind = kinds[i]
                for (k, high) in zip(kind.logicOutputs, Logic.outputs(kind, logicStates[i], function: Int(c.value))) where high {
                    stampCurrent(&rhs, 0, nodes[k], c.supply * c.outputConductance)
                }
            case .atmega328p, .atmega2560, .attiny85, .rp2040:
                guard let states = chipPinStates[i] else { continue }
                for (pin, state) in states.enumerated() where pin < nodes.count {
                    switch state {
                    case .output(high: true): stampCurrent(&rhs, 0, nodes[pin], c.supply * c.outputConductance)
                    case .input(pullUp: true): stampCurrent(&rhs, 0, nodes[pin], c.supply * c.onConductance)
                    default: break
                    }
                }
            case .delayLine:
                let row = topology.sourceRow[i]
                if row >= 0 { rhs[row] = delayedOutput(i) }
            case .digitalDelay:
                stampCurrent(&rhs, 0, nodes[1], Self.echoReference / c.value)
                let row = topology.sourceRow[i]
                if row >= 0 { rhs[row] = moduleStates[i].output }
            case .comparator, .vco, .vcf, .envelope, .vca, .sampleHold, .divider:
                let row = topology.sourceRow[i]
                if row >= 0 { rhs[row] = moduleStates[i].output }
            default:
                break
            }
        }
    }

    /// A bucket-brigade delay line's output: its input as it was one delay ago, the delay being the stages over twice
    /// the clock, which the control voltage raises or lowers
    private func delayedOutput(_ i: Int) -> Double {
        let c = constants[i]
        guard let history = delayHistory[i] else { return 0 }
        let clock = max(c.frequency + c.slew * voltage(topology.elementNodes[i][1]), c.frequency * 0.05, 100)
        let delay = c.value / (2 * clock)
        return c.gain * history.value(stepsAgo: delay / timeStep - 1)
    }

    /// A vactrol's LDR: its resistance falls as a power of the light, which follows the LED current with the attack
    /// and decay times (the state)
    func vactrolConductance(_ i: Int) -> Double {
        let c = constants[i]
        let light = max(memristorStates[i], 0)
        let g = pow(light / c.high, c.threshold) / c.value
        return min(max(g, c.offConductance), 10)
    }

    func memristorConductance(_ i: Int, state: Double) -> Double {
        state * constants[i].onConductance + (1 - state) * constants[i].offConductance
    }

    private func stampMemristors(_ matrix: inout [Double], _ m: Int) {
        for i in memristorIndices {
            let nodes = topology.elementNodes[i]
            stampConductance(&matrix, m, nodes[0], nodes[1], memristorConductance(i, state: memristorStates[i]))
        }
    }

    // MARK: Parameters

    /// Parameter values the equations use, read from each element's parameters when the circuit is loaded instead of
    /// being looked up by name at every Newton iteration
    struct Constants {
        /// Capacitance, inductance, a current source's current, a DC source's voltage or a Zener's breakdown voltage
        var value = 0.0
        // AC and square-wave sources (phase in radians)
        var amplitude = 0.0, frequency = 0.0, phase = 0.0, duty = 0.0, high = 0.0, low = 0.0
        // op-amps, and the AC source's offset (slew rate in V/s)
        var offset = 0.0, gain = 1.0, limit = 1.0, gbw = 0.0, slew = 0.0
        // junctions: diodes and LEDs, an OTA's bias input
        var saturation = 1e-14, nvt = Simulator.thermalVoltage, critical = 0.0
        // transistors
        var beta = 1.0, polarity = 1.0, threshold = 0.0
        // OTAs (supply, output clamps), analog switches and Schmitt inverters (supply, thresholds in volts)
        var supply = 0.0, clampLevel = 0.0, upper = 0.0, lower = 0.0
        // analog switches and memristors fully on and off; gate outputs and a 555's discharge pin
        var onConductance = 0.0, offConductance = 0.0, outputConductance = 0.0, dischargeConductance = 0.0, highDrop = 0.0
        // memristors
        var tau = 1.0, von = 0.0, voff = 0.0
    }

    /// A parameter that picks a setting, as a whole number within `range` (typed or scripted values can be anything)
    static func choice(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(max(value.rounded(), range.lowerBound), range.upperBound) : range.lowerBound
    }

    private func makeConstants(_ element: Element) -> Constants {
        var c = Constants()
        func p(_ key: String) -> Double { element[param: key] }
        switch element.kind {
        case .capacitor:
            c.value = p("capacitance")
        case .inductor:
            c.value = max(p("inductance"), 1e-15)
        case .currentSource:
            c.value = p("current")
        case .dcVoltage:
            c.value = p("voltage")
        case .acVoltage:
            c.offset = p("offset")
            c.amplitude = p("amplitude")
            c.frequency = p("frequency")
            c.phase = p("phase") * .pi / 180
        case .squareVoltage:
            c.frequency = p("frequency")
            c.duty = p("duty")
            c.high = p("high")
            c.low = p("low")
        case .keyboardPitch:
            c.tau = max(p("glide"), 0)
        case .keyboardGate:
            c.high = p("high")
        case .noiseVoltage:
            c.amplitude = max(p("amplitude"), 0)
        case .diode, .led:
            (c.saturation, c.nvt) = diodeParameters(element)
            c.critical = c.nvt * log(c.nvt / (sqrt(2) * c.saturation))
        case .zener:
            c.value = abs(p("breakdown"))
        case .npn, .pnp:
            c.beta = max(p("beta"), 1)
            c.saturation = max(p("saturationCurrent"), 1e-20)
            c.critical = Self.thermalVoltage * log(Self.thermalVoltage / (sqrt(2) * c.saturation))
        case .multiplier:
            c.gain = p("scale")
            c.limit = max(p("limit"), 0.1)
        case .delayLine:
            c.value = max(p("stages"), 1)
            c.frequency = max(p("clock"), 1)
            c.slew = p("clockPerVolt")
            c.gain = p("gain")
        case .digitalDelay:
            c.slew = max(p("delayPerKilohm"), 1e-6)
            c.value = max(p("shortest"), 1e-3) / c.slew * 1000
            c.gain = p("gain")
            c.limit = max(p("limit"), 0.01)
            c.amplitude = max(p("noise"), 0)
        case .comparator:
            c.high = p("high")
            c.low = p("low")
            c.threshold = max(p("hysteresis"), 0)
        case .vco:
            c.value = Self.choice(p("waveform"), 0...3)
            c.frequency = max(p("frequency"), 0)
            c.amplitude = p("amplitude")
        case .vcf:
            c.frequency = max(p("cutoff"), 0.01)
            c.gain = 4 * max(p("resonance"), 0)
            c.limit = max(p("drive"), 0.01)
        case .envelope:
            c.tau = max(p("attack"), 1e-6)
            c.von = max(p("decay"), 1e-6)
            c.duty = min(max(p("sustain"), 0), 1)
            c.voff = max(p("release"), 1e-6)
            c.high = p("peak")
        case .vca:
            c.value = Self.choice(p("response"), 0...1)
            c.gain = p("dbPerVolt")
            c.threshold = max(p("unity"), 1e-3)
            c.limit = max(p("limit"), 0.1)
        case .sampleHold:
            c.value = Self.choice(p("mode"), 0...1)
            c.slew = max(p("droop"), 0)
        case .divider:
            c.value = Self.choice(p("division"), 2...1024)
            c.supply = max(p("supply"), 0.1)
        case .vactrol:
            // the LED: a red LED's junction
            (c.saturation, c.nvt) = (0.01 / exp(LEDColor.red.forwardVoltage / (2 * Self.thermalVoltage)), 2 * Self.thermalVoltage)
            c.critical = c.nvt * log(c.nvt / (sqrt(2) * c.saturation))
            c.value = max(p("ron"), 1e-3)
            c.high = max(p("iref"), 1e-9)
            c.offConductance = 1 / max(p("roff"), 1)
            c.threshold = max(p("gamma"), 0.01)
            c.tau = max(p("attack"), 1e-6)
            c.highDrop = max(p("decay"), 1e-6)
        case .nmos, .pmos, .njfet:
            (c.polarity, c.threshold, c.beta) = fetParameters(element)
        case .opAmp:
            c.offset = p("offset")
            c.gain = max(p("gain"), 1)
            c.limit = max(p("limit"), 0.01)
            c.gbw = p("gbw")
            c.slew = p("slewRate") * 1e6
        case .ota:
            // the bias input: one or two junctions down to the negative supply, 1 mA at 0.6 V per junction
            let drops = min(max(p("biasDrop").rounded(), 1), 2)
            c.supply = p("supply")
            c.nvt = drops * Self.thermalVoltage
            c.saturation = 1e-3 / exp(drops * 0.6 / c.nvt)
            c.critical = c.nvt * log(c.nvt / (sqrt(2) * c.saturation))
            // the output clamps below the supply less the headroom, less a junction drop
            c.clampLevel = max(p("supply") - p("headroom") - 0.6, 0)
        case .analogSwitch:
            c.supply = max(p("supply"), 1)
            c.onConductance = 1 / max(p("onResistance"), 1e-3)
            c.offConductance = 1e-10
        case .schmittInverter:
            c.supply = p("supply")
            c.upper = p("upper") * c.supply
            c.lower = p("lower") * c.supply
            c.outputConductance = 1 / max(p("outputResistance"), 0.1)
        case .logicGate, .flipFlop, .decadeCounter, .binaryCounter, .analogMux, .analogSelector, .pll:
            c.supply = max(p("supply"), 0.1)
            c.upper = p("upper") * c.supply
            c.lower = min(p("lower"), p("upper")) * c.supply
            c.outputConductance = 1 / max(p("outputResistance"), 0.1)
            c.onConductance = 1 / max(p("onResistance"), 1e-3)
            c.value = Self.choice(p("function"), 0...Double(Logic.gateFunctions.count - 1))
            c.frequency = max(p("fMin"), 0)
            c.high = max(p("fMax"), c.frequency)
        case .unbufferedInverter:
            c.supply = p("supply")
            c.threshold = p("threshold")
            c.beta = max(p("beta"), 1e-9)
            c.value = max(p("lambda"), 0)
        case .atmega328p, .atmega2560, .attiny85, .rp2040:
            c.supply = min(max(p("supply"), 0.5), 6)
            c.outputConductance = 1 / max(p("outputResistance"), 0.1)
            c.onConductance = 1 / max(p("pullUp"), 1)
        case .timer555:
            c.outputConductance = 1 / max(p("outputResistance"), 0.1)
            c.dischargeConductance = 1 / max(p("dischargeResistance"), 0.1)
            c.highDrop = p("highDrop")
        case .memristor:
            c.onConductance = 1 / max(p("ron"), 1e-9)
            c.offConductance = 1 / max(p("roff"), 1e-9)
            c.tau = max(p("tau"), 1e-12)
            c.von = p("von")
            c.voff = p("voff")
        default:
            break
        }
        return c
    }

    // MARK: Semiconductors and op-amps

    func diodeParameters(_ element: Element) -> (saturation: Double, nvt: Double) {
        switch element.kind {
        case .led:
            // emission coefficient 2, saturation current chosen for the colour's forward voltage at 10 mA
            let color = LEDColor(rawValue: Int(Self.choice(element[param: "color"], 0...4))) ?? .red
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
        limiting = true
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
    func mosfetCurrent(vgs: Double, vds: Double, threshold: Double, beta: Double, lambda: Double = 0.01)
        -> (id: Double, gm: Double, gds: Double) {
        let leak = 1e-9
        let overdrive = vgs - threshold
        if overdrive <= 0 { return (leak * vds, 0, leak) }
        if vds < overdrive {
            return (beta * (overdrive * vds - vds * vds / 2) + leak * vds, beta * vds, beta * (overdrive - vds) + leak)
        }
        let id = beta / 2 * overdrive * overdrive * (1 + lambda * vds) + leak * vds
        return (id, beta * overdrive * (1 + lambda * vds), beta / 2 * overdrive * overdrive * lambda + leak)
    }

    /// An unbuffered CMOS inverter's output current (into the output node) and its derivatives with respect to the input
    /// and output voltages: the PMOS's current from the supply less the NMOS's to ground, each transistor symmetric in
    /// drain and source
    func inverterCurrent(_ i: Int, vin: Double, vout: Double) -> (current: Double, dIn: Double, dOut: Double) {
        let c = constants[i]
        func branch(gate vg: Double, drain vd: Double) -> (current: Double, dGate: Double, dDrain: Double) {
            // an NMOS with its source at 0 V: the current into its drain
            if vd >= 0 {
                let m = mosfetCurrent(vgs: vg, vds: vd, threshold: c.threshold, beta: c.beta, lambda: c.value)
                return (m.id, m.gm, m.gds)
            }
            // below its source the drain acts as the source, and the current flows out of it
            let m = mosfetCurrent(vgs: vg - vd, vds: -vd, threshold: c.threshold, beta: c.beta, lambda: c.value)
            return (-m.id, -m.gm, m.gm + m.gds)
        }
        let n = branch(gate: vin, drain: vout)
        // the PMOS is an NMOS seen from the supply
        let p = branch(gate: c.supply - vin, drain: c.supply - vout)
        return (p.current - n.current, -p.dGate - n.dGate, -p.dDrain - n.dDrain)
    }

    struct BipolarModel {
        /// Currents into the collector and the base
        var ic, ib: Double
        /// Their derivatives with respect to the base-emitter and base-collector voltages
        var dicVbe, dicVbc, dibVbe, dibVbc: Double
    }

    /// Ebers-Moll transport model of an NPN transistor (a PNP is the same with all voltages and currents negated)
    func bipolarCurrents(vbe: Double, vbc: Double, beta: Double, saturation: Double = Simulator.transistorSaturationCurrent) -> BipolarModel {
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
    func opAmpOutput(_ i: Int, differential raw: Double) -> (voltage: Double, slope: Double, stage: Double) {
        let c = constants[i]
        let vd = raw + c.offset
        let gain = c.gain
        let limit = c.limit
        let gbw = c.gbw
        guard gbw > 0 else {
            let t = tanh(gain * vd / limit)
            return (limit * t, gain * (1 - t * t), limit * t)
        }
        let w = 2 * Double.pi * gbw
        let tau = gain / w
        let denominator = a0 / h + 1 / tau
        let slew = c.slew
        var drive = w * vd
        var driveSlope = w
        if slew > 0 {
            let t = tanh(vd * w / slew)
            drive = slew * t
            driveSlope = w * (1 - t * t)
        }
        // BDF2 for d(internal)/dt = drive - internal / tau
        let stage = (drive - (a1 * capacitorVoltage[i] + a2 * capacitorVoltagePrevious[i]) / h) / denominator
        let t = tanh(stage / limit)
        return (limit * t, (1 - t * t) * driveSlope / denominator, stage)
    }

    /// Input voltage beyond which an op-amp's output is no longer in its linear range within one step
    private func opAmpLinearRange(_ i: Int) -> Double {
        let c = constants[i]
        guard c.gbw > 0 else { return c.limit / c.gain }
        let w = 2 * Double.pi * c.gbw
        let stepGain = w / (a0 / h + w / c.gain)
        var range = c.limit / stepGain
        if c.slew > 0 { range = min(range, c.slew / w) }
        return range
    }

    /// The bias input of an OTA: the bias current I_abc and its conductance at junction voltage `vj` (bias pin voltage
    /// plus the supply)
    func otaBias(_ i: Int, junction vj: Double) -> (current: Double, conductance: Double) {
        diodeCurrent(vj, saturation: constants[i].saturation, nvt: constants[i].nvt)
    }

    /// Conductance of an analog switch and its slope with the control voltage: it turns on around half the supply
    func analogSwitchConductance(_ i: Int, control: Double) -> (conductance: Double, slope: Double) {
        let c = constants[i]
        let supply = c.supply
        let width = 0.02 * supply
        let on = c.onConductance
        let off = c.offConductance
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
        for i in nonlinearIndices {
            let nodes = topology.elementNodes[i]
            let c = constants[i]
            switch kinds[i] {
            case .diode, .led:
                let vd = limitJunction(voltage(nodes[0]) - voltage(nodes[1]), old: limitedVoltage[i], nvt: c.nvt, critical: c.critical)
                limitedVoltage[i] = vd
                var (id, gd) = diodeCurrent(vd, saturation: c.saturation, nvt: c.nvt)
                id += junctionConductance * vd
                gd += junctionConductance
                stampConductance(&matrix, m, nodes[0], nodes[1], gd)
                stampCurrent(&rhs, nodes[0], nodes[1], id - gd * vd)

            case .zener:
                let breakdown = c.value
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
                let p: Double = kinds[i] == .npn ? 1 : -1
                let (base, collector, emitter) = (nodes[0], nodes[1], nodes[2])
                let vt = Self.thermalVoltage
                let critical = c.critical
                // limit the junctions in the transistor's own polarity
                let vbe = limitJunction(p * (voltage(base) - voltage(emitter)), old: limitedVoltage[i], nvt: vt, critical: critical)
                let vbc = limitJunction(p * (voltage(base) - voltage(collector)), old: limitedVoltage2[i], nvt: vt, critical: critical)
                limitedVoltage[i] = vbe
                limitedVoltage2[i] = vbc
                var model = bipolarCurrents(vbe: vbe, vbc: vbc, beta: c.beta, saturation: c.saturation)
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
                func stampTerminal(_ node: Int, _ current: Double, _ gbe: Double, _ gbc: Double) {
                    guard node > 0 else { return }
                    // current into the device at this terminal, linear in vbe and vbc around the limited point
                    let row = node - 1
                    add(&matrix, m, row, base - 1, gbe + gbc)
                    add(&matrix, m, row, emitter - 1, -gbe)
                    add(&matrix, m, row, collector - 1, -gbc)
                    rhs[row] -= current - gbe * realVbe - gbc * realVbc
                }
                stampTerminal(collector, p * model.ic, model.dicVbe, model.dicVbc)
                stampTerminal(base, p * model.ib, model.dibVbe, model.dibVbc)
                stampTerminal(emitter, -p * (model.ic + model.ib), -(model.dicVbe + model.dibVbe), -(model.dicVbc + model.dibVbc))

            case .unbufferedInverter:
                let (input, output) = (nodes[0], nodes[1])
                var vin = voltage(input)
                var vout = voltage(output)
                // limit the change per iteration, as for a MOSFET's gate and drain
                if abs(vin - limitedVoltage[i]) > 0.5 || abs(vout - limitedVoltage2[i]) > 2 { limiting = true }
                vin = limitedVoltage[i] + max(-0.5, min(0.5, vin - limitedVoltage[i]))
                vout = limitedVoltage2[i] + max(-2, min(2, vout - limitedVoltage2[i]))
                limitedVoltage[i] = vin
                limitedVoltage2[i] = vout
                var (current, dIn, dOut) = inverterCurrent(i, vin: vin, vout: vout)
                // a shunt from the output to half the supply while gmin stepping
                current -= junctionConductance * (vout - c.supply / 2)
                dOut -= junctionConductance
                guard output > 0 else { continue }
                // the current into the output, linearised: its row takes the current leaving
                add(&matrix, m, output - 1, input - 1, -dIn)
                add(&matrix, m, output - 1, output - 1, -dOut)
                rhs[output - 1] += current - dIn * vin - dOut * vout

            case .pll:
                // phase comparator 2: driven high while pumping up, low while pumping down, and otherwise let go
                let pump = logicStates[i].count
                guard pump != 0, nodes.count > 6 else { continue }
                stampConductance(&matrix, m, nodes[6], 0, c.outputConductance)
                if pump > 0 { stampCurrent(&rhs, 0, nodes[6], c.supply * c.outputConductance) }

            case .nmos, .pmos, .njfet:
                let (polarity, threshold, beta) = (c.polarity, c.threshold, c.beta)
                let gate = nodes[0]
                var drain = nodes[1]
                var source = nodes[2]
                var vgs = voltage(gate) - voltage(source)
                var vds = voltage(drain) - voltage(source)
                // limit the gate voltage change per iteration
                if abs(vgs - limitedVoltage[i]) > 0.5 || abs(vds - limitedVoltage2[i]) > 2 { limiting = true }
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
                let range = opAmpLinearRange(i)
                if vd * limitedVoltage[i] < 0 && abs(vd) > range && opAmpCrossings[i] < 3 {
                    opAmpCrossings[i] += 1
                    limiting = true
                    vd = vd > 0 ? range : -range
                }
                limitedVoltage[i] = vd
                let (output, slope, _) = opAmpOutput(i, differential: vd)
                // v(out) = output + slope (vd' - vd), linearised around the present inputs
                add(&matrix, m, row, plus - 1, -slope)
                add(&matrix, m, row, minus - 1, slope)
                rhs[row] = output - slope * vd

            case .ota:
                let (minus, plus, output, bias) = (nodes[0], nodes[1], nodes[2], nodes[3])
                let supply = c.supply
                let vt = Self.thermalVoltage
                // bias input
                let vj = limitJunction(voltage(bias) + supply, old: limitedVoltage[i], nvt: c.nvt, critical: c.critical)
                limitedVoltage[i] = vj
                var (ib, gb) = otaBias(i, junction: vj)
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
                let level = c.clampLevel
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

            case .multiplier:
                // out = limit tanh(scale x y / limit), linearised in x and y
                let row = topology.sourceRow[i]
                guard row >= 0 else { continue }
                let vx = voltage(nodes[0])
                let vy = voltage(nodes[1])
                let t = tanh(c.gain * vx * vy / c.limit)
                let slope = 1 - t * t
                let fx = c.gain * vy * slope
                let fy = c.gain * vx * slope
                add(&matrix, m, row, nodes[0] - 1, -fx)
                add(&matrix, m, row, nodes[1] - 1, -fy)
                rhs[row] = c.limit * t - fx * vx - fy * vy

            case .vactrol:
                // the LED, like a diode, and the LDR, a resistance set by the light so far
                let vd = limitJunction(voltage(nodes[0]) - voltage(nodes[1]), old: limitedVoltage[i], nvt: c.nvt, critical: c.critical)
                limitedVoltage[i] = vd
                var (id, gd) = diodeCurrent(vd, saturation: c.saturation, nvt: c.nvt)
                id += junctionConductance * vd
                gd += junctionConductance
                stampConductance(&matrix, m, nodes[0], nodes[1], gd)
                stampCurrent(&rhs, nodes[0], nodes[1], id - gd * vd)
                stampConductance(&matrix, m, nodes[2], nodes[3], vactrolConductance(i))

            case .analogSwitch:
                let (a, b, control) = (nodes[0], nodes[1], nodes[2])
                let vc = voltage(control)
                let (g, slope) = analogSwitchConductance(i, control: vc)
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
        for i in digitalIndices {
            let nodes = topology.elementNodes[i]
            if kinds[i].isLogic {
                if updateLogic(i, nodes) { changed = true }
                continue
            }
            var high = digitalState[i]
            switch kinds[i] {
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
                let input = voltage(nodes[0])
                if input > constants[i].upper {
                    high = false
                } else if input < constants[i].lower {
                    high = true
                }
            default:
                break
            }
            if high != digitalState[i] {
                digitalState[i] = high
                changed = true
                // a 555's output and discharge stages are in the base matrix; a Schmitt inverter's state only moves
                // its output source on the right-hand side
                if kinds[i] == .timer555 { matrixIsCurrent = false }
            }
        }
        return changed
    }

    /// Reads a logic part's inputs (each with its thresholds' hysteresis) and moves it on; true if what it puts out changed
    private func updateLogic(_ i: Int, _ nodes: [Int]) -> Bool {
        let kind = kinds[i]
        let c = constants[i]
        let old = logicStates[i]
        var inputs = old.inputs
        for (bit, terminal) in kind.logicInputs.enumerated() where terminal < nodes.count {
            let mask = UInt32(1) << UInt32(bit)
            let v = voltage(nodes[terminal])
            let high = inputs & mask != 0 ? v >= c.lower : v > c.upper
            if high { inputs |= mask } else { inputs &= ~mask }
        }
        guard inputs != old.inputs else { return false }
        let next = Logic.next(kind, old, inputs: inputs)
        logicStates[i] = next
        if kind == .analogMux || kind == .analogSelector {
            guard Logic.channel(kind, next) != Logic.channel(kind, old) else { return false }
            // the switches are in the base matrix
            matrixIsCurrent = false
            return true
        }
        let function = Int(c.value)
        return Logic.outputs(kind, next, function: function) != Logic.outputs(kind, old, function: function) || next.count != old.count
    }

    // MARK: - After each step

    /// After each substep: the state of capacitors, inductors, op-amps' internal stages, vactrols and memristors
    private func updateDynamicStates() {
        for i in dynamicIndices {
            let nodes = topology.elementNodes[i]
            let parameters = constants[i]
            switch kinds[i] {
            case .capacitor:
                let v = voltage(nodes[0]) - voltage(nodes[1])
                let c = parameters.value
                capacitorCurrent[i] = c / h * (a0 * v + a1 * capacitorVoltage[i] + a2 * capacitorVoltagePrevious[i])
                capacitorVoltageOlder[i] = capacitorVoltagePrevious[i]
                capacitorVoltagePrevious[i] = capacitorVoltage[i]
                capacitorVoltage[i] = v
            case .inductor:
                let v = voltage(nodes[0]) - voltage(nodes[1])
                let g = h / (a0 * parameters.value)
                let next = g * v - (a1 * inductorCurrent[i] + a2 * inductorCurrentPrevious[i]) / a0
                inductorCurrentOlder[i] = inductorCurrentPrevious[i]
                inductorCurrentPrevious[i] = inductorCurrent[i]
                inductorCurrent[i] = next
                inductorVoltage[i] = v
            case .vactrol:
                // the light follows the LED current, faster as it rises (attack) than as it falls (decay)
                let led = diodeCurrent(voltage(nodes[0]) - voltage(nodes[1]), saturation: parameters.saturation, nvt: parameters.nvt).current
                let light = memristorStates[i]
                let tau = led > light ? parameters.tau : parameters.highDrop
                memristorStates[i] = max(0, led + (light - led) * exp(-h / tau))
            case .opAmp where parameters.gbw > 0:
                let (_, _, stage) = opAmpOutput(i, differential: voltage(nodes[1]) - voltage(nodes[0]))
                // the internal stage cannot wind up far beyond the output swing
                let bound = 3 * parameters.limit
                capacitorVoltagePrevious[i] = capacitorVoltage[i]
                capacitorVoltage[i] = min(bound, max(-bound, stage))
            case .memristor:
                // threshold switching: the state relaxes towards "on" above the on threshold and towards "off" below
                // minus the off threshold, with the given switching time
                let v = voltage(nodes[0]) - voltage(nodes[1])
                let sharpness = 0.02
                let tau = parameters.tau
                let towardsOn = 1 / (1 + exp(-(v - parameters.von) / sharpness)) / tau
                let towardsOff = 1 / (1 + exp((v + parameters.voff) / sharpness)) / tau
                let rate = towardsOn + towardsOff
                if rate > 1e-12 {
                    let target = towardsOn / rate
                    memristorStates[i] = target + (memristorStates[i] - target) * exp(-rate * h)
                }
            case .pll:
                // the VCO runs at a frequency from fMin to fMax as VCO IN goes from 0 V to the supply; inhibited, it stops
                guard logicStates[i].inputs & 0b100 == 0 else { break }
                let fraction = min(max(voltage(nodes[2]) / max(parameters.supply, 1e-3), 0), 1)
                let frequency = parameters.frequency + (parameters.high - parameters.frequency) * fraction
                logicStates[i].phase = (logicStates[i].phase + frequency * h).truncatingRemainder(dividingBy: 1)
            default:
                break
            }
        }
    }

    /// After each whole step: keyboard glide, noise, delay lines and synth chips, which move in steps of their own
    private func updateStepStates() {
        for i in stepIndices {
            let nodes = topology.elementNodes[i]
            let parameters = constants[i]
            switch kinds[i] {
            case .keyboardPitch:
                capacitorVoltage[i] = sourceVoltage(i, at: time)
            case .noiseVoltage:
                // a new sample every 1/48000 s (or every step, if steps are longer): with sound on, the steps of an
                // oversampled audio sample share one, so the noise sounds the same however many steps there are
                if time >= memristorStates[i] {
                    capacitorVoltage[i] = nextNoise(i)
                    memristorStates[i] = time + Self.noiseSampleTime - timeStep / 2
                }
            case .comparator, .vco, .vcf, .envelope, .vca, .sampleHold, .divider:
                updateModule(i, nodes, parameters)
            case .delayLine:
                if delayHistory[i] == nil { delayHistory[i] = DelayHistory(capacity: delayCapacity(i, timeStep: timeStep)) }
                delayHistory[i]?.append(voltage(nodes[0]))
            case .digitalDelay:
                if delayHistory[i] == nil { delayHistory[i] = DelayHistory(capacity: delayCapacity(i, timeStep: timeStep)) }
                delayHistory[i]?.append(voltage(nodes[0]))
                updateEcho(i)
            default:
                break
            }
        }
    }

    /// An echo chip's longest delay
    static let longestEcho = 1.0
    /// The reference an echo chip's pin 6 sits behind
    static let echoReference = 2.5

    /// An echo chip's delay. Its pin 6 is an internal reference behind an internal resistance, and the current drawn
    /// from it sets the clock: so the delay goes with the resistance from pin 6 to ground plus the internal one (the
    /// PT2399 datasheet's table: about 11.5 ms per kΩ, plus 24 ms), and a control voltage through a resistor moves it.
    func echoDelay(_ i: Int) -> Double {
        let c = constants[i]
        let nodes = topology.elementNodes[i]
        guard nodes.count > 1 else { return c.slew * c.value / 1000 }
        let current = (Self.echoReference - voltage(nodes[1])) / c.value
        guard current > Self.echoReference / 1e9 else { return Self.longestEcho }
        let delay = c.slew * (Self.echoReference / current) / 1000
        return min(max(delay, 1e-3), Self.longestEcho)
    }

    /// The delay of the echo chip at `index`, in seconds
    public func echoDelaySeconds(_ index: Int) -> Double {
        guard index < kinds.count, kinds[index] == .digitalDelay, x.count == topology.matrixSize else { return 0 }
        return echoDelay(index)
    }

    /// An echo chip's output over the next step: its input one delay ago, with the converters' noise, through two poles
    /// of low-pass filtering. Both follow the clock: the longer the delay the slower it runs, so the noisier and the
    /// darker the echo (20 kHz of bandwidth at 30 ms, 2.4 kHz at 340 ms).
    private func updateEcho(_ i: Int) {
        let c = constants[i]
        let delay = echoDelay(i)
        let delayed = delayHistory[i]?.value(stepsAgo: delay / timeStep - 1) ?? 0
        // white noise of the given RMS in a 24 kHz band, whatever the step
        let noise = c.amplitude * (delay / 0.1) * (1 / (48_000 * timeStep)).squareRoot() * (c.amplitude > 0 ? nextNoise(i) : 0)
        let cutoff = min(820 / delay, 20_000, 0.4 / timeStep)
        let g = 1 - exp(-2 * .pi * cutoff * timeStep)
        var s = moduleStates[i]
        s.s1 += g * (delayed + noise - s.s1)
        s.s2 += g * (s.s1 - s.s2)
        s.output = c.limit * tanh(c.gain * s.s2 / c.limit)
        moduleStates[i] = s
    }

    /// A logic input with hysteresis, as the synth chips have: high above 1.5 V, low again below 1 V
    @inline(__always) private static func logicHigh(_ v: Double, was: Bool) -> Bool {
        was ? v >= 1 : v > 1.5
    }

    // MARK: Microcontrollers

    /// The chip of the microcontroller at `index`, if it has firmware
    public func chip(_ index: Int) -> Microcontroller? { chips[index] }

    /// Restarts one chip from its reset vector, the rest of the circuit carrying on
    public func resetChip(_ index: Int) {
        guard let chip = chips[index] else { return }
        chip.reset()
        chipCycleCarry[index] = 0
        chipPinStates[index] = chip.pinStates
        matrixIsCurrent = false
        currentsAreStale = true
    }

    /// Runs each chip for the coming step's clock cycles, its inputs at the voltages of the last step, and notes
    /// whether its pins changed between input and output (which changes the matrix; levels only change currents)
    private func runChips() {
        for i in chipIndices {
            guard let chip = chips[i] else { continue }
            let nodes = topology.elementNodes[i]
            var volts = [Double](repeating: 0, count: chip.pinCount)
            for pin in 0..<min(chip.pinCount, nodes.count) { volts[pin] = voltage(nodes[pin]) }
            chip.pinVoltages = volts
            let budget = timeStep * chip.clock + (chipCycleCarry[i] ?? 0)
            let whole = max(Int(budget), 0)
            let start = chip.cycles
            if whole > 0 { chip.run(cycles: whole) }
            // the last instruction may run past the budget: the next step has that much less
            chipCycleCarry[i] = budget - Double(chip.cycles - start)
            let states = chip.pinStates
            if !Self.samePinSetup(states, chipPinStates[i]) { matrixIsCurrent = false }
            chipPinStates[i] = states
        }
    }

    /// Whether two pin states need the same matrix: each pin an output, an input with pull-up or pull-down, or a bare input
    private static func samePinSetup(_ a: [PinState], _ b: [PinState]?) -> Bool {
        guard let b, a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            switch (x, y) {
            case (.output, .output): continue
            case let (.input(p), .input(q)) where p == q: continue
            case (.inputPullDown, .inputPullDown): continue
            default: return false
            }
        }
        return true
    }

    /// Works out what a synth chip or comparator puts out over the next step, from its inputs at the end of this one
    private func updateModule(_ i: Int, _ nodes: [Int], _ c: Constants) {
        var s = moduleStates[i]
        let in0 = voltage(nodes[0])
        let in1 = voltage(nodes[1])
        let dt = timeStep
        switch kinds[i] {
        case .comparator:
            // + minus −, with half the hysteresis either side of zero
            let difference = in1 - in0
            if s.high {
                if difference < -c.threshold / 2 { s.high = false }
            } else if difference > c.threshold / 2 {
                s.high = true
            }
            s.output = s.high ? c.high : c.low
        case .vco:
            // one volt per octave from the CV; the phase runs from 0 to 1 once per cycle
            let frequency = min(c.frequency * pow(2, min(max(in0, -16), 16)), 0.45 / dt)
            let increment = frequency * dt
            var phase = s.level + increment
            phase -= phase.rounded(.down)
            s.level = phase
            let duty = min(max(0.5 + in1 / 10, 0.05), 0.95)
            s.output = c.amplitude * Self.oscillator(Int(c.value), phase: phase, increment: increment, duty: duty)
        case .vcf:
            // four one-pole stages with soft saturation, the last fed back to the input for resonance: the cutoff
            // doubles with each volt of CV
            let cutoff = min(c.frequency * pow(2, min(max(in1, -16), 16)), 0.4 / dt)
            let g = 1 - exp(-2 * .pi * cutoff * dt)
            let input = tanh(in0 / c.limit - c.gain * s.s4)
            let t1 = tanh(s.s1), t2 = tanh(s.s2), t3 = tanh(s.s3)
            s.s1 += g * (input - t1)
            s.s2 += g * (t1 - t2)
            s.s3 += g * (t2 - t3)
            s.s4 += g * (t3 - tanh(s.s4))
            s.output = c.limit * s.s4
        case .envelope:
            let gateWas = s.high
            let triggerWas = s.high2
            s.high = Self.logicHigh(in0, was: gateWas)
            s.high2 = Self.logicHigh(in1, was: triggerWas)
            if !s.high {
                s.stage = 0
            } else if !gateWas || (s.high2 && !triggerWas) {
                s.stage = 1
            }
            switch s.stage {
            case 1:
                // attack: charging towards one and a half times the peak reaches the peak in the attack time
                s.level = 1.5 + (s.level - 1.5) * exp(-dt * log(3) / c.tau)
                if s.level >= 1 {
                    s.level = 1
                    s.stage = 2
                }
            case 2:
                // decay towards the sustain level, nine tenths of the way in the decay time
                s.level = c.duty + (s.level - c.duty) * exp(-dt * log(10) / c.von)
            default:
                // release: down to a tenth in the release time
                s.level *= exp(-dt * log(10) / c.voff)
            }
            s.output = c.high * s.level
        case .vca:
            let gain = c.value < 0.5 ? pow(10, min(c.gain * in1 / 20, 40.0 / 20)) : min(max(in1, 0) / c.threshold, 100)
            s.output = c.limit * tanh(gain * in0 / c.limit)
        case .sampleHold:
            let was = s.high
            s.high = Self.logicHigh(in1, was: was)
            if c.value < 0.5 ? (s.high && !was) : s.high {
                s.level = in0
            } else if c.slew > 0 {
                // the hold capacitor slowly leaks towards zero
                s.level -= min(abs(s.level), c.slew * dt) * (s.level < 0 ? -1 : 1)
            }
            s.output = s.level
        case .divider:
            // CMOS input: switches at half the supply, with a little hysteresis; reset holds the count at zero
            let threshold = c.supply / 2
            let was = s.high
            s.high = was ? in0 > threshold * 0.9 : in0 > threshold * 1.1
            s.high2 = in1 > threshold
            let n = Int(c.value)
            if s.high2 {
                s.stage = 0
            } else if s.high && !was {
                s.stage = (s.stage + 1) % n
            }
            // high for the first half of the count
            s.output = s.stage < (n + 1) / 2 ? c.supply : 0
        default:
            break
        }
        moduleStates[i] = s
    }

    /// One sample of a VCO waveform (from −1 to 1) at `phase`, the phase advancing by `increment` per sample. The jumps
    /// of the saw and pulse are smoothed over a sample either side (PolyBLEP), which keeps high notes from aliasing.
    static func oscillator(_ waveform: Int, phase t: Double, increment dt: Double, duty: Double) -> Double {
        func blep(_ t: Double) -> Double {
            if t < dt {
                let x = t / dt
                return x + x - x * x - 1
            }
            if t > 1 - dt {
                let x = (t - 1) / dt
                return x * x + x + x + 1
            }
            return 0
        }
        switch waveform {
        case 1:
            return 1 - 4 * abs(t - 0.5)
        case 2:
            var fall = t - duty + 1
            fall -= fall.rounded(.down)
            return (t < duty ? 1 : -1) + blep(t) - blep(fall)
        case 3:
            return sin(2 * .pi * t)
        default:
            return 2 * t - 1 - blep(t)
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
        case .dcVoltage, .acVoltage, .squareVoltage, .noiseVoltage, .keyboardPitch, .keyboardGate:
            let row = topology.sourceRow[i]
            return twoTerminal(row >= 0 && row < x.count ? x[row] : 0)
        case .currentSource:
            return twoTerminal(constants[i].value)
        case .diode, .led:
            let c = constants[i]
            return twoTerminal(diodeCurrent(v(nodes[0]) - v(nodes[1]), saturation: c.saturation, nvt: c.nvt).current)
        case .zener:
            return twoTerminal(zenerCurrent(v(nodes[0]) - v(nodes[1]), breakdown: constants[i].value).current)
        case .memristor:
            return twoTerminal((v(nodes[0]) - v(nodes[1])) * memristorConductance(i, state: memristorStates[i]))
        case .nmos, .pmos, .njfet:
            let (polarity, threshold, beta) = (constants[i].polarity, constants[i].threshold, constants[i].beta)
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
                                        beta: constants[i].beta, saturation: constants[i].saturation)
            let (ic, ib) = (p * model.ic, p * model.ib)
            return (ic, [-ib, -ic, ic + ib])
        case .opAmp, .multiplier, .comparator, .delayLine, .digitalDelay, .vco, .vcf, .envelope, .vca, .sampleHold, .divider:
            let row = topology.sourceRow[i]
            let current = row >= 0 && row < x.count ? x[row] : 0
            return (current, [0, 0, current])
        case .vactrol:
            let c = constants[i]
            let led = diodeCurrent(v(nodes[0]) - v(nodes[1]), saturation: c.saturation, nvt: c.nvt).current
            let ldr = (v(nodes[2]) - v(nodes[3])) * vactrolConductance(i)
            return (led, [-led, led, -ldr, ldr])
        case .ota:
            let supply = constants[i].supply
            let bias = otaBias(i, junction: v(nodes[3]) + supply).current
            let level = constants[i].clampLevel
            let vt = Self.thermalVoltage
            let clampUp = diodeCurrent(v(nodes[2]) - level, saturation: 1e-14, nvt: vt).current
            let clampDown = diodeCurrent(-level - v(nodes[2]), saturation: 1e-14, nvt: vt).current
            let output = bias * tanh((v(nodes[1]) - v(nodes[0])) / (2 * vt)) - clampUp + clampDown
            return (output, [0, 0, output, -bias])
        case .analogSwitch:
            let g = analogSwitchConductance(i, control: v(nodes[2])).conductance
            let current = g * (v(nodes[0]) - v(nodes[1]))
            return (current, [-current, current, 0])
        case .schmittInverter:
            let target = digitalState[i] ? constants[i].supply : 0
            let current = (target - v(nodes[1])) * constants[i].outputConductance
            return (current, [0, current])
        case .unbufferedInverter:
            let current = inverterCurrent(i, vin: v(nodes[0]), vout: v(nodes[1])).current
            return (current, [0, current])
        case .logicGate, .flipFlop, .decadeCounter, .binaryCounter, .pll:
            // the main current: what the outputs supply (for a gate, what its output puts out)
            let c = constants[i]
            let kind = element.kind
            var flows = [Double](repeating: 0, count: nodes.count)
            var total = 0.0
            for (k, high) in zip(kind.logicOutputs, Logic.outputs(kind, logicStates[i], function: Int(c.value))) where k < nodes.count {
                flows[k] = ((high ? c.supply : 0) - v(nodes[k])) * c.outputConductance
                total += kind == .logicGate ? flows[k] : max(flows[k], 0)
            }
            return (total, flows)
        case .analogMux, .analogSelector:
            // through the channel that is on, into the common terminal
            var flows = [Double](repeating: 0, count: nodes.count)
            guard let channel = Logic.channel(element.kind, logicStates[i]), channel < nodes.count - 1 else { return (0, flows) }
            let current = (v(nodes[channel]) - v(nodes[nodes.count - 1])) * constants[i].onConductance
            flows[channel] = -current
            flows[nodes.count - 1] = current
            return (current, flows)
        case .atmega328p, .atmega2560, .attiny85, .rp2040:
            let c = constants[i]
            var flows = [Double](repeating: 0, count: nodes.count)
            var total = 0.0
            if let states = chipPinStates[i] {
                for (pin, state) in states.enumerated() where pin < nodes.count {
                    switch state {
                    case .output(let high): flows[pin] = ((high ? c.supply : 0) - v(nodes[pin])) * c.outputConductance
                    case .input(pullUp: true): flows[pin] = (c.supply - v(nodes[pin])) * c.onConductance
                    case .inputPullDown: flows[pin] = -v(nodes[pin]) * c.onConductance
                    case .input: break
                    }
                    total += max(flows[pin], 0)
                }
            }
            // the main current: what the chip supplies through its pins
            return (total, flows)
        case .timer555:
            let (ground, output, control, discharge, supply) = (nodes[0], nodes[2], nodes[4], nodes[6], nodes[7])
            let high = digitalState[i]
            let upper = (v(supply) - v(control)) / 5000
            let lower = (v(control) - v(ground)) / 10_000
            let target = high ? v(supply) - constants[i].highDrop : v(ground) + 0.1
            let out = (target - v(output)) * constants[i].outputConductance
            let dischargeIn = (v(discharge) - v(ground)) * (high ? 1e-9 : constants[i].dischargeConductance)
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

    private func refreshCurrents() {
        guard currentsAreStale else { return }
        currentsAreStale = false
        computeCurrents()
    }

    private func computeCurrents() {
        let elements = circuit.elements
        guard storedCurrents.count == elements.count else { return }
        let hasSolution = x.count == topology.matrixSize
        func v(_ node: Int) -> Double { hasSolution ? voltage(node) : 0 }

        var injection = [Double](repeating: 0, count: topology.points.count)
        for (i, element) in elements.enumerated() {
            if element.isConductor {
                storedCurrents[i] = 0
                continue
            }
            let (main, out) = elementCurrents(i, element, v)
            storedCurrents[i] = main
            for (point, current) in zip(topology.elementPoints[i], out) {
                injection[point] += current
            }
        }
        // wires and other conductors carry what flows into them from the leaves of the wire network inwards
        for step in topology.flowOrder {
            let flow = injection[step.from]
            injection[step.to] += flow
            storedCurrents[step.element] = topology.elementPoints[step.element][0] == step.from ? flow : -flow
        }
    }

    // MARK: - Readings

    public func voltage(at point: GridPoint) -> Double {
        guard let p = topology.pointIndex[point], x.count == topology.matrixSize else { return 0 }
        return voltage(topology.nodeOfPoint[p])
    }

    /// Voltage of each terminal of the element at `index`
    /// Voltage of one terminal of the element at `index`, without building the list of all of them
    public func terminalVoltage(_ index: Int, _ terminal: Int) -> Double {
        guard index < topology.elementNodes.count, x.count == topology.matrixSize else { return 0 }
        let nodes = topology.elementNodes[index]
        return terminal >= 0 && terminal < nodes.count ? voltage(nodes[terminal]) : 0
    }

    public func terminalVoltages(_ index: Int) -> [Double] {
        guard index < topology.elementNodes.count, x.count == topology.matrixSize else { return [] }
        return topology.elementNodes[index].map { voltage($0) }
    }

    /// Voltage across the element: a minus b; for voltage sources + (b) minus - (a), so a 5 V source reads 5 V;
    /// drain minus source (collector minus emitter) for transistors; the output voltage for op-amps
    public func voltageAcross(_ index: Int) -> Double {
        guard index < topology.elementNodes.count, index < kinds.count, x.count == topology.matrixSize else { return 0 }
        let nodes = topology.elementNodes[index]
        func v(_ k: Int) -> Double { voltage(nodes[k]) }
        if nodes.count == 1 { return v(0) }
        guard nodes.count >= 2 else { return 0 }
        let kind = kinds[index]
        if kind.isTransistor { return v(1) - v(2) }
        if kind == .ota || kind.drivesOutput { return v(2) }
        if kind == .timer555 { return v(2) - v(0) }
        if kind.isMicrocontroller || kind.chipPackage != nil { return constants[index].supply }
        if kind == .schmittInverter || kind == .unbufferedInverter { return v(1) }
        if kind == .logicGate { return v(2) }
        return kind.isVoltageSource ? v(1) - v(0) : v(0) - v(1)
    }

    public func current(_ index: Int) -> Double {
        refreshCurrents()
        return index < storedCurrents.count ? storedCurrents[index] : 0
    }

    public func value(_ quantity: Quantity, of index: Int) -> Double {
        switch quantity {
        case .voltage: return voltageAcross(index)
        case .current: return current(index)
        case .power: return voltageAcross(index) * current(index)
        case .resistance:
            let element = circuit.elements[index]
            if element.kind == .memristor { return 1 / memristorConductance(index, state: memristorStates[index]) }
            if element.kind == .resistor || element.kind == .lamp || element.kind == .potentiometer {
                return element[param: "resistance"]
            }
            let i = current(index)
            return abs(i) > 1e-15 ? voltageAcross(index) / i : .infinity
        }
    }

    /// 0 (dark) to 1 (full brightness) for LEDs and lamps (and the Pico's LED)
    public func brightness(_ index: Int) -> Double {
        let element = circuit.elements[index]
        switch element.kind {
        case .led:
            return min(1, max(0, current(index) / 0.015))
        case .lamp:
            let power = abs(voltageAcross(index) * current(index))
            return min(1, power / max(element[param: "ratedPower"], 1e-9))
        case .rp2040:
            // the Pico's own LED
            return (chips[index] as? Pico)?.ledOn == true ? 1 : 0
        default:
            return 0
        }
    }

    /// True while a 555's, Schmitt inverter's or logic gate's output is high
    public func isHigh(_ index: Int) -> Bool {
        if index < kinds.count, kinds[index] == .logicGate { return logicOutputs(index).first ?? false }
        return index < digitalState.count ? digitalState[index] : false
    }

    /// Whether each output of a logic part is high, in the order of its output terminals
    public func logicOutputs(_ index: Int) -> [Bool] {
        guard index < kinds.count, index < logicStates.count else { return [] }
        return Logic.outputs(kinds[index], logicStates[index], function: Int(constants[index].value))
    }

    /// A counter's count, a flip-flop's Q (1 or 0), or the channel a multiplexer has on (-1 while inhibited)
    public func logicCount(_ index: Int) -> Int {
        guard index < kinds.count, index < logicStates.count else { return 0 }
        if kinds[index] == .analogMux || kinds[index] == .analogSelector { return Logic.channel(kinds[index], logicStates[index]) ?? -1 }
        return logicStates[index].count
    }

    /// 0 (open) to 1 (closed) for analog switches
    public func switchConduction(_ index: Int) -> Double {
        guard index < circuit.elements.count, circuit.elements[index].kind == .analogSwitch else { return 0 }
        let v = terminalVoltages(index)
        guard v.count == 3 else { return 0 }
        let g = analogSwitchConductance(index, control: v[2]).conductance
        return min(1, g / constants[index].onConductance)
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
        recordedTraces = circuit.scopes.compactMap { spec in
            guard let trace = next[spec.id], let index = circuit.index(of: spec.elementID) else { return nil }
            return (trace, index)
        }
    }

    public func trace(_ id: UUID) -> ScopeTrace? { traces[id] }

    private func record(_ trace: ScopeTrace, _ index: Int) {
        switch trace.spec.plot {
        case .time:
            switch trace.spec.quantity {
            case .current: trace.add(scopedCurrent(index), at: time)
            case .power: trace.add(voltageAcross(index) * scopedCurrent(index), at: time)
            default: trace.add(value(trace.spec.quantity, of: index), at: time)
            }
        case .currentVersusVoltage:
            trace.addPoint(voltage: voltageAcross(index), current: scopedCurrent(index), at: time)
        }
    }

    /// One element's current for a scope at every step, without working out the whole circuit's: only wires and
    /// other conductors need the walk through the wire network
    private func scopedCurrent(_ index: Int) -> Double {
        let element = circuit.elements[index]
        if element.isConductor { return current(index) }
        return elementCurrents(index, element) { self.voltage($0) }.main
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

    /// Copies another trace's history
    func adopt(_ other: ScopeTrace) {
        minimums = other.minimums
        maximums = other.maximums
        lastValue = other.lastValue
        voltages = other.voltages
        currents = other.currents
        lastVoltage = other.lastVoltage
        bucketStart = other.bucketStart
        bucketMin = other.bucketMin
        bucketMax = other.bucketMax
    }

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
