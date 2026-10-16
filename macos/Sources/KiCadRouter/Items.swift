// Ported from KiCad 10.0.7: pcbnew/router/pns_layerset.h, pns_item.h, pns_item.cpp, pns_linked_item.h, pns_hole.h,
// pns_hole.cpp, pns_solid.h, pns_solid.cpp, pns_segment.h, pns_via.h and pns_via.cpp (padstacks of one size only).
// Copyright (C) 2013-2014 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// A range of the router's copper layers, 0 the front (KiCad's PNS_LAYER_RANGE): -1 to -1 for none
public struct LayerRange: Hashable, Sendable, CustomStringConvertible {
    public private(set) var start: Int
    public private(set) var end: Int

    public init() { (start, end) = (-1, -1) }
    public init(_ a: Int, _ b: Int) { (start, end) = a > b ? (b, a) : (a, b) }
    public init(_ layer: Int) { (start, end) = (layer, layer) }

    /// All layers there can be
    public static let all = LayerRange(0, 256)

    public var description: String { "\(start)-\(end)" }

    public func overlaps(_ o: LayerRange) -> Bool {
        if start < 0 || end < 0 || o.start < 0 || o.end < 0 { return false }
        return end >= o.start && start <= o.end
    }

    public func overlaps(_ layer: Int) -> Bool {
        if start < 0 || end < 0 || layer < 0 { return false }
        return layer >= start && layer <= end
    }

    public var isMultilayer: Bool { start != end }

    public mutating func merge(_ o: LayerRange) {
        if start < 0 || end < 0 {
            (start, end) = (o.start, o.end)
            return
        }
        if o.start < start { start = o.start }
        if o.end > end { end = o.end }
    }

    public func intersection(_ o: LayerRange) -> LayerRange {
        var r = LayerRange()
        r.start = max(start, o.start)
        r.end = end < 0 ? o.end : o.end < 0 ? end : min(end, o.end)
        return r
    }
}

/// Marks the router puts on items (KiCad's LineMarker)
public struct Marker: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let head = Marker(rawValue: 1 << 0)
    public static let violation = Marker(rawValue: 1 << 3)
    public static let locked = Marker(rawValue: 1 << 4)
    public static let dpCoupled = Marker(rawValue: 1 << 5)
}

/// What a router item is (KiCad's ITEM::PnsKind), as a mask
public struct ItemKind: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let solid = ItemKind(rawValue: 1)
    public static let line = ItemKind(rawValue: 2)
    public static let joint = ItemKind(rawValue: 4)
    public static let segment = ItemKind(rawValue: 8)
    public static let arc = ItemKind(rawValue: 16)
    public static let via = ItemKind(rawValue: 32)
    public static let diffPair = ItemKind(rawValue: 64)
    public static let hole = ItemKind(rawValue: 128)
    public static let any = ItemKind(rawValue: 0xffff)
    public static let linkedItems: ItemKind = [.solid, .segment, .arc, .via, .hole]
}

/// A net, as the router knows it: KiCad's NET_HANDLE, which the board's side gives out. Items with no net of the
/// board's (its net 0, "unconnected") still have a handle, the board's "orphaned" one; only the router's own scratch
/// items have none (nil).
public typealias NetHandle = Int

/// Something on the board the router routes round or with: a pad, a track's segment, a via, a hole, a line of
/// segments (KiCad's PNS::ITEM)
public class Item: CustomStringConvertible {
    public let kind: ItemKind
    /// What on the board it stands for (KiCad's BOARD_ITEM parent): the router passes it back to the board's side
    /// and never looks inside it
    public var parent: AnyObject? {
        didSet { if parent != nil { sourceItem = parent } }
    }
    /// What on the board it came from, where it stands for none one to one (a dragged track's pieces)
    public var sourceItem: AnyObject?
    public var layers = LayerRange()
    public var movable = true
    private var _net: NetHandle?
    public var marker: Marker = []
    public var rank = -1
    public var isRoutable = true
    public var isVirtual = false
    public var isFreePadFlag = false
    public var isCompoundShapePrimitive = false
    /// The node (or the pad or via, for a hole) that owns it
    public weak var owner: AnyObject?

    /// The order items were made in, which stands in for the memory addresses KiCad orders some of its sets by
    public let serial: Int
    nonisolated(unsafe) private static var serials = 0

    public init(kind: ItemKind) {
        self.kind = kind
        Item.serials += 1
        serial = Item.serials
    }

