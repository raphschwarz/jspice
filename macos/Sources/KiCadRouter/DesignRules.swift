// Ported from KiCad 10.0.7: pcbnew/drc/drc_rule_parser.cpp (DRC_RULES_PARSER: a .kicad_dru's version, its rules, their
// layers, conditions, constraints, values with units and severities), common/drc_rules.keywords (its keywords),
// common/dsnlexer.cpp (DSNLEXER::NextTok: how the file is cut into tokens, isNumber, isSpace),
// pcbnew/drc/drc_rule.h and drc_rule.cpp (DRC_RULE, DRC_CONSTRAINT, DRC_CONSTRAINT_T, DRC_DISALLOW_T),
// libs/core/include/core/minoptmax.h (MINOPTMAX), include/layer_ids.h and common/lset.cpp (PCB_LAYER_ID, LSET::Name,
// the masks), common/layer_id.cpp (LayerName) and common/string_utils.cpp (WildCompareString); and, for the
// wildcards KiCad's rules match names with, wxWidgets 3.2's wxString::Matches (src/common/string.cpp).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt; Copyright the wxWidgets team (wxString::Matches).
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// KiCad's DRC_CONSTRAINT_T: what a rule's constraint constrains
public enum DRCConstraintType: Int, Sendable, CaseIterable {
    case null = 0, clearance, creepage, holeClearance, holeToHole, edgeClearance, holeSize, courtyardClearance,
         silkClearance, textHeight, textThickness, trackWidth, trackSegmentLength, annularWidth, zoneConnection,
         thermalReliefGap, thermalSpokeWidth, minResolvedSpokes, solderMaskExpansion, solderPasteAbsMargin,
         solderPasteRelMargin, disallow, viaDiameter, length, skew, diffPairGap, maxUncoupled, diffPairIntraSkew,
         viaCount, physicalClearance, physicalHoleClearance, assertion, connectionWidth, trackAngle, viaDangling,
         bridgedMask, solderMaskSliver

    /// The constraint's keyword in a rules file
    var keyword: String {
        switch self {
        case .null: return "null"
        case .clearance: return "clearance"
        case .creepage: return "creepage"
        case .holeClearance: return "hole_clearance"
        case .holeToHole: return "hole_to_hole"
        case .edgeClearance: return "edge_clearance"
        case .holeSize: return "hole_size"
        case .courtyardClearance: return "courtyard_clearance"
        case .silkClearance: return "silk_clearance"
        case .textHeight: return "text_height"
        case .textThickness: return "text_thickness"
        case .trackWidth: return "track_width"
        case .trackSegmentLength: return "track_segment_length"
        case .annularWidth: return "annular_width"
        case .zoneConnection: return "zone_connection"
        case .thermalReliefGap: return "thermal_relief_gap"
        case .thermalSpokeWidth: return "thermal_spoke_width"
        case .minResolvedSpokes: return "min_resolved_spokes"
        case .solderMaskExpansion: return "solder_mask_expansion"
        case .solderPasteAbsMargin: return "solder_paste_abs_margin"
        case .solderPasteRelMargin: return "solder_paste_rel_margin"
        case .disallow: return "disallow"
        case .viaDiameter: return "via_diameter"
        case .length: return "length"
        case .skew: return "skew"
        case .diffPairGap: return "diff_pair_gap"
        case .maxUncoupled: return "diff_pair_uncoupled"
        case .diffPairIntraSkew: return "diff_pair_intra_skew"
        case .viaCount: return "via_count"
        case .physicalClearance: return "physical_clearance"
        case .physicalHoleClearance: return "physical_hole_clearance"
        case .assertion: return "assertion"
        case .connectionWidth: return "connection_width"
        case .trackAngle: return "track_angle"
        case .viaDangling: return "via_dangling"
        case .bridgedMask: return "bridged_mask"
        case .solderMaskSliver: return "solder_mask_sliver"
        }
    }
}

/// KiCad's MINOPTMAX<int>: a constraint's least, best and greatest values, each set or not (an unset least reads as
/// 0, an unset greatest as the largest int, an unset best as the least)
public struct MinOptMax: Sendable, Equatable {
    public private(set) var hasMin = false, hasOpt = false, hasMax = false
    private var minValue = 0, optValue = 0, maxValue = 0
    public private(set) var isNull = true

    public init() {}

    public var min: Int { hasMin ? minValue : 0 }
    public var max: Int { hasMax ? maxValue : Int(Int32.max) }
    public var opt: Int { hasOpt ? optValue : min }

    public mutating func setMin(_ v: Int) { (isNull, minValue, hasMin) = (false, v, true) }
    public mutating func setMax(_ v: Int) { (isNull, maxValue, hasMax) = (false, v, true) }
    public mutating func setOpt(_ v: Int) { (isNull, optValue, hasOpt) = (false, v, true) }
}

