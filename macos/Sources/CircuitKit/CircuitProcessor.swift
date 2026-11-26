import Foundation

/// A circuit as an audio processor, a block of samples at a time, as a plugin runs it: the host's sound goes into its
/// audio input parts, what its speaker hears comes out, its knobs and switches are the plugin's parameters, and notes
/// play its keyboard sources (the last note held sounds, as on a monophonic synth).
///
/// Not thread-safe: the host's audio thread calls `process`; parameters and notes are set between blocks. `process`,
/// the notes and `takeOver(from:)` allocate nothing of their own (what `Simulator.step` does inside is the simulator's);
/// `set` does (it rebuilds the simulator's parts at the next block), which is why the Audio Unit moves knobs through
/// `PluginEngine` instead.
public final class CircuitProcessor {
    /// A knob or switch of the circuit, at the top level or inside a block
    public struct Control: Sendable, Equatable {
        public var name: String
        /// A pot's position, or a switch's state (1 closed)
        public var value: Double
        public var isSwitch: Bool
        /// The part, or the block part that holds it
        public var part: UUID
        /// For a control inside a block: its id in the block's circuit
        public var inner: UUID?
    }

    /// How a new processor starts
    public enum Start: Sendable {
        /// From where the circuit rests, its coupling capacitors charged (up to a second of circuit time simulated)
        case settled
        /// From rest, but having stepped once or twice so that its matrices, plan and delay lines are made: for one
        /// that will take over another's running state (`takeOver(from:)`) on the render thread
        case primed
    }

    public private(set) var circuit: Circuit
    public private(set) var controls: [Control]
    public let sampleRate: Double
    /// Whether the circuit takes the host's sound (an effect) and plays notes (an instrument)
    public let hasInput: Bool
    public let hasKeyboard: Bool
    /// Simulation steps per audio sample
    public let oversampling: Int
    /// The most samples one simulated chunk takes (longer calls of `process` are run in chunks)
    public let maximumFrames: Int
    /// Equal for two processors whose simulations have the same parts wired into the same equations: one can take over
    /// the other's state
    public let shapeKey: Int

    let simulator: Simulator
    /// A second simulator of the same circuit that never runs, for `takeOver(from:)` (primed processors only)
    private let blank: Simulator?
    private let speaker: Int
    private let fullScale: Double
    /// The host's sound for the present chunk, allocated once (two samples longer than a chunk: the last is held)
    private var input: [Float]
    private var blockerInput = 0.0
    private var blockerOutput = 0.0
    private let blockerPole: Double
    /// Notes held, oldest first, in storage allocated once
    private var held: [Int]
    private var heldCount = 0
    private var pendingParameters = false

