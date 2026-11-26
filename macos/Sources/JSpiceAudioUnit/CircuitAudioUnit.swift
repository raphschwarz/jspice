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
    /// How the render thread is keeping up (the window polls it)
    var renderStatus: PluginEngine.Status { kernel.status }

    /// Where the app exports circuits: ~/Music/JSpice/Audio Units in the user's own home folder (the extension is
    /// sandboxed, with an exception to read there)
    static var exportFolder: URL {
        var home = FileManager.default.homeDirectoryForCurrentUser.path
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { home = String(cString: dir) }
        return URL(fileURLWithPath: home).appendingPathComponent(PluginLibrary.folder, isDirectory: true)
    }

    public override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        let instrument = componentDescription.componentType == kAudioUnitType_MusicDevice
        isInstrument = instrument
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let output = try AUAudioUnitBus(format: format)
        output.maximumChannelCount = 2
        outputBus = output
        if instrument {
            inputBus = nil
        } else {
            inputBus = try AUAudioUnitBus(format: format)
        }
        kernel = CircuitKernel(effect: !instrument)
        library = PluginLibrary.entries(instrument: instrument, folder: Self.exportFolder)
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

    /// Mono or stereo: the circuit is mono, its input the channels' average and its speaker in every output channel
    public override var channelCapabilities: [NSNumber]? {
        isInstrument ? [0, 1, 0, 2] : [1, 1, 1, 2, 2, 2]
    }

    public override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
        (1...2).contains(format.channelCount) && format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved
            && super.shouldChange(to: format, for: bus)
    }

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

/// What the render thread uses. It takes no lock that another thread can hold, allocates and frees nothing, and never
/// rebuilds the circuit: `PluginEngine` prepares processors on a background queue and the render thread swaps them in
/// at the top of a call (see there). The buffers here are made in `allocate`, before the host starts rendering, and
/// only replaced when it has stopped.
final class CircuitKernel: @unchecked Sendable {
    let engine = PluginEngine()
    private let effect: Bool
    // render resources (set up while the host is not rendering)
    private var sampleRate = 48_000.0
    private var maximumFrames = 0
    private var inputBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?
    private var mono: UnsafeMutablePointer<Float>?
    private var out: UnsafeMutablePointer<Float>?
    private var capacity = 0
    /// Seconds per tick of `mach_absolute_time`
    private let secondsPerTick: Double

    init(effect: Bool) {
        self.effect = effect
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerTick = timebase.denom == 0 ? 1e-9 : Double(timebase.numer) / Double(timebase.denom) * 1e-9
    }

    deinit {
        mono?.deallocate()
        out?.deallocate()
    }

    /// The circuit playing, its knobs where they are now
    var circuit: Circuit? { engine.circuit }

    /// What the window shows about the render thread: its load, whether it is keeping up, the steps per sample
    var status: PluginEngine.Status { engine.status }

    /// Plays another circuit: made in the background, the one playing goes on until it is ready
    func load(_ circuit: Circuit) {
        engine.load(circuit)
    }

    func allocate(sampleRate: Double, inputFormat: AVAudioFormat?, maximumFrames: Int) {
        let frames = max(maximumFrames, 1)
        self.sampleRate = sampleRate
        self.maximumFrames = frames
        inputBuffer = inputFormat.flatMap { AVAudioPCMBuffer(pcmFormat: $0, frameCapacity: AVAudioFrameCount(frames)) }
        outputBuffer = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
            .flatMap { AVAudioPCMBuffer(pcmFormat: $0, frameCapacity: AVAudioFrameCount(frames)) }
        if capacity < frames {
            mono?.deallocate()
            out?.deallocate()
            mono = .allocate(capacity: frames)
            out = .allocate(capacity: frames)
            capacity = frames
        }
        mono?.initialize(repeating: 0, count: capacity)
        out?.initialize(repeating: 0, count: capacity)
        // the first processor is made before this returns, so the first render call plays the circuit
        engine.allocate(sampleRate: sampleRate, maximumFrames: frames)
    }

    func deallocate() {
        engine.deallocate()
    }

    /// From the parameter tree (the plugin's window, or the host from its own threads)
    func set(_ index: Int, to value: Double) {
        engine.setControl(index, value)
    }

    func value(_ index: Int) -> Double {
        engine.controlValue(index)
    }

