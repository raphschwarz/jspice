import Foundation

/// A circuit saved as a functional block, to be used as one part in other circuits. Its ports (`ElementKind.port`)
/// are the block's pins: drawn down the left of the box (inputs) and the right (outputs), named after the ports. Each
/// block part carries its own copy of the definition, so a circuit file is complete in itself and each copy's knobs
/// can be set apart.
public struct BlockDefinition: Codable, Hashable, Sendable {
    public var name: String
    public var circuit: Circuit

    public init(name: String, circuit: Circuit) {
        self.name = name
        self.circuit = circuit
    }

    /// One pin of the block: the port element's index in `circuit.elements`, its name, and whether it is on the right
    public struct Port: Hashable, Sendable {
        public var index: Int
        public var name: String
        public var right: Bool
    }

    /// The ports in pin order: the left side's (inputs) from the top, then the right side's (outputs). A port set to
    /// neither side goes on the side of the circuit it is drawn on.
    public var ports: [Port] {
        let elements = circuit.elements
        let found = elements.indices.filter { elements[$0].kind == .port }
        guard !found.isEmpty else { return [] }
        let xs = elements.flatMap { [$0.a.x, $0.b.x] }
        let middle = Double((xs.min() ?? 0) + (xs.max() ?? 0)) / 2
        var ports = found.map { i -> (port: Port, y: Int, x: Int) in
            let element = elements[i]
            let side = Simulator.choice(element[param: "side"], 0...2)
            let right = side == 0 ? Double(element.a.x) > middle : side == 2
            let name = element.name.trimmingCharacters(in: .whitespaces)
            return (Port(index: i, name: name, right: right), element.a.y, element.a.x)
        }
        ports.sort { ($0.port.right ? 1 : 0, $0.y, $0.x) < ($1.port.right ? 1 : 0, $1.y, $1.x) }
        // unnamed ports are numbered
        return ports.enumerated().map { k, entry in
            var port = entry.port
            if port.name.isEmpty { port.name = "p\(k + 1)" }
            return port
        }
    }

    /// The pins' names, in pin order
    public var terminalNames: [String] { ports.map(\.name) }

    /// How the block is drawn: a box named after it, its inputs down one side and its outputs down the other
    public var chipPackage: ChipPackage {
        var places: [Board.PinPlace] = []
        var left = 0, right = 0
        let ports = ports
        for port in ports {
            if port.right {
                places.append(Board.PinPlace(second: false, offset: right))
                right += 1
            } else {
                places.append(Board.PinPlace(second: true, offset: left))
                left += 1
            }
        }
        let names = ports.map(\.name)
        return ChipPackage(name: name, terminalNames: names, pinLabels: names, pinPlaces: places, length: max(max(left, right) - 1, 2))
    }

    /// Whether a block named `name` is this one or is used inside it, at any depth: a block cannot be put inside itself
    public func uses(_ name: String) -> Bool {
        self.name == name || circuit.elements.contains { $0.block?.uses(name) ?? false }
    }
}

