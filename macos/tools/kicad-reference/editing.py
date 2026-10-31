#!/usr/bin/env python3
"""KiCad's copy, cut, paste, duplicate, Create Array and align and distribute, done by KiCad's own PCB editor, for
checking the port's (KiCadRouter's BoardClipboard.swift, BoardClipboardEditing.swift, BoardArray.swift and
BoardAlign.swift) against.

KiCad's Python module reaches none of these (they are the editor's tools, and the clipboard's text is CLIPBOARD_IO's),
so, as tuning.py does, this runs KiCad's PCB editor itself under Xvfb with an action plugin of its own (in a folder of
its own, with a copy of the user's KiCad configuration whose grid is a micrometre, whose magnetic items are off, so that
nothing snaps the pointer, and with hotkeys of its own for align and distribute, which KiCad gives none), driving the
editor as a user does: the view zoomed to fit and its scale worked out from the status bar, items selected by a box
drawn with the pointer (wx.UIActionSimulator: X's pointer pressed, moved and let go), KiCad's tools started by their
keys (Ctrl+C, Ctrl+V, Ctrl+D, Ctrl+T and the align hotkeys), the pointer moved and clicked to place what they move, the
Create Array dialog's fields filled in, and the clipboard read and written through wx.TheClipboard; what the selection
was (pcbnew.GetCurrentSelection, in its order) and where the status bar said the pointer was at each step written down.

    editing.py copy OUTDIR BOARD.kicad_pcb...
        each board copied into OUTDIR with its project, and BOARD.copies (JSON) beside it: the view's scale (mm a
        pixel), and for each copy (everything, Ctrl+A; the items in a box drawn from outside the board's corner; a
        footprint alone) the box drawn, the selection (uuids, in order), the cursor at Ctrl+C and the clipboard's text.
    editing.py paste BOARD.kicad_pcb [SOURCE.kicad_pcb] [--ours COPIES]
        the copies of BOARD.copies (or of SOURCE's, pasted into BOARD) pasted one after another (Ctrl+V, the pointer
        moved to a point of the board, a click), the box copy also with Paste Special's unique references, and a text
        that is not KiCad's; BOARD-pasted.kicad_pcb (or BOARD-from-SOURCE.kicad_pcb), and BOARD.pastes: for each paste
        the text, the cursor where it was placed and the mode. With --ours, the port's copies of the same selections
        pasted instead (COPIES: JSON, each copy's text by its name, as ClipboardTests writes BOARD.ours with
        KICAD_CLIPBOARD_DUMP), into BOARD-ours-pasted.kicad_pcb.
    editing.py duplicate BOARD.kicad_pcb
        the box copy's items selected again, duplicated (Ctrl+D), moved and placed with a click; and the footprint alone
        likewise: BOARD-duplicated.kicad_pcb, and BOARD.duplicates (the selections, the cursors at Ctrl+D and the click).
    editing.py array BOARD.kicad_pcb
        Create Array (Ctrl+T) on the box copy's items with each of a list of settings (grids of counts, spacings,
        offsets, stagger by rows and columns, centred or not; circular arrays about a centre, full circle or by an
        angle, clockwise or not, items turned or not; arranged rather than duplicated; references kept or made
        unique), each a run of its own: BOARD-array-N.kicad_pcb, and BOARD.arrays (the settings and selections).
    editing.py align BOARD.kicad_pcb
        the box copy's items selected, each of KiCad's align and distribute actions with the pointer over one of them or
        not, one after another, the board saved after each (pcbnew.SaveBoard of the editor's board):
        BOARD-align-N.kicad_pcb, and BOARD.aligns (the action, selection and cursor of each).

KiCad 10's pcbnew, Xvfb (xvfb-run) and a KiCad configuration made by running KiCad once (it is copied).
"""

import json
import os
import random
import shutil
import subprocess
import sys
import tempfile

MM = 1_000_000

ALIGN = ["alignTop", "alignBottom", "alignLeft", "alignRight", "alignCenterX", "alignCenterY",
         "distributeHorizontallyCenters", "distributeHorizontallyGaps", "distributeVerticallyCenters",
         "distributeVerticallyGaps"]
