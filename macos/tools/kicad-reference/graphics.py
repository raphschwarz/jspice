#!/usr/bin/env python3
"""Boards' graphics and dimensions as KiCad reads them, for checking what the port draws and edits (KiCadRouter's
GraphicTool, ShapePointEditor, DimensionTool and BoardEditing's addShape, addDimension, setShape, addCorner,
removeCorner, moveDrawings, rotateTexts and removeDrawings) against: through KiCad's pcbnew module (each board with its
project beside it), each of the board's own PCB_SHAPEs (its kind, start, end, an arc's middle and centre as KiCad has
them once read, a circle's centre and radius, a rectangle's corner radius, a polygon's corners, its pen's width and line
style, whether it is filled, its layer), beside what KiCad's drawing tools give a new graphic on that layer
(BOARD_DESIGN_SETTINGS::GetLineThickness; a polygon filled but on Edge.Cuts and the courtyards); and each dimension
(PCB_DIMENSION_BASE: its kind, start, end, height, orientation, leader length, the text Update made and where it put
it, at what angle, its size, pen, italic and mirroring, what it measured, and the lines GetShapes holds: segments by
their ends, circles by centre and radius), with the board's dimension defaults (BOARD_DESIGN_SETTINGS' m_Dimension...);
and each of these as KiCad writes it again once it has read it (pcbnew.SaveBoard: its text, by its id). JSON on
standard output, the boards by their paths.

    graphics.py BOARD.kicad_pcb...
    graphics.py --transform OPS.json BOARD.kicad_pcb
        the board's items of OPS (JSON: each {"uuid", "move": [dx, dy]} or {"uuid", "rotate": degrees, "center":
        [x, y] or null}, nanometres) moved and turned as KiCad's Move and Rotate do (BOARD_ITEM::Move, Rotate; a
        rotation of no centre about the one EDIT_TOOL::Rotate takes for an item selected alone: a rectangle's or
        polygon's GetCenter, another's GetPosition), one after another; then read as above.
"""

import json
import os
import re
import sys
import tempfile

import pcbnew


def xy(p):
    return [p.x, p.y]


SHAPES = {pcbnew.SHAPE_T_SEGMENT: "segment", pcbnew.SHAPE_T_RECTANGLE: "rectangle", pcbnew.SHAPE_T_ARC: "arc",
          pcbnew.SHAPE_T_CIRCLE: "circle", pcbnew.SHAPE_T_POLY: "polygon", pcbnew.SHAPE_T_BEZIER: "bezier"}

DIMENSIONS = {"PCB_DIM_ALIGNED": "aligned", "PCB_DIM_ORTHOGONAL": "orthogonal", "PCB_DIM_LEADER": "leader",
              "PCB_DIM_CENTER": "center", "PCB_DIM_RADIAL": "radial"}


def shape(item, bds):
    layer = item.GetLayer()
    kind = SHAPES.get(item.GetShape(), str(item.GetShape()))
    out = {"uuid": item.m_Uuid.AsString(), "kind": kind, "layer": pcbnew.LSET.Name(layer),
           "width": item.GetWidth(), "filled": item.IsSolidFill(),
           "expected": {"width": bds.GetLineThickness(layer),
                        "filled": layer not in (pcbnew.Edge_Cuts, pcbnew.F_CrtYd, pcbnew.B_CrtYd)}}
    if kind in ("segment", "rectangle"):
        out.update(start=xy(item.GetStart()), end=xy(item.GetEnd()))
    if kind == "rectangle":
        out["radius"] = item.GetCornerRadius()
    if kind == "arc":
        out.update(start=xy(item.GetStart()), end=xy(item.GetEnd()), mid=xy(item.GetArcMid()),
                   center=xy(item.GetCenter()), radius=item.GetRadius())
    if kind == "circle":
        out.update(center=xy(item.GetCenter()), end=xy(item.GetEnd()), radius=item.GetRadius())
    if kind == "polygon":
        poly = item.GetPolyShape()
        out["outlines"] = poly.OutlineCount()
        chain = poly.Outline(0)
        out["points"] = [xy(chain.CPoint(i)) for i in range(chain.PointCount())]
        out["arcs"] = chain.ArcCount()
    return out


