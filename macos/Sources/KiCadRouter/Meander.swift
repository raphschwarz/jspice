// Ported from KiCad 10.0.7: pcbnew/router/pns_meander.h and pns_meander.cpp (the length domain: not the time
// domain's delays).
// Copyright (C) 2013-2015 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// The shapes a meander can have (KiCad's MEANDER_TYPE)
public enum MeanderType: Int, Sendable {
    /// _|^|_, on one side
    case single
    /// _|^|
    case start
    /// |^|_
    case finish
    /// |^| or |_|
    case turn
    /// A start tried, and a turn after it, but no line made
    case checkStart
    /// A turn tried, and a finish after it, but no line made
    case checkFinish
    /// A corner of the line
    case corner
    /// An arc of the line
    case arc
    /// No meander: the line straight
    case empty
}

/// How a meander's corners are made (KiCad's MEANDER_STYLE)
public enum MeanderStyle: Int, Sendable {
    /// Rounded, a quarter of a circle
    case round = 1
    /// Chamfered, a 45 degree segment
    case chamfer
}

/// The side the meanders start on (KiCad's MEANDER_SIDE)
public enum MeanderSide: Int, Sendable {
    case left = -1
    /// The side the pointer is on
    case `default` = 0
    case right = 1
}

/// What a length tuning makes: the meanders' sizes and the length to reach (KiCad's MEANDER_SETTINGS, its length
/// domain)
public struct MeanderSettings: Sendable {
    /// The tolerance either side of a target length given alone (a tenth of a millimetre)
    public static let defaultLengthTolerance = 100_000
    /// A target length that is none (a kilometre)
    public static let lengthUnconstrained = 1_000_000 * 1_000_000
    public static let skewUnconstrained = Int(Int32.max)

    public var minAmplitude = 200_000
    public var maxAmplitude = 1_000_000
    /// The meanders' period (the dialog's spacing)
    public var spacing = 600_000
    /// What the amplitude and spacing change by, step by step
    public var step = 50_000
    public var lenPadToDie = 0
    /// The length to reach: at least `targetLength.min`, at most `targetLength.max`, `targetLength.opt` best
    public var targetLength = (min: 0, opt: lengthUnconstrained, max: lengthUnconstrained)
    /// The skew to reach, for a differential pair's skew
    public var targetSkew = (min: -defaultLengthTolerance, opt: 0, max: defaultLengthTolerance)
    public var overrideCustomRules = false
    public var cornerStyle = MeanderStyle.round
    /// The corners' radius, a percentage of the spacing (0 to 100)
    public var cornerRadiusPercentage = 80
    /// Meanders on one side of the line only
    public var singleSided = false
    /// The side the meanders start on
    public var initialSide = MeanderSide.left
    public var lengthTolerance = 0
    /// The tuned part of the line keeps the points it is cut from the rest at
    public var keepEndpoints = false

    public init() {}

    /// The length to reach, the default tolerance either side (none: anything up to a kilometre) (KiCad's
    /// SetTargetLength)
    public mutating func setTargetLength(_ opt: Int) {
        if opt == Self.lengthUnconstrained {
            targetLength = (0, opt, opt)
        } else {
            targetLength = (opt - Self.defaultLengthTolerance, opt, opt + Self.defaultLengthTolerance)
        }
    }

    /// The skew to reach, the default tolerance either side (KiCad's SetTargetSkew)
    public mutating func setTargetSkew(_ opt: Int) {
        if opt == Self.skewUnconstrained {
            targetSkew = (0, opt, opt)
        } else {
            targetSkew = (opt - Self.defaultLengthTolerance, opt, opt + Self.defaultLengthTolerance)
        }
    }
}

/// tan( 22.5° ), which a chamfered meander's corners are worked out with (KiCad's tan( DEG2RAD( 22.5 ) ))
private let tan22_5 = tan(22.5 * Double.pi / 180.0)

