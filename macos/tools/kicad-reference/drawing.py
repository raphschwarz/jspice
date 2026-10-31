#!/usr/bin/env python3
"""KiCad's drawing tools and point editor driven by the pointer, for checking the port's (KiCadRouter's GraphicTool,
DimensionTool and ShapePointEditor, BoardGraphics.swift and Dimensions.swift) against.

KiCad's Python module reaches neither its drawing tools nor its point editor, so, as tuning.py does, this runs KiCad's
PCB editor itself (pcbnew, under Xvfb, its window the size of a large screen) with an action plugin of its own in a
folder of its own and a copy of the user's KiCad configuration whose grid is a micrometre and whose magnetic snapping
is off (no pads, tracks or graphics snapped to: the pointer goes to the grid alone, which the port is given as KiCad's
grid helper would make it), and whose angle snap mode is the board's plan's. The view is zoomed to fit, the pointer
moved to two places and the status bar read at each (the view's scale and offset worked out from them); then each of
the plan's steps is done as a user does it: a tool picked from the Place menu (or its submenu Draw Dimensions), the
pointer moved and clicked, double clicked, Escape, a graphic selected by a click on it and one of its edit points
dragged (the button pressed on it, the pointer moved, let go). (No Ctrl: in KiCad 10 it takes the grid away too.) Each
place the pointer goes to is a pixel of the screen chosen near the plan's point where the view puts a whole
micrometre, so that the grid's point KiCad snaps to is known (the view's transform applied to the pixel, rounded);
where a step reads the status bar, KiCad's own reading of it is kept too.

    drawing.py boards OUTDIR COUNT [SEED]
        boards to draw on (OUTDIR/draw-SEED-N.kicad_pcb and .kicad_pro): an outline, nothing else; their projects'
        line widths and dimension defaults random (KiCad's own on some), and beside each BOARD.plan (JSON): the angle
        snap mode KiCad is run with, and the steps: lines (chains of them, finished by a double click or a click in
        the same place again), rectangles and circles, arcs (by their centre, start and end, the pointer going round
        on the way), polygons (finished by a double click or a click on the first corner), dimensions of each kind,
        and then edit points of the graphics made dragged: a line's ends, an arc's start, middle, end and centre, a
        rectangle's corners, sides and centre, a circle's centre and its point on it, a polygon's corners (no arc at
        45° or 90°, no rectangle's side or polygon's corner at 45°: see make_plan).
    drawing.py draw BOARD.kicad_pcb...
        the plan of each board done in KiCad, the board saved after the drawing (BOARD-drawn.kicad_pcb) and after the
        edits (BOARD-edited.kicad_pcb); BOARD.drawn (JSON): each step as it was done, every event the pointer made in
        it (the grid point it was at), the ids of the items each drawing step made, each edit's item and the edit
        point's place as KiCad had it; and graphics.py's reading of the two boards KiCad saved.

KiCad 10's pcbnew, Xvfb (xvfb-run) and a KiCad configuration made by running KiCad once (it is copied).
"""

import json
import math
import os
import random
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def fmt(v):
    s = f"{v:.6f}".rstrip("0").rstrip(".")
    return "0" if s == "-0" else s


# MARK: - Boards and their plans

def board_text(rng, w, h):
    n = [0]

    def uid():
        n[0] += 1
        return f"{rng.getrandbits(32):08x}-{rng.getrandbits(16):04x}-4{rng.getrandbits(12):03x}-8{rng.getrandbits(12):03x}-{n[0]:012x}"

    corners = [(100, 100), (100 + w, 100), (100 + w, 100 + h), (100, 100 + h)]
    edges = []
    for i in range(4):
        (ax, ay), (bx, by) = corners[i], corners[(i + 1) % 4]
        edges.append(f'\t(gr_line (start {ax} {ay}) (end {bx} {by}) (stroke (width 0.05) (type default)) '
                     f'(layer "Edge.Cuts") (uuid "{uid()}"))')
    layers = "\n".join(f"\t\t{l}" for l in [
        '(0 "F.Cu" signal)', '(2 "B.Cu" signal)', '(9 "F.Adhes" user "F.Adhesive")', '(11 "B.Adhes" user "B.Adhesive")',
        '(13 "F.Paste" user)', '(15 "B.Paste" user)', '(5 "F.SilkS" user "F.Silkscreen")', '(7 "B.SilkS" user "B.Silkscreen")',
        '(1 "F.Mask" user)', '(3 "B.Mask" user)', '(17 "Dwgs.User" user "User.Drawings")', '(19 "Cmts.User" user "User.Comments")',
        '(25 "Edge.Cuts" user)', '(27 "Margin" user)', '(31 "F.CrtYd" user "F.Courtyard")', '(29 "B.CrtYd" user "B.Courtyard")',
        '(35 "F.Fab" user)', '(33 "B.Fab" user)'])
    return ("(kicad_pcb\n\t(version 20260206)\n\t(generator \"pcbnew\")\n\t(generator_version \"10.0\")\n"
            "\t(general\n\t\t(thickness 1.6)\n\t\t(legacy_teardrops no)\n\t)\n\t(paper \"A4\")\n"
            "\t(layers\n" + layers + "\n\t)\n\t(setup\n\t\t(pad_to_mask_clearance 0)\n\t)\n"
            + "\n".join(edges) + "\n)\n")


