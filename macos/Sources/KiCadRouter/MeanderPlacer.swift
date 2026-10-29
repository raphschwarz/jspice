// Ported from KiCad 10.0.7: pcbnew/router/pns_meander_placer_base.h, pns_meander_placer_base.cpp,
// pns_meander_placer.h, pns_meander_placer.cpp, and the parts of pns_topology.cpp a length tuning uses
// (AssembleTuningPath, walkTuningPath, findLinesFromVia) (the length domain: not the time domain's delays).
// Copyright (C) 2013-2015 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// What a length tuning has in common, a single track's or a differential pair's (KiCad's MEANDER_PLACER_BASE): its
/// settings, and the meanders fitted to the length asked
public class MeanderPlacerBase: PlacementAlgo {
    /// How the tuned length compares with the length asked (KiCad's TUNING_STATUS)
    public enum TuningStatus: Int, Sendable {
        case tooShort = 0
        case tooLong
        case tuned
    }

    /// Within how far of its target a meander's length is taken to be on it (KiCad's LENGTH_TARGET_TOLERANCE)
    static let lengthTargetTolerance = 20

    unowned let router: Router
    /// The branch of the router's world the tuning is in, the tuned line taken out of it
    var world: Node?
    /// The tuned line's width
    var currentWidth = 0
    /// The meanders' sizes and the length to reach
    public internal(set) var meanderSettings = MeanderSettings()
    public internal(set) var currentEnd = IPoint.zero
    var startPadP: Solid?
    var endPadP: Solid?
    var startPadN: Solid?
    var endPadN: Solid?

    init(router: Router) { self.router = router }

    // MARK: - What each tuning has of its own

    /// The tuned length (or a pair's skew)
    public var tuningLengthResult: Int { fatalError("MeanderPlacerBase.tuningLengthResult") }

    public var tuningStatus: TuningStatus { fatalError("MeanderPlacerBase.tuningStatus") }

    /// Whether the meander fits where it is: clear of the board and of the meanders already fitted
    func checkFit(_ shape: MeanderShape) -> Bool { false }

    /// The path the tuned length is measured along: its lines and vias, from pad to pad or as far as they go
    public func tunedPath() -> [Item] { fatalError("MeanderPlacerBase.tunedPath") }

    public func start(_ p: IPoint, _ startItem: Item?) -> Bool { fatalError("MeanderPlacerBase.start") }
    public func move(_ p: IPoint, _ endItem: Item?) -> Bool { fatalError("MeanderPlacerBase.move") }
    public func fixRoute(_ p: IPoint, _ endItem: Item?, forceFinish: Bool) -> Bool { fatalError("MeanderPlacerBase.fixRoute") }
    public func commitPlacement() -> Bool { false }
    public func abortPlacement() -> Bool { false }
    public var hasPlacedAnything: Bool { false }
    public func toggleVia(_ enabled: Bool) -> Bool { false }
    public var isPlacingVia: Bool { false }
    public func setLayer(_ layer: Int) -> Bool { false }
    public func traces() -> [Item] { fatalError("MeanderPlacerBase.traces") }
    public var currentStart: IPoint { fatalError("MeanderPlacerBase.currentStart") }
    public var currentNets: [NetHandle?] { fatalError("MeanderPlacerBase.currentNets") }
    public var currentLayer: Int { fatalError("MeanderPlacerBase.currentLayer") }
    public func currentNode(loopsRemoved: Bool) -> Node? { fatalError("MeanderPlacerBase.currentNode") }
    public func flipPosture() {}
    public func updateSizes(_ sizes: SizesSettings) {}
    public func setOrthoMode(_ ortho: Bool) {}

    // MARK: - Settings

    /// The meanders' largest amplitude a step up or down, no less than their least (KiCad's AmplitudeStep)
    public func amplitudeStep(_ sign: Int) {
        var a = meanderSettings.maxAmplitude + sign * meanderSettings.step
        a = max(a, meanderSettings.minAmplitude)
        meanderSettings.maxAmplitude = a
    }