/// One meander's geometry (KiCad's MEANDER_SHAPE): drawn by a turtle along its base segment, on one side of it, its
/// amplitude tried from the largest down until it fits; or a dummy for a corner or an arc of the line, which the
/// meanders are fitted between
public final class MeanderShape {
    public private(set) var type = MeanderType.single
    unowned let placer: MeanderPlacerBase
    /// Two lines at an offset either side of the base (a differential pair's), or one
    public private(set) var isDual: Bool
    public let width: Int
    public private(set) var amplitude = 0
    private var baselineOffset = 0
    /// The corners' radius the shape was last drawn with (for a differential pair's chamfered corners)
    private var meanCornerRadius = 0
    /// The length of the base the shape tries to keep when resized
    private var targetBaseLen = 0
    /// Where the meander starts
    private var p0 = IPoint.zero
    private var baseSeg = Seg(.zero, .zero)
    /// The part of the base segment the meander spans
    public private(set) var baseSegment = Seg(.zero, .zero)
    /// Whether the meander is on the right of its base
    public private(set) var side = false
    /// The lines (the first only, but for a pair)
    private var shapes = [LineChain(), LineChain()]
    /// The meandered segment's index in its line
    public var baseIndex = 0
    private var currentDir = DPoint(0, 0)
    private var currentPos = DPoint(0, 0)
    /// The line the turtle draws on
    private var currentTarget = LineChain()

    init(placer: MeanderPlacerBase, width: Int, isDual: Bool = false) {
        self.placer = placer
        self.isDual = isDual
        self.width = width
    }

    private init(copying o: MeanderShape) {
        type = o.type
        placer = o.placer
        isDual = o.isDual
        width = o.width
        amplitude = o.amplitude
        baselineOffset = o.baselineOffset
        meanCornerRadius = o.meanCornerRadius
        targetBaseLen = o.targetBaseLen
        p0 = o.p0
        baseSeg = o.baseSeg
        baseSegment = o.baseSegment
        side = o.side
        shapes = o.shapes
        baseIndex = o.baseIndex
        currentDir = o.currentDir
        currentPos = o.currentPos
    }

    /// A copy of the meander (KiCad's MEANDER_SHAPE copy)
    public func copy() -> MeanderShape { MeanderShape(copying: self) }

    public func setType(_ t: MeanderType) { type = t }

    /// The meander's line (0), or its second (1, a pair's)
    public func cLine(_ shape: Int) -> LineChain { shapes[shape] }

    /// Where the meander's base ends
    public var end: IPoint { baseSegment.b }

    var settings: MeanderSettings { placer.meanderSettings }

    /// The offset of the lines from the base segment (a pair's)
    public func setBaselineOffset(_ offset: Int) { baselineOffset = offset }

    /// The length of base the meander tries to keep when it is resized
    public func setTargetBaselineLength(_ length: Int) { targetBaseLen = length }

    /// The length of its base (the least the meander can be)
    public var baselineLength: Int { baseSegment.length }

    /// The length of its line
    public var currentLength: Int { cLine(0).length }

    /// Its length at its least amplitude, keeping its base
    public var minTunableLength: Int {
        let copy = copy()
        copy.setTargetBaselineLength(baselineLength)
        copy.resize(copy.minAmplitude)
        return copy.currentLength
    }

    /// The least amplitude its corners can be made with (KiCad's MinAmplitude)
    public var minAmplitude: Int {
        var minAmplitude = settings.minAmplitude
        if placer.meanderSettings.cornerStyle == .round {
            minAmplitude = max(minAmplitude, abs(baselineOffset) + width)
        } else {
            let correction = Int(Double(width) * tan(1 - tan22_5))
            minAmplitude = max(minAmplitude, abs(baselineOffset) + correction)
        }
        return minAmplitude
    }

    /// The radius of its corners, as the settings ask and its amplitude and spacing allow (KiCad's cornerRadius)
    func cornerRadius() -> Int {
        if amplitude == 0 { return 0 }
        var minCr = 0
        if placer.meanderSettings.cornerStyle == .round {
            minCr = abs(baselineOffset) + width / 2
        } else {
            minCr = Int(Double(abs(baselineOffset)) + Double(width / 2) * (1 - tan22_5))
        }
        let maxCr1 = (amplitude + abs(baselineOffset)) / 2
        let maxCr2 = spacing() / 2
        let maxCr = min(maxCr1, maxCr2)
        // (KiCad's check, which says so and gives the largest)
        if maxCr < minCr { return maxCr }
        let rPercent = settings.cornerRadiusPercentage
        let optCr = Int(Int32(truncatingIfNeeded: spacing() * rPercent / 200))
        return min(max(optCr, minCr), maxCr)
    }

