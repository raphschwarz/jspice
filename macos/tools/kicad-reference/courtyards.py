#!/usr/bin/env python3
"""KiCad's courtyards of boards' footprints, for checking the port's (KiCadRouter's BoardDRC.courtyards) against: each
footprint's FOOTPRINT::BuildCourtyardCaches, through KiCad's pcbnew Python module, its front and back courtyards
(each polygon's outline and holes, their points, and how many arcs they have, which is none: KiCad makes its
courtyards of points only), the width it gives the first outline, and whether it found either malformed, written
next to the board as BOARD.courtyards (JSON; named so that a folder's .json files are its boards' scenes only), the
footprints by their uuids.

    courtyards.py BOARD.kicad_pcb...

With --draw, a board of footprints whose courtyards are drawn to take KiCad's conversion of drawings to polygons
(ConvertOutlineToPolygon) down its other ways, saved and then its courtyards written as above: outlines with holes
and islands in the holes, holes crossing each other, outlines crossing, chains of lines that do not close or close
within the chaining distance, that cross themselves or branch, arcs (some drawn the other way round), circles,
curves, rectangles with rounded corners, turned off square, polygons, lines of no length, a line joining a
rectangle, a chain through the origin, where a polygon's ends are; front and back, of mixed widths, turned and
flipped (Tests/KiCadRouterTests/Fixtures/courtyards/drawn.kicad_pcb is one). With --random, COUNT footprints of
random courtyards instead: outlines of lines, arcs and curves, some of them drawn the other way round, in no order,
their ends now and then a little apart (within the chaining distance or just beyond it), with circles, rectangles,
polygons and other such outlines inside them, across them or beside them, on the front or the back, turned and
flipped; and every other arc's start and end swapped in the file KiCad saves (as other tools may write them, the
wrong way round), which KiCad swaps back as it reads them, working out their middles again.

    courtyards.py --draw OUT.kicad_pcb
    courtyards.py --random OUT.kicad_pcb COUNT [SEED]
"""

import json
import math
import os
import random
import re
import sys

import pcbnew

MM = 1_000_000


def chain(c):
    return {"points": [[c.CPoint(i).x, c.CPoint(i).y] for i in range(c.PointCount())],
            "closed": c.IsClosed(), "arcs": c.ArcCount()}


def polygons(ps):
    return [{"outline": chain(ps.Outline(i)), "holes": [chain(ps.Hole(i, j)) for j in range(ps.HoleCount(i))]}
            for i in range(ps.OutlineCount())]


def side(fp, layer):
    ps = fp.GetCachedCourtyard(layer)
    return {"polygons": polygons(ps), "width": ps.Outline(0).Width() if ps.OutlineCount() > 0 else 0}


def write(board):
    b = pcbnew.LoadBoard(board)
    out = {}
    for fp in b.GetFootprints():
        fp.BuildCourtyardCaches()
        flags = fp.GetFlags()
        out[fp.m_Uuid.AsString()] = {
            "reference": fp.GetReference(),
            "front": side(fp, pcbnew.F_CrtYd),
            "back": side(fp, pcbnew.B_CrtYd),
            "malformedFront": bool(flags & pcbnew.MALFORMED_F_COURTYARD),
            "malformedBack": bool(flags & pcbnew.MALFORMED_B_COURTYARD),
        }
    with open(os.path.splitext(board)[0] + ".courtyards", "w") as f:
        json.dump(out, f, sort_keys=True)
        f.write("\n")


# --- drawn courtyards: each shape in millimetres about its footprint, ("F" or "B", width, kind, points...)

def box(x0, y0, x1, y1, layer="F", w=0.05):
    return [(layer, w, "seg", (x0, y0), (x1, y0)), (layer, w, "seg", (x1, y0), (x1, y1)),
            (layer, w, "seg", (x1, y1), (x0, y1)), (layer, w, "seg", (x0, y1), (x0, y0))]


