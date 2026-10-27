// Ported from KiCad 10.0.7: common/eda_text.cpp (GetEffectiveTextShape, GetTextBox, GetEffectiveTextPenWidth, the
// setters' clamping), pcbnew/pcb_text.cpp (GetShownText, GetDrawRotation, GetBoundingBox, GetEffectiveShape, Rotate),
// pcbnew/pcb_field.cpp (GetShownText), pcbnew/footprint.cpp (ResolveTextVar, as far as a footprint's own fields and
// name, SetOrientation), common/common.cpp (ResolveTextVars, ExpandTextVars), common/string_utils.cpp
// (UnescapeString), common/gr_text.cpp (GetPenSizeForBold, GetPenSizeForNormal, ClampTextPenSize) and
// pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp (parsePCB_TEXT, parsePCB_TEXT_effects, parseEDA_TEXT and a
// footprint's properties: a text as KiCad reads it, turned and moved with its footprint).
// Copyright (C) 2004-2017 Jean-Pierre Charras; Copyright (C) 2012 SoftPLC Corporation, Dick Hollenbeck; Copyright
// (C) 2011 Wayne Stambaugh; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// A text's strokes as KiCad's DRC takes them (PCB_TEXT::GetEffectiveShape of a text in the KiCad font: the
/// SHAPE_COMPOUND of its strokes' segments, each as wide as the text's pen), and its boxes
public struct TextStrokes: Sendable {
    public var segments: [Seg]
    /// The pen's width (EDA_TEXT::GetEffectiveTextPenWidth)
    public var width: Int
    /// EDA_TEXT::GetTextBox: the text's box as if it were not turned
    public var textBox: IBox
    /// PCB_TEXT::GetBoundingBox: the text box turned with the text, about its position, and boxed again
    public var boundingBox: IBox
    /// Whether it is shown: a footprint's field may be hidden (KiCad's DRC leaves it out)
    public var visible: Bool
    /// The text it shows, its variables resolved (GetShownText)
    public var shownText: String
    /// Where it is drawn from and how it is turned (GetDrawPos, GetDrawRotation)
    public var position = IPoint.zero
    public var rotation = EDAAngle.zero

    public var shapes: [Shape] { segments.map { .segment($0, width: width) } }
}

extension BoardWorld {
    /// A text's strokes and boxes: a board's text (gr_text), or a footprint's field (property, or fp_text reference or
    /// value) or text (fp_text user), `footprint` the footprint's node. Nil for what the port does not make, said to
    /// `unsupported`: a text in another font, a knockout text, variables it cannot resolve (the board's, the
    /// project's, nets'), and items that are not texts on the board
    public static func textStrokes(_ node: SExpr, footprint: SExpr?, unsupported: ((String) -> Void)? = nil) -> TextStrokes? {
        do {
            let t = try BoardText(node, footprint: footprint)
            let shown = try t.shownText()
            return t.strokes(shown)
        } catch let e as BoardText.Unsupported {
            unsupported?(e.reason)
            return nil
        } catch {
            return nil
        }
    }

    /// A text's shapes as KiCad's DRC takes them: its strokes' segments; nil for a hidden field, and for a text the
    /// port does not make
    public static func textShapes(_ node: SExpr, footprint: SExpr?) -> [Shape]? {
        guard let t = textStrokes(node, footprint: footprint), t.visible else { return nil }
        return t.shapes
    }
}

/// A PCB_TEXT (or PCB_FIELD) as KiCad reads it from a board
struct BoardText {
    struct Unsupported: Error { let reason: String }

    enum Kind { case board, footprintText, field(name: String) }

    var kind: Kind
    var text: String
    var position = IPoint.zero
    var angle = EDAAngle.zero
    var attributes = StrokeFont.Attributes()
    var keepUpright = false
    var visible = true
    var layer = ""
    var footprint: FootprintTexts?

