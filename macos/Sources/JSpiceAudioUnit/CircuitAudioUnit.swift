import AudioToolbox
import AVFoundation
import CircuitKit

/// The JSpice Audio Unit: a circuit as an effect (the host's sound into its audio inputs) or an instrument (MIDI notes
/// on its keyboard sources), its speaker the output, its knobs and switches the parameters. The circuits are the
/// presets: the sound examples, and the circuits exported from the app. The whole circuit is saved with the session.
public final class CircuitAudioUnit: AUAudioUnit {
    let kernel: CircuitKernel
    let isInstrument: Bool
    private let outputBus: AUAudioUnitBus
    private let inputBus: AUAudioUnitBus?
    private var outputArray: AUAudioUnitBusArray!
    private var inputArray: AUAudioUnitBusArray!
    private(set) var library: [PluginLibrary.Entry]
    private var preset: AUAudioUnitPreset?
    /// The circuit playing, and its name
    private(set) var circuitName = ""
    /// Called on the main thread when another circuit is loaded
    var onLoad: (() -> Void)?

    /// Where the app exports circuits: ~/Music/JSpice/Audio Units in the user's own home folder (the extension is
    /// sandboxed, with an exception to read there)
    static var exportFolder: URL {
        var home = FileManager.default.homeDirectoryForCurrentUser.path
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { home = String(cString: dir) }
        return URL(fileURLWithPath: home).appendingPathComponent(PluginLibrary.folder, isDirectory: true)
    }

    public override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        isInstrument = componentDescription.componentType == kAudioUnitType_MusicDevice
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        outputBus = try AUAudioUnitBus(format: format)
        outputBus.maximumChannelCount = 2
        inputBus = isInstrument ? nil : try AUAudioUnitBus(format: format)
        kernel = CircuitKernel(effect: !isInstrument)
        library = PluginLibrary.entries(instrument: isInstrument, folder: Self.exportFolder)
        try super.init(componentDescription: componentDescription, options: options)
        outputArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        inputArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: inputBus.map { [$0] } ?? [])
        maximumFramesToRender = 4096
        if let first = library.first {
            load(first.name, first.circuit)
            let preset = AUAudioUnitPreset()
            preset.number = 0
            preset.name = first.name
            self.preset = preset
        } else {
            parameterTree = AUParameterTree.createTree(withChildren: [])
        }
    }

    public override var inputBusses: AUAudioUnitBusArray { inputArray }
    public override var outputBusses: AUAudioUnitBusArray { outputArray }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        kernel.allocate(sampleRate: outputBus.format.sampleRate, inputFormat: inputBus?.format, maximumFrames: Int(maximumFramesToRender))
    }

    public override func deallocateRenderResources() {
        kernel.deallocate()
        super.deallocateRenderResources()
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = self.kernel
        return { flags, timestamp, frames, _, output, events, pull in
            kernel.render(flags: flags, timestamp: timestamp, frames: frames, output: output, events: events, pull: pull)
        }
    }

    // MARK: - Circuits

    /// Plays another circuit: its knobs become the parameters
    func load(_ name: String, _ circuit: Circuit) {
        circuitName = name
        kernel.load(circuit)
        let controls = CircuitProcessor.controls(of: circuit)
        let parameters = controls.enumerated().map { k, control -> AUParameter in
            let parameter = AUParameterTree.createParameter(withIdentifier: "control\(k)", name: control.name, address: AUParameterAddress(k),
                                                            min: 0, max: 1, unit: control.isSwitch ? .boolean : .generic, unitName: nil,
                                                            flags: [.flag_IsReadable, .flag_IsWritable], valueStrings: nil, dependentParameters: nil)
            parameter.value = AUValue(control.value)
            return parameter
        }
        let tree = AUParameterTree.createTree(withChildren: parameters)
        let kernel = self.kernel
        tree.implementorValueObserver = { parameter, value in kernel.set(Int(parameter.address), to: Double(value)) }
        tree.implementorValueProvider = { parameter in AUValue(kernel.value(Int(parameter.address))) }
        parameterTree = tree
        if Thread.isMainThread { onLoad?() } else { DispatchQueue.main.async { self.onLoad?() } }
    }

    /// Looks again for circuits exported from the app
    func reloadLibrary() {
        library = PluginLibrary.entries(instrument: isInstrument, folder: Self.exportFolder)
    }

    public override var factoryPresets: [AUAudioUnitPreset]? {
        library.enumerated().map { k, entry in
            let preset = AUAudioUnitPreset()
            preset.number = k
            preset.name = entry.name
            return preset
        }
    }

    public override var currentPreset: AUAudioUnitPreset? {
        get { preset }
        set {
            guard let newValue else { return }
            if newValue.number >= 0 {
                guard library.indices.contains(newValue.number) else { return }
                let entry = library[newValue.number]
                load(entry.name, entry.circuit)
            }
            preset = newValue
        }
    }

    /// The session's state: the circuit itself, with its knobs where they are, so it plays the same on another Mac
    public override var fullState: [String: Any]? {
        get {
            var state = super.fullState ?? [:]
            if let circuit = kernel.circuit, let data = try? JSONEncoder().encode(circuit) { state["jspiceCircuit"] = data }
            state["jspiceName"] = circuitName
            return state
        }
        set {
            if let data = newValue?["jspiceCircuit"] as? Data, let circuit = try? JSONDecoder().decode(Circuit.self, from: data) {
                load(newValue?["jspiceName"] as? String ?? "Circuit", circuit)
                let preset = AUAudioUnitPreset()
                preset.number = -1
                preset.name = circuitName
                self.preset = preset
            }
            super.fullState = newValue
        }
    }

    public override var supportsUserPresets: Bool { false }
}