extension Circuit {
    /// The circuit as it is simulated: each block's parts put in its place, after the circuit's own parts (which keep
    /// their order and indices), for blocks inside blocks too. A block's parts are moved far off to one side of the
    /// drawing, each copy to a place of its own, and each port becomes a wire to its pin on the block. Their ids are
    /// made from the block's and their own, so a part keeps its state while the circuit is edited; their names are
    /// the block's name, a dot and their own ("X1.R2"). Net labels inside a block are its own (two copies of a block
    /// do not join at a label inside them), except ground.
    public func flattened(expandingModels: Bool = true) -> Circuit {
        guard elements.contains(where: { ($0.kind == .block && $0.block != nil) || (expandingModels && ($0.kind.isTube || $0.kind == .transformer)) }) else {
            return self
        }
        var result = self
        var copies = 0
        // flattening a circuit flattened already changes nothing: its blocks' parts are there (with these ids)
        let present = Set(elements.map(\.id))
        func expand(_ instance: Element, depth: Int) {
            guard depth < 8, let block = instance.block else { return }
            if let first = block.circuit.elements.first, present.contains(UUID.combining(instance.id, first.id)) { return }
            copies += 1
            let offset = GridPoint(1_000_000 * copies, 1_000_000)
            let pins = instance.posts
            var pinOfPort: [Int: Int] = [:]
            for (k, port) in block.ports.enumerated() { pinOfPort[port.index] = k }
            for (i, inner) in block.circuit.elements.enumerated() {
                var element = inner
                element.id = UUID.combining(instance.id, inner.id)
                element.a = inner.a + offset
                element.b = inner.b + offset
                if let pin = pinOfPort[i] {
                    if pin < pins.count { result.elements.append(Element(id: element.id, kind: .wire, a: element.a, b: pins[pin])) }
                    continue
                }
                let name = inner.name.trimmingCharacters(in: .whitespaces)
                if inner.kind == .netLabel {
                    if !name.isEmpty && !Topology.isGroundName(name) { element.name = instance.id.uuidString + "/" + name }
                } else if !name.isEmpty {
                    element.name = instance.name + "." + name
                }
                result.elements.append(element)
                if element.kind == .block { expand(element, depth: depth + 1) }
            }
        }
        for element in elements where element.kind == .block { expand(element, depth: 0) }
        if expandingModels { result.expandModels() }
        return result
    }

    /// Parts simulated as other parts, put in after the rest (see `flattened`): a transformer as its windings'
    /// resistances, its leakage and magnetising inductances and an ideal core (exactly two coupled inductors), and a
    /// tube's capacitances between its electrodes. Their own parts are drawn far off, below and to the left.
    mutating func expandModels() {
        var added: [Element] = []
        var copies = 0
        // a circuit flattened already has them
        let present = Set(elements.map(\.id))
        func part(_ owner: Element, _ role: Int, _ kind: ElementKind, _ a: GridPoint, _ b: GridPoint, _ suffix: String,
                  _ params: [String: Double] = [:]) {
            var element = Element(kind: kind, name: owner.name.isEmpty ? "" : owner.name + "." + suffix, a: a, b: b, params: params)
            element.id = UUID.combining(owner.id, UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(role))))
            if !present.contains(element.id) { added.append(element) }
        }
        for owner in elements {
            switch owner.kind {
            case .transformer where owner[param: "core"] == 0:
                copies += 1
                let origin = GridPoint(-1_000_000 * copies, -1_000_000)
                let pins = owner.posts
                guard pins.count == 4 else { continue }
                let lp = max(owner[param: "inductance"], 1e-12)
                let k = min(max(owner[param: "coupling"], 0.01), 1)
                let ratio = max(owner[param: "ratio"], 1e-6)
                // coupled inductors Lp and Ls = n² Lp with coupling k are exactly a leakage inductance (1 - k²) Lp in
                // series with the primary, a magnetising inductance k² Lp across it, and an ideal transformer of
                // ratio n / k (unloaded, k² of the primary's voltage reaches the core: k n of it the secondary, M / Lp)
                let x = origin, y = origin + GridPoint(0, 2), secondary = origin + GridPoint(0, 4)
                let rp = owner[param: "rp"], rs = owner[param: "rs"]
                if rp > 0 { part(owner, 1, .resistor, pins[0], x, "Rp", ["resistance": rp]) } else { part(owner, 1, .wire, pins[0], x, "Rp") }
                let leakage = (1 - k * k) * lp
                if leakage > 1e-9 * lp { part(owner, 2, .inductor, x, y, "Lleak", ["inductance": leakage]) } else { part(owner, 2, .wire, x, y, "Lleak") }
                part(owner, 3, .inductor, y, pins[1], "Lm", ["inductance": k * k * lp])
                var core = Element(kind: .transformer, name: owner.name.isEmpty ? "" : owner.name + ".core",
                                   a: origin + GridPoint(10, 10), b: origin + GridPoint(14, 10),
                                   params: ["core": 1, "ratio": ratio / k])
                core.id = UUID.combining(owner.id, UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4)))
                if !present.contains(core.id) { added.append(core) }
                let corePins = core.posts
                part(owner, 5, .wire, corePins[0], y, "w1")
                part(owner, 6, .wire, corePins[1], pins[1], "w2")
                part(owner, 7, .wire, corePins[2], secondary, "w3")
                part(owner, 8, .wire, corePins[3], pins[3], "w4")
                if rs > 0 { part(owner, 9, .resistor, secondary, pins[2], "Rs", ["resistance": rs]) } else { part(owner, 9, .wire, secondary, pins[2], "Rs") }
            case .triode, .pentode:
                let pins = owner.posts
                guard pins.count >= 3 else { continue }
                // grid, plate, cathode
                for (role, (key, from, to)) in [("cgk", 0, 2), ("cgp", 0, 1), ("cpk", 1, 2)].enumerated() {
                    let farads = owner[param: key]
                    if farads > 0 { part(owner, 10 + role, .capacitor, pins[from], pins[to], key.uppercased(), ["capacitance": farads]) }
                }
            default:
                continue
            }
        }
        elements += added
    }

    /// The circuit as a block: the ports it has, under `name`, with its scopes, sequence and MIDI mappings left out
    public func asBlock(named name: String) -> BlockDefinition {
        var inner = self
        inner.scopes = []
        inner.sequence = nil
        inner.midiMappings = []
        return BlockDefinition(name: name, circuit: inner)
    }
}

