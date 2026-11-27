#!/usr/bin/env python3
"""KiCad's footprint editor's saving, checks and Update Footprints from Library, done by KiCad, for checking the port's
(KiCadRouter's FootprintFormat.swift, FootprintEditor.swift, FootprintChecks.swift and FootprintExchange.swift) against.

    footprints.py roundtrip OUTDIR
        footprints of KiCad's libraries (some of each kind of item and pad, and some at random) read and saved again by
        KiCad's own plugin (PCB_IO_KICAD_SEXPR's FootprintLoad keeping their ids, FootprintSave): OUTDIR/library/LIB.pretty
        holds each as its library has it, OUTDIR/kicad/LIB.pretty as KiCad saved it.
    footprints.py all OUTDIR
        every footprint of KiCad's libraries saved so, into OUTDIR/LIB.pretty (for KICAD_FOOTPRINT_ROUNDTRIP).
    footprints.py edits OUTDIR
        footprints edited through KiCad's own model, as its footprint editor's tools edit them (EDIT_TOOL's Move,
        Rotate and Delete of a footprint's items, PAD_TOOL::PlacePad's pad, made from the master pad as PAD's
        constructor makes it and numbered by FOOTPRINT::GetNextPadNumber, the pad properties dialog's size, shape and
        hole, DRAWING_TOOL's shapes and texts, the footprint properties' description, keywords, value and attributes,
        net tie pad groups, Save As's name) and saved (FootprintSave): OUTDIR/edits.json (each case: its footprint and
        its edits) and OUTDIR/kicad/CASE.kicad_mod.
    footprints.py boardsave OUTDIR BOARD.kicad_pcb...
        each board's footprints saved into a library as FootprintSave saves a board's (a copy turned to 0°, onto the
        front, on no net), each under its reference: OUTDIR/BOARD.pretty.
    footprints.py readback OURS KICAD
        each footprint of OURS (LIB.pretty/NAME.kicad_mod, written by the port: FootprintEditorTests writes them with
        KICAD_FOOTPRINT_DUMP) and of KICAD read by KiCad (FootprintLoad) and compared field by field (its properties,
        fields, pads, drawings, texts, zones and models, as KiCad's model holds them), and saved again by KiCad: the
        same text as the port's. Prints what differs, and how many were compared.
    footprints.py checks OUTDIR
        footprints of KiCad's libraries made faulty (pads without holes, holes outside or larger than their pads, SMD
        pads with holes or on both sides, negative margins, wrong attributes, pads that overlap, unknown or repeated
        net tie pads, malformed or missing courtyards), each on a board of its own (OUTDIR/CASE.kicad_pcb, its project
        reporting a missing courtyard), and kicad-cli's design rules check of each (OUTDIR/CASE.drc), whose footprint
        checks (DRC_TEST_PROVIDER_FOOTPRINT_CHECKS' and the courtyards') are the footprint checker's.
    footprints.py update OUTDIR
        a board of footprints of KiCad's libraries (turned, on the back, locked, on nets, their texts moved and
        restyled, fields added) and copies of those libraries changed (pads moved and resized, pads added and taken
        away, drawings and texts added, changed and taken away, fields added), in the project's fp-lib-table; then
        KiCad's own PCB editor, under Xvfb, with an action plugin of its own, opening Tools > Update Footprints from
        Library..., its options set (UPDATE_CASES), pressing Update, saving the board: OUTDIR/update-N/board.kicad_pcb
        (before) and board-updated.kicad_pcb, with update.json (the options and what the dialog reported).

KiCad 10's pcbnew Python module, kicad-cli, Xvfb (xvfb-run) and a KiCad configuration made by running KiCad once (it
is copied; KICAD_CONFIG_HOME names it).
"""

import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile

import pcbnew

STOCK = os.environ.get("KICAD_FOOTPRINT_DIR", "/usr/share/kicad/footprints")
MM = 1_000_000


_IO = pcbnew.PCB_IO_KICAD_SEXPR()

# (the footprint checks, made errors: some are ignored or warnings where a project does not say otherwise)
SEVERITIES = ["footprint_type_mismatch", "pad_th_with_no_hole", "padstack", "padstack_invalid", "footprint",
              "missing_courtyard", "malformed_courtyard", "shorting_items"]


def io():
    """KiCad's own plugin (one, kept: what it loads are copies its cache owns until it goes)"""
    return _IO


def iu(v):
    return int(round(v * MM))


def point(p):
    return pcbnew.VECTOR2I(iu(p[0]), iu(p[1]))


def stock_files():
    for lib in sorted(os.listdir(STOCK)):
        if not lib.endswith(".pretty"):
            continue
        for f in sorted(os.listdir(os.path.join(STOCK, lib))):
            if f.endswith(".kicad_mod"):
                yield lib, f


# MARK: - Round trips

FEATURES = [r"\(zone", r"\(pad \"[^\"]*\" \w+ custom", r"\(fp_arc", r"\(fp_poly", r"\(fp_circle", r"\(fp_curve",
            r"\(fp_text_box", r"\(group", r"\(point", r"trapezoid", r"chamfer", r"np_thru_hole", r"net_tie_pad_groups",
            r"\(model", r"\(fp_text user", r"roundrect", r"\(drill oval", r"\(offset", r"\(primitives",
            r"\(solder_mask_margin", r"\(clearance", r"\(zone_connect", r"\(property \"[A-Z][a-z]+\" \"[^\"]+\"",
            r"\(unlocked yes", r"\(justify", r"\(locked yes", r"\(attr [^)]*exclude", r"\(private_layers",
            r"\(thermal_bridge", r"knockout", r"\(fp_rect[^)]*\n[^)]*\n[^)]*\(radius"]


def save_copy(src_lib, name, outlib, keep=True):
    fp = io().FootprintLoad(os.path.join(STOCK, src_lib), name, keep)
    io().FootprintSave(outlib, fp)


