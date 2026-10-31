// Ported from KiCad 10.0.7: common/project/project_local_settings.cpp (PROJECT_LOCAL_SETTINGS: the board's part of a
// project's local settings, their defaults and how each is read and written), common/settings/json_settings.cpp
// (JSON_SETTINGS::SaveToFile and formatFileContents: the file as read with the settings written into it, nlohmann's
// dump( 2 )), thirdparty/nlohmann_json (its serializer: indentation, escapes, numbers), common/settings/
// layer_settings_utils.cpp (UserVisbilityLayers, VisibilityLayerToString, RenderLayerFromVisbilityString),
// include/layer_ids.h (PCB_LAYER_ID, GAL_LAYER_ID), common/lset.cpp and include/base_set.h (LSET::Name, FmtHex,
// ParseHex), common/settings/builtin_color_themes.h and color_settings.cpp (the "KiCad Default" theme, GetDefaultColor)
// and pcbnew/widgets/appearance_controls.cpp (the layers the Appearance panel lists, their order and tooltips; the
// built-in layer presets).
// Copyright (C) 2020 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

// MARK: - KiCad's JSON

/// A JSON value as KiCad's settings hold it (nlohmann::json): its objects' keys sorted as it sorts them (std::map, by
/// their bytes), its numbers integers or doubles as they were read
public indirect enum KiCadJSON: Equatable, Sendable {
    case object([String: KiCadJSON])
    case array([KiCadJSON])
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case null

    /// A JSON text read (nil where it is not JSON)
    public init?(text: String) {
        var parser = Parser(Array(text.utf8))
        guard let value = parser.value() else { return nil }
        parser.skipSpace()
        guard parser.at == parser.bytes.count else { return nil }
        self = value
    }

    public subscript(key: String) -> KiCadJSON? {
        get { if case .object(let o) = self { return o[key] } else { return nil } }
        set {
            guard case .object(var o) = self else { return }
            o[key] = newValue
            self = .object(o)
        }
    }

    /// The value at a dotted path ("board.opacity.tracks")
    public subscript(path path: String) -> KiCadJSON? {
        get {
            var v: KiCadJSON? = self
            for part in path.split(separator: ".") { v = v?[String(part)] }
            return v
        }
        set {
            let parts = path.split(separator: ".").map(String.init)
            func set(_ node: inout KiCadJSON, _ i: Int) {
                if case .object = node {} else { node = .object([:]) }
                if i == parts.count - 1 {
                    node[parts[i]] = newValue
                } else {
                    var child = node[parts[i]] ?? .object([:])
                    set(&child, i + 1)
                    node[parts[i]] = child
                }
            }
            set(&self, 0)
        }
    }

    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    /// A number as an integer (nlohmann's get<int> of a double cuts it)
    public var int: Int? {
        switch self {
        case .integer(let i): return Int(i)
        case .double(let d): return d.isFinite ? Int(d) : nil
        default: return nil
        }
    }
    public var number: Double? {
        switch self {
        case .integer(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
    public var array: [KiCadJSON]? { if case .array(let a) = self { return a } else { return nil } }

    /// nlohmann's update( other, merge_objects = true ): the other's keys put in, objects merged key by key
    public mutating func merge(_ other: KiCadJSON) {
        guard case .object(var mine) = self, case .object(let theirs) = other else {
            self = other
            return
        }
        for (k, v) in theirs {
            if var existing = mine[k], case .object = existing, case .object = v {
                existing.merge(v)
                mine[k] = existing
            } else {
                mine[k] = v
            }
        }
        self = .object(mine)
    }

    /// The text nlohmann's dump( 2 ) writes: objects' keys sorted, two spaces of indent a level, an empty object or
    /// array on one line
    public func dump(indent: Int = 0) -> String {
        var out = ""
        write(&out, indent)
        return out
    }

    private func write(_ out: inout String, _ level: Int) {
        let pad = String(repeating: " ", count: level + 2)
        let closing = String(repeating: " ", count: level)
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .integer(let i): out += String(i)
        case .double(let d): out += Self.formatDouble(d)
        case .string(let s): out += Self.quoted(s)
        case .array(let a):
            if a.isEmpty {
                out += "[]"
                return
            }
            out += "[\n"
            for (i, v) in a.enumerated() {
                out += pad
                v.write(&out, level + 2)
                out += i == a.count - 1 ? "\n" : ",\n"
            }
            out += closing + "]"
        case .object(let o):
            if o.isEmpty {
                out += "{}"
                return
            }
            out += "{\n"
            let keys = o.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            for (i, k) in keys.enumerated() {
                out += pad + Self.quoted(k) + ": "
                o[k]!.write(&out, level + 2)
                out += i == keys.count - 1 ? "\n" : ",\n"
            }
            out += closing + "}"
        }
    }

    /// nlohmann's string escapes (ensure_ascii off): quotes, backslashes and control characters, the rest as it is
    static func quoted(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    /// nlohmann's dump of a double: its shortest digits that read back the same (Grisu2), written in fixed notation
    /// for decimal exponents from -4 to 15 (".0" after a whole number), else in scientific notation with an exponent
    /// of two digits at least
    static func formatDouble(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
        // (Swift's description is the shortest round trip too: its digits and exponent taken from it)
        var text = "\(abs(d))"
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...]) ?? 0
            text = String(text[..<e])
        }
        var digits = text.replacingOccurrences(of: ".", with: "")
        let point = text.firstIndex(of: ".").map { text.distance(from: text.startIndex, to: $0) } ?? text.count
        // value = 0.digits × 10^(point + exponent)
        var n = point + exponent
        while digits.hasPrefix("0") && digits.count > 1 {
            digits.removeFirst()
            n -= 1
        }
        while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() }
        let len = digits.count
        let k = n - len
        var out = d < 0 ? "-" : ""
        if k >= 0 && n <= 15 {
            out += digits + String(repeating: "0", count: k) + ".0"
        } else if n > 0 && n <= 15 {
            out += String(digits.prefix(n)) + "." + String(digits.dropFirst(n))
        } else if n > -4 && n <= 0 {
            out += "0." + String(repeating: "0", count: -n) + digits
        } else {
            out += len == 1 ? digits : String(digits.prefix(1)) + "." + String(digits.dropFirst())
            let e = n - 1
            out += "e" + (e < 0 ? "-" : "+") + (abs(e) < 10 ? "0" : "") + String(abs(e))
        }
        return out
    }

    struct Parser {
        let bytes: [UInt8]
        var at = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSpace() {
            while at < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[at]) { at += 1 }
        }

        mutating func value() -> KiCadJSON? {
            skipSpace()
            guard at < bytes.count else { return nil }
            switch bytes[at] {
            case UInt8(ascii: "{"):
                at += 1
                var o: [String: KiCadJSON] = [:]
                skipSpace()
                if at < bytes.count, bytes[at] == UInt8(ascii: "}") {
                    at += 1
                    return .object(o)
                }
                while true {
                    skipSpace()
                    guard case .string(let k)? = value() else { return nil }
                    skipSpace()
                    guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { return nil }
                    at += 1
                    guard let v = value() else { return nil }
                    o[k] = v
                    skipSpace()
                    guard at < bytes.count else { return nil }
                    if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                    if bytes[at] == UInt8(ascii: "}") { at += 1; return .object(o) }
                    return nil
                }
            case UInt8(ascii: "["):
                at += 1
                var a: [KiCadJSON] = []
                skipSpace()
                if at < bytes.count, bytes[at] == UInt8(ascii: "]") {
                    at += 1
                    return .array(a)
                }
                while true {
                    guard let v = value() else { return nil }
                    a.append(v)
                    skipSpace()
                    guard at < bytes.count else { return nil }
                    if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                    if bytes[at] == UInt8(ascii: "]") { at += 1; return .array(a) }
                    return nil
                }
            case UInt8(ascii: "\""):
                at += 1
                var scalars = String.UnicodeScalarView()
                var raw: [UInt8] = []
                func flush() {
                    scalars.append(contentsOf: String(decoding: raw, as: UTF8.self).unicodeScalars)
                    raw.removeAll()
                }
                while at < bytes.count {
                    let c = bytes[at]
                    at += 1
                    if c == UInt8(ascii: "\"") {
                        flush()
                        return .string(String(scalars))
                    }
                    if c != UInt8(ascii: "\\") {
                        raw.append(c)
                        continue
                    }
                    flush()
                    guard at < bytes.count else { return nil }
                    let e = bytes[at]
                    at += 1
                    switch e {
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "u"):
                        guard let hi = hex4() else { return nil }
                        var code = hi
                        if (0xD800..<0xDC00).contains(hi), at + 1 < bytes.count, bytes[at] == UInt8(ascii: "\\"),
                           bytes[at + 1] == UInt8(ascii: "u") {
                            at += 2
                            guard let lo = hex4() else { return nil }
                            code = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                        }
                        if let s = Unicode.Scalar(code) { scalars.append(s) }
                    default: scalars.append(Unicode.Scalar(e))
                    }
                }
                return nil
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            default:
                let start = at
                var isDouble = false
                while at < bytes.count, "+-0123456789.eE".utf8.contains(bytes[at]) {
                    if [UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E")].contains(bytes[at]) { isDouble = true }
                    at += 1
                }
                let text = String(decoding: bytes[start..<at], as: UTF8.self)
                if !isDouble, let i = Int64(text) { return .integer(i) }
                return Double(text).map { .double($0) }
            }
        }

        mutating func hex4() -> UInt32? {
            guard at + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[at..<at + 4], as: UTF8.self), radix: 16) else { return nil }
            at += 4
            return v
        }

        mutating func literal(_ word: String, _ v: KiCadJSON) -> KiCadJSON? {
            let w = Array(word.utf8)
            guard at + w.count <= bytes.count, Array(bytes[at..<at + w.count]) == w else { return nil }
            at += w.count
            return v
        }
    }
}

