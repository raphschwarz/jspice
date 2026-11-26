#!/usr/bin/env python3
"""The nets' colours and hidden ratsnest as KiCad's PCB editor keeps them (the project's net_settings: each net's
colour, "net_colors", and each net class's, "pcb_color"; the local settings' board: the nets and net classes whose
ratsnest is hidden, "hidden_nets" and "hidden_netclasses", and the net colour mode), changed in the Nets tab of its
Appearance panel as a user changes them, for checking the port's (KiCadRouter's NetDisplay, KiCadKit's KiCadNetColors
and KiCadAppearanceControls) against.

Neither the panel nor these settings reach KiCad's Python module. So, as appearance.py does, this runs KiCad's PCB
editor itself (pcbnew under Xvfb, with an action plugin in a folder of its own and a copy of the user's KiCad
configuration) and, once the board is open, does what a step says through the Nets tab's own controls (their events as
a click on them sends them, the colour picker a double click opens driven as a user drives it), then saves the board
with File > Save, twice, and closes the editor, each of which writes the settings as KiCad writes them:

    netdisplay.py BOARD.kicad_pcb...
        writes BOARD.netdisplay (JSON) beside each board: two runs of KiCad, the first on the board and its project
        with no local settings, the second on what the first left; in each, random steps: a net's colour set (its
        swatch double clicked, the colour typed into the picker as #RRGGBB, OK) or taken off (the picker's Clear
        Color, OK), a net's eye clicked, a net class's colour set or taken off the same way, a net class's eye
        clicked, the net colour mode chosen (All, Ratsnest, None). For each run its steps, the .kicad_pro and
        .kicad_prl as the first File > Save left them (the net classes' colours and hidden net classes as they now
        are, the rest as opened: KiCad writes the project before it copies the view's settings into it), as the
        second left them, and as closing the editor left them (the nets' colours copied from the view into the
        project: SaveProjectLocalSettings).

KiCad 10's pcbnew, Xvfb (xvfb-run) and a KiCad configuration made by running KiCad once (it is copied).
"""

import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import zlib

