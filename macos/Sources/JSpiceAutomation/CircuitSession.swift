import Foundation
import CircuitKit

/// An error for the caller (an AI agent): the message says what to fix.
public struct ToolError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// One circuit under automated control: building it from netlists or by position, simulating it and measuring it.
/// Every tool takes and returns JSON-compatible values (dictionaries, arrays, strings, numbers, booleans).
///
/// The session can drive a circuit of its own (the `jspice-mcp` server) or a document open in the app, which sets
/// `circuit` before each call and is told about changes through `onChange`.
public final class CircuitSession {
    public var circuit: Circuit {
        didSet { liveSimulator = nil }
    }
    /// Called after a tool changes the circuit, with a short description of the change (for an Undo menu)
    public var onChange: ((Circuit, String) -> Void)?
    /// The simulator kept between `simulate` calls that continue instead of starting over
    private var liveSimulator: Simulator?
    /// Blocks made with define_block, by name
    private var blocks: [String: BlockDefinition] = [:]

    public init(circuit: Circuit = Circuit()) {
        self.circuit = circuit
    }

    // MARK: - Tool catalogue

    public struct Tool {
        public let name: String
        public let description: String
        public let inputSchema: [String: Any]
        let run: (CircuitSession, [String: Any]) throws -> Any
    }

    public static let instructions = """
    JSpice is a circuit simulator: a physics harness for designing analog circuits. Typical use: call list_parts to see \
    the parts, their terminals, parameters and real-part models (op-amps such as TL072, OTAs such as LM13700, 555, \
    CD40106, CD4066, JFETs…); build a circuit with build_circuit from a netlist (each part lists which net each of its \
    terminals joins; the net "GND" is ground); then simulate it and read waveforms and measurements, or call \
    frequency_response for filters and amplifiers (small-signal analysis by default). Adjust values with set_parameter or set_model and simulate again. \
    Values accept SI prefixes as strings ("4.7k", "100n", "2.2u", "1meg"). Probes: "V(net)" is a net's voltage, \
    "V(R1)" the voltage across a part, "I(R1)" its current, "P(R1)" its power, "V(U1.out)" a terminal's voltage. \
    Synth circuits can be played: keyboardPitch parts put out 1 V per octave (0 V at C2) and keyboardGate parts a gate, \
    driven by the "keyboard" events of simulate (for example [{"at": 0, "note": "C4"}, {"at": 0.5, "off": true}]) \
    or by a step sequence (set_sequence). Synth chips (vco, vcf, envelope, vca, sampleHold, comparator, divider) model \
    the AS3340, AS3320, AS3310, SSM2164, LF398, LM393 and CD4013 and patch together like modules. \
    A circuit can be made into a block with define_block (its "port" parts are its pins) and used as one part, as often \
    as needed: {"kind": "block", "block": "name", "connections": {...}}.
    """

