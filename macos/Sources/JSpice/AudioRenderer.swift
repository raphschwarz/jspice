import Foundation
import os
import CircuitKit

/// Plays a circuit through its speaker: a copy of the window's simulator runs on its own thread in real time, so the
/// sound does not stop while the main thread is busy drawing or handling a menu. The window's simulator takes on this
/// one's state at each display frame (`share(into:)`) to show what it is doing.
///
/// Each audio sample is the average of several steps (4, or fewer if the circuit is too heavy to keep up): oscillators
/// that switch at a threshold then switch within a quarter of a sample, so their pitch is right and their edges clean.
final class AudioRenderer: @unchecked Sendable {
    // the simulator and what goes with it are shared between the sound thread and the main thread under `lock`; the
    // sound thread lets go of it every few samples, so neither waits long for the other
    private let lock = NSLock()
    private let simulator: Simulator
    private var speaker: Int
    private var fullScale: Double

    /// Small values both threads read or set, under a lock of their own so that reading the meter or playing a note
    /// never waits for the simulation
    private struct Shared {
        var paused = false
        var stopped = false
        var achieved = 1.0
        /// Largest output since the window last asked, as a fraction of the speaker's full scale (above 1 clips)
        var peak = 0.0
        /// A keyboard change the sound thread has not taken yet
        var keyboard: Simulator.KeyboardState?
    }
    private let shared: OSAllocatedUnfairLock<Shared>

    private let output: AudioOutput
    /// Whether an audio input part plays the Mac's live input
    private let liveInput: Bool
    /// Sound queued ahead of the speaker: enough to ride out a busy moment, short enough to answer a knob quickly
    private let latency = 0.05
    /// Samples made between letting go of the simulator
    private let block = 32

    // used only on the sound thread
    private var chunk = [Float](repeating: 0, count: 256)
    /// DC blocker: the speaker hears changes, not a constant offset (a one-pole high-pass at about 4 Hz)
    private var blockerInput = 0.0
    private var blockerOutput = 0.0
    private let blockerPole: Double
    private var windowStart = 0.0
    private var windowSamples = 0
    /// Time spent simulating in this window
    private var windowBusy = 0.0
    private var fellBehind = false
    /// Windows in a row in which the circuit took well under its time: then it can afford more steps per sample again
    private var idleWindows = 0
    /// Steps per audio sample
    private var oversampling = 4
    static let maximumOversampling = 4

    /// Called on the main thread when the sound output changes (headphones plugged in or out, another device chosen):
    /// the renderer then has to be replaced, as the new output may run at another sample rate
    var onOutputChange: (() -> Void)? {
        get { output.onConfigurationChange }
        set { output.onConfigurationChange = newValue }
    }

    /// Starts playing from where `display` is; nil if there is no sound output
    init?(continuing display: Simulator, speaker: Int, fullScale: Double, scopeWindow: Double, paused: Bool) {
        output = AudioOutput()
        let wantsInput = display.circuit.flattened().elements.contains { $0.kind == .audioInput && $0[param: "input"] >= 0.5 }
        guard output.start(input: wantsInput) else { return nil }
        liveInput = wantsInput && output.inputSampleRate > 0
        simulator = Simulator(circuit: display.circuit, timeStep: 1 / output.sampleRate)
        simulator.configureScopes(window: scopeWindow)
        // the sound sets its own step by how fast the computer keeps up: substeps only where Newton-Raphson needs them
        simulator.errorControl = false
        simulator.adoptState(of: display)
        simulator.keyboard = display.keyboard
        self.speaker = speaker
        self.fullScale = max(fullScale, 1e-3)
        shared = OSAllocatedUnfairLock(initialState: Shared(paused: paused))
        blockerPole = exp(-2 * .pi * 4 / output.sampleRate)
        simulator.setTimeStep(1 / (output.sampleRate * Double(oversampling)))
        windowStart = ProcessInfo.processInfo.systemUptime
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
        shared.withLock { state in
            defer { state.peak = 0 }
            return state.peak
        }
    }

    /// Fraction of real time the circuit recently ran at (below 1 when it is too heavy to keep up)
    var achieved: Double { shared.withLock { $0.achieved } }

    func stop() {
        shared.withLock { $0.stopped = true }
        output.stop()
    }

    deinit {
        output.stop()
    }

    func setPaused(_ paused: Bool) {
        shared.withLock { $0.paused = paused }
    }

    /// Switches to a changed circuit, keeping the state of the parts that remain
    func load(_ circuit: Circuit, speaker: Int, fullScale: Double, scopeWindow: Double) {
        lock.withLock {
            if !simulator.updateParameters(circuit) { simulator.load(circuit) }
            simulator.configureScopes(window: scopeWindow)
            self.speaker = speaker
            self.fullScale = max(fullScale, 1e-3)
        }
    }

