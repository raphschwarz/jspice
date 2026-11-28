#!/usr/bin/env python3
"""KiCad's footprint checker and pad numbering, done by KiCad, for checking the port's (KiCadRouter's
FootprintChecks.swift and FootprintEditor.swift) against.

    footprint-checker.py checks OUTDIR [COUNT [SEED]]
        footprints made to fail the footprint checker's checks (hand-made ones: pads over each other of different
        numbers, of one number, of one net tie group, touching, on other layers, holes at one place and touching, every
        shape of pad, custom ones; silk over pads and mask openings; footprints.py's faulty footprints of KiCad's
        libraries), COUNT random ones (pads of every kind crowded together, drawings and texts on the silk and mask
        layers, courtyards closed, open and none, net tie groups) and some of KiCad's libraries as they are, each
        OUTDIR/checks.pretty/CASE.kicad_mod, and what KiCad's own footprint checker finds of each, as
        DIALOG_FOOTPRINT_CHECKER::runChecks calls KiCad's functions (BuildCourtyardCaches' malformed courtyards, a
        missing courtyard, CheckFootprintAttributes, CheckPads, CheckShortingPads, a net tie's CheckNetTiePadGroups
        and CheckNetTies, CheckClippedSilk), each through KiCad's pcbnew module with a callback (callbacks.cpp), on a
        board of its own as the footprint editor's: OUTDIR/checks.json, each marker's check, the severity the footprint
        editor's design settings give it (BOARD_DESIGN_SETTINGS' defaults), its detail, its items and its position.
    footprint-checker.py numbers OUTDIR [COUNT [SEED]]
        FOOTPRINT::GetNextPadNumber of footprints of random pad numbers after random last numbers (prefixes, digits,
        question marks, numbers too long for an int, characters not ASCII): OUTDIR/numbers.json.
    footprint-checker.py renumber OUTDIR
        KiCad's own footprint editor (the PCB editor under Xvfb, a footprint of a board opened in it with Ctrl+E, as
        footprints.py editboard opens one) renumbering pads with its Renumber Pads tool (PAD_TOOL::EnumeratePads), its
        dialog's start, step and prefix set, pads clicked, clicked again and dragged over (RENUMBER_CASES), the run
        finished with a double click and the footprint saved back onto the board (File > Save): OUTDIR/renumber.pretty
        holds the footprints, OUTDIR/renumber.json each run's settings, the pointer's events as KiCad's tool had them
        and the pad numbers KiCad gave.

KiCad 10's pcbnew Python module, g++ (callbacks.cpp), and for renumber Xvfb (xvfb-run) and a KiCad configuration made by
running KiCad once (it is copied; KICAD_CONFIG_HOME names it).
"""

import ctypes
import json
import math
import os
import random
import shutil
import subprocess
import sys
import tempfile
import uuid as uuidlib

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import footprints  # noqa: E402  (its faulty footprints and their faults)

STOCK = os.environ.get("KICAD_FOOTPRINT_DIR", "/usr/share/kicad/footprints")
MM = 1_000_000

# PCB_DRC_CODE (pcbnew/drc/drc_item.h), in order from 1, and the settings key of those the checker reports
DRC_CODES = ["UNCONNECTED_ITEMS", "SHORTING_ITEMS", "ALLOWED_ITEMS", "TEXT_ON_EDGECUTS", "CLEARANCE", "CREEPAGE",
             "TRACKS_CROSSING", "EDGE_CLEARANCE", "ZONES_INTERSECT", "ISOLATED_COPPER", "STARVED_THERMAL",
             "DANGLING_VIA", "DANGLING_TRACK", "DRILLED_HOLES_TOO_CLOSE", "DRILLED_HOLES_COLOCATED", "HOLE_CLEARANCE",
             "TRACK_WIDTH", "TRACK_ANGLE", "TRACK_SEGMENT_LENGTH", "ANNULAR_WIDTH", "CONNECTION_WIDTH",
             "DRILL_OUT_OF_RANGE", "VIA_DIAMETER", "PADSTACK", "PADSTACK_INVALID", "MICROVIA_DRILL_OUT_OF_RANGE",
             "OVERLAPPING_FOOTPRINTS", "MISSING_COURTYARD", "MALFORMED_COURTYARD", "PTH_IN_COURTYARD",
             "NPTH_IN_COURTYARD", "DISABLED_LAYER_ITEM", "INVALID_OUTLINE", "MISSING_FOOTPRINT", "DUPLICATE_FOOTPRINT",
             "EXTRA_FOOTPRINT", "NET_CONFLICT", "SCHEMATIC_PARITY", "FOOTPRINT_FILTERS", "FOOTPRINT_TYPE_MISMATCH",
             "LIB_FOOTPRINT_ISSUES", "LIB_FOOTPRINT_MISMATCH", "PAD_TH_WITH_NO_HOLE", "FOOTPRINT",
             "UNRESOLVED_VARIABLE", "ASSERTION_FAILURE", "GENERIC_WARNING", "GENERIC_ERROR", "COPPER_SLIVER",
             "SOLDERMASK_BRIDGE", "SILK_MASK_CLEARANCE"]
CODE = {name: i + 1 for i, name in enumerate(DRC_CODES)}
KEYS = {"SHORTING_ITEMS": "shorting_items", "DRILLED_HOLES_TOO_CLOSE": "hole_to_hole",
        "DRILLED_HOLES_COLOCATED": "holes_co_located", "PADSTACK": "padstack", "PADSTACK_INVALID": "padstack_invalid",
        "MISSING_COURTYARD": "missing_courtyard", "MALFORMED_COURTYARD": "malformed_courtyard",
        "FOOTPRINT_TYPE_MISMATCH": "footprint_type_mismatch", "PAD_TH_WITH_NO_HOLE": "through_hole_pad_without_hole",
        "FOOTPRINT": "footprint", "SILK_MASK_CLEARANCE": "silk_over_copper"}
KEY_OF_CODE = {CODE[k]: v for k, v in KEYS.items()}
# (SEVERITY, include/widgets/report_severity.h)
SEVERITY = {0x10: "warning", 0x20: "error", 0x40: "ignore"}

_IO = pcbnew.PCB_IO_KICAD_SEXPR()


def iu(v):
    return int(round(v * MM))


# MARK: - KiCad's checks through callbacks

class _TypeInfo(ctypes.Structure):
    """SWIG's swig_type_info, whose name is all its type checks compare"""
    _fields_ = [("name", ctypes.c_char_p), ("str", ctypes.c_char_p), ("dcast", ctypes.c_void_p),
                ("cast", ctypes.c_void_p), ("clientdata", ctypes.c_void_p), ("owndata", ctypes.c_int)]


class _SwigObject(ctypes.Structure):
    """SWIG's SwigPyObject: a pointer and its type"""
    _fields_ = [("refcnt", ctypes.c_ssize_t), ("type", ctypes.c_void_p), ("ptr", ctypes.c_void_p),
                ("ty", ctypes.POINTER(_TypeInfo)), ("own", ctypes.c_int), ("next", ctypes.c_void_p)]


PAIR_CB = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int)
SILK_CB = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int, ctypes.c_int)
TRIPLE_CB = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int, ctypes.c_int)
PAD_MSG_CB = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p)
MSG_CB = ctypes.CFUNCTYPE(None, ctypes.c_char_p)
OUTLINE_CB = ctypes.CFUNCTYPE(None, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int, ctypes.c_int)


class Callbacks:
    """callbacks.cpp built and loaded, and its std::functions handed to KiCad as SWIG pointers of the types KiCad's
    wrappers ask for"""

    def __init__(self):
        self.tmp = tempfile.mkdtemp()
        so = os.path.join(self.tmp, "callbacks.so")
        subprocess.run(["g++", "-std=c++17", "-shared", "-fPIC", "-O1", "-Wno-deprecated-declarations",
                        os.path.join(HERE, "callbacks.cpp"), "-o", so], check=True)
        self.lib = ctypes.CDLL(so)
        for name, cb in (("make_pair_fn", PAIR_CB), ("make_silk_fn", SILK_CB), ("make_triple_fn", TRIPLE_CB),
                         ("make_pad_msg_fn", PAD_MSG_CB), ("make_msg_fn", MSG_CB), ("make_outline_fn", OUTLINE_CB)):
            f = getattr(self.lib, name)
            f.restype = ctypes.c_void_p
            f.argtypes = [cb]
        self.keep = []

    def pointer(self, ptr, type_name):
        """A SWIG object holding `ptr` as of the SWIG type `type_name` (a VECTOR2I's object, its pointer and type
        changed, its own let go)"""
        holder = pcbnew.VECTOR2I(0, 0)
        obj = holder.this
        holder.thisown = False
        info = _TypeInfo(type_name.encode(), type_name.encode(), None, None, None, 0)
        self.keep += [holder, info]
        s = _SwigObject.from_address(id(obj))
        s.ptr, s.ty, s.own = ptr, ctypes.pointer(info), 0
        return obj

    def function(self, maker, cbtype, type_name, py):
        cb = cbtype(py)
        self.keep.append(cb)
        return self.pointer(getattr(self.lib, maker)(cb), type_name)


