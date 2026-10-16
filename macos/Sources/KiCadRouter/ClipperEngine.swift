// Ported from Clipper2 2.0.1 (the version KiCad 10.0.7 ships, thirdparty/clipper2), as KiCad compiles it (USINGZ):
// Clipper2Lib/include/clipper2/clipper.engine.h and Clipper2Lib/src/clipper.engine.cpp (with KiCad's stripe index for
// the point in polygon tests that nest the solution's paths).
// Clipper2: Copyright Angus Johnson 2010-2026, https://www.angusj.com.
// Boost Software License 1.0, https://www.boost.org/LICENSE_1_0.txt (see KICAD-NOTICE.md).

import Foundation

extension Clipper {
    /// What to make of the subject and clip paths (all but the difference work either way round)
    public enum ClipType: Int, Sendable { case noClip, intersection, union, difference, xor }

    enum PathType { case subject, clip }

    enum JoinWith { case noJoin, left, right }

    struct VertexFlags: OptionSet {
        let rawValue: UInt32
        static let openStart = VertexFlags(rawValue: 1)
        static let openEnd = VertexFlags(rawValue: 2)
        static let localMax = VertexFlags(rawValue: 4)
        static let localMin = VertexFlags(rawValue: 8)
    }

    /// A point of an input path, linked to its neighbours round the path
    final class Vertex {
        var pt: Point64
        var next: Vertex!
        var prev: Vertex!
        var flags: VertexFlags = []

        init(_ pt: Point64) { self.pt = pt }
    }

    /// Where an output path's points are kept: a ring, each point linked to its neighbours
    final class OutPt {
        var pt: Point64
        var next: OutPt!
        var prev: OutPt!
        var outrec: OutRec!
        /// whether a horizontal segment starts here (Clipper2 keeps a pointer to it, only ever asked whether there is
        /// one)
        var horz = false

        init(_ pt: Point64, _ outrec: OutRec) {
            self.pt = pt
            self.outrec = outrec
        }
    }

    /// A path of the solution as it is made: its points, the edges adding to its two ends, and what it is in
    final class OutRec {
        var idx = 0
        var owner: OutRec?
        var frontEdge: Active?
        var backEdge: Active?
        var pts: OutPt?
        var polypath: PolyPath64?
        /// the paths it split into (Clipper2's splits list; empty when it has none)
        var splits: [OutRec] = []
        var recursiveSplit: OutRec?
        /// while its splits are gone through, looking for an owner: how far the search had got when it started (see
        /// checkSplitOwner)
        var splitSearchStep: Int?
        var bounds = Rect64()
        var path = Path64()
        var isOpen = false
        /// built when the tree is nested, for the point in polygon tests against this path
        var pipIndex: StripeIndex?
    }

    /// An edge in the sweep: from its bottom to its top (y down, as Clipper2 thinks of it), where it is on the
    /// current scanline, its winding counts, and its places in the active and sorted edge lists
    final class Active {
        var bot = Point64(0, 0)
        var top = Point64(0, 0)
        var currX = 0
        var dx = 0.0
        var windDx = 1
        var windCnt = 0
        var windCnt2 = 0
        var outrec: OutRec?
        var prevInAEL: Active?
        var nextInAEL: Active?
        var prevInSEL: Active?
        var nextInSEL: Active?
        var jump: Active?
        var vertexTop: Vertex!
        var localMin: LocalMinima!
        var isLeftBound = false
        var joinWith = JoinWith.noJoin
    }

    final class LocalMinima {
        let vertex: Vertex
        let polytype: PathType
        let isOpen: Bool

        init(_ vertex: Vertex, _ polytype: PathType, _ isOpen: Bool) {
            self.vertex = vertex
            self.polytype = polytype
            self.isOpen = isOpen
        }
    }

    struct IntersectNode {
        var pt: Point64
        var edge1: Active
        var edge2: Active
    }

    final class HorzSegment {
        var leftOp: OutPt?
        var rightOp: OutPt?
        var leftToRight = true

        init(_ op: OutPt) { leftOp = op }
    }

    struct HorzJoin {
        var op1: OutPt
        var op2: OutPt
    }

    /// KiCad's index of a ring's edges in horizontal stripes, so that a point in polygon test looks only at the edges
    /// of the stripe the point is in (it declines rings whose edges each cross many stripes)
    final class StripeIndex {
        private struct StripeEdge {
            var a: Point64
            var b: Point64
        }

        private var edges: [StripeEdge] = []
        private var stripes: [[Int32]] = []
        private var yMin = 0
        private var stripeHeight = 1
        private var stripeCount = 1

        var isEmpty: Bool { edges.isEmpty }

        private func yToStripe(_ y: Int) -> Int {
            let s = (y - yMin) / stripeHeight
            if s < 0 { return 0 }
            if s >= stripeCount { return stripeCount - 1 }
            return s
        }

        private func build(_ newEdges: [StripeEdge]) {
            edges = newEdges
            stripes = []
            if edges.isEmpty {
                yMin = 0
                stripeHeight = 1
                stripeCount = 1
                return
            }
            yMin = edges[0].a.y
            var yMax = edges[0].a.y
            for e in edges {
                yMin = min(yMin, min(e.a.y, e.b.y))
                yMax = max(yMax, max(e.a.y, e.b.y))
            }
            stripeCount = Int(Double(edges.count).squareRoot())
            if stripeCount < 1 { stripeCount = 1 }
            if stripeCount > 65536 { stripeCount = 65536 }
            let yRange = yMax - yMin
            stripeHeight = yRange <= 0 ? 1 : (yRange + stripeCount - 1) / stripeCount

            // tall edges each in many stripes: looking at every edge is quicker
            var totalRefs = 0
            for e in edges {
                totalRefs += yToStripe(max(e.a.y, e.b.y)) - yToStripe(min(e.a.y, e.b.y)) + 1
            }
            if totalRefs > edges.count * 8 {
                edges.removeAll()
                return
            }
            stripes = [[Int32]](repeating: [], count: stripeCount)
            for (i, e) in edges.enumerated() {
                let sMin = yToStripe(min(e.a.y, e.b.y)), sMax = yToStripe(max(e.a.y, e.b.y))
                for s in sMin...sMax { stripes[s].append(Int32(i)) }
            }
        }

        func build(fromRing op: OutPt?) {
            var newEdges: [StripeEdge] = []
            if let op, op.next !== op, op.prev !== op.next {
                var cur = op
                repeat {
                    let nxt = cur.next!
                    if cur.pt.x != nxt.pt.x || cur.pt.y != nxt.pt.y { newEdges.append(StripeEdge(a: cur.pt, b: nxt.pt)) }
                    cur = nxt
                } while cur !== op
            }
            build(newEdges)
        }

        func pointInPolygon(_ pt: Point64) -> PointInPolygonResult {
            if edges.isEmpty { return .isOutside }
            var inside = false
            for idx in stripes[yToStripe(pt.y)] {
                let e = edges[Int(idx)]
                let cross = crossProductSign(e.a, e.b, pt)
                // on the edge: on its line, and within its box
                if cross == 0 && pt.x >= min(e.a.x, e.b.x) && pt.x <= max(e.a.x, e.b.x) &&
                    pt.y >= min(e.a.y, e.b.y) && pt.y <= max(e.a.y, e.b.y) {
                    return .isOn
                }
                // (half open, so that horizontal edges never count)
                if (e.a.y > pt.y) != (e.b.y > pt.y) {
                    if e.b.y > pt.y ? cross > 0 : cross < 0 { inside.toggle() }
                }
            }
            return inside ? .isInside : .isOutside
        }
    }

    // MARK: - Edges

    @inline(__always) static func isOdd(_ val: Int) -> Bool { val & 1 != 0 }
    @inline(__always) static func isHotEdge(_ e: Active) -> Bool { e.outrec != nil }
    @inline(__always) static func isOpen(_ e: Active) -> Bool { e.localMin.isOpen }
    @inline(__always) static func isOpenEnd(_ v: Vertex) -> Bool { !v.flags.isDisjoint(with: [.openStart, .openEnd]) }
    @inline(__always) static func isOpenEnd(_ ae: Active) -> Bool { isOpenEnd(ae.vertexTop) }

    static func getPrevHotEdge(_ e: Active) -> Active? {
        var prev = e.prevInAEL
        while let p = prev, isOpen(p) || !isHotEdge(p) { prev = p.prevInAEL }
        return prev
    }

    @inline(__always) static func isFront(_ e: Active) -> Bool { e === e.outrec!.frontEdge }

    /// An edge's slope as x per y: for horizontals, minus the largest double heading right, the largest heading left
    static func getDx(_ pt1: Point64, _ pt2: Point64) -> Double {
        let dy = Double(pt2.y - pt1.y)
        if dy != 0 { return Double(pt2.x - pt1.x) / dy }
        return pt2.x > pt1.x ? -maxDouble : maxDouble
    }

    /// Where an edge is at y
    @inline(__always)
    static func topX(_ ae: Active, _ currentY: Int) -> Int {
        if currentY == ae.top.y || ae.top.x == ae.bot.x { return ae.top.x }
        if currentY == ae.bot.y { return ae.bot.x }
        return ae.bot.x + nearbyInt(ae.dx * Double(currentY - ae.bot.y))
    }

    @inline(__always) static func isHorizontal(_ e: Active) -> Bool { e.top.y == e.bot.y }
    @inline(__always) static func isHeadingRightHorz(_ e: Active) -> Bool { e.dx == -maxDouble }
    @inline(__always) static func isHeadingLeftHorz(_ e: Active) -> Bool { e.dx == maxDouble }
    @inline(__always) static func getPolyType(_ e: Active) -> PathType { e.localMin.polytype }
    @inline(__always) static func isSamePolyType(_ e1: Active, _ e2: Active) -> Bool { e1.localMin.polytype == e2.localMin.polytype }
    @inline(__always) static func setDx(_ e: Active) { e.dx = getDx(e.bot, e.top) }
    @inline(__always) static func nextVertex(_ e: Active) -> Vertex { e.windDx > 0 ? e.vertexTop.next : e.vertexTop.prev }

    /// The top of the other bound's edge, at an edge's insertion
    @inline(__always)
    static func prevPrevVertex(_ ae: Active) -> Vertex { ae.windDx > 0 ? ae.vertexTop.prev.prev : ae.vertexTop.next.next }

    static func extractFromSEL(_ ae: Active) -> Active? {
        let res = ae.nextInSEL
        res?.prevInSEL = ae.prevInSEL
        ae.prevInSEL!.nextInSEL = res
        return res
    }

    static func insert1Before2InSEL(_ ae1: Active, _ ae2: Active) {
        ae1.prevInSEL = ae2.prevInSEL
        ae1.prevInSEL?.nextInSEL = ae1
        ae1.nextInSEL = ae2
        ae2.prevInSEL = ae1
    }