    static let mandatoryFields: Set<String> = ["Reference", "Value", "Datasheet", "Description"]

    /// What a footprint's texts resolve their variables with: its fields as FOOTPRINT::GetField finds them, its library
    /// name
    struct FootprintTexts {
        var fields: [(name: String, text: String)] = []
        var libraryNickname = ""
        var libraryItemName = ""

        init(_ fp: SExpr) {
            // (the four every footprint has, then the user's, a name met again setting the field it names)
            fields = [("Reference", ""), ("Value", ""), ("Datasheet", ""), ("Description", "")]
            func set(_ name: String, _ text: String) {
                if let i = fields.firstIndex(where: { $0.name == name }) {
                    fields[i].text = text
                } else {
                    fields.append((name, text))
                }
            }
            for item in fp.items {
                if item.head == "property", let name = item.text(at: 0), let text = item.text(at: 1) {
                    if name != "ki_fp_filters" && name != "Footprint" { set(name, text) }
                } else if item.head == "fp_text", let text = BoardText.textArgument(item, 1) {
                    let t = text.replacingOccurrences(of: "%V", with: "${VALUE}").replacingOccurrences(of: "%R", with: "${REFERENCE}")
                    if item.text(at: 0) == "reference" { set("Reference", t) }
                    if item.text(at: 0) == "value" { set("Value", t) }
                }
            }
            let id = fp.text(at: 0) ?? ""
            if let colon = id.firstIndex(of: ":") {
                libraryNickname = String(id[..<colon])
                libraryItemName = String(id[id.index(after: colon)...])
            } else {
                libraryItemName = id
            }
        }

        func field(_ name: String) -> String? { fields.first { $0.name == name }?.text }
    }

    /// The text of a text's item `index` (0 the first after its head), past a bare "locked" (the legacy token)
    static func textArgument(_ node: SExpr, _ index: Int) -> String? {
        var i = index + 1
        if i < node.items.count, node.items[i].kind == .symbol, node.items[i].text == "locked" { i += 1 }
        guard i < node.items.count, node.items[i].kind != .list else { return nil }
        return node.items[i].text
    }

    init(_ node: SExpr, footprint fp: SExpr?) throws {
        switch node.head ?? "" {
        case "gr_text":
            kind = .board
            guard let t = Self.textArgument(node, 0) else { throw Unsupported(reason: "a text with no text") }
            text = t.replacingOccurrences(of: "%V", with: "${VALUE}").replacingOccurrences(of: "%R", with: "${REFERENCE}")
        case "fp_text":
            guard fp != nil else { throw Unsupported(reason: "a footprint's text outside a footprint") }
            switch node.text(at: 0) {
            case "reference": kind = .field(name: "Reference")
            case "value": kind = .field(name: "Value")
            default: kind = .footprintText
            }
            guard let t = Self.textArgument(node, 1) else { throw Unsupported(reason: "a text with no text") }
            text = t.replacingOccurrences(of: "%V", with: "${VALUE}").replacingOccurrences(of: "%R", with: "${REFERENCE}")
        case "property":
            guard fp != nil, let name = node.text(at: 0), let value = node.text(at: 1) else {
                throw Unsupported(reason: "a property outside a footprint")
            }
            // (KiCad keeps neither as a field)
            if name == "ki_fp_filters" || name == "Footprint" { throw Unsupported(reason: "property \(name), not a field") }
            if !Self.mandatoryFields.contains(name) {
                // (a field of the user's own is styled from the board's settings before its effects are read)
                guard let font = node["effects"]?["font"], font["size"] != nil, font["thickness"] != nil else {
                    throw Unsupported(reason: "a field with no size or thickness of its own")
                }
            }
            kind = .field(name: name)
            text = value
        default:
            throw Unsupported(reason: "\(node.head ?? "?"), not a text")
        }
        if let fp {
            footprint = FootprintTexts(fp)
            keepUpright = true
        }
        try readEffects(node, footprint: fp)
    }

