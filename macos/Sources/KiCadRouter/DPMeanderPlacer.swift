// Ported from KiCad 10.0.7: pcbnew/router/pns_dp_meander_placer.h, pns_dp_meander_placer.cpp,
// pns_meander_skew_placer.h, pns_meander_skew_placer.cpp, and TOPOLOGY::AssembleDiffPair (pns_topology.cpp) (the
// length domain: not the time domain's delays).
// Copyright (C) 2013-2015 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// A differential pair's length tuned (KiCad's DP_MEANDER_PLACER): the parts of its two lines between where it
/// starts and the pointer meandered together, on bases half way between their coupled segments, in a branch of the
/// world, to the length the settings ask, the longer of the two paths of its nets from pad to pad
public final class DPMeanderPlacer: MeanderPlacerBase {
    /// Where the tuned part starts
    private var currentStartPoint = IPoint.zero
    private var currentNodeBranch: Node?
    /// The pair, as it was
    public private(set) var originPair = DiffPair()
    private var currentTraceP = Line()
    private var currentTraceN = Line()
    private var tunedPathP: [Item] = []
    private var tunedPathN: [Item] = []
    private var finalShapeP = LineChain()
    private var finalShapeN = LineChain()
    private var result: MeanderedLine!
    private var initialSegment: LinkedItem?
    private var lastLength = 0
    /// What the pads at the paths' ends add (their pad-to-die lengths)
    private var padToDieLengthP = 0
    private var padToDieLengthN = 0
    private var lastStatus = TuningStatus.tooShort

    public override func currentNode(loopsRemoved: Bool) -> Node? { currentNodeBranch ?? world }

    /// Starts tuning the pair of the track `startItem` (a segment or an arc) at `p` (KiCad's Start): the track and
    /// the coupled net's track alongside it, a line each
    public override func start(_ p: IPoint, _ startItem: Item?) -> Bool {
        guard let startItem, startItem.ofKind([.segment, .arc]), let initial = startItem as? LinkedItem else {
            router.failureReason = "Please select a track whose length you want to tune."
            return false
        }
        initialSegment = initial
        currentNodeBranch = nil
        currentStartPoint = snappedStartPoint(initial, p)
        let world = router.world!.branch()
        self.world = world
        let topo = Topology(world)
        guard let pair = topo.assembleDiffPair(initial) else {
            router.failureReason = "Unable to find complementary differential pair net for length tuning. Make sure "
                + "the names of the nets belonging to a differential pair end with either _N/_P or +/-."
            return false
        }
        originPair = pair
        if originPair.gap < 0 { originPair.setGap(router.sizes.diffPairGap) }
        if originPair.pLine().segmentCount == 0 || originPair.nLine().segmentCount == 0 { return false }
        (tunedPathP, startPadP, endPadP) = topo.assembleTuningPath(router.iface!, originPair.pLine().getLink(0))
        padToDieLengthP = 0
        if let startPadP { padToDieLengthP += startPadP.padToDie }
        if let endPadP { padToDieLengthP += endPadP.padToDie }
        (tunedPathN, startPadN, endPadN) = topo.assembleTuningPath(router.iface!, originPair.nLine().getLink(0))
        padToDieLengthN = 0
        if let startPadN { padToDieLengthN += startPadN.padToDie }
        if let endPadN { padToDieLengthN += endPadN.padToDie }
        world.remove(originPair.pLine())
        world.remove(originPair.nLine())
        currentWidth = originPair.width
        return true
    }

    /// The longer of the two paths as they were (KiCad's origPathLength)
    private func origPathLength() -> Int {
        let totalP = padToDieLengthP + lineLength(tunedPathP, startPadP, endPadP)
        let totalN = padToDieLengthN + lineLength(tunedPathN, startPadN, endPadN)
        return max(totalP, totalN)
    }

