import Foundation

/// A node of a KiCad S-expression, the language of KiCad's boards, footprints and library tables: a symbol (a keyword or
/// a number, written bare), a string (written in quotes) or a list. Nodes are objects so that a board can be edited
/// where it stands: a footprint found in the tree is changed in place, and the file written again keeps everything
/// JSpice does not know about exactly as KiCad wrote it.
public final class SExpr {
    public enum Kind: Sendable { case symbol, string, list }

    public var kind: Kind
    /// A symbol's or a string's text (a string's without its quotes and escapes)
    public var text: String
    /// A list's items
    public var items: [SExpr]

    public init(symbol: String) { kind = .symbol; text = symbol; items = [] }
    public init(string: String) { kind = .string; text = string; items = [] }
    public init(list items: [SExpr]) { kind = .list; text = ""; self.items = items }

    /// A list headed by a keyword: `SExpr("at", 20, 20)` is `(at 20 20)`
    public convenience init(_ head: String, _ arguments: SExprConvertible...) {
        self.init(list: [SExpr(symbol: head)] + arguments.map(\.sexpr))
    }

    public convenience init(_ head: String, _ arguments: [SExprConvertible]) {
        self.init(list: [SExpr(symbol: head)] + arguments.map(\.sexpr))
    }

    public var isList: Bool { kind == .list }

    /// The keyword a list starts with
    public var head: String? {
        guard kind == .list, let first = items.first, first.kind == .symbol else { return nil }
        return first.text
    }

    /// The items after the head
    public var arguments: ArraySlice<SExpr> { items.dropFirst() }

    /// The first list in this one headed by `name`
    public subscript(_ name: String) -> SExpr? { items.first { $0.head == name } }

    /// Every list in this one headed by `name`
    public func all(_ name: String) -> [SExpr] { items.filter { $0.head == name } }

    /// The text of the argument at `index` (0 is the first after the head)
    public func text(at index: Int) -> String? {
        let i = index + 1
        guard i < items.count, items[i].kind != .list else { return nil }
        return items[i].text
    }

    public func number(at index: Int) -> Double? { text(at: index).flatMap(Double.init) }

    /// The first argument of the list headed by `name`: `(layer "F.Cu")`'s "F.Cu"
    public func value(_ name: String) -> String? { self[name]?.text(at: 0) }

    /// Whether `(name yes)` is set (or, as KiCad writes some flags, the bare symbol `name` is among the arguments)
    public func flag(_ name: String) -> Bool {
        if let list = self[name] { return list.text(at: 0) != "no" }
        return arguments.contains { $0.kind == .symbol && $0.text == name }
    }

    /// Puts `node` in the place of the first list headed as it is, or after the last item that comes before it in
    /// `order` (KiCad reads its lists in any order, but writes them in its own, so following it keeps files alike)
    public func set(_ node: SExpr, after order: [String] = []) {
        if let i = items.firstIndex(where: { $0.head == node.head }) {
            items[i] = node
            return
        }
        insert(node, after: order)
    }

    /// Inserts `node` after the last item headed by one of `order`, or at the end
    public func insert(_ node: SExpr, after order: [String]) {
        if let i = items.lastIndex(where: { item in item.head.map(order.contains) ?? false }) {
            items.insert(node, at: i + 1)
        } else {
            items.append(node)
        }
    }

    /// Removes every list headed by `name`
    public func remove(_ name: String) { items.removeAll { $0.head == name } }

    public func remove(_ node: SExpr) { items.removeAll { $0 === node } }

    /// A copy of the whole tree under this node
    public func copy() -> SExpr {
        switch kind {
        case .symbol: return SExpr(symbol: text)
        case .string: return SExpr(string: text)
        case .list: return SExpr(list: items.map { $0.copy() })
        }
    }

    /// Every node under this one (itself first), depth first
    public func walk(_ visit: (SExpr) -> Void) {
        visit(self)
        for item in items { item.walk(visit) }
    }

    // MARK: - Reading

    public struct ParseError: Error, CustomStringConvertible {
        public var description: String
    }

    /// Reads the first expression in `text`
    public static func parse(_ text: String) throws -> SExpr {
        var reader = Reader(Array(text.utf8))
        reader.skipSpace()
        let node = try reader.expression()
        return node
    }

    struct Reader {
        let bytes: [UInt8]
        var i = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSpace() {
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0a || bytes[i] == 0x0d { i += 1 }
        }