// MARK: - KiCad's layers

/// KiCad 10's board layers by their ids (PCB_LAYER_ID: copper on the even numbers, F.Cu 0, B.Cu 2, In1.Cu 4...; the
/// others on the odd ones), and sets of them (LSET)
public enum KiCadLayers {
    /// LSET::Name: each id's canonical name
    public static let names: [Int: String] = {
        var n: [Int: String] = [0: "F.Cu", 2: "B.Cu", 1: "F.Mask", 3: "B.Mask", 5: "F.SilkS", 7: "B.SilkS", 9: "F.Adhes",
                                11: "B.Adhes", 13: "F.Paste", 15: "B.Paste", 17: "Dwgs.User", 19: "Cmts.User",
                                21: "Eco1.User", 23: "Eco2.User", 25: "Edge.Cuts", 27: "Margin", 29: "B.CrtYd",
                                31: "F.CrtYd", 33: "B.Fab", 35: "F.Fab", 37: "Rescue"]
        for i in 1...30 { n[2 + 2 * i] = "In\(i).Cu" }
        for i in 1...45 { n[37 + 2 * i] = "User.\(i)" }
        return n
    }()

    public static let ids: [String: Int] = Dictionary(uniqueKeysWithValues: names.map { ($1, $0) })

    public static func isCopper(_ id: Int) -> Bool { id >= 0 && id < 64 && id % 2 == 0 }

