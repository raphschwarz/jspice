// Ported from KiCad 10.0.7: pcbnew/router/pns_kicad_iface.cpp (PNS_PCBNEW_RULE_RESOLVER: QueryConstraint, a line of
// several segments with no board item evaluated segment by segment where the rules have geometry-dependent
// conditions, getBoardItem's dummy tracks, arcs and vias, Clearance and its caches of board items' and temporary
// items' clearances, HasUserDefinedPhysicalConstraint; PNS_KICAD_IFACE_BASE::ImportSizes, the sizes the rules give)
// and pcbnew/pcb_track.cpp (the dummies' defaults: a track's width, a via's layers).
// Copyright (C) 2013-2016 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// A world item as the router's items keep it: the board item a router item stands for to the design rules
/// (KiCad's BOARD_ITEM parent of a router item)
public final class WorldItemRef {
    public let item: WorldItem
    public init(_ item: WorldItem) { self.item = item }
}

/// The design rules a world's resolver goes by: a board's rules engine (its DRC_ENGINE), the board's items as the
/// engine sees them, and the dummy items the resolver asks it about for router items with no board item behind them
final class RouterRules {
    let engine: DesignRuleEngine
    /// The rule item of a world item (its board item), made once
    private let makeItem: (WorldItem) -> RuleItem
    private var items: [ObjectIdentifier: RuleItem] = [:]
    /// KiCad's layer id of a router layer (UNDEFINED_LAYER for none)
    let boardLayer: (Int) -> Int
    /// A net's code, name and effective net class
    let net: (NetHandle?) -> (code: Int, name: String, netClass: RuleItem.NetClassRef)
    let copperLayers: Int
    let maxError: Int

    /// KiCad's m_dummyTracks, m_dummyArcs and m_dummyVias: router transients, each kept as it was last set (a dummy
    /// track's width only where a line's segments set it, else a new track's 0.2 mm)
    private let dummyTracks = [RuleItem(.track, uuid: ""), RuleItem(.track, uuid: "")]
    private let dummyArcs = [RuleItem(.arc, uuid: ""), RuleItem(.arc, uuid: "")]
    private let dummyVias = [RuleItem(.via, uuid: ""), RuleItem(.via, uuid: "")]
    private var dummyTrackWidth = [200_000, 200_000]
    private var dummyTrackEnds = [(IPoint.zero, IPoint.zero), (IPoint.zero, IPoint.zero)]
    private var dummyArcEnds = [(IPoint.zero, IPoint.zero), (IPoint.zero, IPoint.zero)]

    /// m_clearanceCache and m_tempClearanceCache: by the two items (their serials) and whether the epsilon was taken
    struct ClearanceKey: Hashable {
        let a: Int, b: Int
        let epsilon: Bool
    }
    var clearanceCache: [ClearanceKey: Int] = [:]
    var tempClearanceCache: [ClearanceKey: Int] = [:]

    init(engine: DesignRuleEngine, copperLayers: Int, maxError: Int, boardLayer: @escaping (Int) -> Int,
         net: @escaping (NetHandle?) -> (code: Int, name: String, netClass: RuleItem.NetClassRef),
         item: @escaping (WorldItem) -> RuleItem) {
        self.engine = engine
        self.copperLayers = copperLayers
        self.maxError = maxError
        self.boardLayer = boardLayer
        self.net = net
        makeItem = item
        for d in dummyTracks + dummyArcs + dummyVias {
            d.transient = true
            d.connected = true
            d.isOnCopper = true
        }
        for v in dummyVias {
            // (PCB_VIA's constructor: a through via from F.Cu to B.Cu, its drill the default)
            v.viaType = .through
            v.layerSet = KiLayerSet.allCu(copperLayers)
            v.hasHole = true
            v.hasDrilledHole = true
            v.properties["Via Type"] = .enumString("Through")
            v.properties["Diameter"] = .int(0)
            v.properties["Hole"] = .int(-1)
        }
        for (i, t) in dummyTracks.enumerated() { setTrack(i, t, ends: (.zero, .zero)) }
        for (i, a) in dummyArcs.enumerated() { setArc(i, a, ends: (.zero, .zero)) }
    }