# (hotkeys of their own, Ctrl+Alt+Shift and a letter: KiCad gives align and distribute none)
ALIGN_KEYS = "QWERTYUIOP"

PLUGIN = r'''
import json, os, re, traceback
import wx
import pcbnew

JOB = json.load(open(os.environ["JSPICE_EDITING_JOB"]))
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


def finish(code):
    with open(JOB["out"], "w") as f:
        json.dump(out, f)
    os._exit(code)


MODS = {"ctrl": wx.MOD_CONTROL, "shift": wx.MOD_SHIFT, "alt": wx.MOD_ALT}


def dialog_fields(d):
    """A dialog's controls by the label before each (wxFormBuilder puts a label's control after it)"""
    fields = {}
    for w in walk(d):
        kids = list(w.GetChildren())
        for a, b in zip(kids, kids[1:]):
            if isinstance(a, wx.StaticText) and a.GetLabel().strip():
                fields.setdefault(a.GetLabel().strip(), b)
    return fields


def fill_array(d, settings):
    """The Create Array dialog given `settings`: its page, its fields by their labels, its radio buttons and
    check boxes by theirs"""
    book = next(w for w in walk(d) if isinstance(w, wx.Notebook))
    page = 0 if settings["kind"] == "grid" else 1
    book.SetSelection(page)
    fields = dialog_fields(book.GetPage(page))
    for label, value in settings.get("fields", {}).items():
        ctrl = fields[label]
        ctrl.SetValue(str(value))
    for w in walk(d):
        if isinstance(w, (wx.RadioButton, wx.CheckBox)) and w.GetLabel() in settings.get("checks", {}):
            want = settings["checks"][w.GetLabel()]
            if w.GetValue() != want or isinstance(w, wx.RadioButton):
                w.SetValue(want)
                kind = wx.wxEVT_RADIOBUTTON if isinstance(w, wx.RadioButton) else wx.wxEVT_CHECKBOX
                evt = wx.CommandEvent(kind, w.GetId())
                evt.SetEventObject(w)
                evt.SetInt(1 if want else 0)
                w.GetEventHandler().ProcessEvent(evt)
        if isinstance(w, wx.RadioBox) and w.GetLabel() in settings.get("radios", {}):
            w.SetSelection(settings["radios"][w.GetLabel()])
            evt = wx.CommandEvent(wx.wxEVT_RADIOBOX, w.GetId())
            evt.SetEventObject(w)
            evt.SetInt(w.GetSelection())
            w.GetEventHandler().ProcessEvent(evt)
    # (what the dialog holds then: its fields' texts, its buttons' and boxes' states, by their labels)
    held = {k: v.GetValue() for k, v in dialog_fields(book.GetPage(page)).items() if isinstance(v, wx.TextCtrl)}
    for w in walk(d):
        if isinstance(w, (wx.RadioButton, wx.CheckBox)) and w.IsShownOnScreen():
            held[w.GetLabel()] = w.GetValue()
        if isinstance(w, wx.RadioBox) and w.IsShownOnScreen():
            held[w.GetLabel()] = w.GetSelection()
    return held


def tick():
    try:
        state["ticks"] += 1
        if state["ticks"] > JOB.get("ticks", 2500):
            log("timeout", state["step"])
            finish(3)
        if state["wait"] > 0:
            state["wait"] -= 1
            return
        f = frame()
        if state["phase"] == "load":
            # (a warning as the board is read, a rule area KiCad's router cannot cut: said, and closed first)
            warning = shown("Warning")
            if warning is not None:
                out["steps"].append({"dialog": "Warning", "said": [w.GetLabel() for w in walk(warning) if isinstance(w, wx.StaticText)]})
                warning.EndModal(wx.ID_OK)
                state["quiet"] = 0
                return
            state["quiet"] += 1
            if f is not None and pcbnew.GetBoard() is not None and state["quiet"] > 8:
                f.SetSize(0, 0, 2560, 1600)
                state["phase"] = "steps"
                state["wait"] = 6
            return
        # (a warning or an error KiCad shows: said, and closed)
        for title in ("Warning", "Error", "Confirmation"):
            box = shown(title)
            if box is not None:
                out["steps"].append({"dialog": title, "said": [w.GetLabel() for w in walk(box) if isinstance(w, wx.StaticText)]})
                box.EndModal(wx.ID_OK)
                state["wait"] = 3
                return
        steps = JOB["steps"]
        if state["step"] >= len(steps):
            finish(0)
        s = steps[state["step"]]
        if state.get("logged") != state["step"]:
            state["logged"] = state["step"]
            log("step", state["step"], s[0], str(s[1])[:60] if len(s) > 1 else "")
        kind = s[0]
        if kind == "menu":
            menu(s[1], s[2])
            state["wait"] = s[3] if len(s) > 3 else 6
        elif kind == "calibrate":
            c = canvas()
            r = c.GetScreenRect()
            pts = [(r.x + r.width // 5, r.y + r.height // 5), (r.x + 4 * r.width // 5, r.y + 4 * r.height // 5)]
            cal = state.setdefault("cal", {"readings": [], "moved": False, "last": None})
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
            if w1[0] == w2[0] or w1[1] == w2[1]:
                # (the pointer held by a dialog KiCad showed meanwhile: again)
                state.pop("cal")
                state["wait"] = 6
                return
            out["transform"] = {"px": p1[0], "py": p1[1], "wx": w1[0], "wy": w1[1],
                                "sx": (w2[0] - w1[0]) / (p2[0] - p1[0]), "sy": (w2[1] - w1[1]) / (p2[1] - p1[1]),
                                "canvas": [r.x, r.y, r.width, r.height]}
            state.pop("cal")
        elif kind == "move":
            q = to_screen(s[1])
            sim.MouseMove(q[0] + 1, q[1])
            sim.MouseMove(*q)
            state["wait"] = s[2] if len(s) > 2 else 5
        elif kind == "cursor":
            out["steps"].append({"cursor": cursor(), "tag": s[1] if len(s) > 1 else None})
        elif kind == "down":
            sim.MouseDown(wx.MOUSE_BTN_LEFT)
            state["wait"] = 3
        elif kind == "up":
            sim.MouseUp(wx.MOUSE_BTN_LEFT)
            state["wait"] = 6
        elif kind == "click":
            sim.MouseClick(wx.MOUSE_BTN_LEFT)
            state["wait"] = s[1] if len(s) > 1 else 8
        elif kind == "key":
            canvas().SetFocus()
            mods = 0
            for m in s[2]:
                mods |= MODS[m]
            code = {"escape": wx.WXK_ESCAPE, "delete": wx.WXK_DELETE}.get(s[1], ord(s[1]) if len(s[1]) == 1 else 0)
            sim.Char(code, mods)
            state["wait"] = s[3] if len(s) > 3 else 8
        elif kind == "enter":
            # (a message box of GTK's own, which wx does not list, answered: Return)
            sim.Char(wx.WXK_RETURN)
            out["steps"].append({"dialog": "message box", "said": ["answered with Return"]})
            state["wait"] = 8
        elif kind == "selection":
            sel = pcbnew.GetCurrentSelection()
            ids = []
            for k in range(len(sel)):
                # (an item the module does not cast, a footprint's field, by its id all the same)
                ids.append(sel[k].m_Uuid.AsString())
            out["steps"].append({"selection": ids, "tag": s[1] if len(s) > 1 else None})
        elif kind == "getclip":
            cb = wx.TheClipboard
            text = None
            if cb.Open():
                d = wx.TextDataObject()
                if cb.GetData(d):
                    text = d.GetText()
                cb.Close()
            out["steps"].append({"clip": text, "tag": s[1] if len(s) > 1 else None})
        elif kind == "setclip":
            cb = wx.TheClipboard
            if cb.Open():
                cb.SetData(wx.TextDataObject(s[1]))
                cb.Flush()
                cb.Close()
        elif kind == "paste_special":
            d = shown("Paste Special")
            if d is None:
                if state.get("ps", 0) > 40:
                    log("no paste special dialog")
                    finish(4)
                state["ps"] = state.get("ps", 0) + 1
                state["wait"] = 2
                return
            state.pop("ps", None)
            for w in walk(d):
                if isinstance(w, wx.RadioBox):
                    w.SetSelection(s[1])
            # (its OK pressed, which takes the choice: TransferDataFromWindow)
            ok = d.FindWindow(wx.ID_OK)
            evt = wx.CommandEvent(wx.wxEVT_BUTTON, wx.ID_OK)
            evt.SetEventObject(ok)
            wx.PostEvent(ok, evt)
            state["wait"] = 8
        elif kind == "array":
            d = shown("Create Array")
            if d is None:
                if state.get("ad", 0) > 40:
                    log("no array dialog")
                    finish(4)
                state["ad"] = state.get("ad", 0) + 1
                state["wait"] = 2
                return
            state.pop("ad", None)
            out["steps"].append({"array": fill_array(d, s[1])})
            ok = d.FindWindow(wx.ID_OK)
            evt = wx.CommandEvent(wx.wxEVT_BUTTON, wx.ID_OK)
            evt.SetEventObject(ok)
            wx.PostEvent(ok, evt)
            state["wait"] = 12
        elif kind == "snapshot":
            pcbnew.SaveBoard(s[1], pcbnew.GetBoard())
        elif kind == "wait":
            state["wait"] = s[1]
        state["step"] += 1
    except Exception:
        log(traceback.format_exc())
        finish(2)


timer = wx.Timer()
timer.Bind(wx.EVT_TIMER, lambda e: tick())
timer.Start(150)
'''


