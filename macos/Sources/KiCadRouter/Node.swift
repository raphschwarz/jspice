// Ported from KiCad 10.0.7: pcbnew/router/pns_node.h, pns_node.cpp, pns_index.h, pns_index.cpp and pns_joint.h.
// Copyright (C) 2013-2014 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// Something found too close to what was looked for (KiCad's OBSTACLE)
public struct Obstacle {
    /// What was looked for
    public var head: Item
    /// What it comes too close to
    public var item: Item
    /// The first place the head's path crosses the item's hull, and how far along the path
    public var ipFirst = IPoint.zero
    public var clearance = 0
    public var pos = IPoint.zero
    public var distFirst = 0
    public var maxFanoutWidth = 0

    public init(head: Item, item: Item, clearance: Int) {
        self.head = head
        self.item = item
        self.clearance = clearance
    }
}

/// How collisions are looked for (KiCad's COLLISION_SEARCH_OPTIONS)
public struct CollisionSearchOptions {
    public var differentNetsOnly = true
    public var overrideClearance = -1
    public var limitCount = -1
    public var kindMask = ItemKind.any
    public var useClearanceEpsilon = true
    public var filter: ((Item) -> Bool)?
    public var layer = -1

    public init() {}
}

/// The obstacles found so far, kept as KiCad's std::set<OBSTACLE> keeps them: one for each head and item, in the
/// order of the head's and then the item's making. (KiCad orders them by address, so that which of two obstacles met
/// at the same place comes first is down to its memory allocator; tools/kicad-reference has KiCad order them as here.)
public final class CollisionSearchContext {
    public let options: CollisionSearchOptions
    private(set) var obstacles: [Obstacle] = []
    private var keys = Set<Key>()

    struct Key: Hashable, Comparable {
        var head: Int, item: Int
        static func < (a: Key, b: Key) -> Bool { a.head != b.head ? a.head < b.head : a.item < b.item }
    }

    public init(options: CollisionSearchOptions = CollisionSearchOptions()) { self.options = options }

    public var count: Int { obstacles.count }

    func insert(_ o: Obstacle) {
        let key = Key(head: o.head.serial, item: o.item.serial)
        guard keys.insert(key).inserted else { return }
        let i = obstacles.firstIndex { Key(head: $0.head.serial, item: $0.item.serial) > key } ?? obstacles.count
        obstacles.insert(o, at: i)
    }
}

/// The design rules, as the board's side gives them (KiCad's RULE_RESOLVER)
public protocol RuleResolver: AnyObject {
    /// The clearance two items need (-1 for none: the same net, say)
    func clearance(_ a: Item, _ b: Item?, useEpsilon: Bool) -> Int
    var hasUserDefinedPhysicalConstraint: Bool { get }
    func isInNetTie(_ a: Item) -> Bool
    func isNetTieExclusion(_ item: Item, _ pos: IPoint, _ colliding: Item) -> Bool
    func isDrilledHole(_ item: Item) -> Bool
    func isNonPlatedSlot(_ item: Item) -> Bool
    /// Whether the item stands for the board's outline (KiCad checks its parent's layer is Edge.Cuts)
    func isOnEdgeCuts(_ item: Item) -> Bool
    func isKeepout(_ obstacle: Item, _ item: Item, _ enforce: inout Bool) -> Bool
    func queryConstraint(_ type: ConstraintType, _ a: Item?, _ b: Item?, layer: Int) -> Constraint?
    var clearanceEpsilon: Int { get }
    func hullCache(_ item: Item, clearance: Int, walkaroundThickness: Int, layer: Int) -> LineChain
    func clearCaches()
    func clearTemporaryCaches()
}

extension RuleResolver {
    public func hullCache(_ item: Item, clearance: Int, walkaroundThickness: Int, layer: Int) -> LineChain {
        item.hull(clearance: clearance, walkaroundThickness: walkaroundThickness, layer: layer)
    }
    public func clearCaches() {}
    public func clearTemporaryCaches() {}
}

public enum ConstraintType: Int, Sendable {
    case clearance = 1, diffPairGap, length, width, viaDiameter, viaHole, holeClearance, edgeClearance, holeToHole,
         diffPairSkew, maxUncoupled, physicalClearance, physicalHoleClearance
}

/// A rule's values (KiCad's CONSTRAINT, its MINOPTMAX)
public struct Constraint: Sendable {
    public var type: ConstraintType
    public var min: Int
    public var opt: Int
    public var max: Int
    public var allowed = true
    public var ruleName = ""

    public init(type: ConstraintType, min: Int, opt: Int? = nil, max: Int = Int.max) {
        self.type = type
        self.min = min
        self.opt = opt ?? min
        self.max = max
    }
}

/// Where items meet: a point of a net on some layers, and what is linked there (KiCad's JOINT)
public final class Joint: Item {
    public struct Tag: Hashable {
        public var pos: IPoint
        public var net: NetHandle?
    }

    public let tag: Tag
    public private(set) var links: [Item] = []
    public private(set) var isJointLocked = false

