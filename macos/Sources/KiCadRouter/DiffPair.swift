// Ported from KiCad 10.0.7: pcbnew/router/pns_diff_pair.h, pns_diff_pair.cpp and ranged_num.h (without what the
// pair placer does not call: gateways projected orthogonally, pairs' total lengths).
// Copyright (C) 2013-2015 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// A value, and how far above and below it another may be and still match it (KiCad's RANGED_NUM)
public struct RangedNum: Sendable {
    public var value: Int
    public var tolerancePlus: Int
    public var toleranceMinus: Int

    public init(_ value: Int = 0, _ tolerancePlus: Int = 0, _ toleranceMinus: Int = 0) {
        self.value = value
        self.tolerancePlus = tolerancePlus
        self.toleranceMinus = toleranceMinus
    }

    public func matches(_ other: Int) -> Bool { other >= value - toleranceMinus && other <= value + tolerancePlus }
}

/// Where a differential pair goes into or comes out of: two anchors, one for each net, in line or diagonal, with
/// the angles it may be entered at and, perhaps, the lines that lead into it (KiCad's DP_GATEWAY). The router joins
/// two gateways with parallel lines.
public struct DPGateway: Sendable {
    public private(set) var anchorP: IPoint
    public private(set) var anchorN: IPoint
    /// Whether the anchors lie on a diagonal
    public let isDiagonal: Bool
    /// The 45° angles it may be entered at
    public let allowedAngles: Direction45.AngleType
    /// How much it is preferred, matching gateways
    public var priority: Int
    public private(set) var entryP = LineChain()
    public private(set) var entryN = LineChain()
    public private(set) var hasEntryLines = false

    public init(_ anchorP: IPoint, _ anchorN: IPoint, _ isDiagonal: Bool, allowedAngles: Direction45.AngleType = .obtuse,
                priority: Int = 0) {
        self.anchorP = anchorP
        self.anchorN = anchorN
        self.isDiagonal = isDiagonal
        self.allowedAngles = allowedAngles
        self.priority = priority
    }

    public mutating func setEntryLines(_ p: LineChain, _ n: LineChain) {
        entryP = p
        entryN = n
        hasEntryLines = true
    }

    /// The entry lines as a pair (KiCad's Entry)
    public var entry: DiffPair { DiffPair(p: entryP, n: entryN, gap: 0) }

    public mutating func reverse() {
        entryN = entryN.reversed()
        entryP = entryP.reversed()
    }
}

/// The pads, vias or track ends a differential pair starts or ends on, one of each net, and the points on them it
/// starts from (KiCad's DP_PRIMITIVE_PAIR). It keeps copies of them, as KiCad clones them.
public struct DPPrimitivePair {
    public private(set) var primP: Item?
    public private(set) var primN: Item?
    public private(set) var anchorP = IPoint.zero
    public private(set) var anchorN = IPoint.zero

    public init() {}

    public init(_ primP: Item, _ primN: Item) {
        let p = primP.clone(), n = primN.clone()
        self.primP = p
        self.primN = n
        anchorP = p.anchor(0)
        anchorN = n.anchor(0)
    }

    public init(anchorP: IPoint, anchorN: IPoint) {
        self.anchorP = anchorP
        self.anchorN = anchorN
    }

    public mutating func setAnchors(_ p: IPoint, _ n: IPoint) {
        anchorP = p
        anchorN = n
    }

    /// Whether it is a pair of track ends, which have directions to go on in
    public var directional: Bool { primP?.ofKind([.segment, .arc]) ?? false }

    /// The direction a track end goes on in from `p` (none for a pad or via)
    private func anchorDirection(_ item: Item?, _ p: IPoint) -> Direction45 {
        guard let item, item.ofKind([.segment, .arc]) else { return Direction45() }
        if item.anchor(0) == p { return Direction45(item.anchor(0) - item.anchor(1)) }
        return Direction45(item.anchor(1) - item.anchor(0))
    }

    public var dirP: Direction45 { anchorDirection(primP, anchorP) }
    public var dirN: Direction45 { anchorDirection(primN, anchorN) }