    /// The segment half way between two coupled segments (KiCad's baselineSegment)
    private func baselineSegment(_ coupled: DiffPair.CoupledSegments) -> Seg {
        let a = (coupled.coupledP.a + coupled.coupledN.a).divided(by: 2)
        let b = (coupled.coupledP.b + coupled.coupledN.b).divided(by: 2)
        return Seg(a, b)
    }

    /// Which side of the positive line the negative one is (KiCad's pairOrientation)
    private func pairOrientation(_ pair: DiffPair.CoupledSegments) -> Bool {
        let midp = (pair.coupledP.a + pair.coupledN.a).divided(by: 2)
        return pair.coupledP.side(midp) > 0
    }

    /// The pair from where the tuning started to the points of its lines nearest `p` meandered: dual meanders on
    /// each pair of coupled segments, the corners and arcs between them kept, then tuned to the target length
    /// unless the longer path is too long already (KiCad's Move)
    public override func move(_ p: IPoint, _ endItem: Item?) -> Bool {
        if currentStartPoint == p { return false }
        if let currentNodeBranch { world!.release(currentNodeBranch) }
        currentNodeBranch = world!.branch()
        var (preP, tunedP, postP) = originPair.cp.split(currentStartPoint, p)
        var (preN, tunedN, postN) = originPair.cn.split(currentStartPoint, p)
        tunedP.simplify()
        tunedN.simplify()
        // (nothing to tune where the cut points are too close or off the lines, KiCad's issue #22041)
        if tunedP.pointCount == 0 || tunedN.pointCount == 0 {
            finalShapeP = originPair.cp
            finalShapeN = originPair.cn
            lastLength = origPathLength()
            lastStatus = .tooShort
            return false
        }
        func updateStatus() {
            if lastLength > meanderSettings.targetLength.max {
                lastStatus = .tooLong
            } else if lastLength < meanderSettings.targetLength.min {
                lastStatus = .tooShort
            } else {
                lastStatus = .tuned
            }
        }
        let tuned = originPair.copy()
        tuned.setShape(tunedP, tunedN)
        let coupledSegments = tuned.coupledSegmentPairs()
        if coupledSegments.isEmpty {
            // (the tuning started where the pair is not coupled: the pair as it was, until the pointer is far enough
            // along where it is)
            finalShapeP = originPair.cp
            finalShapeN = originPair.cn
            lastLength = origPathLength()
            updateStatus()
            return false
        }
        result = MeanderedLine(placer: self, isDual: true)
        result.width = tuned.width
        var offset = (tuned.gap + tuned.width) / 2
        if pairOrientation(coupledSegments[0]) { offset *= -1 }
        result.baselineOffset = offset
        /// A shape of the chain at `index`: its arc, or its segment's ends
        func getItem(_ chain: LineChain, _ index: Int) -> (arc: ShapeArc?, startPt: IPoint, endPt: IPoint) {
            if chain.isArcSegment(index) {
                let arc = chain.arcs[chain.arcIndex(index)]
                return (arc, arc.start, arc.end)
            }
            let seg = chain.segment(index)
            return (nil, seg.a, seg.b)
        }
        func checkIndex(_ ok: inout Bool, _ curIndex: Int, _ lastIndex: Int) -> Bool {
            ok = curIndex <= lastIndex && curIndex != -1
            return ok
        }
        var curIndexP = 0, curIndexN = 0
        /// The corners and arcs of the lines up to the segments at `lastIndexP` and `lastIndexN` (KiCad's
        /// addCornersUntilIndex)
        func addCornersUntilIndex(_ lastIndexP: Int, _ lastIndexN: Int) {
            while true {
                var pOk = false, nOk = false
                _ = checkIndex(&pOk, curIndexP, lastIndexP)
                _ = checkIndex(&nOk, curIndexN, lastIndexN)
                if !pOk && !nOk { break }
                var pItem = getItem(tunedP, curIndexP)
                var nItem = getItem(tunedN, curIndexN)
                if pItem.arc == nil && nItem.arc == nil {
                    result.addCorner(pItem.startPt, nItem.startPt)
                } else if let pArc = pItem.arc, let nArc = nItem.arc {
                    result.addArc(pArc, nArc)
                } else if let pArc = pItem.arc {
                    result.addCorner(pItem.startPt, nItem.startPt)
                    // (the arc in N)
                    while checkIndex(&nOk, curIndexN, lastIndexN) {
                        curIndexN = tunedN.nextShape(curIndexN)
                        nItem = getItem(tunedN, curIndexN)
                        if let nArc = nItem.arc {
                            result.addArc(pArc, nArc)
                            break
                        } else {
                            result.addCorner(pItem.startPt, nItem.startPt)
                        }
                    }
                } else if let nArc = nItem.arc {
                    result.addCorner(pItem.startPt, nItem.startPt)
                    // (the arc in P)
                    while checkIndex(&pOk, curIndexP, lastIndexP) {
                        curIndexP = tunedP.nextShape(curIndexP)
                        pItem = getItem(tunedP, curIndexP)
                        if let pArc = pItem.arc {
                            result.addArc(pArc, nArc)
                            break
                        } else {
                            result.addCorner(pItem.startPt, nItem.startPt)
                        }
                    }
                }
                if pOk { curIndexP = tunedP.nextShape(curIndexP) }
                if nOk { curIndexN = tunedN.nextShape(curIndexN) }
            }
        }
        for sp in coupledSegments {
            let base = baselineSegment(sp)
            var side = false
            if meanderSettings.initialSide == .default {
                side = base.side(p) < 0
            } else {
                side = meanderSettings.initialSide.rawValue < 0
            }
            addCornersUntilIndex(sp.indexP, sp.indexN)
            result.meanderSegment(base, side)
        }
        addCornersUntilIndex(tunedP.pointCount - 1, tunedN.pointCount - 1)
        result.addCorner(tunedP.lastPoint, tunedN.lastPoint)
        let dpLen = origPathLength()
        lastStatus = .tuned
        if dpLen > meanderSettings.targetLength.max {
            lastStatus = .tooLong
            lastLength = dpLen
        } else {
            lastLength = dpLen - max(tunedP.length, tunedN.length)
            tuneLineLength(result, meanderSettings.targetLength.opt - dpLen)
        }
        if lastStatus != .tooLong {
            tunedP.clear()
            tunedN.clear()
            for m in result.meanders where m.type != .empty {
                tunedP.append(m.cLine(0))
                tunedN.append(m.cLine(1))
            }
            lastLength += max(tunedP.length, tunedN.length)
            updateStatus()
        }
        finalShapeP.clear()
        finalShapeN.clear()
        if meanderSettings.keepEndpoints {
            preP.simplify()
            tunedP.simplify()
            postP.simplify()
            finalShapeP.append(preP)
            finalShapeP.append(tunedP)
            finalShapeP.append(postP)
            preN.simplify()
            tunedN.simplify()
            postN.simplify()
            finalShapeN.append(preN)
            finalShapeN.append(tunedN)
            finalShapeN.append(postN)
        } else {
            finalShapeP.append(preP)
            finalShapeP.append(tunedP)
            finalShapeP.append(postP)
            finalShapeP.simplify()
            finalShapeN.append(preN)
            finalShapeN.append(tunedN)
            finalShapeN.append(postN)
            finalShapeN.simplify()
        }
        return true
    }