def dimension(item):
    cls = item.GetClass()
    dim = getattr(pcbnew, "Cast_to_" + cls)(item)
    kind = DIMENSIONS[cls]
    out = {"uuid": dim.m_Uuid.AsString(), "kind": kind, "layer": pcbnew.LSET.Name(dim.GetLayer()),
           "start": xy(dim.GetStart()), "end": xy(dim.GetEnd()), "text": dim.GetText(),
           "textPos": xy(dim.GetTextPos()), "textAngle": dim.GetTextAngleDegrees(),
           "textSize": [dim.GetTextWidth(), dim.GetTextHeight()], "textThickness": dim.GetTextThickness(),
           "italic": dim.IsItalic(), "bold": dim.IsBold(), "mirrored": dim.IsMirrored(),
           "measured": dim.GetMeasuredValue(), "lineThickness": dim.GetLineThickness(),
           "arrowLength": dim.GetArrowLength(), "extensionOffset": dim.GetExtensionOffset(),
           "unitsMode": int(dim.GetUnitsMode()), "unitsFormat": int(dim.GetUnitsFormat()),
           "precision": int(dim.GetPrecision()), "suppressZeroes": dim.GetSuppressZeroes(),
           "textPosition": int(dim.GetTextPositionMode()), "keepAligned": dim.GetKeepTextAligned(),
           "prefix": dim.GetPrefix(), "suffix": dim.GetSuffix()}
    if kind in ("aligned", "orthogonal"):
        out["height"] = dim.GetHeight()
        out["extensionHeight"] = dim.GetExtensionHeight()
        out["crossbar"] = [xy(dim.GetCrossbarStart()), xy(dim.GetCrossbarEnd())]
    if kind == "orthogonal":
        out["orientation"] = int(dim.GetOrientation())
    if kind == "radial":
        out["leaderLength"] = dim.GetLeaderLength()
    if kind == "leader":
        out["textFrame"] = int(dim.GetTextBorder())
    shapes = []
    for s in dim.GetShapes():
        if s.Type() == pcbnew.SH_SEGMENT:
            seg = pcbnew.Cast_to_SHAPE_SEGMENT(s).GetSeg()
            shapes.append(["segment", xy(seg.A), xy(seg.B)])
        elif s.Type() == pcbnew.SH_CIRCLE:
            c = pcbnew.Cast_to_SHAPE_CIRCLE(s)
            shapes.append(["circle", xy(c.GetCenter()), c.GetRadius()])
        else:
            shapes.append(["other", int(s.Type())])
    out["shapes"] = shapes
    return out


def items(text):
    """The board's own items as a board's text has them, each by its id (the first uuid in it): its graphics, texts
    and dimensions"""
    out = {}
    depth, start, quoted, i = 0, None, False, 0
    while i < len(text):
        ch = text[i]
        if quoted:
            if ch == "\\":
                i += 1
            elif ch == '"':
                quoted = False
        elif ch == '"':
            quoted = True
        elif ch == "(":
            depth += 1
            if depth == 2:
                start = i
        elif ch == ")":
            if depth == 2 and start is not None:
                item = text[start:i + 1]
                if re.match(r"\((gr_|dimension)", item):
                    m = re.search(r'\(uuid "([^"]+)"\)', item)
                    if m:
                        out[m.group(1)] = item
            depth -= 1
        i += 1
    return out


def saved(board):
    """The board as KiCad writes it once it has read it (pcbnew.SaveBoard), its items by their ids"""
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "saved.kicad_pcb")
        pcbnew.SaveBoard(path, board)
        return items(open(path).read())


def read(path):
    board = pcbnew.LoadBoard(path)
    bds = board.GetDesignSettings()
    shapes, dims = [], []
    for item in board.GetDrawings():
        cls = item.GetClass()
        if cls == "PCB_SHAPE":
            shapes.append(shape(pcbnew.Cast_to_PCB_SHAPE(item), bds))
        elif cls in DIMENSIONS:
            dims.append(dimension(item))
    defaults = {"unitsMode": int(bds.m_DimensionUnitsMode), "precision": int(bds.m_DimensionPrecision),
                "unitsFormat": int(bds.m_DimensionUnitsFormat), "suppressZeroes": bds.m_DimensionSuppressZeroes,
                "textPosition": int(bds.m_DimensionTextPosition), "keepAligned": bds.m_DimensionKeepTextAligned,
                "arrowLength": bds.m_DimensionArrowLength, "extensionOffset": bds.m_DimensionExtensionOffset}
    widths = {name: bds.GetLineThickness(layer) for name, layer in
              (("F.SilkS", pcbnew.F_SilkS), ("F.Cu", pcbnew.F_Cu), ("Edge.Cuts", pcbnew.Edge_Cuts),
               ("F.CrtYd", pcbnew.F_CrtYd), ("F.Fab", pcbnew.F_Fab), ("Dwgs.User", pcbnew.Dwgs_User))}
    return {"shapes": shapes, "dimensions": dims, "defaults": defaults, "widths": widths,
            "userUnits": int(board.GetUserUnits()), "saved": saved(board)}


def transform(ops, path):
    board = pcbnew.LoadBoard(path)
    found = {item.m_Uuid.AsString(): item for item in board.GetDrawings()}
    for op in ops:
        item = found[op["uuid"]]
        cls = item.GetClass()
        item = getattr(pcbnew, "Cast_to_" + cls)(item) if hasattr(pcbnew, "Cast_to_" + cls) else item
        if "move" in op:
            item.Move(pcbnew.VECTOR2I(*op["move"]))
        else:
            if op.get("center") is not None:
                c = pcbnew.VECTOR2I(*op["center"])
            elif cls == "PCB_SHAPE" and item.GetShape() in (pcbnew.SHAPE_T_RECTANGLE, pcbnew.SHAPE_T_POLY):
                c = item.GetCenter()
            else:
                c = item.GetPosition()
            item.Rotate(c, pcbnew.EDA_ANGLE(op["rotate"], pcbnew.DEGREES_T))
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, os.path.basename(path))
        pcbnew.SaveBoard(out, board)
        # (the items as KiCad writes them once moved and turned: a board read again has its rectangles normalized)
        done = read(out)
        done["saved"] = items(open(out).read())
        return done


if __name__ == "__main__":
    if sys.argv[1] == "--transform":
        json.dump({sys.argv[3]: transform(json.load(open(sys.argv[2])), sys.argv[3])}, sys.stdout)
    else:
        json.dump({path: read(path) for path in sys.argv[1:]}, sys.stdout)
