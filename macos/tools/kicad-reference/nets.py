#!/usr/bin/env python3
"""KiCad's Net Inspector and its net highlighting on boards, for checking the port's (KiCadRouter's NetInspector.swift
and NetHighlight.swift) against.

Neither reaches KiCad's Python module: the net inspector is a panel of the PCB editor (PCB_NET_INSPECTOR_PANEL, its
lengths LENGTH_DELAY_CALCULATION's, which the module does not wrap), and highlighting a net is a tool of it
(BOARD_INSPECTION_TOOL::HighlightNet, the board's highlighted nets a bare std::set to the module). So, as
boardsetup.py and tuning.py do, this runs KiCad's PCB editor itself (pcbnew under Xvfb, its window the size of a large
screen, with an action plugin in a folder of its own and a copy of the user's KiCad configuration whose grid is a
micrometre) and drives it as a user does:

    nets.py BOARD.kicad_pcb...
        writes BOARD.nets (JSON) beside each board. First run: the board's project local settings (its .kicad_prl)
        made to show every net (net_inspector_panel's show_zero_pad_nets and show_unconnected_nets) and to look at the
        board from a random active copper layer, inactive layers now and then dimmed (high_contrast_mode), now and
        then a copper layer or tracks, vias, pads or the back footprints hidden (visible_layers, visible_items); View >
        Panels > Net Inspector opened, and of each net its row as the panel shows it (every column's text, in the
        model's order of columns: name, net class, total length, via count, via length, track length, die length,
        pad count, then each copper layer's length); the rows in the order the panel sorts them by each column, up
        and down (its DATA_MODEL::Compare, which the view sorts by); the nets shown for filter texts typed in its
        filter box (parts of net and class names, in other cases, one that matches none). Then the view zoomed to fit,
        the pointer moved to two places and the status bar read at each (the view's transform worked out from them),
        and for points near the board's pads, tracks, vias and zones and anywhere on it: the pointer moved there and
        the highlight net key (`) pressed, the nets KiCad highlights (the board's highlighted net codes, read from
        its std::set as libstdc++ lays one out, with their names; and the net inspector's selection, which follows
        them but has no row for a net of no pads, tracks or vias) and whether it highlights one at all
        (BOARD::IsHighLightNetON), then ` again (which takes a net's highlight off again). Second run: the nets
        grouped by their net classes (group_by_netclass) and by custom group rules (custom_group_rules: a regular
        expression, a wildcard pattern, a part of a name), each group's row (sums of its nets') and its nets' rows
        (read again where the panel had not yet filled its list). And through KiCad's pcbnew module, each track's
        BOARD::GetTrackLength (the length of the copper it is connected to, its vias' heights with it, as the net
        inspector measures a net, to the nanometre).

    nets.py boards OUTDIR COUNT [SEED]
        writes COUNT random boards to inspect (OUTDIR/routed-SEED-N.kicad_pcb and .kicad_pro), saved by KiCad's
        pcbnew module: nets routed between their pads as a user routes them (routed() below has what they have).

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

MM = 1_000_000

PLUGIN = r'''
import functools, json, os, re, traceback
import wx
import wx.dataview as dv
import pcbnew

JOB = json.load(open(os.environ["JSPICE_NETS_JOB"]))
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
    cands = [w for w in walk(frame()) if w.IsShown() and w.GetClassName() == "wxGLCanvas"]
    return max(cands, key=lambda w: w.GetSize().x * w.GetSize().y)


def find_item(menu, label):
    for i in menu.GetMenuItems():
        if i.GetItemLabelText() == label:
            return i
        if i.GetSubMenu():
            found = find_item(i.GetSubMenu(), label)
            if found:
                return found
    return None


def menu(command):
    bar = frame().GetMenuBar()
    for k in range(bar.GetMenuCount()):
        m = bar.GetMenu(k)
        item = find_item(m, command)
        if item:
            evt = wx.CommandEvent(wx.wxEVT_MENU, item.GetId())
            evt.SetEventObject(m)
            wx.CallAfter(m.ProcessEvent, evt)
            return
    raise RuntimeError("no menu item " + command)


def nets_list():
    ctrls = [w for w in walk(frame()) if isinstance(w, dv.DataViewCtrl) and w.GetColumnCount() >= 8]
    return ctrls[0] if ctrls else None


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


def children(model, item):
    kids = dv.DataViewItemArray()
    model.GetChildren(item, kids)
    # (copies: the array's own items go with it)
    return [dv.DataViewItem(k) for k in kids]


def row(model, item, columns):
    return [model.GetValue(item, k) for k in range(columns)]


def tree(model, item, columns):
    # (a group's row has its nets' rows under it; a net's none)
    kids = children(model, item)
    entry = {"cells": row(model, item, columns)}
    if kids:
        entry["children"] = [tree(model, c, columns) for c in kids]
    return entry


def orders(model, items, columns):
    # (the rows as the panel's model compares them, which the view sorts by)
    out = {}
    for col in range(columns):
        for asc in (True, False):
            ranked = sorted(items, key=functools.cmp_to_key(lambda a, b: model.Compare(a, b, col, asc)))
            out[str(col) + ("+" if asc else "-")] = [model.GetValue(i, 0) for i in ranked]
    return out


def highlighted(board):
    """The names of the board's highlighted nets (BOARD::GetHighLightNetCodes: the module gives the std::set< int > as
    a bare pointer, read as libstdc++ lays one out: its tree's header after the comparator, the leftmost node first,
    each node's value after its colour and three links)"""
    import ctypes
    address = int(board.GetHighLightNetCodes())
    count = ctypes.c_size_t.from_address(address + 40).value
    header = address + 8
    node = ctypes.c_void_p.from_address(header + 16).value
    names = []
    for _ in range(count):
        code = ctypes.c_int.from_address(node + 32).value
        net = board.FindNet(code)
        names.append([code, net.GetNetname() if net else ""])
        # (the next node: the leftmost of the right subtree, else up while coming from the right)
        right = ctypes.c_void_p.from_address(node + 24).value
        if right:
            node = right
            while ctypes.c_void_p.from_address(node + 16).value:
                node = ctypes.c_void_p.from_address(node + 16).value
        else:
            parent = ctypes.c_void_p.from_address(node + 8).value
            while parent != header and node == ctypes.c_void_p.from_address(parent + 24).value:
                node, parent = parent, ctypes.c_void_p.from_address(parent + 8).value
            node = parent
    return names


