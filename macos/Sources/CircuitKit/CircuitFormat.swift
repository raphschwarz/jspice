import Foundation

// The .jspice file format: its version, and how a circuit file holding things this build does not understand is still
// read (keeping what it does understand) and written back without losing the rest.

extension Circuit {
    /// The version of the circuit file format this build writes, saved at the top of every circuit file as
    /// `formatVersion` (nested block circuits do not carry it: they are part of the file they are in).
    ///
    /// The number goes up only for a change an older reader cannot safely ignore: a field whose meaning, unit or type
    /// changes, a field that is moved or renamed, or data that must be read for the rest to make sense. Additions an
    /// older reader can skip do not change it: a new part kind, scope quantity or plot (older builds keep such entries
    /// in the file without drawing or simulating them), a new optional field (kept as it is), a new parameter key.
    /// A file without the field is version 1, the format of every file written before the field existed.
    ///
    /// A file of a newer version still opens, with a note in `loadNotes`; saving it again writes its own (newer)
    /// version back, since the parts this build kept unread are in that newer format.
    public static let formatVersion = 1

    /// The format version of the file this circuit was read from (1 for a file without one), or nil for a circuit not
    /// read from a file or read as a block inside one
    public var fileFormatVersion: Int? { loadInfo.fileVersion }

    /// What this build left out when reading the circuit's file, in words to show the person who opened it, including
    /// what was left out inside its blocks; empty for an ordinary file. Not saved.
    public var loadNotes: [String] {
        var notes: [String] = []
        if let version = loadInfo.fileVersion, version > Self.formatVersion {
            notes.append("This file was saved by a newer version of JSpice (file format \(version); this version reads "
                + "format \(Self.formatVersion)). Some of it may be missing or behave differently here, and saving it "
                + "with this version may not keep everything the newer version added.")
        }
        notes += preserved.notes
        for element in elements {
            guard let block = element.block else { continue }
            let label = element.name.isEmpty ? block.name : element.name
            notes += block.circuit.loadNotes.map { "In block \u{201C}\(label)\u{201D}: \($0)" }
        }
        return notes
    }

    /// Reads a circuit file. Parts, scope traces and MIDI mappings this build cannot read are left out of the circuit and
    /// kept to be written back on saving (see `loadNotes`); anything that is not a JSpice circuit at all throws a
    /// `CircuitFileError`, with a message to show rather than a decoding error's.
    public static func decodeDocument(from data: Data) throws -> Circuit {
        let circuit: Circuit
        do {
            circuit = try JSONDecoder().decode(Circuit.self, from: data)
        } catch let error as DecodingError {
            throw CircuitFileError.notACircuit(detail: CircuitFileError.describe(error))
        }
        guard circuit.loadInfo.recognized else {
            throw CircuitFileError.notACircuit(detail: "It has none of the fields a JSpice circuit file has.")
        }
        return circuit
    }
}

extension Circuit {
    /// This circuit with what `original`'s file held that this build could not read (`preserved`) and the version of
    /// that file carried over: for a circuit rebuilt from `original` (Tidy Up, a change made by an AI agent), so that a
    /// newer file's parts and fields still go back into it on saving
    public func carryingPreserved(from original: Circuit) -> Circuit {
        var result = self
        result.preserved = original.preserved
        if result.loadInfo.fileVersion == nil { result.loadInfo.fileVersion = original.loadInfo.fileVersion }
        return result
    }
}

extension Element {
    /// Reads a list of parts (as copied to the pasteboard) one part at a time: the parts this build can read, and those
    /// it cannot (a kind a newer JSpice added), as they were, with their places in the list. Throws only when the data
    /// is not a list.
    public static func decodeList(from data: Data) throws -> (elements: [Element], leftOut: [PreservedEntry]) {
        let entries = try JSONDecoder().decode([Tolerant<Element>].self, from: data)
        let split = Tolerant<Element>.split(entries)
        return (split.values, split.preserved)
    }
}

/// A file that could not be read as a circuit
public enum CircuitFileError: LocalizedError, Equatable {
    case notACircuit(detail: String)

    public var errorDescription: String? {
        "This file is not a JSpice circuit, or it is damaged."
    }

    public var failureReason: String? {
        switch self {
        case .notACircuit(let detail): return detail
        }
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return keys.isEmpty ? "" : " (at \(keys.joined(separator: ".")))"
        }
        switch error {
        case .dataCorrupted(let context): return "It is not valid JSON\(path(context))."
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context):
            return "\(context.debugDescription)\(path(context))"
        @unknown default: return "\(error)"
        }
    }
}

