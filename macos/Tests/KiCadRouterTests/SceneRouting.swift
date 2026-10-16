import Foundation
@testable import KiCadRouter

/// A board given as JSON, routed by the Swift port as tools/kicad-reference/router.cpp routes it with KiCad's own
/// router: the same items in the same order, the same rules, the same steps, and the results written the same way
final class SceneInterface: RouterInterface {
    var items: [[String: Any]]
    let layers: Int
    let resolver = SceneResolver()
    var byIndex: [Item?] = []
    var added: [[String: Any]] = []

    init(scene: [String: Any]) {
        items = scene["items"] as! [[String: Any]]
        layers = (scene["layers"] as? NSNumber)?.intValue ?? 2
        let rules = scene["rules"] as? [String: Any] ?? [:]
        func rule(_ k: String, _ d: Int) -> Int { (rules[k] as? NSNumber)?.intValue ?? d }
        resolver.clearance = rule("clearance", 200_000)
        resolver.holeClearance = rule("holeClearance", 250_000)
        resolver.holeToHole = rule("holeToHole", 250_000)
        resolver.edgeClearance = rule("edgeClearance", 500_000)
        resolver.epsilon = rule("epsilon", 0)
    }

    func syncWorld(_ world: Node) {
        byIndex.removeAll()
        resolver.info.removeAll()
        for j in items {
            let kind = j["kind"] as! String
            var item: Item?
            switch kind {
            case "pad", "edge":
                let solid = Solid()
                solid.layers = kind == "edge" ? LayerRange(0, layers - 1) : LayerRange(int((j["layers"] as! [Any])[0]), int((j["layers"] as! [Any])[1]))
                let npth = (j["npth"] as? NSNumber)?.boolValue ?? false
                if kind == "edge" || npth { solid.isRoutable = false }
                solid.net = (j["net"] as? NSNumber)?.intValue ?? 0
                if let p = j["pos"] { solid.setPos(point(p)) }
                if let h = j["hole"], !(h is NSNull) {
                    solid.setHole(Hole(shape: shape(h)))
                    solid.hole!.layers = LayerRange(0, layers - 1)
                }
                solid.solidShape = shape(j["shape"]!)
                item = solid
                resolver.info[ObjectIdentifier(solid)] = (kind, npth)
                world.add(solid)
            case "track":
                let seg = Segment(Seg(point(j["a"]!), point(j["b"]!)), net: int(j["net"]))
                seg.width = int(j["width"])
                seg.setLayer(int(j["layer"]))
                item = seg
                resolver.info[ObjectIdentifier(seg)] = (kind, false)
                world.add(seg, allowRedundant: true)
            case "via":
                let l = j["layers"] as! [Any]
                let layers = LayerRange(int(l[0]), int(l[1]))
                let via = Via(pos: point(j["pos"]!), layers: layers, diameter: 0, drill: int(j["drill"]), net: int(j["net"]))
                via.setDiameter(int(j["diameter"]))
                via.setHole(.circular(point(j["pos"]!), radius: int(j["drill"]) / 2, layers: layers))
                via.setHoleLayers(layers)
                item = via
                resolver.info[ObjectIdentifier(via)] = (kind, false)
                world.add(via)
            default:
                break
            }
            byIndex.append(item)
        }
        world.ruleResolver = resolver
        world.maxClearance = max(resolver.clearance, resolver.holeClearance, resolver.holeToHole, resolver.edgeClearance) + resolver.clearanceEpsilon
    }

    func addItem(_ item: Item) {
        if let s = item as? Segment {
            added.append(["kind": "track", "net": s.net ?? -1, "layer": s.layer, "a": [s.seg.a.x, s.seg.a.y], "b": [s.seg.b.x, s.seg.b.y],
                          "width": s.width])
        } else if let v = item as? Via {
            added.append(["kind": "via", "net": v.net ?? -1, "pos": [v.pos.x, v.pos.y], "diameter": v.diameter, "drill": v.drill,
                          "layers": [v.layers.start, v.layers.end]])
        }
    }

