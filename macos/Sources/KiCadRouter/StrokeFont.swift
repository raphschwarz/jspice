// Ported from KiCad 10.0.7: common/font/stroke_font.cpp (STROKE_FONT: loadNewStrokeFont, GetTextAsGlyphs,
// GetInterline), common/font/glyph.cpp (STROKE_GLYPH::Transform), common/font/font.cpp (FONT::Draw, getLinePositions,
// drawMarkup, boundingBoxSingleLine, StringBoundaryLimits), include/font/font_metrics.h (METRICS' defaults),
// include/markup_parser.h and common/markup_parser.cpp (the markup of overbars, subscripts, superscripts and links,
// as PEGTL's parse tree keeps it), common/callback_gal.cpp (a stroke glyph's segments) and
// libs/kimath/include/math/box2.h (BOX2I as the font's boxes use it).
// Copyright (C) 2012 Torsten Hueter; Copyright (C) 2013 CERN; Copyright (C) 2021 Ola Rinta-Koski; Copyright The KiCad
// Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// KiCad's stroke font, newstroke (KIFONT::STROKE_FONT with KiCad's default metrics): texts drawn as KiCad draws
/// them with it, as strokes, each a polyline of points in fractions of nanometres
public enum StrokeFont {
    static let scale = 1.0 / 21.0       // STROKE_FONT_SCALE
    static let fontOffset = -8          // FONT_OFFSET
    static let italicTilt = 1.0 / 8     // ITALIC_TILT
    static let interChar = 0.2          // INTER_CHAR
    static let tabWidth = 4
    static let superSubSize = 0.8
    static let subscriptBaselineOffset = 0.15
    static let superscriptBaselineOffset = -0.35
    static let interlinePitch = 1.68    // METRICS::m_InterlinePitch
    static let overbarHeight = 1.23     // METRICS::m_OverbarHeight
    static let legacyFactor = 0.9583    // GetInterline's LEGACY_FACTOR

    /// TEXT_STYLE (SUBSCRIPT lowered, SUPERSCRIPT raised)
    struct Style: OptionSet {
        let rawValue: Int
        static let bold = Style(rawValue: 1)
        static let italic = Style(rawValue: 2)
        static let lowered = Style(rawValue: 4)
        static let raised = Style(rawValue: 8)
    }

    // MARK: - Glyphs (loadNewStrokeFont)

    /// A glyph: its strokes, and its bounding box's width and right (from 0 to its width, BOX2D::GetWidth and
    /// GetEnd().x)
    struct Glyph {
        var strokes: [[DPoint]] = []
        var width = 0.0
        var right = 0.0
    }

    static let table: [UInt8] = Array(newstrokeTable.utf8)

    /// Where each glyph's line starts in the table, and one past the end
    static let lineStarts: [Int] = {
        var starts = [0]
        for (i, c) in table.enumerated() where c == 0x0a { starts.append(i + 1) }
        starts.append(table.count + 1)
        return starts
    }()

    static var glyphCount: Int { lineStarts.count - 1 }

    /// Glyph `index` (its character less U+0020) read as loadNewStrokeFont reads it: two characters a point, offset by
    /// 'R', the first pair the glyph's left and right, " R" lifting the pen
    static func glyph(_ index: Int) -> Glyph {
        let start = lineStarts[index], end = lineStarts[index + 1] - 1
        var g = Glyph()
        var startX = 0.0, glyphWidth = 0.0
        var penDown = false
        var i = start
        while i < end {
            let c0 = Int(table[i]), c1 = i + 1 < end ? Int(table[i + 1]) : 0
            if i - start < 2 {
                startX = Double(c0 - 82) * scale
                let endX = Double(c1 - 82) * scale
                glyphWidth = endX - startX
            } else if c0 == 0x20 && c1 == 82 {
                penDown = false
            } else {
                let p = DPoint(Double(c0 - 82) * scale - startX, Double(c1 - 82 + fontOffset) * scale)
                if !penDown {
                    g.strokes.append([])
                    penDown = true
                }
                g.strokes[g.strokes.count - 1].append(p)
            }
            i += 2
        }
        // (buildGlyphBoundingBox: BOX2D( (0, min y), (width, max y) - (0, min y) ), normalized)
        var x = 0.0, w = glyphWidth - 0.0
        if w < 0 {
            w = -w
            x -= w
        }
        g.width = w
        g.right = x + w
        return g
    }

