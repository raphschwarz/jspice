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
    /// Matrix or right-hand-side entries as Newton-Raphson stamps them: written in place, without the checks an array
    /// makes on every write
    typealias Entries = UnsafeMutablePointer<Double>

    /// The circuit as it was loaded
    public private(set) var circuit: Circuit
    /// What is simulated: the circuit with each block's parts in its place (`Circuit.flattened`). Its elements start
    /// with the circuit's own, in the same order, so an index into the circuit is one into this too.
    private(set) var flat: Circuit
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
    /// Newton-Raphson iterations since the start, each one a solve of the stamped equations, and those of them damped
    public private(set) var newtonIterations = 0
    public private(set) var dampedIterations = 0
    /// Newton-Raphson iterations in which a part limited how far its voltages moved (so it could not converge there)
    public private(set) var limitedIterations = 0
    /// Behavioural sources' stamps given again from their last evaluation, their inputs not having moved
    public private(set) var bypassedEvaluations = 0
    /// Those of them whose inputs had moved, but not out of the straight stretch they were on (see `stampBehavior`)
    public private(set) var straightBypasses = 0

    /// The behavioural sources whose expressions were run most to stamp them, rather than bypassed, since the circuit
    /// loaded: each one's expression in outline (see `SpiceExpression.Program.outline`: a maker's expressions are
    /// theirs), how many times, its reach at the last run and whether it decides (for a benchmark to show where
    /// evaluation goes)
    public func mostEvaluatedSources(_ count: Int) -> [(outline: String, evaluations: Int, reach: Double, decides: Bool)] {
        var found: [(outline: String, evaluations: Int, reach: Double, decides: Bool)] = []
        for i in behaviors.indices {
            guard let b = behaviors[i], b.evaluations > 0 else { continue }
            found.append((outline: b.program.outline, evaluations: b.evaluations, reach: b.reach, decides: b.decides))
        }
        return Array(found.sorted { $0.evaluations > $1.evaluations }.prefix(count))
    }
    /// Newton-Raphson iterations that ended without a solve, their block stamped as the iteration before solved it
    public private(set) var confirmedWithoutSolving = 0
    /// First iterations that started from the stamps the last solve confirmed, without evaluating the parts
    public private(set) var reusedStampings = 0
    /// Solves that started again without them, their parts found elsewhere than the stamps had them
    public private(set) var restartedSolves = 0
    /// Whether a behavioural source whose inputs have not moved is stamped from its last evaluation (see `stampBehavior`)
    public static var bypassesDevices = true
    /// How far (relative, above 1 V) an input can move before a source is evaluated again
    static let bypassTolerance = 1e-9
    /// Of those iterations, how many factored the nonlinear block, and how many solved with factors kept from an earlier
    /// one (see `newton`)
    public private(set) var factorings = 0
    public private(set) var reusedFactorings = 0
    /// Nanoseconds spent restamping the nonlinear block and solving it (factoring or not), while `profiling` is on
    public private(set) var stampNanoseconds: UInt64 = 0
    public private(set) var solveNanoseconds: UInt64 = 0
    /// Whether iterations time their stamping and solving
    public static var profiling = false
    /// Whether Newton-Raphson solves with the factors of an earlier iteration while the nonlinear block stays near the
    /// values they were made from (the chord method); read at each iteration. Off, it factors at every iteration: for
    /// comparing the two.
    public static var reusesFactors = true
    /// Solves done again because a behavioural source's decision (a comparator in a maker's model) changed during one,
    /// and solves left as they were after `decisionRounds` of that (a comparator chattering about its threshold)
    public private(set) var decisionSolves = 0
    public private(set) var chatteringSolves = 0
    /// Whether the last solve was left with a comparator chattering: its substep's error estimate means nothing (the
    /// forcing jumps), so it is not refined for it
    private var solveChattered = false
    /// Set (from any thread) to make a step that is taking too long give up: the simulation fails at its next substep
    /// or iteration
    public var stopRequested = false

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

    /// Sound coming in live, for audio input parts set to the live input: samples at a rate, the first at `startTime`
    /// of circuit time. The sound thread hands each chunk over before simulating it; between chunks the last sample holds.
    public struct LiveInput: Sendable {
        public var samples: [Float]
        public var sampleRate: Double
        public var startTime: Double

        public init(samples: [Float], sampleRate: Double, startTime: Double) {
            self.samples = samples
            self.sampleRate = sampleRate
            self.startTime = startTime
        }
    }

    public var liveInput: LiveInput?
    /// The sounds of audio input parts playing a file, by element index (a part without a sound plays a guitar riff)
    private var audioClips: [Int: (sampleRate: Double, samples: [Float])] = [:]
    /// True while a playing sequence sets the keyboard
    private var sequenceOwnsKeyboard = false

    var topology = Topology()
    /// The elements' nodes again, in one block, for the loops that run at every iteration
    private var nodeLists = NodeLists()
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
    /// The charge each part stores, by slot (`chargeSlots` a part: a diode's junction in the first; a transistor's
    /// base-emitter, base-collector and outer base-collector charges; a JFET's gate-source and gate-drain), at the last
    /// solution and the two before (for the local error), and the current it took to charge over the last step
    var junctionCharge: [Double] = []
    var junctionChargePrevious: [Double] = []
    var junctionChargeOlder: [Double] = []
    var junctionCurrent: [Double] = []
    /// The parts with junction capacitance or stored charge
    private var junctionIndices: [Int] = []
    /// The circuit's temperature in kelvin, and the thermal voltage kT/q there
    public private(set) var kelvin = Simulator.nominalKelvin
    private(set) var vt = Simulator.thermalVoltage
    /// Random number generator state of each noise source (xorshift), so a run can be repeated exactly
    var noiseState: [UInt64] = []
    /// What went into each delay line, one value per step, oldest overwritten first
    private var delayHistory: [Int: DelayHistory] = [:]
    /// Spring reverb tanks' springs, by element index
    private var springTanks: [Int: SpringTank] = [:]
    /// Bucket brigades clocked from their clock pin, by element index, and for those an oscillator drives (a clock
    /// driver's), that oscillator
    private var bucketBrigades: [Int: BucketBrigade] = [:]
    private var clockSources: [Int: Int] = [:]
    /// Effects processors' programs and their delay memories, by element index
    private var effectsProcessors: [Int: EffectsProcessor] = [:]

    /// A bucket brigade clocked from its clock pin: a sample of its input taken at each clock cycle and moved one bucket
    /// along at each (two stages: the delay is its stages over twice the clock), the sample reaching the end held until
    /// the next cycle
    struct BucketBrigade {
        var buckets: [Double]
        var position = 0
        /// What the last end of the line gave over the last step (the samples reaching it then, averaged)
        var output = 0.0
        /// The input at the last step, for the samples taken between steps
        var lastInput = 0.0
        /// The cycles its oscillator had run at the last step, or (clocked by a voltage) whether the clock was high
        var cycles = 0.0
        var clockHigh = false
        /// Clock cycles a second, smoothed over a millisecond
        var rate = 0.0

        init(stages: Double) { buckets = Array(repeating: 0, count: Self.count(stages)) }

        static func count(_ stages: Double) -> Int { max(Int(stages / 2), 1) }

        /// `ticks` clock cycles over a step in which the input went from `from` to `to`
        mutating func clock(_ ticks: Int, from: Double, to: Double) {
            guard ticks > 0 else { return }
            let n = buckets.count
            // more cycles than buckets in a step: the earlier samples would be out again within it
            let count = min(ticks, 2 * n)
            var sum = 0.0
            for k in 0..<count {
                sum += buckets[position]
                buckets[position] = from + (to - from) * Double(k + 1) / Double(count)
                position = position + 1 == n ? 0 : position + 1
            }
            output = sum / Double(count)
        }
    }

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
            let back = steps.isFinite ? min(max(steps, 0), Double(values.count - 2)) : 0
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
    /// For each chip, its pins that logic parts' inputs are wired to, and those inputs (the part and the input's bit):
    /// what the chip does on these pins is replayed into the parts as it happened, change by change
    private var chipWatches: [Int: [Int: [(element: Int, bit: Int)]]] = [:]
    /// Likewise for the converters that answer within a transfer (`isBusDevice`): they follow the chip's pins as it
    /// runs. And for each of those, the chips' pins on the line it drives back (an ADC's DOUT, an I²C target's SDA).
    private var busWatches: [Int: [Int: [(element: Int, bit: Int)]]] = [:]
    private var busLines: [Int: [(chip: Int, pin: Int)]] = [:]
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
    /// Each bipolar transistor's Gummel-Poon card at the circuit's temperature (an empty one for other parts)
    private var bipolar: [GummelPoon] = []
    /// Each diode's, Zener diode's and LED's SPICE card at the circuit's temperature
    private var diodes: [SpiceDiode] = []
    /// Each JFET's SPICE card at the circuit's temperature
    private var jfets: [SpiceJFET] = []
    /// Each MOSFET's SPICE card at the circuit's temperature, and its gate voltages and half Meyer capacitances at the
    /// last solution (SPICE integrates Meyer's capacitances over each step from both its ends)
    private var mosfets: [SpiceMOSFET] = []
    struct MeyerHistory: Equatable {
        var vgs = 0.0, vgd = 0.0, vgb = 0.0
        var gs = 0.0, gd = 0.0, gb = 0.0
    }
    private var meyerHistory: [MeyerHistory] = []
    /// Each behavioural source's expression, and where its inputs come from: a voltage between two nodes, or the current
    /// through a source (its row, and the sign that makes it SPICE's: into the source's + terminal)
    struct BehaviorInput {
        var plus = 0, minus = 0, row = -1, sign = -1.0
    }
    final class Behavior {
        let expression: SpiceExpression
        /// The expression and its slopes compiled, to run at every iteration
        let program: SpiceExpression.Program
        let inputs: [BehaviorInput]
        let voltage: Bool
        /// An affine expression (a gain, POLY of the first degree): stamped once in the base matrix with its constant
        /// slopes, its value at zero inputs on the right-hand side, and kept out of Newton-Raphson's nonlinear block
        var linear = false
        var offset = 0.0
        /// Whether its value jumps where a decision in it changes (a comparison, IF, u, sgn…): Newton-Raphson holds its
        /// decisions where the solve started (`decisionX`), and the solve is done again if they have changed by the end
        var decides = false

        /// The inputs again, in memory of their own: read at every iteration without touching reference counts
        let inputList: UnsafeMutablePointer<BehaviorInput>
        let inputCount: Int
        /// Its last evaluation: the inputs, those its decisions were made at, the value and each input's slope, and
        /// how far the inputs can move from those with every decision in it as it was (see `stampBehavior`'s bypass)
        let lastInputs: UnsafeMutablePointer<Double>
        let lastDecisions: UnsafeMutablePointer<Double>
        let lastSlopes: UnsafeMutablePointer<Double>
        var lastValue = 0.0
        var lastCelsius = 0.0
        var reach = 0.0
        var evaluated = false
        /// Times its expression was run to stamp it (rather than bypassed)
        var evaluations = 0
        /// The plan's slots its stamps go to, for the plan numbered `slotsSerial` (see `stampBehavior`): four for each
        /// input, then four for its own row (-1 where an entry is ground's); usable unless some stamp is outside the plan
        let slots: UnsafeMutablePointer<Int32>
        var slotsSerial = -1
        var slotsUsable = false

        init(expression: SpiceExpression, program: SpiceExpression.Program, inputs: [BehaviorInput], voltage: Bool) {
            self.expression = expression
            self.program = program
            self.inputs = inputs
            self.voltage = voltage
            inputCount = inputs.count
            inputList = .allocate(capacity: max(inputs.count, 1))
            inputList.initialize(from: inputs, count: inputs.count)
            lastInputs = .allocate(capacity: max(inputs.count, 1))
            lastInputs.initialize(repeating: 0, count: max(inputs.count, 1))
            lastDecisions = .allocate(capacity: max(inputs.count, 1))
            lastDecisions.initialize(repeating: 0, count: max(inputs.count, 1))
            slots = .allocate(capacity: 4 * inputs.count + 4)
            slots.initialize(repeating: -1, count: 4 * inputs.count + 4)
            lastSlopes = .allocate(capacity: max(inputs.count, 1))
            lastSlopes.initialize(repeating: 0, count: max(inputs.count, 1))
        }

        deinit {
            inputList.deallocate()
            lastInputs.deallocate()
            lastDecisions.deallocate()
            slots.deallocate()
            lastSlopes.deallocate()
        }
    }
    private var behaviors: [Behavior?] = []
    /// Expressions read and compiled, by their text: a knob turned takes on new values without reading them again
    private var compiledExpressions: [String: (expression: SpiceExpression, program: SpiceExpression.Program)] = [:]
    /// Where a behavioural source's program writes its steps' values (room for `behaviorRegisterRoom`)
    private var behaviorRegisters = UnsafeMutablePointer<Double>.allocate(capacity: 1)
    /// And where it works out each step's rate (see `SpiceExpression.Program.straightReach`), with the same room
    private var behaviorRates = UnsafeMutablePointer<Double>.allocate(capacity: 1)
    private var behaviorRegisterRoom = 1
    /// What reading the behavioural sources' expressions found wrong
    private var behaviorProblems: [String] = []
    /// A behavioural source's inputs at the present solution (room for `behaviorInputRoom`)
    private var behaviorValues = UnsafeMutablePointer<Double>.allocate(capacity: 1)
    private var behaviorInputRoom = 1
    /// The inputs a behavioural source's decisions are made at, and the solution they are read from: held through a
    /// solve, from where it started (see `solve`)
    private var behaviorDecisions = UnsafeMutablePointer<Double>.allocate(capacity: 1)
    private var decisionX: [Double] = []
    /// The behavioural sources whose decisions are held
    private var decidingIndices: [Int] = []
    /// Whether Newton-Raphson is damped when its steps stop shrinking: with nonlinear behavioural sources only (their
    /// TABLE, IF, LIMIT and clamps have sharp corners); other parts converge as they always have
    private var dampsNewton = false
    /// The time the present solve is for (a behavioural source's `time`)
    private var solveTime = 0.0
    /// The charges each part stores and integrates, by slot: a diode's junction; a transistor's base-emitter,
    /// base-collector at the internal base, and base-collector at the external base
    static let chargeSlots = 5
    /// The conductance SPICE puts across every junction of a transistor (its gmin)
    static let junctionGmin = 1e-12
    /// The elements each part of a step needs, so wires and resistors cost nothing once the base matrix is built
    private var nonlinearIndices: [Int] = []
    /// The nonlinear parts other than behavioural sources: those whose voltages Newton-Raphson limits
    private var limitingIndices: [Int] = []
    private var drivenIndices: [Int] = []
    private var statefulIndices: [Int] = []
    private var digitalIndices: [Int] = []
    private var memristorIndices: [Int] = []
    /// Elements whose state moves with each substep, those whose error is estimated, and those that move once a step
    private var dynamicIndices: [Int] = []
    /// The capacitors among them, and the rest
    private var dynamicCapacitors: [Int] = []
    private var dynamicOthers: [Int] = []
    private var reactiveIndices: [Int] = []
    private var stepIndices: [Int] = []
    /// Scopes with the index of the element each one shows
    private var recordedTraces: [(trace: ScopeTrace, index: Int)] = []

    /// How the equations are factored (see `SparsePlan`): made at the first solve after the circuit changes shape, and
    /// again whenever it no longer fits
    private var plan: SparsePlan? { didSet { planSerial &+= 1 } }
    /// Counts the plans set, so what is worked out for one (a source's slots) is known to be for the present one
    private var planSerial = 0
    /// Plans made since the start, and the seconds spent making them
    public private(set) var plans = 0
    public private(set) var planningSeconds = 0.0
    /// Whether affine behavioural sources (gains, POLY of the first degree) are stamped as linear parts, out of the
    /// nonlinear block; read when a circuit is loaded. Off, they are linearised at every iteration as any other: for
    /// comparing the two.
    public static var linearAffineSources = true
    /// The equations' shape, for profiling: unknowns, those in the nonlinear block (factored at every iteration), and
    /// the pivot orders kept for it
    public var planShape: (unknowns: Int, nonlinear: Int, orders: Int) {
        (topology.matrixSize, plan?.block.count ?? 0, plan?.orderCount ?? 0)
    }
    /// Set when the plan no longer fits (a stamp fell outside it, or a pivot became too small): planned again next
    private var needsPlan = false
    /// Matrix positions (row × size + column) stamped outside the plan, and unknowns Newton-Raphson stamped outside its
    /// nonlinear block, for the next plan to include
    private var missedPositions: [Int] = []
    private var extraNonlinear: Set<Int> = []
    /// Newton-Raphson's values (the base's, with the nonlinear block restamped and refactored) and right-hand side
    private var values: [Double] = []
    private var workVector: [Double] = []
    /// The base matrix in the plan's slots, its linear block factored (and, without nonlinear parts, its nonlinear block
    /// too, by `baseOrder`); its version, and the version `values` holds
    private var baseValues: [Double] = []
    private var baseOrder: EliminationProgram?
    /// The nonlinear block's values, kept while pivot orders are tried
    private var blockScratch: [Double] = []
    private var baseVersion = 0
    private var valuesVersion = -1
    /// The right-hand side after the linear block's forward substitution
    private var rhsForwarded: [Double] = []
    /// Whether building the right-hand side reads the present solution (a DAC's reference, a delay line's clock): it is
    /// then kept as built through a solve, to forward again for a new plan, rather than built again
    private var rightHandSideReadsSolution = false
    /// While stamping into the plan's slots: the slot map, the first slot a stamp may write (the base writes any, Newton-
    /// Raphson only the nonlinear block's), and whether one fell outside
    private var sparseStamping = false
    private var slotMap = Simulator.noSlots
    private var stampFloor = 0
    private var stampSize = 0
    private var stampMissed = false
    private static let noSlots = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    /// The predictor: the solution at the start of the substep being solved, the one before it (the start of the last
    /// substep kept), whether that one is from an ordinary substep (not across a reset, a load or a part switching
    /// over), and whether the next solve starts from the prediction
    private var substepStartX: [Double] = []
    private var olderX: [Double] = []
    private var predictorReady = false
    private var predictNext = false
    private var predictionRatio = 1.0
    /// The solution and junction voltages at the start of a step, to go back to for gmin stepping
    private var savedX: [Double] = []
    /// Whether the solve under way started from `substepStartX` (then `savedX` is not kept)
    private var solveStartsSubstep = false
    /// The iterate a damped Newton-Raphson iteration moves from
    private var dampFrom: [Double] = []
    /// The nonlinear block's last factoring, kept for the iterations after it (see `newton`): the plan and pivot order it
    /// was made with, the factors (in the plan's slots), the base matrix it was made on, the values the slots
    /// Newton-Raphson's stamps reach had then, and the largest entry of each row of the block
    private var keptPlan: SparsePlan?
    private var keptOrder: EliminationProgram?
    /// The factors, packed in the order substitution reads them (see `EliminationProgram.pack`)
    private var keptFactors: [Double] = []
    private var keptValues: [Double] = []
    private var keptBaseVersion = -1
    /// The block's structure: its slots, and the row of the block each is in (for the rows' largest entries)
    private var keptSlots: [Int32] = []
    private var keptLocalRows: [Int32] = []
    private var keptRowScale: [Double] = []
    /// How many of the stamped slots there were when the present factoring's values were kept
    private var keptStampedCount = 0
    /// The block's factorings before the present one, most recent first (see `formerFactorsSuit`), on the same plan and
    /// base matrix: their values at the stamped slots (in `stampedSlots`' order), their rows' scale, factors and order
    private struct FormerFactoring {
        var values: [Double]
        var rowScale: [Double]
        var factors: [Double]
        var order: EliminationProgram
    }
    private var formerFactorings: [FormerFactoring] = []
    static let formerFactoringsKept = 3
    /// Tries of the former factorings that missed, one after another, and the factorings for which none is kept after
    /// too many (see `rememberPresentFactoring`)
    private var formerMisses = 0
    private var formerRest = 0
    static let formerMissesTolerated = 16
    static let formerRestFactorings = 256
    /// Factorings taken up again from the former ones rather than made afresh
    public private(set) var restoredFactorings = 0
    /// The linear block's factors packed (see `EliminationProgram.pack`) from the base matrix of version
    /// `linearPackedVersion`, for a circuit with nonlinear parts
    private var linearPacked: [Double] = []
    private var linearPackedVersion = -1
    private var linearPackedSerial = -1
    /// The largest entry of each row of the block in the base matrix of version `baseRowScaleVersion`
    private var baseRowScale: [Double] = []
    private var baseRowScaleVersion = -1
    private var residual: [Double] = []
    /// The slots of the nonlinear block that Newton-Raphson's stamps have reached since the plan was made, each with its
    /// row and column and its row of the block (`stampedFlags` marks them): on the same base matrix, the only slots in
    /// which an iteration's block can differ from the one the kept factors were made from
    private var stampedSlots: [Int32] = []
    private var stampedRows: [Int32] = []
    private var stampedColumns: [Int32] = []
    private var stampedLocalRows: [Int32] = []
    private var stampedFlags: UnsafeMutablePointer<Bool>?
    private var stampedPlan: SparsePlan?
    /// Whether a slot has been reached for the first time since the factors were kept (they were not made with it in view)
    private var stampedSlotsGrew = false
    /// Whether the stamps going in are Newton-Raphson's, to be recorded
    private var recordingStamps = false
    /// Whether the values hold a factoring of the block (written over more than the stamps reach)
    private var valuesFactored = true
    /// The block as the last iteration stamped it: the values of the stamped slots, and what the stamps added to the
    /// block's rows of the right-hand side (beyond the forwarded sources)
    private var stampSnapshot: [Double] = []
    private var rightSnapshot: [Double] = []
    /// Whether the last solve ended confirmed (see `newton`): its snapshot is then the stamps its solution solved, which
    /// the parts gave again there, kept with the plan and base matrix they are for
    private var confirmedStamps = false
    private var reuseAllowed = false
    private var confirmedPlanSerial = -1
    private var confirmedBaseVersion = -1
    /// Whether `newton` starts from where `solve` started it (where `restoreSolveStart` puts `x`, moved on by the
    /// predictor), so that it can start again from there
    private var newtonFromSolveStart = false
    private var savedLimited: [Double] = []
    private var savedLimited2: [Double] = []
    private var savedLimited3: [Double] = []

    private var matrixIsCurrent = false
    private var hasNonlinear = false
    /// When the only nonlinear parts are VCAs: nearly linear (a soft limit on a gain), solved in one iteration from the
    /// predicted solution, their linearisation there exact to second order
    private var onlyQuasiLinear = false
    /// This solve started from a prediction
    private var predictedSolve = false
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
    private var baseCache: [Int: (values: [Double], version: Int, order: EliminationProgram?)] = [:]
    private var baseKey = -1
    private var baseVersionCount = 0
    /// What a substep changes, kept to go back to if it is thrown away
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

    /// The thermal voltage kT/q at the nominal temperature, 27 °C (300.15 K), which the parts' parameters are given at, with
    /// ngspice's constants (const.h): what a manufacturer's card was fitted with
    static let thermalVoltage = 1.38064852e-23 * 300.15 / 1.6021766208e-19
    static let nominalKelvin = 300.15
    static let gmin = 1e-12
    static let maxNewtonIterations = 80
    /// Iterations a substep that can still be halved gets before it is (SPICE's ITL4 is 10): Newton-Raphson that has not
    /// converged by then is crawling round a sharp corner (a maker's model's output stage handing over at a zero
    /// crossing), which a substep half as long, starting nearer its answer, gets round in a few
    static let halvingIterations = 12
    /// Junction shunts for gmin stepping, strongest first, ending without any
    static let steppedConductances: [Double] = [1e-2, 1e-4, 1e-6, 1e-8, 1e-10, 0]
    static let steppedIterations = 40
    /// How long a noise source holds each sample, at least
    static let noiseSampleTime = 1 / 48_000.0

    deinit {
        stampedFlags?.deallocate()
        behaviorRegisters.deallocate()
        behaviorRates.deallocate()
        behaviorValues.deallocate()
        behaviorDecisions.deallocate()
    }

    public init(circuit: Circuit = Circuit(), timeStep: Double = 1e-5) {
        self.circuit = Circuit()
        self.flat = Circuit()
        self.timeStep = timeStep
        h = timeStep
        load(circuit)
    }

    // MARK: - Loading and settings

    private struct SavedState {
        var cv, cvp, cvo, ci, lv, li, lip, lio, m, l1, l2, l3: Double
        var q: [Double]
        var meyer: MeyerHistory
        var digital: Bool
        var logic: LogicState
        var module: ModuleState
        var noise: UInt64
        var delay: DelayHistory?
        var brigade: BucketBrigade?
    }

    /// Switches to a changed circuit, keeping the state (charge, current, memristor state) of elements that remain
    public func load(_ newCircuit: Circuit) {
        var previous: [UUID: SavedState] = [:]
        for (i, element) in flat.elements.enumerated() where i < capacitorVoltage.count {
            previous[element.id] = SavedState(
                cv: capacitorVoltage[i], cvp: capacitorVoltagePrevious[i], cvo: capacitorVoltageOlder[i],
                ci: capacitorCurrent[i], lv: inductorVoltage[i], li: inductorCurrent[i], lip: inductorCurrentPrevious[i],
                lio: inductorCurrentOlder[i], m: memristorStates[i], l1: limitedVoltage[i],
                l2: limitedVoltage2[i], l3: limitedVoltage3[i],
                q: Self.chargeSlots * (i + 1) <= junctionCharge.count
                    ? Array(junctionCharge[Self.chargeSlots * i ..< Self.chargeSlots * (i + 1)])
                        + Array(junctionChargePrevious[Self.chargeSlots * i ..< Self.chargeSlots * (i + 1)])
                        + Array(junctionChargeOlder[Self.chargeSlots * i ..< Self.chargeSlots * (i + 1)])
                    : [Double](repeating: 0, count: 3 * Self.chargeSlots),
                meyer: i < meyerHistory.count ? meyerHistory[i] : MeyerHistory(),
                digital: digitalState[i], logic: logicStates[i], module: moduleStates[i],
                noise: noiseState[i], delay: delayHistory[i], brigade: bucketBrigades[i])
        }
        // chips keep running through edits that leave their firmware alone
        var previousChips: [UUID: (firmware: Data?, chip: Microcontroller, carry: Double)] = [:]
        for (i, chip) in chips where i < flat.elements.count {
            previousChips[flat.elements[i].id] = (flat.elements[i].firmware, chip, chipCycleCarry[i] ?? 0)
        }
        // node voltages by place, so an edit does not throw away the solution (a latch keeps its state, and a paused
        // circuit still shows its voltages)
        var previousVoltages: [GridPoint: Double] = [:]
        if x.count == topology.matrixSize {
            for (p, point) in topology.points.enumerated() { previousVoltages[point] = voltage(topology.nodeOfPoint[p]) }
        }
        circuit = newCircuit
        flat = newCircuit.flattened()
        setTemperature(newCircuit.settings.temperature)
        topology = Topology(circuit: flat)
        nodeLists = NodeLists(topology.elementNodes)
        let count = flat.elements.count
        junctionCharge = Array(repeating: 0, count: Self.chargeSlots * count)
        junctionChargePrevious = Array(repeating: 0, count: Self.chargeSlots * count)
        junctionChargeOlder = Array(repeating: 0, count: Self.chargeSlots * count)
        junctionCurrent = Array(repeating: 0, count: Self.chargeSlots * count)
        meyerHistory = Array(repeating: MeyerHistory(), count: count)
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
        // an op-amp running its maker's model is that model's parts (see `Circuit.flattened`): its own equations are
        // left out, as a block's are
        kinds = flat.elements.map { $0.runsMakerModel ? .block : $0.kind }
        constants = flat.elements.map { makeConstants($0) }
        bipolar = flat.elements.map { $0.kind.isBipolar ? GummelPoon($0, kelvin: kelvin, vt: vt) : GummelPoon() }
        diodes = flat.elements.map { $0.kind.isDiode ? SpiceDiode($0, kelvin: kelvin, vt: vt) : SpiceDiode() }
        jfets = flat.elements.map { $0.kind.isJFET ? SpiceJFET($0, kelvin: kelvin, vt: vt) : SpiceJFET() }
        mosfets = flat.elements.map { $0.kind.isMOSFET ? SpiceMOSFET($0, kelvin: kelvin, vt: vt) : SpiceMOSFET() }
        func indices(_ include: (ElementKind) -> Bool) -> [Int] { kinds.indices.filter { include(kinds[$0]) } }
        nonlinearIndices = indices {
            switch $0 {
            case .diode, .zener, .led, .npn, .pnp, .nmos, .pmos, .njfet, .pjfet, .opAmp, .ota, .analogSwitch, .multiplier, .vactrol,
                 .unbufferedInverter, .pll, .triode, .pentode, .vca, .behavioralSource: return true
            default: return false
            }
        }
        // inductors whose cores saturate are nonlinear too
        nonlinearIndices += flat.elements.indices.filter { flat.elements[$0].saturates }
        drivenIndices = indices {
            switch $0 {
            case .dcVoltage, .acVoltage, .squareVoltage, .noiseVoltage, .audioInput, .currentSource, .capacitor, .inductor, .timer555,
                 .schmittInverter, .keyboardPitch, .keyboardGate, .delayLine, .digitalDelay, .comparator, .vco, .vcf, .envelope, .vca,
                 .sampleHold, .divider, .levelDetector, .springReverb, .agcPreamp, .atmega328p, .atmega2560, .attiny85, .rp2040, .logicGate, .flipFlop, .decadeCounter,
                 .binaryCounter, .shiftRegister, .pll, .dac, .dualDac, .spiAdc, .i2cDac, .i2sDac, .effectsProcessor: return true
            default: return false
            }
        }
        statefulIndices = indices {
            [.capacitor, .inductor, .opAmp, .memristor, .keyboardPitch, .noiseVoltage, .vactrol, .vuMeter, .effectsProcessor].contains($0)
                || $0.isModule || $0 == .comparator
        }
        dynamicIndices = statefulIndices.filter { [.capacitor, .inductor, .opAmp, .memristor, .vactrol].contains(kinds[$0]) }
            + indices { $0 == .pll }
        dynamicCapacitors = dynamicIndices.filter { kinds[$0] == .capacitor }
        dynamicOthers = dynamicIndices.filter { kinds[$0] != .capacitor }
        reactiveIndices = indices { $0 == .capacitor || $0 == .inductor }
        stepIndices = statefulIndices.filter { !dynamicIndices.contains($0) }
        delayHistory = [:]
        springTanks = [:]
        bucketBrigades = [:]
        effectsProcessors = [:]
        digitalIndices = indices { $0.isDigital }
        chipIndices = indices { $0.isMicrocontroller }
        chips = [:]
        chipPinStates = [:]
        chipCycleCarry = [:]
        for i in chipIndices {
            let element = flat.elements[i]
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
        compileBehaviors()
        // affine behavioural sources (a maker's model has dozens of gains) are linear: in the base matrix, their offsets
        // on the right-hand side, out of the nonlinear block
        let linearBehaviors = Set(kinds.indices.filter { kinds[$0] == .behavioralSource && behaviors[$0]?.linear == true })
        nonlinearIndices.removeAll { linearBehaviors.contains($0) }
        limitingIndices = nonlinearIndices.filter { kinds[$0] != .behavioralSource }
        rightHandSideReadsSolution = kinds.contains { $0 == .dac || $0 == .delayLine }
        drivenIndices += linearBehaviors.sorted()
        decidingIndices = nonlinearIndices.filter { kinds[$0] == .behavioralSource && behaviors[$0]?.decides == true }
        dampsNewton = nonlinearIndices.contains { kinds[$0] == .behavioralSource }
        junctionIndices = kinds.indices.filter { storesCharge($0) }
        audioClips = [:]
        for i in indices({ $0 == .audioInput }) {
            let clip = flat.elements[i].audio ?? AudioClip.guitarRiff
            audioClips[i] = (clip.sampleRate, clip.samples)
        }
        watchChipPins()
        for (i, element) in flat.elements.enumerated() {
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
                for slot in 0..<Self.chargeSlots {
                    junctionCharge[Self.chargeSlots * i + slot] = state.q[slot]
                    junctionChargePrevious[Self.chargeSlots * i + slot] = state.q[Self.chargeSlots + slot]
                    junctionChargeOlder[Self.chargeSlots * i + slot] = state.q[2 * Self.chargeSlots + slot]
                }
                meyerHistory[i] = state.meyer
                digitalState[i] = state.digital
                logicStates[i] = state.logic
                moduleStates[i] = state.module
                noiseState[i] = state.noise
                if let delay = state.delay, element.kind == .delayLine || element.kind == .digitalDelay {
                    // a delay line keeps what it holds, in a history long enough for its new settings
                    let capacity = delayCapacity(i, timeStep: timeStep)
                    delayHistory[i] = delay.values.count == capacity ? delay : delay.resampled(stepRatio: 1, capacity: capacity)
                }
                if let brigade = state.brigade, element.kind == .delayLine,
                   brigade.buckets.count == BucketBrigade.count(constants[i].value) {
                    bucketBrigades[i] = brigade
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
        // a transistor's or diode's internal nodes start where its terminals are
        for i in kinds.indices where kinds[i].isDiode && diodes[i].hasSeriesNode {
            let nodes = topology.elementNodes[i]
            if nodes[2] > 0 { x[nodes[2] - 1] = nodes[0] > 0 ? x[nodes[0] - 1] : 0 }
        }
        for i in kinds.indices where kinds[i].isBipolar {
            let nodes = topology.elementNodes[i]
            let n = Self.bipolarNodes({ nodes[$0] }, bipolar[i])
            for (inner, outer) in [(n.bp, n.b), (n.cp, n.c), (n.ep, n.e)] where inner != outer && inner > 0 {
                x[inner - 1] = outer > 0 ? x[outer - 1] : 0
            }
        }
        for i in kinds.indices where kinds[i].isJFET || kinds[i].isMOSFET {
            let nodes = topology.elementNodes[i]
            let n = kinds[i].isJFET ? Self.jfetNodes({ nodes[$0] }, jfets[i])
                : Self.fetNodes({ nodes[$0] }, drain: mosfets[i].hasDrainNode, source: mosfets[i].hasSourceNode)
            for (inner, outer) in [(n.dp, n.d), (n.sp, n.s)] where inner != outer && inner > 0 {
                x[inner - 1] = outer > 0 ? x[outer - 1] : 0
            }
        }
        decisionX = x
        hasNonlinear = !nonlinearIndices.isEmpty
        onlyQuasiLinear = hasNonlinear && nonlinearIndices.allSatisfy { kinds[$0] == .vca }
        hasDigital = !digitalIndices.isEmpty
        hasMemristor = !memristorIndices.isEmpty
        linkClocks()
        // the equations' shape may have changed: plan afresh
        predictorReady = false
        plan = nil
        needsPlan = false
        missedPositions = []
        extraNonlinear = []
        values = []
        baseValues = []
        baseOrder = nil
        blockScratch = []
        valuesVersion = -1
        matrixIsCurrent = false
        isFailed = false
        problems = topology.problems + behaviorProblems
        configureScopes(window: traces.values.first?.window ?? 1)
        currentsAreStale = true
    }

    private func initialiseState(_ i: Int) {
        let element = flat.elements[i]
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
        for k in Self.chargeSlots * i ..< Self.chargeSlots * (i + 1) where k < junctionCharge.count {
            junctionCharge[k] = 0
            junctionChargePrevious[k] = 0
            junctionChargeOlder[k] = 0
            junctionCurrent[k] = 0
        }
        if i < meyerHistory.count { meyerHistory[i] = MeyerHistory() }
        // a Schmitt inverter's input starts low, so its output starts high; a 555 decides from its trigger
        digitalState[i] = element.kind == .schmittInverter
        logicStates[i] = LogicState()
        // a keyboard's pitch starts at the present note rather than gliding up from 0 V
        if element.kind == .keyboardPitch { capacitorVoltage[i] = keyboard.pitchVoltage }
        // each noise source has its own sequence, the same every run
        noiseState[i] = 0x9E37_79B9_7F4A_7C15 &* UInt64(i + 1) | 1
        delayHistory[i] = nil
        bucketBrigades[i] = nil
        effectsProcessors[i] = nil
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
        predictorReady = false
        // a delay line's history is kept one value per step: resample it to the new step
        for (i, history) in delayHistory {
            delayHistory[i] = history.resampled(stepRatio: dt / previous, capacity: delayCapacity(i, timeStep: dt))
        }
        // rebuild the history at the new step from the present slope (the junctions' charges as if still)
        junctionChargePrevious = junctionCharge
        junctionChargeOlder = junctionCharge
        substepLevel = 0
        lastLevel = 0
        olderLevel = 0
        for (i, element) in flat.elements.enumerated() {
            if element.kind == .capacitor {
                let c = max(element[param: "capacitance"], 1e-30)
                capacitorVoltagePrevious[i] = capacitorVoltage[i] - capacitorCurrent[i] * dt / c
                capacitorVoltageOlder[i] = 2 * capacitorVoltagePrevious[i] - capacitorVoltage[i]
            } else if element.kind == .inductor {
                let l = i < constants.count ? constants[i].value : max(element[param: "inductance"], 1e-15)
                inductorCurrentPrevious[i] = inductorCurrent[i] - inductorVoltage[i] * dt / l
                inductorCurrentOlder[i] = 2 * inductorCurrentPrevious[i] - inductorCurrent[i]
            } else if element.kind == .opAmp {
                capacitorVoltagePrevious[i] = capacitorVoltage[i]
            }
        }
    }

    /// Copies into an array of the same size in place. Simply assigning would share the other simulator's storage, and
    /// that one (the sound's, on its own thread) would then have to copy it at its next step.
    @inline(__always) static func adopt<T>(_ target: inout [T], _ source: [T]) {
        guard target.count == source.count else {
            target = source
            return
        }
        target.withUnsafeMutableBufferPointer { target in
            source.withUnsafeBufferPointer { source in
                guard let to = target.baseAddress, let from = source.baseAddress else { return }
                to.update(from: from, count: source.count)
            }
        }
    }

    /// Takes on the state of another simulator running the same circuit: its time and time step, solution, every
    /// element's state and its scope traces. The app's sound runs a second simulator on its own thread, and the window's
    /// simulator follows it this way to show what it is doing.
    ///
    /// The delay lines' histories (up to seconds of samples) are taken only with `delays`, or when the time step changes
    /// (they are recorded at it): taking them at every frame would make the other simulator copy them at its next step.
    public func adoptState(of other: Simulator, delays: Bool = false) {
        guard other.flat.elements.count == flat.elements.count, other.x.count == x.count else { return }
        time = other.time
        predictorReady = false
        if timeStep != other.timeStep {
            timeStep = other.timeStep
            matrixIsCurrent = false
            delayHistory = other.delayHistory
            springTanks = other.springTanks
            bucketBrigades = other.bucketBrigades
            effectsProcessors = other.effectsProcessors
        } else if delays {
            delayHistory = other.delayHistory
            springTanks = other.springTanks
            bucketBrigades = other.bucketBrigades
            effectsProcessors = other.effectsProcessors
        }
        if digitalState != other.digitalState { matrixIsCurrent = false }
        Self.adopt(&x, other.x)
        Self.adopt(&capacitorVoltage, other.capacitorVoltage)
        Self.adopt(&capacitorVoltagePrevious, other.capacitorVoltagePrevious)
        Self.adopt(&capacitorVoltageOlder, other.capacitorVoltageOlder)
        Self.adopt(&capacitorCurrent, other.capacitorCurrent)
        Self.adopt(&inductorVoltage, other.inductorVoltage)
        Self.adopt(&inductorCurrent, other.inductorCurrent)
        Self.adopt(&inductorCurrentPrevious, other.inductorCurrentPrevious)
        Self.adopt(&inductorCurrentOlder, other.inductorCurrentOlder)
        (substepLevel, lastLevel, olderLevel) = (other.substepLevel, other.lastLevel, other.olderLevel)
        Self.adopt(&memristorStates, other.memristorStates)
        Self.adopt(&limitedVoltage, other.limitedVoltage)
        Self.adopt(&limitedVoltage2, other.limitedVoltage2)
        Self.adopt(&limitedVoltage3, other.limitedVoltage3)
        Self.adopt(&junctionCharge, other.junctionCharge)
        Self.adopt(&junctionChargePrevious, other.junctionChargePrevious)
        Self.adopt(&junctionChargeOlder, other.junctionChargeOlder)
        Self.adopt(&meyerHistory, other.meyerHistory)
        Self.adopt(&junctionCurrent, other.junctionCurrent)
        Self.adopt(&digitalState, other.digitalState)
        if logicStates != other.logicStates { matrixIsCurrent = false }
        Self.adopt(&logicStates, other.logicStates)
        Self.adopt(&moduleStates, other.moduleStates)
        for (i, chip) in chips {
            guard let source = other.chips[i] else { continue }
            chip.adopt(source)
            if let states = other.chipPinStates[i] {
                if !Self.samePinSetup(states, chipPinStates[i]) { matrixIsCurrent = false }
                chipPinStates[i] = states
            }
            chipCycleCarry[i] = other.chipCycleCarry[i]
        }
        Self.adopt(&noiseState, other.noiseState)
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
        for i in flat.elements.indices { initialiseState(i) }
        x = Array(repeating: 0, count: topology.matrixSize)
        isFailed = false
        problems = topology.problems + behaviorProblems
        for trace in traces.values { trace.clear() }
        delayHistory = [:]
        springTanks = [:]
        bucketBrigades = [:]
        effectsProcessors = [:]
        // 555s start low again, and their state is part of the base matrix; so do the chips' pins
        for (i, chip) in chips {
            chip.reset()
            chipPinStates[i] = chip.pinStates
            chipCycleCarry[i] = 0
        }
        watchChipPins()
        matrixIsCurrent = false
        predictorReady = false
        sequenceOwnsKeyboard = false
        currentsAreStale = true
    }

    /// Takes on new parameter values when nothing else about the circuit has changed (a knob turned, a value typed):
    /// the topology, every element's state and the solution all stay. False when the circuit changed in another way,
    /// which needs `load`.
    public func updateParameters(_ newCircuit: Circuit) -> Bool {
        guard newCircuit.elements.count == circuit.elements.count, newCircuit.scopes == circuit.scopes else { return false }
        // a knob inside a block is a parameter of a part of the flattened circuit
        let newFlat = newCircuit.flattened()
        guard newFlat.elements.count == flat.elements.count else { return false }
        for (old, new) in zip(flat.elements, newFlat.elements) {
            var same = new
            same.params = old.params
            same.block = old.block
            if same != old { return false }
            // (a transistor given a resistance, or losing one, gains or loses a node)
            if new.internalNodeCount != old.internalNodeCount { return false }
            // (an inductor's core starting or ceasing to saturate makes it nonlinear, or linear)
            if new.saturates != old.saturates { return false }
        }
        circuit = newCircuit
        flat = newFlat
        setTemperature(newCircuit.settings.temperature)
        constants = newFlat.elements.map { makeConstants($0) }
        bipolar = newFlat.elements.map { $0.kind.isBipolar ? GummelPoon($0, kelvin: kelvin, vt: vt) : GummelPoon() }
        diodes = newFlat.elements.map { $0.kind.isDiode ? SpiceDiode($0, kelvin: kelvin, vt: vt) : SpiceDiode() }
        jfets = newFlat.elements.map { $0.kind.isJFET ? SpiceJFET($0, kelvin: kelvin, vt: vt) : SpiceJFET() }
        mosfets = newFlat.elements.map { $0.kind.isMOSFET ? SpiceMOSFET($0, kelvin: kelvin, vt: vt) : SpiceMOSFET() }
        compileBehaviors()
        junctionIndices = kinds.indices.filter { storesCharge($0) }
        for (i, chip) in chips { chip.supply = constants[i].supply }
        linkClocks()
        for (i, history) in delayHistory {
            let capacity = delayCapacity(i, timeStep: timeStep)
            if history.values.count != capacity { delayHistory[i] = history.resampled(stepRatio: 1, capacity: capacity) }
        }
        matrixIsCurrent = false
        currentsAreStale = true
        // a simulation that failed tries again with the new values (from where it was, unless that was not finite)
        if isFailed {
            isFailed = false
            problems = topology.problems + behaviorProblems
            if x.contains(where: { !$0.isFinite }) { x = [Double](repeating: 0, count: topology.matrixSize) }
        }
        return true
    }

    /// Finds the oscillator clocking each bucket brigade clocked from its clock pin: one whose output is the clock pin,
    /// or a voltage source's other end from it (a clock driver's square wave lifted to swing from 0 V). Such a bucket
    /// brigade counts the oscillator's cycles however long the steps are; any other clock it sees by its edges.
    private func linkClocks() {
        clockSources = [:]
        var oscillators: [Int: Int] = [:]
        for i in kinds.indices where kinds[i] == .vco {
            let nodes = topology.elementNodes[i]
            if nodes.count == 3, nodes[2] > 0 { oscillators[nodes[2]] = i }
        }
        for i in kinds.indices where kinds[i] == .delayLine && constants[i].duty >= 0.5 {
            let nodes = topology.elementNodes[i]
            guard nodes.count == 3, nodes[1] > 0 else { continue }
            let clock = nodes[1]
            if let source = oscillators[clock] {
                clockSources[i] = source
                continue
            }
            for k in kinds.indices where kinds[k] == .dcVoltage {
                let ends = topology.elementNodes[k]
                guard ends.count == 2 else { continue }
                if ends[0] == clock, let source = oscillators[ends[1]] { clockSources[i] = source; break }
                if ends[1] == clock, let source = oscillators[ends[0]] { clockSources[i] = source; break }
            }
        }
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
        if let sequence = flat.sequence, sequence.playing, let state = sequence.state(at: end) {
            keyboard = KeyboardState(note: state.note, gate: state.gate)
            sequenceOwnsKeyboard = true
        } else if sequenceOwnsKeyboard {
            keyboard.gate = false
            sequenceOwnsKeyboard = false
        }
        if !chips.isEmpty { runChips() }
        // without capacitors, inductors, stored charge or op-amp dynamics, smaller steps would only give the same answer again
        let canSubdivide = !dynamicIndices.isEmpty || !junctionIndices.isEmpty
        if !canSubdivide { substepLevel = 0 }
        let whole = 1 << Self.finestLevel
        var position = 0
        while position < whole {
            if stopRequested {
                fail()
                return
            }
            let level = substepLevel
            let units = whole >> level
            h = timeStep / Double(1 << level)
            let ratio = Double(1 << lastLevel) / Double(1 << level)
            a0 = (1 + 2 * ratio) / (1 + ratio)
            a1 = -(1 + ratio)
            a2 = ratio * ratio / (1 + ratio)
            let t = position + units == whole ? end : time + timeStep * Double(position + units) / Double(whole)
            let mayReject = canSubdivide && level < Self.finestLevel
            // (a rejected substep goes back to `substepStartX`, the solution it started from)
            if mayReject {
                saveLimited(&rejectLimited, &rejectLimited2, &rejectLimited3)
                rejectDigital = digitalState
                rejectLogic = logicStates
            }
            Self.copy(x, into: &substepStartX)
            predictNext = predictorReady && hasNonlinear
            predictionRatio = ratio
            var converged = solve(at: t, canHalve: mayReject, fromSubstepStart: true)
            if isFailed { return }
            // a 555 or Schmitt trigger that switches during the substep changes the circuit: solve it again
            var switched = false
            if hasDigital {
                for _ in 0..<4 {
                    guard updateDigitalStates() else { break }
                    switched = true
                    converged = solve(at: t, canHalve: mayReject)
                    if isFailed { return }
                }
            }
            let error = canSubdivide && errorControl && converged && !solveChattered ? errorRatio() : 0
            if mayReject && (!converged || error > 1) {
                Self.copy(substepStartX, into: &x)
                restoreLimited(rejectLimited, rejectLimited2, rejectLimited3)
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
            // the next substep predicts from this one's start and end, unless the circuit jumped (a part switched over)
            swap(&olderX, &substepStartX)
            predictorReady = !switched
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
        let lists = nodeLists
        for i in reactiveIndices {
            let nodes = lists[i]
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
        // and each junction's stored charge, as SPICE checks every charge: a charge in error by the current tolerance
        // over the substep is as much as a capacitor's voltage is allowed
        for i in junctionIndices {
            forEachStoredCharge(i, lists[i]) { slot, x0 in
                let k = Self.chargeSlots * i + slot
                let x1 = junctionCharge[k], x2 = junctionChargePrevious[k], x3 = junctionChargeOlder[k]
                if x0 == 0 && x1 == 0 { return }
                let d01 = (x0 - x1) / h, d12 = (x1 - x2) / h1, d23 = (x2 - x3) / h2
                let d3 = ((d01 - d12) / (h + h1) - (d12 - d23) / (h1 + h2)) / (h + h1 + h2)
                let tolerance = Self.relativeTolerance * max(abs(x0), abs(x1)) + Self.currentTolerance * h
                worst = max(worst, scale * abs(d3) / tolerance)
            }
        }
        return worst
    }

    /// Solves the circuit equations for time `t` into `x`; false if Newton-Raphson did not converge.
    ///
    /// When it does not converge, the circuit has usually snapped from one state to another, like the two transistors of
    /// a flip-flop changing over: the solution has jumped far from the last one, out of Newton's reach. A substep that
    /// can still be halved gets `halvingIterations` and is then given up, to be done in halves (as SPICE cuts its time
    /// step after ITL4 iterations): a shorter substep starts nearer its answer. One that cannot gets
    /// `maxNewtonIterations`, then the junctions are temporarily shunted with conductances strong enough to leave the
    /// circuit a single, easily found solution, and the shunts are stepped down to nothing, each solution leading Newton
    /// to the next (gmin stepping).
    private func solve(at t: Double, canHalve: Bool = false, fromSubstepStart: Bool = false) -> Bool {
        solveTime = t
        solveChattered = false
        let m = topology.matrixSize
        guard m > 0 else { return true }
        prepareBaseMatrix()
        if isFailed { return false }
        buildRightHandSide(at: t)
        forwardRightHandSide()
        if !hasNonlinear && !hasMemristor {
            guard let plan, let order = baseOrder else { fail(); return false }
            if workVector.count != m { workVector = [Double](repeating: 0, count: m) }
            // into a scratch vector first: a failed solve must not leave non-finite voltages behind
            let change = baseValues.withUnsafeBufferPointer { v -> Double in
                rhsForwarded.withUnsafeBufferPointer { b -> Double in
                    workVector.withUnsafeMutableBufferPointer { x -> Double in
                        let block = order.back(v.baseAddress!, b.baseAddress!, x.baseAddress!)
                        return block.isNaN ? .nan : plan.linear.back(v.baseAddress!, b.baseAddress!, x.baseAddress!)
                    }
                }
            }
            if change.isNaN { fail(); return false }
            Self.copy(workVector, into: &x)
            return true
        }
        // where it starts, to go back to: the substep's start, kept already, or kept here
        solveStartsSubstep = fromSubstepStart && substepStartX.count == x.count
        if !solveStartsSubstep { Self.copy(x, into: &savedX) }
        saveLimited(&savedLimited, &savedLimited2, &savedLimited3)
        // behavioural sources' decisions held where the solve starts
        if !decidingIndices.isEmpty { Self.copy(x, into: &decisionX) }
        junctionConductance = 0
        predictedSolve = predictNext
        if predictNext {
            // Newton-Raphson starts from the solution extrapolated along the last substep, a far better guess than the
            // last solution while a signal is moving: one iteration fewer to converge (the fallback is the last solution)
            predictNext = false
            predict()
        }
        let iterations = canHalve ? Self.halvingIterations : Self.maxNewtonIterations
        newtonFromSolveStart = true
        var converged = newton(iterations: iterations)
        newtonFromSolveStart = false
        if converged && !isFailed && !decidingIndices.isEmpty {
            // comparators that switched during the solve: solved again with their decisions made where it ended, until
            // they stay (or, a comparator chattering about its threshold, as they are after a few rounds)
            var rounds = 0
            while rounds < Self.decisionRounds && decisionsMoved() {
                rounds += 1
                decisionSolves += 1
                Self.copy(x, into: &decisionX)
                // (not from the stamps the solve ended on: they were made with the decisions as they were)
                converged = newton(iterations: iterations)
                if !converged || isFailed { break }
            }
            if converged && rounds == Self.decisionRounds {
                chatteringSolves += 1
                solveChattered = true
            }
        }
        if converged || isFailed || !hasNonlinear { return !isFailed }
        // the substep is done again in halves (the caller goes back to where it started)
        if canHalve { return false }
        predictedSolve = false
        let firstTry = (x, limitedVoltage, limitedVoltage2, limitedVoltage3)
        restoreSolveStart()
        (limitedVoltage, limitedVoltage2, limitedVoltage3) = (savedLimited, savedLimited2, savedLimited3)
        converged = false
        for conductance in Self.steppedConductances {
            junctionConductance = conductance
            converged = newton(iterations: Self.steppedIterations)
            if isFailed { break }
        }
        junctionConductance = 0
        // if that failed too, the first try is the better guess to carry on from
        if !converged && !isFailed { (x, limitedVoltage, limitedVoltage2, limitedVoltage3) = firstTry }
        return converged && !isFailed
    }

    /// Puts `x` back where the solve started
    private func restoreSolveStart() {
        if solveStartsSubstep {
            Self.copy(substepStartX, into: &x)
        } else {
            Self.copy(savedX, into: &x)
        }
    }

    /// Moves `x` along the last substep: x + (x − x before) × this substep's length over the last's. Only the nonlinear
    /// block's unknowns, where there is a plan: Newton-Raphson starts from them alone, and the linear block's follow
    /// from them at the end, whatever they were.
    private func predict() {
        let ratio = predictionRatio
        guard olderX.count == x.count, ratio.isFinite, ratio > 0 else { return }
        let block = plan.flatMap { $0.n == x.count ? $0.block : nil }
        x.withUnsafeMutableBufferPointer { x in
            olderX.withUnsafeBufferPointer { older in
                if let block {
                    for k in block { x[k] += ratio * (x[k] - older[k]) }
                } else {
                    for k in 0..<x.count { x[k] += ratio * (x[k] - older[k]) }
                }
            }
        }
    }

    /// Newton-Raphson has converged when an iteration moves the solution by less than this (relative above 1 V or 1 A,
    /// absolute below) without limiting a junction: it converges quadratically, so the solution is then within about
    /// the square of that of the answer (a junction's curvature, about 20 per volt, times 10⁻¹²). The iteration that
    /// would only confirm it is not needed.
    static let newtonTolerance = 1e-6

    /// Newton-Raphson is damped, in a circuit with nonlinear behavioural sources, once this many iterations have not
    /// converged and an iteration's step is not at least half the one before (without a junction's limiting, which
    /// shortens steps by itself): around the sharp corner of a TABLE, IF, LIMIT or clamp (a maker's model's output
    /// stage in saturation), the full step can jump from one side of the corner to the other and back for ever. Each
    /// such iteration halves the step taken (to a sixty-fourth at most), and each one that contracts doubles it back.
    static let dampingAfter = 8

    /// How many times a solve is done again for behavioural sources' decisions that changed during it
    static let decisionRounds = 4

    /// Newton-Raphson from the present `x`; true when it converged.
    ///
    /// Each iteration starts from the base's values, whose linear block is already factored (and with it what the
    /// linear block adds to the nonlinear one), restamps the nonlinear parts into the nonlinear block, factors that and
    /// solves for its unknowns: the only ones the nonlinear parts depend on. The linear block's unknowns follow from
    /// them once, at the end.
    private func newton(iterations: Int) -> Bool {
        let m = topology.matrixSize
        for i in limitingIndices { opAmpCrossings[i] = 0 }
        if workVector.count != m { workVector = [Double](repeating: 0, count: m) }
        var iteration = 0
        var plansMade = 0
        var converged = false
        var lastChange = Double.infinity
        var damping = 1.0
        var refactor = false
        var chordSteps = 0
        // only a solve that ends confirmed leaves stamps to start the next from, and only a solve that can start again
        // from where it started takes them (not one that a single iteration from the prediction ends)
        let mayReuse = confirmedStamps && junctionConductance == 0 && newtonFromSolveStart && !(onlyQuasiLinear && predictedSolve)
        confirmedStamps = false
        reuseAllowed = mayReuse
        // whether the first iteration started from them
        var startedFromKept = false
        // whether the last iteration solved the block as it stamped it, undamped and unlimited
        var solvedAsStamped = false
        // Newton-Raphson from where the solve started, as if the kept stamps had not been taken (at the second
        // iteration, its parts found elsewhere than the stamps had them)
        func startAgain() {
            startedFromKept = false
            reuseAllowed = false
            restoreSolveStart()
            if predictedSolve { predict() }
            restoreLimited(savedLimited, savedLimited2, savedLimited3)
            for i in limitingIndices { opAmpCrossings[i] = 0 }
            iteration = 0
            lastChange = .infinity
            damping = 1
            refactor = false
            chordSteps = 0
            solvedAsStamped = false
            stampMissed = false
            restartedSolves += 1
        }
        while iteration < iterations {
            if stopRequested {
                restoreSolveStart()
                fail()
                return false
            }
            if needsPlan {
                // a stamp fell outside the plan or a pivot became too small: plan again, around the present solution
                plansMade += 1
                guard plansMade <= 4 else { break }
                replan()
                prepareBaseMatrix()
                if isFailed { return false }
                if !rightHandSideReadsSolution { buildRightHandSide(at: solveTime) }
                forwardRightHandSide()
            }
            guard let plan else { fail(); return false }
            iteration += 1
            newtonIterations += 1
            let fromKept = iteration == 1 && mayReuseLastStamps(plan)
            if valuesVersion != baseVersion || values.count != baseValues.count {
                Self.copy(baseValues, into: &values)
                valuesVersion = baseVersion
            } else if valuesFactored || stampedPlan !== plan {
                // only the nonlinear block's structure and what elimination writes can have changed
                values.withUnsafeMutableBufferPointer { v in
                    baseValues.withUnsafeBufferPointer { plan.restoreChanging(v.baseAddress!, from: $0.baseAddress!) }
                }
            } else if !fromKept {
                // since a chord step (which factors nothing), only the slots the stamps reached (which the kept stamps
                // are written over, each of them)
                values.withUnsafeMutableBufferPointer { v in
                    baseValues.withUnsafeBufferPointer { base in
                        for slot in stampedSlots { v[Int(slot)] = base[Int(slot)] }
                    }
                }
            }
            valuesFactored = false
            let started = Self.profiling ? DispatchTime.now().uptimeNanoseconds : 0
            // only the block's rows: the stamps reach no others, and the linear block's are read from `rhsForwarded`
            Self.copy(plan.block, from: rhsForwarded, into: &workVector)
            limiting = false
            if fromKept {
                reuseLastStamps(plan)
                // the last step ended on stamps that its own solution confirmed (its parts on straight stretches): this
                // step's first iteration starts from them rather than evaluating every part. It cannot end the solve:
                // the next iteration evaluates every part at its solution and confirms it, or Newton-Raphson starts
                // again from where it would have started without them
                reusedStampings += 1
                startedFromKept = true
            } else {
                beginSparseStamping(plan, floor: plan.tailStart)
                recordStamps(for: plan)
                stampMemristors(&values, m)
                if hasNonlinear { stampNonlinear(&values, &workVector, m) }
                sparseStamping = false
                recordingStamps = false
            }
            if stampMissed {
                if startedFromKept {
                    startAgain()
                } else {
                    needsPlan = true
                }
                continue
            }
            if limiting { limitedIterations += 1 }
            let stamped = Self.profiling ? DispatchTime.now().uptimeNanoseconds : 0
            let damped = damping < 1
            // stamped at the last iteration's solution, the block is the very block that iteration solved (its parts
            // sit where they did, or on straight stretches of their curves): that solution is this one's, to far
            // within the tolerance, and the solve would only confirm it
            if Self.reusesFactors && solvedAsStamped && !damped && !limiting && stampsUnchanged(plan) {
                confirmedWithoutSolving += 1
                converged = true
                // the snapshot (the stamps the solution solved, which the parts gave again there) for the next step
                // to start from
                confirmedStamps = true
                confirmedPlanSerial = planSerial
                confirmedBaseVersion = baseVersion
                break
            }
            if startedFromKept && iteration == 2 {
                startAgain()
                continue
            }
            // (the kept stamps are the snapshot already)
            if Self.reusesFactors && !fromKept { snapshotStamps(plan) }
            if damped {
                Self.copy(x, into: &dampFrom)
                dampedIterations += 1
            }
            let change: Double
            if Self.reusesFactors && !damped && !refactor && (keptFactorsSuit(plan) || formerFactorsSuit(plan)) {
                // the block is as it was when last factored, near enough: a step solved with those factors from the
                // present residual (the chord method) converges to the very same solution, without factoring
                change = chordStep(plan)
                reusedFactorings += 1
                chordSteps += 1
            } else {
                // the nonlinear block, by the first of the plan's pivot orders that suits its values (or a new one)
                keepEntries(plan)
                valuesFactored = true
                let blockCount = max(plan.entryCount - plan.tailStart, 1)
                if blockScratch.count != blockCount { blockScratch = [Double](repeating: 0, count: blockCount) }
                let chosen = values.withUnsafeMutableBufferPointer { v -> EliminationProgram? in
                    blockScratch.withUnsafeMutableBufferPointer { plan.factorBlock(v.baseAddress!, scratch: $0.baseAddress!) }
                }
                guard let order = chosen else {
                    keptOrder = nil
                    restoreSolveStart()
                    fail()
                    return false
                }
                keepFactors(plan, order)
                factorings += 1
                chordSteps = 0
                change = values.withUnsafeBufferPointer { v -> Double in
                    workVector.withUnsafeMutableBufferPointer { b -> Double in
                        order.forward(v.baseAddress!, b.baseAddress!)
                        return x.withUnsafeMutableBufferPointer { x -> Double in order.back(v.baseAddress!, b.baseAddress!, x.baseAddress!) }
                    }
                }
            }
            if Self.profiling {
                let now = DispatchTime.now().uptimeNanoseconds
                stampNanoseconds &+= stamped &- started
                solveNanoseconds &+= now &- stamped
            }
            // the chord method contracts linearly, by how near the kept factors are: where it does not contract fast,
            // the next iteration factors afresh
            refactor = chordSteps > 0 && (change > 0.25 * lastChange || chordSteps >= 4)
            if change.isNaN {
                if fromKept {
                    startAgain()
                    continue
                }
                restoreSolveStart()
                fail()
                return false
            }
            if !fromKept && (!hasNonlinear || (onlyQuasiLinear && predictedSolve) || (change < Self.newtonTolerance && !limiting)) {
                converged = true
                break
            }
            solvedAsStamped = !damped && !limiting
            if damped {
                // only the nonlinear block's unknowns moved (the linear block's follow from them at the end)
                let lambda = damping
                x.withUnsafeMutableBufferPointer { x in
                    dampFrom.withUnsafeBufferPointer { from in
                        for u in plan.block { x[u] = from[u] + lambda * (x[u] - from[u]) }
                    }
                }
            }
            if dampsNewton && iteration >= Self.dampingAfter && !limiting {
                damping = change > 0.5 * lastChange ? max(damping / 2, 1.0 / 64) : min(damping * 2, 1)
            }
            lastChange = change
        }
        // the linear block's unknowns, from the nonlinear block's (its rows of the right-hand side are as forwarded),
        // through its factors packed for the base matrix
        guard let plan, valuesVersion == baseVersion else { return converged }
        packLinear(plan)
        let finite = linearPacked.withUnsafeBufferPointer { f -> Bool in
            rhsForwarded.withUnsafeBufferPointer { b -> Bool in
                x.withUnsafeMutableBufferPointer { x -> Bool in plan.linear.substituteBack(f.baseAddress!, b.baseAddress!, x.baseAddress!) }
            }
        }
        if !finite {
            restoreSolveStart()
            fail()
            return false
        }
        return converged
    }

    /// The largest change in a nonlinear block entry, against the largest entry of its row, for which the kept factors
    /// still serve: the chord method then contracts by about that much a step (times the block's conditioning)
    static let reuseTolerance = 1e-7

    /// Keeps the block as just stamped: its stamped slots' values, and what the stamps added to its rows of the
    /// right-hand side
    private func snapshotStamps(_ plan: SparsePlan) {
        let count = stampedSlots.count, rows = plan.block.count
        if stampSnapshot.count != count { stampSnapshot = [Double](repeating: 0, count: count) }
        if rightSnapshot.count != rows { rightSnapshot = [Double](repeating: 0, count: rows) }
        values.withUnsafeBufferPointer { v in
            stampSnapshot.withUnsafeMutableBufferPointer { kept in
                for k in 0..<count { kept[k] = v[Int(stampedSlots[k])] }
            }
        }
        workVector.withUnsafeBufferPointer { b in
            rhsForwarded.withUnsafeBufferPointer { forwarded in
                rightSnapshot.withUnsafeMutableBufferPointer { kept in
                    for k in 0..<rows {
                        let row = plan.block[k]
                        kept[k] = b[row] - forwarded[row]
                    }
                }
            }
        }
    }

    /// Whether there are stamps the last solve confirmed, for this plan and base matrix, to start from
    private func mayReuseLastStamps(_ plan: SparsePlan) -> Bool {
        reuseAllowed && Self.reusesFactors && confirmedPlanSerial == planSerial && stampedPlan === plan && confirmedBaseVersion == baseVersion
            && stampSnapshot.count == stampedSlots.count && rightSnapshot.count == plan.block.count
    }

    /// Puts the stamps the last solve confirmed (see `mayReuseLastStamps`) into the block, in place of stamping
    private func reuseLastStamps(_ plan: SparsePlan) {
        let rows = plan.block.count
        reuseAllowed = false
        values.withUnsafeMutableBufferPointer { v in
            stampSnapshot.withUnsafeBufferPointer { kept in
                for k in 0..<kept.count { v[Int(stampedSlots[k])] = kept[k] }
            }
        }
        workVector.withUnsafeMutableBufferPointer { b in
            rightSnapshot.withUnsafeBufferPointer { kept in
                for k in 0..<rows { b[plan.block[k]] += kept[k] }
            }
        }
    }

    /// Whether the block as just stamped is the one `snapshotStamps` kept, each entry within 10⁻¹² of its row's scale
    private func stampsUnchanged(_ plan: SparsePlan) -> Bool {
        let rows = plan.block.count
        guard stampedPlan === plan, keptPlan === plan, stampSnapshot.count == stampedSlots.count, rightSnapshot.count == rows,
              keptRowScale.count == rows else { return false }
        let tolerance = 1e-12
        return values.withUnsafeBufferPointer { v -> Bool in
            keptRowScale.withUnsafeBufferPointer { scale -> Bool in
                for k in 0..<stampedSlots.count {
                    let now = v[Int(stampedSlots[k])], then = stampSnapshot[k]
                    // (written so that a value that is not a number fails too)
                    guard abs(now - then) <= tolerance * (abs(now) + scale[Int(stampedLocalRows[k])]) else { return false }
                }
                return workVector.withUnsafeBufferPointer { b -> Bool in
                    rhsForwarded.withUnsafeBufferPointer { forwarded -> Bool in
                        rightSnapshot.withUnsafeBufferPointer { kept -> Bool in
                            for k in 0..<rows {
                                let row = plan.block[k]
                                let now = b[row], added = now - forwarded[row]
                                guard abs(added - kept[k]) <= tolerance * (abs(now) + scale[k]) else { return false }
                            }
                            return true
                        }
                    }
                }
            }
        }
    }

    /// Packs the linear block's factors from the base matrix, once for each base matrix
    private func packLinear(_ plan: SparsePlan) {
        let count = plan.linear.packedCount
        guard linearPackedVersion != baseVersion || linearPackedSerial != planSerial || linearPacked.count != max(count, 1) else { return }
        if linearPacked.count != max(count, 1) { linearPacked = [Double](repeating: 0, count: max(count, 1)) }
        baseValues.withUnsafeBufferPointer { v in
            linearPacked.withUnsafeMutableBufferPointer { plan.linear.pack(v.baseAddress!, into: $0.baseAddress!) }
        }
        linearPackedVersion = baseVersion
        linearPackedSerial = planSerial
    }

    /// Starts recording which slots of the nonlinear block Newton-Raphson's stamps reach, afresh for a new plan
    private func recordStamps(for plan: SparsePlan) {
        if stampedPlan !== plan {
            stampedFlags?.deallocate()
            let count = max(plan.entryCount, 1)
            let flags = UnsafeMutablePointer<Bool>.allocate(capacity: count)
            flags.initialize(repeating: false, count: count)
            stampedFlags = flags
            stampedPlan = plan
            stampedSlots = []
            stampedRows = []
            stampedColumns = []
            stampedLocalRows = []
            stampedSlotsGrew = true
        }
        recordingStamps = true
    }

    /// A slot of the nonlinear block reached by a stamp for the first time
    @inline(never) private func noteStampedSlot(_ slot: Int) {
        guard let plan = stampedPlan, let flags = stampedFlags else { return }
        flags[slot] = true
        let s = plan.block.count
        let local = slot - plan.tailStart
        guard s > 0, local >= 0, local < s * s else { return }
        stampedSlots.append(Int32(slot))
        stampedRows.append(Int32(plan.block[local / s]))
        stampedColumns.append(Int32(plan.block[local % s]))
        stampedLocalRows.append(Int32(local / s))
        stampedSlotsGrew = true
    }

    /// Whether the kept factors were made for this plan, on this base matrix, and the block's entries, as stamped, are
    /// near those they were made from (only the slots the stamps reach can differ)
    private func keptFactorsSuit(_ plan: SparsePlan) -> Bool {
        guard keptPlan === plan, keptOrder != nil, !plan.block.isEmpty, keptBaseVersion == baseVersion, !stampedSlotsGrew,
              keptValues.count == plan.entryCount else { return false }
        let count = stampedSlots.count
        return values.withUnsafeBufferPointer { v -> Bool in
            keptValues.withUnsafeBufferPointer { kept -> Bool in
                stampedSlots.withUnsafeBufferPointer { slots -> Bool in
                    stampedLocalRows.withUnsafeBufferPointer { rows -> Bool in
                        keptRowScale.withUnsafeBufferPointer { scale -> Bool in
                            var k = 0
                            while k < count {
                                let slot = Int(slots[k])
                                // (written so that a value that is not a number fails too)
                                guard abs(v[slot] - kept[slot]) <= Self.reuseTolerance * scale[Int(rows[k])] else { return false }
                                k += 1
                            }
                            return true
                        }
                    }
                }
            }
        }
    }

    /// Keeps the block's entries as stamped, before factoring: the largest of each row (the base matrix's, worked out once
    /// for it, or a stamped one's), and those of the slots the stamps reach, which later iterations' are compared with
    private func keepEntries(_ plan: SparsePlan) {
        let s = plan.block.count
        if keptPlan !== plan || keptBaseVersion != baseVersion {
            formerFactorings.removeAll()
        } else if let order = keptOrder, keptStampedCount > 0, keptStampedCount == stampedSlots.count {
            rememberPresentFactoring(order)
        }
        if keptPlan !== plan {
            keptPlan = plan
            keptSlots = []
            keptLocalRows = []
            for i in 0..<s {
                for j in 0..<s where plan.blockStructure[i * s + j] {
                    keptSlots.append(Int32(plan.tailStart + i * s + j))
                    keptLocalRows.append(Int32(i))
                }
            }
            keptValues = [Double](repeating: 0, count: plan.entryCount)
            keptRowScale = [Double](repeating: 0, count: s)
            baseRowScale = [Double](repeating: 0, count: s)
            baseRowScaleVersion = -1
        }
        keptOrder = nil
        if baseRowScaleVersion != baseVersion {
            baseValues.withUnsafeBufferPointer { base in
                baseRowScale.withUnsafeMutableBufferPointer { scale in
                    for i in 0..<s { scale[i] = 0 }
                    for k in keptSlots.indices {
                        let row = Int(keptLocalRows[k])
                        scale[row] = max(scale[row], abs(base[Int(keptSlots[k])]))
                    }
                }
            }
            baseRowScaleVersion = baseVersion
        }
        Self.copy(baseRowScale, into: &keptRowScale)
        values.withUnsafeBufferPointer { v in
            keptRowScale.withUnsafeMutableBufferPointer { scale in
                keptValues.withUnsafeMutableBufferPointer { kept in
                    for k in stampedSlots.indices {
                        let slot = Int(stampedSlots[k])
                        let row = Int(stampedLocalRows[k])
                        kept[slot] = v[slot]
                        scale[row] = max(scale[row], abs(v[slot]))
                    }
                }
            }
        }
        keptBaseVersion = baseVersion
        keptStampedCount = stampedSlots.count
        stampedSlotsGrew = false
    }

    /// Keeps the factoring about to be replaced among the former ones, for the block to come back to, in the memory of
    /// the oldest when there are enough. Not while former factorings keep missing (a transistor's slopes move a little
    /// at every iteration, and its block never comes back exactly): then none is kept for a while.
    private func rememberPresentFactoring(_ order: EliminationProgram) {
        if formerRest > 0 {
            formerRest -= 1
            return
        }
        if formerMisses >= Self.formerMissesTolerated {
            formerMisses = 0
            formerRest = Self.formerRestFactorings
            formerFactorings.removeAll()
            return
        }
        var former = formerFactorings.count >= Self.formerFactoringsKept
            ? formerFactorings.removeLast() : FormerFactoring(values: [], rowScale: [], factors: [], order: order)
        former.values.removeAll(keepingCapacity: true)
        keptValues.withUnsafeBufferPointer { kept in
            for k in 0..<keptStampedCount { former.values.append(kept[Int(stampedSlots[k])]) }
        }
        former.rowScale.removeAll(keepingCapacity: true)
        former.rowScale.append(contentsOf: keptRowScale)
        former.factors.removeAll(keepingCapacity: true)
        former.factors.append(contentsOf: keptFactors)
        former.order = order
        formerFactorings.insert(former, at: 0)
    }

    /// Whether one of the former factorings was made from the block as it is stamped now, near enough (as
    /// `keptFactorsSuit` asks of the present one): a comparator that flipped and flipped back puts a maker's model's
    /// block back exactly as it was, its parts being straight lines between their decisions. That one becomes the
    /// present factoring, and the present one a former.
    private func formerFactorsSuit(_ plan: SparsePlan) -> Bool {
        guard keptPlan === plan, keptBaseVersion == baseVersion, !formerFactorings.isEmpty, !plan.block.isEmpty,
              keptValues.count == plan.entryCount else { return false }
        let count = stampedSlots.count
        let found = values.withUnsafeBufferPointer { v -> Int? in
            stampedSlots.withUnsafeBufferPointer { slots -> Int? in
                stampedLocalRows.withUnsafeBufferPointer { rows -> Int? in
                    formerFactorings.firstIndex { former in
                        guard former.values.count == count else { return false }
                        return former.values.withUnsafeBufferPointer { kept -> Bool in
                            former.rowScale.withUnsafeBufferPointer { scale -> Bool in
                                for k in 0..<count {
                                    // (written so that a value that is not a number fails too)
                                    guard abs(v[Int(slots[k])] - kept[k]) <= Self.reuseTolerance * scale[Int(rows[k])] else { return false }
                                }
                                return true
                            }
                        }
                    }
                }
            }
        }
        guard let found else {
            formerMisses += 1
            return false
        }
        formerMisses = 0
        // the former factoring and the present one change places, each in the other's memory
        var former = formerFactorings.remove(at: found)
        let present = keptOrder
        keptValues.withUnsafeMutableBufferPointer { kept in
            former.values.withUnsafeMutableBufferPointer { values in
                for k in 0..<count {
                    let slot = Int(stampedSlots[k])
                    (kept[slot], values[k]) = (values[k], kept[slot])
                }
            }
        }
        swap(&keptRowScale, &former.rowScale)
        swap(&keptFactors, &former.factors)
        keptOrder = former.order
        if let present, keptStampedCount == count {
            former.order = present
            formerFactorings.insert(former, at: 0)
        }
        keptStampedCount = count
        stampedSlotsGrew = false
        restoredFactorings += 1
        return true
    }

    /// Keeps the block's factors, just made by `order`, packed for the iterations after
    private func keepFactors(_ plan: SparsePlan, _ order: EliminationProgram) {
        guard keptPlan === plan else { return }
        let count = order.packedCount
        if keptFactors.count != count { keptFactors = [Double](repeating: 0, count: max(count, 1)) }
        values.withUnsafeBufferPointer { v in
            keptFactors.withUnsafeMutableBufferPointer { order.pack(v.baseAddress!, into: $0.baseAddress!) }
        }
        keptOrder = order
    }

    /// One chord step: the block's equations as stamped, A x = b, solved with the factors of the block A₀ they were made
    /// from as A₀ x' = b + (A₀ − A) x at the present solution x, A₀ − A being zero but where the stamps reach. Its
    /// fixed point is A x = b, Newton-Raphson's solution. Writes x' and returns the largest change of an unknown,
    /// relative to its new size, or NaN.
    private func chordStep(_ plan: SparsePlan) -> Double {
        guard let order = keptOrder else { return .nan }
        let m = workVector.count
        if residual.count != m { residual = [Double](repeating: 0, count: m) }
        // (substitution through the block's factors reads and writes only its rows)
        Self.copy(plan.block, from: workVector, into: &residual)
        let count = stampedSlots.count
        values.withUnsafeBufferPointer { v in
            keptValues.withUnsafeBufferPointer { kept in
                residual.withUnsafeMutableBufferPointer { r in
                    x.withUnsafeBufferPointer { x in
                        stampedSlots.withUnsafeBufferPointer { slots in
                            stampedRows.withUnsafeBufferPointer { rows in
                                stampedColumns.withUnsafeBufferPointer { columns in
                                    var k = 0
                                    while k < count {
                                        let slot = Int(slots[k])
                                        r[Int(rows[k])] += (kept[slot] - v[slot]) * x[Int(columns[k])]
                                        k += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return keptFactors.withUnsafeBufferPointer { f -> Double in
            residual.withUnsafeMutableBufferPointer { r -> Double in
                order.forwardPacked(f.baseAddress!, r.baseAddress!)
                return x.withUnsafeMutableBufferPointer { x -> Double in order.backPacked(f.baseAddress!, r.baseAddress!, x.baseAddress!) }
            }
        }
    }

    /// The linear block's forward substitution of the right-hand side, done once per solve (the nonlinear parts only
    /// stamp the nonlinear block's rows); for a circuit without them, the whole forward substitution. The right-hand
    /// side as built becomes the forwarded one (to be built again before it is forwarded again), unless building it
    /// reads the solution.
    private func forwardRightHandSide() {
        if rightHandSideReadsSolution {
            Self.copy(rhs, into: &rhsForwarded)
        } else {
            swap(&rhs, &rhsForwarded)
        }
        guard let plan, baseValues.count == plan.entryCount else { return }
        if hasNonlinear || hasMemristor {
            // through the linear block's factors packed for the base matrix, as Newton-Raphson goes back through them
            packLinear(plan)
            linearPacked.withUnsafeBufferPointer { f in
                rhsForwarded.withUnsafeMutableBufferPointer { plan.linear.forwardPacked(f.baseAddress!, $0.baseAddress!) }
            }
            return
        }
        let order = hasNonlinear || hasMemristor ? nil : baseOrder
        baseValues.withUnsafeBufferPointer { v in
            rhsForwarded.withUnsafeMutableBufferPointer { b in
                plan.linear.forward(v.baseAddress!, b.baseAddress!)
                order?.forward(v.baseAddress!, b.baseAddress!)
            }
        }
    }

    private func beginSparseStamping(_ plan: SparsePlan, floor: Int) {
        sparseStamping = true
        // Newton-Raphson's stamps (into the nonlinear block) only within its structure
        slotMap = floor > 0 ? plan.stampSlots : plan.slots
        stampFloor = floor
        stampSize = plan.n
        stampMissed = false
    }

    /// A stamp outside the plan: noted for the next plan, which includes the position (and, for Newton-Raphson's
    /// stamps, puts its row and column in the nonlinear block)
    @inline(never) private func missStamp(_ index: Int) {
        stampMissed = true
        missedPositions.append(index)
        if stampFloor > 0 && stampSize > 0 {
            extraNonlinear.insert(index / stampSize)
            extraNonlinear.insert(index % stampSize)
        }
    }

    /// Keeps the voltages Newton-Raphson limited, to go back to: only the parts that limit theirs (a maker's model is
    /// mostly wires, labels and resistors, each with an entry, and behavioural sources, which limit nothing)
    private func saveLimited(_ a: inout [Double], _ b: inout [Double], _ c: inout [Double]) {
        guard a.count == limitedVoltage.count, b.count == limitedVoltage2.count, c.count == limitedVoltage3.count else {
            (a, b, c) = (limitedVoltage, limitedVoltage2, limitedVoltage3)
            return
        }
        guard !limitingIndices.isEmpty else { return }
        Self.copy(limitingIndices, from: limitedVoltage, into: &a)
        Self.copy(limitingIndices, from: limitedVoltage2, into: &b)
        Self.copy(limitingIndices, from: limitedVoltage3, into: &c)
    }

    /// Goes back to limited voltages kept by `saveLimited`
    private func restoreLimited(_ a: [Double], _ b: [Double], _ c: [Double]) {
        guard a.count == limitedVoltage.count, b.count == limitedVoltage2.count, c.count == limitedVoltage3.count else {
            (limitedVoltage, limitedVoltage2, limitedVoltage3) = (a, b, c)
            return
        }
        guard !limitingIndices.isEmpty else { return }
        Self.copy(limitingIndices, from: a, into: &limitedVoltage)
        Self.copy(limitingIndices, from: b, into: &limitedVoltage2)
        Self.copy(limitingIndices, from: c, into: &limitedVoltage3)
    }

    /// Copies the entries at `indices` (each within both arrays) from one array into another
    @inline(__always) private static func copy(_ indices: [Int], from source: [Double], into target: inout [Double]) {
        target.withUnsafeMutableBufferPointer { target in
            source.withUnsafeBufferPointer { source in
                for i in indices { target[i] = source[i] }
            }
        }
    }

    /// Copies element by element into an array of the same size, so the target keeps its storage
    @inline(__always) private static func copy(_ source: [Double], into target: inout [Double]) {
        guard target.count == source.count, !source.isEmpty else {
            target = source
            return
        }
        target.withUnsafeMutableBufferPointer { target in
            source.withUnsafeBufferPointer { target.baseAddress!.update(from: $0.baseAddress!, count: $0.count) }
        }
    }

    private func finishStep(at t: Double) {
        time = t
        updateStepStates()
        currentsAreStale = true
        for (trace, index) in recordedTraces { record(trace, index) }
    }

    private func fail() {
        isFailed = true
        problems = topology.problems + behaviorProblems + ["The circuit can't be solved. Look for voltage sources in parallel, a loop of sources and wires, or a current source with nowhere to go."]
    }

    // MARK: - Equations

    @inline(__always) private func voltage(_ node: Int) -> Double {
        node == 0 ? 0 : x[node - 1]
    }

    /// Conductance g between nodes a and b
    @inline(__always) private func stampConductance(_ matrix: Entries, _ m: Int, _ a: Int, _ b: Int, _ g: Double) {
        if a > 0 { stamp(matrix, (a - 1) * m + a - 1, g) }
        if b > 0 { stamp(matrix, (b - 1) * m + b - 1, g) }
        if a > 0 && b > 0 {
            stamp(matrix, (a - 1) * m + b - 1, -g)
            stamp(matrix, (b - 1) * m + a - 1, -g)
        }
    }

    /// Adds to one matrix entry, given as row × size + column: in a dense matrix, or while stamping sparse, in the plan's
    /// slot for it (one it may write, or else noted as missed)
    @inline(__always) private func stamp(_ matrix: Entries, _ index: Int, _ value: Double) {
        if sparseStamping {
            let slot = Int(slotMap[index])
            if slot >= stampFloor {
                matrix[slot] += value
                if recordingStamps, let flags = stampedFlags, !flags[slot] { noteStampedSlot(slot) }
            } else {
                missStamp(index)
            }
        } else {
            matrix[index] += value
        }
    }

    /// A current i flowing through the element from node a to node b
    @inline(__always) private func stampCurrent(_ rhs: Entries, _ a: Int, _ b: Int, _ i: Double) {
        if a > 0 { rhs[a - 1] -= i }
        if b > 0 { rhs[b - 1] += i }
    }

    /// Adds `value` at (row, column) given as 0-based matrix indices; negative indices (ground) are skipped
    @inline(__always) private func add(_ matrix: Entries, _ m: Int, _ row: Int, _ column: Int, _ value: Double) {
        if row >= 0 && column >= 0 { stamp(matrix, row * m + column, value) }
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
        if plan == nil || needsPlan {
            guard replan() else { return }
        }
        let key = substepLevel << 4 | lastLevel
        if matrixIsCurrent {
            if key == baseKey { return }
            if let entry = baseCache[key] {
                (baseValues, baseVersion, baseOrder) = (entry.values, entry.version, entry.order)
                baseKey = key
                return
            }
        } else {
            baseCache.removeAll(keepingCapacity: true)
        }
        buildBaseMatrix()
        guard !isFailed else { return }
        baseKey = key
        baseCache[key] = (baseValues, baseVersion, baseOrder)
    }

    /// The part of the matrix that only changes with the circuit or the substep, stamped into the plan's slots and its
    /// linear block factored (all of it, for a circuit without nonlinear parts). Planned again if it no longer fits.
    private func buildBaseMatrix() {
        let m = topology.matrixSize
        for _ in 0..<4 {
            guard let plan else { break }
            baseVersionCount += 1
            baseVersion = baseVersionCount
            var built = [Double](repeating: 0, count: plan.entryCount)
            beginSparseStamping(plan, floor: 0)
            fillBaseMatrix(&built, m)
            sparseStamping = false
            if !stampMissed && built.withUnsafeMutableBufferPointer({ plan.linear.factor($0.baseAddress!) }) < 0 {
                // without nonlinear parts the nonlinear block (unknowns the linear block could not pivot) is factored
                // here too, once
                var order: EliminationProgram?
                if !hasNonlinear && !hasMemristor {
                    let blockCount = max(plan.entryCount - plan.tailStart, 1)
                    if blockScratch.count != blockCount { blockScratch = [Double](repeating: 0, count: blockCount) }
                    order = built.withUnsafeMutableBufferPointer { v -> EliminationProgram? in
                        blockScratch.withUnsafeMutableBufferPointer { plan.factorBlock(v.baseAddress!, scratch: $0.baseAddress!) }
                    }
                }
                if hasNonlinear || hasMemristor || order != nil {
                    baseValues = built
                    baseOrder = order
                    matrixIsCurrent = true
                    return
                }
            }
            guard replan() else { return }
        }
        fail()
    }

    /// Plans the factoring afresh (see `SparsePlan`): from the base matrix and, with nonlinear parts, their stamps at the
    /// present solution, so the pivots suit the values Newton-Raphson will meet. Every position an earlier plan had
    /// stays in, so the pattern only grows. False (and the simulation fails) when the equations are singular.
    @discardableResult
    private func replan() -> Bool {
        let m = topology.matrixSize
        plans += 1
        let started = DispatchTime.now().uptimeNanoseconds
        defer { planningSeconds += Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 }
        needsPlan = false
        matrixIsCurrent = false
        baseCache.removeAll(keepingCapacity: true)
        baseKey = -1
        valuesVersion = -1
        guard m > 0 else { return true }
        var matrix = makeBaseMatrix()
        var pattern = matrix.map { $0 != 0 }
        if let old = plan, old.n == m {
            for i in 0..<(m * m) where old.structure[i] { pattern[i] = true }
        }
        for index in missedPositions where index >= 0 && index < m * m { pattern[index] = true }
        missedPositions.removeAll()
        var nonlinear = [Bool](repeating: false, count: m)
        func unknowns(_ i: Int) -> [Int] {
            var result = topology.elementNodes[i].filter { $0 > 0 }.map { $0 - 1 }
            if topology.sourceRow[i] >= 0 { result.append(topology.sourceRow[i]) }
            // the rows of the sources a behavioural source reads the current of
            if i < behaviors.count, let b = behaviors[i] { result += b.inputs.compactMap { $0.row >= 0 && $0.row < m ? $0.row : nil } }
            return result
        }
        // a nonlinear part stamps (and reads) only its own unknowns: they are the nonlinear block, each part's in full
        for i in nonlinearIndices + memristorIndices {
            let own = unknowns(i)
            for a in own {
                nonlinear[a] = true
                for b in own { pattern[a * m + b] = true }
            }
        }
        for u in extraNonlinear where u < m { nonlinear[u] = true }
        // parts whose base stamps move with their state (a 555's output, a multiplexer's channel, a chip's pins): every
        // position they can stamp, so switching does not need a new plan
        for i in kinds.indices {
            switch kinds[i] {
            case .timer555, .analogMux, .analogSelector:
                let own = unknowns(i)
                for a in own { for b in own { pattern[a * m + b] = true } }
            case .atmega328p, .atmega2560, .attiny85, .rp2040:
                for a in unknowns(i) { pattern[a * m + a] = true }
            default:
                break
            }
        }
        if hasNonlinear || hasMemristor {
            let saved = (limitedVoltage, limitedVoltage2, limitedVoltage3, opAmpCrossings, limiting)
            var scratch = [Double](repeating: 0, count: m)
            stampMemristors(&matrix, m)
            if hasNonlinear { stampNonlinear(&matrix, &scratch, m) }
            (limitedVoltage, limitedVoltage2, limitedVoltage3, opAmpCrossings, limiting) = saved
        }
        guard let made = SparsePlan.make(matrix: matrix, pattern: pattern, nonlinear: nonlinear, size: m) else {
            plan = nil
            fail()
            return false
        }
        plan = made
        return true
    }

    /// The base matrix's entries, dense; while linearising, without the capacitors and inductors
    private func makeBaseMatrix() -> [Double] {
        let m = topology.matrixSize
        var matrix = [Double](repeating: 0, count: m * m)
        fillBaseMatrix(&matrix, m)
        return matrix
    }

    /// Stamps the base matrix's entries into `matrix`: dense, or the plan's slots while stamping sparse
    private func fillBaseMatrix(_ matrix: Entries, _ m: Int) {
        for node in 1..<max(1, topology.nodeCount) {
            stamp(matrix, (node - 1) * m + node - 1, Self.gmin)
        }
        for (i, element) in flat.elements.enumerated() {
            let nodes = topology.elementNodes[i]
            switch element.kind {
            case .resistor, .lamp:
                stampConductance(matrix, m, nodes[0], nodes[1], 1 / max(element[param: "resistance"], 1e-9))
            case .behavioralSource:
                stampLinearBehavior(i, nodes, matrix, m)
            case .potentiometer:
                let (upper, lower) = potentiometerResistances(element)
                stampConductance(matrix, m, nodes[0], nodes[2], 1 / upper)
                stampConductance(matrix, m, nodes[2], nodes[1], 1 / lower)
            case .capacitor where !linearising:
                stampConductance(matrix, m, nodes[0], nodes[1], a0 * element[param: "capacitance"] / h)
            case .inductor where !linearising:
                stampConductance(matrix, m, nodes[0], nodes[1], h / (a0 * constants[i].value))
            case .transformer:
                // an ideal transformer (a transformer part's core): the secondary is a voltage source of `ratio` times
                // the primary's voltage, and the primary carries `ratio` times the secondary's current, so it passes
                // on exactly the power the secondary delivers
                let row = topology.sourceRow[i]
                guard row >= 0, nodes.count == 4 else { continue }
                let r = constants[i].value
                add(matrix, m, nodes[2] - 1, row, -1)
                add(matrix, m, nodes[3] - 1, row, 1)
                add(matrix, m, nodes[0] - 1, row, r)
                add(matrix, m, nodes[1] - 1, row, -r)
                add(matrix, m, row, nodes[2] - 1, 1)
                add(matrix, m, row, nodes[3] - 1, -1)
                add(matrix, m, row, nodes[0] - 1, -r)
                add(matrix, m, row, nodes[1] - 1, r)
            case .diode, .led, .zener:
                // the series resistance to the junction's internal anode
                if diodes[i].hasSeriesNode { stampConductance(matrix, m, nodes[0], nodes[2], 1 / diodes[i].rs) }
            case .npn, .pnp:
                // the resistances to the internal nodes (a base resistance that falls with the base current is stamped
                // with the junctions, at each iteration)
                let g = bipolar[i]
                let n = Self.bipolarNodes({ nodes[$0] }, g)
                if g.hasBaseNode && !g.baseModulated { stampConductance(matrix, m, n.b, n.bp, 1 / g.rb) }
                if g.hasCollectorNode { stampConductance(matrix, m, n.c, n.cp, 1 / g.rc) }
                if g.hasEmitterNode { stampConductance(matrix, m, n.e, n.ep, 1 / g.re) }
            case .njfet, .pjfet:
                // the drain and source resistances to the internal nodes
                let j = jfets[i]
                let n = Self.jfetNodes({ nodes[$0] }, j)
                if j.hasDrainNode { stampConductance(matrix, m, n.d, n.dp, 1 / j.rd) }
                if j.hasSourceNode { stampConductance(matrix, m, n.s, n.sp, 1 / j.rs) }
            case .nmos, .pmos:
                let f = mosfets[i]
                let n = Self.fetNodes({ nodes[$0] }, drain: f.hasDrainNode, source: f.hasSourceNode)
                if f.hasDrainNode { stampConductance(matrix, m, n.d, n.dp, 1 / f.rd) }
                if f.hasSourceNode { stampConductance(matrix, m, n.s, n.sp, 1 / f.rs) }
            case .dcVoltage, .acVoltage, .squareVoltage, .noiseVoltage, .keyboardPitch, .keyboardGate, .audioInput:
                let row = topology.sourceRow[i]
                guard row >= 0 else { continue }
                let minus = nodes[0] - 1
                let plus = nodes[1] - 1
                // the source delivers its current out of the + terminal (b) and takes it back at the - terminal (a)
                add(matrix, m, plus, row, -1)
                add(matrix, m, minus, row, 1)
                add(matrix, m, row, plus, 1)
                add(matrix, m, row, minus, -1)
            case .opAmp, .multiplier, .comparator, .delayLine, .digitalDelay, .vco, .vcf, .envelope, .vca, .sampleHold, .divider,
                 .levelDetector, .springReverb, .agcPreamp:
                // output: a voltage source to ground, whose voltage the nonlinear stage (or the delay line, or the chip's
                // state) sets
                if element.kind == .springReverb {
                    // the tank's input coil
                    stampConductance(matrix, m, nodes[0], nodes[1], constants[i].onConductance)
                }
                if element.kind == .digitalDelay {
                    // an echo chip's pin 6: its internal reference behind its internal resistance
                    stampConductance(matrix, m, nodes[1], 0, 1 / constants[i].value)
                }
                let row = topology.sourceRow[i]
                guard row >= 0 else { continue }
                add(matrix, m, nodes[2] - 1, row, -1)
                add(matrix, m, row, nodes[2] - 1, 1)
            case .timer555:
                // pins: GND, TRIG, OUT, RESET, CTRL, THR, DIS, VCC. The internal divider sets CTRL to 2/3 of the supply
                // (the trigger compares with half of CTRL); the output drives towards VCC or GND; DIS shorts to GND
                // while the output is low
                let (ground, output, control, discharge, supply) = (nodes[0], nodes[2], nodes[4], nodes[6], nodes[7])
                stampConductance(matrix, m, supply, control, 1 / 5000.0)
                stampConductance(matrix, m, control, ground, 1 / 10_000.0)
                let high = digitalState[i]
                stampConductance(matrix, m, output, high ? supply : ground, 1 / max(element[param: "outputResistance"], 0.1))
                stampConductance(matrix, m, discharge, ground, high ? 1e-9 : 1 / max(element[param: "dischargeResistance"], 0.1))
            case .schmittInverter:
                // output drives towards the hidden supply or ground through its output resistance
                stampConductance(matrix, m, nodes[1], 0, 1 / max(element[param: "outputResistance"], 0.1))
            case .logicGate, .flipFlop, .decadeCounter, .binaryCounter, .shiftRegister, .pll:
                // each output likewise; the inputs draw nothing
                for k in element.kind.logicOutputs where k < nodes.count {
                    stampConductance(matrix, m, nodes[k], 0, constants[i].outputConductance)
                }
            case .dac:
                // the output: driven to its voltage through its output resistance
                if nodes.count > 5 { stampConductance(matrix, m, nodes[5], 0, constants[i].outputConductance) }
            case .effectsProcessor, .dualDac:
                // both outputs likewise
                for k in [4, 5] where k < nodes.count { stampConductance(matrix, m, nodes[k], 0, constants[i].outputConductance) }
            case .i2sDac:
                for k in [3, 4] where k < nodes.count { stampConductance(matrix, m, nodes[k], 0, constants[i].outputConductance) }
            case .i2cDac:
                if nodes.count > 3 { stampConductance(matrix, m, nodes[3], 0, constants[i].outputConductance) }
                // SDA pulled low while it acknowledges
                if Logic.acknowledging(logicStates[i]), nodes.count > 1 {
                    stampConductance(matrix, m, nodes[1], 0, constants[i].outputConductance)
                }
            case .spiAdc:
                // DOUT driven while CS is low, and let go otherwise
                if logicStates[i].inputs & 1 == 0, nodes.count > 3 {
                    stampConductance(matrix, m, nodes[3], 0, constants[i].outputConductance)
                }
            case .analogMux, .analogSelector:
                // the channel the select inputs pick, connected to the common terminal
                if let channel = Logic.channel(element.kind, logicStates[i]), let common = nodes.last, channel < nodes.count {
                    stampConductance(matrix, m, nodes[channel], common, constants[i].onConductance)
                }
            case .atmega328p, .atmega2560, .attiny85, .rp2040:
                // each output pin drives towards the supply or ground through its resistance; a pull-up is a resistor
                // to the supply, a pull-down one to ground; other inputs draw nothing
                guard let states = chipPinStates[i] else { continue }
                let c = constants[i]
                for (pin, state) in states.enumerated() where pin < nodes.count {
                    switch state {
                    case .output: stampConductance(matrix, m, nodes[pin], 0, c.outputConductance)
                    case .input(pullUp: true), .inputPullDown: stampConductance(matrix, m, nodes[pin], 0, c.onConductance)
                    case .input: break
                    }
                }
            default:
                break
            }
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
        case .audioInput:
            return c.offset + c.value * audioSample(i, at: t)
        default:
            return 0
        }
    }

    /// An audio input's sound at circuit time `t`, from −1 to 1: its file (looped or once), or the live input
    private func audioSample(_ i: Int, at t: Double) -> Double {
        if constants[i].high >= 0.5 {
            guard let live = liveInput, !live.samples.isEmpty else { return 0 }
            let position = min(max((t - live.startTime) * live.sampleRate, 0), Double(live.samples.count - 1))
            return Self.interpolate(live.samples, at: position)
        }
        guard let clip = audioClips[i], !clip.samples.isEmpty else { return 0 }
        var position = t * clip.sampleRate
        let length = Double(clip.samples.count)
        if constants[i].duty >= 0.5 {
            position = position.truncatingRemainder(dividingBy: length)
        } else if position >= length - 1 {
            return 0
        }
        return Self.interpolate(clip.samples, at: max(position, 0))
    }

    private static func interpolate(_ samples: [Float], at position: Double) -> Double {
        let k = Int(position)
        let f = position - Double(k)
        let a = Double(samples[min(k, samples.count - 1)])
        let b = Double(samples[min(k + 1, samples.count - 1)])
        return a + (b - a) * f
    }

    /// The next sample of a noise source: Gaussian with unit variance (Box-Muller from two uniform numbers)
    private func nextNoise(_ i: Int) -> Double {
        if constants[i].value >= 0.5 {
            // the MM5837's 17-stage shift register, its last stage fed back with the 14th: a maximal sequence of 131071
            // bits, two of them a sample, each ±1
            var s = noiseState[i] & 0x1FFFF
            if s == 0 { s = 1 }
            for _ in 0..<2 {
                let bit = ((s >> 16) ^ (s >> 13)) & 1
                s = ((s << 1) | bit) & 0x1FFFF
            }
            noiseState[i] = s
            return s & 1 != 0 ? 1 : -1
        }
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
        if rhs.count != m { rhs = [Double](repeating: 0, count: m) }
        rhs.withUnsafeMutableBufferPointer { buffer in
            guard let r = buffer.baseAddress else { return }
            r.update(repeating: 0, count: m)
            fillRightHandSide(r, at: t)
        }
    }

    /// The sources' and reactive parts' terms of the right-hand side, into `r` (zeroed)
    private func fillRightHandSide(_ r: Entries, at t: Double) {
        let lists = nodeLists
        for i in drivenIndices {
            let nodes = lists[i]
            let c = constants[i]
            switch kinds[i] {
            case .dcVoltage, .acVoltage, .squareVoltage, .noiseVoltage, .keyboardPitch, .keyboardGate, .audioInput:
                let row = topology.sourceRow[i]
                if row >= 0 { r[row] = sourceVoltage(i, at: t) }
            case .currentSource:
                stampCurrent(r, nodes[0], nodes[1], c.value)
            case .capacitor:
                // BDF2: i(n+1) = C/h (a0 v(n+1) + a1 v(n) + a2 v(n-1))
                let history = -c.value / h * (a1 * capacitorVoltage[i] + a2 * capacitorVoltagePrevious[i])
                stampCurrent(r, nodes[0], nodes[1], -history)
            case .inductor:
                // BDF2: i(n+1) = h / (a0 L) v(n+1) - (a1 i(n) + a2 i(n-1)) / a0
                let history = -(a1 * inductorCurrent[i] + a2 * inductorCurrentPrevious[i]) / a0
                stampCurrent(r, nodes[0], nodes[1], history)
            case .timer555:
                if digitalState[i] {
                    // high: VCC minus the output stage's drop
                    stampCurrent(r, nodes[2], nodes[7], c.outputConductance * c.highDrop)
                } else {
                    // low: 0.1 V above GND
                    stampCurrent(r, nodes[0], nodes[2], c.outputConductance * 0.1)
                }
            case .schmittInverter:
                if digitalState[i] {
                    stampCurrent(r, 0, nodes[1], c.supply * c.outputConductance)
                }
            case .dac:
                guard nodes.count > 5 else { continue }
                let output = Logic.dacOutput(logicStates[i].count, reference: voltage(nodes[4]), supply: c.supply)
                stampCurrent(r, 0, nodes[5], output * c.outputConductance)
            case .dualDac:
                guard nodes.count > 5 else { continue }
                for channel in 0...1 {
                    let output = Logic.dualDacOutput(logicStates[i].count, channel: channel, supply: c.supply)
                    stampCurrent(r, 0, nodes[4 + channel], output * c.outputConductance)
                }
            case .i2sDac:
                guard nodes.count > 4 else { continue }
                stampCurrent(r, 0, nodes[3], Logic.i2sOutput(Int32(bitPattern: logicStates[i].latch)) * c.outputConductance)
                stampCurrent(r, 0, nodes[4], Logic.i2sOutput(Int32(truncatingIfNeeded: logicStates[i].count)) * c.outputConductance)
            case .i2cDac:
                guard nodes.count > 3 else { continue }
                stampCurrent(r, 0, nodes[3], Logic.i2cDacOutput(logicStates[i].count, supply: c.supply) * c.outputConductance)
            case .spiAdc:
                guard nodes.count > 3, logicStates[i].inputs & 1 == 0, logicStates[i].count != 0 else { continue }
                stampCurrent(r, 0, nodes[3], c.supply * c.outputConductance)
            case .effectsProcessor:
                guard nodes.count > 5, let processor = effectsProcessors[i] else { continue }
                stampCurrent(r, 0, nodes[4], processor.left * c.outputConductance)
                stampCurrent(r, 0, nodes[5], processor.right * c.outputConductance)
            case .logicGate, .flipFlop, .decadeCounter, .binaryCounter, .shiftRegister, .pll:
                let kind = kinds[i]
                for (k, high) in zip(kind.logicOutputs, Logic.outputs(kind, logicStates[i], function: Int(c.value))) where high {
                    stampCurrent(r, 0, nodes[k], c.supply * c.outputConductance)
                }
            case .atmega328p, .atmega2560, .attiny85, .rp2040:
                guard let states = chipPinStates[i] else { continue }
                for (pin, state) in states.enumerated() where pin < nodes.count {
                    switch state {
                    case .output(high: true): stampCurrent(r, 0, nodes[pin], c.supply * c.outputConductance)
                    case .input(pullUp: true): stampCurrent(r, 0, nodes[pin], c.supply * c.onConductance)
                    default: break
                    }
                }
            case .delayLine:
                let row = topology.sourceRow[i]
                if row >= 0 { r[row] = delayedOutput(i) }
            case .digitalDelay:
                stampCurrent(r, 0, nodes[1], Self.echoReference / c.value)
                let row = topology.sourceRow[i]
                if row >= 0 { r[row] = moduleStates[i].output }
            case .comparator, .vco, .vcf, .envelope, .sampleHold, .divider, .levelDetector, .springReverb, .agcPreamp:
                let row = topology.sourceRow[i]
                if row >= 0 { r[row] = moduleStates[i].output }
            case .behavioralSource:
                // a linear one's value at zero inputs
                guard i < behaviors.count, let b = behaviors[i], b.linear, b.offset != 0, b.offset.isFinite else { break }
                if b.voltage {
                    let row = topology.sourceRow[i]
                    if row >= 0 { r[row] += b.offset }
                } else {
                    stampCurrent(r, nodes[0], nodes[1], b.offset)
                }
            default:
                break
            }
        }
    }

    /// A bucket-brigade delay line's output: its input as it was one delay ago, the delay being the stages over twice
    /// the clock, which the control voltage raises or lowers
    private func delayedOutput(_ i: Int) -> Double {
        let c = constants[i]
        if c.duty >= 0.5 { return c.gain * (bucketBrigades[i]?.output ?? 0) }
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

    private func stampMemristors(_ matrix: Entries, _ m: Int) {
        for i in memristorIndices {
            let nodes = topology.elementNodes[i]
            stampConductance(matrix, m, nodes[0], nodes[1], memristorConductance(i, state: memristorStates[i]))
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
        // tubes
        var tube = TubeModel()
        // junction capacitances: zero-bias capacitance, junction potential and grading of a diode's junction or a
        // transistor's base-emitter (0) and base-collector (1) junctions, and the transit time of the charge stored
        // by the forward current
        var cj0 = 0.0, vj0 = 1.0, m0 = 0.5, cj1 = 0.0, vj1 = 0.75, m1 = 0.33, transit = 0.0
        // an op-amp's input noise voltage, V/√Hz
        var noiseDensity = 0.0
        /// an op-amp's middle of its swing (half a single supply)
        var midpoint = 0.0
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
            let l0 = max(p("inductance"), 1e-15)
            c.value = l0
            if element.saturates {
                // a saturating core: the inductor at its saturated inductance (its current, times that, is the flux), with
                // the core's own current on top (see stampSaturation); its inductance unsaturated, and the flux it
                // saturates at
                c.value = l0 * min(max(p("saturatedFraction"), 1e-6), 1)
                c.gain = l0
                c.threshold = l0 * p("saturationCurrent")
            }
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
            c.value = Self.choice(p("type"), 0...1)
        case .audioInput:
            c.value = p("level")
            c.offset = p("offset")
            c.duty = Self.choice(p("loop"), 0...1)
            c.high = Self.choice(p("input"), 0...1)
        case .multiplier:
            c.gain = p("scale")
            c.limit = max(p("limit"), 0.1)
        case .delayLine:
            let stages = p("stages")
            c.value = stages.isFinite ? max(stages, 1) : 1
            c.frequency = max(p("clock"), 1)
            c.slew = p("clockPerVolt")
            c.gain = p("gain")
            c.duty = Self.choice(p("clocking"), 0...1)
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
            c.duty = Self.choice(p("response"), 0...1)
            c.gain = max(p("hzPerVolt"), 0)
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
            c.offset = p("cvOffset")
        case .agcPreamp:
            c.gain = max(p("gain"), 0)
            c.value = max(p("ratio"), 1)
            c.threshold = max(p("rotation"), 1e-6)
            c.low = max(p("gate"), 1e-9)
            c.tau = max(p("averaging"), 1e-6)
            c.limit = max(p("limit"), 0.01)
        case .levelDetector:
            c.value = Self.choice(p("mode"), 0...3)
            c.tau = max(p("attack"), 0)
            c.voff = max(p("release"), 0)
            c.gain = p("scale")
            c.threshold = max(p("reference"), 1e-9)
        case .springReverb:
            c.value = max(p("decay"), 0.05)
            c.tau = min(max(p("delay"), 0.002), 0.2)
            c.gain = p("gain")
            c.onConductance = 1 / max(p("inputResistance"), 0.1)
            c.duty = min(max(p("dispersion"), 0), 0.95)
        case .vuMeter:
            c.value = Self.choice(p("mode"), 0...1)
            c.threshold = max(p("reference"), 1e-9)
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
        case .triode, .pentode:
            c.tube = TubeModel(mu: p("mu"), ex: p("ex"), kg1: p("kg1"), kg2: p("kg2"), kp: p("kp"), kvb: p("kvb"), rgi: p("rgi"))
        case .transformer:
            c.value = p("ratio")
        case .opAmp:
            c.offset = p("offset")
            c.gain = max(p("gain"), 1)
            c.limit = max(p("limit"), 0.01)
            c.gbw = p("gbw")
            c.slew = p("slewRate") * 1e6
            c.noiseDensity = max(p("noise"), 0)
            c.midpoint = p("midpoint")
        case .ota:
            // the bias input: one or two junctions down to the negative supply, 1 mA at 0.6 V per junction
            let drops = min(max(p("biasDrop").rounded(), 1), 2)
            c.supply = p("supply")
            c.nvt = drops * vt
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
        case .logicGate, .flipFlop, .decadeCounter, .binaryCounter, .shiftRegister, .analogMux, .analogSelector, .pll, .dac, .dualDac, .spiAdc, .i2cDac, .i2sDac:
            c.supply = max(p("supply"), 0.1)
            c.upper = p("upper") * c.supply
            c.lower = min(p("lower"), p("upper")) * c.supply
            c.outputConductance = 1 / max(p("outputResistance"), 0.1)
            c.onConductance = 1 / max(p("onResistance"), 1e-3)
            c.value = Self.choice(p("function"), 0...Double(Logic.gateFunctions.count - 1))
            if element.kind == .shiftRegister { c.value = Self.choice(p("type"), 0...1) }
            c.frequency = max(p("fMin"), 0)
            c.high = max(p("fMax"), c.frequency)
        case .effectsProcessor:
            c.value = Self.choice(p("program"), 0...7)
            c.supply = max(p("supply"), 0.1)
            c.outputConductance = 1 / 100
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

    /// Sets the temperature the parts work at (°C): their thermal voltage, and with it their saturation currents
    private func setTemperature(_ celsius: Double) {
        kelvin = min(max(celsius, -200), 500) + 273.15
        vt = Self.thermalVoltage * kelvin / Self.nominalKelvin
    }

    /// A junction's saturation current at the circuit's temperature, from its value at the nominal temperature, as
    /// SPICE scales it: Is · (T/Tnom)^(XTI/n) · exp((T/Tnom − 1) Eg / (n Vt)), with silicon's band gap (1.11 eV) and
    /// XTI 3
    func atTemperature(_ saturation: Double, emission n: Double) -> Double {
        let ratio = kelvin / Self.nominalKelvin
        guard ratio != 1 else { return saturation }
        return saturation * exp((ratio - 1) * 1.11 / (n * vt)) * pow(ratio, 3 / n)
    }

    /// The charge on a junction's depletion capacitance at voltage `v`, and the capacitance (SPICE's: graded as
    /// (1 − v/vj)^−m up to half the junction potential, then continued in a straight line)
    static func depletion(_ v: Double, cj: Double, vj: Double, m: Double) -> (charge: Double, capacitance: Double) {
        guard cj > 0 else { return (0, 0) }
        let fc = 0.5
        if v < fc * vj {
            let s = pow(1 - v / vj, -m)
            return (cj * vj / (1 - m) * (1 - (1 - v / vj) * s), cj * s)
        }
        let f1 = vj / (1 - m) * (1 - pow(1 - fc, 1 - m))
        let f2 = pow(1 - fc, 1 + m)
        let f3 = 1 - fc * (1 + m)
        let vf = fc * vj
        return (cj * f1 + cj / f2 * (f3 * (v - vf) + m / (2 * vj) * (v * v - vf * vf)), cj / f2 * (f3 + m * v / vj))
    }

    /// Whether a part stores charge that changes with its voltages: a junction's depletion charge or its stored charge
    private func storesCharge(_ i: Int) -> Bool {
        if kinds[i].isBipolar { return bipolar[i].hasCharges }
        if kinds[i].isDiode { return diodes[i].hasCharges }
        if kinds[i].isJFET { return jfets[i].hasCharges }
        if kinds[i].isMOSFET { return mosfets[i].hasCharges }
        return constants[i].cj0 > 0 || constants[i].cj1 > 0 || constants[i].transit > 0
    }

    /// A bipolar transistor's terminals, and where its junctions are: the internal nodes behind its resistances (after
    /// its terminals in its nodes), or the terminals themselves
    struct BipolarNodes {
        let b, c, e, bp, cp, ep: Int
    }

    @inline(__always) static func bipolarNodes(_ node: (Int) -> Int, _ g: GummelPoon) -> BipolarNodes {
        var next = 3
        func inner(_ present: Bool, _ terminal: Int) -> Int {
            guard present else { return node(terminal) }
            next += 1
            return node(next - 1)
        }
        let bp = inner(g.hasBaseNode, 0), cp = inner(g.hasCollectorNode, 1), ep = inner(g.hasEmitterNode, 2)
        return BipolarNodes(b: node(0), c: node(1), e: node(2), bp: bp, cp: cp, ep: ep)
    }

    /// A JFET's terminals, and where its channel ends: the internal drain and source behind its resistances (after its
    /// three terminals, in that order), or the terminals themselves
    struct JFETNodes {
        let g, d, s, dp, sp: Int
    }

    @inline(__always) static func jfetNodes(_ node: (Int) -> Int, _ j: SpiceJFET) -> JFETNodes {
        fetNodes(node, drain: j.hasDrainNode, source: j.hasSourceNode)
    }

    /// A field-effect transistor's terminals (gate, drain, source) and its internal drain and source, if it has them
    @inline(__always) static func fetNodes(_ node: (Int) -> Int, drain: Bool, source: Bool) -> JFETNodes {
        var next = 3
        func inner(_ present: Bool, _ terminal: Int) -> Int {
            guard present else { return node(terminal) }
            next += 1
            return node(next - 1)
        }
        let dp = inner(drain, 1), sp = inner(source, 2)
        return JFETNodes(g: node(0), d: node(1), s: node(2), dp: dp, sp: sp)
    }

    /// The charge a junction holds at voltage `v` (in the part's own polarity) and its slope: depletion charge, plus
    /// the charge its forward current stores over the transit time
    private func junctionChargeAndCapacitance(_ i: Int, slot: Int, _ v: Double) -> (charge: Double, capacitance: Double) {
        if kinds[i].isDiode {
            let d = diodes[i]
            return d.charge(v, current: d.current(v, gmin: Self.junctionGmin))
        }
        let c = constants[i]
        var (q, cap) = slot == 0 ? Self.depletion(v, cj: c.cj0, vj: c.vj0, m: c.m0) : Self.depletion(v, cj: c.cj1, vj: c.vj1, m: c.m1)
        if slot == 0 && c.transit > 0 {
            let forward = diodeCurrent(v, saturation: c.saturation, nvt: c.nvt)
            q += c.transit * forward.current
            cap += c.transit * forward.conductance
        }
        return (q, cap)
    }

    /// Stamps the charging of a junction's charge (slot `slot` of part `i`) over the substep, linearised at junction
    /// voltage `v` (in the part's polarity `p`), from `plus` to `minus`
    private func stampJunctionCharge(_ matrix: Entries, _ rhs: Entries, _ m: Int, _ i: Int, slot: Int,
                                     _ plus: Int, _ minus: Int, polarity p: Double, _ v: Double) {
        guard !linearising else { return }
        let (q, cap) = junctionChargeAndCapacitance(i, slot: slot, v)
        guard cap > 0 || q != 0 else { return }
        let k = Self.chargeSlots * i + slot
        let current = (a0 * q + a1 * junctionCharge[k] + a2 * junctionChargePrevious[k]) / h
        let g = a0 * cap / h
        stampConductance(matrix, m, plus, minus, g)
        stampCurrent(rhs, plus, minus, p * (current - g * v))
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

    /// A field-effect transistor's gate voltage limited as SPICE limits it (DEVfetlim): steps that would carry it far
    /// past the threshold `vto` in one iteration are cut back
    private func limitFET(_ new: Double, old: Double, vto: Double) -> Double {
        var vnew = new
        let vtsthi = abs(2 * (old - vto)) + 2
        let vtstlo = abs(old - vto) + 1
        let vtox = vto + 3.5
        let delv = new - old
        if old >= vto {
            if old >= vtox {
                if delv <= 0 {
                    // going off
                    if vnew >= vtox {
                        if -delv > vtstlo { vnew = old - vtstlo }
                    } else {
                        vnew = max(vnew, vto + 2)
                    }
                } else if delv >= vtsthi {
                    // staying on
                    vnew = old + vtsthi
                }
            } else {
                // the middle region
                vnew = delv <= 0 ? max(vnew, vto - 0.5) : min(vnew, vto + 4)
            }
        } else if delv <= 0 {
            // off
            if -delv > vtsthi { vnew = old - vtsthi }
        } else {
            let vtemp = vto + 0.5
            if vnew <= vtemp {
                if delv > vtstlo { vnew = old + vtstlo }
            } else {
                vnew = vtemp
            }
        }
        if vnew != new { limiting = true }
        return vnew
    }

    /// A MOSFET's drain voltage limited as SPICE limits it (DEVlimvds)
    private func limitVDS(_ new: Double, old: Double) -> Double {
        var vnew = new
        if old >= 3.5 {
            vnew = new > old ? min(new, 3 * old + 2) : (new < 3.5 ? max(new, 2) : new)
        } else {
            vnew = new > old ? min(new, 4) : max(new, -0.5)
        }
        if vnew != new { limiting = true }
        return vnew
    }

    /// Current and conductance of a junction, with a tiny leak in parallel. The current must include the leak whenever the
    /// conductance does: if they disagree, Newton-Raphson only creeps towards the solution.
    func diodeCurrent(_ vd: Double, saturation: Double, nvt: Double) -> (current: Double, conductance: Double) {
        let e = exp(min(vd / nvt, 700))
        return (saturation * (e - 1) + Self.gmin * vd, saturation * e / nvt + Self.gmin)
    }

    /// Level-1 (Shichman-Hodges) MOSFET for positive vgs/vds: drain current and its derivatives. A 1 nS leak from drain
    /// to source keeps a switched-off transistor's drain from floating; it is in the current as well as in its slope.
    func mosfetCurrent(vgs: Double, vds: Double, threshold: Double, beta: Double, lambda: Double = 0.01)
        -> (id: Double, gm: Double, gds: Double) {
        let leak = 1e-9
        let overdrive = vgs - threshold
        if overdrive <= 0 { return (leak * vds, 0, leak) }
        if vds < overdrive {
            // channel-length modulation here too, as in SPICE's level 1, so the current runs on smoothly into saturation
            let modulation = 1 + lambda * vds
            let base = overdrive * vds - vds * vds / 2
            return (beta * base * modulation + leak * vds, beta * vds * modulation,
                    beta * (overdrive - vds) * modulation + beta * base * lambda + leak)
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
        // the output swings `limit` either side of its midpoint (0, or half a single supply)
        let mid = c.midpoint
        guard gbw > 0 else {
            let t = tanh((gain * vd - mid) / limit)
            return (mid + limit * t, gain * (1 - t * t), mid + limit * t)
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
        let t = tanh((stage - mid) / limit)
        return (mid + limit * t, (1 - t * t) * driveSlope / denominator, stage)
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

    /// A bipolar transistor's junctions, linearised at the present solution (limited as SPICE limits them): the
    /// Gummel-Poon currents into its internal collector, base and emitter, and the charging of its stored charges, each
    /// linear in the internal base-emitter and base-collector voltages and the external base to internal collector
    /// voltage; and a base resistance that falls with the base current
    private func stampBipolar(_ i: Int, _ nodes: NodeList, _ matrix: Entries, _ rhs: Entries, _ m: Int) {
        let p: Double = kinds[i] == .npn ? 1 : -1
        let g = bipolar[i]
        let n = Self.bipolarNodes({ nodes[$0] }, g)
        // in the transistor's own polarity
        let vbe = limitJunction(p * (voltage(n.bp) - voltage(n.ep)), old: limitedVoltage[i], nvt: vt, critical: g.critical)
        let vbc = limitJunction(p * (voltage(n.bp) - voltage(n.cp)), old: limitedVoltage2[i], nvt: vt, critical: g.critical)
        limitedVoltage[i] = vbe
        limitedVoltage2[i] = vbc
        let vbx = p * (voltage(n.b) - voltage(n.cp))
        let r = g.currents(vbe: vbe, vbc: vbc, gmin: Self.junctionGmin)
        // currents into the internal collector, base and emitter and the external base, with their slopes in vbe, vbc, vbx
        typealias Flow = (i: Double, be: Double, bc: Double, bx: Double)
        var cp: Flow = (r.cc, r.gm + r.go, -r.go - r.gmu, 0)
        var bp: Flow = (r.cb, r.gpi, r.gmu, 0)
        var ep: Flow = (-r.cc - r.cb, -(r.gm + r.go) - r.gpi, r.go, 0)
        var bx: Flow = (0, 0, 0, 0)
        if junctionConductance > 0 {
            // gmin stepping's shunts across both junctions
            let gs = junctionConductance
            bp.i += gs * (vbe + vbc)
            bp.be += gs
            bp.bc += gs
            cp.i -= gs * vbc
            cp.bc -= gs
            ep.i -= gs * vbe
            ep.be -= gs
        }
        let charged = g.hasCharges && !linearising
        if charged {
            let q = g.charges(vbe: vbe, vbc: vbc, vbx: vbx, r)
            let k = Self.chargeSlots * i
            func flow(_ slot: Int, _ charge: Double) -> Double {
                (a0 * charge + a1 * junctionCharge[k + slot] + a2 * junctionChargePrevious[k + slot]) / h
            }
            let s = a0 / h
            // base-emitter: b' to e', moving with vbc too
            let be = flow(0, q.qbe)
            bp.i += be
            bp.be += s * q.capbe
            bp.bc += s * q.dqbeVbc
            ep.i -= be
            ep.be -= s * q.capbe
            ep.bc -= s * q.dqbeVbc
            // base-collector at the internal base: b' to c'
            let bc = flow(1, q.qbc)
            bp.i += bc
            bp.bc += s * q.capbc
            cp.i -= bc
            cp.bc -= s * q.capbc
            // and at the external base: b to c'
            let xc = flow(2, q.qbx)
            bx.i += xc
            bx.bx += s * q.capbx
            cp.i -= xc
            cp.bx -= s * q.capbx
        }
        // currents and voltages flip sign for a PNP, slopes do not
        func stampTerminal(_ node: Int, _ t: Flow) {
            guard node > 0 else { return }
            let row = node - 1
            add(matrix, m, row, n.bp - 1, t.be + t.bc)
            add(matrix, m, row, n.ep - 1, -t.be)
            add(matrix, m, row, n.cp - 1, -t.bc - t.bx)
            add(matrix, m, row, n.b - 1, t.bx)
            rhs[row] -= p * t.i - t.be * p * vbe - t.bc * p * vbc - t.bx * p * vbx
        }
        stampTerminal(n.cp, cp)
        stampTerminal(n.bp, bp)
        stampTerminal(n.ep, ep)
        if charged && g.cjcOuter > 0 { stampTerminal(n.b, bx) }
        if g.baseModulated { stampConductance(matrix, m, n.b, n.bp, r.gx) }
    }

    /// A MOSFET's voltages in its own polarity (gate, internal drain and bulk to internal source) at the present
    /// solution, limited as ngspice limits them from the last iteration's
    private func mosfetVoltages(_ i: Int, _ n: JFETNodes) -> (vgs: Double, vds: Double, vbs: Double) {
        let f = mosfets[i]
        let t = f.type
        var vgs = t * (voltage(n.g) - voltage(n.sp)), vds = t * (voltage(n.dp) - voltage(n.sp))
        var vbs = t * (voltage(n.s) - voltage(n.sp))
        let (oldGS, oldDS, oldBS) = (limitedVoltage[i], limitedVoltage2[i], limitedVoltage3[i])
        var vgd = vgs - vds
        let von = f.von(bulk: oldDS >= 0 ? oldBS : oldBS - oldDS)
        if oldDS >= 0 {
            vgs = limitFET(vgs, old: oldGS, vto: von)
            vds = limitVDS(vgs - vgd, old: oldDS)
            vgd = vgs - vds
        } else {
            vgd = limitFET(vgd, old: oldGS - oldDS, vto: von)
            vds = -limitVDS(-(vgs - vgd), old: -oldDS)
            vgs = vgd + vds
        }
        if vds >= 0 {
            vbs = limitJunction(vbs, old: oldBS, nvt: f.vt, critical: f.critical)
        } else {
            vbs = limitJunction(vbs - vds, old: oldBS - oldDS, nvt: f.vt, critical: f.critical) + vds
        }
        return (vgs, vds, vbs)
    }

    /// A MOSFET's charges, by slot (bulk-drain, bulk-source, gate-source, gate-drain, gate-bulk), at `vgs`, `vds` and
    /// `vbs`: the bulk junctions' depletion charges, and Meyer's gate charges carried on from the last solution with the
    /// capacitance averaged over the step (as ngspice does); and the capacitances
    private func mosfetCharges(_ i: Int, vgs: Double, vds: Double, vbs: Double, _ r: SpiceMOSFET.Currents)
        -> (q: (Double, Double, Double, Double, Double), cap: (Double, Double, Double, Double, Double)) {
        let f = mosfets[i]
        let vgd = vgs - vds, vgb = vgs - vbs
        let bulk = f.bulkCharges(vbd: vbs - vds, vbs: vbs)
        let half = f.meyer(vgs: vgs, vgd: vgd, r)
        let last = meyerHistory[i]
        let k = Self.chargeSlots * i
        let capgs = half.gs + last.gs + f.cgso, capgd = half.gd + last.gd + f.cgdo, capgb = half.gb + last.gb + f.cgbo
        let q = (bulk.qbd, bulk.qbs, junctionCharge[k + 2] + capgs * (vgs - last.vgs),
                 junctionCharge[k + 3] + capgd * (vgd - last.vgd), junctionCharge[k + 4] + capgb * (vgb - last.vgb))
        return (q, (bulk.capbd, bulk.capbs, capgs, capgd, capgb))
    }

    /// A MOSFET's bulk junctions and channel (ngspice's mos1load.c), linearised at the present solution, and the charging
    /// of its bulk and gate charges. Its bulk is its source terminal, outside the source resistance.
    private func stampMOSFET(_ i: Int, _ nodes: NodeList, _ matrix: Entries, _ rhs: Entries, _ m: Int) {
        let f = mosfets[i]
        let t = f.type
        let n = Self.fetNodes({ nodes[$0] }, drain: f.hasDrainNode, source: f.hasSourceNode)
        let (vgs, vds, vbs) = mosfetVoltages(i, n)
        limitedVoltage[i] = vgs
        limitedVoltage2[i] = vds
        limitedVoltage3[i] = vbs
        let vbd = vbs - vds, vgd = vgs - vds, vgb = vgs - vbs
        let r = f.currents(vgs: vgs, vds: vds, vbs: vbs, gmin: Self.junctionGmin)
        // gmin stepping's shunts across the bulk junctions
        var (cbs, gbs) = (r.cbs + junctionConductance * vbs, r.gbs + junctionConductance)
        var (cbd, gbd) = (r.cbd + junctionConductance * vbd, r.gbd + junctionConductance)
        var (gcgs, gcgd, gcgb, ceqgs, ceqgd, ceqgb) = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        if f.hasCharges && !linearising {
            let (q, cap) = mosfetCharges(i, vgs: vgs, vds: vds, vbs: vbs, r)
            let k = Self.chargeSlots * i
            func flow(_ slot: Int, _ charge: Double) -> Double {
                (a0 * charge + a1 * junctionCharge[k + slot] + a2 * junctionChargePrevious[k + slot]) / h
            }
            cbd += flow(0, q.0)
            gbd += a0 * cap.0 / h
            cbs += flow(1, q.1)
            gbs += a0 * cap.1 / h
            (gcgs, gcgd, gcgb) = (a0 * cap.2 / h, a0 * cap.3 / h, a0 * cap.4 / h)
            ceqgs = flow(2, q.2) - gcgs * vgs
            ceqgd = flow(3, q.3) - gcgd * vgd
            ceqgb = flow(4, q.4) - gcgb * vgb
        }
        let (gm, gds, gmbs) = (r.gm, r.gds, r.gmbs)
        let (xnrm, xrev): (Double, Double) = r.mode > 0 ? (1, 0) : (0, 1)
        let ceqbs = t * (cbs - gbs * vbs), ceqbd = t * (cbd - gbd * vbd)
        let cdreq = r.mode > 0 ? t * (r.cdrain - gds * vds - gm * vgs - gmbs * vbs)
                               : -t * (r.cdrain + gds * vds - gm * vgd - gmbs * vbd)
        func inject(_ node: Int, _ value: Double) { if node > 0 { rhs[node - 1] += value } }
        inject(n.g, -t * (ceqgs + ceqgb + ceqgd))
        inject(n.s, -(ceqbs + ceqbd - t * ceqgb))
        inject(n.dp, ceqbd - cdreq + t * ceqgd)
        inject(n.sp, cdreq + ceqbs + t * ceqgs)
        let g = n.g - 1, b = n.s - 1, dp = n.dp - 1, sp = n.sp - 1
        add(matrix, m, g, g, gcgd + gcgs + gcgb)
        add(matrix, m, b, b, gbd + gbs + gcgb)
        add(matrix, m, dp, dp, gds + gbd + xrev * (gm + gmbs) + gcgd)
        add(matrix, m, sp, sp, gds + gbs + xnrm * (gm + gmbs) + gcgs)
        add(matrix, m, g, b, -gcgb)
        add(matrix, m, g, dp, -gcgd)
        add(matrix, m, g, sp, -gcgs)
        add(matrix, m, b, g, -gcgb)
        add(matrix, m, b, dp, -gbd)
        add(matrix, m, b, sp, -gbs)
        add(matrix, m, dp, g, (xnrm - xrev) * gm - gcgd)
        add(matrix, m, dp, b, -gbd + (xnrm - xrev) * gmbs)
        add(matrix, m, dp, sp, -gds - xnrm * (gm + gmbs))
        add(matrix, m, sp, g, -(xnrm - xrev) * gm - gcgs)
        add(matrix, m, sp, b, -gbs - (xnrm - xrev) * gmbs)
        add(matrix, m, sp, dp, -gds - xrev * (gm + gmbs))
        // and a shunt from drain to source while gmin stepping
        stampConductance(matrix, m, n.dp, n.sp, junctionConductance)
    }

    /// A JFET's gate junctions and channel (between its internal drain and source), linearised at the present solution
    /// with SPICE's limiting, and the charging of its gate charges
    private func stampJFET(_ i: Int, _ nodes: NodeList, _ matrix: Entries, _ rhs: Entries, _ m: Int) {
        let j = jfets[i]
        let p = j.polarity
        let n = Self.jfetNodes({ nodes[$0] }, j)
        // in the transistor's own polarity
        var vgs = p * (voltage(n.g) - voltage(n.sp))
        var vgd = p * (voltage(n.g) - voltage(n.dp))
        vgs = limitJunction(vgs, old: limitedVoltage[i], nvt: j.vt, critical: j.critical)
        vgd = limitJunction(vgd, old: limitedVoltage2[i], nvt: j.vt, critical: j.critical)
        vgs = limitFET(vgs, old: limitedVoltage[i], vto: j.threshold)
        vgd = limitFET(vgd, old: limitedVoltage2[i], vto: j.threshold)
        limitedVoltage[i] = vgs
        limitedVoltage2[i] = vgd
        let vds = vgs - vgd
        let r = j.currents(vgs: vgs, vgd: vgd, gmin: Self.junctionGmin)
        // the gate-source and gate-drain branches, with gmin stepping's shunts across them
        var (cgs, ggs) = (r.cg - r.cgd + junctionConductance * vgs, r.ggs + junctionConductance)
        var (cgd, ggd) = (r.cgd + junctionConductance * vgd, r.ggd + junctionConductance)
        if j.hasCharges && !linearising {
            let q = j.charges(vgs: vgs, vgd: vgd)
            let k = Self.chargeSlots * i
            cgs += (a0 * q.qgs + a1 * junctionCharge[k] + a2 * junctionChargePrevious[k]) / h
            ggs += a0 * q.capgs / h
            cgd += (a0 * q.qgd + a1 * junctionCharge[k + 1] + a2 * junctionChargePrevious[k + 1]) / h
            ggd += a0 * q.capgd / h
        }
        stampConductance(matrix, m, n.g, n.sp, ggs)
        stampCurrent(rhs, n.g, n.sp, p * (cgs - ggs * vgs))
        stampConductance(matrix, m, n.g, n.dp, ggd)
        stampCurrent(rhs, n.g, n.dp, p * (cgd - ggd * vgd))
        // the channel, internal drain to internal source: cdrain(vgs, vds)
        let (gm, gds) = (r.gm, r.gds)
        let d = n.dp - 1, s = n.sp - 1, g = n.g - 1
        add(matrix, m, d, d, gds)
        add(matrix, m, d, s, -gds - gm)
        add(matrix, m, d, g, gm)
        add(matrix, m, s, d, -gds)
        add(matrix, m, s, s, gds + gm)
        add(matrix, m, s, g, -gm)
        stampCurrent(rhs, n.dp, n.sp, p * (r.cdrain - gds * vds - gm * vgs))
    }

    /// The current a saturating core adds to its inductor at saturated inductance Lsat, as a function of the flux λ:
    /// together i(λ) = λ / Lsat − (1/Lsat − 1/L0) λsat tanh(λ / λsat), so the inductance is L0 while the flux is small
    /// and falls to Lsat past λsat; and its slope in the flux
    func coreCurrent(_ i: Int, flux: Double) -> (current: Double, slope: Double) {
        let c = constants[i]
        let (lsat, l0, saturation) = (c.value, c.gain, max(c.threshold, 1e-30))
        let t = tanh(flux / saturation)
        let k = 1 / lsat - 1 / l0
        return (-k * saturation * t, -k * (1 - t * t))
    }

    /// A saturating inductor's core, linearised at the present solution: its flux is the inductor's (at saturated
    /// inductance) current times Lsat, which this substep's voltage sets through BDF2
    private func stampSaturation(_ i: Int, _ nodes: NodeList, _ matrix: Entries, _ rhs: Entries, _ m: Int) {
        // (small-signal analysis takes the whole inductor's inductance at the operating point instead)
        guard !linearising, i < constants.count else { return }
        let lsat = constants[i].value
        let v = voltage(nodes[0]) - voltage(nodes[1])
        let g = h / (a0 * lsat)
        let current = g * v - (a1 * inductorCurrent[i] + a2 * inductorCurrentPrevious[i]) / a0
        let core = coreCurrent(i, flux: lsat * current)
        // d(core current)/dv = d/dflux × lsat × g
        let conductance = core.slope * lsat * g
        stampConductance(matrix, m, nodes[0], nodes[1], conductance)
        stampCurrent(rhs, nodes[0], nodes[1], core.current - conductance * v)
    }

    /// Reads each behavioural source's expression, and finds what its inputs read: a voltage between its own pins (in1 …
    /// in8, + and −, or 0 for ground), or the current through a voltage source by name, looked for first beside the source
    /// (in the same block) and then anywhere
    private func compileBehaviors() {
        behaviors = Array(repeating: nil, count: kinds.count)
        behaviorProblems = []
        var widest = 0
        var longest = 0
        for (i, element) in flat.elements.enumerated() where element.kind == .behavioralSource {
            let name = element.name.isEmpty ? "B" : element.name
            // (without an expression it is 0, so a voltage it sets still has its equation)
            let text = element.code ?? ""
            var expression = SpiceExpression(root: .constant(0), inputs: [])
            var program: SpiceExpression.Program?
            if let compiled = compiledExpressions[text] {
                expression = compiled.expression
                program = compiled.program
            } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                do {
                    expression = try SpiceExpression(parsing: text)
                    let made = SpiceExpression.Program(expression)
                    compiledExpressions[text] = (expression, made)
                    program = made
                } catch {
                    behaviorProblems.append("\(name): can't read its expression \(text): \(error)")
                }
            }
            let nodes = topology.elementNodes[i]
            let pins = element.terminalNames
            func node(_ pin: String) -> Int? {
                let lower = pin.lowercased()
                if Topology.isGroundName(lower) { return 0 }
                guard let k = pins.firstIndex(where: { $0.lowercased() == lower }), k < nodes.count else { return nil }
                return nodes[k]
            }
            let scope = element.name.contains(".") ? String(element.name[...element.name.lastIndex(of: ".")!]) : ""
            var inputs: [BehaviorInput] = []
            for input in expression.inputs {
                switch input {
                case let .voltage(a, b):
                    let minus: Int? = b.map { node($0) } ?? 0
                    guard let plus = node(a), let minus else {
                        behaviorProblems.append("\(name): its expression reads \(a)\(b.map { "," + $0 } ?? ""), not one of its pins")
                        inputs.append(BehaviorInput())
                        continue
                    }
                    inputs.append(BehaviorInput(plus: plus, minus: minus))
                case let .current(source):
                    let wanted = [scope + source, source].map { $0.lowercased() }
                    let found = wanted.lazy.compactMap { w in
                        self.flat.elements.indices.first { self.flat.elements[$0].name.lowercased() == w && self.topology.sourceRow[$0] >= 0 }
                    }.first
                    guard let j = found else {
                        behaviorProblems.append("\(name): no voltage source \(source) for its expression to read the current of")
                        inputs.append(BehaviorInput())
                        continue
                    }
                    // a source's row holds the current it delivers from its + terminal; SPICE's I( ) is into it
                    inputs.append(BehaviorInput(row: topology.sourceRow[j], sign: -1))
                }
            }
            widest = max(widest, inputs.count)
            let behavior = Behavior(expression: expression, program: program ?? SpiceExpression.Program(expression), inputs: inputs,
                                    voltage: element[param: "mode"] >= 0.5)
            longest = max(longest, behavior.program.count)
            if Self.linearAffineSources && expression.isAffine {
                let zeros = [Double](repeating: 0, count: max(inputs.count, 1))
                behavior.linear = true
                behavior.offset = zeros.withUnsafeBufferPointer { expression.value($0.baseAddress!, time: 0, celsius: kelvin - 273.15) }
            }
            behavior.decides = expression.decides
            behaviors[i] = behavior
        }
        if widest > behaviorInputRoom {
            behaviorValues.deallocate()
            behaviorDecisions.deallocate()
            behaviorInputRoom = widest
            behaviorValues = .allocate(capacity: widest)
            behaviorDecisions = .allocate(capacity: widest)
        }
        behaviorValues.initialize(repeating: 0, count: behaviorInputRoom)
        behaviorDecisions.initialize(repeating: 0, count: behaviorInputRoom)
        if longest > behaviorRegisterRoom {
            behaviorRegisters.deallocate()
            behaviorRates.deallocate()
            behaviorRegisterRoom = longest
            behaviorRegisters = .allocate(capacity: longest)
            behaviorRates = .allocate(capacity: longest)
        }
        behaviorRegisters.initialize(repeating: 0, count: behaviorRegisterRoom)
        behaviorRates.initialize(repeating: 0, count: behaviorRegisterRoom)
    }

    /// A behavioural source, linearised at the present solution with its expression's exact slopes: a voltage across + and
    /// − (its own row: v(+) − v(−) = f), or a current from + to − through it
    private func stampBehavior(_ i: Int, _ nodes: NodeList, _ matrix: Entries, _ rhs: Entries, _ m: Int) {
        guard i < behaviors.count, let b = behaviors[i] else { return }
        let count = b.inputCount
        let inputs = b.inputList
        let holds = b.decides && decisionX.count == x.count
        let v = behaviorValues, d = behaviorDecisions, r = behaviorRegisters
        for k in 0..<count {
            let input = inputs[k]
            v[k] = input.row >= 0 ? (input.row < x.count ? input.sign * x[input.row] : 0)
                : voltage(input.plus) - voltage(input.minus)
            if holds { d[k] = decisionInput(input) }
        }
        let celsius = kelvin - 273.15
        let plus = nodes[0] - 1, minus = nodes[1] - 1
        let last = b.lastInputs, lastDecisions = b.lastDecisions, lastSlopes = b.lastSlopes
        // bypass, as SPICE bypasses a device whose voltages have not moved: inputs within a billionth of the last
        // evaluation's give the same stamp again, its value and slopes as they were (the difference is far below what
        // Newton-Raphson resolves, being second order in so small a change). And a source made of straight lines
        // between its decisions (a LIMIT, IF or TABLE of its inputs, as a maker's model's are) whose inputs, and those
        // its decisions are made at, have moved less than half its reach from the last evaluation's: no decision in it
        // can have changed, so its value has moved along its slopes and its stamp is exactly the one it made.
        var bypass = false
        if Self.bypassesDevices && b.evaluated && b.lastCelsius == celsius && !b.program.readsTime {
            // (a deciding source's value moves with where its decisions are held, which the first test does not see)
            var near = !b.decides
            var furthest = 0.0, finite = true
            for k in 0..<count {
                let change = abs(v[k] - last[k])
                if change > furthest { furthest = change } else if change.isNaN { finite = false }
                if !(change <= Self.bypassTolerance * (1 + abs(v[k]))) { near = false }
            }
            if b.decides {
                for k in 0..<count {
                    let change = abs((holds ? d[k] : v[k]) - lastDecisions[k])
                    if change > furthest { furthest = change } else if change.isNaN { finite = false }
                }
            }
            if near {
                bypass = true
            } else if finite && furthest <= 0.5 * b.reach {
                bypass = true
                straightBypasses += 1
            }
        }
        if bypass {
            bypassedEvaluations += 1
            for k in 0..<count { v[k] = last[k] }
        } else {
            // the value and every slope in one run of the compiled expression
            let program = b.program
            program.run(v, deciding: holds ? d : nil, time: solveTime, celsius: celsius, into: r)
            let slopes = program.slopeSteps
            for k in 0..<count {
                last[k] = v[k]
                lastDecisions[k] = holds ? d[k] : v[k]
                lastSlopes[k] = r[slopes[k]]
            }
            b.lastValue = r[program.value]
            b.lastCelsius = celsius
            b.reach = Self.bypassesDevices && program.piecewiseLinear ? program.straightReach(r, rates: behaviorRates) : 0
            b.evaluated = true
            b.evaluations += 1
        }
        var equivalent = b.lastValue
        let row = topology.sourceRow[i]
        let voltageSource = b.voltage
        // Newton-Raphson's stamps go straight to the plan's slots, worked out once for each plan, rather than through
        // the slot map (as large as the matrix is dense) for every entry: the same additions in the same order
        let cached = sparseStamping && stampFloor > 0 && slotsUsable(b, row, plus, minus, m)
        let slots = b.slots
        let recording = recordingStamps, flags = stampedFlags
        func entry(_ j: Int, _ r: Int, _ c: Int, _ value: Double) {
            guard cached else {
                add(matrix, m, r, c, value)
                return
            }
            let slot = Int(slots[j])
            guard slot >= 0 else { return }
            matrix[slot] += value
            if recording, let flags, !flags[slot] { noteStampedSlot(slot) }
        }
        for k in 0..<count {
            let slope = lastSlopes[k]
            guard slope != 0 && slope.isFinite else { continue }
            equivalent -= slope * v[k]
            let input = inputs[k]
            let j = 4 * k
            if voltageSource {
                guard row >= 0 else { continue }
                if input.row >= 0 {
                    entry(j, row, input.row, -slope * input.sign)
                } else {
                    entry(j, row, input.plus - 1, -slope)
                    entry(j + 1, row, input.minus - 1, slope)
                }
            } else if input.row >= 0 {
                entry(j, plus, input.row, slope * input.sign)
                entry(j + 1, minus, input.row, -slope * input.sign)
            } else {
                entry(j, plus, input.plus - 1, slope)
                entry(j + 1, plus, input.minus - 1, -slope)
                entry(j + 2, minus, input.plus - 1, -slope)
                entry(j + 3, minus, input.minus - 1, slope)
            }
        }
        if voltageSource {
            guard row >= 0 else { return }
            // as a voltage source's: its current leaves + and returns at −, and v(+) − v(−) is the expression
            let own = 4 * count
            entry(own, plus, row, -1)
            entry(own + 1, minus, row, 1)
            entry(own + 2, row, plus, 1)
            entry(own + 3, row, minus, -1)
            if equivalent.isFinite { rhs[row] += equivalent }
        } else if equivalent.isFinite {
            stampCurrent(rhs, nodes[0], nodes[1], equivalent)
        }
    }

    /// Whether a behavioural source's slots (see `Behavior.slots`) serve the present plan, working them out from the
    /// slot map if they are for another: in the order and positions `stampBehavior` stamps them
    private func slotsUsable(_ b: Behavior, _ row: Int, _ plus: Int, _ minus: Int, _ m: Int) -> Bool {
        if b.slotsSerial == planSerial { return b.slotsUsable }
        b.slotsSerial = planSerial
        let count = b.inputCount, inputs = b.inputList, slots = b.slots
        var usable = true
        func slot(_ r: Int, _ c: Int) -> Int32 {
            guard r >= 0 && c >= 0 else { return -1 }
            let s = slotMap[r * m + c]
            if Int(s) < stampFloor { usable = false }
            return s
        }
        slots.update(repeating: -1, count: 4 * count + 4)
        for k in 0..<count {
            let input = inputs[k]
            let j = 4 * k
            if b.voltage {
                guard row >= 0 else { continue }
                if input.row >= 0 {
                    slots[j] = slot(row, input.row)
                } else {
                    slots[j] = slot(row, input.plus - 1)
                    slots[j + 1] = slot(row, input.minus - 1)
                }
            } else if input.row >= 0 {
                slots[j] = slot(plus, input.row)
                slots[j + 1] = slot(minus, input.row)
            } else {
                slots[j] = slot(plus, input.plus - 1)
                slots[j + 1] = slot(plus, input.minus - 1)
                slots[j + 2] = slot(minus, input.plus - 1)
                slots[j + 3] = slot(minus, input.minus - 1)
            }
        }
        if b.voltage && row >= 0 {
            let own = 4 * count
            slots[own] = slot(plus, row)
            slots[own + 1] = slot(minus, row)
            slots[own + 2] = slot(row, plus)
            slots[own + 3] = slot(row, minus)
        }
        b.slotsUsable = usable
        return usable
    }

    /// A behavioural source's input at the solution its decisions are held at
    @inline(__always) private func decisionInput(_ input: BehaviorInput) -> Double {
        if input.row >= 0 { return input.row < decisionX.count ? input.sign * decisionX[input.row] : 0 }
        let p = input.plus > 0 ? decisionX[input.plus - 1] : 0, n = input.minus > 0 ? decisionX[input.minus - 1] : 0
        return p - n
    }

    /// Whether a behavioural source's value at the present solution changes with its decisions made there rather than
    /// where they are held: a comparator in it has switched during the solve
    private func decisionsMoved() -> Bool {
        let celsius = kelvin - 273.15
        for i in decidingIndices {
            guard let b = behaviors[i] else { continue }
            let v = behaviorValues, d = behaviorDecisions, r = behaviorRegisters
            let count = b.inputCount, inputs = b.inputList
            for k in 0..<count {
                let input = inputs[k]
                v[k] = input.row >= 0 ? (input.row < x.count ? input.sign * x[input.row] : 0)
                    : voltage(input.plus) - voltage(input.minus)
                d[k] = decisionInput(input)
            }
            // within half its reach of its last evaluation, both where it ended and where its decisions are held (and
            // its decisions made where it ended): every decision in it is as it was there, the same both ways
            if Self.bypassesDevices && b.evaluated && b.reach > 0 && b.lastCelsius == celsius {
                let last = b.lastInputs, lastDecisions = b.lastDecisions
                var furthest = 0.0, finite = true
                for k in 0..<count {
                    let (live, ended, held) = (abs(v[k] - last[k]), abs(v[k] - lastDecisions[k]), abs(d[k] - lastDecisions[k]))
                    if !(live.isFinite && ended.isFinite && held.isFinite) { finite = false }
                    // (in twos: max of four takes the fourth in an array, made and freed each time)
                    furthest = max(max(furthest, live), max(ended, held))
                }
                if finite && furthest <= 0.5 * b.reach { continue }
            }
            let program = b.program
            program.run(v, deciding: d, time: solveTime, celsius: celsius, into: r)
            let held = r[program.value]
            program.run(v, time: solveTime, celsius: celsius, into: r)
            let now = r[program.value]
            if !(Swift.abs(held - now) <= 1e-9 * (1 + Swift.abs(now))) { return true }
        }
        return false
    }

    /// A linear behavioural source's constant slopes, into the base matrix (as `stampBehavior` stamps them at every
    /// iteration for one that is not linear): a voltage across + and − on its own row, or a current from + to −
    private func stampLinearBehavior(_ i: Int, _ nodes: [Int], _ matrix: Entries, _ m: Int) {
        guard i < behaviors.count, let b = behaviors[i], b.linear, nodes.count >= 2 else { return }
        let plus = nodes[0] - 1, minus = nodes[1] - 1
        let row = topology.sourceRow[i]
        for (k, input) in b.inputs.enumerated() {
            guard k < b.expression.slopes.count, case let .constant(slope) = b.expression.slopes[k], slope != 0, slope.isFinite else { continue }
            if b.voltage {
                guard row >= 0 else { continue }
                if input.row >= 0 {
                    add(matrix, m, row, input.row, -slope * input.sign)
                } else {
                    add(matrix, m, row, input.plus - 1, -slope)
                    add(matrix, m, row, input.minus - 1, slope)
                }
            } else if input.row >= 0 {
                add(matrix, m, plus, input.row, slope * input.sign)
                add(matrix, m, minus, input.row, -slope * input.sign)
            } else {
                add(matrix, m, plus, input.plus - 1, slope)
                add(matrix, m, plus, input.minus - 1, -slope)
                add(matrix, m, minus, input.plus - 1, -slope)
                add(matrix, m, minus, input.minus - 1, slope)
            }
        }
        if b.voltage && row >= 0 {
            add(matrix, m, plus, row, -1)
            add(matrix, m, minus, row, 1)
            add(matrix, m, row, plus, 1)
            add(matrix, m, row, minus, -1)
        }
    }

    /// The current through a behavioural source, from + to − (into + as SPICE has it), at the present solution
    private func behaviorCurrent(_ i: Int, _ v: (Int) -> Double) -> Double {
        guard i < behaviors.count, let b = behaviors[i] else { return 0 }
        if b.voltage {
            let row = topology.sourceRow[i]
            return row >= 0 && row < x.count ? -x[row] : 0
        }
        var values = [Double](repeating: 0, count: max(b.inputs.count, 1))
        for (k, input) in b.inputs.enumerated() {
            values[k] = input.row >= 0 ? (input.row < x.count ? input.sign * x[input.row] : 0) : v(input.plus) - v(input.minus)
        }
        return values.withUnsafeBufferPointer { b.expression.value($0.baseAddress!, time: time, celsius: kelvin - 273.15) }
    }

    /// A diode's junction (inside its series resistance), linearised at the present solution and limited as SPICE limits
    /// it, with the charging of its stored charge
    private func stampDiode(_ i: Int, _ nodes: NodeList, _ matrix: Entries, _ rhs: Entries, _ m: Int) {
        let d = diodes[i]
        let anode = d.hasSeriesNode ? nodes[2] : nodes[0], cathode = nodes[1]
        let vd = d.limit(voltage(anode) - voltage(cathode), old: limitedVoltage[i]) {
            limitJunction($0, old: $1, nvt: $2, critical: $3)
        }
        limitedVoltage[i] = vd
        let junction = d.current(vd, gmin: Self.junctionGmin)
        var (id, gd) = junction
        id += junctionConductance * vd
        gd += junctionConductance
        if d.hasCharges && !linearising {
            let (q, cap) = d.charge(vd, current: junction)
            let k = Self.chargeSlots * i
            id += (a0 * q + a1 * junctionCharge[k] + a2 * junctionChargePrevious[k]) / h
            gd += a0 * cap / h
        }
        stampConductance(matrix, m, anode, cathode, gd)
        stampCurrent(rhs, anode, cathode, id - gd * vd)
    }

    private func stampNonlinear(_ matrix: Entries, _ rhs: Entries, _ m: Int) {
        let lists = nodeLists
        for i in nonlinearIndices {
            let nodes = lists[i]
            let c = constants[i]
            switch kinds[i] {
            case .diode, .led, .zener:
                stampDiode(i, nodes, matrix, rhs, m)

            case .npn, .pnp:
                stampBipolar(i, nodes, matrix, rhs, m)

            case .behavioralSource:
                stampBehavior(i, nodes, matrix, rhs, m)

            case .inductor:
                stampSaturation(i, nodes, matrix, rhs, m)

            case .njfet, .pjfet:
                stampJFET(i, nodes, matrix, rhs, m)

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
                add(matrix, m, output - 1, input - 1, -dIn)
                add(matrix, m, output - 1, output - 1, -dOut)
                rhs[output - 1] += current - dIn * vin - dOut * vout

            case .pll:
                // phase comparator 2: driven high while pumping up, low while pumping down, and otherwise let go
                let pump = logicStates[i].count
                guard pump != 0, nodes.count > 6 else { continue }
                stampConductance(matrix, m, nodes[6], 0, c.outputConductance)
                if pump > 0 { stampCurrent(rhs, 0, nodes[6], c.supply * c.outputConductance) }

            case .triode, .pentode:
                let (grid, plate, cathode) = (nodes[0], nodes[1], nodes[2])
                let pentode = kinds[i] == .pentode
                let screen = pentode && nodes.count > 3 ? nodes[3] : 0
                var vgk = voltage(grid) - voltage(cathode)
                var vpk = voltage(plate) - voltage(cathode)
                var vsk = pentode ? voltage(screen) - voltage(cathode) : 0
                // limit each change per iteration: the grid finely (the current is steep in it), the plate and screen
                // in bigger steps, as they swing over hundreds of volts
                if abs(vgk - limitedVoltage[i]) > 2 || abs(vpk - limitedVoltage2[i]) > 50 || abs(vsk - limitedVoltage3[i]) > 50 {
                    limiting = true
                }
                vgk = limitedVoltage[i] + max(-2, min(2, vgk - limitedVoltage[i]))
                vpk = limitedVoltage2[i] + max(-50, min(50, vpk - limitedVoltage2[i]))
                vsk = limitedVoltage3[i] + max(-50, min(50, vsk - limitedVoltage3[i]))
                limitedVoltage[i] = vgk
                limitedVoltage2[i] = vpk
                limitedVoltage3[i] = vsk
                /// a current from `a` to `b` through the tube, following the voltage from `plus` to `minus` with slope `g`
                func follows(_ a: Int, _ b: Int, _ plus: Int, _ minus: Int, _ g: Double) {
                    add(matrix, m, a - 1, plus - 1, g)
                    add(matrix, m, a - 1, minus - 1, -g)
                    add(matrix, m, b - 1, plus - 1, -g)
                    add(matrix, m, b - 1, minus - 1, g)
                }
                if pentode {
                    let t = c.tube.pentode(vgk: vgk, vsk: vsk, vpk: vpk)
                    follows(plate, cathode, grid, cathode, t.plateGrid)
                    follows(plate, cathode, screen, cathode, t.plateScreen)
                    follows(plate, cathode, plate, cathode, t.platePlate)
                    stampCurrent(rhs, plate, cathode, t.plate - t.plateGrid * vgk - t.plateScreen * vsk - t.platePlate * vpk)
                    follows(screen, cathode, grid, cathode, t.screenGrid)
                    follows(screen, cathode, screen, cathode, t.screenScreen)
                    stampCurrent(rhs, screen, cathode, t.screen - t.screenGrid * vgk - t.screenScreen * vsk)
                } else {
                    let t = c.tube.triode(vgk: vgk, vpk: vpk)
                    follows(plate, cathode, grid, cathode, t.dGrid)
                    follows(plate, cathode, plate, cathode, t.dPlate)
                    stampCurrent(rhs, plate, cathode, t.current - t.dGrid * vgk - t.dPlate * vpk)
                }
                let g = c.tube.grid(vgk: vgk)
                stampConductance(matrix, m, grid, cathode, g.slope)
                stampCurrent(rhs, grid, cathode, g.current - g.slope * vgk)
                // shunts while gmin stepping
                stampConductance(matrix, m, plate, cathode, junctionConductance)
                stampConductance(matrix, m, grid, cathode, junctionConductance)

            case .nmos, .pmos:
                stampMOSFET(i, nodes, matrix, rhs, m)

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
                if linearising {
                    // small changes: the output follows the internal stage through the slope of its limit, and the
                    // stage integrates the input, leaking at its pole (without dynamics, the output follows the input)
                    if c.gbw > 0 {
                        let w = 2 * Double.pi * c.gbw
                        let driveSlope = c.slew > 0 ? w * (1 - pow(tanh((vd + c.offset) * w / c.slew), 2)) : w
                        let t = tanh(capacitorVoltage[i] / c.limit)
                        let pole = SmallSignalModel.Transfer.pole(gain: (1 - t * t) * driveSlope, rate: w / c.gain)
                        if plus > 0 { linearEntries.append(.init(row: row, column: plus - 1, scale: -1, transfer: pole)) }
                        if minus > 0 { linearEntries.append(.init(row: row, column: minus - 1, scale: 1, transfer: pole)) }
                    } else {
                        let t = tanh(c.gain * (vd + c.offset) / c.limit)
                        let slope = c.gain * (1 - t * t)
                        add(matrix, m, row, plus - 1, -slope)
                        add(matrix, m, row, minus - 1, slope)
                    }
                    continue
                }
                let (output, slope, _) = opAmpOutput(i, differential: vd)
                // v(out) = output + slope (vd' - vd), linearised around the present inputs
                add(matrix, m, row, plus - 1, -slope)
                add(matrix, m, row, minus - 1, slope)
                rhs[row] += output - slope * vd

            case .ota:
                let (minus, plus, output, bias) = (nodes[0], nodes[1], nodes[2], nodes[3])
                let supply = c.supply
                let vt = self.vt
                // bias input
                let vj = limitJunction(voltage(bias) + supply, old: limitedVoltage[i], nvt: c.nvt, critical: c.critical)
                limitedVoltage[i] = vj
                var (ib, gb) = otaBias(i, junction: vj)
                ib += junctionConductance * vj
                gb += junctionConductance
                if bias > 0 {
                    add(matrix, m, bias - 1, bias - 1, gb)
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
                    add(matrix, m, row, plus - 1, -gd)
                    add(matrix, m, row, minus - 1, gd)
                    add(matrix, m, row, bias - 1, -gbias)
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
                    add(matrix, m, row, row, gu + gl)
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
                add(matrix, m, row, nodes[0] - 1, -fx)
                add(matrix, m, row, nodes[1] - 1, -fy)
                rhs[row] += c.limit * t - fx * vx - fy * vy

            case .vca:
                // out = limit · tanh(gain · in / limit), the gain set by the control: solved with the circuit, so its
                // output follows its input at once (a compressor's gain cell sits in an op-amp's feedback, where a
                // sample's delay would make the loop ring), linearised in the input and the control. The small-signal
                // model passes it on its own.
                guard !linearising else { continue }
                let row = topology.sourceRow[i]
                guard row >= 0 else { continue }
                let vin = voltage(nodes[0])
                let vcv = voltage(nodes[1])
                let exponential = c.value < 0.5
                let raw = exponential ? c.gain * (vcv - c.offset) / 20 : max(vcv, 0) / c.threshold
                let gain = exponential ? pow(10, min(raw, 40.0 / 20)) : min(raw, 100)
                let gainSlope = exponential ? (raw < 2 ? gain * log(10) * c.gain / 20 : 0) : (vcv > 0 && raw < 100 ? 1 / c.threshold : 0)
                let t = tanh(gain * vin / c.limit)
                let fx = gain * (1 - t * t)
                let fy = vin * (1 - t * t) * gainSlope
                add(matrix, m, row, nodes[0] - 1, -fx)
                add(matrix, m, row, nodes[1] - 1, -fy)
                rhs[row] += c.limit * t - fx * vin - fy * vcv

            case .vactrol:
                // the LED, like a diode, and the LDR, a resistance set by the light so far
                let vd = limitJunction(voltage(nodes[0]) - voltage(nodes[1]), old: limitedVoltage[i], nvt: c.nvt, critical: c.critical)
                limitedVoltage[i] = vd
                var (id, gd) = diodeCurrent(vd, saturation: c.saturation, nvt: c.nvt)
                id += junctionConductance * vd
                gd += junctionConductance
                stampConductance(matrix, m, nodes[0], nodes[1], gd)
                stampCurrent(rhs, nodes[0], nodes[1], id - gd * vd)
                stampConductance(matrix, m, nodes[2], nodes[3], vactrolConductance(i))

            case .analogSwitch:
                let (a, b, control) = (nodes[0], nodes[1], nodes[2])
                let vc = voltage(control)
                let (g, slope) = analogSwitchConductance(i, control: vc)
                let k = slope * (voltage(a) - voltage(b))
                stampConductance(matrix, m, a, b, g)
                add(matrix, m, a - 1, control - 1, k)
                add(matrix, m, b - 1, control - 1, -k)
                if a > 0 { rhs[a - 1] += k * vc }
                if b > 0 { rhs[b - 1] -= k * vc }
            default:
                break
            }
        }
    }

    // MARK: - Small-signal analysis

    /// Set while the circuit is being linearised: the base matrix leaves out capacitors and inductors, and op-amps note
    /// their internal pole in `linearEntries` instead of stamping the slope of one step
    private var linearising = false
    private var linearEntries: [SmallSignalModel.Entry] = []

    /// The circuit linearised around its present state, for small-signal (AC) analysis: the operating point is
    /// whatever the circuit is doing now, so let it settle first. Switches, logic and chips stay as they are; synth
    /// chips with an audio path (filter, VCA, delay lines, a sample and hold while tracking) pass small signals through
    /// it, oscillators and envelopes do not. Nil if there is no solution to linearise around.
    /// The circuit's sources of noise at the present solution, for `SmallSignalModel.noise`: each resistor's thermal
    /// noise (4kT/R), each junction's shot noise (2qI: a diode's current, a transistor's collector and base currents),
    /// field-effect transistors' channel noise ((8/3)kT·gm), tubes' (as 2.5/gm of resistance at the grid) and op-amps'
    /// input noise voltage. There is no flicker (1/f) noise.
    public func noiseSources() -> [SmallSignalModel.NoiseSource] {
        guard x.count == topology.matrixSize else { return [] }
        let q = 1.602176634e-19
        // kT, from the thermal voltage kT/q
        let kT = q * vt
        var sources: [SmallSignalModel.NoiseSource] = []
        for i in kinds.indices {
            let nodes = topology.elementNodes[i]
            let element = flat.elements[i]
            let c = constants[i]
            let name = element.name.isEmpty ? element.kind.displayName : element.name
            func v(_ k: Int) -> Double { voltage(nodes[k]) }
            func current(_ label: String, _ density: Double, _ a: Int, _ b: Int) {
                guard density > 0, density.isFinite, a != b else { return }
                sources.append(.init(element: i, label: label, density: density, injection: .current(from: a, to: b)))
            }
            switch kinds[i] {
            case .resistor, .lamp:
                // (not a macromodel's noiseless resistor)
                if element[param: "noiseless"] < 0.5 { current(name, 4 * kT / max(element[param: "resistance"], 1e-9), nodes[0], nodes[1]) }
            case .potentiometer:
                let (upper, lower) = potentiometerResistances(element)
                current(name + " (a side)", 4 * kT / upper, nodes[0], nodes[2])
                current(name + " (b side)", 4 * kT / lower, nodes[2], nodes[1])
            case .diode, .led, .zener:
                // shot noise at the junction, thermal noise of the series resistance
                let d = diodes[i]
                let anode = d.hasSeriesNode ? nodes[2] : nodes[0]
                current(name, 2 * q * abs(d.current(voltage(anode) - v(1), gmin: Self.junctionGmin).current), anode, nodes[1])
                if d.hasSeriesNode { current(name + " series resistance", 4 * kT / d.rs, nodes[0], anode) }
            case .npn, .pnp:
                // shot noise of the collector and base currents at the junctions, thermal noise of the resistances
                let p: Double = kinds[i] == .npn ? 1 : -1
                let g = bipolar[i]
                let n = Self.bipolarNodes({ nodes[$0] }, g)
                let r = g.currents(vbe: p * (voltage(n.bp) - voltage(n.ep)), vbc: p * (voltage(n.bp) - voltage(n.cp)),
                                   gmin: Self.junctionGmin)
                current(name + " collector", 2 * q * abs(r.cc), n.cp, n.ep)
                current(name + " base", 2 * q * abs(r.cb), n.bp, n.ep)
                if g.hasBaseNode { current(name + " base resistance", 4 * kT * r.gx, n.b, n.bp) }
                if g.hasCollectorNode { current(name + " collector resistance", 4 * kT / g.rc, n.c, n.cp) }
                if g.hasEmitterNode { current(name + " emitter resistance", 4 * kT / g.re, n.e, n.ep) }
            case .njfet, .pjfet:
                // the channel's thermal noise (from its transconductance, as in ngspice) and the resistances'
                let j = jfets[i]
                let n = Self.jfetNodes({ nodes[$0] }, j)
                let r = j.currents(vgs: j.polarity * (voltage(n.g) - voltage(n.sp)), vgd: j.polarity * (voltage(n.g) - voltage(n.dp)),
                                   gmin: Self.junctionGmin)
                current(name, 8.0 / 3 * kT * abs(r.gm), n.dp, n.sp)
                if j.hasDrainNode { current(name + " drain resistance", 4 * kT / j.rd, n.d, n.dp) }
                if j.hasSourceNode { current(name + " source resistance", 4 * kT / j.rs, n.s, n.sp) }
            case .nmos, .pmos:
                // the channel's thermal noise (from its transconductance, as in ngspice) and the resistances'
                let f = mosfets[i]
                let n = Self.fetNodes({ nodes[$0] }, drain: f.hasDrainNode, source: f.hasSourceNode)
                let t = f.type
                let r = f.currents(vgs: t * (voltage(n.g) - voltage(n.sp)), vds: t * (voltage(n.dp) - voltage(n.sp)),
                                   vbs: t * (voltage(n.s) - voltage(n.sp)), gmin: Self.junctionGmin)
                current(name, 8.0 / 3 * kT * abs(r.gm), n.dp, n.sp)
                if f.hasDrainNode { current(name + " drain resistance", 4 * kT / f.rd, n.d, n.dp) }
                if f.hasSourceNode { current(name + " source resistance", 4 * kT / f.rs, n.s, n.sp) }
            case .triode, .pentode:
                let vgk = v(0) - v(2), vpk = v(1) - v(2)
                let gm = kinds[i] == .pentode && nodes.count > 3
                    ? c.tube.pentode(vgk: vgk, vsk: v(3) - v(2), vpk: vpk).plateGrid
                    : c.tube.triode(vgk: vgk, vpk: vpk).dGrid
                current(name, 4 * kT * 2.5 * abs(gm), nodes[1], nodes[2])
            case .opAmp where c.noiseDensity > 0:
                let row = topology.sourceRow[i]
                guard row >= 0 else { continue }
                // a voltage in series with the + input reaches the output row as the inputs do
                let vd = v(1) - v(0)
                let transfer: SmallSignalModel.Transfer
                if c.gbw > 0 {
                    let w = 2 * Double.pi * c.gbw
                    let driveSlope = c.slew > 0 ? w * (1 - pow(tanh((vd + c.offset) * w / c.slew), 2)) : w
                    let t = tanh(capacitorVoltage[i] / c.limit)
                    transfer = .pole(gain: (1 - t * t) * driveSlope, rate: w / c.gain)
                } else {
                    let t = tanh(c.gain * (vd + c.offset) / c.limit)
                    transfer = .constant(c.gain * (1 - t * t))
                }
                sources.append(.init(element: i, label: name, density: c.noiseDensity * c.noiseDensity, injection: .row(row, transfer)))
            default:
                break
            }
        }
        return sources
    }

    public func smallSignalModel() -> SmallSignalModel? {
        let m = topology.matrixSize
        guard m > 0, x.count == m, !isFailed else { return nil }
        let saved = (limitedVoltage, limitedVoltage2, limitedVoltage3, limiting)
        linearising = true
        linearEntries = []
        // behavioural sources decided at the operating point
        if !decidingIndices.isEmpty { Self.copy(x, into: &decisionX) }
        var matrix = makeBaseMatrix()
        var scratch = [Double](repeating: 0, count: m)
        junctionConductance = 0
        stampMemristors(&matrix, m)
        if hasNonlinear {
            for i in nonlinearIndices { opAmpCrossings[i] = 0 }
            // linearised at the present solution: the junctions' last linearisation points are taken from it, so
            // nothing is held back by limiting
            for i in nonlinearIndices { alignLinearisationPoint(i) }
            stampNonlinear(&matrix, &scratch, m)
        }
        var entries = linearEntries
        linearising = false
        linearEntries = []
        (limitedVoltage, limitedVoltage2, limitedVoltage3, limiting) = saved

        func admittance(_ a: Int, _ b: Int, _ transfer: SmallSignalModel.Transfer) {
            if a > 0 { entries.append(.init(row: a - 1, column: a - 1, scale: 1, transfer: transfer)) }
            if b > 0 { entries.append(.init(row: b - 1, column: b - 1, scale: 1, transfer: transfer)) }
            if a > 0 && b > 0 {
                entries.append(.init(row: a - 1, column: b - 1, scale: -1, transfer: transfer))
                entries.append(.init(row: b - 1, column: a - 1, scale: -1, transfer: transfer))
            }
        }
        var drives: [Int: SmallSignalModel.Drive] = [:]
        var terminals: [Int: SmallSignalModel.Terminals] = [:]
        for i in kinds.indices {
            let nodes = topology.elementNodes[i]
            let c = constants[i]
            let row = topology.sourceRow[i]
            // the output row of a chip: v(out) − Σ transfer × v(input) = 0
            func passes(_ input: Int, _ transfer: SmallSignalModel.Transfer) {
                guard row >= 0, input > 0 else { return }
                entries.append(.init(row: row, column: input - 1, scale: -1, transfer: transfer))
            }
            switch kinds[i] {
            case .capacitor:
                admittance(nodes[0], nodes[1], .capacitance(c.value))
            case .inductor:
                if flat.elements[i].saturates {
                    // the inductance at the operating point's flux: 1 / (di/dλ)
                    let flux = c.value * inductorCurrent[i]
                    let slope = 1 / c.value + coreCurrent(i, flux: flux).slope
                    admittance(nodes[0], nodes[1], .inductance(1 / max(slope, 1e-30)))
                } else {
                    admittance(nodes[0], nodes[1], .inductance(c.value))
                }
            case .diode, .led, .zener:
                let anode = diodes[i].hasSeriesNode ? nodes[2] : nodes[0]
                let capacitance = junctionChargeAndCapacitance(i, slot: 0, voltage(anode) - voltage(nodes[1])).capacitance
                if capacitance > 0 { admittance(anode, nodes[1], .capacitance(capacitance)) }
            case .npn, .pnp:
                // the stored charges' capacitances at the operating point, and the base-emitter charge's dependence on
                // vbc (a transcapacitance: current b' to e' with v(b') − v(c'))
                let p: Double = kinds[i] == .npn ? 1 : -1
                let g = bipolar[i]
                guard g.hasCharges else { continue }
                let n = Self.bipolarNodes({ nodes[$0] }, g)
                let vbe = p * (voltage(n.bp) - voltage(n.ep)), vbc = p * (voltage(n.bp) - voltage(n.cp))
                let q = g.charges(vbe: vbe, vbc: vbc, vbx: p * (voltage(n.b) - voltage(n.cp)),
                                  g.currents(vbe: vbe, vbc: vbc, gmin: Self.junctionGmin))
                if q.capbe != 0 { admittance(n.bp, n.ep, .capacitance(q.capbe)) }
                if q.capbc != 0 { admittance(n.bp, n.cp, .capacitance(q.capbc)) }
                if q.capbx != 0 { admittance(n.b, n.cp, .capacitance(q.capbx)) }
                if q.dqbeVbc != 0 {
                    for (row, column, scale) in [(n.bp, n.bp, 1.0), (n.bp, n.cp, -1.0), (n.ep, n.bp, -1.0), (n.ep, n.cp, 1.0)]
                    where row > 0 && column > 0 {
                        entries.append(.init(row: row - 1, column: column - 1, scale: scale, transfer: .capacitance(q.dqbeVbc)))
                    }
                }
            case .njfet, .pjfet:
                // the gate's depletion capacitances at the operating point
                let j = jfets[i]
                guard j.hasCharges else { continue }
                let n = Self.jfetNodes({ nodes[$0] }, j)
                let q = j.charges(vgs: j.polarity * (voltage(n.g) - voltage(n.sp)), vgd: j.polarity * (voltage(n.g) - voltage(n.dp)))
                if q.capgs > 0 { admittance(n.g, n.sp, .capacitance(q.capgs)) }
                if q.capgd > 0 { admittance(n.g, n.dp, .capacitance(q.capgd)) }
            case .nmos, .pmos:
                // the bulk junctions' capacitances and Meyer's (the whole of each at the operating point) with the overlaps
                let f = mosfets[i]
                guard f.hasCharges else { continue }
                let n = Self.fetNodes({ nodes[$0] }, drain: f.hasDrainNode, source: f.hasSourceNode)
                let t = f.type
                let (vgs, vds, vbs) = (t * (voltage(n.g) - voltage(n.sp)), t * (voltage(n.dp) - voltage(n.sp)),
                                       t * (voltage(n.s) - voltage(n.sp)))
                let r = f.currents(vgs: vgs, vds: vds, vbs: vbs, gmin: Self.junctionGmin)
                let bulk = f.bulkCharges(vbd: vbs - vds, vbs: vbs)
                let half = f.meyer(vgs: vgs, vgd: vgs - vds, r)
                for (a, b, c) in [(n.g, n.sp, 2 * half.gs + f.cgso), (n.g, n.dp, 2 * half.gd + f.cgdo), (n.g, n.s, 2 * half.gb + f.cgbo),
                                  (n.s, n.dp, bulk.capbd), (n.s, n.sp, bulk.capbs)] where c > 0 {
                    admittance(a, b, .capacitance(c))
                }
            case .dcVoltage, .acVoltage, .squareVoltage, .noiseVoltage, .keyboardPitch, .keyboardGate, .audioInput:
                if row >= 0 {
                    drives[i] = .row(row)
                    terminals[i] = .init(minus: nodes[0], plus: nodes[1])
                }
            case .currentSource:
                drives[i] = .current(from: nodes[0], to: nodes[1])
            case .vcf:
                // the four stages, each a one-pole low-pass whose slope at its present level sets its pole, and the
                // feedback from the last to the input
                let s = moduleStates[i]
                // (the chip's own cutoff, without the limit the step's length puts on its updates)
                let cutoff = c.frequency * pow(2, min(max(voltage(nodes[1]), -16), 16))
                let w = 2 * Double.pi * cutoff
                let slopes = [s.s1, s.s2, s.s3, s.s4].map { 1 - tanh($0) * tanh($0) }
                let input = tanh(voltage(nodes[0]) / c.limit - c.gain * s.s4)
                passes(nodes[0], .ladder(numerator: pow(w, 4) * slopes[0] * slopes[1] * slopes[2], poles: slopes.map { w * $0 },
                                         drive: 1 - input * input, feedback: c.gain))
            case .vca:
                let (in0, in1) = (voltage(nodes[0]), voltage(nodes[1]))
                let exponential = c.value < 0.5
                let raw = exponential ? c.gain * (in1 - c.offset) / 20 : max(in1, 0) / c.threshold
                let gain = exponential ? pow(10, min(raw, 40.0 / 20)) : min(raw, 100)
                let t = tanh(gain * in0 / c.limit)
                let gainSlope = exponential ? (raw < 2 ? gain * log(10) * c.gain / 20 : 0) : (in1 > 0 && raw < 100 ? 1 / c.threshold : 0)
                passes(nodes[0], .delay(gain: gain * (1 - t * t), time: 0, cutoff: 0, poles: 0))
                passes(nodes[1], .delay(gain: in0 * (1 - t * t) * gainSlope, time: 0, cutoff: 0, poles: 0))
            case .agcPreamp:
                // the preamp and the VCA at the gain the detector has set
                let t = moduleStates[i].output / c.limit
                let gain = c.gain * moduleStates[i].s1 * (1 - t * t)
                passes(nodes[0], .delay(gain: gain, time: 0, cutoff: 0, poles: 0))
                passes(nodes[1], .delay(gain: -gain, time: 0, cutoff: 0, poles: 0))
            case .sampleHold where c.value >= 0.5 && moduleStates[i].high:
                passes(nodes[0], .delay(gain: 1, time: 0, cutoff: 0, poles: 0))
            case .delayLine where c.duty >= 0.5:
                // clocked from its pin: delayed by its buckets at the rate its clock was running (silent without one)
                let rate = bucketBrigades[i]?.rate ?? 0
                if rate > 1 {
                    passes(nodes[0], .delay(gain: c.gain, time: Double(BucketBrigade.count(c.value)) / rate, cutoff: 0, poles: 0))
                }
            case .delayLine:
                let clock = max(c.frequency + c.slew * voltage(nodes[1]), c.frequency * 0.05, 100)
                passes(nodes[0], .delay(gain: c.gain, time: c.value / (2 * clock), cutoff: 0, poles: 0))
            case .digitalDelay:
                let delay = echoDelay(i)
                let t = moduleStates[i].output / c.limit
                let cutoff = min(820 / delay, 20_000)
                passes(nodes[0], .delay(gain: c.gain * (1 - t * t), time: delay, cutoff: 2 * .pi * cutoff, poles: 2))
            default:
                break
            }
        }
        return SmallSignalModel(size: m, nodeCount: topology.nodeCount, matrix: matrix, entries: entries, drives: drives,
                                terminals: terminals)
    }

    /// Sets an element's last linearisation point to the present solution, so that stamping it is not held back by
    /// Newton limiting
    private func alignLinearisationPoint(_ i: Int) {
        let nodes = topology.elementNodes[i]
        func v(_ k: Int) -> Double { voltage(nodes[k]) }
        switch kinds[i] {
        case .diode, .led, .zener:
            limitedVoltage[i] = voltage(diodes[i].hasSeriesNode ? nodes[2] : nodes[0]) - v(1)
        case .vactrol:
            limitedVoltage[i] = v(0) - v(1)
        case .npn, .pnp:
            let p: Double = kinds[i] == .npn ? 1 : -1
            let n = Self.bipolarNodes({ nodes[$0] }, bipolar[i])
            limitedVoltage[i] = p * (voltage(n.bp) - voltage(n.ep))
            limitedVoltage2[i] = p * (voltage(n.bp) - voltage(n.cp))
        case .njfet, .pjfet:
            let j = jfets[i]
            let n = Self.jfetNodes({ nodes[$0] }, j)
            limitedVoltage[i] = j.polarity * (voltage(n.g) - voltage(n.sp))
            limitedVoltage2[i] = j.polarity * (voltage(n.g) - voltage(n.dp))
        case .nmos, .pmos:
            let f = mosfets[i]
            let n = Self.fetNodes({ nodes[$0] }, drain: f.hasDrainNode, source: f.hasSourceNode)
            limitedVoltage[i] = f.type * (voltage(n.g) - voltage(n.sp))
            limitedVoltage2[i] = f.type * (voltage(n.dp) - voltage(n.sp))
            limitedVoltage3[i] = f.type * (voltage(n.s) - voltage(n.sp))
        case .triode, .pentode:
            limitedVoltage[i] = v(0) - v(2)
            limitedVoltage2[i] = v(1) - v(2)
            if nodes.count > 3 { limitedVoltage3[i] = v(3) - v(2) }
        case .unbufferedInverter:
            limitedVoltage[i] = v(0)
            limitedVoltage2[i] = v(1)
        case .opAmp:
            limitedVoltage[i] = v(1) - v(0)
        case .ota:
            limitedVoltage[i] = v(3) + constants[i].supply
            limitedVoltage2[i] = v(2) - constants[i].clampLevel
            limitedVoltage3[i] = -constants[i].clampLevel - v(2)
        default:
            break
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
        let next = advanceLogic(i, old, inputs: inputs)
        if kind == .analogMux || kind == .analogSelector {
            return Logic.channel(kind, next) != Logic.channel(kind, old)
        }
        let function = Int(c.value)
        return Logic.outputs(kind, next, function: function) != Logic.outputs(kind, old, function: function) || next.count != old.count
            || (kind == .i2sDac && next.latch != old.latch)
    }

    /// Moves a logic part on to new input levels: its state, an ADC's sample when it takes one (of the circuit as it
    /// was at the last step), and a fresh matrix when what it switches into the base matrix changed (a multiplexer's
    /// channel, an ADC's DOUT driven or let go, an I²C target holding SDA)
    @discardableResult
    private func advanceLogic(_ i: Int, _ old: LogicState, inputs: UInt32) -> LogicState {
        let kind = kinds[i]
        var next = Logic.next(kind, old, inputs: inputs, function: Int(constants[i].value))
        switch kind {
        case .analogMux, .analogSelector:
            if Logic.channel(kind, next) != Logic.channel(kind, old) { matrixIsCurrent = false }
        case .spiAdc:
            if next.phase >= 0.5 {
                next.phase = 0
                next.latch = adcCode(i, configuration: next.shift)
            }
            if (next.inputs ^ old.inputs) & 1 != 0 { matrixIsCurrent = false }
        case .i2cDac:
            if Logic.acknowledging(next) != Logic.acknowledging(old) { matrixIsCurrent = false }
        default:
            break
        }
        logicStates[i] = next
        return next
    }

    /// An MCP3008's conversion: SGL/DIFF and D2–D0 pick the input (single-ended against ground, or a pair: CH2k and
    /// CH2k+1, either way round), read against VREF as 1024 steps
    private func adcCode(_ i: Int, configuration: UInt32) -> UInt32 {
        let nodes = topology.elementNodes[i]
        guard nodes.count >= 13 else { return 0 }
        let channel = Int(configuration & 0x7)
        let reference = voltage(nodes[4])
        let plus = voltage(nodes[5 + channel])
        let minus = configuration & 0x8 != 0 ? 0 : voltage(nodes[5 + (channel ^ 1)])
        guard reference > 1e-6 else { return 0 }
        let code = ((plus - minus) / reference * 1024).rounded(.down)
        return UInt32(min(max(code, 0), 1023))
    }

    // MARK: - After each step

    /// The charges part `i` stores, by slot, at the junction voltages Newton-Raphson last stamped (the solution's, once
    /// it converged: a substep accepted without converging leaves the solution at an unlimited iterate, where exp() would
    /// store a huge charge)
    @inline(__always) private func forEachStoredCharge(_ i: Int, _ nodes: NodeList, _ body: (Int, Double) -> Void) {
        switch kinds[i] {
        case .npn, .pnp:
            let g = bipolar[i]
            let n = Self.bipolarNodes({ nodes[$0] }, g)
            let p: Double = kinds[i] == .npn ? 1 : -1
            let (vbe, vbc) = (limitedVoltage[i], limitedVoltage2[i])
            let q = g.charges(vbe: vbe, vbc: vbc, vbx: p * (voltage(n.b) - voltage(n.cp)),
                              g.currents(vbe: vbe, vbc: vbc, gmin: Self.junctionGmin))
            body(0, q.qbe)
            body(1, q.qbc)
            body(2, q.qbx)
        case .diode, .led, .zener:
            body(0, junctionChargeAndCapacitance(i, slot: 0, limitedVoltage[i]).charge)
        case .njfet, .pjfet:
            let q = jfets[i].charges(vgs: limitedVoltage[i], vgd: limitedVoltage2[i])
            body(0, q.qgs)
            body(1, q.qgd)
        case .nmos, .pmos:
            let (vgs, vds, vbs) = (limitedVoltage[i], limitedVoltage2[i], limitedVoltage3[i])
            let r = mosfets[i].currents(vgs: vgs, vds: vds, vbs: vbs, gmin: Self.junctionGmin)
            let q = mosfetCharges(i, vgs: vgs, vds: vds, vbs: vbs, r).q
            body(0, q.0)
            body(1, q.1)
            body(2, q.2)
            body(3, q.3)
            body(4, q.4)
        default:
            body(0, junctionChargeAndCapacitance(i, slot: 0, voltage(nodes[0]) - voltage(nodes[1])).charge)
        }
    }

    /// After each substep: the state of capacitors, inductors, op-amps' internal stages, vactrols and memristors
    private func updateDynamicStates() {
        let lists = nodeLists
        for i in junctionIndices {
            // (each slot's charge is worked out from its own history alone, all before any is stored)
            forEachStoredCharge(i, lists[i]) { slot, charge in
                let k = Self.chargeSlots * i + slot
                junctionCurrent[k] = (a0 * charge + a1 * junctionCharge[k] + a2 * junctionChargePrevious[k]) / h
                junctionChargeOlder[k] = junctionChargePrevious[k]
                junctionChargePrevious[k] = junctionCharge[k]
                junctionCharge[k] = charge
            }
            if kinds[i].isMOSFET {
                // the gate voltages and half capacitances the next step's Meyer charges start from
                let (vgs, vds, vbs) = (limitedVoltage[i], limitedVoltage2[i], limitedVoltage3[i])
                let half = mosfets[i].meyer(vgs: vgs, vgd: vgs - vds,
                                            mosfets[i].currents(vgs: vgs, vds: vds, vbs: vbs, gmin: Self.junctionGmin))
                meyerHistory[i] = MeyerHistory(vgs: vgs, vgd: vgs - vds, vgb: vgs - vbs, gs: half.gs, gd: half.gd, gb: half.gb)
            }
        }
        // the capacitors (a maker's model has dozens), each from its own history alone
        if !dynamicCapacitors.isEmpty {
            let (h, a0, a1, a2) = (self.h, self.a0, self.a1, self.a2)
            x.withUnsafeBufferPointer { x in
                constants.withUnsafeBufferPointer { constants in
                    capacitorCurrent.withUnsafeMutableBufferPointer { current in
                        capacitorVoltage.withUnsafeMutableBufferPointer { now in
                            capacitorVoltagePrevious.withUnsafeMutableBufferPointer { previous in
                                capacitorVoltageOlder.withUnsafeMutableBufferPointer { older in
                                    for i in dynamicCapacitors {
                                        let nodes = lists[i]
                                        let (p, n) = (nodes[0], nodes[1])
                                        let v = (p == 0 ? 0 : x[p - 1]) - (n == 0 ? 0 : x[n - 1])
                                        let c = constants[i].value
                                        current[i] = c / h * (a0 * v + a1 * now[i] + a2 * previous[i])
                                        older[i] = previous[i]
                                        previous[i] = now[i]
                                        now[i] = v
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        for i in dynamicOthers {
            let nodes = lists[i]
            let parameters = constants[i]
            switch kinds[i] {
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
                capacitorVoltage[i] = min(parameters.midpoint + bound, max(parameters.midpoint - bound, stage))
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
            case .comparator, .vco, .vcf, .envelope, .vca, .sampleHold, .divider, .levelDetector, .springReverb, .agcPreamp:
                updateModule(i, nodes, parameters)
            case .vuMeter:
                updateMeter(i, nodes, parameters)
            case .delayLine where parameters.duty >= 0.5:
                clockBucketBrigade(i, nodes, parameters)
            case .effectsProcessor where nodes.count == 6:
                // taken out while it runs: a copy left behind would make the first write copy its delay memory
                var processor = effectsProcessors.removeValue(forKey: i) ?? EffectsProcessor(program: Int(parameters.value))
                if processor.program != Int(parameters.value) { processor = EffectsProcessor(program: Int(parameters.value)) }
                processor.step(input: voltage(nodes[0]), pot0: voltage(nodes[1]), pot1: voltage(nodes[2]), pot2: voltage(nodes[3]),
                               supply: parameters.supply, dt: timeStep)
                effectsProcessors[i] = processor
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

    /// A bucket brigade clocked from its clock pin, over the last step: as many samples in and out as its clock ran
    /// cycles (counted from the oscillator driving it, else from the rising edges it saw)
    private func clockBucketBrigade(_ i: Int, _ nodes: [Int], _ c: Constants) {
        // taken out while it runs: a copy left behind would make the first write copy its buckets
        var brigade = bucketBrigades.removeValue(forKey: i) ?? BucketBrigade(stages: c.value)
        if brigade.buckets.count != BucketBrigade.count(c.value) { brigade = BucketBrigade(stages: c.value) }
        let input = voltage(nodes[0])
        var ticks = 0
        if let source = clockSources[i], source < moduleStates.count {
            let total = moduleStates[source].s1
            ticks = max(Int(total.rounded(.down) - brigade.cycles.rounded(.down)), 0)
            brigade.cycles = total
        } else {
            let high = Self.logicHigh(voltage(nodes[1]), was: brigade.clockHigh)
            if high && !brigade.clockHigh { ticks = 1 }
            brigade.clockHigh = high
        }
        brigade.clock(ticks, from: brigade.lastInput, to: input)
        brigade.lastInput = input
        brigade.rate += (Double(ticks) / timeStep - brigade.rate) * (1 - exp(-timeStep / 1e-3))
        bucketBrigades[i] = brigade
    }

    /// A VU meter's needle: the rectified voltage across it smoothed so a steady tone reads in 300 ms (VU), or its peaks
    /// held, rising in 10 ms and falling 20 dB in 1.5 s (a peak programme meter). Kept as the RMS level of a sine.
    private func updateMeter(_ i: Int, _ nodes: [Int], _ c: Constants) {
        guard nodes.count == 2 else { return }
        var s = moduleStates[i]
        // a sine's rectified average is 0.9 of its RMS
        let level = abs(voltage(nodes[0]) - voltage(nodes[1])) / 0.9003
        if c.value < 0.5 {
            s.level += (level - s.level) * (1 - exp(-timeStep / 0.065))
        } else if level > s.level {
            s.level += (level - s.level) * (1 - exp(-timeStep / 0.01))
        } else {
            s.level *= exp(-timeStep / 0.65)
        }
        moduleStates[i] = s
    }

    /// A VU meter's reading, in dB about its reference (0 dB at the reference RMS level); −60 dB at most below it
    public func meterReading(_ index: Int) -> Double {
        guard index < kinds.count, kinds[index] == .vuMeter, index < moduleStates.count else { return -60 }
        return max(20 * log10(max(moduleStates[index].level, 1e-12) / constants[index].threshold), -60)
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
        watchChipPins()
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
            // the bus devices wired to it follow its pins as it runs, and answer within the run
            if busWatches[i] != nil { chip.onPinEvent = { [unowned self] event in self.busEvent(i, event) } }
            if whole > 0 { chip.run(cycles: whole) }
            chip.onPinEvent = nil
            // the last instruction may run past the budget: the next step has that much less
            chipCycleCarry[i] = budget - Double(chip.cycles - start)
            let states = chip.pinStates
            if !Self.samePinSetup(states, chipPinStates[i]) { matrixIsCurrent = false }
            chipPinStates[i] = states
        }
        replayPinEvents()
    }

    /// Finds the logic parts' inputs wired to chips' pins, and has the chips log those pins
    private func watchChipPins() {
        chipWatches = [:]
        busWatches = [:]
        busLines = [:]
        for i in chipIndices {
            guard let chip = chips[i], i < topology.elementNodes.count else { continue }
            let chipNodes = topology.elementNodes[i]
            var byPin: [Int: [(element: Int, bit: Int)]] = [:]
            var busByPin: [Int: [(element: Int, bit: Int)]] = [:]
            for j in kinds.indices where kinds[j].isLogic && j < topology.elementNodes.count {
                let nodes = topology.elementNodes[j]
                let bus = kinds[j].isBusDevice
                for (bit, terminal) in kinds[j].logicInputs.enumerated() where terminal < nodes.count && nodes[terminal] > 0 {
                    for (pin, node) in chipNodes.enumerated() where node == nodes[terminal] {
                        if bus { busByPin[pin, default: []].append((j, bit)) } else { byPin[pin, default: []].append((j, bit)) }
                    }
                }
                // the line a bus device drives back: an ADC's DOUT, an I²C target's SDA
                let line = kinds[j] == .spiAdc ? 3 : 1
                if bus, line < nodes.count, nodes[line] > 0 {
                    for (pin, node) in chipNodes.enumerated() where node == nodes[line] { busLines[j, default: []].append((i, pin)) }
                }
            }
            chip.watchedPins = Set(byPin.keys).union(busByPin.keys).sorted()
            if !byPin.isEmpty { chipWatches[i] = byPin }
            if !busByPin.isEmpty { busWatches[i] = busByPin }
        }
    }

    /// A watched pin changing as a chip runs, for the bus devices that follow it: they move on at once, and what they
    /// drive back on the chip's pins (an ADC's DOUT bit, an I²C target's acknowledge) is what the chip reads from then
    private func busEvent(_ chipIndex: Int, _ event: PinEvent) {
        guard let targets = busWatches[chipIndex]?[event.pin] else { return }
        for target in targets {
            let old = logicStates[target.element]
            let mask = UInt32(1) << UInt32(target.bit)
            let inputs = event.high ? old.inputs | mask : old.inputs & ~mask
            guard inputs != old.inputs else { continue }
            let next = advanceLogic(target.element, old, inputs: inputs)
            for line in busLines[target.element] ?? [] {
                guard let chip = chips[line.chip], line.pin < chip.pinVoltages.count else { continue }
                let volts: Double
                switch kinds[target.element] {
                case .spiAdc:
                    // DOUT while CS is low; let go, it stays as the circuit last had it
                    guard next.inputs & 1 == 0 else { continue }
                    volts = next.count != 0 ? chip.supply : 0
                default:
                    // SDA held low while it acknowledges, else pulled up
                    volts = Logic.acknowledging(next) ? 0 : chip.supply
                }
                if chip.pinVoltages[line.pin] != volts { chip.pinVoltages[line.pin] = volts }
            }
        }
    }

    /// Plays what the chips did on the watched pins during their run into the logic parts wired to them, in the order
    /// it happened: an SPI word clocked out within one step reaches a DAC bit by bit
    private func replayPinEvents() {
        guard !chipWatches.isEmpty || !busWatches.isEmpty else { return }
        var events: [(time: Double, order: Int, chip: Int, event: PinEvent)] = []
        for (i, chip) in chips where chipWatches[i] != nil || busWatches[i] != nil {
            // (the bus devices had theirs as the chip ran)
            let taken = chip.takePinEvents()
            guard chipWatches[i] != nil else { continue }
            for event in taken {
                events.append((Double(event.cycle) / chip.clock, events.count, i, event))
            }
        }
        events.sort { ($0.time, $0.order) < ($1.time, $1.order) }
        for (_, _, i, event) in events {
            for target in chipWatches[i]?[event.pin] ?? [] {
                let old = logicStates[target.element]
                let mask = UInt32(1) << UInt32(target.bit)
                let inputs = event.high ? old.inputs | mask : old.inputs & ~mask
                guard inputs != old.inputs else { continue }
                advanceLogic(target.element, old, inputs: inputs)
            }
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
            // one volt per octave from the CV, or (a function generator's timing current, sensed across a resistor) a
            // frequency in proportion to the voltage from CV to PW; the phase runs from 0 to 1 once per cycle
            let linear = c.duty >= 0.5
            let wanted = linear ? c.gain * (in0 - in1) : c.frequency * pow(2, min(max(in0, -16), 16))
            let frequency = min(max(wanted, 0), 0.45 / dt)
            // the cycles run, uncapped: a bucket brigade it clocks counts them
            s.s1 += max(wanted, 0) * dt
            let increment = frequency * dt
            var phase = s.level + increment
            phase -= phase.rounded(.down)
            s.level = phase
            let duty = linear ? 0.5 : min(max(0.5 + in1 / 10, 0.05), 0.95)
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
            let gain = c.value < 0.5 ? pow(10, min(c.gain * (in1 - c.offset) / 20, 40.0 / 20)) : min(max(in1, 0) / c.threshold, 100)
            s.output = c.limit * tanh(gain * in0 / c.limit)
        case .agcPreamp:
            // the preamp; an RMS detector on its output (the mean square smoothed over the averaging time); and the gain
            // the VCA takes from it: none between the gate and the rotation point, falling by (1 − 1/ratio) dB for each
            // dB above the rotation point, and below the gate by a dB for each dB (an expander, down to −60 dB)
            let x = c.gain * (in0 - in1)
            s.level += (x * x - s.level) * (1 - exp(-dt / c.tau))
            let level = 20 * log10(max(s.level.squareRoot(), 1e-12) / c.threshold)
            let gate = 20 * log10(c.low / c.threshold)
            var db = 0.0
            if level > 0 {
                db = -(1 - 1 / c.value) * level
            } else if level < gate {
                db = max(level - gate, -60)
            }
            s.s1 = pow(10, db / 20)
            s.output = c.limit * tanh(s.s1 * x / c.limit)
        case .levelDetector:
            // the input against its reference pin, smoothed: attack while it rises, release while it falls
            let x = in0 - in1
            func smooth(_ target: Double) {
                let tau = target > s.level ? c.tau : c.voff
                s.level = tau > 0 ? s.level + (target - s.level) * (1 - exp(-dt / tau)) : target
            }
            switch Int(c.value) {
            case 0:
                // mean square, then its root in dB about the reference, so many millivolts per dB
                smooth(x * x)
                s.output = c.gain * 20 * log10(max(s.level.squareRoot(), 1e-6) / c.threshold)
            case 1:
                smooth(abs(x))
                s.output = s.level
            case 2:
                if abs(x) > s.level {
                    s.level = c.tau > 0 ? s.level + (abs(x) - s.level) * (1 - exp(-dt / c.tau)) : abs(x)
                } else {
                    s.level *= c.voff > 0 ? exp(-dt / c.voff) : 0
                }
                s.output = s.level
            default:
                s.output = abs(x)
            }
        case .springReverb:
            // the input coil's voltage drives the springs; the output coil gives back what arrives
            // (worked on in place: copying the springs out and back would copy their delay lines at every step)
            let out = springTanks[i, default: SpringTank()].process(in0 - in1, dt: dt, decay: c.value, delay: c.tau, dispersion: c.duty)
            s.output = c.gain * out
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
            let saturating = element.saturates && i < constants.count
            return twoTerminal(inductorCurrent[i] + (saturating ? coreCurrent(i, flux: constants[i].value * inductorCurrent[i]).current : 0))
        case .dcVoltage, .acVoltage, .squareVoltage, .noiseVoltage, .keyboardPitch, .keyboardGate, .audioInput:
            let row = topology.sourceRow[i]
            return twoTerminal(row >= 0 && row < x.count ? x[row] : 0)
        case .currentSource:
            return twoTerminal(constants[i].value)
        case .diode, .led, .zener:
            let d = diodes[i]
            let anode = d.hasSeriesNode ? nodes[2] : nodes[0]
            return twoTerminal(d.current(v(anode) - v(nodes[1]), gmin: Self.junctionGmin).current + junctionCurrent[Self.chargeSlots * i])
        case .memristor:
            return twoTerminal((v(nodes[0]) - v(nodes[1])) * memristorConductance(i, state: memristorStates[i]))
        case .behavioralSource:
            let current = behaviorCurrent(i, v)
            var out = [Double](repeating: 0, count: nodes.count)
            if out.count >= 2 { (out[0], out[1]) = (-current, current) }
            return (current, out)
        case .njfet, .pjfet:
            let j = jfets[i]
            let n = Self.jfetNodes({ nodes[$0] }, j)
            let p = j.polarity
            let r = j.currents(vgs: p * (v(n.g) - v(n.sp)), vgd: p * (v(n.g) - v(n.dp)), gmin: Self.junctionGmin)
            // with the gate charges' charging currents, gate to source and gate to drain
            let k = Self.chargeSlots * i
            let (gs, gd) = (p * (r.cg - r.cgd + junctionCurrent[k]), p * (r.cgd + junctionCurrent[k + 1]))
            let drain = p * r.cdrain - gd
            return (drain, [-(gs + gd), -drain, gs + gd + drain])
        case .nmos, .pmos:
            let f = mosfets[i]
            let n = Self.fetNodes({ nodes[$0] }, drain: f.hasDrainNode, source: f.hasSourceNode)
            let t = f.type
            let r = f.currents(vgs: t * (v(n.g) - v(n.sp)), vds: t * (v(n.dp) - v(n.sp)), vbs: t * (v(n.s) - v(n.sp)),
                               gmin: Self.junctionGmin)
            // with the stored charges' charging currents: bulk to drain and to source, gate to source, drain and bulk
            let k = Self.chargeSlots * i
            let cbd = r.cbd + junctionCurrent[k]
            let (igs, igd, igb) = (junctionCurrent[k + 2], junctionCurrent[k + 3], junctionCurrent[k + 4])
            // into the gate, the drain, and the source with the bulk
            let gate = t * (igs + igd + igb)
            let drain = t * (r.mode * r.cdrain - cbd - igd)
            return (drain, [-gate, -drain, gate + drain])
        case .npn, .pnp:
            let p: Double = element.kind == .npn ? 1 : -1
            let g = bipolar[i]
            let n = Self.bipolarNodes({ nodes[$0] }, g)
            let r = g.currents(vbe: p * (v(n.bp) - v(n.ep)), vbc: p * (v(n.bp) - v(n.cp)), gmin: Self.junctionGmin)
            // with the stored charges' charging currents: base to emitter, base to collector inside and outside the
            // base resistance
            let k = Self.chargeSlots * i
            let (be, bc, bx) = (p * junctionCurrent[k], p * junctionCurrent[k + 1], p * junctionCurrent[k + 2])
            let (ic, ib) = (p * r.cc - bc - bx, p * r.cb + be + bc + bx)
            return (ic, [-ib, -ic, ic + ib])
        case .opAmp, .multiplier, .comparator, .delayLine, .digitalDelay, .vco, .vcf, .envelope, .vca, .sampleHold, .divider,
             .levelDetector:
            let row = topology.sourceRow[i]
            let current = row >= 0 && row < x.count ? x[row] : 0
            return (current, [0, 0, current])
        case .springReverb:
            let row = topology.sourceRow[i]
            let current = row >= 0 && row < x.count ? x[row] : 0
            let coil = (v(nodes[0]) - v(nodes[1])) * constants[i].onConductance
            return (current, [-coil, coil, current])
        case .triode, .pentode:
            let tube = constants[i].tube
            let vgk = v(nodes[0]) - v(nodes[2])
            let vpk = v(nodes[1]) - v(nodes[2])
            let ig = tube.grid(vgk: vgk).current
            if element.kind == .pentode, nodes.count > 3 {
                let t = tube.pentode(vgk: vgk, vsk: v(nodes[3]) - v(nodes[2]), vpk: vpk)
                return (t.plate, [-ig, -t.plate, t.plate + t.screen + ig, -t.screen])
            }
            let ip = tube.triode(vgk: vgk, vpk: vpk).current
            return (ip, [-ig, -ip, ip + ig])
        case .transformer:
            // the part itself; its core carries the currents (see `Circuit.expandModels`)
            let row = topology.sourceRow[i]
            let current = row >= 0 && row < x.count ? x[row] : 0
            let r = constants[i].value
            // out of the core: the secondary's current at s1, back in at s2; the primary's comes in at p1
            return (current, [-r * current, r * current, current, -current])
        case .vactrol:
            let c = constants[i]
            let led = diodeCurrent(v(nodes[0]) - v(nodes[1]), saturation: c.saturation, nvt: c.nvt).current
            let ldr = (v(nodes[2]) - v(nodes[3])) * vactrolConductance(i)
            return (led, [-led, led, -ldr, ldr])
        case .ota:
            let supply = constants[i].supply
            let bias = otaBias(i, junction: v(nodes[3]) + supply).current
            let level = constants[i].clampLevel
            let vt = self.vt
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
        case .logicGate, .flipFlop, .decadeCounter, .binaryCounter, .shiftRegister, .pll:
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
        case .dualDac, .i2sDac, .i2cDac:
            // into each analog output from its source behind the output resistance
            var flows = [Double](repeating: 0, count: nodes.count)
            let c = constants[i]
            let state = logicStates[i]
            let outputs: [(Int, Double)]
            switch element.kind {
            case .dualDac:
                outputs = (0...1).map { (4 + $0, Logic.dualDacOutput(state.count, channel: $0, supply: c.supply)) }
            case .i2sDac:
                outputs = [(3, Logic.i2sOutput(Int32(bitPattern: state.latch))), (4, Logic.i2sOutput(Int32(truncatingIfNeeded: state.count)))]
            default:
                outputs = [(3, Logic.i2cDacOutput(state.count, supply: c.supply))]
            }
            for (k, target) in outputs where k < nodes.count { flows[k] = (target - v(nodes[k])) * c.outputConductance }
            return (outputs.first.map { flows[$0.0] } ?? 0, flows)
        case .effectsProcessor:
            var flows = [Double](repeating: 0, count: nodes.count)
            guard nodes.count > 5, let processor = effectsProcessors[i] else { return (0, flows) }
            let g = constants[i].outputConductance
            flows[4] = (processor.left - v(nodes[4])) * g
            flows[5] = (processor.right - v(nodes[5])) * g
            return (flows[4], flows)
        case .dac:
            var flows = [Double](repeating: 0, count: nodes.count)
            guard nodes.count > 5 else { return (0, flows) }
            let c = constants[i]
            let target = Logic.dacOutput(logicStates[i].count, reference: v(nodes[4]), supply: c.supply)
            flows[5] = (target - v(nodes[5])) * c.outputConductance
            return (flows[5], flows)
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
        let elements = flat.elements
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
        let kind = kinds[index]
        if kind == .behavioralSource, let (plus, minus) = acrossNodes(index) { return voltage(plus) - voltage(minus) }
        if kind.isMicrocontroller || kind.hasChipPackage { return constants[index].supply }
        guard let (plus, minus) = acrossNodes(index) else { return 0 }
        return voltage(plus) - voltage(minus)
    }

    /// The nodes `voltageAcross` reads, plus then minus (0 is ground); nil for parts it reads no nodes of
    public func acrossNodes(_ index: Int) -> (plus: Int, minus: Int)? {
        guard index < topology.elementNodes.count, index < kinds.count else { return nil }
        let nodes = topology.elementNodes[index]
        if nodes.count == 1 { return (nodes[0], 0) }
        guard nodes.count >= 2 else { return nil }
        let kind = kinds[index]
        if kind.isTransistor || kind.isTube { return (nodes[1], nodes[2]) }
        if kind == .transformer { return nodes.count == 4 ? (nodes[2], nodes[3]) : nil }
        if kind == .ota || kind.drivesOutput { return (nodes[2], 0) }
        if kind == .timer555 { return (nodes[2], nodes[0]) }
        if kind == .behavioralSource { return (nodes[0], nodes[1]) }
        if kind.isMicrocontroller || kind.hasChipPackage || kind == .block { return nil }
        if kind == .schmittInverter || kind == .unbufferedInverter { return (nodes[1], 0) }
        if kind == .logicGate { return (nodes[2], 0) }
        return kind.isVoltageSource ? (nodes[1], nodes[0]) : (nodes[0], nodes[1])
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
            let element = flat.elements[index]
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
        let element = flat.elements[index]
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

    /// An SPI ADC's last conversion (0 to 1023)
    public func adcReading(_ index: Int) -> Int {
        guard index < kinds.count, index < logicStates.count, kinds[index] == .spiAdc else { return 0 }
        return Int(logicStates[index].latch)
    }

    /// 0 (open) to 1 (closed) for analog switches
    public func switchConduction(_ index: Int) -> Double {
        guard index < flat.elements.count, flat.elements[index].kind == .analogSwitch else { return 0 }
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

    /// The equations' size: unknowns, entries that can be non-zero, entries of the factors (fill-in included), and the
    /// unknowns in the nonlinear block, which Newton-Raphson refactors
    public var equationStatistics: (unknowns: Int, nonzeros: Int, factorEntries: Int, nonlinearUnknowns: Int) {
        let m = topology.matrixSize
        guard let plan else { return (m, 0, 0, 0) }
        let nonzeros = plan.structure.reduce(0) { $1 ? $0 + 1 : $0 }
        return (m, nonzeros, plan.entryCount, plan.n - plan.leading)
    }

    /// The nonlinear block's factors as last factored: entries of L and U, and the multiply-adds of factoring
    public var blockFactorSize: (lower: Int, upper: Int, operations: Int) {
        plan?.blockFactorSize ?? (0, 0, 0)
    }

    /// Pivot orders the plan has for its nonlinear block (one for each state its parts have been seen in, up to a few)
    public var pivotOrders: Int {
        plan?.orderCount ?? 0
    }

    /// The index of a part of the circuit as it is simulated: one of the circuit's own, or one inside a block (by its
    /// id there, `UUID.inBlock`)
    public func flatIndex(of id: UUID) -> Int? {
        flat.elements.firstIndex { $0.id == id }
    }

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
            // a frequency response is worked out when shown, not recorded
            guard spec.plot != .frequencyResponse, let trace = next[spec.id], let index = circuit.index(of: spec.elementID) else { return nil }
            return (trace, index)
        }
    }

    public func trace(_ id: UUID) -> ScopeTrace? { traces[id] }

    private func record(_ trace: ScopeTrace, _ index: Int) {
        func scoped() -> Double {
            switch trace.spec.quantity {
            case .current: return scopedCurrent(index)
            case .power: return voltageAcross(index) * scopedCurrent(index)
            default: return value(trace.spec.quantity, of: index)
            }
        }
        switch trace.spec.plot {
        case .time:
            trace.add(scoped(), at: time)
        case .spectrum:
            trace.addSample(scoped(), at: time)
        case .currentVersusVoltage:
            trace.addPoint(voltage: voltageAcross(index), current: scopedCurrent(index), at: time)
        case .frequencyResponse:
            break
        }
    }

    /// One element's current for a scope at every step, without working out the whole circuit's: only wires and
    /// other conductors need the walk through the wire network
    private func scopedCurrent(_ index: Int) -> Double {
        let element = flat.elements[index]
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
    /// For a spectrum: the newest `spectrumLength` values at even intervals (between steps, on the line joining them)
    private var ring: [Double] = []
    private var ringNext = 0
    private var ringCount = 0
    private var nextTick = 0.0
    private var previousTime = 0.0
    private var previousValue = 0.0
    private var sampling = false
    /// The simulation's recent step, on average: the spectrum shows nothing faster than it can follow
    private var averageStep = 0.0

    /// Samples a spectrum is worked out from: eight windows' worth, 2048 a window
    public static let spectrumLength = 16_384

    init(spec: ScopeSpec, window: Double) {
        self.spec = spec
        self.window = max(window, 1e-12)
        if spec.plot == .spectrum { ring = [Double](repeating: 0, count: Self.spectrumLength) }
    }

    /// Seconds between a spectrum's samples
    public var sampleInterval: Double { window / 2048 }

    var interval: Double { window / Double(Self.capacity) }

    /// Copies another trace's history
    func adopt(_ other: ScopeTrace) {
        Simulator.adopt(&minimums, other.minimums)
        Simulator.adopt(&maximums, other.maximums)
        lastValue = other.lastValue
        Simulator.adopt(&voltages, other.voltages)
        Simulator.adopt(&currents, other.currents)
        lastVoltage = other.lastVoltage
        bucketStart = other.bucketStart
        bucketMin = other.bucketMin
        bucketMax = other.bucketMax
        Simulator.adopt(&ring, other.ring)
        ringNext = other.ringNext
        ringCount = other.ringCount
        nextTick = other.nextTick
        previousTime = other.previousTime
        previousValue = other.previousValue
        sampling = other.sampling
        averageStep = other.averageStep
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
        ringNext = 0
        ringCount = 0
        sampling = false
        averageStep = 0
    }

    /// Records a value for a spectrum: one sample at each tick of `sampleInterval` passed since the last value,
    /// on the line from it
    func addSample(_ value: Double, at time: Double) {
        guard value.isFinite, !ring.isEmpty else { return }
        lastValue = value
        let interval = sampleInterval
        if !sampling || time < previousTime {
            sampling = true
            ringNext = 0
            ringCount = 0
            averageStep = 0
            nextTick = time
        } else {
            let step = time - previousTime
            if step > 0 { averageStep = averageStep == 0 ? step : averageStep * 0.98 + step * 0.02 }
        }
        // after a long gap only the newest ring's worth matters
        if (time - nextTick) / interval > Double(ring.count) { nextTick = time - Double(ring.count - 1) * interval }
        let span = time - previousTime
        while nextTick <= time {
            let f = span > 0 ? min(max((nextTick - previousTime) / span, 0), 1) : 1
            ring[ringNext] = previousValue + (value - previousValue) * f
            ringNext = (ringNext + 1) % ring.count
            ringCount = min(ringCount + 1, ring.count)
            nextTick += interval
        }
        previousTime = time
        previousValue = value
    }

    /// The spectrum's samples, oldest first
    public var evenSamples: [Double] {
        guard ringCount > 0 else { return [] }
        let start = (ringNext - ringCount + ring.count) % ring.count
        return (0..<ringCount).map { ring[(start + $0) % ring.count] }
    }

    /// The spectrum of the recent samples, up to the highest frequency both the sampling and the simulation's steps
    /// show; nil until there are enough
    public func spectrum() -> Spectrum? {
        let top = averageStep > 0 ? 0.5 / averageStep : .infinity
        return Spectrum.analyze(evenSamples, interval: sampleInterval, maxFrequency: top)
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