def run_checks(cb, fp):
    """DIALOG_FOOTPRINT_CHECKER::runChecks of `fp` (on a board of its own): its markers in the order the checker adds
    them, each {type, code, severity, detail, items, at}"""
    board = fp.GetBoard()
    severities = board.GetDesignSettings()
    items = {}

    def remember(item):
        items[int(item.this)] = item.m_Uuid.AsString()

    # (the footprint's own id is new each time KiCad loads one of a library: "footprint")
    items[int(fp.this)] = "footprint"
    for p in fp.Pads():
        remember(p)
    for d in fp.GraphicalItems():
        remember(d)
    for z in fp.Zones():
        remember(z)
    for f in fp.GetFields():
        remember(f)
    markers = []

    def severity(code):
        # (a SEVERITY, which the module hands back as a pointer to it)
        value = ctypes.c_int.from_address(int(severities.GetSeverity(code))).value
        return SEVERITY.get(value, str(value))

    def marker(a, b, c, code, msg, x, y):
        markers.append({"code": code, "type": KEY_OF_CODE.get(code, str(code)), "severity": severity(code),
                        "detail": msg, "items": [items.get(p, "?") for p in (a, b, c) if p],
                        "at": [x, y]})

    # (BuildCourtyardCaches' OUTLINE_ERROR_HANDLER: a single item made item A)
    def outline(msg, a, b, x, y):
        if not a:
            a, b = b, a
        marker(a, b, None, CODE["MALFORMED_COURTYARD"], msg.decode(), x, y)

    handler = cb.function("make_outline_fn", OUTLINE_CB, "_p_OUTLINE_ERROR_HANDLER", outline)
    fp.BuildCourtyardCaches(handler)
    if not fp.AllowMissingCourtyard() and fp.GetCourtyard(pcbnew.F_CrtYd).OutlineCount() == 0 \
            and fp.GetCourtyard(pcbnew.B_CrtYd).OutlineCount() == 0:
        marker(int(fp.this), None, None, CODE["MISSING_COURTYARD"], "", 0, 0)
    fp.CheckFootprintAttributes(cb.function(
        "make_msg_fn", MSG_CB, "_p_std__functionT_void_fwxString_const_RF_t",
        lambda msg: marker(int(fp.this), None, None, CODE["FOOTPRINT_TYPE_MISMATCH"], msg.decode(), 0, 0)))
    pads = {int(p.this): p for p in fp.Pads()}
    units = pcbnew.UNITS_PROVIDER(pcbnew.pcbIUScale, pcbnew.EDA_UNITS_MM)
    fp.CheckPads(units, cb.function(
        "make_pad_msg_fn", PAD_MSG_CB, "_p_std__functionT_void_fPAD_const_p_int_wxString_const_RF_t",
        lambda pad, code, msg: marker(pad, None, None, code, msg.decode(), pads[pad].GetPosition().x,
                                      pads[pad].GetPosition().y)))
    fp.CheckShortingPads(cb.function(
        "make_pair_fn", PAIR_CB, "_p_std__functionT_void_fPAD_const_p_PAD_const_p_int_VECTOR2T_int_t_const_RF_t",
        lambda a, b, code, x, y: marker(a, b, None, code, "", x, y)))
    if fp.IsNetTie():
        fp.CheckNetTiePadGroups(cb.function(
            "make_msg_fn", MSG_CB, "_p_std__functionT_void_fwxString_const_RF_t",
            lambda msg: marker(int(fp.this), None, None, CODE["FOOTPRINT"], msg.decode(), 0, 0)))
        fp.CheckNetTies(cb.function(
            "make_triple_fn", TRIPLE_CB,
            "_p_std__functionT_void_fBOARD_ITEM_const_p_BOARD_ITEM_const_p_BOARD_ITEM_const_p_VECTOR2T_int_t_const_RF_t",
            lambda a, b, c, x, y: marker(a, b, c, CODE["SHORTING_ITEMS"], "", x, y)))
    fp.CheckClippedSilk(cb.function(
        "make_silk_fn", SILK_CB, "_p_std__functionT_void_fBOARD_ITEM_p_BOARD_ITEM_p_VECTOR2T_int_t_const_RF_t",
        lambda a, b, x, y: marker(a, b, None, CODE["SILK_MASK_CLEARANCE"], "", x, y)))
    return markers


def unflashed_pair(fp):
    """A pair of pads CheckShortingPads asks the shapes of on F.Cu (ALL_LAYERS, both padstacks normal) where one is a
    plated pad not flashed there: its GetEffectiveShape makes a compound of its hole that the shared pointer it is
    handed back in, a temporary, frees before CheckShortingPads asks it what it collides with (it keeps only .get()),
    so that KiCad reads freed memory (and now and then crashes): the pair's pad numbers, None if there is none"""
    pads = list(fp.Pads())
    def copper(p):
        return {l for l in p.GetLayerSet().Seq() if pcbnew.IsCopperLayer(l)}

    for i, a in enumerate(pads):
        ties = [int(p.this) for p in fp.GetNetTiePads(a)]
        for b in pads[i + 1:]:
            if a.SameLogicalPadAs(b) or int(b.this) in ties:
                continue
            if not copper(a) & copper(b):
                continue
            if not a.GetBoundingBox().Intersects(b.GetBoundingBox()):
                continue
            for p in (a, b):
                if p.GetAttribute() == pcbnew.PAD_ATTRIB_PTH and not p.FlashLayer(pcbnew.F_Cu):
                    return [a.GetNumber(), b.GetNumber()]
    return None


# MARK: - Footprints to check

def u():
    return str(uuidlib.uuid4())


def num(v):
    s = f"{v:.6f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def xy(p):
    return f"{num(p[0])} {num(p[1])}"


def at(p, angle=0):
    return f"(at {xy(p)}{' ' + num(angle) if angle else ''})"


def quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def pad_text(n):
    """A pad as KiCad's file holds one, from a dict: number, attribute, shape, at, angle, size, layers, drill, offset,
    and shape's and margins' extras"""
    parts = [f"(pad {quote(n['number'])} {n['attr']} {n['shape']}", at(n["at"], n.get("angle", 0)),
             f"(size {xy(n['size'])})"]
    if "drill" in n:
        d = n["drill"]
        off = f" (offset {xy(n['offset'])})" if "offset" in n else ""
        if d[0] == d[1] and not n.get("oval"):
            parts.append(f"(drill {num(d[0])}{off})")
        else:
            parts.append(f"(drill oval {num(d[0])} {num(d[1])}{off})")
    elif "offset" in n:
        parts.append(f"(drill 0 (offset {xy(n['offset'])}))")
    if n.get("property"):
        parts.append(f"(property {n['property']})")
    parts.append("(layers " + " ".join(quote(l) for l in n["layers"]) + ")")
    if n.get("remove_unused"):
        parts.append("(remove_unused_layers yes)")
        if n.get("keep_end"):
            parts.append("(keep_end_layers yes)")
    if "rratio" in n:
        parts.append(f"(roundrect_rratio {num(n['rratio'])})")
    if "delta" in n:
        parts.append(f"(rect_delta {xy(n['delta'])})")
    if "chamfer" in n:
        parts.append(f"(chamfer_ratio {num(n['chamfer_ratio'])})")
        parts.append("(chamfer " + " ".join(n["chamfer"]) + ")")
    for k in ("solder_mask_margin", "solder_paste_margin", "clearance"):
        if k in n:
            parts.append(f"({k} {num(n[k])})")
    if n["shape"] == "custom":
        parts.append(f"(options (clearance outline) (anchor {n.get('anchor', 'rect')}))")
        parts.append("(primitives " + " ".join(n["primitives"]) + ")")
    parts.append(f"(uuid {quote(u())}))")
    return " ".join(parts)


def line(a, b, layer, width=0.12):
    return f"(fp_line (start {xy(a)}) (end {xy(b)}) (stroke (width {num(width)}) (type solid)) (layer {quote(layer)}) (uuid {quote(u())}))"


