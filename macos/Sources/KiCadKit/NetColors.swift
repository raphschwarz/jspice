// Ported from KiCad 10.0.8: common/gal/color4d.cpp and include/gal/color4d.h (COLOR4D: SetFromWxString,
// SetFromHexString, ToColour, ToCSSString, to_json and from_json, UNSPECIFIED), with wxWidgets 3.2's wxColour::Set
// (wxColourBase::FromString: the CSS strings KiCad writes), common/project/net_settings.cpp (NET_SETTINGS'
// "net_colors" and its classes' "pcb_color": how they are read and written) and include/netclass.h (GetPcbColor,
// HasPcbColor).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// A colour as KiCad keeps one (COLOR4D): red, green, blue and alpha from 0 to 1, as doubles
public struct KiCadColor: Equatable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        (self.r, self.g, self.b, self.a) = (r, g, b, a)
    }

    /// COLOR4D(): black, opaque
    public init() { self.init(r: 0, g: 0, b: 0, a: 1) }

    /// COLOR4D::UNSPECIFIED: no colour (0, 0, 0, 0), as a net or net class without one has
    public static let unspecified = KiCadColor(r: 0, g: 0, b: 0, a: 0)

    public var isUnspecified: Bool { self == .unspecified }

    public var rgba: KiCadColorTheme.RGBA { (r, g, b, a) }

    public init(_ c: KiCadColorTheme.RGBA) { self.init(r: c.r, g: c.g, b: c.b, a: c.a) }

    /// COLOR4D::SetFromWxString: the colour of a string as wxColour::Set reads it ("rgb(r, g, b)", "rgba(r, g, b, a)"
    /// with its channels clipped to 0 to 255 and its alpha a fraction rounded to a 255th, "#RRGGBB"), each channel
    /// its byte over 255; nil where wxColour cannot read it (a colour's name, which wxWidgets' colour database would
    /// look up, is not read here)
    public init?(wxString s: String) {
        guard let (red, green, blue, alpha) = Self.wxColour(s) else { return nil }
        self.init(r: Double(red) / 255, g: Double(green) / 255, b: Double(blue) / 255, a: Double(alpha) / 255)
    }

    /// COLOR4D::SetFromHexString: "#RRGGBB" (opaque) or "#RRGGBBAA", spaces around it let go; nil otherwise
    public init?(hex: String) {
        let s = hex.trimmingCharacters(in: .whitespaces)
        guard s.count >= 7, s.hasPrefix("#") else { return nil }
        // (wxSscanf's %lx: the hexadecimal digits from the start)
        let digits = s.dropFirst().prefix { $0.isHexDigit }
        guard !digits.isEmpty, let tmp = UInt64(digits.suffix(16), radix: 16) else { return nil }
        if s.count >= 9 {
            self.init(r: Double((tmp >> 24) & 0xFF) / 255, g: Double((tmp >> 16) & 0xFF) / 255,
                      b: Double((tmp >> 8) & 0xFF) / 255, a: Double(tmp & 0xFF) / 255)
        } else {
            self.init(r: Double((tmp >> 16) & 0xFF) / 255, g: Double((tmp >> 8) & 0xFF) / 255, b: Double(tmp & 0xFF) / 255)
        }
    }

    /// COLOR4D::ToColour: each channel's byte (its 255ths, half a one added, cut)
    public var bytes: (r: Int, g: Int, b: Int, a: Int) {
        func byte(_ v: Double) -> Int { Int(UInt8(clamping: Int((v * 255 + 0.5).rounded(.towardZero)))) }
        return (byte(r), byte(g), byte(b), byte(a))
    }

    /// COLOR4D::ToCSSString, as KiCad writes a colour in its settings (to_json): "rgb(r, g, b)" when opaque, else
    /// "rgba(r, g, b, a)" with the alpha's fraction to three places
    public var css: String {
        let c = bytes
        if c.a == 255 { return "rgb(\(c.r), \(c.g), \(c.b))" }
        return "rgba(\(c.r), \(c.g), \(c.b), \(String(format: "%.3f", Double(c.a) / 255)))"
    }

    /// COLOR4D::Brightened, Darkened, WithAlpha
    public func brightened(_ f: Double) -> KiCadColor { KiCadColor(r: r * (1 - f) + f, g: g * (1 - f) + f, b: b * (1 - f) + f, a: a) }
    public func darkened(_ f: Double) -> KiCadColor { KiCadColor(r: r * (1 - f), g: g * (1 - f), b: b * (1 - f), a: a) }
    public func withAlpha(_ alpha: Double) -> KiCadColor { KiCadColor(r: r, g: g, b: b, a: alpha) }
    /// COLOR4D::GetBrightness
    public var brightness: Double { (r + g + b) / 3 }

    /// wxColourBase::FromString's reading of a string: its bytes, or nil
    static func wxColour(_ s: String) -> (Int, Int, Int, Int)? {
        let chars = Array(s.unicodeScalars)
        guard !chars.isEmpty else { return nil }
        if chars.count >= 3, String(String.UnicodeScalarView(chars[0..<3])).lowercased() == "rgb" {
            var scanner = Scanner(chars)
            let withAlpha = chars.count > 3 && (chars[3] == "a" || chars[3] == "A")
            scanner.at = withAlpha ? 4 : 3
            // ("( %d , %d , %d , %15[^)] )" or "( %d , %d , %d )": a space in the format any white space)
            guard scanner.literal("("), let red = scanner.int(), scanner.literal(","), let green = scanner.int(),
                  scanner.literal(","), let blue = scanner.int() else { return nil }
            var alpha = 255
            if withAlpha {
                guard scanner.literal(",") else { return nil }
                scanner.skipSpace()
                // (%15[^)]: up to fifteen characters before a parenthesis, then read as a C double, all of it)
                var text = ""
                while scanner.at < chars.count, chars[scanner.at] != ")", text.unicodeScalars.count < 15 {
                    text.unicodeScalars.append(chars[scanner.at])
                    scanner.at += 1
                }
                guard !text.isEmpty, let a = Self.cDouble(text) else { return nil }
                // (wxRound: half away from nought)
                let scaled = a * 255
                alpha = Int(scaled < 0 ? (scaled - 0.5).rounded(.towardZero) : (scaled + 0.5).rounded(.towardZero))
            }
            func clip(_ v: Int) -> Int { min(max(v, 0), 255) }
            return (clip(red), clip(green), clip(blue), clip(alpha))
        }
        if chars[0] == "#" && chars.count == 7 {
            let digits = String(String.UnicodeScalarView(chars[1...])).prefix { $0.isHexDigit }
            guard !digits.isEmpty, let tmp = UInt64(digits, radix: 16) else { return nil }
            return (Int((tmp >> 16) & 0xFF), Int((tmp >> 8) & 0xFF), Int(tmp & 0xFF), 255)
        }
        return nil
    }

    /// wxString::ToCDouble: the whole string a number in the C locale
    static func cDouble(_ s: String) -> Double? {
        guard let first = s.unicodeScalars.first, !CharacterSet.whitespaces.contains(first) else { return nil }
        return Double(s)
    }

    /// Enough of wxSscanf for wxColour's formats
    struct Scanner {
        let chars: [Unicode.Scalar]
        var at = 0

        init(_ chars: [Unicode.Scalar]) { self.chars = chars }

        mutating func skipSpace() {
            while at < chars.count, [" ", "\t", "\n", "\r", "\u{0B}", "\u{0C}"].contains(chars[at]) { at += 1 }
        }

        /// White space, then the character
        mutating func literal(_ c: Unicode.Scalar) -> Bool {
            skipSpace()
            guard at < chars.count, chars[at] == c else { return false }
            at += 1
            return true
        }

        /// %d: white space, a sign, digits
        mutating func int() -> Int? {
            skipSpace()
            var text = ""
            if at < chars.count, chars[at] == "-" || chars[at] == "+" {
                text.unicodeScalars.append(chars[at])
                at += 1
            }
            var digits = 0
            while at < chars.count, ("0"..."9").contains(chars[at]) {
                text.unicodeScalars.append(chars[at])
                at += 1
                digits += 1
            }
            guard digits > 0 else { return nil }
            return Int(text.hasPrefix("+") ? String(text.dropFirst()) : text).map { min(max($0, Int(Int32.min)), Int(Int32.max)) }
        }
    }
}