PLUGIN = r'''
import json, os, traceback
import wx
import wx.grid
import pcbnew

JOB = json.load(open(os.environ["JSPICE_NETDISPLAY_JOB"]))
state = {"step": 0, "wait": 0, "ticks": 0, "phase": "load", "quiet": 0, "dialog": None}


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


def notebook():
    return next(w for w in walk(frame()) if isinstance(w, wx.Notebook)
                and [w.GetPageText(i) for i in range(w.GetPageCount())][:3] == ["Layers", "Objects", "Nets"])


def page(name):
    nb = notebook()
    i = [nb.GetPageText(k) for k in range(nb.GetPageCount())].index(name)
    if nb.GetSelection() != i:
        nb.SetSelection(i)
    return nb.GetPage(i)


def grid():
    return next(w for w in walk(page("Nets")) if isinstance(w, wx.grid.Grid))


def row_of(net):
    g = grid()
    for r in range(g.GetNumberRows()):
        if g.GetCellValue(r, 2) == net:
            return r
    raise RuntimeError("no net " + net)


def class_panel(name):
    found = [w for w in walk(page("Nets")) if isinstance(w, wx.StaticText) and w.GetLabel() == name and w.IsShown()]
    if not found:
        raise RuntimeError("no class " + name)
    return found[-1].GetParent()


def grid_event(kind, row, col):
    g = grid()
    evt = wx.grid.GridEvent(g.GetId(), kind, g, row, col)
    wx.CallAfter(g.GetEventHandler().ProcessEvent, evt)


def mouse(window, kind):
    evt = wx.MouseEvent(kind)
    evt.SetEventObject(window)
    wx.CallAfter(window.GetEventHandler().ProcessEvent, evt)


def menu(command):
    bar = frame().GetMenuBar()
    for k in range(bar.GetMenuCount()):
        m = bar.GetMenu(k)
        item = next((i for i in m.GetMenuItems() if i.GetItemLabelText() == command), None)
        if item:
            evt = wx.CommandEvent(wx.wxEVT_MENU, item.GetId())
            evt.SetEventObject(m)
            wx.CallAfter(m.ProcessEvent, evt)
            return
    raise RuntimeError("no menu item " + command)


def picker():
    f = frame()
    return next((w for w in wx.GetTopLevelWindows() if w is not f and w.IsShown() and isinstance(w, wx.Dialog)), None)


def press(dialog, button):
    evt = wx.CommandEvent(wx.wxEVT_BUTTON, button.GetId())
    evt.SetEventObject(button)
    wx.PostEvent(button, evt)


def record(name):
    out = {}
    for ext in ("pro", "prl"):
        p = JOB[ext]
        out[ext] = open(p).read() if os.path.exists(p) else None
    with open(JOB[name], "w") as f:
        json.dump(out, f)


def tick():
    try:
        state["ticks"] += 1
        if state["ticks"] > 2500:
            log("timeout", state["step"], state["phase"])
            os._exit(3)
        if state["wait"] > 0:
            state["wait"] -= 1
            return
        f = frame()
        if state["phase"] == "load":
            warning = shown("Warning")
            if warning is not None:
                warning.EndModal(wx.ID_OK)
                state["quiet"] = 0
                return
            state["quiet"] += 1
            if f is not None and pcbnew.GetBoard() is not None and pcbnew.GetBoard().GetFileName().endswith("b.kicad_pcb") and state["quiet"] > 30:
                state["phase"] = "steps"
                state["wait"] = 30
            return
        if state["phase"] == "picker":
            # (the colour picker the double click opened: the colour typed in, or Clear Color (its Reset to Default for a
            # colour of no default), then OK)
            d = picker()
            if d is None:
                state["pickerwait"] = state.get("pickerwait", 0) + 1
                if state["pickerwait"] > 60:
                    raise RuntimeError("no colour picker")
                return
            s = JOB["steps"][state["step"]]
            if not state.get("typed"):
                if s[0] in ("netcolor", "classcolor"):
                    text = next(w for w in walk(d) if isinstance(w, wx.TextCtrl))
                    text.SetValue(s[2])
                else:
                    reset = next(w for w in walk(d) if isinstance(w, wx.Button) and w.GetLabel() in ("Clear Color", "Reset to Default"))
                    press(d, reset)
                state["typed"] = True
                state["wait"] = 3
                return
            press(d, d.FindWindow(wx.ID_OK))
            state["typed"] = False
            state["pickerwait"] = 0
            state["phase"] = "steps"
            log("did", s)
            state["step"] += 1
            state["wait"] = 6
            return
        if state["phase"] in ("saving", "again"):
            p = JOB["prl"]
            state["saving"] = state.get("saving", 0) + 1
            changed = os.path.exists(p) and os.path.getmtime(p) > state["before"]
            if not changed and state["saving"] < 40:
                return
            record("saved" if state["phase"] == "saving" else "again")
            log("saved", state["phase"])
            state["saving"] = 0
            if state["phase"] == "saving":
                state["before"] = os.path.getmtime(p) if os.path.exists(p) else 0
                state["phase"] = "again"
                menu("Save")
                state["wait"] = 5
            else:
                # (closing the editor: SaveProjectLocalSettings, then the process ends)
                state["phase"] = "closing"
                log("closing")
                wx.CallAfter(f.Close)
            return
        if state["phase"] == "closing":
            return
        steps = JOB["steps"]
        if state["step"] >= len(steps):
            p = JOB["prl"]
            state["before"] = os.path.getmtime(p) if os.path.exists(p) else 0
            menu("Save")
            state["phase"] = "saving"
            state["wait"] = 5
            return
        s = steps[state["step"]]
        kind = s[0]
        if kind in ("netcolor", "netclear"):
            grid_event(wx.grid.wxEVT_GRID_CELL_LEFT_DCLICK, row_of(s[1]), 0)
            state["phase"] = "picker"
            state["wait"] = 4
            return
        if kind in ("classcolor", "classclear"):
            swatch = class_panel(s[1]).GetChildren()[0]
            mouse(swatch.GetChildren()[0], wx.wxEVT_LEFT_DCLICK)
            state["phase"] = "picker"
            state["wait"] = 4
            return
        if kind == "neteye":
            grid_event(wx.grid.wxEVT_GRID_CELL_LEFT_CLICK, row_of(s[1]), 1)
        elif kind == "classeye":
            eye = class_panel(s[1]).GetChildren()[1]
            mouse(eye.GetChildren()[0], wx.wxEVT_LEFT_UP)
        elif kind == "colormode":
            page("Nets")
            radio = next(w for w in walk(notebook().GetParent()) if isinstance(w, wx.RadioButton) and w.GetLabel() == s[1]
                         and w.GetParent().GetChildren().__len__() > 0
                         and any(isinstance(x, wx.RadioButton) and x.GetLabel() == "Ratsnest" for x in w.GetParent().GetChildren()))
            radio.SetValue(True)
            evt = wx.CommandEvent(wx.wxEVT_RADIOBUTTON, radio.GetId())
            evt.SetEventObject(radio)
            evt.SetInt(1)
            radio.GetEventHandler().ProcessEvent(evt)
        log("did", s)
        state["step"] += 1
        # (a toggle lets go of a second click within a fifth of a second)
        state["wait"] = 4
    except Exception:
        log(traceback.format_exc())
        os._exit(2)


timer = wx.Timer()
timer.Bind(wx.EVT_TIMER, lambda e: tick())
timer.Start(100)
'''