def drive(board, steps, ticks=2500):
    """KiCad's PCB editor on `board` (its project beside it), its window the size of a screen of 2560 by 1600, the
    plugin's `steps` done; what it wrote"""
    with tempfile.TemporaryDirectory() as tmp:
        share = os.path.join(tmp, "share")
        plugins = os.path.join(share, "kicad", "10.0", "scripting", "plugins")
        os.makedirs(plugins)
        with open(os.path.join(plugins, "jspice_editing.py"), "w") as f:
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
        editing = cfg.setdefault("editing", {})
        editing["magnetic_graphics"] = False
        editing["magnetic_pads"] = 0
        editing["magnetic_tracks"] = 0
        json.dump(cfg, open(pj, "w"))
        with open(os.path.join(config, "10.0", "user.hotkeys"), "a") as f:
            for name, key in zip(ALIGN, ALIGN_KEYS):
                f.write(f"pcbnew.AlignAndDistribute.{name}\tCtrl+Alt+Shift+{key}\n")
        job = {"steps": steps, "log": os.path.join(tmp, "log.txt"), "out": os.path.join(tmp, "out.json"), "ticks": ticks}
        with open(os.path.join(tmp, "job.json"), "w") as f:
            json.dump(job, f)
        env = dict(os.environ, XDG_DATA_HOME=share, KICAD_CONFIG_HOME=config, JSPICE_EDITING_JOB=os.path.join(tmp, "job.json"))
        text = ""
        for attempt in range(4):
            for p in (job["log"], job["out"]):
                if os.path.exists(p):
                    os.remove(p)
            run = subprocess.run(["xvfb-run", "-a", "-s", "-screen 0 2560x1600x24", "pcbnew", os.path.basename(board)],
                                 cwd=os.path.dirname(os.path.abspath(board)), env=env, capture_output=True, text=True,
                                 timeout=900)
            text = open(job["log"]).read() if os.path.exists(job["log"]) else ""
            if run.returncode == 0 and os.path.exists(job["out"]):
                done = json.load(open(job["out"]))
                done["log"] = text
                return done
        sys.exit(f"{board}: KiCad did not finish ({run.returncode}): {text} {run.stderr[-2000:]}")