    /// Where a copper layer is in the board's stack, top to bottom (CuStack's order: F.Cu, the inner ones, B.Cu)
    public static func stackOrder(_ id: Int) -> Int { id == 0 ? 0 : id == 2 ? 1000 : id }

    /// The layers a board has (its layers table: BOARD::GetEnabledLayers), by id, and its own names for them
    /// (BOARD::GetLayerName: the user's name, else the canonical one)
    public static func enabled(_ board: KiCadBoard) -> [(id: Int, name: String, canonical: String)] {
        (board.root["layers"]?.items ?? []).compactMap { entry in
            guard let id = entry.number(at: 0).map({ Int($0) }) ?? entry.text(at: 0).flatMap({ Int($0) }),
                  let canonical = entry.text(at: 1) else { return nil }
            let user = entry.text(at: 3) ?? ""
            return (id, user.isEmpty ? canonical : user, canonical)
        }
    }

    /// The layers the Appearance panel lists, in its order (APPEARANCE_CONTROLS::rebuildLayers): the copper layers top
    /// to bottom, then the board's others in its order of them, each with its tooltip
    public static func appearanceOrder(_ enabled: [Int]) -> [(id: Int, tooltip: String)] {
        let set = Set(enabled)
        let copper = enabled.filter(isCopper).sorted { stackOrder($0) < stackOrder($1) }.map { id -> (Int, String) in
            (id, id == 0 ? "Front copper layer" : id == 2 ? "Back copper layer" : "Inner copper layer")
        }
        var others: [(Int, String)] = [(9, "Adhesive on board's front"), (11, "Adhesive on board's back"),
                                       (13, "Solder paste on board's front"), (15, "Solder paste on board's back"),
                                       (5, "Silkscreen on board's front"), (7, "Silkscreen on board's back"),
                                       (1, "Solder mask on board's front"), (3, "Solder mask on board's back"),
                                       (17, "Explanatory drawings"), (19, "Explanatory comments"), (21, "User defined meaning"),
                                       (23, "User defined meaning"), (25, "Board's perimeter definition"),
                                       (27, "Board's edge setback outline"), (31, "Footprint courtyards on board's front"),
                                       (29, "Footprint courtyards on board's back"), (35, "Footprint assembly on board's front"),
                                       (33, "Footprint assembly on board's back")]
        for i in 1...45 { others.append((37 + 2 * i, "User defined layer \(i)")) }
        return copper + others.filter { set.contains($0.0) }
    }

