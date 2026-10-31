#!/usr/bin/env python3
"""The board's appearance as KiCad's PCB editor keeps it in the project's local settings (the .kicad_prl's "board"),
changed in its Appearance panel as a user changes it, for checking the port's (KiCadKit's LocalSettings.swift:
KiCadAppearanceControls, KiCadBoardAppearance and KiCadLocalSettings) against.

The panel cannot be driven headless: KiCad's Python module reaches neither it nor the project's local settings. So, as
boardsetup.py does, this runs KiCad's PCB editor itself (pcbnew under Xvfb, with an action plugin in a folder of its
own and a copy of the user's KiCad configuration), once the board is open does what a step says through the panel's
own controls (their events as a click on them sends them) and saves the board with File > Save, twice, each of which
writes the local settings as KiCad writes them:

    appearance.py BOARD.kicad_pcb...
        writes BOARD.appearance (JSON) beside each board: two runs of KiCad, the first on the board with no local
        settings, the second on what the first left; in each, random steps: a layer's visibility toggled (the eye of
        its row of the Layers tab), an object's (the Objects tab: tracks, vias, pads, zones, images, footprints of
        either side, values, references, footprint text, ratsnest, DRC markers, anchors, shadows, the grid...), an
        object's opacity set with its slider, the inactive layers' mode chosen (Normal, Dim, Hide), a layer made the
        active one (a click on its name), a built-in layer preset chosen. For each run its steps, the .kicad_prl's text
        File > Save wrote (and whether it wrote one: KiCad writes it before it copies the frame's display options and
        active layer into it, so it has those as they were) and the text a second File > Save wrote (with them as the
        editor has them, as closing the editor writes them).

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
import pcbnew

JOB = json.load(open(os.environ["JSPICE_APPEARANCE_JOB"]))
state = {"step": 0, "wait": 0, "ticks": 0, "phase": "load", "quiet": 0}


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


def label(name, tab):
    found = [w for w in walk(page(tab)) if isinstance(w, wx.StaticText) and w.GetLabel() == name and w.IsShown()]
    if not found:
        raise RuntimeError("no row " + name)
    return found[0]


def toggle(row_label):
    # (the eye before the row's name: its bitmap let go of as a click lets go of it)
    kids = list(row_label.GetParent().GetChildren())
    eye = kids[kids.index(row_label) - 1]
    bitmap = eye.GetChildren()[0]
    evt = wx.MouseEvent(wx.wxEVT_LEFT_UP)
    evt.SetEventObject(bitmap)
    bitmap.GetEventHandler().ProcessEvent(evt)


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


def tick():
    try:
        state["ticks"] += 1
        if state["ticks"] > 1500:
            log("timeout", state["step"])
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
                # (the editor let settle a few seconds more: a click on the panel at once now and then crashes it)
                state["wait"] = 30
            return
        if state["phase"] == "saving":
            # (the local settings written: once their file is newer than before; KiCad writes none it finds unchanged,
            # so after a few seconds taken as written. File > Save writes them before it copies the frame's display
            # options and active layer into them: saved again, they are written as the editor has them, as closing it
            # would write them, which under Xvfb now and then crashes it)
            prl = JOB["prl"]
            state["saving"] = state.get("saving", 0) + 1
            changed = os.path.exists(prl) and os.path.getmtime(prl) > state["before"]
            if not changed and state["saving"] < 40:
                return
            again = state.get("again", False)
            with open(JOB["again" if again else "saved"], "w") as f:
                json.dump({"changed": changed, "text": open(prl).read() if os.path.exists(prl) else None}, f)
            log("saved again" if again else "saved")
            if again:
                os._exit(0)
            state["again"] = True
            state["saving"] = 0
            state["before"] = os.path.getmtime(prl) if os.path.exists(prl) else 0
            menu("Save")
            state["wait"] = 5
            return
        steps = JOB["steps"]
        if state["step"] >= len(steps):
            prl = JOB["prl"]
            state["before"] = os.path.getmtime(prl) if os.path.exists(prl) else 0
            menu("Save")
            state["phase"] = "saving"
            state["wait"] = 5
            return
        s = steps[state["step"]]
        kind = s[0]
        if kind == "layer":
            toggle(label(s[1], "Layers"))
        elif kind == "object":
            toggle(label(s[1], "Objects"))
        elif kind == "active":
            l = label(s[1], "Layers")
            evt = wx.MouseEvent(wx.wxEVT_LEFT_DOWN)
            evt.SetEventObject(l)
            l.GetEventHandler().ProcessEvent(evt)
        elif kind == "opacity":
            row = label(s[1], "Objects").GetParent()
            slider = next(w for w in row.GetChildren() if isinstance(w, wx.Slider))
            slider.SetValue(s[2])
            evt = wx.ScrollEvent(wx.wxEVT_SCROLL_CHANGED, slider.GetId(), s[2])
            evt.SetEventObject(slider)
            slider.GetEventHandler().ProcessEvent(evt)
        elif kind == "contrast":
            page("Layers")
            radio = next(w for w in walk(notebook().GetParent()) if isinstance(w, wx.RadioButton) and w.GetLabel() == s[1])
            radio.SetValue(True)
            evt = wx.CommandEvent(wx.wxEVT_RADIOBUTTON, radio.GetId())
            evt.SetEventObject(radio)
            evt.SetInt(1)
            radio.GetEventHandler().ProcessEvent(evt)
        elif kind == "preset":
            choice = next(w for w in walk(notebook().GetParent()) if isinstance(w, wx.Choice)
                          and s[1] in list(w.GetStrings()))
            choice.SetSelection(list(choice.GetStrings()).index(s[1]))
            evt = wx.CommandEvent(wx.wxEVT_CHOICE, choice.GetId())
            evt.SetEventObject(choice)
            evt.SetInt(choice.GetSelection())
            choice.GetEventHandler().ProcessEvent(evt)
        b = pcbnew.GetBoard()
        log("did", s)
        state["step"] += 1
        # (a toggle lets go of a second click within a fifth of a second)
        state["wait"] = 3
    except Exception:
        log(traceback.format_exc())
        os._exit(2)


timer = wx.Timer()
timer.Bind(wx.EVT_TIMER, lambda e: tick())
timer.Start(100)
'''

OBJECTS = ["Tracks", "Vias", "Pads", "Zones", "Images", "Footprints Front", "Footprints Back", "Values", "References",
           "Footprint Text", "Ratsnest", "DRC Warnings", "DRC Errors", "DRC Exclusions", "Anchors", "Points",
           "Locked Item Shadow", "Colliding Courtyards", "Board Area Shadow", "Drawing Sheet", "Grid"]
OPACITIES = ["Tracks", "Vias", "Pads", "Zones", "Filled Shapes", "Images"]
PRESETS = ["All Layers", "No Layers", "All Copper Layers", "Inner Copper Layers", "Front Layers", "Front Assembly View",
           "Back Layers", "Back Assembly View"]


def layer_names(path):
    """The board's layers' names as the panel shows them (its own names for them)"""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from boardsetup import parse, child
    root = parse(open(path, encoding="utf-8").read())
    out = []
    for entry in child(root, "layers")[1:]:
        out.append(entry[3] if len(entry) > 3 and entry[3] else entry[1])
    return out


def steps(rng, names):
    out = []
    copper = [n for n in names if n.endswith(".Cu")]
    for _ in range(rng.randint(6, 14)):
        k = rng.random()
        if k < 0.3:
            out.append(["layer", rng.choice(names)])
        elif k < 0.55:
            out.append(["object", rng.choice(OBJECTS)])
        elif k < 0.7:
            out.append(["opacity", rng.choice(OPACITIES), rng.randint(0, 100)])
        elif k < 0.8:
            out.append(["contrast", rng.choice(["Normal", "Dim", "Hide"])])
        elif k < 0.9:
            out.append(["active", rng.choice(copper if rng.random() < 0.6 else names)])
        else:
            out.append(["preset", rng.choice(PRESETS)])
    return out


def drive(work, steps_):
    """KiCad's PCB editor on the board in `work` (b.kicad_pcb, its project and local settings beside it), `steps_`
    done, the board saved; the local settings KiCad wrote"""
    with tempfile.TemporaryDirectory() as tmp:
        share = os.path.join(tmp, "share")
        plugins = os.path.join(share, "kicad", "10.0", "scripting", "plugins")
        os.makedirs(plugins)
        with open(os.path.join(plugins, "jspice_appearance.py"), "w") as f:
            f.write(PLUGIN)
        config = os.path.join(tmp, "config")
        home = os.environ.get("KICAD_CONFIG_HOME") or os.path.expanduser("~/.config/kicad")
        shutil.copytree(home, config, ignore=shutil.ignore_patterns("*.lck"))
        job = {"steps": steps_, "log": os.path.join(tmp, "log.txt"), "prl": os.path.join(work, "b.kicad_prl"),
               "saved": os.path.join(tmp, "saved.json"), "again": os.path.join(tmp, "again.json")}
        with open(os.path.join(tmp, "job.json"), "w") as f:
            json.dump(job, f)
        env = dict(os.environ, XDG_DATA_HOME=share, KICAD_CONFIG_HOME=config,
                   JSPICE_APPEARANCE_JOB=os.path.join(tmp, "job.json"))
        prl = os.path.join(work, "b.kicad_prl")
        before = open(prl).read() if os.path.exists(prl) else None
        text = ""
        # (KiCad's editor now and then crashes as it starts under Xvfb: tried again)
        for attempt in range(4):
            if os.path.exists(job["log"]):
                os.remove(job["log"])
            # (the locks the editor before it left behind, which would have this one ask whether to open the board)
            for name in os.listdir(work):
                if name.endswith(".lck"):
                    os.remove(os.path.join(work, name))
            if before is None and os.path.exists(prl):
                os.remove(prl)
            elif before is not None:
                with open(prl, "w") as f:
                    f.write(before)
            run = subprocess.run(["xvfb-run", "-a", "-s", "-screen 0 2560x1600x24", "pcbnew", "b.kicad_pcb"], cwd=work,
                                 env=env, capture_output=True, text=True, timeout=600)
            text = open(job["log"]).read() if os.path.exists(job["log"]) else ""
            if run.returncode == 0 and "saved again" in text:
                return json.load(open(job["saved"])), json.load(open(job["again"]))
        sys.exit(f"KiCad did not finish ({run.returncode}): {text} {run.stderr[-2000:]}")


def appearance(path):
    name = os.path.basename(path)
    rng = random.Random(zlib.crc32(("appearance " + name).encode()))
    names = layer_names(path)
    record = {"runs": []}
    with tempfile.TemporaryDirectory() as work:
        shutil.copy(path, os.path.join(work, "b.kicad_pcb"))
        pro = path[: -len(".kicad_pcb")] + ".kicad_pro"
        if os.path.exists(pro):
            shutil.copy(pro, os.path.join(work, "b.kicad_pro"))
        for run in range(2):
            s = steps(rng, names)
            saved, again = drive(work, s)
            record["runs"].append({"steps": s, "saved": saved["text"], "saved_changed": saved["changed"],
                                   "saved_again": again["text"], "saved_again_changed": again["changed"]})
            print(f"{name}: run {run + 1}, {len(s)} steps", file=sys.stderr)
    with open(path[: -len(".kicad_pcb")] + ".appearance", "w") as f:
        json.dump(record, f, indent=1)
        f.write("\n")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for board in sys.argv[1:]:
        appearance(board)
