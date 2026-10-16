// The router's world as JSON: the scenes tools/kicad-reference's router.cpp routes with KiCad's own router, and
// board-scene.py writes from KiCad's own reading of a board. GNU General Public License version 3 or later, as the
// router (see KICAD-NOTICE.md).

import Foundation

extension Shape {
    /// A shape as a scene gives it: {"circle": [x, y], "r"}, {"rect": [x, y], "size": [w, h]}, {"segment": [a, b],
    /// "w"}, {"simple": points}, {"chain": points}, {"arc": [start, mid, end], "w"}
    public init?(scene v: Any?) {
        guard let d = v as? [String: Any] else { return nil }
        func int(_ x: Any?) -> Int { (x as? NSNumber)?.intValue ?? 0 }
        func point(_ x: Any?) -> IPoint {
            let a = x as? [Any] ?? []
            return a.count == 2 ? IPoint(int(a[0]), int(a[1])) : .zero
        }
        func points(_ x: Any?) -> [IPoint] { (x as? [Any] ?? []).map(point) }
        if let c = d["circle"] {
            self = .circle(center: point(c), radius: int(d["r"]))
        } else if let p = d["rect"] {
            let o = point(p), s = point(d["size"])
            self = .rect(IBox(minX: o.x, minY: o.y, maxX: o.x + s.x, maxY: o.y + s.y))
        } else if let s = d["segment"] as? [Any], s.count == 2 {
            self = .segment(Seg(point(s[0]), point(s[1])), width: int(d["w"]))
        } else if let a = d["arc"] as? [Any], a.count == 3 {
            self = .arc(ShapeArc(start: point(a[0]), mid: point(a[1]), end: point(a[2]), width: int(d["w"])))
        } else if let s = d["simple"] {
            self = .simple(LineChain(points(s), closed: true))
        } else if let c = d["chain"] {
            self = .chain(LineChain(points(c)))
        } else {
            return nil
        }
    }

    /// The shape as a scene gives it
    public var scene: [String: Any] {
        func p(_ q: IPoint) -> [Int] { [q.x, q.y] }
        switch self {
        case .circle(let c, let r): return ["circle": p(c), "r": r]
        case .rect(let b): return ["rect": [b.minX, b.minY], "size": [b.maxX - b.minX, b.maxY - b.minY]]
        case .segment(let s, let w): return ["segment": [p(s.a), p(s.b)], "w": w]
        case .simple(let l): return ["simple": l.points.map(p)]
        case .chain(let l): return ["chain": l.points.map(p)]
        case .arc(let a): return ["arc": [p(a.start), p(a.mid), p(a.end)], "w": a.width]
        }
    }
}

extension WorldItem {
    /// An item as a scene gives it
    public init?(scene j: [String: Any], layers layerCount: Int) {
        guard let k = j["kind"] as? String, let kind = Kind(rawValue: k) else { return nil }
        self.init(kind: kind)
        func int(_ x: Any?) -> Int { (x as? NSNumber)?.intValue ?? 0 }
        func bool(_ x: Any?) -> Bool { (x as? NSNumber)?.boolValue ?? false }
        func point(_ x: Any?) -> IPoint {
            let a = x as? [Any] ?? []
            return a.count == 2 ? IPoint(int(a[0]), int(a[1])) : .zero
        }
        npth = bool(j["npth"])
        copper = (j["copper"] as? NSNumber)?.boolValue ?? (kind != .edge)
        drilled = bool(j["drilled"])
        npthSlot = bool(j["npthSlot"])
        clearanceOverride = (j["clearanceOverride"] as? NSNumber)?.intValue
        flashed = (j["flashed"] as? [Any])?.map { bool($0) } ?? []
        freePad = bool(j["freePad"])
        compound = bool(j["compound"])
        locked = bool(j["locked"])
        free = bool(j["free"])
        footprint = j["footprint"] as? String
        // (a text and a zone have no net; anything else a net, the orphaned one if none of its own)
        net = kind == .text || kind == .keepout ? nil : (j["net"] as? NSNumber)?.intValue ?? 0
        if let l = j["layers"] as? [Any], l.count == 2 {
            layers = LayerRange(int(l[0]), int(l[1]))
        } else if kind == .edge {
            layers = LayerRange(0, layerCount - 1)
        }
        shape = Shape(scene: j["shape"])
        if let h = j["hole"], !(h is NSNull) { hole = Shape(scene: h) }
        if let p = j["pos"] { pos = point(p) }
        if let o = j["offset"] { offset = point(o) }
        switch kind {
        case .track:
            a = point(j["a"])
            b = point(j["b"])
            width = int(j["width"])
            layer = int(j["layer"])
        case .arc:
            a = point(j["start"])
            mid = point(j["mid"])
            b = point(j["end"])
            width = int(j["width"])
            layer = int(j["layer"])
        case .via:
            a = point(j["pos"])
            pos = nil
            diameter = int(j["diameter"])
            drill = int(j["drill"])
        case .keepout:
            // (a keepout zone's layers are a list, each one its triangles are put on)
            zoneLayers = (j["layers"] as? [Any] ?? []).map(int)
            layers = LayerRange(zoneLayers.min() ?? 0, zoneLayers.max() ?? 0)
            // (each outline and hole as router.cpp makes it: a closed chain, a point the same as the one before it
            // left out, as SHAPE_POLY_SET::Append leaves it out)
            polygons = (j["polygons"] as? [Any] ?? []).map { poly in
                (poly as? [Any] ?? []).map { chain in
                    var c = LineChain()
                    c.setClosed(true)
                    for p in (chain as? [Any] ?? []).map(point) { c.append(p) }
                    return c
                }
            }
            if let k = j["keepout"] as? [String: Any] {
                keepout = Keepout(tracks: bool(k["tracks"]), vias: bool(k["vias"]), pads: bool(k["pads"]),
                                  footprints: bool(k["footprints"]), footprint: k["footprint"] as? String,
                                  name: k["name"] as? String ?? "")
            }
        default:
            break
        }
    }