/// Any JSON value, kept as it was read so it can be written back: the parts of a file this build does not understand
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    /// A number. Kept as a Double, which writes back as it was read for every number written from a Double, and for
    /// whole numbers up to 2^53.
    case number(Double)
    /// A whole number too large for a Double to hold exactly
    case integer(Int64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            if value == value.rounded(), abs(value) >= 9_007_199_254_740_992, let exact = try? container.decode(Int64.self) {
                self = .integer(exact)
            } else {
                self = .number(value)
            }
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// The value of a key of an object
    public subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

/// A coding key of any name, for reading and writing the keys a type does not know
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// One entry of a list in the file (a part, a scope trace, a MIDI mapping) that this build could not read, as it was
/// in the file, with its place in the list so it goes back there when the circuit is written
public struct PreservedEntry: Hashable, Sendable {
    /// Its index in the list as the file had it
    public var index: Int
    public var raw: JSONValue

    public init(index: Int, raw: JSONValue) {
        self.index = index
        self.raw = raw
    }
}

/// What a circuit's file held that this build did not read, kept to be written back. It takes part in the circuit's
/// equality: two circuits that would save differently are not equal.
public struct PreservedContent: Hashable, Sendable {
    /// Parts of kinds this build does not know, or that it could not read; not drawn or simulated
    public var elements: [PreservedEntry] = []
    public var scopes: [PreservedEntry] = []
    public var midiMappings: [PreservedEntry] = []
    /// Top-level fields this build does not know
    public var fields: [String: JSONValue] = [:]
    /// Fields this build knows but could not read, by key: the circuit has the default in their place, and the field is
    /// written back as it was while that default is left unchanged
    public var unreadableFields: [String: JSONValue] = [:]

    public init() {}

    public var isEmpty: Bool {
        elements.isEmpty && scopes.isEmpty && midiMappings.isEmpty && fields.isEmpty && unreadableFields.isEmpty
    }

    var notes: [String] {
        var notes: [String] = []
        let kinds = elements.map { $0.raw["kind"]?.stringValue }
        let unknown = kinds.compactMap { $0 }.filter { ElementKind(rawValue: $0) == nil }
        if !unknown.isEmpty {
            let names = Self.distinct(unknown)
            let one = unknown.count == 1
            notes.append("\(unknown.count) \(one ? "part" : "parts") this version of JSpice does not know "
                + "(\(names.count == 1 ? "kind" : "kinds"): \(names.joined(separator: ", "))) \(one ? "was" : "were") left "
                + "out of the drawing and the simulation; \(one ? "it is" : "they are") kept in the file.")
        }
        let unreadable = kinds.filter { $0.map { ElementKind(rawValue: $0) != nil } ?? true }
        if !unreadable.isEmpty {
            let names = Self.distinct(unreadable.compactMap { $0 })
            let one = unreadable.count == 1
            notes.append("\(unreadable.count) \(one ? "part" : "parts") this version of JSpice could not read"
                + (names.isEmpty ? "" : " (\(names.joined(separator: ", ")))") + " \(one ? "was" : "were") left out of "
                + "the drawing and the simulation; \(one ? "it is" : "they are") kept in the file.")
        }
        if !scopes.isEmpty {
            let one = scopes.count == 1
            notes.append("\(scopes.count) scope \(one ? "trace" : "traces") this version of JSpice cannot show "
                + "\(one ? "was" : "were") left out; \(one ? "it is" : "they are") kept in the file.")
        }
        if !midiMappings.isEmpty {
            let one = midiMappings.count == 1
            notes.append("\(midiMappings.count) MIDI \(one ? "mapping" : "mappings") this version of JSpice cannot "
                + "read \(one ? "was" : "were") left out; \(one ? "it is" : "they are") kept in the file.")
        }
        for key in unreadableFields.keys.sorted() {
            notes.append("The circuit's \(Self.fieldNames[key] ?? key) could not be read, so the defaults are used; what "
                + "the file had is kept in it unless they are changed here.")
        }
        return notes
    }

    static let fieldNames = ["settings": "simulation settings", "netNames": "net names", "sequence": "step sequence"]

    static func distinct(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}

/// How a circuit was read from its file. Not saved, and ignored by equality and hashing: a circuit read from a file
/// equals the same circuit built in memory.
struct CircuitLoadInfo: Hashable, Sendable {
    /// The file's format version (1 when it has none); nil when not read as a whole file
    var fileVersion: Int?
    /// Whether the JSON had any field a circuit file has (`decodeDocument` refuses JSON that has none)
    var recognized = false

    static func == (lhs: CircuitLoadInfo, rhs: CircuitLoadInfo) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

/// One entry of a list, read if this build can read it, otherwise kept as it was
struct Tolerant<Value: Decodable>: Decodable {
    var value: Value?
    var raw: JSONValue?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Value.self) {
            self.value = value
        } else {
            raw = try container.decode(JSONValue.self)
        }
    }

    /// The entries this build can read, and the others with their places in the list
    static func split(_ entries: [Tolerant]) -> (values: [Value], preserved: [PreservedEntry]) {
        var values: [Value] = []
        var preserved: [PreservedEntry] = []
        for (index, entry) in entries.enumerated() {
            if let value = entry.value { values.append(value) } else if let raw = entry.raw { preserved.append(PreservedEntry(index: index, raw: raw)) }
        }
        return (values, preserved)
    }
}

extension UnkeyedEncodingContainer {
    /// Writes `values` with the preserved entries put back at their places (or at the end, past the last value)
    mutating func encode<Value: Encodable>(_ values: [Value], mergingPreserved preserved: [PreservedEntry]) throws {
        let pending = preserved.sorted { $0.index < $1.index }
        var p = 0
        var v = 0
        for position in 0..<(values.count + pending.count) {
            if p < pending.count && (pending[p].index <= position || v == values.count) {
                try encode(pending[p].raw)
                p += 1
            } else {
                try encode(values[v])
                v += 1
            }
        }
    }
}
