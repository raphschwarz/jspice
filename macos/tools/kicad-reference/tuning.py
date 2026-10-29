#!/usr/bin/env python3
"""KiCad's tuning patterns (PCB_TUNING_PATTERN) made, tuned again and deleted by KiCad itself, for checking the port's
(KiCadRouter's TuningPatterns.swift, TuningPatternGenerator.swift, TuningPatternEditing.swift) against.

KiCad's Python module reaches neither its tuning tools nor its generators (a board's Generators() are bare SWIG
pointers), so this runs KiCad's PCB editor itself (pcbnew, under Xvfb, its window maximized on a large screen), with an
action plugin of its own in a folder of its own and a copy of the user's KiCad configuration whose grid is a micrometre
(so that the status bar says where the pointer is to a micrometre), driven as a user drives it: the view zoomed to fit,
the pointer moved to two places and the status bar read at each (the view's scale and offset worked out from them), then
KiCad's own tools used with the pointer (wx.UIActionSimulator: X's pointer moved and clicked), its menus by their events.

    tuning.py boards OUTDIR COUNT [SEED]
        random boards to tune (OUTDIR/tune-SEED-N.kicad_pcb and .kicad_pro), saved by KiCad: lines of tracks between
        pads, of segments at 0, 45 and 90 degrees with now and then a corner rounded by an arc track, single tracks and
        differential pairs (nets D1_P and D1_N, a net class of their own), pads and tracks of other nets near them; the
        project's tuning pattern settings (amplitudes, spacing, corners, single-sided) random. Beside each board,
        BOARD.plan (JSON): the tunings to make with KiCad's tools, each a mode (single, diffpair, skew), the point of a
        straight segment of a line to click (its origin), a point the pointer goes to on the way, and the end the
        pointer is at for the second click, off the line on the side the meanders are to start on.
    tuning.py place BOARD.kicad_pcb...
        KiCad's Tune Length of a Single Track, Tune Length of a Differential Pair and Tune Skew of a Differential Pair
        (DRAWING_TOOL::PlaceTuningPattern), each tuning of BOARD.plan made as a user makes one: the tool picked from the
        Route menu, the pointer moved onto the track and clicked, moved on twice, clicked; Escape; then File > Save.
        Writes BOARD-placed.kicad_pcb (and its project), and BOARD.placed (JSON): for each tuning where KiCad's pointer
        was (the view's transform applied to the pixels the pointer went to) at each step.
    tuning.py edit BOARD-placed.kicad_pcb...
        each pattern of the board given new properties in its file (a new target length or skew from the length it came
        to, new amplitudes, spacing, corners, side or single-sidedness, an end moved along its line, now and then an
        override of the board's rules), and new patterns written into it on lines not tuned yet, with no base line
        (KiCad makes their base lines from their origins and ends, as its tool does), saved as BOARD-edit.kicad_pcb;
        then KiCad's Edit > Update All Tuning Patterns (GENERATOR_TOOL::RegenerateAllOfType: EditStart, Update and
        EditFinish of each pattern in turn) and File > Save: BOARD-updated.kicad_pcb.
    tuning.py remove BOARD-updated.kicad_pcb...
        one pattern of each board deleted as a user deletes it: a click on one of its tracks (which selects the
        pattern: its members are not selectable on their own) and Delete (EDIT_TOOL::DeleteItems: genRemove, the line
        made straight along its base line again); File > Save: BOARD-removed.kicad_pcb, and BOARD.removed (JSON): the
        uuid of the pattern deleted.
    tuning.py rules BOARD-placed.kicad_pcb...
        each pattern given a target by a rule of the board's own (BOARD-rules.kicad_dru: a length rule of each single
        track's net, mostly shorter than it came to, by turns a min, opt and max, an opt alone, a max alone, a min and
        a max; a length rule of each
        differential pair, a skew rule of each skew pattern's pair; the third single track's pattern overriding the
        rules), saved as BOARD-rules.kicad_pcb; then KiCad's Edit > Update All Tuning Patterns (EditStart takes a target
        from the rules where a pattern does not override them) and File > Save: BOARD-rules-updated.kicad_pcb.
    tuning.py check BOARD.kicad_pcb...
        each board as KiCad reads it (JSON on standard output, by path): through KiCad's pcbnew module, its generators
        (their uuids, names, layers, and their members as PCB_GROUP has them), and the board read and saved again by
        KiCad (pcbnew.SaveBoard: the patterns' properties as SetProperties took them and GetProperties gives them back),
        each generated item of the saved board as it is written; and kicad-cli's design rules check of it (its
        violations, each by its type and the descriptions of the items it names).
    tuning.py saved BOARD.kicad_pcb...
        beside each board, BOARD.saved (JSON): its generated items as KiCad writes them when it has read the board
        (pcbnew.LoadBoard, pcbnew.SaveBoard), which are not always as the board has them: KiCad's SetProperties cuts a
        length to the nanometre toward 0, so that a length it wrote can come back a nanometre short.

KiCad 10's pcbnew and kicad-cli, Xvfb (xvfb-run) and a KiCad configuration made by running KiCad once (it is copied).
"""

import json
import math
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile

MM = 1_000_000


# MARK: - S-expressions (as boardsetup.py reads them)

def parse(text):
    tokens = re.findall(r'"(?:[^"\\]|\\.)*"|\(|\)|[^\s()"]+', text)
    stack = [[]]
    for t in tokens:
        if t == "(":
            stack.append([])
        elif t == ")":
            done = stack.pop()
            stack[-1].append(done)
        elif t.startswith('"'):
            stack[-1].append(("str", re.sub(r'\\(.)', lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), t[1:-1])))
        else:
            stack[-1].append(t)
    return stack[0][0]


def head(node):
    return node[0] if isinstance(node, list) and node and isinstance(node[0], str) else None


def child(node, name):
    return next((c for c in node if head(c) == name), None)


def children(node, name):
    return [c for c in node if head(c) == name]


def text(v):
    return v[1] if isinstance(v, tuple) else v