/// What the render thread uses: the circuit's processor and buffers, behind a lock the other threads take only to
/// swap the circuit or move a knob
final class CircuitKernel: @unchecked Sendable {
    private let lock = NSLock()
    private let effect: Bool
    private var processor: CircuitProcessor?
    private var pending: Circuit?
    private var sampleRate: Double?
    private var maximumFrames = 0
    private var inputBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?
    private var mono: [Float] = []
    private var out: [Float] = []
    /// Knob positions before there is a processor
    private var values: [Double] = []

    init(effect: Bool) {
        self.effect = effect
    }

    /// The circuit playing, its knobs where they are now
    var circuit: Circuit? { lock.withLock { processor?.circuit ?? pending } }

    func load(_ circuit: Circuit) {
        let rate = lock.withLock { () -> Double? in
            pending = circuit
            values = CircuitProcessor.controls(of: circuit).map(\.value)
            return sampleRate
        }
        // made off the render thread: settling the circuit takes a moment
        let made = rate.flatMap { CircuitProcessor(circuit: circuit, sampleRate: $0) }
        lock.withLock {
            guard pending == circuit else { return }
            processor = made
            if made != nil { pending = nil }
        }
    }

    func allocate(sampleRate: Double, inputFormat: AVAudioFormat?, maximumFrames: Int) {
        let circuit = lock.withLock { processor?.circuit ?? pending }
        let made = circuit.flatMap { CircuitProcessor(circuit: $0, sampleRate: sampleRate) }
        let input = inputFormat.flatMap { AVAudioPCMBuffer(pcmFormat: $0, frameCapacity: AVAudioFrameCount(maximumFrames)) }
        let output = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
            .flatMap { AVAudioPCMBuffer(pcmFormat: $0, frameCapacity: AVAudioFrameCount(maximumFrames)) }
        lock.withLock {
            self.sampleRate = sampleRate
            self.maximumFrames = maximumFrames
            processor = made
            pending = made == nil ? circuit : nil
            inputBuffer = input
            outputBuffer = output
            mono = [Float](repeating: 0, count: maximumFrames)
            out = [Float](repeating: 0, count: maximumFrames)
            for (k, value) in values.enumerated() { made?.set(k, to: value) }
        }
    }

