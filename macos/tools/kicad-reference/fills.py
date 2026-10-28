#!/usr/bin/env python3
"""KiCad's zone fills of boards, for checking the port's (KiCadRouter's ZoneFiller) against: through KiCad's pcbnew
module, each board's zones (BOARD::Zones, not its footprints' own) filled by pcbnew.ZONE_FILLER(board).Fill(
board.Zones()), and each zone's filled polygons on each of its layers (each polygon's outline and holes, their points;
whether KiCad keeps it as an island) written next to the board as BOARD.fills (JSON), the zones by their uuids (a
teardrop, which KiCad writes with none, as "zone #N", N its place among the board's zones). With --twice, each board
filled a second time from its first fill too, and any difference between the two said (KiCad's filler runs on
threads).

    fills.py [--twice] BOARD.kicad_pcb...

With --draw, a board of zones taking KiCad's filler down the ways random boards do not, saved, its zones filled, and
then its fills written as above: thermal reliefs on pads of every shape (round, oval, rectangle, rounded and
chamfered rectangle, trapezoid, custom with and without spoke templates) turned to several angles, pads joined solid,
not at all and through-hole only by the zone, their footprint and themselves, pads of their own clearance, thermal
gap and spoke width and angle, zones of several priorities of one net and of others, keepouts of copper pours,
islands removed always, never and below an area, a zone too thin in places for its minimum width, the board's edge
with a cut-out and unplated holes, tracks, arc tracks, vias, texts and drawings of other nets in the zones, a
footprint's own zone, zones on several layers and on no copper, corner smoothing, and a hatched fill.

    fills.py --draw OUT.kicad_pcb

With --draw-open, a small board whose edges do not close, the outline KiCad infers from their box cutting its zone.

    fills.py --draw-open OUT.kicad_pcb
"""

import json
import math
import os
import sys

import pcbnew

MM = 1_000_000


def vec(x, y):
    return pcbnew.VECTOR2I(int(x), int(y))


def pts(chain):
    return [[chain.CPoint(k).x, chain.CPoint(k).y] for k in range(chain.PointCount())]


def fills(board):
    out = {}
    for n, z in enumerate(board.Zones()):
        if z.GetIsRuleArea():
            continue
        layers = {}
        for layer in z.GetLayerSet().Seq():
            if not z.HasFilledPolysForLayer(layer):
                continue
            p = z.GetFilledPolysList(layer)
            layers[pcbnew.LSET.Name(layer)] = [
                {"polygon": [pts(p.Outline(i))] + [pts(p.CHole(i, j)) for j in range(p.HoleCount(i))],
                 "island": z.IsIsland(layer, i)} for i in range(p.OutlineCount())]
        # (a teardrop is written without a uuid, and given a new one each time it is read: by its place among the zones)
        out[f"zone #{n}" if z.IsTeardropArea() else z.m_Uuid.AsString()] = layers
    return out


def fill(board):
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())


def write(path, twice=False):
    board = pcbnew.LoadBoard(path)
    fill(board)
    first = fills(board)
    if twice:
        fill(board)
        second = fills(board)
        if second != first:
            print(f"{path}: filled twice, not the same:", [u for u in first if first[u] != second.get(u)])
    with open(os.path.splitext(path)[0] + ".fills", "w") as f:
        json.dump(first, f, separators=(",", ":"))
        f.write("\n")


def main():
    args = sys.argv[1:]
    if args and args[0] in ("--draw", "--draw-open"):
        (draw if args[0] == "--draw" else draw_open)(args[1])
        write(args[1])
        return
    twice = bool(args) and args[0] == "--twice"
    for path in args[1:] if twice else args:
        write(path, twice)


# --- the drawn board, in millimetres

def mm(*v):
    return [int(round(x * MM)) for x in v]