def rounded(x0, y0, x1, y1, r, flipped_arcs=(), layer="F", w=0.05):
    """A box of lines with its corners rounded by arcs, those in `flipped_arcs` drawn end to start"""
    s = 0.5 ** 0.5
    corners = [((x1 - r, y0), (x1 - r + r * s, y0 + r - r * s), (x1, y0 + r)),
               ((x1, y1 - r), (x1 - r + r * s, y1 - r + r * s), (x1 - r, y1)),
               ((x0 + r, y1), (x0 + r - r * s, y1 - r + r * s), (x0, y1 - r)),
               ((x0, y0 + r), (x0 + r - r * s, y0 + r - r * s), (x0 + r, y0))]
    out = []
    for i, (a, m, b) in enumerate(corners):
        out.append((layer, w, "arc", b, m, a) if i in flipped_arcs else (layer, w, "arc", a, m, b))
        nxt = corners[(i + 1) % 4][0]
        out.append((layer, w, "seg", b, nxt))
    return out


CASES = [
    # (shapes, orientation in degrees, flipped)
    (box(-2, -1, 2, 1), 0, False),
    (box(-3, -2, 3, 2) + [("F", 0.05, "circle", (0, 0), 1)], 0, False),
    (box(-4, -3, 4, 3) + box(-3, -2, 3, 2) + box(-1, -1, 1, 1), 90, False),
    (box(-2, -1, 1, 1) + box(-1, -2, 2, 0), 0, False),
    (box(-5, -4, 5, 4) + box(-3, -2, 0, 2) + box(-1, -1, 2, 1), 30, False),
    (box(-2, -1, 2, 1)[:3], 0, False),
    ([("F", 0.05, "seg", (-2, -1), (2, -1)), ("F", 0.05, "seg", (2, -1), (2, 1)),
      ("F", 0.05, "seg", (2, 1), (-2, 1)), ("F", 0.05, "seg", (-2, 1), (-2, -0.99))], 0, False),
    ([("F", 0.05, "seg", (-2, -1), (2, -1)), ("F", 0.05, "seg", (2, 1), (2, -1.015)),
      ("F", 0.05, "seg", (2, 1), (-2, 1)), ("F", 0.05, "seg", (-2.012, 1), (-2, -1))], 180, False),
    (rounded(-3, -2, 3, 2, 0.8), 0, False),
    (rounded(-3, -2, 3, 2, 0.8, flipped_arcs=(1, 2)), 45, False),
    (rounded(-2.5, -1.5, 2.5, 1.5, 1.0, flipped_arcs=(0,)), 33.3, True),
    ([("F", 0.05, "circle", (0.3, -0.2), 1.5)], 0, False),
    ([("F", 0.05, "circle", (0, 0), 2), ("F", 0.05, "circle", (0, 0), 1)], 270, False),
    ([("F", 0.05, "arc", (-2, 0), (0, -2), (2, 0)), ("F", 0.05, "arc", (2, 0), (0, 2), (-2, 0))], 0, False),
    ([("F", 0.05, "rect", (-2, -1), (2, 1), 0)], 0, False),
    ([("F", 0.05, "rect", (-2, -1), (2, 1), 0.5)], 90, False),
    ([("F", 0.05, "rect", (2, 1), (-2, -1), 0.4)], 0, True),
    ([("F", 0.05, "rect", (-2, -1), (2, 1), 0)], 30, False),
    ([("F", 0.05, "rect", (2, -1), (-2, 1), 0)], 33.3, True),
    ([("F", 0.05, "rect", (-2, -1), (2, 1), 0.4)], 60, False),
    ([("F", 0.05, "rect", (-2, -1), (2, 1), 0), ("F", 0.05, "rect", (-1, -0.5), (1, 0.5), 0)], 0, False),
    ([("F", 0.05, "poly", [(-2, -1), (2, -1.5), (2.5, 1), (0, 2), (-2.2, 0.8)])], 0, False),
    ([("F", 0.05, "poly", [(-2, -1), (2, -1), (2, 1), (-2, 1)]), ("F", 0.05, "circle", (0, 0), 0.5)], 45, False),
    ([("F", 0.05, "seg", (-2, 1), (-2, -1)), ("F", 0.05, "curve", (-2, -1), (-1, -3), (1, -3), (2, -1)),
      ("F", 0.05, "seg", (2, -1), (2, 1)), ("F", 0.05, "seg", (2, 1), (-2, 1))], 0, False),
    ([("F", 0.05, "curve", (-2, 0), (-1, -3), (1, 3), (2, 0)), ("F", 0.05, "curve", (2, 0), (2, 2.5), (-2, 2.5), (-2, 0))],
     20, False),
    ([("F", 0.05, "seg", (-2, -1), (2, 1)), ("F", 0.05, "seg", (2, 1), (2, -1)),
      ("F", 0.05, "seg", (2, -1), (-2, 1)), ("F", 0.05, "seg", (-2, 1), (-2, -1))], 0, False),
    ([("F", 0.05, "seg", (-2, -1), (0, -1)), ("F", 0.05, "seg", (0, -1), (0, -2)), ("F", 0.05, "seg", (0, -1), (2, -1)),
      ("F", 0.05, "seg", (2, -1), (2, 1)), ("F", 0.05, "seg", (2, 1), (-2, 1)), ("F", 0.05, "seg", (-2, 1), (-2, -1))],
     0, False),
    ([("F", 0.05, "seg", (-2, -1), (2, -1)), ("F", 0.1, "seg", (2, -1), (2, 1)), ("F", 0.1, "seg", (2, 1), (-2, 1)),
      ("F", 0.05, "seg", (-2, 1), (-2, -1)), ("B", 0.12, "circle", (0, 0), 2.5)], 0, False),
    ([("F", 0.05, "seg", (3, 2), (2, 1)), ("F", 0.05, "rect", (-2, -1), (2, 1), 0)], 0, False),
    ([("F", 0.05, "rect", (-2, -1), (2, 1), 0), ("F", 0.05, "seg", (2, 1), (3, 2))], 0, False),
    (box(-2, -1, 2, 1) + [("F", 0.05, "seg", (2, 1), (2, 1))], 0, False),
    ([("F", 0.05, "rect", (-2, -1), (2, 1), 0), ("F", 0.05, "rect", (-2, -1), (2, 1), 0)], 0, False),
    (box(-2, -1, 2, 1) + [("F", 0.05, "seg", (-2, -1), (2, -1))], 0, False),
    (box(-3, -2, 3, 2, w=0) + box(-1, -1, 1, 1, w=0.2), 0, True),
    (box(-2, -1, 2, 1, layer="B") + box(-3, -2, 3, 2, layer="F"), 0, True),
    ([], 0, False),
    (box(-4, -3, 4, 3) + rounded(-3, -2, 0.5, 2, 0.5) + [("F", 0.05, "circle", (1.5, 0), 1)], 0, False),
    (box(-4, -3, 4, 3) + box(-3, -2, 3, 2) + box(-2, -1, 2, 1) + box(-1, -0.5, 1, 0.5), 0, False),
    (box(-4, -3, 0, 3) + box(0, -3, 4, 3), 0, False),
    (box(-4, -3, 4, 3) + [("F", 0.05, "circle", (-1, 0), 1.2), ("F", 0.05, "circle", (1, 0), 1.2)], 0, False),
]