/// DRC_DISALLOW_T: what a disallow constraint keeps out
public struct DisallowFlags: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let throughVias = DisallowFlags(rawValue: 1 << 0)
    public static let microVias = DisallowFlags(rawValue: 1 << 1)
    public static let blindVias = DisallowFlags(rawValue: 1 << 2)
    public static let buriedVias = DisallowFlags(rawValue: 1 << 3)
    public static let tracks = DisallowFlags(rawValue: 1 << 4)
    public static let pads = DisallowFlags(rawValue: 1 << 5)
    public static let zones = DisallowFlags(rawValue: 1 << 6)
    public static let texts = DisallowFlags(rawValue: 1 << 7)
    public static let graphics = DisallowFlags(rawValue: 1 << 8)
    public static let holes = DisallowFlags(rawValue: 1 << 9)
    public static let footprints = DisallowFlags(rawValue: 1 << 10)
    /// DRC_DISALLOW_VIAS: a keepout's vias (through vias only)
    public static let vias = DisallowFlags.throughVias
}

/// SEVERITY, as a rule may set it: RPT_SEVERITY_UNDEFINED where it does not
public enum RuleSeverity: String, Sendable {
    case undefined, error, warning, ignore, exclusion
}

/// DRC_IMPLICIT_SOURCE: where KiCad made an implicit rule from
enum ImplicitSource: Sendable {
    case none, boardSetup, barcodeDefaults, keepout, netClass, tuningProfile
}

/// ZONE_CONNECTION, inherited (from the pad's footprint or the zone) where nothing sets it
public enum RuleZoneConnection: Int, Sendable {
    case inherited = -1, none, thermal, full, thtThermal
}

/// A rule's constraint (DRC_CONSTRAINT)
public struct DRCConstraint {
    public var type: DRCConstraintType
    public var value = MinOptMax()
    public var disallowFlags: DisallowFlags = []
    public var zoneConnection: RuleZoneConnection = .inherited
    /// An assertion's test
    var test: RuleCondition?
    /// Whether the least value comes from an implicit rule (m_ImplicitMin)
    public var implicitMin = false
    /// The name of a constraint made on the spot ("board minimum", "net tie"...)
    var name = ""
    /// The rule it comes from
    var parentRule: DesignRule?
    /// within_diff_pairs (SKEW_WITHIN_DIFF_PAIRS), and whether its values are lengths or times
    var skewWithinDiffPairs = false
    var spaceDomain = false, timeDomain = false

    init(_ type: DRCConstraintType, name: String = "") {
        self.type = type
        self.name = name
    }

    /// GetName: an implicit rule's name, "rule 'NAME'" for one of the user's, else the name it was made with
    public var ruleName: String {
        if let p = parentRule { return p.isImplicit ? p.name : "rule '\(p.name)'" }
        return name
    }

    /// GetSeverity: the rule's severity, undefined where it comes from no rule
    public var severity: RuleSeverity { parentRule?.severity ?? .undefined }

    /// IsNull: no constraint of this type applies
    public var isNull: Bool { type == .null }
}

/// A design rule (DRC_RULE): its name, the layers it is on, its condition, its constraints and severity
final class DesignRule {
    var name = ""
    /// The layer clause as written ("outer", "inner", a layer's name), and the layers it covers (all where it has none)
    var layerSource = ""
    var layerCondition = KiLayerSet.all
    var condition: RuleCondition?
    var constraints: [DRCConstraint] = []
    var severity = RuleSeverity.undefined
    var implicitSource = ImplicitSource.none
    /// An implicit keepout rule's zone (its uuid), and the footprint it is of (m_ImplicitItem)
    var implicitZone: String?
    var implicitZoneFootprint: Int?

    init(name: String = "", implicit: ImplicitSource = .none) {
        self.name = name
        implicitSource = implicit
    }

    var isImplicit: Bool { implicitSource != .none }

    func add(_ constraint: DRCConstraint) {
        var c = constraint
        c.parentRule = self
        constraints.append(c)
    }

    func find(_ type: DRCConstraintType) -> DRCConstraint? { constraints.first { $0.type == type } }
}

// MARK: - Layers (PCB_LAYER_ID, LSET)

/// KiCad's board layers by their PCB_LAYER_ID numbers: copper even (F.Cu 0, B.Cu 2, In1.Cu 4...), the rest odd
public enum KiLayer {
    public static let fCu = 0, bCu = 2, in1Cu = 4
    public static let fMask = 1, bMask = 3, fSilkS = 5, bSilkS = 7, fAdhes = 9, bAdhes = 11, fPaste = 13, bPaste = 15
    public static let dwgsUser = 17, cmtsUser = 19, eco1User = 21, eco2User = 23, edgeCuts = 25, margin = 27
    public static let bCrtYd = 29, fCrtYd = 31, bFab = 33, fFab = 35, rescue = 37, user1 = 39
    public static let undefined = -1
    /// PCB_LAYER_ID_COUNT
    public static let count = 128

    /// IsCopperLayer
    public static func isCopper(_ l: Int) -> Bool { l >= 0 && l < count && l & 1 == 0 }

    /// LSET::Name: a layer's canonical name
    public static func name(_ l: Int) -> String {
        switch l {
        case fCu: return "F.Cu"
        case bCu: return "B.Cu"
        case bAdhes: return "B.Adhes"
        case fAdhes: return "F.Adhes"
        case bPaste: return "B.Paste"
        case fPaste: return "F.Paste"
        case bSilkS: return "B.SilkS"
        case fSilkS: return "F.SilkS"
        case bMask: return "B.Mask"
        case fMask: return "F.Mask"
        case dwgsUser: return "Dwgs.User"
        case cmtsUser: return "Cmts.User"
        case eco1User: return "Eco1.User"
        case eco2User: return "Eco2.User"
        case edgeCuts: return "Edge.Cuts"
        case margin: return "Margin"
        case fCrtYd: return "F.CrtYd"
        case bCrtYd: return "B.CrtYd"
        case fFab: return "F.Fab"
        case bFab: return "B.Fab"
        case rescue: return "Rescue"
        default:
            if l < 0 { return "UNDEFINED" }
            if l & 1 == 1 { return "User.\((l - rescue) / 2)" }
            return "In\((l - bCu) / 2).Cu"
        }
    }