def finish(code):
    with open(JOB["out"], "w") as f:
        json.dump(out, f)
    os._exit(code)


def tick():
    try:
        state["ticks"] += 1
        if state["ticks"] > JOB.get("ticks", 4000):
            log("timeout", state["step"])
            finish(3)
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
            if f is not None and pcbnew.GetBoard() is not None and state["quiet"] > 30:
                f.SetSize(0, 0, 2560, 1600)
                state["phase"] = "steps"
                state["wait"] = 6
            return
        steps = JOB["steps"]
        if state["step"] >= len(steps):
            finish(0)
        s = steps[state["step"]]
        kind = s[0]
        if not state.get("pick"):
            log("step", state["step"], kind)
        if kind == "menu":
            menu(s[1])
            state["wait"] = s[2] if len(s) > 2 else 6
        elif kind == "read":
            c = nets_list()
            if c is None:
                state["wait"] = 4
                return
            m = c.GetModel()
            columns = c.GetColumnCount()
            titles = {c.GetColumn(i).GetModelColumn(): c.GetColumn(i).GetTitle() for i in range(columns)}
            out["columns"] = [titles[k] for k in range(columns)]
            top = children(m, dv.NullDataViewItem)
            out["rows"] = [tree(m, i, columns) for i in top]
            if s[1]:
                out["orders"] = orders(m, [i for i in top if not children(m, i)], columns)
        elif kind == "filter":
            # (the text typed in the filter box, its text event sent as typing sends it; the list read once it has
            # been built again)
            if not state.get("typed"):
                # (the net inspector's own filter box, beside its list)
                search = [w for w in nets_list().GetParent().GetChildren() if isinstance(w, wx.SearchCtrl)][0]
                search.ChangeValue(s[1])
                evt = wx.CommandEvent(wx.wxEVT_TEXT, search.GetId())
                evt.SetEventObject(search)
                evt.SetString(s[1])
                search.GetEventHandler().ProcessEvent(evt)
                state["typed"] = True
                state["wait"] = 2
                return
            state["typed"] = False
            m = nets_list().GetModel()
            out.setdefault("filters", []).append({"text": s[1], "nets": [m.GetValue(i, 0) for i in children(m, dv.NullDataViewItem)]})
        elif kind == "calibrate":
            c = canvas()
            r = c.GetScreenRect()
            pts = [(r.x + r.width // 5, r.y + r.height // 5), (r.x + 4 * r.width // 5, r.y + 4 * r.height // 5)]
            cal = state.setdefault("cal", {"last": None, "readings": [], "moved": False})
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
            state.pop("cal")
        elif kind == "pick":
            # (the pointer there, `, what is highlighted, ` again)
            phase = state.get("pick", 0)
            if phase == 0:
                q = to_screen(s[1])
                state["pixel"] = q
                sim.MouseMove(*q)
                state["pick"] = 1
                state["wait"] = 1
                return
            if phase == 1:
                canvas().SetFocus()
                sim.Char(ord("`"))
                state["pick"] = 2
                state["wait"] = 1
                return
            board = pcbnew.GetBoard()
            c = nets_list()
            m = c.GetModel()
            if phase == 2:
                sel = c.GetSelections()
                q = state["pixel"]
                state["entry"] = {"at": s[1], "pixel": q, "world": to_world(q), "on": board.IsHighLightNetON(),
                                  "nets": sorted(m.GetValue(i, 0) for i in sel), "codes": highlighted(board)}
                if board.IsHighLightNetON():
                    canvas().SetFocus()
                    sim.Char(ord("`"))
                state["pick"] = 3
                state["wait"] = 1
                return
            entry = state.pop("entry")
            entry["after"] = board.IsHighLightNetON()
            out.setdefault("picks", []).append(entry)
            state["pick"] = 0
        state["step"] += 1
    except Exception:
        log(traceback.format_exc())
        finish(2)


timer = wx.Timer()
timer.Bind(wx.EVT_TIMER, lambda e: tick())
timer.Start(100)
'''


def drive(board, prl, steps, ticks=6000):
    """KiCad's PCB editor on `board` (its project beside it, its local settings `prl`), the plugin's `steps` done;
    what it wrote"""
    with tempfile.TemporaryDirectory() as tmp:
        share = os.path.join(tmp, "share")
        plugins = os.path.join(share, "kicad", "10.0", "scripting", "plugins")
        os.makedirs(plugins)
        with open(os.path.join(plugins, "jspice_nets.py"), "w") as f:
            f.write(PLUGIN)
        config = os.path.join(tmp, "config")
        home = os.environ.get("KICAD_CONFIG_HOME") or os.path.expanduser("~/.config/kicad")
        shutil.copytree(home, config, ignore=shutil.ignore_patterns("*.lck"))
        # (a micrometre's grid: the status bar's pointer to a micrometre; millimetres, the inspector's lengths in them)
        pj = os.path.join(config, "10.0", "pcbnew.json")
        cfg = json.load(open(pj)) if os.path.exists(pj) else {}
        grid = cfg.setdefault("window", {}).setdefault("grid", {})
        grid["sizes"] = [{"name": "", "x": "0.001 mm", "y": "0.001 mm"}]
        grid["last_size"] = 0
        grid["fast_grid_1"] = 0
        grid["fast_grid_2"] = 0
        cfg.setdefault("system", {})["units"] = 1
        json.dump(cfg, open(pj, "w"))
        work = os.path.join(tmp, "board")
        os.makedirs(work)
        shutil.copy(board, os.path.join(work, "b.kicad_pcb"))
        for ext in (".kicad_pro", ".kicad_dru"):
            src = os.path.splitext(board)[0] + ext
            if os.path.exists(src):
                shutil.copy(src, os.path.join(work, "b" + ext))
        with open(os.path.join(work, "b.kicad_prl"), "w") as f:
            json.dump(prl, f, indent=2)
        job = {"steps": steps, "log": os.path.join(tmp, "log.txt"), "out": os.path.join(tmp, "out.json"), "ticks": ticks}
        with open(os.path.join(tmp, "job.json"), "w") as f:
            json.dump(job, f)
        env = dict(os.environ, XDG_DATA_HOME=share, KICAD_CONFIG_HOME=config, JSPICE_NETS_JOB=os.path.join(tmp, "job.json"))
        text = ""
        # (KiCad's editor now and then crashes as it starts under Xvfb: tried again)
        for attempt in range(4):
            for p in (job["log"], job["out"]):
                if os.path.exists(p):
                    os.remove(p)
            run = subprocess.run(["xvfb-run", "-a", "-s", "-screen 0 2560x1600x24", "pcbnew", "b.kicad_pcb"], cwd=work,
                                 env=env, capture_output=True, text=True, timeout=900)
            text = open(job["log"]).read() if os.path.exists(job["log"]) else ""
            if run.returncode == 0 and os.path.exists(job["out"]):
                return json.load(open(job["out"]))
        sys.exit(f"{board}: KiCad did not finish ({run.returncode}): {text} {run.stderr[-2000:]}")


# MARK: - Boards of routed nets

LIBRARIES = os.environ.get("KICAD_FOOTPRINTS", "/usr/share/kicad/footprints")
FOOTPRINTS = [("Resistor_SMD", "R_0603_1608Metric"), ("Capacitor_SMD", "C_0805_2012Metric"),
              ("Package_SO", "SOIC-8_3.9x4.9mm_P1.27mm"), ("Package_TO_SOT_SMD", "SOT-23"),
              ("Package_DFN_QFN", "QFN-16-1EP_3x3mm_P0.5mm_EP1.75x1.75mm"), ("Package_QFP", "LQFP-32_7x7mm_P0.8mm"),
              ("Connector_PinHeader_2.54mm", "PinHeader_1x04_P2.54mm_Vertical"), ("Package_DIP", "DIP-8_W7.62mm"),
              ("Connector_PinHeader_2.54mm", "PinHeader_2x03_P2.54mm_Vertical"), ("Diode_SMD", "D_SOD-123")]
# (names that sort and filter in KiCad's ways: numbers, multipliers, an R that is a decimal point, cases)
NET_NAMES = ["SIG1", "SIG2", "SIG10", "sig3", "R1", "R10", "4k7", "4K7_IN", "D12", "D7", "/sub/clk", "/sub/CLK2",
             "GND", "VCC", "+3V3", "PWR_5V", "Net-(U1-Pad3)", "unconnected-(U2-Pad5)", "N1", "N2"]


def routed(rng, path):
    """A board of nets routed between their pads as a user routes them, for the net inspector's lengths: on two, four
    or six copper layers; footprints of both kinds of pads, now and then flipped, now and then with pads' lengths to
    their dies; each net's pads joined in turn by lines of segments and arcs, from and to a pad's position or a point
    off it in its copper, changing layers through vias (through, and on more layers blind, buried and micro ones), now
    and then a via in a pad (the line on beyond on another layer), a line ending off a via's centre in its copper, a
    branch from a line, a stub through a via, a via of nothing, a line of no length; now and then a zone, a board
    thicker or thinner, the project not using heights for lengths"""
    import pcbnew

    def vec(x, y):
        return pcbnew.VECTOR2I(int(x), int(y))

    board = pcbnew.NewBoard(path)
    layers = rng.choice([2, 2, 4, 4, 6])
    board.SetCopperLayerCount(layers)
    copper = list(board.GetEnabledLayers().CuStack())
    ds = board.GetDesignSettings()
    ds.SetBoardThickness(rng.choice([1_600_000, 1_600_000, 800_000, 1_000_000, 2_400_000]))
    ds.m_UseHeightForLengthCalcs = rng.random() > 0.15
    x0, y0 = 100 * MM, 50 * MM
    x1, y1 = x0 + rng.randint(40, 70) * MM, y0 + rng.randint(30, 50) * MM
    edge = pcbnew.PCB_SHAPE(board)
    edge.SetShape(pcbnew.SHAPE_T_RECTANGLE)
    edge.SetLayer(pcbnew.Edge_Cuts)
    edge.SetWidth(100_000)
    edge.SetStart(vec(x0, y0))
    edge.SetEnd(vec(x1, y1))
    board.Add(edge)
    ns = ds.m_NetSettings
    for name, pattern, priority in [("Signal", "SIG*", 1), ("Power", "PWR*", 0), ("Clock", "/sub/*", 2), ("Analog", "4?7*", 3)]:
        nc = pcbnew.NETCLASS(name)
        nc.SetPriority(priority)
        ns.SetNetclass(name, nc)
        ns.SetNetclassPatternAssignment(pattern, name)
    nets = []
    for name in rng.sample(NET_NAMES, rng.randint(6, len(NET_NAMES))):
        n = pcbnew.NETINFO_ITEM(board, name)
        board.Add(n)
        nets.append(n)
    pads_of = {}
    for i in range(rng.randint(5, 12)):
        lib, name = rng.choice(FOOTPRINTS)
        fp = pcbnew.FootprintLoad(f"{LIBRARIES}/{lib}.pretty", name)
        fp.SetReference(f"U{i + 1}")
        fp.SetPosition(vec(rng.randint(x0 + 5 * MM, x1 - 5 * MM), rng.randint(y0 + 5 * MM, y1 - 5 * MM)))
        fp.SetOrientationDegrees(rng.choice([0, 0, 90, 180, 270, 45]))
        board.Add(fp)
        if rng.random() < 0.3:
            fp.Flip(fp.GetPosition(), pcbnew.FLIP_DIRECTION_TOP_BOTTOM)
        for pad in fp.Pads():
            if pad.GetAttribute() == pcbnew.PAD_ATTRIB_NPTH or rng.random() < 0.25:
                continue
            net = rng.choice(nets)
            pad.SetNet(net)
            if rng.random() < 0.25:
                pad.SetPadToDieLength(rng.randint(1, 50) * 100_000)
            pads_of.setdefault(net.GetNetname(), []).append(pad)

    def pad_layers(pad):
        return [l for l in copper if pad.IsOnLayer(l)]

    def inside(pad):
        """A point in the pad's copper near its position, or its position"""
        if rng.random() < 0.7:
            return (pad.GetPosition().x, pad.GetPosition().y)
        b = pad.GetBoundingBox()
        for _ in range(20):
            q = (rng.randint(b.GetLeft(), b.GetRight()), rng.randint(b.GetTop(), b.GetBottom()))
            if pad.HitTest(vec(*q), 0):
                return q
        return (pad.GetPosition().x, pad.GetPosition().y)

    def via(at, top, bottom, net):
        v = pcbnew.PCB_VIA(board)
        v.SetPosition(vec(*at))
        a, b = copper.index(top), copper.index(bottom)
        if a > b:
            a, b = b, a
            top, bottom = bottom, top
        if a == 0 and b == len(copper) - 1:
            kind = pcbnew.VIATYPE_THROUGH
        elif b - a == 1 and (a == 0 or b == len(copper) - 1):
            kind = pcbnew.VIATYPE_MICROVIA
        elif a == 0 or b == len(copper) - 1:
            kind = pcbnew.VIATYPE_BLIND
        else:
            kind = pcbnew.VIATYPE_BURIED
        d = rng.randint(3, 4) * 100_000 if kind == pcbnew.VIATYPE_MICROVIA else rng.randint(5, 9) * 100_000
        v.SetViaType(kind)
        v.SetLayerPair(top, bottom)
        v.SetWidth(pcbnew.F_Cu, d)
        v.SetDrill(d // 2 // 50_000 * 50_000)
        v.SetNet(net)
        board.Add(v)
        return d // 2

    def segment(a, b, layer, net, width):
        if rng.random() < 0.2 and a != b:
            # (an arc bulging off the straight way)
            t = pcbnew.PCB_ARC(board)
            mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
            dx, dy = b[0] - a[0], b[1] - a[1]
            k = rng.uniform(-0.4, 0.4)
            t.SetStart(vec(*a))
            t.SetMid(vec(mx - dy * k, my + dx * k))
            t.SetEnd(vec(*b))
        else:
            t = pcbnew.PCB_TRACK(board)
            t.SetStart(vec(*a))
            t.SetEnd(vec(*b))
        t.SetWidth(width)
        t.SetLayer(layer)
        t.SetNet(net)
        board.Add(t)

    def wander(p):
        return (min(x1 - 2 * MM, max(x0 + 2 * MM, p[0] + rng.randint(-8, 8) * MM)),
                min(y1 - 2 * MM, max(y0 + 2 * MM, p[1] + rng.randint(-8, 8) * MM)))

    for name, pads in pads_of.items():
        net = pads[0].GetNet()
        width = rng.randint(2, 6) * 50_000
        points = []
        for k in range(1, len(pads)):
            if rng.random() < 0.15:
                continue
            a, b = pads[k - 1], pads[k]
            start = inside(a)
            if points and rng.random() < 0.2:
                # (a branch from a point the net's lines pass)
                start, layer = rng.choice(points)
            else:
                layer = rng.choice(pad_layers(a) or copper)
            end = inside(b)
            p = start
            for _ in range(rng.randint(0, 3)):
                q = wander(p)
                segment(p, q, layer, net, width)
                p = q
                points.append((p, layer))
                if rng.random() < 0.4:
                    other = rng.choice([l for l in copper if l != layer])
                    r = via(p, layer, other, net)
                    if rng.random() < 0.3:
                        # (the line on from a point off the via's centre, in its copper)
                        p = (p[0] + rng.randint(-r // 2, r // 2), p[1] + rng.randint(-r // 2, r // 2))
                    layer = other
            ends = pad_layers(b)
            if ends and layer not in ends:
                if rng.random() < 0.5:
                    # (a via at the pad: the line ends on another layer, in the pad)
                    via((b.GetPosition().x, b.GetPosition().y), layer, ends[0], net)
                    end = (b.GetPosition().x, b.GetPosition().y)
                else:
                    other = ends[0]
                    q = wander(p)
                    segment(p, q, layer, net, width)
                    via(q, layer, other, net)
                    p, layer = q, other
            segment(p, end, layer, net, width)
        # stubs, vias of nothing, lines of no length
        if points and rng.random() < 0.3:
            p, layer = rng.choice(points)
            q = wander(p)
            segment(p, q, layer, net, width)
            via(q, layer, rng.choice([l for l in copper if l != layer]), net)
        if rng.random() < 0.15:
            via(wander((x0 + 20 * MM, y0 + 15 * MM)), copper[0], copper[-1], net)
        if points and rng.random() < 0.1:
            p, layer = rng.choice(points)
            segment(p, p, layer, net, width)
    if rng.random() < 0.3:
        zone = pcbnew.ZONE(board)
        ls = pcbnew.LSET()
        ls.AddLayer(rng.choice(copper))
        zone.SetLayerSet(ls)
        zone.SetNet(rng.choice(nets))
        poly = zone.Outline()
        poly.NewOutline()
        for x, y in [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]:
            poly.Append(x, y)
        board.Add(zone)
        board.BuildConnectivity()
        pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    pcbnew.SaveBoard(path, board)


def boards(out, count, seed):
    os.makedirs(out, exist_ok=True)
    rng = random.Random(seed)
    for n in range(count):
        routed(rng, os.path.abspath(f"{out}/routed-{seed}-{n}.kicad_pcb"))
    print(f"{out}: {count} boards")


# MARK: - What to ask of each board

def layer_ids(board):
    """The board's copper layers' KiCad ids, top to bottom"""
    import pcbnew
    return [l for l in board.GetEnabledLayers().CuStack()]


def visible_items(rng):
    items = ["vias", "footprint_text", "footprint_anchors", "ratsnest", "grid", "footprints_front", "footprints_back",
             "footprint_values", "footprint_references", "tracks", "drc_errors", "drawing_sheet", "bitmaps", "pads",
             "zones", "drc_warnings", "drc_exclusions", "locked_item_shadows", "conflict_shadows", "shapes",
             "board_outline_area", "ly_points"]
    hidden = set()
    for name in ("tracks", "vias", "pads", "footprints_back", "footprints_front", "zones"):
        if rng.random() < 0.12:
            hidden.add(name)
    return [i for i in items if i not in hidden]


def lset_hex(bits):
    """LSET::FmtHex of the layer ids in `bits`"""
    value = 0
    for b in bits:
        value |= 1 << b
    text = f"{value:032x}"
    return "_".join(text[i:i + 8] for i in range(0, 32, 8))


def picks(board, rng, count):
    """Points to try the highlight on, in mm: near pads, tracks, vias and zones, and anywhere on the board"""
    import pcbnew
    tracks = [t for t in board.GetTracks()]
    pads = [p for f in board.GetFootprints() for p in f.Pads()]
    zones = [z for z in board.Zones() if not z.GetIsRuleArea()]
    whole = board.GetBoardEdgesBoundingBox()
    out = []
    while len(out) < count:
        k = rng.random()
        if k < 0.3 and pads:
            p = rng.choice(pads)
            b = p.GetBoundingBox()
            d = 0.3 * MM
            x = rng.uniform(b.GetLeft() - d, b.GetRight() + d)
            y = rng.uniform(b.GetTop() - d, b.GetBottom() + d)
        elif k < 0.6 and tracks:
            t = rng.choice(tracks)
            if t.GetClass() == "PCB_VIA":
                r = t.GetWidth(pcbnew.F_Cu) / 2 + 0.2 * MM
                x = t.GetPosition().x + rng.uniform(-r, r)
                y = t.GetPosition().y + rng.uniform(-r, r)
            else:
                a, b = t.GetStart(), t.GetEnd()
                u = rng.random()
                w = t.GetWidth() / 2 + 0.2 * MM
                x = a.x + (b.x - a.x) * u + rng.uniform(-w, w)
                y = a.y + (b.y - a.y) * u + rng.uniform(-w, w)
        elif k < 0.75 and zones:
            b = rng.choice(zones).GetBoundingBox()
            x = rng.uniform(b.GetLeft(), b.GetRight())
            y = rng.uniform(b.GetTop(), b.GetBottom())
        else:
            x = rng.uniform(whole.GetLeft(), whole.GetRight())
            y = rng.uniform(whole.GetTop(), whole.GetBottom())
        out.append([round(x / MM, 4), round(y / MM, 4)])
    return out


def filters(names, classes, rng):
    out = [""]
    for source in (names, classes):
        for _ in range(3):
            if not source:
                break
            word = rng.choice(source)
            if len(word) > 1:
                a = rng.randrange(len(word))
                b = rng.randrange(a, len(word)) + 1
                word = word[a:b]
            out.append(word.lower() if rng.random() < 0.5 else word)
    out.append("zz-none-zz")
    return out


def track_lengths(board):
    """Each track's BOARD::GetTrackLength: (items, length of tracks and vias, pad to die), nm. The module gives the
    std::tuple< int, double, double, double, double > it returns as a bare pointer: read as libstdc++ lays one out
    (its last element first, the int last)"""
    import ctypes
    out = {}
    for t in board.GetTracks():
        if t.GetClass() == "PCB_VIA":
            continue
        address = int(board.GetTrackLength(t))
        doubles = (ctypes.c_double * 4).from_address(address)
        count = ctypes.c_int.from_address(address + 32).value
        out[t.m_Uuid.AsString()] = [count, int(round(doubles[3])), int(round(doubles[2]))]
    return out


def inspect(path):
    import pcbnew
    name = os.path.basename(path)
    rng = random.Random(zlib.crc32(name.encode()))
    board = pcbnew.LoadBoard(path)
    copper = layer_ids(board)
    active = rng.choice(copper)
    high_contrast = rng.choice([0, 0, 1, 2])
    every = list(range(128))
    hidden_layers = set()
    if rng.random() < 0.25 and len(copper) > 1:
        hidden_layers.add(rng.choice([c for c in copper if c != active]))
    items = visible_items(rng)
    prl = {"board": {"active_layer": active, "high_contrast_mode": high_contrast,
                     "visible_layers": lset_hex([b for b in every if b not in hidden_layers]),
                     "visible_items": items},
           "net_inspector_panel": {"show_zero_pad_nets": True, "show_unconnected_nets": True},
           "meta": {"filename": "b.kicad_prl", "version": 5}}
    names = sorted({n.GetNetname() for n in board.GetNetInfo().NetsByNetcode().values() if n.GetNetCode() > 0})
    classes = sorted({n.GetNetClassName() for n in board.GetNetInfo().NetsByNetcode().values() if n.GetNetCode() > 0})
    points = picks(board, rng, 24)
    steps = [["menu", "Net Inspector", 12], ["read", True]]
    steps += [["filter", t] for t in filters(names, classes, rng)]
    steps += [["filter", ""], ["menu", "Zoom to Fit", 10], ["calibrate"]]
    steps += [["pick", p] for p in points]
    first = drive(path, prl, steps)
    # (a wildcard pattern, a regular expression between ^ and $, one between slashes, a part of a name)
    rules = []
    if names:
        rules.append(rng.choice(names)[:2] + "*")
        rules.append("^" + rng.choice(names)[:1] + ".*$")
        rules.append("/" + rng.choice(names)[-1:] + "$/")
        rules.append(rng.choice(names)[-2:])
    grouped_prl = {"net_inspector_panel": {"show_zero_pad_nets": True, "show_unconnected_nets": True,
                                           "group_by_netclass": True, "custom_group_rules": rules},
                   "meta": {"filename": "b.kicad_prl", "version": 5}}
    second = drive(path, grouped_prl, [["menu", "Net Inspector", 12], ["read", False]])
    # (the panel now and then read before it has filled its list: read again)
    for _ in range(3):
        if second["rows"] or not first["rows"]:
            break
        second = drive(path, grouped_prl, [["menu", "Net Inspector", 24], ["read", False]])
    record = {"columns": first["columns"], "rows": first["rows"], "orders": first["orders"],
              "filters": first["filters"],
              "highlight": {"settings": prl["board"], "transform": first["transform"], "picks": first.get("picks", [])},
              "grouped": {"rules": rules, "rows": second["rows"]},
              "tracks": track_lengths(board)}
    with open(path[: -len(".kicad_pcb")] + ".nets", "w") as f:
        json.dump(record, f, indent=0)
        f.write("\n")


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "boards":
        boards(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]) if len(sys.argv) > 4 else 20261201)
    elif len(sys.argv) >= 2:
        for board in sys.argv[1:]:
            inspect(board)
            print(board, file=sys.stderr)
    else:
        sys.exit(__doc__)