def roundtrip(outdir):
    rng = random.Random(20261127)
    files = list(stock_files())
    chosen = []
    for pattern in FEATURES:
        hits = [(l, f) for l, f in files if re.search(pattern, open(os.path.join(STOCK, l, f)).read())]
        chosen += rng.sample(hits, min(2, len(hits)))
    chosen += rng.sample(files, 30)
    # (not those with dimensions: KiCad works their texts out again as it reads them, which the port does not)
    chosen = sorted(c for c in set(chosen) if "(dimension" not in open(os.path.join(STOCK, *c)).read())
    for lib, f in chosen:
        for side in ("library", "kicad"):
            os.makedirs(os.path.join(outdir, side, lib), exist_ok=True)
        shutil.copy(os.path.join(STOCK, lib, f), os.path.join(outdir, "library", lib, f))
        save_copy(lib, f[:-10], os.path.join(outdir, "kicad", lib))
    print(len(chosen), "footprints")


def all_stock(outdir):
    n = 0
    for lib, f in stock_files():
        out = os.path.join(outdir, lib)
        if os.path.exists(os.path.join(out, f)):
            continue
        os.makedirs(out, exist_ok=True)
        save_copy(lib, f[:-10], out)
        n += 1
    print(n, "footprints")


# MARK: - Edits

def select(fp, sel):
    """An item of the footprint by its kind and place in its file's order (its ids are new where its file has none):
    pad:N, drawing:N (a shape or text among GraphicalItems), field:NAME"""
    kind, _, which = sel.partition(":")
    if kind == "pad":
        return list(fp.Pads())[int(which)]
    if kind == "drawing":
        return list(fp.GraphicalItems())[int(which)]
    if kind == "field":
        return fp.GetField(which) if which not in ("Reference", "Value") else (fp.Reference() if which == "Reference" else fp.Value())
    raise ValueError(sel)


def angle(d):
    return pcbnew.EDA_ANGLE(d, pcbnew.DEGREES_T)


SHAPES = {"segment": pcbnew.SHAPE_T_SEGMENT, "rectangle": pcbnew.SHAPE_T_RECTANGLE, "circle": pcbnew.SHAPE_T_CIRCLE,
          "arc": pcbnew.SHAPE_T_ARC, "polygon": pcbnew.SHAPE_T_POLY}
PAD_SHAPES = {"circle": pcbnew.PAD_SHAPE_CIRCLE, "rect": pcbnew.PAD_SHAPE_RECTANGLE, "oval": pcbnew.PAD_SHAPE_OVAL,
              "roundrect": pcbnew.PAD_SHAPE_ROUNDRECT}


def apply(fp, edit, state):
    op = edit["op"]
    if op == "move":
        for sel in edit["items"]:
            select(fp, sel).Move(point(edit["by"]))
    elif op == "rotate":
        for sel in edit["items"]:
            select(fp, sel).Rotate(point(edit["about"]), angle(edit["degrees"]))
    elif op == "delete":
        items = [select(fp, sel) for sel in edit["items"]]
        for item in items:
            fp.Remove(item)
    elif op == "placePad":
        pad = pcbnew.PAD(fp)
        number = fp.GetNextPadNumber(state["last"])
        pad.SetNumber(number)
        state["last"] = number
        pad.SetPosition(point(edit["at"]))
        fp.Add(pad)
    elif op == "shape":
        s = pcbnew.PCB_SHAPE(fp, SHAPES[edit["kind"]])
        pts = [point(p) for p in edit["points"]]
        if edit["kind"] == "arc":
            s.SetArcGeometry(pts[0], pts[1], pts[2])
        elif edit["kind"] == "polygon":
            s.SetPolyPoints(pcbnew.VECTOR_VECTOR2I(pts))
        else:
            s.SetStart(pts[0])
            s.SetEnd(pts[1])
        # (its stroke as PCB_SHAPE's constructor makes it, its line style the default: the module cannot set another)
        s.SetWidth(iu(edit["width"]))
        if edit["kind"] in ("rectangle", "circle", "polygon"):
            s.SetFilled(edit.get("filled", False))
        s.SetLayer(layer_id(edit["layer"]))
        fp.Add(s)
    elif op == "text":
        t = pcbnew.PCB_TEXT(fp)
        t.SetText(edit["text"])
        t.SetLayer(layer_id(edit["layer"]))
        style = edit["style"]
        t.SetTextSize(pcbnew.VECTOR2I(iu(style["width"]), iu(style["height"])))
        t.SetTextThickness(iu(style["thickness"]))
        t.SetMirrored(edit["layer"].startswith("B."))
        t.SetKeepUpright(style["upright"])
        t.SetTextPos(point(edit["at"]))
        fp.Add(t)
    elif op == "pad":
        pad = select(fp, edit["item"])
        if "shape" in edit:
            pad.SetShape(pcbnew.F_Cu, PAD_SHAPES[edit["shape"]])
        if "size" in edit:
            pad.SetSize(pcbnew.F_Cu, point(edit["size"]))
        if "drill" in edit:
            pad.SetDrillSize(pcbnew.VECTOR2I(iu(edit["drill"]), iu(edit["drill"])))
        if "ratio" in edit:
            pad.SetRoundRectRadiusRatio(pcbnew.F_Cu, edit["ratio"])
    elif op == "describe":
        fp.SetLibDescription(edit["description"])
        fp.SetKeywords(edit["keywords"])
    elif op == "value":
        fp.SetValue(edit["text"])
    elif op == "attributes":
        flags = {"smd": pcbnew.FP_SMD, "through_hole": pcbnew.FP_THROUGH_HOLE, "board_only": pcbnew.FP_BOARD_ONLY,
                 "exclude_from_bom": pcbnew.FP_EXCLUDE_FROM_BOM, "exclude_from_pos_files": pcbnew.FP_EXCLUDE_FROM_POS_FILES}
        a = 0
        for f in edit["flags"]:
            a |= flags[f]
        fp.SetAttributes(a)
    elif op == "netTie":
        fp.ClearNetTiePadGroups()
        for g in edit["groups"]:
            fp.AddNetTiePadGroup(g)
    elif op == "saveAs":
        update = fp.GetValue() == fp.GetFPID().GetLibItemName().wx_str()
        fp.SetFPID(pcbnew.LIB_ID("", edit["name"]))
        if update:
            fp.SetValue(edit["name"])
    else:
        raise ValueError(op)


