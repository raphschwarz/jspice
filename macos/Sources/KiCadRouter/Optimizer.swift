// Ported from KiCad 10.0.7: pcbnew/router/pns_optimizer.h and pns_optimizer.cpp (single tracks, and differential
// pairs' segments merged), and the rotation and angles of libs/kimath/src/trigo.cpp and
// libs/kimath/include/geometry/eda_angle.h.
// Copyright (C) 2013-2014 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

extension KiMath {
    /// KiCad's RotatePoint for an EDA_ANGLE in degrees: exact on the quarter turns, sin and cos exact on the eighths
    public static func rotate(_ p: IPoint, degrees: Double) -> IPoint { rotate(p, EDAAngle(degrees: degrees)) }

    public static func rotate(_ p: IPoint, around c: IPoint, degrees: Double) -> IPoint { rotate(p - c, degrees: degrees) + c }

    /// KiCad's EDA_ANGLE of a vector, in degrees: exact along the axes and diagonals
    public static func angleDegrees(_ v: IPoint) -> Double { EDAAngle(v).degrees }

    static func normalize180(_ a: Double) -> Double {
        var a = a
        while a <= -180 { a += 360 }
        while a > 180 { a -= 360 }
        return a
    }
}

extension Seg {
    /// KiCad's SEG::Angle: the angle between the segments' directions, 0 to 180 degrees
    public func angleDegrees(_ o: Seg) -> Double {
        let a = KiMath.normalize180(KiMath.angleDegrees(self.a - b))
        let c = KiMath.normalize180(KiMath.angleDegrees(o.a - o.b))
        return abs(KiMath.normalize180(a - c))
    }
}

/// A line's cost: its length and its corners (KiCad's COST_ESTIMATOR)
public struct CostEstimator {
    public private(set) var lengthCost = 0.0
    public private(set) var cornerCost = 0

    public init() {}

    public static func cornerCost(_ a: Seg, _ b: Seg) -> Int {
        switch Direction45(a).angle(Direction45(b)) {
        case .obtuse: return 10
        case .straight: return 5
        case .acute: return 50
        case .right: return 30
        case .halfFull: return 60
        default: return 100
        }
    }

    public static func cornerCost(_ line: LineChain) -> Int {
        var total = 0
        var i = 0
        while i < line.segmentCount - 1 {
            total += cornerCost(line.segment(i), line.segment(i + 1))
            i += 1
        }
        return total
    }

    public static func cornerCost(_ line: Line) -> Int { cornerCost(line.cLine) }

    public mutating func add(_ line: Line) {
        lengthCost += Double(line.cLine.length)
        cornerCost += CostEstimator.cornerCost(line)
    }

    public mutating func remove(_ line: Line) {
        lengthCost -= Double(line.cLine.length)
        cornerCost -= CostEstimator.cornerCost(line)
    }

    public mutating func replace(_ old: Line, _ new: Line) {
        remove(old)
        add(new)
    }

    public func isBetter(_ other: CostEstimator, lengthTolerance: Double, cornerTolerance: Double) -> Bool {
        if other.cornerCost < cornerCost && other.lengthCost < lengthCost { return true }
        if Double(other.cornerCost) < Double(cornerCost) * cornerTolerance && other.lengthCost < lengthCost * lengthTolerance { return true }
        return false
    }
}

/// What a change the optimizer tries must keep to (KiCad's OPT_CONSTRAINT)
protocol OptimizerConstraint {
    func check(_ v1: Int, _ v2: Int, _ originLine: Line, _ currentPath: LineChain, _ replacement: LineChain) -> Bool
}

