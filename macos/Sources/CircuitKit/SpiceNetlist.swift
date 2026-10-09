import Foundation

/// SPICE netlists in and out. A netlist of the usual elements (R, C, L, V, I, D, Q, M, J, coupled inductors, and
/// subcircuits) becomes a circuit drawn by the tidy layout, its subcircuits blocks; a circuit becomes a deck that runs in
/// ngspice (and LTspice) with JSpice's own device equations, the parts SPICE has no element for (op-amps, tubes) as
/// behavioural sources as `tools/spice-reference/crosscheck.py` writes them.
public enum SpiceNetlist {
    // MARK: - Values

    /// A SPICE number: "4.7k", "10meg", "1M" (milli, as in SPICE), "100nF", "2.2u", "1e-3"; letters after the scale
    /// (a unit) are ignored
    public static func value(_ text: String) -> Double? {
        let lower = text.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "µ", with: "u").replacingOccurrences(of: "μ", with: "u")
        let scanner = Scanner(string: lower)
        scanner.locale = Locale(identifier: "en_US_POSIX")
        scanner.charactersToBeSkipped = nil
        guard let number = scanner.scanDouble() else { return nil }
        let rest = String(lower[scanner.currentIndex...])
        let scales: [(String, Double)] = [("meg", 1e6), ("mil", 25.4e-6), ("t", 1e12), ("g", 1e9), ("k", 1e3), ("m", 1e-3),
                                          ("u", 1e-6), ("n", 1e-9), ("p", 1e-12), ("f", 1e-15)]
        for (prefix, scale) in scales where rest.hasPrefix(prefix) { return number * scale }
        return number
    }

    // MARK: - Import

    public struct Import {
        public var title: String
        public var parts: [NetlistPart]
        /// What was left out, and why
        public var warnings: [String]
    }

    /// The parts of a netlist (the first line is its title, as in SPICE). Nodes keep their names; 0 and GND are ground.
    public static func parse(_ text: String) -> Import {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            // inline comments
            var line = raw
            for marker in [";", "$ "] {
                if let range = line.range(of: marker) { line = String(line[..<range.lowerBound]) }
            }
            line = line.trimmingCharacters(in: .whitespaces)
            // a continuation joins the last line of the deck, past comments and blank lines (not the title)
            if line.hasPrefix("+"), let k = lines.indices.last(where: { $0 > 0 && !lines[$0].isEmpty && !lines[$0].hasPrefix("*") }) {
                lines[k] += " " + line.dropFirst()
            } else {
                lines.append(line)
            }
        }
        let title = lines.first.map { $0.hasPrefix("*") ? String($0.dropFirst()).trimmingCharacters(in: .whitespaces) : $0 } ?? ""
        var warnings: [String] = []
        var models: [String: (type: String, params: [String: Double])] = [:]
        // subcircuits: their pins and lines
        var subcircuits: [String: (pins: [String], lines: [String])] = [:]
        var top: [String] = []
        var open: (name: String, pins: [String], lines: [String])?
        // ngspice's interactive commands, between .control and .endc, are not part of the circuit
        var control = false
        // .param's constants, each worked out from those before it
        var parameters: [String: Double] = [:]
        for line in lines.dropFirst() where !line.isEmpty && !line.hasPrefix("*") {
            let words = tokens(line)
            guard let first = words.first?.lowercased() else { continue }
            if control {
                if first == ".endc" { control = false }
                continue
            }
            if first == ".control" {
                control = true
            } else if first == ".model", words.count >= 3 {
                var type = words[2].lowercased()
                var params: [String: Double] = [:]
                // "NPN(IS=1e-14 BF=100)" or "NPN IS=1e-14 BF=100"
                if let paren = type.firstIndex(of: "(") { type = String(type[..<paren]) }
                for word in words.dropFirst(3) where word.contains("=") {
                    let pair = word.split(separator: "=", maxSplits: 1).map(String.init)
                    if pair.count == 2, let v = value(pair[1]) { params[pair[0].uppercased()] = v }
                }
                models[words[1].lowercased()] = (type, params)
            } else if first == ".subckt", words.count >= 2 {
                open = (words[1].lowercased(), Array(words.dropFirst(2)).filter { !$0.contains("=") }, [])
            } else if first == ".ends" {
                if let sub = open { subcircuits[sub.name] = (sub.pins, sub.lines) }
                open = nil
            } else if first == ".end" {
                break
            } else if first == ".param" && open == nil {
                for assignment in Self.assignments(String(line.dropFirst(6))) {
                    if let v = Self.evaluate(assignment.value, parameters) {
                        parameters[assignment.name.lowercased()] = v
                    } else {
                        warnings.append(".param \(assignment.name): can't work out \(assignment.value)")
                    }
                }
            } else if first.hasPrefix(".") {
                if [".include", ".lib", ".param", ".func"].contains(first) { warnings.append("\(words[0]) is not followed: \(line)") }
            } else if open != nil {
                open?.lines.append(line)
            } else {
                top.append(line)
            }
        }
        var cache: [String: BlockDefinition] = [:]
        let parts = elements(top, models: models, subcircuits: subcircuits, cache: &cache, warnings: &warnings, depth: 0,
                             spellings: Spellings(), parameters: parameters)
        return Import(title: title, parts: parts, warnings: warnings)
    }

    /// The parsed netlist drawn as a circuit
    public static func circuit(from text: String) throws -> (circuit: Circuit, warnings: [String]) {
        let imported = parse(text)
        guard !imported.parts.isEmpty else { throw NetlistError.empty }
        return (try SchematicLayout.layout(imported.parts), imported.warnings)
    }

    /// Words of a line, with "(", ")" and "," as spaces except inside a source's function (kept as one word)
    static func tokens(_ line: String) -> [String] {
        var cleaned = line.replacingOccurrences(of: ",", with: " ")
        // "SIN (0 1 1k)" → "SIN(0 1 1k)", "IS = 1e-14" → "IS=1e-14"
        cleaned = cleaned.replacingOccurrences(of: #"\s*=\s*"#, with: "=", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(\w)\s+\("#, with: "$1(", options: .regularExpression)
        var words: [String] = []
        var current = ""
        var depth = 0
        for ch in cleaned {
            if ch == "(" { depth += 1 }
            if ch == ")" { depth = max(0, depth - 1) }
            if (ch == " " || ch == "\t") && depth == 0 {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        // a model's parameters in parentheses become words of their own
        return words.flatMap { word -> [String] in
            guard let open = word.firstIndex(of: "("), word.hasSuffix(")") else { return [word] }
            let head = String(word[..<open])
            let lower = head.lowercased()
            if ["sin", "pulse", "pwl", "exp", "sffm", "dc", "ac"].contains(lower) { return [word] }
            let inner = word[word.index(after: open)..<word.index(before: word.endIndex)]
            return [head] + inner.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        }
    }

    /// A number or a `{expression}` of .param's constants
    static func evaluate(_ text: String, _ parameters: [String: Double]) -> Double? {
        if let v = value(text) { return v }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("(") || parameters[trimmed.lowercased()] != nil else { return nil }
        return (try? SpiceExpression(parsing: trimmed, parameters: parameters))?.constantValue
    }

    /// `name=value` pairs, a value in braces kept whole
    static func assignments(_ text: String) -> [(name: String, value: String)] {
        var result: [(String, String)] = []
        let cleaned = text.replacingOccurrences(of: #"\s*=\s*"#, with: "=", options: .regularExpression)
        var depth = 0, current = ""
        var words: [String] = []
        for ch in cleaned {
            if ch == "{" || ch == "(" { depth += 1 }
            if ch == "}" || ch == ")" { depth = max(0, depth - 1) }
            if (ch == " " || ch == "\t" || ch == ",") && depth == 0 {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        for word in words {
            let pair = word.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { result.append((pair[0], pair[1])) }
        }
        return result
    }

    /// The voltage sources a deck's controlled sources read the current of: F and H sources' controls and the I( ) of
    /// expressions
    static func sensedSources(_ lines: [String]) -> Set<String> {
        var result = Set<String>()
        let current = try? NSRegularExpression(pattern: #"\bi\(\s*([^),\s]+)\s*\)"#, options: .caseInsensitive)
        for line in lines {
            guard let letter = line.lowercased().first else { continue }
            if let current {
                for match in current.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    if let r = Range(match.range(at: 1), in: line) { result.insert(line[r].lowercased()) }
                }
            }
            guard letter == "f" || letter == "h" else { continue }
            let words = tokens(line)
            guard words.count > 3 else { continue }
            if words[3].lowercased() == "poly", words.count > 4, let n = Int(words[4]) {
                for k in 0..<n where 5 + k < words.count { result.insert(words[5 + k].lowercased()) }
            } else {
                result.insert(words[3].lowercased())
            }
        }
        return result
    }

    /// A controlled source's expression in terms of SPICE's net and source names, and whether it sets a voltage: E and G
    /// (gain or transconductance, POLY, VALUE, TABLE), F and H (gain or transresistance, POLY), B (V= or I=)
    static func controlledSource(_ letter: Character, _ words: [String], _ line: String,
                                 _ parameters: [String: Double]) throws -> (SpiceExpression, Bool) {
        let voltage: Bool
        switch letter {
        case "e", "h": voltage = true
        case "f", "g": voltage = false
        default:
            // B: V= or I=, from the line itself (an expression may have spaces)
            guard let match = line.range(of: #"^\S+\s+\S+\s+\S+\s+([VvIi])\s*=\s*"#, options: .regularExpression) else {
                throw SpiceExpression.ParseError.unexpected("B source without V= or I=", at: line)
            }
            let kind = line[match].trimmingCharacters(in: .whitespaces).dropLast().trimmingCharacters(in: .whitespaces).last
            let text = String(line[match.upperBound...])
            return (try SpiceExpression(parsing: text, parameters: parameters), kind == "V" || kind == "v")
        }
        // (a pair of nets in parentheses leaves an empty word before it)
        let rest = words.dropFirst(3).filter { !$0.isEmpty }
        guard let first = rest.first else { throw SpiceExpression.ParseError.unexpected("end", at: line) }
        let head = first.lowercased()
        if let range = line.range(of: #"\bVALUE\s*=\s*"#, options: [.regularExpression, .caseInsensitive]) {
            return (try SpiceExpression(parsing: String(line[range.upperBound...]), parameters: parameters), voltage)
        }
        if head == "table" || head.hasPrefix("table{") {
            // TABLE {expression} = (x, y) (x, y) …
            guard let open = line.firstIndex(of: "{"), let close = line[open...].firstIndex(of: "}") else {
                throw SpiceExpression.ParseError.unexpected("TABLE without {expression}", at: line)
            }
            let argument = try SpiceExpression(parsing: String(line[open...close]), parameters: parameters)
            let numbers = line[line.index(after: close)...].split(whereSeparator: { " ,()=\t".contains($0) })
                .compactMap { evaluate(String($0), parameters) }
            guard numbers.count >= 2 else { throw SpiceExpression.ParseError.unexpected("TABLE points", at: line) }
            let xs = stride(from: 0, to: numbers.count - 1, by: 2).map { numbers[$0] }
            let ys = stride(from: 1, to: numbers.count, by: 2).map { numbers[$0] }
            return (SpiceExpression(root: .table(argument.root, xs, ys), inputs: argument.inputs), voltage)
        }
        if head == "laplace" || head == "freq" || head == "chebyshev" {
            throw SpiceExpression.ParseError.unknown("\(first.uppercased()) source")
        }
        let controlledByVoltage = letter == "e" || letter == "g"
        if head == "poly", rest.count > 1, let n = Int(rest[1]), n >= 1 {
            // POLY(n): n controls (pairs of nets, or sources), then the coefficients
            let controls = controlledByVoltage ? 2 * n : n
            guard rest.count >= 2 + controls else { throw SpiceExpression.ParseError.unexpected("POLY controls", at: line) }
            let names = Array(rest[2..<(2 + controls)])
            let inputs: [SpiceExpression.Input] = controlledByVoltage
                ? stride(from: 0, to: controls, by: 2).map { .voltage(names[$0], names[$0 + 1]) }
                : names.map { .current($0) }
            let coefficients = rest[(2 + controls)...].compactMap { evaluate($0, parameters) }
            return (SpiceExpression.polynomial(dimensions: n, coefficients: coefficients, inputs: inputs), voltage)
        }
        // linear: E/G n+ n- nc+ nc- gain; F/H n+ n- vname gain
        if controlledByVoltage {
            guard rest.count >= 3, let gain = evaluate(rest[2], parameters) else {
                throw SpiceExpression.ParseError.unexpected("gain", at: line)
            }
            return (SpiceExpression.polynomial(dimensions: 1, coefficients: [0, gain], inputs: [.voltage(rest[0], rest[1])]), voltage)
        }
        guard rest.count >= 2, let gain = evaluate(rest[1], parameters) else {
            throw SpiceExpression.ParseError.unexpected("gain", at: line)
        }
        return (SpiceExpression.polynomial(dimensions: 1, coefficients: [0, gain], inputs: [.current(rest[0])]), voltage)
    }

    /// Node names as first spelled: SPICE does not tell "Out" from "OUT"
    private final class Spellings {
        private var first: [String: String] = [:]

        func canonical(_ name: String) -> String {
            let key = name.lowercased()
            if let known = first[key] { return known }
            first[key] = name
            return name
        }
    }

    private static func net(_ name: String, _ prefix: String, _ spellings: Spellings) -> String {
        let lower = name.lowercased()
        if lower == "0" || lower == "gnd" { return "GND" }
        return prefix + spellings.canonical(name)
    }

    /// The arguments of a source's function: "SIN(0 1 1k)" → [0, 1, 1000]
    private static func arguments(_ word: String) -> [Double] {
        guard let open = word.firstIndex(of: "("), let close = word.lastIndex(of: ")"), open < close else { return [] }
        return word[word.index(after: open)..<close].split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { value(String($0)) }
    }

    private static func elements(_ lines: [String], models: [String: (type: String, params: [String: Double])],
                                 subcircuits: [String: (pins: [String], lines: [String])], cache: inout [String: BlockDefinition],
                                 warnings: inout [String], depth: Int, prefix: String = "", spellings: Spellings,
                                 parameters: [String: Double] = [:]) -> [NetlistPart] {
        var parts: [NetlistPart] = []
        // voltage sources whose current a controlled source reads: kept as sources (a 0 V one is otherwise an ammeter)
        let sensed = Self.sensedSources(lines)
        var inductors: [String: Int] = [:]
        var couplings: [(String, String, Double)] = []
        for line in lines {
            let words = tokens(line)
            guard let name = words.first, let letter = name.lowercased().first else { continue }
            func node(_ k: Int) -> String? { k < words.count ? net(words[k], prefix, spellings) : nil }
            func number(_ k: Int) -> Double? { k < words.count ? Self.evaluate(words[k], parameters) : nil }
            func keyword(_ key: String) -> Double? {
                words.first { $0.lowercased().hasPrefix(key.lowercased() + "=") }
                    .flatMap { Self.evaluate(String($0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[1]), parameters) }
            }
            switch letter {
            case "r", "c", "l":
                guard let a = node(1), let b = node(2), let v = number(3) else {
                    warnings.append("Can't read \(line)")
                    continue
                }
                switch letter {
                case "r": parts.append(NetlistPart(kind: .resistor, name: name, params: ["resistance": v], connections: ["a": a, "b": b]))
                case "c":
                    var params = ["capacitance": v]
                    if let ic = keyword("ic") { params["initialVoltage"] = ic }
                    parts.append(NetlistPart(kind: .capacitor, name: name, params: params, connections: ["a": a, "b": b]))
                default:
                    inductors[name.lowercased()] = parts.count
                    parts.append(NetlistPart(kind: .inductor, name: name, params: ["inductance": v], connections: ["a": a, "b": b]))
                }
            case "v", "i":
                guard let plus = node(1), let minus = node(2) else {
                    warnings.append("Can't read \(line)")
                    continue
                }
                let rest = Array(words.dropFirst(3))
                let function = rest.first { $0.contains("(") && !$0.lowercased().hasPrefix("ac") && !$0.lowercased().hasPrefix("dc(") }
                var dc = 0.0
                for (k, word) in rest.enumerated() {
                    if word.lowercased() == "dc", k + 1 < rest.count, let v = value(rest[k + 1]) { dc = v }
                }
                if let first = rest.first, let v = value(first) { dc = v }
                if letter == "i" {
                    parts.append(NetlistPart(kind: .currentSource, name: name, params: ["current": dc], connections: ["a": plus, "b": minus]))
                } else if let function, function.lowercased().hasPrefix("sin") {
                    let a = arguments(function)
                    var params = ["offset": a.count > 0 ? a[0] : 0, "amplitude": a.count > 1 ? a[1] : 0, "frequency": a.count > 2 ? a[2] : 1000]
                    if a.count > 5 { params["phase"] = a[5] }
                    parts.append(NetlistPart(kind: .acVoltage, name: name, params: params, connections: ["plus": plus, "minus": minus]))
                } else if let function, function.lowercased().hasPrefix("pulse") {
                    let a = arguments(function)
                    let period = a.count > 6 && a[6] > 0 ? a[6] : 1e-3
                    let width = a.count > 5 ? a[5] : period / 2
                    parts.append(NetlistPart(kind: .squareVoltage, name: name, params: [
                        "low": a.count > 0 ? a[0] : 0, "high": a.count > 1 ? a[1] : 1, "frequency": 1 / period,
                        "duty": min(max(width / period, 0.01), 0.99),
                    ], connections: ["plus": plus, "minus": minus]))
                } else {
                    if let function { warnings.append("\(name): \(function.prefix(while: { $0 != "(" })) is read as its DC value, \(dc) V") }
                    if dc == 0 && function == nil && !sensed.contains(name.lowercased()) {
                        // a 0 V source is SPICE's ammeter
                        parts.append(NetlistPart(kind: .ammeter, name: name, connections: ["in": plus, "out": minus]))
                    } else {
                        parts.append(NetlistPart(kind: .dcVoltage, name: name, params: ["voltage": dc], connections: ["plus": plus, "minus": minus]))
                    }
                }
            case "d":
                guard let anode = node(1), let cathode = node(2) else { continue }
                let model = words.count > 3 ? models[words[3].lowercased()] : nil
                let card = model?.params ?? [:]
                // the whole card; drawn as a Zener when it breaks down below 40 V (a rectifier's BV is its rating)
                let kind: ElementKind = (card["BV"].map { abs($0) < 40 } ?? false) ? .zener : .diode
                let (params, ignored) = SpiceDiode.parameters(fromCard: card, kind: kind)
                if !ignored.isEmpty { warnings.append("\(name): \(ignored.joined(separator: ", ")) of its model left out") }
                parts.append(NetlistPart(kind: kind, name: name, params: params, connections: ["anode": anode, "cathode": cathode]))
            case "q":
                guard let c = node(1), let b = node(2), let e = node(3), words.count > 4 else { continue }
                // a fourth node (the substrate) may come before the model
                let modelName = words.count > 5 && models[words[5].lowercased()] != nil ? words[5] : words[4]
                guard let model = models[modelName.lowercased()] else {
                    warnings.append("\(name): no model \(modelName)")
                    continue
                }
                // the whole Gummel-Poon card
                let (params, ignored) = GummelPoon.parameters(fromCard: model.params)
                if !ignored.isEmpty { warnings.append("\(name): \(ignored.joined(separator: ", ")) of model \(modelName) left out") }
                parts.append(NetlistPart(kind: model.type == "pnp" ? .pnp : .npn, name: name, params: params,
                                         connections: ["collector": c, "base": b, "emitter": e]))
            case "m":
                guard let d = node(1), let g = node(2), let s = node(3), words.count > 5, let model = models[words[5].lowercased()] else {
                    warnings.append("Can't read \(line)")
                    continue
                }
                // the whole level-1 card, its process parameters worked out for this transistor's size (ngspice's default
                // W and L are 100 µm)
                let pmos = model.type == "pmos"
                if let level = model.params["LEVEL"], level != 1 {
                    warnings.append("\(name): model \(words[5]) is level \(Int(level)), read as level 1")
                }
                if let bulk = node(4), bulk != s { warnings.append("\(name): its bulk is tied to its source") }
                if let multiplier = keyword("m"), multiplier != 1 { warnings.append("\(name): M=\(multiplier) is left out") }
                let (params, ignored) = SpiceMOSFET.parameters(
                    fromCard: model.params, pmos: pmos, w: keyword("w") ?? 1e-4, l: keyword("l") ?? 1e-4, ad: keyword("ad") ?? 0,
                    as: keyword("as") ?? 0, nrd: keyword("nrd") ?? 1, nrs: keyword("nrs") ?? 1)
                if !ignored.isEmpty { warnings.append("\(name): \(ignored.joined(separator: ", ")) of model \(words[5]) left out") }
                parts.append(NetlistPart(kind: pmos ? .pmos : .nmos, name: name, params: params,
                                         connections: ["drain": d, "gate": g, "source": s]))
            case "j":
                guard let d = node(1), let g = node(2), let s = node(3), words.count > 4, let model = models[words[4].lowercased()] else {
                    warnings.append("Can't read \(line)")
                    continue
                }
                guard model.type == "njf" else {
                    warnings.append("\(name): only N-channel JFETs")
                    continue
                }
                // the whole card
                let (params, ignored) = SpiceJFET.parameters(fromCard: model.params)
                if !ignored.isEmpty { warnings.append("\(name): \(ignored.joined(separator: ", ")) of model \(words[4]) left out") }
                parts.append(NetlistPart(kind: .njfet, name: name, params: params, connections: ["drain": d, "gate": g, "source": s]))
            case "k":
                guard words.count >= 4, let k = number(3) else { continue }
                couplings.append((words[1].lowercased(), words[2].lowercased(), k))
            case "e", "f", "g", "h", "b":
                guard let plus = node(1), let minus = node(2) else {
                    warnings.append("Can't read \(line)")
                    continue
                }
                do {
                    let (expression, voltage) = try Self.controlledSource(letter, words, line, parameters)
                    // each net the expression reads on a sense pin of its own
                    var pins: [String: String] = [:]
                    var connections = ["plus": plus, "minus": minus]
                    func pin(_ spiceNet: String) throws -> String {
                        if Topology.isGroundName(spiceNet) { return "0" }
                        let lower = spiceNet.lowercased()
                        if let known = pins[lower] { return known }
                        guard pins.count < 8 else { throw SpiceExpression.ParseError.unexpected("more than eight nets", at: line) }
                        let made = "in\(pins.count + 1)"
                        pins[lower] = made
                        connections[made] = net(spiceNet, prefix, spellings)
                        return made
                    }
                    var names: [SpiceExpression.Input: String] = [:]
                    for input in expression.inputs {
                        switch input {
                        case let .voltage(a, b): names[input] = "V(" + (try pin(a)) + (try b.map { "," + (try pin($0)) } ?? "") + ")"
                        case let .current(source): names[input] = "I(\(source))"
                        }
                    }
                    var part = NetlistPart(kind: .behavioralSource, name: name, params: ["mode": voltage ? 1 : 0], connections: connections)
                    part.code = expression.text { names[$0] ?? "0" }
                    parts.append(part)
                } catch {
                    warnings.append("\(name): \(error), left out")
                }
            case "x":
                guard words.count >= 2 else { continue }
                let subName = words[words.count - 1].lowercased()
                guard let sub = subcircuits[subName] else {
                    warnings.append("\(name): no subcircuit \(words[words.count - 1])")
                    continue
                }
                guard depth < 8 else { continue }
                let block: BlockDefinition
                if let made = cache[subName] {
                    block = made
                } else {
                    // a subcircuit's nodes are its own: spelled as it spells them
                    let inside = Spellings()
                    var inner = elements(sub.lines, models: models, subcircuits: subcircuits, cache: &cache, warnings: &warnings,
                                         depth: depth + 1, spellings: inside, parameters: parameters)
                    for pin in sub.pins {
                        inner.append(NetlistPart(kind: .port, name: pin, connections: ["net": net(pin, "", inside)]))
                    }
                    guard let drawn = try? SchematicLayout.layout(inner) else {
                        warnings.append("\(name): subcircuit \(subName) can't be drawn")
                        continue
                    }
                    block = drawn.asBlock(named: words[words.count - 1])
                    cache[subName] = block
                }
                let nodes = words.dropFirst().dropLast()
                var part = NetlistPart(kind: .block, name: name)
                part.block = block
                // pins by name: the block's ports are named after the subcircuit's pins
                for (pin, n) in zip(sub.pins, nodes) { part.connections[pin] = net(n, prefix, spellings) }
                parts.append(part)
            default:
                warnings.append("\(name): \(letter.uppercased()) elements are not supported, left out")
            }
        }
        // coupled inductors become a transformer: the first the primary, the second the secondary
        var removed = Set<Int>()
        for (first, second, k) in couplings {
            guard let a = inductors[first], let b = inductors[second], !removed.contains(a), !removed.contains(b) else {
                warnings.append("Coupling \(first) and \(second): both must be inductors")
                continue
            }
            let lp = parts[a].params["inductance"] ?? 1, ls = parts[b].params["inductance"] ?? 1
            parts.append(NetlistPart(kind: .transformer, name: "T_" + parts[a].name, params: [
                "inductance": lp, "ratio": (ls / lp).squareRoot(), "coupling": min(max(abs(k), 0.5), 1), "rp": 0, "rs": 0,
            ], connections: ["p1": parts[a].connections["a"] ?? "", "p2": parts[a].connections["b"] ?? "",
                             "s1": parts[b].connections["a"] ?? "", "s2": parts[b].connections["b"] ?? ""]))
            removed.formUnion([a, b])
        }
        return parts.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
    }

    // MARK: - Export

    /// The circuit as a SPICE deck: its parts by net, the models they use, and a transient analysis
    public static func export(_ circuit: Circuit, title: String = "JSpice circuit") -> String {
        var deck = Deck()
        deck.lines.append("* " + title)
        deck.lines.append("* written by JSpice: device equations as JSpice's (ngspice or LTspice)")
        let temperature = circuit.settings.temperature
        if temperature != 27 { deck.lines.append(".options temp=\(format(temperature)) tnom=27") }
        deck.add(NetlistExtractor.netlist(from: circuit))
        if !deck.subcircuits.isEmpty { deck.lines.insert(contentsOf: deck.subcircuits, at: 2) }
        deck.lines += deck.models
        let pacing = Pacing.suggest(for: circuit)
        let duration = max(Pacing.slowestTimeScale(of: circuit) ?? 0.01, 1e-6) * 5
        deck.lines.append(".tran \(format(pacing.timeStep)) \(format(duration))")
        deck.lines.append(".end")
        return deck.lines.joined(separator: "\n") + "\n"
    }

    static func format(_ v: Double) -> String { String(format: "%.6g", v) }

    private struct Deck {
        var lines: [String] = []
        var models: [String] = []
        var subcircuits: [String] = []
        var written: [String: String] = [:]

        /// A SPICE name for a part: its own when it starts with the element's letter, else the letter and its own
        func device(_ letter: String, _ name: String) -> String {
            let clean = name.replacingOccurrences(of: #"[^A-Za-z0-9_]"#, with: "_", options: .regularExpression)
            return clean.uppercased().hasPrefix(letter) ? clean : letter + "_" + clean
        }

        func node(_ name: String?) -> String {
            guard let name, !Topology.isGroundName(name) else { return "0" }
            return name.replacingOccurrences(of: #"[^A-Za-z0-9_+\-]"#, with: "_", options: .regularExpression)
        }

        mutating func add(_ parts: [NetlistPart]) {
            for part in parts { add(part) }
        }

        mutating func add(_ part: NetlistPart) {
            let c = part.connections
            func n(_ terminal: String) -> String { node(c[terminal]) }
            func p(_ key: String) -> Double {
                part.params[key] ?? part.kind.params.first { $0.key == key }?.defaultValue ?? 0
            }
            let f = SpiceNetlist.format
            let name = part.name
            switch part.kind {
            case .resistor, .lamp:
                lines.append("\(device("R", name)) \(n("a")) \(n("b")) \(f(max(p("resistance"), 1e-9)))")
            case .potentiometer:
                let total = max(p("resistance"), 1e-3)
                var position = min(1, max(0, p("position")))
                if p("taper") >= 0.5 { position = (pow(10, 2 * position) - 1) / 99 }
                let floor = total * 1e-4 + 1e-3
                lines.append("\(device("R", name))_a \(n("a")) \(n("wiper")) \(f(max(total * position, floor)))")
                lines.append("\(device("R", name))_b \(n("wiper")) \(n("b")) \(f(max(total * (1 - position), floor)))")
            case .capacitor:
                lines.append("\(device("C", name)) \(n("a")) \(n("b")) \(f(p("capacitance"))) IC=\(f(p("initialVoltage")))")
            case .inductor:
                lines.append("\(device("L", name)) \(n("a")) \(n("b")) \(f(max(p("inductance"), 1e-15)))")
            case .dcVoltage:
                lines.append("\(device("V", name)) \(n("plus")) \(n("minus")) DC \(f(p("voltage")))")
            case .acVoltage:
                lines.append("\(device("V", name)) \(n("plus")) \(n("minus")) SIN(\(f(p("offset"))) \(f(p("amplitude"))) \(f(p("frequency"))) 0 0 \(f(p("phase")))) AC 1")
            case .squareVoltage:
                let period = 1 / max(p("frequency"), 1e-9)
                let edge = period * 1e-6
                lines.append("\(device("V", name)) \(n("plus")) \(n("minus")) PULSE(\(f(p("low"))) \(f(p("high"))) 0 \(f(edge)) \(f(edge)) \(f(p("duty") * period - edge)) \(f(period)))")
            case .noiseVoltage:
                lines.append("\(device("V", name)) \(n("plus")) \(n("minus")) TRNOISE(\(f(p("amplitude"))) 20u 0 0)  ; ngspice's noise source")
            case .audioInput, .keyboardPitch, .keyboardGate:
                lines.append("\(device("V", name)) \(n("plus")) \(n("minus")) DC 0  ; \(part.kind.displayName): no SPICE equivalent, 0 V")
            case .currentSource:
                lines.append("\(device("I", name)) \(n("a")) \(n("b")) DC \(f(p("current")))")
            case .toggleSwitch, .pushButton:
                lines.append("\(device("R", name)) \(n("a")) \(n("b")) \(part.closed ? "1m" : "1e12")  ; \(part.closed ? "closed" : "open") switch")
            case .ammeter:
                lines.append("\(device("V", name)) \(n("in")) \(n("out")) DC 0  ; ammeter")
            case .diode, .led, .zener:
                let model = "D_" + device("D", name)
                models.append(".model \(model) D(\(SpiceDiode.cardText(p, kind: part.kind)))")
                lines.append("\(device("D", name)) \(n("anode")) \(n("cathode")) \(model)")
            case .npn, .pnp:
                let model = "Q_" + device("Q", name)
                models.append(".model \(model) \(part.kind == .npn ? "NPN" : "PNP")(\(GummelPoon.cardText(p, kind: part.kind)))")
                lines.append("\(device("Q", name)) \(n("collector")) \(n("base")) \(n("emitter")) \(model)")
            case .nmos, .pmos:
                let model = "M_" + device("M", name)
                models.append(".model \(model) \(part.kind == .nmos ? "NMOS" : "PMOS")(\(SpiceMOSFET.cardText(p, kind: part.kind)))")
                lines.append("\(device("M", name)) \(n("drain")) \(n("gate")) \(n("source")) \(n("source")) \(model) L=1 W=1")
            case .njfet:
                let model = "J_" + device("J", name)
                models.append(".model \(model) NJF(\(SpiceJFET.cardText(p, kind: part.kind)))")
                lines.append("\(device("J", name)) \(n("drain")) \(n("gate")) \(n("source")) \(model)")
            case .behavioralSource:
                // the expression with its pins' nets, and the sources it reads by their names in the deck
                guard let text = part.code, let expression = try? SpiceExpression(parsing: text) else {
                    lines.append("* \(name): a behavioural source without an expression, left out")
                    break
                }
                func net(_ pin: String) -> String { Topology.isGroundName(pin) ? "0" : n(pin) }
                let body = expression.text { input in
                    switch input {
                    case let .voltage(a, b): return "V(" + net(a) + (b.map { "," + net($0) } ?? "") + ")"
                    case let .current(source): return "I(" + device("V", source) + ")"
                    }
                }
                lines.append("\(device("B", name)) \(n("plus")) \(n("minus")) \(p("mode") >= 0.5 ? "V" : "I")={\(body)}")
            case .opAmp:
                // JSpice's op-amp: an integrator with a pole at the gain-bandwidth, slew limited, ahead of a smooth limit
                let gain = max(p("gain"), 1), limit = max(p("limit"), 0.01), gbw = p("gbw"), slew = p("slewRate") * 1e6
                let b = device("B", name)
                let vd = "(V(\(n("plus")))-V(\(n("minus")))+\(f(p("offset"))))"
                // a single-supply op-amp swings about its midpoint
                let mid = p("midpoint")
                if gbw <= 0 {
                    lines.append(mid == 0 ? "\(b) \(n("out")) 0 V=\(f(limit))*tanh(\(f(gain))*\(vd)/\(f(limit)))"
                                          : "\(b) \(n("out")) 0 V=\(f(mid))+\(f(limit))*tanh((\(f(gain))*\(vd)-\(f(mid)))/\(f(limit)))")
                } else {
                    let w = 2 * Double.pi * gbw
                    let stage = "\(b)_stage"
                    let drive = slew > 0 ? "\(f(slew))*tanh(\(vd)*\(f(w))/\(f(slew)))" : "\(f(w))*\(vd)"
                    lines.append("\(b)_drive 0 \(stage) I=\(drive)")
                    lines.append("C_\(stage) \(stage) 0 1 IC=0")
                    lines.append("R_\(stage) \(stage) 0 \(f(gain / w))")
                    lines.append(mid == 0 ? "\(b) \(n("out")) 0 V=\(f(limit))*tanh(V(\(stage))/\(f(limit)))"
                                          : "\(b) \(n("out")) 0 V=\(f(mid))+\(f(limit))*tanh((V(\(stage))-\(f(mid)))/\(f(limit)))")
                }
            case .triode, .pentode:
                let b = device("B", name)
                let g = n("grid"), pl = n("plate"), ca = n("cathode")
                let vg = "V(\(g),\(ca))", vp = "V(\(pl),\(ca))"
                let (mu, ex, kg1, kp, kvb, rgi) = (p("mu"), p("ex"), p("kg1"), p("kp"), p("kvb"), p("rgi"))
                if part.kind == .triode {
                    let e1 = "\(vp)/\(f(kp))*ln(1+exp(\(f(kp))*(1/\(f(mu))+\(vg)/sqrt(\(f(kvb))+\(vp)*\(vp)))))"
                    lines.append("\(b)_p \(pl) \(ca) I=2*pwr(max(\(e1),0),\(f(ex)))/\(f(kg1))")
                } else {
                    let sc = n("screen")
                    let vs = "max(V(\(sc),\(ca)),1e-3)"
                    let e1 = "\(vs)/\(f(kp))*ln(1+exp(\(f(kp))*(1/\(f(mu))+\(vg)/\(vs))))"
                    lines.append("\(b)_p \(pl) \(ca) I=2*pwr(max(\(e1),0),\(f(ex)))/\(f(kg1))*atan(max(\(vp),0)/\(f(kvb)))")
                    lines.append("\(b)_s \(sc) \(ca) I=pwr(max(\(vg)+V(\(sc),\(ca))/\(f(mu)),0),\(f(ex)))/\(f(p("kg2")))")
                }
                lines.append("\(b)_g \(g) \(ca) I=pwr(max(\(vg),0),1.5)/\(f(rgi))")
                for (key, x, y) in [("cgk", g, ca), ("cgp", g, pl), ("cpk", pl, ca)] where p(key) > 0 {
                    lines.append("C_\(device("V", name))_\(key) \(x) \(y) \(f(p(key)))")
                }
            case .transformer:
                let t = device("L", name)
                let lp = max(p("inductance"), 1e-12), ratio = p("ratio"), k = min(max(p("coupling"), 0.01), 1)
                lines.append("R_\(t)_p \(n("p1")) \(t)_px \(f(max(p("rp"), 1e-6)))")
                lines.append("\(t)_p \(t)_px \(n("p2")) \(f(lp))")
                lines.append("R_\(t)_s \(t)_sx \(n("s1")) \(f(max(p("rs"), 1e-6)))")
                lines.append("\(t)_s \(t)_sx \(n("s2")) \(f(lp * ratio * ratio))")
                lines.append("K_\(t) \(t)_p \(t)_s \(f(k))")
            case .block:
                guard let block = part.block else { return }
                let sub = subcircuit(block)
                let pins = block.terminalNames.map { n($0) }.joined(separator: " ")
                lines.append("X_\(device("X", name)) \(pins) \(sub)")
            case _ where part.kind.isExpandedPart:
                // the small circuit the part is simulated as, as a subcircuit
                guard let block = PartExpansion.block(for: part) else { return }
                let sub = subcircuit(block)
                let pins = block.terminalNames.map { n($0) }.joined(separator: " ")
                lines.append("X_\(device("X", name)) \(pins) \(sub)")
            case .wire, .ground, .netLabel, .port, .probe, .speaker, .vuMeter:
                break
            default:
                lines.append("* \(name): a \(part.kind.displayName) has no SPICE equivalent here, left out")
            }
        }

        /// A subcircuit for a block, written once for each different block
        mutating func subcircuit(_ block: BlockDefinition) -> String {
            let key = (try? String(data: JSONEncoder().encode(block), encoding: .utf8)) ?? block.name
            if let made = written[key] { return made }
            var name = block.name.replacingOccurrences(of: #"[^A-Za-z0-9_]"#, with: "_", options: .regularExpression)
            if name.isEmpty { name = "block" }
            var unique = name
            var k = 2
            while written.values.contains(unique) {
                unique = "\(name)_\(k)"
                k += 1
            }
            written[key] = unique
            var inner = Deck()
            inner.written = written
            inner.add(NetlistExtractor.netlist(from: block.circuit).filter { $0.kind != .port })
            written = inner.written
            subcircuits += inner.subcircuits
            let pins = block.ports.map { port -> String in
                let element = block.circuit.elements[port.index]
                // the port's net, by the part on it
                return node(NetlistExtractor.netlist(from: block.circuit).first { $0.id == element.id }?.connections["net"] ?? port.name)
            }
            subcircuits.append(".subckt \(unique) \(pins.joined(separator: " "))")
            subcircuits += inner.lines + inner.models
            subcircuits.append(".ends \(unique)")
            return unique
        }
    }
}