    /// A set of layers (LSET, of KiCad's 128): their ids
    public struct Set128: Equatable, Hashable, Sendable {
        public var low: UInt64
        public var high: UInt64

        public init(low: UInt64 = 0, high: UInt64 = 0) { (self.low, self.high) = (low, high) }

        public init(_ ids: [Int]) {
            self.init()
            for id in ids { insert(id) }
        }

        /// Every layer (LSET::AllLayersMask)
        public static let all = Set128(low: .max, high: .max)

        public func contains(_ id: Int) -> Bool {
            guard id >= 0 && id < 128 else { return false }
            return id < 64 ? low & (1 << UInt64(id)) != 0 : high & (1 << UInt64(id - 64)) != 0
        }

        public mutating func insert(_ id: Int) {
            guard id >= 0 && id < 128 else { return }
            if id < 64 { low |= 1 << UInt64(id) } else { high |= 1 << UInt64(id - 64) }
        }

        public mutating func remove(_ id: Int) {
            guard id >= 0 && id < 128 else { return }
            if id < 64 { low &= ~(1 << UInt64(id)) } else { high &= ~(1 << UInt64(id - 64)) }
        }

        public mutating func set(_ id: Int, _ on: Bool) { if on { insert(id) } else { remove(id) } }

        /// FmtHex: the bits from the highest down, in hexadecimal, an underscore between each eight digits
        public var hex: String {
            let text = String(format: "%016llx%016llx", high, low)
            let chars = Array(text)
            return stride(from: 0, to: 32, by: 8).map { String(chars[$0..<$0 + 8]) }.joined(separator: "_")
        }

        /// ParseHex: the digits from the end (lowest) back, underscores passed over, up to the first that is not
        /// one; nil where there is none (the set left as it was)
        public init?(hex: String) {
            var bits = Set128()
            var nibble = 0
            var consumed = 0
            for c in hex.reversed() {
                if c == "_" {
                    consumed += 1
                    continue
                }
                guard let v = c.hexDigitValue else { break }
                consumed += 1
                for b in 0..<4 where v & (1 << b) != 0 { bits.insert(nibble * 4 + b) }
                nibble += 1
                if nibble * 4 >= 128 { break }
            }
            guard consumed > 0 else { return nil }
            self = bits
        }
    }
}

// MARK: - The board's appearance

/// The board's appearance as KiCad's PCB editor keeps it for each board, in its project's local settings (the
/// .kicad_prl's "board": PROJECT_LOCAL_SETTINGS, which the Appearance panel and the display options read and write)
public struct KiCadBoardAppearance: Equatable, Sendable {
    /// The objects the Appearance panel's Objects tab shows and hides (VISIBILITY_LAYER), in the order KiCad writes
    /// them (their GAL layers' order)
    public enum Item: String, CaseIterable, Sendable {
        case vias, footprintText = "footprint_text", footprintAnchors = "footprint_anchors", ratsnest, grid
        case footprintsFront = "footprints_front", footprintsBack = "footprints_back", footprintValues = "footprint_values"
        case footprintReferences = "footprint_references", tracks, drcErrors = "drc_errors", drawingSheet = "drawing_sheet"
        case bitmaps, pads, zones, drcWarnings = "drc_warnings", drcExclusions = "drc_exclusions"
        case lockedItemShadows = "locked_item_shadows", conflictShadows = "conflict_shadows", shapes
        case boardOutlineArea = "board_outline_area", points = "ly_points"
    }

    /// HIGH_CONTRAST_MODE: inactive layers shown as they are, dimmed, or hidden
    public enum HighContrast: Int, Sendable { case normal = 0, dimmed = 1, hidden = 2 }