def edge(board, a, b, width=0.1):
    s = pcbnew.PCB_SHAPE(board)
    s.SetShape(pcbnew.SHAPE_T_SEGMENT)
    s.SetLayer(pcbnew.Edge_Cuts)
    s.SetWidth(mm(width)[0])
    s.SetStart(vec(*mm(*a)))
    s.SetEnd(vec(*mm(*b)))
    board.Add(s)


def box_edges(board, x0, y0, x1, y1):
    for a, b in [((x0, y0), (x1, y0)), ((x1, y0), (x1, y1)), ((x1, y1), (x0, y1)), ((x0, y1), (x0, y0))]:
        edge(board, a, b)


def track(board, a, b, net, width=0.25, layer=pcbnew.F_Cu):
    t = pcbnew.PCB_TRACK(board)
    t.SetStart(vec(*mm(*a)))
    t.SetEnd(vec(*mm(*b)))
    t.SetWidth(mm(width)[0])
    t.SetLayer(layer)
    t.SetNet(net)
    board.Add(t)


def arc_track(board, a, m, b, net, width=0.3, layer=pcbnew.F_Cu):
    t = pcbnew.PCB_ARC(board)
    t.SetStart(vec(*mm(*a)))
    t.SetMid(vec(*mm(*m)))
    t.SetEnd(vec(*mm(*b)))
    t.SetWidth(mm(width)[0])
    t.SetLayer(layer)
    t.SetNet(net)
    board.Add(t)


def via(board, at, net, size=0.8, drill=0.4):
    v = pcbnew.PCB_VIA(board)
    v.SetPosition(vec(*mm(*at)))
    v.SetWidth(pcbnew.F_Cu, mm(size)[0])
    v.SetDrill(mm(drill)[0])
    v.SetNet(net)
    board.Add(v)


def shape(board, kind, layer, net=None, width=0.2, filled=False, **p):
    s = pcbnew.PCB_SHAPE(board)
    s.SetShape(kind)
    s.SetLayer(layer)
    s.SetWidth(mm(width)[0])
    if "start" in p:
        s.SetStart(vec(*mm(*p["start"])))
    if "end" in p:
        s.SetEnd(vec(*mm(*p["end"])))
    if "center" in p:
        s.SetCenter(vec(*mm(*p["center"])))
    if "points" in p:
        s.SetPolyPoints([vec(*mm(*q)) for q in p["points"]])
    if "radius" in p:
        s.SetCornerRadius(mm(p["radius"])[0])
    s.SetFilled(filled)
    if net:
        s.SetNet(net)
    board.Add(s)
    return s


def text(board, s, at, layer=pcbnew.F_Cu, angle=0, size=1.0):
    t = pcbnew.PCB_TEXT(board)
    t.SetText(s)
    t.SetLayer(layer)
    t.SetPosition(vec(*mm(*at)))
    t.SetTextSize(vec(*mm(size, size)))
    t.SetTextThickness(mm(0.15)[0])
    if angle:
        t.SetTextAngleDegrees(angle)
    board.Add(t)


SHAPES = {"circle": pcbnew.PAD_SHAPE_CIRCLE, "rect": pcbnew.PAD_SHAPE_RECTANGLE, "oval": pcbnew.PAD_SHAPE_OVAL,
          "trapezoid": pcbnew.PAD_SHAPE_TRAPEZOID, "roundrect": pcbnew.PAD_SHAPE_ROUNDRECT,
          "chamfered": pcbnew.PAD_SHAPE_CHAMFERED_RECT, "custom": pcbnew.PAD_SHAPE_CUSTOM}


def footprint(board, ref, at, angle=0, layer=pcbnew.F_Cu):
    fp = pcbnew.FOOTPRINT(board)
    fp.SetReference(ref)
    fp.Reference().SetVisible(False)
    fp.Value().SetVisible(False)
    board.Add(fp)
    fp.SetPosition(vec(*mm(*at)))
    if layer == pcbnew.B_Cu:
        fp.Flip(fp.GetPosition(), pcbnew.FLIP_DIRECTION_TOP_BOTTOM)
    return fp