    /// The meanders' period, no less than the line's width and clearance (KiCad's spacing)
    func spacing() -> Int {
        if !isDual {
            return max(width + placer.clearance(), settings.spacing)
        }
        let sp = width + placer.clearance() + 2 * abs(baselineOffset)
        return max(sp, settings.spacing)
    }

    /// A quarter turn of radius `dir`'s length from `p`, to the right if `side` (KiCad's makeMiterShape): an arc, or
    /// a chamfer
    private func makeMiterShape(_ p: DPoint, _ dir: DPoint, _ side: Bool) -> LineChain {
        var lc = LineChain()
        if dir.norm == 0 {
            lc.append(p.truncated)
            return lc
        }
        let dirU = dir
        let dirV = dir.perpendicular
        let endPoint = p + dirU + dirV * (side ? -1.0 : 1.0)
        var q = p
        lc.append(KiMath.cInt(q.x), KiMath.cInt(q.y))
        switch placer.meanderSettings.cornerStyle {
        case .round:
            let arcEnd = IPoint(KiMath.cInt(endPoint.x), KiMath.cInt(endPoint.y))
            let arc = ShapeArc(start: p.truncated, end: arcEnd, angle: side ? -EDAAngle.a90 : EDAAngle.a90)
            lc.append(arc)
        case .chamfer:
            let radius = dir.norm
            var correction = 0.0
            if isDual && radius > Double(meanCornerRadius) {
                correction = Double(-2 * abs(baselineOffset)) * tan22_5
            }
            let dirCU = dirU.resized(correction)
            let dirCV = dirV.resized(correction)
            q = p - dirCU
            lc.append(KiMath.cInt(q.x), KiMath.cInt(q.y))
            q = p + dirU + (dirV + dirCV) * (side ? -1.0 : 1.0)
            lc.append(KiMath.cInt(q.x), KiMath.cInt(q.y))
            q = endPoint
            lc.append(KiMath.cInt(q.x), KiMath.cInt(q.y))
        }
        return lc
    }

    /// The turtle put at `where`, heading `dir`, drawing a new line (KiCad's start)
    private func start(_ at: DPoint, _ dir: DPoint) {
        currentTarget.clear()
        currentTarget.append(at.truncated)
        currentDir = dir
        currentPos = at
    }

    /// The turtle forward `length` (KiCad's forward: nothing for very short steps)
    private func forward(_ length: Int) {
        if length < 5 { return }
        currentPos = currentPos + currentDir.resized(Double(length))
        currentTarget.append(currentPos.truncated)
    }

    private func turn(_ angle: EDAAngle) {
        currentDir = KiMath.rotate(currentDir, angle)
    }

    /// A corner of radius `radius` turning the turtle a quarter turn, left if `side` (KiCad's miter)
    private func miter(_ radius: Int, _ side: Bool) {
        if radius <= 0 {
            turn(side ? .a90 : -.a90)
            return
        }
        let dir = currentDir.resized(Double(radius))
        let lc = makeMiterShape(currentPos, dir, side)
        currentPos = DPoint(lc.lastPoint)
        turn(side ? .a90 : -.a90)
        currentTarget.append(lc)
    }

    /// A U: up, across and down (KiCad's uShape)
    private func uShape(_ sides: Int, _ corner: Int, _ top: Int) {
        forward(sides)
        miter(corner, true)
        forward(top)
        miter(corner, true)
        forward(sides)
    }