    /// The layers shown (LSET, by id: a layer the board has is shown if it is in it)
    public var visibleLayers = KiCadLayers.Set128.all
    public var visibleItems = Set(Item.allCases)
    /// The layer worked on (a KiCad id, the board's front copper by default)
    public var activeLayer = 0
    public var activeLayerPreset = ""
    public var highContrast = HighContrast.normal
    /// NET_COLOR_MODE: 0 off, 1 the ratsnest only, 2 everything
    public var netColorMode = 1
    public var autoTrackWidth = true
    /// ZONE_DISPLAY_MODE: 0 filled, 1 outlines, 2 fractured, 3 triangulated
    public var zoneDisplayMode = 0
    public var prototypeZoneFills = false
    public var trackOpacity = 1.0, viaOpacity = 1.0, padOpacity = 1.0, zoneOpacity = 0.6, imageOpacity = 0.6, shapeOpacity = 1.0
    public var hiddenNets: [String] = []
    /// The net classes whose ratsnest is hidden (kept sorted, a set)
    public var hiddenNetclasses: [String] = []
    /// The selection filter: lockedItems, footprints, text, tracks, vias, pads, graphics, zones, keepouts, dimensions,
    /// otherItems
    public var selectionFilter: [String: Bool] = KiCadBoardAppearance.defaultSelectionFilter

    public static let defaultSelectionFilter: [String: Bool] = [
        "lockedItems": false, "footprints": true, "text": true, "tracks": true, "vias": true, "pads": true,
        "graphics": true, "zones": true, "keepouts": true, "dimensions": true, "otherItems": true,
    ]

    public init() {}

    public func isVisible(_ item: Item) -> Bool { visibleItems.contains(item) }

    /// BOARD::IsLayerVisible: a layer the board has, and shown
    public func isLayerVisible(_ id: Int, enabled: Set<Int>) -> Bool { enabled.contains(id) && visibleLayers.contains(id) }

    /// As KiCad reads it from the local settings' JSON (each setting its default where the file has none or one of
    /// another kind; an enum's outside its range)
    public init(json: KiCadJSON?) {
        let b = json?["board"]
        if let s = b?["visible_layers"]?.string, let set = KiCadLayers.Set128(hex: s) { visibleLayers = set }
        // (an empty or missing list is every object shown; "none" alone is none)
        if let list = b?["visible_items"]?.array, !list.isEmpty {
            var visible = Set<Item>()
            var none = false
            for entry in list {
                guard let s = entry.string else { continue }
                if let item = Item.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(s) == .orderedSame }) {
                    visible.insert(item)
                } else if s == "none" {
                    none = true
                }
            }
            visibleItems = visible.isEmpty && !none ? Set(Item.allCases) : visible
        }
        func enumValue(_ key: String, _ lo: Int, _ hi: Int, _ fallback: Int) -> Int {
            guard let v = b?[key]?.int else { return fallback }
            return v >= lo && v <= hi ? v : fallback
        }
        activeLayer = enumValue("active_layer", 0, 35, 0)
        activeLayerPreset = b?["active_layer_preset"]?.string ?? ""
        highContrast = HighContrast(rawValue: enumValue("high_contrast_mode", 0, 2, 0)) ?? .normal
        netColorMode = enumValue("net_color_mode", 0, 2, 1)
        autoTrackWidth = b?["auto_track_width"]?.bool ?? true
        zoneDisplayMode = enumValue("zone_display_mode", 0, 3, 0)
        prototypeZoneFills = b?["prototype_zone_fills"]?.bool ?? false
        let o = b?["opacity"]
        trackOpacity = o?["tracks"]?.number ?? 1.0
        viaOpacity = o?["vias"]?.number ?? 1.0
        padOpacity = o?["pads"]?.number ?? 1.0
        zoneOpacity = o?["zones"]?.number ?? 0.6
        imageOpacity = o?["images"]?.number ?? 0.6
        shapeOpacity = o?["shapes"]?.number ?? 1.0
        hiddenNets = (b?["hidden_nets"]?.array ?? []).compactMap(\.string)
        hiddenNetclasses = Array(Set((b?["hidden_netclasses"]?.array ?? []).compactMap(\.string))).sorted {
            $0.compare($1, options: .literal) == .orderedAscending
        }
        if case .object(let f)? = b?["selection_filter"], !f.isEmpty {
            for (k, v) in f where selectionFilter[k] != nil { if let on = v.bool { selectionFilter[k] = on } }
        }
    }

    /// The local settings' "board" as KiCad writes it
    public var json: KiCadJSON {
        var visible = Item.allCases.filter(visibleItems.contains).map { KiCadJSON.string($0.rawValue) }
        // (an explicit marker to tell a list wiped out from one of nothing shown)
        if visible.isEmpty { visible = [.string("none")] }
        return .object([
            "visible_layers": .string(visibleLayers.hex),
            "visible_items": .array(visible),
            "selection_filter": .object(selectionFilter.mapValues { .bool($0) }),
            "active_layer": .integer(Int64(activeLayer)),
            "active_layer_preset": .string(activeLayerPreset),
            "high_contrast_mode": .integer(Int64(highContrast.rawValue)),
            "opacity": .object(["tracks": .double(trackOpacity), "vias": .double(viaOpacity), "pads": .double(padOpacity),
                                "zones": .double(zoneOpacity), "images": .double(imageOpacity), "shapes": .double(shapeOpacity)]),
            "hidden_nets": .array(hiddenNets.map { .string($0) }),
            "hidden_netclasses": .array(hiddenNetclasses.map { .string($0) }),
            "net_color_mode": .integer(Int64(netColorMode)),
            "auto_track_width": .bool(autoTrackWidth),
            "zone_display_mode": .integer(Int64(zoneDisplayMode)),
            "prototype_zone_fills": .bool(prototypeZoneFills),
        ])
    }

    // MARK: Layer presets

    /// The Appearance panel's built-in layer presets (APPEARANCE_CONTROLS' presetAllLayers... presetBackAssembly):
    /// their names, layers, and whether they show the board from underneath; the assembly views show the default
    /// objects too, and make their side's silkscreen the active layer
    public struct Preset: Sendable {
        public var name: String
        public var layers: KiCadLayers.Set128
        public var flipped: Bool
        public var assembly = false
        public var activeLayer: Int?
    }

    public static let presets: [Preset] = {
        let allCu = KiCadLayers.Set128([0, 2] + (1...30).map { 2 + 2 * $0 })
        let innerCu = KiCadLayers.Set128((1...30).map { 2 + 2 * $0 })
        func plus(_ s: KiCadLayers.Set128, _ ids: [Int]) -> KiCadLayers.Set128 {
            var r = s
            for id in ids { r.insert(id) }
            return r
        }
        // (LSET::FrontMask: front copper and technical layers; FrontAssembly: silkscreen, mask, fab, courtyard)
        let front = KiCadLayers.Set128([0, 9, 13, 5, 1, 31, 35])
        let back = KiCadLayers.Set128([2, 11, 15, 7, 3, 29, 33])
        return [
            Preset(name: "All Layers", layers: .all, flipped: false),
            Preset(name: "No Layers", layers: KiCadLayers.Set128(), flipped: false),
            Preset(name: "All Copper Layers", layers: plus(allCu, [25]), flipped: false),
            Preset(name: "Inner Copper Layers", layers: plus(innerCu, [25]), flipped: false),
            Preset(name: "Front Layers", layers: plus(front, [25]), flipped: false),
            Preset(name: "Front Assembly View", layers: KiCadLayers.Set128([5, 1, 35, 31, 25]), flipped: false, assembly: true,
                   activeLayer: 5),
            Preset(name: "Back Layers", layers: plus(back, [25]), flipped: true),
            Preset(name: "Back Assembly View", layers: KiCadLayers.Set128([7, 3, 33, 29, 25]), flipped: true, assembly: true,
                   activeLayer: 7),
        ]
    }()
}