def project(rng):
    defaults = {}
    if rng.random() < 0.7:
        for key in ("silk", "copper", "fab", "other"):
            defaults[f"{key}_line_width"] = rng.choice([0.08, 0.1, 0.12, 0.15, 0.2, 0.25])
        defaults["dimension_units"] = rng.choice([0, 1, 2, 3])
        defaults["dimension_precision"] = rng.choice([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        defaults["dimensions"] = {"units_format": rng.choice([0, 1, 2]), "suppress_zeroes": rng.random() < 0.5,
                                  "text_position": rng.choice([0, 1]), "keep_text_aligned": rng.random() < 0.7,
                                  "arrow_length": rng.choice([800000, 1000000, 1270000, 1500000]),
                                  "extension_offset": rng.choice([0, 250000, 500000])}
        for key in ("other", "silk", "copper"):
            defaults[f"{key}_text_size_v"] = rng.choice([0.8, 1.0, 1.2])
            defaults[f"{key}_text_size_h"] = rng.choice([0.8, 1.0, 1.2])
            defaults[f"{key}_text_thickness"] = rng.choice([0.1, 0.15, 0.2])
    return {"board": {"design_settings": {"defaults": defaults}}, "meta": {"filename": "", "version": 3}}


def anchors(step, handle):
    """Where the plan's graphic has its edit points, roughly (mm), and where `handle` is among them"""
    p = step["points"]
    mid = lambda a, b: [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]
    if step["op"] == "line":
        pts = {"start": p[0], "end": p[1]}
    elif step["op"] == "rectangle":
        l, r = min(p[0][0], p[1][0]), max(p[0][0], p[1][0])
        t, b = min(p[0][1], p[1][1]), max(p[0][1], p[1][1])
        c = [[l, t], [r, t], [r, b], [l, b]]
        pts = {f"corner{i}": c[i] for i in range(4)}
        pts.update({f"side{i}": mid(c[i], c[(i + 1) % 4]) for i in range(4)})
        pts["center"] = mid(c[0], c[2])
    elif step["op"] == "circle":
        pts = {"center": p[0], "end": p[1]}
    elif step["op"] == "arc":
        c, s = p[0], p[1]
        rad = math.hypot(s[0] - c[0], s[1] - c[1])
        a = math.atan2(s[1] - c[1], s[0] - c[0])
        sweep = 0.0
        for w in p[2:]:
            b = math.atan2(w[1] - c[1], w[0] - c[0])
            sweep += (b - a - sweep + math.pi) % (2 * math.pi) - math.pi
        on = lambda t: [c[0] + rad * math.cos(t), c[1] + rad * math.sin(t)]
        a0 = math.atan2(s[1] - c[1], s[0] - c[0])
        pts = {"center": c, "start": on(a0), "mid": on(a0 + sweep / 2), "end": on(a0 + sweep)}
    else:
        pts = {f"corner{i}": q for i, q in enumerate(p)}
    return list(pts.values()), pts[handle]


def make_plan(rng, w, h, snap=0):
    """The steps on a board of `w` by `h` mm at (100, 100): each drawing in a cell of its own; the board's angle snap
    mode `snap`"""
    cells = [(100 + 4 + 15 * i, 100 + 4 + 15 * j) for j in range(int((h - 8) // 15)) for i in range(int((w - 8) // 15))]
    rng.shuffle(cells)
    cells = iter(cells)

    def pt(cell, x, y):
        return [round(cell[0] + x, 3), round(cell[1] + y, 3)]

    def r(a, b):
        return rng.uniform(a, b)

    steps = []
    for _ in range(2):
        c = next(cells)
        pts = [pt(c, r(0, 3), r(0, 3))]
        for _ in range(rng.choice([2, 3, 4])):
            pts.append(pt(c, r(0, 11), r(0, 11)))
        steps.append({"op": "line", "points": pts, "finish": rng.choice(["double", "same"])})
    for _ in range(2):
        c = next(cells)
        steps.append({"op": "rectangle", "points": [pt(c, r(0, 10), r(0, 10)), pt(c, r(0, 10), r(0, 10))]})
    for _ in range(2):
        c = next(cells)
        steps.append({"op": "circle", "points": [pt(c, 5.5, 5.5), pt(c, 5.5 + r(-4, 4), 5.5 + r(-4, 4))]})
    for _ in range(3):
        c = next(cells)
        rad = r(2, 5)
        a0 = r(0, 2 * math.pi)
        sweep = rng.choice([-1, 1]) * r(0.6, 5.5)
        ways = [pt(c, 5.5 + rad * 1.1 * math.cos(a0 + sweep * t), 5.5 + rad * 1.1 * math.sin(a0 + sweep * t))
                for t in (0.15, 0.4, 0.7, 1.0)]
        steps.append({"op": "arc", "points": [pt(c, 5.5, 5.5), pt(c, 5.5 + rad * math.cos(a0), 5.5 + rad * math.sin(a0))] + ways})
    for _ in range(2):
        c = next(cells)
        n = rng.choice([3, 4, 5, 6])
        pts = []
        for k in range(n):
            a = 2 * math.pi * k / n + r(-0.3, 0.3)
            rr = r(3, 5.5)
            pts.append(pt(c, 5.5 + rr * math.cos(a), 5.5 + rr * math.sin(a)))
        steps.append({"op": "polygon", "points": pts, "finish": rng.choice(["double", "first"])})
    for kind in ("aligned", "orthogonal", "center", "radial", "leader"):
        c = next(cells)
        a = pt(c, r(1, 4), r(3, 8))
        b = pt(c, r(6, 10), r(3, 8))
        p = [a, b]
        if kind in ("aligned", "orthogonal"):
            p.append(pt(c, r(1, 10), rng.choice([r(0, 2), r(9, 11)])))
        steps.append({"op": "dimension", "kind": kind, "points": p})
    # edit points of what was drawn dragged
    edits = []
    lines = [i for i, s in enumerate(steps) if s["op"] == "line"]
    edits += [(lines[0], "segment", 0, "start"), (lines[1], "segment", 0, "end")]
    rects = [i for i, s in enumerate(steps) if s["op"] == "rectangle"]
    edits += [(rects[0], "rectangle", 0, f"corner{rng.randrange(4)}"), (rects[0], "rectangle", 0, f"side{rng.randrange(4)}"),
              (rects[1], "rectangle", 0, "center"), (rects[1], "rectangle", 0, f"corner{rng.randrange(4)}")]
    circles = [i for i, s in enumerate(steps) if s["op"] == "circle"]
    edits += [(circles[0], "circle", 0, "end"), (circles[1], "circle", 0, "center")]
    arcs = [i for i, s in enumerate(steps) if s["op"] == "arc"]
    # (an arc's edit points not dragged at 45° or 90°: KiCad's point editor then snaps them to where the lines of its
    # angles cross the arc's circle as it was, construction geometry the port does not snap to)
    if snap == 0:
        edits += [(arcs[0], "arc", 0, "start"), (arcs[1], "arc", 0, "mid"), (arcs[2], "arc", 0, "end"), (arcs[2], "arc", 0, "center")]
    polys = [i for i, s in enumerate(steps) if s["op"] == "polygon"]
    edits += [(polys[0], "polygon", 0, "corner1"), (polys[1], "polygon", 0, "corner0")]
    if snap == 1:
        # (nor, at 45°, a rectangle's side or a polygon's corner: KiCad's point editor then snaps them to the lines
        # of its angles through where the drag began, KiCad 10's snap lines, which the port does not snap to)
        edits = [e for e in edits if e[1] != "polygon" and not e[3].startswith("side")]
    dragged = {}
    for target, kind, index, handle in edits:
        # (the first move a millimetre and more, some fifteen pixels at the view's scale: past the drag threshold
        # of KiCad's tool dispatcher whichever way it goes; and none within a millimetre of the graphic's other edit
        # points as they were, which KiCad's point editor snaps to as construction geometry, nor of where an edit
        # before left one)
        near, at = anchors(steps[target], handle)
        near = [q for q in near if q != at] + dragged.get(target, [])
        for _ in range(100):
            moves = []
            a, length = r(0, 2 * math.pi), r(2.5, 4.0)
            dx, dy = length * math.cos(a), length * math.sin(a)
            for t in (0.6, 0.8, 1.0):
                moves.append([round(dx * t, 3), round(dy * t, 3)])
            if all(math.hypot(at[0] + m[0] - q[0], at[1] + m[1] - q[1]) > 1.0 for m in moves for q in near):
                break
        dragged.setdefault(target, []).append([at[0] + moves[-1][0], at[1] + moves[-1][1]])
        steps.append({"op": "edit", "target": target, "kind": kind, "index": index, "handle": handle, "moves": moves})
    return steps


def boards(out, count, seed):
    os.makedirs(out, exist_ok=True)
    for i in range(count):
        rng = random.Random(f"{seed}-{i}")
        base = os.path.join(out, f"draw-{seed}-{i}")
        w, h = 126, 66
        with open(base + ".kicad_pcb", "w") as f:
            f.write(board_text(rng, w, h))
        p = project(rng)
        p["meta"]["filename"] = os.path.basename(base) + ".kicad_pro"
        with open(base + ".kicad_pro", "w") as f:
            json.dump(p, f, indent=2)
        # (saved by KiCad, as KiCad writes it)
        import pcbnew
        pcbnew.SaveBoard(base + ".kicad_pcb", pcbnew.LoadBoard(base + ".kicad_pcb"))
        plan = {"angleSnap": i % 3, "steps": make_plan(rng, w, h, i % 3)}
        with open(base + ".plan", "w") as f:
            json.dump(plan, f, indent=1)
        print(base + ".kicad_pcb", file=sys.stderr)


# MARK: - KiCad's PCB editor, driven

PLUGIN = r'''
import json, math, os, re, shutil, traceback
import wx
import pcbnew

JOB = json.load(open(os.environ["JSPICE_DRAWING_JOB"]))
state = {"step": 0, "wait": 0, "ticks": 0, "phase": "load", "quiet": 0}
sim = wx.UIActionSimulator()
out = {"events": [], "readings": []}


def log(*a):
    with open(JOB["log"], "a") as f:
        f.write(" ".join(str(x) for x in a) + "\n")


def walk(w):
    yield w
    for c in w.GetChildren():
        yield from walk(c)


def frame():
    return next((w for w in wx.GetTopLevelWindows() if w.GetName() == "PcbFrame" and w.IsShown()), None)


def canvas():
    f = frame()
    cands = [w for w in walk(f) if w.IsShown() and w.GetClassName() == "wxGLCanvas"]
    return max(cands, key=lambda w: w.GetSize().x * w.GetSize().y)


def find_item(m, path):
    for item in m.GetMenuItems():
        label = item.GetItemLabelText()
        if label == path[0]:
            if len(path) == 1:
                return m, item
            if item.GetSubMenu() is not None:
                return find_item(item.GetSubMenu(), path[1:])
    return None


def menu(path):
    f = frame()
    bar = f.GetMenuBar()
    m = bar.GetMenu(next(i for i in range(bar.GetMenuCount()) if bar.GetMenuLabelText(i) == path[0]))
    found = find_item(m, path[1:])
    if found is None:
        log("menu not found", path, [i.GetItemLabelText() for i in m.GetMenuItems()])
        raise RuntimeError("menu")
    owner, item = found
    # (highlighted first, with no idle between, as a pick from the menu bar is: else ACTION_MENU takes the command
    # for a hotkey's, of the pointer's position, and a drawing tool starts with a click there)
    # (the highlight to the frame, which hands it the tool dispatcher and that the menu it names)
    lit = wx.MenuEvent(wx.wxEVT_MENU_HIGHLIGHT, item.GetId(), owner)
    lit.SetEventObject(f)
    evt = wx.CommandEvent(wx.wxEVT_MENU, item.GetId())
    evt.SetEventObject(owner)

    def pick():
        f.ProcessEvent(lit)
        owner.ProcessEvent(evt)
    wx.CallAfter(pick)


def cursor():
    sb = frame().GetStatusBar()
    for i in range(sb.GetFieldsCount()):
        m = re.match(r"X (-?[0-9.]+)\s+Y (-?[0-9.]+)", sb.GetStatusText(i))
        if m:
            return float(m.group(1)), float(m.group(2))
    return None


CALIBRATION = 48


def fit(readings):
    """The view's transform from pixels to millimetres, each axis a line, from the status bar's readings of the
    pointer at pixels (each the grid's micrometre nearest the place the pixel is at): a least squares line, then its
    offset made the middle of those every reading allows (each within half a micrometre of its line)"""
    (p0, _), out = readings[0], {}
    for axis, (pk, wk, sk) in enumerate((("px", "wx", "sx"), ("py", "wy", "sy"))):
        xs = [p[axis] - p0[axis] for p, _ in readings]
        ys = [w[axis] for _, w in readings]
        n = len(xs)
        mx, my = sum(xs) / n, sum(ys) / n
        s = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)
        lo = max(y - 0.0005 - s * x for x, y in zip(xs, ys))
        hi = min(y + 0.0005 - s * x for x, y in zip(xs, ys))
        o = (lo + hi) / 2 if lo <= hi else my - s * mx
        out.update({pk: p0[axis], wk: o, sk: s})
    return out


def to_world(q):
    t = out["transform"]
    return (t["wx"] + (q[0] - t["px"]) * t["sx"], t["wy"] + (q[1] - t["py"]) * t["sy"])


def pixel(p):
    """The pixel near `p` (mm) where the view puts nearest a whole micrometre, and that micrometre (nm)"""
    t = out["transform"]
    px = t["px"] + (p[0] - t["wx"]) / t["sx"]
    py = t["py"] + (p[1] - t["wy"]) / t["sy"]
    best = None
    for dx in range(-3, 4):
        for dy in range(-3, 4):
            q = (round(px) + dx, round(py) + dy)
            w = to_world(q)
            fx = abs(w[0] * 1000 - round(w[0] * 1000))
            fy = abs(w[1] * 1000 - round(w[1] * 1000))
            score = max(fx, fy) + 0.02 * (abs(dx) + abs(dy))
            if best is None or score < best[0]:
                best = (score, q, w)
    _, q, w = best
    return q, [int(round(w[0] * 1000)) * 1000, int(round(w[1] * 1000)) * 1000], [w[0] * 1e6, w[1] * 1e6]


def finish(code):
    with open(JOB["out"], "w") as f:
        json.dump(out, f)
    os._exit(code)


def drawings():
    return {item.m_Uuid.AsString(): item for item in pcbnew.GetBoard().GetDrawings()}


def handle_of(item, handle):
    """Where KiCad's point editor puts `handle` of the graphic, and a point on its outline to click it by (nm)"""
    s = pcbnew.Cast_to_PCB_SHAPE(item)
    kind = s.GetShape()
    xy = lambda v: [v.x, v.y]
    if kind == pcbnew.SHAPE_T_SEGMENT:
        at = {"start": xy(s.GetStart()), "end": xy(s.GetEnd())}[handle]
        a, b = s.GetStart(), s.GetEnd()
        return at, [(a.x + b.x) // 2, (a.y + b.y) // 2]
    if kind == pcbnew.SHAPE_T_ARC:
        at = {"start": xy(s.GetStart()), "mid": xy(s.GetArcMid()), "end": xy(s.GetEnd()), "center": xy(s.GetCenter())}[handle]
        return at, xy(s.GetArcMid())
    if kind == pcbnew.SHAPE_T_CIRCLE:
        at = {"center": xy(s.GetCenter()), "end": xy(s.GetEnd())}[handle]
        return at, xy(s.GetEnd())
    if kind == pcbnew.SHAPE_T_RECTANGLE:
        a, b = s.GetStart(), s.GetEnd()
        l, r, t, bt = min(a.x, b.x), max(a.x, b.x), min(a.y, b.y), max(a.y, b.y)
        corners = [[l, t], [r, t], [r, bt], [l, bt]]
        if handle.startswith("corner"):
            at = corners[int(handle[6:])]
            return at, at
        if handle.startswith("side"):
            i = int(handle[4:])
            p, q = corners[i], corners[(i + 1) % 4]
            # (EDIT_LINE::GetPosition: half of each end, VECTOR2I / 2 rounding halves away from nought)
            half = lambda v: int(math.copysign(math.floor(abs(v) / 2 + 0.5), v))
            at = [half(p[0]) + half(q[0]), half(p[1]) + half(q[1])]
            return at, at
        c = s.GetCenter()
        return [c.x, c.y], corners[0]
    if kind == pcbnew.SHAPE_T_POLY:
        chain = s.GetPolyShape().Outline(0)
        at = xy(chain.CPoint(int(handle[6:])))
        return at, at
    raise RuntimeError("shape")


def act(s):
    kind = s[0]
    ev = {"ev": kind}
    if kind == "menu":
        menu(s[1])
        state["wait"] = 8
        ev["path"] = s[1]
    elif kind == "move":
        p = s[1]
        if s[2:3] == ["rel"]:
            p = [state["anchor"][0] / 1e6 + p[0], state["anchor"][1] / 1e6 + p[1]]
        q, snapped, raw = pixel(p)
        sim.MouseMove(*q)
        ev.update(pixel=q, at=snapped, raw=raw)
        state["wait"] = 4
    elif kind == "hover":
        # (the pointer to an edit point of the graphic made by a step: KiCad's own place for it)
        uuids = out["made"][s[1]]
        item = drawings()[uuids[s[2]]]
        at, on = handle_of(item, s[3])
        state["anchor"] = at
        state["on"] = on
        q, snapped, raw = pixel([at[0] / 1e6, at[1] / 1e6])
        sim.MouseMove(*q)
        ev.update(uuid=uuids[s[2]], handle=s[3], handleAt=at, pixel=q, at=snapped, raw=raw)
        state["wait"] = 4
    elif kind == "select":
        uuids = out["made"][s[1]]
        item = drawings()[uuids[s[2]]]
        _, on = handle_of(item, s[3])
        q, snapped, raw = pixel([on[0] / 1e6, on[1] / 1e6])
        sim.MouseMove(*q)
        state["pending_click"] = True
        ev.update(uuid=uuids[s[2]], pixel=q, at=snapped)
        state["wait"] = 4
    elif kind == "click":
        sim.MouseClick(wx.MOUSE_BTN_LEFT)
        state["wait"] = 6
    elif kind == "dclick":
        sim.MouseDblClick(wx.MOUSE_BTN_LEFT)
        state["wait"] = 8
    elif kind == "down":
        sim.MouseDown(wx.MOUSE_BTN_LEFT)
        state["wait"] = 4
    elif kind == "up":
        sim.MouseUp(wx.MOUSE_BTN_LEFT)
        state["wait"] = 8
    elif kind == "key":
        code = {"escape": wx.WXK_ESCAPE}[s[1]]
        canvas().SetFocus()
        sim.Char(code)
        ev["key"] = s[1]
        state["wait"] = 6
    elif kind == "shot":
        # (the screen as it is, for a look at what KiCad shows)
        dc = wx.ScreenDC()
        size = dc.GetSize()
        bmp = wx.Bitmap(size.x, size.y)
        mem = wx.MemoryDC(bmp)
        mem.Blit(0, 0, size.x, size.y, dc, 0, 0)
        mem.SelectObject(wx.NullBitmap)
        bmp.SaveFile(s[1], wx.BITMAP_TYPE_PNG)
    elif kind == "check":
        ev["cursor"] = cursor()
        if JOB.get("debug"):
            focus, capture = wx.Window.FindFocus(), wx.Window.GetCapture()
            ev["windows"] = [(w.GetTitle(), w.GetClassName()) for w in wx.GetTopLevelWindows() if w.IsShown()]
            ev["focus"] = focus.GetClassName() if focus else None
            ev["capture"] = capture.GetClassName() if capture else None
            ev["shapes"] = {u: [[i.GetStart().x, i.GetStart().y], [i.GetEnd().x, i.GetEnd().y]]
                            for u, i in drawings().items() if i.GetClass() == "PCB_SHAPE"}
    elif kind == "mark":
        # (the board's drawings now, for the step that follows to know what it makes)
        state["before"] = set(drawings().keys())
        ev["step"] = s[1]
    elif kind == "made":
        now = drawings()
        # (in the order KiCad made them: a commit puts each new drawing first among the board's, ADD_MODE::INSERT)
        new = [u for u in now if u not in state["before"]][::-1]
        out.setdefault("made", {})[str(s[1])] = new
        ev["uuids"] = new
        ev["step"] = s[1]
    elif kind == "copy":
        shutil.copy(JOB["board"], JOB["board"][:-len(".kicad_pcb")] + s[1] + ".kicad_pcb")
    out["events"].append(ev)
    if JOB.get("debug"):
        with open(JOB["debug"], "w") as f:
            json.dump(out, f)


def tick():
    try:
        state["ticks"] += 1
        if state["ticks"] > JOB.get("ticks", 6000):
            log("timeout", state["step"])
            finish(3)
        if state["wait"] > 0:
            state["wait"] -= 1
            return
        f = frame()
        # (a dialog KiCad opened: a warning as the board is read, the leader's properties as it is made: its OK)
        for w in wx.GetTopLevelWindows():
            if state["phase"] != "load" and w is not f and w.IsShown() and isinstance(w, wx.Dialog) \
                    and w.GetTitle() != "Load PCB":
                out.setdefault("dialogs", []).append(w.GetTitle())
                ok = w.FindWindow(wx.ID_OK)
                if ok is not None:
                    evt = wx.CommandEvent(wx.wxEVT_BUTTON, wx.ID_OK)
                    evt.SetEventObject(ok)
                    wx.PostEvent(ok, evt)
                elif w.IsModal():
                    w.EndModal(wx.ID_OK)
                state["wait"] = 6
                return
        if state["phase"] == "load":
            state["quiet"] += 1
            if f is not None and pcbnew.GetBoard() is not None and state["quiet"] > 8:
                f.SetSize(0, 0, 2560, 1600)
                state["phase"] = "steps"
                state["wait"] = 6
            return
        steps = JOB["steps"]
        if state["step"] >= len(steps):
            finish(0)
        s = steps[state["step"]]
        if s[0] == "calibrate":
            c = canvas()
            r = c.GetScreenRect()
            pts = [(r.x + r.width // 5, r.y + r.height // 5), (r.x + 4 * r.width // 5, r.y + 4 * r.height // 5)]
            # (and more between, for the view's transform to well under the micrometre the status bar gives the
            # pointer's place to, which is the grid's)
            pts += [(pts[0][0] + 13 * i + (i * i) % 7, pts[0][1] + 9 * i + (i * i) % 5) for i in range(1, CALIBRATION)]
            cal = state.setdefault("cal", {"readings": [], "moved": False, "last": None})
            k = len(cal["readings"])
            if k < len(pts):
                target = pts[k]
                if not cal["moved"]:
                    sim.MouseMove(target[0] + 3, target[1] + 3)
                    sim.MouseMove(*target)
                    cal["moved"] = True
                    cal["last"] = None
                    state["wait"] = 4
                    return
                now = cursor()
                sb = frame().GetStatusBar()
                log("cal", target, now, r, [sb.GetStatusText(i) for i in range(sb.GetFieldsCount())],
                    wx.GetMousePosition(), [(w.GetTitle(), w.GetClassName(), w.IsShown()) for w in wx.GetTopLevelWindows()],
                    out.get("dialogs"))
                if now is not None and now == cal["last"]:
                    cal["readings"].append((target, now))
                    cal["moved"] = False
                else:
                    cal["last"] = now
                    sim.MouseMove(*target)
                    state["wait"] = 3
                return
            out["transform"] = fit(cal["readings"])
            out["calibration"] = cal["readings"]
            state.pop("cal")
            log("transform", out["transform"])
            # (how far the pointer goes with the button down before KiCad's tool dispatcher takes it for a drag:
            # wxSYS_DRAG_X and _Y, TOOL_DISPATCHER's DragDistanceThreshold where there are none)
            drag = [wx.SystemSettings.GetMetric(wx.SYS_DRAG_X), wx.SystemSettings.GetMetric(wx.SYS_DRAG_Y)]
            out["dragThreshold"] = [d if d != -1 else 8 for d in drag]
        elif s[0] == "save":
            menu(["File", "Save"])
            state["phase"] = "saving"
            state["step"] += 1
            return
        elif s[0] == "zoom":
            menu(["View", "Zoom to Fit"])
            state["wait"] = 10
        else:
            act(s)
            if state.pop("pending_click", False):
                steps.insert(state["step"] + 1, ["click"])
        state["step"] += 1
    except Exception:
        log(traceback.format_exc())
        finish(2)


def ontimer(e):
    if state["phase"] == "saving":
        state["ticks"] += 1
        if state["ticks"] > JOB.get("ticks", 6000):
            log("timeout saving")
            finish(4)
        if frame().GetTitle().startswith("*"):
            return
        state["phase"] = "steps"
    tick()


timer = wx.Timer()
timer.Bind(wx.EVT_TIMER, ontimer)
timer.Start(120)
'''

TOOLS = {"line": ["Place", "Draw Lines"], "rectangle": ["Place", "Draw Rectangles"], "circle": ["Place", "Draw Circles"],
         "arc": ["Place", "Draw Arcs"], "polygon": ["Place", "Draw Polygons"],
         "aligned": ["Place", "Draw Dimensions", "Draw Aligned Dimensions"],
         "orthogonal": ["Place", "Draw Dimensions", "Draw Orthogonal Dimensions"],
         "center": ["Place", "Draw Dimensions", "Draw Center Dimensions"],
         "radial": ["Place", "Draw Dimensions", "Draw Radial Dimensions"],
         "leader": ["Place", "Draw Dimensions", "Draw Leaders"]}


def events(plan):
    """The plugin's steps for a plan's"""
    steps = [["zoom"], ["calibrate"]]
    for i, s in enumerate(plan["steps"]):
        if s["op"] == "edit":
            continue
        tool = s.get("kind") if s["op"] == "dimension" else s["op"]
        steps += [["mark", i], ["menu", TOOLS[tool]]]
        pts = s["points"]
        if s["op"] == "line":
            for p in pts:
                steps += [["move", p], ["check"], ["click"]]
            if s["finish"] == "double":
                steps += [["dclick"]]
            else:
                steps += [["click"]]
        elif s["op"] in ("rectangle", "circle"):
            steps += [["move", pts[0]], ["click"], ["move", pts[1]], ["check"], ["click"]]
        elif s["op"] == "arc":
            steps += [["move", pts[0]], ["click"], ["move", pts[1]], ["click"]]
            for p in pts[2:]:
                steps += [["move", p]]
            steps += [["check"], ["click"]]
        elif s["op"] == "polygon":
            for p in pts:
                steps += [["move", p], ["check"], ["click"]]
            if s["finish"] == "double":
                steps += [["dclick"]]
            else:
                steps += [["move", pts[0]], ["click"]]
        elif s["op"] == "dimension":
            for p in pts:
                steps += [["move", p], ["check"], ["click"]]
        steps += [["key", "escape"], ["key", "escape"], ["made", i]]
    steps += [["save"], ["copy", "-drawn"]]
    for i, s in enumerate(plan["steps"]):
        if s["op"] != "edit":
            continue
        shots = os.environ.get("JSPICE_DRAWING_SHOTS")
        shot = (lambda name: [["shot", os.path.join(shots, f"edit{i}-{name}.png")]]) if shots else (lambda name: [])
        steps += [["key", "escape"], ["select", str(s["target"]), s["index"], s["handle"]]] + shot("selected") + [
            ["hover", str(s["target"]), s["index"], s["handle"]], ["down"]]
        for m in s["moves"]:
            steps += [["move", m, "rel"]]
        steps += shot("dragged") + [["up"], ["key", "escape"]]
    steps += [["save"], ["copy", "-edited"]]
    return steps


def drive(board, plan, fresh, ticks=9000):
    with tempfile.TemporaryDirectory() as tmp:
        share = os.path.join(tmp, "share")
        plugins = os.path.join(share, "kicad", "10.0", "scripting", "plugins")
        os.makedirs(plugins)
        with open(os.path.join(plugins, "jspice_drawing.py"), "w") as f:
            f.write(PLUGIN)
        config = os.path.join(tmp, "config")
        home = os.environ.get("KICAD_CONFIG_HOME") or os.path.expanduser("~/.config/kicad")
        shutil.copytree(home, config, ignore=shutil.ignore_patterns("*.lck"))
        pj = os.path.join(config, "10.0", "pcbnew.json")
        cfg = json.load(open(pj))
        grid = cfg.setdefault("window", {}).setdefault("grid", {})
        grid["sizes"] = [{"name": "", "x": "0.001 mm", "y": "0.001 mm"}]
        grid["last_size"] = 0
        grid["fast_grid_1"] = 0
        grid["fast_grid_2"] = 0
        grid["overrides_enabled"] = False
        editing = cfg.setdefault("editing", {})
        editing["magnetic_graphics"] = False
        editing["magnetic_pads"] = 0
        editing["magnetic_tracks"] = 0
        editing["magnetic_all_layers"] = False
        editing["pcb_angle_snap_mode"] = plan["angleSnap"]
        editing["arc_edit_mode"] = 0
        json.dump(cfg, open(pj, "w"))
        job = {"steps": events(plan), "log": os.path.join(tmp, "log.txt"), "out": os.path.join(tmp, "out.json"),
               "ticks": ticks, "board": os.path.abspath(board), "debug": os.path.join(os.environ["JSPICE_DRAWING_SHOTS"], "partial.json") if os.environ.get("JSPICE_DRAWING_SHOTS") else None}
        with open(os.path.join(tmp, "job.json"), "w") as f:
            json.dump(job, f)
        env = dict(os.environ, XDG_DATA_HOME=share, KICAD_CONFIG_HOME=config, JSPICE_DRAWING_JOB=os.path.join(tmp, "job.json"))
        text = ""
        for attempt in range(4):
            for p in (job["log"], job["out"]):
                if os.path.exists(p):
                    os.remove(p)
            # (the board as it was, each try, and no lock left by the one before)
            fresh()
            folder = os.path.dirname(os.path.abspath(board))
            for name in os.listdir(folder):
                if name.startswith("~") and name.endswith(".lck"):
                    os.remove(os.path.join(folder, name))
            run = subprocess.run(["xvfb-run", "-a", "-s", "-screen 0 2560x1600x24", "pcbnew", os.path.basename(board)],
                                 cwd=os.path.dirname(os.path.abspath(board)), env=env, capture_output=True, text=True,
                                 timeout=1800)
            text = open(job["log"]).read() if os.path.exists(job["log"]) else ""
            if run.returncode == 0 and os.path.exists(job["out"]):
                done = json.load(open(job["out"]))
                done["log"] = text
                return done
            print(f"{board}: try {attempt + 1} did not finish ({run.returncode}): {text[-3000:]}", file=sys.stderr)
        sys.exit(f"{board}: KiCad did not finish ({run.returncode}): {text} {run.stderr[-2000:]}")


def draw(paths):
    for board in paths:
        base = board[:-len(".kicad_pcb")]
        plan = json.load(open(base + ".plan"))
        work = base + "-work.kicad_pcb"
        # (a lock left by a run that did not finish would have KiCad ask whether to open the board anyway)
        for name in os.listdir(os.path.dirname(os.path.abspath(work))):
            if name.startswith("~" + os.path.basename(base)) and name.endswith(".lck"):
                os.remove(os.path.join(os.path.dirname(os.path.abspath(work)), name))

        def fresh():
            shutil.copy(board, work)
            shutil.copy(base + ".kicad_pro", work[:-len(".kicad_pcb")] + ".kicad_pro")
        done = drive(work, plan, fresh)
        wbase = work[:-len(".kicad_pcb")]
        for suffix in ("-drawn", "-edited"):
            shutil.move(wbase + suffix + ".kicad_pcb", base + suffix + ".kicad_pcb")
            shutil.copy(base + ".kicad_pro", base + suffix + ".kicad_pro")
        for ext in (".kicad_pcb", ".kicad_pro", ".kicad_prl"):
            if os.path.exists(wbase + ext):
                os.remove(wbase + ext)
        said = subprocess.run([sys.executable, os.path.join(HERE, "graphics.py"), base + "-drawn.kicad_pcb",
                               base + "-edited.kicad_pcb"], capture_output=True, text=True, check=True).stdout
        # (SWIG's notes of leaks among it)
        reads = json.loads(said[said.index("{"):said.rindex("}") + 1])
        record = {"plan": plan, "transform": done.get("transform"), "dragThreshold": done.get("dragThreshold"),
                  "events": done["events"], "made": done.get("made", {}),
                  "dialogs": done.get("dialogs", []),
                  "kicad": {"drawn": reads.get(base + "-drawn.kicad_pcb"), "edited": reads.get(base + "-edited.kicad_pcb")}}
        with open(base + ".drawn", "w") as f:
            json.dump(record, f, indent=1)
        print(base, len(done["events"]), "events", file=sys.stderr)


if __name__ == "__main__":
    if sys.argv[1] == "boards":
        boards(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]) if len(sys.argv) > 4 else 20261201)
    elif sys.argv[1] == "draw":
        draw(sys.argv[2:])
    else:
        sys.exit(__doc__)