    // MARK: - Items

    /// BoardItem: the board item behind a router item (a hole's, its pad's or via's), as the rules see it
    func boardItem(_ item: Item?) -> RuleItem? {
        guard let item else { return nil }
        var ref = item.boardItem as? WorldItemRef
        if ref == nil, item.kind == .hole { ref = item.parentPadVia?.boardItem as? WorldItemRef }
        guard let ref else { return nil }
        let key = ObjectIdentifier(ref)
        if let r = items[key] { return r }
        let r = makeItem(ref.item)
        items[key] = r
        return r
    }

    private func setNet(_ r: RuleItem, _ handle: NetHandle?) {
        let n = net(handle)
        (r.netCode, r.netName, r.netClass) = (n.code, n.name, n.netClass)
    }

    private func setTrack(_ i: Int, _ r: RuleItem, ends: (IPoint, IPoint)) {
        dummyTrackEnds[i] = ends
        let width = dummyTrackWidth[i]
        let (a, b) = ends
        r.properties["Width"] = .int(width)
        r.bbox = RuleItem.trackBox(a, b, width: width)
        let shape = Shape.segment(Seg(a, b), width: width)
        r.effectiveShape = { _ in [shape] }
        let maxError = maxError
        r.polygon = { _ in PadPolygon.oval(start: a, end: b, width: width, maxError: maxError, errorLocation: .outside) }
    }

    private func setArc(_ i: Int, _ r: RuleItem, ends: (IPoint, IPoint)) {
        dummyArcEnds[i] = ends
        // (a new arc's width, its mid point the origin: KiCad's dummy arcs are given their ends only)
        let width = 200_000
        let (a, b) = ends
        r.properties["Width"] = .int(width)
        let arc = ShapeArc(start: a, mid: .zero, end: b, width: width)
        r.bbox = RuleItem.arcBox(Shape.arc(arc).bbox, width: width)
        r.effectiveShape = { _ in [.arc(arc)] }
        let maxError = maxError
        r.polygon = { _ in PadPolygon.arc(start: a, mid: .zero, end: b, width: width, maxError: maxError, errorLocation: .outside) }
    }

    /// getBoardItem: a dummy of the router item's kind, on the board layer, of its net, at its anchors
    func dummy(_ item: Item, _ boardLayer: Int, _ idx: Int) -> RuleItem? {
        switch item.kind {
        case .arc:
            let r = dummyArcs[idx]
            r.layer = boardLayer
            r.layerSet = KiLayerSet([boardLayer])
            setNet(r, item.net)
            setArc(idx, r, ends: (item.anchor(0), item.anchor(1)))
            return r
        case .via, .hole:
            let r = dummyVias[idx]
            r.layer = boardLayer
            setNet(r, item.net)
            let p = item.anchor(0)
            r.bbox = RuleItem.viaBox(p, diameter: 0)
            r.effectiveShape = { _ in [.circle(center: p, radius: 0)] }
            r.holeShape = .circle(center: p, radius: 0)
            r.polygon = nil
            return r
        case .segment, .line:
            let r = dummyTracks[idx]
            r.layer = boardLayer
            r.layerSet = KiLayerSet([boardLayer])
            setNet(r, item.net)
            setTrack(idx, r, ends: (item.anchor(0), item.anchor(1)))
            return r
        default:
            return nil
        }
    }

    /// A dummy track for a line's segment (evaluateLineSegments): the line's width, net and layer, the segment's ends
    func dummySegment(_ idx: Int, _ boardLayer: Int, _ net: NetHandle?, width: Int, _ a: IPoint, _ b: IPoint) -> RuleItem {
        let r = dummyTracks[idx]
        r.layer = boardLayer
        r.layerSet = KiLayerSet([boardLayer])
        setNet(r, net)
        dummyTrackWidth[idx] = width
        setTrack(idx, r, ends: (a, b))
        return r
    }

    /// The same track's next segment
    func moveDummySegment(_ idx: Int, _ a: IPoint, _ b: IPoint) -> RuleItem {
        setTrack(idx, dummyTracks[idx], ends: (a, b))
        return dummyTracks[idx]
    }