    /// The point between the pair, and the direction a pair from it goes in towards `cursor` (KiCad's
    /// CursorOrientation): two parallel tracks' own direction, else across the line between the anchors, towards
    /// the cursor
    public func cursorOrientation(_ cursor: IPoint) -> (midpoint: IPoint, direction: IPoint) {
        let primP = primP!, primN = primN!
        var aP: IPoint, aN: IPoint
        if let segP = primP as? Segment, let segN = primN as? Segment {
            aP = primP.anchor(1)
            aN = primN.anchor(1)
            // If both segments are parallel, use that as the direction. Otherwise, fall back on the direction
            // perpendicular to the anchor points.
            let sp = segP.seg, sn = segN.seg
            if sp.b != sp.a && sn.b != sn.a && sp.approxParallel(sn) {
                return ((aP + aN).divided(by: 2), (sp.b - sp.a).resized((aP - aN).norm))
            }
        } else {
            aP = primP.anchor(0)
            aN = primN.anchor(0)
        }
        let midpoint = (aP + aN).divided(by: 2)
        var direction = (aP - aN).perpendicular
        if direction.dot(cursor - midpoint) < 0 { direction = -direction }
        return (midpoint, direction)
    }
}

/// The angle between two vectors' 45° directions
private func angle(_ a: IPoint, _ b: IPoint) -> Direction45.AngleType { Direction45(a).angle(Direction45(b)) }

/// Whether two lines keep `gap` apart (less 100 nm), but within `transitionRadius` of `entryMid`, where they may
/// keep only the gap of the anchors they start from, if that is narrower (KiCad's checkGap)
private func checkGap(_ p: LineChain, _ n: LineChain, _ gap: Int, _ entryGap: Int = -1, _ entryMid: IPoint = .zero,
                      _ transitionRadius: Int = 0) -> Bool {
    let gapSq = (gap - 100) * (gap - 100)
    // Inside the entry transition window the pair may legitimately hold a gap as small as the existing anchor pair
    // (e.g. starting in a neckdown area) while it widens out to the configured gap. Outside the window the full
    // configured gap is enforced.
    let relaxEntry = entryGap >= 0 && entryGap < gap
    let entryGapSq = relaxEntry ? (entryGap - 100) * (entryGap - 100) : gapSq
    let radiusSq = transitionRadius * transitionRadius
    for i in 0..<p.segmentCount {
        let sp = p.segment(i)
        let pNearEntry = relaxEntry && ((sp.a + sp.b).divided(by: 2) - entryMid).squaredNorm <= radiusSq
        for j in 0..<n.segmentCount {
            let sn = n.segment(j)
            let distSq = sp.squaredDistance(sn)
            var limitSq = gapSq
            if pNearEntry && ((sn.a + sn.b).divided(by: 2) - entryMid).squaredNorm <= radiusSq { limitSq = entryGapSq }
            if distSq < limitSq { return false }
        }
    }
    return true
}

/// A vector along `dir` of the length that makes twice it at least `length` (KiCad's makeGapVector)
private func makeGapVector(_ dir: IPoint, _ length: Int) -> IPoint {
    var l = length / 2
    var rv: IPoint
    if dir.norm == 0 { return dir }
    repeat {
        rv = dir.resized(l)
        l += 1
    } while (rv * 2).norm < length
    return rv
}

/// The gateways of a pair: worked out for the cursor, or for the pads, vias or tracks the pair starts or ends on
/// (KiCad's DP_GATEWAYS)
public struct DPGateways {
    private var gap: Int
    private var viaGap: Int
    private var viaDiameter = 0
    private var fitVias = true
    public var gateways: [DPGateway] = []

    public init(gap: Int) {
        self.gap = gap
        viaGap = gap
    }

    public mutating func setFitVias(_ enable: Bool, diameter: Int = 0, viaGap: Int = -1) {
        fitVias = enable
        viaDiameter = diameter
        self.viaGap = viaGap < 0 ? gap : viaGap
    }

    /// The pair joining one of `entry`'s gateways to one of `target`'s, the best by their priorities, into `dp`
    /// (KiCad's FitGateways); whether there is one
    public func fitGateways(_ entry: DPGateways, _ target: DPGateways, prefDiagonal: Bool, _ dp: DiffPair) -> Bool {
        var bestP = LineChain(), bestN = LineChain()
        var bestScore = -1000
        var found = false
        for gEntry in entry.gateways {
            for gTarget in target.gateways {
                for preferred in [false, true] {
                    var score = preferred ? 0 : -3
                    score += gEntry.priority
                    score += gTarget.priority
                    if score >= bestScore {
                        let l = DiffPair(gap: gap)
                        if l.buildInitial(gEntry, gTarget, prefDiagonal: preferred ? prefDiagonal : !prefDiagonal) {
                            bestP = l.cp
                            bestN = l.cn
                            bestScore = score
                            found = true
                        }
                    }
                }
            }
        }
        if found {
            dp.setGap(gap)
            dp.setShape(bestP, bestN)
            return true
        }
        return false
    }