    public init(_ pos: IPoint, _ layers: LayerRange, net: NetHandle?) {
        tag = Tag(pos: pos, net: net)
        super.init(kind: .joint)
        self.layers = layers
    }

    /// A copy, its links the same items
    public init(copying j: Joint) {
        tag = j.tag
        super.init(kind: .joint)
        layers = j.layers
        links = j.links
        isJointLocked = j.isJointLocked
    }

    public var pos: IPoint { tag.pos }
    public override var net: NetHandle? {
        get { tag.net }
        set {}
    }

    public func isLineCorner(allowLockedSegments: Bool = false) -> Bool {
        let segs = links.filter { $0.ofKind([.segment, .arc]) }
        if links.count == 2 && segs.count == 2 {
            let s1 = links[0] as! LinkedItem, s2 = links[1] as! LinkedItem
            if !allowLockedSegments && (s1.isLocked || s2.isLocked) { return false }
            return s1.width == s2.width
        } else if links.count > 2 && segs.count == 2 {
            if !allowLockedSegments { return false }
            var s1: LinkedItem?, s2: LinkedItem?
            for item in links where !item.isVirtual {
                if item.kind == .segment || item.kind == .arc {
                    if s1 == nil { s1 = item as? LinkedItem } else { s2 = item as? LinkedItem }
                } else {
                    return false
                }
            }
            if let s1, let s2 { return s1.width == s2.width }
        }
        return false
    }

    public var isNonFanoutVia: Bool {
        var vias = 0, segs = 0, real = 0
        for item in links where !item.isVirtual {
            if item.kind == .via { vias += 1 } else if item.kind == .segment || item.kind == .arc { segs += 1 }
            real += 1
        }
        return real == 3 && vias == 1 && segs == 2
    }

    public var isStitchingVia: Bool { links.count == 1 && links[0].kind == .via }
    public var isTrivialEndpoint: Bool { links.count == 1 && links[0].kind == .segment }

    public var isTraceWidthChange: Bool {
        if linkCount(.segment) != 2 { return false }
        var s1: LinkedItem?, s2: LinkedItem?
        for item in links where !item.isVirtual {
            if item.kind == .via { return false }
            if item.kind == .segment || item.kind == .arc {
                if s1 == nil { s1 = item as? LinkedItem } else { s2 = item as? LinkedItem }
            }
        }
        guard let s1, let s2 else { return false }
        return s1.width != s2.width
    }

    public func link(_ item: Item) {
        if links.contains(where: { $0 === item }) { return }
        links.append(item)
    }

    @discardableResult
    public func unlink(_ item: Item) -> Bool {
        if let i = links.firstIndex(where: { $0 === item }) { links.remove(at: i) }
        if links.isEmpty { layers = LayerRange(-1) }
        return links.isEmpty
    }

    /// The one other segment of the same net and layer here, if there is just one and nothing else (no pad or via)
    public func nextSegment(_ current: LinkedItem, allowLockedSegments: Bool = false) -> LinkedItem? {
        var other: LinkedItem?
        for item in links where item !== current {
            if item.ofKind([.segment, .arc]) {
                if item.net == current.net && item.layers.overlaps(current.layers) {
                    if other != nil { return nil }
                    if !item.isLocked || allowLockedSegments { other = item as? LinkedItem }
                }
            } else if item.ofKind([.solid, .via]) {
                if item.kind == .via && item.isVirtual && allowLockedSegments { continue }
                return nil
            }
        }
        return other
    }

    public var via: Via? { links.first { $0.ofKind(.via) } as? Via }

    public func linkCount(_ mask: ItemKind = .any) -> Int {
        mask == .any ? links.count : links.filter { $0.ofKind(mask) }.count
    }

    public func merge(_ j: Joint) {
        if !overlaps(j) { return }
        layers.merge(j.layers)
        if j.isJointLocked { isJointLocked = true }
        links.append(contentsOf: j.links)
    }

    public func overlaps(_ j: Joint) -> Bool { tag == j.tag && layers.overlaps(j.layers) }

    public func lock(_ l: Bool = true) { isJointLocked = l }
}

/// The items of a node, indexed by layer and box, and by net (KiCad's PNS::INDEX)
final class ItemIndex {
    private var subIndices: [RTree<Item>] = []
    private var netMap: [NetHandle: [Item]] = [:]
    /// Everything, in the order it came (KiCad keeps an unordered set)
    private(set) var all: [Item] = []
    private var allIDs = Set<ObjectIdentifier>()

    func add(_ item: Item) {
        let range = item.layers
        while subIndices.count <= range.end { subIndices.append(RTree()) }
        for i in range.start...range.end {
            if let s = item.shape(i) { subIndices[i].insert(s.bbox, item) }
        }
        if allIDs.insert(ObjectIdentifier(item)).inserted { all.append(item) }
        if let net = item.net { netMap[net, default: []].append(item) }
    }

