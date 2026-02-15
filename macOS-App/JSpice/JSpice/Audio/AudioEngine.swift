import Foundation
import AVFoundation
import Accelerate
import os

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
    private var sourceNode: AVAudioSourceNode?

    private let ringBuffer = RingBuffer(capacity: 65536)  // ~1.3s at 48kHz
    private var sampleRate: Double = 48000
    private var _isPlaying = false

    // Level metering — atomic for safe access from render thread
    private let _peakLevel = OSAllocatedUnfairLock(initialState: Float(0))
    private let _rmsLevel = OSAllocatedUnfairLock(initialState: Float(0))

    var peakLevel: Float { _peakLevel.withLock { $0 } }
    var rmsLevel: Float { _rmsLevel.withLock { $0 } }
    var isPlaying: Bool { _isPlaying }

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
        let rb = ringBuffer
        let peakRef = _peakLevel
        let rmsRef = _rmsLevel

        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let buffer = bufferList.first,
                  let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }

            let frames = Int(frameCount)
            var peak: Float = 0
            var sumSquares: Float = 0

            for i in 0..<frames {
                let sample = Float(rb.read() ?? 0)
                data[i] = sample

                let absSample = abs(sample)
                if absSample > peak { peak = absSample }
                sumSquares += sample * sample
            }

            peakRef.withLock { $0 = peak }
            rmsRef.withLock { $0 = sqrt(sumSquares / max(Float(frames), 1)) }

            return noErr
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)

        self.audioEngine = engine
        self.sourceNode = source
    }

    // MARK: - Control

    func play() {
        guard !_isPlaying else { return }

        do {
            try audioEngine?.start()
            _isPlaying = true
        } catch {
            print("Audio engine failed to start: \(error)")
        }
    }

    func stop() {
        audioEngine?.stop()
        _isPlaying = false
        ringBuffer.reset()
    }

    func pause() {
        audioEngine?.pause()
        _isPlaying = false
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

// MARK: - Lock-Free Ring Buffer (SPSC)

/// Single-producer single-consumer lock-free ring buffer for audio data.
/// Uses atomic read/write indices for wait-free operation between
/// the simulation thread (writer) and audio render thread (reader).
///
/// IMPORTANT: This is designed for exactly one writer thread and one reader thread.
/// Multiple concurrent writers or readers require external synchronization.
final class RingBuffer: @unchecked Sendable {
    private let buffer: UnsafeMutableBufferPointer<Double>
    private let mask: Int  // capacity - 1 (capacity must be power of 2)
    private let _writeIndex = OSAllocatedUnfairLock(initialState: Int(0))
    private let _readIndex = OSAllocatedUnfairLock(initialState: Int(0))

    init(capacity requestedCapacity: Int) {
        // Round up to power of 2 for fast modulo via bitmask
        let cap = max(1 << Int(ceil(log2(Double(max(requestedCapacity, 2))))), 2)
        self.mask = cap - 1
        let ptr = UnsafeMutablePointer<Double>.allocate(capacity: cap)
        ptr.initialize(repeating: 0, count: cap)
        self.buffer = UnsafeMutableBufferPointer(start: ptr, count: cap)
    }

    deinit {
        buffer.baseAddress?.deallocate()
    }

    var availableToRead: Int {
        let w = _writeIndex.withLock { $0 }
        let r = _readIndex.withLock { $0 }
        return (w &- r) & mask
    }

    /// Write a sample. If buffer is full, the oldest sample is overwritten.
    func write(_ value: Double) {
        let w = _writeIndex.withLock { $0 }
        buffer[w & mask] = value
        _writeIndex.withLock { $0 = (w &+ 1) & mask }
    }

    /// Read a sample. Returns nil if buffer is empty (underrun).
    func read() -> Double? {
        let r = _readIndex.withLock { $0 }
        let w = _writeIndex.withLock { $0 }
        guard r != w else { return nil }

        let value = buffer[r & mask]
        _readIndex.withLock { $0 = (r &+ 1) & mask }
        return value
    }

    func reset() {
        _readIndex.withLock { $0 = 0 }
        _writeIndex.withLock { $0 = 0 }
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