    /// Takes one note or parameter change; true for a note pressed (which should sound for a sample before the next event)
    @inline(__always)
    private func handle(_ e: UnsafePointer<AURenderEvent>, _ processor: CircuitProcessor) -> Bool {
        switch e.pointee.head.eventType {
        case .parameter, .parameterRamp:
            // a knob moved by the host's automation: handed to the background, which prepares a processor for it
            let parameter = e.pointee.parameter
            engine.requestControl(Int(parameter.parameterAddress), Double(parameter.value))
        case .MIDI:
            let midi = e.pointee.MIDI
            let status = midi.data.0 & 0xF0
            if status == 0x90 && midi.data.2 > 0 {
                processor.noteOn(Int(midi.data.1))
                return true
            } else if status == 0x80 || status == 0x90 {
                processor.noteOff(Int(midi.data.1))
            } else if status == 0xB0 && (midi.data.1 == 123 || midi.data.1 == 120) {
                processor.allNotesOff()
            }
        default:
            break
        }
        return false
    }

    /// The render callback, on the host's real-time thread
    func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timestamp: UnsafePointer<AudioTimeStamp>,
                frames: AUAudioFrameCount, output: UnsafeMutablePointer<AudioBufferList>,
                events: UnsafePointer<AURenderEvent>?, pull: AURenderPullInputBlock?) -> AUAudioUnitStatus {
        let started = mach_absolute_time()
        let count = Int(frames)
        guard count <= maximumFrames, let mono, let out else { return kAudioUnitErr_TooManyFramesToProcess }
        // a prepared processor swapped in, the one it replaces handed back, knob moves passed on: all without waiting
        engine.beginRender()
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        // a host that gives no buffers renders into ours
        if let channels = outputBuffer?.floatChannelData {
            for k in 0..<buffers.count where buffers[k].mData == nil {
                buffers[k].mData = UnsafeMutableRawPointer(channels[min(k, 1)])
            }
        }
        for k in 0..<buffers.count { buffers[k].mDataByteSize = UInt32(count * MemoryLayout<Float>.size) }
        guard let processor = engine.processor else {
            for k in 0..<buffers.count { if let data = buffers[k].mData { memset(data, 0, count * MemoryLayout<Float>.size) } }
            flags.pointee.insert(.unitRenderAction_OutputIsSilence)
            finish(started, count)
            return noErr
        }

        // the host's sound, mixed to mono
        var input = false
        if effect, let pull, let inputBuffer {
            // the buffer list as allocated: the host may have pointed it elsewhere last time
            let list = UnsafeMutableAudioBufferListPointer(inputBuffer.mutableAudioBufferList)
            let channels = inputBuffer.floatChannelData
            for k in 0..<list.count {
                list[k].mData = channels.map { UnsafeMutableRawPointer($0[k]) }
                list[k].mDataByteSize = UInt32(count * MemoryLayout<Float>.size)
            }
            var pullFlags = AudioUnitRenderActionFlags()
            if pull(&pullFlags, timestamp, frames, 0, inputBuffer.mutableAudioBufferList) == noErr, list.count > 0 {
                for n in 0..<count { mono[n] = 0 }
                for k in 0..<list.count {
                    guard let data = list[k].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for n in 0..<count { mono[n] += data[n] }
                }
                let scale = 1 / Float(list.count)
                for n in 0..<count { mono[n] *= scale }
                input = true
            }
        }
        // notes at their own sample: the block is rendered in pieces between them, so a note that starts and ends
        // within one block still sounds, and a quick release and press retriggers
        let start = AUEventSampleTime(timestamp.pointee.mSampleTime)
        var event = events
        var done = 0
        while done < count {
            while let e = event, Self.offset(e, start, count) <= done {
                event = UnsafePointer(e.pointee.head.next)
                if handle(e, processor) { break }
            }
            // at least one sample before the next event, so a note pressed is heard before its release
            let next = event.map { min(count, max(done + 1, Self.offset($0, start, count))) } ?? count
            processor.process(input: input ? UnsafePointer(mono + done) : nil, output: out + done, frames: next - done)
            done = next
        }
        // events past the end of the block (a host should not send them): taken now rather than lost
        while let e = event {
            event = UnsafePointer(e.pointee.head.next)
            _ = handle(e, processor)
        }
        for k in 0..<buffers.count {
            guard let data = buffers[k].mData?.assumingMemoryBound(to: Float.self) else { continue }
            data.update(from: out, count: count)
        }
        finish(started, count)
        return noErr
    }

    /// Where an event falls in the block
    @inline(__always)
    private static func offset(_ e: UnsafePointer<AURenderEvent>, _ start: AUEventSampleTime, _ count: Int) -> Int {
        Int(max(0, min(AUEventSampleTime(count), e.pointee.head.eventSampleTime - start)))
    }

    /// The time this call took against the time its buffer lasts: the engine lowers the steps per sample when the
    /// circuit cannot keep up, and the window shows it (nothing is logged here)
    @inline(__always)
    private func finish(_ started: UInt64, _ count: Int) {
        let elapsed = mach_absolute_time() &- started
        engine.endRender(busy: Double(elapsed) * secondsPerTick, budget: Double(count) / sampleRate)
    }
}