    /// parsePCB_TEXT_effects (with parseEDA_TEXT), then the text turned and moved with its footprint
    private mutating func readEffects(_ node: SExpr, footprint fp: SExpr?) throws {
        var hasAngle = false, hasPos = false
        for item in node.items {
            if item.kind == .symbol {
                // (a bare "hide", as older files have it)
                if item.text == "hide", fp != nil { visible = false }
                continue
            }
            switch item.head ?? "" {
            case "at":
                hasPos = true
                position = BoardWorld.point(item)
                if let a = item.number(at: 2) {
                    angle = EDAAngle(degrees: a)
                    hasAngle = true
                }
                if fp != nil, item.arguments.contains(where: { $0.kind == .symbol && $0.text == "unlocked" }) { keepUpright = false }
            case "layer":
                layer = item.text(at: 0) ?? ""
                if item.arguments.contains(where: { $0.kind == .symbol && $0.text == "knockout" }) {
                    throw Unsupported(reason: "a knockout text")
                }
            case "hide":
                if fp != nil { visible = item.text(at: 0) == "no" || item.text(at: 0) == "false" }
            case "unlocked":
                if fp != nil { keepUpright = !(item.text(at: 0) == "yes" || item.text(at: 0) == "true") }
            case "effects":
                try readEDAText(item)
            default:
                break
            }
        }
        if !hasAngle { angle = .zero }
        if case .board = kind { visible = true }
        if let fp {
            guard hasPos else { throw Unsupported(reason: "a footprint's text with no position") }
            // (the angle read is the text's on the board: made the footprint's, then turned back with it, normalized)
            let orientation = EDAAngle(degrees: fp["at"]?.number(at: 2) ?? 0).normalized180
            angle = ((angle - orientation) + orientation).normalized
            position = KiMath.rotate(position, orientation) + BoardWorld.point(fp["at"])
        }
    }

    /// parseEDA_TEXT: its font, justification and whether it is hidden
    private mutating func readEDAText(_ effects: SExpr) throws {
        attributes.hAlign = 0
        attributes.vAlign = 0
        attributes.mirrored = false
        var foundSize = false
        for item in effects.items {
            if item.kind == .symbol {
                if item.text == "hide" { visible = false }
                continue
            }
            switch item.head ?? "" {
            case "font":
                for f in item.items {
                    if f.kind == .symbol {
                        if f.text == "bold" { attributes.bold = true }
                        if f.text == "italic" { attributes.italic = true }
                        continue
                    }
                    switch f.head ?? "" {
                    case "face":
                        let face = f.text(at: 0) ?? ""
                        if !face.isEmpty && !face.hasPrefix("KiCad Font") {
                            throw Unsupported(reason: "a text in font \(face)")
                        }
                    case "size":
                        // (height, then width; EDA_TEXT::SetTextSize keeps them from 1 µm to 250 mm)
                        func clamp(_ v: Int) -> Int { min(max(v, 1000), 250_000_000) }
                        attributes.size = IPoint(clamp(BoardWorld.iu(f, 1)), clamp(BoardWorld.iu(f, 0)))
                        foundSize = true
                    case "line_spacing":
                        attributes.lineSpacing = f.number(at: 0) ?? 1
                    case "thickness":
                        attributes.strokeWidth = BoardWorld.iu(f, 0)
                    case "bold":
                        attributes.bold = !(f.text(at: 0) == "no" || f.text(at: 0) == "false")
                    case "italic":
                        attributes.italic = !(f.text(at: 0) == "no" || f.text(at: 0) == "false")
                    default:
                        break
                    }
                }
            case "justify":
                for j in item.arguments {
                    switch j.text {
                    case "left": attributes.hAlign = -1
                    case "right": attributes.hAlign = 1
                    case "top": attributes.vAlign = -1
                    case "bottom": attributes.vAlign = 1
                    case "mirror": attributes.mirrored = true
                    default: break
                    }
                }
            case "hide":
                visible = item.text(at: 0) == "no" || item.text(at: 0) == "false"
            default:
                break
            }
        }
        // (60 mils where a file has no size, as before 5.0)
        if !foundSize { attributes.size = IPoint(1_524_000, 1_524_000) }
    }