# a chain through the board's origin, where a polygon drawn as one has its ends (its start and end, never set)
ORIGIN_CASE = ([("F", 0.05, "seg", (0, 0), (2, 0)), ("F", 0.05, "seg", (2, 0), (1, 2)), ("F", 0.05, "seg", (1, 2), (0, 0)),
                ("F", 0.05, "poly", [(3, 3), (5, 3), (5, 5), (3, 5)])], 0, False)


def random_outline(rng, layer, cx, cy, size):
    """A closed outline of lines, arcs and curves round (cx, cy), its shapes shuffled, some turned round, some of
    their ends moved a little"""
    n = rng.randint(3, 8)
    angles = sorted(rng.uniform(0, 2 * math.pi) for _ in range(n))
    pts = [(cx + size * rng.uniform(0.5, 1) * math.cos(a), cy + size * rng.uniform(0.5, 1) * math.sin(a)) for a in angles]
    if rng.random() < 0.2:
        pts = [(round(x * 4) / 4, round(y * 4) / 4) for x, y in pts]
    width = rng.choice([0.05, 0.05, 0.05, 0.1, 0.12, 0])
    shapes = []
    for i in range(n):
        a, b = pts[i], pts[(i + 1) % n]
        if rng.random() < 0.25:
            # (an end moved: within 20 µm, or a little beyond)
            d = rng.choice([0.001, 0.01, 0.0199, 0.021, 0.03]) * rng.random()
            t = rng.uniform(0, 2 * math.pi)
            a = (a[0] + d * math.cos(t), a[1] + d * math.sin(t))
        k = rng.random()
        mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
        nx, ny = -(b[1] - a[1]), b[0] - a[0]
        if k < 0.2 and math.hypot(nx, ny) > 0.2:
            bulge = rng.uniform(-0.4, 0.4)
            shape = [layer, width, "arc", a, (mx + bulge * nx, my + bulge * ny), b]
            if rng.random() < 0.5:
                shape = [layer, width, "arc", b, shape[4], a]
        elif k < 0.3:
            c1 = (a[0] + (b[0] - a[0]) / 3 + rng.uniform(-1, 1), a[1] + (b[1] - a[1]) / 3 + rng.uniform(-1, 1))
            c2 = (a[0] + 2 * (b[0] - a[0]) / 3 + rng.uniform(-1, 1), a[1] + 2 * (b[1] - a[1]) / 3 + rng.uniform(-1, 1))
            shape = [layer, width, "curve", a, c1, c2, b]
            if rng.random() < 0.5:
                shape = [layer, width, "curve", b, c2, c1, a]
        else:
            shape = [layer, width, "seg", a, b]
            if rng.random() < 0.5:
                shape = [layer, width, "seg", b, a]
        shapes.append(tuple(shape))
    rng.shuffle(shapes)
    return shapes


