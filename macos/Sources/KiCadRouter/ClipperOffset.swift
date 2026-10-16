// Ported from Clipper2 2.0.1 (the version KiCad 10.0.7 ships, thirdparty/clipper2), as KiCad compiles it (USINGZ):
// Clipper2Lib/include/clipper2/clipper.offset.h and Clipper2Lib/src/clipper.offset.cpp.
// Clipper2: Copyright Angus Johnson 2010-2026, https://www.angusj.com.
// Boost Software License 1.0, https://www.boost.org/LICENSE_1_0.txt (see KICAD-NOTICE.md).

import Foundation

extension Clipper {
    /// How the offset of a corner is made: squared off at the offset distance, cut straight across (bevel), rounded,
    /// or mitred (squared off where the miter would be longer than the limit allows)
    public enum JoinType: Int, Sendable { case square, bevel, round, miter }

    /// How a path is offset: as a polygon (one side, closed paths), as a closed path both sides (joined), or as an
    /// open path both sides, its ends cut square at them (butt), squared off beyond them (square) or rounded
    public enum EndType: Int, Sendable { case polygon, joined, butt, square, round }

    /// For a delta that changes along a path: the path, its edges' normals, the point offset and the one before it
    public typealias DeltaCallback64 = (_ path: Path64, _ pathNormals: PathD, _ currIdx: Int, _ prevIdx: Int) -> Double

    /// Clipper2's offsetter: paths grown (or shrunk) by a distance, their corners joined as asked, and the result
    /// cleaned of what crosses itself by a union
    public final class ClipperOffset {
        private struct Group {
            var pathsIn: Paths64
            var lowestPathIdx: Int?
            var isReversed = false
            var joinType: JoinType
            var endType: EndType

            init(_ paths: Paths64, _ joinType: JoinType, _ endType: EndType) {
                pathsIn = paths
                self.joinType = joinType
                self.endType = endType
                let isJoined = endType == .polygon || endType == .joined
                for i in pathsIn.indices { stripDuplicates(&pathsIn[i], isClosedPath: isJoined) }
                if endType == .polygon {
                    var isNegArea = false
                    lowestPathIdx = getLowestClosedPathInfo(pathsIn, &isNegArea)
                    // the lowest path must be an outline: if it goes round the other way, the whole group is
                    // reversed (its delta negated) rather than every path turned round
                    isReversed = lowestPathIdx != nil && isNegArea
                } else {
                    lowestPathIdx = nil
                    isReversed = false
                }
            }
        }

        private static let floatingPointTolerance = 1e-12
        /// the arc tolerance when none is given, as a fraction of the offset: 1/500
        private static let arcConst = 0.002

        private var delta = 0.0
        private var groupDelta = 0.0
        private var tempLim = 0.0
        private var stepsPerRad = 0.0
        private var stepSin = 0.0
        private var stepCos = 0.0
        private var norms = PathD()
        private var pathOut = Path64()
        private var solution = Paths64()
        private var groups: [Group] = []
        private var joinType = JoinType.bevel
        private var endType = EndType.polygon

        /// How far a miter may reach, in deltas (beyond it, squared off)
        public var miterLimit: Double
        /// How far a rounded join's segments may stray from the true arc (0: Clipper2's own, the offset / 500)
        public var arcTolerance: Double
        public var preserveCollinear: Bool
        public var reverseSolution: Bool
        public var zCallback: ZCallback64?
        public var deltaCallback: DeltaCallback64?

        public init(miterLimit: Double = 2.0, arcTolerance: Double = 0.0, preserveCollinear: Bool = false,
                    reverseSolution: Bool = false) {
            self.miterLimit = miterLimit
            self.arcTolerance = arcTolerance
            self.preserveCollinear = preserveCollinear
            self.reverseSolution = reverseSolution
        }

        public func addPath(_ path: Path64, _ joinType: JoinType, _ endType: EndType) {
            groups.append(Group([path], joinType, endType))
        }

        public func addPaths(_ paths: Paths64, _ joinType: JoinType, _ endType: EndType) {
            if paths.isEmpty { return }
            groups.append(Group(paths, joinType, endType))
        }

        public func clear() {
            groups.removeAll()
            norms.removeAll()
        }

