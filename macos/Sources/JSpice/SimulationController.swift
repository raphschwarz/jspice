import Foundation
import QuartzCore
import CircuitKit

/// Runs one window's simulation against the display's refresh: each frame it advances the circuit by the wall-clock time
/// since the last frame times the speed, within a compute budget, and moves the current dots.
@MainActor
final class SimulationController: ObservableObject {
    struct Status: Equatable {
        var time: Double = 0
        var speed: Double = 1
        var timeStep: Double = 1e-3
        /// Fraction of the requested speed actually reached (below 1 when the circuit is too heavy to keep up)
        var achieved: Double = 1
        var problems: [String] = []
        var failed = false
        var automatic = true
        /// Sound on: running in real time, one step per audio sample
        var audio = false
    }

    @Published private(set) var isRunning = true
    @Published private(set) var status = Status()
    /// True when the circuit has a speaker to listen to
    @Published private(set) var hasSpeaker = false
    @Published private(set) var soundOn = false
    @Published private(set) var soundProblem: String?
    /// True when the circuit has a keyboard pitch or gate source to play
    @Published private(set) var hasKeyboard = false
    /// The note the computer keyboard's A key plays (Z and X move it by an octave)
    @Published private(set) var keyboardBase = 60

    let simulator: Simulator
    /// Simulated seconds per real second
    private(set) var speed: Double = 1
    private var automatic = true
    /// Position of the current dots on each element, in grid units along it
    private(set) var dotPhase: [UUID: CGFloat] = [:]
    /// Voltage that maps to full colour, following the circuit's largest voltage
    private(set) var voltageScale: Double = 5
    /// Current that moves the dots at full speed, following the circuit's largest current
    private(set) var currentScale: Double = 1e-3

    private var lastTick: CFTimeInterval?
    /// While sound is on, the circuit runs on the sound thread and `simulator` follows it
    private var renderer: AudioRenderer?
    private var speakerIndex: Int?
    private var lastPublish: CFTimeInterval = 0
    private var achieved = 1.0

    /// The speaker's recent peak level as a fraction of its full scale (above 1 clips), for the front panel's meter
    private(set) var outputLevel = 0.0

    /// Seconds of wall-clock time a scope shows
    static let scopeSpan = 4.0

    init(circuit: Circuit) {
        simulator = Simulator(circuit: circuit, timeStep: Pacing.suggest(for: circuit).timeStep)
        findSpeaker(in: circuit)
        applySettings(of: circuit)
        simulator.configureScopes(window: speed * Self.scopeSpan)
        publish()
    }

    func load(_ circuit: Circuit) {
        // a turned knob or a typed value only needs the new values; anything else, a new circuit
        let quick = simulator.updateParameters(circuit)
        if !quick {
            // a part being dragged changes the circuit at every mouse move: rebuild at most every 50 ms while it keeps
            // changing, and once more for where it ends
            let now = CACurrentMediaTime()
            let wait = lastRebuild + Self.rebuildInterval - now
            if wait > 0 {
                pendingLoad = circuit
                if !loadScheduled {
                    loadScheduled = true
                    scheduleLoad(after: wait)
                }
                return
            }
            lastRebuild = now
        }
        pendingLoad = nil
        findSpeaker(in: circuit)
        applySettings(of: circuit)
        if !quick { simulator.load(circuit) }
        simulator.configureScopes(window: speed * Self.scopeSpan)
        if let renderer, let speaker = speakerIndex {
            if renderer.wantedInput != AudioRenderer.wantsInput(circuit) {
                // the live input was switched on or off: the sound starts again with or without it
                restartSound()
            } else {
                renderer.load(circuit, speaker: speaker, fullScale: circuit.elements[speaker][param: "fullScale"],
                              scopeWindow: Self.scopeSpan)
            }
        }
        publish()
    }

    /// The latest circuit waiting to be loaded while rebuilds are spaced out
    private var pendingLoad: Circuit?
    private var loadScheduled = false
    private var lastRebuild: CFTimeInterval = 0
    private static let rebuildInterval: CFTimeInterval = 0.05

