// Ported from KiCad 10.0.7: common/libeval_compiler/libeval_compiler.cpp and grammar.lemon, include/libeval_compiler/
// libeval_compiler.h (LIBEVAL: the tokenizer, the grammar's precedences as its lemon parser applies them, the code
// generation with its errors and its short-circuit jumps, the stack machine that runs it, VALUE's comparisons),
// pcbnew/pcbexpr_evaluator.cpp (PCBEXPR_UCODE::CreateVarRef, PCBEXPR_VAR_REF::GetValue and the values of layers,
// pin types, net classes and nets, the unit resolvers, PCBEXPR_EVALUATOR) and common/eda_units.cpp
// (DoubleValueFromString, FromUserUnit).
// Copyright (C) 2017 Michael Geselbracht; Copyright (C) 2017-2020 Tomasz Wlostowski; Copyright The KiCad Developers,
// see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

// MARK: - Units (EDA_UNITS, the unit resolvers)

enum RuleUnits {
    /// EDA_UNITS, those a rule's values can have
    enum Unit: Sendable { case inch, mils, mm, um, cm, degrees, percent, unscaled, fs, ps, psPerInch, psPerCm, psPerMm }
    /// EDA_DATA_TYPE
    enum DataType { case distance, unitless, time, lengthDelay }

    /// UNITS_PROVIDER::GetTypeFromUnits
    static func dataType(_ u: Unit) -> DataType {
        switch u {
        case .inch, .mm, .um, .cm, .mils: return .distance
        case .degrees, .percent, .unscaled: return .unitless
        case .fs, .ps: return .time
        case .psPerInch, .psPerCm, .psPerMm: return .lengthDelay
        }
    }

    /// PCBEXPR_UNIT_RESOLVER's units, in the order the lexer tries them
    static let pcbUnits = ["mil", "mm", "in", "deg", "fs", "ps"]
    static let pcbUnitTypes: [Unit] = [.mils, .mm, .inch, .degrees, .fs, .ps]

    /// pcbIUScale's IU_PER_MM, IU_PER_MILS and IU_PER_PS
    static let iuPerMM = 1e6
    static let iuPerMils = 1e6 * 0.0254
    static let iuPerPS = 1e6

    /// FromUserUnit (MM_TO_IU and the like, as the macros expand)
    static func fromUserUnit(_ u: Unit, _ v: Double) -> Double {
        switch u {
        case .um: return v / 1000.0 * iuPerMM
        case .mm: return v * iuPerMM
        case .cm: return v * 10 * iuPerMM
        case .mils: return v * iuPerMils
        case .inch: return v * iuPerMils * 1000
        case .fs: return v / 1000.0 * iuPerPS
        case .ps: return v * iuPerPS
        case .psPerInch: return v / 25.4 * iuPerPS
        case .psPerCm: return v / 10 * iuPerPS
        case .psPerMm: return v * iuPerPS
        case .degrees, .unscaled, .percent: return v
        }
    }

    /// The numeric part of a value as DoubleValueFromString finds it: its first characters that are digits, signs or
    /// decimal separators ('.' and ',' both taken as the C locale's '.'), and what follows
    private static func numericPart(_ text: String) -> (Double, String, Bool) {
        let buf = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        var brk = buf.startIndex
        while brk < buf.endIndex, let c = buf[brk].unicodeScalars.first,
              ("0"..."9").contains(c) || c == "." || c == "-" || c == "+" {
            brk = buf.index(after: brk)
        }
        return (toDouble(String(buf[..<brk])), String(buf[brk...]), brk > buf.startIndex)
    }

    /// wxString::ToDouble as far as a number goes (strtod: the longest prefix that is one, 0 for none)
    static func toDouble(_ s: String) -> Double {
        if let d = Double(s) { return d }
        var best = 0.0
        var prefix = ""
        for ch in s {
            prefix.append(ch)
            if let d = Double(prefix) { best = d }
        }
        return best
    }

    /// DoubleValueFromString( text ): its number, unscaled
    static func doubleValue(_ text: String) -> Double { numericPart(text).0 }

    /// DoubleValueFromString( pcbIUScale, units, text ) of a distance or time: its number in internal units, a unit
    /// written after it taking the place of `units`
    static func doubleValue(_ text: String, _ unitsIn: Unit) -> Double {
        var units = unitsIn
        var (v, rest, _) = numericPart(text)
        let trimmed = String(rest.drop { $0 == " " || $0 == "\t" })
        let unit = String(trimmed.prefix(2)).lowercased()
        switch units {
        case .um, .mm, .cm, .mils, .inch:
            if unit == "um" || unit == "\u{00B5}m" || unit == "\u{03BC}m" {
                units = .um
            } else if unit == "mm" {
                units = .mm
            } else if unit == "cm" {
                units = .cm
            } else if unit == "mi" || unit == "th" {
                units = .mils
            } else if unit == "in" || unit == "\"" {
                units = .inch
            } else if unit == "oz" {
                units = .mils
                v *= 1.37
            }
        case .degrees:
            if unit == "ra" { v *= 180.0 / Double(Float.pi) }
        case .fs, .ps, .psPerInch, .psPerCm, .psPerMm:
            let timeUnit = String(trimmed.prefix(5)).lowercased()
            if timeUnit == "fs" { units = .fs }
            if timeUnit == "ps" {
                units = .ps
            } else if timeUnit == "ps/in" {
                units = .psPerInch
            } else if timeUnit == "ps/cm" {
                units = .psPerCm
            } else if timeUnit == "ps/mm" {
                units = .psPerMm
            }
        default:
            break
        }
        rest = ""
        return fromUserUnit(units, v)
    }

