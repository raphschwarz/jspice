#!/usr/bin/env python3
"""KiCad's Board Setup dialog, driven as a user drives it, for checking the port of what it does (KiCadRouter's
BoardEditing.setCopperLayerCount and its pre-defined sizes) against.

The dialog cannot be driven headless: KiCad's Python module reaches neither it nor the board's stackup. So this runs
KiCad's PCB editor itself (pcbnew, under Xvfb), with an action plugin of its own that, once the board is open, opens
File > Board Setup..., goes to its Physical Stackup page, picks a copper layer count there as a click on its choice
does (the choice's event: the page's onCopperLayersSelCount), presses OK (and OK on the warning of items on removed
layers, if KiCad gives one), and saves the board with File > Save. Each step is a run of its own on the board the step
before saved, so that what KiCad keeps between steps is what its file keeps. A board's pre-defined sizes are put
through the dialog's Pre-defined Sizes page the same way (opened, OK, saved), which writes the project's lists as the
page writes them.

    boardsetup.py edge OUTDIR
        writes OUTDIR/edge-6.kicad_pcb and .kicad_pro: a board of six copper layers with what removing layers reaches
        (blind, buried and micro vias, tracks and arcs on every layer, drawings, texts and a dimension on inner
        layers, zones on several layers with fills and hatch positions, a rule area on every copper layer, groups, a
        footprint with a pad with a hole on its front copper only and a drawing on an inner layer), a stackup of its
        own (colours, a locked dielectric, sublayers, materials not given), and pre-defined sizes out of order.
    boardsetup.py dialog BOARD.kicad_pcb...
        each board's copper layer count changed in KiCad's dialog step by step (from two layers: 4, 6, 2; four: 6, 2,
        4; six: 2, 8, 4; eight: 4, 2), and its pre-defined sizes put through it where its project has some; writes
        BOARD.setup beside it (JSON): for each step, the board KiCad saved, summarized (summary below), and what kicad-cli's
        Gerber job file of it says of its stackup; and the project's lists before and after the dialog.
    boardsetup.py check BOARD.kicad_pcb...
        each board summarized, its Gerber job file's stackup, and the sizes KiCad's router takes for each of its
        project's pre-defined track widths and via sizes as its track width menu picks them (JSON on standard output,
        the boards by their paths).

A board's summary: its (layers ...) and (general (thickness ...)); its (setup (stackup ...)) as a tree of words;
every board item with an id (tracks, vias, zones, drawings, texts, groups...), by id: its kind, the layers it is on
(wildcards spelled out to the board's own layers), a via's type, a zone's filled layers and those with properties, a
group's members; and every pad's layers. The job file's MaterialStackup, and whether its stackup was up to date
(KiCad's writer brings the stackup to the board's layers first, and leaves the thicknesses out where it had to).

KiCad 10's pcbnew and kicad-cli, Xvfb (xvfb-run) and a KiCad configuration made by running KiCad once (it is copied:
the plugin is put in a folder of its own, not in the user's).
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

STEPS = {2: [4, 6, 2], 4: [6, 2, 4], 6: [2, 8, 4], 8: [4, 2]}
HERE = os.path.dirname(os.path.abspath(__file__))


# MARK: - S-expressions

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
            stack[-1].append(re.sub(r'\\(.)', lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), t[1:-1]))
        else:
            stack[-1].append(t)
    return stack[0][0]


def head(node):
    return node[0] if isinstance(node, list) and node and isinstance(node[0], str) else None


def child(node, name):
    return next((c for c in node if head(c) == name), None)


def children(node, name):
    return [c for c in node if head(c) == name]


WILDCARDS = {"F&B.Cu": ["F.Cu", "B.Cu"], "*.Mask": ["F.Mask", "B.Mask"], "*.Paste": ["F.Paste", "B.Paste"],
             "*.SilkS": ["F.SilkS", "B.SilkS"], "*.Adhes": ["F.Adhes", "B.Adhes"], "*.Fab": ["F.Fab", "B.Fab"],
             "*.CrtYd": ["F.CrtYd", "B.CrtYd"]}


def expand(names, enabled, copper):
    out = set()
    for n in names:
        if n == "*.Cu":
            out.update(copper)
        elif n == "*In.Cu":
            out.update(c for c in copper if c.startswith("In"))
        else:
            out.update(WILDCARDS.get(n, [n]))
    return sorted(out & enabled)


def summary(path):
    root = parse(open(path, encoding="utf-8").read())
    layers = child(root, "layers")[1:]
    enabled = {entry[1] for entry in layers}
    copper = [entry[1] for entry in layers if entry[1].endswith(".Cu")]
    general = child(root, "general")
    thickness = child(general, "thickness")[1] if general and child(general, "thickness") else None
    setup = child(root, "setup") or []
    items = {}
    pads = {}
    for node in root[1:]:
        h = head(node)
        if h == "footprint":
            fid = child(node, "uuid")[1] if child(node, "uuid") else ""
            for k, pad in enumerate(children(node, "pad")):
                pid = child(pad, "uuid")[1] if child(pad, "uuid") else str(k)
                pl = child(pad, "layers")
                pads[fid + "/" + pid] = expand(pl[1:] if pl else [], enabled, copper)
            continue
        uid = child(node, "uuid") if isinstance(node, list) else None
        if not uid:
            continue
        entry = {"kind": h}
        if child(node, "layer"):
            entry["layers"] = expand([child(node, "layer")[1]], enabled, copper)
        elif child(node, "layers"):
            entry["layers"] = expand(child(node, "layers")[1:], enabled, copper)
        if h == "via":
            entry["type"] = next((t for t in node[1:] if t in ("blind", "buried", "micro")), "through")
            entry["layers"] = child(node, "layers")[1:]
        if h == "zone":
            entry["fills"] = sorted(child(f, "layer")[1] for f in children(node, "filled_polygon"))
            fill = child(node, "fill")
            entry["filled"] = bool(fill and "yes" in fill[1:])
            entry["properties"] = sorted(child(p, "layer")[1] for p in children(node, "property") if child(p, "layer"))
        if h == "group":
            members = child(node, "members")
            entry["members"] = sorted(members[1:]) if members else []
        items[uid[1]] = entry
    return {"layers": layers, "thickness": thickness, "stackup": child(setup, "stackup"), "items": items, "pads": pads}


def jobfile(path):
    with tempfile.TemporaryDirectory() as tmp:
        run = subprocess.run(["kicad-cli", "pcb", "export", "gerbers", "-o", tmp + "/", "-l", "F.Cu", path],
                             capture_output=True, text=True)
        jobs = [f for f in os.listdir(tmp) if f.endswith(".gbrjob")]
        if run.returncode != 0 or not jobs:
            sys.exit(f"{path}: kicad-cli wrote no job file: {run.stderr}")
        with open(os.path.join(tmp, jobs[0])) as f:
            job = json.load(f)
    # (KiCad's writer leaves the thicknesses out where it had to bring the stackup to the board's layers)
    material = job["MaterialStackup"]
    return {"material": material, "upToDate": any("Thickness" in m for m in material)}


# MARK: - KiCad's PCB editor, driven

PLUGIN = r'''
import json, os, traceback
import wx
import pcbnew

JOB = json.load(open(os.environ["JSPICE_BOARDSETUP_JOB"]))
state = {"phase": "wait", "ticks": 0}


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


def menu(command):
    f = frame()
    m = f.GetMenuBar().GetMenu(0)
    item = next(i for i in m.GetMenuItems() if i.GetItemLabelText() == command)
    evt = wx.CommandEvent(wx.wxEVT_MENU, item.GetId())
    evt.SetEventObject(m)
    wx.CallAfter(m.ProcessEvent, evt)


def click(dialog, wid):
    button = dialog.FindWindow(wid)
    evt = wx.CommandEvent(wx.wxEVT_BUTTON, wid)
    evt.SetEventObject(button)
    wx.PostEvent(button, evt)


def tick():
    try:
        state["ticks"] += 1
        if state["ticks"] > 400:
            log("timeout", state["phase"])
            os._exit(3)
        phase = state["phase"]
        if phase == "wait":
            # (a warning as the board is read: said, and closed)
            warning = shown("Warning")
            if warning is not None:
                log("load warning", [w.GetLabel() for w in walk(warning) if isinstance(w, wx.StaticText)])
                warning.EndModal(wx.ID_OK)
                state["quiet"] = 0
                return
            if shown("Load PCB") is not None:
                state["quiet"] = 0
                return
            state["quiet"] = state.get("quiet", 0) + 1
            f = frame()
            if f is not None and pcbnew.GetBoard() is not None and state["quiet"] > 8:
                menu("Board Setup...")
                state["phase"] = "dialog"
        elif phase == "dialog":
            dialog = shown("Board Setup")
            if dialog is None:
                return
            book = next(w for w in walk(dialog) if isinstance(w, wx.Treebook))
            book.SetSelection(next(i for i in range(book.GetPageCount()) if book.GetPageText(i) == JOB["page"]))
            state["phase"] = "page"
        elif phase == "page":
            dialog = shown("Board Setup")
            if JOB.get("copper"):
                choices = [w for w in walk(dialog) if isinstance(w, wx.Choice) and w.IsShownOnScreen()
                           and list(w.GetStrings())[:3] == ["2", "4", "6"]]
                if not choices:
                    return
                choice = choices[0]
                selection = JOB["copper"] // 2 - 1
                if choice.GetSelection() != selection:
                    choice.SetSelection(selection)
                    evt = wx.CommandEvent(wx.wxEVT_CHOICE, choice.GetId())
                    evt.SetEventObject(choice)
                    evt.SetInt(selection)
                    choice.GetEventHandler().ProcessEvent(evt)
            state["phase"] = "ok"
        elif phase == "ok":
            click(shown("Board Setup"), wx.ID_OK)
            state["phase"] = "closing"
        elif phase == "closing":
            warning = shown("Warning")
            if warning is not None:
                said = [w.GetLabel() for w in walk(warning) if isinstance(w, wx.StaticText)]
                log("removed layers warning" if any("removed layers" in t for t in said) else "warning", said)
                warning.EndModal(wx.ID_OK)
                return
            if shown("Board Setup") is not None:
                return
            menu("Save")
            state["phase"] = "saving"
        elif phase == "saving":
            if frame().GetTitle().startswith("*"):
                return
            log("saved", pcbnew.GetBoard().GetCopperLayerCount())
            os._exit(0)
    except Exception:
        log(traceback.format_exc())
        os._exit(2)


timer = wx.Timer()
timer.Bind(wx.EVT_TIMER, lambda e: tick())
timer.Start(250)
'''


def kicad_config():
    home = os.environ.get("KICAD_CONFIG_HOME") or os.path.expanduser("~/.config/kicad")
    return home


def drive(board, page, copper=None):
    """KiCad's Board Setup dialog on `board` (its project beside it): `page` shown, the copper layer count set to
    `copper` there if given, OK, the board saved"""
    with tempfile.TemporaryDirectory() as tmp:
        share = os.path.join(tmp, "share")
        plugins = os.path.join(share, "kicad", "10.0", "scripting", "plugins")
        os.makedirs(plugins)
        with open(os.path.join(plugins, "jspice_boardsetup.py"), "w") as f:
            f.write(PLUGIN)
        config = os.path.join(tmp, "config")
        shutil.copytree(kicad_config(), config, ignore=shutil.ignore_patterns("*.lck"))
        job = {"page": page, "copper": copper, "log": os.path.join(tmp, "log.txt")}
        with open(os.path.join(tmp, "job.json"), "w") as f:
            json.dump(job, f)
        env = dict(os.environ, XDG_DATA_HOME=share, KICAD_CONFIG_HOME=config,
                   JSPICE_BOARDSETUP_JOB=os.path.join(tmp, "job.json"))
        # (KiCad's editor now and then crashes as it starts under Xvfb: tried again)
        for attempt in range(4):
            if os.path.exists(job["log"]):
                os.remove(job["log"])
            run = subprocess.run(["xvfb-run", "-a", "pcbnew", os.path.basename(board)], cwd=os.path.dirname(board),
                                 env=env, capture_output=True, text=True, timeout=240)
            text = open(job["log"]).read() if os.path.exists(job["log"]) else ""
            if run.returncode == 0 and "saved" in text:
                return text
        sys.exit(f"{board}: KiCad's Board Setup did not finish ({run.returncode}): {text}")


def dialog(boards):
    for board in boards:
        name = os.path.splitext(os.path.basename(board))[0]
        record = {"steps": []}
        with tempfile.TemporaryDirectory() as tmp:
            work = os.path.join(tmp, "b.kicad_pcb")
            shutil.copy(board, work)
            project = os.path.splitext(board)[0] + ".kicad_pro"
            if os.path.exists(project):
                shutil.copy(project, os.path.join(tmp, "b.kicad_pro"))
            count = len([e for e in child(parse(open(board).read()), "layers")[1:] if e[1].endswith(".Cu")])
            for n in STEPS[count]:
                said = drive(work, "Physical Stackup", n)
                step = {"copper": n, "warned": "removed layers warning" in said, "board": summary(work)}
                step.update(jobfile(work))
                record["steps"].append(step)
                print(f"{name}: {n} copper layers", file=sys.stderr)
            pro = os.path.join(tmp, "b.kicad_pro")
            if os.path.exists(pro):
                ds = json.load(open(pro)).get("board", {}).get("design_settings", {})
                if ds.get("track_widths") or ds.get("via_dimensions"):
                    before = {k: ds.get(k) for k in ("track_widths", "via_dimensions")}
                    drive(work, "Pre-defined Sizes")
                    ds = json.load(open(pro))["board"]["design_settings"]
                    record["presets"] = {"before": before,
                                         "after": {k: ds.get(k) for k in ("track_widths", "via_dimensions")}}
        with open(os.path.splitext(board)[0] + ".setup", "w") as f:
            json.dump(record, f, indent=1)
            f.write("\n")


def sizes(board):
    """The track width and via size KiCad's router takes for each entry of the project's pre-defined lists, as its
    track width menu chooses them (SetTrackWidthIndex, SetViaSizeIndex; GetCurrentTrackWidth, GetCurrentViaSize,
    GetCurrentViaDrill), nm, and the board's minimum track width"""
    import pcbnew
    ds = pcbnew.LoadBoard(board).GetDesignSettings()
    tracks, vias = [], []
    for i in range(len(ds.m_TrackWidthList)):
        ds.SetTrackWidthIndex(i)
        tracks.append(ds.GetCurrentTrackWidth())
    for i in range(len(ds.m_ViasDimensionsList)):
        ds.SetViaSizeIndex(i)
        vias.append([ds.GetCurrentViaSize(), ds.GetCurrentViaDrill()])
    return {"tracks": tracks, "vias": vias, "trackMinWidth": ds.m_TrackMinWidth}