    private func checkDiagonalAlignment(_ a: IPoint, _ b: IPoint) -> Bool {
        let dir = IPoint(abs(a.x - b.x), abs(a.y - b.y))
        return (dir.x == 0 && dir.y != 0) || dir.x == dir.y || (dir.y == 0 && dir.x != 0)
    }

    /// The gateways left but those whose anchors' direction makes one of `angleMask`'s angles with `refOrientation`
    /// (KiCad's FilterByOrientation)
    public mutating func filterByOrientation(_ angleMask: Direction45.AngleType, _ refOrientation: Direction45) {
        gateways.removeAll { !Direction45($0.anchorP - $0.anchorN).angle(refOrientation).intersection(angleMask).isEmpty }
    }

    /// The gateways out of a pair of pads, vias or track ends (KiCad's BuildFromPrimitivePair): a track pair's own
    /// continuation; round pads' and vias' the generic ones; others' also fanned out from them by their size
    public mutating func buildFromPrimitivePair(_ pair: DPPrimitivePair, preferDiagonal: Bool) {
        var p0p = IPoint.zero, p0n = IPoint.zero
        var orthoFanDistance = 0, diagFanDistance = 0
        var shP: Shape?
        guard let primP = pair.primP, let primN = pair.primN else {
            buildGeneric(pair.anchorP, pair.anchorN, buildEntries: true)
            return
        }
        let pvMask: ItemKind = [.solid, .via]
        if primP.ofKind(pvMask) && primN.ofKind(pvMask) {
            p0p = pair.anchorP
            p0n = pair.anchorN
            // (KiCad's TODO: padstacks)
            shP = primP.shape(-1)
        } else if primP.ofKind([.segment, .arc]) && primN.ofKind([.segment, .arc]) {
            buildDpContinuation(pair, isDiagonal: preferDiagonal)
            return
        }
        let majorDirection = (p0p - p0n).perpendicular
        guard let shP else { return }
        switch shP {
        case .circle:
            buildGeneric(p0p, p0n, buildEntries: true)
            return
        case .rect(let b):
            var w = b.width, h = b.height
            if w < h { swap(&w, &h) }
            orthoFanDistance = (w + 1) * 3 / 2
            diagFanDistance = w - h
        case .segment(let s, let width):
            orthoFanDistance = width + (s.b - s.a).norm
            diagFanDistance = (s.b - s.a).norm
        case .simple(let c):
            let bbox = c.bbox
            var w = bbox.width, h = bbox.height
            if w < h { swap(&w, &h) }
            orthoFanDistance = (w + 1) * 3 / 2
            diagFanDistance = w - h
        case .chain, .arc:
            // (KiCad's wxFAIL_MSG: an unsupported starting primitive, its fans of no length)
            break
        }
        if checkDiagonalAlignment(p0p, p0n) {
            let padDist = (p0p - p0n).norm
            for k in 0..<2 {
                let dir = makeGapVector(majorDirection, k == 0 ? orthoFanDistance : diagFanDistance)
                let d = max(0, padDist - gap)
                let dp = makeGapVector(dir, d)
                let dv = makeGapVector(p0n - p0p, d)
                for i in 0..<2 {
                    let sign = i != 0 ? -1 : 1
                    let gwP = p0p + (dir + dp) * sign + dv
                    let gwN = p0n + (dir + dp) * sign - dv
                    let entryP = LineChain([p0p, p0p + dir * sign, gwP])
                    let entryN = LineChain([p0n, p0n + dir * sign, gwN])
                    var gw = DPGateway(gwP, gwN, false)
                    gw.setEntryLines(entryP, entryN)
                    gw.priority = 100 - k
                    gateways.append(gw)
                }
            }
        }
        buildGeneric(p0p, p0n, buildEntries: true)
    }

