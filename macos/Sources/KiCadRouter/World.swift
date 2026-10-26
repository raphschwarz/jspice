// Ported from KiCad 10.0.7: pcbnew/router/pns_kicad_iface.cpp (PNS_KICAD_IFACE_BASE::SyncWorld and its sync
// functions, PNS_PCBNEW_RULE_RESOLVER::Clearance and IsKeepout) and the parts of pcbnew/drc/drc_engine.cpp
// (DRC_ENGINE::EvalRules) that a board without rules of the user's own takes.
// Copyright (C) 2013-2016 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// One item of the router's world as KiCad's SyncWorld makes it from a board item: a pad's solid (one per unique
/// layer of its padstack), a drawing's piece on the edge or on copper, a text on copper, a keepout zone, a track, an
/// arc track, a via. What the router's rule resolver asks of the board item behind it is kept with it.
public struct WorldItem: Sendable {
    public enum Kind: String, Sendable { case pad, edge, graphic, text, keepout, track, arc, via }

    /// What a keepout zone keeps out
    public struct Keepout: Sendable, Hashable {
        public var tracks = false, vias = false, pads = false, footprints = false
        public var footprint: String?
        /// The zone's name (ZONE::GetZoneName, empty if it has none)
        public var name = ""
        public init(tracks: Bool = false, vias: Bool = false, pads: Bool = false, footprints: Bool = false, footprint: String? = nil,
                    name: String = "") {
            (self.tracks, self.vias, self.pads, self.footprints, self.footprint) = (tracks, vias, pads, footprints, footprint)
            self.name = name
        }
    }

    public var kind: Kind
    /// Its net: 0 is the orphaned net (a pad, track or drawing with none); nil no net at all (a text, a zone)
    public var net: NetHandle?
    public var layers = LayerRange(0, 0)
    public var shape: Shape?
    public var hole: Shape?
    public var pos: IPoint?
    public var offset: IPoint?
    public var npth = false
    /// BOARD_ITEM::IsOnCopperLayer
    public var copper = true
    /// BOARD_ITEM::HasDrilledHole
    public var drilled = false
    public var npthSlot = false
    /// BOARD_CONNECTED_ITEM::GetClearanceOverrides: a pad's own clearance, or its footprint's
    public var clearanceOverride: Int?
    /// PAD::FlashLayer, PCB_VIA::FlashLayer, by router layer (empty: by the item's layers)
    public var flashed: [Bool] = []
    public var freePad = false
    public var compound = false
    public var locked = false
    /// A via's PCB_VIA::GetIsFree
    public var free = false
    /// A via's PCB_VIA::GetViaType
    public var viaType = Via.ViaType.through
    // a track's, an arc's, a via's
    public var a = IPoint.zero, b = IPoint.zero, mid = IPoint.zero
    public var width = 0, layer = 0, diameter = 0, drill = 0
    /// A keepout zone's outlines, each with its holes (as KiCad holds them: its SHAPE_POLY_SET's)
    public var polygons: [[LineChain]] = []
    /// A keepout zone's copper layers, in order (its layer set: not always a run of them, as `layers` is)
    public var zoneLayers: [Int] = []
    public var keepout: Keepout?
    /// The reference of the footprint a pad belongs to
    public var footprint: String?
    /// The board item it was made from (its uuid), for what the router does with it
    public var source: String?
    /// Made other than as KiCad makes it: bigger, so that routing round it is safe (a custom pad's outline)
    public var approximate = false

    public init(kind: Kind) { self.kind = kind }

    /// BOARD_ITEM::IsConnected: a pad, track, via or drawing; not a text or a rule area
    public var connected: Bool { kind != .text && kind != .keepout }
}

/// What the router's rule resolver works from: one clearance for everything (`board` false, router.cpp's simple
/// scenes), or a board's rules as KiCad's DRC engine works them out when the user has none of their own: each net's
/// net class clearance, a pad's or its footprint's own clearance first, the board's minimums
public struct WorldRules: Sendable {
    public var board = false
    /// The clearance between copper (simple), or the board's minimum
    public var clearance = 200_000
    public var holeClearance = 250_000
    public var holeToHole = 250_000
    public var edgeClearance = 500_000
    public var epsilon = 0
    /// The board's worst clearance (BOARD::GetMaxClearanceValue, and pads' own), nil: the worst of the above
    public var maxClearance: Int?
    /// Each net's net class clearance
    public var netClearance: [Int: Int] = [:]
    public var maxError = 5000

    public init() {}
}

/// The rule resolver of a world (KiCad's PNS_PCBNEW_RULE_RESOLVER, on the board's implicit rules)
public final class WorldResolver: RuleResolver {
    public var rules: WorldRules
    var info: [ObjectIdentifier: WorldItem] = [:]