    @inline(__always) static func isMaxima(_ v: Vertex) -> Bool { v.flags.contains(.localMax) }
    @inline(__always) static func isMaxima(_ e: Active) -> Bool { isMaxima(e.vertexTop) }

    static func getCurrYMaximaVertexOpen(_ e: Active) -> Vertex? {
        var result: Vertex = e.vertexTop
        if e.windDx > 0 {
            while result.next.pt.y == result.pt.y && result.flags.isDisjoint(with: [.openEnd, .localMax]) { result = result.next }
        } else {
            while result.prev.pt.y == result.pt.y && result.flags.isDisjoint(with: [.openEnd, .localMax]) { result = result.prev }
        }
        return isMaxima(result) ? result : nil
    }

    static func getCurrYMaximaVertex(_ e: Active) -> Vertex? {
        var result: Vertex = e.vertexTop
        if e.windDx > 0 {
            while result.next.pt.y == result.pt.y { result = result.next }
        } else {
            while result.prev.pt.y == result.pt.y { result = result.prev }
        }
        return isMaxima(result) ? result : nil
    }

    static func getMaximaPair(_ e: Active) -> Active? {
        var e2 = e.nextInAEL
        while let x = e2 {
            if x.vertexTop === e.vertexTop { return x }
            e2 = x.nextInAEL
        }
        return nil
    }

    // MARK: - Output points

    static func disposeOutPt(_ op: OutPt) -> OutPt {
        let result = op.next!
        op.prev.next = op.next
        op.next.prev = op.prev
        return result
    }

    static func setSides(_ outrec: OutRec, _ startEdge: Active, _ endEdge: Active) {
        outrec.frontEdge = startEdge
        outrec.backEdge = endEdge
    }

    static func swapOutrecs(_ e1: Active, _ e2: Active) {
        let or1 = e1.outrec, or2 = e2.outrec
        if or1 === or2 {
            let e = or1!.frontEdge
            or1!.frontEdge = or1!.backEdge
            or1!.backEdge = e
            return
        }
        if let or1 {
            if e1 === or1.frontEdge { or1.frontEdge = e2 } else { or1.backEdge = e2 }
        }
        if let or2 {
            if e2 === or2.frontEdge { or2.frontEdge = e1 } else { or2.backEdge = e1 }
        }
        e1.outrec = or2
        e2.outrec = or1
    }

    static func area(_ op: OutPt) -> Double {
        var result = 0.0
        var op2 = op
        repeat {
            result += Double(op2.prev.pt.y + op2.pt.y) * Double(op2.prev.pt.x - op2.pt.x)
            op2 = op2.next
        } while op2 !== op
        return result * 0.5
    }

    static func areaTriangle(_ pt1: Point64, _ pt2: Point64, _ pt3: Point64) -> Double {
        Double(pt3.y + pt1.y) * Double(pt3.x - pt1.x) + Double(pt1.y + pt2.y) * Double(pt1.x - pt2.x) +
            Double(pt2.y + pt3.y) * Double(pt2.x - pt3.x)
    }

    static func getRealOutRec(_ outrec: OutRec?) -> OutRec? {
        var outrec = outrec
        while let o = outrec, o.pts == nil { outrec = o.owner }
        return outrec
    }

    /// Whether testOwner may own outrec (not if outrec owns it, directly or not)
    static func isValidOwner(_ outrec: OutRec, _ testOwner: OutRec?) -> Bool {
        var testOwner = testOwner
        while let t = testOwner, t !== outrec { testOwner = t.owner }
        return testOwner == nil
    }

    static func uncoupleOutRec(_ ae: Active) {
        guard let outrec = ae.outrec else { return }
        outrec.frontEdge!.outrec = nil
        outrec.backEdge!.outrec = nil
        outrec.frontEdge = nil
        outrec.backEdge = nil
    }

    @inline(__always)
    static func ptsReallyClose(_ pt1: Point64, _ pt2: Point64) -> Bool { abs(pt1.x - pt2.x) < 2 && abs(pt1.y - pt2.y) < 2 }

    static func isVerySmallTriangle(_ op: OutPt) -> Bool {
        op.next.next === op.prev &&
            (ptsReallyClose(op.prev.pt, op.next.pt) || ptsReallyClose(op.pt, op.next.pt) || ptsReallyClose(op.pt, op.prev.pt))
    }

    static func isValidClosedPath(_ op: OutPt?) -> Bool {
        guard let op else { return false }
        return op.next !== op && op.next !== op.prev && !isVerySmallTriangle(op)
    }

    @inline(__always) static func outrecIsAscending(_ hotEdge: Active) -> Bool { hotEdge === hotEdge.outrec!.frontEdge }

    static func swapFrontBackSides(_ outrec: OutRec) {
        let tmp = outrec.frontEdge
        outrec.frontEdge = outrec.backEdge
        outrec.backEdge = tmp
        outrec.pts = outrec.pts!.next
    }

    @inline(__always)
    static func edgesAdjacentInAEL(_ inode: IntersectNode) -> Bool {
        inode.edge1.nextInAEL === inode.edge2 || inode.edge1.prevInAEL === inode.edge2
    }

    @inline(__always) static func isJoined(_ e: Active) -> Bool { e.joinWith != .noJoin }

    static func setOwner(_ outrec: OutRec, _ newOwner: OutRec) {
        newOwner.owner = getRealOutRec(newOwner.owner)
        var tmp: OutRec? = newOwner
        while let t = tmp, t !== outrec { tmp = t.owner }
        if tmp != nil { newOwner.owner = outrec.owner }
        outrec.owner = newOwner
    }

    // MARK: - Point in polygon for rings

    static func pointInOpPolygon(_ pt: Point64, _ op: OutPt) -> PointInPolygonResult {
        var op: OutPt = op
        if op === op.next || op.prev === op.next { return .isOutside }

        var op2 = op
        repeat {
            if op.pt.y != pt.y { break }
            op = op.next
        } while op !== op2
        if op.pt.y == pt.y { return .isOutside }  // not a proper polygon

        var isAbove = op.pt.y < pt.y
        let startingAbove = isAbove
        var val = 0
        op2 = op.next
        while op2 !== op {
            if isAbove {
                while op2 !== op && op2.pt.y < pt.y { op2 = op2.next }
            } else {
                while op2 !== op && op2.pt.y > pt.y { op2 = op2.next }
            }
            if op2 === op { break }

            // it has touched or crossed pt's horizontal (as it must, an even number of times)
            if op2.pt.y == pt.y {
                if op2.pt.x == pt.x || (op2.pt.y == op2.prev.pt.y && (pt.x < op2.prev.pt.x) != (pt.x < op2.pt.x)) {
                    return .isOn
                }
                op2 = op2.next
                if op2 === op { break }
                continue
            }

            if pt.x < op2.pt.x && pt.x < op2.prev.pt.x {
                // only edges crossing on the left count
            } else if pt.x > op2.prev.pt.x && pt.x > op2.pt.x {
                val = 1 - val
            } else {
                let i = crossProductSign(op2.prev.pt, op2.pt, pt)
                if i == 0 { return .isOn }
                if (i < 0) == isAbove { val = 1 - val }
            }
            isAbove = !isAbove
            op2 = op2.next
        }

        if isAbove != startingAbove {
            let i = crossProductSign(op2.prev.pt, op2.pt, pt)
            if i == 0 { return .isOn }
            if (i < 0) == isAbove { val = 1 - val }
        }
        return val == 0 ? .isOutside : .isInside
    }

    /// A ring's points with those in the middle of straight horizontal or vertical runs left out
    static func getCleanPath(_ op: OutPt) -> Path64 {
        var result = Path64()
        var op2 = op
        while op2.next !== op &&
            ((op2.pt.x == op2.next.pt.x && op2.pt.x == op2.prev.pt.x) || (op2.pt.y == op2.next.pt.y && op2.pt.y == op2.prev.pt.y)) {
            op2 = op2.next
        }
        result.append(op2.pt)
        var prevOp = op2
        op2 = op2.next
        while op2 !== op {
            if (op2.pt.x != op2.next.pt.x || op2.pt.x != prevOp.pt.x) && (op2.pt.y != op2.next.pt.y || op2.pt.y != prevOp.pt.y) {
                result.append(op2.pt)
                prevOp = op2
            }
            op2 = op2.next
        }
        return result
    }

    /// Whether ring op2 holds ring op1 (allowing for the small crossings rounding makes)
    static func path2ContainsPath1(_ op1: OutPt, _ op2: OutPt) -> Bool {
        var pip = PointInPolygonResult.isOn
        var op = op1
        repeat {
            switch pointInOpPolygon(op.pt, op2) {
            case .isOutside:
                if pip == .isOutside { return false }
                pip = .isOutside
            case .isInside:
                if pip == .isInside { return true }
                pip = .isInside
            case .isOn:
                break
            }
            op = op.next
        } while op !== op1
        // not clear yet: again, with the paths cleaned
        return path2ContainsPath1(getCleanPath(op1), getCleanPath(op2))
    }

    /// The same, with the owner's stripe index once its path is long enough for one to pay (the answers are the same)
    static func path2ContainsPath1Indexed(_ op1: OutPt, _ owner: OutRec, _ indexThreshold: Int) -> Bool {
        if owner.path.count <= indexThreshold { return path2ContainsPath1(op1, owner.pts!) }
        if owner.pipIndex == nil {
            let index = StripeIndex()
            index.build(fromRing: owner.pts)
            owner.pipIndex = index
        }
        let index = owner.pipIndex!
        if index.isEmpty { return path2ContainsPath1(op1, owner.pts!) }

        var pip = PointInPolygonResult.isOn
        var op = op1
        repeat {
            switch index.pointInPolygon(op.pt) {
            case .isOutside:
                if pip == .isOutside { return false }
                pip = .isOutside
            case .isInside:
                if pip == .isInside { return true }
                pip = .isInside
            case .isOn:
                break
            }
            op = op.next
        } while op !== op1
        return path2ContainsPath1(getCleanPath(op1), getCleanPath(owner.pts!))
    }

    /// A path built from a ring: its points from the ring's back, or front when reversed, repeated points once
    static func buildPath64(_ op: OutPt?, _ reverse: Bool, _ isOpen: Bool, _ path: inout Path64) -> Bool {
        guard var op, op.next !== op, isOpen || op.next !== op.prev else { return false }
        path.removeAll(keepingCapacity: true)
        var lastPt: Point64
        var op2: OutPt
        if reverse {
            lastPt = op.pt
            op2 = op.prev
        } else {
            op = op.next
            lastPt = op.pt
            op2 = op.next
        }
        path.append(lastPt)
        while op2 !== op {
            if op2.pt != lastPt {
                lastPt = op2.pt
                path.append(lastPt)
            }
            op2 = reverse ? op2.prev : op2.next
        }
        if !isOpen && path.count == 3 && isVerySmallTriangle(op2) { return false }
        return true
    }