    /// DoubleValueFromString( pcbIUScale, text, value ): a number with one of the units after it, in internal units;
    /// nil where it has no number or no unit KiCad knows
    static func doubleValueWithUnits(_ text: String) -> Double? {
        let (v0, rest, any) = numericPart(text)
        guard any else { return nil }
        var v = v0
        let unit = rest.trimmingCharacters(in: .whitespaces).lowercased()
        let units: Unit
        switch unit {
        case "um", "\u{00B5}m", "\u{03BC}m": units = .um
        case "mm": units = .mm
        case "cm": units = .cm
        case "mil", "mils", "thou": units = .mils
        case "in", "\"": units = .inch
        case "oz":
            units = .mils
            v *= 1.37
        case "ra":
            v *= 180.0 / Double(Float.pi)
            units = .mm
        case "fs": units = .fs
        case "ps": units = .ps
        case "ps/in": units = .psPerInch
        case "ps/cm": units = .psPerCm
        case "ps/mm": units = .psPerMm
        default: return nil
        }
        return fromUserUnit(units, v)
    }

    /// PCBEXPR_UNIT_RESOLVER::Convert
    static func convert(_ s: String, _ unitId: Int) -> Double {
        switch unitId {
        case 0: return doubleValue(s, .mils)
        case 1: return doubleValue(s, .mm)
        case 2: return doubleValue(s, .inch)
        case 4: return doubleValue(s, .fs)
        case 5: return doubleValue(s, .ps)
        default: return toDouble(s)
        }
    }
}

// MARK: - Values (LIBEVAL::VALUE and PCBEXPR's)

/// A value of a rule's expression (LIBEVAL::VALUE), or one of PCBEXPR's that compare in their own ways: a layer's,
/// a pad's pin type's, an item's net class's, an item's net's
final class RuleValue {
    /// VAR_TYPE_T
    enum VarType: Sendable { case string, numeric, numericDouble, undefined, parseError, null }
    enum Special {
        case none
        case layer(Int)
        case pinType
        case netClass(RuleItem)
        case net(RuleItem)
    }

    private(set) var type: VarType
    private var dbl = 0.0
    private var str = ""
    private(set) var isWildcard = false
    var units = RuleUnits.Unit.unscaled
    private var deferredDbl: (() -> Double)?
    private var deferredStr: (() -> String)?
    let special: Special

    init() {
        type = .undefined
        special = .none
    }

    init(_ s: String, wildcard: Bool = false, special: Special = .none) {
        type = .string
        str = s
        isWildcard = wildcard
        self.special = special
    }

    init(_ d: Double) {
        type = .numeric
        dbl = d
        special = .none
    }

    static func null() -> RuleValue {
        let v = RuleValue()
        v.type = .null
        return v
    }

    func set(_ d: Double) {
        type = .numeric
        dbl = d
    }

    func set(_ s: String) {
        type = .string
        str = s
    }

    /// Set( const VALUE& )
    func set(_ v: RuleValue) {
        type = v.type
        dbl = v.dbl
        isWildcard = v.isWildcard
        units = v.units
        if type == .string { str = v.str }
    }

    func setDeferred(_ f: @escaping () -> Double) {
        type = .numeric
        deferredDbl = f
    }

    func setDeferred(_ f: @escaping () -> String) {
        type = .string
        deferredStr = f
    }

    func asDouble() -> Double {
        if let f = deferredDbl {
            dbl = f()
            deferredDbl = nil
        }
        return dbl
    }

    func asString() -> String {
        switch special {
        case .netClass(let item): str = item.netClass.name
        case .net(let item): str = item.netName
        default: break
        }
        if let f = deferredStr {
            str = f()
            deferredStr = nil
        }
        return str
    }

    /// wxString::IsSameAs( other, false )
    static func sameNoCase(_ a: String, _ b: String) -> Bool {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        guard x.count == y.count else { return false }
        for i in x.indices where x[i] != y[i] {
            if Character(x[i]).lowercased() != Character(y[i]).lowercased() { return false }
        }
        return true
    }

    /// VALUE::EqualTo
    private func baseEqualTo(_ ctx: RuleContext, _ b: RuleValue) -> Bool {
        if type == .undefined || b.type == .undefined { return false }
        if type == .null && b.type == .null { return true }
        if type == .numeric && b.type == .numeric {
            return asDouble() == b.asDouble()
        } else if type == .string && b.type == .string {
            if b.isWildcard { return WildMatch.compare(b.asString(), asString(), caseSensitive: false) }
            return Self.sameNoCase(asString(), b.asString())
        }
        return false
    }

    /// The net class names a net class value is made of, matching a string (its wildcards or its letters)
    private func constituentMatches(_ item: RuleItem, _ b: RuleValue) -> Bool {
        for name in item.netClass.constituents {
            if b.isWildcard {
                if WildMatch.compare(b.asString(), name, caseSensitive: false) { return true }
            } else if Self.sameNoCase(name, b.asString()) {
                return true
            }
        }
        return false
    }