    /// The meanders' spacing a step up or down, no less than the line's width and clearance (KiCad's SpacingStep)
    public func spacingStep(_ sign: Int) {
        var s = meanderSettings.spacing + sign * meanderSettings.step
        s = max(s, currentWidth + clearance())
        meanderSettings.spacing = s
    }

    /// The clearance of the tuned line, the first of its traces' (all of one net class, so any would do) (KiCad's
    /// Clearance)
    public func clearance() -> Int {
        let itemToCheck = traces().first
        guard let constraint = router.ruleResolver?.queryConstraint(.clearance, itemToCheck, nil, layer: currentLayer) else {
            // (KiCad's check, which says there is no minimum clearance, and gives the width)
            return currentWidth
        }
        return constraint.min
    }

    public func updateSettings(_ settings: MeanderSettings) { meanderSettings = settings }

    // MARK: - Tuning

    /// The amplitude, between `minAmp` and `maxAmp`, that makes the meander's length `targetLength`, halving the
    /// range until one end is within the tolerance of it; 0 if none (KiCad's findAmplitudeBinarySearch)
    static func findAmplitudeBinarySearch(_ copy: MeanderShape, _ targetLength: Int, _ minAmp: Int, _ maxAmp: Int) -> Int {
        if minAmp == maxAmp { return maxAmp }
        copy.resize(minAmp)
        let minLen = Int(Int32(truncatingIfNeeded: copy.currentLength))
        copy.resize(maxAmp)
        let maxLen = Int(Int32(truncatingIfNeeded: copy.currentLength))
        if minLen > targetLength { return 0 }
        if maxLen < targetLength { return 0 }
        let minError = minLen - targetLength
        let maxError = maxLen - targetLength
        if abs(minError) < lengthTargetTolerance || abs(maxError) < lengthTargetTolerance {
            return abs(minError) < abs(maxError) ? minAmp : maxAmp
        } else {
            let left = findAmplitudeBinarySearch(copy, targetLength, minAmp, (minAmp + maxAmp) / 2)
            if left != 0 { return left }
            let right = findAmplitudeBinarySearch(copy, targetLength, (minAmp + maxAmp) / 2, maxAmp)
            if right != 0 { return right }
        }
        return 0
    }

    /// The amplitude that makes the meander `targetLength` long, its base kept: a guess if its least amplitude is
    /// within the tolerance of it, else by halving the range (KiCad's findAmplitudeForLength)
    static func findAmplitudeForLength(_ m: MeanderShape, _ targetLength: Int, _ minAmp: Int, _ maxAmp: Int) -> Int {
        let copy = m.copy()
        // (the same length of base kept)
        copy.setTargetBaselineLength(m.baselineLength)
        let initialGuess = m.amplitude - (m.currentLength - targetLength) / 2
        if initialGuess >= minAmp && initialGuess <= maxAmp {
            copy.resize(minAmp)
            if abs(copy.currentLength - targetLength) < lengthTargetTolerance {
                return Int(Int32(truncatingIfNeeded: initialGuess))
            }
        }
        // (else by halving the range)
        return findAmplitudeBinarySearch(copy, targetLength, minAmp, maxAmp)
    }

