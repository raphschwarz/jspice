#!/usr/bin/env python3
"""KiCad's teardrops on boards, for checking the port's (KiCadRouter's Teardrops) against: each board copied to a
folder of its own, its teardrop settings set (with --random, as KiCad's Set Teardrops dialog sets them: the board's
settings for round shapes, other shapes and track ends, and which of vias, plated pads, surface pads and track ends
they go on; then each of those vias and pads given the settings of its shape, teardrops on), and the copy run through
kicad-cli's design rules check with its zones refilled and the board saved (`kicad-cli pcb drc --refill-zones
--save-board`: ZONE_FILLER_TOOL::FillAllZones, which has TEARDROP_MANAGER::UpdateTeardrops build the board's teardrops
again from scratch before it fills the zones, the teardrops among them). KiCad's Python module does not reach the
teardrop manager, and kicad-cli has no command of its own for teardrops; this is the way KiCad makes them without its
editor. Then, through the pcbnew module, the board as kicad-cli saved it read, and written next to the board as
BOARD.teardrops (JSON): the settings set (none without --random: the board's own, as its file and project have them),
each teardrop (a zone of a teardrop's type; KiCad writes them without a uuid, sorted by their layers and the uuids it
made them with, which are lost) with its layer, net, type (padvia or track_end), priority, outline, fill on its layer
(as fills.py writes a fill) and the pads, vias and tracks the connectivity finds it connected with (its cluster:
CONNECTIVITY_DATA::GetConnectedItems), every other zone's
fill as kicad-cli made it (by uuid, as fills.py writes them), with the teardrops among them, and the order kicad-cli
wrote the board's zones in (each by its uuid, a teardrop as "teardrop #N", N its place among the teardrops).

    teardrops.py [--random SEED] BOARD.kicad_pcb...

With --draw, a board of the teardrops random boards seldom make, saved, and then written as with --random with the
drawn board's settings (round shapes' curved, other shapes' straight; on vias, plated pads and track ends, not on
surface pads, which have settings of their own): round, oval, rectangular, rounded and chamfered, trapezoid and custom
pads, turned, with tracks into them straight, at angles, off their centres and across them; tracks too short that go
on into the next, gently and round a bend too sharp; arcs; tracks on the back and inside; surface pads with settings
of their own (curved and straight, narrower, longer, off, a filter too fine for the track); vias with tracks across
them, ending inside them, of no net, and one with a mask opening of its own (its mask teardrop); other nets' pads of
clearances of their own, vias, drawings and a text on copper close by; pads in a zone of their net; track ends of two
widths.

    teardrops.py --draw OUT.kicad_pcb

With --boards, random boards of teardrops, each saved and written as with --random: on a grid, pads of every shape,
size and turn (plated, or on either side, some with random settings of their own) and vias, each with tracks into it
at random angles and widths, off its centre, across it, too short and going on into a second at a random bend, or
arcs, on any layer, now and then another net's track or via close by; track ends of two widths; now and then a zone of
a net, filled.

    teardrops.py --boards OUTDIR COUNT [SEED]
"""

import json
import math
import os
import random
import shutil
import subprocess
import sys
import tempfile

import pcbnew

import fills

MM = 1_000_000


def vec(x, y):
    return pcbnew.VECTOR2I(int(x), int(y))


def pts(chain):
    return [[chain.CPoint(k).x, chain.CPoint(k).y] for k in range(chain.PointCount())]


# --- the settings

def random_parameters(rng):
    """A TEARDROP_PARAMETERS of random values, of the kinds the dialog takes (ratios as whole percents)"""
    return {"maxLength": rng.choice([0, 500_000, 1_000_000, 1_000_000, 1_500_000, 3_000_000]),
            "maxWidth": rng.choice([0, 800_000, 1_200_000, 2_000_000, 2_000_000, 4_000_000]),
            "bestLengthRatio": rng.choice([0.3, 0.5, 0.5, 0.7, 1.0, 1.3]),
            "bestWidthRatio": rng.choice([0.6, 0.8, 1.0, 1.0]),
            "widthToSizeFilterRatio": rng.choice([0.5, 0.75, 0.9, 0.9, 1.0]),
            "curvedEdges": rng.random() < 0.5,
            "enabled": False,
            "allowTwoSegments": rng.random() < 0.7,
            "onPadsInZones": rng.random() < 0.4}