    // MARK: - The text shown

    /// GetShownText( true ): PCB_TEXT's (its unescaped text, its variables resolved) or PCB_FIELD's (the same, but
    /// that it resolves variables wherever ${ or @{ appears)
    func shownText(depth: Int = 0) throws -> String {
        let s = try Self.shownText(text, footprint: footprint, depth: depth)
        return String(String.UnicodeScalarView(s))
    }

    static func shownText(_ raw: String, footprint: FootprintTexts?, depth: Int) throws -> [Unicode.Scalar] {
        var text = raw.isEmpty ? [] : unescape(Array(raw.unicodeScalars))
        if contains(text, "${") || contains(text, "@{") {
            var d = depth
            text = try resolveTextVars(text, depth: &d) { token, depth in
                try resolve(token, footprint: footprint, depth: depth)
            }
        }
        return text
    }

    /// PCB_TEXT's resolver, as far as a footprint's own: FOOTPRINT::ResolveTextVar (its reference, value, library
    /// name and fields); what the board or project would resolve is not made here
    static func resolve(_ token: [Unicode.Scalar], footprint: FootprintTexts?, depth: Int) throws -> [Unicode.Scalar] {
        let name = String(String.UnicodeScalarView(token))
        guard let fp = footprint else { throw Unsupported(reason: "variable ${\(name)} of the board's") }
        let fpDepth = depth + 1
        switch name {
        case "REFERENCE": return try shownText(fp.field("Reference") ?? "", footprint: fp, depth: fpDepth + 1)
        case "VALUE": return try shownText(fp.field("Value") ?? "", footprint: fp, depth: fpDepth + 1)
        case "FOOTPRINT_LIBRARY": return Array(fp.libraryNickname.unicodeScalars)
        case "FOOTPRINT_NAME": return Array(fp.libraryItemName.unicodeScalars)
        case "LAYER": throw Unsupported(reason: "variable ${LAYER}")
        default:
            if ["SHORT_NET_NAME(", "NET_NAME(", "NET_CLASS(", "PIN_NAME("].contains(where: { name.hasPrefix($0) }) {
                throw Unsupported(reason: "variable ${\(name)} of a pad's")
            }
            if let f = fp.field(name) { return try shownText(f, footprint: fp, depth: fpDepth + 1) }
            throw Unsupported(reason: "variable ${\(name)} of the board's")
        }
    }

    static func contains(_ s: [Unicode.Scalar], _ word: String) -> Bool {
        let w = Array(word.unicodeScalars)
        guard s.count >= w.count else { return false }
        for i in 0...(s.count - w.count) where s[i] == w[0] && Array(s[i..<(i + w.count)]) == w { return true }
        return false
    }

    /// UnescapeString: {slash}, {dblquote} and the like made the characters they stand for, other braces kept
    static func unescape(_ source: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let n = source.count
        if n <= 2 { return source }
        var out: [Unicode.Scalar] = []
        var prev: Unicode.Scalar = "\0", ch: Unicode.Scalar = "\0"
        var i = 0
        while i < n {
            prev = ch
            ch = source[i]
            if ch == "{" {
                var token: [Unicode.Scalar] = []
                var depth = 1
                var terminated = false
                i += 1
                while i < n {
                    ch = source[i]
                    if ch == "{" {
                        depth += 1
                    } else if ch == "}" {
                        depth -= 1
                    }
                    if depth <= 0 {
                        terminated = true
                        break
                    }
                    token.append(ch)
                    i += 1
                }
                let t = String(String.UnicodeScalarView(token))
                if !terminated {
                    out.append("{")
                    out += unescape(token)
                } else if prev == "$" || prev == "~" || prev == "^" || prev == "_" {
                    out.append("{")
                    out += unescape(token)
                    out.append("}")
                } else {
                    let map: [String: Unicode.Scalar] = ["dblquote": "\"", "quote": "'", "lt": "<", "gt": ">", "backslash": "\\",
                                                         "slash": "/", "bar": "|", "comma": ",", "colon": ":", "space": " ",
                                                         "dollar": "$", "tab": "\t", "return": "\n", "brace": "{"]
                    if let c = map[t] {
                        out.append(c)
                    } else {
                        out.append("{")
                        out += unescape(token)
                        out.append("}")
                    }
                }
            } else {
                out.append(ch)
            }
            i += 1
        }
        return out
    }