def write(node):
    if isinstance(node, tuple):
        return '"' + node[1].replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'
    if isinstance(node, list):
        return "(" + " ".join(write(c) for c in node) + ")"
    return node


def fmt(v):
    """A length in mm as KiCad writes one (nanometres, no trailing zeros)"""
    s = f"{round(v * MM) / MM:.6f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def g10(v):
    """A number as KiCad writes a generator's ({:.10g})"""
    return f"{v:.10g}"


# MARK: - Boards to tune

class Board:
    def __init__(self, rng, name):
        self.rng = rng
        self.name = name
        self.items = []
        self.n = 0
        self.lines = []     # each: {"net", "layer", "width", "points", "arcs": set of corner indices rounded, "pair": id}
        self.obstacles = []

    def uid(self):
        self.n += 1
        return f"{self.rng.getrandbits(32):08x}-{self.rng.getrandbits(16):04x}-4{self.rng.getrandbits(12):03x}-8{self.rng.getrandbits(12):03x}-{self.n:012x}"

    def pad(self, x, y, net, size=1.2, layer="F.Cu", tht=False):
        ref = f"P{self.n + 1}"
        if tht:
            pad = (f'(pad "1" thru_hole circle (at 0 0) (size {fmt(size)} {fmt(size)}) (drill {fmt(size / 2)}) '
                   f'(layers "*.Cu" "*.Mask") (net "{net}") (uuid "{self.uid()}"))')
        else:
            mask = "F.Mask" if layer == "F.Cu" else "B.Mask"
            pad = (f'(pad "1" smd roundrect (at 0 0) (size {fmt(size)} {fmt(size)}) (layers "{layer}" "{mask}") '
                   f'(roundrect_rratio 0.25) (net "{net}") (uuid "{self.uid()}"))')
        fl = layer if not tht else "F.Cu"
        self.items.append(
            f'\t(footprint "JSpice:Pad" (layer "{fl}") (uuid "{self.uid()}") (at {fmt(x)} {fmt(y)}) '
            f'(property "Reference" "{ref}" (at 0 -1.5 0) (layer "{"F.Fab" if fl == "F.Cu" else "B.Fab"}") (uuid "{self.uid()}") '
            f'(effects (font (size 0.5 0.5) (thickness 0.1)))) '
            f'(property "Value" "Pad" (at 0 1.5 0) (layer "{"F.Fab" if fl == "F.Cu" else "B.Fab"}") (uuid "{self.uid()}") '
            f'(effects (font (size 0.5 0.5) (thickness 0.1)))) {pad})')

    def segment(self, a, b, width, layer, net):
        self.items.append(f'\t(segment (start {fmt(a[0])} {fmt(a[1])}) (end {fmt(b[0])} {fmt(b[1])}) (width {fmt(width)}) '
                          f'(layer "{layer}") (net "{net}") (uuid "{self.uid()}"))')

    def arc(self, a, m, b, width, layer, net):
        self.items.append(f'\t(arc (start {fmt(a[0])} {fmt(a[1])}) (mid {fmt(m[0])} {fmt(m[1])}) (end {fmt(b[0])} {fmt(b[1])}) '
                          f'(width {fmt(width)}) (layer "{layer}") (net "{net}") (uuid "{self.uid()}"))')

    def track_line(self, points, width, layer, net, rounded=()):
        """A line of tracks through `points` (mm), the corners in `rounded` (their indices) rounded by a tangent arc;
        its straight runs as drawn (each a segment between points or arc ends)"""
        runs = []
        start = points[0]
        for i in range(1, len(points) - 1):
            if i in rounded:
                p, c, q = points[i - 1], points[i], points[i + 1]
                d1 = norm(sub(c, p))
                d2 = norm(sub(q, c))
                turn = math.acos(max(-1, min(1, d1[0] * d2[0] + d1[1] * d2[1])))
                r = 1.0
                t = r * math.tan(turn / 2)
                a = sub(c, mul(d1, t))
                b = add(c, mul(d2, t))
                bis = norm(sub(norm(sub(p, c)), mul(d2, -1)))
                bis = norm(add(norm(sub(p, c)), d2))
                mid = add(c, mul(bis, r / math.cos(turn / 2) - r))
                a, b, mid = rnd(a), rnd(b), rnd(mid)
                self.segment(start, a, width, layer, net)
                runs.append((start, a))
                self.arc(a, mid, b, width, layer, net)
                start = b
            else:
                self.segment(start, points[i], width, layer, net)
                runs.append((start, points[i]))
                start = points[i]
        self.segment(start, points[-1], width, layer, net)
        runs.append((start, points[-1]))
        return runs

    def text(self, project):
        corners = [(100, 100), (100 + self.w, 100), (100 + self.w, 100 + self.h), (100, 100 + self.h)]
        edges = []
        for i in range(4):
            (ax, ay), (bx, by) = corners[i], corners[(i + 1) % 4]
            edges.append(f'\t(gr_line (start {ax} {ay}) (end {bx} {by}) (stroke (width 0.05) (type default)) '
                         f'(layer "Edge.Cuts") (uuid "{self.uid()}"))')
        layers = "\n".join(f"\t\t{l}" for l in [
            '(0 "F.Cu" signal)', '(2 "B.Cu" signal)', '(9 "F.Adhes" user "F.Adhesive")', '(11 "B.Adhes" user "B.Adhesive")',
            '(13 "F.Paste" user)', '(15 "B.Paste" user)', '(5 "F.SilkS" user "F.Silkscreen")', '(7 "B.SilkS" user "B.Silkscreen")',
            '(1 "F.Mask" user)', '(3 "B.Mask" user)', '(17 "Dwgs.User" user "User.Drawings")', '(19 "Cmts.User" user "User.Comments")',
            '(25 "Edge.Cuts" user)', '(27 "Margin" user)', '(31 "F.CrtYd" user "F.Courtyard")', '(29 "B.CrtYd" user "B.Courtyard")',
            '(35 "F.Fab" user)', '(33 "B.Fab" user)'])
        return ("(kicad_pcb\n\t(version 20260206)\n\t(generator \"pcbnew\")\n\t(generator_version \"10.0\")\n"
                "\t(general\n\t\t(thickness 1.6)\n\t\t(legacy_teardrops no)\n\t)\n\t(paper \"A4\")\n"
                "\t(layers\n" + layers + "\n\t)\n\t(setup\n\t\t(pad_to_mask_clearance 0)\n\t)\n"
                + "\n".join(self.items + edges) + "\n)\n")


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1])