def rect(a, b, layer, width=0.05, fill=False):
    return (f"(fp_rect (start {xy(a)}) (end {xy(b)}) (stroke (width {num(width)}) (type solid)) "
            f"(fill {'yes' if fill else 'no'}) (layer {quote(layer)}) (uuid {quote(u())}))")


def circle(c, r, layer, width=0.12, fill=False):
    return (f"(fp_circle (center {xy(c)}) (end {xy((c[0] + r, c[1]))}) (stroke (width {num(width)}) (type solid)) "
            f"(fill {'yes' if fill else 'no'}) (layer {quote(layer)}) (uuid {quote(u())}))")


def arc(s, m, e, layer, width=0.12):
    return f"(fp_arc (start {xy(s)}) (mid {xy(m)}) (end {xy(e)}) (stroke (width {num(width)}) (type solid)) (layer {quote(layer)}) (uuid {quote(u())}))"


def poly(pts, layer, width=0.1, fill=True):
    return (f"(fp_poly (pts {' '.join('(xy ' + xy(p) + ')' for p in pts)}) (stroke (width {num(width)}) (type solid)) "
            f"(fill {'yes' if fill else 'no'}) (layer {quote(layer)}) (uuid {quote(u())}))")


def text(s, p, layer, size=1.0, angle=0, hide=False):
    return (f"(fp_text user {quote(s)} {at(p, angle)} (layer {quote(layer)}){' (hide yes)' if hide else ''} (uuid {quote(u())}) "
            f"(effects (font (size {num(size)} {num(size)}) (thickness {num(size * 0.15)}))))")


def footprint_text(name, items, attr="smd", courtyard=True, net_ties=None, allow_missing=False):
    attrs = [a for a in [attr, "allow_missing_courtyard" if allow_missing else None] if a]
    parts = [f"(footprint {quote(name)} (version 20260206) (generator \"pcbnew\") (generator_version \"10.0\") (layer \"F.Cu\")",
             f"(property \"Reference\" \"REF**\" (at 0 -4 0) (layer \"F.SilkS\") (uuid {quote(u())}) (effects (font (size 1 1) (thickness 0.15))))",
             f"(property \"Value\" {quote(name)} (at 0 4 0) (layer \"F.Fab\") (uuid {quote(u())}) (effects (font (size 1 1) (thickness 0.15))))"]
    if attrs:
        parts.append("(attr " + " ".join(attrs) + ")")
    if net_ties:
        parts.append("(net_tie_pad_groups " + " ".join(quote(g) for g in net_ties) + ")")
    if courtyard:
        parts.append(rect((-6, -6), (6, 6), "F.CrtYd"))
    parts += items
    parts.append("(embedded_fonts no))")
    return "\n".join(parts) + "\n"


def smd(number, p, size, shape="rect", layers=("F.Cu", "F.Mask", "F.Paste"), **kw):
    return pad_text(dict(number=number, attr="smd", shape=shape, at=p, size=size, layers=list(layers), **kw))


def tht(number, p, size, drill, shape="circle", layers=("*.Cu", "*.Mask"), **kw):
    return pad_text(dict(number=number, attr="thru_hole", shape=shape, at=p, size=size, drill=drill, layers=list(layers), **kw))


def npth(number, p, size, drill, shape="circle", layers=("*.Cu", "*.Mask"), **kw):
    return pad_text(dict(number=number, attr="np_thru_hole", shape=shape, at=p, size=size, drill=drill, layers=list(layers), **kw))


def custom_prims(rng):
    out = []
    for _ in range(rng.randint(1, 3)):
        k = rng.choice(["poly", "circle", "rect", "line", "arc"])
        c = (round(rng.uniform(-0.6, 0.6), 2), round(rng.uniform(-0.6, 0.6), 2))
        if k == "poly":
            n = rng.randint(3, 6)
            r = rng.uniform(0.2, 0.8)
            pts = [(round(c[0] + r * math.cos(2 * math.pi * i / n + 0.3), 3), round(c[1] + r * math.sin(2 * math.pi * i / n + 0.3), 3))
                   for i in range(n)]
            out.append(f"(gr_poly (pts {' '.join('(xy ' + xy(p) + ')' for p in pts)}) (width {num(rng.choice([0, 0.1]))}) (fill yes))")
        elif k == "circle":
            out.append(f"(gr_circle (center {xy(c)}) (end {xy((c[0] + round(rng.uniform(0.1, 0.6), 2), c[1]))}) (width {num(rng.choice([0, 0.1]))}) (fill yes))")
        elif k == "rect":
            d = (round(rng.uniform(0.1, 0.7), 2), round(rng.uniform(0.1, 0.7), 2))
            out.append(f"(gr_rect (start {xy(c)}) (end {xy((c[0] + d[0], c[1] + d[1]))}) (width {num(rng.choice([0, 0.1]))}) (fill yes))")
        elif k == "line":
            e = (round(c[0] + rng.uniform(-0.8, 0.8), 2), round(c[1] + rng.uniform(-0.8, 0.8), 2))
            out.append(f"(gr_line (start {xy(c)}) (end {xy(e)}) (width {num(rng.choice([0.1, 0.25]))}))")
        else:
            r = rng.uniform(0.3, 0.7)
            a0 = rng.uniform(0, 6)
            pts = [(round(c[0] + r * math.cos(a0 + t), 3), round(c[1] + r * math.sin(a0 + t), 3)) for t in (0, 0.8, 1.6)]
            out.append(f"(gr_arc (start {xy(pts[0])}) (mid {xy(pts[1])}) (end {xy(pts[2])}) (width 0.15))")
    return out


def random_pad(rng, number, p):
    attr = rng.choices(["smd", "thru_hole", "np_thru_hole", "connect"], [45, 35, 12, 8])[0]
    shape = rng.choices(["circle", "rect", "oval", "roundrect", "trapezoid", "chamfered", "custom"], [18, 22, 16, 14, 8, 8, 14])[0]
    size = (round(rng.uniform(0.3, 2.0), 2), round(rng.uniform(0.3, 2.0), 2))
    if shape == "circle":
        size = (size[0], size[0])
    n = dict(number=number, attr=attr, at=p, size=size, angle=rng.choice([0, 0, 0, 90, 45, 30, 180, 270, 15.5]))
    if shape == "chamfered":
        n.update(shape="roundrect", rratio=rng.choice([0, 0.1, 0.25]), chamfer_ratio=rng.choice([0.1, 0.2, 0.3]),
                 chamfer=rng.sample(["top_left", "top_right", "bottom_left", "bottom_right"], rng.randint(1, 4)))
    elif shape == "roundrect":
        n.update(shape="roundrect", rratio=rng.choice([0.05, 0.15, 0.25, 0.5]))
    elif shape == "trapezoid":
        n.update(shape="trapezoid", delta=rng.choice([(0, round(size[0] * 0.3, 2)), (round(size[1] * 0.3, 2), 0)]))
    elif shape == "custom":
        n.update(shape="custom", anchor=rng.choice(["rect", "circle"]), size=(round(size[0] / 2, 2), round(size[0] / 2, 2)),
                 primitives=custom_prims(rng))
    else:
        n["shape"] = shape
    if attr in ("thru_hole", "np_thru_hole"):
        d = round(rng.uniform(0.2, min(size) * 1.1), 2)
        if rng.random() < 0.25:
            n["drill"] = (d, round(d * rng.choice([1, 1.5, 2]), 2))
            n["oval"] = True
        else:
            n["drill"] = (d, d)
        if rng.random() < 0.15:
            n["offset"] = (round(rng.uniform(-0.3, 0.3), 2), round(rng.uniform(-0.3, 0.3), 2))
        n["layers"] = rng.choices([["*.Cu", "*.Mask"], ["F.Cu", "F.Mask"], ["B.Cu", "B.Mask"],
                                   ["F.Cu", "B.Cu", "F.Mask", "B.Mask"], ["F.Cu", "In1.Cu", "B.Cu"], ["In2.Cu", "In1.Cu"],
                                   ["*.Mask"]], [50, 10, 3, 12, 8, 2, 8])[0]
        if attr == "thru_hole" and rng.random() < 0.1:
            n.update(remove_unused=True, keep_end=True)
    else:
        n["layers"] = rng.choice([["F.Cu", "F.Mask", "F.Paste"], ["F.Cu", "F.Mask", "F.Paste"], ["B.Cu", "B.Mask", "B.Paste"],
                                  ["F.Cu", "F.Mask"], ["In1.Cu"], ["In2.Cu"], ["F.Cu", "B.Cu"], ["F.Paste"], ["F.Cu", "B.Mask"]])
    if rng.random() < 0.05:
        n["property"] = rng.choice(["pad_prop_heatsink", "pad_prop_fiducial_loc", "pad_prop_testpoint", "pad_prop_castellated"])
    return pad_text(n)