    func remove(_ item: Item) {
        let range = item.layers
        if subIndices.count <= range.end { return }
        for i in range.start...range.end {
            if let s = item.shape(i) { subIndices[i].remove(s.bbox, item) }
        }
        if allIDs.remove(ObjectIdentifier(item)) != nil, let i = all.firstIndex(where: { $0 === item }) { all.remove(at: i) }
        if let net = item.net, var list = netMap[net] {
            list.removeAll { $0 === item }
            netMap[net] = list
        }
    }

    func contains(_ item: Item) -> Bool { allIDs.contains(ObjectIdentifier(item)) }
    var count: Int { all.count }

    func items(forNet net: NetHandle?) -> [Item]? {
        guard let net else { return nil }
        return netMap[net]
    }

    /// Visits what may be within `minDistance` of `item`, layer by layer; how many it visited
    @discardableResult
    func query(_ item: Item, minDistance: Int, _ visitor: ObstacleVisitor) -> Int {
        var total = 0
        let layers = item.layers
        guard layers.start >= 0 else { return 0 }
        for i in layers.start...layers.end {
            if let s = item.shape(i) { total += querySingle(i, s, minDistance, visitor) }
        }
        return total
    }

    @discardableResult
    func query(_ shape: Shape, minDistance: Int, _ visitor: ObstacleVisitor) -> Int {
        var total = 0
        for i in subIndices.indices { total += querySingle(i, shape, minDistance, visitor) }
        return total
    }

    private func querySingle(_ index: Int, _ shape: Shape, _ minDistance: Int, _ visitor: ObstacleVisitor) -> Int {
        guard index < subIndices.count else { return 0 }
        visitor.layerContext = index
        defer { visitor.layerContext = nil }
        return subIndices[index].search(shape.bbox.inflated(minDistance)) { visitor.visit($0) }
    }
}

/// What a search of the index does with each item it finds (KiCad's OBSTACLE_VISITOR)
class ObstacleVisitor {
    let item: Item?
    unowned(unsafe) var node: Node!
    weak var overrideNode: Node?
    var layerContext: Int?

    init(_ item: Item?) { self.item = item }

    func setWorld(_ node: Node, _ override: Node? = nil) {
        self.node = node
        overrideNode = override
    }

    /// Whether a later branch has its own version of the candidate
    func isOverridden(_ candidate: Item) -> Bool { overrideNode?.overrides(candidate) ?? false }

    /// Whether to go on searching
    func visit(_ candidate: Item) -> Bool { true }
}

/// The router's world: the board's items and the joints between them, and branches of it that try changes without
/// touching it (KiCad's PNS::NODE)
public final class Node {
    public private(set) var depth = 0
    public private(set) weak var parent: Node?
    /// (the root owns itself; KiCad's m_root)
    private var _root: Node?
    public var root: Node { _root ?? self }
    private var children: [Node] = []
    private var overrideIDs = Set<ObjectIdentifier>()
    public private(set) var overrides: [Item] = []
    public var maxClearance = 800_000
    public var ruleResolver: RuleResolver!
    let index = ItemIndex()
    private var joints: [Joint.Tag: [Joint]] = [:]
    private var jointOrder: [Joint.Tag] = []
    private var edgeExclusions: [Shape] = []

    public init() {}

    public var isRoot: Bool { parent == nil }
    public var jointCount: Int { joints.values.reduce(0) { $0 + $1.count } }
    public var hasChildren: Bool { !children.isEmpty }
    public var items: [Item] { index.all }

    public func clearance(_ a: Item, _ b: Item, useEpsilon: Bool = true) -> Int {
        guard let ruleResolver else { return 100_000 }
        if a.isVirtual || b.isVirtual { return 0 }
        return ruleResolver.clearance(a, b, useEpsilon: useEpsilon)
    }

    /// A branch of this node: changes made in it leave this one as it is
    public func branch() -> Node {
        let child = Node()
        children.append(child)
        child.depth = depth + 1
        child.parent = self
        child.ruleResolver = ruleResolver
        child._root = isRoot ? self : root
        child.maxClearance = maxClearance
        // (the root's own children copy nothing; deeper ones copy their parent's items, joints and overrides; the
        // items in the order they were made, as tools/kicad-reference has KiCad copy them: KiCad takes them from a
        // hash set of pointers, in no order but the allocator's, and the order they go into the R-trees in decides
        // which obstacle a search that stops at the first finds)
        if !isRoot {
            for item in Node.bySerial(index.all) { child.index.add(item) }
            for tag in jointOrder {
                if let js = joints[tag] { child.joints[tag] = js.map(Joint.init(copying:)) }
            }
            child.jointOrder = jointOrder
            child.overrideIDs = overrideIDs
            child.overrides = overrides
        }
        return child
    }

    public func overrides(_ item: Item) -> Bool { overrideIDs.contains(ObjectIdentifier(item)) }

    private func addOverride(_ item: Item) {
        if overrideIDs.insert(ObjectIdentifier(item)).inserted { overrides.append(item) }
    }

    // MARK: - Collisions

    final class DefaultObstacleVisitor: ObstacleVisitor {
        let ctx: CollisionSearchContext