    /// A copy's base: what KiCad's ITEM copy constructor copies (not the owner)
    public init(copying o: Item) {
        kind = o.kind
        layers = o.layers
        _net = o._net
        movable = o.movable
        parent = o.parent
        sourceItem = o.sourceItem
        marker = o.marker
        rank = o.rank
        isRoutable = o.isRoutable
        isVirtual = o.isVirtual
        isFreePadFlag = o.isFreePadFlag
        isCompoundShapePrimitive = o.isCompoundShapePrimitive
        Item.serials += 1
        serial = Item.serials
    }

    public func clone() -> Item { fatalError("an item of kind \(kind.rawValue) cannot be cloned") }

    public var net: NetHandle? {
        get { _net }
        set { _net = newValue }
    }

    func setNet(_ n: NetHandle?) { _net = n }

    public func ofKind(_ mask: ItemKind) -> Bool { !mask.intersection(kind).isEmpty }

    public var layer: Int { layers.start }
    public func setLayer(_ l: Int) { layers = LayerRange(l) }
    public func layersOverlap(_ o: Item) -> Bool { layers.overlaps(o.layers) }

    /// Its shape on `layer` (-1: any)
    public func shape(_ layer: Int) -> Shape? { nil }

    /// Its walkaround hull: its outline grown by `clearance` and half the width of what walks round it
    public func hull(clearance: Int = 0, walkaroundThickness: Int = 0, layer: Int = -1) -> LineChain { LineChain() }

    public var uniqueShapeLayers: [Int] { [-1] }
    public var hasUniqueShapeLayers: Bool { false }

    public func relevantShapeLayers(_ other: Item) -> [Int] {
        if !hasUniqueShapeLayers && !other.hasUniqueShapeLayers { return [-1] }
        return Array(Set(uniqueShapeLayers).union(other.uniqueShapeLayers)).sorted()
    }

    public func mark(_ m: Marker) { marker = m }
    public func unmark(_ m: Marker = Marker(rawValue: -1)) { marker.subtract(m) }
    public var isLocked: Bool { marker.contains(.locked) }

    public func anchor(_ n: Int) -> IPoint { .zero }
    public var anchorCount: Int { 0 }

    public var isFreePad: Bool { isFreePadFlag || (parentPadVia?.isFreePadFlag ?? false) }
    public var parentPadVia: Item? { nil }

    public var hasHole: Bool { false }
    public var hole: Hole? { nil }

    public var description: String { "\(kindName) net \(net.map(String.init) ?? "none") layers \(layers)" }

    var kindName: String {
        switch kind {
        case .arc: return "arc"
        case .line: return "line"
        case .segment: return "segment"
        case .via: return "via"
        case .joint: return "joint"
        case .solid: return "solid"
        case .diffPair: return "diff-pair"
        case .hole: return "hole"
        default: return "unknown"
        }
    }

    /// The node it is in (its pad's or via's, for a hole)
    public var owningNode: Node? { (parentPadVia?.owner ?? owner) as? Node }

    // MARK: - Collisions (pns_item.cpp)

    /// Whether `head` comes too close to this item in `node`, on `layer` (and, with a context, all the ways it does)
    public func collide(_ head: Item, _ node: Node, layer: Int, context: CollisionSearchContext? = nil) -> Bool {
        collideSimple(head, node, layer, context)
    }

    // prune self-collisions, i.e. a via/pad annular ring with its own hole
    static func shouldConsiderHoleCollisions(_ item: Item, _ head: Item) -> Bool {
        let holeI = item as? Hole, holeH = head as? Hole
        if let holeI, let holeH {
            guard let parentI = holeI.parentPadVia, let parentH = holeH.parentPadVia else { return true }
            // (a via's hole and an identical copy's, as when a line is checked against a node it is already in)
            if let vi = parentI as? Via, let vh = parentH as? Via, vi.pos == vh.pos, vi.padstackMatches(vh), vi.net == vh.net,
               vi.drill == vh.drill {
                return false
            }
            return parentI !== parentH
        }
        if let holeI { return holeI.parentPadVia !== head }
        if let holeH { return holeH.parentPadVia !== item }
        return true
    }