    // MARK: - Clipper64

    /// Clipper2's boolean operations: subject paths (closed, or open) and clip paths, their union, intersection,
    /// difference or exclusive or under a fill rule, as closed paths (outlines counter-clockwise with y up, holes the
    /// other way, unless reversed) and open paths, or as a tree of outlines and holes
    public final class Clipper64 {
        // what the sweep works with
        private var cliptype = ClipType.noClip
        private var fillrule = FillRule.evenOdd
        private let fillpos = FillRule.positive
        private var botY = 0
        private var minimaListSorted = false
        private var usingPolytree = false
        private var actives: Active?
        private var sel: Active?
        private var minimaList: [LocalMinima] = []
        private var currentLocMin = 0
        private var vertexLists: [[Vertex]] = []
        private var scanlines = ScanlineHeap()
        private var intersectNodes: [IntersectNode] = []
        private var horzSegList: [HorzSegment] = []
        private var horzJoinList: [HorzJoin] = []
        private var outrecList: [OutRec] = []
        // everything made in a run, so that its links can be cut when it is done (they make cycles)
        private var allActives: [Active] = []
        private var allOutPts: [OutPt] = []
        /// the changes made while owners are looked for in splits (see checkSplitOwner)
        private var splitSearchSteps = 0

        /// Whether points in the middle of straight runs are kept (only spikes, where a path turns back on itself,
        /// removed), or removed too
        public var preserveCollinear = true
        /// Solutions turned the other way round: outlines clockwise with y up
        public var reverseSolution = false
        public private(set) var errorCode = 0
        private var hasOpenPaths = false
        private var succeeded = true
        /// How long an owner's path must be before its point in polygon tests use a stripe index
        public var pipIndexThreshold = 64
        /// Called for each point made where edges cross, to give it a z value
        public var zCallback: ZCallback64?
        /// The z of points made where edges cross, none of whose ends they are, before the callback sees them
        public var defaultZ = 0

        public init() {}

        deinit { clear() }

        public func addSubject(_ subjects: Paths64) { addPaths(subjects, .subject, false) }
        public func addOpenSubject(_ openSubjects: Paths64) { addPaths(openSubjects, .subject, true) }
        public func addClip(_ clips: Paths64) { addPaths(clips, .clip, false) }

        /// Runs the operation: its closed paths, and its open ones. False when Clipper2 could not finish it (then
        /// there are no paths)
        @discardableResult
        public func execute(_ clipType: ClipType, _ fillRule: FillRule, closedPaths: inout Paths64,
                            openPaths: inout Paths64) -> Bool {
            closedPaths.removeAll()
            openPaths.removeAll()
            if executeInternal(clipType, fillRule, false) { buildPaths64(&closedPaths, &openPaths) }
            cleanUp()
            return succeeded
        }

        @discardableResult
        public func execute(_ clipType: ClipType, _ fillRule: FillRule, closedPaths: inout Paths64) -> Bool {
            var open = Paths64()
            return execute(clipType, fillRule, closedPaths: &closedPaths, openPaths: &open)
        }

        /// Runs the operation into a tree of outlines and holes, and its open paths
        @discardableResult
        public func execute(_ clipType: ClipType, _ fillRule: FillRule, polytree: PolyTree64, openPaths: inout Paths64) -> Bool {
            if executeInternal(clipType, fillRule, true) {
                openPaths.removeAll()
                polytree.clear()
                buildTree64(polytree, &openPaths)
            }
            cleanUp()
            return succeeded
        }

        @discardableResult
        public func execute(_ clipType: ClipType, _ fillRule: FillRule, polytree: PolyTree64) -> Bool {
            var open = Paths64()
            return execute(clipType, fillRule, polytree: polytree, openPaths: &open)
        }

        /// The paths added forgotten too
        public func clear() {
            cleanUp()
            disposeVerticesAndLocalMinima()
            currentLocMin = 0
            minimaListSorted = false
            hasOpenPaths = false
        }

        // MARK: Paths in

        private func addPaths(_ paths: Paths64, _ polytype: PathType, _ isOpen: Bool) {
            if isOpen { hasOpenPaths = true }
            minimaListSorted = false
            var vertices: [Vertex] = []
            vertices.reserveCapacity(paths.reduce(0) { $0 + $1.count })
            for path in paths {
                // each path a ring of its points (repeated points once)
                if path.isEmpty { continue }
                var v0: Vertex?
                var prevV: Vertex?
                var cnt = 0
                for pt in path {
                    if let p = prevV, p.pt == pt { continue }
                    let currV = Vertex(pt)
                    vertices.append(currV)
                    currV.prev = prevV
                    prevV?.next = currV
                    if v0 == nil { v0 = currV }
                    prevV = currV
                    cnt += 1
                }
                guard var last = prevV, last.prev != nil, let first = v0 else { continue }
                if !isOpen && last.pt == first.pt { last = last.prev }
                last.next = first
                first.prev = last
                if cnt < 2 || (cnt == 2 && !isOpen) { continue }

                // its local minima
                var goingUp: Bool
                if isOpen {
                    var currV: Vertex = first.next
                    while currV !== first && currV.pt.y == first.pt.y { currV = currV.next }
                    goingUp = currV.pt.y <= first.pt.y
                    if goingUp {
                        first.flags = .openStart
                        addLocMin(first, polytype, true)
                    } else {
                        first.flags = [.openStart, .localMax]
                    }
                } else {
                    var pv: Vertex = first.prev
                    while pv !== first && pv.pt.y == first.pt.y { pv = pv.prev }
                    if pv === first { continue }  // only open paths can be flat
                    goingUp = pv.pt.y > first.pt.y
                }

                let goingUp0 = goingUp
                var pv: Vertex = first
                var currV: Vertex = first.next
                while currV !== first {
                    if currV.pt.y > pv.pt.y && goingUp {
                        pv.flags.insert(.localMax)
                        goingUp = false
                    } else if currV.pt.y < pv.pt.y && !goingUp {
                        goingUp = true
                        addLocMin(pv, polytype, isOpen)
                    }
                    pv = currV
                    currV = currV.next
                }

                if isOpen {
                    pv.flags.insert(.openEnd)
                    if goingUp { pv.flags.insert(.localMax) } else { addLocMin(pv, polytype, isOpen) }
                } else if goingUp != goingUp0 {
                    if goingUp0 { addLocMin(pv, polytype, false) } else { pv.flags.insert(.localMax) }
                }
            }
            vertexLists.append(vertices)
        }

        private func addLocMin(_ vert: Vertex, _ polytype: PathType, _ isOpen: Bool) {
            // each vertex once
            if vert.flags.contains(.localMin) { return }
            vert.flags.insert(.localMin)
            minimaList.append(LocalMinima(vert, polytype, isOpen))
        }

        // MARK: Housekeeping

        private func cleanUp() {
            actives = nil
            sel = nil
            for e in allActives {
                e.prevInAEL = nil; e.nextInAEL = nil; e.prevInSEL = nil; e.nextInSEL = nil; e.jump = nil; e.outrec = nil
            }
            allActives.removeAll()
            scanlines = ScanlineHeap()
            intersectNodes.removeAll()
            for op in allOutPts {
                op.next = nil; op.prev = nil; op.outrec = nil
            }
            allOutPts.removeAll()
            for o in outrecList {
                o.owner = nil; o.frontEdge = nil; o.backEdge = nil; o.pts = nil; o.polypath = nil; o.splits = []
                o.recursiveSplit = nil; o.pipIndex = nil
            }
            outrecList.removeAll()
            horzSegList.removeAll()
            horzJoinList.removeAll()
        }

        private func disposeVerticesAndLocalMinima() {
            minimaList.removeAll()
            for list in vertexLists {
                for v in list { v.next = nil; v.prev = nil }
            }
            vertexLists.removeAll()
        }

        private func reset() {
            if !minimaListSorted {
                // lowest first (y down: the greatest y), then from the left
                stableSort(&minimaList) { a, b in
                    a.vertex.pt.y != b.vertex.pt.y ? b.vertex.pt.y < a.vertex.pt.y : b.vertex.pt.x > a.vertex.pt.x
                }
                minimaListSorted = true
            }
            for lm in minimaList.reversed() { scanlines.push(lm.vertex.pt.y) }
            currentLocMin = 0
            actives = nil
            sel = nil
            succeeded = true
        }

        private func setZ(_ e1: Active, _ e2: Active, _ ip: inout Point64) {
            guard let zCallback else { return }
            // subject vertices before clip vertices
            if getPolyType(e1) == .subject {
                if ip == e1.bot { ip.z = e1.bot.z }
                else if ip == e1.top { ip.z = e1.top.z }
                else if ip == e2.bot { ip.z = e2.bot.z }
                else if ip == e2.top { ip.z = e2.top.z }
                else { ip.z = defaultZ }
                zCallback(e1.bot, e1.top, e2.bot, e2.top, &ip)
            } else {
                if ip == e2.bot { ip.z = e2.bot.z }
                else if ip == e2.top { ip.z = e2.top.z }
                else if ip == e1.bot { ip.z = e1.bot.z }
                else if ip == e1.top { ip.z = e1.top.z }
                else { ip.z = defaultZ }
                zCallback(e2.bot, e2.top, e1.bot, e1.top, &ip)
            }
        }

        private func popScanline() -> Int? {
            guard let y = scanlines.pop() else { return nil }
            while scanlines.top == y { _ = scanlines.pop() }  // the same y once
            return y
        }

        private func popLocalMinima(_ y: Int) -> LocalMinima? {
            guard currentLocMin < minimaList.count, minimaList[currentLocMin].vertex.pt.y == y else { return nil }
            currentLocMin += 1
            return minimaList[currentLocMin - 1]
        }

        // MARK: Winding

        private func isContributingClosed(_ e: Active) -> Bool {
            switch fillrule {
            case .evenOdd: break
            case .nonZero: if abs(e.windCnt) != 1 { return false }
            case .positive: if e.windCnt != 1 { return false }
            case .negative: if e.windCnt != -1 { return false }
            }

            switch cliptype {
            case .noClip:
                return false
            case .intersection:
                switch fillrule {
                case .positive: return e.windCnt2 > 0
                case .negative: return e.windCnt2 < 0
                default: return e.windCnt2 != 0
                }
            case .union:
                switch fillrule {
                case .positive: return e.windCnt2 <= 0
                case .negative: return e.windCnt2 >= 0
                default: return e.windCnt2 == 0
                }
            case .difference:
                let result: Bool
                switch fillrule {
                case .positive: result = e.windCnt2 <= 0
                case .negative: result = e.windCnt2 >= 0
                default: result = e.windCnt2 == 0
                }
                return getPolyType(e) == .subject ? result : !result
            case .xor:
                return true
            }
        }