# MARK: - What to select

def board_box(path):
    """The box round everything on the board, mm"""
    import pcbnew
    b = pcbnew.LoadBoard(path)
    box = b.ComputeBoundingBox(False)
    return [box.GetLeft() / MM, box.GetTop() / MM, box.GetRight() / MM, box.GetBottom() / MM]


def footprint_boxes(path):
    import pcbnew
    b = pcbnew.LoadBoard(path)
    out = []
    for fp in b.GetFootprints():
        box = fp.GetBoundingBox(True)
        out.append({"uuid": fp.m_Uuid.AsString(), "ref": fp.GetReference(), "position": [fp.GetPosition().x / MM, fp.GetPosition().y / MM],
                    "box": [box.GetLeft() / MM, box.GetTop() / MM, box.GetRight() / MM, box.GetBottom() / MM]})
    return out


def drag(a, b):
    """A box drawn with the pointer from `a` to `b` (mm)"""
    return [["move", a, 5], ["down"], ["move", [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2], 4], ["move", b, 5], ["up"]]


def selections(path, rng):
    """The boxes the copies select: one from just outside the board's top left corner to a point within it, two fifths
    to three quarters across; one just round a footprint (its box with its texts, 0.3 mm out), from a corner no other
    item's box covers, holding nothing else wholly"""
    import pcbnew
    x0, y0, x1, y1 = board_box(path)
    start = [round(x0 - 0.5, 3), round(y0 - 0.5, 3)]
    fps = sorted(footprint_boxes(path), key=lambda f: f["box"][0] + f["box"][1])
    b = pcbnew.LoadBoard(path)
    items = list(b.GetFootprints()) + list(b.GetDrawings()) + list(b.GetTracks()) + list(b.Zones())
    def box(i):
        r = i.GetBoundingBox(True) if isinstance(i, pcbnew.FOOTPRINT) else i.GetBoundingBox()
        return [r.GetLeft() / MM, r.GetTop() / MM, r.GetRight() / MM, r.GetBottom() / MM]
    def inside(r, a, z):
        return a[0] <= r[0] and r[2] <= z[0] and a[1] <= r[1] and r[3] <= z[1]
    # (an end of the box that takes no footprint's field without its footprint: KiCad selects a field on its own,
    # which JSpice does not)
    for attempt in range(200):
        end = [round(x0 + (x1 - x0) * rng.uniform(0.25, 0.95), 3), round(y0 + (y1 - y0) * rng.uniform(0.25, 0.95), 3)]
        stray = False
        for fp in b.GetFootprints():
            if inside(box(fp), start, end):
                continue
            for field in list(fp.GetFields()) + [t for t in fp.GraphicalItems() if t.GetClass() == "PCB_TEXT"]:
                r = field.GetBoundingBox()
                if inside([r.GetLeft() / MM, r.GetTop() / MM, r.GetRight() / MM, r.GetBottom() / MM], start, end):
                    stray = True
        if not stray:
            break
    else:
        end = None
    one = None
    for f in fps:
        a = [round(f["box"][0] - 0.3, 3), round(f["box"][1] - 0.3, 3)]
        z = [round(f["box"][2] + 0.3, 3), round(f["box"][3] + 0.3, 3)]
        others = [i for i in items if i.m_Uuid.AsString() != f["uuid"]]
        covered = any(r[0] <= a[0] <= r[2] and r[1] <= a[1] <= r[3] for r in map(box, others))
        held = any(a[0] <= r[0] and r[2] <= z[0] and a[1] <= r[1] and r[3] <= z[1] for r in map(box, others))
        if not covered and not held:
            one = (a, z)
            break
    return {"box": (start, end) if end else None, "one": one, "footprints": fps, "bounds": [x0, y0, x1, y1]}