def pad(fp, number, net, kind="rect", size=(1.6, 1.0), offset=(0, 0), angle=0, drill=None, npth=False, layer=pcbnew.F_Cu,
        anchor="rect", primitives=(), templates=(), **overrides):
    p = pcbnew.PAD(fp)
    p.SetNumber(number)
    al = pcbnew.PADSTACK.ALL_LAYERS
    p.SetShape(al, SHAPES[kind])
    p.SetSize(al, vec(*mm(*size)))
    if kind == "trapezoid":
        p.SetDelta(al, vec(*mm(0.4, 0)))
    if kind == "roundrect":
        p.SetRoundRectRadiusRatio(al, 0.3)
    if kind == "chamfered":
        p.SetRoundRectRadiusRatio(al, 0.1)
        p.SetChamferRectRatio(al, 0.25)
        p.SetChamferPositions(al, 1 | 8)
    if kind == "custom":
        p.SetAnchorPadShape(al, SHAPES[anchor])
        p.SetSize(al, vec(*mm(*size)))
        for poly in primitives:
            s = pcbnew.PCB_SHAPE(None, pcbnew.SHAPE_T_POLY)
            s.SetPolyPoints([vec(*mm(*q)) for q in poly])
            s.SetWidth(0)
            s.SetFilled(True)
            p.AddPrimitiveShape(al, s)
            s.thisown = False
        for a, b in templates:
            s = pcbnew.PCB_SHAPE(None, pcbnew.SHAPE_T_SEGMENT)
            s.SetStart(vec(*mm(*a)))
            s.SetEnd(vec(*mm(*b)))
            s.SetWidth(mm(0.3)[0])
            s.SetIsProxyItem(True)
            p.AddPrimitiveShape(al, s)
            s.thisown = False
    if npth:
        p.SetAttribute(pcbnew.PAD_ATTRIB_NPTH)
        p.SetDrillSize(vec(*mm(*drill)))
        if drill[0] != drill[1]:
            p.SetDrillShape(pcbnew.PAD_DRILL_SHAPE_OBLONG)
        p.SetLayerSet(p.UnplatedHoleMask())
    elif drill:
        p.SetAttribute(pcbnew.PAD_ATTRIB_PTH)
        p.SetDrillSize(vec(*mm(*drill)))
        if drill[0] != drill[1]:
            p.SetDrillShape(pcbnew.PAD_DRILL_SHAPE_OBLONG)
        p.SetLayerSet(p.PTHMask())
    else:
        p.SetAttribute(pcbnew.PAD_ATTRIB_SMD)
        if layer == pcbnew.F_Cu:
            p.SetLayerSet(p.SMDMask())
        else:
            ls = pcbnew.LSET()
            for l in (pcbnew.B_Cu, pcbnew.B_Paste, pcbnew.B_Mask):
                ls.AddLayer(l)
            p.SetLayerSet(ls)
    if offset != (0, 0):
        p.SetOffset(al, vec(*mm(*offset)))
    fp.Add(p)
    p.SetFPRelativePosition(vec(0, 0))
    p.SetFPRelativeOrientation(pcbnew.EDA_ANGLE(angle, pcbnew.DEGREES_T))
    if net:
        p.SetNet(net)
    for k, v in overrides.items():
        if k == "connection":
            p.SetLocalZoneConnection(v)
        elif k == "gap":
            p.SetThermalGap(mm(v)[0])
        elif k == "spoke":
            p.SetLocalThermalSpokeWidthOverride(mm(v)[0])
        elif k == "spoke_angle":
            p.SetThermalSpokeAngleDegrees(v)
        elif k == "clearance":
            p.SetLocalClearance(mm(v)[0])
        elif k == "convexhull":
            p.SetCustomShapeInZoneOpt(pcbnew.CUSTOM_SHAPE_ZONE_MODE_CONVEXHULL)
    return p