    /// m_ResolveTextRecursionDepth
    static let maxDepth = 6

    /// ResolveTextVars: ExpandTextVars again while ${ is left, as deep as KiCad goes (`depth` counted as KiCad counts
    /// it, the resolver given its count)
    static func resolveTextVars(_ source: [Unicode.Scalar], depth: inout Int,
                                _ resolver: ([Unicode.Scalar], Int) throws -> [Unicode.Scalar]) throws -> [Unicode.Scalar] {
        var text = source
        while contains(text, "${") || contains(text, "@{") {
            depth += 1
            guard depth <= maxDepth else { break }
            let d = depth
            text = try expandTextVars(text, depth: 0) { try resolver($0, d) }
            if contains(text, "@{") { throw Unsupported(reason: "an expression @{…}") }
        }
        return text
    }

    /// ExpandTextVars: each ${token} made what the resolver makes of it, tokens within it first; the DRC's own
    /// warnings and errors (${DRC_ERROR …} and the like) dropped
    static func expandTextVars(_ s: [Unicode.Scalar], depth: Int,
                               _ resolver: ([Unicode.Scalar]) throws -> [Unicode.Scalar]) throws -> [Unicode.Scalar] {
        let n = s.count
        var out: [Unicode.Scalar] = []
        var i = 0
        func at(_ k: Int, _ word: String) -> Bool {
            let w = Array(word.unicodeScalars)
            return k + w.count <= n && Array(s[k..<(k + w.count)]) == w
        }
        while i < n {
            if at(i, "<<<ESC_DOLLAR:") || at(i, "<<<ESC_AT:") { throw Unsupported(reason: "an escaped variable") }
            if s[i] == "\\" && i + 2 < n && (s[i + 1] == "$" || s[i + 1] == "@") && s[i + 2] == "{" {
                throw Unsupported(reason: "an escaped variable")
            }
            if (s[i] == "$" || s[i] == "@") && i + 1 < n && s[i + 1] == "{" {
                if s[i] == "@" { throw Unsupported(reason: "an expression @{…}") }
                var token: [Unicode.Scalar] = []
                var braceDepth = 1
                i += 2
                while i < n {
                    if at(i, "<<<ESC_DOLLAR:") || at(i, "<<<ESC_AT:") { throw Unsupported(reason: "an escaped variable") }
                    if s[i] == "{" {
                        braceDepth += 1
                        token.append(s[i])
                    } else if s[i] == "}" {
                        braceDepth -= 1
                        if braceDepth == 0 { break }
                        token.append(s[i])
                    } else {
                        token.append(s[i])
                    }
                    i += 1
                }
                i += 1
                if token.isEmpty { continue }
                if (contains(token, "${") || contains(token, "@{")) && depth < maxDepth {
                    token = try expandTextVars(token, depth: depth + 1, resolver)
                    if contains(token, "@{") { throw Unsupported(reason: "an expression @{…}") }
                }
                let name = String(String.UnicodeScalarView(token))
                if ["ERC_WARNING", "ERC_ERROR", "DRC_WARNING", "DRC_ERROR"].contains(where: { name.hasPrefix($0) }) {
                    continue
                }
                out += try resolver(token)
                continue
            }
            out.append(s[i])
            i += 1
        }
        return out
    }