def random_settings(rng):
    s = {"round": random_parameters(rng), "rect": random_parameters(rng), "track": random_parameters(rng),
         "vias": rng.random() < 0.8, "pthPads": rng.random() < 0.8, "smdPads": rng.random() < 0.8,
         "trackToTrack": rng.random() < 0.6}
    s["track"]["enabled"] = s["trackToTrack"]
    return s


def set_parameters(item, p):
    item.SetTeardropsEnabled(True)
    item.SetTeardropBestLengthRatio(p["bestLengthRatio"])
    item.SetTeardropMaxLength(p["maxLength"])
    item.SetTeardropBestWidthRatio(p["bestWidthRatio"])
    item.SetTeardropMaxWidth(p["maxWidth"])
    item.SetTeardropCurved(p["curvedEdges"])
    item.SetTeardropPreferZoneConnections(not p["onPadsInZones"])
    item.SetTeardropAllowSpanTwoTracks(p["allowTwoSegments"])
    item.SetTeardropMaxTrackWidth(p["widthToSizeFilterRatio"])


def is_round(pad):
    """TEARDROP_MANAGER::IsRound of a pad on all its layers"""
    al = pcbnew.PADSTACK.ALL_LAYERS
    shape = pad.GetShape(al)
    return shape == pcbnew.PAD_SHAPE_CIRCLE or (shape == pcbnew.PAD_SHAPE_OVAL and pad.GetSize(al).x == pad.GetSize(al).y)


def apply_settings(board, s):
    """DIALOG_GLOBAL_EDIT_TEARDROPS::TransferDataFromWindow with "add teardrops with default values for shape" and
    no filters: each via, plated pad and surface (or connector) pad it is asked for given its shape's settings,
    teardrops on"""
    if s["vias"]:
        for t in board.GetTracks():
            if t.GetClass() == "PCB_VIA":
                set_parameters(t, s["round"])
    for fp in board.GetFootprints():
        for pad in fp.Pads():
            a = pad.GetAttribute()
            if (s["pthPads"] and a == pcbnew.PAD_ATTRIB_PTH) or \
                    (s["smdPads"] and a in (pcbnew.PAD_ATTRIB_SMD, pcbnew.PAD_ATTRIB_CONN)):
                set_parameters(pad, s["round"] if is_round(pad) else s["rect"])


def project_entry(name, p):
    """BOARD_DESIGN_SETTINGS' teardrop_parameters entry of a target, as KiCad writes it"""
    return {"td_target_name": name, "td_enabled": p["enabled"], "td_maxlen": p["maxLength"] / MM,
            "td_maxheight": p["maxWidth"] / MM, "td_length_ratio": p["bestLengthRatio"],
            "td_height_ratio": p["bestWidthRatio"], "td_curve_segcount": 1 if p["curvedEdges"] else 0,
            "td_width_to_size_filter_ratio": p["widthToSizeFilterRatio"],
            "td_allow_use_two_tracks": p["allowTwoSegments"], "td_on_pad_in_zone": p["onPadsInZones"]}


def write_project_settings(pro, s):
    """The board's settings into its project (BOARD_DESIGN_SETTINGS' teardrop_options and teardrop_parameters)"""
    with open(pro) as f:
        project = json.load(f)
    ds = project.setdefault("board", {}).setdefault("design_settings", {})
    ds["teardrop_options"] = [{"td_onvia": s["vias"], "td_onpthpad": s["pthPads"], "td_onsmdpad": s["smdPads"],
                               "td_ontrackend": s["trackToTrack"], "td_onroundshapesonly": False}]
    ds["teardrop_parameters"] = [project_entry("td_round_shape", s["round"]), project_entry("td_rect_shape", s["rect"]),
                                 project_entry("td_track_end", s["track"])]
    with open(pro, "w") as f:
        json.dump(project, f, indent=2)