        /// The paths offset by delta (positive grows polygons, negative shrinks them)
        public func execute(_ delta: Double) -> Paths64 {
            solution = []
            var out = Paths64()
            executeInternal(delta, nil, &out)
            return out
        }

        /// The same, as a tree of outlines and holes
        public func execute(_ delta: Double, polytree: PolyTree64) {
            polytree.clear()
            solution = []
            var unused = Paths64()
            executeInternal(delta, polytree, &unused)
        }

        /// The paths offset by what the callback says for each point (its delta 1, as Clipper2's)
        public func execute(_ deltaCallback: @escaping DeltaCallback64) -> Paths64 {
            self.deltaCallback = deltaCallback
            return execute(1.0)
        }

        // MARK: Geometry

        /// The path with the lowest point (greatest y, then least x), and whether its area is negative
        private static func getLowestClosedPathInfo(_ paths: Paths64, _ isNegArea: inout Bool) -> Int? {
            var idx: Int?
            var botPt = Point64(Int.max, Int.min)
            for i in paths.indices {
                var a = maxDouble
                for pt in paths[i] {
                    if pt.y < botPt.y || (pt.y == botPt.y && pt.x >= botPt.x) { continue }
                    if a == maxDouble {
                        a = area(paths[i])
                        if a == 0 { break }  // not a proper closed path
                        isNegArea = a < 0
                    }
                    idx = i
                    botPt.x = pt.x
                    botPt.y = pt.y
                }
            }
            return idx
        }

        @inline(__always)
        private static func hypot(_ x: Double, _ y: Double) -> Double { (x * x + y * y).squareRoot() }

        private static func getUnitNormal(_ pt1: Point64, _ pt2: Point64) -> PointD {
            if pt1 == pt2 { return PointD(0, 0) }
            var dx = Double(pt2.x - pt1.x), dy = Double(pt2.y - pt1.y)
            let inverseHypot = 1.0 / hypot(dx, dy)
            dx *= inverseHypot
            dy *= inverseHypot
            return PointD(dy, -dx)
        }

        private static func normalizeVector(_ vec: PointD) -> PointD {
            let h = hypot(vec.x, vec.y)
            if abs(h) < 0.001 { return PointD(0, 0) }
            let inverseHypot = 1 / h
            return PointD(vec.x * inverseHypot, vec.y * inverseHypot)
        }

        private static func getAvgUnitVector(_ vec1: PointD, _ vec2: PointD) -> PointD {
            normalizeVector(PointD(vec1.x + vec2.x, vec1.y + vec2.y))
        }

        @inline(__always)
        private static func getPerpendic(_ pt: Point64, _ norm: PointD, _ delta: Double) -> Point64 {
            Point64(Double(pt.x) + norm.x * delta, Double(pt.y) + norm.y * delta, pt.z)
        }

        @inline(__always)
        private static func getPerpendicD(_ pt: Point64, _ norm: PointD, _ delta: Double) -> PointD {
            PointD(Double(pt.x) + norm.x * delta, Double(pt.y) + norm.y * delta, pt.z)
        }

        @inline(__always)
        private static func translatePoint(_ pt: PointD, _ dx: Double, _ dy: Double) -> PointD {
            PointD(pt.x + dx, pt.y + dy, pt.z)
        }

        @inline(__always)
        private static func reflectPoint(_ pt: PointD, _ pivot: PointD) -> PointD {
            PointD(pivot.x + (pivot.x - pt.x), pivot.y + (pivot.y - pt.y), pt.z)
        }

        private func buildNormals(_ path: Path64) {
            norms.removeAll(keepingCapacity: true)
            if path.isEmpty { return }
            norms.reserveCapacity(path.count)
            for i in 0..<(path.count - 1) { norms.append(Self.getUnitNormal(path[i], path[i + 1])) }
            norms.append(Self.getUnitNormal(path[path.count - 1], path[0]))
        }

        // MARK: Joins

        private func doBevel(_ path: Path64, _ j: Int, _ k: Int) {
            let pt1: PointD, pt2: PointD
            let p = path[j]
            if j == k {
                let absDelta = abs(groupDelta)
                pt1 = PointD(Double(p.x) - absDelta * norms[j].x, Double(p.y) - absDelta * norms[j].y, p.z)
                pt2 = PointD(Double(p.x) + absDelta * norms[j].x, Double(p.y) + absDelta * norms[j].y, p.z)
            } else {
                pt1 = PointD(Double(p.x) + groupDelta * norms[k].x, Double(p.y) + groupDelta * norms[k].y, p.z)
                pt2 = PointD(Double(p.x) + groupDelta * norms[j].x, Double(p.y) + groupDelta * norms[j].y, p.z)
            }
            pathOut.append(Point64(pt1))
            pathOut.append(Point64(pt2))
        }

