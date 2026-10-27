#!/usr/bin/env python3
"""Each copper layer's copper as KiCad's sliver check makes it, for checking the port's (KiCadRouter's
BoardDRC.copperLayerPolygons) against: through KiCad's pcbnew module, each item on the layer (in
DRC_TEST_PROVIDER::forEachGeometryItem's order: tracks, the board's drawings, its zones, then each footprint's fields,
pads (a pad with a hole on every layer), drawings and zones) made polygons by its TransformShapeToPolygon (no
clearance, ARC_LOW_DEF, the error inside), a zone by its fill, all united (SHAPE_POLY_SET::Simplify), written next to
the board as BOARD.copper (JSON): each layer's polygons by the layer's name, each its outline and holes, their points.

    copper.py BOARD.kicad_pcb...

With --draw, a board of copper of the kinds random boards do not have, saved, its zones filled, and then its copper
written as above (and drc.py run on it): texts on copper (the board's and footprints', turned, mirrored, several
lines), drawings of each kind (lines, arcs, circles and rings, rectangles filled, outlined and with round corners,
polygons filled with a line round them or outlined, curves), footprints' drawings turned off square, arc tracks,
through and blind vias on four layers, plated and unplated holes, a custom pad, a footprint's own zone, a rule area,
tracks of other nets at sharp angles in a zone, and filled polygons with spikes sharper and blunter than the sliver
check's limit.

    copper.py --draw OUT.kicad_pcb
"""

import json
import math
import os
import subprocess
import sys

import pcbnew

MM = 1_000_000
ARC_LOW_DEF = 20_000


def vec(x, y):
    return pcbnew.VECTOR2I(int(x), int(y))


def layer_poly(board, layer):
    poly = pcbnew.SHAPE_POLY_SET()

    def add(item):
        if isinstance(item, pcbnew.ZONE):
            if not item.GetIsRuleArea():
                fill = item.GetFill(layer)
                if fill is not None:
                    poly.Append(fill.CloneDropTriangulation())
        else:
            item.TransformShapeToPolygon(poly, layer, 0, ARC_LOW_DEF, pcbnew.ERROR_INSIDE)

    for t in board.GetTracks():
        if t.GetLayerSet().Contains(layer):
            add(t)
    for d in board.GetDrawings():
        if d.GetLayerSet().Contains(layer):
            add(d)
    for z in board.Zones():
        if z.GetLayerSet().Contains(layer):
            add(z)
    for fp in board.GetFootprints():
        for f in fp.GetFields():
            if f.GetLayerSet().Contains(layer):
                add(f)
        for p in fp.Pads():
            if p.HasHole() or p.GetLayerSet().Contains(layer):
                add(p)
        for g in fp.GraphicalItems():
            if g.GetLayerSet().Contains(layer):
                add(g)
        for z in fp.Zones():
            if z.GetLayerSet().Contains(layer):
                add(z)
    poly.Simplify()
    return poly


def write(path):
    board = pcbnew.LoadBoard(path)

    def pts(chain):
        return [[chain.CPoint(k).x, chain.CPoint(k).y] for k in range(chain.PointCount())]

    out = {}
    for layer in pcbnew.LSET.AllCuMask(board.GetCopperLayerCount()).Seq():
        p = layer_poly(board, layer)
        out[board.GetStandardLayerName(layer)] = [
            [pts(p.Outline(i))] + [pts(p.CHole(i, j)) for j in range(p.HoleCount(i))] for i in range(p.OutlineCount())]
    with open(os.path.splitext(path)[0] + ".copper", "w") as f:
        json.dump(out, f, separators=(",", ":"))
        f.write("\n")


def shape(board, kind, layer, width=200_000, filled=False, parent=None):
    s = pcbnew.PCB_SHAPE(parent or board, kind)
    s.SetLayer(layer)
    s.SetWidth(width)
    s.SetFilled(filled)
    return s


def text(parent, string, x, y, layer, angle=0, size=1.2, mirrored=False, thickness=0.18):
    t = pcbnew.PCB_TEXT(parent)
    t.SetText(string)
    t.SetLayer(layer)
    t.SetTextSize(vec(size * MM, size * MM))
    t.SetTextThickness(int(thickness * MM))
    t.SetPosition(vec(x, y))
    t.SetTextAngleDegrees(angle)
    t.SetMirrored(mirrored)
    return t