    func collideSimple(_ head: Item, _ node: Node, _ layer: Int, _ ctx: CollisionSearchContext?) -> Bool {
        // (this item's hole, a pad's or a via's, is an item of its own in the node; the head's is not)
        let holeH = head.hole, holeI = hole
        var collisionsFound = false
        if self === head { return false }
        if !Item.shouldConsiderHoleCollisions(self, head) { return false }
        let runPhysicalOnly = node.ruleResolver.hasUserDefinedPhysicalConstraint

        // lines ending with vias: their vias collide too
        if let line = self as? Line, let via = line.via {
            collisionsFound = via.collideSimple(head, node, layer, ctx) || collisionsFound
        }
        if let line = head as? Line, let via = line.via {
            collisionsFound = via.collideSimple(self, node, layer, ctx) || collisionsFound
        }
        // and the head's hole
        if head.hasHole, let holeH, Item.shouldConsiderHoleCollisions(self, holeH) {
            if kind == .hole || net != holeH.net || runPhysicalOnly {
                collisionsFound = collideSimple(holeH, node, layer, ctx) || collisionsFound
            }
        }
        if hasHole, let holeI, Item.shouldConsiderHoleCollisions(holeI, head) {
            collisionsFound = holeI.collideSimple(head, node, layer, ctx) || collisionsFound
        }

        // (collisions ignore a chain's width, so a line's half width goes with the clearance)
        let lineWidthI = (self as? Line).map { $0.width / 2 } ?? 0
        let lineWidthH = (head as? Line).map { $0.width / 2 } ?? 0

        if !layers.overlaps(head.layers) { return false }

        let iface = Router.interface
        var differentNetsOnly = ctx?.options.differentNetsOnly ?? true
        var enforce = false
        let clearance: Int
        // hole to hole has nothing to do with nets
        if kind == .hole && head.kind == .hole { differentNetsOnly = false }
        if differentNetsOnly && net == head.net && head.net != nil && !runPhysicalOnly {
            clearance = -1
        } else if differentNetsOnly && (isFreePad || head.isFreePad) && !runPhysicalOnly {
            clearance = -1
        } else if node.ruleResolver.isKeepout(self, head, &enforce) || node.ruleResolver.isKeepout(head, self, &enforce) {
            clearance = enforce ? 0 : -1
        } else if let iface, !iface.isFlashed(self, onLayers: head.layers) {
            clearance = -1
        } else if let iface, !iface.isFlashed(head, onLayers: layers) {
            clearance = -1
        } else if let o = ctx?.options.overrideClearance, o >= 0 {
            clearance = o
        } else {
            clearance = node.clearance(self, head, useEpsilon: ctx?.options.useClearanceEpsilon ?? false)
        }

        if clearance >= 0 {
            let checkCastellation = node.ruleResolver.isOnEdgeCuts(self) || node.ruleResolver.isNonPlatedSlot(self)
            let checkNetTie = node.ruleResolver.isInNetTie(self)
            guard let shapeI = shape(layer), let shapeH = head.shape(layer) else { return false }
            // (the "- 1": hulls are built to the clearance exactly, and exactly the clearance away is no collision)
            if checkCastellation || checkNetTie {
                var actual: Int?
                var pos: IPoint?
                if shapeH.collide(shapeI, clearance: clearance + lineWidthH + lineWidthI - 1, actual: &actual, location: &pos) {
                    if checkCastellation, let pos, node.queryEdgeExclusions(pos) { return false }
                    if checkNetTie, let pos, node.ruleResolver.isNetTieExclusion(head, pos, self) { return false }
                    guard let ctx else { return true }
                    collisionsFound = true
                    ctx.insert(Obstacle(head: head, item: self, clearance: clearance))
                }
            } else if shapeH.collide(shapeI, clearance: clearance + lineWidthH + lineWidthI - 1) {
                guard let ctx else { return true }
                collisionsFound = true
                ctx.insert(Obstacle(head: head, item: self, clearance: clearance))
            }
        }
        return collisionsFound
    }
}

/// An item the node links to joints: a segment, a via, a pad (KiCad's LINKED_ITEM)
public class LinkedItem: Item {
    public typealias UniqueID = UInt64
    public private(set) var uid: UniqueID
    nonisolated(unsafe) private static var uidCount: UniqueID = 0

    private static func nextUid() -> UniqueID {
        defer { uidCount += 1 }
        return uidCount
    }

    public override init(kind: ItemKind) {
        uid = LinkedItem.nextUid()
        super.init(kind: kind)
    }

    public init(copying o: LinkedItem) {
        uid = o.uid
        super.init(copying: o)
    }