    // MARK: - Shapes

    var inFootprint: Bool { footprint != nil }

    /// PCB_TEXT::GetDrawRotation: a footprint's text kept upright (within -90 and 90 degrees, 90 kept) if it is to
    /// be, any other normalized
    var drawRotation: EDAAngle {
        var r = angle
        if inFootprint && keepUpright {
            while r > .a90 { r -= .a180 }
            while r <= -.a90 { r += .a180 }
        } else {
            r = r.normalized
        }
        return r
    }

    /// EDA_TEXT::GetEffectiveTextPenWidth: its thickness, or (where it has none) a fifth of its width if bold, an
    /// eighth if not; never more than a quarter of its size
    var penWidth: Int {
        var pen = attributes.strokeWidth
        if pen <= 1 {
            pen = attributes.bold ? KiMath.round(Double(attributes.size.x) / 5.0) : KiMath.round(Double(attributes.size.x) / 8.0)
        }
        let size = min(abs(attributes.size.x), abs(attributes.size.y))
        return min(pen, KiMath.round(Double(size) * 0.25))
    }

    /// EDA_TEXT::GetTextBox( nullptr, -1 ): its first line's box, as wide as its widest, as tall as all its lines
    /// (their spacing left out), placed by its justification, not turned
    func textBox(_ shown: [Unicode.Scalar]) -> StrokeFont.Box {
        let lines = StrokeFont.lines(shown)
        var text = shown
        let thickness = penWidth
        if !lines.isEmpty { text = lines[0] }
        let size = attributes.size
        var extents = StrokeFont.stringBoundaryLimits(text, size: size, thickness: thickness, bold: attributes.bold,
                                                      italic: attributes.italic)
        var textSize = extents
        let fudge = KiMath.round(Double(extents.y) * 0.17)
        textSize.y += fudge
        let overbarOffset = Self.contains(text, "~{") ? extents.y / 6 : 0
        var box = StrokeFont.Box()
        box.setOrigin(position)
        if lines.count > 1 {
            for line in lines.dropFirst() {
                extents = StrokeFont.stringBoundaryLimits(line, size: size, thickness: thickness, bold: attributes.bold,
                                                          italic: attributes.italic)
                textSize.x = max(textSize.x, extents.x)
            }
            textSize.y += KiMath.round(Double(lines.count - 1) * StrokeFont.interline(Double(size.y)))
        }
        textSize.y += overbarOffset
        box.size = textSize
        let italicOffset = attributes.italic ? KiMath.round(Double(size.y) * StrokeFont.italicTilt) : 0
        switch attributes.hAlign {
        case -1: if attributes.mirrored { box.pos.x -= box.size.x - italicOffset }
        case 0: box.pos.x -= (box.size.x - italicOffset) / 2
        default: if !attributes.mirrored { box.pos.x -= box.size.x - italicOffset }
        }
        switch attributes.vAlign {
        case -1: box.pos.y -= fudge
        case 0: box.pos.y -= box.size.y / 2
        default:
            box.pos.y -= box.size.y
            box.pos.y += fudge
        }
        box.normalize()
        return box
    }

    /// GetEffectiveTextShape's strokes, made segments, and the boxes
    func strokes(_ shownString: String) -> TextStrokes {
        let shown = Array(shownString.unicodeScalars)
        var attrs = attributes
        let rotation = drawRotation
        attrs.angle = rotation
        let segments = StrokeFont.segments(StrokeFont.draw(shown, position: position, attrs))
        let box = textBox(shown)
        let bounding = rotation.degrees == 0 ? box : box.rotated(position, rotation)
        return TextStrokes(segments: segments, width: penWidth, textBox: box.ibox, boundingBox: bounding.ibox,
                           visible: visible, shownText: shownString, position: position, rotation: rotation)
    }
}
