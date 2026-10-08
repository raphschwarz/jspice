import AVFoundation
import os

/// Plays the samples the simulation produces. The sound thread writes into a ring buffer and the audio system reads
/// from it; when the buffer runs dry the sound fades out instead of clicking.
final class AudioOutput {
    private struct Ring {
        var samples: [Float]
        var read = 0
        var write = 0
        var count = 0
        var last: Float = 0
        var underruns = 0
    }

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let ring: OSAllocatedUnfairLock<Ring>
    private(set) var sampleRate: Double = 48_000
    /// Sound taken from the Mac's input, for audio input parts set to the live input
    private var inputRing: OSAllocatedUnfairLock<Ring>?
    private(set) var inputSampleRate: Double = 0
    /// Called on the main thread when the output device or its format changes, which stops the engine
    var onConfigurationChange: (() -> Void)?
    private var observer: NSObjectProtocol?

    init(seconds: Double = 1) {
        ring = OSAllocatedUnfairLock(initialState: Ring(samples: Array(repeating: 0, count: Int(48_000 * seconds) * 2)))
    }

    /// Starts playing, and with `input` taking sound in from the Mac's input too (the first time, macOS asks to allow
    /// it); false if there is no audio output
    func start(input: Bool = false) -> Bool {
        if input { startInput() }
        let hardware = engine.outputNode.outputFormat(forBus: 0).sampleRate
        sampleRate = hardware > 0 ? hardware : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return false }
        let ring = ring
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let frames = Int(frameCount)
            guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            ring.withLock { state in
                for i in 0..<frames {
                    if state.count > 0 {
                        state.last = state.samples[state.read]
                        state.read = (state.read + 1) % state.samples.count
                        state.count -= 1
                    } else {
                        if i == 0 { state.underruns += 1 }
                        state.last *= 0.995
                    }
                    first[i] = state.last
                }
            }
            for buffer in buffers.dropFirst() {
                if let data = buffer.mData { memcpy(data, first, frames * MemoryLayout<Float>.size) }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            engine.detach(node)
            return false
        }
        source = node
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: .main) { [weak self] _ in
            self?.onConfigurationChange?()
        }
        return true
    }

    /// Takes the input's channels, mixed to one, into a ring buffer of its own (the newest second)
    private func startInput() {
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        inputSampleRate = format.sampleRate
        let ring = OSAllocatedUnfairLock(initialState: Ring(samples: Array(repeating: 0, count: Int(format.sampleRate))))
        inputRing = ring
        let channels = Int(format.channelCount)
        node.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            ring.withLock { state in
                let size = state.samples.count
                for f in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += data[c][f] }
                    if state.count == size {
                        state.read = (state.read + 1) % size
                        state.count -= 1
                    }
                    state.samples[state.write] = sum / Float(channels)
                    state.write = (state.write + 1) % size
                    state.count += 1
                }
            }
        }
    }

    /// The next `count` samples of input, at `inputSampleRate`: the last one repeated if the input has fallen behind,
    /// and older ones skipped if it has run more than 50 ms ahead, so the delay stays short
    func readInput(_ count: Int) -> [Float] {
        guard let inputRing, count > 0 else { return [] }
        let ahead = Int(0.05 * inputSampleRate)
        return inputRing.withLock { state in
            let size = state.samples.count
            if state.count > count + ahead {
                let skip = state.count - count - ahead / 2
                state.read = (state.read + skip) % size
                state.count -= skip
            }
            var result = [Float](repeating: 0, count: count)
            for k in 0..<count {
                if state.count > 0 {
                    state.last = state.samples[state.read]
                    state.read = (state.read + 1) % size
                    state.count -= 1
                }
                result[k] = state.last
            }
            return result
        }
    }

    func stop() {
        if inputRing != nil { engine.inputNode.removeTap(onBus: 0) }
        inputRing = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
        ring.withLock { $0.count = 0; $0.read = 0; $0.write = 0 }
    }

    /// Samples waiting to be played
    var buffered: Int { ring.withLock { $0.count } }

    func write<Samples: Collection>(_ samples: Samples) where Samples.Element == Float {
        guard !samples.isEmpty else { return }
        ring.withLock { state in
            for sample in samples where state.count < state.samples.count {
                state.samples[state.write] = sample
                state.write = (state.write + 1) % state.samples.count
                state.count += 1
            }
        }
    }
}
