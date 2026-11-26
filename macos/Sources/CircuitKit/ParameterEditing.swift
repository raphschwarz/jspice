import Foundation

// What the inspector does with a typed value, apart from drawing it: stepping it with the arrow keys (through the
// standard values parts are made in, or by a round amount), and editing several selected parts at once.

extension ESeries {
    /// The value of the series of `size` (12, 24 or 96) next above `value` (or below it, with `up` false), strictly:
    /// 4.7k steps up to 5.6k in E12, and 5k (between two values) to 5.6k as well. Nil for a value that is not positive
    /// or a series that does not exist.
    public static func step(_ value: Double, series size: Int, up: Bool) -> Double? {
        guard value > 0, value.isFinite, let mantissas = mantissas(size) else { return nil }
        let exponent = floor(log10(value))
        // the series over three decades around the value, so that its neighbours are there at either end
        let candidates = [exponent - 1, exponent, exponent + 1].flatMap { e in
            mantissas.map { clean($0 * pow(10, e)) }
        }
        // a value typed as 4.7k is 4700 to within rounding: it is on the series, not just below or above it
        let tolerance = 1e-6
        return up ? candidates.first { $0 > value * (1 + tolerance) } : candidates.last { $0 < value * (1 - tolerance) }
    }

    /// The value of the series nearest to `value` in ratio, as parts are chosen (cleaned of rounding: 5600, not
    /// 5600.000000000001)
    public static func nearest(_ value: Double, series size: Int) -> Double? {
        around(value, series: size).map { clean($0.nearest) }
    }

    /// `x` to four significant digits, computed so that it is the double nearest to the decimal (4.7e-6 exactly as typed)
    static func clean(_ x: Double) -> Double {
        guard x != 0, x.isFinite else { return x }
        let e = floor(log10(abs(x))) - 3
        if e >= 0 {
            let p = pow(10, e)
            return (x / p).rounded() * p
        }
        let p = pow(10, -e)
        return (x * p).rounded() / p
    }
}

/// The ↑ and ↓ keys in a parameter's field: the next standard value for a resistance, capacitance or inductance, and a
/// round step for anything else
public enum ParameterStepping {
    /// What typed text that is not a value is answered with
    public static let parseHint = "Not a value: try 4.7k, 10u, 2M2 or 100n"

    /// Resistances, capacitances and inductances, the values parts come in a series of (a parameter on a logarithmic
    /// slider in Ω, F or H: a resistor's or potentiometer's resistance, a capacitor's capacitance, an inductor's inductance)
    public static func usesESeries(_ spec: ParamSpec) -> Bool {
        spec.logarithmic && spec.choices.isEmpty && ["Ω", "F", "H"].contains(spec.unit)
    }

    /// The value one step above `value` (or below it), for `spec`. `finer` is the ⌥ key: E24 in place of E12, and for
    /// the other parameters a finer step (a tenth of it on a linear slider; the E12 values on a logarithmic one, in
    /// place of 1, 2, 5)
    public static func step(_ value: Double, _ spec: ParamSpec, up: Bool, finer: Bool = false) -> Double {
        let lower = spec.range.lowerBound
        if spec.logarithmic {
            guard value > 0, value.isFinite else {
                // from nothing, up goes to the slider's lowest value
                return up && lower > 0 ? lower : value
            }
            if usesESeries(spec) {
                return ESeries.step(value, series: finer ? 24 : 12, up: up) ?? value
            }
            return finer ? (ESeries.step(value, series: 12, up: up) ?? value) : oneTwoFive(value, up: up)
        }
        let step = linearStep(spec, finer: finer)
        guard value.isFinite else { return value }
        // onto the next multiple of the step: 0.537 goes up to 0.54 and down to 0.53
        let n = up ? floor(value / step + 1e-9) + 1 : ceil(value / step - 1e-9) - 1
        var result = multiple(n, of: step)
        // no negative capacitance or duty cycle by stepping down from 0
        if lower >= 0 { result = max(result, lower) }
        return result
    }

    /// The step of a parameter on a linear slider: a round hundredth of its range (0.01 for 0 to 1, 0.2 for ±15 V)
    public static func linearStep(_ spec: ParamSpec, finer: Bool = false) -> Double {
        let span = spec.range.upperBound - spec.range.lowerBound
        let step = span > 0 && span.isFinite ? SI.niceFloor(span / 100) : 1
        return finer ? step / 10 : step
    }

    /// A short note of what ↑ and ↓ do in the field, for its help tag
    public static func hint(_ spec: ParamSpec) -> String {
        if usesESeries(spec) { return "↑ ↓ step through the E12 values (with ⌥, E24)" }
        if spec.logarithmic { return "↑ ↓ step through 1, 2, 5, 10… (with ⌥, the E12 values)" }
        let step = linearStep(spec)
        let unit = spec.unit == "°" || spec.unit.count > 3 ? "" : spec.unit
        return "↑ ↓ step by \(SI.format(step, unit: unit)) (with ⌥, \(SI.format(step / 10, unit: unit)))"
    }

    /// The next 1, 2 or 5 × 10ⁿ value strictly above `value` (or below it)
    static func oneTwoFive(_ value: Double, up: Bool) -> Double {
        let exponent = floor(log10(value))
        let candidates = [exponent - 1, exponent, exponent + 1].flatMap { e in
            [1.0, 2, 5].map { ESeries.clean($0 * pow(10, e)) }
        }
        let tolerance = 1e-6
        return (up ? candidates.first { $0 > value * (1 + tolerance) } : candidates.last { $0 < value * (1 - tolerance) }) ?? value
    }