    /// Nil when the circuit has no speaker to listen to
    public init?(circuit: Circuit, sampleRate: Double, oversampling: Int = 2, start: Start = .settled, maximumFrames: Int = 4096) {
        var circuit = circuit
        guard let speaker = circuit.elements.firstIndex(where: { $0.kind == .speaker }) else { return nil }
        // every audio input part plays the host's sound
        func live(_ elements: inout [Element]) {
            for i in elements.indices {
                if elements[i].kind.playsClip { elements[i][param: "input"] = 1 }
                if var block = elements[i].block {
                    live(&block.circuit.elements)
                    elements[i].block = block
                }
            }
        }
        live(&circuit.elements)
        let flat = circuit.flattened()
        hasInput = flat.elements.contains { $0.kind == .audioInput }
        hasKeyboard = flat.elements.contains { $0.kind == .keyboardPitch || $0.kind == .keyboardGate }
        self.circuit = circuit
        self.sampleRate = sampleRate
        self.speaker = speaker
        self.oversampling = max(1, oversampling)
        self.maximumFrames = max(1, maximumFrames)
        input = [Float](repeating: 0, count: self.maximumFrames + 2)
        held = [Int](repeating: 0, count: 128)
        fullScale = max(circuit.elements[speaker][param: "fullScale"], 1e-3)
        blockerPole = exp(-2 * .pi * 4 / sampleRate)
        controls = Self.controls(of: circuit)
        let timeStep = 1 / (sampleRate * Double(self.oversampling))
        simulator = Simulator(circuit: circuit, timeStep: timeStep)
        simulator.errorControl = false
        var hasher = Hasher()
        hasher.combine(simulator.topology.matrixSize)
        for element in simulator.flat.elements {
            hasher.combine(element.id)
            hasher.combine(element.kind)
        }
        for nodes in simulator.topology.elementNodes { hasher.combine(nodes) }
        hasher.combine(self.oversampling)
        hasher.combine(sampleRate)
        shapeKey = hasher.finalize()
        switch start {
        case .settled:
            blank = nil
            // start from where the circuit rests, its coupling capacitors charged
            for _ in 0..<Int(min(Simulator.settling(circuit).duration, 1) * sampleRate * Double(self.oversampling)) where !simulator.isFailed {
                simulator.step()
            }
        case .primed:
            let blank = Simulator(circuit: circuit, timeStep: timeStep)
            blank.errorControl = false
            self.blank = blank
            // what the first steps make (the factoring plan, the base matrices, the delay lines' storage) made here,
            // not on the render thread
            var silence = [Float](repeating: 0, count: 4)
            for _ in 0..<2 {
                silence.withUnsafeMutableBufferPointer { run(nil, $0.baseAddress!, 1) }
            }
            (blockerInput, blockerOutput) = (0, 0)
        }
    }

    /// The circuit's knobs and switches, in the order of the front panel
    public static func controls(of circuit: Circuit) -> [Control] {
        func control(_ element: Element, name: String, part: UUID, inner: UUID?) -> Control? {
            switch element.kind {
            case .potentiometer:
                return Control(name: name, value: element[param: "position"], isSwitch: false, part: part, inner: inner)
            case .toggleSwitch, .pushButton, .footswitch, .jack:
                return Control(name: name, value: element.closed ? 1 : 0, isSwitch: true, part: part, inner: inner)
            default:
                return nil
            }
        }
        var found: [(place: (Int, Int), control: Control)] = []
        for element in circuit.elements {
            let place = (min(element.a.x, element.b.x), min(element.a.y, element.b.y))
            if let c = control(element, name: element.name, part: element.id, inner: nil) { found.append((place, c)) }
            for inner in element.block?.circuit.elements ?? [] {
                if let c = control(inner, name: "\(element.name) \(inner.name)", part: element.id, inner: inner.id) { found.append((place, c)) }
            }
        }
        return found.sorted { $0.place < $1.place }.map(\.control)
    }

    /// Sets `control` to `value` (0 to 1) in `circuit`
    public static func apply(_ control: Control, _ value: Double, to circuit: inout Circuit) {
        func apply(_ element: inout Element) {
            if control.isSwitch { element.closed = value >= 0.5 } else { element[param: "position"] = value }
        }
        guard let i = circuit.index(of: control.part) else { return }
        if let inner = control.inner {
            guard var block = circuit.elements[i].block, let j = block.circuit.index(of: inner) else { return }
            apply(&block.circuit.elements[j])
            circuit.elements[i].block = block
        } else {
            apply(&circuit.elements[i])
        }
    }

    /// Moves a knob or switch, 0 to 1; it takes effect at the next block. (Not for a render thread: the next block
    /// rebuilds the simulator's parts.)
    public func set(_ index: Int, to value: Double) {
        guard controls.indices.contains(index) else { return }
        let value = min(max(value, 0), 1)
        guard controls[index].value != value else { return }
        controls[index].value = value
        Self.apply(controls[index], value, to: &circuit)
        pendingParameters = true
    }

    // MARK: - Notes