def random_footprint(rng, name):
    items = []
    count = rng.randint(2, 9)
    numbers = rng.choice([[str(i + 1) for i in range(count)], ["1", "2", "1", "3", "2", "", "A1", "MP", "MP"]])
    spread = rng.choice([0.8, 1.5, 3.0])
    grid = rng.choice([0.05, 0.25, 0.5])
    for i in range(count):
        p = (round(rng.uniform(-spread, spread) / grid) * grid, round(rng.uniform(-spread, spread) / grid) * grid)
        items.append(random_pad(rng, numbers[i % len(numbers)], p))
    for _ in range(rng.randint(0, 5)):
        layer = rng.choice(["F.SilkS", "F.SilkS", "B.SilkS", "F.Mask", "B.Mask", "F.Fab", "F.Cu", "B.Cu"])
        a = (round(rng.uniform(-3, 3), 2), round(rng.uniform(-3, 3), 2))
        b = (round(rng.uniform(-3, 3), 2), round(rng.uniform(-3, 3), 2))
        k = rng.choice(["line", "rect", "circle", "arc", "poly", "text"])
        if k == "line":
            items.append(line(a, b, layer, rng.choice([0.1, 0.12, 0.2])))
        elif k == "rect":
            items.append(rect(a, b, layer, rng.choice([0.1, 0.12]), fill=rng.random() < 0.3))
        elif k == "circle":
            items.append(circle(a, round(rng.uniform(0.2, 1.5), 2), layer, 0.12, fill=rng.random() < 0.3))
        elif k == "arc":
            m = ((a[0] + b[0]) / 2 + 0.4, (a[1] + b[1]) / 2 - 0.3)
            items.append(arc(a, (round(m[0], 2), round(m[1], 2)), b, layer))
        elif k == "poly":
            items.append(poly([a, b, (round(a[0] + 0.7, 2), round(b[1] - 0.4, 2))], layer, fill=rng.random() < 0.6))
        elif layer.endswith(".Cu"):
            # (no text on copper: the port leaves a net tie's texts on copper unmade)
            items.append(line(a, b, layer, 0.2))
        else:
            items.append(text(rng.choice(["X", "ab", "1", "${REFERENCE}"]), a, layer, rng.choice([0.5, 1.0]), rng.choice([0, 90])))
    groups = None
    if rng.random() < 0.25:
        groups = rng.choice([["1, 2"], ["1,2,3"], ["2, 3", "1"], ["1, 9"], ["1, 2", "2, 3"]])
    courtyard = rng.random() < 0.8
    attr = rng.choice(["smd", "through_hole", None])
    text_ = footprint_text(name, items, attr=attr, courtyard=courtyard, net_ties=groups, allow_missing=rng.random() < 0.1)
    if not courtyard and rng.random() < 0.6:
        # (an open courtyard: lines, an arc, lines crossing)
        layer = rng.choice(["F.CrtYd", "B.CrtYd"])
        open_ = rng.choice([
            [line((-5, -5), (5, -5), layer, 0.05), line((5, -5), (5, 5), layer, 0.05)],
            [arc((-4, 0), (0, -4), (4, 0), layer, 0.05), line((4, 0), (0, 4.5), layer, 0.05)],
            [arc((-4, 0), (0, round(rng.uniform(-4.5, -3), 2)), (4, 0), layer, 0.05), arc((-4.1, 0.1), (0, 3), (3.9, 0.2), layer, 0.05)],
            [line((-4, -4), (4, 4), layer, 0.05), line((4, -4), (-4, 4), layer, 0.05), line((-4, 4.03), (-4, -4), layer, 0.05)],
            [line((-3, -3), (3, -3), layer, 0.12)],
        ])
        text_ = text_.replace("(embedded_fonts no))", "\n".join(open_) + "\n(embedded_fonts no))")
    return text_