def layer_id(name):
    """A layer's id by its canonical name (LSET::Name: "F.SilkS", not the board's "F.Silkscreen")"""
    for i in range(pcbnew.PCB_LAYER_ID_COUNT):
        if pcbnew.LSET.Name(i) == name:
            return i
    raise ValueError(name)


def text_style(layer):
    """BOARD_DESIGN_SETTINGS' defaults for a text on `layer` (the footprint editor's own settings, as KiCad ships them)"""
    if layer in ("F.SilkS", "B.SilkS"):
        return {"width": 1.0, "height": 1.0, "thickness": 0.1, "upright": False}
    if layer.endswith(".Cu"):
        return {"width": 1.5, "height": 1.5, "thickness": 0.3, "upright": False}
    return {"width": 1.0, "height": 1.0, "thickness": 0.15, "upright": False}


EDIT_CASES = [
    ("Resistor_SMD.pretty", "R_0805_2012Metric", [
        {"op": "move", "items": ["pad:0", "pad:1"], "by": [0.25, -0.1]},
        {"op": "placePad", "at": [0, 2]},
        {"op": "placePad", "at": [1.27, 2]},
    ]),
    ("Package_SO.pretty", "SOIC-8_3.9x4.9mm_P1.27mm", [
        {"op": "rotate", "items": ["pad:0", "pad:7", "drawing:0"], "about": [0, 0], "degrees": 90},
        {"op": "delete", "items": ["pad:3", "drawing:2"]},
        {"op": "pad", "item": "pad:1", "shape": "roundrect", "size": [1.9, 0.7], "ratio": 0.25},
    ]),
    ("Connector_PinHeader_2.54mm.pretty", "PinHeader_1x04_P2.54mm_Vertical", [
        {"op": "shape", "kind": "segment", "layer": "F.SilkS", "width": 0.12, "points": [[-2, -2], [2, -2]]},
        {"op": "shape", "kind": "rectangle", "layer": "F.Fab", "width": 0.1, "points": [[-1, -1], [1, 9]]},
        {"op": "shape", "kind": "circle", "layer": "F.SilkS", "width": 0.12, "points": [[0, 0], [0.5, 0]]},
        {"op": "shape", "kind": "arc", "layer": "F.CrtYd", "width": 0.05, "points": [[-2, 10], [0, 12], [2, 10]]},
        {"op": "shape", "kind": "polygon", "layer": "F.Cu", "width": 0.2, "filled": True, "points": [[3, 0], [4, 0], [4, 1]]},
        {"op": "text", "text": "${REFERENCE}", "at": [0, 11], "layer": "F.Fab"},
        {"op": "text", "text": "back", "at": [0, -3], "layer": "B.SilkS"},
    ]),
    ("Package_QFP.pretty", "LQFP-32_7x7mm_P0.8mm", [
        {"op": "describe", "description": "An LQFP edited in JSpice", "keywords": "LQFP JSpice"},
        {"op": "value", "text": "MCU"},
        {"op": "attributes", "flags": ["smd", "exclude_from_bom"]},
        {"op": "move", "items": ["field:Reference"], "by": [1, 0.5]},
        {"op": "rotate", "items": ["field:Value"], "about": [0, 0], "degrees": 90},
    ]),
    ("Capacitor_THT.pretty", "C_Disc_D5.0mm_W2.5mm_P5.00mm", [
        {"op": "pad", "item": "pad:0", "size": [2, 2], "drill": 1.0},
        {"op": "pad", "item": "pad:1", "shape": "oval", "size": [2.4, 1.6]},
        {"op": "netTie", "groups": ["1, 2"]},
        {"op": "saveAs", "name": "C_Disc_Tie"},
    ]),
    ("Diode_SMD.pretty", "D_SOD-123", [
        {"op": "rotate", "items": ["pad:0", "pad:1", "drawing:0", "drawing:1", "drawing:2"], "about": [0.5, 0.25], "degrees": 45},
        {"op": "move", "items": ["drawing:3", "drawing:4"], "by": [-0.05, 0.05]},
        {"op": "saveAs", "name": "D_SOD-123_turned"},
    ]),
]


def edits(outdir):
    os.makedirs(os.path.join(outdir, "kicad"), exist_ok=True)
    cases = []
    for n, (lib, name, steps) in enumerate(EDIT_CASES):
        fp = io().FootprintLoad(os.path.join(STOCK, lib), name, True)
        state = {"last": "1"}
        for step in steps:
            if step["op"] == "text":
                step["style"] = text_style(step["layer"])
            apply(fp, step, state)
        case = f"edit-{n}"
        lib_out = os.path.join(outdir, "kicad", case + ".pretty")
        if os.path.exists(lib_out):
            shutil.rmtree(lib_out)
        io().CreateLibrary(lib_out)
        io().FootprintSave(lib_out, fp)
        saved = os.listdir(lib_out)[0]
        shutil.copy(os.path.join(lib_out, saved), os.path.join(outdir, "kicad", case + ".kicad_mod"))
        shutil.rmtree(lib_out)
        source = os.path.join(outdir, "library", case + ".kicad_mod")
        os.makedirs(os.path.dirname(source), exist_ok=True)
        shutil.copy(os.path.join(STOCK, lib, name + ".kicad_mod"), source)
        cases.append({"case": case, "library": lib[:-7], "footprint": name, "edits": steps, "saved": saved})
    with open(os.path.join(outdir, "edits.json"), "w") as f:
        json.dump(cases, f, indent=1)
    print(len(cases), "cases")