    /// The gateways round the cursor, across and along the axes and diagonals, the gap apart (or, fitting vias,
    /// the vias' and their gap apart, the generic gateways of such a pair) (KiCad's BuildForCursor)
    public mutating func buildForCursor(_ cursor: IPoint) {
        let gap = fitVias ? viaGap + viaDiameter : self.gap
        for diagonal in [false, true] {
            for i in 0..<4 {
                var dir: IPoint
                if !diagonal {
                    dir = makeGapVector(IPoint(gap, gap), gap)
                    if i % 2 == 0 { dir.x = -dir.x }
                    if i / 2 == 0 { dir.y = -dir.y }
                } else if i / 2 == 0 {
                    dir = IPoint((gap + 1) / 2 * (i % 2 != 0 ? -1 : 1), 0)
                } else {
                    dir = IPoint(0, (gap + 1) / 2 * (i % 2 != 0 ? -1 : 1))
                }
                if fitVias {
                    buildGeneric(cursor + dir, cursor - dir, buildEntries: true, viaMode: true)
                } else {
                    gateways.append(DPGateway(cursor + dir, cursor - dir, diagonal))
                }
            }
        }
    }

    /// Lines into each gateway that has none, from `p0p` and `p0n` (KiCad's buildEntries)
    private mutating func buildEntries(_ p0p: IPoint, _ p0n: IPoint) {
        for i in gateways.indices where !gateways[i].hasEntryLines {
            let g = gateways[i]
            let leadP = Direction45().buildInitialTrace(g.anchorP, p0p, startDiagonal: g.isDiagonal).reversed()
            let leadN = Direction45().buildInitialTrace(g.anchorN, p0n, startDiagonal: g.isDiagonal).reversed()
            gateways[i].setEntryLines(leadP, leadN)
        }
    }

    /// The gateway that goes on from a pair of track ends, and, for a pair across an axis or a diagonal, ones with an
    /// anchor moved on a little (about 22.5°), to meet tracks at 45° to it (KiCad's buildDpContinuation)
    private mutating func buildDpContinuation(_ pair: DPPrimitivePair, isDiagonal: Bool) {
        var gw = DPGateway(pair.anchorP, pair.anchorN, isDiagonal)
        gw.priority = 100
        gateways.append(gw)
        if !pair.directional { return }
        // If we're at a "normal" angle (cardinal or 45-degree-diagonal), then add gateways that angle the anchor
        // points by 22.5-degrees for connection to tracks which are at +/- 45 degrees from the existing direction.
        let epsilon = 5 // 0.005um
        let sin22_5 = 0.38268 // sin(22.5)
        let sin23_5 = 0.39875 // sin(23.5)
        func addAngledGateways(_ length: Int, _ priority: Int) {
            var entryLineP = LineChain()
            entryLineP.append(pair.anchorP)
            entryLineP.append(pair.anchorP + pair.dirP.vector.resized(length))
            var gwExtendP = DPGateway(entryLineP.lastPoint, pair.anchorN, isDiagonal)
            gwExtendP.priority = priority
            gwExtendP.setEntryLines(entryLineP, LineChain())
            gateways.append(gwExtendP)
            var entryLineN = LineChain()
            entryLineN.append(pair.anchorN)
            entryLineN.append(pair.anchorN + pair.dirN.vector.resized(length))
            var gwExtendN = DPGateway(pair.anchorP, entryLineN.lastPoint, isDiagonal)
            gwExtendN.priority = priority
            gwExtendN.setEntryLines(LineChain(), entryLineN)
            gateways.append(gwExtendN)
        }
        let delta = pair.anchorP - pair.anchorN
        if abs(delta.x) < epsilon || abs(delta.y) < epsilon || abs(delta.x - delta.y) < epsilon {
            addAngledGateways(KiMath.round(Double(gap) * sin22_5), 20)
            // fixme; sin(22.5) doesn't always work, so we also add some lower priority ones with a bit of wiggle
            // room. See https://gitlab.com/kicad/code/kicad/-/issues/12459.
            addAngledGateways(KiMath.round(Double(gap) * sin23_5), 5)
        }
    }