    // MARK: - QueryConstraint

    static func hostType(_ type: ConstraintType) -> DRCConstraintType {
        switch type {
        case .clearance: return .clearance
        case .width: return .trackWidth
        case .diffPairGap: return .diffPairGap
        case .length: return .length
        case .diffPairSkew: return .skew
        case .maxUncoupled: return .maxUncoupled
        case .viaDiameter: return .viaDiameter
        case .viaHole: return .holeSize
        case .holeClearance: return .holeClearance
        case .edgeClearance: return .edgeClearance
        case .holeToHole: return .holeToHole
        case .physicalClearance: return .physicalClearance
        case .physicalHoleClearance: return .physicalHoleClearance
        }
    }

    /// PNS_PCBNEW_RULE_RESOLVER::QueryConstraint: the constraint of a type between two router items on a router layer
    /// (nil where no rule sets one); a rule's ignored severity a minimum of -1
    func queryConstraint(_ type: ConstraintType, _ itemA: Item?, _ itemB: Item?, layer: Int) -> Constraint? {
        let host = Self.hostType(type)
        var parentA = boardItem(itemA), parentB = boardItem(itemB)
        let board = boardLayer(layer)
        var constraint = DRCConstraint(.null)

        // (for clearances, the smaller: true once it is no more than 0, which nothing is less than)
        func pickSmaller(_ best: inout DRCConstraint, _ candidate: DRCConstraint) -> Bool {
            if candidate.type == .null { return false }
            if best.type == .null {
                best = candidate
            } else if candidate.value.hasMin && best.value.hasMin && candidate.value.min < best.value.min {
                best = candidate
            }
            return best.value.hasMin && best.value.min <= 0
        }
        func isMultiSegmentLine(_ item: Item?, _ parent: RuleItem?) -> Bool {
            guard let line = item as? Line, parent == nil else { return false }
            return line.cLine.segmentCount > 1
        }
        var lineA = false, lineB = false
        if engine.hasGeometryDependentRules {
            lineA = isMultiSegmentLine(itemA, parentA)
            lineB = isMultiSegmentLine(itemB, parentB)
        }
        func evaluateLineSegments(_ line: Line, _ opposing: RuleItem?, lineFirst: Bool, _ idx: Int) -> DRCConstraint {
            var best = DRCConstraint(.null)
            let chain = line.cLine
            var dummy = dummySegment(idx, board, line.net, width: line.width, chain.point(0), chain.point(0))
            for i in 0..<chain.segmentCount {
                dummy = moveDummySegment(idx, chain.point(i), chain.point(i + 1))
                let seg = lineFirst ? engine.evalRules(host, dummy, opposing, layer: board) : engine.evalRules(host, opposing, dummy, layer: board)
                if pickSmaller(&best, seg) { break }
            }
            return best
        }
        func linesBoxesOverlap() -> Bool {
            guard lineA && lineB, let a = itemA as? Line, let b = itemB as? Line else { return true }
            let threshold = max(a.width, b.width) * 2
            return a.cLine.bbox.inflated(threshold).intersects(b.cLine.bbox)
        }
        if (lineA || lineB) && linesBoxesOverlap() {
            if let itemA, parentA == nil && !lineA { parentA = dummy(itemA, board, 0) }
            if let itemB, parentB == nil && !lineB { parentB = dummy(itemB, board, 1) }
            if lineA && lineB, let a = itemA as? Line, let b = itemB as? Line {
                // (each pair of segments near enough to each other)
                let chainA = a.cLine, chainB = b.cLine
                let threshold = max(a.width, b.width) * 2
                _ = dummySegment(0, board, a.net, width: a.width, chainA.point(0), chainA.point(0))
                _ = dummySegment(1, board, b.net, width: b.width, chainB.point(0), chainB.point(0))
                var done = false
                for i in 0..<chainA.segmentCount where !done {
                    let p1 = chainA.point(i), p2 = chainA.point(i + 1)
                    let boxA = IBox(p1, p2).inflated(threshold)
                    let dummyA = moveDummySegment(0, p1, p2)
                    for j in 0..<chainB.segmentCount {
                        let q1 = chainB.point(j), q2 = chainB.point(j + 1)
                        guard boxA.intersects(IBox(q1, q2)) else { continue }
                        let dummyB = moveDummySegment(1, q1, q2)
                        if pickSmaller(&constraint, engine.evalRules(host, dummyA, dummyB, layer: board)) {
                            done = true
                            break
                        }
                    }
                }
            } else if lineA, let a = itemA as? Line {
                constraint = evaluateLineSegments(a, parentB, lineFirst: true, 0)
            } else if let b = itemB as? Line {
                constraint = evaluateLineSegments(b, parentA, lineFirst: false, 1)
            }
        } else {
            if let itemA, parentA == nil { parentA = dummy(itemA, board, 0) }
            if let itemB, parentB == nil { parentB = dummy(itemB, board, 1) }
            if let parentA { constraint = engine.evalRules(host, parentA, parentB, layer: board) }
        }
        guard constraint.type != .null else { return nil }
        if constraint.severity == .ignore,
           let rule = constraint.parentRule, !rule.isImplicit || rule.implicitSource != .tuningProfile {
            var c = Constraint(type: type, min: -1)
            c.ruleName = constraint.ruleName
            return c
        }
        let v = constraint.value
        var c = Constraint(type: type, min: v.min, opt: v.opt, max: v.hasMax ? v.max : Int.max)
        c.ruleName = constraint.ruleName
        return c
    }
}