    public static let tools: [Tool] = [
        Tool(name: "list_parts",
             description: "Lists every part kind with its terminals (in order), parameters (with units, defaults and ranges) and the real parts it can behave like (models).",
             inputSchema: schema([:]), run: { session, _ in session.listParts() }),
        Tool(name: "list_examples",
             description: "Lists the built-in example circuits.",
             inputSchema: schema([:]), run: { _, _ in Examples.all.map { ["id": $0.id, "title": $0.title, "summary": $0.summary] } }),
        Tool(name: "load_example",
             description: "Replaces the circuit with a built-in example.",
             inputSchema: schema(["id": string("Example id from list_examples")], required: ["id"]),
             run: { session, arguments in try session.loadExample(arguments) }),
        Tool(name: "new_circuit",
             description: "Starts an empty circuit.",
             inputSchema: schema([:]), run: { session, _ in session.replace(Circuit(), "New Circuit"); return ["ok": true] }),
        Tool(name: "build_circuit",
             description: "Builds a circuit from a netlist and draws it as a tidy schematic (signal flowing left to right, wires, ground symbols, supply flags). Each part has a kind (from list_parts), an optional name, an optional model, parameters, and connections from terminal names to net names. Parts on the same net are connected; \"GND\" is ground. Replaces the circuit unless append is true.",
             inputSchema: schema([
                "parts": ["type": "array", "description": "The parts", "items": partSchema],
                "append": ["type": "boolean", "description": "Add to the present circuit instead of replacing it"],
             ], required: ["parts"]),
             run: { session, arguments in try session.buildCircuit(arguments) }),
        Tool(name: "add_part",
             description: "Adds one part: either by its connections (like a build_circuit part), or at grid positions `a` and `b` ([x, y]) to draw it by hand; terminals that land on the same grid point are connected.",
             inputSchema: schema(partProperties.merging([
                "a": point("First grid point (by position)"),
                "b": point("Second grid point: sets length and direction"),
             ]) { $1 }, required: ["kind"]),
             run: { session, arguments in try session.addPart(arguments) }),
        Tool(name: "add_wire",
             description: "Draws a wire between two grid points.",
             inputSchema: schema(["a": point("Start"), "b": point("End")], required: ["a", "b"]),
             run: { session, arguments in try session.addWire(arguments) }),
        Tool(name: "remove_part",
             description: "Removes a part by name.",
             inputSchema: schema(["part": string("Part name")], required: ["part"]),
             run: { session, arguments in try session.removePart(arguments) }),
        Tool(name: "set_parameter",
             description: "Sets one parameter of a part (see list_parts for the keys).",
             inputSchema: schema([
                "part": string("Part name"), "parameter": string("Parameter key"),
                "value": ["description": "Number, or string with an SI prefix such as \"4.7k\""],
             ], required: ["part", "parameter", "value"]),
             run: { session, arguments in try session.setParameter(arguments) }),
        Tool(name: "set_model",
             description: "Makes a part behave like a real part (for example an op-amp as \"TL072\" or \"LM358\"), setting all of that model's parameters.",
             inputSchema: schema(["part": string("Part name"), "model": string("Model name from list_parts")], required: ["part", "model"]),
             run: { session, arguments in try session.setModel(arguments) }),
        Tool(name: "set_switch",
             description: "Opens or closes a switch or push button.",
             inputSchema: schema(["part": string("Part name"), "closed": ["type": "boolean"]], required: ["part", "closed"]),
             run: { session, arguments in try session.setSwitch(arguments) }),
        Tool(name: "set_temperature",
             description: "Sets the temperature the circuit works at, in °C (27 by default, where the parts' parameters are given). Diodes, LEDs and bipolar transistors follow it as in SPICE: their saturation current rises and their junctions drop about 2 mV less per degree, so a bias point drifts as a real one does.",
             inputSchema: schema(["celsius": ["description": "Temperature in °C, -200 to 500"]], required: ["celsius"]),
             run: { session, arguments in try session.setTemperature(arguments) }),
        Tool(name: "map_midi",
             description: "Maps a MIDI controller (control change number 0–119) to a potentiometer, switch or push button, as MIDI Learn does in the app: the pot follows the controller across its travel, a switch or button is on from 64 up. The mapping is saved with the circuit. remove true takes the part's mapping away.",
             inputSchema: schema([
                "part": string("Part name: a potentiometer, switch or push button"),
                "controller": ["type": "integer", "description": "Control change number, 0 to 119"],
                "channel": ["type": "integer", "description": "MIDI channel 1 to 16 (left out: any channel)"],
                "remove": ["type": "boolean", "description": "Forget the part's mapping instead"],
             ], required: ["part"]),
             run: { session, arguments in try session.mapMIDI(arguments) }),
        Tool(name: "set_sequence",
             description: "Sets the step sequencer that plays the circuit's keyboard pitch and gate sources by itself: one step per sixteenth note, each a note or a rest, repeating. It runs on circuit time, in simulate and with sound on in the app. Pass playing false to stop it.",
             inputSchema: schema([
                "steps": ["type": "array", "items": [String: Any](),
                          "description": "Notes, one per step: MIDI numbers (60) or names (\"C4\", \"F#2\"); null or \"-\" is a rest"],
                "tempo": ["type": "number", "description": "Quarter notes per minute (default 120)"],
                "gate": ["type": "number", "description": "Fraction of each step the gate is open (default 0.5)"],
                "playing": ["type": "boolean", "description": "Default true"],
             ], required: ["steps"]),
             run: { session, arguments in try session.setSequence(arguments) }),
        Tool(name: "upload_sketch",
             description: "Compiles an Arduino sketch (C++, as in the Arduino IDE: setup() and loop(), pinMode, digitalWrite, analogRead, analogWrite, delay, millis, Serial, tone…) for a microcontroller part (atmega328p: Arduino Uno, pins d0-d13 and a0-a5; atmega2560: Arduino Mega, d0-d53 and a0-a15; attiny85: pins pb0-pb5, numbered 0-5 in the sketch, no Serial; rp2040: Raspberry Pi Pico at 3.3 V, pins gp0-gp22 and gp26-gp28 (analog A0-A2), numbered as GPIOs in the sketch, LED_BUILTIN on GP25, Serial over USB) and loads the firmware into it; the chip runs it from reset in simulate. Returns the firmware size, or the compiler's errors with sketch line numbers.",
             inputSchema: schema(["part": string("Name of a microcontroller part"), "code": string("The sketch's source")],
                                 required: ["part", "code"]),
             run: { session, arguments in try session.uploadSketch(arguments) }),
        Tool(name: "read_serial",
             description: "What a microcontroller has printed on its serial port (Serial.print) in the simulation so far; optionally sends it text, which it receives in the next simulate with continue true.",
             inputSchema: schema(["part": string("Name of a microcontroller part"), "send": string("Text to send to the chip")],
                                 required: ["part"]),
             run: { session, arguments in try session.readSerial(arguments) }),
        Tool(name: "install_chip_support",
             description: "Downloads and installs what compiling sketches takes, if it is not installed yet: for avr (the Uno, Mega and ATtiny85) avr-gcc and the Arduino AVR core, about 40 MB from Arduino's package index; for rp2040 (the Pico) arm-none-eabi-gcc and arduino-pico, about 240 MB from arduino-pico's index.",
             inputSchema: schema(["family": string("avr (the default) or rp2040")]),
             run: { session, arguments in try session.installChipSupport(arguments) }),
        Tool(name: "describe_circuit",
             description: "Describes the circuit: every part with its kind, model, parameters and the node (and net names) of each terminal, plus any problems that keep it from being simulated.",
             inputSchema: schema([:]), run: { session, _ in session.describe() }),
        Tool(name: "simulate",
             description: "Runs a transient simulation from rest (or continues the last one) and returns the probed waveforms, each with min, max, mean, RMS, peak-to-peak, final value and estimated frequency.",
             inputSchema: schema([
                "duration": ["description": "Seconds of circuit time to simulate (number or SI string)"],
                "probes": ["type": "array", "items": ["type": "string"],
                           "description": "What to record: \"V(net)\", \"V(part)\", \"I(part)\", \"P(part)\", \"R(part)\" or \"V(part.terminal)\""],
                "time_step": ["description": "Time step in seconds; default: chosen from the circuit's time constants"],
                "points": ["type": "integer", "description": "Samples returned per probe (default 200)"],
                "continue": ["type": "boolean", "description": "Continue from the end of the last simulation instead of starting from rest"],
                "keyboard": ["type": "array", "items": ["type": "object"],
                             "description": "Notes to play on the circuit's keyboard pitch and gate sources, in time order: {\"at\": seconds, \"note\": 60 or \"C4\"} presses a key (the newest key sounds), {\"at\": seconds, \"off\": true} releases all keys. The pitch stays on the last note after release."],
             ], required: ["duration", "probes"]),
             run: { session, arguments in try session.simulate(arguments) }),
        Tool(name: "measure",
             description: "The present value of every net voltage and every part's voltage, current and power, at the end of the last simulation.",
             inputSchema: schema([:]), run: { session, _ in session.measure() }),
        Tool(name: "frequency_response",
             description: "Gain and phase from a source to a probe over a range of frequencies. method \"ac\" (the default) is small-signal analysis, as SPICE's .ac: the circuit settles from rest with the source held at its offset, is linearised there, and the response is solved exactly at every frequency in a moment. method \"transient\" drives an AC voltage source with its own amplitude and measures each frequency by simulating until steady, so it includes clipping and other effects of large signals, but takes much longer. The result lists each frequency's gain and phase, the peak, and where the gain crosses 3 dB below the peak.",
             inputSchema: schema([
                "source": string("Name of the source driving the circuit: any voltage or current source for ac, an AC voltage source for transient"),
                "output": string("Probe for the output: \"V(net)\", \"V(part)\" or \"V(part.terminal)\" (transient also takes I, P and R)"),
                "method": string("ac (default) or transient"),
                "start": ["description": "Lowest frequency in Hz (default 10)"],
                "stop": ["description": "Highest frequency in Hz (default 100k)"],
                "points_per_decade": ["type": "integer", "description": "Default 20 for ac, 5 for transient"],
                "frequencies": ["type": "array", "items": ["type": "number"], "description": "Explicit frequencies instead of start/stop"],
                "settle": ["description": "ac: seconds the circuit runs from rest to settle before it is linearised (default: five of its slowest time constants)"],
             ], required: ["source", "output"]),
             run: { session, arguments in try session.frequencyResponse(arguments) }),
        Tool(name: "sweep",
             description: "Steps one parameter of one part through a list of values (or from start to stop) and measures the circuit at each: how a filter's corner follows a capacitor, a bias point follows a resistor, a fuzz's gain follows its pot. Returns a row of measurements per value.",
             inputSchema: schema([
                "part": string("Part name"),
                "parameter": string("Parameter key from list_parts, for example \"resistance\" or \"position\""),
                "values": ["type": "array", "items": [String: Any](), "description": "The values (numbers or strings with SI prefixes)"],
                "start": ["description": "First value, when not giving values"],
                "stop": ["description": "Last value"],
                "points": ["type": "integer", "description": "How many values from start to stop (default 11, at most 100)"],
                "logarithmic": ["type": "boolean", "description": "Even ratios instead of even steps (default: true when stop is ten times start or more)"],
                "measure": ["type": "object", "description": "What to measure on each circuit: {\"type\": \"ac\", \"source\": \"VIN\", \"output\": \"V(out)\", \"frequencies\": [100, 1000]} (small-signal gain and phase, with the peak and the -3 dB corner when there are three or more frequencies), {\"type\": \"op\", \"probes\": [\"V(out)\", \"I(Q1)\"]} (the operating point it settles to), or {\"type\": \"transient\", \"duration\": 0.1, \"skip\": 0.05, \"probes\": [\"V(out)\"]} (min, max, mean, RMS, peak-to-peak and frequency after skip seconds). Each may give settle (seconds)."],
             ], required: ["part", "parameter", "measure"]),
             run: { session, arguments in try session.sweep(arguments) }),
        Tool(name: "optimize",
             description: "Finds part values that meet targets: a downhill simplex (Nelder-Mead) search over the parameters given, each within its range (on a log scale for values that span decades), measuring the circuit at each try. Targets: {\"metric\": \"corner_hz\", \"value\": 1000} to hit a value, {\"metric\": \"gain_db@1000\", \"min\": 19, \"max\": 21} to stay in a range, or {\"metric\": \"V(out) rms\", \"goal\": \"maximize\"}; each may have a weight. Errors are relative, except in dB and degrees, which count as they are. series 12, 24 or 96 then moves resistors, capacitors and inductors to E12, E24 or E96 values, trying the neighbours of each. The result is applied to the circuit unless apply is false.",
             inputSchema: schema([
                "parameters": ["type": "array", "items": ["type": "object"], "description": "What to change: [{\"part\": \"C1\", \"parameter\": \"capacitance\", \"min\": \"1n\", \"max\": \"10u\"}], with log true or false (default: true when max is ten times min or more)"],
                "measure": ["type": "object", "description": "What to measure on each circuit: {\"type\": \"ac\", \"source\": \"VIN\", \"output\": \"V(out)\", \"frequencies\": [100, 1000]} (small-signal gain and phase, with the peak and the -3 dB corner when there are three or more frequencies), {\"type\": \"op\", \"probes\": [\"V(out)\", \"I(Q1)\"]} (the operating point it settles to), or {\"type\": \"transient\", \"duration\": 0.1, \"skip\": 0.05, \"probes\": [\"V(out)\"]} (min, max, mean, RMS, peak-to-peak and frequency after skip seconds). Each may give settle (seconds)."],
                "targets": ["type": "array", "items": ["type": "object"], "description": "What to achieve, by the measurements' names"],
                "evaluations": ["type": "integer", "description": "Most measurements to make (default 150, at most 1000)"],
                "series": ["type": "integer", "description": "12, 24 or 96: end on standard values"],
                "apply": ["type": "boolean", "description": "Set the values found in the circuit (default true)"],
             ], required: ["parameters", "measure", "targets"]),
             run: { session, arguments in try session.optimize(arguments) }),
        Tool(name: "monte_carlo",
             description: "Tolerance analysis: measures many copies of the circuit, each with its parts' values drawn within their tolerances (normally distributed, three standard deviations at the tolerance), as a batch built from real parts would come out. Resistors vary ±5 %, capacitors and inductors ±10 %, transistors' gain ±30 % and JFETs ±20 % unless told otherwise. Returns, for each measurement, its nominal value and the spread: mean, standard deviation, minimum, maximum, and the 5th and 95th percentiles, and which run went furthest each way.",
             inputSchema: schema([
                "runs": ["type": "integer", "description": "How many copies (default 50, at most 500)"],
                "seed": ["type": "integer", "description": "Seed of the random draws, to repeat an analysis exactly (default 1)"],
                "tolerances": ["type": "object", "description": "± fractions by kind: resistors, capacitors, inductors, transistor_gain, fets; and parts: {\"R1\": 0.001} for single parts"],
                "measure": ["type": "object", "description": "What to measure on each circuit: {\"type\": \"ac\", \"source\": \"VIN\", \"output\": \"V(out)\", \"frequencies\": [100, 1000]} (small-signal gain and phase, with the peak and the -3 dB corner when there are three or more frequencies), {\"type\": \"op\", \"probes\": [\"V(out)\", \"I(Q1)\"]} (the operating point it settles to), or {\"type\": \"transient\", \"duration\": 0.1, \"skip\": 0.05, \"probes\": [\"V(out)\"]} (min, max, mean, RMS, peak-to-peak and frequency after skip seconds). Each may give settle (seconds)."],
             ], required: ["measure"]),
             run: { session, arguments in try session.monteCarlo(arguments) }),
        Tool(name: "noise",
             description: "Noise analysis, as SPICE's .noise: the circuit settles from rest (its input source held still), is linearised, and every resistor's thermal noise (4kT/R), junction's shot noise (2qI), field-effect transistor's channel noise, tube's and op-amp's input noise (TL072 18 nV/√Hz, NE5532 5, LM358 40) is carried to the output. Returns the output's noise density at each frequency, the same referred to the input source (divided by the gain from it), the total RMS noise over the band, and the parts it comes from, loudest first. No flicker (1/f) noise.",
             inputSchema: schema([
                "output": string("Probe for the output: \"V(net)\", \"V(part)\" or \"V(part.terminal)\""),
                "source": string("The input source, for input-referred noise (default: the circuit's signal source)"),
                "start": ["description": "Lowest frequency in Hz (default 20)"],
                "stop": ["description": "Highest frequency in Hz (default 20k)"],
                "points_per_decade": ["type": "integer", "description": "Default 20"],
                "settle": ["description": "Seconds the circuit runs from rest to settle before it is linearised (default: five of its slowest time constants)"],
             ], required: ["output"]),
             run: { session, arguments in try session.noise(arguments) }),
        Tool(name: "spectrum",
             description: "The spectrum of a probe's signal, as a spectrum analyser shows it: the circuit runs from rest for settle seconds, then its signal is recorded for duration seconds and analysed (Hann window, FFT). Returns the fundamental, total harmonic distortion (THD, the RMS of harmonics 2 to 10 over the fundamental), each harmonic's frequency and level, the strongest other peaks, and the signal's RMS and mean. Keyboard events play as in simulate.",
             inputSchema: schema([
                "probe": string("What to analyse: \"V(net)\", \"V(part)\", \"I(part)\"…"),
                "duration": ["description": "Seconds recorded for the analysis (default 0.5); the resolution is 1 / duration"],
                "settle": ["description": "Seconds run first and not analysed, so the circuit settles (default 0.2)"],
                "max_frequency": ["description": "Highest frequency of interest in Hz (default 20k); sets the time step"],
                "keyboard": ["type": "array", "items": ["type": "object"], "description": "Notes to play, as in simulate"],
             ], required: ["probe"]),
             run: { session, arguments in try session.spectrum(arguments) }),
        Tool(name: "set_audio_input",
             description: "Gives an audio input part (kind \"audioInput\", a voltage source that plays a sound) a WAV file to play: 8 to 32-bit PCM or float, any sample rate, mixed to mono, up to a minute. Its level parameter is the peak voltage of full scale (0.5 V by default, about a guitar's), offset is added, and loop plays it over and over. Without a path it plays the built-in guitar riff.",
             inputSchema: schema([
                "part": string("Name of the audio input part"),
                "path": string("WAV file to play (left out: the built-in guitar riff)"),
                "level": ["description": "Volts at full scale"],
                "loop": ["type": "boolean", "description": "Play it over and over (default true)"],
             ], required: ["part"]),
             run: { session, arguments in try session.setAudioInput(arguments) }),
        Tool(name: "render_audio",
             description: "Simulates the circuit for a while and writes what a part hears, the speaker by default, to a WAV file (24-bit mono), as the app's speaker would play it: the voltage across it, divided by its full scale, without DC and softly limited above full scale. Audio inputs play their sounds and keyboard events play the keyboard sources. Returns the peak level (1 is full scale) and the fraction of samples that clipped.",
             inputSchema: schema([
                "path": string("WAV file to write"),
                "duration": ["description": "Seconds of sound (at most 120)"],
                "output": string("Part whose voltage is the sound (default: the speaker)"),
                "sample_rate": ["description": "Samples per second (default 48000)"],
                "full_scale": ["description": "Volts that make full scale (default: the speaker's full scale parameter, or 1 V for other parts)"],
                "keyboard": ["type": "array", "items": ["type": "object"], "description": "Notes to play, as in simulate"],
             ], required: ["path", "duration"]),
             run: { session, arguments in try session.renderAudio(arguments) }),
        Tool(name: "define_block",
             description: "Makes a block: a circuit used as one part (a subcircuit). Its parts are a netlist as in build_circuit, with \"port\" parts as its pins: {\"kind\": \"port\", \"name\": \"in\", \"connections\": {\"net\": \"in\"}} makes a pin named in on the net in. Ports go on the left of the block (inputs) or the right (outputs): by their side parameter (1 left, 2 right), or if it is left out, on the right when a part's output drives the port's net or the port's name contains \"out\". Net labels inside a block are its own; GND is shared. Then use it in build_circuit or add_part as {\"kind\": \"block\", \"block\": \"name\", \"connections\": {\"in\": \"...\", \"out\": \"...\"}}; each use is a copy with its own state. save true also keeps it in the block library, where the app's library shows it.",
             inputSchema: schema([
                "name": string("The block's name"),
                "parts": ["type": "array", "description": "Its parts, ports included", "items": partSchema],
                "save": ["type": "boolean", "description": "Also save it in the block library"],
             ], required: ["name", "parts"]),
             run: { session, arguments in try session.defineBlock(arguments) }),
        Tool(name: "list_blocks",
             description: "Lists the blocks that can be used: those made with define_block in this session and those in the block library, with their pins.",
             inputSchema: schema([:]), run: { session, _ in session.listBlocks() }),
        Tool(name: "import_spice",
             description: "Replaces the circuit with a SPICE netlist, drawn as a tidy schematic: R, C, L, V and I (DC, SIN, PULSE; a 0 V source becomes an ammeter), D, Q, M (level 1), J (N-channel) with their .model parameters, K (two coupled inductors become a transformer) and X with .subckt (subcircuits become blocks). The first line is the title, as in SPICE; M is milli and MEG mega. Returns what was left out.",
             inputSchema: schema([
                "netlist": string("The netlist's text"),
                "path": string("Or a file to read it from"),
             ]),
             run: { session, arguments in try session.importSpice(arguments) }),
        Tool(name: "export_spice",
             description: "The circuit as a SPICE deck for ngspice or LTspice, with JSpice's own device equations: its parts by net, .model lines, op-amps and tubes as behavioural sources, transformers as coupled inductors, blocks as subcircuits, and a .tran analysis. Parts with no SPICE element (chips, microcontrollers) are named in comments. Writes it to path if given.",
             inputSchema: schema(["path": string("File to write (optional)")]),
             run: { session, arguments in try session.exportSpice(arguments) }),
        Tool(name: "save_circuit",
             description: "Saves the circuit as a .jspice file the JSpice app can open.",
             inputSchema: schema(["path": string("File path")], required: ["path"]),
             run: { session, arguments in try session.save(arguments) }),
        Tool(name: "tidy_up",
             description: "Redraws the circuit as a tidy schematic, as a person would draw it: signal flowing left to right, parts to ground hanging below, feedback over op-amps, wires instead of labels. Connections, values and scopes are kept.",
             inputSchema: schema([:]), run: { session, _ in try session.tidyUp() }),
        Tool(name: "open_circuit",
             description: "Opens a .jspice file.",
             inputSchema: schema(["path": string("File path")], required: ["path"]),
             run: { session, arguments in try session.open(arguments) }),
    ]