        init(_ ctx: CollisionSearchContext, _ item: Item) {
            self.ctx = ctx
            super.init(item)
        }

        override func visit(_ candidate: Item) -> Bool {
            if !candidate.ofKind(ctx.options.kindMask) { return true }
            if item === candidate { return true }
            if let f = ctx.options.filter, !f(candidate) { return true }
            if isOverridden(candidate) { return true }
            if !candidate.collide(item!, node, layer: layerContext ?? -1, context: ctx) { return true }
            if ctx.options.limitCount > 0 && ctx.count >= ctx.options.limitCount { return false }
            return true
        }
    }

    /// What `item` comes too close to, added to `ctx`; how many there are now
    @discardableResult
    public func queryColliding(_ item: Item, _ ctx: CollisionSearchContext) -> Int {
        if item.isVirtual { return 0 }
        let visitor = DefaultObstacleVisitor(ctx, item)
        visitor.setWorld(self)
        index.query(item, minDistance: maxClearance, visitor)
        if !isRoot && (ctx.count < ctx.options.limitCount || ctx.options.limitCount < 0) {
            visitor.setWorld(root, self)
            root.index.query(item, minDistance: maxClearance, visitor)
        }
        return ctx.count
    }

    public func queryColliding(_ item: Item, options: CollisionSearchOptions = CollisionSearchOptions()) -> [Obstacle] {
        let ctx = CollisionSearchContext(options: options)
        queryColliding(item, ctx)
        return ctx.obstacles
    }

    /// The obstacle `line` meets first along its path (KiCad's NearestObstacle)
    public func nearestObstacle(_ line: Line, options: CollisionSearchOptions = CollisionSearchOptions()) -> Obstacle? {
        let cornerMode = Router.instance?.settings.cornerMode ?? .mitered45
        let ctx = CollisionSearchContext(options: options)
        for i in 0..<line.cLine.segmentCount {
            queryColliding(Segment(line: line, line.cLine.segment(i)), ctx)
        }
        if let via = line.via { queryColliding(via, ctx) }
        let obstacles = ctx.obstacles
        if obstacles.isEmpty { return nil }
        let layer = line.layer
        let simplifyHull = cornerMode == .mitered90
        func makeHull(_ cached: LineChain) -> LineChain {
            guard simplifyHull else { return cached }
            let b = cached.bbox
            return LineChain([IPoint(b.minX, b.minY), IPoint(b.maxX, b.minY), IPoint(b.maxX, b.maxY), IPoint(b.minX, b.maxY)])
        }
        var nearest: Obstacle?
        var nearestDist = Int(Int32.max)
        for obstacle in obstacles {
            let clearance = self.clearance(obstacle.item, line, useEpsilon: options.useClearanceEpsilon) + line.width / 2
            var hulls = [makeHull(ruleResolver.hullCache(obstacle.item, clearance: clearance, walkaroundThickness: 0, layer: layer))]
            if let via = line.via {
                let viaClearance = self.clearance(obstacle.item, via, useEpsilon: options.useClearanceEpsilon) + via.diameter / 2
                hulls.append(makeHull(ruleResolver.hullCache(obstacle.item, clearance: viaClearance, walkaroundThickness: 0, layer: layer)))
            }
            var dist = Int(Int32.max), ip = IPoint.zero
            for hull in hulls {
                for x in Shape.hullIntersection(hull, line.cLine) where x.valid {
                    let d = line.cLine.pathLength(x.p, index: x.indexTheir)
                    if d < dist {
                        dist = d
                        ip = x.p
                    }
                }
            }
            if dist < nearestDist {
                nearest = obstacle
                nearest?.distFirst = dist
                nearest?.ipFirst = ip
                nearestDist = dist
                if dist == 0 { break }
            }
        }
        // (none crossed: the first found, as it was found)
        return nearest ?? obstacles[0]
    }

    public func checkColliding(_ items: [Item], kindMask: ItemKind = .any) -> Obstacle? {
        for item in items {
            if let o = checkColliding(item, kindMask: kindMask) { return o }
        }
        return nil
    }

    public func checkColliding(_ item: Item, kindMask: ItemKind = .any) -> Obstacle? {
        var opts = CollisionSearchOptions()
        opts.kindMask = kindMask
        opts.limitCount = 1
        return checkColliding(item, options: opts)
    }

    public func checkColliding(_ item: Item, options: CollisionSearchOptions) -> Obstacle? {
        let ctx = CollisionSearchContext(options: options)
        if let line = item as? Line {
            let l = line.cLine
            for i in 0..<l.segmentCount {
                let s = Segment(line: line, l.segment(i))
                if queryColliding(s, ctx) > 0 { return ctx.obstacles.first }
            }
            if let via = line.via, queryColliding(via, ctx) > 0 { return ctx.obstacles.first }
        } else if queryColliding(item, ctx) > 0 {
            return ctx.obstacles.first
        }
        return nil
    }

    final class HitVisitor: ObstacleVisitor {
        var found: [Item] = []
        let point: IPoint