def add(a, b):
    return (a[0] + b[0], a[1] + b[1])


def mul(a, k):
    return (a[0] * k, a[1] * k)


def norm(a):
    l = math.hypot(*a)
    return (a[0] / l, a[1] / l)


def rnd(p):
    return (round(p[0] * MM) / MM, round(p[1] * MM) / MM)


def offset_polyline(points, d):
    """The polyline `points` offset by `d` to its left (y down: to the left of the way it runs), its corners mitred"""
    normals = []
    for a, b in zip(points, points[1:]):
        t = norm(sub(b, a))
        normals.append((t[1], -t[0]))
    out = [add(points[0], mul(normals[0], d))]
    for i in range(1, len(points) - 1):
        n1, n2 = normals[i - 1], normals[i]
        bis = norm(add(n1, n2))
        cos = bis[0] * n1[0] + bis[1] * n1[1]
        out.append(add(points[i], mul(bis, d / cos)))
    out.append(add(points[-1], mul(normals[-1], d)))
    return [rnd(p) for p in out]


def make_board(rng, path):
    b = Board(rng, os.path.basename(path))
    b.w, b.h = 70, 12 * 5 + 6
    plan = []
    band = 0
    lines = []
    n_single = rng.choice([2, 3, 3, 4])
    kinds = ["single"] * n_single + ["pair"] * (5 - n_single)
    rng.shuffle(kinds)
    for k, kind in enumerate(kinds):
        y0 = 100 + 6 + 12 * k + 3
        x = 100 + 6
        width = rng.choice([0.2, 0.25, 0.3]) if kind == "single" else 0.2
        # (a centerline: a run east, a jog at 45 degrees up or down, east again, now and then another jog)
        pts = [(x, y0)]
        jogs = rng.choice([1, 1, 2])
        lengths = []
        total = 0
        for j in range(jogs):
            run = rng.randint(8, 18)
            x += run
            pts.append((x, y0 if j == 0 else pts[-1][1]))
            dy = rng.choice([-1, 1]) * rng.choice([2, 3, 4])
            if pts[-1][1] + dy < 100 + 4 + 12 * k or pts[-1][1] + dy > 100 + 4 + 12 * k + 8:
                dy = -dy
            x += abs(dy)
            pts.append((x, pts[-1][1] + dy))
        x = 100 + b.w - 6
        pts.append((x, pts[-1][1]))
        net = f"S{k + 1}" if kind == "single" else f"D{k + 1}"
        if kind == "single":
            rounded = {i for i in range(1, len(pts) - 1) if rng.random() < 0.3}
            b.pad(*pts[0], net, size=rng.choice([1.0, 1.2, 1.5]))
            b.pad(*pts[-1], net, size=rng.choice([1.0, 1.2]), tht=rng.random() < 0.3)
            runs = b.track_line(pts, width, "F.Cu", net, rounded)
            lines.append({"kind": kind, "net": net, "runs": runs, "width": width})
        else:
            s = 0.45 / 2
            pp = offset_polyline(pts, s)
            nn = offset_polyline(pts, -s)
            # (each line fanned out at its ends, at 45 degrees away from the other, to a pad of its own)
            pp = [rnd((pp[0][0] - 1, pp[0][1] - 1))] + pp + [rnd((pp[-1][0] + 1, pp[-1][1] - 1))]
            nn = [rnd((nn[0][0] - 1, nn[0][1] + 1))] + nn + [rnd((nn[-1][0] + 1, nn[-1][1] + 1))]
            for q, sub_net in ((pp, net + "_P"), (nn, net + "_N")):
                b.pad(*q[0], sub_net, size=0.6)
                b.pad(*q[-1], sub_net, size=0.6)
            runs_p = b.track_line(pp, 0.2, "F.Cu", net + "_P")
            runs_n = b.track_line(nn, 0.2, "F.Cu", net + "_N")
            lines.append({"kind": kind, "net": net, "runs": runs_p, "coupled": runs_n, "width": 0.2})
        # (now and then an obstacle near the line: a pad of another net beside a run)
        for _ in range(rng.choice([0, 1, 2])):
            a, c = rng.choice(lines[-1]["runs"])
            t = rng.uniform(0.3, 0.7)
            p = add(a, mul(sub(c, a), t))
            d = norm(sub(c, a))
            side = rng.choice([-1, 1])
            q = add(p, mul((d[1], -d[0]), side * rng.uniform(1.4, 2.6)))
            b.pad(*rnd(q), f"X{b.n}", size=0.8)
    # the plan: a tuning on most lines, on a straight run of it long enough, from a fifth of the way along it
    for line in lines:
        if rng.random() < 0.15:
            continue
        runs = [r for r in line["runs"] if math.hypot(*sub(r[1], r[0])) >= 7]
        if not runs:
            continue
        a, c = max(runs, key=lambda r: math.hypot(*sub(r[1], r[0])))
        d = sub(c, a)
        click = add(a, mul(d, rng.uniform(0.15, 0.3)))
        via = add(a, mul(d, 0.5))
        endp = add(a, mul(d, rng.uniform(0.7, 0.92)))
        u = norm(d)
        side = rng.choice([-1, 1])
        off = (u[1] * side * 0.8, -u[0] * side * 0.8)
        mode = "single" if line["kind"] == "single" else rng.choice(["diffpair", "diffpair", "skew"])
        plan.append({"mode": mode, "net": line["net"] + ("_P" if line["kind"] == "pair" else ""), "click": list(click),
                     "via": list(add(via, off)), "end": list(add(endp, off)), "run": [list(a), list(c)]})
    with open(path, "w") as f:
        f.write(b.text(None))
    s = {"min_amplitude": rng.choice([0.1, 0.2, 0.3]), "max_amplitude": rng.choice([0.8, 1.0, 1.5, 2.0]),
         "spacing": rng.choice([0.5, 0.6, 0.8, 1.0]), "corner_style": rng.choice([0, 1, 1]),
         "corner_radius_percentage": rng.choice([40, 80, 100]), "single_sided": rng.random() < 0.15}
    dp = dict(s, spacing=rng.choice([0.8, 1.0, 1.2]))
    project = {"board": {"design_settings": {"tuning_pattern_settings": {
        "single_track_defaults": s, "diff_pair_defaults": dp, "diff_pair_skew_defaults": dict(s)}}},
        "net_settings": {"classes": [
            {"name": "Default", "clearance": 0.2, "track_width": 0.25, "via_diameter": 0.6, "via_drill": 0.3,
             "diff_pair_width": 0.2, "diff_pair_gap": 0.25, "diff_pair_via_gap": 0.25, "wire_width": 6, "bus_width": 12,
             "line_style": 0, "microvia_diameter": 0.3, "microvia_drill": 0.1, "pcb_color": "rgba(0, 0, 0, 0.000)",
             "schematic_color": "rgba(0, 0, 0, 0.000)", "priority": 2147483647},
            {"name": "Pairs", "clearance": 0.2, "track_width": 0.2, "via_diameter": 0.6, "via_drill": 0.3,
             "diff_pair_width": 0.2, "diff_pair_gap": 0.25, "diff_pair_via_gap": 0.25, "wire_width": 6, "bus_width": 12,
             "line_style": 0, "microvia_diameter": 0.3, "microvia_drill": 0.1, "pcb_color": "rgba(0, 0, 0, 0.000)",
             "schematic_color": "rgba(0, 0, 0, 0.000)", "priority": 0}],
            "netclass_patterns": [{"netclass": "Pairs", "pattern": "D*"}], "meta": {"version": 4}},
        "meta": {"filename": os.path.basename(path)[:-len(".kicad_pcb")] + ".kicad_pro", "version": 3}}
    with open(path[:-len(".kicad_pcb")] + ".kicad_pro", "w") as f:
        json.dump(project, f, indent=2)
    import pcbnew
    pcbnew.SaveBoard(path, pcbnew.LoadBoard(path))
    with open(path[:-len(".kicad_pcb")] + ".plan", "w") as f:
        json.dump(plan, f, indent=1)
    return plan


