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
    private var audio: AudioOutput?
    private var speakerIndex: Int?
    /// DC blocker state: the speaker hears changes, not a constant offset
    private var blockerInput = 0.0
    private var blockerOutput = 0.0
    private var lastPublish: CFTimeInterval = 0
    private var achieved = 1.0

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
        findSpeaker(in: circuit)
        applySettings(of: circuit)
        simulator.load(circuit)
        simulator.configureScopes(window: speed * Self.scopeSpan)
        publish()
    }

    private func findSpeaker(in circuit: Circuit) {
        speakerIndex = circuit.elements.firstIndex { $0.kind == .speaker }
        hasSpeaker = speakerIndex != nil
        if !hasSpeaker && soundOn { setSound(false) }
    }

    private var playing: Bool { soundOn && speakerIndex != nil && audio != nil }

    /// Turns sound on or off. While it is on the circuit runs in real time with one step per audio sample.
    func setSound(_ on: Bool) {
        if on {
            guard hasSpeaker, audio == nil else { return }
            let output = AudioOutput()
            guard output.start() else {
                soundProblem = "No sound output is available."
                return
            }
            soundProblem = nil
            audio = output
            soundOn = true
        } else {
            audio?.stop()
            audio = nil
            soundOn = false
        }
        applySettings(of: simulator.circuit)
        simulator.configureScopes(window: speed * Self.scopeSpan)
        publish()
    }

    private func applySettings(of circuit: Circuit) {
        if playing, let audio {
            automatic = false
            speed = 1
            simulator.setTimeStep(1 / audio.sampleRate)
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

        if playing {
            achieved = achieved * 0.9 + produceSound(wall: wall, budget: budget) * 0.1
        } else {
            let requested = speed * wall
            let progress = simulator.advance(by: requested, deadline: ProcessInfo.processInfo.systemUptime + budget)
            let ratio = progress.fellBehind ? progress.simulatedTime / requested : 1
            achieved = achieved * 0.9 + ratio * 0.1
        }
        moveDots(wall: wall)
        voltageScale = max(1, simulator.maxNodeVoltage, voltageScale * pow(0.7, wall))
        if now - lastPublish > 0.2 || simulator.isFailed {
            lastPublish = now
            publish()
        }
    }

    /// Steps the circuit once per audio sample until about 80 ms of sound is queued (or the frame's time is up).
    /// Returns the fraction of real time reached.
    private func produceSound(wall: Double, budget: TimeInterval) -> Double {
        guard let audio, let speaker = speakerIndex, speaker < simulator.circuit.elements.count else { return 1 }
        let rate = audio.sampleRate
        let target = Int(0.08 * rate)
        let needed = target - audio.buffered
        guard needed > 0 else { return 1 }
        let fullScale = max(simulator.circuit.elements[speaker][param: "fullScale"], 1e-3)
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        var samples: [Float] = []
        samples.reserveCapacity(needed)
        while samples.count < needed && !simulator.isFailed {
            simulator.step()
            let x = simulator.voltageAcross(speaker) / fullScale
            // one-pole high-pass at about 4 Hz, then a soft limit instead of hard clipping
            let y = x - blockerInput + 0.9995 * blockerOutput
            blockerInput = x
            blockerOutput = y
            samples.append(Float(tanh(y)))
            if samples.count & 63 == 0 && ProcessInfo.processInfo.systemUptime > deadline { break }
        }
        audio.write(samples)
        return min(1, Double(samples.count) / max(1, wall * rate))
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

    func setRunning(_ running: Bool) {
        isRunning = running
        lastTick = nil
        publish()
    }

    func toggleRunning() {
        setRunning(!isRunning)
    }

    func reset() {
        simulator.reset()
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