    private func release(_ note: Int) {
        var k = 0
        while k < heldCount {
            if held[k] == note {
                for j in k..<(heldCount - 1) { held[j] = held[j + 1] }
                heldCount -= 1
            } else {
                k += 1
            }
        }
    }

    public func noteOn(_ note: Int) {
        release(note)
        if heldCount == held.count {
            // (more keys than a keyboard has: the oldest is forgotten)
            for j in 0..<(heldCount - 1) { held[j] = held[j + 1] }
            heldCount -= 1
        }
        held[heldCount] = note
        heldCount += 1
        simulator.keyboard = Simulator.KeyboardState(note: Double(note), gate: true)
    }

    public func noteOff(_ note: Int) {
        release(note)
        // back to the last note still held, or the gate closes on the note that was playing
        simulator.keyboard = heldCount > 0
            ? Simulator.KeyboardState(note: Double(held[heldCount - 1]), gate: true)
            : Simulator.KeyboardState(note: simulator.keyboard.note, gate: false)
    }

    public func allNotesOff() {
        heldCount = 0
        simulator.keyboard.gate = false
    }

    /// Takes on the notes held on `other`'s keyboard
    public func takeNotes(from other: CircuitProcessor) {
        heldCount = min(other.heldCount, held.count)
        for k in 0..<heldCount { held[k] = other.held[k] }
        simulator.keyboard = other.simulator.keyboard
    }

    // MARK: - Taking over

    /// Carries on from where `old` is: its circuit's state (charges, currents, the solution, delay lines and reverbs),
    /// time, notes and output filter, with this processor's knob positions. For a primed processor of the same shape
    /// (`shapeKey`), and an `old` that has not failed; false (and nothing changed) otherwise.
    ///
    /// Meant for the render thread, where `old` was playing until now: nothing large is freed here. The state moves in
    /// three steps so that no buffer is ever left with no owner: the blank simulator first keeps what this one made
    /// while priming, then this one takes `old`'s state (sharing `old`'s delay-line histories), then `old` takes the
    /// blank's, so that this processor is the only owner of the histories it now writes to (sharing them would make
    /// its next step copy them). `old` is left holding the primed leftovers and must not be played again.
    @discardableResult
    public func takeOver(from old: CircuitProcessor) -> Bool {
        guard let blank, old !== self, old.shapeKey == shapeKey, !old.simulator.isFailed else { return false }
        blank.adoptState(of: simulator, delays: true)
        simulator.adoptState(of: old.simulator, delays: true)
        old.simulator.adoptState(of: blank, delays: true)
        (blockerInput, blockerOutput) = (old.blockerInput, old.blockerOutput)
        takeNotes(from: old)
        return true
    }

    /// Starts again from rest, keeping the controls where they are
    public func reset() {
        simulator.reset()
        blockerInput = 0
        blockerOutput = 0
    }

    /// Whether the circuit has stopped converging (its output is then silence)
    public var isFailed: Bool { simulator.isFailed }

    // MARK: - Running

