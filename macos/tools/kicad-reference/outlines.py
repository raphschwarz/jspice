#!/usr/bin/env python3
"""Boards whose outlines take KiCad's outline check (DRCE_INVALID_OUTLINE, the miscellaneous DRC provider's
testOutline) down its ways, for checking the port's (KiCadRouter's BoardDRC.checkOutline) against: each a board of
drawings on Edge.Cuts, the board's own and footprints', saved as OUT/NAME.kicad_pcb with kicad-cli's report of it
next to it as OUT/NAME.drc (drc.py's), with no project of its own. No edges at all; drawings too small to see; closed outlines crossing; open
chains that do not close, close within the chaining distance, branch, double back or run over themselves; arcs,
circles, curves, rounded rectangles and polygons, some filled; footprints' outlines that are holes in the board's
(round pads outside them, or more than one) and those that are not (round their pads, or not closed, or crossing
themselves), turned off square; outlines apart.

(Which drawing KiCad names for a loop of open drawings crossing another outline is the one of the loop it holds at
the lowest address, its open drawings a std::set of pointers: mostly the first read, but not where the allocator
hands a later one memory freed earlier, as it does for a board of one footprint and a loop of lines, whose third
line read KiCad then names. The port takes the first read, as KiCad does for each loop here.)

    outlines.py OUT
"""

import os
import subprocess
import sys

import pcbnew

MM = 1_000_000


def box(x0, y0, x1, y1, w=0.1):
    return [("seg", (x0, y0), (x1, y0), w), ("seg", (x1, y0), (x1, y1), w), ("seg", (x1, y1), (x0, y1), w),
            ("seg", (x0, y1), (x0, y0), w)]


RECT = [("rect", (0, 0), (40, 30), 0, 0.1)]