    /// LayerName: the name KiCad shows of a layer (its standard user name)
    public static func displayName(_ l: Int) -> String {
        switch l {
        case -2, -1: return "undefined"
        case fCu: return "F.Cu"
        case bCu: return "B.Cu"
        case bAdhes: return "B.Adhesive"
        case fAdhes: return "F.Adhesive"
        case bPaste: return "B.Paste"
        case fPaste: return "F.Paste"
        case bSilkS: return "B.Silkscreen"
        case fSilkS: return "F.Silkscreen"
        case bMask: return "B.Mask"
        case fMask: return "F.Mask"
        case dwgsUser: return "User.Drawings"
        case cmtsUser: return "User.Comments"
        case eco1User: return "User.Eco1"
        case eco2User: return "User.Eco2"
        case edgeCuts: return "Edge.Cuts"
        case margin: return "Margin"
        case fCrtYd: return "F.Courtyard"
        case bCrtYd: return "B.Courtyard"
        case fFab: return "F.Fab"
        case bFab: return "B.Fab"
        case rescue: return "Rescue"
        default:
            if l > 0 && l < count && l & 1 == 1 { return "User.\((l - user1) / 2 + 1)" }
            return "In\((l - in1Cu) / 2 + 1).Cu"
        }
    }

    /// The layer of a canonical name, nil for none
    public static func id(_ name: String) -> Int? { byName[name] }

    private static let byName: [String: Int] = {
        var m: [String: Int] = [:]
        for l in 0..<count { m[KiLayer.name(l)] = l }
        return m
    }()

    /// A router layer's KiCad layer, of a board of `copperLayers` copper layers (0 F.Cu, the last B.Cu)
    public static func fromRouter(_ r: Int, copperLayers: Int) -> Int {
        if r == 0 { return fCu }
        if r >= copperLayers - 1 { return bCu }
        return bCu + 2 * r
    }

    /// A KiCad copper layer's router layer, nil for one the board does not have
    public static func toRouter(_ l: Int, copperLayers: Int) -> Int? {
        if l == fCu { return 0 }
        if l == bCu { return copperLayers - 1 }
        guard isCopper(l), l >= in1Cu else { return nil }
        let r = (l - bCu) / 2
        return r < copperLayers - 1 ? r : nil
    }
}

/// A set of KiCad's board layers (LSET), by PCB_LAYER_ID
public struct KiLayerSet: Hashable, Sendable {
    var lo: UInt64 = 0, hi: UInt64 = 0

    public init() {}

    public init<S: Sequence>(_ layers: S) where S.Element == Int {
        for l in layers { insert(l) }
    }

    public func contains(_ l: Int) -> Bool {
        guard l >= 0 && l < KiLayer.count else { return false }
        return l < 64 ? lo & (1 << UInt64(l)) != 0 : hi & (1 << UInt64(l - 64)) != 0
    }

    public mutating func insert(_ l: Int) {
        guard l >= 0 && l < KiLayer.count else { return }
        if l < 64 { lo |= 1 << UInt64(l) } else { hi |= 1 << UInt64(l - 64) }
    }

    public var isEmpty: Bool { lo == 0 && hi == 0 }
    public var count: Int { lo.nonzeroBitCount + hi.nonzeroBitCount }
    public func union(_ o: KiLayerSet) -> KiLayerSet { var s = self; s.lo |= o.lo; s.hi |= o.hi; return s }
    public func intersection(_ o: KiLayerSet) -> KiLayerSet { var s = self; s.lo &= o.lo; s.hi &= o.hi; return s }
    public func intersects(_ o: KiLayerSet) -> Bool { lo & o.lo != 0 || hi & o.hi != 0 }
    /// The layers in their numbers' order (LSET's iteration)
    public var layers: [Int] { (0..<KiLayer.count).filter(contains) }
    /// ExtractLayer: the one layer of a set of one, else UNDEFINED_LAYER
    public var extractLayer: Int { count == 1 ? layers[0] : KiLayer.undefined }

    /// AllLayersMask
    public static var all: KiLayerSet { var s = KiLayerSet(); s.lo = ~0; s.hi = ~0; return s }
    /// AllCuMask: every copper layer KiCad has (MAX_CU_LAYERS)
    public static let allCu = KiLayerSet(stride(from: 0, to: 64, by: 2))
    /// AllCuMask( count ): a board's copper layers
    public static func allCu(_ copperLayers: Int) -> KiLayerSet {
        var s = KiLayerSet([KiLayer.fCu, KiLayer.bCu])
        for i in 0..<max(0, copperLayers - 2) { s.insert(KiLayer.in1Cu + 2 * i) }
        return s
    }
    /// ExternalCuMask, InternalCuMask
    public static let externalCu = KiLayerSet([KiLayer.fCu, KiLayer.bCu])
    public static let internalCu = KiLayerSet(stride(from: KiLayer.in1Cu, to: 64, by: 2))
    public static let frontTech = KiLayerSet([KiLayer.fSilkS, KiLayer.fMask, KiLayer.fAdhes, KiLayer.fPaste, KiLayer.fCrtYd, KiLayer.fFab])
    public static let backTech = KiLayerSet([KiLayer.bSilkS, KiLayer.bMask, KiLayer.bAdhes, KiLayer.bPaste, KiLayer.bCrtYd, KiLayer.bFab])
    /// FrontMask, BackMask: a side's technical layers and its copper
    public static let front = frontTech.union(KiLayerSet([KiLayer.fCu]))
    public static let back = backTech.union(KiLayerSet([KiLayer.bCu]))
}