    public func call(_ name: String, arguments: [String: Any]) throws -> Any {
        guard let tool = Self.tools.first(where: { $0.name == name }) else { throw ToolError("Unknown tool \(name)") }
        return try tool.run(self, arguments)
    }

    // MARK: - Schemas

    static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var result: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { result["required"] = required }
        return result
    }

    static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }

    static func point(_ description: String) -> [String: Any] {
        ["type": "array", "items": ["type": "integer"], "minItems": 2, "maxItems": 2, "description": description]
    }

    static let partProperties: [String: Any] = [
        "kind": string("Part kind from list_parts, for example \"resistor\", \"opAmp\", \"ota\", \"timer555\""),
        "name": string("Unique name such as \"R1\"; generated if left out"),
        "model": string("Real part to behave like, from list_parts (for example \"TL072\")"),
        "params": ["type": "object", "description": "Parameter values by key (numbers, or strings with SI prefixes)"],
        "connections": ["type": "object", "description": "Terminal name to net name, for example {\"plus\": \"in\", \"minus\": \"GND\"}"],
        "flipped": ["type": "boolean", "description": "Mirror the part (transistors, op-amps…)"],
        "block": string("For kind \"block\": the name of a block made with define_block or saved in the block library; its terminals are its ports"),
    ]

    static let partSchema: [String: Any] = schema(partProperties, required: ["kind"])

    // MARK: - Argument helpers

    private static func number(_ value: Any?, _ what: String) throws -> Double? {
        guard let value else { return nil }
        if let text = value as? String {
            guard let parsed = SI.parse(text) else { throw ToolError("\(what): can't read \"\(text)\" as a number") }
            return parsed
        }
        if let number = value as? NSNumber { return number.doubleValue }
        throw ToolError("\(what) should be a number")
    }

    private static func text(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else { throw ToolError("Missing \"\(key)\"") }
        return value
    }

    private static func gridPoint(_ value: Any?, _ what: String) throws -> GridPoint? {
        guard let value else { return nil }
        guard let array = value as? [Any], array.count == 2,
              let x = (array[0] as? NSNumber)?.doubleValue, let y = (array[1] as? NSNumber)?.doubleValue,
              abs(x) <= 100_000, abs(y) <= 100_000 else {
            throw ToolError("\(what) should be [x, y] with whole numbers within ±100000")
        }
        return GridPoint(Int(x.rounded()), Int(y.rounded()))
    }

    private func index(ofPart name: String) throws -> Int {
        guard let index = circuit.elements.firstIndex(where: { $0.name == name && $0.kind != .netLabel }) else {
            let names = circuit.elements.filter { $0.kind != .wire && $0.kind != .ground && $0.kind != .netLabel }.map(\.name)
            throw ToolError("No part named \(name). Parts: \(names.joined(separator: ", "))")
        }
        return index
    }

    private static func kind(_ value: Any?) throws -> ElementKind {
        guard let name = value as? String else { throw ToolError("Missing \"kind\"") }
        if let kind = ElementKind(rawValue: name) { return kind }
        if let kind = ElementKind.allCases.first(where: {
            $0.rawValue.lowercased() == name.lowercased() || $0.displayName.lowercased() == name.lowercased()
        }) {
            return kind
        }
        throw ToolError("Unknown kind \(name). Kinds: \(ElementKind.allCases.map(\.rawValue).joined(separator: ", "))")
    }

    /// Parameters for a part: its model's values, then the given ones
    private static func parameters(kind: ElementKind, model: Any?, params: Any?) throws -> [String: Double] {
        var result: [String: Double] = [:]
        if let modelName = model as? String {
            guard let model = kind.models.first(where: { $0.name.lowercased() == modelName.lowercased() }) else {
                let names = kind.models.map(\.name)
                throw ToolError(names.isEmpty ? "\(kind.rawValue) has no models"
                                              : "\(kind.rawValue) has no model \(modelName); models: \(names.joined(separator: ", "))")
            }
            result = model.values
        }
        if let params = params as? [String: Any] {
            for (key, value) in params {
                guard kind.params.contains(where: { $0.key == key }) else {
                    throw ToolError("\(kind.rawValue) has no parameter \(key); parameters: \(kind.params.map(\.key).joined(separator: ", "))")
                }
                result[key] = try number(value, key)
            }
        } else if params != nil {
            throw ToolError("\"params\" should be an object")
        }
        return result
    }

    private func netlistPart(_ arguments: [String: Any]) throws -> NetlistPart {
        let kind = try Self.kind(arguments["kind"])
        var connections: [String: String] = [:]
        if let given = arguments["connections"] as? [String: Any] {
            for (terminal, net) in given {
                guard let net = net as? String else { throw ToolError("Net names should be strings (terminal \(terminal))") }
                connections[terminal] = net
            }
        }
        var part = NetlistPart(kind: kind, name: arguments["name"] as? String ?? "",
                               params: try Self.parameters(kind: kind, model: arguments["model"], params: arguments["params"]),
                               flipped: arguments["flipped"] as? Bool ?? false, connections: connections)
        if kind == .block {
            guard let name = arguments["block"] as? String, !name.isEmpty else {
                throw ToolError("A block part needs \"block\": the name of a block (see list_blocks)")
            }
            guard let block = self.block(named: name) else {
                throw ToolError("No block named \(name); blocks: \(availableBlocks().map(\.name).joined(separator: ", "))")
            }
            part.block = block
        }
        return part
    }

    /// Blocks made in this session, then those in the block library, then those already used in the circuit
    private func availableBlocks() -> [BlockDefinition] {
        var found = Array(blocks.values).sorted { $0.name < $1.name }
        var names = Set(found.map { $0.name.lowercased() })
        for block in BlockLibrary.all() + circuit.elements.compactMap(\.block) where !names.contains(block.name.lowercased()) {
            found.append(block)
            names.insert(block.name.lowercased())
        }
        return found
    }

    private func block(named name: String) -> BlockDefinition? {
        availableBlocks().first { $0.name.lowercased() == name.lowercased() }
    }

    func defineBlock(_ arguments: [String: Any]) throws -> Any {
        let name = try Self.text(arguments, "name").trimmingCharacters(in: .whitespaces)
        guard let list = arguments["parts"] as? [[String: Any]] else { throw ToolError("\"parts\" should be an array of parts") }
        let parts = SchematicLayout.choosingPortSides(try list.map(netlistPart))
        guard parts.contains(where: { $0.kind == .port }) else {
            throw ToolError("A block needs at least one port part: {\"kind\": \"port\", \"name\": \"in\", \"connections\": {\"net\": \"in\"}}")
        }
        if let used = parts.first(where: { $0.block?.uses(name) ?? false }) {
            throw ToolError("\(used.name) is block \(name) or uses it: a block cannot contain itself")
        }
        let inner: Circuit
        do {
            inner = try SchematicLayout.layout(parts)
        } catch let error as NetlistError {
            throw ToolError(error.description)
        }
        let block = inner.asBlock(named: name)
        blocks[name] = block
        if arguments["save"] as? Bool == true { try BlockLibrary.save(block) }
        return Self.describe(block)
    }

    func listBlocks() -> Any {
        availableBlocks().map { Self.describe($0) }
    }

    static func describe(_ block: BlockDefinition) -> [String: Any] {
        let ports = block.ports
        return ["name": block.name, "inputs": ports.filter { !$0.right }.map(\.name), "outputs": ports.filter(\.right).map(\.name),
                "parts": block.circuit.elements.filter { ![.wire, .ground, .netLabel, .port].contains($0.kind) }.count]
    }

    private func replace(_ next: Circuit, _ action: String) {
        circuit = next
        onChange?(next, action)
    }

    private func change(_ action: String, _ body: (inout Circuit) throws -> Void) rethrows {
        var next = circuit
        try body(&next)
        replace(next, action)
    }

    // MARK: - Tools

    func listParts() -> Any {
        ElementKind.allCases.map { kind -> [String: Any] in
            var parameters: [[String: Any]] = []
            for spec in kind.params {
                var entry: [String: Any] = ["key": spec.key, "name": spec.name, "unit": spec.unit, "default": spec.defaultValue,
                                            "min": spec.range.lowerBound, "max": spec.range.upperBound]
                if kind == .led && spec.key == "color" { entry["name"] = "Color: 0 red, 1 green, 2 blue, 3 yellow, 4 white" }
                if !spec.choices.isEmpty {
                    let names = spec.choices.map { "\(SI.trimmed($0.value, digits: 3)) \($0.name)" }
                    entry["name"] = spec.name + ": " + names.joined(separator: ", ")
                }
                parameters.append(entry)
            }
            var models: [[String: Any]] = []
            for model in kind.models {
                models.append(["name": model.name, "summary": model.summary, "values": model.values])
            }
            let part: [String: Any] = [
                "kind": kind.rawValue,
                "name": kind.displayName,
                "category": kind.category.rawValue,
                "terminals": kind == .block ? ["(its ports, by name: see list_blocks)"] : kind.terminalNames,
                "parameters": parameters,
                "models": models,
            ]
            return part
        }
    }

    func loadExample(_ arguments: [String: Any]) throws -> Any {
        let id = try Self.text(arguments, "id")
        guard let example = Examples.example(id) else {
            throw ToolError("No example \(id); examples: \(Examples.all.map(\.id).joined(separator: ", "))")
        }
        replace(example.circuit, "Open \(example.title)")
        return describe()
    }

    func buildCircuit(_ arguments: [String: Any]) throws -> Any {
        guard let parts = arguments["parts"] as? [[String: Any]] else { throw ToolError("\"parts\" should be an array of parts") }
        let append = arguments["append"] as? Bool ?? false
        try layOut(adding: try parts.map(netlistPart), keepExisting: append, action: append ? "Add Parts" : "Build Circuit")
        return describe()
    }

    /// Redraws the circuit as a tidy schematic from its netlist, with `parts` added (and the existing parts dropped
    /// unless `keepExisting`)
    private func layOut(adding parts: [NetlistPart], keepExisting: Bool, action: String) throws {
        var netlist = keepExisting ? NetlistExtractor.netlist(from: circuit) : []
        var names = Set(netlist.map(\.name))
        for part in parts where !part.name.isEmpty {
            guard !names.contains(part.name) else { throw ToolError("There is already a part named \(part.name)") }
            names.insert(part.name)
        }
        netlist += parts
        var next: Circuit
        do {
            next = try SchematicLayout.layout(netlist)
        } catch let error as NetlistError {
            throw ToolError(error.description)
        }
        next.settings = circuit.settings
        next.sequence = circuit.sequence
        if keepExisting { next.scopes = circuit.scopes.filter { scope in next.elements.contains { $0.id == scope.elementID } } }
        replace(next, action)
    }

    func tidyUp() throws -> Any {
        try layOut(adding: [], keepExisting: true, action: "Tidy Up")
        return describe()
    }

    func addPart(_ arguments: [String: Any]) throws -> Any {
        let part = try netlistPart(arguments)
        let a = try Self.gridPoint(arguments["a"], "a")
        let b = try Self.gridPoint(arguments["b"], "b")
        var name = ""
        if a != nil { try change("Add \(part.kind.displayName)") { circuit in
            if let a {
                guard part.name.isEmpty || !circuit.elements.contains(where: { $0.name == part.name }) else {
                    throw ToolError("There is already a part named \(part.name)")
                }
                var params = part.params
                for spec in part.kind.params where params[spec.key] == nil { params[spec.key] = spec.defaultValue }
                let fixedLength = part.kind == .block ? part.block?.chipPackage.length : part.kind.fixedLength
                var end = b ?? a + (part.kind == .block ? GridPoint(0, fixedLength ?? 2) : part.kind.defaultOffset)
                if let fixed = fixedLength {
                    let d = end - a
                    let direction = abs(d.x) >= abs(d.y) ? GridPoint(d.x >= 0 ? 1 : -1, 0) : GridPoint(0, d.y >= 0 ? 1 : -1)
                    end = a + direction * fixed
                }
                var element = Element(kind: part.kind, name: part.name, a: a, b: end, params: params, flipped: part.flipped)
                element.block = part.block
                let id = circuit.add(element)
                circuit.connectTerminals(of: [id])
                name = circuit[id]?.name ?? ""
            }
        } }
        if a == nil {
            // by its connections: redraw the whole circuit with the part in its place
            var named = part
            if named.name.isEmpty { named.name = circuit.uniqueName(for: part.kind) }
            name = named.name
            try layOut(adding: [named], keepExisting: true, action: "Add \(part.kind.displayName)")
        }
        guard let index = circuit.elements.firstIndex(where: { $0.name == name }) else { return ["ok": true] }
        let element = circuit.elements[index]
        return ["name": name, "terminals": Dictionary(zip(element.terminalNames, element.posts.map { [$0.x, $0.y] })) { first, _ in first }]
    }

    func addWire(_ arguments: [String: Any]) throws -> Any {
        guard let a = try Self.gridPoint(arguments["a"], "a"), let b = try Self.gridPoint(arguments["b"], "b") else {
            throw ToolError("A wire needs \"a\" and \"b\"")
        }
        guard a != b else { throw ToolError("The wire's ends are the same point") }
        change("Add Wire") { circuit in
            let id = circuit.add(Element(kind: .wire, a: a, b: b))
            circuit.connectTerminals(of: [id])
        }
        return ["ok": true]
    }

    func removePart(_ arguments: [String: Any]) throws -> Any {
        let index = try index(ofPart: try Self.text(arguments, "part"))
        let id = circuit.elements[index].id
        change("Delete") { $0.remove([id]) }
        return ["ok": true]
    }

    func setParameter(_ arguments: [String: Any]) throws -> Any {
        let index = try index(ofPart: try Self.text(arguments, "part"))
        let key = try Self.text(arguments, "parameter")
        let element = circuit.elements[index]
        guard let spec = element.kind.params.first(where: { $0.key == key }) else {
            throw ToolError("\(element.name) has no parameter \(key); parameters: \(element.kind.params.map(\.key).joined(separator: ", "))")
        }
        guard let value = try Self.number(arguments["value"], key) else { throw ToolError("Missing \"value\"") }
        change("Change \(spec.name)") { $0.elements[index][param: key] = value }
        return ["part": element.name, key: value, "model": circuit.elements[index].model?.name ?? "custom"]
    }

    func setModel(_ arguments: [String: Any]) throws -> Any {
        let index = try index(ofPart: try Self.text(arguments, "part"))
        let kind = circuit.elements[index].kind
        let values = try Self.parameters(kind: kind, model: try Self.text(arguments, "model"), params: nil)
        change("Use \(arguments["model"] as? String ?? "")") { circuit in
            for (key, value) in values { circuit.elements[index][param: key] = value }
        }
        return ["part": circuit.elements[index].name, "model": circuit.elements[index].model?.name ?? "custom", "values": values]
    }

    // MARK: - Microcontrollers

    private func microcontroller(_ arguments: [String: Any]) throws -> Int {
        let index = try index(ofPart: try Self.text(arguments, "part"))
        guard circuit.elements[index].kind.isMicrocontroller else {
            throw ToolError("\(circuit.elements[index].name) is not a microcontroller")
        }
        return index
    }

    func uploadSketch(_ arguments: [String: Any]) throws -> Any {
        let index = try microcontroller(arguments)
        let code = try Self.text(arguments, "code")
        let board = circuit.elements[index].kind.board ?? .uno
        guard ChipSupport.isAvailable(board.family) else {
            throw ToolError("No compiler for the \(board.chip) is installed: call install_chip_support with family "
                            + "\(board.family.rawValue) first (or install it from JSpice's Chip Support window)")
        }
        let result = SketchBuilder.build(code, board: board)
        guard let firmware = result.firmware else {
            let errors = result.errors.map { ["line": $0.line, "column": $0.column, "message": $0.message] as [String: Any] }
            return ["uploaded": false, "errors": errors, "log": String(result.log.suffix(4000))]
        }
        change("Upload Sketch") { circuit in
            circuit.elements[index].code = code
            circuit.elements[index].firmware = firmware
        }
        return ["uploaded": true, "part": circuit.elements[index].name, "bytes": firmware.count, "flash": board.flashSize]
    }

    func readSerial(_ arguments: [String: Any]) throws -> Any {
        let index = try microcontroller(arguments)
        guard let chip = liveSimulator?.chip(index) else {
            return ["output": "", "note": "Nothing simulated yet (or the part has no sketch): call simulate first"]
        }
        if let text = arguments["send"] as? String { chip.serialInput += Array(text.utf8) }
        return ["output": String(decoding: chip.serialOutput.suffix(16_384), as: UTF8.self), "time": liveSimulator?.time ?? 0]
    }

    func installChipSupport(_ arguments: [String: Any]) throws -> Any {
        let name = arguments["family"] as? String ?? ChipFamily.avr.rawValue
        guard let family = ChipFamily(rawValue: name) else {
            throw ToolError("unknown family \(name): \(ChipFamily.allCases.map(\.rawValue).joined(separator: " or "))")
        }
        if ChipSupport.isAvailable(family) { return ["installed": true, "note": "already available"] }
        final class Outcome: @unchecked Sendable { var error: Error? }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await ChipSupport.install(family) { _ in }
            } catch {
                outcome.error = error
            }
            done.signal()
        }
        done.wait()
        if let error = outcome.error { throw ToolError("\(error)") }
        return ["installed": true, "versions": ChipSupport.installedVersions(family).map { ["compiler": $0.compiler, "core": $0.core] } ?? [:]]
    }

    func setSwitch(_ arguments: [String: Any]) throws -> Any {
        let index = try index(ofPart: try Self.text(arguments, "part"))
        guard circuit.elements[index].kind.isSwitch else { throw ToolError("\(circuit.elements[index].name) is not a switch") }
        let closed = arguments["closed"] as? Bool ?? true
        change(closed ? "Close Switch" : "Open Switch") { $0.elements[index].closed = closed }
        return ["part": circuit.elements[index].name, "closed": closed]
    }

    func setTemperature(_ arguments: [String: Any]) throws -> Any {
        guard let celsius = try Self.number(arguments["celsius"], "celsius"), (-200...500).contains(celsius) else {
            throw ToolError("\"celsius\" should be a temperature from -200 to 500 °C")
        }
        change("Change Temperature") { $0.settings.temperature = celsius }
        return ["temperature": celsius]
    }

    func mapMIDI(_ arguments: [String: Any]) throws -> Any {
        let index = try index(ofPart: try Self.text(arguments, "part"))
        let element = circuit.elements[index]
        guard MIDIMapping.mappable.contains(element.kind) else {
            throw ToolError("\(element.name) is a \(element.kind.displayName); MIDI controllers map to potentiometers, switches and push buttons")
        }
        if arguments["remove"] as? Bool == true {
            change("Forget MIDI Controller") { $0.forgetMIDI(part: element.id) }
            return ["part": element.name, "midi": NSNull()]
        }
        guard let controller = (arguments["controller"] as? NSNumber)?.intValue, (0...119).contains(controller) else {
            throw ToolError("\"controller\" should be a control change number from 0 to 119")
        }
        var channel: Int?
        if let given = arguments["channel"] {
            guard let number = (given as? NSNumber)?.intValue, (1...16).contains(number) else { throw ToolError("\"channel\" should be 1 to 16") }
            channel = number - 1
        }
        change("Learn MIDI Controller") { $0.learnMIDI(controller: controller, channel: channel, part: element.id) }
        return ["part": element.name, "midi": circuit.midiMapping(part: element.id)?.label ?? ""]
    }

    func setSequence(_ arguments: [String: Any]) throws -> Any {
        guard let list = arguments["steps"] as? [Any] else { throw ToolError("\"steps\" should be a list of notes and rests") }
        var steps: [Double?] = []
        for step in list {
            if step is NSNull { steps.append(nil); continue }
            if let number = step as? NSNumber, number.doubleValue.isFinite, abs(number.doubleValue) < 1000 {
                steps.append(number.doubleValue)
                continue
            }
            if let text = step as? String {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed == "-" || trimmed.lowercased() == "rest" { steps.append(nil); continue }
                if let note = Self.noteNumber(trimmed) { steps.append(note); continue }
            }
            throw ToolError("Can't read the step \(step) as a note: use a MIDI number such as 60, a name such as \"C4\", or null for a rest")
        }
        guard steps.count <= 64 else { throw ToolError("At most 64 steps") }
        var sequence = circuit.sequence ?? StepSequence(steps: [])
        sequence.steps = steps
        if let tempo = try Self.number(arguments["tempo"], "tempo") {
            guard tempo >= 20, tempo <= 400 else { throw ToolError("\"tempo\" should be between 20 and 400") }
            sequence.tempo = tempo
        }
        if let gate = try Self.number(arguments["gate"], "gate") {
            guard gate > 0, gate <= 1 else { throw ToolError("\"gate\" should be above 0 and at most 1") }
            sequence.gateLength = gate
        }
        sequence.playing = arguments["playing"] as? Bool ?? true
        if !circuit.elements.contains(where: { $0.kind.isKeyboard }) {
            throw ToolError("The circuit has no keyboardPitch or keyboardGate source for the sequence to play")
        }
        change(sequence.playing ? "Set Sequence" : "Stop Sequence") { $0.sequence = sequence }
        return Self.describe(sequence)
    }

    static func describe(_ sequence: StepSequence) -> [String: Any] {
        let steps = sequence.steps.map { step -> Any in
            if let step { return step }
            return NSNull()
        }
        return ["steps": steps, "tempo": sequence.tempo,
         "gate": sequence.gateLength, "playing": sequence.playing, "step_seconds": sequence.stepDuration]
    }

    func describe() -> [String: Any] {
        let simulator = Simulator(circuit: circuit, timeStep: 1e-6)
        let netlist = NetlistExtractor.netlist(from: circuit)
        var parts: [[String: Any]] = []
        var nets = Set<String>()
        for entry in netlist {
            guard let element = circuit.elements.first(where: { $0.id == entry.id }) else { continue }
            nets.formUnion(entry.connections.values)
            var part: [String: Any] = [
                "name": element.name, "kind": element.kind.rawValue, "connections": entry.connections,
            ]
            if !element.kind.params.isEmpty {
                part["params"] = Dictionary(uniqueKeysWithValues: element.kind.params.map { ($0.key, element[param: $0.key]) })
            }
            if !element.kind.models.isEmpty { part["model"] = element.model?.name ?? "custom" }
            if element.kind.isSwitch { part["closed"] = element.closed }
            if let block = element.block { part["block"] = block.name }
            if let mapping = circuit.midiMapping(part: element.id) { part["midi"] = mapping.label }
            parts.append(part)
        }
        var result: [String: Any] = [
            "parts": parts,
            "nets": nets.sorted(),
            "problems": simulator.problems,
            "suggested_time_step": Pacing.suggest(for: circuit).timeStep,
            "temperature": circuit.settings.temperature,
        ]
        if let sequence = circuit.sequence { result["sequence"] = Self.describe(sequence) }
        return result
    }

    // MARK: - Simulation

    /// Reads one probe value from the simulator
    private struct Probe {
        let label: String
        let read: (Simulator) -> Double
    }

    private func probe(_ spec: String) throws -> Probe {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else {
            throw ToolError("Probe \(spec) should look like V(net), V(R1), I(R1), P(R1), R(R1) or V(U1.out)")
        }
        let quantity = trimmed[..<open].uppercased()
        let target = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        // a terminal: part.terminal
        if quantity == "V", let dot = target.lastIndex(of: "."), circuit.elements.contains(where: { $0.name == String(target[..<dot]) }) {
            let index = try index(ofPart: String(target[..<dot]))
            let terminal = String(target[target.index(after: dot)...])
            guard let t = NetlistLayout.terminalIndex(terminal, of: circuit.elements[index]) else {
                throw ToolError("\(target[..<dot]) has no terminal \(terminal); terminals: \(circuit.elements[index].terminalNames.joined(separator: ", "))")
            }
            return Probe(label: trimmed) { $0.terminalVoltage(index, t) }
        }
        // a net
        if quantity == "V" {
            if target.uppercased() == "GND" || target == "0" { return Probe(label: trimmed) { _ in 0 } }
            if !circuit.elements.contains(where: { $0.kind != .netLabel && $0.name == target }), let (index, t) = terminal(onNet: target) {
                return Probe(label: trimmed) { $0.terminalVoltage(index, t) }
            }
        }
        let index = try index(ofPart: target)
        switch quantity {
        case "V": return Probe(label: trimmed) { $0.voltageAcross(index) }
        case "I": return Probe(label: trimmed) { $0.current(index) }
        case "P": return Probe(label: trimmed) { $0.value(.power, of: index) }
        case "R": return Probe(label: trimmed) { $0.value(.resistance, of: index) }
        default: throw ToolError("Unknown quantity \(quantity) in \(spec): use V, I, P or R")
        }
    }

    private static let maxSteps = 4_000_000
    /// A run stops after this long, so a heavy circuit cannot hold the app (or the agent) indefinitely
    private static let maxWallSeconds = 300.0

    func simulate(_ arguments: [String: Any]) throws -> Any {
        guard let duration = try Self.number(arguments["duration"], "duration"), duration > 0 else {
            throw ToolError("\"duration\" should be a positive number of seconds")
        }
        guard let specs = arguments["probes"] as? [String], !specs.isEmpty else { throw ToolError("\"probes\" should list what to record") }
        let probes = try specs.map(probe)
        let points = max(2, min(5000, (arguments["points"] as? NSNumber)?.intValue ?? 200))
        let timeStep = try Self.number(arguments["time_step"], "time_step") ?? min(Pacing.suggest(for: circuit).timeStep, duration / 400)
        guard timeStep > 0 else { throw ToolError("\"time_step\" should be positive") }
        let stepCount = (duration / timeStep).rounded(.up)
        guard stepCount.isFinite, stepCount <= Double(Self.maxSteps) else {
            throw ToolError("That is \(stepCount) steps; at most \(Self.maxSteps). Use a shorter duration or a longer time step.")
        }
        let steps = max(1, Int(stepCount))

        let simulator: Simulator
        if arguments["continue"] as? Bool == true, let live = liveSimulator {
            simulator = live
            simulator.setTimeStep(timeStep)
        } else {
            simulator = Simulator(circuit: circuit, timeStep: timeStep)
        }
        liveSimulator = simulator
        if simulator.isFailed { throw ToolError(simulator.problems.joined(separator: " ")) }

        let events = try Self.keyboardEvents(arguments["keyboard"])
        var nextEvent = 0
        let start = simulator.time
        var traces = probes.map { _ in Trace() }
        let wallStart = Date()
        let stride = max(1, (steps + points - 1) / points)
        let keepEvery = max(1, steps / 200_000)
        var truncated = false
        for step in 1...steps {
            // events take effect from the first step that ends at or after their time (relative to this run's start)
            while nextEvent < events.count && events[nextEvent].at <= simulator.time - start + timeStep / 2 {
                let event = events[nextEvent]
                simulator.keyboard = Simulator.KeyboardState(note: event.note ?? simulator.keyboard.note, gate: event.note != nil)
                nextEvent += 1
            }
            simulator.step()
            if simulator.isFailed { break }
            if step % 4096 == 0 && Date().timeIntervalSince(wallStart) > Self.maxWallSeconds {
                truncated = true
                break
            }
            let record = step % stride == 0 || step == steps
            let keep = step % keepEvery == 0
            for k in probes.indices {
                let value = probes[k].read(simulator)
                traces[k].add(value, at: simulator.time, sample: record, keep: keep)
            }
        }
        var result: [String: Any] = [
            "start_time": start, "end_time": simulator.time, "time_step": timeStep, "steps": steps,
            "wall_seconds": Date().timeIntervalSince(wallStart),
            "convergence_failures": simulator.convergenceFailures,
            "truncated": truncated,
        ]
        if simulator.isFailed || !simulator.problems.isEmpty { result["problems"] = simulator.problems }
        var outputs: [String: Any] = [:]
        for (probe, trace) in zip(probes, traces) { outputs[probe.label] = trace.summary() }
        result["probes"] = outputs
        return result
    }

    /// Keyboard events for simulate: a time, and a note to press or nil to release
    func noise(_ arguments: [String: Any]) throws -> Any {
        let spec = try Self.text(arguments, "output")
        let source: Int?
        if let name = arguments["source"] as? String, !name.isEmpty {
            source = try index(ofPart: name)
        } else {
            let preference: [ElementKind] = [.acVoltage, .audioInput, .squareVoltage, .noiseVoltage, .keyboardPitch, .currentSource]
            source = preference.lazy.compactMap { kind in self.circuit.elements.firstIndex { $0.kind == kind } }.first
        }
        let start = try Self.number(arguments["start"], "start") ?? 20
        let stop = try Self.number(arguments["stop"], "stop") ?? 20_000
        let perDecade = max(1, min(200, (arguments["points_per_decade"] as? NSNumber)?.intValue ?? 20))
        guard start > 0, stop > start, stop < 1e10, log10(stop / start) * Double(perDecade) <= 2000 else {
            throw ToolError("Need 0 < start < stop < 10 GHz, and at most 2000 frequencies")
        }
        let frequencies = FrequencySweep.logarithmic(from: start, to: stop, pointsPerDecade: perDecade)
        let settle = try Self.number(arguments["settle"], "settle")
        if let settle, !(settle >= 0 && settle < 1000) { throw ToolError("\"settle\" should be from 0 to 1000 seconds") }
        let simulator = Simulator.settled(circuit, holding: source, duration: settle)
        if simulator.isFailed { throw ToolError(simulator.problems.joined(separator: " ")) }
        let (plus, minus) = try smallSignalNodes(spec, simulator)
        guard let model = simulator.smallSignalModel(),
              let result = model.noise(plus: plus, minus: minus, input: source.flatMap { model.canDrive(from: $0) ? $0 : nil },
                                       sources: simulator.noiseSources(), frequencies: frequencies) else {
            throw ToolError("The linearised circuit can't be solved. Look for parts left floating without a DC path.")
        }
        var points: [[String: Any]] = []
        for (k, frequency) in frequencies.enumerated() {
            var point: [String: Any] = ["frequency": frequency, "output_nv_per_root_hz": result.output[k] * 1e9]
            if let input = result.input, input[k].isFinite { point["input_nv_per_root_hz"] = input[k] * 1e9 }
            points.append(point)
        }
        let power = result.total * result.total
        var reply: [String: Any] = [
            "output": spec, "points": points, "total_rms_uv": result.total * 1e6, "band": [start, stop],
            "contributions": result.contributions.prefix(12).map {
                ["source": $0.label, "rms_uv": $0.rms * 1e6, "share_percent": power > 0 ? 100 * $0.rms * $0.rms / power : 0]
            },
            "temperature": circuit.settings.temperature,
        ]
        if let source { reply["input"] = circuit.elements[source].name }
        return reply
    }

    // MARK: - Sweeps and tolerances

    /// Measurements of a circuit (this one, or a copy with other values), by name
    private func measure(_ circuit: Circuit, _ spec: [String: Any]) throws -> [String: Double] {
        let type = (spec["type"] as? String ?? "ac").lowercased()
        let settle = try Self.number(spec["settle"], "settle")
        if let settle, !(settle >= 0 && settle < 1000) { throw ToolError("\"settle\" should be from 0 to 1000 seconds") }
        var metrics: [String: Double] = [:]
        switch type {
        case "ac":
            let source = try index(ofPart: try Self.text(spec, "source"))
            let output = try Self.text(spec, "output")
            let frequencies = try (spec["frequencies"] as? [Any])?.map { try Self.number($0, "frequencies") ?? 0 } ?? [1000]
            guard !frequencies.isEmpty, frequencies.count <= 400, frequencies.allSatisfy({ $0 > 0 && $0 < 1e10 }) else {
                throw ToolError("\"frequencies\" should be 1 to 400 positive frequencies")
            }
            let simulator = Simulator.settled(circuit, holding: source, duration: settle)
            if simulator.isFailed { throw ToolError(simulator.problems.joined(separator: " ")) }
            let (plus, minus) = try smallSignalNodes(output, simulator)
            guard let model = simulator.smallSignalModel(),
                  let response = model.response(input: source, plus: plus, minus: minus, frequencies: frequencies) else {
                throw ToolError("The linearised circuit can't be solved")
            }
            let gains = response.map { 20 * log10(max($0.magnitude, 1e-15)) }
            for (k, f) in frequencies.enumerated() {
                metrics["gain_db@" + String(format: "%g", f)] = gains[k]
                metrics["phase_deg@" + String(format: "%g", f)] = response[k].phase * 180 / .pi
            }
            if frequencies.count >= 3, let peak = gains.indices.max(by: { gains[$0] < gains[$1] }) {
                metrics["peak_db"] = gains[peak]
                metrics["peak_hz"] = frequencies[peak]
                let level = gains[peak] - 3
                for k in 1..<gains.count where (gains[k - 1] - level) * (gains[k] - level) < 0 {
                    let f = (gains[k - 1] - level) / (gains[k - 1] - gains[k])
                    metrics["corner_hz"] = frequencies[k - 1] * pow(frequencies[k] / frequencies[k - 1], f)
                    break
                }
            }
        case "op":
            guard let specs = spec["probes"] as? [String], !specs.isEmpty else { throw ToolError("\"probes\" should list what to read") }
            let probes = try specs.map(probe)
            // every signal source held still: the operating point is where the circuit rests
            var still = circuit
            for i in still.elements.indices where [.acVoltage, .squareVoltage, .noiseVoltage, .audioInput].contains(still.elements[i].kind) {
                still = Simulator.quiet(still, holding: i)
            }
            let simulator = Simulator.settled(still, holding: nil, duration: settle)
            if simulator.isFailed { throw ToolError(simulator.problems.joined(separator: " ")) }
            for probe in probes { metrics[probe.label] = probe.read(simulator) }
        case "transient":
            guard let specs = spec["probes"] as? [String], !specs.isEmpty else { throw ToolError("\"probes\" should list what to record") }
            let probes = try specs.map(probe)
            guard let duration = try Self.number(spec["duration"], "duration"), duration > 0 else { throw ToolError("\"duration\" should be positive") }
            let skip = try Self.number(spec["skip"], "skip") ?? 0
            let timeStep = min(Pacing.suggest(for: circuit).timeStep, duration / 400)
            let steps = Int(((duration + skip) / timeStep).rounded(.up))
            guard steps <= Self.maxSteps else { throw ToolError("That is \(steps) steps; at most \(Self.maxSteps)") }
            let simulator = Simulator(circuit: circuit, timeStep: timeStep)
            var traces = probes.map { _ in Trace() }
            for _ in 0..<steps {
                simulator.step()
                if simulator.isFailed { throw ToolError(simulator.problems.joined(separator: " ")) }
                guard simulator.time >= skip else { continue }
                for k in probes.indices { traces[k].add(probes[k].read(simulator), at: simulator.time, sample: false, keep: true) }
            }
            for (probe, trace) in zip(probes, traces) where trace.count > 0 {
                let mean = trace.sum / Double(trace.count)
                metrics[probe.label + " mean"] = mean
                metrics[probe.label + " rms"] = (trace.sumOfSquares / Double(trace.count)).squareRoot()
                metrics[probe.label + " min"] = trace.minimum
                metrics[probe.label + " max"] = trace.maximum
                metrics[probe.label + " peak_to_peak"] = trace.maximum - trace.minimum
                if let frequency = trace.frequency() { metrics[probe.label + " frequency"] = frequency }
            }
        default:
            throw ToolError("\"type\" should be ac, op or transient")
        }
        return metrics
    }

    func sweep(_ arguments: [String: Any]) throws -> Any {
        let index = try index(ofPart: try Self.text(arguments, "part"))
        let key = try Self.text(arguments, "parameter")
        let element = circuit.elements[index]
        guard element.kind.params.contains(where: { $0.key == key }) else {
            throw ToolError("\(element.name) has no parameter \(key); parameters: \(element.kind.params.map(\.key).joined(separator: ", "))")
        }
        guard let spec = arguments["measure"] as? [String: Any] else { throw ToolError("\"measure\" should say what to measure") }
        var values = try (arguments["values"] as? [Any])?.map { try Self.number($0, "values") ?? 0 } ?? []
        if values.isEmpty {
            guard let start = try Self.number(arguments["start"], "start"), let stop = try Self.number(arguments["stop"], "stop") else {
                throw ToolError("Give \"values\", or \"start\" and \"stop\"")
            }
            let points = max(2, min(100, (arguments["points"] as? NSNumber)?.intValue ?? 11))
            let logarithmic = arguments["logarithmic"] as? Bool ?? (start > 0 && stop / start >= 10)
            values = Sweep.values(from: start, to: stop, count: points, logarithmic: logarithmic)
        }
        guard values.count <= 100 else { throw ToolError("At most 100 values") }
        let wallStart = Date()
        var rows: [[String: Any]] = []
        var truncated = false
        for value in values {
            if Date().timeIntervalSince(wallStart) > Self.maxWallSeconds {
                truncated = true
                break
            }
            var variant = circuit
            variant.elements[index][param: key] = value
            var row: [String: Any] = ["value": value]
            do {
                for (name, metric) in try measure(variant, spec) { row[name] = metric }
            } catch {
                row["error"] = "\(error)"
            }
            rows.append(row)
        }
        return ["part": element.name, "parameter": key, "rows": rows, "truncated": truncated,
                "wall_seconds": Date().timeIntervalSince(wallStart)]
    }

    func optimize(_ arguments: [String: Any]) throws -> Any {
        guard let spec = arguments["measure"] as? [String: Any] else { throw ToolError("\"measure\" should say what to measure") }
        guard let given = arguments["parameters"] as? [[String: Any]], !given.isEmpty, given.count <= 12 else {
            throw ToolError("\"parameters\" should list 1 to 12 values to change")
        }
        struct Knob {
            var index: Int, key: String, low: Double, high: Double, log: Bool
            var passive: Bool
            func value(_ u: Double) -> Double { log ? low * pow(high / low, u) : low + (high - low) * u }
            func unit(_ v: Double) -> Double {
                let u = log ? Foundation.log(v / low) / Foundation.log(high / low) : (v - low) / (high - low)
                return u.isFinite ? min(max(u, 0), 1) : 0.5
            }
        }
        var knobs: [Knob] = []
        for entry in given {
            let index = try index(ofPart: try Self.text(entry, "part"))
            let key = try Self.text(entry, "parameter")
            let element = circuit.elements[index]
            guard let spec = element.kind.params.first(where: { $0.key == key }) else {
                throw ToolError("\(element.name) has no parameter \(key); parameters: \(element.kind.params.map(\.key).joined(separator: ", "))")
            }
            let low = try Self.number(entry["min"], "min") ?? spec.range.lowerBound
            let high = try Self.number(entry["max"], "max") ?? spec.range.upperBound
            guard high > low else { throw ToolError("\(element.name) \(key): min should be below max") }
            let log = entry["log"] as? Bool ?? (low > 0 && high / low >= 10)
            guard !log || low > 0 else { throw ToolError("\(element.name) \(key): a log scale needs a positive min") }
            let passive = ["resistance", "capacitance", "inductance"].contains(key)
            knobs.append(Knob(index: index, key: key, low: low, high: high, log: log, passive: passive))
        }
        struct Target {
            var metric: String, value: Double?, low: Double?, high: Double?, goal: Double, weight: Double
            /// dB and degrees count as they are; anything else relative to the target
            func scale(_ reference: Double) -> Double {
                metric.contains("db") || metric.contains("deg") ? 1 : max(abs(reference), 1e-12)
            }
        }
        guard let targetList = arguments["targets"] as? [[String: Any]], !targetList.isEmpty else { throw ToolError("\"targets\" should say what to achieve") }
        let targets = try targetList.map { entry -> Target in
            let goal = (entry["goal"] as? String)?.lowercased()
            guard goal == nil || goal == "minimize" || goal == "maximize" else { throw ToolError("\"goal\" should be minimize or maximize") }
            return Target(metric: try Self.text(entry, "metric"), value: try Self.number(entry["value"], "value"),
                          low: try Self.number(entry["min"], "min"), high: try Self.number(entry["max"], "max"),
                          goal: goal == "minimize" ? 1 : goal == "maximize" ? -1 : 0, weight: try Self.number(entry["weight"], "weight") ?? 1)
        }
        func variant(at values: [Double]) -> Circuit {
            var copy = self.circuit
            for (knob, value) in zip(knobs, values) { copy.elements[knob.index][param: knob.key] = value }
            return copy
        }
        var missing = Set<String>()
        func cost(_ values: [Double]) -> (cost: Double, metrics: [String: Double]) {
            guard let metrics = try? measure(variant(at: values), spec) else { return (1e12, [:]) }
            var total = 0.0
            for target in targets {
                guard let m = metrics[target.metric] else {
                    missing.insert(target.metric)
                    total += 1e6
                    continue
                }
                if let value = target.value {
                    let e = (m - value) / target.scale(value)
                    total += target.weight * e * e
                }
                if let low = target.low, m < low {
                    let e = (low - m) / target.scale(low)
                    total += target.weight * e * e
                }
                if let high = target.high, m > high {
                    let e = (m - high) / target.scale(high)
                    total += target.weight * e * e
                }
                if target.goal != 0 { total += target.weight * target.goal * m / target.scale(m) }
            }
            return (total, metrics)
        }
        let limit = max(10, min(1000, (arguments["evaluations"] as? NSNumber)?.intValue ?? 150))
        let wallStart = Date()
        let start = knobs.map { $0.unit(circuit.elements[$0.index][param: $0.key]) }
        let found = Optimizer.minimize({ point in
            Date().timeIntervalSince(wallStart) > Self.maxWallSeconds ? .greatestFiniteMagnitude : cost(zip(knobs, point).map { $0.value($1) }).cost
        }, start: start, evaluations: limit)
        if !missing.isEmpty {
            throw ToolError("No measurement named \(missing.sorted().joined(separator: ", ")); the measurement gives \(cost(knobs.map { circuit.elements[$0.index][param: $0.key] }).metrics.keys.sorted().joined(separator: ", "))")
        }
        var values = zip(knobs, found.point).map { $0.value($1) }
        var best = cost(values)
        var evaluations = found.evaluations
        // standard values: the nearest of each, then whichever neighbour helps, until none does
        if let size = (arguments["series"] as? NSNumber)?.intValue {
            guard ESeries.mantissas(size) != nil else { throw ToolError("\"series\" should be 12, 24 or 96") }
            for (k, knob) in knobs.enumerated() where knob.passive {
                if let around = ESeries.around(values[k], series: size) { values[k] = around.nearest }
            }
            best = cost(values)
            var improved = true
            while improved && evaluations < limit + 100 {
                improved = false
                for (k, knob) in knobs.enumerated() where knob.passive {
                    guard let around = ESeries.around(values[k], series: size) else { continue }
                    for candidate in [around.below, around.above] where candidate >= knob.low * 0.999 && candidate <= knob.high * 1.001 {
                        var trial = values
                        trial[k] = candidate
                        let result = cost(trial)
                        evaluations += 1
                        if result.cost < best.cost {
                            values = trial
                            best = result
                            improved = true
                        }
                    }
                }
            }
        }
        if arguments["apply"] as? Bool ?? true {
            change("Optimize") { circuit in
                for (knob, value) in zip(knobs, values) { circuit.elements[knob.index][param: knob.key] = value }
            }
        }
        return [
            "values": zip(knobs, values).map { ["part": circuit.elements[$0.index].name, "parameter": $0.key, "value": $1] },
            "cost": best.cost, "metrics": best.metrics, "evaluations": evaluations,
            "wall_seconds": Date().timeIntervalSince(wallStart),
            "targets": targets.map { target -> [String: Any] in
                var entry: [String: Any] = ["metric": target.metric]
                if let m = best.metrics[target.metric] { entry["achieved"] = m }
                if let v = target.value { entry["wanted"] = v }
                return entry
            },
        ]
    }

    func monteCarlo(_ arguments: [String: Any]) throws -> Any {
        guard let spec = arguments["measure"] as? [String: Any] else { throw ToolError("\"measure\" should say what to measure") }
        let runs = max(1, min(500, (arguments["runs"] as? NSNumber)?.intValue ?? 50))
        let seed = UInt64(truncatingIfNeeded: (arguments["seed"] as? NSNumber)?.int64Value ?? 1)
        var tolerances = Tolerances()
        if let given = arguments["tolerances"] as? [String: Any] {
            for (key, value) in given where key != "parts" {
                guard let fraction = try Self.number(value, key), fraction >= 0, fraction < 1 else { throw ToolError("\(key) should be a fraction from 0 to 1") }
                switch key {
                case "resistors": tolerances.resistors = fraction
                case "capacitors": tolerances.capacitors = fraction
                case "inductors": tolerances.inductors = fraction
                case "transistor_gain": tolerances.transistorGain = fraction
                case "fets": tolerances.fets = fraction
                default: throw ToolError("Unknown tolerance \(key): resistors, capacitors, inductors, transistor_gain, fets, parts")
                }
            }
            for (name, value) in given["parts"] as? [String: Any] ?? [:] {
                guard let fraction = try Self.number(value, name), fraction >= 0, fraction < 1 else { throw ToolError("\(name) should be a fraction from 0 to 1") }
                tolerances.parts[circuit.elements[try index(ofPart: name)].id] = fraction
            }
        }
        let wallStart = Date()
        let nominal = try measure(circuit, spec)
        var samples: [String: [(run: Int, value: Double)]] = [:]
        var failed = 0, done = 0
        for run in 1...runs {
            if Date().timeIntervalSince(wallStart) > Self.maxWallSeconds { break }
            done += 1
            guard let metrics = try? measure(tolerances.variant(of: circuit, seed: seed, run: run), spec) else {
                failed += 1
                continue
            }
            for (name, value) in metrics { samples[name, default: []].append((run, value)) }
        }
        var results: [String: Any] = [:]
        for (name, values) in samples {
            guard let summary = Tolerances.summary(values.map(\.value)) else { continue }
            var entry: [String: Any] = [
                "mean": summary.mean, "std": summary.standardDeviation, "min": summary.minimum, "max": summary.maximum,
                "p5": summary.low, "p95": summary.high,
            ]
            if let value = nominal[name] { entry["nominal"] = value }
            if let low = values.min(by: { $0.value < $1.value }) { entry["min_run"] = low.run }
            if let high = values.max(by: { $0.value < $1.value }) { entry["max_run"] = high.run }
            results[name] = entry
        }
        return ["runs": done, "failed": failed, "seed": seed, "metrics": results, "wall_seconds": Date().timeIntervalSince(wallStart)]
    }

    // MARK: - Sound

    func spectrum(_ arguments: [String: Any]) throws -> Any {
        let probe = try probe(try Self.text(arguments, "probe"))
        let duration = try Self.number(arguments["duration"], "duration") ?? 0.5
        let settle = try Self.number(arguments["settle"], "settle") ?? 0.2
        let maxFrequency = try Self.number(arguments["max_frequency"], "max_frequency") ?? 20_000
        guard duration > 0, settle >= 0, maxFrequency > 0 else { throw ToolError("duration and max_frequency should be positive, settle not negative") }
        let timeStep = min(Pacing.suggest(for: circuit).timeStep, 1 / (4 * maxFrequency))
        let total = ((duration + settle) / timeStep).rounded(.up)
        guard total <= Double(Self.maxSteps) else {
            throw ToolError("That is \(Int(total)) steps; at most \(Self.maxSteps). Use a shorter duration or a lower max_frequency.")
        }
        let events = try Self.keyboardEvents(arguments["keyboard"])
        let simulator = Simulator(circuit: circuit, timeStep: timeStep)
        if simulator.isFailed { throw ToolError(simulator.problems.joined(separator: " ")) }
        let settleSteps = Int((settle / timeStep).rounded())
        let wallStart = Date()
        var values: [Double] = []
        values.reserveCapacity(Int(total) - settleSteps)
        var nextEvent = 0
        for step in 0..<Int(total) {
            while nextEvent < events.count && events[nextEvent].at <= simulator.time + timeStep / 2 {
                simulator.keyboard = Simulator.KeyboardState(note: events[nextEvent].note ?? simulator.keyboard.note, gate: events[nextEvent].note != nil)
                nextEvent += 1
            }
            simulator.step()
            if simulator.isFailed { break }
            if step >= settleSteps { values.append(probe.read(simulator)) }
            if step % 4096 == 0 && Date().timeIntervalSince(wallStart) > Self.maxWallSeconds { break }
        }
        if simulator.isFailed { throw ToolError("The simulation failed: \(simulator.problems.joined(separator: " "))") }
        guard let spectrum = Spectrum.analyze(values, interval: timeStep, maxFrequency: maxFrequency) else {
            throw ToolError("Too short to analyse: record at least 64 steps (a longer duration)")
        }
        func decibels(_ a: Double) -> Double { 20 * log10(max(a, 1e-15)) }
        var result: [String: Any] = [
            "probe": probe.label, "resolution_hz": spectrum.resolution, "max_frequency": spectrum.maxFrequency,
            "rms": spectrum.rms, "mean": spectrum.mean, "time_step": timeStep,
        ]
        if let f0 = spectrum.fundamental { result["fundamental_hz"] = f0 }
        if let thd = spectrum.thd { result["thd_percent"] = thd * 100 }
        let reference = spectrum.harmonics.first?.amplitude ?? 0
        result["harmonics"] = spectrum.harmonics.map { harmonic -> [String: Any] in
            var entry: [String: Any] = ["n": harmonic.number, "frequency": harmonic.frequency, "amplitude": harmonic.amplitude,
                                        "level_db": decibels(harmonic.amplitude)]
            if reference > 0 { entry["relative_db"] = decibels(harmonic.amplitude / reference) }
            return entry
        }
        // the strongest peaks that are not harmonics: hum, intermodulation, aliasing…
        let a = spectrum.amplitudes
        let loudest = a.dropFirst(3).max() ?? 0
        let harmonicBins = Set(spectrum.harmonics.flatMap { h -> [Int] in
            let c = Int((h.frequency / spectrum.binWidth).rounded())
            return Array((c - 3)...(c + 3))
        })
        let peaks = (3..<max(3, a.count - 1)).filter {
            a[$0] > a[$0 - 1] && a[$0] >= a[$0 + 1] && a[$0] > loudest * 1e-3 && !harmonicBins.contains($0)
        }
        .sorted { a[$0] > a[$1] }
        .prefix(8)
        result["other_peaks"] = peaks.map { ["frequency": spectrum.frequency(ofBin: $0), "level_db": decibels(a[$0])] }
        return result
    }

    func setAudioInput(_ arguments: [String: Any]) throws -> Any {
        let index = try index(ofPart: try Self.text(arguments, "part"))
        guard circuit.elements[index].kind == .audioInput else { throw ToolError("\(circuit.elements[index].name) is not an audio input") }
        var clip: AudioClip?
        if let path = arguments["path"] as? String, !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let data: Data
            do { data = try Data(contentsOf: url) } catch { throw ToolError("Can't read \(path)") }
            do { clip = try AudioClip(name: url.deletingPathExtension().lastPathComponent, wav: data) } catch {
                throw ToolError("\(path): \(error)")
            }
        }
        let level = try Self.number(arguments["level"], "level")
        let loop = arguments["loop"] as? Bool
        change("Choose Sound") {
            $0.elements[index].audio = clip
            $0.elements[index][param: "input"] = 0
            if let level { $0.elements[index][param: "level"] = level }
            if let loop { $0.elements[index][param: "loop"] = loop ? 1 : 0 }
        }
        let playing = clip ?? AudioClip.guitarRiff
        return ["part": circuit.elements[index].name, "sound": playing.name, "seconds": playing.duration,
                "sample_rate": playing.sampleRate, "level": circuit.elements[index][param: "level"]]
    }

    func renderAudio(_ arguments: [String: Any]) throws -> Any {
        let path = (try Self.text(arguments, "path") as NSString).expandingTildeInPath
        guard let duration = try Self.number(arguments["duration"], "duration"), duration > 0, duration <= 120 else {
            throw ToolError("\"duration\" should be between 0 and 120 seconds")
        }
        let output: Int
        if let name = arguments["output"] as? String, !name.isEmpty {
            output = try index(ofPart: name)
        } else if let speaker = circuit.elements.firstIndex(where: { $0.kind == .speaker }) {
            output = speaker
        } else {
            throw ToolError("There is no speaker; name the part to record as \"output\"")
        }
        let sampleRate = try Self.number(arguments["sample_rate"], "sample_rate") ?? 48_000
        guard (8000...192_000).contains(sampleRate) else { throw ToolError("\"sample_rate\" should be between 8000 and 192000") }
        let fullScale = try Self.number(arguments["full_scale"], "full_scale")
        if let fullScale, !(fullScale > 0) { throw ToolError("\"full_scale\" should be positive") }
        let events = try Self.keyboardEvents(arguments["keyboard"])
        let wallStart = Date()
        let result = AudioRender.render(circuit, output: output, duration: duration, sampleRate: sampleRate, fullScale: fullScale,
                                        keyboard: events, deadline: wallStart.addingTimeInterval(Self.maxWallSeconds))
        do {
            try WAV.encode(result.samples, sampleRate: result.sampleRate).write(to: URL(fileURLWithPath: path))
        } catch {
            throw ToolError("Can't write \(path)")
        }
        let seconds = Double(result.samples.count) / result.sampleRate
        var reply: [String: Any] = [
            "saved": path, "seconds": seconds, "sample_rate": result.sampleRate,
            "peak": result.peak, "clipped": result.clipped, "wall_seconds": Date().timeIntervalSince(wallStart),
            "truncated": seconds < duration - 0.5 / sampleRate,
        ]
        if !result.problems.isEmpty { reply["problems"] = result.problems }
        return reply
    }

    static func keyboardEvents(_ value: Any?) throws -> [(at: Double, note: Double?)] {
        guard let value else { return [] }
        guard let list = value as? [[String: Any]] else { throw ToolError("\"keyboard\" should be a list of {\"at\": seconds, \"note\": 60} or {\"at\": seconds, \"off\": true}") }
        var events: [(at: Double, note: Double?)] = []
        for entry in list {
            let at = try number(entry["at"], "at") ?? 0
            if entry["off"] as? Bool == true {
                events.append((at, nil))
            } else if let number = entry["note"] as? NSNumber, number.doubleValue.isFinite, abs(number.doubleValue) < 1000 {
                events.append((at, number.doubleValue))
            } else if let name = entry["note"] as? String, let note = noteNumber(name) {
                events.append((at, note))
            } else {
                throw ToolError("Each keyboard event needs \"note\" (a MIDI number such as 60, or a name such as \"C4\" or \"F#3\") or \"off\": true")
            }
        }
        return events.sorted { $0.at < $1.at }
    }

    /// MIDI note number of a note name such as "C4" (60), "A4" (69), "F#3" or "Bb2"
    static func noteNumber(_ name: String) -> Double? {
        NoteName.number(name)
    }

    /// A part terminal on the named net: (element index, terminal index)
    private func terminal(onNet net: String) -> (Int, Int)? {
        for entry in NetlistExtractor.netlist(from: circuit) {
            guard let (terminal, _) = entry.connections.first(where: { $0.value == net }),
                  let index = circuit.elements.firstIndex(where: { $0.id == entry.id }),
                  let t = circuit.elements[index].terminalNames.firstIndex(of: terminal) else { continue }
            return (index, t)
        }
        if let label = circuit.elements.firstIndex(where: { $0.kind == .netLabel && $0.name == net }) { return (label, 0) }
        return nil
    }

    func measure() -> Any {
        guard let simulator = liveSimulator else { return ["note": "Nothing simulated yet: call simulate first"] }
        var nets: [String: Double] = [:]
        for entry in NetlistExtractor.netlist(from: circuit) {
            guard let index = circuit.elements.firstIndex(where: { $0.id == entry.id }) else { continue }
            let voltages = simulator.terminalVoltages(index)
            for (terminal, net) in entry.connections where nets[net] == nil {
                if let t = circuit.elements[index].terminalNames.firstIndex(of: terminal), t < voltages.count { nets[net] = voltages[t] }
            }
        }
        var parts: [String: Any] = [:]
        for (i, element) in circuit.elements.enumerated() where ![.wire, .ground, .netLabel].contains(element.kind) {
            parts[element.name] = [
                "voltage": simulator.voltageAcross(i), "current": simulator.current(i),
                "power": simulator.value(.power, of: i),
                "terminals": Dictionary(zip(element.terminalNames, simulator.terminalVoltages(i))) { first, _ in first },
            ] as [String: Any]
        }
        return ["time": simulator.time, "nets": nets, "parts": parts]
    }

    func frequencyResponse(_ arguments: [String: Any]) throws -> Any {
        let sourceName = try Self.text(arguments, "source")
        let sourceIndex = try index(ofPart: sourceName)
        let method = (arguments["method"] as? String ?? "ac").lowercased()
        guard method == "ac" || method == "transient" else { throw ToolError("\"method\" should be ac or transient") }
        let small = method == "ac"
        let limit = small ? 2000 : 200
        var frequencies = try (arguments["frequencies"] as? [Any])?.map { try Self.number($0, "frequencies") ?? 0 } ?? []
        if frequencies.isEmpty {
            let start = try Self.number(arguments["start"], "start") ?? 10
            let stop = try Self.number(arguments["stop"], "stop") ?? 100_000
            let perDecade = max(1, min(200, (arguments["points_per_decade"] as? NSNumber)?.intValue ?? (small ? 20 : 5)))
            guard start > 0, stop > start else { throw ToolError("Need 0 < start < stop") }
            let count = (log10(stop / start) * Double(perDecade)).rounded() + 1
            guard count.isFinite, count <= Double(limit) else { throw ToolError("At most \(limit) frequencies") }
            frequencies = FrequencySweep.logarithmic(from: start, to: stop, pointsPerDecade: perDecade)
        }
        guard frequencies.count <= limit else { throw ToolError("At most \(limit) frequencies") }
        guard frequencies.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1e10 }) else {
            throw ToolError("Frequencies should be positive and below 10 GHz")
        }
        if small { return try smallSignalResponse(arguments, source: sourceIndex, frequencies: frequencies) }
        guard circuit.elements[sourceIndex].kind == .acVoltage else { throw ToolError("\(sourceName) should be an AC voltage source") }
        let output = try probe(try Self.text(arguments, "output"))
        let wallStart = Date()
        var previousPhase: Double?
        // long enough for the slowest part of the circuit to settle, and at least 10 cycles
        let settle = 5 * (Pacing.slowestTimeScale(of: circuitWithoutSources()) ?? 0)
        let input = Probe(label: sourceName) { $0.voltageAcross(sourceIndex) }
        var rows: [[String: Any]] = []
        for frequency in frequencies where frequency > 0 {
            var test = circuit
            test.elements[sourceIndex][param: "frequency"] = frequency
            let samplesPerCycle = 64
            let timeStep = 1 / (frequency * Double(samplesPerCycle))
            let measureCycles = 4
            // settle for the slowest part of the circuit, within the step limit (high frequencies take the most steps)
            let wanted = max(10, (settle * frequency).rounded(.up))
            let affordable = Double(Self.maxSteps / samplesPerCycle - measureCycles)
            let settled = wanted.isFinite && wanted <= affordable
            let settleCycles = Int(settled ? wanted : max(10, affordable))
            let total = (settleCycles + measureCycles) * samplesPerCycle
            guard Date().timeIntervalSince(wallStart) < 300 else {
                rows.append(["frequency": frequency, "error": "skipped: the sweep ran out of time (5 minutes)"])
                continue
            }
            let simulator = Simulator(circuit: test, timeStep: timeStep)
            var inPhase = (0.0, 0.0)
            var outPhase = (0.0, 0.0)
            for step in 1...total {
                simulator.step()
                guard step > settleCycles * samplesPerCycle else { continue }
                let angle = 2 * Double.pi * frequency * simulator.time
                let x = input.read(simulator)
                let y = output.read(simulator)
                if simulator.isFailed { break }
                inPhase.0 += x * cos(angle)
                inPhase.1 -= x * sin(angle)
                outPhase.0 += y * cos(angle)
                outPhase.1 -= y * sin(angle)
            }
            let inputAmplitude = hypot(inPhase.0, inPhase.1)
            let outputAmplitude = hypot(outPhase.0, outPhase.1)
            let gain = inputAmplitude > 0 ? outputAmplitude / inputAmplitude : 0
            if simulator.isFailed {
                rows.append(["frequency": frequency, "error": simulator.problems.joined(separator: " ")])
                continue
            }
            var phase = (atan2(outPhase.1, outPhase.0) - atan2(inPhase.1, inPhase.0)) * 180 / .pi
            while phase > 180 { phase -= 360 }
            while phase <= -180 { phase += 360 }
            // continuous from one frequency to the next, so a third-order roll-off reads −270°, not +90°
            if let previous = previousPhase {
                while phase - previous > 180 { phase -= 360 }
                while phase - previous < -180 { phase += 360 }
            }
            previousPhase = phase
            var row: [String: Any] = ["frequency": frequency, "gain": gain, "gain_db": 20 * log10(max(gain, 1e-12)), "phase_deg": phase]
            if !settled { row["settled"] = false }
            rows.append(row)
        }
        return ["source": sourceName, "output": output.label, "method": "transient", "points": rows]
    }

    /// frequency_response by small-signal analysis around the operating point the circuit settles to
    private func smallSignalResponse(_ arguments: [String: Any], source: Int, frequencies: [Double]) throws -> Any {
        let sourceName = circuit.elements[source].name
        let kind = circuit.elements[source].kind
        guard kind.isVoltageSource || kind == .currentSource else { throw ToolError("\(sourceName) should be a voltage or current source") }
        let spec = try Self.text(arguments, "output")
        let settle = try Self.number(arguments["settle"], "settle")
        if let settle, !(settle >= 0 && settle < 1000) { throw ToolError("\"settle\" should be from 0 to 1000 seconds") }
        let wallStart = Date()
        let simulator = Simulator.settled(circuit, holding: source, duration: settle)
        if simulator.isFailed { throw ToolError(simulator.problems.joined(separator: " ")) }
        let (plus, minus) = try smallSignalNodes(spec, simulator)
        guard let model = simulator.smallSignalModel(),
              let response = model.response(input: source, plus: plus, minus: minus, frequencies: frequencies) else {
            throw ToolError("The linearised circuit can't be solved. Look for parts left floating without a DC path.")
        }
        let phases = FrequencySweep.unwrappedPhases(response)
        let gains = response.map(\.magnitude)
        var rows: [[String: Any]] = []
        for (k, frequency) in frequencies.enumerated() {
            rows.append(["frequency": frequency, "gain": gains[k], "gain_db": 20 * log10(max(gains[k], 1e-15)), "phase_deg": phases[k]])
        }
        var result: [String: Any] = [
            "source": sourceName, "output": spec, "method": "ac", "points": rows,
            "operating_point": ["time": simulator.time, "output_dc": simulator.nodeVoltage(plus) - simulator.nodeVoltage(minus)],
            "wall_seconds": Date().timeIntervalSince(wallStart),
        ]
        if let peak = gains.indices.max(by: { gains[$0] < gains[$1] }) {
            let peakDB = 20 * log10(max(gains[peak], 1e-15))
            result["peak"] = ["frequency": frequencies[peak], "gain_db": peakDB]
            // where the gain crosses 3 dB below the peak, interpolated on the log-frequency scale
            var corners: [Double] = []
            let level = peakDB - 3
            for k in 1..<max(1, gains.count) {
                let a = 20 * log10(max(gains[k - 1], 1e-15)) - level
                let b = 20 * log10(max(gains[k], 1e-15)) - level
                guard (a < 0) != (b < 0), a != b else { continue }
                let f = a / (a - b)
                corners.append(frequencies[k - 1] * pow(frequencies[k] / frequencies[k - 1], f))
            }
            result["minus_3db"] = corners
        }
        if !simulator.problems.isEmpty { result["problems"] = simulator.problems }
        return result
    }

    /// The nodes a voltage probe reads, plus and minus, for small-signal analysis
    private func smallSignalNodes(_ spec: String, _ simulator: Simulator) throws -> (Int, Int) {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")"), trimmed[..<open].uppercased() == "V" else {
            throw ToolError("For ac, the output should be a voltage: V(net), V(part) or V(part.terminal); use method transient for I, P or R")
        }
        let target = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        if let dot = target.lastIndex(of: "."), circuit.elements.contains(where: { $0.name == String(target[..<dot]) }) {
            let index = try index(ofPart: String(target[..<dot]))
            let terminal = String(target[target.index(after: dot)...])
            guard let t = NetlistLayout.terminalIndex(terminal, of: circuit.elements[index]) else {
                throw ToolError("\(target[..<dot]) has no terminal \(terminal); terminals: \(circuit.elements[index].terminalNames.joined(separator: ", "))")
            }
            return (simulator.nodes(of: index)[t], 0)
        }
        if target.uppercased() == "GND" || target == "0" { return (0, 0) }
        if !circuit.elements.contains(where: { $0.kind != .netLabel && $0.name == target }), let (index, t) = terminal(onNet: target) {
            return (simulator.nodes(of: index)[t], 0)
        }
        let index = try index(ofPart: target)
        guard let nodes = simulator.acrossNodes(index) else { throw ToolError("\(target) has no voltage to probe") }
        return (nodes.plus, nodes.minus)
    }

    /// The circuit without its sources' own periods, for estimating how long it takes to settle
    private func circuitWithoutSources() -> Circuit {
        var copy = circuit
        copy.elements.removeAll { [.acVoltage, .squareVoltage, .noiseVoltage, .audioInput].contains($0.kind) }
        return copy
    }

    // MARK: - Files

    func importSpice(_ arguments: [String: Any]) throws -> Any {
        var text = arguments["netlist"] as? String ?? ""
        if text.isEmpty, let path = arguments["path"] as? String, !path.isEmpty {
            do { text = try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8) } catch {
                throw ToolError("Can't read \(path)")
            }
        }
        guard !text.isEmpty else { throw ToolError("Give the netlist as \"netlist\" or a file as \"path\"") }
        let (imported, warnings) = try SpiceNetlist.circuit(from: text)
        replace(imported, "Import SPICE Netlist")
        var result = describe()
        result["left_out"] = warnings
        return result
    }

    func exportSpice(_ arguments: [String: Any]) throws -> Any {
        let deck = SpiceNetlist.export(circuit)
        if let path = arguments["path"] as? String, !path.isEmpty {
            let file = (path as NSString).expandingTildeInPath
            do { try deck.write(toFile: file, atomically: true, encoding: .utf8) } catch { throw ToolError("Can't write \(path)") }
            return ["saved": file, "netlist": deck]
        }
        return ["netlist": deck]
    }

    func save(_ arguments: [String: Any]) throws -> Any {
        let path = (try Self.text(arguments, "path") as NSString).expandingTildeInPath
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(circuit).write(to: URL(fileURLWithPath: path))
        return ["saved": path]
    }

    func open(_ arguments: [String: Any]) throws -> Any {
        let path = (try Self.text(arguments, "path") as NSString).expandingTildeInPath
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        replace(try JSONDecoder().decode(Circuit.self, from: data), "Open")
        return describe()
    }
}