def boards(out, count, seed):
    os.makedirs(out, exist_ok=True)
    for i in range(count):
        rng = random.Random(f"{seed}-{i}")
        path = os.path.join(out, f"tune-{seed}-{i}.kicad_pcb")
        plan = make_board(rng, path)
        print(path, len(plan), file=sys.stderr)


# MARK: - KiCad's PCB editor, driven

PLUGIN = r'''
import json, os, re, traceback
import wx
import pcbnew

JOB = json.load(open(os.environ["JSPICE_TUNING_JOB"]))
state = {"step": 0, "wait": 0, "ticks": 0, "phase": "load", "quiet": 0}
sim = wx.UIActionSimulator()
out = {"steps": []}


def log(*a):
    with open(JOB["log"], "a") as f:
        f.write(" ".join(str(x) for x in a) + "\n")


def walk(w):
    yield w
    for c in w.GetChildren():
        yield from walk(c)


def shown(title):
    return next((w for w in wx.GetTopLevelWindows() if w.IsShown() and w.GetTitle() == title), None)


def frame():
    return next((w for w in wx.GetTopLevelWindows() if w.GetName() == "PcbFrame" and w.IsShown()), None)


def canvas():
    f = frame()
    cands = [w for w in walk(f) if w.IsShown() and w.GetClassName() == "wxGLCanvas"]
    return max(cands, key=lambda w: w.GetSize().x * w.GetSize().y)


def menu(title, command):
    f = frame()
    bar = f.GetMenuBar()
    m = bar.GetMenu(next(i for i in range(bar.GetMenuCount()) if bar.GetMenuLabelText(i) == title))
    item = next(i for i in m.GetMenuItems() if i.GetItemLabelText() == command)
    evt = wx.CommandEvent(wx.wxEVT_MENU, item.GetId())
    evt.SetEventObject(m)
    wx.CallAfter(m.ProcessEvent, evt)


def cursor():
    sb = frame().GetStatusBar()
    for i in range(sb.GetFieldsCount()):
        m = re.match(r"X (-?[0-9.]+)\s+Y (-?[0-9.]+)", sb.GetStatusText(i))
        if m:
            return float(m.group(1)), float(m.group(2))
    return None


def to_screen(p):
    t = out["transform"]
    return (round(t["px"] + (p[0] - t["wx"]) / t["sx"]), round(t["py"] + (p[1] - t["wy"]) / t["sy"]))


def to_world(q):
    t = out["transform"]
    return (t["wx"] + (q[0] - t["px"]) * t["sx"], t["wy"] + (q[1] - t["py"]) * t["sy"])


def finish(code):
    with open(JOB["out"], "w") as f:
        json.dump(out, f)
    os._exit(code)


def tick():
    try:
        state["ticks"] += 1
        if state["ticks"] > JOB.get("ticks", 1500):
            log("timeout", state["step"])
            finish(3)
        if state["wait"] > 0:
            state["wait"] -= 1
            return
        f = frame()
        if state["phase"] == "load":
            warning = shown("Warning")
            if warning is not None:
                out.setdefault("warnings", []).append([w.GetLabel() for w in walk(warning) if isinstance(w, wx.StaticText)])
                warning.EndModal(wx.ID_OK)
                state["quiet"] = 0
                return
            state["quiet"] += 1
            if f is not None and pcbnew.GetBoard() is not None and state["quiet"] > 8:
                # (no window manager under Xvfb to maximize it: the frame made the screen's size)
                f.SetSize(0, 0, 2560, 1600)
                state["phase"] = "steps"
                state["wait"] = 6
            return
        warning = shown("Warning")
        if warning is not None:
            out.setdefault("warnings", []).append([w.GetLabel() for w in walk(warning) if isinstance(w, wx.StaticText)])
            warning.EndModal(wx.ID_OK)
            state["wait"] = 2
            return
        steps = JOB["steps"]
        if state["step"] >= len(steps):
            finish(0)
        s = steps[state["step"]]
        kind = s[0]
        if kind == "menu":
            menu(s[1], s[2])
            state["wait"] = s[3] if len(s) > 3 else 6
        elif kind == "calibrate":
            # (the pointer at two places of the canvas, the status bar read at each once it has caught up: each
            # place visited twice, a reading taken when two in a row agree)
            c = canvas()
            r = c.GetScreenRect()
            pts = [(r.x + r.width // 5, r.y + r.height // 5), (r.x + 4 * r.width // 5, r.y + 4 * r.height // 5)]
            cal = state.setdefault("cal", {"i": 0, "last": None, "readings": [], "moved": False})
            k = len(cal["readings"])
            if k < 2:
                target = pts[k]
                if not cal["moved"]:
                    sim.MouseMove(target[0] + 3, target[1] + 3)
                    sim.MouseMove(*target)
                    cal["moved"] = True
                    cal["last"] = None
                    state["wait"] = 4
                    return
                now = cursor()
                if now is not None and now == cal["last"]:
                    cal["readings"].append((target, now))
                    cal["moved"] = False
                else:
                    cal["last"] = now
                    sim.MouseMove(*target)
                    state["wait"] = 3
                return
            (p1, w1), (p2, w2) = cal["readings"]
            out["transform"] = {"px": p1[0], "py": p1[1], "wx": w1[0], "wy": w1[1],
                                "sx": (w2[0] - w1[0]) / (p2[0] - p1[0]), "sy": (w2[1] - w1[1]) / (p2[1] - p1[1])}
            out["readings"] = cal["readings"]
            state.pop("cal")
            log("transform", out["transform"])
        elif kind == "move":
            q = to_screen(s[1])
            sim.MouseMove(*q)
            out["steps"].append({"move": s[1], "pixel": q, "world": to_world(q)})
            state["wait"] = s[2] if len(s) > 2 else 4
        elif kind == "wait":
            state["wait"] = s[1]
        elif kind == "windows":
            # (the windows KiCad has open, by their titles, and its info bar's message: for a look at what it said)
            out["steps"].append({"windows": [(w.GetTitle(), w.IsShown(), [c.GetLabel() for c in walk(w) if isinstance(c, wx.StaticText)][:8])
                                             for w in wx.GetTopLevelWindows() if w is not f],
                                 "infobar": [c.GetLabel() for c in walk(f) if c.IsShown() and isinstance(c, wx.StaticText)
                                             and c.GetParent() is not None and "InfoBar" in c.GetParent().GetClassName()]})
        elif kind == "check":
            # (where the status bar says the pointer is)
            out["steps"].append({"cursor": cursor()})
        elif kind == "click":
            sim.MouseClick(wx.MOUSE_BTN_LEFT)
            state["wait"] = s[1] if len(s) > 1 else 6
        elif kind == "key":
            code = {"escape": wx.WXK_ESCAPE, "delete": wx.WXK_DELETE}[s[1]]
            canvas().SetFocus()
            sim.Char(code)
            state["wait"] = s[2] if len(s) > 2 else 6
        elif kind == "save":
            menu("File", "Save")
            state["phase"] = "saving"
            state["step"] += 1
            return
        state["step"] += 1
    except Exception:
        log(traceback.format_exc())
        finish(2)


def saving():
    if frame().GetTitle().startswith("*"):
        return False
    state["phase"] = "steps"
    return True


def ontimer(e):
    if state["phase"] == "saving":
        if not saving():
            return
    tick()


timer = wx.Timer()
timer.Bind(wx.EVT_TIMER, ontimer)
timer.Start(150)
'''