    func equalTo(_ ctx: RuleContext, _ b: RuleValue) -> Bool {
        switch special {
        case .layer(let layer):
            // (every layer whose canonical or user name matches the other's string)
            return ctx.board?.layersMatching(b.asString()).contains(layer) ?? false
        case .pinType:
            let thisStr = asString(), otherStr = b.asString()
            if Self.sameNoCase(thisStr, otherStr) { return true }
            if WildMatch.matches(thisStr, otherStr) { return true }
            let alt: String
            switch thisStr {
            case "tri_state": alt = "Tri-state"
            case "power_in": alt = "Power input"
            case "power_out": alt = "Power output"
            case "no_connect": alt = "Unconnected"
            default: alt = ""
            }
            if !alt.isEmpty {
                if Self.sameNoCase(alt, otherStr) { return true }
                if WildMatch.matches(alt, otherStr) { return true }
            }
            return false
        case .netClass(let item):
            if case .netClass(let other) = b.special { return item.netClass.constituents == other.netClass.constituents }
            if b.type == .string && constituentMatches(item, b) { return true }
            return baseEqualTo(ctx, b)
        case .net(let item):
            if case .net(let other) = b.special { return item.netCode == other.netCode }
            return baseEqualTo(ctx, b)
        case .none:
            return baseEqualTo(ctx, b)
        }
    }

    /// NotEqualTo (not EqualTo's inverse: both false for an undefined value)
    func notEqualTo(_ ctx: RuleContext, _ b: RuleValue) -> Bool {
        switch special {
        case .netClass(let item):
            if case .netClass(let other) = b.special { return item.netClass.constituents != other.netClass.constituents }
            if b.type == .string {
                let inConstituents = constituentMatches(item, b)
                let isFullName = baseEqualTo(ctx, b)
                return !inConstituents && !isFullName
            }
        case .net(let item):
            if case .net(let other) = b.special { return item.netCode != other.netCode }
        default:
            break
        }
        if type == .undefined || b.type == .undefined { return false }
        return !equalTo(ctx, b)
    }
}

// MARK: - Variable references (PCBEXPR_VAR_REF)

/// A reference to an item or its property in an expression (PCBEXPR_VAR_REF and the special ones for net classes,
/// net names and types): the item (0 A, 1 B, 2 the layer), what it reads of it
final class RuleVarRef {
    enum Kind { case property, netClass, netName, type, componentClass }
    let kind: Kind
    let itemIndex: Int
    /// The property's name as KiCad's property manager takes it (underscores spaces), lower case
    var property = ""
    var type = RuleValue.VarType.undefined
    var isEnum = false
    var isOptional = false

    init(_ kind: Kind, _ index: Int) {
        self.kind = kind
        itemIndex = index
        switch kind {
        case .netClass, .netName, .type, .componentClass: type = .string
        case .property: break
        }
    }

    /// GetObject: the item of the context it refers to
    func object(_ ctx: RuleContext) -> RuleItem? { itemIndex == 0 ? ctx.items.0 : itemIndex == 1 ? ctx.items.1 : nil }

    /// GetValue
    func value(_ ctx: RuleContext) -> RuleValue {
        switch kind {
        // (of a BOARD_CONNECTED_ITEM, connected or not: a footprint's drawing has a net, the orphaned one)
        case .netClass:
            guard let item = object(ctx), item.kind.isConnectedClass else { return RuleValue() }
            return RuleValue("", special: .netClass(item))
        case .netName:
            guard let item = object(ctx), item.kind.isConnectedClass else { return RuleValue() }
            return RuleValue("", special: .net(item))
        case .type:
            guard let item = object(ctx) else { return RuleValue() }
            return RuleValue(ctx.effectiveType(item).typeName)
        case .componentClass:
            ctx.unsupported("component classes")
            return RuleValue()
        case .property:
            break
        }
        if type == .null { return .null() }
        if itemIndex == 2 { return RuleValue(KiLayer.displayName(ctx.layer), special: .layer(ctx.layer)) }
        guard let item = object(ctx) else { return RuleValue() }
        // (a property the item has not, but its footprint has, its footprint's)
        var target = item
        var prop = RuleProperties.lookup(property, item.kind)
        if prop == nil, let fp = item.parentFootprint, let p = RuleProperties.lookup(property, .footprint) {
            target = fp
            prop = p
        }
        guard let prop else { return RuleValue() }
        guard let v = prop.read(target, ctx) else {
            ctx.unsupported("the '\(prop.name)' property of a \(target.kind.typeName.lowercased())")
            return RuleValue()
        }
        switch v {
        case .int(let i):
            return RuleValue(Double(i))
        case .optionalInt(let i):
            return i.map { RuleValue(Double($0)) } ?? .null()
        case .double(let d):
            return RuleValue(d)
        case .bool(let b):
            return RuleValue(b ? 1 : 0)
        case .string(let s):
            if prop.name == "Pin Type" { return RuleValue(s, special: .pinType) }
            // (if it quacks like a duck, it is a duck: a number with units is a number)
            if let d = RuleUnits.doubleValueWithUnits(s) { return RuleValue(d) }
            return RuleValue(s)
        case .enumString(let s):
            return RuleValue(s)
        case .layer(let l):
            return RuleValue(KiLayer.displayName(l), special: .layer(l))
        }
    }
}