# MARK: - Board footprints saved to a library

def boardsave(outdir, boards):
    os.makedirs(outdir, exist_ok=True)
    for path in boards:
        board = pcbnew.LoadBoard(path)
        lib = os.path.join(outdir, os.path.splitext(os.path.basename(path))[0] + ".pretty")
        if os.path.exists(lib):
            shutil.rmtree(lib)
        io().CreateLibrary(lib)
        for fp in board.Footprints():
            # (FootprintSave saves a copy of its own: the board's, renamed, is what it is given)
            fp.SetFPID(pcbnew.LIB_ID("", fp.GetReference()))
            io().FootprintSave(lib, fp)
        print(path, len(board.Footprints()))


# MARK: - Read back

def describe(fp):
    """What KiCad's model holds of a footprint, field by field"""
    def p(v):
        return [v.x, v.y]

    def text(t):
        return {"text": t.GetText(), "pos": p(t.GetFPRelativePosition()), "angle": t.GetTextAngle().AsDegrees(),
                "size": p(t.GetTextSize()), "thickness": t.GetTextThickness(), "layer": t.GetLayerName(),
                "visible": t.IsVisible(), "bold": t.IsBold(), "italic": t.IsItalic(), "mirrored": t.IsMirrored(),
                "hjustify": int(t.GetHorizJustify()), "vjustify": int(t.GetVertJustify()), "upright": t.IsKeepUpright(),
                "knockout": t.IsKnockout()}

    out = {"name": fp.GetFPID().GetLibItemName().wx_str(), "layer": fp.GetLayerName(), "descr": fp.GetLibDescription(),
           "tags": fp.GetKeywords(), "attributes": fp.GetAttributes(), "netTie": fp.IsNetTie(),
           "clearance": str(fp.GetLocalClearance()), "mask": str(fp.GetLocalSolderMaskMargin()),
           "paste": str(fp.GetLocalSolderPasteMargin()), "zoneConnect": int(fp.GetLocalZoneConnection()),
           "allowMissingCourtyard": fp.AllowMissingCourtyard(), "duplicatePadsJumpers": fp.GetDuplicatePadNumbersAreJumpers(),
           "models": [m.m_Filename for m in fp.Models()]}
    out["fields"] = {f.GetName(): text(f) for f in fp.GetFields()}
    out["pads"] = []
    for pad in fp.Pads():
        out["pads"].append({"number": pad.GetNumber(), "attribute": int(pad.GetAttribute()),
                            "shape": int(pad.GetShape(pcbnew.F_Cu)), "pos": p(pad.GetFPRelativePosition()),
                            "size": p(pad.GetSize(pcbnew.F_Cu)), "drill": p(pad.GetDrillSize()),
                            "drillShape": int(pad.GetDrillShape()), "angle": pad.GetOrientation().AsDegrees(),
                            "offset": p(pad.GetOffset(pcbnew.F_Cu)), "layers": [l for l in pad.GetLayerSet().Seq()],
                            "rratio": pad.GetRoundRectRadiusRatio(pcbnew.F_Cu), "property": int(pad.GetProperty()),
                            "clearance": str(pad.GetLocalClearance()), "mask": str(pad.GetLocalSolderMaskMargin()),
                            "zoneConnect": int(pad.GetLocalZoneConnection()), "uuid": pad.m_Uuid.AsString()})
    out["drawings"] = []
    for d in fp.GraphicalItems():
        if d.GetClass() == "PCB_TEXT":
            out["drawings"].append(dict(text(pcbnew.Cast_to_PCB_TEXT(d)), kind="text"))
        elif d.GetClass() == "PCB_SHAPE":
            s = pcbnew.Cast_to_PCB_SHAPE(d)
            item = {"kind": s.ShowShape(), "layer": s.GetLayerName(), "width": s.GetWidth(), "filled": s.IsSolidFill(),
                    "start": p(s.GetStart()), "end": p(s.GetEnd()), "uuid": s.m_Uuid.AsString()}
            if s.GetShape() == pcbnew.SHAPE_T_ARC:
                item["center"] = p(s.GetCenter())
            if s.GetShape() == pcbnew.SHAPE_T_POLY:
                item["points"] = [p(s.GetPolyShape().CVertex(i)) for i in range(s.GetPolyShape().TotalVertices())]
            out["drawings"].append(item)
        else:
            out["drawings"].append({"kind": d.GetClass(), "layer": d.GetLayerName()})
    out["zones"] = [{"layers": [l for l in z.GetLayerSet().Seq()], "corners": z.GetNumCorners(), "rule": z.GetIsRuleArea()}
                    for z in fp.Zones()]
    return out


def diff(a, b, path=""):
    if isinstance(a, dict) and isinstance(b, dict):
        out = []
        for k in sorted(set(a) | set(b)):
            out += diff(a.get(k), b.get(k), f"{path}.{k}")
        return out
    if isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        out = []
        for i, (x, y) in enumerate(zip(a, b)):
            out += diff(x, y, f"{path}[{i}]")
        return out
    return [] if a == b else [f"{path}: ours {a!r}, KiCad's {b!r}"]