def lone_pad(board, ref, at, net, angle=0, fp_angle=0, **kw):
    fp = footprint(board, ref, at, fp_angle, kw.get("layer", pcbnew.F_Cu))
    pad(fp, "1", net, angle=angle, **kw)
    return fp


def zone(board, net, layers, outline, priority=0, connection=pcbnew.ZONE_CONNECTION_THERMAL, gap=0.5, spoke=0.4,
         min_thickness=0.25, clearance=0.3, name="", parent=None, holes=(), **kw):
    z = pcbnew.ZONE(parent or board)
    ls = pcbnew.LSET()
    for l in layers:
        ls.AddLayer(l)
    z.SetLayerSet(ls)
    if net:
        z.SetNet(net)
    z.SetAssignedPriority(priority)
    z.SetPadConnection(connection)
    z.SetThermalReliefGap(mm(gap)[0])
    z.SetThermalReliefSpokeWidth(mm(spoke)[0])
    z.SetMinThickness(mm(min_thickness)[0])
    z.SetLocalClearance(mm(clearance)[0])
    if name:
        z.SetZoneName(name)
    poly = z.Outline()
    poly.NewOutline()
    for q in outline:
        poly.Append(*mm(*q))
    for h in holes:
        poly.NewHole()
        for q in h:
            poly.Append(*mm(*q), -1, poly.HoleCount(0) - 1)
    for k, v in kw.items():
        if k == "islands":
            z.SetIslandRemovalMode(v)
        elif k == "min_island":
            z.SetMinIslandArea(int(v * MM * MM))
        elif k == "hatch":
            z.SetFillMode(pcbnew.ZONE_FILL_MODE_HATCH_PATTERN)
            thickness, hgap, orientation, level, value = v
            z.SetHatchThickness(mm(thickness)[0])
            z.SetHatchGap(mm(hgap)[0])
            z.SetHatchOrientation(pcbnew.EDA_ANGLE(orientation, pcbnew.DEGREES_T))
            z.SetHatchSmoothingLevel(level)
            z.SetHatchSmoothingValue(value)
        elif k == "smoothing":
            kind, radius = v
            z.SetCornerSmoothingType(kind)
            z.SetCornerRadius(mm(radius)[0])
        elif k == "keepout":
            z.SetIsRuleArea(True)
            tracks, vias, pads, fills = v
            z.SetDoNotAllowTracks(tracks)
            z.SetDoNotAllowVias(vias)
            z.SetDoNotAllowPads(pads)
            z.SetDoNotAllowZoneFills(fills)
            z.SetDoNotAllowFootprints(False)
    if parent:
        parent.Add(z)
    else:
        board.Add(z)
    return z


def rect(x0, y0, x1, y1):
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def draw_open(path):
    """A board whose edges do not close: the outline KiCad infers from their box, which cuts the fill of a zone
    reaching past it and drops an island of it outside"""
    board = pcbnew.NewBoard(path)
    for a, b in [((0, 0), (30, 0)), ((30, 0), (30, 20)), ((30, 20), (0, 20)), ((0, 20), (0, 2))]:
        edge(board, a, b)
    gnd = pcbnew.NETINFO_ITEM(board, "GND")
    board.Add(gnd)
    sig = pcbnew.NETINFO_ITEM(board, "SIG")
    board.Add(sig)
    zone(board, gnd, [pcbnew.F_Cu], rect(-5, 5, 26, 25))
    lone_pad(board, "P1", (10, 10), gnd)
    lone_pad(board, "P2", (20, 15), sig, kind="circle", size=(1.6, 1.6), drill=(0.8, 0.8))
    track(board, (-6, 17), (31, 17), sig)
    pcbnew.SaveBoard(path, board)


