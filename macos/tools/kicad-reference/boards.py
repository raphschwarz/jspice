#!/usr/bin/env python3
"""Random boards made by KiCad itself (its pcbnew module), from KiCad's own footprint libraries, to check the router's
world of a board against KiCad's: footprints with every kind of pad (rectangles, rounded and cut corners, ovals,
trapezoids, circles, unplated holes, custom pads), turned and flipped, on two or four layers; nets in net classes (by
pattern, of different priorities, regular expressions among them), pads' and footprints' own clearances; tracks and
vias, on a four layer board blind, buried and micro ones too; drawings on copper; outlines with rounded corners and round cut-outs; keepout zones (rule areas) of several
shapes, some with holes, some in footprints; on half of them copper zones, filled by KiCad. Each board is saved (its .kicad_pcb and .kicad_pro), and board-scene.py
run on it (KiCad reading it afresh) writes what KiCad's router sees of it. With --custom-pads, the footprints are
drawn from every footprint of KiCad's libraries with a custom pad (their primitives: polygons, lines, arcs, circles
and rings, rectangles, filled or outlined, of some width or none) instead. With --pairs, boards with differential
pairs to route instead: a connector and a chip with two pairs of their pads of pairs' nets, a net class with a diff
pair width and gap of its own, parts and tracks of other nets between. With --arcs, arc tracks too (from a random
sequence of their own, so that the rest of each board is as it is without them): out of pads of their net, rounding
the turns of tracks of a few segments, or on their own.

    boards.py [--custom-pads | --pairs] [--arcs] OUTDIR COUNT [SEED]
"""

import math
import os
import random
import subprocess
import sys

import pcbnew

MM = 1_000_000
LIBRARIES = os.environ.get("KICAD_FOOTPRINTS", "/usr/share/kicad/footprints")

FOOTPRINTS = [
    ("Resistor_SMD", "R_0603_1608Metric"),
    ("Resistor_SMD", "R_1206_3216Metric"),
    ("Capacitor_SMD", "C_0805_2012Metric"),
    ("Capacitor_SMD", "C_0402_1005Metric"),
    ("Package_SO", "SOIC-8_3.9x4.9mm_P1.27mm"),
    ("Package_SO", "TSSOP-16_4.4x5mm_P0.65mm"),
    ("Package_TO_SOT_SMD", "SOT-23"),
    ("Package_TO_SOT_SMD", "SOT-223-3_TabPin2"),
    ("Package_DFN_QFN", "QFN-16-1EP_3x3mm_P0.5mm_EP1.75x1.75mm"),
    ("Package_DFN_QFN", "Analog_QFN-28-36-2EP_5x6mm_P0.5mm"),
    ("Package_QFP", "LQFP-32_7x7mm_P0.8mm"),
    ("Package_BGA", "BGA-64_9.0x9.0mm_Layout10x10_P0.8mm"),
    ("Connector_PinHeader_2.54mm", "PinHeader_1x04_P2.54mm_Vertical"),
    ("Connector_PinHeader_2.54mm", "PinHeader_2x03_P2.54mm_Vertical"),
    ("Connector_JST", "JST_XH_B2B-XH-A_1x02_P2.50mm_Vertical"),
    ("Package_DIP", "DIP-8_W7.62mm"),
    ("MountingHole", "MountingHole_3.2mm_M3"),
    ("MountingHole", "MountingHole_3.2mm_M3_Pad"),
    ("Diode_SMD", "D_SOD-123"),
    ("Diode_SMD", "D_SMA-SMB_Universal_Handsoldering"),
    ("LED_SMD", "LED_0805_2012Metric"),
    ("Inductor_SMD", "L_Bourns_SDR0604"),
    ("Crystal", "Crystal_SMD_3225-4Pin_3.2x2.5mm"),
    ("Capacitor_THT", "CP_Radial_D5.0mm_P2.00mm"),
    ("Connector_Coaxial", "MMCX_Molex_73415-0961_Horizontal_0.8mm-PCB"),
    ("Battery", "BatteryHolder_Keystone_590"),
]

NET_NAMES = ["PWR1", "PWR_5V", "SIG1", "SIG2", "D12", "D7", "/net3", "/sub/clk", "GND", "VCC", "N1", "N2", "N3"]


