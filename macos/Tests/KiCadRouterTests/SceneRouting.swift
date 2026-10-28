import Foundation
@testable import KiCadRouter

/// A board given as JSON, routed by the Swift port as tools/kicad-reference/router.cpp routes it with KiCad's own
/// router: the same items in the same order (WorldItem's scene form), the same rules, the same steps, and the
/// results written the same way
enum SceneRouting {
    /// Routes the scene's routes as router.cpp does; its output, as router.cpp writes it
    static func route(_ scene: [String: Any]) -> [[String: Any]] {
        let copper = (scene["layers"] as? NSNumber)?.intValue ?? 2
        var items = (scene["items"] as! [[String: Any]]).compactMap { WorldItem(scene: $0, layers: copper) }
        var rules = WorldRules(scene: scene["rules"] as? [String: Any] ?? [:])
        // (the nets' names, which say which are differential pairs)
        for (code, name) in scene["netNames"] as? [String: Any] ?? [:] {
            if let n = Int(code), let name = name as? String { rules.netNames[n] = name }
        }
        let iface = WorldInterface(items: items, layers: copper, rules: rules)
        // (the board's thickness between its copper layers, which a length tuning counts for a via)
        iface.stackupHeights = (scene["stackupHeights"] as? [[Any]] ?? []).map { $0.map(int) }
        let router = Router()
        router.setInterface(iface)
        var out: [[String: Any]] = []
        // (what a route takes off the board listed, and gone for the routes after it, if the scene says so)
        let removeItems = (scene["removeItems"] as? NSNumber)?.boolValue ?? false
        for route in scene["routes"] as! [[String: Any]] {
            let mode = route["mode"] as? String ?? "walkaround"
            router.settings.mode = mode == "mark" ? .markObstacles : mode == "shove" ? .shove : .walkaround
            router.settings.optimizerEffort = .medium
            // (no time limit on a shove, as router.cpp sets KiCad's: it gives up after a second, by the clock, which
            // would make what it does depend on how fast the machine is, and a debug build is slower; it stops on its
            // iteration limit alone)
            router.settings.shoveTimeLimit = Int(Int32.max)
            router.settings.smoothDraggedSegments = (route["smooth"] as? NSNumber)?.boolValue ?? true
            router.settings.optimizeEntireDraggedTrack = (route["optimizeEntire"] as? NSNumber)?.boolValue ?? false
            router.settings.allowDRCViolationsSetting = (route["allowViolations"] as? NSNumber)?.boolValue ?? false
            router.settings.fixAllSegments = (route["fixAll"] as? NSNumber)?.boolValue ?? true
            // (the track corner mode: mitered or rounded, at 45 or 90 degrees)
            router.settings.cornerMode = Direction45.CornerMode(rawValue: (route["cornerMode"] as? NSNumber)?.intValue ?? 0) ?? .mitered45
            // (a differential pair, the router tool's Route Differential Pair; a length tuning, the tuning pattern
            // generator's, of a track, a pair or a pair's skew; else a single track)
            let diffPair = (route["diffPair"] as? NSNumber)?.boolValue ?? false
            let tune = route["tune"] as? [String: Any]
            let tuneMode: Router.Mode = tune?["mode"] as? String == "diffpair" ? .tuneDiffPair
                : tune?["mode"] as? String == "skew" ? .tuneDiffPairSkew : .tuneSingle
            router.mode = diffPair ? .routeDiffPair : tune != nil ? tuneMode : .routeSingle
            iface.items = items
            router.clearWorld()
            router.syncWorld()
            var sizes = SizesSettings()
            sizes.trackWidth = (route["width"] as? NSNumber)?.intValue ?? 250_000
            sizes.viaDiameter = (route["viaDiameter"] as? NSNumber)?.intValue ?? 600_000
            sizes.viaDrill = (route["viaDrill"] as? NSNumber)?.intValue ?? 300_000
            sizes.clearance = rules.clearance
            // (a pair's sizes, and its vias' hole clearances as ImportSizes takes them from the rules, as router.cpp
            // sets them)
            sizes.diffPairWidth = (route["dpWidth"] as? NSNumber)?.intValue ?? 125_000
            sizes.diffPairGap = (route["dpGap"] as? NSNumber)?.intValue ?? 180_000
            if let viaGap = route["dpViaGap"] as? NSNumber {
                sizes.diffPairViaGap = viaGap.intValue
                sizes.diffPairViaGapSameAsTraceGap = false
            }
            sizes.diffPairHoleToHole = rules.holeToHole
            sizes.diffPairCopperToHole = rules.holeClearance
            sizes.minClearance = (route["minClearance"] as? NSNumber)?.intValue ?? 0
            router.updateSizes(sizes)
            func itemAt(_ key: String, _ from: [String: Any]? = nil) -> Item? {
                guard let i = ((from ?? route)[key] as? NSNumber)?.intValue, i >= 0, i < iface.routerItems.count else { return nil }
                // (an item taken off the board by a part of the route already committed is gone, as router.cpp has it)
                if iface.removedItems.contains(where: { $0 === iface.routerItems[i] }) { return nil }
                return iface.routerItems[i]
            }
            var r: [String: Any] = [:]
            iface.added.removeAll()
            iface.removedItems.removeAll()
            // (with the first route, the keepout zones' triangles as the world has them, if there are any)
            if out.isEmpty, let world = router.world {
                let triangles: [[String: Any]] = world.index.all.compactMap { item in
                    guard iface.worldItem(item)?.kind == .keepout, let s = item as? Solid, case .simple(let c)? = s.solidShape else { return nil }
                    return ["layer": s.layer, "triangle": c.points.map { [$0.x, $0.y] }]
                }
                if !triangles.isEmpty { r["keepoutTriangles"] = triangles }
            }
            // (a drag, of the item the route names, from where it says; else a track from its start)
            let drag = route["drag"] as? [String: Any]
            let started: Bool
            if let drag {
                started = router.startDragging(point(drag["at"]!), itemAt("item", drag),
                                               mode: (drag["freeAngle"] as? NSNumber)?.boolValue == true ? [.any, .freeAngle] : .any)
            } else if let tune {
                started = router.startRouting(point(tune["at"]!), itemAt("item", tune),
                                              layer: (tune["layer"] as? NSNumber)?.intValue ?? 0)
            } else {
                started = router.startRouting(point(route["start"]!), itemAt("startItem"),
                                              layer: (route["layer"] as? NSNumber)?.intValue ?? 0)
            }
            r["started"] = started
            if !started { r["failure"] = router.failureReason }
            var moves: [[String: Any]] = []
            var lastNode = canonical(NSNull())
            if started && drag != nil {
                moves = dragSteps(router, route, &r, iface, removeItems)
            } else if started && tune != nil {
                moves = tuneSteps(router, route, &r, iface, removeItems)
            } else if started {
                var finished = false
                // (the steps as router.cpp takes them: a pointer position, or a layer pair, via placement toggled, a
                // layer switch, the posture flipped, a fix, an undo; a pair's moves with whether it got there clear)
                for m in route["moves"] as! [Any] {
                    var step: [String: Any] = [:]
                    if m is [Any] {
                        let moved = router.move(point(m), itemAt("endItem"))
                        if diffPair { step["moved"] = moved }
                    } else if let m = m as? [String: Any] {
                        if let to = m["move"] {
                            let moved = router.move(point(to), itemAt("endItem", m))
                            if diffPair { step["moved"] = moved }
                        } else if let pair = m["pair"] as? [Any] {
                            var s = router.sizes
                            s.clearLayerPairs()
                            s.addLayerPair(int(pair[0]), int(pair[1]))
                            router.updateSizes(s)
                        } else if let via = m["via"] {
                            if via as? String != "on" || !router.isPlacingVia { router.toggleViaPlacement() }
                        } else if let layer = m["layer"] {
                            step["switched"] = router.switchLayer(int(layer))
                        } else if m["posture"] != nil {
                            router.flipPosture()
                        } else if let fix = m["fix"] {
                            finished = router.fixRoute(point(fix), itemAt("endItem", m["endItem"] != nil ? m : nil))
                            step["fixed"] = finished
                        } else if m["undo"] != nil {
                            step["undone"] = router.undoLastSegment().map { [$0.x, $0.y] } ?? NSNull()
                        }
                    }
                    let placer = router.placer!
                    if let linePlacer = router.linePlacer {
                        step["head"] = lineJSON(linePlacer.head)
                        step["tail"] = lineJSON(linePlacer.tail)
                        step["trace"] = lineJSON(linePlacer.trace)
                    } else {
                        // (the pair's positive and negative lines)
                        let traces = placer.traces()
                        step["p"] = lineJSON(traces[0] as! Line)
                        step["n"] = lineJSON(traces[1] as! Line)
                    }
                    step["layer"] = router.currentLayer
                    step["placingVia"] = router.isPlacingVia
                    // (and the board as the router has it now, what it has shoved where, for a scene that asks: when
                    // it has changed since the step before)
                    if removeItems {
                        let node = nodeJSON(placer.currentNode(loopsRemoved: true), iface)
                        let key = canonical(node)
                        if key != lastNode { step["node"] = node }
                        lastNode = key
                    }
                    moves.append(step)
                    if finished { break }
                }
                if !finished, let fix = route["fix"] {
                    r["fixed"] = router.fixRoute(point(fix), itemAt("endItem"),
                                                 forceFinish: (route["forceFinish"] as? NSNumber)?.boolValue ?? false)
                }
                router.commitRouting()
            }
            // (what the route added, in the order router.cpp sorts it to, for the next route)
            let added = iface.added.compactMap(addedJSON).sorted { canonical($0) < canonical($1) }
            r["moves"] = moves
            r["added"] = added
            if removeItems {
                let removed = iface.removedItems.compactMap { item in iface.routerItems.firstIndex { $0 === item } }.sorted()
                r["removed"] = removed
                for i in removed.reversed() { items.remove(at: i) }
            }
            out.append(r)
            items += added.compactMap { WorldItem(scene: $0, layers: copper) }
        }
        return out
    }