/// The colours a project gives nets and net classes for the board (its .kicad_pro's net_settings, NET_SETTINGS):
/// each net's own colour by name ("net_colors", m_netColorAssignments), and each net class's ("pcb_color" of each
/// of "classes")
public struct KiCadNetColors: Equatable, Sendable {
    /// The nets' colours by name, as the file has them (one KiCad cannot read is black: from_json of a COLOR4D
    /// made black)
    public var nets: [String: KiCadColor] = [:]
    /// The classes' colours by name, as the file has them (UNSPECIFIED where none: KiCad writes that too); the
    /// Default class's as read and written, though KiCad never shows it (GetPcbColor gives UNSPECIFIED for it)
    public var classes: [String: KiCadColor] = [:]

    public init() {}

    /// As KiCad reads them from the project file's JSON (NET_SETTINGS' "net_colors" and readNetClass)
    public init(project: [String: Any]?) {
        let ns = project?["net_settings"] as? [String: Any] ?? [:]
        if let colors = ns["net_colors"] as? [String: Any] {
            for (name, value) in colors {
                guard let s = value as? String else { continue }
                nets[name] = KiCadColor(wxString: s) ?? KiCadColor()
            }
        }
        for c in ns["classes"] as? [[String: Any]] ?? [] {
            guard let name = c["name"] as? String else { continue }
            if let s = c["pcb_color"] as? String {
                classes[name] = KiCadColor(wxString: s) ?? KiCadColor()
            } else {
                classes[name] = .unspecified
            }
        }
    }

    /// A class's colour as the board shows it (NETCLASS::GetPcbColor: none for the default class)
    public func pcbColor(ofClass name: String) -> KiCadColor {
        name == "Default" ? .unspecified : classes[name] ?? .unspecified
    }

    /// Written into the project file's JSON as KiCad writes them: "net_colors" whole (its unknown keys dropped:
    /// SetClearUnknownKeys), each class's "pcb_color" (GetPcbColor( true )) where the file has the class
    public func write(into project: inout [String: Any]) {
        var ns = project["net_settings"] as? [String: Any] ?? ["meta": ["version": 5]]
        ns["net_colors"] = nets.mapValues { $0.css } as [String: String]
        if var list = ns["classes"] as? [[String: Any]] {
            for i in list.indices {
                guard let name = list[i]["name"] as? String, let color = classes[name] else { continue }
                list[i]["pcb_color"] = color.css
            }
            ns["classes"] = list
        }
        project["net_settings"] = ns
    }
}
