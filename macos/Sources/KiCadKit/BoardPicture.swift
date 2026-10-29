import Foundation

/// A board as it is drawn: its outline, copper (zones' fills, tracks, vias, pads and their holes), silkscreen,
/// footprints' boxes and references and the connections still to route, all on the board in millimetres, worked out
/// once from the board's file so that drawing it is only drawing
public struct KiCadBoardPicture: Sendable {
    public struct Line: Sendable {
        public var points: [KiCadPoint]
        public var width: Double
        public var closed: Bool
        public var filled: Bool
        public var layer: String
    }

    public struct Pad: Sendable {
        public var outline: [KiCadPoint]
        public var center: KiCadPoint
        /// A round hole's diameter, an oval one's width and height
        public var drill: (width: Double, height: Double)?
        public var angle: Double
        /// "F", "B" or "FB" (both, through the board)
        public var sides: String
        public var net: String?
        public var number: String
        /// The footprint's id
        public var footprint: String
    }

    public struct Footprint: Sendable {
        public var uuid: String
        public var reference: String
        public var value: String
        public var libID: String
        public var position: KiCadPoint
        public var box: KiCadBox
        public var isOnBack: Bool
        public var isDNP: Bool
        /// Where its reference is written, how high, at what angle
        public var label: (at: KiCadPoint, height: Double, angle: Double, visible: Bool)?
    }

    public struct Track: Sendable {
        public var points: [KiCadPoint]
        public var width: Double
        public var layer: String
        public var net: String?
        public var uuid: String = ""
    }

    public struct Via: Sendable {
        public var center: KiCadPoint
        public var size: Double
        public var drill: Double
        public var net: String?
        public var uuid: String = ""
    }

    public struct Zone: Sendable {
        public var layer: String
        public var fills: [[KiCadPoint]]
        public var outline: [KiCadPoint]
        public var net: String?
        public var isRuleArea: Bool
    }

    /// A board's own text: its s-expression as the file has it (for drawing it in KiCad's font), its layer and id
    public struct Text: Sendable {
        public var source: String
        public var layer: String
        public var uuid: String
    }

    public var outline: [Line] = []
    public var silkscreen: [Line] = []
    public var texts: [Text] = []
    public var zones: [Zone] = []
    public var tracks: [Track] = []
    public var vias: [Via] = []
    public var pads: [Pad] = []
    public var footprints: [Footprint] = []
    /// The connections still to route (KiCad's ratsnest)
    public var airwires: [KiCadConnectivity.Airwire] = []
    public var copperLayers: [String] = []
    /// Everything drawn
    public var bounds = KiCadBox(minX: 0, minY: 0, maxX: 100, maxY: 80)
    /// The board's own extent: its outline, if it has one
    public var boardSize: (width: Double, height: Double)?
    /// Its outline's corners' radius (mm), when the outline is one rectangle (as a new board's is)
    public var outlineCornerRadius: Double?

    public init() {}

