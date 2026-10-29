// A via placed on its own as KiCad's Add Vias tool places one (pcbnew/tools/drawing_tool.cpp, DRAWING_TOOL::DrawVia's
// VIA_PLACER, KiCad 10.0.7): snapped onto the track, pad or drawing under the pointer, given the net of what it is put
// on, refused where the board's design rules keep it off other nets' copper or holes or out of a rule area, and
// splitting the track it is put on. GNU General Public License version 3 or later, as the DRC (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardDRC {
    /// VIA_PLACER::findTrack: the track (or arc) on the via's layers within half its width and the via's of `p`,
    /// the one whose line (its ends' chord, for an arc) is nearest
    func viaPlacerTrack(_ c: Copper, at p: IPoint, viaWidth: Int) -> CopperItem? {
        var best: CopperItem?, minD = Int.max
        for t in c.tracks where t.kind == .track || t.kind == .arc {
            guard let l = t.layers.first else { continue }
            let hit: Bool
            if t.kind == .track {
                // (TestSegmentHit, within half the track's and the via's widths)
                let d = (t.trackWidth + viaWidth) / 2
                hit = Seg(t.trackStart, t.trackEnd).squaredDistance(p) <= d * d
            } else {
                // (PCB_ARC::HitTest, within half the via's width of the arc as wide as it is)
                hit = Self.collide(t.shapes[l] ?? [], [.circle(center: p, radius: 0)], viaWidth / 2) != nil
            }
            guard hit else { continue }
            let d = (Seg(t.trackStart, t.trackEnd).nearestPoint(p) - p).norm
            if d < minD {
                minD = d
                best = t
            }
        }
        return best
    }

    /// VIA_PLACER::findPad: the pad `p` is on (PAD::HitTest, on any of its layers)
    func viaPlacerPad(_ c: Copper, at p: IPoint) -> CopperItem? {
        for pads in c.footprintPads {
            for pad in pads where pad.layers.contains(where: { Self.collide(pad.shapes[$0] ?? [], [.circle(center: p, radius: 0)], 0) != nil }) {
                return pad
            }
        }
        return nil
    }

    /// VIA_PLACER::findGraphic: the drawing on copper within half the via's width of `p` whose position is nearest
    func viaPlacerGraphic(_ c: Copper, at p: IPoint, viaWidth: Int) -> CopperItem? {
        var best: CopperItem?, minD = Int.max
        for d in c.drawings + c.footprintDrawings.flatMap({ $0 }) {
            guard let l = d.layers.first, Self.collide(d.shapes[l] ?? [], [.circle(center: p, radius: 0)], viaWidth / 2) != nil else { continue }
            let dist = (d.position - p).norm
            if dist < minD {
                minD = dist
                best = d
            }
        }
        return best
    }

    /// VIA_PLACER::findStitchedZoneNet: the nets of the copper zones whose fills `p` is in, on any copper layer
    func viaPlacerZoneNets(_ c: Copper, at p: IPoint) -> [String] {
        var nets: [String] = []
        for z in c.zones where z.layers.contains(where: { l in (z.fills[l] ?? []).contains { $0.pointInside(p, accuracy: 0) } }) {
            if !nets.contains(z.netName) { nets.append(z.netName) }
        }
        return nets
    }

    /// VIA_PLACER::checkDRCViolation: whether the via (its copper item, on the board as it would be with it) is
    /// nearer another net's copper or another item's hole than the design rules allow, or in a rule area keeping
    /// vias out (hasDRCViolation for each item: copper zones left out, which the via is to stitch; items of no net
    /// tried by their holes only, as such an item may take the via's net), or where the rules disallow it
    /// (EvalRules(DISALLOW_CONSTRAINT, via, nullptr, UNDEFINED_LAYER), its severity not ignore)
    func viaPlacerViolates(_ via: CopperItem, _ c: Copper) -> Bool {
        ruleState.copper = c
        func subE(_ v: Int) -> Int { max(0, v - settings.epsilon) }
        let viaWidth = (via.via?.diameter ?? 0)
        for other in c.items where other !== via {
            if other.net != 0 && other.net == via.net { continue }
            if other.net != 0 {
                // (each copper layer of the other item's: EvalRules(CLEARANCE_CONSTRAINT, via, other, layer))
                for l in other.layers where via.layers.contains(l) {
                    let clearance = clearanceConstraint(via, other, l, c).value.min
                    if clearance >= 0, Self.collide(via.shapes[l] ?? [], other.shapes[l] ?? [], subE(clearance)) != nil { return true }
                }
            }
            if let hole = other.hole {
                // (EvalRules(HOLE_CLEARANCE_CONSTRAINT, via, other, UNDEFINED_LAYER))
                let clearance = ruleState.engine.evalRules(.holeClearance, ruleItem(via, c), ruleItem(other, c),
                                                           layer: KiLayer.undefined).value.min
                if clearance >= 0, Self.collide([.circle(center: via.via?.start ?? .zero, radius: viaWidth / 2)], [hole], subE(clearance)) != nil {
                    return true
                }
            }
        }
        // the rule areas keeping vias out, the via's centre in one or nearer it than half the via's width
        let r = viaWidth / 2
        for area in keepouts() where area.vias {
            let d = Self.squaredDistance(area.outline, via.via?.start ?? .zero)
            if d == 0 || d < r * r { return true }
        }
        let k = ruleState.engine.evalRules(.disallow, ruleItem(via, c), nil, layer: KiLayer.undefined)
        return !k.disallowFlags.isEmpty && k.severity != .ignore
    }
}