    /// The tuned pair put in the world (KiCad's FixRoute; which, fixed before it has been moved, adds the pair to a
    /// node it has not got: here nothing is fixed)
    public override func fixRoute(_ p: IPoint, _ endItem: Item?, forceFinish: Bool) -> Bool {
        guard let currentNodeBranch else { return false }
        let lP = Line(originPair.pLine(), finalShapeP)
        let lN = Line(originPair.nLine(), finalShapeN)
        currentNodeBranch.add(lP)
        currentNodeBranch.add(lN)
        _ = commitPlacement()
        return true
    }

    public override func abortPlacement() -> Bool {
        world?.killChildren()
        return true
    }

    public override var hasPlacedAnything: Bool { originPair.cp.segmentCount > 0 || originPair.cn.segmentCount > 0 }

    public override func commitPlacement() -> Bool {
        if let currentNodeBranch { router.commitRouting(currentNodeBranch) }
        currentNodeBranch = nil
        return true
    }

    /// Whether the dual meander's lines are clear of the board and keep four times the width from the meanders
    /// already fitted (KiCad's CheckFit)
    override func checkFit(_ shape: MeanderShape) -> Bool {
        let l1 = Line(originPair.pLine(), shape.cLine(0))
        let l2 = Line(originPair.nLine(), shape.cLine(1))
        if currentNodeBranch!.checkColliding(l1) != nil { return false }
        if currentNodeBranch!.checkColliding(l2) != nil { return false }
        let w = shape.width
        let clearance = w + w * 3
        return result.checkSelfIntersections(shape, clearance)
    }