// MARK: - The rules file's tokens (DSNLEXER)

/// A .kicad_dru's tokens as KiCad's DSNLEXER cuts them (not in specctra mode, knowing '|')
struct RulesLexer {
    enum Token: Equatable {
        case none, eof, left, right, bar, symbol, number, string
        case keyword(String)
    }

    static let keywords: Set<String> = [
        "annular_width", "assertion", "assign_component_class", "board_edge", "bridged_mask", "blind_via", "buried_via",
        "clearance", "condition", "connection_width", "constraint", "courtyard_clearance", "creepage", "diff_pair_gap",
        "diff_pair_uncoupled", "disallow", "edge_clearance", "error", "exclusion", "footprint", "graphic", "hole",
        "hole_clearance", "hole_size", "hole_to_hole", "ignore", "inner", "layer", "length", "max",
        "mechanical_clearance", "mechanical_hole_clearance", "micro_via", "min", "min_resolved_spokes", "none", "npth",
        "opt", "outer", "pad", "pth", "physical_clearance", "physical_hole_clearance", "rule", "severity",
        "silk_clearance", "skew", "solder_mask_expansion", "solder_paste_abs_margin", "solder_paste_rel_margin",
        "solder_mask_sliver", "solid", "text", "text_height", "text_thickness", "thermal_reliefs", "thermal_relief_gap",
        "thermal_spoke_width", "through_via", "track", "track_angle", "track_width", "track_segment_length", "version",
        "via", "via_count", "via_dangling", "via_diameter", "warning", "within_diff_pairs", "zone", "zone_connection",
    ]

    private let lines: [[UInt8]]
    private var lineIndex = -1
    private var line: [UInt8] = []
    private var pos = 0
    private(set) var curTok = Token.none
    private(set) var curText = ""
    /// The whitespace before the token (CurSeparator)
    private(set) var curSeparator = ""
    private(set) var lineNumber = 0
    private(set) var offset = 0

    init(_ text: String) {
        // (LINE_READER: each line with its end)
        var out: [[UInt8]] = []
        var cur: [UInt8] = []
        for b in Array(text.utf8) {
            cur.append(b)
            if b == 0x0A {
                out.append(cur)
                cur = []
            }
        }
        if !cur.isEmpty { out.append(cur) }
        lines = out
    }

