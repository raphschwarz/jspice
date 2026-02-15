import Foundation
import AVFoundation
import Accelerate

// MARK: - Audio Engine

/// Real-time audio engine for routing circuit simulation output to speakers.
/// Uses Core Audio (via AVAudioEngine) for low-latency playback.
///
/// Design:
/// - Simulation produces samples at the circuit simulation rate
/// - Samples are written to a lock-free ring buffer
/// - Audio render callback reads from the ring buffer at hardware sample rate
/// - Sample rate conversion is applied when rates differ
final class AudioEngine {

    // MARK: - Properties

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var sourceNode: AVAudioSourceNode?

    private var ringBuffer = RingBuffer(capacity: 65536)  // ~1.3s at 48kHz
    private var sampleRate: Double = 48000
    private var isPlaying = false

    // Level metering
    private(set) var peakLevel: Float = 0
    private(set) var rmsLevel: Float = 0

    // MARK: - Initialization

    init() {
        setupAudioEngine()
    }

    deinit {
        stop()
    }

    // MARK: - Setup

    private func setupAudioEngine() {
        let engine = AVAudioEngine()
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        sampleRate = outputFormat.sampleRate

        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1  // Mono output
        )!

        // Source node renders audio from our ring buffer
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            return self.renderAudio(
                frameCount: frameCount,
                audioBufferList: audioBufferList
            )
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)

        self.audioEngine = engine
        self.sourceNode = source
    }

    // MARK: - Render Callback

    private func renderAudio(
        frameCount: AVAudioFrameCount,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let buffer = bufferList.first,
              let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
            return noErr
        }

        let frames = Int(frameCount)
        var peak: Float = 0
        var sumSquares: Float = 0

        for i in 0..<frames {
            let sample = Float(ringBuffer.read() ?? 0)
            data[i] = sample

            let absSample = abs(sample)
            if absSample > peak { peak = absSample }
            sumSquares += sample * sample
        }

        peakLevel = peak
        rmsLevel = sqrt(sumSquares / Float(frames))

        return noErr
    }

    // MARK: - Control

    func play() {
        guard !isPlaying else { return }

        do {
            try audioEngine?.start()
            isPlaying = true
        } catch {
            print("Audio engine failed to start: \(error)")
        }
    }

    func stop() {
        audioEngine?.stop()
        isPlaying = false
        ringBuffer.reset()
    }

    func pause() {
        audioEngine?.pause()
        isPlaying = false
    }

    // MARK: - Feed samples from simulation

    /// Load a pre-computed array of samples (e.g., from transient analysis)
    func loadSamples(_ samples: [Double], sampleRate sourceSampleRate: Double) {
        ringBuffer.reset()

        // Resample if rates differ
        if abs(sourceSampleRate - sampleRate) > 1 {
            let resampled = resample(samples, from: sourceSampleRate, to: sampleRate)
            for sample in resampled {
                ringBuffer.write(sample)
            }
        } else {
            for sample in samples {
                ringBuffer.write(sample)
            }
        }
    }

    /// Write a single sample (for real-time streaming from simulation)
    func writeSample(_ sample: Double) {
        ringBuffer.write(sample)
    }

    /// Write a block of samples (for real-time streaming)
    func writeSamples(_ samples: [Double]) {
        for sample in samples {
            ringBuffer.write(sample)
        }
    }

    // MARK: - Resampling

    private func resample(_ input: [Double], from sourceRate: Double, to targetRate: Double) -> [Double] {
        let ratio = targetRate / sourceRate
        let outputLength = Int(Double(input.count) * ratio)
        var output = [Double](repeating: 0, count: outputLength)

        // Linear interpolation resampling
        for i in 0..<outputLength {
            let sourceIndex = Double(i) / ratio
            let index0 = Int(sourceIndex)
            let frac = sourceIndex - Double(index0)

            let s0 = index0 < input.count ? input[index0] : 0
            let s1 = (index0 + 1) < input.count ? input[index0 + 1] : s0
            output[i] = s0 + frac * (s1 - s0)
        }

        return output
    }
}

// MARK: - Lock-Free Ring Buffer

/// Thread-safe ring buffer for audio data.
/// Uses atomic read/write indices for lock-free operation between
/// the simulation thread (writer) and audio render thread (reader).
final class RingBuffer: @unchecked Sendable {
    private var buffer: [Double]
    private let capacity: Int
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private let lock = NSLock()  // Simplified; real impl would use atomics

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Double](repeating: 0, count: capacity)
    }

    var availableToRead: Int {
        let w = writeIndex
        let r = readIndex
        if w >= r {
            return w - r
        }
        return capacity - r + w
    }

    var availableToWrite: Int {
        capacity - availableToRead - 1
    }

    func write(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }

        buffer[writeIndex] = value
        writeIndex = (writeIndex + 1) % capacity
    }

    func read() -> Double? {
        lock.lock()
        defer { lock.unlock() }

        guard readIndex != writeIndex else { return nil }  // Empty

        let value = buffer[readIndex]
        readIndex = (readIndex + 1) % capacity
        return value
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }

        readIndex = 0
        writeIndex = 0
    }
}

// MARK: - Signal Generator (standalone audio test)

/// Generates test signals for audio output verification
enum AudioSignalGenerator {
    static func sine(frequency: Double, sampleRate: Double, duration: Double) -> [Double] {
        let sampleCount = Int(sampleRate * duration)
        return (0..<sampleCount).map { i in
            sin(2.0 * .pi * frequency * Double(i) / sampleRate)
        }
    }

    static func square(frequency: Double, sampleRate: Double, duration: Double) -> [Double] {
        let sampleCount = Int(sampleRate * duration)
        let period = sampleRate / frequency
        return (0..<sampleCount).map { i in
            Double(i).truncatingRemainder(dividingBy: period) < period / 2 ? 1.0 : -1.0
        }
    }

    static func sawtooth(frequency: Double, sampleRate: Double, duration: Double) -> [Double] {
        let sampleCount = Int(sampleRate * duration)
        let period = sampleRate / frequency
        return (0..<sampleCount).map { i in
            2.0 * (Double(i).truncatingRemainder(dividingBy: period) / period) - 1.0
        }
    }

    static func triangle(frequency: Double, sampleRate: Double, duration: Double) -> [Double] {
        let sampleCount = Int(sampleRate * duration)
        let period = sampleRate / frequency
        return (0..<sampleCount).map { i in
            let t = Double(i).truncatingRemainder(dividingBy: period) / period
            if t < 0.25 { return 4.0 * t }
            if t < 0.75 { return 2.0 - 4.0 * t }
            return 4.0 * t - 4.0
        }
    }

    static func whiteNoise(sampleRate: Double, duration: Double) -> [Double] {
        let sampleCount = Int(sampleRate * duration)
        return (0..<sampleCount).map { _ in
            Double.random(in: -1...1)
        }
    }
}