def draw(path):
    board = pcbnew.NewBoard(path)
    board.SetCopperLayerCount(4)
    box_edges(board, 0, 0, 200, 120)
    # a cut-out across the first zone's edge, and a slot inside it
    box_edges(board, 88, 62, 98, 74)
    nets = {}
    for name in ["GND", "VCC", "SIG", "SIG2"]:
        n = pcbnew.NETINFO_ITEM(board, name)
        board.Add(n)
        nets[name] = n
    gnd, vcc, sig, sig2 = nets["GND"], nets["VCC"], nets["SIG"], nets["SIG2"]
    F, B, In1, In2 = pcbnew.F_Cu, pcbnew.B_Cu, pcbnew.In1_Cu, pcbnew.In2_Cu

    # 1. thermal reliefs on pads of every shape at several angles (odd shapes plated through)
    zone(board, gnd, [F], rect(10, 10, 95, 72))
    kinds = ["circle", "rect", "oval", "trapezoid", "roundrect", "chamfered", "custom", "custom"]
    poly = [[(0.4, -0.3), (1.6, -0.6), (1.6, 0.6), (0.4, 0.3)]]
    for i, kind in enumerate(kinds):
        for j, angle in enumerate([0, 30, 45, 90, 135]):
            x, y = 15 + 10 * i, 15 + 7 * j
            kw = {}
            size = (1.6, 1.6) if kind == "circle" else (1.8, 1.1)
            if kind == "custom":
                kw = {"anchor": "rect" if i == 6 else "circle", "primitives": poly}
                size = (1.0, 1.0)
                if i == 7:
                    kw["templates"] = [((0, 0), (0, -2.0)), ((0, 0), (-2.0, 0))]
            if i % 2 == 1:
                kw["drill"] = (0.8, 0.8)
            lone_pad(board, f"T{i}{j}", (x, y), gnd, kind=kind, size=size, angle=angle, **kw)
    # 2. connections and the pads' own settings
    row = 52
    overrides = [{"connection": pcbnew.ZONE_CONNECTION_FULL}, {"connection": pcbnew.ZONE_CONNECTION_NONE},
                 {"gap": 0.25}, {"spoke": 0.6}, {"spoke_angle": 30}, {"gap": 0.8, "spoke": 0.3},
                 {"connection": pcbnew.ZONE_CONNECTION_NONE, "drill": (0.8, 0.8)}]
    for i, o in enumerate(overrides):
        lone_pad(board, f"O{i}", (15 + 9 * i, row), gnd, size=(1.8, 1.1), offset=(0.2, 0) if i == 3 else (0, 0), **o)
    fp = footprint(board, "O9", (78, row))
    fp.SetLocalZoneConnection(pcbnew.ZONE_CONNECTION_NONE)
    pad(fp, "1", gnd)
    fp = footprint(board, "O10", (85, row))
    fp.SetLocalClearance(mm(0.6)[0])
    pad(fp, "1", sig)
    lone_pad(board, "O11", (90, row), sig, clearance=0.45)
    lone_pad(board, "O12", (15, 58), sig, kind="custom", size=(1.0, 1.0), primitives=poly, convexhull=True)
    lone_pad(board, "O13", (21, 58), gnd, kind="oval", size=(1.2, 1.2))
    lone_pad(board, "O14", (21, 58), gnd, kind="oval", size=(1.2, 1.2))
    # 3. other nets' tracks, arcs, vias, texts and drawings in the zone; unplated holes
    track(board, (25, 62), (45, 62), sig)
    track(board, (45, 62), (50, 67), sig)
    track(board, (25, 64.4), (40, 64.4), sig2, width=0.2)
    arc_track(board, (52, 60), (56, 63), (60, 60), sig)
    via(board, (30, 68), sig)
    via(board, (34, 68), gnd)
    via(board, (38, 68), sig, size=0.6, drill=0.3)
    text(board, "TEXT", (70, 60))
    text(board, "TURNED", (78, 66), angle=30)
    shape(board, pcbnew.SHAPE_T_SEGMENT, F, sig, start=(60, 66), end=(66, 69))
    shape(board, pcbnew.SHAPE_T_CIRCLE, F, None, start=(70, 68), end=(71, 68), filled=True)
    shape(board, pcbnew.SHAPE_T_POLY, F, sig2, points=[(74, 67), (77, 69), (73, 70)], filled=True, width=0.1)
    shape(board, pcbnew.SHAPE_T_RECTANGLE, F, None, start=(80, 56), end=(84, 59), radius=0.6, width=0.15)
    fp = footprint(board, "H1", (42, 69))
    pad(fp, "", None, kind="circle", size=(1.5, 1.5), drill=(1.5, 1.5), npth=True)
    fp = footprint(board, "H2", (50, 70))
    pad(fp, "", None, kind="oval", size=(2.4, 1.2), drill=(2.4, 1.2), npth=True)
    # 4. the back: plated holes only relieved, surface pads of its net, a net of its own
    zone(board, vcc, [B], rect(10, 10, 95, 72), connection=pcbnew.ZONE_CONNECTION_THT_THERMAL, clearance=0.25)
    for i in range(4):
        lone_pad(board, f"V{i}", (60 + 6 * i, 45), vcc, kind="circle", size=(1.7, 1.7), drill=(0.9, 0.9))
        lone_pad(board, f"W{i}", (60 + 6 * i, 49), vcc, layer=B)
    # 5. priorities, on In1: a higher zone of the net, one of another net between, keepouts
    zone(board, gnd, [In1], rect(105, 10, 190, 55))
    zone(board, gnd, [In1], rect(150, 15, 185, 40), priority=2)
    zone(board, vcc, [In1], rect(110, 20, 160, 45), priority=1, clearance=0.4)
    zone(board, None, [In1, In2], rect(165, 44, 180, 52), keepout=(False, False, False, True))
    zone(board, None, [In1], rect(115, 47, 122, 53), keepout=(True, True, False, False))
    lone_pad(board, "P1", (120, 30), vcc, kind="circle", size=(1.7, 1.7), drill=(0.9, 0.9))
    lone_pad(board, "P2", (170, 25), gnd, kind="circle", size=(1.7, 1.7), drill=(0.9, 0.9))
    lone_pad(board, "P3", (130, 50), gnd, kind="circle", size=(1.7, 1.7), drill=(0.9, 0.9))
    # 6. islands on In2: removed always, never, below an area; a zone of no net
    for i, (mode, area) in enumerate([(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS, 0), (pcbnew.ISLAND_REMOVAL_MODE_NEVER, 0),
                                      (pcbnew.ISLAND_REMOVAL_MODE_AREA, 3)]):
        x0 = 105 + 29 * i
        zone(board, gnd, [In2], rect(x0, 60, x0 + 26, 80), islands=mode, min_island=area)
        lone_pad(board, f"I{i}", (x0 + 4, 64), gnd, kind="circle", size=(1.7, 1.7), drill=(0.9, 0.9))
        for (cx, cy, r) in [(x0 + 12, 70, 1.0), (x0 + 19, 72, 2.2)]:
            for a, b in [((cx - r, cy - r), (cx + r, cy - r)), ((cx + r, cy - r), (cx + r, cy + r)),
                         ((cx + r, cy + r), (cx - r, cy + r)), ((cx - r, cy + r), (cx - r, cy - r))]:
                track(board, a, b, sig, layer=In2)
    zone(board, None, [In2], rect(105, 84, 130, 96))
    track(board, (112, 83), (112, 97), sig, layer=In2)
    track(board, (120, 83), (120, 97), sig, layer=In2)
    # 7. a zone too thin in places
    zone(board, sig2, [In2], [(135, 84), (150, 84), (150, 89), (143.15, 89), (143.15, 92), (150, 92), (150, 97), (135, 97),
                              (135, 92), (142.85, 92), (142.85, 89), (135, 89)], min_thickness=0.5)
    track(board, (137, 90.5), (148, 90.6), sig, layer=In2, width=0.3)
    # 8. hatched zones with thermal reliefs of pads and vias, smoothed holes, turned
    zone(board, vcc, [F], rect(155, 85, 180, 105), hatch=(1.0, 1.5, 30, 2, 0.5))
    zone(board, vcc, [B], rect(155, 85, 180, 105), hatch=(0.8, 1.2, 0, 1, 0.3), connection=pcbnew.ZONE_CONNECTION_FULL)
    for i in range(3):
        lone_pad(board, f"Q{i}", (159 + 7 * i, 90), vcc, kind=["circle", "rect", "oval"][i], size=(1.8, 1.4), drill=(0.8, 0.8))
        via(board, (159 + 7 * i, 96), vcc, size=0.6, drill=0.3)
    via(board, (176, 100), gnd)
    track(board, (152, 102), (183, 102), sig)
    # 9. smoothed corners
    zone(board, gnd, [B], [(105, 10), (125, 10), (125, 30), (115, 30), (115, 40), (105, 40)],
         smoothing=(pcbnew.ZONE_SETTINGS.CORNER_SMOOTHING_CHAMFER, 1.0))
    zone(board, gnd, [B], [(130, 10), (150, 10), (150, 25), (140, 25), (140, 35), (130, 35)],
         smoothing=(pcbnew.ZONE_SETTINGS.CORNER_SMOOTHING_FILLET, 1.5))
    lone_pad(board, "S1", (110, 15), gnd, layer=B)
    lone_pad(board, "S2", (135, 15), gnd, layer=B)
    # 10. zones on no copper, and a zone on three copper layers with a hole in it
    zone(board, None, [pcbnew.F_SilkS], rect(10, 80, 40, 112))
    zone(board, None, [pcbnew.B_Mask], rect(12, 82, 38, 110), hatch=(1.0, 1.0, 45, 0, 0.1))
    zone(board, gnd, [F, In1, B], rect(12, 80, 40, 112), holes=[rect(20, 90, 28, 98)])
    lone_pad(board, "M1", (16, 85), gnd, kind="circle", size=(1.7, 1.7), drill=(0.9, 0.9))
    lone_pad(board, "M2", (34, 104), sig, kind="circle", size=(1.7, 1.7), drill=(0.9, 0.9))
    # 11. a zone with a footprint's own zones in it, a net tie, a teardrop
    zone(board, gnd, [F], rect(45, 80, 95, 115))
    fp = footprint(board, "Z1", (55, 90))
    pad(fp, "1", gnd)
    zone(board, sig, [F], rect(57, 87, 62, 93), parent=fp)
    zone(board, None, [F], rect(64, 87, 68, 93), keepout=(False, False, False, True), parent=fp)
    fp = footprint(board, "NT1", (75, 95))
    fp.AddNetTiePadGroup("1,2")
    p1 = pad(fp, "1", gnd)
    p2 = pad(fp, "2", sig)
    p2.SetFPRelativePosition(vec(*mm(3, 0)))
    s = pcbnew.PCB_SHAPE(fp, pcbnew.SHAPE_T_SEGMENT)
    s.SetLayer(F)
    s.SetStart(vec(*mm(75, 95)))
    s.SetEnd(vec(*mm(78, 95)))
    s.SetWidth(mm(0.3)[0])
    fp.Add(s)
    track(board, (78, 95), (90, 95), sig)
    track(board, (60, 105), (70, 105), sig, width=0.3)
    via(board, (70, 105), sig)
    zone(board, sig, [F], [(68.6, 104.85), (69.4, 104.3), (70.5, 104.3), (70.5, 105.7), (69.4, 105.7), (68.6, 105.15)],
         name="TEARDROP", connection=pcbnew.ZONE_CONNECTION_FULL, min_thickness=0.0254)
    board.BuildConnectivity()
    pcbnew.SaveBoard(path, board)
    # (the teardrop's attribute, which the Python module cannot set)
    with open(path) as f:
        t = f.read()
    t = t.replace('(name "TEARDROP")', '(name "TEARDROP") (attr (teardrop (type padvia)))')
    with open(path, "w") as f:
        f.write(t)


if __name__ == "__main__":
    main()
