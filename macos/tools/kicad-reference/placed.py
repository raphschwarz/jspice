#!/usr/bin/env python3
"""Boards' texts and footprints as KiCad reads them, for checking what the port places on its own (KiCadRouter's
BoardEditing.addText and addFootprint) against: through KiCad's pcbnew module (each board with its project beside it),
each of the board's own texts' words, layer, position, angle, size, pen width, bold, italic, kept upright, mirrored and
justification, with what KiCad's Add Text gives a new text on that layer as KiCad's own file of it reads back
(DRAWING_TOOL::PlaceText: the board's design settings' GetTextSize, GetTextThickness and GetTextItalic for it,
InferBold, mirrored on the back's layers, justified left and to the baseline; kept upright as GetTextUpright says, which
a board's own text does not keep in the file: PCB_IO_KICAD_SEXPR writes it for a footprint's texts only, and the
parser reads a board's as not kept upright); and each footprint's reference, value, library id, position, angle,
side, attributes and its pads' nets. JSON on standard output, the boards by their paths.

    placed.py BOARD.kicad_pcb...
"""

import json
import sys

import pcbnew


def read(path):
    board = pcbnew.LoadBoard(path)
    bds = board.GetDesignSettings()
    texts = []
    for item in board.GetDrawings():
        if item.GetClass() != "PCB_TEXT":
            continue
        layer = item.GetLayer()
        size = bds.GetTextSize(layer)
        pen = bds.GetTextThickness(layer)
        smaller = min(size.x, size.y)
        texts.append({
            "uuid": item.m_Uuid.AsString(), "text": item.GetText(), "layer": pcbnew.LSET.Name(layer),
            "position": [item.GetTextPos().x, item.GetTextPos().y], "angle": item.GetTextAngleDegrees(),
            "size": [item.GetTextWidth(), item.GetTextHeight()], "thickness": item.GetTextThickness(),
            "bold": item.IsBold(), "italic": item.IsItalic(), "upright": item.IsKeepUpright(), "mirrored": item.IsMirrored(),
            "justify": [int(item.GetHorizJustify()), int(item.GetVertJustify())],
            "expected": {
                "size": [size.x, size.y], "thickness": pen,
                "bold": abs(pen - round(smaller / 5.0)) < abs(pen - round(smaller / 8.0)),
                "italic": bds.GetTextItalic(layer), "upright": False, "mirrored": board.IsBackLayer(layer),
                "justify": [int(pcbnew.GR_TEXT_H_ALIGN_LEFT), int(pcbnew.GR_TEXT_V_ALIGN_BOTTOM)],
            },
        })
    footprints = []
    for fp in board.GetFootprints():
        footprints.append({
            "uuid": fp.m_Uuid.AsString(), "reference": fp.GetReference(), "value": fp.GetValue(),
            "lib_id": fp.GetFPIDAsString(), "position": [fp.GetPosition().x, fp.GetPosition().y],
            "angle": fp.GetOrientationDegrees(), "layer": pcbnew.LSET.Name(fp.GetLayer()),
            "board_only": fp.IsBoardOnly(), "pads": len(fp.Pads()), "nets": sorted({p.GetNetname() for p in fp.Pads()}),
        })
    return {"texts": texts, "footprints": footprints}


if __name__ == "__main__":
    json.dump({path: read(path) for path in sys.argv[1:]}, sys.stdout)