def drive(board, steps, ticks=1500):
    """KiCad's PCB editor on `board` (its project beside it), its window maximized on a screen of 2560 by 1600, the
    plugin's `steps` done; what it wrote"""
    with tempfile.TemporaryDirectory() as tmp:
        share = os.path.join(tmp, "share")
        plugins = os.path.join(share, "kicad", "10.0", "scripting", "plugins")
        os.makedirs(plugins)
        with open(os.path.join(plugins, "jspice_tuning.py"), "w") as f:
            f.write(PLUGIN)
        config = os.path.join(tmp, "config")
        home = os.environ.get("KICAD_CONFIG_HOME") or os.path.expanduser("~/.config/kicad")
        shutil.copytree(home, config, ignore=shutil.ignore_patterns("*.lck"))
        # (a micrometre's grid: the status bar's pointer to a micrometre)
        pj = os.path.join(config, "10.0", "pcbnew.json")
        cfg = json.load(open(pj))
        grid = cfg.setdefault("window", {}).setdefault("grid", {})
        grid["sizes"] = [{"name": "", "x": "0.001 mm", "y": "0.001 mm"}]
        grid["last_size"] = 0
        grid["fast_grid_1"] = 0
        grid["fast_grid_2"] = 0
        json.dump(cfg, open(pj, "w"))
        job = {"steps": steps, "log": os.path.join(tmp, "log.txt"), "out": os.path.join(tmp, "out.json"), "ticks": ticks}
        with open(os.path.join(tmp, "job.json"), "w") as f:
            json.dump(job, f)
        env = dict(os.environ, XDG_DATA_HOME=share, KICAD_CONFIG_HOME=config, JSPICE_TUNING_JOB=os.path.join(tmp, "job.json"))
        text = ""
        # (KiCad's editor now and then crashes as it starts under Xvfb: tried again)
        for attempt in range(4):
            for p in (job["log"], job["out"]):
                if os.path.exists(p):
                    os.remove(p)
            run = subprocess.run(["xvfb-run", "-a", "-s", "-screen 0 2560x1600x24", "pcbnew", os.path.basename(board)],
                                 cwd=os.path.dirname(os.path.abspath(board)), env=env, capture_output=True, text=True,
                                 timeout=600)
            text = open(job["log"]).read() if os.path.exists(job["log"]) else ""
            # (what KiCad said on its standard error, its failed assertions among it, kept for a look)
            global LAST_STDERR
            LAST_STDERR = run.stderr
            if run.returncode == 0 and os.path.exists(job["out"]):
                done = json.load(open(job["out"]))
                done["log"] = text
                return done
        sys.exit(f"{board}: KiCad did not finish ({run.returncode}): {text} {run.stderr[-2000:]}")