    /// The meander of type `type` from `p` along `dir`, on the right of it if `side`, at `baselineOffset` from it
    /// (KiCad's genMeanderShape)
    private func genMeanderShape(_ p: DPoint, _ dir: DPoint, _ side: Bool, _ type: MeanderType, _ baselineOffset: Int = 0)
        -> LineChain {
        var cr = cornerRadius()
        var offset = baselineOffset
        let spc = spacing()
        let amplitude = self.amplitude
        let targetBaseLen = self.targetBaseLen
        if side { offset *= -1 }
        let dirUB = dir.resized(Double(offset))
        let dirVB = dirUB.perpendicular
        if 2 * cr > amplitude + abs(offset) { cr = (amplitude + abs(offset)) / 2 }
        if 2 * cr > spc { cr = spc / 2 }
        if cr - offset < 0 { cr = offset }
        meanCornerRadius = cr
        let sCorner = cr - offset
        let uCorner = cr + offset
        let startSide = amplitude - 2 * cr + abs(offset)
        let turnSide = amplitude - cr
        var top = spc - 2 * cr
        start(p + dirVB, dir)
        switch type {
        case .empty:
            currentTarget.append((p + dirVB + dir).truncated)
        case .start:
            if targetBaseLen != 0 { top = max(top, targetBaseLen - sCorner - uCorner * 2 + offset) }
            miter(sCorner, false)
            uShape(startSide, uCorner, top)
            forward(min(sCorner, uCorner))
            forward(abs(offset))
        case .finish:
            if targetBaseLen != 0 { top = max(top, targetBaseLen - cr - spc) }
            start(p - dirUB, dir)
            turn(-.a90)
            forward(min(sCorner, uCorner))
            forward(abs(offset))
            uShape(startSide, uCorner, top)
            miter(sCorner, false)
            if targetBaseLen >= spc + cr {
                currentTarget.append((p + dirVB + dir.resized(Double(targetBaseLen))).truncated)
            } else {
                currentTarget.append((p + dirVB + dir.resized(Double(2 * spc - cr))).truncated)
            }
        case .turn:
            if targetBaseLen != 0 { top = max(top, targetBaseLen - uCorner * 2 + offset * 2) }
            start(p - dirUB, dir)
            turn(-.a90)
            forward(abs(offset))
            uShape(turnSide, uCorner, top)
            forward(abs(offset))
        case .single:
            if targetBaseLen != 0 { top = max(top, (targetBaseLen - sCorner * 2 - uCorner * 2) / 2) }
            miter(sCorner, false)
            uShape(startSide, uCorner, top)
            miter(sCorner, false)
            currentTarget.append((p + dirVB + dir.resized(Double(2 * spc))).truncated)
        default:
            break
        }
        var lc = currentTarget
        currentTarget = LineChain()
        if side {
            let axis = Seg(p.truncated, (p + dir).truncated)
            lc.mirror(axis)
        }
        return lc
    }

    /// The meander of type `type` fitted at `p` on `seg`, on the right of it if `side`: the largest amplitude the
    /// settings allow that fits, down to the least, by steps (KiCad's Fit). A start or finish to check (MT_CHECK_*)
    /// fits only with the turn that would go on from it; it makes the start alone.
    @discardableResult
    public func fit(_ type: MeanderType, _ seg: Seg, _ p: IPoint, _ side: Bool) -> Bool {
        let st = settings
        var checkMode = false
        var prim1 = MeanderType.empty
        var prim2 = MeanderType.empty
        if type == .checkStart {
            prim1 = .start
            prim2 = .turn
            checkMode = true
        } else if type == .checkFinish {
            prim1 = .turn
            prim2 = .finish
            checkMode = true
        }
        if checkMode {
            let m1 = MeanderShape(placer: placer, width: width, isDual: isDual)
            let m2 = MeanderShape(placer: placer, width: width, isDual: isDual)
            m1.setBaselineOffset(baselineOffset)
            m2.setBaselineOffset(baselineOffset)
            let c1 = m1.fit(prim1, seg, p, side)
            var c2 = false
            if c1 { c2 = m2.fit(prim2, seg, m1.end, !side) }
            if c1 && c2 {
                self.type = prim1
                shapes[0] = m1.shapes[0]
                shapes[1] = m1.shapes[1]
                baseSeg = seg
                p0 = p
                self.side = side
                amplitude = m1.amplitude
                isDual = m1.isDual
                baseSeg = m1.baseSeg
                baseIndex = m1.baseIndex
                updateBaseSegment()
                baselineOffset = m1.baselineOffset
                return true
            }
            return false
        }
        let minAmpl = minAmplitude
        let maxAmpl = max(st.maxAmplitude, minAmpl)
        // (the least corner radius that rounds a corner visibly: half the track's width)
        let minCornerRadius = width / 2
        var ampl = maxAmpl
        while ampl >= minAmpl {
            defer { ampl -= st.step }
            amplitude = ampl
            if isDual {
                shapes[0] = genMeanderShape(DPoint(p), DPoint(seg.b - seg.a), side, type, baselineOffset)
                shapes[1] = genMeanderShape(DPoint(p), DPoint(seg.b - seg.a), side, type, -baselineOffset)
            } else {
                shapes[0] = genMeanderShape(DPoint(p), DPoint(seg.b - seg.a), side, type, 0)
            }
            self.type = type
            baseSeg = seg
            p0 = p
            self.side = side
            updateBaseSegment()
            // (corners all but square refused, KiCad's issue #8629)
            if meanCornerRadius < minCornerRadius { continue }
            if placer.checkFit(self) { return true }
        }
        return false
    }