def vec(x, y):
    return pcbnew.VECTOR2I(int(x), int(y))


def outline(rng, board, x0, y0, x1, y1):
    """The board's edge: a rectangle drawn as one (now and then with its corners rounded), as lines, or with arcs at
    its corners; now and then round cut-outs"""
    def shape(kind):
        s = pcbnew.PCB_SHAPE(board)
        s.SetShape(kind)
        s.SetLayer(pcbnew.Edge_Cuts)
        s.SetWidth(rng.choice([50_000, 100_000, 150_000]))
        board.Add(s)
        return s

    style = rng.choice(["rect", "lines", "rounded", "rounded", "roundrect"])
    if style in ("rect", "roundrect"):
        s = shape(pcbnew.SHAPE_T_RECTANGLE)
        s.SetStart(vec(x0, y0))
        s.SetEnd(vec(x1, y1))
        if style == "roundrect":
            s.SetCornerRadius(rng.randint(1, 50) * MM // 10)
    elif style == "lines":
        c = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
        for i in range(4):
            s = shape(pcbnew.SHAPE_T_SEGMENT)
            s.SetStart(vec(*c[i]))
            s.SetEnd(vec(*c[(i + 1) % 4]))
    else:
        r = rng.randint(1, 5) * MM
        for (ax, ay), (bx, by) in [((x0 + r, y0), (x1 - r, y0)), ((x1, y0 + r), (x1, y1 - r)), ((x1 - r, y1), (x0 + r, y1)),
                                   ((x0, y1 - r), (x0, y0 + r))]:
            s = shape(pcbnew.SHAPE_T_SEGMENT)
            s.SetStart(vec(ax, ay))
            s.SetEnd(vec(bx, by))
        for cx, cy, a in [(x1 - r, y0 + r, -45), (x1 - r, y1 - r, 45), (x0 + r, y1 - r, 135), (x0 + r, y0 + r, 225)]:
            s = shape(pcbnew.SHAPE_T_ARC)
            d = math.radians(a)
            start = (cx + r * math.cos(d - math.pi / 4), cy + r * math.sin(d - math.pi / 4))
            mid = (cx + r * math.cos(d), cy + r * math.sin(d))
            end = (cx + r * math.cos(d + math.pi / 4), cy + r * math.sin(d + math.pi / 4))
            s.SetArcGeometry(vec(*start), vec(*mid), vec(*end))
    for _ in range(rng.choice([0, 0, 1, 2])):
        s = shape(pcbnew.SHAPE_T_CIRCLE)
        cx, cy = rng.randint(x0 + 5 * MM, x1 - 5 * MM), rng.randint(y0 + 5 * MM, y1 - 5 * MM)
        s.SetCenter(vec(cx, cy))
        s.SetEnd(vec(cx + rng.randint(1, 3) * MM, cy))


def net_classes(rng, board):
    """Net classes by pattern: power ones wide apart and first, signals closer, the default between"""
    ds = board.GetDesignSettings()
    ns = ds.m_NetSettings
    default = ns.GetDefaultNetclass()
    default.SetClearance(rng.choice([150_000, 200_000, 250_000]))
    for name, clearance, priority, pattern in [("Power", rng.choice([300_000, 400_000]), 0, "PWR*"),
                                               ("Signal", rng.choice([100_000, 120_000]), 1, "SIG?"),
                                               ("Digital", rng.choice([180_000, 220_000]), rng.choice([0, 2]), "D[0-9]+"),
                                               ("Clock", None, 3, "/sub/*")]:
        nc = pcbnew.NETCLASS(name)
        if clearance is not None:
            nc.SetClearance(clearance)
        nc.SetPriority(priority)
        ns.SetNetclass(name, nc)
        ns.SetNetclassPatternAssignment(pattern, name)
    ds.m_MinClearance = rng.choice([0, 0, 100_000, 160_000])
    ds.m_HoleClearance = rng.choice([0, 250_000])
    ds.m_CopperEdgeClearance = rng.choice([300_000, 500_000])


def keepouts(rng, board, x0, y0, x1, y1, copper, footprints):
    """Rule areas keeping tracks or vias out (or only pads, footprints or fills, which the router still sees): boxes, L
    shapes, polygons and now and then one crossing itself, some with box or round holes (which may cross their edge),
    on some of the copper layers, a few in footprints; now and then a tiny one KiCad's router cannot cut into
    triangles (near copies of holes a few nanometres apart, as geometry.cpp's), which it leaves out"""
    def grid(v):
        return v if rng.random() < 0.2 else v // 10_000 * 10_000

    for _ in range(rng.choice([0, 1, 1, 2, 2, 3])):
        fp = rng.choice(footprints) if footprints and rng.random() < 0.25 else None
        if fp is not None:
            cx, cy = fp.GetPosition().x, fp.GetPosition().y
        else:
            cx, cy = rng.randint(x0 + 3 * MM, x1 - 3 * MM), rng.randint(y0 + 3 * MM, y1 - 3 * MM)
        zone = pcbnew.ZONE(fp if fp is not None else board)
        zone.SetIsRuleArea(True)
        rules = rng.choice(["tracks", "vias", "both", "both", "both", "other"])
        zone.SetDoNotAllowTracks(rules in ("tracks", "both"))
        zone.SetDoNotAllowVias(rules in ("vias", "both"))
        zone.SetDoNotAllowPads(rng.random() < 0.3)
        zone.SetDoNotAllowFootprints(rng.random() < 0.3)
        zone.SetDoNotAllowZoneFills(rules == "other" or rng.random() < 0.5)
        if rng.random() < 0.5:
            zone.SetZoneName(f"Keepout {rng.randint(1, 99)}")
        layers = pcbnew.LSET()
        chosen = [l for l in copper if rng.random() < 0.6] or [rng.choice(copper)]
        for l in chosen:
            layers.AddLayer(l)
        zone.SetLayerSet(layers)
        poly = zone.Outline()
        poly.NewOutline()
        w, h = rng.randint(1, 12) * MM, rng.randint(1, 12) * MM
        shape = rng.choice(["box", "box", "L", "polygon", "polygon", "crossing", "tiny"])
        if shape == "box":
            pts = [(0, 0), (w, 0), (w, h), (0, h)]
        elif shape == "L":
            a, b = rng.randint(w // 4, w * 3 // 4), rng.randint(h // 4, h * 3 // 4)
            pts = [(0, 0), (w, 0), (w, b), (a, b), (a, h), (0, h)]
        elif shape == "polygon":
            angles = sorted(rng.uniform(0, 2 * math.pi) for _ in range(rng.randint(3, 9)))
            pts = [(w / 2 + w / 2 * rng.uniform(0.4, 1) * math.cos(t), h / 2 + h / 2 * rng.uniform(0.4, 1) * math.sin(t))
                   for t in angles]
        elif shape == "crossing":
            pts = [(0, 0), (w, h), (w, 0), (0, h)]
        else:
            pts = [(0, 0), (7300, 0), (7300, 7300), (0, 7300)]
        if rng.random() < 0.5:
            pts.reverse()
        for x, y in pts:
            poly.Append(int(grid(cx + int(x))) if shape != "tiny" else cx + int(x),
                        int(grid(cy + int(y))) if shape != "tiny" else cy + int(y))
        if shape == "tiny":
            for hole in [[(2909, 4391), (4369, 4391), (4369, 7311), (2909, 7311)],
                         [(2926, 4368), (4386, 4368), (4386, 7288), (2926, 7288)],
                         [(2923, 4370), (4383, 4370), (4383, 7290), (2923, 7290)],
                         [(725, 3649), (1455, 3649), (1455, 6569), (725, 6569)],
                         [(742, 3641), (1472, 3641), (1472, 6561), (742, 6561)],
                         [(2913, 2910), (5833, 2910), (5833, 3640), (2913, 3640)],
                         [(2923, 2925), (5843, 2925), (5843, 3655), (2923, 3655)]]:
                h = poly.NewHole()
                for x, y in hole:
                    poly.Append(cx + x, cy + y, -1, h)
        elif shape in ("box", "L", "polygon") and rng.random() < 0.5:
            for _ in range(rng.randint(1, 2)):
                hx, hy = rng.randint(0, w), rng.randint(0, h)
                hole = poly.NewHole()
                if rng.random() < 0.5:
                    r = rng.randint(2, 8) * 100_000
                    k = rng.choice([16, 24, 32])
                    hp = [(hx + r * math.cos(2 * math.pi * j / k), hy + r * math.sin(2 * math.pi * j / k)) for j in range(k)]
                else:
                    hw, hh = rng.randint(1, 4) * 500_000, rng.randint(1, 4) * 500_000
                    hp = [(hx, hy), (hx + hw, hy), (hx + hw, hy + hh), (hx, hy + hh)]
                for x, y in hp:
                    poly.Append(int(grid(cx + int(x))), int(grid(cy + int(y))), -1, hole)
        if fp is not None:
            fp.Add(zone)
        else:
            board.Add(zone)


def copper_zones(rng, board, x0, y0, x1, y1, copper, nets):
    """Copper zones on half the boards, filled by KiCad's own zone filler as the board is saved: boxes and polygons of
    a net (now and then of none), on one copper layer or a few, of different priorities, their pads joined by thermal
    reliefs, solidly or not at all, some with a clearance of their own, now and then two of one net overlapping"""
    if rng.random() < 0.5:
        return False
    for _ in range(rng.randint(1, 3)):
        zone = pcbnew.ZONE(board)
        layers = pcbnew.LSET()
        chosen = [rng.choice(copper)] if rng.random() < 0.7 else [l for l in copper if rng.random() < 0.6] or [copper[0]]
        for l in chosen:
            layers.AddLayer(l)
        zone.SetLayerSet(layers)
        if rng.random() < 0.9:
            zone.SetNet(rng.choice(nets))
        zone.SetAssignedPriority(rng.randint(0, 3))
        zone.SetPadConnection(rng.choice([pcbnew.ZONE_CONNECTION_THERMAL, pcbnew.ZONE_CONNECTION_THERMAL,
                                          pcbnew.ZONE_CONNECTION_FULL, pcbnew.ZONE_CONNECTION_NONE]))
        if rng.random() < 0.3:
            zone.SetLocalClearance(rng.choice([300_000, 500_000]))
        poly = zone.Outline()
        poly.NewOutline()
        w, h = rng.randint(5, 30) * MM, rng.randint(5, 30) * MM
        cx, cy = rng.randint(x0 - 2 * MM, x1 - w // 2), rng.randint(y0 - 2 * MM, y1 - h // 2)
        if rng.random() < 0.6:
            pts = [(0, 0), (w, 0), (w, h), (0, h)]
        else:
            angles = sorted(rng.uniform(0, 2 * math.pi) for _ in range(rng.randint(4, 9)))
            pts = [(w / 2 + w / 2 * rng.uniform(0.5, 1) * math.cos(a), h / 2 + h / 2 * rng.uniform(0.5, 1) * math.sin(a))
                   for a in angles]
        for x, y in pts:
            poly.Append(cx + int(x) // 10_000 * 10_000, cy + int(y) // 10_000 * 10_000)
        board.Add(zone)
    return True


def layered_vias(rng, board, x0, y0, x1, y1, nets):
    """On a four layer board, vias that go through some of it: blind (from the top or the bottom to an inner layer),
    buried (between the inner layers) and micro (one layer deep)"""
    if board.GetCopperLayerCount() != 4:
        return
    kinds = [(pcbnew.VIATYPE_BLIND, pcbnew.F_Cu, pcbnew.In2_Cu), (pcbnew.VIATYPE_BLIND, pcbnew.In1_Cu, pcbnew.B_Cu),
             (pcbnew.VIATYPE_BURIED, pcbnew.In1_Cu, pcbnew.In2_Cu), (pcbnew.VIATYPE_MICROVIA, pcbnew.F_Cu, pcbnew.In1_Cu),
             (pcbnew.VIATYPE_MICROVIA, pcbnew.In2_Cu, pcbnew.B_Cu)]
    for _ in range(rng.randint(0, 6)):
        kind, top, bottom = rng.choice(kinds)
        v = pcbnew.PCB_VIA(board)
        v.SetPosition(vec(rng.randint(x0 + 3 * MM, x1 - 3 * MM), rng.randint(y0 + 3 * MM, y1 - 3 * MM)))
        d = rng.randint(3, 4) * 100_000 if kind == pcbnew.VIATYPE_MICROVIA else rng.randint(5, 8) * 100_000
        v.SetViaType(kind)  # (before its layers, as KiCad's router sets it)
        v.SetLayerPair(top, bottom)
        v.SetWidth(pcbnew.F_Cu, d)
        v.SetDrill(d // 2 // 50_000 * 50_000)
        v.SetNet(rng.choice(nets))
        board.Add(v)


# the eight directions a track goes, round the way KiCad's y axis turns
DIRS = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]


def arc_turn(p, d, turn, r):
    """An arc track's mid and end from `p`, going on in direction `d` (one of DIRS) and turning `turn` eighths of a
    turn on a radius of `r`, tangent to the way it came and the way it goes on"""
    u = (DIRS[d][0] / math.hypot(*DIRS[d]), DIRS[d][1] / math.hypot(*DIRS[d]))
    side = 1 if turn > 0 else -1
    c = (p[0] - u[1] * side * r, p[1] + u[0] * side * r)

    def at(a):
        dx, dy = p[0] - c[0], p[1] - c[1]
        return (round(c[0] + dx * math.cos(a) - dy * math.sin(a)), round(c[1] + dx * math.sin(a) + dy * math.cos(a)))

    theta = turn * math.pi / 4
    return at(theta / 2), at(theta)


def arc_tracks(rng, board, x0, y0, x1, y1, copper, nets, pads):
    """Arc tracks: lines of segments and arcs (each arc tangent to the segments either side), from a pad of their net
    or from anywhere, now and then arcs one after the other or an arc on its own"""
    def inside(p):
        return x0 + 2 * MM <= p[0] <= x1 - 2 * MM and y0 + 2 * MM <= p[1] <= y1 - 2 * MM

    for _ in range(rng.randint(3, 8)):
        width = rng.randint(3, 8) * 50_000
        layer = rng.choice(copper)
        if pads and rng.random() < 0.5:
            pad = rng.choice(pads)
            net = pad.GetNet() if pad.GetNetCode() > 0 else rng.choice(nets)
            p = (pad.GetPosition().x, pad.GetPosition().y)
        else:
            net = rng.choice(nets)
            p = (rng.randint(x0 + 3 * MM, x1 - 3 * MM) // 50_000 * 50_000,
                 rng.randint(y0 + 3 * MM, y1 - 3 * MM) // 50_000 * 50_000)
        d = rng.randrange(8)
        for _ in range(rng.randint(1, 4)):
            if rng.random() < 0.45:
                length = rng.randint(1, 10) * 500_000
                q = (p[0] + DIRS[d][0] * length, p[1] + DIRS[d][1] * length)
                if not inside(q):
                    break
                t = pcbnew.PCB_TRACK(board)
                t.SetStart(vec(*p))
                t.SetEnd(vec(*q))
                p = q
            else:
                turn = rng.choice([1, -1, 2, -2, 3, -3])
                mid, end = arc_turn(p, d, turn, rng.randint(1, 24) * 125_000)
                if not inside(end):
                    break
                t = pcbnew.PCB_ARC(board)
                t.SetStart(vec(*p))
                t.SetMid(vec(*mid))
                t.SetEnd(vec(*end))
                p, d = end, (d + turn) % 8
            t.SetWidth(width)
            t.SetLayer(layer)
            t.SetNet(net)
            if rng.random() < 0.04:
                t.SetLocked(True)
            board.Add(t)


def custom_pad_footprints():
    """Every footprint of KiCad's libraries with a custom pad, as (library, name), in order"""
    found = []
    for lib in sorted(os.listdir(LIBRARIES)):
        if not lib.endswith(".pretty"):
            continue
        for f in sorted(os.listdir(f"{LIBRARIES}/{lib}")):
            if f.endswith(".kicad_mod"):
                with open(f"{LIBRARIES}/{lib}/{f}") as mod:
                    if " custom" in mod.read():
                        found.append((lib[:-len(".pretty")], f[:-len(".kicad_mod")]))
    return found


def make(rng, path, krng, footprints_from=FOOTPRINTS, vrng=None, arng=None, zrng=None):
    board = pcbnew.NewBoard(path)
    board.SetCopperLayerCount(rng.choice([2, 2, 4]))
    size = rng.randint(30, 70) * MM
    x0, y0 = 100 * MM, 50 * MM
    x1, y1 = x0 + size, y0 + int(size * rng.uniform(0.6, 1.0))
    outline(rng, board, x0, y0, x1, y1)
    net_classes(rng, board)
    nets = []
    for name in rng.sample(NET_NAMES, rng.randint(4, len(NET_NAMES))):
        n = pcbnew.NETINFO_ITEM(board, name)
        board.Add(n)
        nets.append(n)
    pads = []
    footprints = []
    for i in range(rng.randint(6, 18)):
        lib, name = rng.choice(footprints_from)
        fp = pcbnew.FootprintLoad(f"{LIBRARIES}/{lib}.pretty", name)
        if fp is None:
            continue
        footprints.append(fp)
        fp.SetReference(f"U{i + 1}")
        fp.SetPosition(vec(rng.randint(x0 + 4 * MM, x1 - 4 * MM), rng.randint(y0 + 4 * MM, y1 - 4 * MM)))
        fp.SetOrientationDegrees(rng.choice([0, 0, 90, 180, 270, 45, 30, round(rng.uniform(0, 360), 1)]))
        board.Add(fp)
        if rng.random() < 0.3:
            fp.Flip(fp.GetPosition(), pcbnew.FLIP_DIRECTION_TOP_BOTTOM)
        if rng.random() < 0.1:
            fp.SetLocalClearance(rng.choice([300_000, 500_000]))
        for pad in fp.Pads():
            if rng.random() < 0.75 and pad.GetAttribute() != pcbnew.PAD_ATTRIB_NPTH:
                pad.SetNet(rng.choice(nets))
            if rng.random() < 0.08:
                pad.SetLocalClearance(rng.choice([100_000, 350_000]))
            pads.append(pad)
    copper = [pcbnew.F_Cu, pcbnew.B_Cu] + ([pcbnew.In1_Cu, pcbnew.In2_Cu] if board.GetCopperLayerCount() == 4 else [])
    # tracks already there, from pad to pad mostly, and vias
    for _ in range(rng.randint(0, 8)):
        if len(pads) < 2:
            break
        a, b = rng.sample(pads, 2)
        t = pcbnew.PCB_TRACK(board)
        t.SetStart(a.GetPosition())
        t.SetEnd(b.GetPosition() if rng.random() < 0.5 else a.GetPosition() + vec(rng.randint(-8, 8) * MM, rng.randint(-8, 8) * MM))
        t.SetWidth(rng.randint(2, 8) * 50_000)
        t.SetLayer(rng.choice(copper))
        if a.GetNetCode() > 0:
            t.SetNet(a.GetNet())
        board.Add(t)
    for _ in range(rng.randint(0, 4)):
        v = pcbnew.PCB_VIA(board)
        v.SetPosition(vec(rng.randint(x0 + 3 * MM, x1 - 3 * MM), rng.randint(y0 + 3 * MM, y1 - 3 * MM)))
        d = rng.randint(5, 9) * 100_000
        v.SetWidth(pcbnew.F_Cu, d)
        v.SetDrill(d * rng.randint(4, 6) // 10)
        v.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu)
        v.SetNet(rng.choice(nets))
        board.Add(v)
    # drawings on copper
    for _ in range(rng.choice([0, 0, 1, 2])):
        s = pcbnew.PCB_SHAPE(board)
        kind = rng.choice([pcbnew.SHAPE_T_SEGMENT, pcbnew.SHAPE_T_RECTANGLE, pcbnew.SHAPE_T_CIRCLE])
        s.SetShape(kind)
        s.SetLayer(rng.choice(copper))
        s.SetWidth(rng.randint(1, 6) * 50_000)
        cx, cy = rng.randint(x0 + 5 * MM, x1 - 5 * MM), rng.randint(y0 + 5 * MM, y1 - 5 * MM)
        if kind == pcbnew.SHAPE_T_CIRCLE:
            s.SetCenter(vec(cx, cy))
            s.SetEnd(vec(cx + rng.randint(1, 3) * MM, cy))
        else:
            s.SetStart(vec(cx, cy))
            s.SetEnd(vec(cx + rng.randint(1, 6) * MM, cy + rng.randint(-4, 4) * MM))
        s.SetFilled(kind != pcbnew.SHAPE_T_SEGMENT and rng.random() < 0.5)
        if rng.random() < 0.5:
            s.SetNet(rng.choice(nets))
        board.Add(s)
    # keepout zones (from a random sequence of their own, so that the rest of each board is as it was without them)
    keepouts(krng, board, x0, y0, x1, y1, copper, footprints)
    # blind, buried and micro vias (the same)
    if vrng is not None:
        layered_vias(vrng, board, x0, y0, x1, y1, nets)
    # arc tracks (the same)
    if arng is not None:
        plated = [p for p in pads if p.GetAttribute() != pcbnew.PAD_ATTRIB_NPTH]
        arc_tracks(arng, board, x0, y0, x1, y1, copper, nets, plated)
    # copper zones, filled (the same)
    if zrng is not None and copper_zones(zrng, board, x0, y0, x1, y1, copper, nets):
        board.BuildConnectivity()
        pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    pcbnew.SaveBoard(path, board)


# differential pairs' nets, as KiCad tells them (a last P or N, + or -), and other nets
PAIR_NETS = [("USB_D+", "USB_D-"), ("LVDS0_P", "LVDS0_N"), ("CLK_P", "CLK_N"), ("TX_P_1", "TX_N_1")]
PAIR_ENDS = [("Connector_PinHeader_2.54mm", "PinHeader_1x04_P2.54mm_Vertical"),
             ("Connector_PinHeader_1.27mm", "PinHeader_1x04_P1.27mm_Vertical")]
PAIR_CHIPS = [("Package_SO", "SOIC-8_3.9x4.9mm_P1.27mm"), ("Package_SO", "TSSOP-16_4.4x5mm_P0.65mm")]


def make_pairs(rng, path):
    """A board with differential pairs to route: a connector on the left, a chip on the right, two pairs of their
    pads (pins 1 and 2, 3 and 4) of two pairs' nets, in a net class of its own for some (its own diff pair width and
    gap); parts and tracks of other nets between, on two or four layers"""
    board = pcbnew.NewBoard(path)
    board.SetCopperLayerCount(rng.choice([2, 2, 4]))
    x0, y0 = 100 * MM, 50 * MM
    x1, y1 = x0 + rng.randint(30, 45) * MM, y0 + rng.randint(25, 35) * MM
    edge = pcbnew.PCB_SHAPE(board)
    edge.SetShape(pcbnew.SHAPE_T_RECTANGLE)
    edge.SetLayer(pcbnew.Edge_Cuts)
    edge.SetWidth(100_000)
    edge.SetStart(vec(x0, y0))
    edge.SetEnd(vec(x1, y1))
    board.Add(edge)
    ds = board.GetDesignSettings()
    ns = ds.m_NetSettings
    default = ns.GetDefaultNetclass()
    default.SetClearance(rng.choice([150_000, 200_000]))
    default.SetDiffPairWidth(rng.choice([200_000, 250_000]))
    default.SetDiffPairGap(rng.choice([250_000, 300_000]))
    default.SetDiffPairViaGap(250_000)
    fast = pcbnew.NETCLASS("HighSpeed")
    fast.SetClearance(150_000)
    fast.SetDiffPairWidth(rng.choice([120_000, 150_000]))
    fast.SetDiffPairGap(rng.choice([150_000, 180_000]))
    fast.SetDiffPairViaGap(200_000)
    fast.SetPriority(0)
    ns.SetNetclass("HighSpeed", fast)
    ns.SetNetclassPatternAssignment("USB*", "HighSpeed")
    ns.SetNetclassPatternAssignment("LVDS*", "HighSpeed")
    ds.m_MinClearance = rng.choice([0, 100_000])
    nets = {}
    for name in [n for pair in rng.sample(PAIR_NETS, 2) for n in pair] + ["GND", "VCC", "SIG1"]:
        nets[name] = pcbnew.NETINFO_ITEM(board, name)
        board.Add(nets[name])
    pairs = [n for n in nets if n not in ("GND", "VCC", "SIG1")]
    singles = [nets["GND"], nets["VCC"], nets["SIG1"]]

    def place(lib, name, x, y, ref):
        fp = pcbnew.FootprintLoad(f"{LIBRARIES}/{lib}.pretty", name)
        fp.SetReference(ref)
        fp.SetPosition(vec(x, y))
        fp.SetOrientationDegrees(rng.choice([0, 90, 180, 270]))
        board.Add(fp)
        return fp

    ym = (y0 + y1) // 2
    connector = place(*rng.choice(PAIR_ENDS), x0 + 5 * MM, ym + rng.randint(-4, 4) * MM, "J1")
    chip = place(*rng.choice(PAIR_CHIPS), x1 - 6 * MM, ym + rng.randint(-4, 4) * MM, "U1")
    for fp in (connector, chip):
        for pad in fp.Pads():
            n = int(pad.GetNumber()) if pad.GetNumber().isdigit() else 0
            if 1 <= n <= 4:
                pad.SetNet(nets[pairs[n - 1]])
            elif rng.random() < 0.6:
                pad.SetNet(rng.choice(singles))
    # parts and tracks of other nets in the way
    for i in range(rng.randint(1, 4)):
        fp = place("Resistor_SMD", "R_0603_1608Metric", rng.randint(x0 + 12 * MM, x1 - 14 * MM),
                   rng.randint(y0 + 4 * MM, y1 - 4 * MM), f"R{i + 1}")
        for pad in fp.Pads():
            pad.SetNet(rng.choice(singles))
    copper = [pcbnew.F_Cu, pcbnew.B_Cu] + ([pcbnew.In1_Cu, pcbnew.In2_Cu] if board.GetCopperLayerCount() == 4 else [])
    a, b = connector.GetPosition(), chip.GetPosition()
    for _ in range(rng.randint(2, 5)):
        # (across the way from the connector to the chip, mostly short enough to be shoved, on the top mostly)
        f = rng.uniform(0.3, 0.7)
        x, y = a.x + int((b.x - a.x) * f), a.y + int((b.y - a.y) * f) + rng.randint(-2, 2) * MM
        half = rng.choice([1, 1, 2, 8]) * MM
        t = pcbnew.PCB_TRACK(board)
        t.SetStart(vec(x, max(y0 + 2 * MM, y - half)))
        t.SetEnd(vec(x + rng.choice([0, 0, MM, -MM]), min(y1 - 2 * MM, y + half)))
        t.SetWidth(rng.randint(2, 5) * 50_000)
        t.SetLayer(pcbnew.F_Cu if rng.random() < 0.7 else rng.choice(copper))
        t.SetNet(rng.choice(singles))
        board.Add(t)
    pcbnew.SaveBoard(path, board)


def main():
    args = sys.argv[1:]
    custom = "--custom-pads" in args
    pairs = "--pairs" in args
    arcs = "--arcs" in args
    args = [a for a in args if a not in ("--custom-pads", "--pairs", "--arcs")]
    out, count = args[0], int(args[1])
    seed = int(args[2]) if len(args) > 2 else 20261016
    footprints_from = custom_pad_footprints() if custom else FOOTPRINTS
    rng = random.Random(seed)
    os.makedirs(out, exist_ok=True)
    here = os.path.dirname(os.path.abspath(__file__))
    for n in range(count):
        kind = "pairs" if pairs else "custom" if custom else "random"
        path = os.path.abspath(f"{out}/{kind}{'-arcs' if arcs else ''}-{seed}-{n}.kicad_pcb")
        if pairs:
            make_pairs(rng, path)
        else:
            make(rng, path, random.Random(f"keepouts-{seed}-{n}"), footprints_from, random.Random(f"vias-{seed}-{n}"),
                 random.Random(f"arcs-{seed}-{n}") if arcs else None, random.Random(f"zones-{seed}-{n}"))
        subprocess.run([sys.executable, f"{here}/board-scene.py", path, path[:-len(".kicad_pcb")] + ".json"], check=True,
                       stderr=subprocess.DEVNULL)
    print(f"{out}: {count} boards")


if __name__ == "__main__":
    main()