    /// isSpace: what the lexer skips (ASCII space, newline, carriage return, tab, nul)
    static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0 }

    private static func isSep(_ c: UInt8) -> Bool { isSpace(c) || c == 0x28 || c == 0x29 || c == 0x7C }

    /// isNumber: an integer, a fixed point or a float with an exponent, all of the token
    static func isNumber(_ s: [UInt8]) -> Bool {
        var i = 0
        var saw = false
        func digit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        if i < s.count && (s[i] == 0x2D || s[i] == 0x2B) { i += 1 }
        while i < s.count && digit(s[i]) { i += 1; saw = true }
        if i < s.count && s[i] == 0x2E {
            i += 1
            while i < s.count && digit(s[i]) { i += 1; saw = true }
        }
        if saw && i < s.count && (s[i] == 0x45 || s[i] == 0x65) {
            i += 1
            saw = false
            if i < s.count && (s[i] == 0x2D || s[i] == 0x2B) { i += 1 }
            while i < s.count && digit(s[i]) { i += 1; saw = true }
        }
        return saw && i == s.count
    }

    private mutating func readLine() -> Bool {
        lineIndex += 1
        guard lineIndex < lines.count else { return false }
        line = lines[lineIndex]
        lineNumber = lineIndex + 1
        pos = 0
        return true
    }

    /// NextTok
    @discardableResult
    mutating func next() throws -> Token {
        curSeparator = ""
        if curTok == .eof { return .eof }
        var sep: [UInt8] = []
        func finish(_ t: Token, _ start: Int) -> Token {
            curSeparator = String(decoding: sep, as: UTF8.self)
            curTok = t
            offset = start
            return t
        }
        while true {
            if pos >= line.count {
                guard readLine() else {
                    curText = ""
                    return finish(.eof, 0)
                }
                while pos < line.count && Self.isSpace(line[pos]) {
                    sep.append(line[pos])
                    pos += 1
                }
                // (a line whose first character is '#' is a comment)
                if pos < line.count && line[pos] == 0x23 {
                    pos = line.count
                    continue
                }
            } else {
                while pos < line.count && Self.isSpace(line[pos]) {
                    sep.append(line[pos])
                    pos += 1
                }
            }
            if pos < line.count { break }
        }
        let start = pos
        let c = line[pos]
        if c == 0x28 || c == 0x29 || c == 0x7C {
            curText = String(UnicodeScalar(c))
            pos += 1
            return finish(c == 0x28 ? .left : c == 0x29 ? .right : .bar, start)
        }
        if c == 0x22 {
            // a quoted string, its escapes deciphered
            var text: [UInt8] = []
            var head = pos + 1
            while head < line.count {
                if line[head] == 0x5C {
                    head += 1
                    guard head < line.count else { break }
                    let e = line[head]
                    head += 1
                    switch e {
                    case 0x22, 0x5C: text.append(e)
                    case 0x61: text.append(0x07)
                    case 0x62: text.append(0x08)
                    case 0x66: text.append(0x0C)
                    case 0x6E: text.append(0x0A)
                    case 0x72: text.append(0x0D)
                    case 0x74: text.append(0x09)
                    case 0x76: text.append(0x0B)
                    case 0x78:
                        var hex: [UInt8] = []
                        while hex.count < 2 && head + hex.count < line.count,
                              let _ = Int(String(UnicodeScalar(line[head + hex.count])), radix: 16) {
                            hex.append(line[head + hex.count])
                        }
                        text.append(hex.isEmpty ? 0x78 : UInt8(Int(String(decoding: hex, as: UTF8.self), radix: 16)!))
                        head += hex.count
                    default:
                        head -= 1
                        var oct: [UInt8] = []
                        while oct.count < 3 && head + oct.count < line.count && line[head + oct.count] >= 0x30 && line[head + oct.count] <= 0x37 {
                            oct.append(line[head + oct.count])
                        }
                        text.append(oct.isEmpty ? 0x5C : UInt8(truncatingIfNeeded: Int(String(decoding: oct, as: UTF8.self), radix: 8)!))
                        head += oct.count
                    }
                } else if line[head] == 0x22 {
                    curText = String(decoding: text, as: UTF8.self)
                    pos = head + 1
                    return finish(.string, start)
                } else {
                    text.append(line[head])
                    head += 1
                }
            }
            throw RulesError(message: "Unterminated delimited string", line: lineNumber, offset: start)
        }
        var text: [UInt8] = []
        while pos < line.count && !Self.isSep(line[pos]) {
            text.append(line[pos])
            pos += 1
        }
        curText = String(decoding: text, as: UTF8.self)
        if Self.isNumber(text) { return finish(.number, start) }
        return finish(Self.keywords.contains(curText) ? .keyword(curText) : .symbol, start)
    }

    /// IsSymbol: a symbol, a quoted string, or a keyword taken as one
    static func isSymbol(_ t: Token) -> Bool {
        switch t {
        case .symbol, .string, .keyword: return true
        default: return false
        }
    }

    /// GetCurStrAsToken: a quoted string taken as the keyword it spells
    var curStrAsToken: Token { Self.keywords.contains(curText) ? .keyword(curText) : .symbol }
}

/// A rules file KiCad would not take (its PARSE_ERROR): KiCad then goes by its implicit rules alone
struct RulesError: Error {
    var message: String
    var line = 0
    var offset = 0
}

// MARK: - The rules file (DRC_RULES_PARSER)

/// A .kicad_dru's rules as KiCad's DRC_RULES_PARSER reads them. Any error in it is KiCad's PARSE_ERROR (it reads the
/// file with no reporter, so each error throws), and KiCad then takes none of the file's rules.
struct DesignRulesParser {
    /// DRC_RULE_FILE_VERSION
    static let fileVersion = 1

    private var lex: RulesLexer
    private(set) var requiredVersion = 0
    private(set) var tooRecent = false

    init(_ text: String) { lex = RulesLexer(text) }

    private func error(_ message: String) -> RulesError {
        RulesError(message: message, line: lex.lineNumber, offset: lex.offset)
    }

    /// checkUnresolvedTextVariable: a "${" in the token (a component class selector, ${CLASS:...}, aside)
    private func checkUnresolvedTextVariable() throws {
        let t = lex.curText
        var search = t.startIndex
        while let r = t.range(of: "${", range: search..<t.endIndex) {
            if let end = t.range(of: "}", range: r.upperBound..<t.endIndex),
               t[r.upperBound..<end.lowerBound].uppercased().hasPrefix("CLASS:") {
                search = r.upperBound
                continue
            }
            throw error("Unresolved text variable")
        }
    }

    /// expected: the token is not one the parser can take here
    private func expected(_ what: String) -> RulesError {
        if lex.curText.hasPrefix("${") { return error("Unresolved text variable.") }
        return error("Unrecognized item '\(lex.curText)'. Expected \(what).")
    }

    /// Parse
    mutating func parse() throws -> [DesignRule] {
        var rules: [DesignRule] = []
        var haveVersion = false
        var token = try lex.next()
        while token != .eof {
            try checkUnresolvedTextVariable()
            if token != .left { throw error("Missing '('.") }
            token = try lex.next()
            if !haveVersion && token != .keyword("version") { throw error("Missing version statement.") }
            switch token {
            case .keyword("version"):
                haveVersion = true
                token = try lex.next()
                if token == .right {
                    throw error("Missing version number.")
                } else if token == .number {
                    requiredVersion = Self.strtol(lex.curText)
                    tooRecent = requiredVersion > Self.fileVersion
                    if try lex.next() != .right { throw error("Missing ')'.") }
                } else {
                    throw expected("version number")
                }
            case .keyword("rule"):
                rules.append(try parseRule())
            case .eof:
                throw error("Incomplete statement.")
            default:
                throw expected("rule or version")
            }
            token = try lex.next()
        }
        return rules
    }

