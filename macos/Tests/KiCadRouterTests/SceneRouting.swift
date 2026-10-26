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
        let rules = WorldRules(scene: scene["rules"] as? [String: Any] ?? [:])
        let iface = WorldInterface(items: items, layers: copper, rules: rules)
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
            iface.items = items
            router.clearWorld()
            router.syncWorld()
            var sizes = SizesSettings()
            sizes.trackWidth = (route["width"] as? NSNumber)?.intValue ?? 250_000
            sizes.viaDiameter = (route["viaDiameter"] as? NSNumber)?.intValue ?? 600_000
            sizes.viaDrill = (route["viaDrill"] as? NSNumber)?.intValue ?? 300_000
            sizes.clearance = rules.clearance
            router.updateSizes(sizes)
            func itemAt(_ key: String, _ from: [String: Any]? = nil) -> Item? {
                guard let i = ((from ?? route)[key] as? NSNumber)?.intValue, i >= 0, i < iface.routerItems.count else { return nil }
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
            } else if started {
                var finished = false
                // (the steps as router.cpp takes them: a pointer position, or a layer pair, via placement toggled, a
                // layer switch, the posture flipped, a fix, an undo)
                for m in route["moves"] as! [Any] {
                    var step: [String: Any] = [:]
                    if m is [Any] {
                        router.move(point(m), itemAt("endItem"))
                    } else if let m = m as? [String: Any] {
                        if let to = m["move"] {
                            router.move(point(to), itemAt("endItem", m))
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
                    step["head"] = lineJSON(placer.head)
                    step["tail"] = lineJSON(placer.tail)
                    step["trace"] = lineJSON(placer.trace)
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
        if let s = item as? Segment {
            return ["kind": "track", "net": s.net ?? -1, "layer": s.layer, "a": [s.seg.a.x, s.seg.a.y], "b": [s.seg.b.x, s.seg.b.y],
                    "width": s.width]
        }
        if let v = item as? Via {
            return ["kind": "via", "net": v.net ?? -1, "pos": [v.pos.x, v.pos.y], "diameter": v.diameter, "drill": v.drill,
                    "layers": [v.layers.start, v.layers.end]]
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
        return j
    }

    private static func int(_ v: Any?) -> Int { (v as! NSNumber).intValue }

    private static func point(_ v: Any) -> IPoint {
        let a = v as! [Any]
        return IPoint(int(a[0]), int(a[1]))
    }
}
