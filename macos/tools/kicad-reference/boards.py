#!/usr/bin/env python3
"""Random boards made by KiCad itself (its pcbnew module), from KiCad's own footprint libraries, to check the router's
world of a board against KiCad's: footprints with every kind of pad (rectangles, rounded and cut corners, ovals,
trapezoids, circles, unplated holes, custom pads), turned and flipped, on two or four layers; nets in net classes (by
pattern, of different priorities, regular expressions among them), pads' and footprints' own clearances; tracks and
vias; drawings on copper; outlines with rounded corners and round cut-outs; keepout zones (rule areas) of several
shapes, some with holes, some in footprints. Each board is saved (its .kicad_pcb and .kicad_pro), and board-scene.py
run on it (KiCad reading it afresh) writes what KiCad's router sees of it. With --custom-pads, the footprints are
drawn from every footprint of KiCad's libraries with a custom pad (their primitives: polygons, lines, arcs, circles
and rings, rectangles, filled or outlined, of some width or none) instead.

    boards.py [--custom-pads] OUTDIR COUNT [SEED]
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


def make(rng, path, krng, footprints_from=FOOTPRINTS):
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
    pcbnew.SaveBoard(path, board)


def main():
    args = sys.argv[1:]
    custom = "--custom-pads" in args
    args = [a for a in args if a != "--custom-pads"]
    out, count = args[0], int(args[1])
    seed = int(args[2]) if len(args) > 2 else 20261016
    footprints_from = custom_pad_footprints() if custom else FOOTPRINTS
    rng = random.Random(seed)
    os.makedirs(out, exist_ok=True)
    here = os.path.dirname(os.path.abspath(__file__))
    for n in range(count):
        path = os.path.abspath(f"{out}/{'custom' if custom else 'random'}-{seed}-{n}.kicad_pcb")
        make(rng, path, random.Random(f"keepouts-{seed}-{n}"), footprints_from)
        subprocess.run([sys.executable, f"{here}/board-scene.py", path, path[:-len(".kicad_pcb")] + ".json"], check=True,
                       stderr=subprocess.DEVNULL)
    print(f"{out}: {count} boards")


if __name__ == "__main__":
    main()