/// What a property of an item reads as
enum RulePropertyValue {
    case int(Int), optionalInt(Int?), double(Double), bool(Bool), string(String), enumString(String), layer(Int)
}

// MARK: - The context (PCBEXPR_CONTEXT)

/// What an expression runs in: the items (A and B), the constraint and layer asked about, the board, the stack
final class RuleContext {
    var constraint: DRCConstraintType
    var layer: Int
    var items: (RuleItem?, RuleItem?)
    let board: RuleBoard?
    var stack: [RuleValue] = []
    /// The error callback (the compiler's, preflighting a function; or a reporter's)
    var errorHandler: ((String) -> Void)?
    /// Items taken as another type (a teardrop as a track)
    var typeOverrides: [ObjectIdentifier: RuleItem.Kind] = [:]

    init(constraint: DRCConstraintType, layer: Int, items: (RuleItem?, RuleItem?), board: RuleBoard?) {
        self.constraint = constraint
        self.layer = layer
        self.items = items
        self.board = board
    }

    func push(_ v: RuleValue) { stack.append(v) }

    func pop() -> RuleValue {
        if stack.isEmpty {
            reportError("Malformed expression")
            return RuleValue()
        }
        return stack.removeLast()
    }

    func top() -> RuleValue {
        if stack.isEmpty {
            reportError("Malformed expression")
            return RuleValue()
        }
        return stack[stack.count - 1]
    }

    var hasErrorCallback: Bool { errorHandler != nil }

    func reportError(_ message: String) { errorHandler?(message) }

    /// GetEffectiveType
    func effectiveType(_ item: RuleItem) -> RuleItem.Kind { typeOverrides[ObjectIdentifier(item)] ?? item.kind }

    /// What the port cannot evaluate as KiCad does, told to the board
    func unsupported(_ what: String) { board?.unsupported.insert(what) }
}

/// A function of the rules' language (a PCBEXPR built-in): run on the context, its arguments on the stack, the
/// item it is called on
typealias RuleFunction = (RuleContext, RuleVarRef?) -> Void

// MARK: - The compiler (LIBEVAL::COMPILER)

/// A compiled expression's code (UCODE), run as KiCad's stack machine runs it
final class RuleCode {
    enum Op {
        case pushVar(RuleVarRef?)
        case pushValue(RuleValue)
        case methodCall(RuleFunction?, RuleVarRef?)
        case binary(LibEvalCompiler.NodeOp)
        case unary(LibEvalCompiler.NodeOp)
        case jz(Int), jnz(Int)
    }

    var ops: [Op] = []
    var hasJumps = false
    var hasGeometryDependentFunctions = false

    /// UCODE::Run: the value left on the stack, 0 if the stack is left other than with one
    func run(_ ctx: RuleContext) -> RuleValue {
        var ip = 0
        while ip < ops.count {
            let next = exec(ops[ip], ctx)
            ip = next < 0 ? ip + 1 : next
        }
        if ctx.stack.count == 1 { return ctx.pop() }
        return RuleValue(0)
    }

    /// UOP::Exec: the next op to run, -1 for the one after
    private func exec(_ op: Op, _ ctx: RuleContext) -> Int {
        switch op {
        case .jz(let target):
            if ctx.top().asDouble() == 0 {
                _ = ctx.pop()
                ctx.push(RuleValue(0))
                return target
            }
            return -1
        case .jnz(let target):
            if ctx.top().asDouble() != 0 {
                _ = ctx.pop()
                ctx.push(RuleValue(1))
                return target
            }
            return -1
        case .pushVar(let ref):
            ctx.push(ref?.value(ctx) ?? RuleValue())
            return -1
        case .pushValue(let v):
            if v.type == .string {
                let copy = RuleValue()
                copy.set(v)
                ctx.push(copy)
            } else {
                ctx.push(v)
            }
            return -1
        case .methodCall(let f, let ref):
            f?(ctx, ref)
            return -1
        case .binary(let o):
            let arg2 = ctx.pop(), arg1 = ctx.pop()
            if ctx.hasErrorCallback {
                if arg1.type == .string && arg2.type == .numeric {
                    ctx.reportError("Type mismatch between '\(arg1.asString())' and \(String(format: "%lf", arg2.asDouble()))")
                } else if arg1.type == .numeric && arg2.type == .string {
                    ctx.reportError("Type mismatch between \(String(format: "%lf", arg1.asDouble())) and '\(arg2.asString())'")
                }
            }
            func resultUnits() -> RuleUnits.Unit {
                if arg1.units == .unscaled && arg2.units != .unscaled { return arg2.units }
                if arg1.units != .unscaled && arg2.units == .unscaled { return arg1.units }
                return arg2.units
            }
            var units = RuleUnits.Unit.unscaled
            let result: Double
            switch o {
            case .add:
                result = arg1.asDouble() + arg2.asDouble()
                units = resultUnits()
            case .sub:
                result = arg1.asDouble() - arg2.asDouble()
                units = resultUnits()
            case .mul:
                result = arg1.asDouble() * arg2.asDouble()
                units = resultUnits()
            case .div:
                result = arg1.asDouble() / arg2.asDouble()
                units = resultUnits()
            case .lessEqual: result = arg1.asDouble() <= arg2.asDouble() ? 1 : 0
            case .greaterEqual: result = arg1.asDouble() >= arg2.asDouble() ? 1 : 0
            case .less: result = arg1.asDouble() < arg2.asDouble() ? 1 : 0
            case .greater: result = arg1.asDouble() > arg2.asDouble() ? 1 : 0
            case .equal:
                result = (arg2.type == .undefined ? arg2.equalTo(ctx, arg1) : arg1.equalTo(ctx, arg2)) ? 1 : 0
            case .notEqual:
                result = (arg2.type == .undefined ? arg2.notEqualTo(ctx, arg1) : arg1.notEqualTo(ctx, arg2)) ? 1 : 0
            case .boolAnd: result = arg1.asDouble() != 0 && arg2.asDouble() != 0 ? 1 : 0
            case .boolOr: result = arg1.asDouble() != 0 || arg2.asDouble() != 0 ? 1 : 0
            default: result = 0
            }
            let rp = RuleValue(result)
            rp.units = units
            ctx.push(rp)
            return -1
        case .unary(let o):
            let arg1 = ctx.pop()
            let v = arg1.asDouble()
            let rp = RuleValue(o == .boolNot ? (v != 0 ? 0 : 1) : (v != 0 ? 1 : 0))
            rp.units = arg1.units
            ctx.push(rp)
            return -1
        }
    }
}