        private func doSquare(_ path: Path64, _ j: Int, _ k: Int) {
            let vec: PointD
            if j == k {
                vec = PointD(norms[j].y, -norms[j].x)
            } else {
                vec = Self.getAvgUnitVector(PointD(-norms[k].y, norms[k].x), PointD(norms[j].y, -norms[j].x))
            }
            let absDelta = abs(groupDelta)

            // the vertex moved delta along the unit vector, and the corners either side of it
            var ptQ = PointD(path[j])
            ptQ = Self.translatePoint(ptQ, absDelta * vec.x, absDelta * vec.y)
            let pt1 = Self.translatePoint(ptQ, groupDelta * vec.y, groupDelta * -vec.x)
            let pt2 = Self.translatePoint(ptQ, groupDelta * -vec.y, groupDelta * vec.x)
            // two points along one edge's offset
            let pt3 = Self.getPerpendicD(path[k], norms[k], groupDelta)
            if j == k {
                let pt4 = PointD(pt3.x + vec.x * groupDelta, pt3.y + vec.y * groupDelta)
                var pt = ptQ
                _ = getLineIntersectPt(pt1, pt2, pt3, pt4, &pt)
                // the other corner, reflected
                pathOut.append(Point64(Self.reflectPoint(pt, ptQ)))
                pathOut.append(Point64(pt))
            } else {
                let pt4 = Self.getPerpendicD(path[j], norms[k], groupDelta)
                var pt = ptQ
                _ = getLineIntersectPt(pt1, pt2, pt3, pt4, &pt)
                pathOut.append(Point64(pt))
                pathOut.append(Point64(Self.reflectPoint(pt, ptQ)))
            }
        }

        private func doMiter(_ path: Path64, _ j: Int, _ k: Int, _ cosA: Double) {
            let q = groupDelta / (cosA + 1)
            pathOut.append(Point64(Double(path[j].x) + (norms[k].x + norms[j].x) * q,
                                   Double(path[j].y) + (norms[k].y + norms[j].y) * q, path[j].z))
        }

        private func doRound(_ path: Path64, _ j: Int, _ k: Int, _ angle: Double) {
            if deltaCallback != nil {
                // (the delta changes from point to point: so do the steps)
                let absDelta = abs(groupDelta)
                let arcTol = arcTolerance > Self.floatingPointTolerance ? min(absDelta, arcTolerance) : absDelta * Self.arcConst
                let stepsPer360 = min(Double.pi / acos(1 - arcTol / absDelta), absDelta * Double.pi)
                stepSin = sin(2 * Double.pi / stepsPer360)
                stepCos = cos(2 * Double.pi / stepsPer360)
                if groupDelta < 0.0 { stepSin = -stepSin }
                stepsPerRad = stepsPer360 / (2 * Double.pi)
            }

            let pt = path[j]
            var offsetVec = PointD(norms[k].x * groupDelta, norms[k].y * groupDelta)
            if j == k {
                offsetVec.x = -offsetVec.x
                offsetVec.y = -offsetVec.y
            }
            pathOut.append(Point64(Double(pt.x) + offsetVec.x, Double(pt.y) + offsetVec.y, pt.z))
            let steps = toInt32((stepsPerRad * abs(angle)).rounded(.up))
            var i = 1
            while i < steps {  // one less than steps
                offsetVec = PointD(offsetVec.x * stepCos - stepSin * offsetVec.y, offsetVec.x * stepSin + offsetVec.y * stepCos)
                pathOut.append(Point64(Double(pt.x) + offsetVec.x, Double(pt.y) + offsetVec.y, pt.z))
                i += 1
            }
            pathOut.append(Self.getPerpendic(path[j], norms[j], groupDelta))
        }