        private func isContributingOpen(_ e: Active) -> Bool {
            let isInClip: Bool, isInSubj: Bool
            switch fillrule {
            case .positive:
                isInClip = e.windCnt2 > 0
                isInSubj = e.windCnt > 0
            case .negative:
                isInClip = e.windCnt2 < 0
                isInSubj = e.windCnt < 0
            default:
                isInClip = e.windCnt2 != 0
                isInSubj = e.windCnt != 0
            }
            switch cliptype {
            case .intersection: return isInClip
            case .union: return !isInSubj && !isInClip
            default: return !isInClip
            }
        }

        /// An edge's winding counts (the higher of the two regions it parts), from the nearest closed edge of its
        /// type to its left, and then the other type's edges to its left
        private func setWindCountForClosedPathEdge(_ e: Active) {
            var e2 = e.prevInAEL
            let pt = getPolyType(e)
            while let x = e2, getPolyType(x) != pt || isOpen(x) { e2 = x.prevInAEL }

            if e2 == nil {
                e.windCnt = e.windDx
                e2 = actives
            } else if fillrule == .evenOdd {
                e.windCnt = e.windDx
                e.windCnt2 = e2!.windCnt2
                e2 = e2!.nextInAEL
            } else {
                let x = e2!
                // (non-zero, positive or negative: the region on the right of an edge whose count goes its way is
                // filled)
                if x.windCnt * x.windDx < 0 {
                    // opposite ways: e is outside x
                    if abs(x.windCnt) > 1 {
                        // outside x, but still inside another
                        e.windCnt = x.windDx * e.windDx < 0 ? x.windCnt : x.windCnt + e.windDx
                    } else {
                        // outside all of its type
                        e.windCnt = isOpen(e) ? 1 : e.windDx
                    }
                } else {
                    // e is inside x
                    e.windCnt = x.windDx * e.windDx < 0 ? x.windCnt : x.windCnt + e.windDx
                }
                e.windCnt2 = x.windCnt2
                e2 = x.nextInAEL
            }

            if fillrule == .evenOdd {
                while let x = e2, x !== e {
                    if getPolyType(x) != pt && !isOpen(x) { e.windCnt2 = e.windCnt2 == 0 ? 1 : 0 }
                    e2 = x.nextInAEL
                }
            } else {
                while let x = e2, x !== e {
                    if getPolyType(x) != pt && !isOpen(x) { e.windCnt2 += x.windDx }
                    e2 = x.nextInAEL
                }
            }
        }

        private func setWindCountForOpenPathEdge(_ e: Active) {
            var e2 = actives
            if fillrule == .evenOdd {
                var cnt1 = 0, cnt2 = 0
                while let x = e2, x !== e {
                    if getPolyType(x) == .clip { cnt2 += 1 } else if !isOpen(x) { cnt1 += 1 }
                    e2 = x.nextInAEL
                }
                e.windCnt = isOdd(cnt1) ? 1 : 0
                e.windCnt2 = isOdd(cnt2) ? 1 : 0
            } else {
                while let x = e2, x !== e {
                    if getPolyType(x) == .clip { e.windCnt2 += x.windDx } else if !isOpen(x) { e.windCnt += x.windDx }
                    e2 = x.nextInAEL
                }
            }
        }

        /// Whether newcomer goes to the right of resident in the active edge list
        private func isValidAelOrder(_ resident: Active, _ newcomer: Active) -> Bool {
            if newcomer.currX != resident.currX { return newcomer.currX > resident.currX }

            // which way resident.top, newcomer.bot, newcomer.top turns
            let i = crossProductSign(resident.top, newcomer.bot, newcomer.top)
            if i != 0 { return i < 0 }

            // collinear: for open paths starting here, by the way they are about to turn
            if !isMaxima(resident) && resident.top.y > newcomer.top.y {
                return crossProductSign(newcomer.bot, resident.top, nextVertex(resident).pt) <= 0
            } else if !isMaxima(newcomer) && newcomer.top.y > resident.top.y {
                return crossProductSign(newcomer.bot, newcomer.top, nextVertex(newcomer).pt) >= 0
            }

            let y = newcomer.bot.y
            let newcomerIsLeft = newcomer.isLeftBound
            if resident.bot.y != y || resident.localMin.vertex.pt.y != y {
                return newcomer.isLeftBound
            } else if resident.isLeftBound != newcomerIsLeft {
                // resident just inserted too
                return newcomerIsLeft
            } else if isCollinear(prevPrevVertex(resident).pt, resident.bot, resident.top) {
                return true
            } else {
                // by the turn of the other bound
                return (crossProductSign(prevPrevVertex(resident).pt, newcomer.bot, prevPrevVertex(newcomer).pt) > 0) == newcomerIsLeft
            }
        }

        private func insertLeftEdge(_ e: Active) {
            guard let first = actives else {
                e.prevInAEL = nil
                e.nextInAEL = nil
                actives = e
                return
            }
            if !isValidAelOrder(first, e) {
                e.prevInAEL = nil
                e.nextInAEL = first
                first.prevInAEL = e
                actives = e
            } else {
                var e2: Active? = first
                while let n = e2!.nextInAEL, isValidAelOrder(n, e) { e2 = n }
                if e2!.joinWith == .right { e2 = e2!.nextInAEL }
                guard let x = e2 else { return }
                e.nextInAEL = x.nextInAEL
                x.nextInAEL?.prevInAEL = e
                e.prevInAEL = x
                x.nextInAEL = e
            }
        }

        private func insertRightEdge(_ e: Active, _ e2: Active) {
            e2.nextInAEL = e.nextInAEL
            e.nextInAEL?.prevInAEL = e2
            e2.prevInAEL = e
            e.nextInAEL = e2
        }

        private func newActive() -> Active {
            let e = Active()
            allActives.append(e)
            return e
        }

        private func newOutPt(_ pt: Point64, _ outrec: OutRec) -> OutPt {
            let op = OutPt(pt, outrec)
            op.next = op
            op.prev = op
            allOutPts.append(op)
            return op
        }

        private func insertLocalMinimaIntoAEL(_ botY: Int) {
            // the local minima at botY (horizontal ones' edges hold the minimum's vertex.prev)
            while let localMinima = popLocalMinima(botY) {
                var leftBound: Active?
                if !localMinima.vertex.flags.contains(.openStart) {
                    let lb = newActive()
                    lb.bot = localMinima.vertex.pt
                    lb.currX = lb.bot.x
                    lb.windDx = -1
                    lb.vertexTop = localMinima.vertex.prev  // descending
                    lb.top = lb.vertexTop.pt
                    lb.localMin = localMinima
                    setDx(lb)
                    leftBound = lb
                }

                var rightBound: Active?
                if !localMinima.vertex.flags.contains(.openEnd) {
                    let rb = newActive()
                    rb.bot = localMinima.vertex.pt
                    rb.currX = rb.bot.x
                    rb.windDx = 1
                    rb.vertexTop = localMinima.vertex.next  // ascending
                    rb.top = rb.vertexTop.pt
                    rb.localMin = localMinima
                    setDx(rb)
                    rightBound = rb
                }

                // the left bound is the descending one so far: swapped if it is not on the left
                if let lb = leftBound, let rb = rightBound {
                    if isHorizontal(lb) {
                        if isHeadingRightHorz(lb) { swap(&leftBound, &rightBound) }
                    } else if isHorizontal(rb) {
                        if isHeadingLeftHorz(rb) { swap(&leftBound, &rightBound) }
                    } else if lb.dx < rb.dx {
                        swap(&leftBound, &rightBound)
                    }
                } else if leftBound == nil {
                    leftBound = rightBound
                    rightBound = nil
                }

                let lb = leftBound!
                let contributing: Bool
                lb.isLeftBound = true
                insertLeftEdge(lb)

                if isOpen(lb) {
                    setWindCountForOpenPathEdge(lb)
                    contributing = isContributingOpen(lb)
                } else {
                    setWindCountForClosedPathEdge(lb)
                    contributing = isContributingClosed(lb)
                }

                if let rb = rightBound {
                    rb.isLeftBound = false
                    rb.windCnt = lb.windCnt
                    rb.windCnt2 = lb.windCnt2
                    insertRightEdge(lb, rb)
                    if contributing {
                        addLocalMinPoly(lb, rb, lb.bot, true)
                        if !isHorizontal(lb) { checkJoinLeft(lb, lb.bot) }
                    }

                    while let n = rb.nextInAEL, isValidAelOrder(n, rb) {
                        intersectEdges(rb, n, rb.bot)
                        swapPositionsInAEL(rb, rb.nextInAEL!)
                    }

                    if isHorizontal(rb) {
                        pushHorz(rb)
                    } else {
                        checkJoinRight(rb, rb.bot)
                        scanlines.push(rb.top.y)
                    }
                } else if contributing {
                    startOpenPath(lb, lb.bot)
                }

                if isHorizontal(lb) { pushHorz(lb) } else { scanlines.push(lb.top.y) }
            }
        }

        private func pushHorz(_ e: Active) {
            e.nextInSEL = sel
            sel = e
        }

        private func popHorz() -> Active? {
            guard let e = sel else { return nil }
            sel = e.nextInSEL
            return e
        }

        // MARK: Output paths

        @discardableResult
        private func addLocalMinPoly(_ e1: Active, _ e2: Active, _ pt: Point64, _ isNew: Bool = false) -> OutPt {
            let outrec = newOutRec()
            e1.outrec = outrec
            e2.outrec = outrec

            if isOpen(e1) {
                outrec.owner = nil
                outrec.isOpen = true
                if e1.windDx > 0 { setSides(outrec, e1, e2) } else { setSides(outrec, e2, e1) }
            } else {
                // (the edges' wind directions are the input paths', not the output's: its front edge is the
                // ascending one)
                if let prevHotEdge = getPrevHotEdge(e1) {
                    if usingPolytree { setOwner(outrec, prevHotEdge.outrec!) }
                    if outrecIsAscending(prevHotEdge) == isNew { setSides(outrec, e2, e1) } else { setSides(outrec, e1, e2) }
                } else {
                    outrec.owner = nil
                    if isNew { setSides(outrec, e1, e2) } else { setSides(outrec, e2, e1) }
                }
            }

            let op = newOutPt(pt, outrec)
            outrec.pts = op
            return op
        }

