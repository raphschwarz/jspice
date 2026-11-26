#!/usr/bin/env python3
"""Where KiCad's PCB editor snaps the pointer to the board's items (PCB_GRID_HELPER::BestSnapAnchor, its magnetic
points), for checking the port's (KiCadRouter's BoardSnapping.swift: PCBGridHelper, SnapBoard) against.

KiCad's Python module reaches neither the grid helper nor the tools that use it. So, as drawing.py does (whose
action plugin this uses), this runs KiCad's PCB editor itself under Xvfb, with a copy of the user's configuration
whose grid is a micrometre, whose Magnetic Points snap to pads, tracks and graphics always (CAPTURE_ALWAYS), whose
angle snap is off, and whose advanced settings turn KiCad 10's extension snaps off (EnableExtensionSnaps=0: the
construction geometry it activates after the pointer rests half a second, which depends on the clock); and draws
lines with Place > Draw Lines from a point near one of the board's items to another, as a user does: the pointer
moved to a pixel and clicked, moved and clicked again, Escape. Each line KiCad drew starts and ends where its grid
helper put the pointer.

    snapping.py boards OUTDIR BOARD.kicad_pcb...
        each board copied to OUTDIR with graphics of its own added on F.Cu (lines crossing each other, a circle, an
        arc, a rectangle: KiCad's pcbnew module adds them and saves it), and beside it BOARD.plan: the lines to
        draw, each from near an anchor of the board's on F.Cu (a pad's centre or corner, a track's end, a via, a
        footprint's position, a zone's corner, a graphic's end, middle, centre or corner), a little or a lot off it,
        to near another, or to a point level with the first or below it (where the snap line through the first
        catches the pointer), or anywhere; and for some boards, local settings of their own (BOARD.plan's "prl":
        inactive layers dimmed, tracks, vias, pads, zones or front footprints hidden), which KiCad opens them on.
    snapping.py draw BOARD.kicad_pcb...
        the plan of each board done in KiCad; BOARD.snapped (JSON): every event the pointer made (the pixel, the
        micrometre of the grid it was at, its place on the board to a fraction of a nanometre by the view's
        transform), the ids of the lines each step drew and their ends as KiCad saved them.

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
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import drawing  # noqa: E402  (its action plugin)


def anchors_of(board):
    """Points of the board's items on F.Cu that KiCad snaps to (mm), and the board's box"""
    import pcbnew
    out = []
    mm = lambda v: [v.x / 1e6, v.y / 1e6]
    for fp in board.GetFootprints():
        if fp.GetLayer() == pcbnew.F_Cu:
            out.append(mm(fp.GetPosition()))
        for pad in fp.Pads():
            if pad.IsOnLayer(pcbnew.F_Cu):
                out.append(mm(pad.GetPosition()))
                bb = pad.GetBoundingBox()
                out.append([bb.GetLeft() / 1e6, bb.GetTop() / 1e6])
    for t in board.GetTracks():
        if t.GetClass() == "PCB_VIA":
            out.append(mm(t.GetPosition()))
        elif t.GetLayer() == pcbnew.F_Cu:
            out += [mm(t.GetStart()), mm(t.GetEnd())]
    for z in board.Zones():
        if z.IsOnLayer(pcbnew.F_Cu) and not z.GetIsRuleArea():
            o = z.Outline()
            for i in range(min(o.TotalVertices(), 8)):
                out.append(mm(o.CVertex(i)))
    for d in board.GetDrawings():
        if d.GetClass() == "PCB_SHAPE" and d.GetLayer() == pcbnew.F_Cu:
            s = pcbnew.Cast_to_PCB_SHAPE(d)
            out += [mm(s.GetStart()), mm(s.GetEnd()), mm(s.GetCenter())]
    bb = board.GetBoardEdgesBoundingBox()
    return out, (bb.GetLeft() / 1e6, bb.GetTop() / 1e6, bb.GetRight() / 1e6, bb.GetBottom() / 1e6)


def add_graphics(rng, board, box):
    import pcbnew
    l, t, r, b = box
    w, h = r - l, b - t
    pt = lambda x, y: pcbnew.VECTOR2I(int(round((l + x * w) * 1e3)) * 1000, int(round((t + y * h) * 1e3)) * 1000)

    def shape(kind):
        s = pcbnew.PCB_SHAPE(board)
        s.SetShape(kind)
        s.SetLayer(pcbnew.F_Cu)
        s.SetWidth(200000)
        return s
    for _ in range(3):
        s = shape(pcbnew.SHAPE_T_SEGMENT)
        s.SetStart(pt(rng.uniform(0.15, 0.5), rng.uniform(0.15, 0.85)))
        s.SetEnd(pt(rng.uniform(0.5, 0.85), rng.uniform(0.15, 0.85)))
        board.Add(s)
    s = shape(pcbnew.SHAPE_T_CIRCLE)
    c = pt(rng.uniform(0.3, 0.7), rng.uniform(0.3, 0.7))
    s.SetStart(c)
    s.SetEnd(pcbnew.VECTOR2I(c.x + int(rng.uniform(2, 6)) * 1000000, c.y))
    board.Add(s)
    s = shape(pcbnew.SHAPE_T_ARC)
    s.SetArcGeometry(pt(0.2, 0.3), pt(0.35, 0.2), pt(0.5, 0.35))
    board.Add(s)
    s = shape(pcbnew.SHAPE_T_RECTANGLE)
    s.SetStart(pt(rng.uniform(0.2, 0.4), rng.uniform(0.5, 0.6)))
    s.SetEnd(pt(rng.uniform(0.6, 0.8), rng.uniform(0.7, 0.85)))
    board.Add(s)


def make_plan(rng, anchors, box):
    l, t, r, b = box
    lines = []

    def near(p):
        d = rng.choice([0.0, 0.03, 0.08, 0.15, 0.3, 0.6, 1.2])
        a = rng.uniform(0, 2 * math.pi)
        return [p[0] + d * math.cos(a), p[1] + d * math.sin(a)]
    for _ in range(14):
        a = rng.choice(anchors)
        p1 = near(a)
        k = rng.random()
        if k < 0.45:
            p2 = near(rng.choice(anchors))
        elif k < 0.75:
            along = rng.choice([-1, 1]) * rng.uniform(2, 8)
            off = rng.choice([0.0, 0.05, 0.12, 0.25])
            p2 = [a[0] + along, a[1] + off] if rng.random() < 0.5 else [a[0] + off, a[1] + along]
        else:
            p2 = [rng.uniform(l, r), rng.uniform(t, b)]
        lines.append([p1, p2])
    # (a place far from everything for the pointer to wait at between lines)
    neutral = [l - 3, t - 3]
    return {"lines": lines, "neutral": neutral}


def boards(out, paths):
    import pcbnew
    os.makedirs(out, exist_ok=True)
    for path in paths:
        name = os.path.basename(path)[: -len(".kicad_pcb")]
        rng = random.Random(zlib.crc32(("snapping " + name).encode()))
        base = os.path.join(out, "snap-" + name)
        board = pcbnew.LoadBoard(path)
        _, box = anchors_of(board)
        add_graphics(rng, board, box)
        pcbnew.SaveBoard(base + ".kicad_pcb", board)
        pro = path[: -len(".kicad_pcb")] + ".kicad_pro"
        if os.path.exists(pro):
            shutil.copy(pro, base + ".kicad_pro")
        board = pcbnew.LoadBoard(base + ".kicad_pcb")
        anchors, box = anchors_of(board)
        plan = make_plan(rng, anchors, box)
        if rng.random() < 0.5:
            # (now and then the board opened on local settings of its own: inactive layers dimmed, or a layer or an
            # object hidden, which the pointer then does not snap to)
            hidden = rng.sample(["tracks", "vias", "pads", "zones", "footprints_front"], rng.randint(0, 2))
            items = [i for i in ["vias", "footprint_text", "footprint_anchors", "ratsnest", "grid", "footprints_front",
                                 "footprints_back", "footprint_values", "footprint_references", "tracks", "drc_errors",
                                 "drawing_sheet", "bitmaps", "pads", "zones", "drc_warnings", "drc_exclusions",
                                 "locked_item_shadows", "conflict_shadows", "shapes", "board_outline_area", "ly_points"]
                     if i not in hidden]
            plan["prl"] = json.dumps({"board": {"high_contrast_mode": rng.choice([0, 1, 1]), "active_layer": 0,
                                                "visible_items": items}}, indent=2)
        with open(base + ".plan", "w") as f:
            json.dump(plan, f, indent=1)
        print(base + ".kicad_pcb", file=sys.stderr)


def events(plan):
    steps = [["zoom"], ["calibrate"]]
    for i, (p1, p2) in enumerate(plan["lines"]):
        steps += [["move", plan["neutral"]], ["mark", i], ["menu", drawing.TOOLS["line"]],
                  ["move", p1], ["check"], ["click"], ["move", p2], ["check"], ["click"],
                  ["key", "escape"], ["key", "escape"], ["made", i]]
    steps += [["save"], ["copy", "-snapped"]]
    return steps


def drive(board, plan, fresh, ticks=9000):
    with tempfile.TemporaryDirectory() as tmp:
        share = os.path.join(tmp, "share")
        plugins = os.path.join(share, "kicad", "10.0", "scripting", "plugins")
        os.makedirs(plugins)
        with open(os.path.join(plugins, "jspice_drawing.py"), "w") as f:
            f.write(drawing.PLUGIN)
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
        editing["magnetic_graphics"] = True
        editing["magnetic_pads"] = 2
        editing["magnetic_tracks"] = 2
        editing["magnetic_all_layers"] = False
        editing["pcb_angle_snap_mode"] = 0
        json.dump(cfg, open(pj, "w"))
        with open(os.path.join(config, "10.0", "kicad_advanced"), "w") as f:
            f.write("EnableExtensionSnaps=0\n")
        job = {"steps": events(plan), "log": os.path.join(tmp, "log.txt"), "out": os.path.join(tmp, "out.json"),
               "ticks": ticks, "board": os.path.abspath(board), "debug": None}
        with open(os.path.join(tmp, "job.json"), "w") as f:
            json.dump(job, f)
        env = dict(os.environ, XDG_DATA_HOME=share, KICAD_CONFIG_HOME=config, JSPICE_DRAWING_JOB=os.path.join(tmp, "job.json"))
        text = ""
        for attempt in range(4):
            for p in (job["log"], job["out"]):
                if os.path.exists(p):
                    os.remove(p)
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
                return json.load(open(job["out"]))
            print(f"{board}: try {attempt + 1} did not finish ({run.returncode}): {text[-3000:]}", file=sys.stderr)
        sys.exit(f"{board}: KiCad did not finish ({run.returncode}): {text} {run.stderr[-2000:]}")


def draw(paths):
    import pcbnew
    for board in paths:
        base = board[:-len(".kicad_pcb")]
        plan = json.load(open(base + ".plan"))
        work = base + "-work.kicad_pcb"

        def fresh():
            shutil.copy(board, work)
            if os.path.exists(base + ".kicad_pro"):
                shutil.copy(base + ".kicad_pro", work[:-len(".kicad_pcb")] + ".kicad_pro")
            prl = work[:-len(".kicad_pcb")] + ".kicad_prl"
            if os.path.exists(prl):
                os.remove(prl)
            if plan.get("prl"):
                with open(prl, "w") as f:
                    f.write(plan["prl"])
        done = drive(work, plan, fresh)
        wbase = work[:-len(".kicad_pcb")]
        drawn = pcbnew.LoadBoard(wbase + "-snapped.kicad_pcb")
        lines = {}
        for d in drawn.GetDrawings():
            u = d.m_Uuid.AsString()
            if any(u in v for v in done.get("made", {}).values()):
                s = pcbnew.Cast_to_PCB_SHAPE(d)
                lines[u] = {"start": [s.GetStart().x, s.GetStart().y], "end": [s.GetEnd().x, s.GetEnd().y],
                            "width": s.GetWidth(), "layer": s.GetLayerName()}
        for ext in (".kicad_pcb", ".kicad_pro", ".kicad_prl", "-snapped.kicad_pcb", "-snapped.kicad_pro"):
            if os.path.exists(wbase + ext):
                os.remove(wbase + ext)
        record = {"plan": plan, "transform": done.get("transform"), "events": done["events"], "made": done.get("made", {}),
                  "lines": lines, "dialogs": done.get("dialogs", [])}
        with open(base + ".snapped", "w") as f:
            json.dump(record, f, indent=1)
        print(base, len(done["events"]), "events", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    if sys.argv[1] == "boards":
        boards(sys.argv[2], sys.argv[3:])
    elif sys.argv[1] == "draw":
        draw(sys.argv[2:])
    else:
        sys.exit(__doc__)
