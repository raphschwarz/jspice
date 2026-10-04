import AVFoundation
import os

/// Plays the samples the simulation produces. The simulation writes into a ring buffer on the main thread and the audio
/// thread reads from it; when the buffer runs dry the sound fades out instead of clicking.
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

    init(seconds: Double = 1) {
        ring = OSAllocatedUnfairLock(initialState: Ring(samples: Array(repeating: 0, count: Int(48_000 * seconds) * 2)))
    }

    /// Starts playing; false if there is no audio output
    func start() -> Bool {
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
        return true
    }

    func stop() {
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
        ring.withLock { $0.count = 0; $0.read = 0; $0.write = 0 }
    }

    /// Samples waiting to be played
    var buffered: Int { ring.withLock { $0.count } }

    func write(_ samples: [Float]) {
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