    /// The gateways out of two points whatever they are (KiCad's BuildGeneric): from between them and beside them,
    /// where they are in line or diagonal, and where the straight and diagonal lines through them cross; with lines
    /// into them from the points, if asked. In via mode only those where like lines cross.
    public mutating func buildGeneric(_ p0p: IPoint, _ p0n: IPoint, buildEntries: Bool = false, viaMode: Bool = false) {
        let padToGapThreshold = 3
        let padDist = (p0n - p0p).norm
        let stP = [Seg(p0p + IPoint(-100, 0), p0p + IPoint(100, 0)), Seg(p0p + IPoint(0, -100), p0p + IPoint(0, 100))]
        let stN = [Seg(p0n + IPoint(-100, 0), p0n + IPoint(100, 0)), Seg(p0n + IPoint(0, -100), p0n + IPoint(0, 100))]
        let dP = [Seg(p0p + IPoint(-100, -100), p0p + IPoint(100, 100)), Seg(p0p + IPoint(100, -100), p0p + IPoint(-100, 100))]
        let dN = [Seg(p0n + IPoint(-100, -100), p0n + IPoint(100, 100)), Seg(p0n + IPoint(100, -100), p0n + IPoint(-100, 100))]

        // midpoint exit & side-by exits
        for i in 0..<2 {
            let straightColl = stP[i].collinear(stN[i])
            let diagColl = dP[i].collinear(dN[i])
            if straightColl || diagColl {
                var dir = makeGapVector(p0n - p0p, gap / 2)
                let m = (p0p + p0n).divided(by: 2)
                let prio = padDist > padToGapThreshold * gap ? 2 : 1
                if !viaMode {
                    gateways.append(DPGateway(m - dir, m + dir, diagColl, allowedAngles: .right, priority: prio))
                    dir = makeGapVector(p0n - p0p, 2 * gap)
                    gateways.append(DPGateway(p0p - dir, p0p - dir + dir.perpendicular, diagColl))
                    gateways.append(DPGateway(p0p - dir, p0p - dir - dir.perpendicular, diagColl))
                    gateways.append(DPGateway(p0n + dir + dir.perpendicular, p0n + dir, diagColl))
                    gateways.append(DPGateway(p0n + dir - dir.perpendicular, p0n + dir, diagColl))
                }
            }
        }

        for i in 0..<2 {
            for j in 0..<2 {
                var ips: [IPoint?] = [dN[i].intersectLines(dP[j]), stP[i].intersectLines(stN[j])]
                if dN[i].collinear(dP[j]) { ips[0] = nil }
                // (KiCad tests the straight line through the positive anchor against itself here)
                if stP[i].collinear(stP[j]) { ips[1] = nil }
                // diagonal-diagonal and straight-straight cases - the most typical case if the pads are on the same
                // straight/diagonal line
                for k in 0..<2 {
                    guard let m = ips[k], m != p0p && m != p0n else { continue }
                    let prio = padDist > padToGapThreshold * gap ? 10 : 20
                    let gP = (p0p - m).resized(Int((Double(gap) * 0.5.squareRoot()).rounded(.up)))
                    let gN = (p0n - m).resized(Int((Double(gap) * 0.5.squareRoot()).rounded(.up)))
                    gateways.append(DPGateway(m + gP, m + gN, k == 0, allowedAngles: .obtuse, priority: prio))
                }
                ips = [stN[i].intersectLines(dP[j]), stP[i].intersectLines(dN[j])]
                // diagonal-straight cases: 8 possibilities of "weirder" exists
                for k in 0..<2 {
                    guard let m = ips[k], !viaMode && m != p0p && m != p0n else { continue }
                    var gP = (p0p - m).resized(Int((Double(gap) * 2.0.squareRoot()).rounded(.up)))
                    var gN = (p0n - m).resized(Int(Double(gap).rounded(.up)))
                    if angle(gP, gN) != .acute { gateways.append(DPGateway(m + gP, m + gN, true)) }
                    gP = (p0p - m).resized(gap)
                    gN = (p0n - m).resized(Int((Double(gap) * 2.0.squareRoot()).rounded(.up)))
                    if angle(gP, gN) != .acute { gateways.append(DPGateway(m + gP, m + gN, true)) }
                }
            }
        }
        if buildEntries { self.buildEntries(p0p, p0n) }
    }
}