    public func resetUid() { uid = LinkedItem.nextUid() }
    func setUid(_ u: UniqueID) { uid = u }

    public var width: Int {
        get { 0 }
        set {}
    }
}

/// A drilled hole: a pad's or a via's, an item of its own for the clearances holes have (KiCad's PNS::HOLE)
public final class Hole: Item {
    public private(set) var holeShape: Shape
    public weak var parentPadViaItem: Item?

    public init(shape: Shape) {
        holeShape = shape
        super.init(kind: .hole)
    }

    public static func circular(_ pos: IPoint, radius: Int, layers: LayerRange) -> Hole {
        let h = Hole(shape: .circle(center: pos, radius: radius))
        h.layers = layers
        return h
    }

    public override func clone() -> Item {
        let h = Hole(shape: holeShape)
        h.layers = layers
        h.rank = rank
        h.marker = marker
        h.parent = parent
        h.isVirtual = isVirtual
        return h
    }

    public override var net: NetHandle? {
        get { parentPadViaItem?.net ?? super.net }
        set { super.net = newValue }
    }

    public override var parentPadVia: Item? { parentPadViaItem }
    public override func shape(_ layer: Int) -> Shape? { holeShape }

    public override func hull(clearance: Int = 0, walkaroundThickness: Int = 0, layer: Int = -1) -> LineChain {
        if case .circle(let c, let r) = holeShape {
            let cl = clearance + walkaroundThickness / 2
            let width = r * 2
            // chamfer = width * (1 - sqrt(2)/2), for an equilateral octagon
            return Shape.octagonalHull(c - IPoint(width / 2, width / 2), IPoint(width, width), cl,
                                       Int(Double(2 * cl + width) * (1.0 - 0.5.squareRoot())))
        }
        return holeShape.hull(clearance: clearance, walkaroundThickness: walkaroundThickness)
    }

    public var radius: Int {
        if case .circle(_, let r) = holeShape { return r }
        return 0
    }

    public func setCenter(_ c: IPoint) {
        if case .circle(_, let r) = holeShape { holeShape = .circle(center: c, radius: r) }
    }

    public func setRadius(_ r: Int) {
        if case .circle(let c, _) = holeShape { holeShape = .circle(center: c, radius: r) }
    }

    public func move(_ d: IPoint) { holeShape = holeShape.moved(d) }
}

/// A pad, or anything else on the board the router keeps clear of and does not move: its copper's shape (KiCad's
/// PNS::SOLID)
public final class Solid: Item {
    public private(set) var pos = IPoint.zero
    public var solidShape: Shape?
    public var offset = IPoint.zero
    public var padToDie = 0
    public var padToDieDelay = 0
    /// Its turn, in degrees
    public var orientation = 0.0
    public var anchorPoints: [IPoint] = []
    private var _hole: Hole?

    public init() {
        super.init(kind: .solid)
        movable = false
    }

    private init(copying s: Solid) {
        super.init(copying: s)
        solidShape = s.solidShape
        if let h = s._hole { setHole(h.clone() as! Hole) }
        pos = s.pos
        padToDie = s.padToDie
        padToDieDelay = s.padToDieDelay
        orientation = s.orientation
        anchorPoints = s.anchorPoints
    }

    public override func clone() -> Item { Solid(copying: self) }

    public override func shape(_ layer: Int) -> Shape? { solidShape }

    public override func hull(clearance: Int = 0, walkaroundThickness: Int = 0, layer: Int = -1) -> LineChain {
        solidShape?.hull(clearance: clearance, walkaroundThickness: walkaroundThickness) ?? LineChain()
    }

    public func setPos(_ c: IPoint) {
        let d = c - pos
        solidShape = solidShape?.moved(d)
        _hole?.move(d)
        pos = c
    }

    public override func anchor(_ n: Int) -> IPoint { anchorPoints.isEmpty ? pos : anchorPoints[n] }
    public override var anchorCount: Int { anchorPoints.isEmpty ? 1 : anchorPoints.count }

    public func setHole(_ h: Hole) {
        _hole = h
        h.parentPadViaItem = self
        h.owner = self
        h.layers = layers
    }

    public override var hasHole: Bool { _hole != nil }
    public override var hole: Hole? { _hole }
}

/// A straight piece of track (KiCad's PNS::SEGMENT)
public final class Segment: LinkedItem {
    public private(set) var seg: Seg
    private var _width: Int