# --- what KiCad made

def layer_fills(z, layer):
    if not z.HasFilledPolysForLayer(layer):
        return []
    p = z.GetFilledPolysList(layer)
    return [{"polygon": [pts(p.Outline(i))] + [pts(p.CHole(i, j)) for j in range(p.HoleCount(i))],
             "island": z.IsIsland(layer, i)} for i in range(p.OutlineCount())]


def uuids(items):
    return sorted(i.m_Uuid.AsString() for i in items)


def teardrop_types(path):
    """The type of each of the board's own teardrops, in its order (which the Python module does not give: its
    TEARDROP_TYPE is not wrapped)"""
    types = []
    with open(path) as f:
        zone = None
        for line in f:
            if line.startswith("\t(zone"):
                zone = []
            elif zone is not None and line.startswith("\t)"):
                if any("(type padvia)" in l for l in zone):
                    types.append("padvia")
                elif any("(type track_end)" in l for l in zone):
                    types.append("track_end")
                zone = None
            elif zone is not None:
                zone.append(line)
    return types


def made(path):
    board = pcbnew.LoadBoard(path)
    connectivity = board.GetConnectivity()
    types = iter(teardrop_types(path))
    teardrops, fills, order = [], {}, []
    for z in board.Zones():
        order.append(f"teardrop #{len(teardrops)}" if z.IsTeardropArea() else z.m_Uuid.AsString())
        if z.GetIsRuleArea():
            continue
        if not z.IsTeardropArea():
            fills[z.m_Uuid.AsString()] = {pcbnew.LSET.Name(l): layer_fills(z, l) for l in z.GetLayerSet().Seq()}
            continue
        layer = z.GetFirstLayer()
        connected = list(connectivity.GetConnectedItems(z)) if z.IsOnCopperLayer() else []
        teardrops.append({
            "layer": pcbnew.LSET.Name(layer), "net": z.GetNetname() if z.IsOnCopperLayer() else "",
            "type": next(types),
            "priority": z.GetAssignedPriority(), "outline": pts(z.Outline().COutline(0)),
            "fill": layer_fills(z, layer),
            "pads": uuids(i for i in connected if i.GetClass() == "PAD"),
            "vias": uuids(i for i in connected if i.GetClass() == "PCB_VIA"),
            "tracks": uuids(i for i in connected if i.GetClass() in ("PCB_TRACK", "PCB_ARC"))})
    return teardrops, fills, order