/// The parts of `p` and `n` that run alongside each other (KiCad's commonParallelProjection): `p` clipped to where
/// `n` projected on it overlaps it, and `n` to the projections of those ends; nil if they do not overlap
func commonParallelProjection(_ p: Seg, _ n: Seg) -> (pClip: Seg, nClip: Seg)? {
    let nProjP = Seg(p.lineProject(n.a), p.lineProject(n.b))
    var tA = 0
    var tB = p.tCoef(p.b)
    var tprojA = p.tCoef(nProjP.a)
    var tprojB = p.tCoef(nProjP.b)
    if tB < tA { swap(&tB, &tA) }
    if tprojB < tprojA { swap(&tprojB, &tprojA) }
    if tB <= tprojA { return nil }
    if tA >= tprojB { return nil }
    // (KiCad's "awful and disgusting way of finding 2 midpoints")
    let tv = [0, p.tCoef(p.b), p.tCoef(nProjP.a), p.tCoef(nProjP.b)].sorted()
    let pLenSq = p.squaredLength
    let dp = p.b - p.a
    // (each coordinate an int, as KiCad's VECTOR2I takes the 64-bit result)
    let pClipA = IPoint(Int(Int32(truncatingIfNeeded: p.a.x + KiMath.rescale(dp.x, tv[1], pLenSq))),
                        Int(Int32(truncatingIfNeeded: p.a.y + KiMath.rescale(dp.y, tv[1], pLenSq))))
    let pClipB = IPoint(Int(Int32(truncatingIfNeeded: p.a.x + KiMath.rescale(dp.x, tv[2], pLenSq))),
                        Int(Int32(truncatingIfNeeded: p.a.y + KiMath.rescale(dp.y, tv[2], pLenSq))))
    return (Seg(pClipA, pClipB), Seg(n.lineProject(pClipA), n.lineProject(pClipB)))
}

/// A differential pair: the paths of its positive and negative lines, their nets, width and gap, and the vias they
/// end in, if they do (KiCad's DIFF_PAIR, a LINK_HOLDER). KiCad's pairs are values, copied as they are passed round;
/// here a pair is an object, and `copy()` is KiCad's copy.
public final class DiffPair: Item {
    /// Segments of the two lines that run alongside each other, the gap apart (KiCad's COUPLED_SEGMENTS)
    public struct CoupledSegments: Sendable {
        public var coupledP: Seg
        public var coupledN: Seg
        public var parentP: Seg
        public var parentN: Seg
        public var indexP: Int
        public var indexN: Int
    }

    public private(set) var cp = LineChain()
    public private(set) var cn = LineChain()
    private var viaP: Via?
    private var viaN: Via?
    public private(set) var endsWithVias = false
    public private(set) var netP: NetHandle?
    public private(set) var netN: NetHandle?
    public private(set) var width = 0
    public private(set) var gap = 0
    private var viaGap = 0
    private var maxUncoupledLength = 0
    private var chamferLimit = 0
    public private(set) var gapConstraint = RangedNum()
    /// The lines the pair was made of, linked to the world's tracks (KiCad's m_line_p and m_line_n, which
    /// DIFF_PAIR( LINE, LINE ) keeps): PLine and NLine give them as they are while they are linked, and bring them up
    /// to date with the pair once they are not. (A pair made of its paths has none: its lines are made each time.)
    private var heldP: Line?
    private var heldN: Line?

    public init() {
        super.init(kind: .diffPair)
    }

    /// The pair of two lines, kept as they are (KiCad's DIFF_PAIR( LINE, LINE )): their paths and nets; its width and
    /// gap none yet
    public init(lineP: Line, lineN: Line, gap: Int = 0) {
        heldP = lineP.copy()
        heldN = lineN.copy()
        gapConstraint = RangedNum(gap)
        netP = lineP.net
        netN = lineN.net
        cp = lineP.cLine
        cn = lineN.cLine
        super.init(kind: .diffPair)
    }

    public init(gap: Int) {
        gapConstraint = RangedNum(gap)
        super.init(kind: .diffPair)
    }

    public init(p: LineChain, n: LineChain, gap: Int = 0) {
        cp = p
        cn = n
        gapConstraint = RangedNum(gap)
        super.init(kind: .diffPair)
    }

    private init(copying o: DiffPair) {
        super.init(kind: .diffPair)
        assign(o)
    }

    /// KiCad's copy constructor
    public func copy() -> DiffPair { DiffPair(copying: self) }