    /// The line drawn again from its settings (KiCad's Recalculate)
    public func recalculate() {
        shapes[0] = genMeanderShape(DPoint(p0), DPoint(baseSeg.b - baseSeg.a), side, type, isDual ? baselineOffset : 0)
        if isDual {
            shapes[1] = genMeanderShape(DPoint(p0), DPoint(baseSeg.b - baseSeg.a), side, type, -baselineOffset)
        }
        updateBaseSegment()
    }

    /// The meander at amplitude `ampl`, no less than its corners allow (KiCad's Resize)
    public func resize(_ ampl: Int) {
        if ampl < 0 { return }
        let minAmpl = minAmplitude
        amplitude = max(ampl, minAmpl)
        recalculate()
    }

    /// The meander made a straight line along its base (KiCad's MakeEmpty)
    public func makeEmpty() {
        updateBaseSegment()
        let dir = baseSegment.b - baseSegment.a
        type = .empty
        amplitude = 0
        shapes[0] = genMeanderShape(DPoint(p0), DPoint(dir), side, type, isDual ? baselineOffset : 0)
        if isDual {
            shapes[1] = genMeanderShape(DPoint(p0), DPoint(dir), side, type, -baselineOffset)
        }
    }

    /// A dummy for a corner of the line, at `p1` (and `p2`, a pair's other line's) (KiCad's MakeCorner)
    func makeCorner(_ p1: IPoint, _ p2: IPoint = .zero) {
        setType(.corner)
        shapes[0].clear()
        shapes[1].clear()
        shapes[0].append(p1)
        shapes[1].append(p2)
        baseSegment = Seg(p1, p1)
    }

    /// A dummy for an arc of the line (and of a pair's other line) (KiCad's MakeArc)
    func makeArc(_ arc1: ShapeArc, _ arc2: ShapeArc) {
        setType(.corner)
        shapes[0].clear()
        shapes[1].clear()
        shapes[0].append(arc1)
        shapes[1].append(arc2)
        baseSegment = Seg(arc1.end, arc1.end)
    }

    /// The part of the base the line spans, its ends (a pair's lines' midpoints) projected on it (KiCad's
    /// updateBaseSegment)
    private func updateBaseSegment() {
        if isDual {
            let midpA = (cLine(0).point(0) + cLine(1).point(0)).divided(by: 2)
            let midpB = (cLine(0).lastPoint + cLine(1).lastPoint).divided(by: 2)
            baseSegment = Seg(baseSeg.lineProject(midpA), baseSeg.lineProject(midpB))
        } else {
            baseSegment = Seg(baseSeg.lineProject(cLine(0).point(0)), baseSeg.lineProject(cLine(0).lastPoint))
        }
    }
}

/// The meanders fitted along a line or a pair of lines (KiCad's MEANDERED_LINE): its corners and arcs, and the
/// meanders on its segments, in order
public final class MeanderedLine {
    private var last = IPoint.zero
    unowned let placer: MeanderPlacerBase
    public private(set) var meanders: [MeanderShape] = []
    private let isDual: Bool
    public var width = 0
    public var baselineOffset = 0

    init(placer: MeanderPlacerBase, isDual: Bool = false) {
        self.placer = placer
        self.isDual = isDual
    }

    var settings: MeanderSettings { placer.meanderSettings }