def hand_made():
    """Footprints made to reach CheckShortingPads' and CheckClippedSilk's corners: (name, text)"""
    cases = []

    def case(name, items, **kw):
        cases.append((name, footprint_text(name, items, **kw)))

    case("short-two-numbers", [smd("1", (0, 0), (1, 1)), smd("2", (0.5, 0), (1, 1))])
    case("short-same-number", [smd("1", (0, 0), (1, 1)), smd("1", (0.5, 0), (1, 1))])
    case("short-no-numbers", [smd("", (0, 0), (1, 1)), smd("", (0.5, 0), (1, 1))])
    case("short-touching-edges", [smd("1", (0, 0), (1, 1)), smd("2", (1, 0), (1, 1))])
    case("short-touching-corners", [smd("1", (0, 0), (1, 1)), smd("2", (1, 1), (1, 1))])
    case("short-apart", [smd("1", (0, 0), (1, 1)), smd("2", (1.001, 0), (1, 1))])
    case("short-boxes-meet-shapes-not", [smd("1", (0, 0), (1, 1), shape="circle"), smd("2", (0.95, 0.95), (1, 1), shape="circle")])
    case("short-other-sides", [smd("1", (0, 0), (1, 1)), smd("2", (0.5, 0), (1, 1), layers=("B.Cu", "B.Mask", "B.Paste"))])
    case("short-back", [smd("1", (0, 0), (1, 1), layers=("B.Cu", "B.Mask")), smd("2", (0.5, 0), (1, 1), layers=("B.Cu", "B.Mask"))])
    case("short-inner", [smd("1", (0, 0), (1, 1), layers=("In2.Cu",)), tht("2", (0.8, 0), (1, 1), (0.5, 0.5))])
    case("short-inner-apart", [smd("1", (0, 0), (1, 1), layers=("In2.Cu",)), smd("2", (0.5, 0), (1, 1), layers=("In3.Cu",))])
    case("short-paste-only", [smd("1", (0, 0), (1, 1), layers=("F.Paste",)), smd("2", (0.5, 0), (1, 1))])
    case("short-net-tie", [smd("1", (0, 0), (1, 1)), smd("2", (0.5, 0), (1, 1)), smd("3", (-0.5, 0), (1, 1))], net_ties=["1, 2"])
    case("short-net-tie-escaped", [smd("1,2", (0, 0), (1, 1)), smd("3", (0.5, 0), (1, 1))], net_ties=["1\\,2, 3"])
    case("short-three", [smd("1", (0, 0), (1, 1)), smd("2", (0.5, 0), (1, 1)), smd("3", (0.25, 0.4), (1, 1))])
    case("holes-co-located", [tht("1", (0, 0), (1.5, 1.5), (0.8, 0.8)), tht("2", (0, 0), (1.5, 1.5), (0.8, 0.8))], attr="through_hole")
    case("holes-co-located-same-number", [tht("1", (0, 0), (1.5, 1.5), (0.8, 0.8)), tht("1", (0, 0), (1.2, 1.2), (0.6, 0.6))], attr="through_hole")
    case("holes-touching", [tht("1", (0, 0), (1.2, 1.2), (0.8, 0.8)), tht("2", (0.9, 0), (1.2, 1.2), (0.8, 0.8))], attr="through_hole")
    case("holes-near", [tht("1", (0, 0), (1.2, 1.2), (0.8, 0.8)), tht("2", (0.4, 0), (1.2, 1.2), (0.8, 0.8))], attr="through_hole")
    case("holes-near-wide", [tht("1", (0, 0), (1.2, 1.2), (1.0, 1.0)), tht("2", (0.5, 0), (1.2, 1.2), (0.2, 0.2))], attr="through_hole")
    case("holes-oval", [tht("1", (0, 0), (2, 1.2), (1.6, 0.8), shape="oval", oval=True), tht("2", (0.9, 0), (1.2, 1.2), (0.6, 0.6))], attr="through_hole")
    case("holes-oval-square", [tht("1", (0, 0), (1.2, 1.2), (0.8, 0.8), oval=True), tht("2", (0, 0), (1.2, 1.2), (0.8, 0.8))], attr="through_hole")
    case("holes-npth", [npth("", (0, 0), (1, 1), (1, 1)), npth("", (0.5, 0), (1, 1), (1, 1)), tht("1", (0, 0), (2, 2), (1, 1))], attr="through_hole")
    case("holes-offset", [tht("1", (0, 0), (2, 2), (0.6, 0.6), offset=(0.5, 0)), tht("2", (1.2, 0), (1, 1), (0.6, 0.6))], attr="through_hole")
    case("pth-front-only", [tht("1", (0, 0), (2, 2), (0.6, 0.6), layers=("F.Cu", "F.Mask")), tht("2", (1.2, 0), (2, 2), (0.6, 0.6), layers=("F.Cu", "F.Mask"))], attr="through_hole")
    # (a plated pad not on F.Cu against another whose box meets its: undefined in KiCad, see unflashed_pair; one of
    # the same number, its hole checked alone, and one apart)
    case("pth-back-same-number", [tht("1", (0, 0), (2, 2), (0.8, 0.8), layers=("B.Cu", "B.Mask")), tht("1", (0.7, 0), (2, 2), (0.8, 0.8), layers=("B.Cu", "B.Mask"))], attr="through_hole")
    case("pth-back-apart", [tht("1", (0, 0), (1, 1), (0.6, 0.6), layers=("B.Cu", "B.Mask")), tht("2", (1.2, 0), (1, 1), (0.6, 0.6), layers=("B.Cu", "B.Mask"))], attr="through_hole")
    case("pth-keep-ends", [pad_text(dict(number="1", attr="thru_hole", shape="circle", at=(0, 0), size=(2, 2), drill=(0.6, 0.6),
                                         layers=["*.Cu", "*.Mask"], remove_unused=True, keep_end=True)),
                           smd("2", (1.2, 0), (2, 2))], attr="through_hole")
    case("npth-copper", [npth("", (0, 0), (2, 2), (1, 1)), smd("2", (1.2, 0), (1, 1))])
    case("npth-no-ring", [npth("", (0, 0), (1, 1), (1, 1)), smd("2", (0.8, 0), (1, 1))])
    case("npth-oval-no-ring", [npth("", (0, 0), (2, 1), (2, 1), shape="oval", oval=True), smd("2", (1.3, 0), (1, 1))])
    case("net-tie-bridge", [smd("1", (-1, 0), (0.6, 0.6)), smd("2", (1, 0), (0.6, 0.6)), smd("3", (0, 1), (0.6, 0.6)),
                            line((-1, 0), (1, 0), "F.Cu", 0.2), line((0, 0), (0, 1), "F.Cu", 0.2)], net_ties=["1, 2"])
    case("net-tie-bridge-ok", [smd("1", (-1, 0), (0.6, 0.6)), smd("2", (1, 0), (0.6, 0.6)),
                               poly([(-1, -0.1), (1, -0.1), (1, 0.1), (-1, 0.1)], "F.Cu", 0, True)], net_ties=["1, 2"])
    case("net-tie-no-drawing", [smd("1", (-1, 0), (1.4, 0.6)), smd("2", (0.3, 0), (1.4, 0.6)),
                                line((-1, 0), (-0.8, 0), "F.Cu", 0.2)], net_ties=["1, 3"])
    case("net-tie-back", [smd("1", (-1, 0), (0.6, 0.6), layers=("B.Cu", "B.Mask")), smd("2", (1, 0), (0.6, 0.6), layers=("B.Cu", "B.Mask")),
                          arc((-1, 0), (0, -0.6), (1, 0), "B.Cu", 0.2)], net_ties=["2, 3"])
    case("courtyard-arcs-open", [smd("1", (0, 0), (1, 1)), arc((-3, 0), (0, -3), (3, 0), "F.CrtYd", 0.05),
                                 arc((-3, 0.1), (0, 3), (2.9, 0.3), "F.CrtYd", 0.05)], courtyard=False)
    # (the first's crossing segments' ends as far from the origin as each other: KiCad's map of the segments' owners,
    # comparing points by their lengths, finds the polygon for both; the second's for one)
    case("courtyard-crossing", [smd("1", (0, 0), (1, 1)), poly([(-3, -3), (3, 3), (3, -3), (-3, 3)], "F.CrtYd", 0.05, False)],
         courtyard=False)
    case("courtyard-crossing-one-owner", [smd("1", (0, 0), (1, 1)), poly([(0, 0), (4, 0), (4, 4), (2, -2)], "F.CrtYd", 0.05, False)],
         courtyard=False)
    case("courtyard-lone-line", [smd("1", (0, 0), (1, 1)), line((-3, -3), (3, -3), "B.CrtYd", 0.05)], courtyard=False)
    case("npth-numbered", [npth("1", (0, 0), (2, 2), (1, 1)), smd("1", (1.2, 0), (1, 1))])
    case("aperture-numbered", [smd("1", (0, 0), (1, 1), layers=("F.Paste", "F.Mask")), smd("1", (0.5, 0), (1, 1)),
                               smd("2", (-0.5, 0), (1, 1), layers=("F.Paste",))], net_ties=["2, 1"])
    case("aperture", [smd("", (0, 0), (1, 1), layers=("F.Paste", "F.Mask")), smd("2", (0.5, 0), (1, 1))])
    case("shapes-circle-oval", [smd("1", (0, 0), (1, 1), shape="circle"), smd("2", (1.2, 0), (2, 0.6), shape="oval", angle=30)])
    case("shapes-roundrect", [smd("1", (0, 0), (1, 1), shape="roundrect", rratio=0.5), smd("2", (0.99, 0.99), (1, 1), shape="roundrect", rratio=0.5)])
    case("shapes-roundrect-corners", [smd("1", (0, 0), (1, 1), shape="roundrect", rratio=0.25), smd("2", (0.95, 0.95), (1, 1), shape="roundrect", rratio=0.25)])
    case("shapes-chamfered", [smd("1", (0, 0), (1, 1), shape="roundrect", rratio=0, chamfer_ratio=0.3, chamfer=["bottom_right"]),
                              smd("2", (0.9, 0.9), (1, 1), shape="roundrect", rratio=0, chamfer_ratio=0.3, chamfer=["top_left"])])
    case("shapes-trapezoid", [smd("1", (0, 0), (1, 1), shape="trapezoid", delta=(0, 0.4)), smd("2", (0.95, 0), (1, 1))])
    case("shapes-turned", [smd("1", (0, 0), (2, 0.5), angle=45), smd("2", (1, 0), (2, 0.5), angle=-45)])
    case("custom-pads", [pad_text(dict(number="1", attr="smd", shape="custom", at=(0, 0), size=(0.5, 0.5), layers=["F.Cu", "F.Mask"],
                                       primitives=["(gr_poly (pts (xy 0 0) (xy 1.5 0) (xy 1.5 0.2) (xy 0 0.2)) (width 0) (fill yes))"])),
                         smd("2", (1.4, 0), (0.4, 0.4), shape="circle")])
    case("custom-pads-apart", [pad_text(dict(number="1", attr="smd", shape="custom", at=(0, 0), size=(0.5, 0.5), layers=["F.Cu", "F.Mask"],
                                             primitives=["(gr_circle (center 1 1) (end 1.2 1) (width 0) (fill yes))"])),
                               smd("2", (1.0, -0.6), (0.4, 0.4), shape="circle")])
    case("custom-line", [pad_text(dict(number="1", attr="smd", shape="custom", at=(0, 0), size=(0.3, 0.3), layers=["F.Cu", "F.Mask"],
                                       primitives=["(gr_line (start 0 0) (end 2 0) (width 0.2))"])),
                         smd("2", (2.2, 0), (0.2, 0.2))])
    case("silk-over-pad", [smd("1", (0, 0), (1, 1)), line((-1, 0), (1, 0), "F.SilkS")])
    case("silk-near-pad", [smd("1", (0, 0), (1, 1)), line((-1, 0.62), (1, 0.62), "F.SilkS")])
    case("silk-touching-pad", [smd("1", (0, 0), (1, 1)), line((-1, 0.56), (1, 0.56), "F.SilkS")])
    case("silk-back-over-pad", [smd("1", (0, 0), (1, 1), layers=("B.Cu", "B.Mask")), line((-1, 0), (1, 0), "B.SilkS"),
                                line((-1, 0.2), (1, 0.2), "F.SilkS")])
    case("silk-over-pth", [tht("1", (0, 0), (1.5, 1.5), (0.8, 0.8)), circle((0, 0), 0.7, "F.SilkS"), circle((0, 0), 0.7, "B.SilkS")], attr="through_hole")
    case("silk-over-mask-drawing", [rect((-1, -1), (1, 1), "F.Mask", 0.1, fill=True), line((-2, 0), (2, 0), "F.SilkS"),
                                    circle((3, 3), 0.5, "F.SilkS")])
    case("silk-text-over-pad", [smd("1", (0, 0), (2, 1)), text("XY", (0, 0), "F.SilkS"), text("Z", (0, 3), "F.SilkS")])
    case("silk-field-over-pad", [smd("1", (0, 0), (2, 1)), f"(property \"Field\" \"XY\" (at 0 0 0) (layer \"F.SilkS\") (uuid {quote(u())}) (effects (font (size 1 1) (thickness 0.15))))"])
    case("silk-over-npth", [npth("", (0, 0), (1, 1), (1, 1), layers=("*.Mask",)), line((-1, 0), (1, 0), "F.SilkS")])
    case("silk-over-paste-pad", [smd("1", (0, 0), (1, 1), layers=("F.Cu", "F.Paste")), line((-1, 0), (1, 0), "F.SilkS")])
    case("silk-filled-shapes", [smd("1", (0, 0), (1, 1)), rect((0.4, 0.4), (1.5, 1.5), "F.SilkS", 0.1, fill=True),
                                circle((-1, -1), 0.6, "F.SilkS", 0.1, fill=True), poly([(1, -1), (2, -1), (1.5, -0.4)], "F.SilkS")])
    return cases