    /// The meanders of `tuned` made to lengthen the line by `elongation`: as many as it takes at their largest, the
    /// last of them a start or single one made an end, the rest made straight; then those left made smaller, each by
    /// its share of what is too much (KiCad's tuneLineLength)
    func tuneLineLength(_ tuned: MeanderedLine, _ elongation: Int) {
        var maxElongation = 0
        var minElongation = 0
        var finished = false
        for m in tuned.meanders where m.type != .corner && m.type != .arc {
            let end = m.copy()
            let endType: MeanderType = m.type == .start || m.type == .single ? .single : .finish
            end.setType(endType)
            end.recalculate()
            let maxEndElongation = end.currentLength - end.baselineLength
            if maxElongation + maxEndElongation > elongation {
                if !finished {
                    m.setType(endType)
                    m.recalculate()
                    if endType == .single {
                        // (whether this meander is needed at all)
                        let endMinElongation = m.minTunableLength - m.baselineLength
                        if minElongation + endMinElongation >= elongation { m.makeEmpty() }
                    }
                    finished = true
                } else {
                    m.makeEmpty()
                }
            }
            maxElongation += m.currentLength - m.baselineLength
            minElongation += m.minTunableLength - m.baselineLength
        }
        var remainingElongation = elongation
        var meanderCount = 0
        for m in tuned.meanders where m.type != .corner && m.type != .arc && m.type != .empty {
            remainingElongation -= m.currentLength - m.baselineLength
            meanderCount += 1
        }
        var lenReductionLeft = -remainingElongation
        var meandersLeft = meanderCount
        if lenReductionLeft < 0 || meandersLeft == 0 { return }
        for m in tuned.meanders where m.type != .corner && m.type != .arc && m.type != .empty {
            let lenReductionHere = lenReductionLeft / meandersLeft
            let initialLen = m.currentLength
            let minAmpl = m.minAmplitude
            var amp = Self.findAmplitudeForLength(m, Int(Int32(truncatingIfNeeded: initialLen - lenReductionHere)),
                                                  minAmpl, m.amplitude)
            if amp < minAmpl { amp = minAmpl }
            m.setTargetBaselineLength(m.baselineLength)
            m.resize(amp)
            lenReductionLeft -= initialLen - m.currentLength
            meandersLeft -= 1
            if meandersLeft == 0 { break }
        }
    }

    /// Where on the track the tuning starts: the nearest point of a segment, the nearer end of an arc (KiCad's
    /// getSnappedStartPoint)
    func snappedStartPoint(_ startItem: LinkedItem, _ startPoint: IPoint) -> IPoint {
        if let s = startItem as? Segment { return s.seg.nearestPoint(startPoint) }
        let arc = startItem as! Arc
        if (arc.anchor(0) - startPoint).squaredNorm <= (arc.anchor(1) - startPoint).squaredNorm {
            return arc.anchor(0)
        }
        return arc.anchor(1)
    }

    /// The length of a path of lines and vias, as the board measures it (KiCad's lineLength)
    func lineLength(_ line: [Item], _ startPad: Solid?, _ endPad: Solid?) -> Int {
        if line.isEmpty { return 0 }
        return router.iface!.calculateRoutedPathLength(line, startPad: startPad, endPad: endPad)
    }
}

/// A single track's length tuned (KiCad's MEANDER_PLACER): the part of the track between where it starts and the
/// pointer meandered, in a branch of the world, to the length the settings ask, measured along the whole path of its
/// net from pad to pad
public class MeanderPlacer: MeanderPlacerBase {
    /// Where the tuned part starts
    var currentStartPoint = IPoint.zero
    var currentNodeBranch: Node?
    /// The track's line, as it was
    var originLine = Line()
    /// The track's line as tuned
    private var currentTrace = Line()
    var tunedPathItems: [Item] = []
    private var finalShape = LineChain()
    private var result: MeanderedLine!
    var initialSegment: LinkedItem?
    /// What the pads at the path's ends add (their pad-to-die lengths)
    private var padToDieLength = 0
    var lastLength = 0
    private var lastStatus = TuningStatus.tooShort

    public override func currentNode(loopsRemoved: Bool) -> Node? { currentNodeBranch ?? world }