    static let spaceWidth = glyph(0).width

    /// STROKE_FONT::GetInterline: the distance between lines' baselines
    static func interline(_ glyphHeight: Double) -> Double { glyphHeight * interlinePitch * legacyFactor }

    // MARK: - Boxes

    /// KiCad's BOX2I as the font uses it: an origin and a size, and whether it has been set
    struct Box {
        var pos = IPoint.zero
        var size = IPoint.zero
        var initialized = false

        init() {}

        init(pos: IPoint, size: IPoint) {
            self.pos = pos
            self.size = size
            initialized = true
            normalize()
        }

        var end: IPoint { pos + size }

        mutating func setOrigin(_ p: IPoint) {
            pos = p
            initialized = true
        }

        mutating func setEnd(_ p: IPoint) {
            size = p - pos
            initialized = true
        }

        mutating func normalize() {
            if size.y < 0 {
                size.y = -size.y
                pos.y -= size.y
            }
            if size.x < 0 {
                size.x = -size.x
                pos.x -= size.x
            }
        }

        mutating func merge(_ r: Box) {
            if !initialized {
                if r.initialized { self = r }
                return
            }
            normalize()
            var rect = r
            rect.normalize()
            var e = end
            let re = rect.end
            pos.x = min(pos.x, rect.pos.x)
            pos.y = min(pos.y, rect.pos.y)
            e.x = max(e.x, re.x)
            e.y = max(e.y, re.y)
            setEnd(e)
        }

        mutating func inflate(_ d: Int) {
            func one(_ p: inout Int, _ s: inout Int) {
                if s >= 0 {
                    if s < -2 * d {
                        p += s / 2
                        s = 0
                    } else {
                        p -= d
                        s += 2 * d
                    }
                } else {
                    if s > 2 * d {
                        p -= s / 2
                        s = 0
                    } else {
                        p += d
                        s -= 2 * d
                    }
                }
            }
            one(&pos.x, &size.x)
            one(&pos.y, &size.y)
        }

        /// GetBoundingBoxRotated: the box round its corners turned about `center`
        func rotated(_ center: IPoint, _ angle: EDAAngle) -> Box {
            let e = end
            let corners = [pos, IPoint(pos.x, e.y), e, IPoint(e.x, pos.y)].map { KiMath.rotate($0, around: center, angle) }
            var lo = corners[0], hi = corners[0]
            for c in corners.dropFirst() {
                lo = IPoint(min(lo.x, c.x), min(lo.y, c.y))
                hi = IPoint(max(hi.x, c.x), max(hi.y, c.y))
            }
            var b = Box()
            b.setOrigin(lo)
            b.setEnd(hi)
            return b
        }

        var ibox: IBox { IBox(minX: pos.x, minY: pos.y, maxX: pos.x + size.x, maxY: pos.y + size.y) }
    }

    // MARK: - Markup (MARKUP::MARKUP_PARSER)

    /// A node of the markup's parse tree as KiCad keeps it: runs of text and links with their content; subscripts,
    /// superscripts and overbars with their children only (and none kept with no children)
    final class Node {
        enum Kind { case root, text, url, lowered, raised, overbar }
        let kind: Kind
        let content: [Unicode.Scalar]?
        var children: [Node]

        init(_ kind: Kind, content: [Unicode.Scalar]? = nil, children: [Node] = []) {
            self.kind = kind
            self.content = content
            self.children = children
        }
    }

    /// The markup grammar, a PEG: anything = anyString | url | subscript | superscript | overbar, until the end
    struct MarkupParser {
        let s: [Unicode.Scalar]

        private func at(_ i: Int, _ c: Unicode.Scalar) -> Bool { i < s.count && s[i] == c }

        private func at(_ i: Int, _ word: String) -> Bool {
            var k = i
            for c in word.unicodeScalars {
                guard at(k, c) else { return false }
                k += 1
            }
            return true
        }

        /// markup: subscript | superscript | overbar (the node nil where the match keeps none)
        func markup(_ i: Int) -> (end: Int, node: Node?)? {
            braces(i, "_", .lowered) ?? braces(i, "^", .raised) ?? braces(i, "~", .overbar)
        }