    /// Runs the circuit for `frames` samples: `input` (mono, or nil for silence) into its audio inputs, its speaker
    /// into `output`, scaled so the speaker's full scale is 1 and bent softly above 0.7 instead of clipping
    public func process(input samples: UnsafePointer<Float>?, output: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            let count = min(frames - done, maximumFrames)
            run(samples.map { $0 + done }, output + done, count)
            done += count
        }
    }

    private func run(_ samples: UnsafePointer<Float>?, _ output: UnsafeMutablePointer<Float>, _ frames: Int) {
        if pendingParameters {
            pendingParameters = false
            if !simulator.updateParameters(circuit) { simulator.load(circuit) }
        }
        if hasInput {
            // the simulator lets go of the last chunk's samples first, so they are written in place (sharing them
            // would make each chunk copy them)
            simulator.liveInput = nil
            for k in 0..<frames { input[k] = samples?[k] ?? 0 }
            // the last sample holds past the chunk's end (the simulator interpolates between neighbours)
            let last = input[max(frames - 1, 0)]
            input[frames] = last
            input[frames + 1] = last
            simulator.liveInput = Simulator.LiveInput(samples: input, sampleRate: sampleRate, startTime: simulator.time)
        }
        for n in 0..<frames {
            var sum = 0.0
            if !simulator.isFailed {
                for _ in 0..<oversampling {
                    simulator.step()
                    sum += simulator.voltageAcross(speaker)
                }
            }
            let x = sum / Double(oversampling) / fullScale
            // the speaker hears changes, not a constant offset
            let y = x - blockerInput + blockerPole * blockerOutput
            blockerInput = x
            blockerOutput = y
            output[n] = Float(Self.limit(y))
        }
    }

    /// Above 0.7 of full scale the output bends softly towards 1 instead of clipping
    static func limit(_ y: Double) -> Double {
        guard y.isFinite else { return 0 }
        let magnitude = abs(y)
        guard magnitude > 0.7 else { return y }
        let bent = 0.7 + 0.3 * tanh((magnitude - 0.7) / 0.3)
        return y < 0 ? -bent : bent
    }
}

// MARK: - The Audio Unit's engine

/// A circuit played by an Audio Unit, split so that the host's render thread never waits, allocates or rebuilds:
///
/// - The render thread owns the processor playing. It calls `beginRender()` at the top of each render call, plays
///   `processor`, passes knob moves from the host's events to `requestControl`, and ends with `endRender`.
/// - Everything else (a knob moved in the plugin's window or by the host, a preset, a new sample rate, a circuit too
///   heavy) changes the model here, and a background queue prepares a complete processor for it, which the render
///   thread picks up at its next call by swapping one reference. A knob that leaves the circuit's equations the same
///   shape gets a primed processor that takes over the running state (`CircuitProcessor.takeOver`), so the sound
///   carries on; anything else (a new circuit, a switch that joins or parts nodes) a settled one, from rest.
/// - Processors the render thread is done with go back through a retire list and are freed on the background queue.
public final class PluginEngine: @unchecked Sendable {
    /// What the plugin's window shows about the render thread
    public struct Status: Sendable, Equatable {
        /// Time spent rendering over the time the buffers last, recently
        public var load = 0.0
        /// The circuit has recently been too heavy for the host's buffer
        public var overloaded = false
        /// Simulation steps per audio sample now (fewer than `PluginEngine.oversampling` once lowered to keep up)
        public var stepsPerSample = 0
        /// The circuit stopped converging (it is silent until a knob moves or another circuit is chosen)
        public var failed = false
        public init() {}
    }

    /// Steps per sample a circuit starts with
    public static let oversampling = 2
    /// The most knobs and switches the hand-off holds
    public static let maximumControls = 256

    /// What the background queue offers the render thread: a processor (nil: silence, the circuit has no speaker) and
    /// whether it carries on from the one playing or starts afresh
    final class Prepared {
        let processor: CircuitProcessor?
        let continues: Bool
        init(_ processor: CircuitProcessor?, continues: Bool) {
            self.processor = processor
            self.continues = continues
        }
    }

    // the model, under `modelLock` (never taken on the render thread)
    private let modelLock = TryLock()
    private var base: Circuit?
    private var controlList: [CircuitProcessor.Control] = []
    /// Bumped for each change that needs a processor started afresh
    private var generation = 0
    private var sampleRate: Double?
    private var maximumFrames = 4096
    private var steps = PluginEngine.oversampling
    /// Knob positions: the model's, and the render thread's way to move them
    private let values = ParameterTable(capacity: PluginEngine.maximumControls)

    // between the threads
    private let exchange = ObjectExchange(retireCapacity: 8)
    private let reportLock = TryLock()
    private var report = Status()
    private var askedAfresh = false
    private var askedFewerSteps = 0