def copy_board(src, dst):
    shutil.copy(src, dst)
    for ext in (".kicad_pro", ".kicad_dru"):
        other = src[:-len(".kicad_pcb")] + ext
        if os.path.exists(other):
            shutil.copy(other, dst[:-len(".kicad_pcb")] + ext)


TOOLS = {"single": "Tune Length of a Single Track", "diffpair": "Tune Length of a Differential Pair",
         "skew": "Tune Skew of a Differential Pair"}


def place(boards):
    for board in boards:
        base = board[:-len(".kicad_pcb")]
        plan = json.load(open(base + ".plan"))
        out = base + "-placed.kicad_pcb"
        copy_board(board, out)
        steps = [["menu", "View", "Zoom to Fit", 10], ["calibrate"]]
        for t in plan:
            steps += [["menu", "Route", TOOLS[t["mode"]], 8], ["move", t["click"], 6], ["check"], ["click", 10],
                      ["move", t["via"], 10], ["move", t["end"], 10], ["check"], ["click", 12], ["key", "escape", 8]]
        steps += [["save"]]
        done = drive(out, steps)
        record = {"transform": done.get("transform"), "tunings": []}
        moves = [s for s in done["steps"] if "move" in s]
        checks = [s for s in done["steps"] if "cursor" in s]
        for k, t in enumerate(plan):
            m = moves[3 * k:3 * k + 3]
            record["tunings"].append(dict(t, click=m[0]["world"], via=m[1]["world"], end=m[2]["world"],
                                          clickCursor=checks[2 * k]["cursor"], endCursor=checks[2 * k + 1]["cursor"]))
        with open(base + ".placed", "w") as f:
            json.dump(record, f, indent=1)
        print(out, file=sys.stderr)


# MARK: - Patterns edited in the file, tuned again by KiCad