/// Straightens and smooths a routed line without its coming too close to anything (KiCad's OPTIMIZER)
public final class Optimizer {
    public struct Effort: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// Corners taken out, step by step
        public static let mergeSegments = Effort(rawValue: 0x01)
        /// Pad exits rerouted
        public static let smartPads = Effort(rawValue: 0x02)
        /// Obtuse corners merged
        public static let mergeObtuse = Effort(rawValue: 0x04)
        /// Short pad to pad and pad to via connections made straight
        public static let fanoutCleanup = Effort(rawValue: 0x08)
        public static let keepTopology = Effort(rawValue: 0x10)
        public static let preserveVertex = Effort(rawValue: 0x20)
        public static let restrictVertexRange = Effort(rawValue: 0x40)
        public static let mergeColinear = Effort(rawValue: 0x80)
        public static let restrictArea = Effort(rawValue: 0x100)
        public static let limitCornerCount = Effort(rawValue: 0x200)
    }

    var world: Node
    public var collisionKindMask: ItemKind = .any
    public var effortLevel: Effort = .mergeSegments
    private var preservedVertex = IPoint.zero
    private var restrictedVertexRange = (0, 0)
    private var restrictArea = IBox(minX: 0, minY: 0, maxX: 0, maxY: 0)
    private var restrictAreaIsStrict = false
    private var constraints: [OptimizerConstraint] = []

    public init(world: Node) { self.world = world }

    public func setWorld(_ node: Node) { world = node }

    public func setPreserveVertex(_ v: IPoint) {
        preservedVertex = v
        effortLevel.insert(.preserveVertex)
    }

    public func setRestrictVertexRange(_ start: Int, _ end: Int) {
        restrictedVertexRange = (start, end)
        effortLevel.insert(.restrictVertexRange)
    }

    public func setRestrictArea(_ area: IBox, strict: Bool = true) {
        restrictArea = area
        restrictAreaIsStrict = strict
        effortLevel.insert(.restrictArea)
    }

    public func clearCache(staticOnly: Bool = false) {}
    public func cacheRemove(_ item: Item) {}

    // MARK: - Constraints

    struct AreaConstraint: OptimizerConstraint {
        let allowedArea: IBox

        func check(_ v1: Int, _ v2: Int, _ originLine: Line, _ currentPath: LineChain, _ replacement: LineChain) -> Bool {
            let p1 = currentPath.point(v1), p2 = currentPath.point(v2)
            let p1In = allowedArea.contains(p1), p2In = allowedArea.contains(p2)
            if p1In && p2In { return true }
            if v1 < currentPath.pointCount - 1 && !p1In && p2In && allowedArea.contains(currentPath.point(v1 + 1)) {
                let a = replacement.segment(0).angleDegrees(currentPath.segment(v1))
                return a == 0 || a == 180
            }
            if p1In && !p2In && allowedArea.contains(currentPath.point(v2 - 1)) {
                let a = replacement.segment(-1).angleDegrees(currentPath.segment(v2 - 1))
                return a == 0 || a == 180
            }
            return false
        }
    }

    struct PreserveVertexConstraint: OptimizerConstraint {
        let v: IPoint

        func check(_ v1: Int, _ v2: Int, _ originLine: Line, _ currentPath: LineChain, _ replacement: LineChain) -> Bool {
            var cv = false
            var i = v1
            while i < v2 {
                if currentPath.segment(i).squaredDistance(v) <= 1 {
                    cv = true
                    break
                }
                i += 1
            }
            if !cv { return true }
            for i in 0..<replacement.segmentCount where replacement.segment(i).squaredDistance(v) <= 1 { return true }
            return false
        }
    }

    struct RestrictVertexRangeConstraint: OptimizerConstraint {
        func check(_ v1: Int, _ v2: Int, _ originLine: Line, _ currentPath: LineChain, _ replacement: LineChain) -> Bool { true }
    }

    struct CornerCountLimitConstraint: OptimizerConstraint {
        let minCorners: Int
        let angleMask: Direction45.AngleType

        func check(_ v1: Int, _ v2: Int, _ originLine: Line, _ currentPath: LineChain, _ replacement: LineChain) -> Bool {
            // (KiCad counts the corners and lets every replacement through)
            true
        }
    }

    /// KiCad's pointInside2: inside a closed polygon, its boundary included
    static func pointInside2(_ l: LineChain, _ p: IPoint) -> Bool {
        if !l.isClosed || l.segmentCount < 3 { return false }
        var result = 0
        let cnt = l.pointCount
        var ip = l.point(0)
        for i in 1...cnt {
            let ipNext = i == cnt ? l.point(0) : l.point(i)
            if ipNext.y == p.y {
                if ipNext.x == p.x || (ip.y == p.y && ((ipNext.x > p.x) == (ip.x < p.x))) { return true }
            }
            if (ip.y < p.y) != (ipNext.y < p.y) {
                if ip.x >= p.x {
                    if ipNext.x > p.x {
                        result = 1 - result
                    } else {
                        let d = Double(ip.x - p.x) * Double(ipNext.y - p.y) - Double(ipNext.x - p.x) * Double(ip.y - p.y)
                        if d == 0 { return true }
                        if (d > 0) == (ipNext.y > ip.y) { result = 1 - result }
                    }
                } else if ipNext.x > p.x {
                    let d = Double(ip.x - p.x) * Double(ipNext.y - p.y) - Double(ipNext.x - p.x) * Double(ip.y - p.y)
                    if d == 0 { return true }
                    if (d > 0) == (ipNext.y > ip.y) { result = 1 - result }
                }
            }
            ip = ipNext
        }
        return result > 0
    }

    struct KeepTopologyConstraint: OptimizerConstraint {
        let world: Node

        func check(_ v1: Int, _ v2: Int, _ originLine: Line, _ currentPath: LineChain, _ replacement: LineChain) -> Bool {
            var encPoly = originLine.cLine.slice(v1, v2)
            encPoly.append(replacement.reversed())
            encPoly.setClosed(true)
            let joints = world.queryJoints(encPoly.bbox, layers: originLine.layers, kinds: .solid)
            if joints.isEmpty { return true }
            for j in joints where j.net != originLine.net {
                if Optimizer.pointInside2(encPoly, j.pos) {
                    let falsePositive = encPoly.points.contains(j.pos)
                    if !falsePositive { return false }
                }
            }
            return true
        }
    }

    private func checkConstraints(_ v1: Int, _ v2: Int, _ originLine: Line, _ currentPath: LineChain, _ replacement: LineChain) -> Bool {
        for c in constraints where !c.check(v1, v2, originLine, currentPath, replacement) { return false }
        return true
    }

    private func checkColliding(_ item: Item) -> Bool { world.checkColliding(item) != nil }

    private func checkColliding(_ line: Line, _ optPath: LineChain) -> Bool { checkColliding(Line(line, optPath)) }

    // MARK: - Merging

    private func mergeObtuse(_ aLine: Line) -> Bool {
        let line = aLine.cLine
        var step = line.pointCount - 3
        let segsPre = line.segmentCount
        if step < 0 { return false }
        var currentPath = line
        while true {
            var nSegs = currentPath.segmentCount
            let maxStep = nSegs - 2
            if step > maxStep { step = maxStep }
            if step < 2 {
                aLine.setLine(currentPath)
                return currentPath.segmentCount < segsPre
            }
            var foundAnything = false
            var n = 0
            while n < nSegs - step {
                let s1 = currentPath.segment(n), s2 = currentPath.segment(n + step)
                if Direction45(s1).isObtuse(Direction45(s2)), let ip = s1.intersectLines(s2) {
                    let s1opt = Seg(s1.a, ip), s2opt = Seg(ip, s2.b)
                    if Direction45(s1opt).isObtuse(Direction45(s2opt)) {
                        let optTrack = Line(aLine, LineChain([s1opt.a, s1opt.b, s2opt.b].reduce(into: [IPoint]()) { if $0.last != $1 { $0.append($1) } }))
                        if !checkColliding(optTrack) {
                            currentPath.replace(s1.index + 1, s2.index, with: ip)
                            nSegs = currentPath.segmentCount
                            foundAnything = true
                            break
                        }
                    }
                }
                n += 1
            }
            if !foundAnything {
                if step <= 2 {
                    aLine.setLine(currentPath)
                    return currentPath.segmentCount < segsPre
                }
                step -= 1
            }
        }
    }

    private func mergeFull(_ aLine: Line) -> Bool {
        var line = aLine.cLine
        var step = line.segmentCount - 1
        let segsPre = line.segmentCount
        line.simplify2()
        aLine.setLine(line)
        if step < 0 { return false }
        var currentPath = line
        while true {
            let nSegs = currentPath.segmentCount
            let maxStep = nSegs - 2
            if step > maxStep { step = maxStep }
            if step < 1 { break }
            let found = mergeStep(aLine, &currentPath, step)
            if !found { step -= 1 }
            if step == 0 { break }
        }
        aLine.setShape(currentPath)
        return currentPath.segmentCount < segsPre
    }

    private func mergeColinear(_ aLine: Line) -> Bool {
        var line = aLine.cLine
        let nSegs = line.segmentCount
        var segIdx = 0
        while segIdx < line.segmentCount - 1 {
            let s1 = line.segment(segIdx), s2 = line.segment(segIdx + 1)
            // (segments of no length, where arcs meet, passed by; an arc's points kept)
            if s1.squaredLength != 0 && s2.squaredLength != 0 && s1.collinear(s2) && !line.isPointOnArc(segIdx + 1) {
                line.remove(segIdx + 1)
            }
            segIdx += 1
        }
        aLine.setLine(line)
        return line.segmentCount < nSegs
    }

    private func mergeStep(_ aLine: Line, _ currentPath: inout LineChain, _ step: Int) -> Bool {
        let nSegs = currentPath.segmentCount
        let costOrig = CostEstimator.cornerCost(currentPath)
        if aLine.segmentCount < 2 { return false }
        let cornerMode = Router.instance?.settings.cornerMode ?? .mitered45
        var n = 0
        while n < nSegs - step {
            // (no merging the segments that are pieces of an arc)
            if currentPath.isArcSegment(n) || currentPath.isArcSegment(n + step) {
                n += 1
                continue
            }
            let s1 = currentPath.segment(n), s2 = currentPath.segment(n + step)
            var path = [LineChain(), LineChain()]
            var cost = [Int(Int32.max), Int(Int32.max)]
            for i in 0..<2 {
                let bypass = Direction45().buildInitialTrace(s1.a, s2.b, startDiagonal: i == 1, mode: cornerMode)
                var ok = false
                if !checkColliding(aLine, bypass) { ok = checkConstraints(n, n + step + 1, aLine, currentPath, bypass) }
                if ok {
                    path[i] = currentPath
                    path[i].replace(s1.index, s2.index, with: bypass)
                    path[i].simplify2()
                    cost[i] = CostEstimator.cornerCost(path[i])
                }
            }
            var picked: LineChain?
            if cost[0] < costOrig && cost[0] < cost[1] {
                picked = path[0]
            } else if cost[1] < costOrig {
                picked = path[1]
            }
            if let picked {
                currentPath = picked
                return true
            }
            n += 1
        }
        return false
    }

    // MARK: - Pad exits

    private func circleBreakouts(_ width: Int, _ center: IPoint, _ radius: Int) -> [LineChain] {
        var breakouts: [LineChain] = []
        var angle = 0.0
        while angle < 360 {
            let v0 = KiMath.rotate(IPoint(Int(Double(radius) * 2.0.squareRoot()), 0), degrees: -angle)
            breakouts.append(LineChain([center, center + v0]))
            angle += 45
        }
        return breakouts
    }

    private func customBreakouts(_ width: Int, _ item: Item, _ convex: LineChain, _ permitDiagonal: Bool) -> [LineChain] {
        var breakouts: [LineChain] = []
        let bbox = convex.bbox
        let p0 = (item as! Solid).pos
        // (long enough to cross the polygon)
        let length = max(bbox.width, bbox.height) / 2 + 5
        let increment = permitDiagonal ? 45.0 : 90.0
        var angle = 0.0
        while angle < 360 {
            let v0 = KiMath.rotate(p0 + IPoint(length, 0), around: p0, degrees: -angle)
            let intersections = convex.intersect(Seg(p0, v0))
            if let first = intersections.first { breakouts.append(LineChain([p0, first.p])) }
            angle += increment
        }
        return breakouts
    }

    private func rectBreakouts(_ width: Int, _ rect: IBox, _ permitDiagonal: Bool) -> [LineChain] {
        let s = IPoint(rect.width, rect.height)
        let c = IPoint(rect.minX, rect.minY) + IPoint(s.x / 2, s.y / 2)
        var breakouts: [LineChain] = []
        let dOffset = IPoint(s.x > s.y ? (s.x - s.y) / 2 : 0, s.x < s.y ? (s.y - s.x) / 2 : 0)
        let dVert = IPoint(0, s.y / 2 + width), dHoriz = IPoint(s.x / 2 + width, 0)
        breakouts.append(LineChain([c, c + dHoriz]))
        breakouts.append(LineChain([c, c - dHoriz]))
        breakouts.append(LineChain([c, c + dVert]))
        breakouts.append(LineChain([c, c - dVert]))
        if permitDiagonal {
            let l = width + min(s.x, s.y) / 2
            // (KiCad makes these from a list of points as they are: a square pad's have its centre twice, and the
            // segment of no length between makes a corner the pad exit check then refuses)
            func chain(_ pts: [IPoint]) -> LineChain { LineChain(pts) }
            if s.x >= s.y {
                breakouts.append(chain([c, c + dOffset, c + dOffset + IPoint(l, l)]))
                breakouts.append(chain([c, c + dOffset, c + dOffset - IPoint(-l, l)]))
                breakouts.append(chain([c, c - dOffset, c - dOffset + IPoint(-l, l)]))
                breakouts.append(chain([c, c - dOffset, c - dOffset - IPoint(l, l)]))
            } else {
                breakouts.append(chain([c, c + dOffset, c + dOffset + IPoint(l, l)]))
                breakouts.append(chain([c, c - dOffset, c - dOffset - IPoint(-l, l)]))
                breakouts.append(chain([c, c + dOffset, c + dOffset + IPoint(-l, l)]))
                breakouts.append(chain([c, c - dOffset, c - dOffset - IPoint(l, l)]))
            }
        }
        return breakouts
    }

    private func computeBreakouts(_ width: Int, _ item: Item, _ permitDiagonal: Bool) -> [LineChain] {
        if let via = item as? Via { return circleBreakouts(width, via.pos, via.diameter / 2) }
        guard item.kind == .solid, let shape = item.shape(-1) else { return [] }
        switch shape {
        case .rect(let b): return rectBreakouts(width, b, permitDiagonal)
        case .segment(let s, let w):
            // KiCad's ApproximateSegmentAsRect
            let delta = IPoint(w / 2, w / 2)
            let p0 = s.a - delta, p1 = s.b + delta
            return rectBreakouts(width, IBox(minX: min(p0.x, p1.x), minY: min(p0.y, p1.y), maxX: min(p0.x, p1.x) + abs(p1.x - p0.x),
                                             maxY: min(p0.y, p1.y) + abs(p1.y - p0.y)), permitDiagonal)
        case .circle(let c, let r): return circleBreakouts(width, c, r)
        case .simple(let l): return customBreakouts(width, item, l, permitDiagonal)
        case .chain, .arc: return []
        }
    }

    private func findPadOrVia(_ layer: Int, _ net: NetHandle?, _ p: IPoint) -> Item? {
        world.findJoint(p, layer: layer, net: net)?.links.first { $0.ofKind([.via, .solid]) }
    }

    private func smartPadsSingle(_ aLine: Line, _ pad: Item, _ atEnd: Bool, _ endVertex: Int) -> Int {
        let dir = Direction45()
        let forbidden: Direction45.AngleType = [.acute, .right, .halfFull, .undefined]
        var variants: [(Int, Int, LineChain)] = []
        let solid = pad as? Solid
        // (not offset pads; not vias, whose exits the router leaves as they are meant)
        if let solid, solid.offset != .zero { return -1 }
        if pad.kind == .via { return -1 }
        let breakouts = computeBreakouts(aLine.width, pad, true)
        let line = atEnd ? aLine.cLine.reversed() : aLine.cLine
        let pEnd = min(endVertex, min(3, line.pointCount - 1))
        if pEnd >= 1 {
            for p in 1...pEnd {
                // a line inside the pad left as it is
                if let solid, let s = solid.shape(-1), !s.collide(.segment(Seg(line.point(0), line.point(p)), width: 0), clearance: aLine.width / 2) {
                    continue
                }
                for breakout in breakouts {
                    for diag in 0..<2 {
                        let connect = dir.buildInitialTrace(breakout.lastPoint, line.point(p), startDiagonal: diag == 0)
                        let dirBreakout = Direction45(breakout.segment(-1))
                        if connect.segmentCount == 0 { continue }
                        let ang1 = dirBreakout.angle(Direction45(connect.segment(0)))
                        if !ang1.intersection(forbidden).isEmpty { continue }
                        if breakout.length > line.length { continue }
                        var v = breakout
                        v.append(connect)
                        var i = p + 1
                        while i < line.pointCount {
                            v.append(line.point(i))
                            i += 1
                        }
                        let tmp = Line(aLine, v)
                        if tmp.countCorners(forbidden) == 0 {
                            var chosen = atEnd ? v.reversed() : v
                            chosen.simplify2()
                            variants.append((p, breakout.length, chosen))
                        }
                    }
                }
            }
        }
        // the least corner cost, and of two as good the longer pad exit (an oblong pad's track leaving along it)
        var minCost = CostEstimator.cornerCost(aLine)
        var maxLength = 0
        var found = false
        var pBest = -1
        var lBest = LineChain()
        for vp in variants {
            let tmp = Line(aLine, vp.2)
            let cost = CostEstimator.cornerCost(vp.2)
            let len = vp.1
            if !checkColliding(tmp) {
                if cost < minCost || (cost == minCost && len > maxLength) {
                    lBest = vp.2
                    pBest = vp.0
                    found = true
                    if cost <= minCost { maxLength = max(len, maxLength) }
                    minCost = min(cost, minCost)
                }
            }
        }
        if found {
            aLine.setShape(lBest)
            return pBest
        }
        return -1
    }

    private func runSmartPads(_ aLine: Line) -> Bool {
        let line = aLine.cLine
        if line.pointCount < 3 { return false }
        let pStart = line.point(0), pEnd = line.lastPoint
        let startPad = findPadOrVia(aLine.layer, aLine.net, pStart)
        let endPad = findPadOrVia(aLine.layer, aLine.net, pEnd)
        var vtx = -1
        if let startPad { vtx = smartPadsSingle(aLine, startPad, false, 3) }
        if let endPad {
            let n = aLine.cLine.pointCount
            _ = smartPadsSingle(aLine, endPad, true, vtx < 0 ? n - 1 : n - 1 - vtx)
        }
        var simplified = aLine.cLine
        simplified.simplify2()
        aLine.setLine(simplified)
        return true
    }

    private func fanoutCleanup(_ aLine: Line) -> Bool {
        if aLine.pointCount < 3 { return false }
        let cornerMode = Router.instance?.settings.cornerMode ?? .mitered45
        let pStart = aLine.cPoint(0), pEnd = aLine.cLastPoint
        guard let startPad = findPadOrVia(aLine.layer, aLine.net, pStart) else { return false }
        let endPad = findPadOrVia(aLine.layer, aLine.net, pEnd)
        let thr = aLine.width * 10
        let len = aLine.cLine.length
        let startMatch = startPad.ofKind([.via, .solid])
        let endMatch = endPad.map { $0.ofKind([.via, .solid]) } ?? (aLine.via != nil)
        if startMatch && endMatch && len < thr {
            for i in 0..<2 {
                let l2 = Direction45().buildInitialTrace(pStart, pEnd, startDiagonal: i == 1, mode: cornerMode)
                let repl = Line(aLine, l2)
                if world.checkColliding(repl) == nil {
                    aLine.setShape(repl.cLine)
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Optimizing

    /// `line` optimized into `result` (its links let go): KiCad's OPTIMIZER::Optimize
    @discardableResult
    public func optimize(_ line: Line, _ result: Line, root: Line? = nil) -> Bool {
        result.assign(line)
        result.clearLinks()
        var rv = false
        if effortLevel.contains(.limitCornerCount), let root {
            constraints.append(CornerCountLimitConstraint(minCorners: root.countCorners(.obtuse), angleMask: .obtuse))
        }
        if effortLevel.contains(.preserveVertex) { constraints.append(PreserveVertexConstraint(v: preservedVertex)) }
        if effortLevel.contains(.restrictVertexRange) { constraints.append(RestrictVertexRangeConstraint()) }
        if effortLevel.contains(.restrictArea) { constraints.append(AreaConstraint(allowedArea: restrictArea)) }
        if effortLevel.contains(.keepTopology) { constraints.append(KeepTopologyConstraint(world: world)) }
        // (a line with arcs only has its collinear segments merged: KiCad's other steps are yet to be made right for
        // arcs)
        let hasArcs = line.cLine.arcCount > 0
        if !hasArcs && effortLevel.contains(.mergeSegments) { rv = mergeFull(result) || rv }
        if !hasArcs && effortLevel.contains(.mergeObtuse) { rv = mergeObtuse(result) || rv }
        if effortLevel.contains(.mergeColinear) { rv = mergeColinear(result) || rv }
        if !hasArcs && effortLevel.contains(.smartPads) { rv = runSmartPads(result) || rv }
        if !hasArcs && effortLevel.contains(.fanoutCleanup) { rv = fanoutCleanup(result) || rv }
        return rv
    }

    /// KiCad's static OPTIMIZER::Optimize: `line` optimized in place
    @discardableResult
    public static func optimize(_ line: Line, effort: Effort, world: Node, preserving v: IPoint = .zero) -> Bool {
        let opt = Optimizer(world: world)
        opt.effortLevel = effort
        opt.collisionKindMask = .any
        if effort.contains(.preserveVertex) { opt.setPreserveVertex(v) }
        let tmp = line.copy()
        return opt.optimize(tmp, line)
    }
}

// MARK: - Differential pairs

extension Optimizer {
    /// The pair's corners taken out where its lines stay coupled (KiCad's OPTIMIZER::Optimize for a DIFF_PAIR)
    @discardableResult
    public func optimize(_ pair: DiffPair) -> Bool { mergeDpSegments(pair) }

    /// The indices of the segments of `coupled` parallel to `origSeg` and the pair's gap from `vertex` (KiCad's
    /// findCoupledVertices)
    private static func findCoupledVertices(_ vertex: IPoint, _ origSeg: Seg, _ coupled: LineChain, _ pair: DiffPair) -> [Int] {
        var indices: [Int] = []
        for i in 0..<coupled.segmentCount {
            let s = coupled.segment(i)
            let projOverCoupled = s.lineProject(vertex)
            if s.approxParallel(origSeg) {
                let dist = (projOverCoupled - vertex).norm - pair.width
                if pair.gapConstraint.matches(dist) { indices.append(i) }
            }
        }
        return indices
    }

    /// Whether the pair's lines on these paths clear each other and everything in `node` (KiCad's verifyDpBypass)
    private static func verifyDpBypass(_ node: Node, _ pair: DiffPair, _ refIsP: Bool, _ newRef: LineChain,
                                       _ newCoupled: LineChain) -> Bool {
        let refLine = Line(refIsP ? pair.pLine() : pair.nLine(), newRef)
        let coupledLine = Line(refIsP ? pair.nLine() : pair.pLine(), newCoupled)
        if refLine.collide(coupledLine, node, layer: refLine.layer) { return false }
        if node.checkColliding(refLine) != nil { return false }
        if node.checkColliding(coupledLine) != nil { return false }
        return true
    }

    /// The coupled line given a bypass alongside the reference line's `refBypass`, from one of its vertices the gap
    /// from the bypass's start to each other vertex of it, the one that stays coupled longest and clears everything
    /// (KiCad's coupledBypass)
    private static func coupledBypass(_ node: Node, _ pair: DiffPair, _ refIsP: Bool, _ ref: LineChain, _ refBypass: LineChain,
                                      _ coupled: LineChain) -> LineChain? {
        let vStartIdx = findCoupledVertices(refBypass.point(0), refBypass.segment(0), coupled, pair)
        let dir = Direction45(refBypass.segment(0))
        var bestLength = -1
        var bestBypass: LineChain?
        for start in vStartIdx {
            for j in stride(from: 1, to: coupled.pointCount - 1, by: 1) where abs(start - j) > 1 {
                let vs = coupled.point(start)
                let bypass = dir.buildInitialTrace(vs, coupled.point(j), startDiagonal: dir.isDiagonal)
                let coupledLength = pair.coupledLength(ref, bypass)
                var newCoupled = coupled
                if start < j {
                    newCoupled.replace(start, j, with: bypass)
                } else {
                    newCoupled.replace(j, start, with: bypass.reversed())
                }
                if coupledLength > bestLength && verifyDpBypass(node, pair, refIsP, ref, newCoupled) {
                    bestBypass = newCoupled
                    bestLength = coupledLength
                }
            }
        }
        return bestBypass
    }

    /// Corners `step` segments apart on one line of the pair cut short, the other line following, if the pair stays
    /// coupled about as long and clear of everything (KiCad's mergeDpStep); whether one was
    private func mergeDpStep(_ pair: DiffPair, _ tryP: Bool, _ step: Int) -> Bool {
        var n = 1
        let currentPath = tryP ? pair.cp : pair.cn
        var coupledPath = tryP ? pair.cn : pair.cp
        let nSegs = currentPath.segmentCount - 1
        let clenPre = pair.coupledLength(currentPath, coupledPath)
        let budget = clenPre / 10 // fixme: come up with something more intelligent here...
        while n < nSegs - step {
            let s1 = currentPath.segment(n), s2 = currentPath.segment(n + step)
            let dir1 = Direction45(s1), dir2 = Direction45(s2)
            if dir1.isObtuse(dir2) {
                let bypass = Direction45().buildInitialTrace(s1.a, s2.b, startDiagonal: dir1.isDiagonal)
                var newRef = currentPath
                newRef.replace(s1.index, s2.index, with: bypass)
                let deltaUni = pair.coupledLength(newRef, coupledPath) - clenPre + budget
                if var newCoup = Self.coupledBypass(world, pair, tryP, newRef, bypass, coupledPath) {
                    let deltaCoupled = pair.coupledLength(newRef, newCoup) - clenPre + budget
                    if deltaCoupled >= 0 {
                        newRef.simplify2()
                        newCoup.simplify2()
                        pair.setShape(newRef, newCoup, swapLanes: !tryP)
                        return true
                    }
                } else if deltaUni >= 0 && Self.verifyDpBypass(world, pair, tryP, newRef, coupledPath) {
                    newRef.simplify2()
                    coupledPath.simplify2()
                    pair.setShape(newRef, coupledPath, swapLanes: !tryP)
                    return true
                }
            }
            n += 1
        }
        return false
    }

    /// The pair's corners merged, the widest steps first, on either line (KiCad's mergeDpSegments)
    private func mergeDpSegments(_ pair: DiffPair) -> Bool {
        var stepP = pair.cp.segmentCount - 2
        var stepN = pair.cn.segmentCount - 2
        while true {
            let maxStepP = pair.cp.segmentCount - 2
            let maxStepN = pair.cn.segmentCount - 2
            if stepP > maxStepP { stepP = maxStepP }
            if stepN > maxStepN { stepN = maxStepN }
            if stepP < 1 && stepN < 1 { break }
            var foundAnythingP = false, foundAnythingN = false
            if stepP > 1 { foundAnythingP = mergeDpStep(pair, true, stepP) }
            if stepN > 1 { foundAnythingN = mergeDpStep(pair, false, stepN) }
            if !foundAnythingN && !foundAnythingP {
                stepN -= 1
                stepP -= 1
            }
        }
        return true
    }
}