    func updateItem(_ item: Item) {}
    func removeItem(_ item: Item) {}
    func commit() {}
    func isFlashed(_ item: Item, onLayer layer: Int) -> Bool { defaultIsFlashed(item, onLayer: layer) }
    func isFlashed(_ item: Item, onLayers layers: LayerRange) -> Bool { defaultIsFlashed(item, onLayers: layers) }
    func isCopperLayer(_ layer: Int) -> Bool { layer >= 0 && layer < layers }
    func importSizes(_ sizes: inout SizesSettings, startItem: Item?, net: NetHandle?, start: IPoint) -> Bool { false }
    func stackupHeight(_ firstLayer: Int, _ secondLayer: Int) -> Int { 0 }
    func netCode(_ net: NetHandle?) -> Int { net ?? -1 }
    func netName(_ net: NetHandle?) -> String { "Net-\(net ?? -1)" }
    var orphanedNetHandle: NetHandle { 0 }
    var ruleResolver: RuleResolver { resolver }
    var copperLayerCount: Int { layers }

    func int(_ v: Any?) -> Int { (v as! NSNumber).intValue }
    private func point(_ v: Any) -> IPoint {
        let a = v as! [Any]
        return IPoint(int(a[0]), int(a[1]))
    }

    private func shape(_ v: Any) -> Shape {
        let d = v as! [String: Any]
        if let c = d["circle"] { return .circle(center: point(c), radius: int(d["r"])) }
        if let p = d["rect"] {
            let o = point(p), s = point(d["size"]!)
            return .rect(IBox(minX: o.x, minY: o.y, maxX: o.x + s.x, maxY: o.y + s.y))
        }
        if let s = d["segment"] as? [Any] { return .segment(Seg(point(s[0]), point(s[1])), width: int(d["w"])) }
        return .simple(LineChain((d["simple"] as! [Any]).map(point), closed: true))
    }

    /// Routes the scene's routes as router.cpp does; its output, as router.cpp writes it
    static func route(_ scene: [String: Any]) -> [[String: Any]] {
        let iface = SceneInterface(scene: scene)
        let router = Router()
        router.setInterface(iface)
        var out: [[String: Any]] = []
        for route in scene["routes"] as! [[String: Any]] {
            let mode = route["mode"] as? String ?? "walkaround"
            router.settings.mode = mode == "mark" ? .markObstacles : mode == "shove" ? .shove : .walkaround
            router.settings.optimizerEffort = .medium
            router.clearWorld()
            router.syncWorld()
            var sizes = SizesSettings()
            sizes.trackWidth = (route["width"] as? NSNumber)?.intValue ?? 250_000
            sizes.viaDiameter = (route["viaDiameter"] as? NSNumber)?.intValue ?? 600_000
            sizes.viaDrill = (route["viaDrill"] as? NSNumber)?.intValue ?? 300_000
            sizes.clearance = iface.resolver.clearance
            router.updateSizes(sizes)
            func itemAt(_ key: String, _ from: [String: Any]? = nil) -> Item? {
                guard let i = ((from ?? route)[key] as? NSNumber)?.intValue, i >= 0, i < iface.byIndex.count else { return nil }
                return iface.byIndex[i]
            }
            var r: [String: Any] = [:]
            iface.added.removeAll()
            let started = router.startRouting(iface.point(route["start"]!), itemAt("startItem"),
                                              layer: (route["layer"] as? NSNumber)?.intValue ?? 0)
            r["started"] = started
            var moves: [[String: Any]] = []
            if started {
                var finished = false
                // (the steps as router.cpp takes them: a pointer position, or a layer pair, via placement toggled, a
                // layer switch, the posture flipped, a fix, an undo)
                for m in route["moves"] as! [Any] {
                    var step: [String: Any] = [:]
                    if m is [Any] {
                        router.move(iface.point(m), itemAt("endItem"))
                    } else if let m = m as? [String: Any] {
                        if let pair = m["pair"] as? [Any] {
                            var s = router.sizes
                            s.clearLayerPairs()
                            s.addLayerPair(iface.int(pair[0]), iface.int(pair[1]))
                            router.updateSizes(s)
                        } else if let via = m["via"] {
                            if via as? String != "on" || !router.isPlacingVia { router.toggleViaPlacement() }
                        } else if let layer = m["layer"] {
                            step["switched"] = router.switchLayer(iface.int(layer))
                        } else if m["posture"] != nil {
                            router.flipPosture()
                        } else if let fix = m["fix"] {
                            finished = router.fixRoute(iface.point(fix), itemAt("endItem", m["endItem"] != nil ? m : nil))
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
                    moves.append(step)
                    if finished { break }
                }
                if !finished, let fix = route["fix"] {
                    r["fixed"] = router.fixRoute(iface.point(fix), itemAt("endItem"),
                                                 forceFinish: (route["forceFinish"] as? NSNumber)?.boolValue ?? false)
                }
                router.commitRouting()
            }
            // (what the route added, in the order router.cpp sorts it to, for the next route)
            iface.added.sort { canonical($0) < canonical($1) }
            r["moves"] = moves
            r["added"] = iface.added
            out.append(r)
            iface.items += iface.added
        }
        return out
    }

    /// The JSON as nlohmann's dump() writes it: keys in order, no spaces
    static func canonical(_ v: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]), as: UTF8.self)
    }

    static func lineJSON(_ l: Line) -> [String: Any] {
        var j: [String: Any] = ["points": l.cLine.points.map { [$0.x, $0.y] }, "width": l.width, "layer": l.layer]
        if let v = l.via { j["via"] = [v.pos.x, v.pos.y] }
        return j
    }
}