/// LIBEVAL's compiler: an expression's tokens (lexDefault, lexString), parsed as the grammar's lemon parser parses
/// them (its precedences: , && || comparisons ! + - * / . units, from the loosest), its code generated
/// (generateUCode) with the errors KiCad's generation reports
struct LibEvalCompiler {
    enum Units { case pcb, unitless }

    enum NodeOp: Equatable {
        case number, identifier, structRef, string, unit, argList, null
        case mul, div, add, sub, less, greater, lessEqual, greaterEqual, equal, notEqual, boolAnd, boolOr
        case boolNot, funcCall, methodCall

        var isBinary: Bool {
            switch self {
            case .mul, .div, .add, .sub, .less, .greater, .lessEqual, .greaterEqual, .equal, .notEqual, .boolAnd, .boolOr: return true
            default: return false
            }
        }
    }

    final class Node {
        var op: NodeOp
        var str: String?
        var idx = 0
        var leaf: [Node?] = [nil, nil]
        var uop: RuleCode.Op?
        var isTerminal = false
        var isVisited = false
        var srcPos = 0

        init(_ op: NodeOp, str: String? = nil, idx: Int = 0, srcPos: Int) {
            self.op = op
            self.str = str
            self.idx = idx
            self.srcPos = srcPos
        }
    }

    enum Token: Equatable {
        case ends, value(String), unit(Int), string(String), identifier(String)
        case plus, minus, mult, divide, boolNot, less, greater, lessEqual, greaterEqual, equal, notEqual
        case boolAnd, boolOr, parenL, parenR, semicolon, structRef, comma
    }

    let units: Units
    /// The errors it reported (its error callback's messages)
    private(set) var errors: [String] = []
    private var chars: [Unicode.Scalar] = []
    private var pos = 0
    private var tokens: [(Token, Int)] = []
    private var tokenIndex = 0
    private var parseFailed = false

    init(units: Units) { self.units = units }

    private var supportedUnits: [String] { units == .pcb ? RuleUnits.pcbUnits : [] }
    private var supportedUnitTypes: [RuleUnits.Unit] { units == .pcb ? RuleUnits.pcbUnitTypes : [] }
    private var supportedUnitsMessage: String { units == .pcb ? "must be mm, in, mil, deg, fs, or ps" : "" }

    private mutating func reportError(_ message: String) { errors.append(message) }

    // MARK: Tokens