def random_closed(rng, layer, cx, cy, size):
    k = rng.random()
    w = rng.choice([0.05, 0.1])
    if k < 0.4:
        return [(layer, w, "circle", (cx, cy), size * rng.uniform(0.2, 1))]
    if k < 0.7:
        a, b = rng.uniform(0.2, 1) * size, rng.uniform(0.2, 1) * size
        r = rng.choice([0, 0, rng.uniform(0, min(a, b))])
        return [(layer, w, "rect", (cx - a, cy - b), (cx + a, cy + b), r)]
    n = rng.randint(3, 7)
    angles = sorted(rng.uniform(0, 2 * math.pi) for _ in range(n))
    return [(layer, w, "poly", [(cx + size * rng.uniform(0.4, 1) * math.cos(a), cy + size * rng.uniform(0.4, 1) * math.sin(a))
                                for a in angles])]


def random_cases(count, seed):
    rng = random.Random(seed)
    cases = []
    for _ in range(count):
        shapes = []
        for layer in ["F", "B"] if rng.random() < 0.3 else [rng.choice("FB")]:
            shapes += random_outline(rng, layer, 0, 0, rng.uniform(1.5, 4))
            for _ in range(rng.choice([0, 0, 1, 1, 2, 3])):
                cx, cy, size = rng.uniform(-2, 2), rng.uniform(-2, 2), rng.uniform(0.3, 1.5)
                shapes += random_closed(rng, layer, cx, cy, size) if rng.random() < 0.6 else \
                    random_outline(rng, layer, cx, cy, size)
        angle = rng.choice([0, 0, 90, 180, 270, 45, round(rng.uniform(0, 360), 1)])
        cases.append((shapes, angle, rng.random() < 0.3))
    return cases


