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

    /// Reads a file a deck includes: its path as the deck writes it and the name of the file that includes it (nil
    /// for the deck itself), to the file's name (for the files it includes in turn) and text, or nil when it can't
    public typealias Includer = (_ path: String, _ from: String?) -> (name: String, text: String)?

    /// An includer for a deck saved at `deck`: paths relative to the including file's folder, read as UTF-8, UTF-16 or
    /// Windows-1252 (as LTspice and vendors write them)
    public static func fileIncluder(deck: URL) -> Includer {
        { path, from in
            let base = from.map { URL(fileURLWithPath: $0).deletingLastPathComponent() } ?? deck.deletingLastPathComponent()
            let expanded = (path as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded)
            guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
            guard let text = [String.Encoding.utf8, .utf16, .windowsCP1252].lazy.compactMap({ String(data: data, encoding: $0) }).first
            else { return nil }
            return (url.path, text)
        }
    }

    /// A deck's lines without comments, each continuation joined to the line it continues (past comments and blank
    /// lines; not to a deck's title)
    static func logicalLines(_ text: String, titled: Bool) -> [String] {
        var lines: [String] = []
        // (DOS's end-of-file mark, which old model files end with, is not text)
        for raw in text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\u{1A}", with: "").components(separatedBy: "\n") {
            // inline comments
            var line = raw
            for marker in [";", "$ "] {
                if let range = line.range(of: marker) { line = String(line[..<range.lowerBound]) }
            }
            line = line.trimmingCharacters(in: .whitespaces)
            let first = titled ? 1 : 0
            if line.hasPrefix("+"), let k = lines.indices.last(where: { $0 >= first && !lines[$0].isEmpty && !lines[$0].hasPrefix("*") }) {
                lines[k] += " " + line.dropFirst()
            } else {
                lines.append(line)
            }
        }
        return lines
    }

    /// The path a .include or .lib line names (in quotes or not) and the words after it
    static func includePath(_ line: String) -> (path: String, rest: [String])? {
        guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
        let after = line[space...].trimmingCharacters(in: .whitespaces)
        guard let quote = after.first else { return nil }
        if quote == "\"" || quote == "'", let close = after.dropFirst().firstIndex(of: quote) {
            let path = String(after[after.index(after: after.startIndex)..<close])
            return (path, tokens(String(after[after.index(after: close)...])))
        }
        let words = tokens(after)
        return words.first.map { ($0, Array(words.dropFirst())) }
    }

    /// `lines` with each .include (and .lib of a file) replaced by the file's lines: the whole file, or for
    /// `.lib file section` its lines from `.lib section` to `.endl`
    static func expandIncludes(_ lines: [String], from: String?, include: Includer?, depth: Int,
                               warnings: inout [String]) -> [String] {
        var result: [String] = []
        for line in lines {
            let first = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first?.lowercased() ?? ""
            guard [".include", ".inc", ".lib"].contains(first), let named = includePath(line) else {
                if first != ".endl" { result.append(line) }
                continue
            }
            let (path, rest) = (named.path, named.rest)
            guard let include else {
                warnings.append("\(path): the files a deck includes are read only from a file, left out")
                continue
            }
            guard depth < 10, let file = include(path, from) else {
                // a library's own section heading (`.lib name`) is not a file
                if !(first == ".lib" && rest.isEmpty) || depth == 0 { warnings.append("\(path): can't read it, left out") }
                continue
            }
            var included = logicalLines(file.text, titled: false)
            if first == ".lib", let section = rest.first?.lowercased() {
                // the section's lines
                var inside = false
                included = included.filter { line in
                    let words = tokens(line).map { $0.lowercased() }
                    if words.first == ".lib", words.count == 2, !inside, words[1] == section {
                        inside = true
                        return false
                    }
                    if words.first == ".endl", inside {
                        inside = false
                        return false
                    }
                    return inside
                }
                if included.isEmpty { warnings.append("\(path): no section \(rest[0])") }
            }
            result += expandIncludes(included, from: file.name, include: include, depth: depth + 1, warnings: &warnings)
        }
        return result
    }

    /// A subcircuit: its pins, its lines, its parameters' defaults, and the .model lines inside it (as written)
    struct Subcircuit {
        var pins: [String]
        var lines: [String]
        var defaults: [(name: String, value: String)]
        var models: [String]
    }

    /// A .model line's name (lower case), type and parameters: "NPN(IS=1e-14 BF=100)" or "NPN IS=1e-14 BF=100"
    static func model(_ line: String, _ parameters: [String: Double],
                      _ functions: [String: SpiceExpression.UserFunction]) -> (name: String, type: String, params: [String: Double])? {
        let words = tokens(line)
        guard words.count >= 3 else { return nil }
        var type = words[2].lowercased()
        if let paren = type.firstIndex(of: "(") { type = String(type[..<paren]) }
        var params: [String: Double] = [:]
        for word in words.dropFirst(3) where word.contains("=") {
            let pair = word.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2, let v = evaluate(pair[1], parameters, functions) { params[pair[0].uppercased()] = v }
        }
        return (words[1].lowercased(), type, params)
    }

    /// The words of a subcircuit's heading or instance before its parameters, and its parameters (after PARAMS: or
    /// as the first name=value)
    static func splitParameters(_ line: String) -> (words: [String], assignments: [(name: String, value: String)]) {
        let cleaned = line.replacingOccurrences(of: #"(?i)(^|\s)params:"#, with: " ", options: .regularExpression)
        guard let start = cleaned.range(of: #"[^\s=]+\s*="#, options: .regularExpression) else { return (tokens(cleaned), []) }
        return (tokens(String(cleaned[..<start.lowerBound])), assignments(String(cleaned[start.lowerBound...])))
    }

    /// The parts of a netlist (the first line is its title, as in SPICE). Nodes keep their names; 0 and GND are ground.
    /// The files it includes (.include, .lib) are read with `include`.
    public static func parse(_ text: String, include: Includer? = nil) -> Import {
        var lines = logicalLines(text, titled: true)
        let title = lines.first.map { $0.hasPrefix("*") ? String($0.dropFirst()).trimmingCharacters(in: .whitespaces) : $0 } ?? ""
        var warnings: [String] = []
        lines = [title] + expandIncludes(Array(lines.dropFirst()), from: nil, include: include, depth: 0, warnings: &warnings)
        var models: [String: (type: String, params: [String: Double])] = [:]
        // subcircuits: their pins, lines and parameters
        var subcircuits: [String: Subcircuit] = [:]
        var top: [String] = []
        var open: (name: String, sub: Subcircuit)?
        // ngspice's interactive commands, between .control and .endc, are not part of the circuit
        var control = false
        // .param's constants, each worked out from those before it, and .func's functions
        var parameters: [String: Double] = [:]
        var functions: [String: SpiceExpression.UserFunction] = [:]
        for line in lines.dropFirst() where !line.isEmpty && !line.hasPrefix("*") {
            let words = tokens(line)
            guard let first = words.first?.lowercased() else { continue }
            if control {
                if first == ".endc" { control = false }
                continue
            }
            if first == ".control" {
                control = true
            } else if first == ".model" && open != nil {
                // a subcircuit's own model, worked out for each instance (with its parameters), as PSpice scopes it
                open?.sub.models.append(line)
            } else if first == ".model", let card = Self.model(line, parameters, functions) {
                models[card.name] = (card.type, card.params)
            } else if first == ".subckt", words.count >= 2 {
                let (heading, defaults) = splitParameters(line)
                open = (words[1].lowercased(), Subcircuit(pins: Array(heading.dropFirst(2)), lines: [], defaults: defaults, models: []))
            } else if first == ".ends" {
                if let sub = open { subcircuits[sub.name] = sub.sub }
                open = nil
            } else if first == ".end" {
                break
            } else if first == ".func" {
                // .func name(a, b) {body}, or = body
                let pattern = #"^\.func\s+(\w+)\s*\(([^)]*)\)\s*=?\s*(.+)$"#
                guard let match = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                    .firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let name = Range(match.range(at: 1), in: line), let arguments = Range(match.range(at: 2), in: line),
                      let body = Range(match.range(at: 3), in: line) else {
                    warnings.append("Can't read \(line)")
                    continue
                }
                let names = line[arguments].split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
                functions[line[name].lowercased()] = SpiceExpression.UserFunction(arguments: names, body: String(line[body]))
            } else if first == ".param" && open != nil {
                // a subcircuit's own constants, worked out for each instance
                open?.sub.lines.append(line)
            } else if first == ".param" {
                for assignment in Self.assignments(String(line.dropFirst(6))) {
                    if let v = Self.evaluate(assignment.value, parameters, functions) {
                        parameters[assignment.name.lowercased()] = v
                    } else {
                        warnings.append(".param \(assignment.name): can't work out \(assignment.value)")
                    }
                }
            } else if first.hasPrefix(".") {
                if first == ".global" { warnings.append("\(words[0]) is not followed: \(line)") }
            } else if open != nil {
                open?.sub.lines.append(line)
            } else {
                top.append(line)
            }
        }
        var cache: [String: BlockDefinition] = [:]
        let parts = elements(top, models: models, globalModels: models, subcircuits: subcircuits, cache: &cache, warnings: &warnings, depth: 0,
                             spellings: Spellings(), parameters: parameters, functions: functions)
        return Import(title: title, parts: parts, warnings: warnings)
    }

    /// The parsed netlist drawn as a circuit
    public static func circuit(from text: String, include: Includer? = nil) throws -> (circuit: Circuit, warnings: [String]) {
        let imported = parse(text, include: include)
        guard !imported.parts.isEmpty else { throw NetlistError.empty }
        return (try SchematicLayout.layout(imported.parts), imported.warnings)
    }

    /// Words of a line, with "(", ")" and "," as spaces except inside a source's function (kept as one word)
    static func tokens(_ line: String) -> [String] {
        // commas separate as spaces do, except inside a {expression} (a function's arguments)
        var braces = 0
        var cleaned = String(line.map { ch -> Character in
            if ch == "{" { braces += 1 }
            if ch == "}" { braces = max(0, braces - 1) }
            return ch == "," && braces == 0 ? " " : ch
        })
        // "SIN (0 1 1k)" → "SIN(0 1 1k)", "IS = 1e-14" → "IS=1e-14"
        cleaned = cleaned.replacingOccurrences(of: #"\s*=\s*"#, with: "=", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(\w)\s+\("#, with: "$1(", options: .regularExpression)
        var words: [String] = []
        var current = ""
        var depth = 0
        for ch in cleaned {
            // a {expression} is one word, spaces and all
            if ch == "(" || ch == "{" { depth += 1 }
            if ch == ")" || ch == "}" { depth = max(0, depth - 1) }
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
    static func evaluate(_ text: String, _ parameters: [String: Double], _ functions: [String: SpiceExpression.UserFunction] = [:]) -> Double? {
        if let v = value(text) { return v }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("(") || parameters[trimmed.lowercased()] != nil else { return nil }
        return (try? SpiceExpression(parsing: trimmed, parameters: parameters, functions: functions))?.constantValue
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

    /// The voltage sources a deck's controlled sources read the current of: F and H sources' and W switches' controls and
    /// the I( ) of expressions
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
            // F and H read a source's current, and so does a W switch
            guard letter == "f" || letter == "h" || letter == "w" else { continue }
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
                                 _ parameters: [String: Double],
                                 _ functions: [String: SpiceExpression.UserFunction] = [:]) throws -> (SpiceExpression, Bool) {
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
            return (try SpiceExpression(parsing: text, parameters: parameters, functions: functions), kind == "V" || kind == "v")
        }
        // (a pair of nets in parentheses leaves an empty word before it)
        let rest = words.dropFirst(3).filter { !$0.isEmpty }
        guard let first = rest.first else { throw SpiceExpression.ParseError.unexpected("end", at: line) }
        let head = first.lowercased()
        if let range = line.range(of: #"\bVALUE\s*=\s*"#, options: [.regularExpression, .caseInsensitive]) {
            return (try SpiceExpression(parsing: String(line[range.upperBound...]), parameters: parameters, functions: functions), voltage)
        }
        if head == "table" || head.hasPrefix("table{") {
            // TABLE {expression} = (x, y) (x, y) …
            guard let open = line.firstIndex(of: "{"), let close = line[open...].firstIndex(of: "}") else {
                throw SpiceExpression.ParseError.unexpected("TABLE without {expression}", at: line)
            }
            let argument = try SpiceExpression(parsing: String(line[open...close]), parameters: parameters, functions: functions)
            let numbers = line[line.index(after: close)...].split(whereSeparator: { " ,()=\t".contains($0) })
                .compactMap { evaluate(String($0), parameters, functions) }
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
            let coefficients = rest[(2 + controls)...].compactMap { evaluate($0, parameters, functions) }
            return (SpiceExpression.polynomial(dimensions: n, coefficients: coefficients, inputs: inputs), voltage)
        }
        // linear: E/G n+ n- nc+ nc- gain; F/H n+ n- vname gain
        if controlledByVoltage {
            guard rest.count >= 3, let gain = evaluate(rest[2], parameters, functions) else {
                throw SpiceExpression.ParseError.unexpected("gain", at: line)
            }
            return (SpiceExpression.polynomial(dimensions: 1, coefficients: [0, gain], inputs: [.voltage(rest[0], rest[1])]), voltage)
        }
        guard rest.count >= 2, let gain = evaluate(rest[1], parameters, functions) else {
            throw SpiceExpression.ParseError.unexpected("gain", at: line)
        }
        return (SpiceExpression.polynomial(dimensions: 1, coefficients: [0, gain], inputs: [.current(rest[0])]), voltage)
    }

    /// A card for `area` parallel devices, as ngspice scales one by an instance's area (and its M): the currents and
    /// capacitances in `times` grow with it and the resistances in `over` shrink, after the card's aliases are read
    static func scaled(_ card: [String: Double], area: Double, times: Set<String>, over: Set<String>,
                       aliases: [String: String]) -> [String: Double] {
        guard area != 1, area > 0 else { return card }
        var result: [String: Double] = [:]
        for (name, value) in card {
            let key = aliases[name] ?? name
            result[key] = times.contains(key) ? value * area : over.contains(key) ? value / area : value
        }
        return result
    }

    /// A switch model's resistance as an expression of its control (`V(nc+,nc-)` or `I(vname)`): PSpice's VSWITCH and
    /// ISWITCH (the resistance's logarithm a cubic between the off and on controls, as PSpice's reference gives it), and
    /// ngspice's SW and CSW read the same way between VT-VH and VT+VH, without their hysteresis (with a warning)
    static func switchResistance(model: (type: String, params: [String: Double]), control: String, name: String,
                                 warnings: inout [String]) -> String? {
        let p = model.params
        var (on, off, ron, roff) = (1.0, 0.0, 1.0, 1e6)
        switch model.type {
        case "vswitch":
            (on, off, ron, roff) = (p["VON"] ?? 1, p["VOFF"] ?? 0, p["RON"] ?? 1, p["ROFF"] ?? 1e6)
        case "iswitch":
            (on, off, ron, roff) = (p["ION"] ?? 1e-3, p["IOFF"] ?? 0, p["RON"] ?? 1, p["ROFF"] ?? 1e6)
        case "sw", "csw":
            let threshold = p[model.type == "sw" ? "VT" : "IT"] ?? 0
            let hysteresis = abs(p[model.type == "sw" ? "VH" : "IH"] ?? 0)
            // an abrupt switch (no hysteresis) changes over a millivolt (a microampere)
            let half = hysteresis > 0 ? hysteresis : (model.type == "sw" ? 1e-3 : 1e-6)
            (on, off, ron, roff) = (threshold + half, threshold - half, p["RON"] ?? 1, p["ROFF"] ?? 1e12)
            warnings.append("\(name): \(model.type.uppercased()) switch read without hysteresis, changing over smoothly between \(off) and \(on)")
        default:
            warnings.append("\(name): model of type \(model.type) is not a switch's, left out")
            return nil
        }
        guard on != off, ron > 0, roff > 0 else {
            warnings.append("\(name): its switch model's on and off are the same, left out")
            return nil
        }
        let lm = log((ron * roff).squareRoot()), lr = log(ron / roff)
        let middle = (on + off) / 2, span = on - off
        let f = format17
        // x from -1/2 (off) to 1/2 (on); R = exp(Lm + Lr (3x/2 - 2x³))
        let x = "((max(min(\(control),\(f(max(on, off)))),\(f(min(on, off))))-(\(f(middle))))/(\(f(span))))"
        return "exp(\(f(lm))+(\(f(lr)))*(1.5*\(x)-2*\(x)*\(x)*\(x)))"
    }

    /// A number written to be read back exactly
    static func format17(_ v: Double) -> String { String(format: "%.17g", v) }

    static let diodeArea: (times: Set<String>, over: Set<String>) = (["IS", "ISR", "IKF", "IKR", "CJO"], ["RS"])
    static let bipolarArea: (times: Set<String>, over: Set<String>) = (
        ["IS", "ISE", "ISC", "ISS", "IKF", "IKR", "IRB", "ITF", "CJE", "CJC", "CJS"], ["RB", "RBM", "RC", "RE"])
    static let jfetArea: (times: Set<String>, over: Set<String>) = (["BETA", "IS", "CGS", "CGD"], ["RD", "RS"])

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
                                 globalModels: [String: (type: String, params: [String: Double])]? = nil,
                                 subcircuits: [String: Subcircuit], cache: inout [String: BlockDefinition],
                                 warnings: inout [String], depth: Int, prefix: String = "", spellings: Spellings,
                                 parameters: [String: Double] = [:], functions: [String: SpiceExpression.UserFunction] = [:]) -> [NetlistPart] {
        var parts: [NetlistPart] = []
        // voltage sources whose current a controlled source reads: kept as sources (a 0 V one is otherwise an ammeter)
        let sensed = Self.sensedSources(lines)
        var inductors: [String: Int] = [:]
        var couplings: [(String, String, Double)] = []
        for line in lines {
            let words = tokens(line)
            guard let name = words.first, let letter = name.lowercased().first else { continue }
            func node(_ k: Int) -> String? { k < words.count ? net(words[k], prefix, spellings) : nil }
            func number(_ k: Int) -> Double? { k < words.count ? Self.evaluate(words[k], parameters, functions) : nil }
            func keyword(_ key: String) -> Double? {
                words.first { $0.lowercased().hasPrefix(key.lowercased() + "=") }
                    .flatMap { Self.evaluate(String($0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[1]), parameters, functions) }
            }
            /// A semiconductor's area: a number after its model's name (word `k`), times AREA= and M=
            func area(after k: Int) -> Double {
                let positional = k < words.count && !words[k].contains("=") ? number(k) : nil
                return (positional ?? keyword("area") ?? 1) * (keyword("m") ?? 1)
            }
            switch letter {
            case "r", "c", "l":
                // R n+ n- value, or PSpice's R n+ n- model value, the model's R (C, L) scaling the value
                let model = words.count > 4 ? models[words[3].lowercased()] : nil
                let card = model.flatMap { ["res", "r", "cap", "c", "ind", "l"].contains($0.type) ? $0.params : nil }
                guard let a = node(1), let b = node(2), let given = number(card == nil ? 3 : 4) else {
                    warnings.append("Can't read \(line)")
                    continue
                }
                let v = given * (card?[String(letter).uppercased()] ?? 1)
                if let card, card.keys.contains(where: { ["TC1", "TC2", "TCE", "VC1", "VC2", "IL1", "IL2"].contains($0) }) {
                    warnings.append("\(name): its model's temperature and voltage coefficients are left out")
                }
                switch letter {
                case "r":
                    var params = ["resistance": v]
                    // no thermal noise: a model at absolute zero (PSpice's R_NOISELESS) or ngspice's noisy=0
                    if (card?["T_ABS"] ?? 0) <= -273 || keyword("noisy") == 0 { params["noiseless"] = 1 }
                    parts.append(NetlistPart(kind: .resistor, name: name, params: params, connections: ["a": a, "b": b]))
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
                    // SPICE's current runs through the source from n+ to n-, out of n- into the circuit: JSpice's runs out of
                    // its plus terminal
                    parts.append(NetlistPart(kind: .currentSource, name: name, params: ["current": dc],
                                             connections: ["minus": plus, "plus": minus]))
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
                let card = Self.scaled(model?.params ?? [:], area: area(after: 4), times: Self.diodeArea.times,
                                       over: Self.diodeArea.over, aliases: SpiceDiode.aliases)
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
                // the whole Gummel-Poon card, for the transistor's area
                let modelIndex = modelName == words[4] ? 4 : 5
                let card = Self.scaled(model.params, area: area(after: modelIndex + 1), times: Self.bipolarArea.times,
                                       over: Self.bipolarArea.over, aliases: GummelPoon.aliases)
                let (params, ignored) = GummelPoon.parameters(fromCard: card)
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
                guard model.type == "njf" || model.type == "pjf" else {
                    warnings.append("\(name): model \(words[4]) is not a JFET's (NJF or PJF)")
                    continue
                }
                // the whole card, for the transistor's area
                let card = Self.scaled(model.params, area: area(after: 5), times: Self.jfetArea.times, over: Self.jfetArea.over,
                                       aliases: SpiceJFET.aliases)
                let (params, ignored) = SpiceJFET.parameters(fromCard: card)
                if !ignored.isEmpty { warnings.append("\(name): \(ignored.joined(separator: ", ")) of model \(words[4]) left out") }
                parts.append(NetlistPart(kind: model.type == "pjf" ? .pjfet : .njfet, name: name, params: params,
                                         connections: ["drain": d, "gate": g, "source": s]))
            case "k":
                guard words.count >= 4, let k = number(3) else { continue }
                couplings.append((words[1].lowercased(), words[2].lowercased(), k))
            case "e", "f", "g", "h", "b":
                guard let plus = node(1), let minus = node(2) else {
                    warnings.append("Can't read \(line)")
                    continue
                }
                do {
                    let (expression, voltage) = try Self.controlledSource(letter, words, line, parameters, functions)
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
            case "s", "w":
                // S n+ n- nc+ nc- model (voltage-controlled), W n+ n- vname model (current-controlled)
                let controlCount = letter == "s" ? 2 : 1
                guard let plus = node(1), let minus = node(2), words.count > 3 + controlCount,
                      let model = models[words[3 + controlCount].lowercased()] else {
                    warnings.append("Can't read \(line)")
                    continue
                }
                let control = letter == "s" ? "V(\(words[3]),\(words[4]))" : "I(\(words[3]))"
                guard let resistance = Self.switchResistance(model: model, control: control, name: name, warnings: &warnings) else {
                    continue
                }
                // a current from n+ to n- through the switch's resistance, as a behavioural source
                let b = "B\(name) \(words[1]) \(words[2]) I={V(\(words[1]),\(words[2]))/(\(resistance))}"
                do {
                    let (expression, _) = try Self.controlledSource("b", tokens(b), b, parameters, functions)
                    var pins: [String: String] = [:]
                    var connections = ["plus": plus, "minus": minus]
                    func pin(_ spiceNet: String) -> String {
                        if Topology.isGroundName(spiceNet) { return "0" }
                        if let known = pins[spiceNet.lowercased()] { return known }
                        let made = "in\(pins.count + 1)"
                        pins[spiceNet.lowercased()] = made
                        connections[made] = net(spiceNet, prefix, spellings)
                        return made
                    }
                    let text = expression.text { input in
                        switch input {
                        case let .voltage(a, b): return "V(" + pin(a) + (b.map { "," + pin($0) } ?? "") + ")"
                        case let .current(source): return "I(\(source))"
                        }
                    }
                    var part = NetlistPart(kind: .behavioralSource, name: name, params: ["mode": 0], connections: connections)
                    part.code = text
                    parts.append(part)
                } catch {
                    warnings.append("\(name): \(error), left out")
                }
            case "x":
                // X name nodes… subcircuit [PARAMS:] name=value…
                let (heading, overrides) = Self.splitParameters(line)
                guard heading.count >= 2 else { continue }
                let subName = heading[heading.count - 1].lowercased()
                guard let sub = subcircuits[subName] else {
                    warnings.append("\(name): no subcircuit \(heading[heading.count - 1])")
                    continue
                }
                guard depth < 8 else { continue }
                // the subcircuit's constants for this instance: what it is given (worked out where it is placed), its
                // defaults for the rest, then its own .param lines
                var inner = parameters
                var own: [String] = []
                for (key, text) in overrides {
                    guard let v = Self.evaluate(text, parameters, functions) else {
                        warnings.append("\(name): can't work out \(key)=\(text)")
                        continue
                    }
                    inner[key.lowercased()] = v
                    own.append(key.lowercased())
                }
                for (key, text) in sub.defaults where !own.contains(key.lowercased()) {
                    guard let v = Self.evaluate(text, inner, functions) else {
                        warnings.append("\(name): can't work out \(key)=\(text) of \(heading[heading.count - 1])")
                        continue
                    }
                    inner[key.lowercased()] = v
                    own.append(key.lowercased())
                }
                for paramLine in sub.lines where paramLine.lowercased().hasPrefix(".param") {
                    for assignment in Self.assignments(String(paramLine.dropFirst(6))) {
                        guard let v = Self.evaluate(assignment.value, inner, functions) else {
                            warnings.append("\(name): can't work out .param \(assignment.name)=\(assignment.value)")
                            continue
                        }
                        inner[assignment.name.lowercased()] = v
                        own.append(assignment.name.lowercased())
                    }
                }
                // the deck's models and the subcircuit's own (which win), its own worked out with its constants
                let globals = globalModels ?? models
                var scope = globals
                for modelLine in sub.models {
                    if let card = Self.model(modelLine, inner, functions) { scope[card.name] = (card.type, card.params) }
                }
                // one block for each different set of its constants
                let key = subName + own.sorted().map { "|\($0)=\(inner[$0] ?? 0)" }.joined()
                let block: BlockDefinition
                if let made = cache[key] {
                    block = made
                } else {
                    // a subcircuit's nodes are its own: spelled as it spells them
                    let inside = Spellings()
                    var drawn = elements(sub.lines.filter { !$0.hasPrefix(".") }, models: scope, globalModels: globals, subcircuits: subcircuits,
                                         cache: &cache, warnings: &warnings, depth: depth + 1, spellings: inside, parameters: inner,
                                         functions: functions)
                    for pin in sub.pins {
                        drawn.append(NetlistPart(kind: .port, name: pin, connections: ["net": net(pin, "", inside)]))
                    }
                    let laid: Circuit
                    do {
                        laid = try SchematicLayout.layout(drawn)
                    } catch {
                        warnings.append("\(name): subcircuit \(subName) can't be drawn: \(error)")
                        continue
                    }
                    block = laid.asBlock(named: heading[heading.count - 1])
                    cache[key] = block
                }
                let nodes = heading.dropFirst().dropLast()
                if nodes.count != sub.pins.count {
                    warnings.append("\(name): \(nodes.count) nodes for the \(sub.pins.count) pins of \(heading[heading.count - 1])")
                }
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
                lines.append("\(device("R", name)) \(n("a")) \(n("b")) \(f(max(p("resistance"), 1e-9)))"
                             + (part.kind == .resistor && p("noiseless") >= 0.5 ? " noisy=0" : ""))
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
                // out of the plus terminal: SPICE's n- (its current runs through the source from n+ to n-)
                lines.append("\(device("I", name)) \(n("minus")) \(n("plus")) DC \(f(p("current")))")
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
            case .njfet, .pjfet:
                let model = "J_" + device("J", name)
                models.append(".model \(model) \(part.kind == .njfet ? "NJF" : "PJF")(\(SpiceJFET.cardText(p, kind: part.kind)))")
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
            if let source = block.source {
                subcircuits.append("* \(block.name): from \(source.file), SHA-256 \(source.sha256)")
            }
            subcircuits.append(".subckt \(unique) \(pins.joined(separator: " "))")
            subcircuits += inner.lines + inner.models
            subcircuits.append(".ends \(unique)")
            return unique
        }
    }
}