    /// The pair as tuned, its positive line and its negative (KiCad's Traces)
    public override func traces() -> [Item] {
        currentTraceP = Line(originPair.pLine(), finalShapeP)
        currentTraceN = Line(originPair.nLine(), finalShapeN)
        return [currentTraceP, currentTraceN]
    }

    /// The two paths, the negative line's first (KiCad's TunedPath)
    public override func tunedPath() -> [Item] { tunedPathN + tunedPathP }

    public override var currentStart: IPoint { currentStartPoint }

    public override var currentNets: [NetHandle?] { [originPair.netP, originPair.netN] }

    public override var currentLayer: Int { initialSegment!.layers.start }

    public override var tuningLengthResult: Int { lastLength != 0 ? lastLength : origPathLength() }

    public override var tuningStatus: TuningStatus { lastStatus }
}

/// One line of a differential pair tuned to a skew against the other (KiCad's MEANDER_SKEW_PLACER): the track's line
/// meandered as a single track's is, to the length of the other line's path and the skew asked
public final class MeanderSkewPlacer: MeanderPlacer {
    private var originPair = DiffPair()
    private var tunedPathP: [Item] = []
    private var tunedPathN: [Item] = []
    /// The other line's path's length
    private var coupledLength = 0
    private var padToDieLengthP = 0
    private var padToDieLengthN = 0

    /// Starts tuning the skew of the pair of the track `startItem` at `p` (KiCad's Start). (KiCad works out the
    /// track's trivial path too, then replaces it: left out.)
    public override func start(_ p: IPoint, _ startItem: Item?) -> Bool {
        guard let startItem, startItem.ofKind([.segment, .arc]), let initial = startItem as? LinkedItem else {
            router.failureReason = "Please select a differential pair track you want to tune."
            return false
        }
        initialSegment = initial
        currentNodeBranch = nil
        currentStartPoint = snappedStartPoint(initial, p)
        let world = router.world!.branch()
        self.world = world
        originLine = world.assembleLine(initial)
        let topo = Topology(world)
        guard let pair = topo.assembleDiffPair(initial) else {
            router.failureReason = "Unable to find complementary differential pair net for skew tuning. Make sure "
                + "the names of the nets belonging to a differential pair end with either _N/_P or +/-."
            return false
        }
        originPair = pair
        if originPair.gap < 0 { originPair.setGap(router.sizes.diffPairGap) }
        if originPair.pLine().segmentCount == 0 || originPair.nLine().segmentCount == 0 { return false }
        (tunedPathP, startPadP, endPadP) = topo.assembleTuningPath(router.iface!, originPair.pLine().getLink(0))
        padToDieLengthP = 0
        if let startPadP { padToDieLengthP += startPadP.padToDie }
        if let endPadP { padToDieLengthP += endPadP.padToDie }
        (tunedPathN, startPadN, endPadN) = topo.assembleTuningPath(router.iface!, originPair.nLine().getLink(0))
        padToDieLengthN = 0
        if let startPadN { padToDieLengthN += startPadN.padToDie }
        if let endPadN { padToDieLengthN += endPadN.padToDie }
        world.remove(originLine)
        currentWidth = originLine.width
        currentEnd = .zero
        if originPair.netP == originLine.net {
            coupledLength = padToDieLengthN + lineLength(tunedPathN, startPadN, endPadN)
            lastLength = padToDieLengthP + lineLength(tunedPathP, startPadP, endPadP)
            tunedPathItems = tunedPathP
        } else {
            coupledLength = padToDieLengthP + lineLength(tunedPathP, startPadP, endPadP)
            lastLength = padToDieLengthN + lineLength(tunedPathN, startPadN, endPadN)
            tunedPathItems = tunedPathN
        }
        return true
    }