        init(_ point: IPoint) {
            self.point = point
            super.init(nil)
        }

        override func visit(_ candidate: Item) -> Bool {
            if let s = candidate.shape(-1), s.collide(.circle(center: point, radius: 0), clearance: 0) { found.append(candidate) }
            return true
        }
    }

    /// What is under `point`
    public func hitTest(_ point: IPoint) -> [Item] {
        let s = Shape.circle(center: point, radius: 0)
        let visitor = HitVisitor(point)
        visitor.setWorld(self)
        index.query(s, minDistance: maxClearance, visitor)
        var items = visitor.found
        if !isRoot {
            let rootVisitor = HitVisitor(point)
            rootVisitor.setWorld(root)
            root.index.query(s, minDistance: maxClearance, rootVisitor)
            items += rootVisitor.found.filter { !overrides($0) }
        }
        return items
    }

    // MARK: - Adding

    private func addSolid(_ solid: Solid) {
        if let h = solid.hole { addHole(h) }
        if solid.isRoutable { linkJoint(solid.pos, solid.layers, solid.net, solid) }
        solid.owner = self
        index.add(solid)
    }

    public func add(_ solid: Solid) {
        solid.owner = self
        addSolid(solid)
    }

    private func addVia(_ via: Via) {
        if via.hasHole, let h = via.hole { addHole(h) }
        linkJoint(via.pos, via.layers, via.net, via)
        via.owner = self
        index.add(via)
    }

    private func addHole(_ hole: Hole) {
        hole.owner = self
        index.add(hole)
    }

    public func add(_ via: Via) { addVia(via) }

    /// Adds an item of any kind (KiCad's AddRaw)
    public func addRaw(_ item: Item, allowRedundant: Bool = false) {
        switch item {
        case let s as Segment: addSegment(s)
        case let v as Via: addVia(v)
        case let s as Solid: addSolid(s)
        default: break // holes come with their pads and vias
        }
    }

    /// Adds a line's segments, linking it to them (and to ones already here, unless redundant ones are allowed)
    public func add(_ line: Line, allowRedundant: Bool = false) {
        let l = line.cLine
        for i in 0..<l.segmentCount {
            let s = l.segment(i)
            if s.a == s.b { continue }
            if !allowRedundant, let r = findRedundantSegment(s.a, s.b, line.layers, line.net) {
                // (another line may already have it)
                if !line.containsLink(r) { line.link(r) }
            } else {
                let seg = Segment(line: line, s)
                line.link(seg)
                add(seg, allowRedundant: true)
            }
        }
    }

    private func addSegment(_ seg: Segment) {
        seg.owner = self
        linkJoint(seg.seg.a, seg.layers, seg.net, seg)
        linkJoint(seg.seg.b, seg.layers, seg.net, seg)
        index.add(seg)
    }

    @discardableResult
    public func add(_ seg: Segment, allowRedundant: Bool = false) -> Bool {
        if seg.seg.a == seg.seg.b { return false }
        if !allowRedundant && findRedundantSegment(seg) != nil { return false }
        addSegment(seg)
        return true
    }

    public func addEdgeExclusion(_ shape: Shape) { edgeExclusions.append(shape) }

    public func queryEdgeExclusions(_ pos: IPoint) -> Bool {
        edgeExclusions.contains { $0.collide(.circle(center: pos, radius: 0), clearance: 0) }
    }

    // MARK: - Removing

    private func doRemove(_ item: Item) {
        var holeRemoved = false
        if item.owner === root && !isRoot {
            // the root's: overridden here, not removed
            addOverride(item)
            if let h = item.hole { addOverride(h) }
        } else if item.owner !== root || isRoot {
            index.remove(item)
            if let h = item.hole {
                index.remove(h)
                holeRemoved = true
            }
        }
        if item.owner === self {
            item.owner = nil
            if let h = item.hole {
                if !holeRemoved { index.remove(h) }
                h.owner = item
            }
        }
    }

    private func removeSegmentIndex(_ seg: Segment) {
        unlinkJoint(seg.seg.a, seg.layers, seg.net, seg)
        unlinkJoint(seg.seg.b, seg.layers, seg.net, seg)
    }

    private func rebuildJoint(_ joint: Joint?, _ item: Item) {
        guard let joint else { return }
        // a pad's or via's joint split into the joints of what was linked to it: all taken out and put back
        let links = joint.links
        let tag = Joint.Tag(pos: joint.pos, net: item.net)
        var split = true
        while split {
            split = false
            guard var range = joints[tag] else { break }
            if let i = range.firstIndex(where: { item.layersOverlap($0) }) {
                range.remove(at: i)
                setJoints(tag, range)
                split = true
            }
        }
        var completelyErased = false
        if !isRoot && (joints[tag] ?? []).isEmpty {
            setJoints(tag, [Joint(tag.pos, LayerRange(-1), net: tag.net)])
            completelyErased = true
        }
        for link in links {
            if link !== item {
                linkJoint(tag.pos, link.layers, tag.net, link)
            } else if !completelyErased {
                unlinkJoint(tag.pos, link.layers, tag.net, link)
            }
        }
    }