    /// strtol( text, nullptr, 10 ) of a number token: its leading integer
    static func strtol(_ s: String) -> Int {
        var digits = ""
        for (i, ch) in s.enumerated() {
            if ch.isASCII && ch.isNumber || (i == 0 && (ch == "-" || ch == "+")) { digits.append(ch) } else { break }
        }
        return Int(digits) ?? 0
    }

    /// parseDRC_RULE
    private mutating func parseRule() throws -> DesignRule {
        let rule = DesignRule()
        var token = try lex.next()
        if !RulesLexer.isSymbol(token) { throw error("Missing rule name.") }
        try checkUnresolvedTextVariable()
        rule.name = lex.curText
        token = try lex.next()
        while token != .right && token != .eof {
            try checkUnresolvedTextVariable()
            if token != .left { throw error("Missing '('.") }
            token = try lex.next()
            switch token {
            case .keyword("constraint"):
                try parseConstraint(rule)
            case .keyword("condition"):
                token = try lex.next()
                if token == .right {
                    throw error("Missing condition expression.")
                } else if RulesLexer.isSymbol(token) {
                    try checkUnresolvedTextVariable()
                    let condition = RuleCondition(lex.curText)
                    // (the parser compiles it with no reporter: only a syntax error tells; what the code generation
                    // finds wrong is found when the engine compiles its rules, which throws then)
                    if !condition.compile() { throw error("Could not parse expression '\(lex.curText)'.") }
                    rule.condition = condition
                    if try lex.next() != .right { throw error("Missing ')'.") }
                } else {
                    throw expected("quoted expression")
                }
            case .keyword("layer"):
                if rule.layerCondition != .all { throw error("'layer' keyword already present.") }
                (rule.layerCondition, rule.layerSource) = try parseLayer()
            case .keyword("severity"):
                rule.severity = try parseSeverity()
            case .eof:
                throw error("Incomplete statement.")
            default:
                throw expected("constraint, condition, or disallow")
            }
            token = try lex.next()
        }
        if lex.curTok != .right { throw error("Missing ')'.") }
        return rule
    }

    /// parseExpression: the tokens up to the clause's closing parenthesis, joined by what separated them
    private mutating func parseExpression() throws -> String {
        var expr = ""
        var depth = 1
        var token = try lex.next()
        while token != .eof {
            if token == .left { depth += 1 }
            if token == .right {
                depth -= 1
                if depth == 0 { break }
            }
            if !expr.isEmpty { expr += lex.curSeparator }
            try checkUnresolvedTextVariable()
            expr += lex.curText
            token = try lex.next()
        }
        return expr
    }

