import Foundation
import CircuitKit

/// How well a schematic was read: a captured circuit against the circuit the drawing shows.
///
/// Parts are matched by name (as drawn: R1, C3, Q2), then the rest by kind and nearest value. A matched part counts as
/// found; its value as right within 2 %. Connections are scored as pairs of terminals that share a net: a pair the
/// drawing has and the capture has too is right, whatever the nets are called. Two-terminal parts that work either way
/// round (a resistor, a capacitor) may be read either way round.
public struct CaptureScore: CustomStringConvertible, Sendable {
    /// Parts in the drawing, and those found with the right kind
    public var parts = 0
    public var found = 0
    /// Parts the capture added that the drawing does not have
    public var extra = 0
    /// Found parts with a value to compare, and those whose value is right
    public var valued = 0
    public var values = 0
    /// Terminal pairs on one net: the drawing's, the capture's, and those in both
    public var truthPairs = 0
    public var capturedPairs = 0
    public var sharedPairs = 0
    /// What is wrong, part by part
    public var mistakes: [String] = []

    public var precision: Double { capturedPairs == 0 ? (truthPairs == 0 ? 1 : 0) : Double(sharedPairs) / Double(capturedPairs) }
    public var recall: Double { truthPairs == 0 ? 1 : Double(sharedPairs) / Double(truthPairs) }
    /// The connections' F1 score: 1 when the capture connects exactly what the drawing does
    public var connections: Double { precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall) }

    public var description: String {
        String(format: "parts %d/%d (+%d extra), values %d/%d, connections %.3f (precision %.3f, recall %.3f)",
               found, parts, extra, values, valued, connections, precision, recall)
    }

    /// Parts that work either way round
    static let symmetric: Set<ElementKind> = [.resistor, .capacitor, .inductor, .lamp, .toggleSwitch, .pushButton]
    /// What is drawn but is not a part
    static let ignored: Set<ElementKind> = [.wire, .ground, .netLabel, .probe, .loopProbe, .port, .block]

    static func netlist(_ circuit: Circuit) -> [NetlistPart] {
        NetlistExtractor.netlist(from: circuit.flattened(expandingModels: false)).filter { !ignored.contains($0.kind) }
    }

    static func value(_ part: NetlistPart) -> Double? {
        guard let spec = part.kind.params.first else { return nil }
        return part.params[spec.key] ?? spec.defaultValue
    }

    public static func compare(_ captured: Circuit, to truth: Circuit) -> CaptureScore {
        compare(netlist(captured), to: netlist(truth))
    }

    public static func compare(_ captured: [NetlistPart], to truth: [NetlistPart]) -> CaptureScore {
        var score = CaptureScore()
        score.parts = truth.count
        // matching: by name first, then by kind and the nearest value
        var match: [Int: Int] = [:]   // captured index -> truth index
        var taken = Set<Int>()
        for (i, part) in captured.enumerated() {
            if let j = truth.indices.first(where: { !taken.contains($0) && truth[$0].name.lowercased() == part.name.lowercased()
                                                    && truth[$0].kind == part.kind }) {
                match[i] = j
                taken.insert(j)
            }
        }
        for (i, part) in captured.enumerated() where match[i] == nil {
            let candidates = truth.indices.filter { !taken.contains($0) && truth[$0].kind == part.kind }
            let v = value(part) ?? 0
            if let j = candidates.min(by: { abs(log(max(value(truth[$0]) ?? 1, 1e-15) / max(v, 1e-15)))
                                            < abs(log(max(value(truth[$1]) ?? 1, 1e-15) / max(v, 1e-15))) }) {
                match[i] = j
                taken.insert(j)
            }
        }
        score.found = match.count
        score.extra = captured.count - match.count
        for j in truth.indices where !taken.contains(j) { score.mistakes.append("\(truth[j].name) (\(truth[j].kind.rawValue)) not found") }
        for i in captured.indices where match[i] == nil { score.mistakes.append("\(captured[i].name) (\(captured[i].kind.rawValue)) is not in the drawing") }
        for (i, j) in match {
            guard let a = value(captured[i]), let b = value(truth[j]) else { continue }
            score.valued += 1
            if abs(a - b) <= 0.02 * max(abs(b), 1e-15) {
                score.values += 1
            } else {
                score.mistakes.append("\(truth[j].name): \(SI.format(a, unit: "")) read for \(SI.format(b, unit: ""))")
            }
        }

        // each terminal under the drawing's names; an unmatched captured part keeps a name of its own
        func name(_ i: Int) -> String { match[i].map { truth[$0].name } ?? "extra:\(captured[i].name)" }
        let symmetricNames = Set(truth.filter { symmetric.contains($0.kind) }.map(\.name))
        /// Nets as sets of terminals, with the ends of parts that work either way round folded together (for choosing
        /// which way round each was read)
        func folded(_ parts: [(name: String, part: NetlistPart)]) -> [String: Set<String>] {
            var nets: [String: Set<String>] = [:]
            for (name, part) in parts {
                for (terminal, net) in part.connections {
                    nets[net, default: []].insert(symmetricNames.contains(name) ? name + ".*" : name + "." + terminal)
                }
            }
            return nets
        }
        let truthNamed: [(name: String, part: NetlistPart)] = truth.map { ($0.name, $0) }
        var capturedNamed: [(name: String, part: NetlistPart)] = captured.indices.map { (name($0), captured[$0]) }
        // which way round each symmetric part was read: the way its ends' nets agree best with the drawing's
        let truthFolded = folded(truthNamed), capturedFolded = folded(capturedNamed)
        func neighbours(_ nets: [String: Set<String>], _ part: NetlistPart, _ terminal: String) -> Set<String> {
            guard let net = part.connections[terminal] else { return [] }
            return nets[net] ?? []
        }
        for k in capturedNamed.indices {
            let (partName, part) = capturedNamed[k]
            guard symmetricNames.contains(partName), part.kind.terminalNames.count == 2,
                  let t = truth.first(where: { $0.name == partName }) else { continue }
            let (x, y) = (part.kind.terminalNames[0], part.kind.terminalNames[1])
            let straight = neighbours(truthFolded, t, x).intersection(neighbours(capturedFolded, part, x)).count
                + neighbours(truthFolded, t, y).intersection(neighbours(capturedFolded, part, y)).count
            let crossed = neighbours(truthFolded, t, x).intersection(neighbours(capturedFolded, part, y)).count
                + neighbours(truthFolded, t, y).intersection(neighbours(capturedFolded, part, x)).count
            if crossed > straight {
                var turned = part
                turned.connections = [x: part.connections[y], y: part.connections[x]].compactMapValues { $0 }
                capturedNamed[k] = (partName, turned)
            }
        }

        func pairs(_ parts: [(name: String, part: NetlistPart)]) -> Set<String> {
            var nets: [String: [String]] = [:]
            for (name, part) in parts {
                for (terminal, net) in part.connections { nets[net, default: []].append(name + "." + terminal) }
            }
            var result = Set<String>()
            for members in nets.values {
                let sorted = members.sorted()
                for a in sorted.indices { for b in sorted.indices where b > a { result.insert(sorted[a] + "|" + sorted[b]) } }
            }
            return result
        }
        let truthPairs = pairs(truthNamed), capturedPairs = pairs(capturedNamed)
        score.truthPairs = truthPairs.count
        score.capturedPairs = capturedPairs.count
        score.sharedPairs = truthPairs.intersection(capturedPairs).count
        for pair in truthPairs.subtracting(capturedPairs).sorted().prefix(8) {
            score.mistakes.append("not joined: " + pair.replacingOccurrences(of: "|", with: " – "))
        }
        for pair in capturedPairs.subtracting(truthPairs).sorted().prefix(8) {
            score.mistakes.append("joined wrongly: " + pair.replacingOccurrences(of: "|", with: " – "))
        }
        return score
    }
}