def readback(ours, kicad):
    compared = failed = 0
    uuid = re.compile(r'\(uuid "[^"]*"\)')
    for root, _, files in os.walk(ours):
        for f in sorted(files):
            if not f.endswith(".kicad_mod"):
                continue
            rel = os.path.relpath(os.path.join(root, f), ours)
            theirs = os.path.join(kicad, rel)
            if not os.path.exists(theirs):
                continue
            a = io().FootprintLoad(os.path.dirname(os.path.join(ours, rel)), f[:-10], True)
            b = io().FootprintLoad(os.path.dirname(theirs), f[:-10], True)
            da, db = describe(a), describe(b)
            # (ids KiCad made anew on either side aside)
            for d in (da, db):
                for item in d["pads"] + d["drawings"]:
                    item.pop("uuid", None)
            problems = diff(da, db)
            # (and KiCad's own save of the port's footprint: the port's text again, its new ids aside)
            with tempfile.TemporaryDirectory() as tmp:
                lib = os.path.join(tmp, "x.pretty")
                io().CreateLibrary(lib)
                io().FootprintSave(lib, a)
                again = open(os.path.join(lib, os.listdir(lib)[0])).read()
            mine = open(os.path.join(ours, rel)).read()
            # (its name aside: a library's footprint is named by its file)
            name = re.compile(r'^\(footprint "[^"]*"')
            if name.sub("", uuid.sub("", again)) != name.sub("", uuid.sub("", mine)):
                problems.append("KiCad's save of ours is not ours")
            compared += 1
            if problems:
                failed += 1
                print(rel, *problems[:6], sep="\n  ")
    print(f"{compared} footprints read back, {failed} with differences")


# MARK: - Checks

CHECK_CASES = [
    # (library, footprint, what is done to it)
    ("Resistor_SMD.pretty", "R_0603_1608Metric", "smd_hole"),
    ("Resistor_SMD.pretty", "R_0603_1608Metric", "smd_both_sides"),
    ("Resistor_SMD.pretty", "R_0603_1608Metric", "smd_mask_other_side"),
    ("Resistor_SMD.pretty", "R_0603_1608Metric", "attr_tht"),
    ("Resistor_SMD.pretty", "R_0603_1608Metric", "overlap"),
    ("Resistor_SMD.pretty", "R_0603_1608Metric", "no_courtyard"),
    ("Resistor_SMD.pretty", "R_0603_1608Metric", "open_courtyard"),
    ("Resistor_SMD.pretty", "R_0603_1608Metric", "negative_margins"),
    ("Connector_PinHeader_2.54mm.pretty", "PinHeader_1x03_P2.54mm_Vertical", "no_hole"),
    ("Connector_PinHeader_2.54mm.pretty", "PinHeader_1x03_P2.54mm_Vertical", "hole_too_big"),
    ("Connector_PinHeader_2.54mm.pretty", "PinHeader_1x03_P2.54mm_Vertical", "attr_smd"),
    ("Connector_PinHeader_2.54mm.pretty", "PinHeader_1x03_P2.54mm_Vertical", "hole_offset_out"),
    ("Connector_PinHeader_2.54mm.pretty", "PinHeader_1x03_P2.54mm_Vertical", "same_place"),
    ("NetTie.pretty", "NetTie-2_SMD_Pad0.5mm", "tie_unknown_pad"),
    ("NetTie.pretty", "NetTie-3_SMD_Pad0.5mm", "tie_repeated_pad"),
    ("NetTie.pretty", "NetTie-2_SMD_Pad0.5mm", "tie_none"),
    ("MountingHole.pretty", "MountingHole_3.2mm_M3", "npth_pad_off"),
    ("Package_SO.pretty", "SOIC-8_3.9x4.9mm_P1.27mm", "fiducial_npth"),
    ("Package_SO.pretty", "SOIC-8_3.9x4.9mm_P1.27mm", "as_is"),
]


def fault(fp, what):
    pads = list(fp.Pads())
    if what == "smd_hole":
        pads[0].SetDrillSize(pcbnew.VECTOR2I(iu(0.3), iu(0.3)))
    elif what == "smd_both_sides":
        ls = pads[0].GetLayerSet()
        ls.AddLayer(pcbnew.B_Cu)
        pads[0].SetLayerSet(ls)
    elif what == "smd_mask_other_side":
        ls = pads[1].GetLayerSet()
        ls.RemoveLayer(pcbnew.F_Mask)
        ls.AddLayer(pcbnew.B_Mask)
        pads[1].SetLayerSet(ls)
    elif what == "attr_tht":
        fp.SetAttributes(pcbnew.FP_THROUGH_HOLE)
    elif what == "attr_smd":
        fp.SetAttributes(pcbnew.FP_SMD)
    elif what == "overlap":
        pads[1].SetPosition(pads[0].GetPosition() + pcbnew.VECTOR2I(iu(0.3), 0))
    elif what == "no_courtyard":
        for d in list(fp.GraphicalItems()):
            if d.GetLayer() in (pcbnew.F_CrtYd, pcbnew.B_CrtYd):
                fp.Remove(d)
    elif what == "open_courtyard":
        for d in list(fp.GraphicalItems()):
            if d.GetLayer() == pcbnew.F_CrtYd:
                s = pcbnew.Cast_to_PCB_SHAPE(d)
                fp.Remove(d)
                for a, b in ((0, 1), (1, 2), (2, 3)):
                    c = [s.GetStart(), pcbnew.VECTOR2I(s.GetEnd().x, s.GetStart().y), s.GetEnd(), pcbnew.VECTOR2I(s.GetStart().x, s.GetEnd().y)]
                    line = pcbnew.PCB_SHAPE(fp, pcbnew.SHAPE_T_SEGMENT)
                    line.SetStart(c[a])
                    line.SetEnd(c[b])
                    line.SetLayer(pcbnew.F_CrtYd)
                    line.SetWidth(iu(0.05))
                    fp.Add(line)
                break
    elif what == "negative_margins":
        pads[0].SetLocalSolderMaskMargin(-iu(2))
        pads[1].SetLocalSolderPasteMargin(-iu(2))
        pads[1].SetLocalClearance(-iu(0.1))
    elif what == "no_hole":
        pads[1].SetDrillSize(pcbnew.VECTOR2I(0, 0))
    elif what == "hole_too_big":
        pads[2].SetDrillSize(pcbnew.VECTOR2I(iu(2), iu(2)))
    elif what == "hole_offset_out":
        pads[1].SetAttribute(pcbnew.PAD_ATTRIB_NPTH)
        pads[1].SetOffset(pcbnew.F_Cu, pcbnew.VECTOR2I(iu(3), 0))
    elif what == "same_place":
        pads[2].SetPosition(pads[1].GetPosition())
    elif what == "no_outer_copper":
        ls = pads[0].GetLayerSet()
        ls.RemoveLayer(pcbnew.F_Cu)
        ls.RemoveLayer(pcbnew.B_Cu)
        pads[0].SetLayerSet(ls)
    elif what == "tie_unknown_pad":
        fp.ClearNetTiePadGroups()
        fp.AddNetTiePadGroup("1, 7")
    elif what == "tie_repeated_pad":
        fp.ClearNetTiePadGroups()
        fp.AddNetTiePadGroup("1, 2")
        fp.AddNetTiePadGroup("2, 3")
    elif what == "tie_none":
        fp.ClearNetTiePadGroups()
        fp.AddNetTiePadGroup("1")
    elif what == "npth_pad_off":
        pads[0].SetOffset(pcbnew.F_Cu, pcbnew.VECTOR2I(iu(5), 0))
    elif what == "fiducial_npth":
        pads[0].SetAttribute(pcbnew.PAD_ATTRIB_NPTH)
        pads[0].SetProperty(pcbnew.PAD_PROP_FIDUCIAL_LOCAL)
    elif what == "as_is":
        pass
    else:
        raise ValueError(what)


