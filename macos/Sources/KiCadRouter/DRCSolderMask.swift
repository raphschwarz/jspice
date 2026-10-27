// Ported from KiCad 10.0.7: pcbnew/drc/drc_test_provider_solder_mask.cpp (solder mask apertures bridging items of
// different nets: each aperture against the others on its mask layer, each copper item against the apertures over it,
// each aperture against the copper zones under it, and apertures with no copper of their own (mask drawings, free pads)
// bridging by the nets they expose), pcbnew/pad.cpp (GetSolderMaskExpansion, IsNPTHWithNoCopper, IsFreePad,
// SameLogicalPadAs, SharesNetTieGroup), pcbnew/pcb_track.cpp (a via's tenting and mask layers, its and a track's mask
// expansion), pcbnew/pcb_shape.cpp (a drawing's mask expansion and mask layers) and
// pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp (how these are read).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardDRC {
    /// An item the solder mask check tests: a track, arc, via, pad or drawing on a copper or mask layer of the board's
    /// outsides
    final class MaskItem {
        enum Kind { case track, arc, via, pad, shape }
        let kind: Kind
        let uuid: String
        var footprint: Int?
        /// Its net code, -1 for an item not connected (a footprint's drawing)
        var net = -1
        var layers: Set<String> = []
        /// Its shape on a copper layer and on a mask layer (GetEffectiveShape)
        var copperShapes: [String: [Shape]] = [:]
        var maskShapes: [Shape] = []
        /// Its mask expansion on the front and on the back (a pad's, a via's not tented, a drawing's; 0 else)
        var expansion: (front: Int, back: Int) = (0, 0)
        var tentedFront = true, tentedBack = true
        var bbox = IBox(minX: 0, minY: 0, maxX: 0, maxY: 0)
        // a pad's
        var number = ""
        var npthWithNoCopper = false
        var freePad = false
        var copperItem: CopperItem?

        init(kind: Kind, uuid: String) { (self.kind, self.uuid) = (kind, uuid) }

        func isOnLayer(_ l: String) -> Bool { layers.contains(l) }

        /// isMaskAperture: a free pad, or an item on a mask layer with no copper
        func isMaskAperture(_ copperNames: Set<String>) -> Bool {
            if freePad { return true }
            return (isOnLayer("F.Mask") || isOnLayer("B.Mask")) && layers.isDisjoint(with: copperNames)
        }

        func expansion(front: Bool) -> Int { front ? expansion.front : expansion.back }
    }

    /// parseFrontBackOptBool: (front yes) (back no), or the legacy (tenting front back)
    static func frontBack(_ node: SExpr?) -> (front: Bool?, back: Bool?) {
        guard let node else { return (nil, nil) }
        var front: Bool?, back: Bool?
        for arg in node.arguments {
            switch (arg.head, arg.text) {
            case ("front", _): front = arg.text(at: 0).map { $0 == "yes" }
            case ("back", _): back = arg.text(at: 0).map { $0 == "yes" }
            case (nil, "front"): front = true
            case (nil, "back"): back = true
            case (nil, "none"): (front, back) = (nil, nil)
            default: break
            }
        }
        return (front, back)
    }

    /// The items the check tests, in the order forEachGeometryItem gathers them (texts left out)
    func maskItems(_ c: Copper) -> [MaskItem] {
        let setup = board.root["setup"]
        let boardMargin = setup?["pad_to_mask_clearance"].map { BoardWorld.iu($0, 0) } ?? 0
        let tenting = Self.frontBack(setup?["tenting"])
        let (tentFront, tentBack) = (tenting.front ?? false, tenting.back ?? false)
        let copperNames = Set(world.layerIndex.keys)
        let names = Dictionary(uniqueKeysWithValues: world.layerIndex.map { ($0.value, $0.key) })
        let byUUID = Dictionary(c.items.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let relevant: Set<String> = ["F.Mask", "B.Mask", "F.Cu", "B.Cu"]
        var out: [MaskItem] = []
        func finish(_ m: MaskItem) {
            var box: IBox?
            for s in m.maskShapes + m.copperShapes.values.flatMap({ $0 }) { if box == nil { box = s.bbox } else { box!.merge(s.bbox) } }
            if let box { m.bbox = box }
            out.append(m)
        }
        var trackNodes: [String: SExpr] = [:]
        for node in board.root.items where ["segment", "arc", "via"].contains(node.head ?? "") {
            if let u = node.value("uuid") { trackNodes[u] = node }
        }
        // tracks, arcs and vias
        for t in tracks {
            guard let item = byUUID[t.uuid] else { continue }
            let node = trackNodes[t.uuid]
            let m = MaskItem(kind: t.kind == .via ? .via : t.kind == .arc ? .arc : .track, uuid: t.uuid)
            m.net = item.netCode
            m.copperItem = item
            if t.kind == .via {
                let tent = Self.frontBack(node?["tenting"])
                m.tentedFront = tent.front ?? tentFront
                m.tentedBack = tent.back ?? tentBack
                let ls = item.layers.compactMap { names[$0] }
                m.layers = Set(ls)
                let spansFront = t.layers.start == 0, spansBack = t.layers.end == world.copperLayers - 1
                if !m.tentedFront && spansFront { m.layers.insert("F.Mask") }
                if !m.tentedBack && spansBack { m.layers.insert("B.Mask") }
                for l in item.layers { if let n = names[l] { m.copperShapes[n] = item.shapes[l] } }
                m.maskShapes = [.circle(center: t.start, radius: t.diameter / 2)]
                m.expansion = (m.tentedFront ? 0 : boardMargin, m.tentedBack ? 0 : boardMargin)
            } else {
                guard let l = item.layers.first, let n = names[l] else { continue }
                m.layers = [n]
                let maskLayers = node?["layers"]?.arguments.map(\.text) ?? []
                if n == "F.Cu" && maskLayers.contains("F.Mask") { m.layers.insert("F.Mask") }
                if n == "B.Cu" && maskLayers.contains("B.Mask") { m.layers.insert("B.Mask") }
                m.copperShapes[n] = item.shapes[l]
                m.maskShapes = item.shapes[l] ?? []
            }
            guard !m.layers.isDisjoint(with: relevant) else { continue }
            finish(m)
        }
        /// A drawing: on a copper layer (its copper item), or on a mask layer; a copper one with a mask too where its
        /// layers say so
        func drawing(_ node: SExpr, placement: BoardWorld.FootprintPlacement?, footprint: Int?) {
            let layerNames = node["layers"]?.arguments.map(\.text) ?? node.value("layer").map { [$0] } ?? []
            guard let first = layerNames.first, let d = world.readDrawing(node, placement: placement),
                  let shapes = world.effectiveShapes(d), !shapes.isEmpty else { return }
            let m = MaskItem(kind: .shape, uuid: node.value("uuid") ?? "")
            m.footprint = footprint
            m.layers = Set(layerNames)
            if copperNames.contains(first) {
                let item = byUUID[m.uuid]
                m.copperItem = item
                m.net = item?.netCode ?? 0
                if footprint != nil { m.net = -1 }
                m.copperShapes[first] = shapes
            } else {
                m.net = footprint == nil ? 0 : -1
            }
            guard !m.layers.isDisjoint(with: relevant) else { return }
            m.maskShapes = shapes
            var margin = node["solder_mask_margin"].map { BoardWorld.iu($0, 0) } ?? boardMargin
            if margin < 0 && !d.filled { margin = max(margin, -d.width / 2) }
            m.expansion = (margin, margin)
            finish(m)
        }
        for node in board.root.items where ["gr_line", "gr_rect", "gr_arc", "gr_circle", "gr_poly", "gr_curve"].contains(node.head ?? "") {
            drawing(node, placement: nil, footprint: nil)
        }
        for (i, fp) in board.root.all("footprint").enumerated() {
            let placement = BoardWorld.FootprintPlacement(fp)
            let fpMargin = fp["solder_mask_margin"].map { BoardWorld.iu($0, 0) }
            for (j, node) in fp.all("pad").enumerated() {
                let p = footprints[i].pads[j]
                let item = c.footprintPads[i][j]
                let m = MaskItem(kind: .pad, uuid: p.uuid)
                m.footprint = i
                m.copperItem = item
                m.net = item.netCode
                m.layers = layerSet(node)
                m.number = p.number
                m.freePad = p.net.hasPrefix("unconnected-(") && p.pinType == "free"
                // (IsNPTHWithNoCopper: an unplated pad no bigger than its hole)
                if p.pad.attribute == .npth {
                    switch p.pad.kind {
                    case .circle: m.npthWithNoCopper = !(p.pad.size.x > p.pad.drill.x)
                    case .oval: m.npthWithNoCopper = !(p.pad.size.x > p.pad.drill.x || p.pad.size.y > p.pad.drill.y)
                    default: m.npthWithNoCopper = false
                    }
                }
                guard p.hasHole || !m.layers.isDisjoint(with: relevant) else { continue }
                for l in item.layers { if let n = names[l] { m.copperShapes[n] = item.shapes[l] } }
                m.maskShapes = item.outline
                // GetSolderMaskExpansion: none for a pad on no copper; the pad's, its footprint's or the board's,
                // no less than half its size's lesser side taken off
                if !m.layers.isDisjoint(with: copperNames) {
                    var margin = node["solder_mask_margin"].map { BoardWorld.iu($0, 0) } ?? fpMargin ?? boardMargin
                    if margin < 0 {
                        let minsize = -min(p.pad.size.x, p.pad.size.y) / 2
                        if margin < minsize { margin = minsize }
                    }
                    m.expansion = (margin, margin)
                }
                finish(m)
            }
            for node in fp.items where ["fp_line", "fp_rect", "fp_arc", "fp_circle", "fp_poly", "fp_curve"].contains(node.head ?? "") {
                drawing(node, placement: placement, footprint: i)
            }
        }
        return out
    }

    // MARK: - The check (DRC_TEST_PROVIDER_SOLDER_MASK's testMaskBridges)

    func checkSolderMask(_ out: inout Report, _ c: Copper) {
        let type = "solder_mask_bridge"
        guard settings.severity(type) != "ignore" else { return }
        let items = maskItems(c)
        let setup = board.root["setup"]
        let webWidth = setup?["solder_mask_min_width"].map { BoardWorld.iu($0, 0) } ?? 0
        let maskToCopper = settings.solderMaskToCopperClearance
        let allowInFootprints = setup?.value("allow_soldermask_bridges_in_footprints") == "yes"
        let copperNames = Set(world.layerIndex.keys)
        let fps = board.root.all("footprint")
        let allowBridges = fps.map { ($0["attr"]?.arguments.map(\.text) ?? []).contains("allow_soldermask_bridges") }
        let onMask = (front: items.filter { $0.isOnLayer("F.Mask") }, back: items.filter { $0.isOnLayer("B.Mask") })
        var checkedPairs: [Set<String>: Set<String>] = [:]
        var apertureNets: [String: (item: MaskItem, net: Int)] = [:]
        var apertureAll: [String: [(item: MaskItem, net: Int)]] = [:]
        var pending: [(aperture: MaskItem, colliding: MaskItem, net: Int, front: Bool)] = []

        func netTies(_ m: MaskItem) -> Set<Int> { m.copperItem.flatMap { c.netTies[ObjectIdentifier($0)] } ?? [] }
        func netTieGroup(_ m: MaskItem) -> Int {
            guard let f = m.footprint, m.kind == .pad else { return -1 }
            return c.netTieGroups[f][m.number] ?? -1
        }
        func sharesNetTieGroup(_ a: MaskItem, _ b: MaskItem) -> Bool {
            guard let f = a.footprint, c.isNetTie(f), b.footprint == f else { return false }
            let g = netTieGroup(a)
            return g >= 0 && g == netTieGroup(b)
        }
        func sameLogicalPad(_ a: MaskItem, _ b: MaskItem) -> Bool { a.footprint == b.footprint && !a.number.isEmpty && a.number == b.number }

        /// checkMaskAperture: whether the aperture now exposes a second net, the first it exposed found
        func checkMaskAperture(_ mask: MaskItem, _ test: MaskItem, testLayer: String, _ testNet: Int) -> MaskItem? {
            if testLayer == "F.Mask" && !test.isOnLayer("F.Cu") { return nil }
            if testLayer == "B.Mask" && !test.isOnLayer("B.Cu") { return nil }
            let front = testLayer.hasPrefix("F.")
            if let f = mask.footprint, allowBridges[f] { return nil }
            let key = mask.uuid + (front ? " F" : " B")
            guard let first = apertureNets[key] else {
                apertureNets[key] = (test, testNet)
                apertureAll[key, default: []].append((test, testNet))
                return nil
            }
            apertureAll[key, default: []].append((test, testNet))
            if first.net == testNet || testNet <= 0 { return nil }
            if first.net <= 0 {
                apertureNets[key] = (test, testNet)
                return nil
            }
            if let f = mask.footprint, test.footprint == f {
                let groups = c.netTieGroups[f]
                let padA = first.item.kind == .pad ? first.item : nil, padB = test.kind == .pad ? test : nil
                if let padA, let padB, sameLogicalPad(padA, padB) || sharesNetTieGroup(padA, padB) { return nil }
                if let padA, test.kind == .shape, groups[padA.number] != nil { return nil }
                if let padB, first.item.kind == .shape, groups[padB.number] != nil { return nil }
            }
            return first.item
        }

        /// checkItemMask
        func checkItemMask(_ m: MaskItem, _ testNet: Int) -> Bool {
            guard let f = m.footprint else { return true }
            if allowBridges[f] { return false }
            if m.kind == .pad && c.isNetTie(f) {
                let g = c.netTieGroups[f][m.number] ?? 0
                if g >= 0 {
                    if testNet < 0 || m.net == testNet { return false }
                    for other in c.footprintPads[f] where other.uuid != m.uuid {
                        if (c.netTieGroups[f][other.pad?.number ?? ""] ?? -1) == g && other.netCode == testNet { return false }
                    }
                }
            }
            return true
        }

        func message(front: Bool) -> String {
            front ? "Front solder mask aperture bridges items with different nets"
                  : "Rear solder mask aperture bridges items with different nets"
        }

        /// testItemAgainstItems: the item on `refLayer` against the apertures on `target`
        func testAgainstItems(_ item: MaskItem, refLayer: String, target: String) {
            let front = target == "F.Mask"
            let itemShapes = refLayer.hasSuffix("Mask") ? item.maskShapes : item.copperShapes[refLayer] ?? []
            for other in front ? onMask.front : onMask.back where other !== item {
                guard !out.exceeded(type) else { return }
                // (the filter)
                if other.net > 0 && other.net == item.net { continue }
                if other.npthWithNoCopper { continue }
                if let f = item.footprint, f == other.footprint, allowInFootprints || allowBridges[f] { continue }
                if item.kind == .pad && other.kind == .pad && (sameLogicalPad(item, other) || sharesNetTieGroup(item, other)) { continue }
                if let f = item.footprint, c.isNetTie(f), other.net < 0 || netTies(item).contains(other.net) { continue }
                if let f = other.footprint, c.isNetTie(f), item.net < 0 || netTies(other).contains(item.net) { continue }
                var clearance = refLayer.hasSuffix("Mask") ? webWidth : maskToCopper
                if item.kind == .pad || item.kind == .shape || (item.kind == .via && !(front ? item.tentedFront : item.tentedBack)) {
                    clearance += item.expansion(front: front)
                }
                if other.kind == .pad || other.kind == .shape || (other.kind == .via && !(front ? other.tentedFront : other.tentedBack)) {
                    clearance += other.expansion(front: front)
                }
                // (each pair once on each layer; boxes too far apart for any clearance asked are not met)
                guard item.bbox.inflated(max(clearance, 0)).intersects(other.bbox) else { continue }
                let pairKey: Set<String> = [item.uuid, other.uuid]
                if checkedPairs[pairKey]?.contains(target) == true { continue }
                checkedPairs[pairKey, default: []].insert(target)
                guard Self.collide(itemShapes, other.maskShapes, clearance) != nil else { continue }
                // (KiCad's threads try a pair one way round or the other, whichever meets it first: where the other
                // way would find otherwise, or an aperture takes the first net it meets, its finding is unsure)
                if item.isMaskAperture(copperNames) {
                    out.unsure.append([item.uuid])
                } else if other.isMaskAperture(copperNames) {
                    out.unsure.append([other.uuid])
                } else if item.isOnLayer(target) && checkItemMask(other, item.net) != checkItemMask(item, other.net) {
                    out.unsure.append(pairKey)
                }
                if item.isMaskAperture(copperNames) {
                    if let colliding = checkMaskAperture(item, other, testLayer: refLayer, other.net) {
                        _ = colliding
                        pending.append((item, other, other.net, front))
                    }
                } else if other.isMaskAperture(copperNames) {
                    if checkMaskAperture(other, item, testLayer: refLayer, item.net) != nil {
                        pending.append((other, item, item.net, front))
                    }
                } else if checkItemMask(other, item.net) {
                    out.addMessage(type, message(front: front), [item.uuid, other.uuid])
                }
            }
        }

        /// testMaskItemAgainstZones: an aperture against the copper zones of other nets under it
        func testAgainstZones(_ item: MaskItem, mask: String, target: String) {
            let front = mask == "F.Mask"
            guard let l = world.layerIndex[target] else { return }
            for zone in c.zones where zone.layers.contains(l) {
                guard !out.exceeded(type) else { return }
                if item.net >= 0 && zone.net == item.net && zone.net > 0 { continue }
                var clearance = maskToCopper
                if item.kind == .pad || item.kind == .shape || (item.kind == .via && !(front ? item.tentedFront : item.tentedBack)) {
                    clearance += item.expansion(front: front)
                }
                guard let zb = zone.zoneBox, item.bbox.inflated(clearance).intersects(zb), let fill = zone.fills[l],
                      Self.collide(item.maskShapes, fill.map { Shape.simple($0) }, clearance) != nil else { continue }
                if item.isMaskAperture(copperNames) { out.unsure.append([item.uuid]) }
                if item.isMaskAperture(copperNames) && zone.net >= 0 {
                    let z = MaskItem(kind: .shape, uuid: zone.uuid)
                    z.net = zone.net
                    z.layers = [target]
                    if let colliding = checkMaskAperture(item, z, testLayer: target, zone.net) {
                        out.addMessage(type, message(front: front), [item.uuid, colliding.uuid, zone.uuid])
                    }
                } else {
                    out.addMessage(type, message(front: front), [item.uuid, zone.uuid])
                }
            }
        }

        for item in items {
            guard !out.exceeded(type) else { break }
            if item.isOnLayer("F.Mask") && !item.npthWithNoCopper {
                testAgainstItems(item, refLayer: "F.Mask", target: "F.Mask")
                testAgainstZones(item, mask: "F.Mask", target: "F.Cu")
            } else if item.isOnLayer("F.Cu") {
                testAgainstItems(item, refLayer: "F.Cu", target: "F.Mask")
            }
            if item.isOnLayer("B.Mask") && !item.npthWithNoCopper {
                testAgainstItems(item, refLayer: "B.Mask", target: "B.Mask")
                testAgainstZones(item, mask: "B.Mask", target: "B.Cu")
            } else if item.isOnLayer("B.Cu") {
                testAgainstItems(item, refLayer: "B.Cu", target: "B.Mask")
            }
        }

        // the apertures that bridge, each with the items of other nets it exposes
        var reported = Set<[String]>()
        for p in pending {
            guard !out.exceeded(type) else { break }
            let key = p.aperture.uuid + (p.front ? " F" : " B")
            var anyTrack = false
            for (first, net) in apertureAll[key] ?? [] where net != p.net && net > 0 {
                let triplet = [p.aperture.uuid, first.uuid, p.colliding.uuid]
                guard !reported.contains(triplet) else { continue }
                reported.insert(triplet)
                reported.insert([p.aperture.uuid, p.colliding.uuid, first.uuid])
                if first.kind == .track || first.kind == .arc {
                    if anyTrack { continue }
                    anyTrack = true
                }
                out.addMessage(type, message(front: p.front), triplet)
            }
        }
    }
}