        /// braces<C>: C '{', then until '}' anyStringWithinBraces | subscript | superscript | overbar
        func braces(_ i: Int, _ control: Unicode.Scalar, _ kind: Node.Kind) -> (end: Int, node: Node?)? {
            guard at(i, control), at(i + 1, "{") else { return nil }
            var j = i + 2
            var children: [Node] = []
            while true {
                if at(j, "}") {
                    j += 1
                    break
                }
                if let r = withinBraces(j) {
                    children.append(r.node)
                    j = r.end
                } else if let r = markup(j) {
                    if let n = r.node { children.append(n) }
                    j = r.end
                } else {
                    return nil
                }
            }
            return (j, children.isEmpty ? nil : Node(kind, children: children))
        }

        /// escapeSequence: '{' identifier '}'
        func escapeSequence(_ i: Int) -> Int? {
            guard at(i, "{"), i + 1 < s.count else { return nil }
            func first(_ c: Unicode.Scalar) -> Bool { (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_" }
            func other(_ c: Unicode.Scalar) -> Bool { first(c) || (c >= "0" && c <= "9") }
            guard first(s[i + 1]) else { return nil }
            var k = i + 2
            while k < s.count && other(s[k]) { k += 1 }
            return at(k, "}") ? k + 1 : nil
        }

        /// anyStringWithinBraces: one or more of (not at markup) an escape sequence or any character but '}'
        func withinBraces(_ i: Int) -> (end: Int, node: Node)? {
            var k = i
            while k < s.count, markup(k) == nil {
                if let e = escapeSequence(k) {
                    k = e
                } else if s[k] != "}" {
                    k += 1
                } else {
                    break
                }
            }
            return k > i ? (k, Node(.text, content: Array(s[i..<k]))) : nil
        }

        /// url: "http://" or "https://", then one or more characters that are not spaces
        func url(_ i: Int) -> Int? {
            var k: Int
            if at(i, "http://") {
                k = i + 7
            } else if at(i, "https://") {
                k = i + 8
            } else {
                return nil
            }
            let start = k
            while k < s.count && s[k] != " " { k += 1 }
            return k > start ? k : nil
        }

        /// anyString: one or more characters at which neither markup nor a link starts
        func anyString(_ i: Int) -> Int? {
            var k = i
            while k < s.count, markup(k) == nil, url(k) == nil { k += 1 }
            return k > i ? k : nil
        }

        /// The parse tree's root, nil where the grammar does not match
        func parse() -> Node? {
            let root = Node(.root)
            var i = 0
            while i < s.count {
                if let e = anyString(i) {
                    root.children.append(Node(.text, content: Array(s[i..<e])))
                    i = e
                } else if let e = url(i) {
                    root.children.append(Node(.url, content: Array(s[i..<e])))
                    i = e
                } else if let r = markup(i) {
                    if let n = r.node { root.children.append(n) }
                    i = r.end
                } else {
                    return nil
                }
            }
            return root
        }
    }

    // MARK: - Drawing

    /// STROKE_GLYPH::Transform of a glyph's strokes: sized, slanted, moved, mirrored about the origin's x and turned
    /// about it
    static func transform(_ strokes: [[DPoint]], size: DPoint, offset: IPoint, tilt: Double, angle: EDAAngle,
                          mirror: Bool, origin: IPoint) -> [[DPoint]] {
        let o = DPoint(origin)
        return strokes.map { stroke in
            stroke.map { q in
                var p = DPoint(q.x * size.x, q.y * size.y)
                if tilt != 0.0 { p.x -= p.y * tilt }
                p = p + DPoint(offset)
                if mirror { p.x = o.x - (p.x - o.x) }
                if angle.degrees != 0 { p = KiMath.rotate(p, around: o, angle) }
                return p
            }
        }
    }

    /// STROKE_FONT::GetTextAsGlyphs: a run of text's glyphs from `position` on, its box, and where the next run starts
    static func textAsGlyphs(_ bbox: inout Box, _ glyphs: inout [[DPoint]]?, _ text: [Unicode.Scalar], size: IPoint,
                             position: IPoint, angle: EDAAngle, mirror: Bool, origin: IPoint, style: Style) -> IPoint {
        var cursor = position
        var glyphSize = DPoint(size)
        let tilt = style.contains(.italic) ? italicTilt : 0.0
        var charCount = 0
        if style.contains(.lowered) || style.contains(.raised) {
            glyphSize = glyphSize * superSubSize
            let offset = style.contains(.lowered) ? subscriptBaselineOffset : superscriptBaselineOffset
            cursor.y = KiMath.cInt(Double(cursor.y) + glyphSize.y * offset)
        }
        for c in text {
            if c == "\t" {
                charCount = (charCount / tabWidth + 1) * tabWidth - 1
                var newCursor = KiMath.cInt(Double(position.x + size.x * charCount) + Double(size.x) * spaceWidth)
                while newCursor <= cursor.x {
                    charCount += tabWidth
                    newCursor += size.x * tabWidth
                }
                cursor.x = newCursor
            } else if c == " " {
                cursor.x += KiMath.round(glyphSize.x * spaceWidth)
            } else {
                var dd = Int(c.value) - 0x20
                if dd < 0 || dd >= glyphCount { dd = Int(("?" as Unicode.Scalar).value) - 0x20 }
                let source = glyph(dd)
                if glyphs != nil {
                    glyphs!.append(contentsOf: transform(source.strokes, size: glyphSize, offset: cursor, tilt: tilt,
                                                         angle: angle, mirror: mirror, origin: origin))
                }
                cursor.x += KiMath.round(source.right * glyphSize.x)
            }
            charCount += 1
        }
        bbox.setOrigin(position)
        bbox.setEnd(IPoint(cursor.x - KiMath.round(glyphSize.x * interChar), KiMath.cInt(Double(cursor.y) - glyphSize.y)))
        bbox.normalize()
        return IPoint(cursor.x, position.y)
    }

    /// drawMarkup: a markup node's text and its children's in turn, overbars over theirs; where the next starts
    static func drawMarkup(_ bbox: inout Box?, _ glyphs: inout [[DPoint]]?, _ node: Node?, position: IPoint, size: IPoint,
                           angle: EDAAngle, mirror: Bool, origin: IPoint, style: Style) -> IPoint {
        var next = position
        var drawOverbar = false
        guard let node else { return next }
        var textStyle = style
        if node.kind != .root {
            if node.kind == .lowered {
                textStyle.insert(.lowered)
            } else if node.kind == .raised {
                textStyle.insert(.raised)
            }
            if node.kind == .overbar { drawOverbar = true }
            if let content = node.content {
                var box = Box()
                next = textAsGlyphs(&box, &glyphs, content, size: size, position: next, angle: angle, mirror: mirror,
                                    origin: origin, style: textStyle)
                bbox?.merge(box)
            }
        }
        for child in node.children {
            next = drawMarkup(&bbox, &glyphs, child, position: next, size: size, angle: angle, mirror: mirror,
                              origin: origin, style: textStyle)
        }
        if drawOverbar && glyphs != nil {
            // (shortened a little so that its round ends do not make it too long)
            let trim = Double(size.x) * 0.1
            let offset = Double(size.y) * overbarHeight
            let bar = [[DPoint(Double(position.x) + trim, Double(position.y) - offset),
                        DPoint(Double(next.x) - trim, Double(next.y) - offset)]]
            glyphs!.append(contentsOf: transform(bar, size: DPoint(1, 1), offset: .zero, tilt: 0, angle: angle,
                                                 mirror: mirror, origin: origin))
        }
        return next
    }

    static func drawMarkup(_ bbox: inout Box?, _ glyphs: inout [[DPoint]]?, _ text: [Unicode.Scalar], position: IPoint,
                           size: IPoint, angle: EDAAngle, mirror: Bool, origin: IPoint, style: Style) -> IPoint {
        drawMarkup(&bbox, &glyphs, MarkupParser(s: text).parse(), position: position, size: size, angle: angle,
                   mirror: mirror, origin: origin, style: style)
    }

    /// TEXT_ATTRIBUTES, as far as the stroke font uses them
    struct Attributes {
        var size = IPoint(1_270_000, 1_270_000)
        var strokeWidth = 0
        var angle = EDAAngle.zero
        /// -1 left (or top), 0 centre, 1 right (or bottom)
        var hAlign = 0
        var vAlign = 0
        var mirrored = false
        var italic = false
        var bold = false
        var lineSpacing = 1.0
    }

    /// wxStringSplit: the text's lines, but for an empty last one
    static func lines(_ text: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
        var out: [[Unicode.Scalar]] = []
        var tmp: [Unicode.Scalar] = []
        for c in text {
            if c == "\n" {
                out.append(tmp)
                tmp = []
            } else {
                tmp.append(c)
            }
        }
        if !tmp.isEmpty { out.append(tmp) }
        return out
    }

    /// FONT::getLinePositions: each line of a text, and where it starts
    static func linePositions(_ text: [Unicode.Scalar], _ position: IPoint, _ attrs: Attributes) -> [([Unicode.Scalar], IPoint)] {
        let lines = lines(text)
        let interline = KiMath.cInt(interline(Double(attrs.size.y)) * attrs.lineSpacing)
        var height = 0
        var extents: [IPoint] = []
        for (i, line) in lines.enumerated() {
            let pos = IPoint(position.x, position.y + i * interline)
            var none: Box? = nil, noGlyphs: [[DPoint]]? = nil
            let end = drawMarkup(&none, &noGlyphs, line, position: pos, size: attrs.size, angle: .zero, mirror: false,
                                 origin: .zero, style: attrs.italic ? .italic : [])
            extents.append(end - pos)
            if i == 0 {
                height = KiMath.cInt(Double(height) + Double(attrs.size.y) * 1.17)   // (a fudge to match 6.0)
            } else {
                height += interline
            }
        }
        var offset = IPoint(0, attrs.size.y)
        // (fudge factors to match 6.0)
        offset.x = KiMath.cInt(Double(offset.x) + Double(attrs.strokeWidth) / 1.52)
        offset.y = KiMath.cInt(Double(offset.y) - Double(attrs.strokeWidth) * 0.052)
        switch attrs.vAlign {
        case 0: offset.y -= height / 2
        case 1: offset.y -= height
        default: break
        }
        return lines.enumerated().map { i, line in
            var lineOffset = offset
            lineOffset.y += i * interline
            switch attrs.hAlign {
            case 0: lineOffset.x = -extents[i].x / 2
            case 1: lineOffset.x = -(extents[i].x + offset.x)
            default: break
            }
            return (line, position + lineOffset)
        }
    }

    /// FONT::Draw: a text's strokes, its lines placed about `position`, turned about it and mirrored about its x
    static func draw(_ text: [Unicode.Scalar], position: IPoint, _ attrs: Attributes) -> [[DPoint]] {
        guard !text.isEmpty else { return [] }
        var glyphs: [[DPoint]]? = []
        for (line, pos) in linePositions(text, position, attrs) {
            var none: Box? = nil
            _ = drawMarkup(&none, &glyphs, line, position: pos, size: attrs.size, angle: attrs.angle,
                           mirror: attrs.mirrored, origin: position, style: attrs.italic ? .italic : [])
        }
        return glyphs ?? []
    }

    /// FONT::StringBoundaryLimits: the size of a line's box, grown by a bit more than half its pen
    static func stringBoundaryLimits(_ text: [Unicode.Scalar], size: IPoint, thickness: Int, bold: Bool, italic: Bool) -> IPoint {
        var box: Box? = Box()
        var noGlyphs: [[DPoint]]? = nil
        var style: Style = []
        if bold { style.insert(.bold) }
        if italic { style.insert(.italic) }
        _ = drawMarkup(&box, &noGlyphs, text, position: .zero, size: size, angle: .zero, mirror: false, origin: .zero,
                       style: style)
        box!.inflate(KiMath.round(Double(thickness) * 1.5))
        return box!.size
    }

    /// The segments CALLBACK_GAL makes of strokes: between each point and the next, made whole (VECTOR2I of a VECTOR2D)
    static func segments(_ strokes: [[DPoint]]) -> [Seg] {
        var out: [Seg] = []
        for stroke in strokes where stroke.count > 1 {
            for i in 1..<stroke.count { out.append(Seg(stroke[i - 1].truncated, stroke[i].truncated)) }
        }
        return out
    }
}
