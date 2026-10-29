// Ported from KiCad 10.0.7: pcbnew/drc/drc_test_provider_zone_connections.cpp (thermal reliefs with too few spokes:
// starved thermals), with pcbnew/drc/drc_engine.cpp (EvalZoneConnection, and EvalRules of the minimum spoke count and
// the thermal relief gap, whose rule names the violation), pcbnew/connectivity/connectivity_algo.cpp (FillIsolatedIslandsMap:
// a fill's islands that touch one item only) and pcbnew/connectivity/connectivity_data.cpp (GetConnectedTracks,
// GetConnectedItems).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardDRC {
    /// ZONE_CONNECTION
    enum ZoneConnection: Int {
        case none = 0, thermal, full, thtThermal
    }

    /// The layer's name as the board gives it (BOARD::GetLayerName: its own name for it, else KiCad's)
    func boardLayerName(_ l: Int) -> String {
        let canonical = world.layerIndex.first { $0.value == l }?.key ?? ""
        for entry in board.root["layers"]?.arguments ?? [] where entry.text(at: 0) == canonical {
            if let user = entry.text(at: 2), !user.isEmpty { return user }
        }
        return canonical
    }

    // MARK: - The check (DRC_TEST_PROVIDER_ZONE_CONNECTIONS)

    func checkZoneConnections(_ out: inout Report, _ c: Copper, _ cn: Connectivity) {
        let fps = board.root.all("footprint")
        var zoneNodes: [String: SExpr] = [:]
        for z in board.root.all("zone") + fps.flatMap({ $0.all("zone") }) {
            if let u = z.value("uuid") { zoneNodes[u] = z }
        }
        /// ARC_LOW_DEF: the pads' outlines made to within 0.02 mm
        let arcLowDef = 20000
        for zone in c.zones {
            guard let node = zoneNodes[zone.uuid], node["attr"]?["teardrop"] == nil else { continue }
            for l in zone.layers {
                guard !out.exceeded("starved_thermal") else { return }
                testZoneLayer(&out, c, cn, zone, node, l, fps, arcLowDef)
            }
        }
    }

    /// The fill's islands (their indices) in a cluster with a pad that touch one item only (m_SingleConnectionOutlines;
    /// none for a footprint's zone, which the map has no entry for)
    func singleConnectionOutlines(_ cn: Connectivity, _ zone: CopperItem, _ l: Int) -> [Int] {
        guard zone.footprint == nil, !(zone.fills[l] ?? []).isEmpty else { return [] }
        var out: [Int] = []
        for cluster in cn.clusters where !cluster.isOrphaned {
            for item in cluster.items where item.parent === zone && item.zoneLayer == l && item.connected.count == 1 {
                out.append(item.subpoly)
            }
        }
        return out
    }

    func testZoneLayer(_ out: inout Report, _ c: Copper, _ cn: Connectivity, _ zone: CopperItem, _ zoneNode: SExpr, _ l: Int,
                       _ fps: [SExpr], _ arcLowDef: Int) {
        let fill = zone.fills[l] ?? []
        let fillSet = PolySet(fill.map { [$0] })
        let singles = singleConnectionOutlines(cn, zone, l)
        let layerName = boardLayerName(l)
        let engine = ruleState.engine
        let zoneRule = ruleItem(zone, c), layer = kiLayer(l)

        for (f, pads) in c.footprintPads.enumerated() {
            let nodes = fps[f].all("pad")
            for (j, pad) in pads.enumerated() {
                guard !out.exceeded("starved_thermal") else { return }
                guard let p = pad.pad, pad.net == zone.net, pad.net > 0 else { continue }
                guard let zbox = zone.zoneBox, boundingBox(p).intersects(zbox), pad.flashed.contains(l) else { continue }
                let padNode = nodes[j]
                let padRule = ruleItem(pad, c)

                // EvalZoneConnection: the pad's own, its footprint's, the zone's (or a rule's)
                guard engine.evalZoneConnection(padRule, zoneRule, layer: layer).zoneConnection == .thermal else { continue }

                let spokesConstraint = engine.evalRules(.minResolvedSpokes, padRule, zoneRule, layer: layer)
                let minCount = spokesConstraint.value.min
                guard settings.severity("starved_thermal") != "ignore", spokesConstraint.severity != .ignore, minCount > 0 else { continue }

                // the thermal relief gap: the pad's own, else the zone's (or a rule's); its constraint names what the
                // violation is of
                let constraint = engine.evalRules(.thermalReliefGap, padRule, zoneRule, layer: layer)
                let gapSource = constraint.ruleName
                let midGap = constraint.value.min / 2

                guard let padPoly = world.padPolygon(p.pad, primitives: p.primitives, errorLocation: .outside,
                                                     clearance: midGap, arcError: arcLowDef),
                      let padOutline = padPoly.polygons.first?.first else { continue }
                var spokes = 0, ignoredSpokes = 0
                for (jj, outline) in fill.enumerated() {
                    var unique: [IPoint] = []
                    for i in outline.intersect(padOutline, excludeColinearAndTouching: true) where !unique.contains(i.p) {
                        unique.append(i.p)
                    }
                    // (spokes to an island that touches the pad only connect it to nothing)
                    guard unique.count >= 2 else { continue }
                    if singles.contains(jj) {
                        ignoredSpokes += unique.count / 2
                    } else {
                        spokes += unique.count / 2
                    }
                }
                if spokes == 0 && ignoredSpokes == 0 { continue }

                var customSpokes = 0
                if p.pad.kind == .custom {
                    customSpokes = (padNode["primitives"]?.arguments ?? []).filter { $0.head == "gr_vector" }.count
                }
                func report(_ detail: String) { out.add("starved_thermal", detail, [zone.uuid, pad.uuid], rule: constraint.parentRule) }
                if customSpokes > 0 {
                    if spokes < customSpokes {
                        report(ignoredSpokes > 0 ? "(layer \(layerName); \(ignoredSpokes) spokes connected to isolated island)"
                               : "(layer \(layerName); \(gapSource) custom spoke count \(customSpokes); actual \(spokes))")
                    }
                    continue
                }
                if spokes >= minCount { continue }

                // spokes drawn by hand: tracks from inside the pad's relief out into the fill
                var tracks: [CopperItem] = []
                for it in cn.entries[ObjectIdentifier(pad)] ?? [] {
                    for n in it.connected where [.track, .arc, .via].contains(n.parent.kind) && !tracks.contains(where: { $0 === n.parent }) {
                        tracks.append(n.parent)
                    }
                }
                for t in tracks {
                    let (start, end) = t.kind == .via ? (t.via!.start, t.via!.start) : (t.trackStart, t.trackEnd)
                    if padOutline.pointInside(start) {
                        if Self.collides(fillSet, end) { spokes += 1 }
                    } else if padOutline.pointInside(end) {
                        if Self.collides(fillSet, start) { spokes += 1 }
                    }
                }
                // and drawings on the layer joined to the pad (the pad's cluster of its net, zones left out)
                for shape in connectedItems(cn, pad) where shape.kind == .shape && shape.layers.contains(l) {
                    let pts = shape.connectionPoints
                    for pt in pts where padOutline.pointInside(pt) {
                        for other in pts where other != pt && Self.collides(fillSet, other) {
                            spokes += 1
                            break
                        }
                        break
                    }
                }
                // (connected to isolated islands only: that is the connectivity check's to report)
                if spokes == 0 {
                    spokes += ignoredSpokes
                    ignoredSpokes = 0
                }
                if spokes < minCount {
                    report(ignoredSpokes > 0 ? "(layer \(layerName); \(ignoredSpokes) spokes connected to isolated island)"
                           : "(layer \(layerName); \(gapSource) min spoke count \(minCount); actual \(spokes))")
                }
            }
        }
    }

    /// CONNECTIVITY_DATA::GetConnectedItems( aItem, EXCLUDE_ZONES ): the items of the cluster of the item's net (zones
    /// left out) it is in
    func connectedItems(_ cn: Connectivity, _ item: CopperItem) -> [CopperItem] {
        guard item.net > 0, let roots = cn.entries[ObjectIdentifier(item)] else { return [] }
        var visited = Set<ObjectIdentifier>()
        var queue: [CNItem] = []
        for r in roots where visited.insert(ObjectIdentifier(r)).inserted { queue.append(r) }
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            for n in current.connected where n.net == item.net && !n.isZone && visited.insert(ObjectIdentifier(n)).inserted {
                queue.append(n)
            }
        }
        return queue.map(\.parent)
    }
}