/// Recorded values of one probe: downsampled samples, and statistics over every step
struct Trace {
    var times: [Double] = []
    var values: [Double] = []
    var kept: [(Double, Double)] = []
    var count = 0
    var sum = 0.0
    var sumOfSquares = 0.0
    var minimum = Double.infinity
    var maximum = -Double.infinity
    var last = 0.0

    mutating func add(_ value: Double, at time: Double, sample: Bool, keep: Bool) {
        guard value.isFinite else { return }
        count += 1
        sum += value
        sumOfSquares += value * value
        minimum = min(minimum, value)
        maximum = max(maximum, value)
        last = value
        if sample {
            times.append(time)
            values.append(value)
        }
        if keep { kept.append((time, value)) }
    }

    /// Frequency from upward crossings of the mean, with hysteresis of a tenth of the peak-to-peak value
    func frequency() -> Double? {
        let mean = sum / Double(max(count, 1))
        let band = (maximum - minimum) * 0.1
        guard band > 0 else { return nil }
        var below = false
        var crossings: [Double] = []
        for (time, value) in kept {
            if value < mean - band { below = true }
            if below && value > mean + band {
                crossings.append(time)
                below = false
            }
        }
        guard crossings.count >= 2 else { return nil }
        return Double(crossings.count - 1) / (crossings.last! - crossings.first!)
    }

    func summary() -> [String: Any] {
        guard count > 0 else { return ["note": "no values"] }
        let mean = sum / Double(count)
        var result: [String: Any] = [
            "min": minimum, "max": maximum, "mean": mean, "rms": (sumOfSquares / Double(count)).squareRoot(),
            "peak_to_peak": maximum - minimum, "final": last, "time": times, "value": values,
        ]
        if let frequency = frequency() { result["frequency"] = frequency }
        return result
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
