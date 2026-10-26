// Ported from KiCad 10.0.7: pcbnew/router/pns_walkaround.h, pns_walkaround.cpp, pns_topology.h and the parts of
// pns_topology.cpp the walkaround and the line placer use.
// Copyright (C) 2013-2014 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// How items connect, through joints (KiCad's TOPOLOGY)
public struct Topology {
    /// Items touching one another, walked round as one
    public struct Cluster {
        public var key: Item?
        public var items: [Item] = []
    }

    let world: Node

    public init(_ world: Node) { self.world = world }

    /// The line's segments in the world made as few as its shape allows
    @discardableResult
    public func simplifyLine(_ line: Line) -> Bool {
        if !line.isLinked || line.segmentCount == 0 { return false }
        let l = world.assembleLine(line.getLink(0), stopAtLockedJoints: false, followLockedSegments: false,
                                   allowSegmentSizeMismatch: false)
        var simplified = l.cLine
        simplified.simplify()
        if simplified.pointCount != l.pointCount {
            world.remove(l)
            let lnew = l.copy()
            lnew.setShape(simplified)
            world.add(lnew)
            return true
        }
        return false
    }

    /// The joints reached from `start` along tracks
    public func connectedJoints(_ start: Joint) -> [Joint] {
        var queue = [start]
        var processed = [start]
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(start)]
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            for item in current.links where item.ofKind([.segment, .arc]) {
                guard let a = world.findJoint(item.anchor(0), item), let b = world.findJoint(item.anchor(1), item) else { continue }
                let next = a.tag == current.tag ? b : a
                if seen.insert(ObjectIdentifier(next)).inserted {
                    processed.append(next)
                    queue.append(next)
                }
            }
        }
        return processed
    }

    /// The nearest item of the joint's net not connected to it, and which of its anchors
    public func nearestUnconnectedItem(_ start: Joint, kinds: ItemKind = .any) -> (Item, Int)? {
        var connected = Set<ObjectIdentifier>()
        for jt in connectedJoints(start) {
            for link in jt.links { connected.insert(ObjectIdentifier(link)) }
        }
        // (KiCad's set goes by address; here by the order the items were made)
        let disconnected = world.allItems(inNet: start.net).filter { !connected.contains(ObjectIdentifier($0)) }
            .sorted { $0.serial < $1.serial }
        var bestDist = Int(Int32.max)
        var best: (Item, Int)?
        for item in disconnected where item.ofKind(kinds) {
            for i in 0..<item.anchorCount {
                let d = (item.anchor(i) - start.pos).norm
                if d < bestDist {
                    bestDist = d
                    best = (item, i)
                }
            }
        }
        return best
    }

    /// Where a track being routed should go next: what its end is connected to, or the nearest item of its net it
    /// is not yet
    public func nearestUnconnectedAnchorPoint(_ track: Line) -> (point: IPoint, layers: LayerRange, item: Item)? {
        let t = track.copy()
        if t.pointCount == 0 { return nil }
        let tmpNode = world.branch()
        defer { world.release(tmpNode) }
        t.clearLinks()
        tmpNode.add(t)
        guard let jt = tmpNode.findJoint(t.cLastPoint, t), let code = jt.net, code > 0 else { return nil }
        var connected: Item?
        if (t.via == nil && jt.linkCount() >= 2) || (t.via != nil && jt.linkCount() >= 3) {
            connected = jt.links.first { $0.owner !== tmpNode }
        }
        if let connected { return (jt.pos, jt.layers, connected) }
        guard let (it, anchor) = Topology(tmpNode).nearestUnconnectedItem(jt) else { return nil }
        return (it.anchor(anchor), it.layers, it)
    }

    /// The ratsnest line from a track's end to where it should go
    public func leadingRatLine(_ track: Line) -> LineChain? {
        guard let (end, _, _) = nearestUnconnectedAnchorPoint(track) else { return nil }
        return LineChain([track.cLastPoint, end])
    }

    /// `start` and everything touching it, on `layer`, but tracks of other nets and anything of `excludedNet`
    public func assembleCluster(_ start: Item, layer: Int, areaExpansionLimit: Double = 0, excludedNet: NetHandle? = nil) -> Cluster {
        var cluster = Cluster()
        var pending = [start]
        var head = 0
        var opts = CollisionSearchOptions()
        opts.differentNetsOnly = false
        opts.overrideClearance = 0
        guard var clusterBox = start.shape(layer)?.bbox else { return cluster }
        // (BOX2::GetArea, in 64 bits)
        let initialArea = clusterBox.width * clusterBox.height
        var processed = Set<ObjectIdentifier>()
        while head < pending.count {
            let top = pending[head]
            head += 1
            if !processed.contains(ObjectIdentifier(top)) { cluster.items.append(top) }
            processed.insert(ObjectIdentifier(top))
            for obs in world.queryColliding(top, options: opts) {
                let trackOnTrack = obs.item.net != top.net && obs.item.ofKind(.segment) && top.ofKind(.segment)
                if trackOnTrack { continue }
                if let excludedNet, obs.item.net == excludedNet { continue }
                if obs.item.ofKind([.segment, .arc]) && obs.item.layers.overlaps(layer) {
                    // (KiCad's line keeps its width in its chain, and the chain's box takes it in, all of it)
                    let line = world.assembleLine(obs.item as! LinkedItem)
                    clusterBox.merge(line.width != 0 ? line.cLine.bbox.inflated(line.width) : line.cLine.bbox)
                } else if let s = obs.item.shape(layer) {
                    clusterBox.merge(s.bbox)
                }
                let areaRatio = Double(clusterBox.width * clusterBox.height) / Double(initialArea + 1)
                if areaExpansionLimit > 0 && areaRatio > areaExpansionLimit { break }
                if !processed.contains(ObjectIdentifier(obs.item)) && obs.item.layers.overlaps(layer) && !obs.item.marker.contains(.head) {
                    processed.insert(ObjectIdentifier(obs.item))
                    cluster.items.append(obs.item)
                    pending.append(obs.item)
                }
            }
        }
        return cluster
    }
}