        mutating func expression() throws -> SExpr {
            guard i < bytes.count else { throw ParseError(description: "unexpected end of file") }
            switch bytes[i] {
            case UInt8(ascii: "("):
                i += 1
                var items: [SExpr] = []
                while true {
                    skipSpace()
                    guard i < bytes.count else { throw ParseError(description: "a list is not closed") }
                    if bytes[i] == UInt8(ascii: ")") { i += 1; break }
                    items.append(try expression())
                }
                return SExpr(list: items)
            case UInt8(ascii: ")"):
                throw ParseError(description: "unexpected ) at byte \(i)")
            case UInt8(ascii: "\""):
                i += 1
                var out: [UInt8] = []
                while true {
                    guard i < bytes.count else { throw ParseError(description: "a string is not closed") }
                    let c = bytes[i]
                    i += 1
                    if c == UInt8(ascii: "\"") { break }
                    if c == UInt8(ascii: "\\"), i < bytes.count {
                        let e = bytes[i]
                        i += 1
                        switch e {
                        case UInt8(ascii: "n"): out.append(0x0a)
                        case UInt8(ascii: "r"): out.append(0x0d)
                        case UInt8(ascii: "t"): out.append(0x09)
                        default: out.append(e)
                        }
                    } else {
                        out.append(c)
                    }
                }
                return SExpr(string: String(decoding: out, as: UTF8.self))
            default:
                let start = i
                while i < bytes.count {
                    let c = bytes[i]
                    if c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d || c == UInt8(ascii: "(") || c == UInt8(ascii: ")") { break }
                    i += 1
                }
                return SExpr(symbol: String(decoding: bytes[start..<i], as: UTF8.self))
            }
        }
    }

    // MARK: - Writing

    /// The tree on one line, items a space apart
    public var compact: String {
        var out = ""
        appendCompact(to: &out)
        return out
    }

    func appendCompact(to out: inout String) {
        switch kind {
        case .symbol: out += text
        case .string: out += SExpr.quoted(text)
        case .list:
            out += "("
            for (n, item) in items.enumerated() {
                if n > 0 { out += " " }
                item.appendCompact(to: &out)
            }
            out += ")"
        }
    }