    private func removeViaIndex(_ via: Via) {
        rebuildJoint(findJoint(via.pos, layer: via.layers.start, net: via.net), via)
    }

    private func removeSolidIndex(_ solid: Solid) {
        if !solid.isRoutable { return }
        rebuildJoint(findJoint(solid.pos, layer: solid.layers.start, net: solid.net), solid)
    }

    public func replace(_ old: Item, with new: Item) {
        remove(old)
        addRaw(new)
    }

    public func replace(_ old: Line, with new: Line, allowRedundantSegments: Bool = false) {
        remove(old)
        add(new, allowRedundant: allowRedundantSegments)
    }

    public func remove(_ item: Item) {
        switch item {
        case let solid as Solid:
            if let h = solid.hole {
                remove(h)
                h.owner = solid
            }
            removeSolidIndex(solid)
            doRemove(solid)
        case let seg as Segment:
            removeSegmentIndex(seg)
            doRemove(seg)
        case let line as Line:
            for s in line.links { remove(s) }
        case let via as Via:
            if via.hasHole, let h = via.hole {
                remove(h)
                h.owner = via
            }
            removeViaIndex(via)
            doRemove(via)
        case is Hole:
            // (KiCad's Remove(ITEM*) passes holes by)
            break
        default:
            break
        }
    }

    /// Takes a line's items out (a line is never in the node itself)
    public func remove(_ line: Line) {
        for li in line.links {
            if let s = li as? Segment {
                removeSegmentIndex(s)
                doRemove(s)
            } else if let v = li as? Via {
                removeViaIndex(v)
                doRemove(v)
            }
        }
        line.owner = nil
        line.clearLinks()
    }

    // MARK: - Lines

    private func followLine(_ start: LinkedItem, _ scanDirection: Bool, _ pos: inout Int, _ limit: Int,
                            _ corners: inout [IPoint], _ segments: inout [LinkedItem?], _ guardHit: inout Bool,
                            _ stopAtLockedJoints: Bool, _ followLockedSegments: Bool, _ allowSegmentSizeMismatch: Bool) {
        var current = start
        var prevReversed = false
        let guardPoint = current.anchor(scanDirection ? 1 : 0)
        let startWidth = current.width
        var count = 0
        while true {
            let p = current.anchor((scanDirection != prevReversed) ? 1 : 0)
            guard let jt = findJoint(p, current) else { break }
            corners[pos] = jt.pos
            segments[pos] = current
            pos += scanDirection ? 1 : -1
            if count > 0 && guardPoint == p {
                if pos >= 0 && pos < limit { segments[pos] = nil }
                guardHit = true
                break
            }
            let locked = stopAtLockedJoints ? jt.isJointLocked : false
            if locked || pos < 0 || pos == limit { break }
            guard let next = jt.nextSegment(current, allowLockedSegments: followLockedSegments),
                  allowSegmentSizeMismatch || next.width == startWidth else { break }
            current = next
            prevReversed = jt.pos == current.anchor(scanDirection ? 1 : 0)
            count += 1
        }
    }

    /// The line `seg` is a segment of: the segments joined end to end through joints with nothing else at them
    public func assembleLine(_ seg: LinkedItem, originSegmentIndex: UnsafeMutablePointer<Int>? = nil,
                             stopAtLockedJoints: Bool = false, followLockedSegments: Bool = false,
                             allowSegmentSizeMismatch: Bool = true) -> Line {
        let maxVerts = 1024 * 16
        var corners = Array(repeating: IPoint.zero, count: maxVerts + 1)
        var segs = [LinkedItem?](repeating: nil, count: maxVerts + 1)
        let pl = Line()
        var guardHit = false
        var iStart = maxVerts / 2
        var iEnd = iStart + 1
        pl.setWidth(seg.width)
        pl.layers = seg.layers
        pl.net = seg.net
        pl.parent = nil
        pl.sourceItem = seg.sourceItem
        pl.owner = self
        followLine(seg, false, &iStart, maxVerts, &corners, &segs, &guardHit, stopAtLockedJoints, followLockedSegments,
                   allowSegmentSizeMismatch)
        if !guardHit {
            followLine(seg, true, &iEnd, maxVerts, &corners, &segs, &guardHit, stopAtLockedJoints, followLockedSegments,
                       allowSegmentSizeMismatch)
        }
        var prev: LinkedItem?
        var originSet = false
        var chain = LineChain()
        for i in (iStart + 1)..<iEnd {
            let p = corners[i]
            let li = segs[i]
            chain.append(p)
            if let li, prev !== li {
                pl.link(li)
                if li === seg, let originSegmentIndex, !originSet {
                    originSegmentIndex.pointee = chain.pointCount - 1
                    originSet = true
                }
            }
            prev = li
        }
        // duplicate points removed, but not collinear segments
        chain.removeDuplicatePoints()
        pl.setShape(chain)
        if let originSegmentIndex, originSegmentIndex.pointee >= pl.segmentCount {
            originSegmentIndex.pointee = pl.segmentCount - 1
        }
        return pl
    }