def stock_sample(rng, count):
    files = list(footprints.stock_files())
    chosen = sorted(rng.sample(files, count))
    return [(lib, f[:-10]) for lib, f in chosen if "(dimension" not in open(os.path.join(STOCK, lib, f)).read()]


def checks(outdir, count=150, seed=20261128):
    rng = random.Random(seed)
    lib = os.path.join(outdir, "checks.pretty")
    os.makedirs(lib, exist_ok=True)
    names = []
    # (footprints.py's faulty footprints of KiCad's libraries, at 0, 0 as the editor has them)
    for n, (src, name, what) in enumerate(footprints.CHECK_CASES):
        fp = _IO.FootprintLoad(os.path.join(STOCK, src), name, True)
        footprints.fault(fp, what)
        fp.SetFPID(pcbnew.LIB_ID("", f"fault-{n}-{what}"))
        _IO.FootprintSave(lib, fp)
        names.append(f"fault-{n}-{what}")
    for name, t in hand_made():
        with open(os.path.join(lib, name + ".kicad_mod"), "w") as f:
            f.write(t)
        names.append(name)
    for i in range(count):
        name = f"random-{seed}-{i}"
        with open(os.path.join(lib, name + ".kicad_mod"), "w") as f:
            f.write(random_footprint(rng, name))
        names.append(name)
    for src, name in stock_sample(rng, 40):
        fp = _IO.FootprintLoad(os.path.join(STOCK, src), name, True)
        fp.SetFPID(pcbnew.LIB_ID("", "stock-" + name))
        _IO.FootprintSave(lib, fp)
        names.append("stock-" + name)
    cb = Callbacks()
    out = {}
    io = pcbnew.PCB_IO_KICAD_SEXPR()
    for name in names:
        fp = io.FootprintLoad(lib, name, True)
        board = pcbnew.BOARD()
        board.Add(fp)
        if unflashed_pair(fp):
            # (KiCad's behaviour there is undefined: left out, and the file with it)
            print(name, "left out: a plated pad not flashed on F.Cu", unflashed_pair(fp))
            os.remove(os.path.join(lib, name + ".kicad_mod"))
            continue
        out[name] = run_checks(cb, fp)
    with open(os.path.join(outdir, "checks.json"), "w") as f:
        json.dump(out, f, indent=1, sort_keys=True)
        f.write("\n")
    kinds = {}
    for markers in out.values():
        for m in markers:
            kinds[m["type"]] = kinds.get(m["type"], 0) + 1
    print(len(out), "footprints;", kinds)


# MARK: - Pad numbers

NUMBER_PARTS = ["", "1", "2", "9", "10", "11", "99", "007", "0", "A", "B", "MP", "EP", "x-", "1.", "?", "??", "A?", "Ü",
                "²", " ", "_", "2147483646", "4294967297", "123456789012", "99999999999999999999"]