        @discardableResult
        private func addLocalMaxPoly(_ e1: Active, _ e2: Active, _ pt: Point64) -> OutPt? {
            if isJoined(e1) { split(e1, pt) }
            if isJoined(e2) { split(e2, pt) }

            if isFront(e1) == isFront(e2) {
                if isOpenEnd(e1) {
                    swapFrontBackSides(e1.outrec!)
                } else if isOpenEnd(e2) {
                    swapFrontBackSides(e2.outrec!)
                } else {
                    succeeded = false
                    return nil
                }
            }

            var result = addOutPt(e1, pt)
            if e1.outrec === e2.outrec {
                let outrec = e1.outrec!
                outrec.pts = result

                if usingPolytree {
                    // (likely not the real owner: RecursiveCheckOwners finds that)
                    if let e = getPrevHotEdge(e1) { setOwner(outrec, e.outrec!) } else { outrec.owner = nil }
                }
                uncoupleOutRec(e1)
                result = outrec.pts!
                if let owner = outrec.owner, owner.frontEdge == nil { outrec.owner = getRealOutRec(owner) }
            } else if isOpen(e1) {
                // (and so as to keep the outrec's winding)
                if e1.windDx < 0 { joinOutrecPaths(e1, e2) } else { joinOutrecPaths(e2, e1) }
            } else if e1.outrec!.idx < e2.outrec!.idx {
                joinOutrecPaths(e1, e2)
            } else {
                joinOutrecPaths(e2, e1)
            }
            return result
        }

        /// e2's path joined onto e1's, and e2's emptied
        private func joinOutrecPaths(_ e1: Active, _ e2: Active) {
            let or1 = e1.outrec!, or2 = e2.outrec!
            let p1St = or1.pts!, p2St = or2.pts!
            let p1End = p1St.next!, p2End = p2St.next!
            if isFront(e1) {
                p2End.prev = p1St
                p1St.next = p2End
                p2St.next = p1End
                p1End.prev = p2St
                or1.pts = p2St
                or1.frontEdge = or2.frontEdge
                or1.frontEdge?.outrec = or1
            } else {
                p1End.prev = p2St
                p2St.next = p1End
                p1St.next = p2End
                p2End.prev = p1St
                or1.backEdge = or2.backEdge
                or1.backEdge?.outrec = or1
            }

            // e2's outrec has no points now
            or2.frontEdge = nil
            or2.backEdge = nil
            or2.pts = nil

            if isOpenEnd(e1) {
                or2.pts = or1.pts
                or1.pts = nil
            } else {
                setOwner(or2, or1)
            }

            // (e1 and e2 are maxima, about to leave the active edges)
            e1.outrec = nil
            e2.outrec = nil
        }

        private func newOutRec() -> OutRec {
            let result = OutRec()
            result.idx = outrecList.count
            outrecList.append(result)
            return result
        }

        @discardableResult
        private func addOutPt(_ e: Active, _ pt: Point64) -> OutPt {
            // a ring whose front is outrec.pts, its back outrec.pts.next
            let outrec = e.outrec!
            let toFront = isFront(e)
            let opFront = outrec.pts!, opBack = opFront.next!

            if toFront {
                if pt == opFront.pt { return opFront }
            } else if pt == opBack.pt {
                return opBack
            }

            let newOp = newOutPt(pt, outrec)
            opBack.prev = newOp
            newOp.prev = opFront
            newOp.next = opBack
            opFront.next = newOp
            if toFront { outrec.pts = newOp }
            return newOp
        }

        func cleanCollinear(_ outrec: OutRec?) {
            guard let outrec = getRealOutRec(outrec), !outrec.isOpen else { return }
            if !isValidClosedPath(outrec.pts) {
                outrec.pts = nil
                return
            }

            var startOp = outrec.pts!, op2 = startOp
            while true {
                // (with collinear points kept, only 180° spikes go)
                if isCollinear(op2.prev.pt, op2.pt, op2.next.pt) &&
                    (op2.pt == op2.prev.pt || op2.pt == op2.next.pt || !preserveCollinear ||
                        dotProduct(op2.prev.pt, op2.pt, op2.next.pt) < 0) {
                    if op2 === outrec.pts { outrec.pts = op2.prev }
                    op2 = disposeOutPt(op2)
                    if !isValidClosedPath(op2) {
                        outrec.pts = nil
                        return
                    }
                    startOp = op2
                    continue
                }
                op2 = op2.next
                if op2 === startOp { break }
            }
            fixSelfIntersects(outrec)
        }

        /// splitOp.prev to splitOp crosses splitOp.next to its next: the ring parted where they cross
        private func doSplitOp(_ outrec: OutRec, _ splitOp: OutPt) {
            let prevOp = splitOp.prev!
            let nextNextOp = splitOp.next.next!
            outrec.pts = prevOp

            var ip = Point64(0, 0)
            _ = getLineIntersectPt(prevOp.pt, splitOp.pt, splitOp.next.pt, nextNextOp.pt, &ip)
            if let zCallback { zCallback(prevOp.pt, splitOp.pt, splitOp.next.pt, nextNextOp.pt, &ip) }

            let area1 = area(prevOp)
            let absArea1 = abs(area1)
            if absArea1 < 2 {
                outrec.pts = nil
                return
            }

            let area2 = areaTriangle(ip, splitOp.pt, splitOp.next.pt)
            let absArea2 = abs(area2)

            // splitOp and splitOp.next out of the ring, the crossing in their place
            if ip == prevOp.pt || ip == nextNextOp.pt {
                nextNextOp.prev = prevOp
                prevOp.next = nextNextOp
            } else {
                let newOp2 = newOutPt(ip, prevOp.outrec)
                newOp2.prev = prevOp
                newOp2.next = nextNextOp
                nextNextOp.prev = newOp2
                prevOp.next = newOp2
            }

            // area1 is the ring's before the split, area2 the triangle's of splitOp and splitOp.next: of the same
            // sign only when the triangle is the bigger, or there is more than one crossing
            if absArea2 >= 1 && (absArea2 > absArea1 || (area2 > 0) == (area1 > 0)) {
                let newOr = newOutRec()
                newOr.owner = outrec.owner
                splitOp.outrec = newOr
                splitOp.next.outrec = newOr
                let newOp = newOutPt(ip, newOr)
                newOp.prev = splitOp.next
                newOp.next = splitOp
                newOr.pts = newOp
                splitOp.prev = newOp
                splitOp.next.next = newOp

                if usingPolytree {
                    if path2ContainsPath1(prevOp, newOp) {
                        newOr.splits = [outrec]
                    } else {
                        outrec.splits.append(newOr)
                    }
                }
            }
        }

        private func fixSelfIntersects(_ outrec: OutRec) {
            var op2 = outrec.pts!
            if op2.prev === op2.next.next { return }  // a triangle cannot cross itself
            while true {
                if segmentsIntersect(op2.prev.pt, op2.pt, op2.next.pt, op2.next.next.pt) {
                    if op2 === outrec.pts || op2.next === outrec.pts { outrec.pts = outrec.pts!.prev }
                    doSplitOp(outrec, op2)
                    guard let pts = outrec.pts else { break }
                    op2 = pts
                    if op2.prev === op2.next.next { break }
                    continue
                } else {
                    op2 = op2.next
                }
                if op2 === outrec.pts { break }
            }
        }

        @discardableResult
        private func startOpenPath(_ e: Active, _ pt: Point64) -> OutPt {
            let outrec = newOutRec()
            outrec.isOpen = true
            if e.windDx > 0 {
                outrec.frontEdge = e
                outrec.backEdge = nil
            } else {
                outrec.frontEdge = nil
                outrec.backEdge = e
            }
            e.outrec = outrec
            let op = newOutPt(pt, outrec)
            outrec.pts = op
            return op
        }

        private func trimHorz(_ horzEdge: Active, _ preserveCollinear: Bool) {
            var wasTrimmed = false
            var pt = nextVertex(horzEdge).pt
            while pt.y == horzEdge.top.y {
                // 180° spikes always go (in closed paths); collinear points only when they need not be kept
                if preserveCollinear && (pt.x < horzEdge.top.x) != (horzEdge.bot.x < horzEdge.top.x) { break }
                horzEdge.vertexTop = nextVertex(horzEdge)
                horzEdge.top = pt
                wasTrimmed = true
                if isMaxima(horzEdge) { break }
                pt = nextVertex(horzEdge).pt
            }
            if wasTrimmed { setDx(horzEdge) }
        }

        private func updateEdgeIntoAEL(_ e: Active) {
            e.bot = e.top
            e.vertexTop = nextVertex(e)
            e.top = e.vertexTop.pt
            e.currX = e.bot.x
            setDx(e)

            if isJoined(e) { split(e, e.bot) }

            if isHorizontal(e) {
                if !isOpen(e) { trimHorz(e, preserveCollinear) }
                return
            }

            scanlines.push(e.top.y)
            checkJoinLeft(e, e.bot)
            checkJoinRight(e, e.bot, true)
        }

        private func findEdgeWithMatchingLocMin(_ e: Active) -> Active? {
            var result = e.nextInAEL
            while let r = result {
                if r.localMin === e.localMin { return r }
                if !isHorizontal(r) && e.bot != r.bot { result = nil } else { result = r.nextInAEL }
            }
            result = e.prevInAEL
            while let r = result {
                if r.localMin === e.localMin { return r }
                if !isHorizontal(r) && e.bot != r.bot { return nil }
                result = r.prevInAEL
            }
            return result
        }

        // MARK: Intersections