    public init(rules: WorldRules) { self.rules = rules }

    func infoOf(_ item: Item?) -> WorldItem? {
        guard let item else { return nil }
        let key = item.kind == .hole ? (item.parentPadVia ?? item) : item
        return info[ObjectIdentifier(key)]
    }

    private func isHole(_ item: Item?) -> Bool { item?.kind == .hole }
    private func isEdge(_ item: Item?) -> Bool { infoOf(item)?.kind == .edge && !isHole(item) }

    private func isCopper(_ item: Item?) -> Bool {
        let i = infoOf(item)
        if !rules.board { return !(i?.kind == .pad && i?.npth == true) }
        return i?.copper ?? true
    }

    /// EvalRules's "non copper": not on a copper layer, or a keepout zone
    private func nonCopper(_ item: Item?) -> Bool {
        guard let i = infoOf(item) else { return false }
        return !i.copper || i.kind == .keepout
    }

    private func connected(_ item: Item?) -> Bool { infoOf(item)?.connected ?? true }

    /// Either item's own clearance, the larger, no less than `minimum` ("local overrides take precedence over
    /// everything except board min clearance")
    private func overrides(_ a: Item, _ b: Item?, _ minimum: Int) -> Int? {
        let oa = connected(a) && !(b.map(nonCopper) ?? false) ? infoOf(a)?.clearanceOverride : nil
        let ob = b != nil && connected(b) && !nonCopper(a) ? infoOf(b)?.clearanceOverride : nil
        guard oa != nil || ob != nil else { return nil }
        var v = oa ?? 0
        if let ob, ob > v { v = ob }
        return v == 0 ? nil : max(v, minimum)
    }

    private func netClearance(_ item: Item) -> Int { rules.netClearance[item.net ?? -1] ?? 0 }

    /// QueryConstraint for a board without rules of its own
    private func boardConstraint(_ type: ConstraintType, _ a: Item, _ b: Item?) -> Int {
        switch type {
        case .clearance:
            if let v = overrides(a, b, rules.clearance) { return v }
            if nonCopper(a) || (b.map(nonCopper) ?? false) { return 0 }
            var c = connected(a) ? netClearance(a) : 0
            if let b, connected(b) { c = max(c, netClearance(b)) }
            return max(c, rules.clearance)
        case .holeClearance:
            return overrides(a, b, rules.holeClearance) ?? rules.holeClearance
        case .holeToHole: return rules.holeToHole
        case .edgeClearance: return rules.edgeClearance
        default: return 0
        }
    }

    public func clearance(_ a: Item, _ b: Item?, useEpsilon: Bool) -> Int {
        var rv = 0
        let sameNet = b != nil && a.net != nil && a.net == b!.net
        let freePad = b != nil && (a.isFreePad || b!.isFreePad)
        func query(_ type: ConstraintType, _ simple: Int) -> Int { rules.board ? boardConstraint(type, a, b) : simple }
        if isDrilledHole(a) && b.map(isDrilledHole) == true {
            rv = max(rv, query(.holeToHole, rules.holeToHole))
        } else if isHole(a) || isHole(b) {
            if !sameNet { rv = max(rv, query(.holeClearance, rules.holeClearance)) }
        }
        // (no else: a plated hole is kept clear both as a hole and as copper)
        if isCopper(a) && (b == nil || isCopper(b)) && !sameNet && !freePad { rv = max(rv, query(.clearance, rules.clearance)) }
        if isEdge(a) || isNonPlatedSlot(a) || isEdge(b) || (b.map(isNonPlatedSlot) ?? false) {
            rv = max(rv, query(.edgeClearance, rules.edgeClearance))
        }
        if (sameNet || freePad) && rv == 0 { rv = -1 }
        if useEpsilon && rv > 0 { rv = max(0, rv - rules.epsilon) }
        return rv
    }

    public var hasUserDefinedPhysicalConstraint: Bool { false }
    public func isInNetTie(_ a: Item) -> Bool { false }
    public func isNetTieExclusion(_ item: Item, _ pos: IPoint, _ colliding: Item) -> Bool { false }

    /// A pad's round hole or a via's: one of the board's (a via the router has just made has no board item, and
    /// KiCad does not count it)
    public func isDrilledHole(_ item: Item) -> Bool {
        guard isHole(item), let i = infoOf(item) else { return false }
        if rules.board { return i.kind == .via || i.drilled }
        return i.kind == .pad || i.kind == .via
    }