    /// Starts tuning the track `startItem` (a segment or an arc) at `p` (KiCad's Start)
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
        originLine = world.assembleLine(initial)
        let topo = Topology(world)
        (tunedPathItems, startPadN, endPadN) = topo.assembleTuningPath(router.iface!, initial)
        padToDieLength = 0
        if let startPadN { padToDieLength += startPadN.padToDie }
        if let endPadN { padToDieLength += endPadN.padToDie }
        world.remove(originLine)
        currentWidth = originLine.width
        currentEnd = .zero
        return true
    }

    /// The length of the path as it was, its pads' pad-to-die lengths with it (KiCad's origPathLength)
    func origPathLength() -> Int { padToDieLength + lineLength(tunedPathItems, startPadN, endPadN) }

    public override func move(_ p: IPoint, _ endItem: Item?) -> Bool {
        doMove(p, endItem, meanderSettings.targetLength.opt, meanderSettings.targetLength.min,
               meanderSettings.targetLength.max)
    }

    /// The line from where the tuning started to the point of it nearest `p` meandered, the meanders' sides by
    /// the side of each segment `p` is on (or the settings' side), then tuned to `targetLength` unless the path is
    /// too long already (KiCad's doMove)
    func doMove(_ p: IPoint, _ endItem: Item?, _ targetLength: Int, _ targetMin: Int, _ targetMax: Int) -> Bool {
        if currentStartPoint == p { return false }
        if let currentNodeBranch { world!.release(currentNodeBranch) }
        currentNodeBranch = world!.branch()
        var (pre, tuned, post) = originLine.cLine.split(currentStartPoint, p)
        result = MeanderedLine(placer: self, isDual: false)
        result.width = originLine.width
        result.baselineOffset = 0
        var i = 0
        while i < tuned.segmentCount {
            defer { i += 1 }
            if tuned.isArcSegment(i) {
                let arcIndex = tuned.arcIndex(i)
                result.addArc(tuned.arcs[arcIndex])
                i = tuned.nextShape(i)
                // (-1 after the last shape)
                if i < 0 { i = tuned.segmentCount }
                continue
            }
            var side = false
            let s = tuned.segment(i)
            if meanderSettings.initialSide == .default {
                side = s.side(p) < 0
            } else {
                side = meanderSettings.initialSide.rawValue < 0
            }
            result.addCorner(s.a)
            result.meanderSegment(s, side)
            result.addCorner(s.b)
        }
        let lineLen = origPathLength()
        lastLength = lineLen
        lastStatus = .tuned
        if lineLen > meanderSettings.targetLength.max {
            lastStatus = .tooLong
        } else {
            lastLength = lineLen - tuned.length
            tuneLineLength(result, targetLength - lineLen)
        }
        if lastStatus != .tooLong {
            tuned.clear()
            for m in result.meanders where m.type != .empty { tuned.append(m.cLine(0)) }
            lastLength += tuned.length
            if lastLength > targetMax {
                lastStatus = .tooLong
            } else if lastLength < targetMin {
                lastStatus = .tooShort
            } else {
                lastStatus = .tuned
            }
        }
        finalShape.clear()
        if meanderSettings.keepEndpoints {
            pre.simplify()
            tuned.simplify()
            post.simplify()
            finalShape.append(pre)
            finalShape.append(tuned)
            finalShape.append(post)
        } else {
            finalShape.append(pre)
            finalShape.append(tuned)
            finalShape.append(post)
            finalShape.simplify()
        }
        return true
    }

    /// The tuned line put in the world (KiCad's FixRoute)
    public override func fixRoute(_ p: IPoint, _ endItem: Item?, forceFinish: Bool) -> Bool {
        guard let currentNodeBranch else { return false }
        currentTrace = Line(originLine, finalShape)
        currentNodeBranch.add(currentTrace)
        _ = commitPlacement()
        return true
    }

    public override func abortPlacement() -> Bool {
        world?.killChildren()
        return true
    }

    public override var hasPlacedAnything: Bool { currentTrace.segmentCount > 0 }

    public override func commitPlacement() -> Bool {
        if let currentNodeBranch { router.commitRouting(currentNodeBranch) }
        currentNodeBranch = nil
        return true
    }

    /// Whether the meander is clear of the board and keeps the line's width and the spacing from the meanders
    /// already fitted (KiCad's CheckFit)
    override func checkFit(_ shape: MeanderShape) -> Bool {
        let l = Line(originLine, shape.cLine(0))
        if currentNodeBranch!.checkColliding(l) != nil { return false }
        let w = shape.width
        let clearance = w + meanderSettings.spacing
        return result.checkSelfIntersections(shape, clearance)
    }

    /// The line as tuned (KiCad's Traces, which makes it again each time it is asked)
    public override func traces() -> [Item] {
        currentTrace = Line(originLine, finalShape)
        return [currentTrace]
    }

    public override func tunedPath() -> [Item] { tunedPathItems }

    public override var currentStart: IPoint { currentStartPoint }

    public override var currentNets: [NetHandle?] { [originLine.net] }

    public override var currentLayer: Int { initialSegment!.layers.start }

    /// The tuned length: the path's with the meanders, or as it was if it has not been moved (KiCad's
    /// TuningLengthResult)
    public override var tuningLengthResult: Int { lastLength != 0 ? lastLength : origPathLength() }

    public override var tuningStatus: TuningStatus { lastStatus }
}