def checks(outdir):
    os.makedirs(outdir, exist_ok=True)
    for n, (lib, name, what) in enumerate(CHECK_CASES):
        board = pcbnew.CreateEmptyBoard()
        fp = io().FootprintLoad(os.path.join(STOCK, lib), name, False)
        fp.SetParent(board)
        fp.SetPosition(pcbnew.VECTOR2I(iu(100), iu(100)))
        board.Add(fp)
        fault(fp, what)
        case = os.path.join(outdir, f"check-{n}-{what}")
        pcbnew.SaveBoard(case + ".kicad_pcb", board)
        with open(case + ".kicad_pro", "w") as f:
            json.dump({"board": {"design_settings": {"rule_severities": {k: "error" for k in SEVERITIES}}}}, f)
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "drc.json")
            subprocess.run(["kicad-cli", "pcb", "drc", "--format", "json", "--units", "mm", "--severity-error",
                            "--severity-warning", "-o", out, case + ".kicad_pcb"], check=True, stdout=subprocess.DEVNULL)
            report = json.load(open(out))
        report.pop("date", None)
        with open(case + ".drc", "w") as f:
            json.dump(report, f, indent=1, sort_keys=True)
            f.write("\n")
        print(case, [v["type"] for v in report["violations"]])


# MARK: - Update Footprints from Library

# The Update Footprints from Library dialog's options for each run (its check boxes by their labels), the first its
# own (its update mode's first settings), the last every reset on (ExchangeFootprint's defaults, as the footprint
# editor's Update Footprint on Board exchanges a footprint)
UPDATE_CASES = [
    {},
    {"Remove text items if not in library footprint": True, "Update/reset text layers and visibilities": True,
     "Update/reset text sizes and styles": True, "Update/reset text positions": True,
     "Update/reset text content": True, "Update/reset fabrication attributes": True,
     "Update/reset clearance overrides": False, "Update/reset 3D models": False},
    {"Remove text items if not in library footprint": True, "Update/reset text layers and visibilities": True,
     "Update/reset text sizes and styles": True, "Update/reset text positions": True,
     "Update/reset text content": True, "Update/reset fabrication attributes": True,
     "Update/reset clearance overrides": True, "Update/reset 3D models": True},
]