    /// A string as KiCad quotes it (OUTPUTFORMATTER::Quotew)
    public static func quoted(_ text: String) -> String {
        var out = "\""
        for c in text.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.unicodeScalars.append(c)
            }
        }
        return out + "\""
    }

    /// The tree as KiCad writes its files: KICAD_FORMAT::Prettify (common/io/kicad/kicad_io_utils.cpp) applied to it
    public func formatted(_ mode: FormatMode = .normal) -> String {
        SExpr.prettify(compact, mode)
    }

    public enum FormatMode: Sendable {
        /// Boards and footprints
        case normal
        /// Schematics: fonts, strokes and fills kept on one line
        case compactTextProperties
        /// Library tables: each library on one line
        case libraryTable
    }

    /// KiCad's own pretty printer, character for character, so that a board JSpice writes reads as one KiCad wrote:
    /// one list a line, indented by tabs, lists of points run together up to column 99, and long runs of tokens broken
    /// after column 72
    public static func prettify(_ source: String, _ mode: FormatMode = .normal) -> String {
        let quoteChar = UInt8(ascii: "\"")
        let xySpecialCaseColumnLimit = 99
        let consecutiveTokenWrapThreshold = 72
        let textSpecialCase = mode == .compactTextProperties
        let libSpecialCase = mode == .libraryTable

        let src = Array(source.utf8)
        var formatted: [UInt8] = []
        formatted.reserveCapacity(src.count + src.count / 4)

        var listDepth = 0
        var libDepth = 0
        var lastNonWhitespace: UInt8 = 0
        var inQuote = false
        var hasInsertedSpace = false
        var inMultiLineList = false
        var inXY = false
        var inShortForm = false
        var inLibRow = false
        var shortFormDepth = 0
        var column = 0
        var backslashCount = 0

        func isWhitespace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d }
        func nextNonWhitespace(_ at: Int) -> UInt8 {
            var seek = at
            while seek < src.count, isWhitespace(src[seek]) { seek += 1 }
            return seek < src.count ? src[seek] : 0
        }
        func isXY(_ at: Int) -> Bool {
            at + 3 < src.count && src[at + 1] == UInt8(ascii: "x") && src[at + 2] == UInt8(ascii: "y") && src[at + 3] == 0x20
        }
        func token(_ at: Int) -> String {
            var seek = at + 1
            var t: [UInt8] = []
            while seek < src.count, (src[seek] >= 0x41 && src[seek] <= 0x5a) || (src[seek] >= 0x61 && src[seek] <= 0x7a) {
                t.append(src[seek])
                seek += 1
            }
            return String(decoding: t, as: UTF8.self)
        }
        func isShortForm(_ at: Int) -> Bool {
            ["font", "stroke", "fill", "teardrop", "offset", "rotate", "scale"].contains(token(at))
        }
        func newline(_ depth: Int) {
            formatted.append(0x0a)
            formatted.append(contentsOf: [UInt8](repeating: 0x09, count: depth))
        }

        var cursor = 0
        while cursor < src.count {
            let c = src[cursor]
            let next = nextNonWhitespace(cursor)
            if isWhitespace(c) && !inQuote {
                if !hasInsertedSpace && listDepth > 0 && lastNonWhitespace != UInt8(ascii: "(")
                    && next != UInt8(ascii: ")") && next != UInt8(ascii: "(") {
                    if inXY || column < consecutiveTokenWrapThreshold {
                        formatted.append(0x20)
                        column += 1
                    } else if inShortForm || inLibRow {
                        formatted.append(0x20)
                    } else {
                        newline(listDepth)
                        column = listDepth
                        inMultiLineList = true
                    }
                    hasInsertedSpace = true
                }
            } else {
                hasInsertedSpace = false
                if c == UInt8(ascii: "(") && !inQuote {
                    let currentIsXY = isXY(cursor)
                    let currentIsShortForm = textSpecialCase && isShortForm(cursor)
                    let currentIsLib = libSpecialCase && token(cursor) == "lib"
                    if formatted.isEmpty {
                        formatted.append(c)
                        column += 1
                    } else if inXY && currentIsXY && column < xySpecialCaseColumnLimit {
                        formatted.append(0x20)
                        formatted.append(c)
                        column += 2
                    } else if inShortForm || inLibRow {
                        formatted.append(0x20)
                        formatted.append(c)
                        column += 2
                    } else {
                        newline(listDepth)
                        formatted.append(c)
                        column = listDepth + 1
                    }
                    inXY = currentIsXY
                    if currentIsShortForm {
                        inShortForm = true
                        shortFormDepth = listDepth
                    } else if currentIsLib {
                        inLibRow = true
                        libDepth = listDepth
                    }
                    listDepth += 1
                } else if c == UInt8(ascii: ")") && !inQuote {
                    if listDepth > 0 { listDepth -= 1 }
                    if inShortForm {
                        formatted.append(c)
                        column += 1
                    } else if inLibRow && listDepth == libDepth {
                        formatted.append(c)
                        inLibRow = false
                    } else if lastNonWhitespace == UInt8(ascii: ")") || inMultiLineList {
                        newline(listDepth)
                        formatted.append(c)
                        column = listDepth + 1
                        inMultiLineList = false
                    } else {
                        formatted.append(c)
                        column += 1
                    }
                    if shortFormDepth == listDepth {
                        inShortForm = false
                        shortFormDepth = 0
                    }
                } else {
                    if c == UInt8(ascii: "\\") {
                        backslashCount += 1
                    } else if c == quoteChar && backslashCount & 1 == 0 {
                        inQuote.toggle()
                    }
                    if c != UInt8(ascii: "\\") { backslashCount = 0 }
                    formatted.append(c)
                    // (KiCad counts bytes, as its std::string does)
                    column += 1
                }
                lastNonWhitespace = c
            }
            cursor += 1
        }
        formatted.append(0x0a)
        return String(decoding: formatted, as: UTF8.self)
    }
}

/// What can stand as an argument of a list: numbers are written as KiCad writes them, strings quoted, and nodes as
/// they are
public protocol SExprConvertible {
    var sexpr: SExpr { get }
}

extension SExpr: SExprConvertible {
    public var sexpr: SExpr { self }
}

extension String: SExprConvertible {
    public var sexpr: SExpr { SExpr(string: self) }
}

extension Double: SExprConvertible {
    public var sexpr: SExpr { SExpr(symbol: KiCadNumber.format(self)) }
}

extension Int: SExprConvertible {
    public var sexpr: SExpr { SExpr(symbol: String(self)) }
}

/// A bare keyword argument: `(attr smd)`'s smd
public struct Keyword: SExprConvertible {
    public var name: String
    public init(_ name: String) { self.name = name }
    public var sexpr: SExpr { SExpr(symbol: name) }
}

public enum KiCadNumber {
    /// A length in millimetres or an angle in degrees as KiCad writes it (FormatDouble2Str on a whole number of
    /// nanometres): no more digits than it takes, no trailing zeros
    public static func format(_ value: Double) -> String {
        // lengths are whole nanometres on a board
        var v = (value * 1e6).rounded() / 1e6
        if v == 0 { v = 0 }  // no "-0"
        if v != 0 && abs(v) <= 0.0001 {
            var s = String(format: "%.16f", v)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s
        }
        return String(format: "%.10g", v)
    }
}