    func reset() {
        lock.withLock { simulator.reset() }
    }

    func sendSerial(_ index: Int, _ bytes: [UInt8]) {
        lock.withLock { simulator.chip(index)?.serialInput += bytes }
    }

    func resetChip(_ index: Int) {
        lock.withLock { simulator.resetChip(index) }
    }

    func setKeyboard(_ state: Simulator.KeyboardState) {
        shared.withLock { $0.keyboard = state }
    }

    /// Gives the window's simulator this one's present state
    func share(into display: Simulator) {
        lock.withLock { display.adoptState(of: simulator) }
    }

    // MARK: - The sound thread

    /// Above 0.7 of full scale the output bends softly towards 1 instead of clipping; below it passes unchanged
    private static func limit(_ y: Double) -> Double {
        let magnitude = abs(y)
        guard magnitude > 0.7 else { return y }
        let bent = 0.7 + 0.3 * tanh((magnitude - 0.7) / 0.3)
        return y < 0 ? -bent : bent
    }

    private func restartWindow(at now: TimeInterval) {
        windowStart = now
        windowSamples = 0
        windowBusy = 0
        fellBehind = false
    }

    /// Makes the next chunk of sound, or waits a moment when enough is queued; false once stopped
    private func renderChunk() -> Bool {
        let (stopped, paused) = shared.withLock { ($0.stopped, $0.paused) }
        if stopped { return false }
        let rate = output.sampleRate
        let needed = Int(latency * rate) - output.buffered
        if paused || needed < 64 {
            Thread.sleep(forTimeInterval: 0.002)
            if paused { restartWindow(at: ProcessInfo.processInfo.systemUptime) }
            return true
        }
        fellBehind = fellBehind || output.buffered == 0
        let count = min(needed, chunk.count)
        var produced = 0
        var failed = false
        var peak = 0.0
        let steps = oversampling
        let started = ProcessInfo.processInfo.systemUptime
        if liveInput {
            // the input for this chunk, handed over before it is simulated
            let inputRate = output.inputSampleRate
            let samples = output.readInput(Int((Double(count) * inputRate / rate).rounded(.up)) + 1)
            lock.withLock {
                simulator.liveInput = Simulator.LiveInput(samples: samples, sampleRate: inputRate, startTime: simulator.time)
            }
        }
        while produced < count && !failed {
            let keyboard = shared.withLock { state -> Simulator.KeyboardState? in
                defer { state.keyboard = nil }
                return state.keyboard
            }
            lock.withLock {
                if let keyboard { simulator.keyboard = keyboard }
                let end = min(produced + block, count)
                while produced < end && !simulator.isFailed {
                    var sum = 0.0
                    for _ in 0..<steps {
                        simulator.step()
                        sum += simulator.voltageAcross(speaker)
                    }
                    let x = sum / Double(steps) / fullScale
                    let y = x - blockerInput + blockerPole * blockerOutput
                    blockerInput = x
                    blockerOutput = y
                    peak = max(peak, abs(y))
                    chunk[produced] = Float(Self.limit(y))
                    produced += 1
                }
                failed = simulator.isFailed
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        windowBusy += now - started
        shared.withLock { $0.peak = max($0.peak, peak) }
        output.write(chunk[0..<produced])
        if failed {
            // nothing to measure until the circuit is changed or reset
            Thread.sleep(forTimeInterval: 0.01)
            restartWindow(at: ProcessInfo.processInfo.systemUptime)
            return true
        }

        // how fast it is going: samples made per second of wall time, if it ran out of sound to play
        windowSamples += produced
        let elapsed = now - windowStart
        if elapsed > 0.25 {
            var ratio = fellBehind ? min(1, Double(windowSamples) / (elapsed * rate)) : 1
            var changed = false
            if ratio < 0.98 && oversampling > 1 {
                // too heavy: fewer steps per sample before running slow
                oversampling /= 2
                changed = true
                ratio = 1
                idleWindows = 0
            } else if oversampling < Self.maximumOversampling && windowBusy < 0.3 * elapsed {
                // light again (the slowdown was a passing stall, or the circuit got simpler): a second of ease earns
                // the steps back
                idleWindows += 1
                if idleWindows >= 4 {
                    oversampling *= 2
                    changed = true
                    idleWindows = 0
                }
            } else {
                idleWindows = 0
            }
            if changed {
                let timeStep = 1 / (rate * Double(oversampling))
                lock.withLock { simulator.setTimeStep(timeStep) }
            }
            shared.withLock { $0.achieved = $0.achieved * 0.5 + ratio * 0.5 }
            restartWindow(at: now)
        }
        return true
    }
}