        private func intersectEdges(_ e1: Active, _ e2: Active, _ pt: Point64) {
            // open paths' intersections on their own
            if hasOpenPaths && (isOpen(e1) || isOpen(e2)) {
                if isOpen(e1) && isOpen(e2) { return }
                let edgeO: Active, edgeC: Active
                if isOpen(e1) {
                    edgeO = e1
                    edgeC = e2
                } else {
                    edgeO = e2
                    edgeC = e1
                }
                if isJoined(edgeC) { split(edgeC, pt) }

                if abs(edgeC.windCnt) != 1 { return }
                switch cliptype {
                case .union:
                    if !isHotEdge(edgeC) { return }
                default:
                    if edgeC.localMin.polytype == .subject { return }
                }

                switch fillrule {
                case .positive: if edgeC.windCnt != 1 { return }
                case .negative: if edgeC.windCnt != -1 { return }
                default: if abs(edgeC.windCnt) != 1 { return }
                }

                // its contribution toggled
                let resultOp: OutPt
                if isHotEdge(edgeO) {
                    resultOp = addOutPt(edgeO, pt)
                    if isFront(edgeO) { edgeO.outrec!.frontEdge = nil } else { edgeO.outrec!.backEdge = nil }
                    edgeO.outrec = nil
                } else if pt == edgeO.localMin.vertex.pt && !isOpenEnd(edgeO.localMin.vertex) {
                    // horizontals can pass under open paths at local minima: joined to the other side of the
                    // minimum, if it is hot
                    if let e3 = findEdgeWithMatchingLocMin(edgeO), isHotEdge(e3) {
                        edgeO.outrec = e3.outrec
                        if edgeO.windDx > 0 { setSides(e3.outrec!, edgeO, e3) } else { setSides(e3.outrec!, e3, edgeO) }
                        return
                    }
                    resultOp = startOpenPath(edgeO, pt)
                } else {
                    resultOp = startOpenPath(edgeO, pt)
                }

                if zCallback != nil { setZ(edgeO, edgeC, &resultOp.pt) }
                return
            }

            // closed paths from here on
            if isJoined(e1) { split(e1, pt) }
            if isJoined(e2) { split(e2, pt) }

            // the winding counts
            var oldE1WindCnt: Int, oldE2WindCnt: Int
            if e1.localMin.polytype == e2.localMin.polytype {
                if fillrule == .evenOdd {
                    oldE1WindCnt = e1.windCnt
                    e1.windCnt = e2.windCnt
                    e2.windCnt = oldE1WindCnt
                } else {
                    if e1.windCnt + e2.windDx == 0 { e1.windCnt = -e1.windCnt } else { e1.windCnt += e2.windDx }
                    if e2.windCnt - e1.windDx == 0 { e2.windCnt = -e2.windCnt } else { e2.windCnt -= e1.windDx }
                }
            } else {
                if fillrule != .evenOdd {
                    e1.windCnt2 += e2.windDx
                    e2.windCnt2 -= e1.windDx
                } else {
                    e1.windCnt2 = e1.windCnt2 == 0 ? 1 : 0
                    e2.windCnt2 = e2.windCnt2 == 0 ? 1 : 0
                }
            }

            switch fillrule {
            case .evenOdd, .nonZero:
                oldE1WindCnt = abs(e1.windCnt)
                oldE2WindCnt = abs(e2.windCnt)
            default:
                if fillrule == fillpos {
                    oldE1WindCnt = e1.windCnt
                    oldE2WindCnt = e2.windCnt
                } else {
                    oldE1WindCnt = -e1.windCnt
                    oldE2WindCnt = -e2.windCnt
                }
            }

            let e1WindCntIn01 = oldE1WindCnt == 0 || oldE1WindCnt == 1
            let e2WindCntIn01 = oldE2WindCnt == 0 || oldE2WindCnt == 1
            if (!isHotEdge(e1) && !e1WindCntIn01) || (!isHotEdge(e2) && !e2WindCntIn01) { return }

            // the intersection itself
            if isHotEdge(e1) && isHotEdge(e2) {
                if (oldE1WindCnt != 0 && oldE1WindCnt != 1) || (oldE2WindCnt != 0 && oldE2WindCnt != 1) ||
                    (e1.localMin.polytype != e2.localMin.polytype && cliptype != .xor) {
                    let resultOp = addLocalMaxPoly(e1, e2, pt)
                    if zCallback != nil, let resultOp { setZ(e1, e2, &resultOp.pt) }
                } else if isFront(e1) || e1.outrec === e2.outrec {
                    // (not strictly needed, but polygons that touch only at a vertex are better apart)
                    let resultOp = addLocalMaxPoly(e1, e2, pt)
                    let op2 = addLocalMinPoly(e1, e2, pt)
                    if zCallback != nil, let resultOp { setZ(e1, e2, &resultOp.pt) }
                    if zCallback != nil { setZ(e1, e2, &op2.pt) }
                } else {
                    let resultOp = addOutPt(e1, pt)
                    let op2 = addOutPt(e2, pt)
                    if zCallback != nil {
                        setZ(e1, e2, &resultOp.pt)
                        setZ(e1, e2, &op2.pt)
                    }
                    swapOutrecs(e1, e2)
                }
            } else if isHotEdge(e1) {
                let resultOp = addOutPt(e1, pt)
                if zCallback != nil { setZ(e1, e2, &resultOp.pt) }
                swapOutrecs(e1, e2)
            } else if isHotEdge(e2) {
                let resultOp = addOutPt(e2, pt)
                if zCallback != nil { setZ(e1, e2, &resultOp.pt) }
                swapOutrecs(e1, e2)
            } else {
                let e1Wc2: Int, e2Wc2: Int
                switch fillrule {
                case .evenOdd, .nonZero:
                    e1Wc2 = abs(e1.windCnt2)
                    e2Wc2 = abs(e2.windCnt2)
                default:
                    if fillrule == fillpos {
                        e1Wc2 = e1.windCnt2
                        e2Wc2 = e2.windCnt2
                    } else {
                        e1Wc2 = -e1.windCnt2
                        e2Wc2 = -e2.windCnt2
                    }
                }

                if !isSamePolyType(e1, e2) {
                    let resultOp = addLocalMinPoly(e1, e2, pt, false)
                    if zCallback != nil { setZ(e1, e2, &resultOp.pt) }
                } else if oldE1WindCnt == 1 && oldE2WindCnt == 1 {
                    var resultOp: OutPt?
                    switch cliptype {
                    case .union:
                        if e1Wc2 <= 0 && e2Wc2 <= 0 { resultOp = addLocalMinPoly(e1, e2, pt, false) }
                    case .difference:
                        if (getPolyType(e1) == .clip && e1Wc2 > 0 && e2Wc2 > 0) ||
                            (getPolyType(e1) == .subject && e1Wc2 <= 0 && e2Wc2 <= 0) {
                            resultOp = addLocalMinPoly(e1, e2, pt, false)
                        }
                    case .xor:
                        resultOp = addLocalMinPoly(e1, e2, pt, false)
                    default:
                        if e1Wc2 > 0 && e2Wc2 > 0 { resultOp = addLocalMinPoly(e1, e2, pt, false) }
                    }
                    if let resultOp, zCallback != nil { setZ(e1, e2, &resultOp.pt) }
                }
            }
        }

        private func deleteFromAEL(_ e: Active) {
            let prev = e.prevInAEL, next = e.nextInAEL
            if prev == nil && next == nil && e !== actives { return }  // already deleted
            if let prev { prev.nextInAEL = next } else { actives = next }
            next?.prevInAEL = prev
            e.prevInAEL = nil
            e.nextInAEL = nil
        }

        private func adjustCurrXAndCopyToSEL(_ topY: Int) {
            var e = actives
            sel = e
            while let x = e {
                x.prevInSEL = x.prevInAEL
                x.nextInSEL = x.nextInAEL
                x.jump = x.nextInSEL
                // (joined edges can be left joined here: IntersectEdges splits them when it must)
                x.currX = topX(x, topY)
                e = x.nextInAEL
            }
        }

        private func executeInternal(_ ct: ClipType, _ fillRule: FillRule, _ usePolytrees: Bool) -> Bool {
            cliptype = ct
            fillrule = fillRule
            usingPolytree = usePolytrees
            reset()
            guard ct != .noClip, var y = popScanline() else { return true }

            while succeeded {
                insertLocalMinimaIntoAEL(y)
                while let e = popHorz() { doHorizontal(e) }
                if !horzSegList.isEmpty {
                    convertHorzSegsToJoins()
                    horzSegList.removeAll()
                }
                botY = y  // the bottom of the scanbeam
                guard let next = popScanline() else { break }
                y = next  // its top
                doIntersections(y)
                doTopOfScanbeam(y)
                while let e = popHorz() { doHorizontal(e) }
            }
            if succeeded { processHorzJoins() }
            return succeeded
        }

        // MARK: Horizontal joins

        private static func fixOutRecPts(_ outrec: OutRec) {
            var op = outrec.pts!
            repeat {
                op.outrec = outrec
                op = op.next
            } while op !== outrec.pts
        }

        private static func setHorzSegHeadingForward(_ hs: HorzSegment, _ opP: OutPt, _ opN: OutPt) -> Bool {
            if opP.pt.x == opN.pt.x { return false }
            if opP.pt.x < opN.pt.x {
                hs.leftOp = opP
                hs.rightOp = opN
                hs.leftToRight = true
            } else {
                hs.leftOp = opN
                hs.rightOp = opP
                hs.leftToRight = false
            }
            return true
        }

        private static func updateHorzSegment(_ hs: HorzSegment) -> Bool {
            let op = hs.leftOp!
            let outrec = getRealOutRec(op.outrec)!
            let outrecHasEdges = outrec.frontEdge != nil
            let currY = op.pt.y
            var opP = op, opN = op
            if outrecHasEdges {
                let opA = outrec.pts!, opZ = opA.next!
                while opP !== opZ && opP.prev.pt.y == currY { opP = opP.prev }
                while opN !== opA && opN.next.pt.y == currY { opN = opN.next }
            } else {
                while opP.prev !== opN && opP.prev.pt.y == currY { opP = opP.prev }
                while opN.next !== opP && opN.next.pt.y == currY { opN = opN.next }
            }
            let result = setHorzSegHeadingForward(hs, opP, opN) && !hs.leftOp!.horz
            if result { hs.leftOp!.horz = true } else { hs.rightOp = nil }  // (for sorting)
            return result
        }

        private func duplicateOp(_ op: OutPt, _ insertAfter: Bool) -> OutPt {
            let result = newOutPt(op.pt, op.outrec)
            if insertAfter {
                result.next = op.next
                result.next.prev = result
                result.prev = op
                op.next = result
            } else {
                result.prev = op.prev
                result.prev.next = result
                result.next = op
                op.prev = result
            }
            return result
        }

        private func convertHorzSegsToJoins() {
            var j = 0
            for hs in horzSegList where Self.updateHorzSegment(hs) { j += 1 }
            if j < 2 { return }

            stableSort(&horzSegList) { hs1, hs2 in
                if hs1.rightOp == nil || hs2.rightOp == nil { return hs1.rightOp != nil }
                return hs2.leftOp!.pt.x > hs1.leftOp!.pt.x
            }

            for i1 in 0..<(j - 1) {
                let hs1 = horzSegList[i1]
                for i2 in (i1 + 1)..<j {
                    let hs2 = horzSegList[i2]
                    if hs2.leftOp!.pt.x >= hs1.rightOp!.pt.x || hs2.leftToRight == hs1.leftToRight ||
                        hs2.rightOp!.pt.x <= hs1.leftOp!.pt.x { continue }
                    let currY = hs1.leftOp!.pt.y
                    if hs1.leftToRight {
                        while hs1.leftOp!.next.pt.y == currY && hs1.leftOp!.next.pt.x <= hs2.leftOp!.pt.x {
                            hs1.leftOp = hs1.leftOp!.next
                        }
                        while hs2.leftOp!.prev.pt.y == currY && hs2.leftOp!.prev.pt.x <= hs1.leftOp!.pt.x {
                            hs2.leftOp = hs2.leftOp!.prev
                        }
                        let join = HorzJoin(op1: duplicateOp(hs1.leftOp!, true), op2: duplicateOp(hs2.leftOp!, false))
                        horzJoinList.append(join)
                    } else {
                        while hs1.leftOp!.prev.pt.y == currY && hs1.leftOp!.prev.pt.x <= hs2.leftOp!.pt.x {
                            hs1.leftOp = hs1.leftOp!.prev
                        }
                        while hs2.leftOp!.next.pt.y == currY && hs2.leftOp!.next.pt.x <= hs1.leftOp!.pt.x {
                            hs2.leftOp = hs2.leftOp!.next
                        }
                        let join = HorzJoin(op1: duplicateOp(hs2.leftOp!, true), op2: duplicateOp(hs1.leftOp!, false))
                        horzJoinList.append(join)
                    }
                }
            }
        }