def draw(path, cases=None):
    board = pcbnew.NewBoard(path)

    def v(p, at):
        return pcbnew.VECTOR2I(int(round(p[0] * MM)) + at[0], int(round(p[1] * MM)) + at[1])

    placed = cases is None
    cases = CASES if cases is None else cases
    cases = [(c, (100 * MM + (i % 16) * 15 * MM, 80 * MM + (i // 16) * 15 * MM)) for i, c in enumerate(cases)]
    if placed:
        cases.append((ORIGIN_CASE, (0, 0)))
    for i, ((shapes, angle, flipped), at) in enumerate(cases):
        fp = pcbnew.FOOTPRINT(board)
        fp.SetReference(f"CY{i + 1}")
        fp.SetPosition(pcbnew.VECTOR2I(*at))
        board.Add(fp)
        for (layer, width, kind, *pts) in shapes:
            s = pcbnew.PCB_SHAPE(fp)
            if kind == "seg":
                s.SetShape(pcbnew.SHAPE_T_SEGMENT)
                s.SetStart(v(pts[0], at))
                s.SetEnd(v(pts[1], at))
            elif kind == "arc":
                s.SetShape(pcbnew.SHAPE_T_ARC)
                s.SetArcGeometry(v(pts[0], at), v(pts[1], at), v(pts[2], at))
            elif kind == "circle":
                s.SetShape(pcbnew.SHAPE_T_CIRCLE)
                s.SetStart(v(pts[0], at))
                s.SetEnd(v((pts[0][0] + pts[1], pts[0][1]), at))
            elif kind == "rect":
                s.SetShape(pcbnew.SHAPE_T_RECTANGLE)
                s.SetStart(v(pts[0], at))
                s.SetEnd(v(pts[1], at))
                s.SetCornerRadius(int(round(pts[2] * MM)))
            elif kind == "poly":
                s.SetShape(pcbnew.SHAPE_T_POLY)
                s.SetPolyPoints([v(p, at) for p in pts[0]])
            elif kind == "curve":
                s.SetShape(pcbnew.SHAPE_T_BEZIER)
                s.SetStart(v(pts[0], at))
                s.SetBezierC1(v(pts[1], at))
                s.SetBezierC2(v(pts[2], at))
                s.SetEnd(v(pts[3], at))
                s.RebuildBezierToSegmentsPointsList(5000)
            s.SetWidth(int(round(width * MM)))
            s.SetLayer(pcbnew.F_CrtYd if layer == "F" else pcbnew.B_CrtYd)
            fp.Add(s)
        if angle:
            fp.SetOrientationDegrees(angle)
        if flipped:
            fp.Flip(fp.GetPosition(), pcbnew.FLIP_DIRECTION_TOP_BOTTOM)
    pcbnew.SaveBoard(path, board)


def swap_arcs(path):
    """Every other footprint arc's start and end swapped in the board file"""
    with open(path) as f:
        text = f.read()
    n = [0]

    def swap(m):
        n[0] += 1
        if n[0] % 2:
            return m.group(0)
        return m.group(1) + "(start " + m.group(4) + ")" + m.group(3) + "(end " + m.group(2) + ")"

    text = re.sub(r'(\(fp_arc\s*)\(start ([^)]*)\)(\s*\(mid [^)]*\)\s*)\(end ([^)]*)\)', swap, text)
    with open(path, "w") as f:
        f.write(text)


def main():
    args = sys.argv[1:]
    if args and args[0] == "--draw":
        draw(args[1])
        write(args[1])
        return
    if args and args[0] == "--random":
        draw(args[1], random_cases(int(args[2]), int(args[3]) if len(args) > 3 else 1))
        swap_arcs(args[1])
        write(args[1])
        return
    for board in args:
        write(board)


if __name__ == "__main__":
    main()