    /// A drag's steps, as router.cpp drives them (as the router tool's performDragging does): pointer positions and
    /// clicks, the last click the route's if the drag is still going on; after each, what router.cpp writes
    static func dragSteps(_ router: Router, _ route: [String: Any], _ r: inout [String: Any], _ iface: WorldInterface,
                          _ removeItems: Bool) -> [[String: Any]] {
        var moves: [[String: Any]] = []
        var finished = false
        var lastNode = canonical(NSNull())
        for m in route["moves"] as! [Any] {
            var step: [String: Any] = [:]
            if m is [Any] {
                step["moved"] = router.move(point(m), nil)
            } else if let m = m as? [String: Any], let fix = m["fix"] {
                finished = router.fixRoute(point(fix), nil, forceCommit: (m["force"] as? NSNumber)?.boolValue ?? false)
                step["fixed"] = finished
            }
            // (a drag kept is in the world, and the dragger's branches gone)
            if !finished, let dragger = router.dragger {
                step["forceMark"] = dragger.forceMarkObstaclesMode
                step["status"] = dragger.dragStatus
                step["dragged"] = dragger.traces.compactMap { item -> [String: Any]? in
                    if let l = item as? Line { return lineJSON(l) }
                    return addedJSON(item)
                }
                step["layer"] = router.currentLayer
                if removeItems {
                    let node = nodeJSON(dragger.currentNode, iface)
                    let key = canonical(node)
                    if key != lastNode { step["node"] = node }
                    lastNode = key
                }
            }
            moves.append(step)
            if finished { break }
        }
        if !finished, let fix = route["fix"] {
            r["fixed"] = router.fixRoute(point(fix), nil, forceCommit: (route["force"] as? NSNumber)?.boolValue ?? false)
        }
        router.stopRouting()
        return moves
    }