def edit(boards, seed=20261129):
    for board in boards:
        rng = random.Random(f"{seed}-{os.path.basename(board)}")
        base = board[:-len("-placed.kicad_pcb")] if board.endswith("-placed.kicad_pcb") else board[:-len(".kicad_pcb")]
        src = open(board).read()
        root = parse(src)
        gens = [c for c in root if head(c) == "generated"]
        edited = []
        for g in gens:
            props = {head(c): c for c in g if isinstance(c, list)}
            mode = text(props["tuning_mode"][1])
            length = float(props["last_tuning_length"][1])
            choice = rng.random()

            def setv(key, value):
                node = props.get(key)
                if node is None:
                    node = [key, value]
                    g.insert(len(g) - 1, node)
                    props[key] = node
                else:
                    node[1] = value

            if mode == "diff_pair_skew":
                target = round(rng.choice([-0.3, 0.2, 0.5, 1.0, 3.0]), 3)
                for k in ("target_skew", "target_skew_min", "target_skew_max"):
                    props.pop(k, None)
                g[:] = [c for c in g if head(c) not in ("target_skew", "target_skew_min", "target_skew_max")]
                g.insert(len(g) - 1, ["target_skew", g10(target)])
            else:
                target = round(length + rng.choice([-2.0, -0.5, 0.3, 1.5, 3.0, 8.0]), 4)
                g[:] = [c for c in g if head(c) not in ("target_length", "target_length_min", "target_length_max")]
                g.insert(len(g) - 1, ["target_length", g10(max(target, 1.0))])
            if choice < 0.3:
                setv("max_amplitude", g10(rng.choice([0.6, 0.9, 1.2, 1.8])))
            if rng.random() < 0.3:
                setv("min_spacing", g10(rng.choice([0.5, 0.7, 1.0])))
            if rng.random() < 0.25:
                setv("rounded", "no" if props["rounded"][1] == "yes" else "yes")
            if rng.random() < 0.25:
                setv("initial_side", ("str", rng.choice(["left", "right", "default"])))
            if rng.random() < 0.15:
                setv("single_sided", "no" if props["single_sided"][1] == "yes" else "yes")
            if rng.random() < 0.2:
                setv("corner_radius_percent", g10(rng.choice([20, 50, 100])))
            if rng.random() < 0.3:
                # (the end moved along the base line)
                bl = child(props["base_line"], "pts")
                pts = [(float(p[1]), float(p[2])) for p in bl if head(p) == "xy"]
                if len(pts) >= 2:
                    a, c = pts[-2], pts[-1]
                    t = rng.uniform(0.8, 1.15)
                    e = add(a, mul(sub(c, a), t))
                    off = norm(sub(c, a))
                    side = rng.choice([-1, 1]) * 0.3
                    e = add(e, (off[1] * side, -off[0] * side))
                    setv("end", ["xy", fmt(e[0]), fmt(e[1])])
            edited.append(text(child(g, "uuid")[1]))
        # (new patterns, of no base line, on lines not tuned yet: KiCad makes their base lines itself)
        tuned = set()
        for g in gens:
            for m in child(g, "members")[1:]:
                tuned.add(text(m))
        segs = [c for c in root if head(c) == "segment"]
        nets_tuned = {text(child(g, "last_netname")[1]) for g in gens}
        added = []
        by_net = {}
        for s in segs:
            net = text(child(s, "net")[1])
            by_net.setdefault(net, []).append(s)
        for net, ss in sorted(by_net.items()):
            if net in nets_tuned or net.startswith("X") or net.endswith("_N"):
                continue
            if net[:-2] + "_P" in nets_tuned or net[:-2] + "_N" in nets_tuned:
                continue
            ss = [s for s in ss if text(child(s, "uuid")[1]) not in tuned]
            if not ss or rng.random() < 0.3:
                continue
            s = max(ss, key=lambda s: math.hypot(float(child(s, "end")[1]) - float(child(s, "start")[1]),
                                                 float(child(s, "end")[2]) - float(child(s, "start")[2])))
            a = (float(child(s, "start")[1]), float(child(s, "start")[2]))
            c = (float(child(s, "end")[1]), float(child(s, "end")[2]))
            if math.hypot(*sub(c, a)) < 6:
                continue
            o = rnd(add(a, mul(sub(c, a), rng.uniform(0.15, 0.35))))
            e = rnd(add(a, mul(sub(c, a), rng.uniform(0.65, 0.9))))
            mode = "single" if not net.endswith("_P") else rng.choice(["diff_pair", "diff_pair_skew"])
            length = math.hypot(*sub(e, o))
            uuid = f"{rng.getrandbits(32):08x}-{rng.getrandbits(16):04x}-4{rng.getrandbits(12):03x}-a{rng.getrandbits(12):03x}-{rng.getrandbits(48):012x}"
            node = ["generated", ["uuid", ("str", uuid)], ["type", "tuning_pattern"], ["name", ("str", "Tuning Pattern")],
                    ["layer", ("str", "F.Cu")], ["corner_radius_percent", g10(rng.choice([50, 80, 100]))],
                    ["end", ["xy", fmt(e[0]), fmt(e[1])]], ["initial_side", ("str", rng.choice(["left", "right"]))],
                    ["last_netname", ("str", net)], ["last_status", ("str", "tuned")],
                    ["max_amplitude", g10(rng.choice([0.8, 1.0, 1.5]))], ["min_amplitude", g10(0.2)],
                    ["min_spacing", g10(rng.choice([0.6, 0.8, 1.0]))], ["origin", ["xy", fmt(o[0]), fmt(o[1])]],
                    ["override_custom_rules", "no"], ["rounded", rng.choice(["yes", "no"])],
                    ["single_sided", "yes" if rng.random() < 0.15 else "no"]]
            if mode == "diff_pair_skew":
                node.append(["target_skew", g10(rng.choice([0.2, 0.5, 1.0]))])
                node.append(["target_length", g10(100)])
            else:
                node.append(["target_length", g10(round(rng.uniform(4, 14) + math.hypot(*sub(c, a)), 3))])
            node += [["tuning_mode", ("str", mode)], ["members", ("str", text(child(s, "uuid")[1]))]]
            root.insert(len(root), node)
            added.append(uuid)
        edit_path = base + "-edit.kicad_pcb"
        with open(edit_path, "w") as f:
            f.write(write(root) + "\n")
        pro = base + ".kicad_pro"
        if os.path.exists(pro):
            shutil.copy(pro, base + "-edit.kicad_pro")
        updated = base + "-updated.kicad_pcb"
        copy_board(edit_path, updated)
        drive(updated, [["menu", "Edit", "Update All Tuning Patterns", 20], ["save"]])
        with open(base + ".edited", "w") as f:
            json.dump({"edited": edited, "added": added}, f, indent=1)
        print(updated, len(edited), len(added), file=sys.stderr)


# MARK: - A pattern deleted

def remove(boards, seed=20261130):
    for board in boards:
        rng = random.Random(f"{seed}-{os.path.basename(board)}")
        base = board[:-len("-updated.kicad_pcb")] if board.endswith("-updated.kicad_pcb") else board[:-len(".kicad_pcb")]
        root = parse(open(board).read())
        gens = [c for c in root if head(c) == "generated"]
        if not gens:
            continue
        g = rng.choice(gens)
        members = {text(m) for m in child(g, "members")[1:]}
        segs = [c for c in root if head(c) == "segment" and text(child(c, "uuid")[1]) in members]
        if not segs:
            continue
        s = max(segs, key=lambda s: math.hypot(float(child(s, "end")[1]) - float(child(s, "start")[1]),
                                               float(child(s, "end")[2]) - float(child(s, "start")[2])))
        a = (float(child(s, "start")[1]), float(child(s, "start")[2]))
        c = (float(child(s, "end")[1]), float(child(s, "end")[2]))
        p = add(a, mul(sub(c, a), 0.5))
        out = base + "-removed.kicad_pcb"
        copy_board(board, out)
        drive(out, [["menu", "View", "Zoom to Fit", 10], ["calibrate"], ["move", list(p), 6], ["click", 10],
                    ["key", "delete", 12], ["save"]])
        with open(base + ".removed", "w") as f:
            json.dump({"removed": text(child(g, "uuid")[1]), "at": list(p)}, f, indent=1)
        print(out, file=sys.stderr)


# MARK: - Targets from the board's rules