    /// The meanders of the largest amplitude that fit, along `base` from its start, beginning on its right if
    /// `side`: turning from side to side where three periods are left, else single ones, stepping on where none fits
    /// (KiCad's MeanderSegment)
    public func meanderSegment(_ base: Seg, _ side: Bool, baseIndex: Int = 0) {
        let baseLen = Double(base.length)
        let singleSided = settings.singleSided
        var side = side
        let dir = DPoint(base.b - base.a)
        if !isDual { addCorner(base.a) }
        var turning = false
        var started = false
        last = base.a
        repeat {
            let m = MeanderShape(placer: placer, width: width, isDual: isDual)
            m.setBaselineOffset(baselineOffset)
            m.baseIndex = baseIndex
            let thr = Double(m.spacing())
            var fail = false
            var remaining = baseLen - Double((last - base.a).norm)
            func flipInitialSide() {
                var settings = placer.meanderSettings
                settings.initialSide = MeanderSide(rawValue: -settings.initialSide.rawValue)!
                placer.updateSettings(settings)
            }
            func addSingleIfFits() {
                fail = true
                if m.fit(.single, base, last, side) {
                    addMeander(m.copy())
                    fail = false
                    started = false
                }
                if fail && !singleSided {
                    if m.fit(.single, base, last, !side) {
                        if !started { flipInitialSide() }
                        addMeander(m.copy())
                        fail = false
                        started = false
                        side = !side
                    }
                }
            }
            if remaining < Double(settings.step) { break }
            if !singleSided && remaining > 3.0 * thr {
                if !turning {
                    for i in 0..<2 {
                        let checkSide = i == 0 ? side : !side
                        if m.fit(.checkStart, base, last, checkSide) {
                            if !started && checkSide != side { flipInitialSide() }
                            turning = true
                            addMeander(m.copy())
                            side = !checkSide
                            started = true
                            break
                        }
                    }
                    if !turning { addSingleIfFits() }
                } else {
                    let rv = m.fit(.checkFinish, base, last, side)
                    if rv {
                        m.fit(.turn, base, last, side)
                        addMeander(m.copy())
                        side = !side
                        started = true
                    } else {
                        m.fit(.finish, base, last, side)
                        started = false
                        addMeander(m.copy())
                        turning = false
                    }
                }
            } else if !singleSided && started {
                let rv = m.fit(.finish, base, last, side)
                if rv { addMeander(m.copy()) }
                break
            } else if !turning && remaining > thr * 2.0 {
                addSingleIfFits()
            } else {
                fail = true
            }
            remaining = baseLen - Double((last - base.a).norm)
            if remaining < Double(settings.step) { break }
            if fail {
                let tmp = MeanderShape(placer: placer, width: width, isDual: isDual)
                tmp.setBaselineOffset(baselineOffset)
                tmp.baseIndex = baseIndex
                let nextP = tmp.spacing() - 2 * tmp.cornerRadius() + settings.step
                let pn = (DPoint(last) + dir.resized(Double(nextP))).truncated
                if base.contains(pn) && !isDual {
                    addCorner(pn)
                } else {
                    break
                }
            }
        } while true
        if !isDual { addCorner(base.b) }
    }

    /// Whether `shape` keeps `clearance` from the meanders already on the line, those on bases at an angle to its
    /// own (KiCad's CheckSelfIntersections)
    public func checkSelfIntersections(_ shape: MeanderShape, _ clearance: Int) -> Bool {
        for m in meanders.reversed() {
            if m.type == .empty || m.type == .corner { continue }
            let b1 = shape.baseSegment
            let b2 = m.baseSegment
            if b1.approxParallel(b2) { continue }
            let line = m.cLine(0)
            for j in stride(from: line.segmentCount - 1, through: 0, by: -1) {
                if shape.cLine(0).collide(line.segment(j), clearance: clearance) { return false }
            }
        }
        return true
    }

    /// A dummy meander for a corner at `a` (and `b`, a pair's other line's) (KiCad's AddCorner)
    public func addCorner(_ a: IPoint, _ b: IPoint = .zero) {
        let m = MeanderShape(placer: placer, width: width, isDual: isDual)
        m.makeCorner(a, b)
        last = a
        meanders.append(m)
    }

    /// A dummy meander for an arc of the line (and of a pair's other line) (KiCad's AddArc)
    public func addArc(_ arc1: ShapeArc, _ arc2: ShapeArc = ShapeArc()) {
        let m = MeanderShape(placer: placer, width: width, isDual: isDual)
        m.makeArc(arc1, arc2)
        last = arc1.end
        meanders.append(m)
    }

    /// An arc of one line, a point of the other (KiCad's AddArcAndPt)
    public func addArcAndPt(_ arc1: ShapeArc, _ pt2: IPoint) {
        addArc(arc1, ShapeArc(start: pt2, mid: pt2, end: pt2))
    }

    /// A point of one line, an arc of the other (KiCad's AddPtAndArc)
    public func addPtAndArc(_ pt1: IPoint, _ arc2: ShapeArc) {
        addArc(ShapeArc(start: pt1, mid: pt1, end: pt1), arc2)
    }

    public func addMeander(_ shape: MeanderShape) {
        last = shape.baseSegment.b
        meanders.append(shape)
    }

    public func clear() { meanders.removeAll() }
}