    /// A length tuning's settings as router.cpp reads them from a route ("meander"), KiCad's defaults for the rest
    static func meanderSettings(_ j: [String: Any]) -> MeanderSettings {
        var s = MeanderSettings()
        func value(_ key: String) -> Int? { (j[key] as? NSNumber)?.intValue }
        if let t = value("targetLength") { s.setTargetLength(t) }
        if let t = value("targetMin") { s.targetLength.min = t }
        if let t = value("targetMax") { s.targetLength.max = t }
        if let t = value("targetSkew") { s.setTargetSkew(t) }
        if let t = value("skewMin") { s.targetSkew.min = t }
        if let t = value("skewMax") { s.targetSkew.max = t }
        s.minAmplitude = value("minAmplitude") ?? s.minAmplitude
        s.maxAmplitude = value("maxAmplitude") ?? s.maxAmplitude
        s.spacing = value("spacing") ?? s.spacing
        s.step = value("step") ?? s.step
        s.cornerStyle = j["cornerStyle"] as? String == "chamfer" ? .chamfer : .round
        s.cornerRadiusPercentage = value("cornerRadius") ?? s.cornerRadiusPercentage
        s.singleSided = (j["singleSided"] as? NSNumber)?.boolValue ?? s.singleSided
        s.initialSide = value("initialSide").flatMap(MeanderSide.init(rawValue:)) ?? s.initialSide
        s.keepEndpoints = (j["keepEndpoints"] as? NSNumber)?.boolValue ?? s.keepEndpoints
        return s
    }

    /// What a meander placer has, as router.cpp writes it: the tuned line (or a pair's two), the tuning's status and
    /// length, and its settings now
    static func tuningJSON(_ placer: MeanderPlacerBase, _ step: inout [String: Any]) {
        let traces = placer.traces()
        if traces.count == 2 {
            step["p"] = lineJSON(traces[0] as! Line)
            step["n"] = lineJSON(traces[1] as! Line)
        } else {
            step["trace"] = lineJSON(traces[0] as! Line)
        }
        step["status"] = placer.tuningStatus.rawValue
        step["length"] = placer.tuningLengthResult
        step["initialSide"] = placer.meanderSettings.initialSide.rawValue
        step["maxAmplitude"] = placer.meanderSettings.maxAmplitude
        step["spacing"] = placer.meanderSettings.spacing
    }