    private func scheduleLoad(after wait: CFTimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.loadScheduled = false
                guard let circuit = self.pendingLoad else { return }
                self.load(circuit)
            }
        }
    }

    private func findSpeaker(in circuit: Circuit) {
        speakerIndex = circuit.elements.firstIndex { $0.kind == .speaker }
        hasSpeaker = speakerIndex != nil
        hasKeyboard = circuit.elements.contains { $0.kind.isKeyboard }
        if !hasSpeaker && soundOn { setSound(false) }
    }

    // MARK: - Keyboard

    /// Notes held down, oldest first; the newest one sounds, and the pitch stays on the last note after release
    private var heldNotes: [Int] = []
    private var lastNote = 60
    /// MIDI pitch bend, in semitones
    private var bend = 0.0

    /// The computer keyboard plays notes instead of choosing tools while sound is on and there is a keyboard to play
    var playsComputerKeyboard: Bool { soundOn && hasKeyboard }

    func noteOn(_ note: Int) {
        heldNotes.removeAll { $0 == note }
        heldNotes.append(note)
        lastNote = note
        applyKeyboard()
    }

    func noteOff(_ note: Int) {
        heldNotes.removeAll { $0 == note }
        if let newest = heldNotes.last { lastNote = newest }
        applyKeyboard()
    }

    func allNotesOff() {
        heldNotes = []
        applyKeyboard()
    }

    func pitchBend(_ semitones: Double) {
        bend = semitones
        applyKeyboard()
    }

    func shiftKeyboard(octaves: Int) {
        keyboardBase = min(96, max(24, keyboardBase + 12 * octaves))
    }

    private func applyKeyboard() {
        let state = Simulator.KeyboardState(note: Double(lastNote) + bend, gate: !heldNotes.isEmpty)
        guard state != simulator.keyboard else { return }
        simulator.keyboard = state
        renderer?.setKeyboard(state)
    }

    private var playing: Bool { renderer != nil }

    /// Turns sound on or off. While it is on the circuit runs in real time with one step per audio sample, on a thread
    /// of its own.
    func setSound(_ on: Bool) {
        if on {
            guard renderer == nil, let speaker = speakerIndex else { return }
            guard let started = AudioRenderer(continuing: simulator, speaker: speaker,
                                              fullScale: simulator.circuit.elements[speaker][param: "fullScale"],
                                              scopeWindow: Self.scopeSpan, paused: !isRunning) else {
                soundProblem = "No sound output is available."
                return
            }
            soundProblem = nil
            // a new output device may run at another sample rate: start again on it
            started.onOutputChange = { [weak self] in
                MainActor.assumeIsolated { self?.restartSound() }
            }
            renderer = started
            soundOn = true
        } else {
            renderer?.stop()
            renderer = nil
            soundOn = false
            allNotesOff()
        }
        applySettings(of: simulator.circuit)
        simulator.configureScopes(window: speed * Self.scopeSpan)
        publish()
    }

    private func restartSound() {
        guard soundOn else { return }
        let held = heldNotes
        setSound(false)
        setSound(true)
        heldNotes = held
        applyKeyboard()
    }

    private func applySettings(of circuit: Circuit) {
        if let renderer {
            automatic = false
            speed = 1
            simulator.setTimeStep(1 / renderer.sampleRate)
            return
        }
        let suggestion = Pacing.suggest(for: circuit)
        let settings = circuit.settings
        automatic = settings.autoSpeed
        speed = settings.autoSpeed ? suggestion.speed : max(settings.speed, 1e-12)
        simulator.setTimeStep(settings.autoTimeStep ? suggestion.timeStep : max(settings.timeStep, 1e-12))
    }

    /// Called every display frame with the frame's timestamp
    func tick(at now: CFTimeInterval, budget: TimeInterval = 0.010) {
        defer { lastTick = now }
        guard let last = lastTick else { return }
        let wall = min(max(now - last, 0), 0.1)
        guard isRunning, !simulator.isFailed, wall > 0 else { return }

        if let renderer {
            renderer.share(into: simulator)
            achieved = renderer.achieved
        } else {
            let requested = speed * wall
            let progress = simulator.advance(by: requested, deadline: ProcessInfo.processInfo.systemUptime + budget)
            let ratio = progress.fellBehind ? progress.simulatedTime / requested : 1
            achieved = achieved * 0.9 + ratio * 0.1
        }
        moveDots(wall: wall)
        measureOutput(wall: wall)
        voltageScale = max(1, simulator.maxNodeVoltage, voltageScale * pow(0.7, wall))
        if now - lastPublish > 0.2 || simulator.isFailed {
            lastPublish = now
            publish()
        }
    }

    private func measureOutput(wall: Double) {
        guard let speaker = speakerIndex, speaker < simulator.circuit.elements.count else {
            outputLevel = 0
            return
        }
        // with sound on, the sound thread's true peak; otherwise the level now (the circuit runs slowly enough to see it)
        let fullScale = max(simulator.circuit.elements[speaker][param: "fullScale"], 1e-3)
        let level = renderer?.takePeak() ?? abs(simulator.voltageAcross(speaker)) / fullScale
        // falls back over about a third of a second, like a peak meter
        outputLevel = max(level, outputLevel * pow(0.001, wall))
    }

    private func moveDots(wall: Double) {
        let elements = simulator.circuit.elements
        var largest = 0.0
        for i in elements.indices { largest = max(largest, abs(simulator.current(i))) }
        currentScale = max(1e-12, largest, currentScale * pow(0.5, wall))
        for (i, element) in elements.enumerated() {
            let current = simulator.current(i)
            let relative = abs(current) / currentScale
            guard relative > 1e-3 else { continue }
            // grid units per second; the square root keeps small currents visible
            let velocity = 4 * relative.squareRoot() * (current > 0 ? 1 : -1)
            let phase = (dotPhase[element.id] ?? 0) + CGFloat(velocity * wall)
            dotPhase[element.id] = phase.truncatingRemainder(dividingBy: 1000)
        }
    }

    // MARK: - Microcontrollers

    /// The last of what the chip of the microcontroller at `index` has sent over its serial port
    func serialOutput(_ index: Int) -> String {
        guard let chip = simulator.chip(index) else { return "" }
        return String(decoding: chip.serialOutput.suffix(8192), as: UTF8.self)
    }

    /// Sends text to the chip's serial port, as the Arduino IDE's serial monitor does
    func sendSerial(_ index: Int, _ text: String) {
        let bytes = Array(text.utf8)
        if let renderer {
            renderer.sendSerial(index, bytes)
        } else {
            simulator.chip(index)?.serialInput += bytes
        }
    }

    func resetChip(_ index: Int) {
        simulator.resetChip(index)
        renderer?.resetChip(index)
    }

    func setRunning(_ running: Bool) {
        isRunning = running
        renderer?.setPaused(!running)
        lastTick = nil
        publish()
    }

    func toggleRunning() {
        setRunning(!isRunning)
    }

    func reset() {
        simulator.reset()
        renderer?.reset()
        dotPhase = [:]
        achieved = 1
        publish()
    }

    private func publish() {
        let next = Status(time: simulator.time, speed: speed, timeStep: simulator.timeStep, achieved: achieved,
                          problems: simulator.problems, failed: simulator.isFailed, automatic: automatic, audio: playing)
        if next != status { status = next }
    }
}