# (name, the board's drawings, footprints: (reference, position, orientation, drawings, pads (x, y, size)))
CASES = [
    ("no-edges", [], []),
    ("closed-rect", RECT, []),
    ("tiny-segment-alone", [("seg", (5, 5), (5.0005, 5), 0.1)], []),
    ("tiny-segment", RECT + [("seg", (50, 5), (50.0008, 5), 0.1)], []),
    ("tiny-circle", RECT + [("circle", (20, 15), 0.0009, 0.1)], []),
    ("tiny-arc", RECT + [("arc", (50, 10), (50.0003, 10.0002), (50.0006, 10), 0.1)], []),
    ("tiny-rect", RECT + [("rect", (60, 10), (60.0006, 10.0006), 0, 0.1)], []),
    ("rects-crossing", [("rect", (0, 0), (40, 30), 0, 0.1), ("rect", (30, 20), (60, 50), 0, 0.1)], []),
    ("circles-crossing", RECT + [("circle", (10, 10), 3, 0.1), ("circle", (13, 10), 3, 0.1)], []),
    ("circle-crossing-rect", RECT + [("circle", (40, 15), 5, 0.1)], []),
    ("open-chain", box(0, 0, 40, 30)[:3], []),
    ("chain-closes-near", [("seg", (0, 0), (40, 0), 0.1), ("seg", (40, 0), (40, 30), 0.1),
                           ("seg", (40, 30), (0, 30), 0.1), ("seg", (0, 30), (0.006, 0.005), 0.1)], []),
    ("chain-gap", [("seg", (0, 0), (40, 0), 0.1), ("seg", (40, 0), (40, 30), 0.1),
                   ("seg", (40, 30), (0, 30), 0.1), ("seg", (0, 30), (0, 0.5), 0.1)], []),
    ("chain-branch", box(0, 0, 40, 30) + [("seg", (40, 30), (50, 40), 0.1)], []),
    ("chain-duplicate", box(0, 0, 40, 30) + [("seg", (0, 0), (40, 0), 0.1)], []),
    ("chain-bowtie", [("seg", (0, 0), (40, 30), 0.1), ("seg", (40, 30), (40, 0), 0.1),
                      ("seg", (40, 0), (0, 30), 0.1), ("seg", (0, 30), (0, 0), 0.1)], []),
    ("lone-segment", RECT + [("seg", (50, 5), (60, 5), 0.1)], []),
    ("two-open", [("seg", (0, 0), (10, 0), 0.1), ("seg", (0, 5), (10, 5), 0.2)], []),
    ("arcs-closed", [("seg", (5, 0), (35, 0), 0.1), ("arc", (35, 0), (38.535534, 1.464466), (40, 5), 0.1),
                     ("seg", (40, 5), (40, 30), 0.1), ("seg", (40, 30), (0, 30), 0.1), ("seg", (0, 30), (0, 5), 0.1),
                     ("arc", (5, 0), (1.464466, 1.464466), (0, 5), 0.1)], []),
    ("arc-gap", [("seg", (5, 0), (35, 0), 0.1), ("arc", (35, 0), (38.535534, 1.464466), (40, 5), 0.1),
                 ("seg", (40, 5.3), (40, 30), 0.1), ("seg", (40, 30), (0, 30), 0.1), ("seg", (0, 30), (0, 5), 0.1),
                 ("arc", (5, 0), (1.464466, 1.464466), (0, 5), 0.1)], []),
    ("arcs-apart", [("arc", (0, 0), (5, -5), (10, 0), 0.1), ("arc", (12, 3), (17, 8), (22, 3), 0.15)], []),
    ("curve-gap", [("seg", (0, 0), (40, 0), 0.1), ("seg", (40, 0), (40, 30), 0.1),
                   ("curve", (40, 30.4), (30, 40), (10, 20), (0, 30), 0.1), ("seg", (0, 30), (0, 0), 0.1)], []),
    ("curve-closed", [("seg", (0, 0), (40, 0), 0.1), ("seg", (40, 0), (40, 30), 0.1),
                      ("curve", (40, 30), (30, 40), (10, 20), (0, 30), 0.1), ("seg", (0, 30), (0, 0), 0.1)], []),
    ("rounded-rect-crossing", [("rect", (0, 0), (40, 30), 4, 0.1), ("seg", (35, 25), (45, 35), 0.1)], []),
    ("rounded-rects-crossing", [("rect", (0, 0), (40, 30), 4, 0.1), ("rect", (36, 26), (60, 50), 3, 0.12)], []),
    ("poly-bowtie", [("poly", [(0, 0), (40, 30), (40, 0), (0, 30)], 0.1)], []),
    ("poly-bowtie-rect", [("poly", [(0, 0), (40, 30), (40, 0), (0, 30)], 0.1), ("rect", (50, 0), (60, 10), 0, 0.1)], []),
    ("poly-crossing-rect", RECT + [("poly", [(30, 10), (50, 10), (50, 20), (30, 20)], 0.1)], []),
    ("filled-circle-gap", RECT + [("circle", (50, 15), 3, 0.1, True), ("seg", (60, 0), (70, 0), 0.1)], []),
    ("filled-crossing", RECT + [("circle", (40, 15), 3, 0.1, True), ("rect", (35, 25), (45, 35), 0, 0.1, True)], []),
    ("disjoint", [("rect", (0, 0), (20, 20), 0, 0.1), ("rect", (30, 0), (50, 20), 0, 0.1),
                  ("circle", (10, 10), 3, 0.1)], []),
    ("nested-crossing", [("rect", (0, 0), (40, 30), 0, 0.1), ("rect", (5, 5), (20, 20), 0, 0.1),
                         ("rect", (15, 15), (30, 25), 0, 0.1)], []),
    ("fp-hole-pad-outside", RECT, [("H1", (20, 15), 0, box(-3, -3, 3, 3), [(5, 0, 1)])]),
    ("fp-not-hole-pad-inside", RECT, [("H1", (20, 15), 0, box(-3, -3, 3, 3), [(0, 0, 1)])]),
    ("fp-two-outlines", RECT, [("H1", (20, 15), 0, box(-6, -3, -1, 3) + box(1, -3, 6, 3), [])]),
    ("fp-hole-crossing-edge", RECT, [("H1", (38, 15), 0, box(-3, -3, 3, 3), [(5, 5, 1)])]),
    ("fp-not-hole-crossing-edge", RECT, [("H1", (38, 15), 0, box(-3, -3, 3, 3), [])]),
    ("fp-open", RECT, [("U1", (20, 15), 0, box(-3, -3, 3, 3)[:3], [(0, 0, 1)])]),
    ("fp-open-hole-pad", RECT, [("U1", (20, 15), 0, box(-3, -3, 3, 3)[:3], [(5, 0, 1)])]),
    ("fp-bowtie", RECT, [("U1", (20, 15), 0, [("seg", (-3, -3), (3, 3), 0.1), ("seg", (3, 3), (3, -3), 0.1),
                                              ("seg", (3, -3), (-3, 3), 0.1), ("seg", (-3, 3), (-3, -3), 0.1)],
                          [(5, 0, 1)])]),
    ("fp-outline-only", [], [("U1", (20, 15), 0, box(-10, -8, 10, 8), [(0, 0, 1)])]),
    ("fp-outline-gap", [("seg", (0, 0), (40, 0), 0.1), ("seg", (40, 0), (40, 30), 0.1), ("seg", (40, 30), (0, 30), 0.1)],
     [("U1", (0, 15), 0, [("seg", (0, 15), (0, -14), 0.1)], [])]),
    ("fp-rotated", RECT, [("U1", (20, 15), 33, [("rect", (-3, -2), (3, 2), 0, 0.1)], [(6, 0, 1)]),
                          ("U2", (10, 10), 45, [("rect", (-2, -1), (2, 1), 0.5, 0.1)], []),
                          ("U3", (30, 20), 90, box(-2, -2, 2, 2)[:3], [])]),
    ("fp-rotated-crossing", RECT, [("U1", (40, 15), 33, [("rect", (-3, -2), (3, 2), 0, 0.1)], []),
                                   ("U2", (0, 15), 45, [("rect", (-2, -1), (2, 1), 0.5, 0.1)], [])]),
    ("chains-crossing", box(0, 0, 40, 30) + box(30, 20, 60, 50, w=0.15), []),
    ("fp-two-open", RECT, [("U1", (10, 10), 0, box(-2, -2, 2, 2)[:2], []), ("U2", (30, 20), 0, box(-2, -2, 2, 2)[1:], [])]),
    ("fp-arcs", RECT, [("U1", (20, 15), 20, [("arc", (-3, 0), (0, -3), (3, 0), 0.1), ("arc", (3, 0.2), (0, 3), (-3, 0), 0.1)],
                        [(0, 0, 1)])]),
]