def draw(path):
    board = pcbnew.NewBoard(path)
    board.SetCopperLayerCount(4)
    x0, y0, x1, y1 = 100 * MM, 50 * MM, 160 * MM, 100 * MM
    edge = shape(board, pcbnew.SHAPE_T_RECTANGLE, pcbnew.Edge_Cuts, 100_000)
    edge.SetStart(vec(x0, y0))
    edge.SetEnd(vec(x1, y1))
    board.Add(edge)
    nets = {}
    for name in ["GND", "SIG", "SIG2"]:
        n = pcbnew.NETINFO_ITEM(board, name)
        board.Add(n)
        nets[name] = n
    F, B, In1 = pcbnew.F_Cu, pcbnew.B_Cu, pcbnew.In1_Cu

    # texts on copper, the board's
    for i, (angle, mirrored, layer, string) in enumerate([(0, False, F, "COPPER"), (30, False, F, "TURNED 30"),
                                                          (90, False, F, "UP"), (200, False, F, "Wg~{BAR}"),
                                                          (0, True, B, "MIRRORED"), (15, False, In1, "TWO\nLINES")]):
        board.Add(text(board, string, x0 + 8 * MM + i * 8 * MM, y0 + 6 * MM, layer, angle, mirrored=mirrored))

    # drawings of each kind on F.Cu
    y = y0 + 14 * MM
    s = shape(board, pcbnew.SHAPE_T_SEGMENT, F)
    s.SetStart(vec(x0 + 4 * MM, y))
    s.SetEnd(vec(x0 + 9 * MM, y + 2 * MM))
    board.Add(s)
    for k, (sx, mx, ex) in enumerate([(0, 1.5, 3), (0, 2, 4)]):
        a = shape(board, pcbnew.SHAPE_T_ARC, F, 250_000)
        a.SetArcGeometry(vec(x0 + (11 + sx + 5 * k) * MM, y), vec(x0 + (11 + mx + 5 * k) * MM, y - (1 + k) * MM),
                         vec(x0 + (11 + ex + 5 * k) * MM, y))
        board.Add(a)
    for k, filled in enumerate([True, False]):
        c = shape(board, pcbnew.SHAPE_T_CIRCLE, F, 300_000, filled)
        c.SetCenter(vec(x0 + (24 + 4 * k) * MM, y))
        c.SetEnd(vec(x0 + (25.3 + 4 * k) * MM, y))
        board.Add(c)
    for k, (filled, radius) in enumerate([(True, 0), (False, 0), (True, 400_000)]):
        r = shape(board, pcbnew.SHAPE_T_RECTANGLE, F, 150_000, filled)
        r.SetStart(vec(x0 + (32 + 5 * k) * MM, y - 1 * MM))
        r.SetEnd(vec(x0 + (35.5 + 5 * k) * MM, y + 1.5 * MM))
        if radius:
            r.SetCornerRadius(radius)
        board.Add(r)
    for k, filled in enumerate([True, False]):
        p = shape(board, pcbnew.SHAPE_T_POLY, F, 200_000, filled)
        cx = x0 + (49 + 5 * k) * MM
        p.SetPolyPoints([vec(cx, y - 1.5 * MM), vec(cx + 2 * MM, y + 1 * MM), vec(cx + 0.5 * MM, y + 0.3 * MM),
                         vec(cx - 1.5 * MM, y + 1.5 * MM)])
        board.Add(p)
    # filled polygons of no line width with spikes sharper and blunter than the check's 20 degrees: slivers
    for k, (deg, layer) in enumerate([(8, F), (15, F), (25, F), (10, pcbnew.In2_Cu)]):
        p = shape(board, pcbnew.SHAPE_T_POLY, layer, 0, True)
        cx, cy = x0 + (5 + 6 * k) * MM, y1 - 6 * MM
        w = 0.3 * MM
        tip = w / math.tan(math.radians(deg / 2))
        # (a body of more than five corners: the check passes over smaller outlines)
        p.SetPolyPoints([vec(cx, cy - w), vec(cx + MM, cy - w - 0.5 * MM), vec(cx + 2 * MM, cy - w - 0.3 * MM),
                         vec(cx + 2.5 * MM, cy), vec(cx + 2 * MM, cy + w + 0.3 * MM), vec(cx + MM, cy + w + 0.5 * MM),
                         vec(cx, cy + w), vec(cx - tip, cy)])
        board.Add(p)
    bz = shape(board, pcbnew.SHAPE_T_BEZIER, F, 200_000)
    bz.SetStart(vec(x0 + 4 * MM, y + 6 * MM))
    bz.SetBezierC1(vec(x0 + 6 * MM, y + 2 * MM))
    bz.SetBezierC2(vec(x0 + 9 * MM, y + 10 * MM))
    bz.SetEnd(vec(x0 + 12 * MM, y + 5 * MM))
    bz.RebuildBezierToSegmentsPointsList(ARC_LOW_DEF)
    board.Add(bz)

    # footprints: turned off square, their drawings and texts on copper, plated and unplated holes, a custom pad, a
    # zone of their own
    for k, angle in enumerate([30, 0, 135]):
        fp = pcbnew.FOOTPRINT(board)
        fp.SetReference(f"U{k + 1}")
        fp.SetPosition(vec(x0 + (18 + 14 * k) * MM, y0 + 28 * MM))
        board.Add(fp)
        ref = fp.Reference()
        ref.SetLayer(F)
        ref.SetPosition(vec(x0 + (18 + 14 * k) * MM, y0 + 24 * MM))
        ln = shape(board, pcbnew.SHAPE_T_SEGMENT, F, 200_000, parent=fp)
        ln.SetStart(vec(x0 + (15 + 14 * k) * MM, y0 + 26 * MM))
        ln.SetEnd(vec(x0 + (21 + 14 * k) * MM, y0 + 27 * MM))
        fp.Add(ln)
        rc = shape(board, pcbnew.SHAPE_T_RECTANGLE, F, 150_000, k == 0, parent=fp)
        rc.SetStart(vec(x0 + (15 + 14 * k) * MM, y0 + 29 * MM))
        rc.SetEnd(vec(x0 + (18 + 14 * k) * MM, y0 + 31 * MM))
        fp.Add(rc)
        ac = shape(board, pcbnew.SHAPE_T_ARC, F, 200_000, parent=fp)
        ac.SetArcGeometry(vec(x0 + (19 + 14 * k) * MM, y0 + 30 * MM), vec(x0 + (20 + 14 * k) * MM, y0 + 29 * MM),
                          vec(x0 + (21 + 14 * k) * MM, y0 + 30 * MM))
        fp.Add(ac)
        fp.Add(text(fp, f"T{k}", x0 + (22 + 14 * k) * MM, y0 + 26 * MM, F, 10 * k))
        for j, attr in enumerate([pcbnew.PAD_ATTRIB_PTH, pcbnew.PAD_ATTRIB_NPTH, pcbnew.PAD_ATTRIB_SMD]):
            pad = pcbnew.PAD(fp)
            pad.SetNumber(str(j + 1))
            pad.SetAttribute(attr)
            pad.SetShape(pcbnew.PADSTACK.ALL_LAYERS, [pcbnew.PAD_SHAPE_CIRCLE, pcbnew.PAD_SHAPE_CIRCLE,
                                                      pcbnew.PAD_SHAPE_ROUNDRECT][j])
            pad.SetSize(pcbnew.PADSTACK.ALL_LAYERS, vec(1.6 * MM, 1.6 * MM) if j < 2 else vec(1.8 * MM, 1.0 * MM))
            if attr != pcbnew.PAD_ATTRIB_SMD:
                pad.SetDrillSize(vec(0.9 * MM, 0.9 * MM) if j == 0 else vec(1.6 * MM, 1.6 * MM))
            pad.SetLayerSet(pad.PTHMask() if j == 0 else pad.UnplatedHoleMask() if j == 1 else pad.SMDMask())
            pad.SetPosition(vec(x0 + (15 + 3 * j + 14 * k) * MM, y0 + 34 * MM))
            fp.Add(pad)
        if k == 1:
            pad = pcbnew.PAD(fp)
            pad.SetNumber("4")
            pad.SetAttribute(pcbnew.PAD_ATTRIB_SMD)
            pad.SetShape(pcbnew.PADSTACK.ALL_LAYERS, pcbnew.PAD_SHAPE_CUSTOM)
            pad.SetAnchorPadShape(pcbnew.PADSTACK.ALL_LAYERS, pcbnew.PAD_SHAPE_RECT)
            pad.SetSize(pcbnew.PADSTACK.ALL_LAYERS, vec(1.0 * MM, 1.0 * MM))
            pad.SetLayerSet(pad.SMDMask())
            arm = pcbnew.PCB_SHAPE(None, pcbnew.SHAPE_T_SEGMENT)
            arm.SetStart(vec(0, 0))
            arm.SetEnd(vec(1.5 * MM, -1 * MM))
            arm.SetWidth(400_000)
            pad.AddPrimitiveShape(pcbnew.F_Cu, arm)
            arm.thisown = False  # (the pad holds it now)
            pad.SetPosition(vec(x0 + (24 + 14 * k) * MM, y0 + 34 * MM))
            fp.Add(pad)
            fz = pcbnew.ZONE(fp)
            fz.SetLayer(B)
            fz.SetNet(nets["GND"])
            ol = fz.Outline()
            ol.NewOutline()
            for px, py in [(28, 26), (34, 26), (34, 32), (28, 32)]:
                ol.Append(x0 + px * MM, y0 + py * MM)
            fp.Add(fz)
        fp.SetOrientationDegrees(angle)

    # arc tracks, vias through and blind
    for k in range(3):
        t = pcbnew.PCB_ARC(board)
        t.SetStart(vec(x0 + (6 + 6 * k) * MM, y0 + 42 * MM))
        t.SetMid(vec(x0 + (8 + 6 * k) * MM, y0 + (40 - k) * MM))
        t.SetEnd(vec(x0 + (10 + 6 * k) * MM, y0 + 42 * MM))
        t.SetWidth(300_000)
        t.SetLayer([F, B, In1][k])
        t.SetNet(nets["SIG"])
        board.Add(t)
    for k, (top, bottom) in enumerate([(F, B), (F, In1), (In1, B)]):
        v = pcbnew.PCB_VIA(board)
        v.SetPosition(vec(x0 + (26 + 4 * k) * MM, y0 + 42 * MM))
        v.SetViaType(pcbnew.VIATYPE_THROUGH if k == 0 else pcbnew.VIATYPE_BLIND)
        v.SetLayerPair(top, bottom)
        v.SetWidth(pcbnew.F_Cu, 800_000)
        v.SetDrill(400_000)
        v.SetNet(nets["SIG"])
        board.Add(v)

    # a zone with tracks of other nets at sharp angles through it, and a rule area
    z = pcbnew.ZONE(board)
    z.SetLayer(F)
    z.SetNet(nets["GND"])
    z.SetMinThickness(100_000)
    ol = z.Outline()
    ol.NewOutline()
    for px, py in [(x0 + 40 * MM, y0 + 38 * MM), (x1 - 2 * MM, y0 + 38 * MM), (x1 - 2 * MM, y1 - 2 * MM),
                   (x0 + 40 * MM, y1 - 2 * MM)]:
        ol.Append(int(px), int(py))
    board.Add(z)
    for k, deg in enumerate([6, 9, 12, 16, 24]):
        ox, oy = x0 + 42 * MM, y0 + (40 + 2 * k) * MM
        for sign in (1, -1):
            t = pcbnew.PCB_TRACK(board)
            t.SetStart(vec(ox, oy))
            r = math.radians(deg / 2 * sign)
            t.SetEnd(vec(ox + 14 * MM * math.cos(r), oy + 14 * MM * math.sin(r)))
            t.SetWidth(150_000)
            t.SetLayer(F)
            t.SetNet(nets["SIG2"])
            board.Add(t)
    ra = pcbnew.ZONE(board)
    ra.SetIsRuleArea(True)
    ra.SetLayer(F)
    ol = ra.Outline()
    ol.NewOutline()
    for px, py in [(5, 46), (12, 46), (12, 49), (5, 49)]:
        ol.Append(x0 + px * MM, y0 + py * MM)
    board.Add(ra)

    board.BuildConnectivity()
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    pcbnew.SaveBoard(path, board)


def main():
    args = sys.argv[1:]
    if args and args[0] == "--draw":
        draw(args[1])
        write(args[1])
        subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "drc.py"), args[1]],
                       check=True)
        return
    for path in args:
        write(path)


if __name__ == "__main__":
    main()