        private func offsetPoint(_ group: Group, _ path: Path64, _ j: Int, _ k: Int) {
            // A, the change in angle where the edges join: 0 flat, π a spike; sin(A) < 0 turning right, cos(A) < 0
            // turning more than 90°
            if path[j] == path[k] { return }

            var sinA = crossProduct(norms[j], norms[k])
            let cosA = dotProduct(norms[j], norms[k])
            if sinA > 1.0 { sinA = 1.0 } else if sinA < -1.0 { sinA = -1.0 }

            if let deltaCallback {
                groupDelta = deltaCallback(path, norms, j, k)
                if group.isReversed { groupDelta = -groupDelta }
            }
            if abs(groupDelta) <= Self.floatingPointTolerance {
                pathOut.append(path[j])
                return
            }

            if cosA > -0.999 && sinA * groupDelta < 0 {
                // concave: three points making negative regions, which the union at the end removes (as it removes
                // paths turned inside out by too much shrinking)
                pathOut.append(Self.getPerpendic(path[j], norms[k], groupDelta))
                pathOut.append(path[j])
                pathOut.append(Self.getPerpendic(path[j], norms[j], groupDelta))
            } else if cosA > 0.999 && joinType != .round {
                // all but straight (less than 2.5°)
                doMiter(path, j, k, cosA)
            } else if joinType == .miter {
                // a miter, unless so sharp it would pass the limit
                if cosA > tempLim - 1 { doMiter(path, j, k, cosA) } else { doSquare(path, j, k) }
            } else if joinType == .round {
                doRound(path, j, k, atan2(sinA, cosA))
            } else if joinType == .bevel {
                doBevel(path, j, k)
            } else {
                doSquare(path, j, k)
            }
        }

        private func offsetPolygon(_ group: Group, _ path: Path64) {
            pathOut.removeAll(keepingCapacity: true)
            var k = path.count - 1
            for j in 0..<path.count {
                offsetPoint(group, path, j, k)
                k = j
            }
            solution.append(pathOut)
        }

        private func offsetOpenJoined(_ group: Group, _ path: Path64) {
            offsetPolygon(group, path)
            let reversePath = Path64(path.reversed())

            // the normals rebuilt for the path the other way round
            norms.reverse()
            norms.append(norms[0])
            norms.removeFirst()
            for i in norms.indices {
                norms[i].x = -norms[i].x
                norms[i].y = -norms[i].y
            }

            offsetPolygon(group, reversePath)
        }

        private func offsetOpenPath(_ group: Group, _ path: Path64) {
            // the start's cap
            if let deltaCallback { groupDelta = deltaCallback(path, norms, 0, 0) }

            if abs(groupDelta) <= Self.floatingPointTolerance {
                pathOut.append(path[0])
            } else {
                switch endType {
                case .butt: doBevel(path, 0, 0)
                case .round: doRound(path, 0, 0, Double.pi)
                default: doSquare(path, 0, 0)
                }
            }

            let highI = path.count - 1
            // the left side, going forward
            var k = 0
            for j in stride(from: 1, to: highI, by: 1) {
                offsetPoint(group, path, j, k)
                k = j
            }

            // the normals turned round
            var i = highI
            while i > 0 {
                norms[i] = PointD(-norms[i - 1].x, -norms[i - 1].y)
                i -= 1
            }
            norms[0] = norms[highI]

            // the end's cap
            if let deltaCallback { groupDelta = deltaCallback(path, norms, highI, highI) }

            if abs(groupDelta) <= Self.floatingPointTolerance {
                pathOut.append(path[highI])
            } else {
                switch endType {
                case .butt: doBevel(path, highI, highI)
                case .round: doRound(path, highI, highI, Double.pi)
                default: doSquare(path, highI, highI)
                }
            }

            // and back along the other side
            k = highI
            var j = highI - 1
            while j > 0 {
                offsetPoint(group, path, j, k)
                k = j
                j -= 1
            }
            solution.append(pathOut)
        }