/// A project's local settings (its .kicad_prl: PROJECT_LOCAL_SETTINGS) as KiCad reads and writes them: the board's
/// appearance, and the rest of the file kept as it was
public struct KiCadLocalSettings: Equatable, Sendable {
    /// The file as read (or nothing), which KiCad writes the settings into and keeps the rest of
    public var original: KiCadJSON
    public var board: KiCadBoardAppearance

    public init(text: String? = nil) {
        original = text.flatMap(KiCadJSON.init(text:)) ?? .object([:])
        if case .object = original {} else { original = .object([:]) }
        board = KiCadBoardAppearance(json: original)
    }

    /// The settings that are not the board's, as KiCad writes them where the file has none (their defaults), or as the
    /// file has them
    static func defaults() -> KiCadJSON {
        .object([
            "git": .object(["integration_disabled": .bool(false), "repo_type": .string(""), "repo_username": .string(""),
                            "ssh_key": .string("")]),
            "net_inspector_panel": .object([
                "col_hidden": .array([]), "col_order": .array([]), "col_widths": .array([]), "custom_group_rules": .array([]),
                "expanded_rows": .array([]), "filter_by_net_name": .bool(true), "filter_by_netclass": .bool(true),
                "filter_text": .string(""), "group_by_constraint": .bool(false), "group_by_netclass": .bool(false),
                "show_time_domain_details": .bool(false), "show_unconnected_nets": .bool(false),
                "show_zero_pad_nets": .bool(false), "sort_ascending": .bool(true), "sorting_column": .integer(-1),
            ]),
            "open_jobsets": .array([]),
            "project": .object(["files": .array([])]),
            "schematic": .object([
                "hierarchy_collapsed": .array([]),
                "selection_filter": .object(["graphics": .bool(true), "images": .bool(true), "labels": .bool(true),
                                             "lockedItems": .bool(false), "otherItems": .bool(true), "pins": .bool(true),
                                             "ruleAreas": .bool(true), "symbols": .bool(true), "text": .bool(true),
                                             "wires": .bool(true)]),
            ]),
        ])
    }