    /// The length of the tuned line's path as it was (KiCad's origPathLength)
    override func origPathLength() -> Int {
        if originPair.netP == originLine.net { return padToDieLengthP + lineLength(tunedPathItems, startPadP, endPadP) }
        return padToDieLengthN + lineLength(tunedPathItems, startPadN, endPadN)
    }

    /// The skew now: the tuned line's length less the other's (KiCad's CurrentSkew)
    public var currentSkew: Int { lastLength - coupledLength }

    /// The track's line meandered to the other line's length and the skew asked (KiCad's Move)
    public override func move(_ p: IPoint, _ endItem: Item?) -> Bool {
        doMove(p, endItem, coupledLength + meanderSettings.targetSkew.opt, coupledLength + meanderSettings.targetSkew.min,
               coupledLength + meanderSettings.targetSkew.max)
    }

    /// The skew it comes to (KiCad's TuningLengthResult)
    public override var tuningLengthResult: Int { lastLength - coupledLength }
}

extension Topology {
    /// The differential pair a track is part of (KiCad's AssembleDiffPair): its line, and the line of the track of the
    /// coupled net alongside it on its layer, of its width (or alongside one of the tracks at its ends), the nearest
    /// to its middle; positive and negative by their nets, and the gap between them. (The coupled net's tracks in the
    /// order they were made, as tools/kicad-reference has KiCad take them.)
    func assembleDiffPair(_ start: Item) -> DiffPair? {
        let refNet = start.net
        guard let coupledNet = world.ruleResolver.dpCoupledNet(refNet), let startItem = start as? LinkedItem else { return nil }
        var lp = world.assembleLine(startItem, stopAtLockedJoints: false, followLockedSegments: false,
                                    allowSegmentSizeMismatch: false)
        let coupledItems = world.allItems(inNet: coupledNet).sorted { $0.serial < $1.serial }
        let nItems = coupledItems.filter { $0.ofKind([.segment, .arc]) && $0.layers == startItem.layers }
        var refItem: LinkedItem?
        var coupledItem: LinkedItem?
        var minDistSq = Int.max
        var minDistTargetSq = Int.max
        let targetPoint = Self.centre(start.shape(-1)!)
        let parallelityThreshold = 5
        func findNItem(_ pItem: Item) {
            for nItem in nItems {
                var distSq = Int.max
                if nItem.kind != pItem.kind { continue }
                if let pSeg = pItem as? Segment, let nSeg = nItem as? Segment {
                    if nSeg.width != pSeg.width { continue }
                    if !pSeg.seg.approxParallel(nSeg.seg, threshold: parallelityThreshold) { continue }
                    if commonParallelProjection(pSeg.seg, nSeg.seg) == nil { continue }
                    distSq = nSeg.seg.squaredDistance(pSeg.seg)
                } else if let pArc = pItem as? Arc, let nArc = nItem as? Arc {
                    if nArc.width != pArc.width { continue }
                    let centerDistSq = (nArc.arc.center - pArc.arc.center).squaredNorm
                    if centerDistSq > parallelityThreshold * parallelityThreshold { continue }
                    let d = KiMath.cInt(pArc.arc.radius - nArc.arc.radius)
                    distSq = d * d
                }
                if distSq <= minDistSq {
                    let distTargetSq = Self.squaredDistance(nItem.shape(-1)!, targetPoint)
                    if distTargetSq < minDistTargetSq {
                        minDistTargetSq = distTargetSq
                        minDistSq = distSq
                        refItem = pItem as? LinkedItem
                        coupledItem = nItem as? LinkedItem
                    }
                }
            }
        }
        findNItem(startItem)
        if coupledItem == nil {
            // (the tracks at its ends, each once, in the order they were made)
            var linksToTest: [Item] = []
            for i in 0..<startItem.anchorCount {
                guard let jt = world.findJoint(startItem.anchor(i), startItem) else { continue }
                for link in jt.links where link !== startItem && !linksToTest.contains(where: { $0 === link }) {
                    linksToTest.append(link)
                }
            }
            for link in linksToTest.sorted(by: { $0.serial < $1.serial }) { findNItem(link) }
        }
        guard let coupledItem, let refItem else { return nil }
        var ln = world.assembleLine(coupledItem, stopAtLockedJoints: false, followLockedSegments: false,
                                    allowSegmentSizeMismatch: false)
        if world.ruleResolver.dpNetPolarity(refNet) < 0 { swap(&lp, &ln) }
        var gap = -1
        if refItem.kind == .segment {
            // (the segments are parallel: the pair's gap)
            let refDir = refItem.anchor(1) - refItem.anchor(0)
            let displacement = refItem.anchor(1) - coupledItem.anchor(1)
            gap = Int(Int32(truncatingIfNeeded: abs(refDir.cross(displacement) / refDir.norm))) - lp.width
        } else if let refArc = refItem as? Arc, let coupledArc = coupledItem as? Arc {
            gap = KiMath.cInt(abs(refArc.arc.radius - coupledArc.arc.radius)) - lp.width
        }
        let pair = DiffPair(lineP: lp, lineN: ln)
        pair.setWidth(lp.width)
        pair.layers = lp.layers
        pair.setGap(gap)
        return pair
    }

