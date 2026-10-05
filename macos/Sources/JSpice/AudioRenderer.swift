import Foundation
import CircuitKit

/// Plays a circuit through its speaker: a copy of the window's simulator runs on its own thread in real time, so the
/// sound does not stop while the main thread is busy drawing or handling a menu. The window's simulator takes on this
/// one's state at each display frame (`share(into:)`) to show what it is doing.
///
/// Each audio sample is the average of several steps (4, or fewer if the circuit is too heavy to keep up): oscillators
/// that switch at a threshold then switch within a quarter of a sample, so their pitch is right and their edges clean.
final class AudioRenderer: @unchecked Sendable {
    // everything below the lock is shared between the sound thread and the main thread
    private let lock = NSLock()
    private let simulator: Simulator
    private var speaker: Int
    private var fullScale: Double
    private var paused = false
    private var stopped = false
    private var achievedValue = 1.0
    /// Largest output since the window last asked, as a fraction of the speaker's full scale (above 1 clips)
    private var peak = 0.0

    private let output: AudioOutput
    /// Sound queued ahead of the speaker: enough to ride out a busy moment, short enough to answer a knob quickly
    private let latency = 0.05

    // used only on the sound thread
    private var chunk = [Float](repeating: 0, count: 256)
    /// DC blocker: the speaker hears changes, not a constant offset
    private var blockerInput = 0.0
    private var blockerOutput = 0.0
    private var windowStart = ProcessInfo.processInfo.systemUptime
    private var windowSamples = 0
    private var fellBehind = false
    /// Steps per audio sample
    private var oversampling = 4

    /// Starts playing from where `display` is; nil if there is no sound output
    init?(continuing display: Simulator, speaker: Int, fullScale: Double, scopeWindow: Double) {
        output = AudioOutput()
        guard output.start() else { return nil }
        simulator = Simulator(circuit: display.circuit, timeStep: 1 / output.sampleRate)
        simulator.configureScopes(window: scopeWindow)
        simulator.adoptState(of: display)
        simulator.keyboard = display.keyboard
        self.speaker = speaker
        self.fullScale = max(fullScale, 1e-3)
        simulator.setTimeStep(1 / (output.sampleRate * Double(oversampling)))
        // the thread holds the renderer only while making a chunk, so letting go of the renderer ends it
        let thread = Thread { [weak self] in
            while let renderer = self, renderer.renderChunk() {}
        }
        thread.name = "JSpice sound"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    var sampleRate: Double { output.sampleRate }

    /// The output's peak level since the last call, for the level meter
    func takePeak() -> Double {
        lock.withLock {
            let value = peak
            peak = 0
            return value
        }
    }

    /// Fraction of real time the circuit recently ran at (below 1 when it is too heavy to keep up)
    var achieved: Double { lock.withLock { achievedValue } }

    func stop() {
        lock.withLock { stopped = true }
        output.stop()
    }

    deinit {
        output.stop()
    }

    func setPaused(_ paused: Bool) {
        lock.withLock { self.paused = paused }
    }

    /// Switches to a changed circuit, keeping the state of the parts that remain
    func load(_ circuit: Circuit, speaker: Int, fullScale: Double, scopeWindow: Double) {
        lock.withLock {
            simulator.load(circuit)
            simulator.configureScopes(window: scopeWindow)
            self.speaker = speaker
            self.fullScale = max(fullScale, 1e-3)
        }
    }

    func reset() {
        lock.withLock { simulator.reset() }
    }

    func setKeyboard(_ state: Simulator.KeyboardState) {
        lock.withLock { simulator.keyboard = state }
    }

    /// Gives the window's simulator this one's present state
    func share(into display: Simulator) {
        lock.withLock { display.adoptState(of: simulator) }
    }

    // MARK: - The sound thread

    /// Makes the next chunk of sound, or waits a moment when enough is queued; false once stopped
    private func renderChunk() -> Bool {
        let (stopped, paused) = lock.withLock { (self.stopped, self.paused) }
        if stopped { return false }
        let rate = output.sampleRate
        let needed = Int(latency * rate) - output.buffered
        if paused || needed < 64 {
            Thread.sleep(forTimeInterval: 0.002)
            if paused {
                windowStart = ProcessInfo.processInfo.systemUptime
                windowSamples = 0
            }
            return true
        }
        fellBehind = fellBehind || output.buffered == 0
        let count = min(needed, chunk.count)
        var produced = 0
        var failed = false
        let steps = oversampling
        lock.withLock {
            while produced < count && !simulator.isFailed {
                var sum = 0.0
                for _ in 0..<steps {
                    simulator.step()
                    sum += simulator.voltageAcross(speaker)
                }
                let x = sum / Double(steps) / fullScale
                peak = max(peak, abs(x))
                // one-pole high-pass at about 4 Hz, then a soft limit instead of hard clipping
                let y = x - blockerInput + 0.9995 * blockerOutput
                blockerInput = x
                blockerOutput = y
                chunk[produced] = Float(tanh(y))
                produced += 1
            }
            failed = simulator.isFailed
        }
        output.write(chunk[0..<produced])
        if failed { Thread.sleep(forTimeInterval: 0.01) }

        // how fast it is going: samples made per second of wall time, if it ran out of sound to play
        windowSamples += produced
        let now = ProcessInfo.processInfo.systemUptime
        if now - windowStart > 0.25 {
            var ratio = fellBehind ? min(1, Double(windowSamples) / ((now - windowStart) * rate)) : 1
            if ratio < 0.98 && oversampling > 1 {
                // too heavy: fewer steps per sample before running slow
                oversampling /= 2
                let timeStep = 1 / (rate * Double(oversampling))
                lock.withLock { simulator.setTimeStep(timeStep) }
                ratio = 1
            }
            lock.withLock { achievedValue = achievedValue * 0.5 + ratio * 0.5 }
            windowStart = now
            windowSamples = 0
            fellBehind = false
        }
        return true
    }
}