// MARK: - A board's rules for its router

extension BoardDRC {
    /// The board's rules for its router's resolver, where it has rules of the user's own (nil: the implicit rules'
    /// fast ways, which the resolver takes itself): its items as the rules see them, by the world items' board items
    func routerRules() -> RouterRules? {
        guard ruleState.hasUserRules else { return nil }
        let copper = makeCopper()
        var byUUID: [String: CopperItem] = [:]
        for item in copper.items + copper.zones where byUUID[item.uuid] == nil { byUUID[item.uuid] = item }
        let world = self.world
        let names = Dictionary(uniqueKeysWithValues: world.layerIndex.map { ($0.value, $0.key) })
        func kiLayer(_ l: Int) -> Int { l < 0 ? KiLayer.undefined : KiLayer.fromRouter(l, copperLayers: world.copperLayers) }
        let netName = { (net: NetHandle?) -> String in net.flatMap { world.netNames[$0] } ?? "" }
        return RouterRules(engine: ruleState.engine, copperLayers: world.copperLayers, maxError: settings.maxError,
                           boardLayer: kiLayer,
                           net: { net in
                               let name = netName(net)
                               return (net ?? 0, name, self.ruleNetClass(name))
                           },
                           item: { w in
                               if w.kind == .keepout, let z = self.ruleState.zones.first(where: { $0.uuid == w.source }) { return z }
                               if let uuid = w.source, let c = byUUID[uuid] { return self.ruleItem(c, copper) }
                               // (a drawing on the board's edge, or a text: its layer and shape)
                               let r = RuleItem(w.kind == .text ? .text : .shape, uuid: w.source ?? "")
                               r.layer = w.kind == .edge ? KiLayer.edgeCuts : names[w.layers.start].flatMap(KiLayer.id) ?? KiLayer.undefined
                               r.layerSet = KiLayerSet([r.layer])
                               r.isOnCopper = w.copper
                               if let s = w.shape {
                                   r.effectiveShape = { _ in [s] }
                                   r.bbox = s.bbox
                               }
                               r.netClass = self.ruleNetClass("")
                               return r
                           })
    }
}

