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
    frequency_response for filters and amplifiers. Adjust values with set_parameter or set_model and simulate again. \
    Values accept SI prefixes as strings ("4.7k", "100n", "2.2u", "1meg"). Probes: "V(net)" is a net's voltage, \
    "V(R1)" the voltage across a part, "I(R1)" its current, "P(R1)" its power, "V(U1.out)" a terminal's voltage. \
    Synth circuits can be played: keyboardPitch parts put out 1 V per octave (0 V at C2) and keyboardGate parts a gate, \
    driven by the "keyboard" events of simulate (for example [{"at": 0, "note": "C4"}, {"at": 0.5, "off": true}]) \
    or by a step sequence (set_sequence). Synth chips (vco, vcf, envelope, vca, sampleHold, comparator, divider) model \
    the AS3340, AS3320, AS3310, SSM2164, LF398, LM393 and CD4013 and patch together like modules.
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
             description: "Measures gain and phase from an AC voltage source to a probe at a range of frequencies, by simulating each frequency until steady and comparing the waveforms.",
             inputSchema: schema([
                "source": string("Name of the AC voltage source driving the circuit"),
                "output": string("Probe for the output, for example \"V(out)\""),
                "start": ["description": "Lowest frequency in Hz (default 10)"],
                "stop": ["description": "Highest frequency in Hz (default 100k)"],
                "points_per_decade": ["type": "integer", "description": "Default 5"],
                "frequencies": ["type": "array", "items": ["type": "number"], "description": "Explicit frequencies instead of start/stop"],
             ], required: ["source", "output"]),
             run: { session, arguments in try session.frequencyResponse(arguments) }),
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
              let x = (array[0] as? NSNumber)?.intValue, let y = (array[1] as? NSNumber)?.intValue else {
            throw ToolError("\(what) should be [x, y] with whole numbers")
        }
        return GridPoint(x, y)
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

    private static func netlistPart(_ arguments: [String: Any]) throws -> NetlistPart {
        let kind = try kind(arguments["kind"])
        var connections: [String: String] = [:]
        if let given = arguments["connections"] as? [String: Any] {
            for (terminal, net) in given {
                guard let net = net as? String else { throw ToolError("Net names should be strings (terminal \(terminal))") }
                connections[terminal] = net
            }
        }
        return NetlistPart(kind: kind, name: arguments["name"] as? String ?? "",
                           params: try parameters(kind: kind, model: arguments["model"], params: arguments["params"]),
                           flipped: arguments["flipped"] as? Bool ?? false, connections: connections)
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
                "terminals": kind.terminalNames,
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
        try layOut(adding: try parts.map(Self.netlistPart), keepExisting: append, action: append ? "Add Parts" : "Build Circuit")
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
        let part = try Self.netlistPart(arguments)
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
                var end = b ?? a + part.kind.defaultOffset
                if let fixed = part.kind.fixedLength {
                    let d = end - a
                    let direction = abs(d.x) >= abs(d.y) ? GridPoint(d.x >= 0 ? 1 : -1, 0) : GridPoint(0, d.y >= 0 ? 1 : -1)
                    end = a + direction * fixed
                }
                let element = Element(kind: part.kind, name: part.name, a: a, b: end, params: params, flipped: part.flipped)
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
        return ["name": name, "terminals": Dictionary(uniqueKeysWithValues: zip(element.kind.terminalNames, element.posts.map { [$0.x, $0.y] }))]
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

    func setSwitch(_ arguments: [String: Any]) throws -> Any {
        let index = try index(ofPart: try Self.text(arguments, "part"))
        guard circuit.elements[index].kind.isSwitch else { throw ToolError("\(circuit.elements[index].name) is not a switch") }
        let closed = arguments["closed"] as? Bool ?? true
        change(closed ? "Close Switch" : "Open Switch") { $0.elements[index].closed = closed }
        return ["part": circuit.elements[index].name, "closed": closed]
    }

    func setSequence(_ arguments: [String: Any]) throws -> Any {
        guard let list = arguments["steps"] as? [Any] else { throw ToolError("\"steps\" should be a list of notes and rests") }
        var steps: [Double?] = []
        for step in list {
            if step is NSNull { steps.append(nil); continue }
            if let number = step as? NSNumber { steps.append(number.doubleValue); continue }
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
            parts.append(part)
        }
        var result: [String: Any] = [
            "parts": parts,
            "nets": nets.sorted(),
            "problems": simulator.problems,
            "suggested_time_step": Pacing.suggest(for: circuit).timeStep,
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
            guard let t = NetlistLayout.terminalIndex(terminal, of: circuit.elements[index].kind) else {
                throw ToolError("\(target[..<dot]) has no terminal \(terminal); terminals: \(circuit.elements[index].kind.terminalNames.joined(separator: ", "))")
            }
            return Probe(label: trimmed) { $0.terminalVoltages(index)[safe: t] ?? 0 }
        }
        // a net
        if quantity == "V" {
            if target.uppercased() == "GND" || target == "0" { return Probe(label: trimmed) { _ in 0 } }
            if !circuit.elements.contains(where: { $0.kind != .netLabel && $0.name == target }), let (index, t) = terminal(onNet: target) {
                return Probe(label: trimmed) { $0.terminalVoltages(index)[safe: t] ?? 0 }
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

    func simulate(_ arguments: [String: Any]) throws -> Any {
        guard let duration = try Self.number(arguments["duration"], "duration"), duration > 0 else {
            throw ToolError("\"duration\" should be a positive number of seconds")
        }
        guard let specs = arguments["probes"] as? [String], !specs.isEmpty else { throw ToolError("\"probes\" should list what to record") }
        let probes = try specs.map(probe)
        let points = max(2, min(5000, (arguments["points"] as? NSNumber)?.intValue ?? 200))
        let timeStep = try Self.number(arguments["time_step"], "time_step") ?? min(Pacing.suggest(for: circuit).timeStep, duration / 400)
        guard timeStep > 0 else { throw ToolError("\"time_step\" should be positive") }
        let steps = Int((duration / timeStep).rounded(.up))
        guard steps <= Self.maxSteps else {
            throw ToolError("That is \(steps) steps; at most \(Self.maxSteps). Use a shorter duration or a longer time step.")
        }

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
        let stride = max(1, steps / points)
        let keepEvery = max(1, steps / 200_000)
        for step in 1...steps {
            // events take effect from the first step that ends at or after their time (relative to this run's start)
            while nextEvent < events.count && events[nextEvent].at <= simulator.time - start + timeStep / 2 {
                let event = events[nextEvent]
                simulator.keyboard = Simulator.KeyboardState(note: event.note ?? simulator.keyboard.note, gate: event.note != nil)
                nextEvent += 1
            }
            simulator.step()
            if simulator.isFailed { break }
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
        ]
        if simulator.isFailed || !simulator.problems.isEmpty { result["problems"] = simulator.problems }
        var outputs: [String: Any] = [:]
        for (probe, trace) in zip(probes, traces) { outputs[probe.label] = trace.summary() }
        result["probes"] = outputs
        return result
    }

    /// Keyboard events for simulate: a time, and a note to press or nil to release
    static func keyboardEvents(_ value: Any?) throws -> [(at: Double, note: Double?)] {
        guard let value else { return [] }
        guard let list = value as? [[String: Any]] else { throw ToolError("\"keyboard\" should be a list of {\"at\": seconds, \"note\": 60} or {\"at\": seconds, \"off\": true}") }
        var events: [(at: Double, note: Double?)] = []
        for entry in list {
            let at = try number(entry["at"], "at") ?? 0
            if entry["off"] as? Bool == true {
                events.append((at, nil))
            } else if let number = entry["note"] as? NSNumber {
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
                  let t = circuit.elements[index].kind.terminalNames.firstIndex(of: terminal) else { continue }
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
                if let t = circuit.elements[index].kind.terminalNames.firstIndex(of: terminal), t < voltages.count { nets[net] = voltages[t] }
            }
        }
        var parts: [String: Any] = [:]
        for (i, element) in circuit.elements.enumerated() where ![.wire, .ground, .netLabel].contains(element.kind) {
            parts[element.name] = [
                "voltage": simulator.voltageAcross(i), "current": simulator.current(i),
                "power": simulator.value(.power, of: i),
                "terminals": Dictionary(uniqueKeysWithValues: zip(element.kind.terminalNames, simulator.terminalVoltages(i))),
            ] as [String: Any]
        }
        return ["time": simulator.time, "nets": nets, "parts": parts]
    }

    func frequencyResponse(_ arguments: [String: Any]) throws -> Any {
        let sourceName = try Self.text(arguments, "source")
        let sourceIndex = try index(ofPart: sourceName)
        guard circuit.elements[sourceIndex].kind == .acVoltage else { throw ToolError("\(sourceName) should be an AC voltage source") }
        let output = try probe(try Self.text(arguments, "output"))
        var frequencies = (arguments["frequencies"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
        if frequencies.isEmpty {
            let start = try Self.number(arguments["start"], "start") ?? 10
            let stop = try Self.number(arguments["stop"], "stop") ?? 100_000
            let perDecade = max(1, (arguments["points_per_decade"] as? NSNumber)?.intValue ?? 5)
            guard start > 0, stop > start else { throw ToolError("Need 0 < start < stop") }
            let count = Int((log10(stop / start) * Double(perDecade)).rounded()) + 1
            frequencies = (0..<count).map { start * pow(10, Double($0) / Double(perDecade)) }
        }
        guard frequencies.count <= 200 else { throw ToolError("At most 200 frequencies") }
        // long enough for the slowest part of the circuit to settle, and at least 10 cycles
        let settle = 5 * (Pacing.slowestTimeScale(of: circuitWithoutSources()) ?? 0)
        let input = Probe(label: sourceName) { $0.voltageAcross(sourceIndex) }
        var rows: [[String: Any]] = []
        for frequency in frequencies where frequency > 0 {
            var test = circuit
            test.elements[sourceIndex][param: "frequency"] = frequency
            let samplesPerCycle = 64
            let timeStep = 1 / (frequency * Double(samplesPerCycle))
            let settleCycles = max(10, Int((settle * frequency).rounded(.up)))
            let measureCycles = 4
            let total = (settleCycles + measureCycles) * samplesPerCycle
            guard total <= Self.maxSteps else {
                throw ToolError("Settling at \(frequency) Hz would take \(total) steps; raise the start frequency")
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
                inPhase.0 += x * cos(angle)
                inPhase.1 -= x * sin(angle)
                outPhase.0 += y * cos(angle)
                outPhase.1 -= y * sin(angle)
            }
            let inputAmplitude = hypot(inPhase.0, inPhase.1)
            let outputAmplitude = hypot(outPhase.0, outPhase.1)
            let gain = inputAmplitude > 0 ? outputAmplitude / inputAmplitude : 0
            var phase = (atan2(outPhase.1, outPhase.0) - atan2(inPhase.1, inPhase.0)) * 180 / .pi
            while phase > 180 { phase -= 360 }
            while phase <= -180 { phase += 360 }
            rows.append(["frequency": frequency, "gain": gain, "gain_db": 20 * log10(max(gain, 1e-12)), "phase_deg": phase])
        }
        return ["source": sourceName, "output": output.label, "points": rows]
    }

    /// The circuit without its sources' own periods, for estimating how long it takes to settle
    private func circuitWithoutSources() -> Circuit {
        var copy = circuit
        copy.elements.removeAll { $0.kind == .acVoltage || $0.kind == .squareVoltage || $0.kind == .noiseVoltage }
        return copy
    }

    // MARK: - Files

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