def copy_board(src, dst):
    shutil.copy(src, dst)
    for ext in (".kicad_pro", ".kicad_dru"):
        other = src[:-len(".kicad_pcb")] + ext
        if os.path.exists(other):
            shutil.copy(other, dst[:-len(".kicad_pcb")] + ext)


def tagged(done, key):
    return {s["tag"]: s[key] for s in done["steps"] if key in s and s.get("tag")}


# MARK: - The modes

def copy(outdir, boards):
    os.makedirs(outdir, exist_ok=True)
    for src in boards:
        board = os.path.join(outdir, os.path.basename(src))
        copy_board(src, board)
        # (the board as KiCad 10.0.7 itself writes it, which is what its copies are made of)
        import pcbnew
        pcbnew.SaveBoard(board, pcbnew.LoadBoard(board))
        rng = random.Random("copy-" + os.path.basename(board))
        sel = selections(board, rng)
        fps = sel["footprints"]
        steps = [["menu", "View", "Zoom to Fit", 10], ["calibrate"]]
        cases = []
        # everything, the pointer near the first footprint's origin
        near = [round(fps[0]["position"][0] + 0.37, 3), round(fps[0]["position"][1] + 0.21, 3)]
        steps += [["move", near], ["key", "a", ["ctrl"]], ["selection", "all"], ["cursor", "all"], ["key", "c", ["ctrl"]],
                  ["getclip", "all"], ["key", "escape", []]]
        cases.append({"name": "all", "box": None})
        for name in ("box", "one"):
            if not sel[name]:
                continue
            a, b = sel[name]
            inside = [round(a[0] + (b[0] - a[0]) * rng.uniform(0.55, 0.9), 3), round(a[1] + (b[1] - a[1]) * rng.uniform(0.55, 0.9), 3)]
            steps += drag(a, b) + [["selection", name], ["move", inside], ["cursor", name], ["key", "c", ["ctrl"]],
                                   ["getclip", name], ["key", "escape", []]]
            cases.append({"name": name, "box": [a, b]})
        done = drive(board, steps)
        sels, curs, clips = tagged(done, "selection"), tagged(done, "cursor"), tagged(done, "clip")
        for c in cases:
            c.update(selection=sels[c["name"]], cursor=curs[c["name"]], text=clips[c["name"]])
        record = {"scale": done["transform"]["sx"], "transform": done["transform"], "copies": cases,
                  "dialogs": [s for s in done["steps"] if "dialog" in s]}
        with open(board[:-len(".kicad_pcb")] + ".copies", "w") as f:
            json.dump(record, f, indent=1)
        print(board, [(c["name"], len(c["selection"])) for c in cases], file=sys.stderr)