extension Topology {
    /// What a walk along a net found (KiCad's WALK_RESULT): its lines and vias, their length (-1: nothing yet, so that
    /// a walk that goes nowhere is found), and the pad it ended on
    struct WalkResult {
        var items: [Item] = []
        var length = -1
        var endPad: Solid?
    }

    /// The lines of the via's net from it: each track of the net touching it with an end in its copper, assembled
    /// into its line once (KiCad's findLinesFromVia, with no board via behind the via: its copper the router's)
    func findLinesFromVia(_ via: Via, _ visited: Set<ObjectIdentifier>) -> [Line] {
        var result: [Line] = []
        var opts = CollisionSearchOptions()
        opts.differentNetsOnly = false
        opts.overrideClearance = 0
        opts.kindMask = [.segment, .arc]
        let obstacles = world.queryColliding(via, options: opts)
        let net = via.net
        var assembled = Set<ObjectIdentifier>()
        for obs in obstacles {
            if obs.item.net != net { continue }
            let linked = obs.item as! LinkedItem
            if visited.contains(ObjectIdentifier(linked)) { continue }
            if assembled.contains(ObjectIdentifier(linked)) { continue }
            // (an end of it in the via's copper)
            let anchor0 = linked.anchor(0)
            let anchor1 = linked.anchor(1)
            let shape = via.shape(via.layer)
            let anchor0Inside = shape?.collide(.circle(center: anchor0, radius: 0), clearance: 0) ?? false
            let anchor1Inside = shape?.collide(.circle(center: anchor1, radius: 0), clearance: 0) ?? false
            if !anchor0Inside && !anchor1Inside { continue }
            let l = world.assembleLine(linked, stopAtLockedJoints: false, followLockedSegments: true)
            for link in l.links { assembled.insert(ObjectIdentifier(link)) }
            result.append(l)
        }
        return result
    }

    /// The longest way along the net from an end of `startLine`, through vias and pads in line, to a pad or as far
    /// as it goes, depth first (KiCad's walkTuningPath, with no time limit)
    func walkTuningPath(_ startLine: Line, fromBack: Bool, _ visitedAtStart: Set<ObjectIdentifier>) -> WalkResult {
        struct State {
            var endpoint: IPoint
            var pathItems: [Item] = []
            var pathLength = 0
            var visited: Set<ObjectIdentifier>
        }
        var best = WalkResult()
        let net = startLine.net
        var stateStack = [State(endpoint: fromBack ? startLine.cLastPoint : startLine.cPoint(0), visited: visitedAtStart)]
        while let popped = stateStack.popLast() {
            var current = popped
            let hits = world.hitTest(current.endpoint)
            var pad: Solid?
            for item in hits where item.ofKind(.solid) && item.net == net && !current.visited.contains(ObjectIdentifier(item)) {
                pad = item as? Solid
                break
            }
            if let pad {
                if current.pathLength > best.length {
                    best.length = current.pathLength
                    best.items = current.pathItems
                    best.endPad = pad
                }
                // (on through a pad in line, so that the tuning spans the whole net)
                current.visited.insert(ObjectIdentifier(pad))
                for item in hits where item.ofKind([.segment, .arc]) {
                    if item.net != net || current.visited.contains(ObjectIdentifier(item)) { continue }
                    let contLine = world.assembleLine(item as! LinkedItem, stopAtLockedJoints: false, followLockedSegments: true)
                    let ep = current.endpoint
                    let startNear = (contLine.cPoint(0) - ep).squaredNorm <= (contLine.cLastPoint - ep).squaredNorm
                    var nextState = State(endpoint: startNear ? contLine.cLastPoint : contLine.cPoint(0), visited: current.visited)
                    nextState.pathItems = current.pathItems + [contLine.copy()]
                    nextState.pathLength = current.pathLength + contLine.cLine.length
                    for link in contLine.links { nextState.visited.insert(ObjectIdentifier(link)) }
                    stateStack.append(nextState)
                }
                continue
            }
            var via: Via?
            for item in hits where item.ofKind(.via) && item.net == net && !item.isVirtual
                && !current.visited.contains(ObjectIdentifier(item)) {
                via = item as? Via
                break
            }
            if let via {
                current.visited.insert(ObjectIdentifier(via))
                let continuations = findLinesFromVia(via, current.visited)
                for contLine in continuations {
                    let ep = current.endpoint
                    let startNearVia = (contLine.cPoint(0) - ep).squaredNorm <= (contLine.cLastPoint - ep).squaredNorm
                    let forwardEndpoint = startNearVia ? contLine.cLastPoint : contLine.cPoint(0)
                    let contLength = contLine.cLine.length
                    var nextState = State(endpoint: forwardEndpoint, visited: current.visited)
                    nextState.pathItems = current.pathItems + [via, contLine.copy()]
                    nextState.pathLength = current.pathLength + contLength
                    for link in contLine.links { nextState.visited.insert(ObjectIdentifier(link)) }
                    stateStack.append(nextState)
                }
                if continuations.isEmpty && current.pathLength > best.length {
                    best.length = current.pathLength
                    best.items = current.pathItems + [via]
                    best.endPad = nil
                }
            } else if current.pathLength > best.length {
                best.length = current.pathLength
                best.items = current.pathItems
                best.endPad = nil
            }
        }
        return best
    }