    // the background queue's own
    private let queue = DispatchQueue(label: "org.knowm.jspice.audiounit.prepare", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var builtGeneration = -1
    private var builtVersion: UInt64 = .max
    private var offeredShape: Int?

    // the render thread's own
    private var live: Prepared?
    /// The one replaced, until the exchange takes it (as `AnyObject` so that it is moved, not copied, into the retire
    /// list: see `ObjectExchange.tryRetire`)
    private var retiring: AnyObject?
    private let pending = PendingParameters(capacity: PluginEngine.maximumControls)
    private var monitor = RenderLoadMonitor()
    private var wantsAfresh = false
    /// Steps per sample of the processor the render thread asked to run fewer steps than (0: not asked)
    private var wantsFewerThan = 0

    public init() {}

    deinit {
        timer?.cancel()
    }

    // MARK: Any thread but the render thread

    /// Plays another circuit (prepared in the background: the one playing goes on until it is ready)
    public func load(_ circuit: Circuit) {
        modelLock.withLock {
            base = circuit
            controlList = CircuitProcessor.controls(of: circuit)
            values.reset(controlList.map(\.value))
            generation += 1
            steps = Self.oversampling
        }
        schedule()
    }

    /// The circuit's knobs and switches (their values as loaded; `controlValue` has where they are now)
    public var controls: [CircuitProcessor.Control] { modelLock.withLock { controlList } }

    /// Moves a knob or switch, 0 to 1. Only a store under a lock held for a few instructions, and nothing allocated
    /// (some hosts set parameters from their own audio threads): the background queue, which looks every few
    /// milliseconds while rendering, prepares the processor for it.
    public func setControl(_ index: Int, _ value: Double) {
        values.set(index, min(max(value, 0), 1))
    }

    public func controlValue(_ index: Int) -> Double { values.value(index) }

    /// The circuit as loaded, with its knobs and switches where they are now
    public var circuit: Circuit? {
        let (circuit, controls, now) = modelLock.withLock { (base, controlList, values.snapshot().values) }
        guard var circuit else { return nil }
        for (k, control) in controls.enumerated() where k < now.count {
            CircuitProcessor.apply(control, now[k], to: &circuit)
        }
        return circuit
    }

    /// Prepares for rendering at a sample rate: the first processor is made before this returns, so the first render
    /// call plays the circuit
    public func allocate(sampleRate: Double, maximumFrames: Int) {
        modelLock.withLock {
            self.sampleRate = sampleRate
            self.maximumFrames = max(maximumFrames, 1)
            generation += 1
            steps = Self.oversampling
        }
        queue.sync { prepare() }
        startPolling()
    }

    /// Rendering has stopped
    public func deallocate() {
        timer?.cancel()
        timer = nil
        modelLock.withLock { sampleRate = nil }
        let withdrawn = exchange.withdraw()
        queue.async {
            _ = withdrawn
            self.builtGeneration = -1
            self.offeredShape = nil
            _ = self.exchange.collectRetired()
        }
    }

    /// What the render thread last reported
    public var status: Status { reportLock.withLock { report } }

    /// Does now what the background queue does every few milliseconds, and waits for it (for tests)
    public func prepareNow() {
        queue.sync { prepare() }
    }

    private func schedule() {
        queue.async { [weak self] in self?.prepare() }
    }

    private func startPolling() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // knob moves from the host's render events, and what the render thread asks for, are picked up this often
        timer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.prepare() }
        timer.resume()
        self.timer = timer
    }

    /// On the background queue: frees what the render thread gave back, takes what it asked for, and prepares a
    /// processor if the model has moved on from the last one offered
    private func prepare() {
        _ = exchange.collectRetired()
        let (afresh, fewerThan) = reportLock.withLock { () -> (Bool, Int) in
            defer { (askedAfresh, askedFewerSteps) = (false, 0) }
            return (askedAfresh, askedFewerSteps)
        }
        let model = modelLock.withLock { () -> (circuit: Circuit?, controls: [CircuitProcessor.Control], generation: Int,
                                                rate: Double?, frames: Int, steps: Int, values: (version: UInt64, values: [Double])) in
            if fewerThan > 1 && fewerThan == steps {
                steps = max(1, steps / 2)
                generation += 1
            }
            if afresh { generation += 1 }
            return (base, controlList, generation, sampleRate, maximumFrames, steps, values.snapshot())
        }
        guard let rate = model.rate, var circuit = model.circuit else { return }
        guard model.generation != builtGeneration || model.values.version != builtVersion else { return }
        for (k, control) in model.controls.enumerated() where k < model.values.values.count {
            CircuitProcessor.apply(control, model.values.values[k], to: &circuit)
        }
        // a knob move carries on from the processor playing, unless one starting afresh is still waiting to be taken
        var continues = model.generation == builtGeneration
        if continues, let waiting = exchange.peek(), !unsafeDowncast(waiting, to: Prepared.self).continues { continues = false }
        var made: CircuitProcessor?
        if continues {
            made = CircuitProcessor(circuit: circuit, sampleRate: rate, oversampling: model.steps, start: .primed, maximumFrames: model.frames)
            // (a switch that joins or parts nodes changes the equations: that needs a settled start)
            if made == nil || made?.shapeKey != offeredShape { continues = false }
        }
        if !continues {
            made = CircuitProcessor(circuit: circuit, sampleRate: rate, oversampling: model.steps, start: .settled, maximumFrames: model.frames)
        }
        builtGeneration = model.generation
        builtVersion = model.values.version
        offeredShape = made?.shapeKey
        let replaced = exchange.offer(Prepared(made, continues: continues))
        _ = replaced  // released here, on the background queue
    }

    // MARK: The render thread

    /// The processor playing, after `beginRender()`
    public var processor: CircuitProcessor? { live?.processor }

    /// At the top of each render call: takes a prepared processor if one is waiting, gives back the one it replaced,
    /// and passes on knob moves and requests. Never waits: whatever finds another thread in the way waits for the next call.
    public func beginRender() {
        _ = exchange.tryRetire(&retiring)
        if retiring == nil, let object = exchange.tryTake() {
            let next = unsafeDowncast(object, to: Prepared.self)
            if !next.continues {
                if let new = next.processor, let old = live?.processor { new.takeNotes(from: old) }
                retiring = live
                live = next
                // a fresh start (another circuit, or fewer steps already) is judged afresh
                wantsFewerThan = 0
                monitor.restart()
            } else if let new = next.processor, let old = live?.processor, new.takeOver(from: old) {
                retiring = live
                live = next
            } else {
                // it cannot carry on from here (the circuit failed, or changed shape meanwhile): one is made afresh
                retiring = next
                wantsAfresh = true
            }
        }
        pending.flush(to: values)
    }

    /// A knob or switch moved by the host's render events (applied once a processor for it is ready, a few
    /// milliseconds later)
    public func requestControl(_ index: Int, _ value: Double) {
        pending.write(index, min(max(value, 0), 1), to: values)
    }

    /// At the end of each render call: `busy` seconds spent on a buffer lasting `budget` seconds. When the circuit
    /// cannot keep up it asks for fewer steps per sample, down to one, and the window shows it.
    public func endRender(busy: Double, budget: Double) {
        let steps = live?.processor?.oversampling ?? 0
        if monitor.record(busy: busy, budget: budget), steps > 1, wantsFewerThan == 0 { wantsFewerThan = steps }
        guard reportLock.tryLock() else { return }
        report.load = monitor.load
        report.overloaded = monitor.overloaded
        report.stepsPerSample = steps
        report.failed = live?.processor?.isFailed ?? false
        if wantsAfresh {
            askedAfresh = true
            wantsAfresh = false
        }
        if wantsFewerThan > 0 && askedFewerSteps == 0 { askedFewerSteps = wantsFewerThan }
        reportLock.unlock()
    }
}