def write(path, settings=None):
    """KiCad's teardrops of the board (with `settings` set first), next to it"""
    base = os.path.splitext(path)[0]
    name = os.path.basename(base)
    with tempfile.TemporaryDirectory() as tmp:
        copy = os.path.join(tmp, name + ".kicad_pcb")
        shutil.copy(path, copy)
        # (the project, and the board's own design rules, which the teardrops keep their clearances by)
        for ext in (".kicad_pro", ".kicad_dru"):
            if os.path.exists(base + ext):
                shutil.copy(base + ext, os.path.join(tmp, name + ext))
        if settings:
            board = pcbnew.LoadBoard(copy)
            apply_settings(board, settings)
            pcbnew.SaveBoard(copy, board)
            write_project_settings(os.path.join(tmp, name + ".kicad_pro"), settings)
        subprocess.run(["kicad-cli", "pcb", "drc", "--refill-zones", "--save-board", "-o", os.path.join(tmp, "drc.rpt"),
                        copy], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        teardrops, fills, order = made(copy)
    out = {"teardrops": teardrops, "fills": fills, "order": order}
    if settings:
        out["settings"] = settings
    with open(base + ".teardrops", "w") as f:
        json.dump(out, f, separators=(",", ":"))
        f.write("\n")
    return len(teardrops)


def main():
    args = sys.argv[1:]
    if args and args[0] == "--draw":
        settings = draw(args[1])
        write(args[1], settings)
        return
    if args and args[0] == "--boards":
        out, count, seed = args[1], int(args[2]), args[3] if len(args) > 3 else "1"
        os.makedirs(out, exist_ok=True)
        for i in range(count):
            path = os.path.join(out, f"teardrops-{seed}-{i}.kicad_pcb")
            settings = random_board(path, random.Random(f"{seed}-board-{i}"))
            n = write(path, settings)
            print(f"{os.path.basename(path)}: {n} teardrops")
        return
    seed = None
    if args and args[0] == "--random":
        seed = args[1]
        args = args[2:]
    for path in args:
        settings = None
        if seed is not None:
            settings = random_settings(random.Random(f"{seed}-{os.path.basename(path)}"))
        n = write(path, settings)
        print(f"{os.path.basename(path)}: {n} teardrops")


# --- the drawn board, in millimetres (fills.py's drawing helpers)

def track(board, a, b, net, width=0.25, layer=pcbnew.F_Cu, mask=False):
    t = pcbnew.PCB_TRACK(board)
    t.SetStart(vec(*fills.mm(*a)))
    t.SetEnd(vec(*fills.mm(*b)))
    t.SetWidth(fills.mm(width)[0])
    t.SetLayer(layer)
    if net:
        t.SetNet(net)
    if mask:
        t.SetHasSolderMask(True)
    board.Add(t)
    return t


def out_of(at, angle, length, offset=0.0):
    """The point `length` from `at` at `angle` (degrees, y down), the line moved `offset` to its side"""
    a = math.radians(angle)
    return (at[0] + length * math.cos(a) - offset * math.sin(a), at[1] + length * math.sin(a) + offset * math.cos(a))


def spoke(board, at, angle, length, net, width=0.25, offset=0.0, layer=pcbnew.F_Cu, mask=False):
    """A track from `at` (moved `offset` to its side) out at `angle`"""
    return track(board, out_of(at, angle, 0, offset), out_of(at, angle, length, offset), net, width, layer, mask)


def own_parameters(**p):
    d = {"maxLength": 1_000_000, "maxWidth": 2_000_000, "bestLengthRatio": 0.5, "bestWidthRatio": 1.0,
         "widthToSizeFilterRatio": 0.9, "curvedEdges": False, "enabled": True, "allowTwoSegments": True,
         "onPadsInZones": False}
    d.update(p)
    return d


def draw(path):
    """The drawn board: its settings (round shapes' curved, others' straight; vias, plated pads and track ends
    asked, surface pads not, which keep settings of their own) handed back for write()"""
    f = fills
    board = pcbnew.NewBoard(path)
    board.SetCopperLayerCount(4)
    f.box_edges(board, 0, 0, 180, 130)
    nets = {}
    for name in ["GND", "A", "B", "C", "D", "E"]:
        n = pcbnew.NETINFO_ITEM(board, name)
        board.Add(n)
        nets[name] = n
    gnd, a, b, c, d, e = (nets[k] for k in ["GND", "A", "B", "C", "D", "E"])
    F, B, In1 = pcbnew.F_Cu, pcbnew.B_Cu, pcbnew.In1_Cu
    pth = {"drill": (0.8, 0.8)}

    # 1. round plated pads: tracks in at angles, off their centres, across them, too short ones that go on into
    # the next (gently, and round a bend too sharp), an arc out of one, wide tracks, on the back and inside
    y = 10
    for i, (angle, offset) in enumerate([(0, 0), (30, 0), (45, 0), (90, 0), (135, 0.4), (200, -0.5), (0, 0.75)]):
        at = (10 + 12 * i, y)
        f.lone_pad(board, f"R{i}", at, a, kind="circle", size=(1.7, 1.7), **pth)
        spoke(board, at, angle, 6, a, offset=offset)
    at = (95, y)
    f.lone_pad(board, "X1", at, b, kind="circle", size=(1.7, 1.7), **pth)
    track(board, (89, y + 0.2), (101, y - 0.2), b)
    at = (110, y)
    f.lone_pad(board, "S1", at, b, kind="circle", size=(1.7, 1.7), **pth)
    track(board, at, out_of(at, 0, 1.1), b)
    track(board, out_of(at, 0, 1.1), out_of(out_of(at, 0, 1.1), 20, 5), b)
    at = (125, y)
    f.lone_pad(board, "S2", at, b, kind="circle", size=(1.7, 1.7), **pth)
    track(board, at, out_of(at, 0, 1.0), b)
    track(board, out_of(at, 0, 1.0), out_of(out_of(at, 0, 1.0), 75, 5), b)
    at = (140, y)
    f.lone_pad(board, "S3", at, b, kind="circle", size=(1.7, 1.7), **pth)
    f.arc_track(board, at, (143, y + 1.2), (146, y + 4), b, width=0.25)
    at = (155, y)
    f.lone_pad(board, "W1", at, c, kind="circle", size=(2.2, 2.2), **pth)
    spoke(board, at, 10, 6, c, width=0.6)
    spoke(board, at, 100, 6, c, width=0.25, layer=B)
    spoke(board, at, 200, 6, c, width=0.2, layer=In1)

    # 2. plated pads of other shapes, turned: ovals along and across, rectangles, rounded rectangles
    y = 26
    shapes = [("oval", (2.6, 1.6), 0, 0), ("oval", (2.6, 1.6), 0, 90), ("oval", (2.6, 1.6), 30, 10),
              ("oval", (1.6, 2.6), 0, 60), ("rect", (2.0, 1.4), 0, 0), ("rect", (2.0, 1.4), 45, 100),
              ("roundrect", (2.0, 1.4), 0, 20), ("roundrect", (2.0, 1.4), 90, 160)]
    for i, (kind, size, rot, angle) in enumerate(shapes):
        at = (10 + 14 * i, y)
        f.lone_pad(board, f"P{i}", at, a, kind=kind, size=size, angle=rot, **pth)
        spoke(board, at, angle, 6, a)
        spoke(board, at, angle + 180, 6, a, offset=0.3)

    # 3. surface pads with settings of their own: every shape, turned, tracks into their sides, corners and ends
    y = 42
    poly = [[(0.3, -0.4), (1.5, -0.7), (1.5, 0.7), (0.3, 0.4)]]
    smd = [("rect", (1.8, 1.2), 0, 0, own_parameters()),
           ("rect", (1.8, 1.2), 30, 70, own_parameters(curvedEdges=True)),
           ("roundrect", (1.8, 1.2), 0, 35, own_parameters(curvedEdges=True)),
           ("roundrect", (1.8, 1.2), 45, -20, own_parameters(curvedEdges=True, bestWidthRatio=0.8, maxWidth=0)),
           ("chamfered", (1.8, 1.2), 0, 10, own_parameters(curvedEdges=True)),
           ("trapezoid", (1.8, 1.2), 0, 0, own_parameters(bestLengthRatio=1.0, maxLength=0)),
           ("oval", (2.4, 1.2), 0, 0, own_parameters(curvedEdges=True)),
           ("oval", (2.4, 1.2), 15, 75, own_parameters(curvedEdges=True)),
           ("circle", (1.4, 1.4), 0, 50, own_parameters(curvedEdges=True, bestWidthRatio=0.6)),
           ("custom", (1.0, 1.0), 0, 180, own_parameters()),
           ("custom", (1.0, 1.0), 90, 10, own_parameters(curvedEdges=True))]
    for i, (kind, size, rot, angle, params) in enumerate(smd):
        at = (10 + 13 * i, y)
        kw = {"primitives": poly, "anchor": "rect"} if kind == "custom" else {}
        fp = f.lone_pad(board, f"M{i}", at, b, kind=kind, size=size, angle=rot, **kw)
        set_parameters(fp.Pads()[0], params)
        spoke(board, at, angle, 6, b, offset=0.25 if i % 3 == 2 else 0)
    # a surface pad's teardrop off, one too narrow for its track, one that keeps a second segment short
    at = (10, 52)
    fp = f.lone_pad(board, "N1", at, b, kind="rect", size=(1.8, 1.2))
    set_parameters(fp.Pads()[0], own_parameters(enabled=False))
    spoke(board, at, 0, 6, b)
    at = (25, 52)
    fp = f.lone_pad(board, "N2", at, b, kind="rect", size=(1.8, 1.2))
    set_parameters(fp.Pads()[0], own_parameters(widthToSizeFilterRatio=0.3))
    spoke(board, at, 0, 6, b)
    at = (40, 52)
    fp = f.lone_pad(board, "N3", at, b, kind="rect", size=(1.8, 1.2))
    set_parameters(fp.Pads()[0], own_parameters(allowTwoSegments=False, bestLengthRatio=1.2, maxLength=0))
    track(board, at, out_of(at, 0, 1.2), b)
    track(board, out_of(at, 0, 1.2), out_of(out_of(at, 0, 1.2), 10, 5), b)

    # 4. vias: radial tracks, off their centres, across them, arcs, a track ending inside one, tracks of no net,
    # a track with a mask opening of its own
    y = 64
    cases = [(0, 0), (60, 0.2), (150, -0.25), (270, 0)]
    for i, (angle, offset) in enumerate(cases):
        at = (10 + 10 * i, y)
        f.via(board, at, c)
        spoke(board, at, angle, 5, c, offset=offset)
    at = (55, y)
    f.via(board, at, c, size=1.0, drill=0.5)
    track(board, (50, y - 0.1), (60, y + 0.1), c)
    at = (70, y)
    f.via(board, at, c)
    track(board, (70.15, y), (76, y + 2), c)
    at = (85, y)
    f.via(board, at, c)
    f.arc_track(board, at, (87, y - 1.5), (90, y - 2), c, width=0.2)
    at = (100, y)
    f.via(board, at, None)
    spoke(board, at, 20, 5, None)
    at = (115, y)
    f.via(board, at, c)
    spoke(board, at, -30, 5, c, mask=True)
    spoke(board, at, 120, 5, c, layer=B)

    # 5. other nets' copper close by, which the teardrops narrow to keep clear of: a track alongside, another net's
    # pad, two vias of two nets with their teardrops into one gap, a drawing on copper
    y = 82
    at = (10, y)
    f.via(board, at, d, size=1.2, drill=0.6)
    spoke(board, at, 0, 6, d)
    f.lone_pad(board, "O0", (11.0, y + 1.4), e, kind="rect", size=(1.0, 1.0), clearance=0.5)
    at = (30, y)
    f.lone_pad(board, "O1", at, d, kind="circle", size=(2.0, 2.0), **pth)
    spoke(board, at, 0, 6, d)
    f.lone_pad(board, "O2", (32.2, y + 1.8), e, kind="rect", size=(1.0, 1.0), clearance=0.5)
    f.via(board, (50, y), d, size=1.2, drill=0.6)
    f.via(board, (51.6, y + 1.3), e, size=1.2, drill=0.6)
    track(board, (50, y), (56, y), d)
    track(board, (51.6, y + 1.3), (45.6, y + 1.3), e)
    track(board, (150, y), (156, y), e, width=0.2)
    track(board, (150, y + 1.0), (156, y + 1.0), d, width=0.2)
    f.via(board, (150, y), e, size=0.8, drill=0.4)
    f.via(board, (150, y + 1.0), d, size=0.8, drill=0.4)
    at = (70, y)
    f.via(board, at, d, size=1.2, drill=0.6)
    spoke(board, at, 0, 6, d)
    f.shape(board, pcbnew.SHAPE_T_CIRCLE, F, None, start=(71.4, y - 1.0), end=(71.7, y - 1.0), filled=True)
    at = (90, y)
    f.via(board, at, d, size=1.2, drill=0.6)
    spoke(board, at, 0, 6, d)
    f.text(board, "TD", (93.2, y - 1.5), size=1.0)

    # 6. pads in zones of their net: a via and a plated pad the zone joins to their track (no teardrop: the
    # board's settings prefer the zone), a surface pad that asks for one in the zone too
    y = 100
    f.zone(board, gnd, [F], fills.rect(5, 95, 60, 110), connection=pcbnew.ZONE_CONNECTION_FULL, clearance=0.3)
    f.via(board, (10, y), gnd)
    spoke(board, (10, y), 0, 6, gnd)
    f.lone_pad(board, "Z1", (25, y), gnd, kind="circle", size=(1.7, 1.7), **pth)
    spoke(board, (25, y), 30, 6, gnd)
    fp = f.lone_pad(board, "Z2", (40, y), gnd, kind="rect", size=(1.8, 1.2))
    set_parameters(fp.Pads()[0], own_parameters(onPadsInZones=True))
    spoke(board, (40, y), 0, 6, gnd)

    # 7. track ends of two widths: wide on narrow, end on end, at an angle; of about one width (none); a pad at the
    # end (the pad's first); a T
    y = 118
    track(board, (80, y), (88, y), e, width=0.8)
    track(board, (88, y), (96, y), e, width=0.25)
    track(board, (100, y), (107, y), e, width=0.6)
    track(board, (107, y), (112, y + 5), e, width=0.2)
    track(board, (115, y), (122, y), e, width=0.5)
    track(board, (122, y), (129, y), e, width=0.46)
    f.lone_pad(board, "T1", (140, y), e, kind="circle", size=(1.0, 1.0), **pth)
    track(board, (133, y), (140, y), e, width=0.6)
    track(board, (140, y), (147, y), e, width=0.2)
    track(board, (150, y - 6), (150, y + 6), e, width=0.25)
    track(board, (150, y), (158, y), e, width=0.8)
    track(board, (160, y), (170, y), e, width=0.8, layer=B)
    track(board, (170, y), (170, y - 6), e, width=0.3, layer=B)

    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    board.BuildConnectivity()
    pcbnew.SaveBoard(path, board)
    track_params = own_parameters(curvedEdges=True, bestLengthRatio=1.0)
    track_params["enabled"] = True
    return {"round": own_parameters(curvedEdges=True, enabled=False), "rect": own_parameters(enabled=False),
            "track": track_params, "vias": True, "pthPads": True, "smdPads": False, "trackToTrack": True}


# --- random boards of teardrops

def random_board(path, rng):
    """A board of random pads and vias (of every shape, size and turn, plated or on either side) and tracks into them
    (at random angles, off their centres, across them, short ones going on into a second at a random bend, arcs, of
    random widths, on any layer), other nets' tracks and vias close by, track ends of two widths, now and then a zone of
    a net filled; saved, and random settings handed back (some surface pads given settings of their own, which the
    settings then leave them if they do not go on surface pads)"""
    f = fills
    board = pcbnew.NewBoard(path)
    board.SetCopperLayerCount(4)
    f.box_edges(board, 0, 0, 150, 100)
    nets = []
    for k in range(10):
        n = pcbnew.NETINFO_ITEM(board, f"N{k}")
        board.Add(n)
        nets.append(n)
    layers = [pcbnew.F_Cu, pcbnew.B_Cu, pcbnew.In1_Cu, pcbnew.In2_Cu]
    kinds = ["circle", "circle", "oval", "rect", "roundrect", "chamfered", "trapezoid", "custom"]
    poly = [[(0.3, -0.4), (1.4, -0.6), (1.4, 0.6), (0.3, 0.4)]]

    def r(a, b):
        return round(rng.uniform(a, b), 3)

    def tracks_from(at, net, size, layer_choices):
        for _ in range(rng.choice([1, 1, 2, 3])):
            layer = rng.choice(layer_choices)
            angle = rng.choice([0, 45, 90, 135, 180, 225, 270, 315, r(0, 360)])
            width = rng.choice([0.15, 0.2, 0.25, 0.25, 0.3, 0.4, 0.6])
            offset = rng.choice([0, 0, 0, r(-0.6, 0.6) * size])
            how = rng.random()
            if how < 0.12:
                # across it
                a = out_of(at, angle, -r(1.0, 3.0), offset)
                b = out_of(at, angle, r(1.0, 3.0), offset)
                track(board, a, b, net, width, layer)
            elif how < 0.24:
                # an arc out of it
                end = out_of(at, angle, r(2.0, 4.0))
                mid = out_of(out_of(at, angle, 0.5 * ((end[0] - at[0]) ** 2 + (end[1] - at[1]) ** 2) ** 0.5),
                             angle + 90, r(-0.8, 0.8))
                f.arc_track(board, at, mid, end, net, width=width, layer=layer)
            elif how < 0.5:
                # too short, going on into the next
                first = out_of(at, angle, size / 2 + r(0.0, 0.6), offset)
                start = out_of(at, angle, 0, offset)
                track(board, start, first, net, width, layer)
                track(board, first, out_of(first, angle + rng.choice([r(-30, 30), r(-80, 80)]), r(0.5, 3.0)), net, width, layer)
            else:
                track(board, out_of(at, angle, 0, offset), out_of(at, angle, r(1.0, 5.0), offset), net, width, layer)
            if rng.random() < 0.3:
                # another net's track or via close by
                other = rng.choice(nets)
                side = rng.choice([-1, 1]) * (size / 2 + r(0.2, 1.0))
                if rng.random() < 0.6:
                    track(board, out_of(at, angle, r(0.0, 1.0), side), out_of(at, angle, r(2.0, 5.0), side), other,
                          rng.choice([0.15, 0.2, 0.3]), layer)
                else:
                    f.via(board, out_of(at, angle + rng.choice([-30, 30]), size / 2 + r(0.6, 1.6)), other,
                          size=0.6, drill=0.3)

    for cy in range(5, 100, 10):
        for cx in range(5, 150, 10):
            at = (cx + r(-1.5, 1.5), cy + r(-1.5, 1.5))
            net = rng.choice(nets + [None] if rng.random() < 0.05 else nets)
            what = rng.random()
            if what < 0.55:
                kind = rng.choice(kinds)
                size = (r(0.8, 2.6), r(0.6, 2.0)) if kind not in ("circle", "custom") else (r(0.8, 2.4),) * 2
                if kind == "custom":
                    size = (1.0, 1.0)
                plated = rng.random() < 0.5 and kind != "custom"
                kw = {"primitives": poly, "anchor": rng.choice(["rect", "circle"])} if kind == "custom" else {}
                angle = rng.choice([0, 0, 15, 30, 45, 90, r(0, 180)])
                if plated:
                    d = round(min(size) * r(0.35, 0.6), 2)
                    kw["drill"] = (d, d)
                    side = layers
                else:
                    side = [rng.choice([pcbnew.F_Cu, pcbnew.B_Cu])]
                    kw["layer"] = side[0]
                fp = f.lone_pad(board, f"U{cx}_{cy}", at, net, kind=kind, size=size, angle=angle, **kw)
                if not plated and rng.random() < 0.5:
                    p = random_parameters(rng)
                    p["enabled"] = rng.random() < 0.85
                    set_parameters(fp.Pads()[0], p)
                    if not p["enabled"]:
                        fp.Pads()[0].SetTeardropsEnabled(False)
                tracks_from(at, net, min(size), side)
            elif what < 0.85:
                size = rng.choice([0.6, 0.8, 0.8, 1.0, 1.2])
                f.via(board, at, net, size=size, drill=round(size * 0.5, 2))
                tracks_from(at, net, size, layers)
            else:
                # track ends of two widths
                layer = rng.choice(layers)
                angle = r(0, 360)
                mid = out_of(at, angle, r(1.0, 3.0))
                wide, narrow = rng.choice([(0.8, 0.25), (0.6, 0.2), (0.5, 0.45), (1.0, 0.3), (0.4, 0.15)])
                track(board, at, mid, net, wide, layer)
                track(board, mid, out_of(mid, angle + r(-60, 60), r(1.0, 3.0)), net, narrow, layer)
    if rng.random() < 0.4:
        x0, y0 = r(0, 80), r(0, 40)
        f.zone(board, rng.choice(nets), [rng.choice(layers)], f.rect(x0, y0, x0 + r(20, 60), y0 + r(20, 50)),
               connection=rng.choice([pcbnew.ZONE_CONNECTION_FULL, pcbnew.ZONE_CONNECTION_THERMAL]), clearance=0.3)
        pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    board.BuildConnectivity()
    pcbnew.SaveBoard(path, board)
    return random_settings(rng)


if __name__ == "__main__":
    main()