    /// parseConstraint
    private mutating func parseConstraint(_ rule: DesignRule) throws {
        var c = DRCConstraint(.null)
        var unitsType = RuleUnits.DataType.unitless
        var token = try lex.next()
        try checkUnresolvedTextVariable()
        // (deprecated names of three)
        if token == .keyword("mechanical_clearance") {
            token = .keyword("physical_clearance")
        } else if token == .keyword("mechanical_hole_clearance") {
            token = .keyword("physical_hole_clearance")
        } else if token == .keyword("hole") {
            token = .keyword("hole_size")
        } else if token == .right || token == .eof {
            throw error("Missing constraint type.")
        }
        let types: [String: DRCConstraintType] = [
            "assertion": .assertion, "clearance": .clearance, "creepage": .creepage, "hole_clearance": .holeClearance,
            "edge_clearance": .edgeClearance, "hole_size": .holeSize, "hole_to_hole": .holeToHole,
            "courtyard_clearance": .courtyardClearance, "silk_clearance": .silkClearance, "text_height": .textHeight,
            "text_thickness": .textThickness, "track_width": .trackWidth, "track_angle": .trackAngle,
            "track_segment_length": .trackSegmentLength, "connection_width": .connectionWidth,
            "annular_width": .annularWidth, "via_diameter": .viaDiameter, "via_dangling": .viaDangling,
            "zone_connection": .zoneConnection, "thermal_relief_gap": .thermalReliefGap,
            "thermal_spoke_width": .thermalSpokeWidth, "min_resolved_spokes": .minResolvedSpokes,
            "solder_mask_expansion": .solderMaskExpansion, "solder_mask_sliver": .solderMaskSliver,
            "solder_paste_abs_margin": .solderPasteAbsMargin, "solder_paste_rel_margin": .solderPasteRelMargin,
            "disallow": .disallow, "length": .length, "skew": .skew, "via_count": .viaCount,
            "diff_pair_gap": .diffPairGap, "diff_pair_uncoupled": .maxUncoupled,
            "physical_clearance": .physicalClearance, "physical_hole_clearance": .physicalHoleClearance,
            "bridged_mask": .bridgedMask,
        ]
        guard case .keyword(let kw) = token, let type = types[kw] else {
            throw expected("assertion, clearance, hole_clearance, edge_clearance, physical_clearance, "
                           + "physical_hole_clearance, courtyard_clearance, silk_clearance, hole_size, "
                           + "hole_to_hole, track_width, track_angle, track_segment_length, annular_width, "
                           + "disallow, zone_connection, thermal_relief_gap, thermal_spoke_width, "
                           + "min_resolved_spokes, solder_mask_expansion, solder_mask_sliver, "
                           + "solder_paste_abs_margin, solder_paste_rel_margin, length, skew, via_count, "
                           + "via_dangling, via_diameter, diff_pair_gap, diff_pair_uncoupled or bridged_mask")
        }
        c.type = type
        if rule.find(c.type) != nil { throw error("Rule already has a '\(lex.curText)' constraint.") }
        let unitless = [.viaCount, .minResolvedSpokes, .trackAngle, .viaDangling, .bridgedMask].contains(c.type)
        let allowsTimeDomain = c.type == .length || c.type == .skew
        switch c.type {
        case .disallow:
            token = try lex.next()
            while token != .right {
                if token == .string { token = lex.curStrAsToken }
                switch token {
                case .keyword("track"): c.disallowFlags.insert(.tracks)
                case .keyword("via"): c.disallowFlags.formUnion([.throughVias, .blindVias, .buriedVias, .microVias])
                case .keyword("through_via"): c.disallowFlags.insert(.throughVias)
                case .keyword("blind_via"): c.disallowFlags.insert(.blindVias)
                case .keyword("buried_via"): c.disallowFlags.insert(.buriedVias)
                case .keyword("micro_via"): c.disallowFlags.insert(.microVias)
                case .keyword("pad"): c.disallowFlags.insert(.pads)
                case .keyword("zone"): c.disallowFlags.insert(.zones)
                case .keyword("text"): c.disallowFlags.insert(.texts)
                case .keyword("graphic"): c.disallowFlags.insert(.graphics)
                case .keyword("hole"): c.disallowFlags.insert(.holes)
                case .keyword("footprint"): c.disallowFlags.insert(.footprints)
                case .eof: throw error("Missing ')'.")
                default:
                    throw expected("track, via, through_via, blind_via, micro_via, buried_via, pad, zone, text, graphic, hole, or footprint.")
                }
                token = try lex.next()
            }
            rule.add(c)
            return
        case .zoneConnection:
            token = try lex.next()
            if token == .string { token = lex.curStrAsToken }
            switch token {
            case .keyword("solid"): c.zoneConnection = .full
            case .keyword("thermal_reliefs"): c.zoneConnection = .thermal
            case .keyword("none"): c.zoneConnection = .none
            case .eof: throw error("Missing ')'.")
            default: throw expected("solid, thermal_reliefs or none.")
            }
            if try lex.next() != .right { throw error("Missing ')'.") }
            rule.add(c)
            return
        case .minResolvedSpokes:
            token = try lex.next()
            if token == .number {
                c.value.setMin(Self.strtol(lex.curText))
                if try lex.next() != .right { throw error("Missing ')'.") }
            } else {
                throw expected("number")
            }
            rule.add(c)
            return
        case .assertion:
            token = try lex.next()
            if token == .right { throw error("Missing assertion expression.") }
            if RulesLexer.isSymbol(token) {
                // (compiled with no reporter, what it finds wrong told to no one)
                let test = RuleCondition(lex.curText)
                _ = test.compile()
                c.test = test
                if try lex.next() != .right { throw error("Missing ')'.") }
            } else {
                throw expected("quoted expression")
            }
            rule.add(c)
            return
        default:
            break
        }
        token = try lex.next()
        while token != .right && token != .eof {
            if token != .left { throw error("Missing '('.") }
            token = try lex.next()
            switch token {
            case .keyword("within_diff_pairs"):
                if c.type == .skew { c.skewWithinDiffPairs = true } else { throw error("within_diff_pairs option invalid for constraint type.") }
                if try lex.next() != .right { throw error("Missing ')'.") }
            case .keyword("min"), .keyword("max"), .keyword("opt"):
                let which = lex.curText
                let expr = try parseExpression()
                if expr.isEmpty { throw error("Missing \(which) value.") }
                let (value, units) = try parseValueWithUnits(expr, unitless: unitless)
                // validateAndSetValueWithUnits
                let typeTmp = RuleUnits.dataType(units)
                if !allowsTimeDomain && typeTmp == .time { throw error("Time based units not allowed for constraint type.") }
                if (c.value.hasMin || c.value.hasMax || c.value.hasOpt) && unitsType != typeTmp {
                    throw error("Mixed units for constraint values.")
                }
                unitsType = typeTmp
                switch which {
                case "min": c.value.setMin(value)
                case "max": c.value.setMax(value)
                default: c.value.setOpt(value)
                }
                if allowsTimeDomain {
                    c.timeDomain = unitsType == .time
                    c.spaceDomain = unitsType != .time
                }
            case .eof:
                throw error("Incomplete statement.")
            default:
                throw expected("min, max, opt, or within_diff_pairs")
            }
            token = try lex.next()
        }
        rule.add(c)
    }

    /// parseValueWithUnits: the value of a constraint's expression (the unit resolver's, or the unitless one's),
    /// rounded to an int, and its units; an error in it is the parser's
    private func parseValueWithUnits(_ expr: String, unitless: Bool) throws -> (Int, RuleUnits.Unit) {
        var compiler = LibEvalCompiler(units: unitless ? .unitless : .pcb)
        let code = compiler.compile(expr)
        if let e = compiler.errors.first { throw error(e) }
        guard let code else { return (0, .unscaled) }
        let ctx = RuleContext(constraint: .null, layer: KiLayer.fCu, items: (nil, nil), board: nil)
        let result = code.run(ctx)
        if let e = compiler.errors.first { throw error(e) }
        guard result.type == .numeric else { return (0, .mm) }
        return (KiMath.round(result.asDouble()), result.units)
    }