    func deallocate() {
        lock.withLock {
            if let processor { pending = processor.circuit }
            processor = nil
            sampleRate = nil
            inputBuffer = nil
            outputBuffer = nil
        }
    }

    func set(_ index: Int, to value: Double) {
        lock.withLock {
            if values.indices.contains(index) { values[index] = value }
            processor?.set(index, to: value)
        }
    }

    func value(_ index: Int) -> Double {
        lock.withLock { processor?.controls[safe: index]?.value ?? values[safe: index] ?? 0 }
    }

    func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timestamp: UnsafePointer<AudioTimeStamp>,
                frames: AUAudioFrameCount, output: UnsafeMutablePointer<AudioBufferList>,
                events: UnsafePointer<AURenderEvent>?, pull: AURenderPullInputBlock?) -> AUAudioUnitStatus {
        lock.lock()
        defer { lock.unlock() }
        let count = Int(frames)
        guard count <= maximumFrames else { return kAudioUnitErr_TooManyFramesToProcess }
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        // a host that gives no buffers renders into ours
        if let channels = outputBuffer?.floatChannelData {
            for k in 0..<buffers.count where buffers[k].mData == nil {
                buffers[k].mData = UnsafeMutableRawPointer(channels[min(k, 1)])
            }
        }
        for k in 0..<buffers.count { buffers[k].mDataByteSize = UInt32(count * MemoryLayout<Float>.size) }
        guard let processor else {
            for buffer in buffers { if let data = buffer.mData { memset(data, 0, count * MemoryLayout<Float>.size) } }
            flags.pointee.insert(.unitRenderAction_OutputIsSilence)
            return noErr
        }

        // notes and parameter changes, at the start of the block
        var event = events
        while let e = event {
            switch e.pointee.head.eventType {
            case .parameter, .parameterRamp:
                let parameter = e.pointee.parameter
                let index = Int(parameter.parameterAddress)
                if values.indices.contains(index) { values[index] = Double(parameter.value) }
                processor.set(index, to: Double(parameter.value))
            case .MIDI:
                let midi = e.pointee.MIDI
                let status = midi.data.0 & 0xF0
                if status == 0x90 && midi.data.2 > 0 {
                    processor.noteOn(Int(midi.data.1))
                } else if status == 0x80 || status == 0x90 {
                    processor.noteOff(Int(midi.data.1))
                } else if status == 0xB0 && (midi.data.1 == 123 || midi.data.1 == 120) {
                    processor.allNotesOff()
                }
            default:
                break
            }
            event = UnsafePointer(e.pointee.head.next)
        }

        // the host's sound, mixed to mono
        var input = false
        if effect, let pull, let inputBuffer {
            // the buffer list as allocated: the host may have pointed it elsewhere last time
            let list = UnsafeMutableAudioBufferListPointer(inputBuffer.mutableAudioBufferList)
            for k in 0..<list.count {
                list[k].mData = inputBuffer.floatChannelData.map { UnsafeMutableRawPointer($0[k]) }
                list[k].mDataByteSize = UInt32(count * MemoryLayout<Float>.size)
            }
            var pullFlags = AudioUnitRenderActionFlags()
            if pull(&pullFlags, timestamp, frames, 0, inputBuffer.mutableAudioBufferList) == noErr, list.count > 0 {
                mono.withUnsafeMutableBufferPointer { mono in
                    for n in 0..<count { mono[n] = 0 }
                    for buffer in list {
                        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        for n in 0..<count { mono[n] += data[n] }
                    }
                    let scale = 1 / Float(list.count)
                    for n in 0..<count { mono[n] *= scale }
                }
                input = true
            }
        }
        mono.withUnsafeBufferPointer { mono in
            out.withUnsafeMutableBufferPointer { out in
                processor.process(input: input ? mono.baseAddress : nil, output: out.baseAddress!, frames: count)
            }
        }
        out.withUnsafeBufferPointer { out in
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for n in 0..<count { data[n] = out[n] }
            }
        }
        return noErr
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