        private static func moveSplits(_ fromOr: OutRec, _ toOr: OutRec) {
            for s in fromOr.splits where s !== toOr { toOr.splits.append(s) }
            fromOr.splits.removeAll()
        }

        private func processHorzJoins() {
            for j in horzJoinList {
                let or1 = getRealOutRec(j.op1.outrec)!
                var or2 = getRealOutRec(j.op2.outrec)!

                let op1b = j.op1.next!, op2b = j.op2.prev!
                j.op1.next = j.op2
                j.op2.prev = j.op1
                op1b.prev = op2b
                op2b.next = op1b

                if or1 === or2 {
                    // a split, not a join
                    or2 = newOutRec()
                    or2.pts = op1b
                    Self.fixOutRecPts(or2)

                    // or1's pts may have gone to or2
                    if or1.pts!.outrec === or2 {
                        or1.pts = j.op1
                        or1.pts!.outrec = or1
                    }

                    if usingPolytree {
                        if path2ContainsPath1(or1.pts!, or2.pts!) {
                            // the two swapped: or2 inside or1
                            let tmp = or1.pts
                            or1.pts = or2.pts
                            or2.pts = tmp
                            Self.fixOutRecPts(or1)
                            Self.fixOutRecPts(or2)
                            or2.owner = or1
                        } else if path2ContainsPath1(or2.pts!, or1.pts!) {
                            or2.owner = or1
                        } else {
                            or2.owner = or1.owner
                        }
                        or1.splits.append(or2)
                    } else {
                        or2.owner = or1
                    }
                } else {
                    or2.pts = nil
                    if usingPolytree {
                        setOwner(or2, or1)
                        if !or2.splits.isEmpty { Self.moveSplits(or2, or1) }
                    } else {
                        or2.owner = or1
                    }
                }
            }
        }

        // MARK: The sweep

        private func doIntersections(_ topY: Int) {
            if buildIntersectList(topY) {
                processIntersectList()
                intersectNodes.removeAll()
            }
        }

        private func addNewIntersectNode(_ e1: Active, _ e2: Active, _ topY: Int) {
            var ip = Point64(0, 0)
            if !getLineIntersectPt(e1.bot, e1.top, e2.bot, e2.top, &ip) { ip = Point64(e1.currX, topY) }  // parallel

            // rounding can put the point just below or above the scanbeam: put back in it
            if ip.y > botY || ip.y < topY {
                let absDx1 = abs(e1.dx), absDx2 = abs(e2.dx)
                if absDx1 > 100 && absDx2 > 100 {
                    if absDx1 > absDx2 {
                        ip = getClosestPointOnSegment(ip, e1.bot, e1.top)
                    } else {
                        ip = getClosestPointOnSegment(ip, e2.bot, e2.top)
                    }
                } else if absDx1 > 100 {
                    ip = getClosestPointOnSegment(ip, e1.bot, e1.top)
                } else if absDx2 > 100 {
                    ip = getClosestPointOnSegment(ip, e2.bot, e2.top)
                } else {
                    if ip.y < topY { ip.y = topY } else { ip.y = botY }
                    if absDx1 < absDx2 { ip.x = topX(e1, ip.y) } else { ip.x = topX(e2, ip.y) }
                }
            }
            intersectNodes.append(IntersectNode(pt: ip, edge1: e1, edge2: e2))
        }

        /// The crossings in the scanbeam: the edges where they will be at its top, sorted into that order by a merge
        /// sort that swaps only neighbours, each swap a crossing
        private func buildIntersectList(_ topY: Int) -> Bool {
            guard let first = actives, first.nextInAEL != nil else { return false }
            _ = first
            adjustCurrXAndCopyToSEL(topY)

            var left = sel
            while let l0 = left, l0.jump != nil {
                var prevBase: Active?
                while let l = left, l.jump != nil {
                    var currBase = l
                    var leftE: Active = l
                    var right: Active? = l.jump
                    var lEnd = right
                    let rEnd = right!.jump
                    l.jump = rEnd
                    while leftE !== lEnd && right !== rEnd {
                        let r = right!
                        if r.currX < leftE.currX {
                            var tmp = r.prevInSEL!
                            while true {
                                addNewIntersectNode(tmp, r, topY)
                                if tmp === leftE { break }
                                tmp = tmp.prevInSEL!
                            }
                            right = extractFromSEL(r)
                            lEnd = right
                            insert1Before2InSEL(r, leftE)
                            if leftE === currBase {
                                currBase = r
                                currBase.jump = rEnd
                                if let pb = prevBase { pb.jump = currBase } else { sel = currBase }
                            }
                        } else {
                            leftE = leftE.nextInSEL!
                        }
                    }
                    prevBase = currBase
                    left = rEnd
                }
                left = sel
            }
            return !intersectNodes.isEmpty
        }

        private func processIntersectList() {
            // bottom up, then from the left (as std::sort sorts them, so that crossings at the same point come in
            // the same order as in KiCad's build)
            introSort(&intersectNodes) { a, b in a.pt.y == b.pt.y ? a.pt.x < b.pt.x : a.pt.y > b.pt.y }

            // and each between neighbours in the active edge list, the order changed where they are not
            for i in 0..<intersectNodes.count {
                if !edgesAdjacentInAEL(intersectNodes[i]) {
                    var i2 = i + 1
                    while !edgesAdjacentInAEL(intersectNodes[i2]) { i2 += 1 }
                    intersectNodes.swapAt(i, i2)
                }
                let node = intersectNodes[i]
                intersectEdges(node.edge1, node.edge2, node.pt)
                swapPositionsInAEL(node.edge1, node.edge2)
                node.edge1.currX = node.pt.x
                node.edge2.currX = node.pt.x
                checkJoinLeft(node.edge2, node.pt, true)
                checkJoinRight(node.edge1, node.pt, true)
            }
        }

        /// e1, just left of e2, and e2 swapped
        private func swapPositionsInAEL(_ e1: Active, _ e2: Active) {
            let next = e2.nextInAEL
            next?.prevInAEL = e1
            let prev = e1.prevInAEL
            prev?.nextInAEL = e2
            e2.prevInAEL = prev
            e2.nextInAEL = e1
            e1.prevInAEL = e2
            e1.nextInAEL = next
            if e2.prevInAEL == nil { actives = e2 }
        }

        private static func getLastOp(_ hotEdge: Active) -> OutPt {
            let outrec = hotEdge.outrec!
            return hotEdge === outrec.frontEdge ? outrec.pts! : outrec.pts!.next
        }

        private func addTrialHorzJoin(_ op: OutPt) {
            if op.outrec.isOpen { return }
            horzSegList.append(HorzSegment(op))
        }

        /// Which way a horizontal goes, and from where to where; true left to right
        private func resetHorzDirection(_ horz: Active, _ maxVertex: Vertex?, _ horzLeft: inout Int,
                                        _ horzRight: inout Int) -> Bool {
            if horz.bot.x == horz.top.x {
                // going nowhere
                horzLeft = horz.currX
                horzRight = horz.currX
                var e = horz.nextInAEL
                while let x = e, x.vertexTop !== maxVertex { e = x.nextInAEL }
                return e != nil
            } else if horz.currX < horz.top.x {
                horzLeft = horz.currX
                horzRight = horz.top.x
                return true
            } else {
                horzLeft = horz.top.x
                horzRight = horz.currX
                return false
            }
        }

        /// A horizontal edge (and those following it in its bound) at a scanline: crossed with the other edges along
        /// it, as if horizontals at the same y were layered
        private func doHorizontal(_ horz: Active) {
            var pt: Point64
            let horzIsOpen = isOpen(horz)
            let y = horz.bot.y
            let vertexMax = horzIsOpen ? getCurrYMaximaVertexOpen(horz) : getCurrYMaximaVertex(horz)

            var horzLeft = 0, horzRight = 0
            var isLeftToRight = resetHorzDirection(horz, vertexMax, &horzLeft, &horzRight)

            if isHotEdge(horz) {
                let op = addOutPt(horz, Point64(horz.currX, y, horz.bot.z))
                addTrialHorzJoin(op)
            }

            while true {  // consecutive horizontals
                var e = isLeftToRight ? horz.nextInAEL : horz.prevInAEL

                while let x = e {
                    if x.vertexTop === vertexMax {
                        if isHotEdge(horz) && isJoined(x) { split(x, x.top) }
                        if isHotEdge(horz) {
                            while horz.vertexTop !== vertexMax {
                                addOutPt(horz, horz.top)
                                updateEdgeIntoAEL(horz)
                            }
                            if isLeftToRight { addLocalMaxPoly(horz, x, horz.top) } else { addLocalMaxPoly(x, horz, horz.top) }
                        }
                        deleteFromAEL(x)
                        deleteFromAEL(horz)
                        return
                    }

                    // a horizontal maximum goes on to its pair; otherwise it stops at the end of the horizontal
                    if vertexMax !== horz.vertexTop || isOpenEnd(horz) {
                        if (isLeftToRight && x.currX > horzRight) || (!isLeftToRight && x.currX < horzLeft) { break }

                        if x.currX == horz.top.x && !isHorizontal(x) {
                            pt = nextVertex(horz).pt
                            if isLeftToRight {
                                // open paths stop only once past the horizontal's end; others when its next edge
                                // goes out steeper than x
                                if isOpen(x) && !isSamePolyType(x, horz) && !isHotEdge(x) {
                                    if topX(x, pt.y) > pt.x { break }
                                } else if topX(x, pt.y) >= pt.x {
                                    break
                                }
                            } else {
                                if isOpen(x) && !isSamePolyType(x, horz) && !isHotEdge(x) {
                                    if topX(x, pt.y) < pt.x { break }
                                } else if topX(x, pt.y) <= pt.x {
                                    break
                                }
                            }
                        }
                    }

                    pt = Point64(x.currX, horz.bot.y)
                    if isLeftToRight {
                        intersectEdges(horz, x, pt)
                        swapPositionsInAEL(horz, x)
                        checkJoinLeft(x, pt)
                        horz.currX = x.currX
                        e = horz.nextInAEL
                    } else {
                        intersectEdges(x, horz, pt)
                        swapPositionsInAEL(x, horz)
                        checkJoinRight(x, pt)
                        horz.currX = x.currX
                        e = horz.prevInAEL
                    }

                    // (the outrec of the point IntersectEdges added may no longer be the horizontal's)
                    if horz.outrec != nil { addTrialHorzJoin(Self.getLastOp(horz)) }
                }

                // done with the horizontals?
                if horzIsOpen && isOpenEnd(horz) {  // open at its top
                    if isHotEdge(horz) {
                        addOutPt(horz, horz.top)
                        if isFront(horz) { horz.outrec!.frontEdge = nil } else { horz.outrec!.backEdge = nil }
                        horz.outrec = nil
                    }
                    deleteFromAEL(horz)
                    return
                } else if nextVertex(horz).pt.y != horz.top.y {
                    break
                }

                // more horizontals in the bound
                if isHotEdge(horz) { addOutPt(horz, horz.top) }
                updateEdgeIntoAEL(horz)
                isLeftToRight = resetHorzDirection(horz, vertexMax, &horzLeft, &horzRight)
            }

            if isHotEdge(horz) {
                let op = addOutPt(horz, horz.top)
                addTrialHorzJoin(op)
            }
            updateEdgeIntoAEL(horz)  // the end of an intermediate horizontal
        }