def check(boards):
    out = {}
    for board in boards:
        out[board] = summary(board)
        out[board].update(jobfile(board))
        out[board]["sizes"] = sizes(board)
    json.dump(out, sys.stdout)


# MARK: - A board of what removing layers reaches

def edge(out):
    os.makedirs(out, exist_ok=True)
    names = ["F.Cu", "In1.Cu", "In2.Cu", "In3.Cu", "In4.Cu", "B.Cu"]
    ids = {"F.Cu": 0, "B.Cu": 2, "In1.Cu": 4, "In2.Cu": 6, "In3.Cu": 8, "In4.Cu": 10}
    n = [0]

    def uid():
        n[0] += 1
        return f"00000000-0000-4000-8000-{n[0]:012d}"

    layers = "".join(f'\t\t({ids[c]} "{c}" signal)\n' for c in names)
    layers += "".join(f"\t\t{l}\n" for l in [
        '(9 "F.Adhes" user "F.Adhesive")', '(11 "B.Adhes" user "B.Adhesive")', '(13 "F.Paste" user)',
        '(15 "B.Paste" user)', '(5 "F.SilkS" user "F.Silkscreen")', '(7 "B.SilkS" user "B.Silkscreen")',
        '(1 "F.Mask" user)', '(3 "B.Mask" user)', '(17 "Dwgs.User" user "User.Drawings")',
        '(19 "Cmts.User" user "User.Comments")', '(25 "Edge.Cuts" user)', '(27 "Margin" user)',
        '(31 "F.CrtYd" user "F.Courtyard")', '(29 "B.CrtYd" user "B.Courtyard")', '(35 "F.Fab" user)',
        '(33 "B.Fab" user)'])
    stackup = """\t\t(stackup
\t\t\t(layer "F.SilkS" (type "Top Silk Screen") (color "White"))
\t\t\t(layer "F.Paste" (type "Top Solder Paste"))
\t\t\t(layer "F.Mask" (type "Top Solder Mask") (color "#1A2B3C") (thickness 0.012))
\t\t\t(layer "F.Cu" (type "copper") (thickness 0.035))
\t\t\t(layer "dielectric 1" (type "prepreg") (color "FR4 natural") (thickness 0.2 locked) (material "FR408") (epsilon_r 3.66) (loss_tangent 0.0117))
\t\t\t(layer "In1.Cu" (type "copper") (thickness 0.0175))
\t\t\t(layer "dielectric 2" (type "core") (thickness 0.3) (material "FR4") (epsilon_r 4.5) (loss_tangent 0.02) addsublayer (thickness 0.05) addsublayer (color "Mauve") (thickness 0.07) (material "PTFE") (epsilon_r 2.1) (loss_tangent 0.0002))
\t\t\t(layer "In2.Cu" (type "copper") (thickness 0.035))
\t\t\t(layer "dielectric 3" (type "glass") (thickness 0.25) (material "FR4") (epsilon_r 4.5) (loss_tangent 0.02))
\t\t\t(layer "In3.Cu" (type "copper") (thickness 0.035))
\t\t\t(layer "dielectric 4" (type "core") (thickness 0.31))
\t\t\t(layer "In4.Cu" (type "copper") (thickness 0.0175))
\t\t\t(layer "dielectric 5" (type "prepreg") (thickness 0.123456) (material "FR4") (epsilon_r 4.4) (loss_tangent 0.02))
\t\t\t(layer "B.Cu" (type "copper") (thickness 0.07))
\t\t\t(layer "B.Mask" (type "Bottom Solder Mask") (thickness 0.01))
\t\t\t(layer "B.SilkS" (type "Bottom Silk Screen"))
\t\t\t(copper_finish "ENIG")
\t\t\t(dielectric_constraints yes)
\t\t\t(edge_connector bevelled)
\t\t\t(edge_plating yes)
\t\t)
"""
    items = []
    x0, y0 = 100, 100
    # tracks on every layer, an arc on In3.Cu
    for i, c in enumerate(names):
        items.append(f'\t(segment (start {x0} {y0 + 2 * i}) (end {x0 + 10} {y0 + 2 * i}) (width 0.2) (layer "{c}") '
                     f'(net "N{i}") (uuid "{uid()}"))')
    items.append(f'\t(arc (start {x0 + 12} {y0}) (mid {x0 + 14} {y0 + 2}) (end {x0 + 12} {y0 + 4}) (width 0.2) '
                 f'(layer "In3.Cu") (net "N3") (uuid "{uid()}"))')
    # vias: through, blind, buried, micro
    vias = [("", "F.Cu", "B.Cu"), ("blind ", "F.Cu", "In2.Cu"), ("buried ", "In1.Cu", "In4.Cu"),
            ("buried ", "In2.Cu", "In3.Cu"), ("micro ", "In3.Cu", "In4.Cu"), ("blind ", "In3.Cu", "B.Cu"),
            ("micro ", "F.Cu", "In1.Cu")]
    for k, (kind, a, b) in enumerate(vias):
        items.append(f'\t(via {kind}(at {x0 + 20 + 2 * k} {y0}) (size 0.6) (drill 0.3) (layers "{a}" "{b}") '
                     f'(net "N0") (uuid "{uid()}"))')
    # drawings and texts on inner layers
    line4 = uid()
    items.append(f'\t(gr_line (start {x0} {y0 + 20}) (end {x0 + 5} {y0 + 20}) (stroke (width 0.2) (type default)) '
                 f'(layer "In4.Cu") (uuid "{line4}"))')
    items.append(f'\t(gr_rect (start {x0 + 6} {y0 + 20}) (end {x0 + 8} {y0 + 22}) (stroke (width 0.1) (type default)) '
                 f'(fill no) (layer "In2.Cu") (uuid "{uid()}"))')
    items.append(f'\t(gr_text "inner" (at {x0} {y0 + 25} 0) (layer "In3.Cu") (uuid "{uid()}") '
                 f'(effects (font (size 1 1) (thickness 0.15))))')
    items.append(f'\t(gr_line (start {x0} {y0 + 30}) (end {x0 + 5} {y0 + 30}) (stroke (width 0.2) (type default)) '
                 f'(layer "Dwgs.User") (uuid "{uid()}"))')
    # zones: on F.Cu, In3.Cu and In4.Cu, filled, with a hatch position on In4.Cu; on In4.Cu alone; on every layer
    def outline(x, y):
        return f"(polygon (pts (xy {x} {y}) (xy {x + 8} {y}) (xy {x + 8} {y + 8}) (xy {x} {y + 8})))"

    def filled(layer, x, y):
        return (f'(filled_polygon (layer "{layer}") (pts (xy {x + 0.5} {y + 0.5}) (xy {x + 7.5} {y + 0.5}) '
                f'(xy {x + 7.5} {y + 7.5}) (xy {x + 0.5} {y + 7.5})))')

    items.append(f'\t(zone (net "N0") (layers "F.Cu" "In3.Cu" "In4.Cu") (uuid "{uid()}") (hatch edge 0.5) '
                 f'(property (layer "In4.Cu") (hatch_position (xy 1 1))) '
                 f'(connect_pads (clearance 0.5)) (min_thickness 0.25) '
                 f'(fill yes (thermal_gap 0.5) (thermal_bridge_width 0.5)) {outline(x0 + 40, y0)} '
                 f'{filled("F.Cu", x0 + 40, y0)} {filled("In3.Cu", x0 + 40, y0)} {filled("In4.Cu", x0 + 40, y0)})')
    items.append(f'\t(zone (net "N0") (layer "In4.Cu") (uuid "{uid()}") (hatch edge 0.5) '
                 f'(connect_pads (clearance 0.5)) (min_thickness 0.25) '
                 f'(fill yes (thermal_gap 0.5) (thermal_bridge_width 0.5)) {outline(x0 + 50, y0)} '
                 f'{filled("In4.Cu", x0 + 50, y0)})')
    items.append(f'\t(zone (net "N0") (layers "In1.Cu" "In2.Cu") (uuid "{uid()}") (hatch edge 0.5) '
                 f'(connect_pads (clearance 0.5)) (min_thickness 0.25) '
                 f'(fill (thermal_gap 0.5) (thermal_bridge_width 0.5)) {outline(x0 + 50, y0 + 10)})')
    items.append(f'\t(zone (layers "*.Cu") (uuid "{uid()}") (hatch edge 0.5) (connect_pads (clearance 0)) '
                 f'(min_thickness 0.25) (keepout (tracks not_allowed) (vias not_allowed) (pads allowed) '
                 f'(copperpour allowed) (footprints allowed)) (fill (thermal_gap 0.5) (thermal_bridge_width 0.5)) '
                 f'{outline(x0 + 60, y0)})')
    # a footprint: a pad with a hole on its front copper only, a drawing on an inner layer
    fp = uid()
    items.append(f'\t(footprint "JSpice:Odd" (layer "F.Cu") (uuid "{fp}") (at {x0 + 30} {y0 + 30}) '
                 f'(property "Reference" "J1" (at 0 -3 0) (layer "F.SilkS") (uuid "{uid()}") (effects (font (size 1 1) (thickness 0.15)))) '
                 f'(property "Value" "Odd" (at 0 3 0) (layer "F.Fab") (uuid "{uid()}") (effects (font (size 1 1) (thickness 0.15)))) '
                 f'(fp_line (start -2 0) (end 2 0) (stroke (width 0.2) (type default)) (layer "In4.Cu") (uuid "{uid()}")) '
                 f'(pad "1" thru_hole circle (at 0 0) (size 1.6 1.6) (drill 0.8) (layers "F.Cu" "F.Mask") (uuid "{uid()}")) '
                 f'(pad "2" thru_hole circle (at 2.54 0) (size 1.6 1.6) (drill 0.8) (layers "*.Cu" "*.Mask") (uuid "{uid()}")) '
                 f'(pad "3" smd rect (at 5 0) (size 1 1) (layers "F.Cu" "F.Mask" "F.Paste") (uuid "{uid()}")))')
    # groups: one of a drawing and a track on In4.Cu, one of a track on F.Cu and one on In4.Cu
    seg_f = re.search(r'layer "F.Cu"\) \(net "N0"\) \(uuid "([^"]+)"', items[0]).group(1)
    seg_4 = re.search(r'\(uuid "([^"]+)"', items[4]).group(1)
    items.append(f'\t(group "" (uuid "{uid()}") (members "{line4}" "{seg_4}"))')
    items.append(f'\t(group "" (uuid "{uid()}") (members "{seg_f}" "{seg_4}"))')
    corners = [(x0 - 5, y0 - 5), (x0 + 75, y0 - 5), (x0 + 75, y0 + 40), (x0 - 5, y0 + 40)]
    for i in range(4):
        (ax, ay), (bx, by) = corners[i], corners[(i + 1) % 4]
        items.append(f'\t(gr_line (start {ax} {ay}) (end {bx} {by}) (stroke (width 0.05) (type default)) '
                     f'(layer "Edge.Cuts") (uuid "{uid()}"))')
    text = ("(kicad_pcb\n\t(version 20260206)\n\t(generator \"pcbnew\")\n\t(generator_version \"10.0\")\n"
            "\t(general\n\t\t(thickness 1.6)\n\t\t(legacy_teardrops no)\n\t)\n\t(paper \"A4\")\n"
            "\t(layers\n" + layers + "\t)\n\t(setup\n" + stackup + "\t\t(pad_to_mask_clearance 0)\n\t)\n"
            + "\n".join(items) + "\n)\n")
    path = os.path.join(out, "edge-6")
    with open(path + ".kicad_pcb", "w") as f:
        f.write(text)
    project = {"board": {"design_settings": {
        "track_widths": [0.0, 0.5, 0.2, 0.15, 0.3],
        "via_dimensions": [{"diameter": 0.0, "drill": 0.0}, {"diameter": 0.8, "drill": 0.4},
                           {"diameter": 0.6, "drill": 0.3}, {"diameter": 0.6, "drill": 0.25}]}},
        "meta": {"filename": "edge-6.kicad_pro", "version": 3}}
    with open(path + ".kicad_pro", "w") as f:
        json.dump(project, f, indent=2)
    # (as KiCad itself writes it: read and saved by its pcbnew module)
    import pcbnew
    pcbnew.SaveBoard(path + ".kicad_pcb", pcbnew.LoadBoard(path + ".kicad_pcb"))
    print(path + ".kicad_pcb")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "edge":
        edge(sys.argv[2])
    elif len(sys.argv) >= 2 and sys.argv[1] == "dialog":
        dialog(sys.argv[2:])
    elif len(sys.argv) >= 2 and sys.argv[1] == "check":
        check(sys.argv[2:])
    else:
        sys.exit(__doc__)