    /// The file's text as KiCad writes it for the project `name` (PROJECT_LOCAL_SETTINGS::SaveToFile): the file as
    /// read with every setting written into it (the board's as they now are, the others as the file had them or their
    /// defaults), meta.filename the project's and meta.version 5, dumped as nlohmann dumps it, a newline after
    public func text(projectName name: String) -> String {
        var out = original
        var settings = Self.defaults()
        // (the settings this port does not change keep what the file had, value by value as KiCad's parameters read
        // and write them back)
        for (section, value) in Self.passThrough(original) { settings[path: section] = value }
        settings["board"] = board.json
        settings["meta"] = .object(["filename": .string(name + ".kicad_prl"), "version": .integer(5)])
        out.merge(settings)
        return out.dump() + "\n"
    }

    /// The other settings as KiCad reads and writes them back: each value the file has, where it is of the kind KiCad
    /// reads (else KiCad's default)
    static func passThrough(_ json: KiCadJSON) -> [(String, KiCadJSON)] {
        var out: [(String, KiCadJSON)] = []
        let d = defaults()
        func keep(_ path: String, _ ok: (KiCadJSON) -> Bool) {
            if let v = json[path: path], ok(v) { out.append((path, v)) }
        }
        func isString(_ v: KiCadJSON) -> Bool { v.string != nil }
        func isBool(_ v: KiCadJSON) -> Bool { v.bool != nil }
        func isArray(_ v: KiCadJSON) -> Bool { v.array != nil }
        for key in ["repo_username", "repo_type", "ssh_key"] { keep("git." + key, isString) }
        keep("git.integration_disabled", isBool)
        if case .object(let p)? = d["net_inspector_panel"] {
            for (k, v) in p {
                switch v {
                case .bool: keep("net_inspector_panel." + k, isBool)
                case .string: keep("net_inspector_panel." + k, isString)
                case .array: keep("net_inspector_panel." + k, isArray)
                default: keep("net_inspector_panel." + k) { $0.int != nil }
                }
            }
        }
        keep("open_jobsets", isArray)
        keep("project.files", isArray)
        keep("schematic.hierarchy_collapsed", isArray)
        if case .object(let f)? = json[path: "schematic.selection_filter"], !f.isEmpty,
           case .object(var filter)? = d[path: "schematic.selection_filter"] {
            for (k, v) in f where filter[k] != nil && v.bool != nil { filter[k] = v }
            out.append(("schematic.selection_filter", .object(filter)))
        }
        return out
    }
}

// MARK: - The colour theme

/// KiCad 10's default colour theme ("KiCad Default", builtin_color_themes.h), its board's colours: red, green, blue
/// and alpha from 0 to 1
public enum KiCadColorTheme {
    public typealias RGBA = (r: Double, g: Double, b: Double, a: Double)

    static func css(_ r: Int, _ g: Int, _ b: Int, _ a: Double) -> RGBA { (Double(r) / 255, Double(g) / 255, Double(b) / 255, a) }