UPDATE_PLUGIN = r'''
import json, os, traceback
import wx
import wx.html
import pcbnew

JOB = json.load(open(os.environ["JSPICE_UPDATE_JOB"]))
state = {"phase": "load", "quiet": 0, "ticks": 0, "wait": 0, "tries": 0}
out = {"options": {}}


def walk(w):
    yield w
    for c in w.GetChildren():
        yield from walk(c)


def shown(title):
    return next((w for w in wx.GetTopLevelWindows() if w.IsShown() and w.GetTitle() == title), None)


def frame():
    return next((w for w in wx.GetTopLevelWindows() if w.GetName() == "PcbFrame" and w.IsShown()), None)


def finish(code):
    with open(JOB["out"], "w") as f:
        json.dump(out, f)
    os._exit(code)


def press(d, id):
    b = d.FindWindow(id)
    evt = wx.CommandEvent(wx.wxEVT_BUTTON, id)
    evt.SetEventObject(b)
    wx.PostEvent(b, evt)


def tick():
    try:
        state["ticks"] += 1
        if state["ticks"] > 2000:
            out["error"] = "timeout in " + state["phase"]
            finish(3)
        if state["wait"] > 0:
            state["wait"] -= 1
            return
        f = frame()
        if state["phase"] == "load":
            state["quiet"] += 1
            if f is not None and pcbnew.GetBoard() is not None and state["quiet"] > 8:
                state["phase"] = "open"
            return
        if state["phase"] == "open":
            bar = f.GetMenuBar()
            m = bar.GetMenu(next(i for i in range(bar.GetMenuCount()) if bar.GetMenuLabelText(i) == "Tools"))
            item = next(i for i in m.GetMenuItems() if i.GetItemLabelText().startswith("Update Footprints from Library"))
            evt = wx.CommandEvent(wx.wxEVT_MENU, item.GetId())
            evt.SetEventObject(m)
            wx.CallAfter(m.ProcessEvent, evt)
            state["phase"] = "dialog"
            state["wait"] = 6
            return
        if state["phase"] == "dialog":
            d = shown("Update Footprints from Library")
            if d is None:
                state["tries"] += 1
                if state["tries"] > 60:
                    out["error"] = "no dialog"
                    finish(4)
                state["wait"] = 2
                return
            for w in walk(d):
                if isinstance(w, wx.RadioButton) and w.GetLabel() == "Update all footprints on board":
                    w.SetValue(True)
                    evt = wx.CommandEvent(wx.wxEVT_RADIOBUTTON, w.GetId())
                    evt.SetEventObject(w)
                    w.GetEventHandler().ProcessEvent(evt)
                if isinstance(w, wx.CheckBox):
                    if w.GetLabel() in JOB["options"]:
                        w.SetValue(JOB["options"][w.GetLabel()])
                    out["options"][w.GetLabel()] = w.GetValue()
            press(d, wx.ID_OK)
            state["phase"] = "report"
            state["wait"] = 20
            return
        if state["phase"] == "report":
            d = shown("Update Footprints from Library")
            if d is not None:
                for w in walk(d):
                    if isinstance(w, wx.html.HtmlWindow):
                        out["report"] = w.ToText()
                press(d, wx.ID_CANCEL)
            state["phase"] = "save"
            state["wait"] = 8
            return
        if state["phase"] == "save":
            pcbnew.SaveBoard(JOB["save"], pcbnew.GetBoard())
            finish(0)
    except Exception:
        out["error"] = traceback.format_exc()
        finish(2)


timer = wx.Timer()
timer.Bind(wx.EVT_TIMER, lambda e: tick())
timer.Start(150)
'''


def update_board(folder):
    """The board the updates start from, and the changed libraries in its project's fp-lib-table"""
    board = pcbnew.CreateEmptyBoard()
    for name in ("GND", "VCC", "SIG"):
        board.Add(pcbnew.NETINFO_ITEM(board, name))

    def place(lib, name, ref, value, pos, rot, back=False, locked=False):
        fp = io().FootprintLoad(os.path.join(STOCK, lib + ".pretty"), name, False)
        fp.SetParent(board)
        fp.SetFPID(pcbnew.LIB_ID(lib, name))
        fp.SetReference(ref)
        fp.SetValue(value)
        board.Add(fp)
        fp.SetPosition(point(pos))
        if back:
            fp.Flip(fp.GetPosition(), pcbnew.FLIP_DIRECTION_TOP_BOTTOM)
        if rot:
            fp.Rotate(fp.GetPosition(), angle(rot))
        fp.SetLocked(locked)
        return fp

    r1 = place("Resistor_SMD", "R_0805_2012Metric", "R1", "10k", (100, 100), 0)
    pads = list(r1.Pads())
    pads[0].SetNet(board.FindNet("GND"))
    pads[1].SetNet(board.FindNet("VCC"))
    pads[1].SetPinFunction("B")
    r1.Reference().SetPosition(r1.Reference().GetPosition() + point((0.5, -0.3)))
    r1.Reference().SetTextSize(pcbnew.VECTOR2I(iu(0.8), iu(0.8)))
    mpn = pcbnew.PCB_FIELD(r1, pcbnew.FIELD_T_USER, "MPN")
    mpn.SetText("RC0805FR-0710KL")
    mpn.SetLayer(pcbnew.F_Fab)
    mpn.SetVisible(False)
    mpn.SetPosition(r1.GetPosition())
    r1.Add(mpn)
    place("Resistor_SMD", "R_0805_2012Metric", "R2", "R_0805_2012Metric", (110, 100), 90, back=True, locked=True)
    u1 = place("Package_SO", "SOIC-8_3.9x4.9mm_P1.27mm", "U1", "LM358", (120, 110), 45)
    for pad, net in zip(list(u1.Pads())[:3], ("SIG", "GND", "VCC")):
        pad.SetNet(board.FindNet(net))
    u1.Value().SetPosition(u1.Value().GetPosition() + point((1, 1)))
    extra = pcbnew.PCB_TEXT(u1)
    extra.SetText("extra")
    extra.SetLayer(pcbnew.F_SilkS)
    extra.SetPosition(u1.GetPosition() + point((0, -4)))
    u1.Add(extra)
    j1 = place("Connector_PinHeader_2.54mm", "PinHeader_1x04_P2.54mm_Vertical", "J1", "Conn_01x04", (130, 100), 180)
    j1.SetAttributes(pcbnew.FP_THROUGH_HOLE | pcbnew.FP_EXCLUDE_FROM_BOM)
    j1.SetLocalClearance(iu(0.3))
    place("Capacitor_THT", "C_Disc_D5.0mm_W2.5mm_P5.00mm", "C1", "100n", (140, 105), 270, back=True)
    os.makedirs(folder, exist_ok=True)
    pcbnew.SaveBoard(os.path.join(folder, "board.kicad_pcb"), board)
    with open(os.path.join(folder, "board.kicad_pro"), "w") as f:
        json.dump({"meta": {"filename": "board.kicad_pro", "version": 3}}, f)

    # the libraries, changed
    libs = os.path.join(folder, "libs")
    changes = {
        ("Resistor_SMD", "R_0805_2012Metric"): "resistor",
        ("Package_SO", "SOIC-8_3.9x4.9mm_P1.27mm"): "soic",
        ("Connector_PinHeader_2.54mm", "PinHeader_1x04_P2.54mm_Vertical"): "header",
        ("Capacitor_THT", "C_Disc_D5.0mm_W2.5mm_P5.00mm"): None,
    }
    rows = []
    for (lib, name), what in changes.items():
        out = os.path.join(libs, lib + ".pretty")
        if not os.path.exists(out):
            os.makedirs(libs, exist_ok=True)
            io().CreateLibrary(out)
            rows.append(f'\t(lib (name "{lib}") (type "KiCad") (uri "${{KIPRJMOD}}/libs/{lib}.pretty") (options "") (descr ""))')
        fp = io().FootprintLoad(os.path.join(STOCK, lib + ".pretty"), name, True)
        pads = list(fp.Pads())
        if what == "resistor":
            pads[0].SetSize(pcbnew.F_Cu, pads[0].GetSize(pcbnew.F_Cu) + point((0.1, 0.1)))
            pads[1].SetPosition(pads[1].GetPosition() + point((0.05, 0)))
            line = pcbnew.PCB_SHAPE(fp, pcbnew.SHAPE_T_SEGMENT)
            line.SetStart(point((-1, 1.2)))
            line.SetEnd(point((1, 1.2)))
            line.SetLayer(pcbnew.F_SilkS)
            line.SetWidth(iu(0.12))
            fp.Add(line)
            fp.Reference().SetPosition(fp.Reference().GetPosition() + point((0, -0.2)))
            field = pcbnew.PCB_FIELD(fp, pcbnew.FIELD_T_USER, "LibField")
            field.SetText("from the library")
            field.SetLayer(pcbnew.F_Fab)
            field.SetVisible(False)
            fp.Add(field)
        elif what == "soic":
            fp.Remove(pads[7])
            ep = pcbnew.PAD(fp)
            ep.SetNumber("9")
            ep.SetAttribute(pcbnew.PAD_ATTRIB_SMD)
            ep.SetShape(pcbnew.F_Cu, pcbnew.PAD_SHAPE_RECTANGLE)
            ep.SetSize(pcbnew.F_Cu, point((2.3, 2.3)))
            ep.SetDrillSize(pcbnew.VECTOR2I(0, 0))
            ls = pcbnew.LSET()
            for l in (pcbnew.F_Cu, pcbnew.F_Mask, pcbnew.F_Paste):
                ls.AddLayer(l)
            ep.SetLayerSet(ls)
            ep.SetPosition(pcbnew.VECTOR2I(0, 0))
            fp.Add(ep)
            drawings = list(fp.GraphicalItems())
            fp.Remove(drawings[0])
            for d in drawings:
                if d.GetClass() == "PCB_TEXT":
                    t = pcbnew.Cast_to_PCB_TEXT(d)
                    t.SetTextSize(pcbnew.VECTOR2I(iu(0.7), iu(0.7)))
        elif what == "header":
            pads[1].SetShape(pcbnew.F_Cu, pcbnew.PAD_SHAPE_OVAL)
            pads[1].SetSize(pcbnew.F_Cu, point((1.7, 1.2)))
            fp.SetLocalClearance(iu(0.2))
        io().FootprintSave(out, fp)
    with open(os.path.join(folder, "fp-lib-table"), "w") as f:
        f.write("(fp_lib_table\n\t(version 7)\n" + "\n".join(rows) + "\n)\n")