        private func doGroupOffset(_ group: Group) {
            if group.endType == .polygon {
                // (a straight path of two points can be offset as a polygon too, its ends 180° joins)
                if group.lowestPathIdx == nil { delta = abs(delta) }
                groupDelta = group.isReversed ? -delta : delta
            } else {
                groupDelta = abs(delta)
            }

            var absDelta = abs(groupDelta)
            joinType = group.joinType
            endType = group.endType

            if group.joinType == .round || group.endType == .round {
                // the steps to a circle for the arc tolerance (when none is given, relative to the offset)
                let arcTol = arcTolerance > Self.floatingPointTolerance ? min(absDelta, arcTolerance) : absDelta * Self.arcConst
                let stepsPer360 = min(Double.pi / acos(1 - arcTol / absDelta), absDelta * Double.pi)
                stepSin = sin(2 * Double.pi / stepsPer360)
                stepCos = cos(2 * Double.pi / stepsPer360)
                if groupDelta < 0.0 { stepSin = -stepSin }
                stepsPerRad = stepsPer360 / (2 * Double.pi)
            }

            for pathIn in group.pathsIn {
                let pathLen = pathIn.count
                pathOut.removeAll(keepingCapacity: true)

                if pathLen == 1 {
                    // a single point: a circle or a square round it
                    if let deltaCallback {
                        groupDelta = deltaCallback(pathIn, norms, 0, 0)
                        if group.isReversed { groupDelta = -groupDelta }
                        absDelta = abs(groupDelta)
                    }
                    if groupDelta < 1 { continue }
                    let pt = pathIn[0]
                    if group.joinType == .round {
                        let radius = absDelta
                        let steps = stepsPerRad > 0 ? toInt((stepsPerRad * 2 * Double.pi).rounded(.up)) : 0
                        pathOut = ellipse(pt, radius, radius, steps)
                        for i in pathOut.indices { pathOut[i].z = pt.z }
                    } else {
                        let d = toInt32(absDelta.rounded(.up))
                        pathOut = Rect64(pt.x - d, pt.y - d, pt.x + d, pt.y + d).asPath
                        for i in pathOut.indices { pathOut[i].z = pt.z }
                    }
                    solution.append(pathOut)
                    continue
                }

                // (an open path of no points is not something Clipper2 offsets: it reads its first point)
                if pathLen == 0 && endType != .polygon { continue }
                if pathLen == 2 && group.endType == .joined { endType = group.joinType == .round ? .round : .square }

                buildNormals(pathIn)
                if endType == .polygon {
                    offsetPolygon(group, pathIn)
                } else if endType == .joined {
                    offsetOpenJoined(group, pathIn)
                } else {
                    offsetOpenPath(group, pathIn)
                }
            }
        }

        /// Clipper2's own z callback for the union: a crossing gets the z its edges' ends share, if they share one,
        /// and otherwise what the user's callback gives it
        private func zcb(_ bot1: Point64, _ top1: Point64, _ bot2: Point64, _ top2: Point64, _ ip: inout Point64) {
            if bot1.z != 0 && (bot1.z == bot2.z || bot1.z == top2.z) {
                ip.z = bot1.z
            } else if bot2.z != 0 && bot2.z == top1.z {
                ip.z = bot2.z
            } else if top1.z != 0 && top1.z == top2.z {
                ip.z = top1.z
            } else if let zCallback {
                zCallback(bot1, top1, bot2, top2, &ip)
            }
        }

        private func checkReverseOrientation() -> Bool {
            // (orientations are taken to agree between groups)
            for g in groups where g.endType == .polygon { return g.isReversed }
            return false
        }

        private func executeInternal(_ delta: Double, _ solutionTree: PolyTree64?, _ out: inout Paths64) {
            if groups.isEmpty { return }

            if abs(delta) < 0.5 {
                // too little to offset
                for group in groups { solution.append(contentsOf: group.pathsIn) }
            } else {
                tempLim = miterLimit <= 1 ? 2.0 : 2.0 / (miterLimit * miterLimit)
                self.delta = delta
                for group in groups { doGroupOffset(group) }
            }

            if solution.isEmpty { return }

            let pathsReversed = checkReverseOrientation()
            // what crosses itself cleaned up
            let c = Clipper64()
            c.preserveCollinear = preserveCollinear
            // (the solution keeps the input's orientation)
            c.reverseSolution = reverseSolution != pathsReversed
            c.zCallback = { [unowned self] bot1, top1, bot2, top2, ip in self.zcb(bot1, top1, bot2, top2, &ip) }
            c.addSubject(solution)
            solution = []
            if let solutionTree {
                c.execute(.union, pathsReversed ? .negative : .positive, polytree: solutionTree)
            } else {
                c.execute(.union, pathsReversed ? .negative : .positive, closedPaths: &out)
            }
        }
    }
}