def v(p, at=(0, 0)):
    return pcbnew.VECTOR2I(int(round((p[0] + at[0]) * MM)), int(round((p[1] + at[1]) * MM)))


def shape(parent, d, at=(0, 0)):
    """A drawing on Edge.Cuts; a footprint's in its own coordinates, placed at `at`"""
    s = pcbnew.PCB_SHAPE(parent)
    kind = d[0]
    filled = False
    if kind == "seg":
        s.SetShape(pcbnew.SHAPE_T_SEGMENT)
        s.SetStart(v(d[1], at))
        s.SetEnd(v(d[2], at))
        w = d[3]
    elif kind == "arc":
        s.SetShape(pcbnew.SHAPE_T_ARC)
        s.SetArcGeometry(v(d[1], at), v(d[2], at), v(d[3], at))
        w = d[4]
    elif kind == "circle":
        s.SetShape(pcbnew.SHAPE_T_CIRCLE)
        s.SetStart(v(d[1], at))
        s.SetEnd(v((d[1][0] + d[2], d[1][1]), at))
        w = d[3]
        filled = len(d) > 4 and d[4]
    elif kind == "rect":
        s.SetShape(pcbnew.SHAPE_T_RECTANGLE)
        s.SetStart(v(d[1], at))
        s.SetEnd(v(d[2], at))
        s.SetCornerRadius(int(round(d[3] * MM)))
        w = d[4]
        filled = len(d) > 5 and d[5]
    elif kind == "poly":
        s.SetShape(pcbnew.SHAPE_T_POLY)
        s.SetPolyPoints([v(p, at) for p in d[1]])
        w = d[2]
    elif kind == "curve":
        s.SetShape(pcbnew.SHAPE_T_BEZIER)
        s.SetStart(v(d[1], at))
        s.SetBezierC1(v(d[2], at))
        s.SetBezierC2(v(d[3], at))
        s.SetEnd(v(d[4], at))
        s.RebuildBezierToSegmentsPointsList(5000)
        w = d[5]
    s.SetWidth(int(round(w * MM)))
    if filled:
        s.SetFilled(True)
    s.SetLayer(pcbnew.Edge_Cuts)
    return s


def draw(path, drawings, footprints):
    board = pcbnew.NewBoard(path)
    origin = (100, 50)
    for (ref, at, angle, shapes, pads) in footprints:
        fp = pcbnew.FOOTPRINT(board)
        fp.SetReference(ref)
        pos = (origin[0] + at[0], origin[1] + at[1])
        fp.SetPosition(v(pos))
        board.Add(fp)
        for d in shapes:
            fp.Add(shape(fp, d, pos))
        for i, (x, y, size) in enumerate(pads):
            p = pcbnew.PAD(fp)
            p.SetNumber(str(i + 1))
            p.SetAttribute(pcbnew.PAD_ATTRIB_SMD)
            p.SetShape(pcbnew.PAD_SHAPE_RECT)
            p.SetSize(v((size, size)))
            p.SetLayerSet(p.SMDMask())
            p.SetPosition(v((pos[0] + x, pos[1] + y)))
            fp.Add(p)
        if angle:
            fp.SetOrientationDegrees(angle)
    for d in drawings:
        board.Add(shape(board, d, origin))
    pcbnew.SaveBoard(path, board)


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    drc = os.path.join(os.path.dirname(os.path.abspath(__file__)), "drc.py")
    for name, drawings, footprints in CASES:
        path = os.path.join(out, name + ".kicad_pcb")
        draw(path, drawings, footprints)
        # (no project: KiCad's defaults, the port's where it has none)
        for ext in (".kicad_pro", ".kicad_prl"):
            if os.path.exists(os.path.join(out, name + ext)):
                os.remove(os.path.join(out, name + ext))
        subprocess.run([sys.executable, drc, path], check=True)


if __name__ == "__main__":
    main()