    private static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }
    private static func isAlpha(_ c: Unicode.Scalar) -> Bool { (c.value >= 0x41 && c.value <= 0x5A) || (c.value >= 0x61 && c.value <= 0x7A) }
    private static func isAlnum(_ c: Unicode.Scalar) -> Bool { isDigit(c) || isAlpha(c) }

    private func char(_ i: Int) -> Unicode.Scalar? { i < chars.count ? chars[i] : nil }

    /// MatchAhead: `match` here, and at the end or a character `stop` takes after it
    private func matchAhead(_ match: String, _ stop: (Unicode.Scalar) -> Bool) -> Bool {
        let m = Array(match.unicodeScalars)
        guard chars.count - pos >= m.count, Array(chars[pos..<(pos + m.count)]) == m else { return false }
        return chars.count - pos == m.count || stop(chars[pos + m.count])
    }

    /// The next token (getToken), nil where the lexer reported an error
    private mutating func nextToken() -> Token? {
        // (a string literal: everything to the next quote, a backslash before a quote taking it)
        func string() -> String {
            var rv = ""
            while pos < chars.count && chars[pos] != "'" {
                if chars[pos] == "\\" && pos + 1 < chars.count && chars[pos + 1] == "'" { pos += 1 }
                rv.unicodeScalars.append(chars[pos])
                pos += 1
            }
            pos += 1
            return rv
        }
        if pos >= chars.count { return .ends }
        while char(pos) == " " { pos += 1 }
        guard let ch = char(pos) else { return .ends }
        func isSep(_ c: Unicode.Scalar) -> Bool { c == "." || c == "," }
        if Self.isDigit(ch) {
            // extractNumber: digits and one decimal separator, each separator the C locale's
            var current = ""
            var haveSeparator = false
            var c = ch
            repeat {
                if isSep(c) && haveSeparator { break }
                current.unicodeScalars.append(isSep(c) ? "." : c)
                if isSep(c) { haveSeparator = true }
                pos += 1
                guard let n = char(pos) else { break }
                c = n
            } while Self.isDigit(c) || isSep(c)
            return .value(current)
        }
        for (i, name) in supportedUnits.enumerated() where matchAhead(name, { !Self.isAlnum($0) }) {
            pos += name.unicodeScalars.count
            return .unit(i)
        }
        if ch == "'" {
            pos += 1
            return .string(string())
        }
        if Self.isAlpha(ch) || ch == "_" {
            var current = ""
            while let c = char(pos), Self.isAlnum(c) || c == "_" {
                current.unicodeScalars.append(c)
                pos += 1
            }
            return .identifier(current)
        }
        for (s, t) in [("==", Token.equal), ("!=", .notEqual), ("<=", .lessEqual), (">=", .greaterEqual)] where matchAhead(s, { $0 != "=" }) {
            pos += 2
            return t
        }
        if matchAhead("&&", { $0 != "&" }) {
            pos += 2
            return .boolAnd
        }
        if matchAhead("||", { $0 != "|" }) {
            pos += 2
            return .boolOr
        }
        let single: [Unicode.Scalar: Token] = ["+": .plus, "!": .boolNot, "-": .minus, "*": .mult, "/": .divide, "<": .less,
                                               ">": .greater, "(": .parenL, ")": .parenR, ";": .semicolon, ".": .structRef,
                                               ",": .comma]
        pos += 1
        if let t = single[ch] { return t }
        if ch == "$" && char(pos) == "{" {
            reportError("Unresolved text variable reference")
        } else {
            reportError("Unrecognized character '\(Character(ch))'")
        }
        return nil
    }

    // MARK: Parsing (the grammar, as its lemon parser applies its precedences)

    /// The precedence of an infix token, and whether it is non-associative
    private static func precedence(_ t: Token) -> (Int, Bool)? {
        switch t {
        case .comma: return (1, false)
        case .boolAnd: return (2, false)
        case .boolOr: return (3, false)
        case .less, .greater, .lessEqual, .greaterEqual, .equal, .notEqual: return (5, true)
        case .plus, .minus: return (7, false)
        case .mult, .divide: return (8, false)
        case .structRef: return (9, true)
        default: return nil
        }
    }

    private var peek: Token { tokenIndex < tokens.count ? tokens[tokenIndex].0 : .ends }
    private var peekPos: Int { tokenIndex < tokens.count ? tokens[tokenIndex].1 : chars.count }

    private mutating func advance() -> Token {
        let t = peek
        tokenIndex += 1
        return t
    }

    /// An operand and the operators binding more tightly than `minPrecedence` after it
    private mutating func parseExpression(_ minPrecedence: Int) -> Node? {
        guard var left = parsePrefix() else { return nil }
        while let (prec, nonassoc) = Self.precedence(peek), prec >= minPrecedence {
            let opToken = advance()
            let pos = peekPos
            guard let right = parseExpression(prec + 1) else { return nil }
            let op: NodeOp
            switch opToken {
            case .comma: op = .argList
            case .boolAnd: op = .boolAnd
            case .boolOr: op = .boolOr
            case .less: op = .less
            case .greater: op = .greater
            case .lessEqual: op = .lessEqual
            case .greaterEqual: op = .greaterEqual
            case .equal: op = .equal
            case .notEqual: op = .notEqual
            case .plus: op = .add
            case .minus: op = .sub
            case .mult: op = .mul
            case .divide: op = .div
            default: op = .structRef
            }
            let n = Node(op, srcPos: pos)
            n.leaf = [left, right]
            left = n
            // (a non-associative operator twice in a row is the grammar's syntax error)
            if nonassoc, let (p2, _) = Self.precedence(peek), p2 == prec {
                parseFailed = true
                return nil
            }
        }
        return left
    }

    private mutating func parsePrefix() -> Node? {
        let pos = peekPos
        switch advance() {
        case .value(let s):
            let n = Node(.number, str: s, srcPos: pos)
            if case .unit(let u) = peek {
                _ = advance()
                n.leaf[0] = Node(.unit, idx: u, srcPos: peekPos)
            }
            return n
        case .string(let s):
            return Node(.string, str: s, srcPos: pos)
        case .identifier(let s):
            if peek == .parenL {
                _ = advance()
                let call = Node(.funcCall, srcPos: pos)
                call.leaf[0] = Node(.identifier, str: s, srcPos: pos)
                if peek == .parenR {
                    _ = advance()
                    call.leaf[1] = Node(.null, srcPos: peekPos)
                    return call
                }
                guard let args = parseExpression(1), advance() == .parenR else {
                    parseFailed = true
                    return nil
                }
                call.leaf[1] = args
                return call
            }
            return Node(.identifier, str: s, srcPos: pos)
        case .parenL:
            guard let inner = parseExpression(1), advance() == .parenR else {
                parseFailed = true
                return nil
            }
            // (a copy of the node within)
            let n = Node(inner.op, str: inner.str, idx: inner.idx, srcPos: peekPos)
            n.leaf = inner.leaf
            return n
        case .boolNot:
            guard let operand = parseExpression(7) else { return nil }
            let n = Node(.boolNot, srcPos: pos)
            n.leaf[0] = operand
            return n
        case .minus:
            guard let operand = parseExpression(8) else { return nil }
            let n = Node(.sub, srcPos: pos)
            n.leaf = [Node(.number, srcPos: pos), operand]
            return n
        case .plus:
            guard let operand = parseExpression(8) else { return nil }
            let n = Node(operand.op, str: operand.str, idx: operand.idx, srcPos: pos)
            n.leaf = operand.leaf
            return n
        default:
            parseFailed = true
            return nil
        }
    }

    // MARK: Compiling

    /// Compile: the expression's code, nil if it has a syntax error (the errors KiCad's code generation reports,
    /// in `errors`, do not stop it)
    mutating func compile(_ text: String) -> RuleCode? {
        chars = Array(text.unicodeScalars)
        pos = 0
        errors = []
        tokens = []
        tokenIndex = 0
        parseFailed = false
        let code = RuleCode()
        if chars.isEmpty {
            code.ops.append(.pushValue(RuleValue(1)))
            return code
        }
        while true {
            let start = pos
            guard let t = nextToken() else { return nil }
            tokens.append((t, start))
            if t == .ends { break }
        }
        // (a statement: nothing, or one expression, before the end)
        var tree: Node?
        if peek != .ends {
            tree = parseExpression(1)
            if parseFailed || tree == nil || peek != .ends {
                reportError("Syntax error")
                return nil
            }
        }
        generate(tree, code)
        return code
    }

    /// squashParamList: a function's arguments in order
    private static func squash(_ root: Node?) -> [Node] {
        guard let root else { return [] }
        var args: [Node] = []
        if root.op != .argList && root.op != .null {
            args.append(root)
        } else {
            var n: Node? = root
            repeat {
                if let l1 = n!.leaf[1] { args.append(l1) }
                n = n!.leaf[0]
            } while n != nil && n!.op == .argList
            if let n { args.append(n) }
        }
        return args.reversed()
    }

    /// generateUCode
    private mutating func generate(_ tree: Node?, _ code: RuleCode) {
        guard let tree else {
            // (an empty expression is true)
            code.ops.append(.pushValue(RuleValue(1)))
            return
        }
        func prepare(_ n: Node) {
            n.isVisited = false
            if n.op == .funcCall, let f = n.leaf[0] { f.leaf = [nil, nil] }
            if let l = n.leaf[0] { prepare(l) }
            if let l = n.leaf[1] { prepare(l) }
        }
        prepare(tree)
        var stack: [Node] = [tree]
        var numericValueCount = 0
        var missingUnitsMsg = ""
        var jumps: [ObjectIdentifier: Int] = [:]
        while let node = stack.last {
            switch node.op {
            case .funcCall:
                if node.uop == nil {
                    reportError("Unknown parent of function parameters")
                    node.uop = .pushValue(RuleValue(0))
                }
                node.isTerminal = true
            case .structRef:
                guard let l0 = node.leaf[0], let l1 = node.leaf[1] else { break }
                if l0.op != .identifier {
                    reportError("Unknown parent of property")
                    l0.isVisited = true
                    l1.isVisited = true
                    node.uop = .pushValue(RuleValue(0))
                    node.isTerminal = true
                    break
                }
                let itemName = l0.str ?? ""
                switch l1.op {
                case .identifier:
                    let propName = l1.str ?? ""
                    let vref = RuleProperties.makeVarRef(itemName, propName)
                    if vref == nil {
                        reportError("Unrecognized item '\(itemName)'")
                    } else if vref!.type == .parseError {
                        reportError("Unrecognized property '\(propName)'")
                    }
                    l0.isVisited = true
                    l1.isVisited = true
                    node.uop = .pushVar(vref)
                    node.isTerminal = true
                case .funcCall:
                    let vref = RuleProperties.makeVarRef(itemName, "")
                    if vref == nil { reportError("Unrecognized item '\(itemName)'") }
                    let functionName = l1.leaf[0]?.str ?? ""
                    let lower = functionName.lowercased()
                    let fn = RuleFunctions.lookup(lower)
                    if RuleFunctions.geometryDependent.contains(lower) { code.hasGeometryDependentFunctions = true }
                    let params = Self.squash(l1.leaf[1])
                    if fn == nil { reportError("Unrecognized function '\(functionName)'") }
                    if let fn {
                        // preflight the call: its arguments as strings, its errors the compiler's
                        let preflight = RuleContext(constraint: .null, layer: KiLayer.fCu, items: (nil, nil), board: nil)
                        for p in params { preflight.push(RuleValue(p.str ?? "")) }
                        var preflightErrors: [String] = []
                        preflight.errorHandler = { preflightErrors.append($0) }
                        fn(preflight, vref)
                        _ = preflight.pop()
                        errors += preflightErrors
                    }
                    l0.isVisited = true
                    l1.isVisited = true
                    l1.leaf[0]?.isVisited = true
                    l1.leaf[1]?.isVisited = true
                    // (the struct reference's place taken by the call and its arguments)
                    stack.removeLast()
                    stack.append(l1)
                    stack += params
                    l1.uop = .methodCall(fn, vref)
                    node.isTerminal = false
                default:
                    if RuleProperties.makeVarRef(itemName, l1.str ?? "") == nil { reportError("Unrecognized item '\(itemName)'") }
                    reportError("Unrecognized property '\(l1.str ?? "")'")
                    l0.isVisited = true
                    l1.isVisited = true
                    node.uop = .pushValue(RuleValue(0))
                    node.isTerminal = true
                }
            case .number:
                let value: Double
                var unitsType = RuleUnits.Unit.unscaled
                if node.str == nil {
                    value = 0
                } else if let son = node.leaf[0], son.op == .unit {
                    if supportedUnits.isEmpty { reportError("Unexpected units for '\(node.str!)'") }
                    let u = son.idx
                    unitsType = u < supportedUnitTypes.count ? supportedUnitTypes[u] : .unscaled
                    value = RuleUnits.convert(node.str!, u)
                    son.isVisited = true
                } else {
                    if !supportedUnitsMessage.isEmpty {
                        missingUnitsMsg = "Missing units for '\(node.str!)' (\(supportedUnitsMessage))"
                    }
                    value = RuleUnits.doubleValue(node.str!)
                }
                let v = RuleValue(value)
                v.units = unitsType
                node.uop = .pushValue(v)
                node.isTerminal = true
                numericValueCount += 1
            case .string:
                let s = node.str ?? ""
                node.uop = .pushValue(RuleValue(s, wildcard: s.contains("?") || s.contains("*")))
                node.isTerminal = true
            case .identifier:
                let vref = RuleProperties.makeVarRef(node.str ?? "", "")
                if vref == nil { reportError("Unrecognized item '\(node.str ?? "")'") }
                node.uop = .pushVar(vref)
                node.isTerminal = true
            default:
                if node.op.isBinary {
                    node.uop = .binary(node.op)
                } else if node.op == .boolNot {
                    node.uop = .unary(node.op)
                } else {
                    node.uop = nil
                }
                node.isTerminal = (node.leaf[0] == nil || node.leaf[0]!.isVisited) && (node.leaf[1] == nil || node.leaf[1]!.isVisited)
            }
            if !node.isTerminal {
                if let l0 = node.leaf[0], !l0.isVisited {
                    stack.append(l0)
                    l0.isVisited = true
                } else if let l1 = node.leaf[1], !l1.isVisited {
                    // (the short-circuit jump of && and ||, past the right operand)
                    if node.op == .boolAnd || node.op == .boolOr {
                        jumps[ObjectIdentifier(node)] = code.ops.count
                        code.ops.append(node.op == .boolAnd ? .jz(-1) : .jnz(-1))
                        code.hasJumps = true
                    }
                    stack.append(l1)
                    l1.isVisited = true
                }
                continue
            }
            node.isVisited = true
            if let uop = node.uop {
                code.ops.append(uop)
                node.uop = nil
                if let j = jumps[ObjectIdentifier(node)] {
                    switch code.ops[j] {
                    case .jz: code.ops[j] = .jz(code.ops.count)
                    default: code.ops[j] = .jnz(code.ops.count)
                    }
                }
            }
            stack.removeLast()
        }
        // (a single number with no units is reported: it would be nanometres)
        if !missingUnitsMsg.isEmpty && numericValueCount == 1 { reportError(missingUnitsMsg) }
    }
}