def paste(board, source=None, ours=None):
    src = source or board
    copies = json.load(open(src[:-len(".kicad_pcb")] + ".copies"))["copies"]
    base = board[:-len(".kicad_pcb")]
    out = base + ("-from-" + os.path.basename(src)[:-len(".kicad_pcb")] if source else "-pasted") + ".kicad_pcb"
    if ours:
        # (the port's copies of the same selections pasted instead: BOARD.ours, written by ClipboardTests)
        texts = json.load(open(ours))
        copies = [dict(c, text=texts[c["name"]]) for c in copies if c["name"] in texts]
        out = base + "-ours-pasted.kicad_pcb"
    copy_board(board, out)
    rng = random.Random("paste-" + os.path.basename(out))
    x0, y0, x1, y1 = board_box(out)
    def somewhere():
        return [round(rng.uniform(x0 + (x1 - x0) * 0.2, x1 - (x1 - x0) * 0.2), 3), round(rng.uniform(y0 + (y1 - y0) * 0.2, y1 - (y1 - y0) * 0.2), 3)]
    pastes = []
    steps = [["menu", "View", "Zoom to Fit", 10], ["calibrate"]]
    for c in copies:
        if (source and c["name"] != "all") or not c["selection"]:
            continue
        modes = ["keep"] if source else (["keep", "unique"] if c["name"] != "all" else ["keep"])
        for mode in modes:
            k = len(pastes)
            at = somewhere()
            steps += [["setclip", c["text"]], ["move", at]]
            if mode == "keep":
                steps += [["key", "v", ["ctrl"], 12]] + ([["enter"]] if source else [])
            else:
                steps += [["key", "v", ["ctrl", "shift"], 6], ["paste_special", 0]]
            steps += [["move", [at[0] + 0.0005, at[1]], 4], ["move", at, 6], ["cursor", str(k)], ["click", 10], ["selection", str(k)],
                      ["key", "escape", []]]
            pastes.append({"copy": c["name"], "mode": mode, "text": c["text"]})
    if not source:
        k = len(pastes)
        at = somewhere()
        steps += [["setclip", "JSpice pasted\ntext"], ["move", at], ["key", "v", ["ctrl"], 12], ["move", [at[0] + 0.0005, at[1]], 4],
                  ["move", at, 6], ["cursor", str(k)], ["click", 10], ["selection", str(k)], ["key", "escape", []]]
        pastes.append({"copy": None, "mode": "text", "text": "JSpice pasted\ntext"})
    steps += [["snapshot", os.path.abspath(out)]]
    done = drive(out, steps)
    curs, sels = tagged(done, "cursor"), tagged(done, "selection")
    for k, p in enumerate(pastes):
        p.update(cursor=curs[str(k)], selection=sels[str(k)])
    with open(out[:-len(".kicad_pcb")] + ".pastes", "w") as f:
        json.dump({"pastes": pastes, "dialogs": [s for s in done["steps"] if "dialog" in s]}, f, indent=1)
    print(out, len(pastes), file=sys.stderr)


