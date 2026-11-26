import Foundation

/// A drawn circuit in words, for VoiceOver and other assistive technology: what each part is called and what its
/// terminals connect to ("between +9V and the base of Q1"), and a one-line summary of the whole schematic.
///
/// Nets are named as `NetlistExtractor` names them (net labels, the names given when the circuit was built from a
/// netlist, supplies such as "+9V", and "GND" for ground). A net with no such name is described by the other parts'
/// terminals on it instead of its made-up number.
public enum CircuitDescription {
    /// Parts that are described on their own: everything except wires and grounds (which are described as the
    /// connections they make). Net labels are included, as they name a connection.
    public static func isDescribed(_ element: Element) -> Bool {
        element.kind != .wire && element.kind != .ground
    }

    /// How many parts the schematic has: everything but wires, grounds and net labels
    public static func partCount(of circuit: Circuit) -> Int {
        circuit.elements.filter { ![.wire, .ground, .netLabel].contains($0.kind) }.count
    }

    /// "Schematic: 21 parts, running"; `state` is left out when nil
    public static func summary(of circuit: Circuit, state: String?) -> String {
        let count = partCount(of: circuit)
        let parts = count == 0 ? "empty" : count == 1 ? "1 part" : "\(count) parts"
        return "Schematic: " + ([parts] + (state.map { [$0] } ?? [])).joined(separator: ", ")
    }

    /// The kind as spoken in a sentence: "resistor", "NPN transistor", "op-amp", "LED". Ordinary words are lower-cased,
    /// abbreviations kept, and nothing in brackets is changed ("ATmega328P (Arduino Uno)").
    public static func spokenKind(_ kind: ElementKind) -> String {
        var result = ""
        var word = ""
        var bracketed = false
        func flush() {
            let letters = word.filter(\.isLetter)
            if !bracketed, letters.count > 1, letters.first?.isUppercase == true, letters.dropFirst().allSatisfy(\.isLowercase) {
                result += word.lowercased()
            } else {
                result += word
            }
            word = ""
        }
        for character in kind.displayName {
            if character == " " || character == "-" || character == "(" {
                flush()
                if character == "(" { bracketed = true }
                result.append(character)
            } else {
                word.append(character)
            }
        }
        flush()
        return result
    }

    /// "R1, resistor" (or just "resistor" for a part without a name; a net label is "net label +9V")
    public static func spokenName(_ element: Element) -> String {
        if element.kind == .netLabel {
            let name = element.name.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? "net label" : "net label \(name)"
        }
        return element.name.isEmpty ? spokenKind(element.kind) : "\(element.name), \(spokenKind(element.kind))"
    }