    /// The path a length tuning of `start` measures (KiCad's AssembleTuningPath): its line, and the longest ways on
    /// from either end through vias and pads in line; and the pads it ends on, which only a board's pads are (KiCad
    /// asks a pad's board item: none in a scene's world). With a board pad at either end, its lines cut to the
    /// copper of the pads they end in, those at its ends and those on its way, and of the board vias next to them
    /// (OptimiseTraceInPad, OptimiseTraceInVia)
    func assembleTuningPath(_ iface: RouterInterface, _ start: Item) -> (path: [Item], startPad: Solid?, endPad: Solid?) {
        var seg: LinkedItem?
        if let via = start as? Via {
            if let jt = world.findJoint(via.pos, via), jt.isNonFanoutVia {
                for item in jt.links where item.ofKind([.segment, .arc]) {
                    seg = item as? LinkedItem
                    break
                }
            }
            if seg == nil {
                let continuations = findLinesFromVia(via, [])
                guard let first = continuations.first else { return ([], nil, nil) }
                for link in first.links where link.ofKind([.segment, .arc]) {
                    seg = link
                    break
                }
            }
        } else if start.ofKind([.segment, .arc]) {
            seg = start as? LinkedItem
        }
        guard let seg else { return ([], nil, nil) }
        let l = world.assembleLine(seg, stopAtLockedJoints: false, followLockedSegments: true)
        var visited = Set<ObjectIdentifier>()
        for link in l.links { visited.insert(ObjectIdentifier(link)) }
        let left = walkTuningPath(l, fromBack: false, visited)
        let right = walkTuningPath(l, fromBack: true, visited)
        var path: [Item] = []
        for item in left.items { path.insert(item, at: 0) }
        path.append(l.copy())
        path += right.items

        // (the ends' pads only where they are board pads, which only a board's world has)
        guard let board = iface as? WorldInterface, let padPolygon = board.boardPadPolygon else { return (path, nil, nil) }
        func boardPad(_ s: Solid?) -> (solid: Solid, info: WorldItem)? {
            guard let s, let info = board.resolver.infoOf(s), info.kind == .pad else { return nil }
            return (s, info)
        }
        let padA = boardPad(left.endPad)
        let padB = boardPad(right.endPad)
        if padA == nil && padB == nil { return (path, nil, nil) }

        func processPad(_ pad: (solid: Solid, info: WorldItem)) {
            var polygon: PolySet??
            func shape() -> PolySet? {
                if polygon == nil { polygon = .some(padPolygon(pad.info)) }
                return polygon!
            }
            for idx in path.indices {
                guard let line = path[idx] as? Line else { continue }
                var slc = line.cLine
                if Self.optimiseTraceInPad(&slc, pad.solid, pad.info, line.layer, shape) {
                    let c = line.copy()
                    c.setShape(slc)
                    path[idx] = c
                }
            }
        }
        if let padA { processPad(padA) }
        if let padB { processPad(padB) }

        // (pads the path passes through on its way)
        // (a board pad known by its uuid, as KiCad knows its PAD)
        func key(_ pad: (solid: Solid, info: WorldItem)) -> String { pad.info.source ?? "serial \(pad.solid.originSerial)" }
        var processed = Set([padA, padB].compactMap { $0.map(key) })
        for idx in path.indices {
            guard let line = path[idx] as? Line else { continue }
            for pt in [line.cPoint(0), line.cLastPoint] {
                for item in world.hitTest(pt) where item.ofKind(.solid) && item.net == line.net {
                    if let pad = boardPad(item as? Solid), !processed.contains(key(pad)) {
                        processPad(pad)
                        processed.insert(key(pad))
                    }
                    break
                }
            }
        }

        // (the parts of lines in a via clipped, and the rest of the way to its centre added)
        for idx in path.indices {
            guard let via = path[idx] as? Via, board.resolver.infoOf(via)?.kind == .via else { continue }
            for delta in [-1, 1] {
                let j = idx + delta
                guard j >= 0, j < path.count, let line = path[j] as? Line else { continue }
                var slc = line.cLine
                if Self.optimiseTraceInVia(&slc, via) {
                    let c = line.copy()
                    c.setShape(slc)
                    path[j] = c
                }
            }
        }
        return (path, padA?.solid, padB?.solid)
    }