extension BoardRouter {
    /// ImportSizes by the board's rules: the clearance, track width, via and differential pair sizes the rules give
    /// a dummy track and via of the start item's net at its anchor on the start layer, no less than the board's
    /// minimums; nil without rules of the user's own (sizes(for:) takes the net class's then)
    func rulesSizes(_ item: Item, layer: Int, start: IPoint?, _ r: RouterRules, _ resolver: WorldResolver) -> SizesSettings {
        var s = implicitSizes(for: item)
        let minClearance = world.rules.clearance
        s.clearance = minClearance
        s.minClearance = minClearance
        // (the anchor nearest the start, a track's)
        var startAnchor = 0
        if item.kind == .segment, let p = start, (p - item.anchor(1)).norm < (p - item.anchor(0)).norm { startAnchor = 1 }
        let dummyTrack = Segment(Seg(item.anchor(startAnchor), item.anchor(startAnchor)), net: item.net)
        dummyTrack.setLayer(layer)
        if let c = r.queryConstraint(.clearance, dummyTrack, nil, layer: layer), c.min >= minClearance { s.clearance = c.min }
        var trackWidth = world.minTrackWidth
        var found = false
        if let track = item as? LinkedItem, item.kind == .segment || item.kind == .arc {
            trackWidth = track.width
            found = true
        }
        if !found, let c = r.queryConstraint(.width, dummyTrack, nil, layer: layer) {
            trackWidth = max(trackWidth, c.opt)
            found = true
        }
        if !found { trackWidth = max(trackWidth, s.trackWidth) }
        s.trackWidth = trackWidth
        s.boardMinTrackWidth = world.minTrackWidth
        var viaDiameter = world.minViaDiameter, viaDrill = world.minViaDrill
        let dummyVia = Via(pos: .zero, layers: LayerRange(0, max(0, world.copperLayers - 1)), diameter: 0, drill: 0, net: item.net,
                           type: .through)
        let coupledVia = Via(pos: .zero, layers: LayerRange(0, max(0, world.copperLayers - 1)), diameter: 0, drill: 0,
                             net: resolver.dpCoupledNet(item.net), type: .through)
        if let c = r.queryConstraint(.viaDiameter, dummyVia, nil, layer: layer) { viaDiameter = max(viaDiameter, c.opt) }
        if let c = r.queryConstraint(.viaHole, dummyVia, nil, layer: layer) { viaDrill = max(viaDrill, c.opt) }
        s.viaDiameter = viaDiameter
        s.viaDrill = viaDrill
        var dpWidth = world.minTrackWidth, dpGap = minClearance, dpViaGap = minClearance
        found = false
        if let track = item as? LinkedItem, item.kind == .segment || item.kind == .arc {
            dpWidth = track.width
            found = true
        }
        let coupledNet = resolver.dpCoupledNet(item.net)
        let pairTrack = Segment(Seg(item.anchor(0), item.anchor(0)), net: item.net)
        pairTrack.setLayer(layer)
        let coupledTrack = Segment(Seg(item.anchor(0), item.anchor(0)), net: coupledNet)
        coupledTrack.setLayer(layer)
        if !found, let c = r.queryConstraint(.width, pairTrack, coupledTrack, layer: layer) { dpWidth = max(dpWidth, c.opt) }
        if let c = r.queryConstraint(.diffPairGap, pairTrack, coupledTrack, layer: layer) {
            dpGap = max(dpGap, c.opt)
            dpViaGap = max(dpViaGap, c.opt)
        }
        s.diffPairWidth = dpWidth
        s.diffPairGap = dpGap
        s.diffPairViaGap = dpViaGap
        s.diffPairViaGapSameAsTraceGap = false
        var holeToHole = world.rules.holeToHole
        if let c = r.queryConstraint(.holeToHole, dummyVia, dummyVia, layer: -1) { holeToHole = c.min }
        s.holeToHole = holeToHole
        if let c = r.queryConstraint(.holeToHole, dummyVia, coupledVia, layer: -1) { holeToHole = c.min }
        s.diffPairHoleToHole = max(holeToHole, s.holeToHole)
        var copperToHole = world.rules.holeClearance
        for type in [ConstraintType.holeClearance, .physicalHoleClearance] {
            if let c = r.queryConstraint(type, dummyVia, coupledVia, layer: -1) { copperToHole = max(copperToHole, c.min) }
            if let c = r.queryConstraint(type, coupledVia, dummyVia, layer: -1) { copperToHole = max(copperToHole, c.min) }
        }
        s.diffPairCopperToHole = copperToHole
        return s
    }
}