    public init(_ s: Seg, net: NetHandle?) {
        seg = Seg(s.a, s.b)
        _width = 0
        super.init(kind: .segment)
        self.net = net
    }

    /// A segment of `line`: its width, net, layers, marks and rank (the line's own and its segments', as KiCad's
    /// LINE::Marker and LINE::Rank give them)
    public init(line: Line, _ s: Seg) {
        seg = Seg(s.a, s.b)
        _width = line.width
        super.init(kind: .segment)
        parent = nil
        sourceItem = line.sourceItem
        net = line.net
        layers = line.layers
        marker = line.allMarkers
        rank = line.lineRank
    }

    private init(copying s: Segment) {
        seg = s.seg
        _width = s._width
        super.init(copying: s)
    }

    public override func clone() -> Item { Segment(copying: self) }

    public override var width: Int {
        get { _width }
        set { _width = newValue }
    }

    public override func shape(_ layer: Int) -> Shape? { .segment(seg, width: _width) }

    public var cLine: LineChain { LineChain([seg.a, seg.b]) }

    public func setEnds(_ a: IPoint, _ b: IPoint) { seg = Seg(a, b) }
    public func swapEnds() { seg = Seg(seg.b, seg.a) }

    public override func hull(clearance: Int = 0, walkaroundThickness: Int = 0, layer: Int = -1) -> LineChain {
        Shape.segmentHull(seg, _width, clearance, walkaroundThickness)
    }

    public override func anchor(_ n: Int) -> IPoint { n == 0 ? seg.a : seg.b }
    public override var anchorCount: Int { 2 }

    public override var description: String { super.description + " \(seg) width \(_width)" }
}

/// A via: copper rings on its layers round a drilled hole (KiCad's PNS::VIA, its padstack one size throughout)
public class Via: LinkedItem {
    public enum ViaType: Sendable { case through, blind, buried, microVia }

    public static let allLayers = 0

    public private(set) var pos: IPoint
    public private(set) var diameter: Int
    public private(set) var drill: Int
    public var viaType: ViaType = .through
    /// Whether its rings are only on its end layers (KiCad's UNCONNECTED_LAYER_MODE::START_END_ONLY)
    public var startEndOnly = false
    public var isFree = false
    public private(set) var holeLayers = LayerRange()
    private var _hole: Hole?

    public init(pos: IPoint, layers: LayerRange, diameter: Int, drill: Int, net: NetHandle? = nil, type: ViaType = .through) {
        self.pos = pos
        self.diameter = diameter
        self.drill = drill
        super.init(kind: .via)
        self.net = net
        self.layers = layers
        holeLayers = layers
        setHole(.circular(pos, radius: drill / 2, layers: LayerRange()))
        viaType = type
    }

    init(copying v: Via) {
        pos = v.pos
        diameter = v.diameter
        drill = v.drill
        super.init(copying: v)
        net = v.net
        layers = v.layers
        holeLayers = v.holeLayers
        setHole(.circular(pos, radius: drill / 2, layers: LayerRange()))
        viaType = v.viaType
        startEndOnly = v.startEndOnly
        isFree = v.isFree
    }

    public override func clone() -> Item { Via(copying: self) }

    public override var uniqueShapeLayers: [Int] { [Via.allLayers] }
    public override var hasUniqueShapeLayers: Bool { true }

    public func setPos(_ p: IPoint) {
        pos = p
        _hole?.setCenter(p)
    }

    public func connectsLayer(_ layer: Int) -> Bool {
        startEndOnly ? layer == layers.start || layer == layers.end : layers.overlaps(layer)
    }

    public func setDiameter(_ d: Int) { diameter = d }

    public func setDrill(_ d: Int) {
        drill = d
        _hole?.setRadius(d / 2)
    }

    public func padstackMatches(_ o: Via) -> Bool { diameter == o.diameter }

    public func setHoleLayers(_ l: LayerRange) {
        holeLayers = l
        _hole?.layers = l
    }

    public override func shape(_ layer: Int) -> Shape? { .circle(center: pos, radius: diameter / 2) }