def rules(boards, seed=20261131):
    """Each board's patterns given targets by rules of its own (BOARD-rules.kicad_dru), then KiCad's Update All"""
    for board in boards:
        rng = random.Random(f"{seed}-{os.path.basename(board)}")
        base = board[:-len("-placed.kicad_pcb")] if board.endswith("-placed.kicad_pcb") else board[:-len(".kicad_pcb")]
        root = parse(open(board).read())
        gens = [c for c in root if head(c) == "generated"]
        lines = ["(version 1)"]
        singles = 0
        shift = rng.randrange(4)
        for g in gens:
            mode = text(child(g, "tuning_mode")[1])
            net = text(child(g, "last_netname")[1])
            length = float(child(g, "last_tuning_length")[1])
            pair = re.sub(r"_[PN]$", "", net)
            if mode == "single":
                # (shorter than the pattern came to, mostly: its meanders made again to fit)
                opt = length + rng.choice([-4.0, -2.0, -1.0, 0.5])
                # (each way a rule can give a length, by turns from a board's own: all three, an opt alone, a max
                # alone, a min and a max)
                shape = (singles + shift) % 4
                singles += 1
                values = [("min", opt - 0.3), ("opt", opt), ("max", opt + 0.6)] if shape == 0 else \
                    [("opt", opt)] if shape == 1 else [("max", opt)] if shape == 2 else [("min", opt - 0.5), ("max", opt + 0.5)]
                constraint = "length"
                condition = f"A.NetName == '{net}'"
                # (and one pattern that overrides the rules: its own target kept)
                if singles == 3:
                    node = child(g, "override_custom_rules")
                    node[1] = "yes"
            elif mode == "diff_pair":
                opt = length + rng.choice([-2.0, -1.0, 1.0])
                values = [("min", opt - 0.2), ("opt", opt), ("max", opt + 0.4)]
                constraint = "length"
                condition = f"A.inDiffPair('{pair}')"
            else:
                values = [("min", -0.1), ("opt", rng.choice([0.3, 0.6])), ("max", 0.8)]
                constraint = "skew"
                condition = f"A.inDiffPair('{pair}')"
            spec = " ".join(f"({k} {fmt(v)}mm)" for k, v in values)
            lines.append(f'(rule "{constraint} {net}" (condition "{condition}") (constraint {constraint} {spec}))')
        out = base + "-rules.kicad_pcb"
        with open(out, "w") as f:
            f.write(write(root) + "\n")
        pro = base + ".kicad_pro"
        if os.path.exists(pro):
            shutil.copy(pro, base + "-rules.kicad_pro")
        with open(base + "-rules.kicad_dru", "w") as f:
            f.write("\n".join(lines) + "\n")
        updated = base + "-rules-updated.kicad_pcb"
        copy_board(out, updated)
        drive(updated, [["menu", "Edit", "Update All Tuning Patterns", 20], ["save"]])
        print(updated, len(gens), file=sys.stderr)


# MARK: - Boards as KiCad reads them

def generated_texts(text):
    """Each `(generated ...)` of a board's text, as it is written there"""
    out = []
    i = text.find("(generated")
    while i >= 0:
        depth = 0
        j = i
        quoted = False
        while j < len(text):
            ch = text[j]
            if quoted:
                if ch == "\\":
                    j += 1
                elif ch == '"':
                    quoted = False
            elif ch == '"':
                quoted = True
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        out.append(text[i:j + 1])
        i = text.find("(generated", j)
    return out


def check(boards):
    import pcbnew
    result = {}
    for board in boards:
        b = pcbnew.LoadBoard(board)
        gens = []
        # (a generator's SWIG pointer is bare: the board's item of its uuid is a BOARD_ITEM, a PCB_GROUP underneath)
        root = parse(open(board).read())
        for node in root:
            if head(node) != "generated":
                continue
            uuid = text(child(node, "uuid")[1])
            item = b.ResolveItem(pcbnew.KIID(uuid))
            entry = {"uuid": uuid, "found": item is not None and item.GetClass() == "PCB_GENERATOR"}
            if entry["found"]:
                grp = pcbnew.Cast_to_PCB_GROUP(item)
                entry["name"] = grp.GetName()
                entry["layer"] = grp.GetLayerName()
                entry["members"] = sorted(m.m_Uuid.AsString() for m in grp.GetItems())
            gens.append(entry)
        with tempfile.TemporaryDirectory() as tmp:
            saved = os.path.join(tmp, "saved.kicad_pcb")
            pcbnew.SaveBoard(saved, b)
            nodes = generated_texts(open(saved).read())
            drc_path = os.path.join(tmp, "drc.json")
            pro = board[:-len(".kicad_pcb")] + ".kicad_pro"
            work = os.path.join(tmp, "b.kicad_pcb")
            shutil.copy(board, work)
            if os.path.exists(pro):
                shutil.copy(pro, os.path.join(tmp, "b.kicad_pro"))
            subprocess.run(["kicad-cli", "pcb", "drc", "--format", "json", "--severity-all", "-o", drc_path, work],
                           capture_output=True, text=True)
            drc = json.load(open(drc_path)) if os.path.exists(drc_path) else {}
        # (each violation by its type and the items it names, as the report describes them: the items' uuids differ
        # from board to board where their tracks are the same)
        violations = sorted(f'{v["type"]}: ' + " / ".join(sorted(i.get("description", "") for i in v.get("items", [])))
                            for v in drc.get("violations", []))
        result[board] = {"generators": len(list(b.Generators())), "patterns": gens, "saved": nodes, "drc": violations}
    json.dump(result, sys.stdout, indent=1)


def saved(boards):
    """BOARD.saved beside each board: its generated items as KiCad writes them having read the board"""
    import pcbnew
    for board in boards:
        b = pcbnew.LoadBoard(board)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "saved.kicad_pcb")
            pcbnew.SaveBoard(path, b)
            nodes = generated_texts(open(path).read())
        with open(board[:-len(".kicad_pcb")] + ".saved", "w") as f:
            json.dump({"saved": nodes}, f, indent=1)


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "boards":
        boards(sys.argv[2], int(sys.argv[3]), sys.argv[4] if len(sys.argv) > 4 else "20261129")
    elif len(sys.argv) >= 2 and sys.argv[1] == "place":
        place(sys.argv[2:])
    elif len(sys.argv) >= 2 and sys.argv[1] == "edit":
        edit(sys.argv[2:])
    elif len(sys.argv) >= 2 and sys.argv[1] == "remove":
        remove(sys.argv[2:])
    elif len(sys.argv) >= 2 and sys.argv[1] == "rules":
        rules(sys.argv[2:])
    elif len(sys.argv) >= 2 and sys.argv[1] == "check":
        check(sys.argv[2:])
    elif len(sys.argv) >= 2 and sys.argv[1] == "saved":
        saved(sys.argv[2:])
    else:
        sys.exit(__doc__)
