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
    snapping.py tools OUTDIR BOARD.kicad_pcb...
        for each board (copied to OUTDIR, if it is not there: those `boards` made), BOARD.tplan: steps of KiCad's
        other tools that snap the pointer, the pointer moved near the board's anchors on F.Cu (now and then with
        Shift or Ctrl held): footprints moved (M with the pointer on one: EDIT_TOOL::doMoveSelection), zones and a
        rule area drawn (Place > Draw Filled Zones, Draw Rule Areas: DRAWING_TOOL::DrawZone), texts placed (Draw
        Text: PlaceText), a footprint placed (Place Footprints, from a library of one footprint: PlaceFootprint),
        corners and sides of the board's graphics and corners of zones dragged with the point editor.
    snapping.py use BOARD.kicad_pcb...
        the tools plan of each board done in KiCad; BOARD.used (JSON): every event (the pixel KiCad's move warped the
        pointer to among them), and what each step changed (footprints' places, zones' outlines, texts' places,
        graphics' points) as KiCad had it after the step.

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


def drive(board, plan, fresh, ticks=9000, steps=None, plugin=None, setup=None, extra=None):
    """KiCad's PCB editor run on `board` doing `steps` (the plan's lines drawn, by default) with `plugin` (drawing.py's,
    by default); `setup` given the folder of the configuration copied, before KiCad starts; `extra`: more for the
    plugin's job"""
    with tempfile.TemporaryDirectory() as tmp:
        share = os.path.join(tmp, "share")
        plugins = os.path.join(share, "kicad", "10.0", "scripting", "plugins")
        os.makedirs(plugins)
        with open(os.path.join(plugins, "jspice_drawing.py"), "w") as f:
            f.write(plugin or drawing.PLUGIN)
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
        if setup:
            setup(os.path.join(config, "10.0"), tmp)
        job = {"steps": steps if steps is not None else events(plan), "log": os.path.join(tmp, "log.txt"), "out": os.path.join(tmp, "out.json"),
               "ticks": ticks, "board": os.path.abspath(board),
               "debug": os.environ.get("JSPICE_SNAPPING_DEBUG")}
        job.update(extra or {})
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
                done = json.load(open(job["out"]))
                done["log"] = text
                return done
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



# MARK: - The other tools that snap the pointer

# (the footprint Add Footprint places, from a library of its own that holds it alone)
PLACED_LIBRARY = "/usr/share/kicad/footprints/Resistor_SMD.pretty"
PLACED_FOOTPRINT = "R_0603_1608Metric"

TOOL_MENUS = {"zone": ["Place", "Draw Filled Zones"], "rule": ["Place", "Draw Rule Areas"], "text": ["Place", "Draw Text"],
              "footprint": ["Place", "Place Footprints"]}


def clear_of(board, p, mm=0.5, keep=None):
    """Whether nothing of the board's but `keep` (a footprint) is within `mm` of `p` (mm): what a click or a hover
    there picks is `keep`, or nothing"""
    import pcbnew
    pt = pcbnew.VECTOR2I(int(round(p[0] * 1e6)), int(round(p[1] * 1e6)))
    acc = int(mm * 1e6)
    for t in board.GetTracks():
        if t.HitTest(pt, acc):
            return False
    for d in board.GetDrawings():
        if d.HitTest(pt, acc):
            return False
    for z in board.Zones():
        if z.HitTestForEdge(pt, acc) or z.HitTestForCorner(pt, acc):
            return False
    for fp in board.GetFootprints():
        if keep is not None and fp.m_Uuid.AsString() == keep:
            continue
        if fp.HitTest(pt, acc):
            return False
    return True


def tools_plan(rng, board, anchors, box):
    """The steps of a board's plan of the other tools: footprints moved (KiCad's Move, M with the pointer on them),
    zones and rule areas drawn, texts and a footprint placed, corners of graphics and zones dragged with the point
    editor; each pointer move near one of the board's anchors on F.Cu (a little or a lot off it) or anywhere, now
    and then with Shift or Ctrl held"""
    import pcbnew
    l, t, r, b = box
    mm = lambda v: [v.x / 1e6, v.y / 1e6]

    def near(p, far=False):
        d = rng.choice([0.0, 0.03, 0.08, 0.15, 0.3] + ([0.6, 1.2] if far else []))
        a = rng.uniform(0, 2 * math.pi)
        return [p[0] + d * math.cos(a), p[1] + d * math.sin(a)]

    def mods():
        return rng.choice([[], [], [], [], [], ["shift"], ["ctrl"]])

    def target(around=None, within=None):
        if around is not None:
            close = [a for a in anchors if math.hypot(a[0] - around[0], a[1] - around[1]) < within]
            if close and rng.random() < 0.85:
                return near(rng.choice(close))
            ang = rng.uniform(0, 2 * math.pi)
            dist = rng.uniform(1, within)
            return [around[0] + dist * math.cos(ang), around[1] + dist * math.sin(ang)]
        if rng.random() < 0.85:
            return near(rng.choice(anchors), far=True)
        return [rng.uniform(l, r), rng.uniform(t, b)]

    steps = []
    # footprints moved: the pointer on one (its position, a pad's centre or its box's), clear of all else
    movable = [fp for fp in board.GetFootprints() if fp.GetLayer() == pcbnew.F_Cu and not fp.IsLocked() and len(fp.Pads())]
    rng.shuffle(movable)
    moved = 0
    for fp in movable:
        if moved >= 4:
            break
        uuid = fp.m_Uuid.AsString()
        spots = [mm(fp.GetPosition()), mm(fp.GetBoundingBox(False).Centre())] + [mm(p.GetPosition()) for p in fp.Pads()]
        spots = [p for p in spots if clear_of(board, p, 0.5, keep=uuid)
                 and fp.HitTest(pcbnew.VECTOR2I(int(p[0] * 1e6), int(p[1] * 1e6)), 0)]
        if not spots:
            continue
        hover = rng.choice(spots)
        at = mm(fp.GetPosition())
        path = []
        for _ in range(rng.choice([1, 2, 3])):
            path.append({"at": target(at, 12), "mods": mods()})
        steps.append({"op": "move", "footprint": uuid, "hover": hover, "path": path})
        moved += 1
    # zones and rule areas drawn: corners near the board's anchors about a place (two millimetres apart at least), in
    # order round it
    for kind in ["zone", "zone", "rule"]:
        centre = rng.choice(anchors)
        corners = []
        for _ in range(100):
            if len(corners) == 5 or (len(corners) >= 3 and rng.random() < 0.4):
                break
            c = target(centre, 10)
            if all(math.hypot(c[0] - o["at"][0], c[1] - o["at"][1]) > 2 for o in corners):
                corners.append({"at": c, "mods": mods()})
        corners.sort(key=lambda c: math.atan2(c["at"][1] - centre[1], c["at"][0] - centre[0]))
        finish = rng.choice(["double", "double", "first"])
        if finish == "first":
            # (the first corner on an anchor, for the click there at the end to come to it again, as a user's does)
            corners[0]["at"] = min(anchors, key=lambda a: math.hypot(a[0] - corners[0]["at"][0], a[1] - corners[0]["at"][1]))
            corners[0]["mods"] = []
        steps.append({"op": kind, "corners": corners, "finish": finish,
                      "between": [{"at": target(c["at"], 3), "mods": []} for c in corners]})
    # texts and a footprint placed: the tool picked with the pointer at a place, the pointer moved, a click to place
    for kind in ["text", "text", "footprint"]:
        first = target()
        path = [{"at": target(first, 8), "mods": mods()} for _ in range(rng.choice([1, 2]))]
        steps.append({"op": kind, "first": {"at": first, "mods": []}, "path": path})
    # corners dragged with the point editor: graphics' on F.Cu, the zones' on it (the board's, and the first drawn)
    handles = []
    for d in board.GetDrawings():
        if d.GetClass() != "PCB_SHAPE" or d.GetLayer() != pcbnew.F_Cu:
            continue
        s = pcbnew.Cast_to_PCB_SHAPE(d)
        u = d.m_Uuid.AsString()
        k = s.GetShape()
        if k == pcbnew.SHAPE_T_SEGMENT:
            handles += [(u, "start"), (u, "end")]
        elif k == pcbnew.SHAPE_T_RECTANGLE:
            handles += [(u, f"corner{i}") for i in range(4)] + [(u, f"side{i}") for i in range(4)]
        elif k == pcbnew.SHAPE_T_CIRCLE:
            handles += [(u, "end")]
    rng.shuffle(handles)
    edits = [{"shape": u, "handle": h} for u, h in handles[:3]]
    zones = [z for z in board.Zones() if z.IsOnLayer(pcbnew.F_Cu) and not z.GetIsRuleArea() and not z.IsLocked()]
    if zones:
        z = rng.choice(zones)
        edits.append({"zone": z.m_Uuid.AsString(), "handle": f"corner{rng.randrange(min(z.Outline().TotalVertices(), 4))}"})
    first_zone = next(i for i, s in enumerate(steps) if s["op"] == "zone")
    edits.append({"zone": f"made:{first_zone}", "handle": f"corner{rng.randrange(3)}"})
    for e in edits:
        e["op"] = "edit"
        # (the moves of the drag in the plugin, from where KiCad has the handle: a first beyond the drag threshold)
        e["toward"] = rng.choice(["anchor", "anchor", "free"])
        e["picks"] = [rng.random() for _ in range(4)]
        e["mods"] = mods()
        steps.append(e)
    return {"tools": steps, "neutral": [l - 3, t - 3]}


def tools_events(plan, anchors):
    """The plugin's steps for a plan of the other tools"""
    steps = [["zoom"], ["calibrate"], ["tmark"]]

    def go(p, held):
        """the pointer moved to `p` (with its modifiers held, those it had let go)"""
        out = []
        for m in sorted(held - set(p["mods"])):
            out.append(["release", m])
        for m in sorted(set(p["mods"]) - held):
            out.append(["hold", m])
        out += [["move", p["at"]], ["check"]]
        return out, set(p["mods"])

    only = os.environ.get("JSPICE_SNAPPING_STEPS")
    for i, s in enumerate(plan["tools"]):
        if only and str(i) not in only.split(","):
            continue
        steps += [["move", plan["neutral"]], ["key", "escape"], ["key", "escape"], ["mark", i]]
        held = set()
        if s["op"] == "move":
            steps += [["move", s["hover"]], ["check"], ["press", "m"], ["warped"], ["msel", i, s["footprint"]]]
            for p in s["path"]:
                more, held = go(p, held)
                steps += more
            steps += [["click"]]
        elif s["op"] in ("zone", "rule"):
            steps += [["menu", TOOL_MENUS[s["op"]]]]
            for k, c in enumerate(s["corners"]):
                more, held = go(c, held)
                steps += more + [["click"]]
                if k + 1 < len(s["corners"]):
                    more, held = go(s["between"][k], held)
                    steps += more
            if s["finish"] == "double":
                # (the double click with the keys the last corner was clicked with: whether its first click comes to
                # KiCad's tool as a click of its own or not, which hangs on how fast KiCad sees the button go up, it
                # is where that corner is)
                steps += [["dclick"]]
            else:
                more, held = go(s["corners"][0], held)
                steps += more + [["click"]]
        elif s["op"] in ("text", "footprint"):
            # (with KiCad's immediate actions, its default, the tool starts with a click where the pointer is: the
            # text made there, its dialog shown, or the footprint chooser; then what it made follows the pointer)
            more, held = go(s["first"], held)
            steps += more + [["menu", TOOL_MENUS[s["op"]]], ["settle"]]
            for p in s["path"]:
                more, held = go(p, held)
                steps += more
            steps += [["click"]]
        elif s["op"] == "edit":
            spec = {k: s[k] for k in ("shape", "zone") if k in s}
            steps += [["eselect", spec, s["handle"]], ["click"], ["echeck", spec, i], ["ehover", spec, s["handle"]], ["down"],
                      ["edrag", spec, s["handle"], s["toward"], s["picks"], s["mods"]], ["up"]]
            held = set(s["mods"])
        for m in sorted(held):
            steps.append(["release", m])
        if os.environ.get("JSPICE_SNAPPING_SHOTS"):
            steps.append(["shot", os.path.join(os.environ["JSPICE_SNAPPING_SHOTS"], f"step{i}.png")])
        steps += [["key", "escape"], ["key", "escape"], ["tmade", i]]
    steps += [["save"], ["copy", "-used"]]
    return steps


# (the plugin's steps for the other tools, on drawing.py's: added to its own)
TOOLS_PLUGIN = r'''

ANCHORS = JOB.get("anchors", [])
dlg = {}


def tree(w, depth=0):
    """A window and what is in it, for the log"""
    out = [("  " * depth) + f"{w.GetClassName()} name={w.GetName()!r} id={w.GetId()} label={getattr(w, 'GetLabel', lambda: '')()!r}"]
    for c in w.GetChildren():
        out += tree(c, depth + 1)
    return out


def snapshot():
    """The board's footprints, zones, texts and graphics as KiCad has them now (nm)"""
    b = pcbnew.GetBoard()
    xy = lambda v: [v.x, v.y]
    fps = {f.m_Uuid.AsString(): {"at": xy(f.GetPosition()), "angle": f.GetOrientationDegrees(), "layer": f.GetLayerName(),
                                 "fpid": f.GetFPIDAsString()} for f in b.GetFootprints()}
    zones = {}
    for z in b.Zones():
        o = z.Outline()
        rings = []
        for i in range(o.OutlineCount()):
            c = o.Outline(i)
            rings.append([xy(c.CPoint(k)) for k in range(c.PointCount())])
            for h in range(o.HoleCount(i)):
                c = o.Hole(i, h)
                rings.append([xy(c.CPoint(k)) for k in range(c.PointCount())])
        zones[z.m_Uuid.AsString()] = {"rings": rings, "layers": [b.GetLayerName(l) for l in z.GetLayerSet().Seq()],
                                      "rule": z.GetIsRuleArea(), "net": z.GetNetname()}
    texts, shapes = {}, {}
    for d in b.GetDrawings():
        u = d.m_Uuid.AsString()
        if d.GetClass() == "PCB_TEXT":
            texts[u] = {"at": xy(d.GetPosition()), "layer": d.GetLayerName(), "text": d.GetText()}
        elif d.GetClass() == "PCB_SHAPE":
            s = pcbnew.Cast_to_PCB_SHAPE(d)
            e = {"shape": s.ShowShape(), "start": xy(s.GetStart()), "end": xy(s.GetEnd()), "layer": s.GetLayerName()}
            if s.GetShape() == pcbnew.SHAPE_T_ARC:
                e["mid"] = xy(s.GetArcMid())
            shapes[u] = e
    return {"footprints": fps, "zones": zones, "texts": texts, "shapes": shapes}


def zone_by(spec):
    z = spec["zone"]
    if z.startswith("made:"):
        made = out.get("made", {}).get(z[5:], {})
        new = [u for u in made.get("zones", {}) if made["zones"][u] is not None]
        if not new:
            return None
        z = new[0]
    return next((x for x in pcbnew.GetBoard().Zones() if x.m_Uuid.AsString() == z), None)


def handle_at(spec, handle):
    """Where the point editor has the handle of a graphic or zone, and a point of its outline to select it by (nm)"""
    if "shape" in spec:
        return handle_of(drawings()[spec["shape"]], handle)
    z = zone_by(spec)
    if z is None:
        return None
    c = z.Outline().Outline(0)
    k = int(handle[6:]) % c.PointCount()
    a, b = c.CPoint(k), c.CPoint((k + 1) % c.PointCount())
    return [a.x, a.y], [(a.x + b.x) // 2, (a.y + b.y) // 2]


def skip_to_made():
    steps = JOB["steps"]
    j = state["step"] + 1
    while j < len(steps) and steps[j][0] != "tmade":
        j += 1
    state["step"] = j - 1


def window_state(w):
    """What the plugin has done with the dialog or window `w` KiCad shows (one at a time), its sightings counted"""
    key = (w.GetId(), w.GetTitle())
    if dlg.get("key") != key:
        dlg.clear()
        dlg.update(key=key, n=0)
    dlg["n"] += 1
    return dlg


def prepare_dialog(w):
    title = w.GetTitle()
    seen = window_state(w)
    if seen["n"] == 1:
        log("dialog", title, "\n".join(tree(w)))
    if "Text Properties" in title:
        # (the text typed in, as a user types it)
        if not seen.get("typed"):
            stc = [c for c in walk(w) if "StyledTextCtrl" in c.GetClassName() and c.IsShown()]
            if stc:
                stc[0].SetFocus()
                sim.Char(ord("T"))
            seen["typed"] = True
            return False
        return seen["n"] > 3
    if "Footprint" in title and "Properties" not in title:
        # (the footprint chooser, if a dialog: the footprint looked for, then chosen)
        found = [c for c in walk(w) if c.GetClassName() in ("wxSearchCtrl", "wxTextCtrl") and c.IsShown()]
        if seen["n"] == 1 and found:
            found[0].SetFocus()
            found[0].SetValue(PLACED)
        return seen["n"] > 6
    return True


def chooser_frame():
    f = frame()
    for w in wx.GetTopLevelWindows():
        if w is not f and w.IsShown() and not isinstance(w, wx.Dialog) and w.FindWindow(wx.ID_OK) is not None:
            return w
    return None


_base_act = act


def act(s):
    kind = s[0]
    ev = {"ev": kind}
    if kind != "settle":
        dlg.clear()
    if kind == "tmark":
        state["snap"] = snapshot()
        return
    elif kind == "tmade":
        now, was = snapshot(), state.get("snap") or {}
        diff = {}
        for key in now:
            d = {u: v for u, v in now[key].items() if was.get(key, {}).get(u) != v}
            d.update({u: None for u in was.get(key, {}) if u not in now[key]})
            if d:
                diff[key] = d
        out.setdefault("made", {})[str(s[1])] = diff
        state["snap"] = now
        ev.update(step=s[1], made=diff)
    elif kind == "press":
        canvas().SetFocus()
        sim.Char(ord(s[1]))
        ev["key"] = s[1]
        state["wait"] = 10
    elif kind in ("hold", "release"):
        code = {"shift": wx.WXK_SHIFT, "ctrl": wx.WXK_CONTROL}[s[1]]
        (sim.KeyDown if kind == "hold" else sim.KeyUp)(code)
        ev["key"] = s[1]
        state["wait"] = 4
    elif kind == "warped":
        # (where KiCad's move warped the pointer: the point it picked the footprint up by)
        q = wx.GetMousePosition()
        q = (q.x, q.y)
        w = to_world(q)
        ev.update(pixel=q, raw=[w[0] * 1e6, w[1] * 1e6])
    elif kind == "msel":
        sel = [i.m_Uuid.AsString() for i in pcbnew.GetCurrentSelection()]
        ev.update(step=s[1], selection=sel, ok=sel == [s[2]])
        if sel != [s[2]]:
            sim.Char(wx.WXK_ESCAPE)
            skip_to_made()
            state["wait"] = 10
    elif kind == "echeck":
        # (the graphic or zone the click selected, alone: else what the drag does is not the point editor's)
        spec = s[1]
        want = spec.get("shape")
        if want is None:
            z = zone_by(spec)
            want = z.m_Uuid.AsString() if z is not None else None
        sel = [i.m_Uuid.AsString() for i in pcbnew.GetCurrentSelection()]
        ev.update(step=s[2], selection=sel, ok=want is not None and sel == [want])
        if not ev["ok"]:
            sim.Char(wx.WXK_ESCAPE)
            skip_to_made()
            state["wait"] = 10
    elif kind == "settle":
        # (the text's dialog, or the footprint chooser, done with: wait for it to go)
        if kind == "settle" and chooser_frame() is not None:
            w = chooser_frame()
            seen = window_state(w)
            if seen["n"] == 1:
                log("chooser", w.GetTitle(), "\n".join(tree(w)))
                found = [c for c in walk(w) if c.GetClassName() in ("wxSearchCtrl", "wxTextCtrl") and c.IsShown()]
                if found:
                    found[0].SetFocus()
                    found[0].SetValue(PLACED)
            elif seen["n"] == 8:
                ok = w.FindWindow(wx.ID_OK)
                evt = wx.CommandEvent(wx.wxEVT_BUTTON, wx.ID_OK)
                evt.SetEventObject(ok)
                wx.PostEvent(ok, evt)
            state["step"] -= 1
            state["wait"] = 4
            return
        if any(w.IsShown() and isinstance(w, wx.Dialog) for w in wx.GetTopLevelWindows()):
            state["step"] -= 1
            state["wait"] = 4
            return
        state["wait"] = 6
        if JOB.get("debug"):
            ev["texts"] = snapshot()["texts"]
            ev["selection"] = [i.m_Uuid.AsString() for i in pcbnew.GetCurrentSelection()]
    elif kind in ("eselect", "ehover"):
        found = handle_at(s[1], s[2])
        if found is None:
            ev["missing"] = True
            skip_to_made()
        else:
            at, on = found
            q, snapped, raw = pixel([(on if kind == "eselect" else at)[0] / 1e6, (on if kind == "eselect" else at)[1] / 1e6])
            sim.MouseMove(*q)
            ev.update(spec=s[1], handle=s[2], handleAt=at, pixel=q, at=snapped, raw=raw)
            state["wait"] = 4
    elif kind == "edrag":
        # (the drag's moves, from where KiCad has the handle now, toward an anchor near it or anywhere)
        found = handle_at(s[1], s[2])
        at = found[0] if found else state.get("anchor", [0, 0])
        at = [at[0] / 1e6, at[1] / 1e6]
        picks = s[4]
        close = [a for a in ANCHORS if 1.2 < math.hypot(a[0] - at[0], a[1] - at[1]) < 6]
        if s[3] == "anchor" and close:
            a = close[int(picks[0] * len(close)) % len(close)]
            d = [0.0, 0.03, 0.08, 0.15][int(picks[1] * 4) % 4]
            ang = picks[2] * 2 * math.pi
            end = [a[0] + d * math.cos(ang), a[1] + d * math.sin(ang)]
        else:
            ang = picks[2] * 2 * math.pi
            r = 2.5 + 1.5 * picks[3]
            end = [at[0] + r * math.cos(ang), at[1] + r * math.sin(ang)]
        mods = s[5]
        steps = JOB["steps"]
        more = []
        for t in (0.6, 0.8):
            more += [["move", [at[0] + (end[0] - at[0]) * t, at[1] + (end[1] - at[1]) * t]], ["check"]]
        more += [["hold", m] for m in mods]
        more += [["move", end], ["check"]]
        steps[state["step"] + 1:state["step"] + 1] = more
        ev.update(spec=s[1], handle=s[2], start=at, end=end)
    else:
        return _base_act(s)
    out["events"].append(ev)
    if JOB.get("debug"):
        with open(JOB["debug"], "w") as f:
            json.dump(out, f)
'''


def tools(out, paths):
    """Plans of the other tools for boards (each copied to OUTDIR if it is not there)"""
    import pcbnew
    os.makedirs(out, exist_ok=True)
    for path in paths:
        name = os.path.basename(path)[: -len(".kicad_pcb")]
        base = os.path.join(out, name)
        if os.path.abspath(path) != os.path.abspath(base + ".kicad_pcb"):
            shutil.copy(path, base + ".kicad_pcb")
            pro = path[: -len(".kicad_pcb")] + ".kicad_pro"
            if os.path.exists(pro):
                shutil.copy(pro, base + ".kicad_pro")
        rng = random.Random(zlib.crc32(("tools " + name).encode()))
        board = pcbnew.LoadBoard(base + ".kicad_pcb")
        anchors, box = anchors_of(board)
        plan = tools_plan(rng, board, anchors, box)
        plan["anchors"] = anchors
        with open(base + ".tplan", "w") as f:
            json.dump(plan, f, indent=1)
        print(base + ".tplan", file=sys.stderr)


def use(paths):
    """The plan of the other tools of each board done in KiCad: BOARD.used"""
    for board in paths:
        base = board[:-len(".kicad_pcb")]
        plan = json.load(open(base + ".tplan"))
        work = base + "-work.kicad_pcb"

        def fresh():
            shutil.copy(board, work)
            if os.path.exists(base + ".kicad_pro"):
                shutil.copy(base + ".kicad_pro", work[:-len(".kicad_pcb")] + ".kicad_pro")
            prl = work[:-len(".kicad_pcb")] + ".kicad_prl"
            if os.path.exists(prl):
                os.remove(prl)

        def setup(config, tmp):
            # (a library of the one footprint Add Footprint places)
            lib = os.path.join(tmp, "jspice.pretty")
            os.makedirs(lib)
            shutil.copy(os.path.join(PLACED_LIBRARY, PLACED_FOOTPRINT + ".kicad_mod"), lib)
            with open(os.path.join(config, "fp-lib-table"), "w") as f:
                f.write(f'(fp_lib_table\n\t(version 7)\n\t(lib (name "JSpice")(type "KiCad")(uri "{lib}")(options "")(descr ""))\n)\n')
        plugin = drawing.PLUGIN + TOOLS_PLUGIN.replace("PLACED)", repr(PLACED_FOOTPRINT) + ")")
        steps = tools_events(plan, plan["anchors"])
        done = drive(work, plan, fresh, ticks=20000, steps=steps, plugin=plugin, setup=setup,
                     extra={"anchors": plan["anchors"]})
        wbase = work[:-len(".kicad_pcb")]
        for ext in (".kicad_pcb", ".kicad_pro", ".kicad_prl", "-used.kicad_pcb", "-used.kicad_pro"):
            if os.path.exists(wbase + ext):
                os.remove(wbase + ext)
        with open(os.path.join(PLACED_LIBRARY, PLACED_FOOTPRINT + ".kicad_mod")) as f:
            placed = f.read()
        record = {"plan": plan, "transform": done.get("transform"), "events": done["events"], "made": done.get("made", {}),
                  "dialogs": done.get("dialogs", []), "placed": placed, "dragThreshold": done.get("dragThreshold")}
        with open(base + ".used", "w") as f:
            json.dump(record, f, indent=1)
        if os.environ.get("JSPICE_SNAPPING_DEBUG"):
            with open(base + ".log", "w") as f:
                f.write(done.get("log", ""))
        print(base, len(done["events"]), "events", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    if sys.argv[1] == "boards":
        boards(sys.argv[2], sys.argv[3:])
    elif sys.argv[1] == "draw":
        draw(sys.argv[2:])
    elif sys.argv[1] == "tools":
        tools(sys.argv[2], sys.argv[3:])
    elif sys.argv[1] == "use":
        use(sys.argv[2:])
    else:
        sys.exit(__doc__)