/// Routing a line round what is in its way, clockwise, anticlockwise or whichever is shorter (KiCad's WALKAROUND)
public final class Walkaround {
    public enum Status: Sendable { case inProgress, almostDone, done, stuck, none }
    public enum Policy: Int, CaseIterable, Sendable { case cw = 0, ccw = 1, shortest = 2 }

    public struct Result {
        public var status: [Status] = [.none, .none, .none]
        public var lines: [Line] = [Line(), Line(), Line()]
    }

    var world: Node
    let router: Router
    private var iteration = 0
    public var iterationLimit: Int
    public var itemMask: ItemKind = .any
    private var restrictedSet = Set<ObjectIdentifier>()
    private var restrictedVertices: [IPoint] = []
    public var lengthLimitOn = true
    public var lengthExpansionFactor = 10.0
    private var enabledPolicies = [false, false, false]
    private var processedItems: [Item] = []
    private var currentResult = Result()
    private var initialLength = 0.0

    public init(world: Node, router: Router) {
        self.world = world
        self.router = router
        iterationLimit = router.settings.walkaroundIterationLimit
    }

    public func setWorld(_ node: Node) { world = node }
    public func setSolidsOnly(_ solidsOnly: Bool) { itemMask = solidsOnly ? .solid : .any }

    public func setLengthLimit(_ enable: Bool, _ factor: Double) {
        lengthLimitOn = enable
        lengthExpansionFactor = factor
    }

    public func setAllowedPolicies(_ policies: [Policy]) {
        enabledPolicies = [false, false, false]
        for p in policies { enabledPolicies[p.rawValue] = true }
    }

    public func restrictToCluster(_ enabled: Bool, _ cluster: Topology.Cluster) {
        restrictedVertices.removeAll()
        restrictedSet.removeAll()
        if enabled {
            for item in cluster.items {
                restrictedSet.insert(ObjectIdentifier(item))
                if let h = item.hole { restrictedSet.insert(ObjectIdentifier(h)) }
            }
        }
        for case let solid as Solid in cluster.items { restrictedVertices.append(solid.anchor(0)) }
    }

    private func start(_ initialPath: Line) {
        iteration = 0
        for pol in 0..<3 {
            currentResult.status[pol] = .inProgress
            let l = initialPath.copy()
            l.clearLinks()
            currentResult.lines[pol] = l
        }
    }

    private func nearestObstacle(_ path: Line) -> Obstacle? {
        var opts = CollisionSearchOptions()
        opts.kindMask = itemMask
        if !restrictedSet.isEmpty {
            let set = restrictedSet
            opts.filter = { set.contains(ObjectIdentifier($0)) }
        }
        opts.useClearanceEpsilon = true
        return world.nearestObstacle(path, options: opts)
    }

