// Ported from KiCad 10.0.8: pcbnew/drc/drc_test_provider_footprint_checks.cpp (a net tie footprint's copper shorting
// pads its net tie pad groups do not let it short) and pcbnew/footprint.cpp (FOOTPRINT::IsNetTie, CheckNetTies).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardDRC {
    /// DRC_TEST_PROVIDER_FOOTPRINT_CHECKS' net ties: for each net tie footprint, on F.Cu, In1.Cu and B.Cu, its copper
    /// drawings made one polygon set, and each of its outlines that meets more than one of the footprint's pads is a
    /// short where those pads are not all of one group (FOOTPRINT::CheckNetTies), named by the drawing at the point of
    /// the outline nearest between the two pads, and the first of them; or by the two pads where no drawing is there
    func checkNetTies(_ out: inout Report, _ c: Copper) {
        for f in board.root.all("footprint").indices {
            // (FOOTPRINT::IsNetTie: a group that is not empty)
            guard c.isNetTie(f), !out.exceeded("shorting_items") else { continue }
            // (the report names the first two of its items)
            for short in netTieShorts(f, c) { out.add("shorting_items", nil, Array(short.items.prefix(2))) }
        }
    }

    /// FOOTPRINT::CheckNetTies of the board's footprint `f`: each short, its items as KiCad names them (the drawing
    /// there, then the two pads; or the two pads) and where
    func netTieShorts(_ f: Int, _ c: Copper) -> [(items: [String], at: IPoint)] {
        var shorts: [(items: [String], at: IPoint)] = []
        let maxError = settings.maxError
        let fp = board.root.all("footprint")[f]
        let placement = BoardWorld.FootprintPlacement(fp)
        // the footprint's items on copper, in the order it keeps them: its drawings, its zones, its fields
        var drawings: [(node: SExpr, layer: String)] = []
        for node in fp.items {
            let head = node.head ?? ""
            guard let layer = BoardWorld.itemLayer(node), world.layerIndex[layer] != nil else { continue }
            if BoardWorld.footprintShapeHeads.contains(head) {
                drawings.append((node, layer))
            } else if head == "fp_text" || head == "fp_text_box" || head == "property" || head == "zone" {
                // (a text's or a zone's copper among a net tie's: not made here)
                ruleState.board.unsupported.insert("a net tie footprint's \(head) on copper")
            }
        }
        // (the drawings as HitTest tries them: every one on copper, whatever its layer)
        let placed = drawings.map { (drawing: world.readDrawing($0.node, placement: placement), uuid: $0.node.value("uuid") ?? "") }
        for layerName in ["F.Cu", "In1.Cu", "B.Cu"] {
            guard let l = world.layerIndex[layerName] else { continue }
            // the copper of the layer, all its drawings' polygons made one (net or no net)
            var copperOutlines = PolySet()
            for d in drawings where d.layer == layerName {
                guard let poly = drawingPolygon(d.node, placement: placement, maxError: maxError, errorLocation: .outside) else {
                    ruleState.board.unsupported.insert("a net tie footprint's drawing the port does not make")
                    continue
                }
                // (TransformShapeToPolygon appends, the one Simplify after unites them all at once)
                copperOutlines.append(poly)
            }
            copperOutlines.simplify()
            guard copperOutlines.outlineCount > 0 else { continue }
            // each pad by the outlines it meets
            var padsOfOutline: [Int: [CopperItem]] = [:]
            for pad in c.footprintPads[f] {
                let shapes = pad.anyLayerShapes(l)
                for ii in 0..<copperOutlines.outlineCount {
                    let outline = Shape.simple(copperOutlines.polygons[ii][0])
                    if shapes.contains(where: { $0.collide(outline, clearance: 0) }) {
                        padsOfOutline[ii, default: []].append(pad)
                    }
                }
            }
            for ii in padsOfOutline.keys.sorted() {
                let pads = padsOfOutline[ii]!
                guard pads.count > 1 else { continue }
                let first = pads[0]
                let firstGroup = c.netTieGroup(first)
                for this in pads.dropFirst() {
                    let group = c.netTieGroup(this)
                    guard group < 0 || group != firstGroup else { continue }
                    let a = first.pad?.pad.pos ?? first.position, b = this.pad?.pad.pos ?? this.position
                    // (VECTOR2I / 2: rounded, as VECTOR2::operator/( double ) rounds)
                    let mid = (a + b).divided(by: 2)
                    let pos = copperOutlines.polygons[ii][0].nearestPoint(mid)
                    if let hit = placed.first(where: { $0.drawing.map { Self.hitTest($0, pos, 1) } ?? false }) {
                        shorts.append(([hit.uuid, first.uuid, this.uuid], pos))
                    } else {
                        shorts.append(([first.uuid, this.uuid], pos))
                    }
                }
            }
        }
        return shorts
    }
}