    public func isNonPlatedSlot(_ item: Item) -> Bool {
        guard rules.board, isHole(item), let i = infoOf(item) else { return false }
        return i.npthSlot
    }

    // (KiCad's slow edge path is for items whose board item is on the edge cuts; the router's never are)
    public func isOnEdgeCuts(_ item: Item) -> Bool { false }

    /// Whether `obstacle` is a keepout zone, and if so whether it keeps `item` out: KiCad asks it of the board item
    /// it makes for the router item's kind, a track for a segment or line, a via for a via or hole, none for a pad
    public func isKeepout(_ obstacle: Item, _ item: Item, _ enforce: inout Bool) -> Bool {
        guard let i = infoOf(obstacle), i.kind == .keepout, let k = i.keepout else { return false }
        switch item.kind {
        case .segment, .line, .arc: enforce = k.tracks
        case .via, .hole: enforce = k.vias
        default: enforce = false
        }
        return true
    }

    public func queryConstraint(_ type: ConstraintType, _ a: Item?, _ b: Item?, layer: Int) -> Constraint? {
        if rules.board {
            guard let a else { return nil }
            switch type {
            case .clearance, .holeClearance, .holeToHole, .edgeClearance: return Constraint(type: type, min: boardConstraint(type, a, b))
            default: return nil
            }
        }
        switch type {
        case .clearance: return Constraint(type: type, min: rules.clearance)
        case .holeClearance: return Constraint(type: type, min: rules.holeClearance)
        case .holeToHole: return Constraint(type: type, min: rules.holeToHole)
        case .edgeClearance: return Constraint(type: type, min: rules.edgeClearance)
        default: return nil
        }
    }

    public var clearanceEpsilon: Int { rules.epsilon }
}

/// The router's side of a world of items (KiCad's PNS_KICAD_IFACE_BASE): it puts them in the router's world in
/// order, as SyncWorld does, and keeps what the router adds
public final class WorldInterface: RouterInterface {
    public var items: [WorldItem]
    public let layerCount: Int
    public let resolver: WorldResolver
    /// The router's item for each world item (nil: none, an arc track)
    public private(set) var routerItems: [Item?] = []
    /// What the router has put on the board, in the order it did
    public var added: [Item] = []
    /// What the world holds that the port cannot make as KiCad makes it yet (an arc track)
    public private(set) var unsupported: Set<String> = []
    /// The keepout zones that could not be cut into triangles, which KiCad's router leaves out (warning that each is
    /// malformed, perhaps crossing itself): their indices among the items
    public private(set) var malformedZones: [Int] = []

    public init(items: [WorldItem], layers: Int, rules: WorldRules) {
        self.items = items
        layerCount = layers
        resolver = WorldResolver(rules: rules)
    }

    /// What ROUTER::isStartingPointRoutable reads from a non-routable item's board item: a pad without plating, a
    /// rule area (one with keepout rules, the only kind in the world) and a text stop a route starting there
    public func nonRoutableReason(_ item: Item) -> String? {
        guard let i = resolver.infoOf(item) else { return nil }
        switch i.kind {
        case .pad where i.npth: return "Cannot start routing from a non-plated hole."
        case .keepout:
            let name = i.keepout?.name ?? ""
            return name.isEmpty ? "Rule area disallows tracks." : "Rule area '\(name)' disallows tracks."
        case .text: return "Cannot start routing from a text item."
        default: return nil
        }
    }