MODES = ["All", "Ratsnest", "None"]


def board_nets(path):
    """The board's nets' names (KiCad 10 names them on its items), and its project's net classes"""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from boardsetup import parse
    root = parse(open(path, encoding="utf-8").read())
    names = set()

    def visit(node):
        if isinstance(node, list):
            if node and node[0] == "net" and len(node) >= 2 and isinstance(node[-1], str):
                names.add(node[-1])
            for c in node:
                visit(c)
    visit(root)
    nets = sorted(n for n in names if n and not n.startswith("unconnected-("))
    pro = path[: -len(".kicad_pcb")] + ".kicad_pro"
    classes = []
    if os.path.exists(pro):
        ns = json.load(open(pro)).get("net_settings", {})
        classes = [c["name"] for c in ns.get("classes", []) if "name" in c]
    if "Default" not in classes:
        classes.insert(0, "Default")
    return nets, classes


def steps(rng, nets, classes):
    out = []
    others = [c for c in classes if c != "Default"]
    hexes = lambda: "#%02X%02X%02X" % (rng.randrange(256), rng.randrange(256), rng.randrange(256))
    for _ in range(rng.randint(6, 14)):
        k = rng.random()
        if k < 0.25 and nets:
            out.append(["netcolor", rng.choice(nets), hexes()])
        elif k < 0.35 and nets:
            out.append(["netclear", rng.choice(nets)])
        elif k < 0.55 and nets:
            out.append(["neteye", rng.choice(nets)])
        elif k < 0.7 and others:
            out.append(["classcolor", rng.choice(others), hexes()])
        elif k < 0.75 and others:
            out.append(["classclear", rng.choice(others)])
        elif k < 0.9:
            out.append(["classeye", rng.choice(classes)])
        else:
            out.append(["colormode", rng.choice(MODES)])
    return out