    public func findLineEnds(_ line: Line) -> (Joint?, Joint?) {
        (findJoint(line.cPoint(0), line), findJoint(line.cLastPoint, line))
    }

    public func findLinesBetweenJoints(_ a: Joint, _ b: Joint) -> [Line] {
        var lines: [Line] = []
        for item in a.links where item.kind == .segment || item.kind == .arc {
            let line = assembleLine(item as! LinkedItem)
            if !line.layers.overlaps(b.layers) { continue }
            var idStart = line.cLine.find(a.pos), idEnd = line.cLine.find(b.pos)
            if idEnd < idStart { swap(&idStart, &idEnd) }
            if idStart >= 0 && idEnd >= 0 {
                line.clipVertexRange(idStart, idEnd)
                lines.append(line)
            }
        }
        return lines
    }

    /// Virtual vias where tracks change width or are locked, for the shove to push against (KiCad's
    /// FixupVirtualVias)
    public func fixupVirtualVias() {
        let hullMargin = 10
        var vvias: [VirtualVia] = []
        var lockedSeg: Segment?
        // (the joints by place, net and layer, as tools/kicad-reference has KiCad take them: it takes them from its
        // hash map, whose order comes from the hashes of places and of nets' addresses)
        let byPlace = jointOrder.flatMap { joints[$0] ?? [] }.sorted { a, b in
            if a.pos.x != b.pos.x { return a.pos.x < b.pos.x }
            if a.pos.y != b.pos.y { return a.pos.y < b.pos.y }
            if a.net != b.net { return (a.net ?? Int.min) < (b.net ?? Int.min) }
            return a.layers.start < b.layers.start
        }
        for joint in byPlace where !joint.layers.isMultilayer {
            let nSeg = 0
            var nSolid = 0, nVias = 0
            var prevW = -1
            var prevMask = false
            var prevMaskMargin: Int?
            var maxW = -1
            var isWidthChange = false, isLocked = false
            for item in joint.links {
                if item.ofKind(.via) {
                    nVias += 1
                } else if item.ofKind(.solid) {
                    nSolid += 1
                } else if let t = item as? Segment {
                    let w = t.width
                    let (mask, maskMargin) = Router.interface?.solderMask(t) ?? (false, nil)
                    if prevW < 0 {
                        prevW = w
                        prevMask = mask
                        prevMaskMargin = maskMargin
                    } else if w != prevW || mask != prevMask || maskMargin != prevMaskMargin {
                        isWidthChange = true
                    }
                    maxW = max(w, maxW)
                    prevW = w
                    isLocked = t.isLocked
                    lockedSeg = t
                }
            }
            // (KiCad counts no segments here: its n_seg stays 0)
            if (isWidthChange || nSeg >= 3 || isLocked) && nSolid == 0 && nVias == 0 {
                vvias.append(VirtualVia(pos: joint.pos, layer: joint.layers.start, diameter: maxW + 2 * hullMargin, net: joint.net))
            }
            if isLocked, let s = lockedSeg {
                let secondPos = s.seg.a == joint.pos ? s.seg.b : s.seg.a
                vvias.append(VirtualVia(pos: secondPos, layer: joint.layers.start, diameter: maxW + 2 * hullMargin, net: joint.net))
            }
        }
        for v in vvias { add(v) }
    }

    // MARK: - Joints

    public func findJoint(_ pos: IPoint, layer: Int, net: NetHandle?) -> Joint? {
        let tag = Joint.Tag(pos: pos, net: net)
        var list = joints[tag] ?? []
        if list.isEmpty && !isRoot { list = root.joints[tag] ?? [] }
        return list.first { $0.layers.overlaps(layer) }
    }

    public func findJoint(_ pos: IPoint, _ item: Item) -> Joint? { findJoint(pos, layer: item.layers.start, net: item.net) }

    public func lockJoint(_ pos: IPoint, _ item: Item, _ lock: Bool) {
        touchJoint(pos, item.layers, item.net).lock(lock)
    }

    private func setJoints(_ tag: Joint.Tag, _ list: [Joint]) {
        if joints[tag] == nil { jointOrder.append(tag) }
        joints[tag] = list
    }

    /// (A tag's joints are kept in the order KiCad's unordered_multimap gives them, libstdc++'s: a joint inserted with
    /// a tag already there goes in front of the others, so the last made comes first; the order decides whose links
    /// come first when joints are merged into a via's or a pad's.)
    @discardableResult
    private func touchJoint(_ pos: IPoint, _ layers: LayerRange, _ net: NetHandle?) -> Joint {
        let tag = Joint.Tag(pos: pos, net: net)
        // not here? the root's copied in (inserted one by one, each in front of the last)
        if (joints[tag] ?? []).isEmpty && !isRoot, let rootJoints = root.joints[tag], !rootJoints.isEmpty {
            setJoints(tag, rootJoints.reversed().map(Joint.init(copying:)))
        }
        // the joints this one overlaps merged into it
        let jt = Joint(pos, layers, net: net)
        var merged = true
        while merged {
            merged = false
            guard var range = joints[tag] else { break }
            if let i = range.firstIndex(where: { layers.overlaps($0.layers) }) {
                jt.merge(range[i])
                range.remove(at: i)
                setJoints(tag, range)
                merged = true
            }
        }
        var range = joints[tag] ?? []
        range.insert(jt, at: 0)
        setJoints(tag, range)
        return jt
    }