    public func syncWorld(_ world: Node) {
        routerItems.removeAll()
        resolver.info.removeAll()
        unsupported.removeAll()
        malformedZones.removeAll()
        for w in items {
            var item: Item?
            switch w.kind {
            case .pad, .edge, .graphic, .text:
                // syncPad, syncGraphicalItem, syncTextItem
                let solid = Solid()
                solid.layers = w.layers
                if w.kind == .edge || w.kind == .text || w.npth { solid.isRoutable = false }
                solid.net = w.net
                if w.freePad { solid.isFreePadFlag = true }
                if let p = w.pos { solid.setPos(p) }
                if let o = w.offset { solid.offset = o }
                if let h = w.hole {
                    solid.setHole(Hole(shape: h))
                    solid.hole!.layers = LayerRange(0, layerCount - 1)
                }
                if let s = w.shape { solid.solidShape = s }
                if w.compound { solid.isCompoundShapePrimitive = true }
                item = solid
                resolver.info[ObjectIdentifier(solid)] = w
                world.add(solid)
            case .keepout:
                // syncZone: the zone's outline cut into triangles as KiCad cuts it, each triangle a solid on each of the
                // zone's copper layers in turn; a zone that cannot be cut is left out (KiCad warns it is malformed)
                var poly = PolySet(w.polygons)
                poly.cacheTriangulation()
                guard poly.isTriangulationUpToDate else {
                    malformedZones.append(routerItems.count)
                    break
                }
                for layer in w.zoneLayers {
                    for tri in poly.triangulatedPolygons {
                        for t in tri.triangles.indices {
                            let (a, b, c) = tri.triangle(t)
                            // (a SHAPE_SIMPLE: closed, a point the same as the one before it left out)
                            var chain = LineChain()
                            chain.setClosed(true)
                            chain.append(a)
                            chain.append(b)
                            chain.append(c)
                            let solid = Solid()
                            solid.setLayer(layer)
                            solid.net = nil
                            solid.solidShape = .simple(chain)
                            solid.isCompoundShapePrimitive = true
                            solid.isRoutable = false
                            resolver.info[ObjectIdentifier(solid)] = w
                            world.add(solid)
                            if item == nil { item = solid }
                        }
                    }
                }
            case .track:
                let seg = Segment(Seg(w.a, w.b), net: w.net)
                seg.width = w.width
                seg.setLayer(w.layer)
                if w.locked { seg.mark(.locked) }
                item = seg
                resolver.info[ObjectIdentifier(seg)] = w
                world.add(seg, allowRedundant: true)
            case .via:
                let via = Via(pos: w.a, layers: w.layers, diameter: 0, drill: w.drill, net: w.net, type: w.viaType)
                via.setDiameter(w.diameter)
                if w.locked { via.mark(.locked) }
                via.isFree = w.free
                via.setHole(.circular(w.a, radius: w.drill / 2, layers: w.layers))
                via.setHoleLayers(w.layers)
                item = via
                resolver.info[ObjectIdentifier(via)] = w
                world.add(via)
            case .arc:
                // (the router's lines have no arcs yet: an arc track is an obstacle of its net, as a solid of its
                // shape, not one to route from or join at its ends)
                unsupported.insert("arc track (an obstacle, not yet routed from)")
                let solid = Solid()
                solid.setLayer(w.layer)
                solid.net = w.net
                solid.solidShape = .arc(ShapeArc(start: w.a, mid: w.mid, end: w.b, width: w.width))
                solid.isRoutable = false
                resolver.info[ObjectIdentifier(solid)] = w
                world.add(solid)
                item = solid
            }
            routerItems.append(item)
        }
        world.ruleResolver = resolver
        let r = resolver.rules
        world.maxClearance = (r.maxClearance ?? max(r.clearance, r.holeClearance, r.holeToHole, r.edgeClearance)) + r.epsilon
    }

    /// What the router has taken off the board (the world's items it replaced)
    public var removedItems: [Item] = []

    public func addItem(_ item: Item) { added.append(item) }
    public func updateItem(_ item: Item) {}
    public func removeItem(_ item: Item) { removedItems.append(item) }

    /// The world item a router item was made from
    public func worldItem(_ item: Item) -> WorldItem? { resolver.info[ObjectIdentifier(item)] }
    public func commit() {}

    /// Which layers a pad or via of the board is flashed on, as KiCad's PAD::FlashLayer and PCB_VIA::FlashLayer say
    private func flashed(_ item: Item) -> [Bool]? {
        guard item.kind != .hole, let f = resolver.info[ObjectIdentifier(item)]?.flashed, !f.isEmpty else { return nil }
        return f
    }

    public func isFlashed(_ item: Item, onLayer layer: Int) -> Bool {
        if layer < 0 { return true }
        if let f = flashed(item) { return layer < f.count && f[layer] }
        return defaultIsFlashed(item, onLayer: layer)
    }

    public func isFlashed(_ item: Item, onLayers layers: LayerRange) -> Bool {
        if let f = flashed(item) {
            let test = item.layers.intersection(layers)
            guard test.start <= test.end else { return false }
            return (test.start...test.end).contains { $0 >= 0 && $0 < f.count && f[$0] }
        }
        return defaultIsFlashed(item, onLayers: layers)
    }

    public func isCopperLayer(_ layer: Int) -> Bool { layer >= 0 && layer < layerCount }
    public func importSizes(_ sizes: inout SizesSettings, startItem: Item?, net: NetHandle?, start: IPoint) -> Bool { false }
    public func stackupHeight(_ firstLayer: Int, _ secondLayer: Int) -> Int { 0 }
    public func netCode(_ net: NetHandle?) -> Int { net ?? -1 }
    public func netName(_ net: NetHandle?) -> String { "Net-\(net ?? -1)" }
    public var orphanedNetHandle: NetHandle { 0 }
    public var ruleResolver: RuleResolver { resolver }
    public var copperLayerCount: Int { layerCount }
}