    /// A line ending in a pad clipped where it leaves the pad, and a straight line from the pad's centre to there put
    /// in its place (KiCad's LENGTH_DELAY_CALCULATION::OptimiseTraceInPad): only a line that ends at the pad's
    /// position, on a layer the pad is flashed on, and that starts (or else ends) in its polygon. Whether it changed
    static func optimiseTraceInPad(_ line: inout LineChain, _ pad: Solid, _ info: WorldItem, _ layer: Int,
                                   _ polygon: () -> PolySet?) -> Bool {
        guard line.pointCount >= 2 else { return false }
        if line.point(0) != pad.pos && line.lastPoint != pad.pos { return false }
        let flashed = info.flashed.isEmpty ? info.layers.overlaps(layer) : (layer >= 0 && layer < info.flashed.count && info.flashed[layer])
        guard flashed, let shape = polygon() else { return false }
        if shape.contains(line.point(0)) {
            return clipLineToPad(&line, pad.pos, shape, forward: true)
        } else if shape.contains(line.lastPoint) {
            return clipLineToPad(&line, pad.pos, shape, forward: false)
        }
        return false
    }

    /// KiCad's clipLineToPad: the line from its first point outside the pad on (or up to its last one outside, going
    /// back), where it crosses the pad's edge (on an arc, the crossing nearest the point inside; else its segment's,
    /// as SHAPE_POLY_SET::Collide finds it), and the pad's centre
    static func clipLineToPad(_ line: inout LineChain, _ center: IPoint, _ shape: PolySet, forward: Bool) -> Bool {
        let start = forward ? 0 : line.pointCount - 1
        let delta = forward ? 1 : -1
        var firstOutside = -1
        var intersection: IPoint?
        var vertex = start + delta
        while forward ? vertex < line.pointCount : vertex >= 0 {
            defer { vertex += delta }
            if shape.contains(line.point(vertex)) { continue }
            firstOutside = vertex
            let prevVertex = vertex - delta
            let arcIdx = line.arcIndex(prevVertex)
            if arcIdx >= 0 && line.arcIndex(vertex) == arcIdx {
                intersection = findArcPadIntersection(line.arcs[arcIdx], shape, line.point(prevVertex))
            }
            if intersection == nil {
                let seg = Seg(line.point(vertex), line.point(prevVertex))
                if let (d, nearest) = squaredDistanceToSeg(shape, seg), d == 0 { intersection = nearest }
            }
            break
        }
        if firstOutside < 0 { return false }
        var newChain = LineChain()
        if forward {
            newChain.append(center)
            if let intersection { newChain.append(intersection) }
            newChain.append(line.slice(firstOutside, -1))
        } else {
            newChain.append(line.slice(0, firstOutside))
            if let intersection { newChain.append(intersection) }
            newChain.append(center)
        }
        line = newChain
        return true
    }