    private func linkJoint(_ pos: IPoint, _ layers: LayerRange, _ net: NetHandle?, _ item: Item) {
        touchJoint(pos, layers, net).link(item)
    }

    private func unlinkJoint(_ pos: IPoint, _ layers: LayerRange, _ net: NetHandle?, _ item: Item) {
        touchJoint(pos, layers, net).unlink(item)
    }

    /// The joints in `box`, on `layers`, with links of `kinds`
    public func queryJoints(_ box: IBox, layers: LayerRange = .all, kinds: ItemKind = .any) -> [Joint] {
        var found: [Joint] = []
        for tag in jointOrder {
            for j in joints[tag] ?? [] where j.layers.overlaps(layers) && box.contains(j.pos) && j.linkCount(kinds) > 0 {
                found.append(j)
            }
        }
        if isRoot { return found }
        for tag in root.jointOrder {
            for j in root.joints[tag] ?? [] where !overrides(j) && j.layers.overlaps(layers) && box.contains(j.pos) && j.linkCount(kinds) > 0 {
                found.append(j)
            }
        }
        return found
    }

    // MARK: - Branches

    /// Items in the order they were made (in which tools/kicad-reference has KiCad take a node's hash sets of them)
    static func bySerial(_ items: [Item]) -> [Item] { items.sorted { $0.serial < $1.serial } }

    /// What this branch takes out of the root, and what it adds, each in the order the items were made
    public func updatedItems() -> (removed: [Item], added: [Item]) {
        if isRoot { return ([], []) }
        return (Node.bySerial(overrides), Node.bySerial(index.all))
    }

    private func releaseChildren() {
        for child in children { child.releaseChildren() }
        for child in children { child.parent = nil }
        children.removeAll()
    }

    /// Takes in a branch's changes (KiCad's Commit)
    public func commit(_ node: Node) {
        if node.isRoot { return }
        for item in Node.bySerial(node.overrides) { remove(item) }
        for item in Node.bySerial(node.index.all) {
            if let h = item.hole { h.owner = item }
            item.rank = -1
            item.unmark()
            addRaw(item)
        }
        releaseChildren()
    }

    public func killChildren() { releaseChildren() }

    /// Lets go of a branch of this node (KiCad deletes the branch)
    public func release(_ child: Node) {
        child.releaseChildren()
        children.removeAll { $0 === child }
        child.parent = nil
    }

    public func allItems(inNet net: NetHandle?, kinds: ItemKind = .any) -> [Item] {
        var found: [Item] = []
        var seen = Set<ObjectIdentifier>()
        for item in index.items(forNet: net) ?? [] where item.ofKind(kinds) && item.isRoutable {
            if seen.insert(ObjectIdentifier(item)).inserted { found.append(item) }
        }
        if !isRoot {
            for item in root.index.items(forNet: net) ?? [] where !overrides(item) && item.ofKind(kinds) && item.isRoutable {
                if seen.insert(ObjectIdentifier(item)).inserted { found.append(item) }
            }
        }
        return found
    }

    public func clearRanks(_ markers: Marker = [.head, .violation]) {
        for item in index.all {
            item.rank = -1
            item.mark(item.marker.subtracting(markers))
        }
    }

    public func removeByMarker(_ m: Marker) {
        for item in index.all.filter({ !$0.marker.intersection(m).isEmpty }) { remove(item) }
    }

    private func findRedundantSegment(_ a: IPoint, _ b: IPoint, _ layers: LayerRange, _ net: NetHandle?) -> Segment? {
        guard let jt = findJoint(a, layer: layers.start, net: net) else { return nil }
        for case let s as Segment in jt.links {
            if s.layers.start == layers.start && ((a == s.seg.a && b == s.seg.b) || (a == s.seg.b && b == s.seg.a)) { return s }
        }
        return nil
    }

    private func findRedundantSegment(_ seg: Segment) -> Segment? { findRedundantSegment(seg.seg.a, seg.seg.b, seg.layers, seg.net) }

    public func findItem(byParent parent: AnyObject, net: NetHandle?) -> Item? {
        index.items(forNet: net)?.first { $0.parent === parent }
    }

    public func findItems(byParent parent: AnyObject) -> [Item] { index.all.filter { $0.parent === parent } }

    public func findVia(_ handle: Via.Handle) -> Via? {
        guard let jt = findJoint(handle.pos, layer: handle.layers.start, net: handle.net) else { return nil }
        return jt.links.first { $0.ofKind(.via) && $0.net == handle.net && $0.layers.overlaps(handle.layers) } as? Via
    }
}