        private func doTopOfScanbeam(_ y: Int) {
            sel = nil  // (it flags horizontals here, as PushHorz uses it)
            var e = actives
            while let x = e {
                // (never horizontal here)
                if x.top.y == y {
                    x.currX = x.top.x
                    if isMaxima(x) {
                        e = doMaxima(x)  // the top of a bound
                        continue
                    }
                    // an intermediate vertex
                    if isHotEdge(x) { addOutPt(x, x.top) }
                    updateEdgeIntoAEL(x)
                    if isHorizontal(x) { pushHorz(x) }  // horizontals later
                } else {
                    x.currX = topX(x, y)
                }
                e = x.nextInAEL
            }
        }

        private func doMaxima(_ e: Active) -> Active? {
            let prevE = e.prevInAEL
            var nextE = e.nextInAEL

            if isOpenEnd(e) {
                if isHotEdge(e) { addOutPt(e, e.top) }
                if !isHorizontal(e) {
                    if isHotEdge(e) {
                        if isFront(e) { e.outrec!.frontEdge = nil } else { e.outrec!.backEdge = nil }
                        e.outrec = nil
                    }
                    deleteFromAEL(e)
                }
                return nextE
            }

            guard let maxPair = getMaximaPair(e) else { return nextE }  // its pair is horizontal

            if isJoined(e) { split(e, e.top) }
            if isJoined(maxPair) { split(maxPair, maxPair.top) }

            // (only maxima that are not horizontal here) the edges between the pair first
            while nextE !== maxPair {
                intersectEdges(e, nextE!, e.top)
                swapPositionsInAEL(e, nextE!)
                nextE = e.nextInAEL
            }

            if isOpen(e) {
                if isHotEdge(e) { addLocalMaxPoly(e, maxPair, e.top) }
                deleteFromAEL(maxPair)
                deleteFromAEL(e)
                return prevE != nil ? prevE!.nextInAEL : actives
            }

            // e's next is its pair now
            if isHotEdge(e) { addLocalMaxPoly(e, maxPair, e.top) }
            deleteFromAEL(e)
            deleteFromAEL(maxPair)
            return prevE != nil ? prevE!.nextInAEL : actives
        }

        private func split(_ e: Active, _ pt: Point64) {
            if e.joinWith == .right {
                e.joinWith = .noJoin
                e.nextInAEL!.joinWith = .noJoin
                addLocalMinPoly(e, e.nextInAEL!, pt, true)
            } else {
                e.joinWith = .noJoin
                e.prevInAEL!.joinWith = .noJoin
                addLocalMinPoly(e.prevInAEL!, e, pt, true)
            }
        }

        private func checkJoinLeft(_ e: Active, _ pt: Point64, _ checkCurrX: Bool = false) {
            guard let prev = e.prevInAEL, isHotEdge(e), isHotEdge(prev), !isHorizontal(e), !isHorizontal(prev),
                  !isOpen(e), !isOpen(prev) else { return }
            if (pt.y < e.top.y + 2 || pt.y < prev.top.y + 2) && (e.bot.y > pt.y || prev.bot.y > pt.y) { return }  // trivial

            if checkCurrX {
                if perpendicDistFromLineSqrd(pt, prev.bot, prev.top) > 0.25 { return }
            } else if e.currX != prev.currX {
                return
            }
            if !isCollinear(e.top, pt, prev.top) { return }

            if e.outrec!.idx == prev.outrec!.idx {
                addLocalMaxPoly(prev, e, pt)
            } else if e.outrec!.idx < prev.outrec!.idx {
                joinOutrecPaths(e, prev)
            } else {
                joinOutrecPaths(prev, e)
            }
            prev.joinWith = .right
            e.joinWith = .left
        }

        private func checkJoinRight(_ e: Active, _ pt: Point64, _ checkCurrX: Bool = false) {
            guard let next = e.nextInAEL, isHotEdge(e), isHotEdge(next), !isHorizontal(e), !isHorizontal(next),
                  !isOpen(e), !isOpen(next) else { return }
            if (pt.y < e.top.y + 2 || pt.y < next.top.y + 2) && (e.bot.y > pt.y || next.bot.y > pt.y) { return }  // trivial

            if checkCurrX {
                if perpendicDistFromLineSqrd(pt, next.bot, next.top) > 0.35 { return }
            } else if e.currX != next.currX {
                return
            }
            if !isCollinear(e.top, pt, next.top) { return }

            if e.outrec!.idx == next.outrec!.idx {
                addLocalMaxPoly(e, next, pt)
            } else if e.outrec!.idx < next.outrec!.idx {
                joinOutrecPaths(e, next)
            } else {
                joinOutrecPaths(next, e)
            }
            e.joinWith = .right
            next.joinWith = .left
        }

        // MARK: Solutions

        private func checkBounds(_ outrec: OutRec) -> Bool {
            if outrec.pts == nil { return false }
            if !outrec.bounds.isEmpty { return true }
            splitSearchSteps += 1
            cleanCollinear(outrec)
            if outrec.pts == nil || !buildPath64(outrec.pts, reverseSolution, false, &outrec.path) { return false }
            outrec.bounds = bounds(outrec.path)
            return true
        }

        private func checkSplitOwner(_ outrec: OutRec, _ splitsOf: OutRec) -> Bool {
            // (by index: the list can grow in the loop)
            var idx = 0
            while idx < splitsOf.splits.count {
                defer { idx += 1 }
                var split: OutRec? = splitsOf.splits[idx]
                // Clipper2 goes through the splits of a split without points with nothing to stop it starting on that
                // split again while it is still going through it. Where something has changed since it started on it
                // (a split marked, a path's bounds found), the port starts again too, as Clipper2 does; where nothing
                // has, Clipper2 can only go round the same way again, for ever (KiCad's copy recurses until its stack
                // runs out, and crashes), and the port does not start again
                if let s = split, s.pts == nil, !s.splits.isEmpty, s.splitSearchStep != splitSearchSteps {
                    let started = s.splitSearchStep
                    s.splitSearchStep = splitSearchSteps
                    let found = checkSplitOwner(outrec, s)
                    s.splitSearchStep = started
                    if found { return true }
                }
                split = getRealOutRec(split)
                guard let s = split, s !== outrec, s.recursiveSplit !== outrec else { continue }
                s.recursiveSplit = outrec  // (no going round for ever)
                splitSearchSteps += 1

                if !s.splits.isEmpty && checkSplitOwner(outrec, s) { return true }

                if !checkBounds(s) || !s.bounds.contains(outrec.bounds) ||
                    !path2ContainsPath1Indexed(outrec.pts!, s, pipIndexThreshold) { continue }

                if !isValidOwner(outrec, s) { s.owner = outrec.owner }  // s is outrec's own
                outrec.owner = s
                return true
            }
            return false
        }

        private func recursiveCheckOwners(_ outrec: OutRec, _ polypath: PolyPath64) {
            // (outrec has its bounds; once done, if it is a path, it has its place in the tree)
            if outrec.polypath != nil || outrec.bounds.isEmpty { return }
            while let owner = outrec.owner {
                if !owner.splits.isEmpty && checkSplitOwner(outrec, owner) { break }
                if owner.pts != nil && checkBounds(owner) && owner.bounds.contains(outrec.bounds) &&
                    path2ContainsPath1Indexed(outrec.pts!, owner, pipIndexThreshold) { break }
                outrec.owner = owner.owner
            }

            if let owner = outrec.owner {
                if owner.polypath == nil { recursiveCheckOwners(owner, polypath) }
                outrec.polypath = owner.polypath!.addChild(outrec.path)
            } else {
                outrec.polypath = polypath.addChild(outrec.path)
            }
        }

        private func buildPaths64(_ solutionClosed: inout Paths64, _ solutionOpen: inout Paths64) {
            solutionClosed.removeAll()
            solutionOpen.removeAll()
            // (the list can grow in the loop: CleanCollinear can split paths)
            var i = 0
            while i < outrecList.count {
                defer { i += 1 }
                let outrec = outrecList[i]
                if outrec.pts == nil { continue }
                var path = Path64()
                if outrec.isOpen {
                    if buildPath64(outrec.pts, reverseSolution, true, &path) { solutionOpen.append(path) }
                } else {
                    cleanCollinear(outrec)
                    // (closed paths counter-clockwise, y up, unless reversed)
                    if buildPath64(outrec.pts, reverseSolution, false, &path) { solutionClosed.append(path) }
                }
            }
        }

        private func buildTree64(_ polytree: PolyPath64, _ openPaths: inout Paths64) {
            polytree.clear()
            openPaths.removeAll()
            // (the list can grow in the loop: CheckBounds can split paths)
            var i = 0
            while i < outrecList.count {
                defer { i += 1 }
                let outrec = outrecList[i]
                if outrec.pts == nil { continue }
                if outrec.isOpen {
                    var path = Path64()
                    if buildPath64(outrec.pts, reverseSolution, true, &path) { openPaths.append(path) }
                    continue
                }
                if checkBounds(outrec) { recursiveCheckOwners(outrec, polytree) }
            }
        }
    }

    /// The scanlines to come: a max-heap of y values
    struct ScanlineHeap {
        private var heap: [Int] = []

        var top: Int? { heap.first }

        mutating func push(_ y: Int) {
            heap.append(y)
            var i = heap.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                if heap[parent] >= heap[i] { break }
                heap.swapAt(parent, i)
                i = parent
            }
        }

        mutating func pop() -> Int? {
            guard let first = heap.first else { return nil }
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < heap.count && heap[l] > heap[m] { m = l }
                    if r < heap.count && heap[r] > heap[m] { m = r }
                    if m == i { break }
                    heap.swapAt(i, m)
                    i = m
                }
            }
            return first
        }
    }
}