// MARK: - Conditions (DRC_RULE_CONDITION)

/// A rule's condition or an assertion's test: its expression and code (DRC_RULE_CONDITION)
final class RuleCondition {
    let expression: String
    private(set) var code: RuleCode?
    /// What its compilation reported (the code generation's errors, a syntax error)
    private(set) var errors: [String] = []

    init(_ expression: String) { self.expression = expression }

    /// Compile, with PCBEXPR_UNIT_RESOLVER's units: false for a syntax error, after which it has no code that runs
    @discardableResult
    func compile() -> Bool {
        var compiler = LibEvalCompiler(units: .pcb)
        code = compiler.compile(expression)
        errors = compiler.errors
        if code == nil {
            // (KiCad's code is the empty one it started with, which leaves nothing on the stack: false)
            code = RuleCode()
            return false
        }
        return true
    }

    var hasGeometryDependentFunctions: Bool { code?.hasGeometryDependentFunctions ?? false }

    /// EvaluateFor: true for an empty expression; the items one way round, then (conditions being commutative) the
    /// other; a teardrop taken as a track
    func evaluate(_ a: RuleItem?, _ b: RuleItem?, constraint: DRCConstraintType, layer: Int, board: RuleBoard) -> Bool {
        if expression.isEmpty { return true }
        guard let code else { return false }
        let ctx = RuleContext(constraint: constraint, layer: layer, items: (a, b), board: board)
        if let a, a.kind == .zone && a.isTeardrop { ctx.typeOverrides[ObjectIdentifier(a)] = .track }
        if let b, b.kind == .zone && b.isTeardrop { ctx.typeOverrides[ObjectIdentifier(b)] = .track }
        if code.run(ctx).asDouble() != 0 { return true }
        if b != nil {
            // (on the same context: what a run left on the stack, it left for the other)
            ctx.items = (b, a)
            if code.run(ctx).asDouble() != 0 { return true }
        }
        return false
    }
}