    private func processCluster(_ cluster: Topology.Cluster, _ line: Line, cw: Bool) -> Bool {
        let cornerMode = router.settings.cornerMode
        for clItem in cluster.items {
            let clearance = world.clearance(clItem, line, useEpsilon: false)
            let cached = world.ruleResolver.hullCache(clItem, clearance: clearance, walkaroundThickness: line.width, layer: line.layer)
            let hull: LineChain
            if cornerMode.isNinety {
                let b = cached.bbox
                hull = LineChain([IPoint(b.minX, b.minY), IPoint(b.maxX, b.minY), IPoint(b.maxX, b.maxY), IPoint(b.minX, b.maxY)])
            } else {
                hull = cached
            }
            let tmp = line.copy()
            var simplified = line.cLine
            simplified.simplify2()
            line.setLine(simplified)
            var walked = tmp.cLine
            let stat = line.walkaround(hull, &walked, cw: cw)
            Router.dbg("  hull stat \(stat ? 1 : 0): \(hull.points)")
            Router.dbg("  walk stat \(stat ? 1 : 0): \((stat ? walked : tmp.cLine).points)")
            if !stat { return false }
            line.setShape(walked)
        }
        return true
    }

    private func singleStep() {
        let topo = Topology(world)
        var pending = [Topology.Cluster(), Topology.Cluster(), Topology.Cluster()]
        for i in 0..<3 where enabledPolicies[i] && currentResult.status[i] == .inProgress {
            let line = currentResult.lines[i]
            Router.dbg("current (policy \(i)): \(line.cLine.points)")
            guard let obstacle = nearestObstacle(line) else {
                Router.dbg("no-more-colls pol \(i)")
                currentResult.status[i] = .done
                continue
            }
            Router.dbg("col-item: \(obstacle.item)")
            pending[i] = topo.assembleCluster(obstacle.item, layer: line.layer, areaExpansionLimit: 0, excludedNet: line.net)
        }
        if enabledPolicies[Policy.cw.rawValue] {
            if !processCluster(pending[0], currentResult.lines[0], cw: true) { currentResult.status[0] = .stuck }
        }
        if enabledPolicies[Policy.ccw.rawValue] {
            if !processCluster(pending[1], currentResult.lines[1], cw: false) { currentResult.status[1] = .stuck }
        }
        if enabledPolicies[Policy.shortest.rawValue] {
            let line = currentResult.lines[2]
            let pathCw = line.copy(), pathCcw = line.copy()
            let stCw = processCluster(pending[2], pathCw, cw: true)
            let stCcw = processCluster(pending[2], pathCcw, cw: false)
            let cwColl = stCw ? world.checkColliding(pathCw) != nil : false
            let ccwColl = stCcw ? world.checkColliding(pathCcw) != nil : false
            var shortest: Line?, shortestAlt: Line?
            if stCw && stCcw {
                if (!cwColl && !ccwColl) || (cwColl && ccwColl) {
                    if pathCw.cLine.length > pathCcw.cLine.length {
                        shortest = pathCcw
                        shortestAlt = pathCw
                    } else {
                        shortest = pathCw
                        shortestAlt = pathCcw
                    }
                } else if !cwColl {
                    shortest = pathCw
                } else if !ccwColl {
                    shortest = pathCcw
                }
            } else if stCcw {
                shortest = pathCcw
            } else if stCw {
                shortest = pathCw
            }
            var anyColliding = false
            if let shortest {
                for item in processedItems {
                    let ctx = CollisionSearchContext()
                    if shortest.collide(item, world, layer: shortest.layer, context: ctx) {
                        anyColliding = true
                        break
                    }
                }
            }
            if anyColliding { shortest = shortestAlt }
            if let shortest {
                currentResult.lines[2] = shortest
            } else {
                currentResult.status[2] = .stuck
            }
            for item in pending[2].items where !processedItems.contains(where: { $0 === item }) { processedItems.append(item) }
        }
    }

    /// Walks `initialPath` round what is in its way, by each allowed policy
    public func route(_ initialPath: Line) -> Result {
        initialLength = Double(initialPath.cLine.length)
        start(initialPath)
        processedItems.removeAll()
        while iteration < iterationLimit {
            singleStep()
            var stillInProgress = false
            for pol in 0..<3 where enabledPolicies[pol] {
                let lengthFactor = Double(currentResult.lines[pol].cLine.length) / Double(initialPath.cLine.length)
                if lengthLimitOn && currentResult.status[pol] != .done && lengthFactor > lengthExpansionFactor {
                    currentResult.status[pol] = .almostDone
                }
                if currentResult.status[pol] == .inProgress { stillInProgress = true }
            }
            if !stillInProgress { break }
            iteration += 1
        }
        for pol in 0..<3 {
            let ln = currentResult.lines[pol].cLine
            currentResult.lines[pol].clearLinks()
            if currentResult.status[pol] == .inProgress { currentResult.status[pol] = .almostDone }
            if ln.segmentCount < 1 || ln.point(0) != initialPath.cPoint(0) { currentResult.status[pol] = .stuck }
            if ln.pointCount > 0 && ln.lastPoint != initialPath.cLastPoint { currentResult.status[pol] = .almostDone }
        }
        return currentResult
    }
}