    /// The item as a scene gives it (board-scene.py's form)
    public var scene: [String: Any] {
        func p(_ q: IPoint) -> [Int] { [q.x, q.y] }
        var j: [String: Any] = ["kind": kind.rawValue]
        switch kind {
        case .track:
            j["net"] = net ?? 0
            j["layer"] = layer
            j["a"] = p(a)
            j["b"] = p(b)
            j["width"] = width
            j["locked"] = locked
        case .arc:
            j["net"] = net ?? 0
            j["layer"] = layer
            j["start"] = p(a)
            j["mid"] = p(mid)
            j["end"] = p(b)
            j["width"] = width
            j["locked"] = locked
        case .via:
            j["net"] = net ?? 0
            j["pos"] = p(a)
            j["layers"] = [layers.start, layers.end]
            j["diameter"] = diameter
            j["drill"] = drill
            j["free"] = free
            j["locked"] = locked
            j["flashed"] = flashed
        case .keepout:
            j["layers"] = zoneLayers
            j["polygons"] = polygons.map { $0.map { $0.points.map(p) } }
            if let k = keepout {
                j["keepout"] = ["tracks": k.tracks, "vias": k.vias, "pads": k.pads, "footprints": k.footprints,
                                "footprint": k.footprint as Any? ?? NSNull(), "name": k.name]
            }
        case .pad:
            j["net"] = net ?? 0
            j["layers"] = [layers.start, layers.end]
            if let pos { j["pos"] = p(pos) }
            j["offset"] = p(offset ?? .zero)
            if let shape { j["shape"] = shape.scene }
            j["npth"] = npth
            j["freePad"] = freePad
            j["copper"] = copper
            j["drilled"] = drilled
            j["npthSlot"] = npthSlot
            j["flashed"] = flashed
            if let footprint { j["footprint"] = footprint }
            if let clearanceOverride { j["clearanceOverride"] = clearanceOverride }
            if let hole { j["hole"] = hole.scene }
        case .edge, .graphic:
            if let shape { j["shape"] = shape.scene }
            j["net"] = net ?? 0
            j["layers"] = [layers.start, layers.end]
            j["copper"] = copper
            j["compound"] = compound
        case .text:
            j["layers"] = [layers.start, layers.end]
            if let shape { j["shape"] = shape.scene }
            j["copper"] = copper
        }
        return j
    }
}

extension WorldRules {
    /// The rules as a scene gives them: {"clearance", "holeClearance", "holeToHole", "edgeClearance", "epsilon"},
    /// and for a board's {"board": true, "minClearance", "maxClearance", "netClearance": {net: clearance}, "maxError"}
    public init(scene r: [String: Any]) {
        self.init()
        func int(_ k: String, _ d: Int) -> Int { (r[k] as? NSNumber)?.intValue ?? d }
        clearance = int("clearance", 200_000)
        holeClearance = int("holeClearance", 250_000)
        holeToHole = int("holeToHole", 250_000)
        edgeClearance = int("edgeClearance", 500_000)
        epsilon = int("epsilon", 0)
        if (r["board"] as? NSNumber)?.boolValue == true {
            board = true
            clearance = int("minClearance", 0)
            maxClearance = int("maxClearance", 0)
            maxError = int("maxError", 5000)
            for (code, c) in r["netClearance"] as? [String: Any] ?? [:] {
                if let n = Int(code), let v = c as? NSNumber { netClearance[n] = v.intValue }
            }
        }
    }

    public var scene: [String: Any] {
        guard board else {
            return ["clearance": clearance, "holeClearance": holeClearance, "holeToHole": holeToHole,
                    "edgeClearance": edgeClearance, "epsilon": epsilon]
        }
        return ["board": true, "minClearance": clearance, "holeClearance": holeClearance, "holeToHole": holeToHole,
                "edgeClearance": edgeClearance, "epsilon": epsilon, "maxClearance": maxClearance ?? 0,
                "netClearance": Dictionary(uniqueKeysWithValues: netClearance.map { (String($0.key), $0.value) }),
                "maxError": maxError]
    }
}