    public override func hull(clearance: Int = 0, walkaroundThickness: Int = 0, layer: Int = -1) -> LineChain {
        let cl = clearance + walkaroundThickness / 2
        var width = diameter
        if let h = _hole, let iface = Router.interface, !iface.isFlashed(self, onLayer: layer) { width = h.radius * 2 }
        // chamfer = width * (1 - sqrt(2)/2), for an equilateral octagon
        return Shape.octagonalHull(pos - IPoint(width / 2, width / 2), IPoint(width, width), cl,
                                   Int(Double(2 * cl + width) * (1.0 - 0.5.squareRoot())))
    }

    /// The force that pushes the via clear of `other` (KiCad's VIA::PushoutForce for one item)
    public func pushoutForce(_ node: Node, _ other: Item) -> IPoint? {
        let clearance = node.clearance(self, other, useEpsilon: false)
        var force = IPoint.zero
        for layer in relevantShapeLayers(other) {
            guard let s = other.shape(layer), let f = s.pushout(circle: pos, radius: diameter / 2, clearance: clearance) else { continue }
            if f.squaredNorm > force.squaredNorm { force = f }
        }
        return force == .zero ? nil : force
    }

    /// Where the via must move to clear everything in `node` (KiCad's VIA::PushoutForce): pushed from obstacle to
    /// obstacle, back along `direction` if that gets nowhere; nil if it cannot be cleared
    public func pushoutForce(_ node: Node, direction: IPoint, kinds: ItemKind = .any, maxIterations: Int = 10) -> IPoint? {
        var iter = 0
        let mv = Via(copying: self)
        var totalForce = IPoint.zero
        Router.dbg("via-force-init-pos, iter \(maxIterations): point (\(pos.x),\(pos.y))")
        while iter < maxIterations {
            var opt = CollisionSearchOptions()
            opt.limitCount = 1
            opt.kindMask = kinds
            opt.useClearanceEpsilon = false
            guard let obs = node.checkColliding(mv, options: opt) else { break }
            // (a collision with no force: the pushing has failed)
            guard let force = mv.pushoutForce(node, obs.item) else { return nil }
            let threshold = diameter / 4
            let forceMag = force.norm
            if iter > maxIterations / 2 && forceMag > threshold {
                // (far out and still pushed hard: back along the lead instead)
                let l = direction.resized(threshold)
                totalForce = totalForce + l
                mv.setPos(mv.pos + l)
            } else {
                // (KiCad means to cap the force at a quarter of the via's diameter, but its Resize's result goes
                // unused)
                totalForce = totalForce + force
                Router.dbg("via-force-coll: (\(mv.pos.x),\(mv.pos.y)) (\(mv.pos.x + force.x),\(mv.pos.y + force.y)) [\(obs.item)]")
                mv.setPos(mv.pos + force)
            }
            iter += 1
        }
        if iter == maxIterations { return nil }
        Router.dbg("via-force-new: point (\(pos.x + totalForce.x),\(pos.y + totalForce.y))")
        return totalForce
    }

    public override func anchor(_ n: Int) -> IPoint { pos }
    public override var anchorCount: Int { 1 }

    public struct Handle: Hashable, Sendable {
        public var pos: IPoint
        public var layers: LayerRange
        public var net: NetHandle?
    }

    public var handle: Handle { Handle(pos: pos, layers: layers, net: net) }

    /// The box round both vias, if one has moved from the other (KiCad's VIA::ChangedArea)
    public func changedArea(_ other: Via) -> IBox? {
        if other.pos == pos { return nil }
        var tmp: IBox?
        for layer in uniqueShapeLayers {
            if let b = shape(layer)?.bbox { tmp = tmp.map { var t = $0; t.merge(b); return t } ?? b }
        }
        for layer in other.uniqueShapeLayers {
            if let b = other.shape(layer)?.bbox { tmp = tmp.map { var t = $0; t.merge(b); return t } ?? b }
        }
        return tmp
    }

    public func setHole(_ h: Hole) {
        _hole = h
        h.parentPadViaItem = self
        h.owner = self
        h.layers = holeLayers
    }

    public override var hasHole: Bool { true }
    public override var hole: Hole? { _hole }

    public override var description: String { super.description + " drill \(drill) at \(pos) diameter \(diameter)" }
}

/// A via the router imagines where a line changes layer on a pad (KiCad's VVIA): no hole
public final class VirtualVia: Via {
    public init(pos: IPoint, layer: Int, diameter: Int, net: NetHandle?) {
        super.init(pos: pos, layers: LayerRange(layer), diameter: diameter, drill: diameter / 2, net: net)
        isVirtual = true
    }

    public override var hasHole: Bool { false }
}