    /// The middle of a track's shape's box (KiCad's SHAPE::Centre): a segment's box made from its first end and the
    /// way to its second, so that its middle is cut towards the first
    static func centre(_ shape: Shape) -> IPoint {
        switch shape {
        case .segment(let s, _):
            return IPoint(s.a.x + (s.b.x - s.a.x) / 2, s.a.y + (s.b.y - s.a.y) / 2)
        default:
            let b = shape.bbox
            return IPoint(b.minX + (b.maxX - b.minX) / 2, b.minY + (b.maxY - b.minY) / 2)
        }
    }

    /// How far, squared, `p` is from a track's shape made a polygon with no error allowed, 0 inside it (KiCad's
    /// SHAPE::SquaredDistance)
    static func squaredDistance(_ shape: Shape, _ p: IPoint) -> Int {
        let buffer: PolySet
        switch shape {
        case .segment(let s, let w):
            buffer = PadPolygon.oval(start: s.a, end: s.b, width: w, maxError: 0, errorLocation: .inside)
        case .arc(let a):
            buffer = PadPolygon.arc(start: a.start, mid: a.mid, end: a.end, width: a.width, maxError: 0, errorLocation: .inside)
        default:
            return Int.max
        }
        guard let outline = buffer.polygons.first?.first else { return Int.max }
        if outline.isClosed && outline.pointInside(p) { return 0 }
        var d = Int.max
        for s in 0..<outline.segmentCount { d = min(d, outline.segment(s).squaredDistance(p)) }
        return d
    }
}