def duplicate(board):
    record = json.load(open(board[:-len(".kicad_pcb")] + ".copies"))
    out = board[:-len(".kicad_pcb")] + "-duplicated.kicad_pcb"
    copy_board(board, out)
    rng = random.Random("duplicate-" + os.path.basename(out))
    steps = [["menu", "View", "Zoom to Fit", 10], ["calibrate"]]
    dups = []
    for c in record["copies"]:
        if not c["box"] or not c["selection"]:
            continue
        a, b = c["box"]
        k = len(dups)
        start = c["cursor"]
        to = [round(start[0] + rng.uniform(-6, 6), 3), round(start[1] + rng.uniform(-6, 6), 3)]
        steps += drag(a, b) + [["selection", "s" + str(k)], ["move", start], ["cursor", "a" + str(k)], ["key", "d", ["ctrl"], 10],
                               ["move", [(start[0] + to[0]) / 2, (start[1] + to[1]) / 2], 4], ["move", to, 6], ["cursor", "b" + str(k)],
                               ["click", 10], ["selection", "d" + str(k)], ["key", "escape", []]]
        dups.append({"copy": c["name"], "box": c["box"]})
    steps += [["snapshot", os.path.abspath(out)]]
    done = drive(out, steps)
    curs, sels = tagged(done, "cursor"), tagged(done, "selection")
    for k, d in enumerate(dups):
        d.update(selection=sels["s" + str(k)], start=curs["a" + str(k)], end=curs["b" + str(k)], made=sels["d" + str(k)])
    with open(out[:-len(".kicad_pcb")] + ".duplicates", "w") as f:
        json.dump({"duplicates": dups, "dialogs": [s for s in done["steps"] if "dialog" in s]}, f, indent=1)
    print(out, len(dups), file=sys.stderr)




ARRAYS = [
    {"kind": "grid", "fields": {"Horizontal count:": 3, "Vertical count:": 2, "Horizontal spacing:": "7.5", "Vertical spacing:": "-4.25",
                                "Horizontal offset:": "0", "Vertical offset:": "0", "Stagger:": "1"},
     "checks": {"Source items remain in place": True, "Assign unique reference designators": True, "Duplicate selection": True}},
    {"kind": "grid", "fields": {"Horizontal count:": 2, "Vertical count:": 3, "Horizontal spacing:": "6", "Vertical spacing:": "5.5",
                                "Horizontal offset:": "1.25", "Vertical offset:": "-0.75", "Stagger:": "3"},
     "checks": {"Rows": True, "Source items remain in place": True, "Keep existing reference designators": True,
                "Duplicate selection": True}},
    {"kind": "grid", "fields": {"Horizontal count:": 4, "Vertical count:": 2, "Horizontal spacing:": "3.3", "Vertical spacing:": "4.4",
                                "Horizontal offset:": "0", "Vertical offset:": "0.5", "Stagger:": "-2"},
     "checks": {"Columns": True, "Centre on source items": True, "Assign unique reference designators": True,
                "Duplicate selection": True}},
    {"kind": "circular", "fields": {"Center pos X:": "0", "Center pos Y:": "0", "Item count:": 5, "Angle between items:": "37.5",
                                    "First item angle:": "10"},
     "checks": {"Full circle": False, "Rotate items": True, "Assign unique reference designators": True,
                "Duplicate selection": True}, "radios": {"Direction": 0}},
    {"kind": "circular", "fields": {"Item count:": 7, "First item angle:": "0"},
     "checks": {"Full circle": True, "Rotate items": False, "Keep existing reference designators": True, "Duplicate selection": True},
     "radios": {"Direction": 1}},
    {"kind": "grid", "fields": {"Horizontal count:": 3, "Vertical count:": 3, "Horizontal spacing:": "5", "Vertical spacing:": "5",
                                "Horizontal offset:": "0", "Vertical offset:": "0", "Stagger:": "1"},
     "checks": {"Source items remain in place": True, "Arrange selection": True}},
]