    /// For every described part, what its terminals connect to, in words. Works out the circuit's nets once, so call
    /// it once per change of the circuit's connections, not per part.
    public static func connections(in circuit: Circuit) -> [UUID: String] {
        let parts = NetlistExtractor.netlist(from: circuit)
        let elements = Dictionary(circuit.elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // names that were chosen, rather than made up as N1, N2…
        var chosenNames = Set(NetlistLayout.netNames(in: circuit))
        chosenNames.formUnion(circuit.netNames.values)
        func isMadeUp(_ net: String) -> Bool {
            guard !chosenNames.contains(net), net.hasPrefix("N") else { return false }
            let digits = net.dropFirst()
            return !digits.isEmpty && digits.allSatisfy(\.isNumber)
        }
        // every terminal on each net, in the parts' order
        var onNet: [String: [(part: Int, terminal: String)]] = [:]
        for (p, part) in parts.enumerated() {
            for terminal in terminalNames(part, elements) {
                if let net = part.connections[terminal] { onNet[net, default: []].append((p, terminal)) }
            }
        }

        /// A terminal of another part, as a listener would want it: "R2", "the base of Q1", "pin PD2 of U1"
        func phrase(part p: Int, terminal: String) -> String {
            let part = parts[p]
            let name = part.name.isEmpty ? "the " + spokenKind(part.kind) : part.name
            let names = terminalNames(part, elements)
            if names.count == 2 && Set(names) == ["a", "b"] { return name }
            let word = terminalWord(terminal, kind: part.kind)
            return word.hasPrefix("pin ") ? "\(word) of \(name)" : "the \(word) of \(name)"
        }

        /// What a terminal on `net` meets, seen from part `p`'s terminal `terminal`
        func describe(net: String, from p: Int, terminal: String) -> String {
            if net == "GND" { return "ground" }
            guard isMadeUp(net) else { return net }
            let others = (onNet[net] ?? []).filter { !($0.part == p && $0.terminal == terminal) }
            guard !others.isEmpty else { return "nothing" }
            var phrases: [String] = []
            for other in others {
                let text = other.part == p ? "its own \(terminalWord(other.terminal, kind: parts[p].kind))" : phrase(part: other.part, terminal: other.terminal)
                if !phrases.contains(text) { phrases.append(text) }
            }
            if phrases.count > 3 { return list(Array(phrases.prefix(2)) + ["\(phrases.count - 2) more"]) }
            return list(phrases)
        }

        var result: [UUID: String] = [:]
        for (p, part) in parts.enumerated() {
            guard let id = part.id else { continue }
            let names = terminalNames(part, elements)
            let nets = names.map { name in part.connections[name].map { describe(net: $0, from: p, terminal: name) } }
            if names.count == 2 && Set(names) == ["a", "b"] {
                switch (nets[0], nets[1]) {
                case let (x?, y?):
                    result[id] = part.connections["a"] == part.connections["b"] ? "both ends on \(x)" : "between \(x) and \(y)"
                case (let x?, nil), (nil, let x?):
                    result[id] = "one end on \(x), the other not connected"
                case (nil, nil):
                    result[id] = "not connected"
                }
                continue
            }
            let connected = zip(names, nets).compactMap { name, net in net.map { "\(terminalWord(name, kind: part.kind)) to \($0)" } }
            let loose = zip(names, nets).filter { $0.1 == nil }.count
            if connected.isEmpty {
                result[id] = "not connected"
            } else if loose > 0 && names.count > 4 {
                // a chip: the pins that are used, and how many are not
                result[id] = connected.joined(separator: ", ") + "; \(loose) \(loose == 1 ? "pin" : "pins") not connected"
            } else {
                result[id] = (connected + zip(names, nets).filter { $0.1 == nil }.map { "\(terminalWord($0.0, kind: part.kind)) not connected" })
                    .joined(separator: ", ")
            }
        }
        // net labels: the parts on their net
        for element in circuit.elements where element.kind == .netLabel {
            let name = element.name.trimmingCharacters(in: .whitespaces)
            let net = Topology.isGroundName(name) ? "GND" : name
            let members = (onNet[net] ?? []).map { phrase(part: $0.part, terminal: $0.terminal) }
            var unique: [String] = []
            for member in members where !unique.contains(member) { unique.append(member) }
            if name.isEmpty || unique.isEmpty {
                result[element.id] = "connects to nothing"
            } else if unique.count > 4 {
                result[element.id] = "connects " + list(Array(unique.prefix(3)) + ["\(unique.count - 3) more"])
            } else {
                result[element.id] = "connects " + list(unique)
            }
        }
        return result
    }

    /// "a", "a and b", "a, b and c"
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    private static func terminalNames(_ part: NetlistPart, _ elements: [UUID: Element]) -> [String] {
        if let id = part.id, let element = elements[id] { return element.terminalNames }
        return part.terminalNames
    }

    /// A terminal's name as a word: "base", "output", "wiper", "plus"; "pin PD2" for a chip's pins
    static func terminalWord(_ terminal: String, kind: ElementKind) -> String {
        switch terminal {
        case "out": return "output"
        case "in": return "input"
        case "in1": return "input 1"
        case "in2": return "input 2"
        case "gnd": return "ground pin"
        case "vcc": return "supply pin"
        case "net": return "net"
        case "a": return kind == .potentiometer || kind == .analogSwitch ? "end a" : "terminal a"
        case "b": return kind == .potentiometer || kind == .analogSwitch ? "end b" : "terminal b"
        case "ctrl", "cv": return "control input"
        case "minus", "plus", "anode", "cathode", "base", "collector", "emitter", "gate", "drain", "source", "grid", "plate",
             "screen", "wiper", "control", "bias", "hot", "trig", "reset", "clock", "time", "ref", "pw", "x", "y":
            return terminal
        case "thr": return "threshold"
        case "dis": return "discharge"
        case "p1", "p2": return "primary " + String(terminal.dropFirst())
        case "s1", "s2": return "secondary " + String(terminal.dropFirst())
        default: return "pin \(terminal)"
        }
    }
}
