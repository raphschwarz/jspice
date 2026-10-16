#!/usr/bin/env python3
"""Random boards made by KiCad itself (its pcbnew module), from KiCad's own footprint libraries, to check the router's
world of a board against KiCad's: footprints with every kind of pad (rectangles, rounded and cut corners, ovals,
trapezoids, circles, unplated holes, custom pads), turned and flipped, on two or four layers; nets in net classes (by
pattern, of different priorities, regular expressions among them), pads' and footprints' own clearances; tracks and
vias; drawings on copper; outlines with rounded corners and round cut-outs. Each board is saved (its .kicad_pcb and
.kicad_pro), and board-scene.py run on it (KiCad reading it afresh) writes what KiCad's router sees of it.

    boards.py OUTDIR COUNT [SEED]
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


def make(rng, path):
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
    for i in range(rng.randint(6, 18)):
        lib, name = rng.choice(FOOTPRINTS)
        fp = pcbnew.FootprintLoad(f"{LIBRARIES}/{lib}.pretty", name)
        if fp is None:
            continue
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
    pcbnew.SaveBoard(path, board)


def main():
    out, count = sys.argv[1], int(sys.argv[2])
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 20261016
    rng = random.Random(seed)
    os.makedirs(out, exist_ok=True)
    here = os.path.dirname(os.path.abspath(__file__))
    for n in range(count):
        path = os.path.abspath(f"{out}/random-{seed}-{n}.kicad_pcb")
        make(rng, path)
        subprocess.run([sys.executable, f"{here}/board-scene.py", path, path[:-len(".kicad_pcb")] + ".json"], check=True,
                       stderr=subprocess.DEVNULL)
    print(f"{out}: {count} boards")


if __name__ == "__main__":
    main()
