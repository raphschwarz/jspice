// Tuning patterns made, edited and taken away on a board's router as KiCad's generator tool drives them
// (PCB_TUNING_PATTERN's EditStart, Update, EditFinish, EditCancel and Remove, with snapToNearestTrack, pickSegment,
// getPNSLine, initBaseLine(s), removeToBaseline, recoverBaseline and resetToBaseline; GENERATOR_TOOL_PNS_PROXY and
// its interface, PNS_KICAD_IFACE_GENERATOR: the changes it keeps, an item it made and took off again none;
// pcbnew/generators/pcb_tuning_pattern.cpp, pcbnew/tools/generator_tool_pns_proxy.cpp, pcbnew/board.cpp's
// DpCoupledNet, KiCad 10.0.7).
// Copyright (C) 2023 Alex Shvartzkop; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardRouter {
    /// A board track, arc track or via, as BOARD::Tracks() has it
    struct BoardTrack {
        let node: SExpr
        var uuid: String { node.value("uuid") ?? "" }
        var net: String { node["net"].flatMap { $0.items.count >= 3 ? $0.text(at: 1) : $0.text(at: 0) } ?? "" }

        /// The point of the track nearest `p` (an arc's by its own NearestPoint, a via's its centre, its start and
        /// end both)
        func nearestPoint(_ p: IPoint) -> IPoint {
            switch node.head {
            case "arc":
                let w = node["width"].map { BoardWorld.iu($0, 0) } ?? 0
                return ShapeArc(start: BoardWorld.point(node["start"]), mid: BoardWorld.point(node["mid"]),
                                end: BoardWorld.point(node["end"]), width: w).nearestPoint(p)
            case "via":
                return BoardWorld.point(node["at"])
            default:
                return Seg(BoardWorld.point(node["start"]), BoardWorld.point(node["end"])).nearestPoint(p)
            }
        }
    }

    /// The point nearest `p` of the board's tracks (of net `net`, if given), and the track (snapToNearestTrack: the
    /// first of those as near, in the board's order)
    func snapToNearestTrack(_ p: IPoint, net: String?) -> (point: IPoint, track: BoardTrack?) {
        var minDist = Int.max
        var closest = p
        var found: BoardTrack?
        for node in board.copperItems {
            let track = BoardTrack(node: node)
            if let net, track.net != net { continue }
            let nearest = track.nearestPoint(p)
            let d = (nearest - p).squaredNorm
            if d < minDist {
                minDist = d
                closest = nearest
                found = track
            }
        }
        return (closest, found)
    }

    /// The net a differential pair's net is coupled with, if the board has it (BOARD::DpCoupledNet)
    func dpCoupledNet(_ net: String) -> String? {
        let (polarity, coupled) = WorldResolver.matchDpSuffix(net)
        guard polarity != 0, world.netCodes[coupled] != nil else { return nil }
        return coupled
    }

    /// The segment or arc of the router's world at `p` on `layer` to tune from, and the point of it nearest `p`
    /// (pickSegment): of those under the pointer, then within the router's clearance and half its track width of
    /// it, the nearest (the last of those as near), of those as near the one nearer `baseline` if one is given
    func pickSegment(_ p: IPoint, layer: Int, baseline: LineChain? = nil) -> (item: LinkedItem?, point: IPoint) {
        let maxSlopRadius = router.sizes.clearance + router.sizes.trackWidth / 2
        var prioritized: LinkedItem?
        var dist = Int.max, distBaseline = Int.max
        var point = IPoint.zero
        for slopRadius in [0, maxSlopRadius] {
            for item in router.queryHoverItems(p, slopRadius: slopRadius) {
                guard item.kind == .segment || item.kind == .arc, item.isRoutable, item.layers.overlaps(layer),
                      let linked = item as? LinkedItem else { continue }
                let nearest: IPoint
                let target: IPoint
                if let arc = item as? Arc {
                    nearest = arc.arc.nearestPoint(p)
                    target = arc.arc.mid
                } else if let seg = item as? Segment {
                    nearest = seg.cLine.nearestPoint(p, allowInternalShapePoints: false)
                    target = seg.seg.center
                } else {
                    continue
                }
                let d = (nearest - p).squaredNorm
                if d > dist { continue }
                if let baseline, baseline.pointCount > 0 {
                    let dc = baseline.segmentCount > 0 ? baseline.squaredDistance(target) : (baseline.point(0) - target).squaredNorm
                    if dc > distBaseline { continue }
                    distBaseline = dc
                }
                prioritized = linked
                dist = d
                point = nearest
            }
        }
        if let prioritized, layer < 0 || prioritized.layers.overlaps(layer) { return (prioritized, point) }
        return (nil, .zero)
    }

    /// The line of the router's world that runs through both `start` and `end` (each picked as pickSegment picks
    /// them), and the points picked (getPNSLine)
    func pnsLine(_ start: IPoint, _ end: IPoint, layer: Int) -> (line: Line, start: IPoint, end: IPoint)? {
        guard let world = router.world else { return nil }
        let (startItem, startOut) = pickSegment(start, layer: layer)
        let (endItem, endOut) = pickSegment(end, layer: layer)
        for testItem in [startItem, endItem] {
            guard let testItem else { continue }
            let line = world.assembleLine(testItem, stopAtLockedJoints: false, followLockedSegments: false)
            let chain = line.cLine
            if chain.pointOnEdge(startOut, accuracy: 1) && chain.pointOnEdge(endOut, accuracy: 1) {
                return (line, startOut, endOut)
            }
        }
        return nil
    }

    /// A base line: `start` and `end` taken to the nearest points of the board's tracks of `net`, the part of the
    /// line through them between them (initBaseLine)
    func initBaseLine(layer: Int, start: inout IPoint, end: inout IPoint, net: String) -> LineChain? {
        guard let world = router.world else { return nil }
        start = snapToNearestTrack(start, net: net).point
        end = snapToNearestTrack(end, net: net).point
        let (startItem, startSnap) = pickSegment(start, layer: layer)
        let (endItem, endSnap) = pickSegment(end, layer: layer)
        guard let startItem, endItem != nil else { return nil }
        let line = world.assembleLine(startItem)
        return line.cLine.split(startSnap, endSnap).mid
    }

    /// The pattern's base lines made from its origin and end (initBaseLines): its line's, and a pair's other line's
    /// (of the net coupled with it, from the points of that net nearest its own), for a skew tuning too
    @discardableResult
    func initBaseLines(_ p: inout TuningPattern, layer: Int) -> Bool {
        p.baseLineCoupled = nil
        let (origin, track) = snapToNearestTrack(p.origin, net: nil)
        p.origin = origin
        guard let track else { return false }
        let net = track.net
        guard let base = initBaseLine(layer: layer, start: &p.origin, end: &p.end, net: net) else { return false }
        p.baseLine = base
        if p.mode == .diffPair || p.mode == .skew {
            guard let coupled = dpCoupledNet(net) else { return false }
            var coupledStart = snapToNearestTrack(p.origin, net: coupled).point
            var coupledEnd = snapToNearestTrack(p.end, net: coupled).point
            guard let c = initBaseLine(layer: layer, start: &coupledStart, end: &coupledEnd, net: coupled) else { return false }
            p.baseLineCoupled = c
        }
        return true
    }

    /// The line the base line is part of made straight along it again, in the router's world and on the board's
    /// side (removeToBaseline)
    func removeToBaseline(layer: Int, _ baseLine: LineChain) -> Bool {
        guard let world = router.world, let (line, startSnap, endSnap) = pnsLine(baseLine.point(0), baseLine.lastPoint, layer: layer) else {
            return false
        }
        let (pre, _, post) = line.cLine.split(startSnap, endSnap)
        for li in line.links { iface.removeItem(li) }
        world.remove(line)
        var straightChain = LineChain()
        straightChain.append(pre)
        straightChain.append(baseLine)
        straightChain.append(post)
        straightChain.simplify()
        let straightLine = Line(line, straightChain)
        world.add(straightLine, allowRedundant: false)
        for li in straightLine.links { iface.addItem(li) }
        return true
    }

    /// The pattern's tracks taken out of the world (those within its outline), and its base lines put in, as a last
    /// resort where its line could not be found (recoverBaseline)
    @discardableResult
    func recoverBaseline(_ p: TuningPattern, layer: Int) -> Bool {
        guard let world = router.world else { return false }
        let chain = p.outline
        let queryItem = Solid()
        queryItem.solidShape = .chain(chain)
        queryItem.setLayer(layer)
        var lineWidth = 0
        var opts = CollisionSearchOptions()
        opts.useClearanceEpsilon = false
        let branch = world.branch()
        for obs in branch.queryColliding(queryItem, options: opts) {
            let item = obs.item
            guard item.kind == .segment || item.kind == .arc else { continue }
            if let li = item as? LinkedItem, lineWidth == 0 || li.width < lineWidth { lineWidth = li.width }
            if chain.pointInside(item.anchor(0), accuracy: 10) && chain.pointInside(item.anchor(1), accuracy: 10) {
                branch.remove(item)
            }
        }
        if lineWidth == 0 { lineWidth = 100_000 }
        if p.baselineValid, let base = p.baseLine {
            let recoverLine = Line()
            recoverLine.setLayer(layer)
            recoverLine.setWidth(lineWidth)
            recoverLine.setLine(base)
            recoverLine.net = self.world.netCodes[p.lastNetName]
            branch.add(recoverLine, allowRedundant: false)
            if p.mode == .diffPair || p.mode == .skew, let coupled = p.baseLineCoupled {
                let recoverLineCoupled = Line()
                recoverLineCoupled.setLayer(layer)
                recoverLineCoupled.setWidth(lineWidth)
                recoverLineCoupled.setLine(coupled)
                recoverLineCoupled.net = dpCoupledNet(p.lastNetName).flatMap { self.world.netCodes[$0] }
                branch.add(recoverLineCoupled, allowRedundant: false)
            }
        }
        router.commitRouting(branch)
        return true
    }

    /// The line the pattern's base line (or a pair's other one, not `primary`) is part of made straight along it
    /// again, cut at the pattern's origin and end (taken to the straight line's nearest points, kept a tenth of a
    /// millimetre apart at least), its part between them its base line now, of the pattern's width, the rest of the
    /// line of the line's own; committed (resetToBaseline). True where the line was not found too, as KiCad has it.
    func resetToBaseline(_ p: inout TuningPattern, layer: Int, primary: Bool) -> Bool {
        guard let world = router.world, let base = primary ? p.baseLine : p.baseLineCoupled else { return true }
        guard let (pnsLine, startSnap, endSnap) = pnsLine(base.point(0), base.lastPoint, layer: layer) else { return true }
        let branch = world.branch()
        var straightChain = LineChain()
        do {
            let (pre, _, post) = pnsLine.cLine.split(startSnap, endSnap)
            straightChain.append(pre)
            straightChain.append(base)
            straightChain.append(post)
            straightChain.simplify()
        }
        branch.remove(pnsLine)
        var newLineChain = LineChain()
        if primary {
            p.origin = straightChain.nearestPoint(p.origin)
            p.end = straightChain.nearestPoint(p.end)
            // (not too close together)
            if (p.end - p.origin).norm < 100_000 {
                p.origin = startSnap
                p.end = endSnap
            }
            let (pre, mid, post) = straightChain.split(p.origin, p.end)
            newLineChain.append(pre)
            newLineChain.append(mid)
            newLineChain.append(post)
            p.baseLine = mid
        } else {
            let start = straightChain.nearestPoint(p.origin)
            let end = straightChain.nearestPoint(p.end)
            let (pre, mid, post) = straightChain.split(start, end)
            newLineChain.append(pre)
            newLineChain.append(mid)
            newLineChain.append(post)
            p.baseLineCoupled = mid
        }
        // (the pattern's part of the line of its own width, the rest of the line's)
        let (pre, mid, post) = newLineChain.split(p.origin, p.end)
        func addPart(_ part: LineChain, _ partWidth: Int) {
            if part.segmentCount == 0 { return }
            let line = Line(pnsLine, part)
            if partWidth > 0 { line.setWidth(partWidth) }
            branch.add(line, allowRedundant: false)
        }
        p.assembledLineWidth = pnsLine.width
        addPart(pre, p.assembledLineWidth)
        addPart(mid, p.trackWidth > 0 ? p.trackWidth : p.assembledLineWidth)
        addPart(post, p.assembledLineWidth)
        router.commitRouting(branch)
        return true
    }

    /// What a length constraint of the board's rules, or a skew constraint, says for the pattern's track (and its
    /// pair's other net's track): the router's rule resolver asked as KiCad's pattern asks it
    /// (PNS_PCBNEW_RULE_RESOLVER::QueryConstraint of CT_LENGTH or CT_DIFF_PAIR_SKEW, the track's board item behind
    /// the item asked about: here the router's own item of that track). The hook for the board's own rules: the
    /// resolver of a board without a design rules file has no length or skew rules, and finds none.
    func tuningConstraint(_ type: ConstraintType, track: BoardTrack, coupled: BoardTrack?, layer: Int) -> Constraint? {
        func routerItem(_ t: BoardTrack?) -> Item? {
            guard let t, let node = router.world else { return nil }
            return node.allItems(inNet: world.netCodes[t.net]).first { iface.resolver.info[ObjectIdentifier($0)]?.source == t.uuid }
        }
        guard let item = routerItem(track) else { return nil }
        return router.ruleResolver?.queryConstraint(type, item, routerItem(coupled), layer: layer)
    }

    /// A length or skew constraint's values as the pattern's target (MEANDER_SETTINGS::SetTargetLength and
    /// SetTargetSkew of a MINOPTMAX: its opt, KiCad's tolerance either side, its min and max where it has them:
    /// here a min other than 0, a max other than none)
    static func applyConstraint(_ c: Constraint, to settings: inout MeanderSettings, skew: Bool) {
        if skew {
            settings.setTargetSkew(c.opt)
            if c.min != 0 { settings.targetSkew.min = c.min }
            if c.max != Int.max { settings.targetSkew.max = c.max }
        } else {
            settings.setTargetLength(c.opt)
            if c.min != 0 { settings.targetLength.min = c.min }
            if c.max != Int.max { settings.targetLength.max = c.max }
        }
    }

    /// The layer the pattern is on (GetLayer): its first member's that is a track, else its own
    func patternLayer(_ p: TuningPattern) -> String {
        let tracks = Dictionary(board.copperItems.map { ($0.value("uuid") ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        for m in p.members {
            if let node = tracks[m], let l = node.head == "via" ? node["layers"]?.text(at: 0) : node.value("layer") { return l }
        }
        return p.layer
    }

    /// The pattern's edit started (EditStart): the router's changes let go of and its world synced from the board,
    /// the pattern's own tracks not locked; its base lines made if it has none; its side set from where its end is
    /// if asked; its origin taken to the nearest track; its target taken from the board's rules unless it overrides
    /// them
    func patternEditStart(_ p: inout TuningPattern) {
        p.inEdit = true
        p.layer = patternLayer(p)
        let pnsLayer = layer(p.layer) ?? -1
        router.stopRouting()
        iface.added.removeAll()
        iface.removedItems.removeAll()
        // (the generator's router has sizes of its own, KiCad's defaults: the router tool's are not its)
        router.updateSizes(SizesSettings())
        reload(editing: p.uuid)
        if !p.baselineValid { initBaseLines(&p, layer: pnsLayer) }
        if p.updateSideFromEnd {
            var centerlineOffsetEnd = IPoint.zero
            if p.mode == .diffPair, let coupled = p.baseLineCoupled, coupled.segmentCount > 0, let base = p.baseLine {
                let d = coupled.lastPoint - base.lastPoint
                centerlineOffsetEnd = IPoint(d.x / 2, d.y / 2)
            }
            let baseEnd0 = p.baseLine.flatMap { $0.segmentCount > 0 ? $0.segment(-1) : nil } ?? Seg(p.origin, p.end)
            let baseEnd = Seg(baseEnd0.a + centerlineOffsetEnd, baseEnd0.b + centerlineOffsetEnd)
            if baseEnd.a != baseEnd.b {
                p.settings.initialSide = baseEnd.side(p.end) < 0 ? .left : .right
            }
            p.updateSideFromEnd = false
        }
        let (origin, track) = snapToNearestTrack(p.origin, net: nil)
        p.origin = origin
        guard let track else { return }
        if !p.settings.overrideCustomRules {
            if p.mode == .single {
                if let c = tuningConstraint(.length, track: track, coupled: nil, layer: pnsLayer) {
                    Self.applyConstraint(c, to: &p.settings, skew: false)
                    p.isTimeDomain = false
                }
            } else {
                let coupledTrack = dpCoupledNet(track.net).flatMap { snapToNearestTrack(p.origin, net: $0).track }
                if let c = tuningConstraint(p.mode == .diffPair ? .length : .diffPairSkew, track: track, coupled: coupledTrack,
                                            layer: pnsLayer) {
                    Self.applyConstraint(c, to: &p.settings, skew: p.mode == .skew)
                    p.isTimeDomain = false
                }
            }
        }
    }

    /// The pattern tuned again (Update): the line made straight along its base line and cut at its origin and end
    /// (its base lines made, if it had none), the meander placer started where its origin is on the line, given its
    /// settings and taken to its end; the width, net, status and length the tuning came to kept. False where it
    /// could not be (and in the time domain, which the port does not tune in: as KiCad without a model of delays).
    @discardableResult
    func patternUpdate(_ p: inout TuningPattern) -> Bool {
        guard p.inEdit else { return false }
        if p.isTimeDomain && !p.isNew { return false }
        if router.routingInProgress { router.stopRouting() }
        p.layer = patternLayer(p)
        let pnsLayer = layer(p.layer) ?? -1
        if !p.baselineValid {
            initBaseLines(&p, layer: pnsLayer)
        } else {
            guard resetToBaseline(&p, layer: pnsLayer, primary: true) else { return false }
            if let base = p.baseLine {
                p.origin = base.point(0)
                p.end = base.lastPoint
            }
            if p.mode == .diffPair && !resetToBaseline(&p, layer: pnsLayer, primary: false) {
                initBaseLines(&p, layer: pnsLayer)
                return false
            }
        }
        guard let base = p.baseLine else { return false }
        let (startItem, startSnapPoint) = pickSegment(p.origin, layer: pnsLayer, baseline: base)
        let (endItem, _) = pickSegment(p.end, layer: pnsLayer, baseline: base)
        guard let startItem, endItem != nil else { return false }
        router.mode = p.mode.routerMode
        router.failureReason = ""
        guard router.startRouting(startSnapPoint, startItem, layer: pnsLayer), let placer = router.meanderPlacer else {
            return false
        }
        p.settings.keepEndpoints = true
        placer.updateSettings(Self.placerSettings(p.settings))
        router.move(p.end, nil)
        if p.trackWidth == 0 {
            if let dp = placer as? DPMeanderPlacer {
                p.trackWidth = dp.originPair.width
                p.diffPairGap = dp.originPair.gap
            } else {
                p.trackWidth = startItem.width
                p.diffPairGap = router.sizes.diffPairGap
            }
        }
        p.settings = placer.meanderSettings
        p.lastNetName = iface.netName(startItem.net)
        p.status = placer.tuningStatus
        p.tuningLength = placer.tuningLengthResult
        return true
    }

    /// The pattern's edit finished (EditFinish): the tuning fixed, forced to finish; what the router took off the
    /// board taken off it, and what it put on put on, a track of it outside the pattern's outline given the line's
    /// own width back, those within it the pattern's members; the pattern written into the board (or taken out of
    /// it if it has no members, as KiCad does not write one so)
    func patternEditFinish(_ p: inout TuningPattern) {
        guard p.inEdit else { return }
        p.inEdit = false
        let bounds = p.outline
        let epsilon = world.rules.epsilon
        if router.routingInProgress {
            _ = router.fixRoute(p.end, nil, forceFinish: true)
            router.stopRouting()
        }
        func withinBounds(_ a: IPoint, _ b: IPoint) -> Bool { bounds.pointInside(a, accuracy: epsilon) && bounds.pointInside(b, accuracy: epsilon) }
        lastAdded = []
        lastRemoved = []
        for item in iface.removedItems {
            guard let uuid = iface.resolver.info[ObjectIdentifier(item)]?.source else { continue }
            if let node = board.copperItems.first(where: { $0.value("uuid") == uuid }) {
                board.root.remove(node)
                lastRemoved.append(uuid)
            }
        }
        var newMembers: [String] = []
        for item in iface.added {
            var uuid: String?
            var within = false
            if let s = item as? Segment {
                within = withinBounds(s.seg.a, s.seg.b)
                uuid = insert(segment: s, width: within || p.assembledLineWidth == s.width ? nil : p.assembledLineWidth)
            } else if let a = item as? Arc {
                within = withinBounds(a.arc.start, a.arc.end)
                uuid = insert(arc: a, width: within || p.assembledLineWidth == a.width ? nil : p.assembledLineWidth)
            } else if let v = item as? Via {
                within = withinBounds(v.pos, v.pos)
                uuid = insert(via: v)
            }
            guard let uuid else { continue }
            lastAdded.append(uuid)
            if within { newMembers.append(uuid) }
        }
        iface.added.removeAll()
        iface.removedItems.removeAll()
        TuningPattern.leaveGroups(board, Set(lastRemoved), memory: patternMemory)
        let onBoard = Set(board.copperItems.compactMap { $0.value("uuid") })
        p.members = p.members.filter { onBoard.contains($0) } + newMembers
        p.isNew = false
        if p.members.isEmpty {
            TuningPattern.remove(p.uuid, from: board)
        } else {
            let (written, node) = p.write(into: board)
            patternMemory.remember(written, as: node)
        }
        reload()
    }

    /// The pattern's edit dropped (EditCancel): the router stopped, the board as it was
    func patternEditCancel(_ p: inout TuningPattern) {
        guard p.inEdit else { return }
        p.inEdit = false
        router.stopRouting()
        iface.added.removeAll()
        iface.removedItems.removeAll()
        reload()
    }

    /// The pattern taken away, its line made straight along its base lines again (Remove: removeToBaseline, a
    /// pair's both lines; recoverBaseline where that could not be done): the board's tracks the router took away
    /// taken off it, those it made put on, the pattern taken out of the board
    func patternRemove(_ p: TuningPattern) {
        router.stopRouting()
        router.updateSizes(SizesSettings())
        reload(editing: p.uuid)
        iface.added.removeAll()
        iface.removedItems.removeAll()
        let pnsLayer = layer(patternLayer(p)) ?? -1
        if p.baselineValid, let base = p.baseLine {
            var success = removeToBaseline(layer: pnsLayer, base)
            if p.mode == .diffPair, let coupled = p.baseLineCoupled {
                success = removeToBaseline(layer: pnsLayer, coupled) && success
            }
            if !success { recoverBaseline(p, layer: pnsLayer) }
        }
        TuningPattern.remove(p.uuid, from: board)
        apply()
    }
}