    /// KiCad's assignment operator: this pair made a copy of `o` (its own copies of its vias)
    public func assign(_ o: DiffPair) {
        cn = o.cn
        cp = o.cp
        viaN = o.viaN.map { $0.clone() as! Via }
        viaP = o.viaP.map { $0.clone() as! Via }
        layers = o.layers
        endsWithVias = o.endsWithVias
        netN = o.netN
        netP = o.netP
        width = o.width
        gap = o.gap
        viaGap = o.viaGap
        maxUncoupledLength = o.maxUncoupledLength
        chamferLimit = o.chamferLimit
        gapConstraint = o.gapConstraint
        heldP = o.heldP?.copy()
        heldN = o.heldN?.copy()
    }

    // (KiCad's Clone asserts: a pair is never cloned)
    public override func clone() -> Item { fatalError("a differential pair is not cloned") }

    public func setShape(_ p: LineChain, _ n: LineChain, swapLanes: Bool = false) {
        if swapLanes {
            cp = n
            cn = p
        } else {
            cp = p
            cn = n
        }
    }

    public func setShape(_ pair: DiffPair) {
        cp = pair.cp
        cn = pair.cn
    }

    public func setNets(_ p: NetHandle?, _ n: NetHandle?) {
        netP = p
        netN = n
    }

    // (KiCad's SetWidth sets its chains' widths too, which nothing here reads)
    public func setWidth(_ w: Int) { width = w }

    public func setGap(_ g: Int) {
        gap = g
        gapConstraint = RangedNum(gap, 10_000, 10_000)
    }

    public func appendVias(_ p: Via, _ n: Via) {
        endsWithVias = true
        viaP = p.clone() as? Via
        viaN = n.clone() as? Via
    }

    public func removeVias() { endsWithVias = false }

    public func setViaDiameter(_ d: Int) {
        viaP?.setDiameter(d)
        viaN?.setDiameter(d)
    }

    public func setViaDrill(_ d: Int) {
        viaP?.setDrill(d)
        viaN?.setDrill(d)
    }

    /// The positive line: its path, the pair's width and layer, its net, and its via if the pair ends in vias
    /// (KiCad's PLine, which brings its line up to date each time it is asked, unless it is the line the pair was
    /// made of and still linked to the world's tracks)
    public func pLine() -> Line {
        guard let heldP else { return line(cp, netP, viaP) }
        if !heldP.isLinked { updateLine(heldP, cp, netP, viaP) }
        return heldP
    }

    public func nLine() -> Line {
        guard let heldN else { return line(cn, netN, viaN) }
        if !heldN.isLinked { updateLine(heldN, cn, netN, viaN) }
        return heldN
    }

    /// A line the pair was made of brought up to date with it (KiCad's updateLine)
    private func updateLine(_ l: Line, _ shape: LineChain, _ net: NetHandle?, _ via: Via?) {
        l.setShape(shape)
        l.setWidth(width)
        l.net = net
        l.setLayer(layers.start)
        l.parent = parent
        l.sourceItem = sourceItem
        if endsWithVias, let via { l.appendVia(via) }
    }

    private func line(_ shape: LineChain, _ net: NetHandle?, _ via: Via?) -> Line {
        let l = Line()
        l.setShape(shape)
        l.setWidth(width)
        l.net = net
        l.setLayer(layers.start)
        if endsWithVias, let via { l.appendVia(via) }
        return l
    }

    /// What the pair ends on, to go on from: its vias, or its lines' last segments (KiCad's EndingPrimitives)
    public func endingPrimitives() -> DPPrimitivePair {
        if endsWithVias, let viaP, let viaN { return DPPrimitivePair(viaP, viaN) }
        let lP = pLine(), lN = nLine()
        let sP = Segment(line: lP, lP.cSegment(-1))
        let sN = Segment(line: lN, lN.cSegment(-1))
        var pair = DPPrimitivePair(sP, sN)
        pair.setAnchors(sP.seg.b, sN.seg.b)
        return pair
    }