def array(board):
    record = json.load(open(board[:-len(".kicad_pcb")] + ".copies"))
    box = next(c for c in record["copies"] if c["name"] == "box")
    a, b = box["box"]
    runs = []
    for n, settings in enumerate(ARRAYS):
        settings = json.loads(json.dumps(settings))
        out = board[:-len(".kicad_pcb")] + f"-array-{n}.kicad_pcb"
        copy_board(board, out)
        if settings["kind"] == "circular" and "Center pos X:" in settings["fields"]:
            # (a centre off the selection: a footprint's position, plus a little)
            c = box["cursor"]
            settings["fields"]["Center pos X:"] = f"{c[0] - 4:.3f}"
            settings["fields"]["Center pos Y:"] = f"{c[1] + 3:.3f}"
        steps = [["menu", "View", "Zoom to Fit", 10], ["calibrate"]] + drag(a, b) + [["selection", "s"], ["key", "t", ["ctrl"], 12],
                                                                                    ["array", settings], ["selection", "after"],
                                                                                    ["snapshot", os.path.abspath(out)]]
        done = drive(out, steps)
        sels = tagged(done, "selection")
        fields = next(s["array"] for s in done["steps"] if "array" in s)
        runs.append({"settings": settings, "dialog": fields, "selection": sels["s"], "after": sels.get("after"),
                     "dialogs": [s for s in done["steps"] if "dialog" in s]})
        print(out, len(sels["s"]), file=sys.stderr)
    with open(board[:-len(".kicad_pcb")] + ".arrays", "w") as f:
        json.dump({"arrays": runs}, f, indent=1)


def align(board):
    record = json.load(open(board[:-len(".kicad_pcb")] + ".copies"))
    box = next(c for c in record["copies"] if c["name"] == "box")
    a, b = box["box"]
    rng = random.Random("align-" + os.path.basename(board))
    footprints = footprint_boxes(board)
    steps = [["menu", "View", "Zoom to Fit", 10], ["calibrate"]]
    actions = []
    for n, (name, key) in enumerate(zip(ALIGN, ALIGN_KEYS)):
        out = board[:-len(".kicad_pcb")] + f"-align-{n}.kicad_pcb"
        # (the pointer over a footprint of the selection, or away from them all)
        over = rng.random() < 0.5
        mine = [f for f in footprints if f["uuid"] in box["selection"]]
        at = rng.choice(mine)["position"] if over and mine else [round(a[0] + 0.5, 3), round(a[1] + 0.5, 3)]
        steps += drag(a, b) + [["selection", "s" + str(n)], ["move", at], ["cursor", "c" + str(n)],
                               ["key", key, ["ctrl", "alt", "shift"], 10], ["snapshot", os.path.abspath(out)], ["key", "escape", []]]
        actions.append({"action": name, "board": os.path.basename(out)})
    done = drive(board, steps)
    curs, sels = tagged(done, "cursor"), tagged(done, "selection")
    for n, act in enumerate(actions):
        act.update(selection=sels["s" + str(n)], cursor=curs["c" + str(n)])
    with open(board[:-len(".kicad_pcb")] + ".aligns", "w") as f:
        json.dump({"aligns": actions, "dialogs": [s for s in done["steps"] if "dialog" in s]}, f, indent=1)
    print(board, len(actions), file=sys.stderr)


if __name__ == "__main__":
    mode, args = sys.argv[1], sys.argv[2:]
    if mode == "copy":
        copy(args[0], args[1:])
    elif mode == "paste":
        ours = args[args.index("--ours") + 1] if "--ours" in args else None
        rest = [a for a in args if a != "--ours" and a != ours]
        paste(rest[0], rest[1] if len(rest) > 1 else None, ours)
    elif mode == "duplicate":
        duplicate(args[0])
    elif mode == "array":
        array(args[0])
    elif mode == "align":
        align(args[0])
    else:
        sys.exit(__doc__)
