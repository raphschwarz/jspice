// Ported from KiCad 10.0.8: pcbnew/zone_filler.cpp (ZONE_FILLER::Fill: the state of conditional via and pad flashing
// determined before filling, from the zones' outlines, and its second pass once filled, from the fills;
// findHighestPriorityZone, isInPourKeepoutArea, zoneReachesPoint), libs/kimath/include/geometry/
// poly_containment_index.h (POLY_CONTAINMENT_INDEX::Contains), pcbnew/pad.cpp and pcbnew/pcb_track.cpp
// (ClearZoneLayerOverrides, SetZoneLayerOverride) and pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.cpp (a pad's and a
// via's zone layer connections as KiCad writes them).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension ZoneFiller {
    // MARK: - Before filling

    /// findHighestPriorityZone: of the board's zones (not rule areas) on the layer whose boxes meet the item's and
    /// that pass `test`, the one of the highest priority, a later one of the same priority where it is of the item's
    /// net (and none of priority 0 not of it)
    func highestPriorityZone(_ box: IBox, _ layer: Int, _ net: Int, _ test: (FillZone) -> Bool) -> FillZone? {
        var highest = 0
        var best: FillZone?
        for z in boardZones {
            if z.ruleArea || z.priority < highest || !z.isOnLayer(layer) || z.numCorners <= 2 || !z.bbox.intersects(box) { continue }
            if !test(z) { continue }
            if z.priority > highest || z.net == net {
                highest = z.priority
                best = z
            }
        }
        return best
    }

    /// isInPourKeepoutArea: whether a board's rule area keeping out zone fills on the layer, whose box meets the
    /// item's, has the point in its outline
    func isInPourKeepoutArea(_ box: IBox, _ layer: Int, _ p: IPoint) -> Bool {
        boardZones.contains { z in
            z.ruleArea && z.hasKeepoutParameters && z.doNotAllowZoneFills && z.isOnLayer(layer) && z.numCorners > 2
                && z.bbox.intersects(box) && z.outline.contains(p)
        }
    }

    /// The state of conditional via and pad flashing, determined before filling from the zones' outlines: each via's
    /// and pad's overrides cleared, and on each layer it flashes only where connected, not to be joined to a zone in
    /// a rule area keeping out fills, else flashed where the highest priority zone over its hole (a via's: touching
    /// it) or its position (a pad's) is of its net (a via that keeps only its ends, on those), not to be joined to one
    /// otherwise. Then each one's layers flashed as the fill asks them (FlashLayer) by these overrides.
    func determineConditionalFlashing() {
        for t in copper.tracks where t.kind == .via {
            guard let v = t.via else { continue }
            t.zoneLayerOverrides = [:]
            // (GetRemoveUnconnected)
            guard v.unconnectedLayers != .keepAll else { continue }
            let box = viaBox(v), center = v.start, holeRadius = v.drill / 2 + 1
            for rl in t.layers where drc.conditionallyFlashed(t, rl) {
                let l = drc.kiLayer(rl)
                if isInPourKeepoutArea(box, l, center) {
                    t.zoneLayerOverrides[rl] = .forceNoZoneConnection
                    continue
                }
                let zone = highestPriorityZone(box, l, t.net) { $0.outline.contains(center, accuracy: holeRadius) }
                if let zone, zone.net == t.net, v.unconnectedLayers != .startEndOnly || rl == v.layers.start || rl == v.layers.end {
                    t.zoneLayerOverrides[rl] = .forceFlashed
                } else {
                    t.zoneLayerOverrides[rl] = .forceNoZoneConnection
                }
            }
        }
        for pads in copper.footprintPads {
            for item in pads {
                guard let p = item.pad else { continue }
                item.zoneLayerOverrides = [:]
                guard p.unconnectedLayers != .keepAll else { continue }
                let center = p.pad.pos
                for rl in world.copper(p.pad.layers) where drc.conditionallyFlashed(item, rl) {
                    let l = drc.kiLayer(rl)
                    if isInPourKeepoutArea(item.bbox, l, center) {
                        item.zoneLayerOverrides[rl] = .forceNoZoneConnection
                        continue
                    }
                    let zone = highestPriorityZone(item.bbox, l, item.net) { $0.outline.contains(center) }
                    item.zoneLayerOverrides[rl] = zone.map { $0.net == item.net } == true ? .forceFlashed : .forceNoZoneConnection
                }
            }
        }
        drc.applyFlashing(copper, connectivity)
    }

    // MARK: - Once filled

    /// POLY_CONTAINMENT_INDEX::Contains: whether the point is inside one of the set's outlines (its holes not looked
    /// at: a fill's are fractured into it), by the crossings of a ray to its right as SHAPE_LINE_CHAIN::PointInside
    /// counts them; or, `accuracy` more than 1, within it of one of their edges
    static func containmentIndexContains(_ set: PolySet, _ p: IPoint, _ accuracy: Int) -> Bool {
        var edges: [(IPoint, IPoint)] = []
        var crossings = [Int](repeating: 0, count: set.outlineCount)
        for (i, poly) in set.polygons.enumerated() {
            let outline = poly[0]
            let n = outline.pointCount
            guard n >= 3 else { continue }
            for j in 0..<n {
                let p1 = outline.point(j), p2 = outline.point((j + 1) % n)
                edges.append((p1, p2))
                // (the edges whose boxes reach the ray's: right of the point, across its height)
                guard max(p1.x, p2.x) >= p.x, min(p1.y, p2.y) <= p.y, max(p1.y, p2.y) >= p.y else { continue }
                if (p1.y >= p.y) == (p2.y >= p.y) { continue }
                let d = KiMath.rescale(p2.x - p1.x, p.y - p1.y, p2.y - p1.y)
                if p.x - p1.x < d { crossings[i] += 1 }
            }
        }
        if crossings.contains(where: { $0 & 1 != 0 }) { return true }
        guard accuracy > 1 else { return false }
        let accuracySq = accuracy * accuracy
        for (p1, p2) in edges {
            guard max(p1.x, p2.x) >= p.x - accuracy, min(p1.x, p2.x) <= p.x + accuracy,
                  max(p1.y, p2.y) >= p.y - accuracy, min(p1.y, p2.y) <= p.y + accuracy else { continue }
            if Seg(p1, p2).squaredDistance(p) <= accuracySq { return true }
        }
        return false
    }

    /// The second pass of conditional flashing, by the fills as made: a via or pad flashed on a layer where the
    /// highest priority zone of its net was over it, but which no fill of its net there reaches (to within its hole's
    /// or its copper's radius, whichever is the greater), not to be joined to a zone there after all
    /// (zoneReachesPoint)
    func reevaluateConditionalFlashing() {
        var filled: [[Int]: [(IBox, PolySet)]] = [:]
        for z in boardZones where !z.ruleArea {
            for l in z.layers {
                guard let fill = z.fills[l], fill.outlineCount > 0 else { continue }
                filled[[z.net, l], default: []].append((z.bbox, fill))
            }
        }
        func reaches(_ net: Int, _ l: Int, _ center: IPoint, _ radius: Int) -> Bool {
            for (box, fill) in filled[[net, l]] ?? [] {
                if !box.inflated(radius).contains(center) { continue }
                if Self.containmentIndexContains(fill, center, radius) { return true }
            }
            return false
        }
        for t in copper.tracks where t.kind == .via {
            guard let v = t.via else { continue }
            let holeRadius = v.drill / 2
            for rl in t.layers where t.zoneLayerOverrides[rl] == .forceFlashed {
                if !reaches(t.net, drc.kiLayer(rl), v.start, max(holeRadius, v.diameter / 2)) { t.zoneLayerOverrides[rl] = .forceNoZoneConnection }
            }
        }
        for pads in copper.footprintPads {
            for item in pads {
                guard let p = item.pad else { continue }
                let holeRadius = p.hasHole ? min(p.pad.drill.x, p.pad.drill.y) / 2 : 0
                let reach = max(holeRadius, min(p.pad.size.x, p.pad.size.y) / 2)
                for rl in world.copper(p.pad.layers) where item.zoneLayerOverrides[rl] == .forceFlashed {
                    if !reaches(item.net, drc.kiLayer(rl), p.pad.pos, reach) { item.zoneLayerOverrides[rl] = .forceNoZoneConnection }
                }
            }
        }
        // the zone layer connections KiCad then writes: each plated pad's and via's that does not keep all its layers,
        // the copper layers it is flashed on whatever connects there, top to bottom
        zoneLayerConnections = [:]
        for t in copper.tracks where t.kind == .via && t.via?.unconnectedLayers != .keepAll {
            zoneLayerConnections[t.uuid] = (0..<world.copperLayers).filter { t.zoneLayerOverrides[$0] == .forceFlashed }.map(layerName)
        }
        for pads in copper.footprintPads {
            for item in pads where item.pad?.pad.attribute == .pth && item.pad?.unconnectedLayers != .keepAll {
                zoneLayerConnections[item.uuid] = (0..<world.copperLayers).filter { item.zoneLayerOverrides[$0] == .forceFlashed }.map(layerName)
            }
        }
    }

    /// A router layer's name
    func layerName(_ rl: Int) -> String { world.layerIndex.first { $0.value == rl }?.key ?? "" }

    // MARK: - Writing them

    /// A pad's or via's node with its zone layer connections as the filler found them, as KiCad writes them: after its
    /// unconnected layers' mode (a pad's keep_end_layers, a via's remove_unused_layers and the rest, locked and free)
    static func setZoneLayerConnections(_ node: SExpr, _ layers: [String]) {
        let list = SExpr(list: [SExpr(symbol: "zone_layer_connections")] + layers.map { SExpr(string: $0) })
        if let i = node.items.firstIndex(where: { $0.head == "zone_layer_connections" }) {
            node.items[i] = list
            return
        }
        let after: Set<String> = ["layers", "remove_unused_layers", "keep_end_layers", "start_end_only", "locked", "free"]
        let i = node.items.lastIndex { after.contains($0.head ?? "") } ?? (node.items.count - 1)
        node.items.insert(list, at: i + 1)
    }
}