def update(outdir):
    home = os.environ.get("KICAD_CONFIG_HOME") or os.path.expanduser("~/.config/kicad")
    for n, options in enumerate(UPDATE_CASES):
        folder = os.path.join(outdir, f"update-{n}")
        if os.path.exists(folder):
            shutil.rmtree(folder)
        update_board(folder)
        with tempfile.TemporaryDirectory() as tmp:
            share = os.path.join(tmp, "share")
            plugins = os.path.join(share, "kicad", "10.0", "scripting", "plugins")
            os.makedirs(plugins)
            with open(os.path.join(plugins, "jspice_update.py"), "w") as f:
                f.write(UPDATE_PLUGIN)
            config = os.path.join(tmp, "config")
            shutil.copytree(home, config, ignore=shutil.ignore_patterns("*.lck"))
            job = {"options": options, "out": os.path.join(tmp, "out.json"),
                   "save": os.path.join(folder, "board-updated.kicad_pcb")}
            with open(os.path.join(tmp, "job.json"), "w") as f:
                json.dump(job, f)
            env = dict(os.environ, XDG_DATA_HOME=share, KICAD_CONFIG_HOME=config,
                       JSPICE_UPDATE_JOB=os.path.join(tmp, "job.json"))
            run = subprocess.run(["xvfb-run", "-a", "-s", "-screen 0 2560x1600x24", "pcbnew", "board.kicad_pcb"],
                                 cwd=folder, env=env, capture_output=True, text=True, timeout=900)
            done = json.load(open(job["out"])) if os.path.exists(job["out"]) else {"error": run.stderr[-2000:]}
        if "error" in done:
            sys.exit(f"{folder}: {done['error']}")
        # (the editor's locks, left as the plugin ends it, and the project files its save wrote)
        for f in os.listdir(folder):
            if f.endswith(".lck") or f in ("board-updated.kicad_pro", "board-updated.kicad_prl"):
                os.remove(os.path.join(folder, f))
        with open(os.path.join(folder, "update.json"), "w") as f:
            json.dump(done, f, indent=1, sort_keys=True)
        print(folder, done.get("report", "")[:400])


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "roundtrip":
        roundtrip(sys.argv[2])
    elif cmd == "all":
        all_stock(sys.argv[2])
    elif cmd == "edits":
        edits(sys.argv[2])
    elif cmd == "boardsave":
        boardsave(sys.argv[2], sys.argv[3:])
    elif cmd == "readback":
        readback(sys.argv[2], sys.argv[3])
    elif cmd == "checks":
        checks(sys.argv[2])
    elif cmd == "update":
        update(sys.argv[2])
    else:
        sys.exit(__doc__)