    /// `n` × `step` without the rounding of a product of decimals (0.54, not 0.54000000000000004)
    static func multiple(_ n: Double, of step: Double) -> Double {
        let inverse = (1 / step).rounded()
        if step < 1, inverse > 1, abs(1 / step - inverse) < 1e-9 * inverse { return n / inverse }
        return n * step
    }
}

/// Editing several selected parts at once: which parts take part, what they have in common, and how they are described
public enum MultiEdit {
    /// Wires, grounds and net labels go along with a selection but have nothing to edit
    public static func isEditable(_ kind: ElementKind) -> Bool {
        kind != .wire && kind != .ground && kind != .netLabel
    }

    /// The selected parts that can be edited, in the circuit's order
    public static func parts(_ ids: Set<UUID>, in circuit: Circuit) -> [Element] {
        circuit.elements.filter { ids.contains($0.id) && isEditable($0.kind) }
    }

    /// The parts' kinds, each once, in the order they first come
    public static func kinds(of parts: [Element]) -> [ElementKind] {
        var seen = Set<ElementKind>()
        return parts.map(\.kind).filter { seen.insert($0).inserted }
    }

    /// The parameters all of `kinds` have, to edit together: for one kind, its parameters (not the SPICE model card's
    /// advanced ones); for several, those with the same key and the same unit in each (and the same settings, for one
    /// that picks a setting), none of them advanced in any. In the order of the first kind.
    public static func commonParams(_ kinds: [ElementKind]) -> [ParamSpec] {
        guard let first = kinds.first else { return [] }
        let candidates = first.params.filter { !$0.advanced }
        return candidates.filter { spec in
            kinds.dropFirst().allSatisfy { kind in
                kind.params.contains { $0.key == spec.key && $0.unit == spec.unit && !$0.advanced && $0.choices == spec.choices }
            }
        }
    }

    /// The value all the parts have for `key`, nil when they differ (to within rounding)
    public static func commonValue(_ parts: [Element], _ key: String) -> Double? {
        guard let value = parts.first?[param: key] else { return nil }
        let same = parts.allSatisfy { abs($0[param: key] - value) <= 1e-9 * max(abs(value), abs($0[param: key])) }
        return same ? value : nil
    }

    /// The model all the parts have (nil, not mixed: all are custom; nil and mixed: they differ)
    public static func commonModel(_ parts: [Element]) -> (model: PartModel?, mixed: Bool) {
        let names = Set(parts.map { $0.model?.name ?? "" })
        guard names.count == 1 else { return (nil, true) }
        return (parts.first?.model, false)
    }

    /// Sets `key` to `value` on each of the parts `ids` whose kind has that parameter
    public static func set(_ key: String, to value: Double, of ids: Set<UUID>, in circuit: inout Circuit) {
        for id in ids {
            guard let element = circuit[id], element.kind.params.contains(where: { $0.key == key }) else { continue }
            circuit.update(id) { $0[param: key] = value }
        }
    }

    /// "6 resistors, 2 capacitors": the selection counted by kind, the most numerous first
    public static func summary(_ ids: Set<UUID>, in circuit: Circuit) -> String {
        var counts: [(kind: ElementKind, count: Int)] = []
        for element in circuit.elements where ids.contains(element.id) {
            if let i = counts.firstIndex(where: { $0.kind == element.kind }) {
                counts[i].count += 1
            } else {
                counts.append((element.kind, 1))
            }
        }
        // parts before wires, grounds and net labels; then by count (a stable sort keeps the circuit's order)
        let ordered = counts.enumerated().sorted { a, b in
            let ea = isEditable(a.element.kind), eb = isEditable(b.element.kind)
            if ea != eb { return ea }
            if a.element.count != b.element.count { return a.element.count > b.element.count }
            return a.offset < b.offset
        }
        return ordered.map { counted($0.element.count, $0.element.kind) }.joined(separator: ", ")
    }

    /// "1 resistor", "3 op-amps", "2 NPN transistors", "2 × ATmega328P (Arduino Uno)"
    public static func counted(_ count: Int, _ kind: ElementKind) -> String {
        let name = kind.displayName
        if name.contains("(") { return count == 1 ? "1 \(name)" : "\(count) × \(name)" }
        let irregular: [String: String] = ["Noise": "noise sources", "Audio In": "audio inputs", "Sample & Hold": "sample-and-holds"]
        if count != 1, let plural = irregular[name] { return "\(count) \(plural)" }
        var words = name.split(separator: " ").map { lowercased(String($0)) }
        if count != 1, let last = words.popLast() {
            let es = ["s", "x", "ch", "sh"].contains { last.hasSuffix($0) }
            words.append(last + (es ? "es" : "s"))
        }
        return "\(count) " + words.joined(separator: " ")
    }

    /// A word of a part's name as in a sentence: "Resistor" → "resistor", "Op-Amp" → "op-amp"; "NPN", "JFET",
    /// "ATtiny85" stay as they are
    private static func lowercased(_ word: String) -> String {
        word.split(separator: "-", omittingEmptySubsequences: false).map { part -> String in
            guard part.count >= 2, let first = part.first, first.isUppercase,
                  part.dropFirst().allSatisfy({ $0.isLowercase }) else { return String(part) }
            return part.lowercased()
        }.joined(separator: "-")
    }
}