    public init(_ board: KiCadBoard) {
        let connectivity = KiCadConnectivity(board)
        // a board without its layers' table (a footprint shown on its own) has the two sides
        copperLayers = connectivity.copperLayers.isEmpty ? ["F.Cu", "B.Cu"] : connectivity.copperLayers
        airwires = connectivity.ratsnest()
        func line(_ d: KiCadDrawing) -> Line? {
            let points = d.points
            guard points.count > 1 else { return nil }
            return Line(points: points, width: d.width, closed: d.isClosed, filled: d.isFilled, layer: d.layer)
        }
        var box: KiCadBox?
        func include(_ p: [KiCadPoint]) {
            for q in p { if box == nil { box = KiCadBox(minX: q.x, minY: q.y, maxX: q.x, maxY: q.y) } else { box!.include(q) } }
        }
        outline = board.outline.compactMap(line)
        outlineCornerRadius = board.outlineRectangle?.radius
        for d in board.drawings where d.layer.hasSuffix("SilkS") { if let l = line(d) { silkscreen.append(l) } }
        for node in board.root.items where node.head == "gr_text" {
            texts.append(Text(source: node.compact, layer: node.value("layer") ?? "", uuid: node.value("uuid") ?? ""))
        }
        for footprint in board.footprints {
            for d in footprint.drawings where d.layer.hasSuffix("SilkS") { if let l = line(d) { silkscreen.append(l) } }
            let attrs = footprint.attributes
            var label: (at: KiCadPoint, height: Double, angle: Double, visible: Bool)?
            if let reference = footprint.node.all("property").first(where: { $0.text(at: 0) == "Reference" }),
               let at = reference["at"], let x = at.number(at: 0), let y = at.number(at: 1) {
                let height = reference["effects"]?["font"]?["size"]?.number(at: 0) ?? 1
                label = (footprint.placement.apply(KiCadPoint(x, y)), height, at.number(at: 2) ?? 0,
                         !reference.flag("hide") && reference.value("layer")?.hasSuffix("SilkS") == true)
            }
            let fpBox = footprint.bounds ?? KiCadBox(minX: footprint.position.x - 1, minY: footprint.position.y - 1,
                                                    maxX: footprint.position.x + 1, maxY: footprint.position.y + 1)
            footprints.append(Footprint(uuid: footprint.uuid, reference: footprint.reference, value: footprint.value,
                                        libID: footprint.libID, position: footprint.position, box: fpBox,
                                        isOnBack: footprint.isOnBack, isDNP: attrs.contains("dnp"), label: label))
            include([KiCadPoint(fpBox.minX, fpBox.minY), KiCadPoint(fpBox.maxX, fpBox.maxY)])
            for pad in footprint.pads {
                let layers = pad.layers
                let front = layers.contains { $0 == "*.Cu" || $0 == "F.Cu" || $0 == "F&B.Cu" }
                let back = layers.contains { $0 == "*.Cu" || $0 == "B.Cu" || $0 == "F&B.Cu" }
                var drill: (Double, Double)?
                if let d = pad.node["drill"] {
                    let numbers = d.arguments.compactMap { $0.kind == .symbol ? Double($0.text) : nil }
                    if let w = numbers.first { drill = (w, numbers.count > 1 ? numbers[1] : w) }
                }
                pads.append(Pad(outline: pad.outline, center: pad.position, drill: drill, angle: pad.angle,
                                sides: (front ? "F" : "") + (back ? "B" : ""), net: pad.net, number: pad.number,
                                footprint: footprint.uuid))
            }
        }
        for track in board.tracks {
            tracks.append(Track(points: track.points, width: track.width, layer: track.layer, net: track.net, uuid: track.uuid))
            include(track.points)
        }
        for via in board.vias { vias.append(Via(center: via.position, size: via.size, drill: via.drill, net: via.net, uuid: via.uuid)) }
        for zone in board.zones {
            for layer in zone.layers.isEmpty ? [""] : zone.layers {
                zones.append(Zone(layer: layer, fills: zone.fills.filter { $0.layer == layer }.map(\.points), outline: zone.outline,
                                  net: zone.net, isRuleArea: zone.isRuleArea))
            }
        }
        for l in outline { include(l.points) }
        if let edge = KiCadBox(outline.flatMap(\.points)) { boardSize = (edge.width, edge.height) }
        bounds = (box ?? bounds).inflated(3)
    }

    /// The footprint whose box holds `point` (the smallest, where boxes overlap)
    public func footprint(at point: KiCadPoint) -> Footprint? {
        footprints.filter { $0.box.contains(point) }.min { $0.box.width * $0.box.height < $1.box.width * $1.box.height }
    }

    /// The pad at `point`
    public func pad(at point: KiCadPoint) -> Pad? {
        pads.first { KiCadPolygon.contains($0.outline, point) }
    }

    /// The via, else the track, at `point` (within `slop` of its copper), a track on one of `layers` (the first of
    /// them first): its id
    public func copper(at point: KiCadPoint, layers: [String], slop: Double = 0) -> String? {
        if let via = vias.first(where: { hypot($0.center.x - point.x, $0.center.y - point.y) <= $0.size / 2 + slop }) {
            return via.uuid
        }
        for layer in layers {
            for track in tracks.reversed() where track.layer == layer {
                for (a, b) in zip(track.points, track.points.dropFirst())
                where Self.distance(point, a, b) <= track.width / 2 + slop { return track.uuid }
            }
        }
        return nil
    }

    /// The connection still to route whose line passes within `slop` of `point` (the nearest)
    public func airwire(at point: KiCadPoint, slop: Double) -> KiCadConnectivity.Airwire? {
        airwires.map { ($0, Self.distance(point, $0.from, $0.to)) }.filter { $0.1 <= slop }.min { $0.1 < $1.1 }?.0
    }

    /// How far `p` is from the segment from `a` to `b`
    static func distance(_ p: KiCadPoint, _ a: KiCadPoint, _ b: KiCadPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