    /// The pair from `entry` to `target`: two 45° traces between their anchors, with the gateways' entry lines
    /// before and after (KiCad's BuildInitial); whether it is one the gateways allow, keeping the gap and not
    /// crossing
    public func buildInitial(_ entry: DPGateway, _ target: DPGateway, prefDiagonal: Bool) -> Bool {
        let p = Direction45().buildInitialTrace(entry.anchorP, target.anchorP, startDiagonal: prefDiagonal)
        let n = Direction45().buildInitialTrace(entry.anchorN, target.anchorN, startDiagonal: prefDiagonal)
        var mask = entry.allowedAngles.union([.straight, .obtuse])
        cp = p
        cn = n
        if entry.hasEntryLines {
            let e = entry.entry
            if !e.checkConnectionAngle(self, mask) { return false }
            cp = e.cp
            cn = e.cn
            cp.append(p)
            cn.append(n)
        } else {
            cp = p
            cn = n
        }
        mask = target.allowedAngles.union([.straight, .obtuse])
        if target.hasEntryLines {
            var t = target
            t.reverse()
            let e = t.entry
            if !checkConnectionAngle(e, mask) { return false }
            cp.append(e.cp)
            cn.append(e.cn)
        }
        // The trace may start from an existing anchor pair that is narrower than the configured gap (e.g. a neckdown
        // area inside a BGA). In that case the entry region legitimately holds a smaller gap than the netclass
        // value while the pair widens out towards the target. Allow the narrower gap only within a transition window
        // around the entry anchor; the rest of the trace must still satisfy the configured gap.
        let configuredGap = gapConstraint.value
        let entryGap = (entry.anchorP - entry.anchorN).norm
        let entryMid = (entry.anchorP + entry.anchorN).divided(by: 2)
        // A 45-degree widening from the entry gap to the configured gap completes within roughly the difference of
        // the two gaps; allow a generous window so the transition segments are accepted.
        let transitionRadius = 4 * configuredGap
        if !checkGap(p, n, configuredGap, entryGap, entryMid, transitionRadius) { return false }
        if p.selfIntersecting() != nil || n.selfIntersecting() != nil { return false }
        if p.intersects(n) { return false }
        return true
    }

    /// Whether `other` goes on from this pair at one of `allowedAngles`, each line from its own (KiCad's
    /// CheckConnectionAngle)
    public func checkConnectionAngle(_ other: DiffPair, _ allowedAngles: Direction45.AngleType) -> Bool {
        let checkP: Bool, checkN: Bool
        if cp.segmentCount == 0 || other.cp.segmentCount == 0 {
            checkP = true
        } else {
            checkP = !Direction45(cp.segment(-1)).angle(Direction45(other.cp.segment(0))).intersection(allowedAngles).isEmpty
        }
        if cn.segmentCount == 0 || other.cn.segmentCount == 0 {
            checkN = true
        } else {
            checkN = !Direction45(cn.segment(-1)).angle(Direction45(other.cn.segment(0))).intersection(allowedAngles).isEmpty
        }
        return checkP && checkN
    }

    /// How much longer the positive line is than the negative
    public var skew: Double { Double(cp.length - cn.length) }

    /// The segments of the two lines that run alongside each other the gap apart (KiCad's CoupledSegmentPairs)
    public func coupledSegmentPairs() -> [CoupledSegments] {
        var pairs: [CoupledSegments] = []
        // Do not simplify the line chains here, otherwise the indices will be invalid
        // (an arc's pieces left out)
        for i in 0..<cp.segmentCount where !cp.isArcSegment(i) {
            for j in 0..<cn.segmentCount where !cn.isArcSegment(j) {
                let sp = cp.segment(i), sn = cn.segment(j)
                let dist = abs(sp.distance(sn) - width)
                if sp.approxParallel(sn, threshold: 2) && gapConstraint.matches(dist), let (pClip, nClip) = commonParallelProjection(sp, sn) {
                    pairs.append(CoupledSegments(coupledP: pClip, coupledN: nClip, parentP: sp, parentN: sn, indexP: i, indexN: j))
                }
            }
        }
        return pairs
    }

    /// How long `p` and `n` run alongside each other the gap apart (KiCad's CoupledLength of two chains)
    public func coupledLength(_ p: LineChain, _ n: LineChain) -> Int {
        var total = 0
        for i in 0..<p.segmentCount {
            for j in 0..<n.segmentCount {
                let sp = p.segment(i), sn = n.segment(j)
                let dist = abs(sp.distance(sn) - width)
                if sp.approxParallel(sn) && gapConstraint.matches(dist), let (pClip, _) = commonParallelProjection(sp, sn) {
                    total += pClip.length
                }
            }
        }
        return total
    }

    /// How long the pair's lines run alongside each other (KiCad's CoupledLength)
    public var coupledLength: Double {
        coupledSegmentPairs().reduce(0.0) { $0 + Double($1.coupledP.length) }
    }
}
