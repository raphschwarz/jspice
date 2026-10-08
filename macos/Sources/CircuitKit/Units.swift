import Foundation

/// Formatting and parsing of engineering values with SI prefixes ("4.7 kΩ", "100n").
public enum SI {
    private static let prefixes: [(scale: Double, symbol: String)] = [
        (1e12, "T"), (1e9, "G"), (1e6, "M"), (1e3, "k"), (1, ""),
        (1e-3, "m"), (1e-6, "µ"), (1e-9, "n"), (1e-12, "p"), (1e-15, "f"),
    ]

    /// 0.0047, "A" -> "4.7 mA"
    public static func format(_ value: Double, unit: String, digits: Int = 3) -> String {
        guard value.isFinite else { return "—" }
        if value == 0 { return unit.isEmpty ? "0" : "0 \(unit)" }
        let magnitude = abs(value)
        var chosen = prefixes[prefixes.count - 1]
        for prefix in prefixes where magnitude >= prefix.scale * 0.9995 {
            chosen = prefix
            break
        }
        let text = trimmed(value / chosen.scale, digits: digits)
        let suffix = chosen.symbol + unit
        return suffix.isEmpty ? text : "\(text) \(suffix)"
    }

    /// A number with `digits` significant digits and no trailing zeros
    public static func trimmed(_ value: Double, digits: Int) -> String {
        let magnitude = abs(value)
        let integerDigits = magnitude >= 100 ? 3 : magnitude >= 10 ? 2 : 1
        let decimals = max(0, digits - integerDigits)
        var text = String(format: "%.\(decimals)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        if text == "-0" { text = "0" }
        return text.replacingOccurrences(of: "-", with: "−")
    }

    /// "4.7k" -> 4700, "100 nF" -> 1e-7, "1M" -> 1e6, "2m" -> 0.002, "1meg" -> 1e6.
    /// Capital M is mega and lowercase m is milli; u, n and p may be capitals. A trailing unit (Ω, F, H, V, A, Hz, s) is ignored.
    public static func parse(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: ",", with: ".")
        // "R47": the R of the RKM code (IEC 60062) as the decimal point, before any digit
        if let first = cleaned.first, first == "R" || first == "r", cleaned.dropFirst().first?.isNumber == true {
            return parse("0." + cleaned.dropFirst())
        }
        let scanner = Scanner(string: cleaned)
        scanner.locale = Locale(identifier: "en_US_POSIX")
        guard var number = scanner.scanDouble() else { return nil }
        let scanned = cleaned[..<scanner.currentIndex]
        let rest = String(cleaned[scanner.currentIndex...]).trimmingCharacters(in: .whitespaces)
        // the RKM code's prefix in place of the decimal point, as schematics print values: 4k7, 2R2, 1M5, 4u7
        let prefixLength = rest.lowercased().hasPrefix("meg") ? 3 : 1
        let fraction = rest.dropFirst(prefixLength).prefix { $0.isNumber }
        if !fraction.isEmpty, !scanned.contains("."), !scanned.lowercased().contains("e"),
           let first = rest.first, first.isLetter || first == "µ" || first == "μ",
           let digits = Double("0." + fraction) {
            number += number < 0 ? -digits : digits
        }
        var multiplier = 1.0
        if rest.lowercased().hasPrefix("meg") {
            multiplier = 1e6
        } else if let first = rest.first {
            switch first {
            case "T": multiplier = 1e12
            case "G": multiplier = 1e9
            case "M": multiplier = 1e6
            case "k", "K": multiplier = 1e3
            case "m": multiplier = 1e-3
            // printed schematics and SPICE decks write these in capitals too ("100N", "4U7", "22P"); F stays farads
            case "u", "U", "µ", "μ": multiplier = 1e-6
            case "n", "N": multiplier = 1e-9
            case "p", "P": multiplier = 1e-12
            case "f": multiplier = 1e-15
            default: multiplier = 1
            }
        }
        let value = number * multiplier
        return value.isFinite ? value : nil
    }

    /// The largest 1/2/5 x 10^n value that is not above `value`
    public static func niceFloor(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return value }
        let magnitude = pow(10, floor(log10(value)))
        let residual = value / magnitude
        let nice: Double = residual >= 5 ? 5 : residual >= 2 ? 2 : 1
        return nice * magnitude
    }
}