    static let layers: [Int: RGBA] = {
        var c: [Int: RGBA] = [
            0: css(200, 52, 52, 1), 2: css(77, 127, 196, 1),
            11: css(0, 0, 132, 1), 9: css(132, 0, 132, 1), 15: css(0, 194, 194, 0.9), 13: css(180, 160, 154, 0.9),
            7: css(232, 178, 167, 1), 5: css(242, 237, 161, 1), 3: css(2, 255, 238, 0.4), 1: css(216, 100, 255, 0.4),
            17: css(194, 194, 194, 1), 19: css(89, 148, 220, 1), 21: css(180, 219, 210, 1), 23: css(216, 200, 82, 1),
            25: css(208, 210, 205, 1), 27: css(255, 38, 226, 1), 29: css(38, 233, 255, 1), 31: css(255, 38, 226, 1),
            33: css(88, 93, 132, 1), 35: css(175, 175, 175, 1),
        ]
        let inner: [RGBA] = [css(127, 200, 127, 1), css(206, 125, 44, 1), css(79, 203, 203, 1), css(219, 98, 139, 1),
                             css(167, 165, 198, 1), css(40, 204, 217, 1), css(232, 178, 167, 1), css(242, 237, 161, 1),
                             css(141, 203, 129, 1), css(237, 124, 51, 1), css(91, 195, 235, 1), css(247, 111, 142, 1),
                             css(167, 165, 198, 1), css(40, 204, 217, 1), css(232, 178, 167, 1), css(242, 237, 161, 1),
                             css(237, 124, 51, 1), css(91, 195, 235, 1), css(247, 111, 142, 1), css(167, 165, 198, 1),
                             css(40, 204, 217, 1), css(232, 178, 167, 1), css(242, 237, 161, 1), css(237, 124, 51, 1),
                             css(91, 195, 235, 1), css(247, 111, 142, 1), css(167, 165, 198, 1), css(40, 204, 217, 1),
                             css(232, 178, 167, 1), css(242, 237, 161, 1)]
        for (i, col) in inner.enumerated() { c[4 + 2 * i] = col }
        let user: [RGBA] = [css(194, 194, 194, 1), css(89, 148, 220, 1), css(180, 219, 210, 1), css(216, 200, 82, 1)]
        for i in 1...45 {
            // (User.9 the one of another colour)
            c[37 + 2 * i] = i == 9 ? css(232, 178, 167, 1) : user[(i - 1) % 4]
        }
        return c
    }()

    /// A board layer's colour (COLOR_SETTINGS::GetColor of the default theme), by id
    public static func layer(_ id: Int) -> RGBA { layers[id] ?? css(194, 194, 194, 1) }

    /// The colours of the objects the theme has, by the Appearance panel's names for them
    public static let background = css(0, 16, 35, 1)
    public static let ratsnest = css(0, 248, 255, 0.35)
    public static let viaHoles = css(227, 183, 46, 1)
    public static let viaHoleWalls = css(236, 236, 236, 1)
    public static let padPlatedHoles = css(194, 194, 0, 1)
    public static let nonPlatedHoles = css(26, 196, 210, 1)
    public static let drcError = css(215, 91, 107, 0.8)
    public static let drcWarning = css(255, 208, 66, 0.8)
    public static let drcExclusion = css(255, 255, 255, 0.8)
    public static let anchor = css(255, 38, 226, 1)
    public static let lockedShadow = css(255, 38, 226, 0.5)
    public static let conflictsShadow = css(255, 0, 5, 0.5)
    public static let boardOutlineArea = css(100, 100, 100, 0.35)
    public static let grid = css(132, 132, 132, 1)
    public static let drawingSheet = css(200, 114, 171, 1)
    public static let points = css(255, 38, 226, 1)
    public static let selectOverlay = css(4, 255, 67, 1)

    /// The colour an object of the Objects tab is shown in by its swatch (those the theme gives one)
    public static func item(_ item: KiCadBoardAppearance.Item) -> RGBA? {
        switch item {
        case .ratsnest: return ratsnest
        case .drcErrors: return drcError
        case .drcWarnings: return drcWarning
        case .drcExclusions: return drcExclusion
        case .footprintAnchors: return anchor
        case .lockedItemShadows: return lockedShadow
        case .conflictShadows: return conflictsShadow
        case .boardOutlineArea: return boardOutlineArea
        case .grid: return grid
        case .drawingSheet: return drawingSheet
        case .points: return points
        default: return nil
        }
    }

    // MARK: How PCB_RENDER_SETTINGS::GetColor changes a colour

    /// COLOR4D::Brightened
    public static func brightened(_ c: RGBA, _ f: Double) -> RGBA { (c.r * (1 - f) + f, c.g * (1 - f) + f, c.b * (1 - f) + f, c.a) }
    /// COLOR4D::Darkened
    public static func darkened(_ c: RGBA, _ f: Double) -> RGBA { (c.r * (1 - f), c.g * (1 - f), c.b * (1 - f), c.a) }
    /// COLOR4D::Mix: `f` of the colour kept, the rest the other's
    public static func mix(_ c: RGBA, _ other: RGBA, _ f: Double) -> RGBA {
        (other.r * (1 - f) + c.r * f, other.g * (1 - f) + c.g * f, other.b * (1 - f) + c.b * f, c.a)
    }

    /// RENDER_SETTINGS' m_highlightFactor
    public static let highlightFactor = 0.5
    /// PCB_RENDER_SETTINGS' m_hiContrastFactor: 1 less the common settings' hicontrast_dimming_factor (0.8)
    public static let hiContrastFactor = 1.0 - 0.8
}