def numbers(outdir, count=400, seed=20261128):
    """GetNextPadNumber of random footprints' pad numbers after random last numbers: OUTDIR/numbers.json, each case
    the footprint's numbers, the last number and KiCad's next"""
    rng = random.Random(seed)
    cases = []

    def number():
        return "".join(rng.choice(NUMBER_PARTS) for _ in range(rng.choice([1, 1, 2, 2, 3])))

    hand = [([], "1"), (["1"], "1"), (["1", "2", "3"], "1"), (["1", "2", "4"], "2"), (["A1", "A2"], "A1"),
            (["A1", "A2"], "A"), (["1"], ""), ([""], ""), (["0", "1"], ""), (["A1"], "A1?"), (["1"], "1?"),
            (["B3"], "B"), (["B0", "B1"], "B"), (["12"], "x12"), (["x13"], "x12"), (["2147483646"], "2147483646"),
            (["5"], "4294967301"), (["1"], "007"), (["8"], "007"), (["7", "8"], "07")]
    for used, last in hand:
        cases.append({"numbers": used, "last": last})
    for _ in range(count):
        used = [number() for _ in range(rng.randint(0, 8))]
        last = rng.choice(used) if used and rng.random() < 0.5 else number()
        # (the next numbers of a last number's digits: some taken)
        prefix = last.rstrip("0123456789?")
        used += [prefix + str(int(d) + k) for d in [last[len(prefix):].rstrip("?")] if d.isdigit() and len(d) < 9
                 for k in range(rng.randint(0, 3))]
        cases.append({"numbers": used, "last": last})
    for c in cases:
        fp = pcbnew.FOOTPRINT(None)
        for n in c["numbers"]:
            pad = pcbnew.PAD(fp)
            pad.SetNumber(n)
            fp.Add(pad)
        c["next"] = fp.GetNextPadNumber(c["last"])
    with open(os.path.join(outdir, "numbers.json"), "w") as f:
        json.dump(cases, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print(len(cases), "cases")


# MARK: - Renumber Pads

def renumber_footprint(name):
    """The footprint the renumbering runs are made on: two rows of six pads 1.5 mm apart (the second row's fourth an
    unplated hole, its fifth an aperture, neither of which can have a number), two pads over each other at the right
    of the first row (the second on F.SilkS too, the active layer, which the collector takes first), a round
    through-hole pad below them, and a courtyard round them all"""
    items = []
    for i in range(6):
        items.append(smd(str(i + 1), (i * 1.5, 0), (1, 1)))
    for i in range(6):
        p = (i * 1.5, 2.5)
        if i == 3:
            items.append(npth("", p, (1, 1), (1, 1)))
        elif i == 4:
            items.append(smd("", p, (1, 1), layers=("F.Paste", "F.Mask")))
        else:
            items.append(smd(str(i + 7), p, (1, 1)))
    items.append(smd("13", (10, 0), (1.6, 1)))
    items.append(smd("14", (10.3, 0), (1, 1), layers=("F.Cu", "F.Mask", "F.SilkS")))
    items.append(tht("15", (10, 2.5), (1.2, 1.2), (0.6, 0.6)))
    items.append(rect((-2, -2), (12, 4.5), "F.CrtYd"))
    return footprint_text(name, items, courtyard=False)


# Each run: DIALOG_ENUM_PADS' start, step and prefix, and what the pointer does (mm, in the footprint editor, the
# footprint at 0, 0): a click on a point, a drag through points (the first move far past the drag threshold), the run
# finished with a double click where there is nothing
RENUMBER_CASES = [
    {"start": 1, "step": 1, "prefix": "",
     "actions": [["click", [3, 0]], ["click", [0, 0]], ["click", [1.5, 0.2]], ["click", [7.5, 2.5]], ["click", [10, 2.5]]]},
    {"start": 5, "step": 2, "prefix": "A",
     "actions": [["click", [0, 0]], ["click", [1.5, 0]], ["click", [3, 0]], ["click", [1.5, 0]], ["click", [6, 0]],
                 ["click", [7.5, 0]], ["click", [0, 0]], ["click", [4.5, 2.5]], ["click", [1.5, 0.3]]]},
    {"start": 1, "step": 1, "prefix": "",
     "actions": [["drag", [[-0.2, 0], [3.2, 0], [7.7, 0.1]]], ["drag", [[7.6, 2.5], [5.1, 2.4], [2.0, 2.5], [-0.1, 2.5]]]]},
    {"start": 10, "step": 10, "prefix": "P",
     "actions": [["drag", [[0, 0], [4.5, 2.5], [6, 0]]], ["click", [10.2, 0]], ["click", [3, 0]], ["click", [10.2, 0]],
                 ["drag", [[10.2, 0], [10, 2.5]]], ["click", [3, 2.5]]]},
    {"start": 0, "step": 0, "prefix": "",
     "actions": [["click", [0, 0]], ["click", [1.5, 0]], ["click", [3, 0]], ["click", [1.5, 0]], ["click", [0, 0]],
                 ["click", [4.5, 0]]]},
    {"start": 999, "step": 999, "prefix": "1",
     "actions": [["click", [9.6, 0]], ["click", [10.6, 0]], ["drag", [[10.2, -0.2], [0, 0.2]]], ["click", [4.5, 0]]]},
]

RENUMBER_PLUGIN = r'''
import json, os, re, traceback
import wx
import pcbnew

JOB = json.load(open(os.environ["JSPICE_RENUMBER_JOB"]))
state = {"phase": "load", "quiet": 0, "ticks": 0, "wait": 0, "tries": 0, "step": 0}
sim = wx.UIActionSimulator()
out = {"dialogs": [], "events": []}


def walk(w):
    yield w
    for c in w.GetChildren():
        yield from walk(c)


def frame():
    return next((w for w in wx.GetTopLevelWindows() if w.GetName() == "PcbFrame" and w.IsShown()), None)


def editor_frame():
    return next((w for w in wx.GetTopLevelWindows() if w.IsShown() and w.GetName() != "PcbFrame"
                 and ("ootprint" in w.GetName() or "Footprint Editor" in w.GetTitle())), None)


def canvas(f):
    cands = [w for w in walk(f) if w.IsShown() and w.GetClassName() == "wxGLCanvas"]
    return max(cands, key=lambda w: w.GetSize().x * w.GetSize().y)


def cursor(f):
    sb = f.GetStatusBar()
    for i in range(sb.GetFieldsCount()):
        m = re.match(r"X (-?[0-9.]+)\s+Y (-?[0-9.]+)", sb.GetStatusText(i))
        if m:
            return float(m.group(1)), float(m.group(2))
    return None


def finish(code):
    with open(JOB["out"], "w") as f:
        json.dump(out, f)
    os._exit(code)


def menu(f, title, command):
    bar = f.GetMenuBar()
    m = bar.GetMenu(next(i for i in range(bar.GetMenuCount()) if bar.GetMenuLabelText(i) == title))
    # (an ellipsis written as three dots or as one character)
    item = next(i for i in m.GetMenuItems() if i.GetItemLabelText().replace("\u2026", "...") == command)
    evt = wx.CommandEvent(wx.wxEVT_MENU, item.GetId())
    evt.SetEventObject(m)
    wx.CallAfter(m.ProcessEvent, evt)


def press(d, id):
    b = d.FindWindow(id)
    evt = wx.CommandEvent(wx.wxEVT_BUTTON, id)
    evt.SetEventObject(b)
    wx.PostEvent(b, evt)


def calibrate(f, key):
    """The canvas' screen points of two world points (the status bar's cursor where the pointer is put, twice): True
    once done, state[key] then (p1, w1, scale)"""
    c = canvas(f)
    f.Raise()
    r = c.GetScreenRect()
    pts = [(r.x + r.width // 5, r.y + r.height // 5), (r.x + 4 * r.width // 5, r.y + 4 * r.height // 5)]
    cal = state.setdefault(key + "cal", {"readings": [], "moved": False, "last": None})
    k = len(cal["readings"])
    if k < 2:
        target = pts[k]
        if not cal["moved"]:
            sim.MouseMove(target[0] + 3, target[1] + 3)
            sim.MouseMove(*target)
            cal["moved"] = True
            cal["last"] = None
            state["wait"] = 4
            return False
        now = cursor(f)
        if now is not None and now == cal["last"]:
            cal["readings"].append((target, now))
            cal["moved"] = False
        else:
            cal["last"] = now
            sim.MouseMove(*target)
            state["wait"] = 3
        return False
    (p1, w1), (p2, w2) = cal["readings"]
    state[key] = (p1, w1, ((w2[0] - w1[0]) / (p2[0] - p1[0]), (w2[1] - w1[1]) / (p2[1] - p1[1])))
    return True


def screen(key, x, y):
    p1, w1, s = state[key]
    return (round(p1[0] + (x - w1[0]) / s[0]), round(p1[1] + (y - w1[1]) / s[1]))


def world(key, q):
    p1, w1, s = state[key]
    return [w1[0] + (q[0] - p1[0]) * s[0], w1[1] + (q[1] - p1[1]) * s[1]]


def record(kind, q):
    out["events"].append([kind, world("e", q)])


def plan():
    """The pointer's moves, presses and letting go for the run's actions, each a step of its own"""
    steps = []
    for action in JOB["actions"] + [["finish", JOB["empty"]]]:
        kind = action[0]
        if kind in ("click", "finish"):
            x, y = action[1]
            steps += [("move", (x, y), (1, 0)), ("move", (x, y), (0, 0)), ("dbl" if kind == "finish" else "click", (x, y), (0, 0))]
        else:
            pts = action[1]
            steps += [("move", pts[0], (1, 0)), ("move", pts[0], (0, 0)), ("down", pts[0], (0, 0))]
            steps += [("drag", p, (0, 0)) for p in pts[1:]]
            steps += [("up", pts[-1], (0, 0))]
    return steps


def tick():
    try:
        state["ticks"] += 1
        if state["ticks"] > 4000:
            out["error"] = "timeout in " + state["phase"]
            finish(3)
        if state["wait"] > 0:
            state["wait"] -= 1
            return
        for w in wx.GetTopLevelWindows():
            if isinstance(w, wx.Dialog) and w.IsShown() and w.IsModal():
                spins = [s for s in walk(w) if isinstance(s, wx.SpinCtrl)]
                if state["phase"] == "dialog" and len(spins) == 2:
                    # (DIALOG_ENUM_PADS: its start, step and prefix set, OK pressed)
                    spins[0].SetValue(JOB["start"])
                    spins[1].SetValue(JOB["step"])
                    texts = [t for t in walk(w) if isinstance(t, wx.TextCtrl) and not isinstance(t, wx.SpinCtrl)]
                    texts[0].SetValue(JOB["prefix"])
                    out["dialog"] = {"title": w.GetTitle(), "start": spins[0].GetValue(), "step": spins[1].GetValue(),
                                     "prefix": texts[0].GetValue(), "ranges": [[s.GetMin(), s.GetMax()] for s in spins]}
                    press(w, wx.ID_OK)
                    state["phase"] = "act"
                    state["steps"] = plan()
                    state["wait"] = 10
                    return
                out["dialogs"].append({"title": w.GetTitle(), "said": [t.GetLabel() for t in walk(w) if isinstance(t, wx.StaticText)]})
                w.EndModal(wx.ID_OK)
                state["wait"] = 4
                return
        f = frame()
        if state["phase"] == "load":
            state["quiet"] += 1
            if f is not None and pcbnew.GetBoard() is not None and state["quiet"] > 8:
                f.SetSize(0, 0, 2560, 1600)
                fe = editor_frame()
                # (a footprint editor KiCad opens again as it starts, as it was when a run before ended, on the
                # board's footprint: that one used, closed if on another)
                if fe is not None and fe.GetTitle().startswith("U1 [from"):
                    out["reopened"] = fe.GetTitle()
                    state["phase"] = "editor"
                    state["wait"] = 8
                    return
                if fe is not None:
                    fe.Close(True)
                state["phase"] = "fit"
                state["wait"] = 8
            return
        if state["phase"] == "fit":
            menu(f, "View", "Zoom to Fit")
            state["phase"] = "calibrate"
            state["wait"] = 10
            return
        if state["phase"] == "calibrate":
            if calibrate(f, "b"):
                state["phase"] = "select"
            return
        if state["phase"] == "select":
            q = screen("b", *JOB["at"])
            sim.MouseMove(q[0] + 1, q[1])
            sim.MouseMove(*q)
            state["phase"] = "click"
            state["wait"] = 6
            return
        if state["phase"] == "click":
            sim.MouseClick(wx.MOUSE_BTN_LEFT)
            state["phase"] = "open"
            state["wait"] = 10
            return
        if state["phase"] == "open":
            sel = pcbnew.GetCurrentSelection()
            out["selection"] = [sel[k].GetClass() for k in range(len(sel))]
            canvas(f).SetFocus()
            sim.Char(ord("e"), wx.MOD_CONTROL)
            state["phase"] = "editor"
            state["wait"] = 20
            return
        fe = editor_frame()
        if state["phase"] == "editor":
            if fe is None:
                state["tries"] += 1
                if state["tries"] > 100:
                    out["error"] = "no footprint editor"
                    finish(4)
                state["wait"] = 3
                return
            fe.SetSize(0, 0, 2560, 1600)
            fe.Raise()
            state["phase"] = "efit"
            state["wait"] = 20
            return
        if state["phase"] == "efit":
            menu(fe, "View", "Zoom to Fit")
            state["phase"] = "ecalibrate"
            state["wait"] = 15
            return
        if state["phase"] == "ecalibrate":
            if calibrate(fe, "e"):
                out["scale"] = state["e"][2]
                state["phase"] = "start"
            return
        if state["phase"] == "start":
            canvas(fe).SetFocus()
            menu(fe, "Edit", "Renumber Pads...")
            state["phase"] = "dialog"
            state["wait"] = 5
            return
        if state["phase"] == "dialog":
            state["tries"] += 1
            if state["tries"] > 300:
                out["error"] = "no Renumber Pads dialog"
                finish(5)
            return
        if state["phase"] == "act":
            steps = state["steps"]
            if state["step"] >= len(steps):
                state["phase"] = "save"
                state["wait"] = 15
                return
            kind, (x, y), (dx, dy) = steps[state["step"]]
            state["step"] += 1
            q = screen("e", x, y)
            q = (q[0] + dx, q[1] + dy)
            if kind == "move":
                sim.MouseMove(*q)
                record("motion", q)
            elif kind == "click":
                sim.MouseClick(wx.MOUSE_BTN_LEFT)
                record("down", q)
                record("click", q)
            elif kind == "dbl":
                sim.MouseDblClick(wx.MOUSE_BTN_LEFT)
                record("down", q)
                record("click", q)
                record("down", q)
            elif kind == "down":
                sim.MouseDown(wx.MOUSE_BTN_LEFT)
                record("down", q)
            elif kind == "drag":
                sim.MouseMove(*q)
                record("drag", q)
            elif kind == "up":
                sim.MouseUp(wx.MOUSE_BTN_LEFT)
                record("up", q)
            state["wait"] = 4
            return
        if state["phase"] == "save":
            menu(fe, "File", "Save")
            state["phase"] = "write"
            state["wait"] = 30
            return
        if state["phase"] == "write":
            pcbnew.SaveBoard(JOB["save"], pcbnew.GetBoard())
            finish(0)
    except Exception:
        out["error"] = traceback.format_exc()
        finish(2)


# (KiCad may import its plugins more than once: one timer drives the run)
if not os.environ.get("JSPICE_RENUMBER_STARTED"):
    os.environ["JSPICE_RENUMBER_STARTED"] = "1"
    timer = wx.Timer()
    timer.Bind(wx.EVT_TIMER, lambda e: tick())
    timer.Start(150)
'''


def free_display():
    """An X display number no server has (xvfb-run -a's first free one from 99 can be another run's too, when runs
    start together, and then each one's pointer moves the other's windows): one of many, at random"""
    rng = random.SystemRandom()
    while True:
        n = rng.randint(400, 3000)
        if not os.path.exists(f"/tmp/.X{n}-lock") and not os.path.exists(f"/tmp/.X11-unix/X{n}"):
            return n


def renumber(outdir):
    """Each of RENUMBER_CASES a run of KiCad's own footprint editor (the PCB editor under Xvfb, its footprint clicked
    and opened with Ctrl+E), Renumber Pads started from its Edit menu, its dialog's fields set, the pointer moved,
    pressed, dragged and clicked, the run ended with a double click and the footprint saved back onto the board:
    OUTDIR/renumber.pretty/renumber.kicad_mod, OUTDIR/renumber-N.kicad_pcb (the board before) and edited-N.kicad_pcb,
    and OUTDIR/renumber.json (each run's settings, actions, the pointer's events in the editor's coordinates as the
    view's scale read from the status bar makes them, that scale, and the pads' numbers KiCad gave, by place)"""
    outdir = os.path.abspath(outdir)
    lib = os.path.join(outdir, "renumber.pretty")
    os.makedirs(lib, exist_ok=True)
    with open(os.path.join(lib, "renumber.kicad_mod"), "w") as f:
        f.write(renumber_footprint("renumber"))
    home = os.environ.get("KICAD_CONFIG_HOME") or os.path.expanduser("~/.config/kicad")
    results = []
    only = os.environ.get("JSPICE_RUNS")
    for n, case in enumerate(RENUMBER_CASES):
        if only and str(n) not in only.split(","):
            continue
        board = pcbnew.CreateEmptyBoard()
        fp = _IO.FootprintLoad(lib, "renumber", True)
        fp.SetParent(board)
        fp.SetPosition(pcbnew.VECTOR2I(iu(100), iu(100)))
        fp.SetReference("U1")
        board.Add(fp)
        before = os.path.join(outdir, f"renumber-{n}.kicad_pcb")
        pcbnew.SaveBoard(before, board)
        # (the footprint clicked where it has nothing but its courtyard)
        at = [100 + 4.5, 100 + 1.25]
        with tempfile.TemporaryDirectory() as tmp:
            share = os.path.join(tmp, "share")
            plugins = os.path.join(share, "kicad", "10.0", "scripting", "plugins")
            os.makedirs(plugins)
            with open(os.path.join(plugins, "jspice_renumber.py"), "w") as f:
                f.write(RENUMBER_PLUGIN)
            config = os.path.join(tmp, "config")
            shutil.copytree(home, config, ignore=shutil.ignore_patterns("*.lck"))
            # (a micrometre grid, nothing magnetic, in both editors: the pointer goes where it is put)
            for name in ("pcbnew.json", "fpedit.json"):
                pj = os.path.join(config, "10.0", name)
                cfg = json.load(open(pj)) if os.path.exists(pj) else {}
                grid = cfg.setdefault("window", {}).setdefault("grid", {})
                grid["sizes"] = [{"name": "", "x": "0.001 mm", "y": "0.001 mm"}]
                grid["last_size"] = 0
                editing = cfg.setdefault("editing", {})
                editing["magnetic_graphics"] = False
                editing["magnetic_pads"] = 0
                editing["magnetic_tracks"] = 0
                json.dump(cfg, open(pj, "w"))
            job = dict(case, at=at, empty=[5.25, -1.5], out=os.path.join(tmp, "out.json"),
                       save=os.path.join(outdir, f"edited-{n}.kicad_pcb"))
            with open(os.path.join(tmp, "job.json"), "w") as f:
                json.dump(job, f)
            env = dict(os.environ, XDG_DATA_HOME=share, KICAD_CONFIG_HOME=config, JSPICE_RENUMBER_JOB=os.path.join(tmp, "job.json"))
            run = subprocess.run(["xvfb-run", "-n", str(free_display()), "-s", "-screen 0 2560x1600x24", "pcbnew", before],
                                 cwd=outdir, env=env, capture_output=True, text=True, timeout=900)
            done = json.load(open(job["out"])) if os.path.exists(job["out"]) else {"error": run.stderr[-2000:]}
        for f in os.listdir(outdir):
            if f.endswith(".lck") or f.endswith(".kicad_prl") or f.endswith(".kicad_pro"):
                os.remove(os.path.join(outdir, f))
        if "error" in done:
            print(f"run {n} failed: {done['error']}")
            continue
        edited = pcbnew.LoadBoard(done.get("save", job["save"]))
        efp = next(iter(edited.Footprints()))
        result = {"run": n, "start": case["start"], "step": case["step"], "prefix": case["prefix"], "actions": case["actions"],
                  "dialog": done.get("dialog"), "scale": done.get("scale"), "events": done["events"],
                  # (by place, in the footprint's own coordinates: saving it onto the board gives each pad the id of
                  # the board's pad of its number, as ExchangeFootprint does, so the ids do not follow pads renumbered)
                  "numbers": {"%.4f,%.4f" % ((p.GetPosition().x - efp.GetPosition().x) / MM,
                                             (p.GetPosition().y - efp.GetPosition().y) / MM): p.GetNumber()
                              for p in efp.Pads()}}
        results.append(result)
        print(n, [p.GetNumber() for p in efp.Pads()], done.get("dialogs"))
    with open(os.path.join(outdir, "renumber.json"), "w") as f:
        json.dump(results, f, indent=1)
        f.write("\n")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "checks":
        checks(sys.argv[2], *(int(a) for a in sys.argv[3:5]))
    elif cmd == "numbers":
        os.makedirs(sys.argv[2], exist_ok=True)
        numbers(sys.argv[2], *(int(a) for a in sys.argv[3:5]))
    elif cmd == "renumber":
        renumber(sys.argv[2])
    else:
        sys.exit(__doc__)