final class SceneResolver: RuleResolver {
    var info: [ObjectIdentifier: (kind: String, npth: Bool)] = [:]
    var clearance = 200_000
    var holeClearance = 250_000
    var holeToHole = 250_000
    var edgeClearance = 500_000
    var epsilon = 0

    private func infoOf(_ item: Item?) -> (kind: String, npth: Bool)? {
        guard let item else { return nil }
        let key = item.kind == .hole ? (item.parentPadVia ?? item) : item
        return info[ObjectIdentifier(key)]
    }

    private func isHole(_ item: Item?) -> Bool { item?.kind == .hole }
    private func isEdge(_ item: Item?) -> Bool { infoOf(item)?.kind == "edge" && !isHole(item) }

    private func isCopper(_ item: Item?) -> Bool {
        guard let i = infoOf(item) else { return true }
        return !(i.kind == "pad" && i.npth)
    }

    func clearance(_ a: Item, _ b: Item?, useEpsilon: Bool) -> Int {
        var rv = 0
        let sameNet = b != nil && a.net != nil && a.net == b!.net
        let freePad = b != nil && (a.isFreePad || b!.isFreePad)
        if isDrilledHole(a) && b.map(isDrilledHole) == true {
            rv = max(rv, holeToHole)
        } else if isHole(a) || isHole(b) {
            if !sameNet { rv = max(rv, holeClearance) }
        }
        if isCopper(a) && (b == nil || isCopper(b)) && !sameNet && !freePad { rv = max(rv, clearance) }
        if isEdge(a) || isEdge(b) { rv = max(rv, edgeClearance) }
        if (sameNet || freePad) && rv == 0 { rv = -1 }
        if useEpsilon && rv > 0 { rv = max(0, rv - epsilon) }
        return rv
    }

    var hasUserDefinedPhysicalConstraint: Bool { false }
    func isInNetTie(_ a: Item) -> Bool { false }
    func isNetTieExclusion(_ item: Item, _ pos: IPoint, _ colliding: Item) -> Bool { false }

    func isDrilledHole(_ item: Item) -> Bool {
        guard isHole(item), let i = infoOf(item) else { return false }
        return i.kind == "pad" || i.kind == "via"
    }

    func isNonPlatedSlot(_ item: Item) -> Bool { false }
    // (router.cpp's items have no BOARD_ITEM, so KiCad never takes its slow edge path for them; here neither)
    func isOnEdgeCuts(_ item: Item) -> Bool { false }
    func isKeepout(_ obstacle: Item, _ item: Item, _ enforce: inout Bool) -> Bool { false }

    func queryConstraint(_ type: ConstraintType, _ a: Item?, _ b: Item?, layer: Int) -> Constraint? {
        switch type {
        case .clearance: return Constraint(type: type, min: clearance)
        case .holeClearance: return Constraint(type: type, min: holeClearance)
        case .holeToHole: return Constraint(type: type, min: holeToHole)
        case .edgeClearance: return Constraint(type: type, min: edgeClearance)
        default: return nil
        }
    }

    var clearanceEpsilon: Int { epsilon }
}