    /// parseLayer: "outer", "inner", or a layer's name (wildcards allowed) matched against each layer's canonical
    /// and user names
    private mutating func parseLayer() throws -> (KiLayerSet, String) {
        var set = KiLayerSet()
        var source = ""
        let token = try lex.next()
        if token == .right {
            throw error("Missing layer name or type.")
        } else if token == .keyword("outer") {
            source = "'outer'"
            set = .externalCu
        } else if token == .keyword("inner") {
            source = "'inner'"
            set = .internalCu
        } else {
            let name = lex.curText
            for l in 0..<KiLayer.count where layerNamesMatch(l, name) {
                source = name
                set.insert(l)
            }
            if set.isEmpty {
                try checkUnresolvedTextVariable()
                throw error("Unrecognized layer '\(name)'.")
            }
        }
        if try lex.next() != .right { throw error("Missing ')'.") }
        return (set, source)
    }

    /// The board's user layer names the layer map holds beside the canonical ones (BOARD::GetLayerName), by layer
    var userLayerNames: [Int: String] = [:]

    /// Whether the layer map's entries for a layer (its canonical name, its user name) match a pattern
    func layerNamesMatch(_ l: Int, _ pattern: String) -> Bool {
        if WildMatch.matches(KiLayer.name(l), pattern) { return true }
        if let u = userLayerNames[l], WildMatch.matches(u, pattern) { return true }
        return false
    }

    /// parseSeverity
    private mutating func parseSeverity() throws -> RuleSeverity {
        let token = try lex.next()
        if token == .right || token == .eof { throw error("Missing severity name.") }
        let s: RuleSeverity
        switch token {
        case .keyword("ignore"): s = .ignore
        case .keyword("warning"): s = .warning
        case .keyword("error"): s = .error
        case .keyword("exclusion"): s = .exclusion
        default: throw expected("ignore, warning, error, or exclusion")
        }
        if try lex.next() != .right { throw error("Missing ')'.") }
        return s
    }
}

// MARK: - Wildcards (wxString::Matches, WildCompareString)

enum WildMatch {
    /// wxString::Matches: `text` against a mask of '*' (any run, '?'s and '*'s after it skipped) and '?' (any one
    /// character), case sensitive; a character that differs fails it at once, and text left over when the mask is
    /// done goes back to the last '*' once
    static func matches(_ text: String, _ mask: String) -> Bool {
        let txt = Array(text.unicodeScalars), msk = Array(mask.unicodeScalars)
        var t = 0, m = 0
        var lastStarInText: Int? = nil, lastStarInMask = 0
        func at(_ a: [Unicode.Scalar], _ i: Int) -> Unicode.Scalar? { i < a.count ? a[i] : nil }
        while true {
            while m < msk.count {
                let mc = msk[m]
                if mc == "?" {
                    if t >= txt.count { return false }
                } else if mc == "*" {
                    lastStarInText = t
                    lastStarInMask = m
                    while m < msk.count && (msk[m] == "*" || msk[m] == "?") { m += 1 }
                    if m >= msk.count { return true }
                    // the run of the mask up to its next wildcard, found in the text from here
                    var end = m
                    while end < msk.count && msk[end] != "*" && msk[end] != "?" { end += 1 }
                    let run = Array(msk[m..<end])
                    var found: Int?
                    if t <= txt.count - run.count {
                        for start in t...(txt.count - run.count) where Array(txt[start..<(start + run.count)]) == run {
                            found = start
                            break
                        }
                    }
                    guard let f = found else { return false }
                    t = f + run.count - 1
                    m += run.count - 1
                } else if at(txt, t) != mc {
                    return false
                }
                m += 1
                t += 1
            }
            if t >= txt.count { return true }
            guard let last = lastStarInText else { return false }
            t = last + 1
            m = lastStarInMask
            lastStarInText = nil
        }
    }

    /// WildCompareString: `text` against a pattern of '*' and '?', in capitals both if not case sensitive
    static func compare(_ pattern: String, _ text: String, caseSensitive: Bool) -> Bool {
        let wild = Array((caseSensitive ? pattern : pattern.uppercased()).unicodeScalars)
        let str = Array((caseSensitive ? text : text.uppercased()).unicodeScalars)
        var w = 0, s = 0
        var mp = 0, cp = 0
        func wc(_ i: Int) -> Unicode.Scalar? { i < wild.count ? wild[i] : nil }
        while s < str.count && wc(w) != "*" {
            if wc(w) != str[s] && wc(w) != "?" { return false }
            w += 1
            s += 1
        }
        while s < str.count {
            if wc(w) == "*" {
                w += 1
                if w >= wild.count { return true }
                mp = w
                cp = s + 1
            } else if wc(w) == str[s] || wc(w) == "?" {
                w += 1
                s += 1
            } else {
                w = mp
                s = cp
                cp += 1
            }
        }
        while wc(w) == "*" { w += 1 }
        return w >= wild.count
    }
}