    /// KiCad's findArcPadIntersection: of where the arc crosses the pad's outlines' segments, the point nearest
    /// `inside`
    static func findArcPadIntersection(_ arc: ShapeArc, _ shape: PolySet, _ inside: IPoint) -> IPoint? {
        var best: IPoint?
        var bestDistSq = Int.max
        for poly in shape.polygons {
            let outline = poly[0]
            for j in 0..<outline.segmentCount {
                let seg = outline.segment(j)
                for pt in arc.intersectLine(seg) where seg.contains(pt) {
                    let d = (pt - inside).squaredNorm
                    if d < bestDistSq {
                        bestDistSq = d
                        best = pt
                    }
                }
            }
        }
        return best
    }

    /// SHAPE_POLY_SET::SquaredDistanceToSeg with its nearest point: per polygon, 0 and the segment's middle if both
    /// its ends are in it, else the least distance to an edge (outline, then holes) and the edge's point nearest the
    /// segment (the first edge as near as any); nil for an empty set
    static func squaredDistanceToSeg(_ set: PolySet, _ s: Seg) -> (Int, IPoint)? {
        var best: (Int, IPoint)?
        for poly in set.polygons {
            var d: Int
            var nearest: IPoint
            if BoardDRC.containsSingle(poly, s.a, 1) && BoardDRC.containsSingle(poly, s.b, 1) {
                d = 0
                nearest = (s.a + s.b).divided(by: 2)
            } else {
                let segs = BoardDRC.segmentsWithHoles(poly)
                guard let first = segs.first else { continue }
                d = first.squaredDistance(s)
                nearest = first.nearestPoint(s)
                for e in segs.dropFirst() where d > 0 {
                    let c = e.squaredDistance(s)
                    if c < d {
                        d = c
                        nearest = e.nearestPoint(s)
                    }
                }
            }
            if best == nil || d < best!.0 { best = (d, nearest) }
        }
        return best
    }

    /// A line ending in a via clipped where it leaves the via's circle, and a straight line from the via's centre to
    /// there put in its place (KiCad's OptimiseTraceInVia and clipLineToVia: the crossing nearest the point outside).
    /// Whether it changed
    static func optimiseTraceInVia(_ line: inout LineChain, _ via: Via) -> Bool {
        guard line.pointCount >= 2 else { return false }
        let r = via.diameter / 2
        // (SHAPE_CIRCLE::Collide of a point, at no clearance: at the centre, or nearer than the radius)
        func inside(_ p: IPoint) -> Bool {
            let d = (p - via.pos).squaredNorm
            return d == 0 || d < r * r
        }
        let forward: Bool
        if inside(line.point(0)) {
            forward = true
        } else if inside(line.lastPoint) {
            forward = false
        } else {
            return false
        }
        let start = forward ? 0 : line.pointCount - 1
        let delta = forward ? 1 : -1
        var firstOutside = -1
        var intersection: IPoint?
        var vertex = start + delta
        while forward ? vertex < line.pointCount : vertex >= 0 {
            defer { vertex += delta }
            if inside(line.point(vertex)) { continue }
            firstOutside = vertex
            let prevVertex = vertex - delta
            let seg = Seg(line.point(vertex), line.point(prevVertex))
            let pts = Circle(via.pos, r).intersect(seg)
            if var best = pts.first {
                let outside = line.point(vertex)
                for p in pts.dropFirst() where (p - outside).squaredNorm < (best - outside).squaredNorm { best = p }
                intersection = best
            }
            break
        }
        if firstOutside < 0 { return false }
        var newChain = LineChain()
        if forward {
            newChain.append(via.pos)
            if let intersection { newChain.append(intersection) }
            newChain.append(line.slice(firstOutside, -1))
        } else {
            newChain.append(line.slice(0, firstOutside))
            if let intersection { newChain.append(intersection) }
            newChain.append(via.pos)
        }
        line = newChain
        return true
    }
}