extension BoardEditing {
    /// What placing a via on its own came to
    public enum ViaPlacement {
        /// Placed: the change (the track it was put on split there, as KiCad splits it), and whether it violates the
        /// design rules (placed so only where they may be: `allowViolations`)
        case placed(Edit, violatesDRC: Bool)
        /// Where KiCad's Add Vias refuses it: "Via location violates DRC."
        case violatesDRC
        /// The point is in the fills of zones of several nets: KiCad asks which ("Select Net:"); `placeVia` again
        /// with one of them
        case ambiguous([String])
    }

    /// A via placed on its own with the pointer at `p` (mm), as KiCad's Add Vias places one (VIA_PLACER): through
    /// every copper layer, at the pre-defined via size chosen (sizeChoice), else the Default net class's via size and
    /// drill (BOARD_DESIGN_SETTINGS::GetCurrentViaSize);
    /// on the grid, or (`snap`) onto the track under the pointer (by the grid's lines across it), the pad's centre,
    /// or onto the drawing on copper there; of the net of the track, pad or drawing (of a net) it is then on, else of
    /// the zone whose fill it is in (`net` choosing between several), else of none; refused where it would be nearer
    /// other nets' copper or other items' holes than the design rules allow or is in a rule area keeping vias out; a
    /// track it is put on split there (with `snap`). One change. `allowViolations` places it where it violates them
    /// too (KiCad's router setting Allow DRC Violations), saying so.
    public func placeVia(at p: KiCadPoint, net chosen: String? = nil, snap: Bool = true, allowViolations: Bool = false) -> ViaPlacement {
        guard !isRouting else { return .violatesDRC }
        let board = router.board
        let drc = BoardDRC(board: board.copy(), project: project, designRules: designRules)
        let c = drc.makeCopper()
        let size = drc.netClasses.defaultClass
        let (viaWidth, viaDrill) = currentViaSize(default: size.viaDiameter ?? 600_000, size.viaDrill ?? 300_000)
        let mouse = Self.nm(p)
        // SnapItem: the via (at the grid point) moved onto what is under the pointer
        var pos = snap ? router.align(mouse) : mouse
        if snap {
            if let track = drc.viaPlacerTrack(c, at: mouse, viaWidth: viaWidth) {
                pos = router.alignToSegment(mouse, Seg(track.trackStart, track.trackEnd))
            } else if let pad = drc.viaPlacerPad(c, at: mouse), let pp = pad.pad {
                pos = pp.pad.pos
            } else if let shape = drc.viaPlacerGraphic(c, at: mouse, viaWidth: viaWidth), let d = shape.drawing, !d.filled {
                // (a filled drawing, which the via may be meant to replace, not snapped to: KiCad goes by its area)
                switch d.kind {
                case .segment: pos = router.alignToSegment(mouse, Seg(d.start, d.end))
                case .arc: pos = (d.end - mouse).squaredNorm < (d.start - mouse).squaredNorm ? d.end : d.start
                case .poly:
                    let pts = d.poly
                    var nearest: Seg?, minDist = Int.max
                    for (a, b) in zip(pts, pts.dropFirst() + pts.prefix(1)) where pts.count > 1 {
                        let dist = Seg(a, b).distance(mouse)
                        if dist < minDist {
                            minDist = dist
                            nearest = Seg(a, b)
                        }
                    }
                    if let nearest { pos = router.alignToSegment(mouse, nearest) }
                default: pos = shape.position
                }
            }
        }
        // PlaceItem: its net, from what it is on
        let track = drc.viaPlacerTrack(c, at: pos, viaWidth: viaWidth)
        let pad = drc.viaPlacerPad(c, at: pos)
        let shape = drc.viaPlacerGraphic(c, at: pos, viaWidth: viaWidth)
        var netName = "", free = false
        if let track {
            netName = track.netName
        } else if let pad {
            netName = pad.netName
        } else if let shape, shape.net > 0 {
            netName = shape.netName
        } else {
            let nets = drc.viaPlacerZoneNets(c, at: pos)
            if nets.count > 1 {
                guard let chosen, nets.contains(chosen) else { return .ambiguous(nets) }
                netName = chosen
            } else {
                netName = nets.first ?? ""
            }
            free = !netName.isEmpty
        }
        // the via, on the board as it would be, checked
        let uuid = KiCadBoard.newUUID()
        var items: [SExprConvertible] = [SExpr("at", Double(pos.x) / 1e6, Double(pos.y) / 1e6), SExpr("size", Double(viaWidth) / 1e6),
                                         SExpr("drill", Double(viaDrill) / 1e6), SExpr("layers", "F.Cu", "B.Cu")]
        if free { items.append(SExpr("free", Keyword("yes"))) }
        items += [board.netList(netName, pad: false), SExpr("uuid", uuid)]
        let node = SExpr("via", items)
        let trial = board.copy()
        trial.addCopper(node.copy())
        let checking = BoardDRC(board: trial, project: project, designRules: designRules)
        let tc = checking.makeCopper()
        guard let item = tc.tracks.first(where: { $0.uuid == uuid }) else { return .violatesDRC }
        let violates = checking.viaPlacerViolates(item, tc)
        if violates && !allowViolations { return .violatesDRC }
        // placed, and the track it is put on split there
        router.board.addCopper(node)
        var changed = [uuid]
        if let track, snap, track.kind == .track, pos != track.trackStart, pos != track.trackEnd,
           Seg(track.trackStart, track.trackEnd).squaredDistance(pos) <= 3,
           let old = router.board.copperItems.first(where: { $0.value("uuid") == track.uuid }) {
            let second = old.copy()
            old.set(SExpr("end", Double(pos.x) / 1e6, Double(pos.y) / 1e6), after: ["start"])
            second.set(SExpr("start", Double(pos.x) / 1e6, Double(pos.y) / 1e6))
            let half = KiCadBoard.newUUID()
            second.set(SExpr("uuid", half))
            router.board.addCopper(second)
            changed += [track.uuid, half]
        }
        router.boardChanged()
        guard let edit = change("Add Via", changed: changed) else { return .violatesDRC }
        return .placed(edit, violatesDRC: violates)
    }
}