    /// A length tuning's steps, as router.cpp drives them (as the tuning pattern generator does): the settings given,
    /// then pointer positions, amplitude and spacing steps and a fix; after each, what router.cpp writes; then the
    /// router stopped
    static func tuneSteps(_ router: Router, _ route: [String: Any], _ r: inout [String: Any], _ iface: WorldInterface,
                          _ removeItems: Bool) -> [[String: Any]] {
        let placer = router.meanderPlacer!
        placer.updateSettings(meanderSettings(route["meander"] as? [String: Any] ?? [:]))
        r["tunedPath"] = placer.tunedPath().map { item -> Any in
            if let l = item as? Line { return lineJSON(l) }
            return addedJSON(item) ?? NSNull()
        }
        r["startLength"] = placer.tuningLengthResult
        var moves: [[String: Any]] = []
        var finished = false
        var lastNode = canonical(NSNull())
        for m in route["moves"] as! [Any] {
            var step: [String: Any] = [:]
            if m is [Any] {
                step["moved"] = router.move(point(m), nil)
            } else if let m = m as? [String: Any] {
                if let a = m["amplitude"] {
                    placer.amplitudeStep(int(a))
                } else if let s = m["spacing"] {
                    placer.spacingStep(int(s))
                } else if let fix = m["fix"] {
                    finished = router.fixRoute(point(fix), nil, forceFinish: true)
                    step["fixed"] = finished
                }
            }
            if !finished {
                tuningJSON(placer, &step)
                if removeItems {
                    let node = nodeJSON(placer.currentNode(loopsRemoved: true), iface)
                    let key = canonical(node)
                    if key != lastNode { step["node"] = node }
                    lastNode = key
                }
            }
            moves.append(step)
            if finished { break }
        }
        if !finished, let fix = route["fix"] {
            r["fixed"] = router.fixRoute(point(fix), nil, forceFinish: true)
        }
        router.stopRouting()
        return moves
    }

    /// The board as a branch of the router's world has it, as router.cpp writes it: the board's items it takes off
    /// (their indices) and the tracks and vias it puts on, each in one order
    static func nodeJSON(_ node: Node?, _ iface: WorldInterface) -> Any {
        guard let node else { return NSNull() }
        let (removed, added) = node.updatedItems()
        let indices = removed.compactMap { item in iface.routerItems.firstIndex { $0 === item } }.sorted()
        let items = added.compactMap(addedJSON).sorted { canonical($0) < canonical($1) }
        return ["removed": indices, "added": items]
    }

    /// What the router put on the board, as router.cpp writes it
    static func addedJSON(_ item: Item) -> [String: Any]? {
        if let a = item as? Arc {
            return ["kind": "arc", "net": a.net ?? -1, "layer": a.layer, "start": [a.arc.start.x, a.arc.start.y],
                    "mid": [a.arc.mid.x, a.arc.mid.y], "end": [a.arc.end.x, a.arc.end.y], "width": a.width]
        }
        if let s = item as? Segment {
            return ["kind": "track", "net": s.net ?? -1, "layer": s.layer, "a": [s.seg.a.x, s.seg.a.y], "b": [s.seg.b.x, s.seg.b.y],
                    "width": s.width]
        }
        if let v = item as? Via {
            var j: [String: Any] = ["kind": "via", "net": v.net ?? -1, "pos": [v.pos.x, v.pos.y], "diameter": v.diameter, "drill": v.drill,
                                    "layers": [v.layers.start, v.layers.end]]
            // (a via's type, unless it goes through, as router.cpp writes it)
            if v.viaType != .through { j["viaType"] = WorldItem.viaTypes.first { $0.0 == v.viaType }?.1 }
            return j
        }
        return nil
    }

    /// The JSON as nlohmann's dump() writes it: keys in order, no spaces
    static func canonical(_ v: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }

    static func lineJSON(_ l: Line) -> [String: Any] {
        var j: [String: Any] = ["points": l.cLine.points.map { [$0.x, $0.y] }, "width": l.width, "layer": l.layer]
        if let v = l.via { j["via"] = [v.pos.x, v.pos.y] }
        // (a line with arcs: its arcs, their three points and centre, and the arcs each point is on)
        if l.cLine.arcCount > 0 {
            j["arcs"] = l.cLine.arcs.map { [[$0.start.x, $0.start.y], [$0.mid.x, $0.mid.y], [$0.end.x, $0.end.y], [$0.center.x, $0.center.y]] }
            j["shapes"] = l.cLine.shapes.map { [$0.first, $0.second] }
        }
        return j
    }

    private static func int(_ v: Any?) -> Int { (v as! NSNumber).intValue }

    private static func point(_ v: Any) -> IPoint {
        let a = v as! [Any]
        return IPoint(int(a[0]), int(a[1]))
    }
}