extension UUID {
    /// The id a part of a block part has in the circuit as it is simulated (see `Circuit.flattened`)
    public static func inBlock(_ block: UUID, part: UUID) -> UUID { combining(block, part) }

    /// An id made from two others, the same each time: the id of part `b` inside the block part `a`
    static func combining(_ a: UUID, _ b: UUID) -> UUID {
        let x = withUnsafeBytes(of: a.uuid) { Array($0) }
        let y = withUnsafeBytes(of: b.uuid) { Array($0) }
        var z = [UInt8](repeating: 0, count: 16)
        for k in 0..<16 {
            z[k] = (x[k] &* 167) ^ y[(k + 5) % 16] ^ (x[(k + 11) % 16] &+ UInt8(k))
        }
        return UUID(uuid: (z[0], z[1], z[2], z[3], z[4], z[5], z[6], z[7], z[8], z[9], z[10], z[11], z[12], z[13], z[14], z[15]))
    }
}

/// The blocks saved on this Mac, one `.jspiceblock` file each (a block definition as JSON), in
/// ~/Library/Application Support/JSpice/Blocks (JSPICE_BLOCKS overrides it). The app's library and the MCP server
/// both read it.
public enum BlockLibrary {
    public static var folder: URL {
        if let path = ProcessInfo.processInfo.environment["JSPICE_BLOCKS"] { return URL(fileURLWithPath: path) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".jspice")
        return base.appendingPathComponent("JSpice/Blocks")
    }

    public static let fileExtension = "jspiceblock"

    /// Every saved block, by name
    public static func all(in folder: URL = folder) -> [BlockDefinition] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == fileExtension }
            .compactMap { try? JSONDecoder().decode(BlockDefinition.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func block(named name: String, in folder: URL = folder) -> BlockDefinition? {
        all(in: folder).first { $0.name.lowercased() == name.lowercased() }
    }

    /// Saves a block, replacing one of the same name
    public static func save(_ block: BlockDefinition, in folder: URL = folder) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(block).write(to: file(for: block.name, in: folder), options: .atomic)
    }

    public static func delete(named name: String, in folder: URL = folder) throws {
        try FileManager.default.removeItem(at: file(for: name, in: folder))
    }

    /// The block's file: its name, with characters a file name cannot have replaced
    static func file(for name: String, in folder: URL) -> URL {
        let safe = name.map { "/:\\".contains($0) ? "-" : $0 }
        return folder.appendingPathComponent(String(safe)).appendingPathExtension(fileExtension)
    }
}