def drive(work, steps_):
    """KiCad's PCB editor on the board in `work` (b.kicad_pcb, its project and local settings beside it), `steps_`
    done, the board saved twice, the editor closed; the settings as each left them"""
    with tempfile.TemporaryDirectory() as tmp:
        share = os.path.join(tmp, "share")
        plugins = os.path.join(share, "kicad", "10.0", "scripting", "plugins")
        os.makedirs(plugins)
        with open(os.path.join(plugins, "jspice_netdisplay.py"), "w") as f:
            f.write(PLUGIN)
        config = os.path.join(tmp, "config")
        home = os.environ.get("KICAD_CONFIG_HOME") or os.path.expanduser("~/.config/kicad")
        shutil.copytree(home, config, ignore=shutil.ignore_patterns("*.lck"))
        job = {"steps": steps_, "log": os.path.join(tmp, "log.txt"), "prl": os.path.join(work, "b.kicad_prl"),
               "pro": os.path.join(work, "b.kicad_pro"),
               "saved": os.path.join(tmp, "saved.json"), "again": os.path.join(tmp, "again.json")}
        with open(os.path.join(tmp, "job.json"), "w") as f:
            json.dump(job, f)
        env = dict(os.environ, XDG_DATA_HOME=share, KICAD_CONFIG_HOME=config,
                   JSPICE_NETDISPLAY_JOB=os.path.join(tmp, "job.json"))
        before = {ext: (open(job[ext]).read() if os.path.exists(job[ext]) else None) for ext in ("pro", "prl")}
        text = ""
        # (KiCad's editor now and then crashes as it starts or closes under Xvfb: tried again)
        for attempt in range(4):
            if os.path.exists(job["log"]):
                os.remove(job["log"])
            for name in os.listdir(work):
                if name.endswith(".lck"):
                    os.remove(os.path.join(work, name))
            for ext, t in before.items():
                if t is None and os.path.exists(job[ext]):
                    os.remove(job[ext])
                elif t is not None:
                    with open(job[ext], "w") as f:
                        f.write(t)
            run = subprocess.run(["xvfb-run", "-a", "-s", "-screen 0 2560x1600x24", "pcbnew", "b.kicad_pcb"], cwd=work,
                                 env=env, capture_output=True, text=True, timeout=900)
            text = open(job["log"]).read() if os.path.exists(job["log"]) else ""
            if "closing" in text and os.path.exists(job["again"]):
                closed = {ext: (open(job[ext]).read() if os.path.exists(job[ext]) else None) for ext in ("pro", "prl")}
                return json.load(open(job["saved"])), json.load(open(job["again"])), closed
            print(f"try {attempt + 1}: {run.returncode} {text[-1500:]}", file=sys.stderr)
        sys.exit(f"KiCad did not finish ({run.returncode}): {text} {run.stderr[-2000:]}")


def netdisplay(path):
    name = os.path.basename(path)
    rng = random.Random(zlib.crc32(("netdisplay " + name).encode()))
    nets, classes = board_nets(path)
    record = {"runs": []}
    with tempfile.TemporaryDirectory() as work:
        shutil.copy(path, os.path.join(work, "b.kicad_pcb"))
        pro = path[: -len(".kicad_pcb")] + ".kicad_pro"
        if os.path.exists(pro):
            shutil.copy(pro, os.path.join(work, "b.kicad_pro"))
        for run in range(2):
            opened = {ext: (open(os.path.join(work, "b." + "kicad_" + ext)).read()
                            if os.path.exists(os.path.join(work, "b.kicad_" + ext)) else None) for ext in ("pro", "prl")}
            s = steps(rng, nets, classes)
            saved, again, closed = drive(work, s)
            record["runs"].append({"steps": s, "opened": opened, "saved": saved, "saved_again": again, "closed": closed})
            print(f"{name}: run {run + 1}, {len(s)} steps", file=sys.stderr)
    with open(path[: -len(".kicad_pcb")] + ".netdisplay", "w") as f:
        json.dump(record, f, indent=1)
        f.write("\n")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for board in sys.argv[1:]:
        netdisplay(board)
