import Foundation

/// What the schematic says the board must have, as KiCad's NETLIST and COMPONENT hold it: each part with its
/// reference, value, footprint, the symbol it stands for, its fields, and the net on each of its pads
public struct PCBNetlist: Sendable, Hashable {
    public struct Pin: Sendable, Hashable {
        public var net: String
        /// The pin's name in the schematic ("out", "base"), shown on the pad in KiCad
        public var function: String
        /// KiCad's pin type: passive, input, output, power_in, no_connect…
        public var type: String

        public init(net: String, function: String = "", type: String = "passive") {
            self.net = net; self.function = function; self.type = type
        }
    }

    /// One gate of a package (KiCad 10's unit metadata, for gate swapping): its name, A, B…, and its pads
    public struct Unit: Sendable, Hashable {
        public var name: String
        public var pins: [String]

        public init(name: String, pins: [String]) { self.name = name; self.pins = pins }
    }

    public struct Component: Sendable, Hashable {
        public var reference: String
        public var value: String
        /// "Library:Name"; empty when no footprint is assigned
        public var footprint: String
        /// The ids of the parts in the schematic it stands for, the first the one its footprint is linked to (a package
        /// of several units has one for each)
        public var ids: [String]
        /// The sheet's path ("/" for the root)
        public var sheetPath: String = "/"
        /// Its fields beyond reference, value and footprint, in order
        public var fields: [(name: String, value: String)] = []
        /// The net on each pad, by pad number
        public var pins: [String: Pin]
        public var units: [Unit] = []
        public var doNotPopulate = false
        public var excludeFromBOM = false
        public var excludeFromBoard = false
        public var excludeFromPositionFiles = false
        /// Where it would go on a board, roughly (from where it is in the schematic), for placing it when it is new
        public var placementHint: KiCadPoint?

        public init(reference: String, value: String, footprint: String, ids: [String], pins: [String: Pin]) {
            self.reference = reference; self.value = value; self.footprint = footprint; self.ids = ids; self.pins = pins
        }

        /// The path of its footprint: the sheet's and the symbol's id
        public var path: String { (sheetPath.hasSuffix("/") ? sheetPath : sheetPath + "/") + (ids.first ?? "") }

        /// Every path a footprint linked to it may have (one for each unit)
        public var paths: [String] { ids.map { (sheetPath.hasSuffix("/") ? sheetPath : sheetPath + "/") + $0 } }

        public static func == (a: Component, b: Component) -> Bool {
            a.reference == b.reference && a.value == b.value && a.footprint == b.footprint && a.ids == b.ids
                && a.sheetPath == b.sheetPath && a.fields.map(\.name) == b.fields.map(\.name)
                && a.fields.map(\.value) == b.fields.map(\.value) && a.pins == b.pins && a.units == b.units
                && a.doNotPopulate == b.doNotPopulate && a.excludeFromBOM == b.excludeFromBOM
                && a.excludeFromBoard == b.excludeFromBoard && a.excludeFromPositionFiles == b.excludeFromPositionFiles
                && a.placementHint == b.placementHint
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(reference); hasher.combine(footprint); hasher.combine(ids)
        }
    }

    public var components: [Component]

    public init(components: [Component]) { self.components = components }

    /// Every net the parts' pins are on
    public var netNames: Set<String> { Set(components.flatMap { $0.pins.values.map(\.net) }) }

    public func component(path: String) -> Component? { components.first { $0.paths.contains(path) } }

    public func component(reference: String) -> Component? {
        components.first { $0.reference.caseInsensitiveCompare(reference) == .orderedSame }
    }

    /// The netlist as KiCad's own netlist file (the S-expression netlist, version E), for KiCad's File ▸ Import ▸
    /// Netlist
    public func kicadNetlist(source: String, date: Date = Date(), tool: String = "JSpice") -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        var components: [SExpr] = []
        for c in self.components {
            var comp: [SExprConvertible] = [SExpr("ref", c.reference), SExpr("value", c.value)]
            if !c.footprint.isEmpty { comp.append(SExpr("footprint", c.footprint)) }
            for field in c.fields { comp.append(SExpr("property", SExpr("name", field.name), SExpr("value", field.value))) }
            if c.doNotPopulate { comp.append(SExpr("property", SExpr("name", "dnp"))) }
            if c.excludeFromBOM { comp.append(SExpr("property", SExpr("name", "exclude_from_bom"))) }
            if c.excludeFromBoard { comp.append(SExpr("property", SExpr("name", "exclude_from_board"))) }
            comp.append(SExpr("sheetpath", SExpr("names", c.sheetPath), SExpr("tstamps", c.sheetPath)))
            comp.append(SExpr("tstamps", c.ids.joined(separator: " ")))
            components.append(SExpr("comp", comp))
        }
        // each net with its pads, ground first, then by name
        var nodes: [String: [(ref: String, pad: String, pin: Pin)]] = [:]
        for c in self.components where !c.excludeFromBoard {
            for (pad, pin) in c.pins { nodes[pin.net, default: []].append((ref: c.reference, pad: pad, pin: pin)) }
        }
        let names = nodes.keys.sorted { a, b in
            let (ga, gb) = (a == "GND", b == "GND")
            return ga != gb ? ga : a.localizedStandardCompare(b) == .orderedAscending
        }
        var nets: [SExpr] = []
        for (code, name) in names.enumerated() {
            var net: [SExprConvertible] = [SExpr("code", String(code + 1)), SExpr("name", name)]
            for node in (nodes[name] ?? []).sorted(by: { ($0.ref, $0.pad) < ($1.ref, $1.pad) }) {
                var n: [SExprConvertible] = [SExpr("ref", node.ref), SExpr("pin", node.pad)]
                if !node.pin.function.isEmpty { n.append(SExpr("pinfunction", node.pin.function)) }
                n.append(SExpr("pintype", node.pin.type))
                net.append(SExpr("node", n))
            }
            nets.append(SExpr("net", net))
        }
        let root = SExpr("export", SExpr("version", "E"),
                         SExpr("design", SExpr("source", source), SExpr("date", stamp), SExpr("tool", tool)),
                         SExpr("components", components), SExpr("nets", nets))
        return root.formatted()
    }
}
