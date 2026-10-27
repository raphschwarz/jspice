#!/usr/bin/env python3
"""KiCad's texts of boards, for checking the port's (KiCadRouter's BoardWorld.textStrokes) against: each text's and
field's shape as KiCad's DRC takes it (PCB_TEXT::GetEffectiveShape: the strokes of the KiCad font, each a segment of
the text's pen width), through KiCad's pcbnew Python module, with its text box (EDA_TEXT::GetTextBox) and bounding
box (PCB_TEXT::GetBoundingBox), the text it shows and whether it is shown, written next to the board as BOARD.texts
(JSON; named so that a folder's .json files are its boards' scenes only), the texts by their uuids: the board's own
texts, and its footprints' fields and texts.

    texts.py BOARD.kicad_pcb...

With --draw, a board of texts made to take KiCad's text drawing down the ways random boards do not, saved and then
its texts written as above: every justification, mirrored or not, at angles on and off the axes; several lines,
with their spacing changed; bold, italic, the pen width worked out or clamped; overbars, subscripts, superscripts,
links, tabs, escaped characters, characters the font does not have, empty and blank texts; texts too small or
stretched; footprints turned and flipped, their fields and texts kept upright or not, showing ${REFERENCE} and
the like, some hidden; and a knockout text and one in another font, which KiCad does not make of strokes
(Tests/KiCadRouterTests/Fixtures/texts/drawn.kicad_pcb is one).

    texts.py --draw OUT.kicad_pcb
"""

import json
import os
import re
import sys

import pcbnew

MM = 1_000_000

SEGMENT = re.compile(r"SHAPE_SEGMENT\( VECTOR2I\( (-?\d+), (-?\d+)\), VECTOR2I\( (-?\d+), (-?\d+)\), (-?\d+)\);")


def box(b):
    return [b.GetX(), b.GetY(), b.GetWidth(), b.GetHeight()]


def text(t, kind):
    shape = t.GetEffectiveShape(t.GetLayer()).Cast()
    out = {
        "kind": kind,
        "text": t.GetText(),
        "shown": t.GetShownText(True),
        "visible": t.IsVisible(),
        "layer": t.GetLayerName(),
        "penWidth": t.GetEffectiveTextPenWidth(),
        "textBox": box(t.GetTextBox(None)),
        "boundingBox": box(t.GetBoundingBox()),
        "drawRotation": t.GetDrawRotation().AsDegrees(),
        "font": t.GetFontName(),
        "knockout": t.IsKnockout(),
    }
    if isinstance(shape, pcbnew.SHAPE_COMPOUND):
        formatted = shape.Format()
        segments = [[int(g) for g in m.groups()] for m in SEGMENT.finditer(formatted)]
        if formatted.count("SHAPE_") == len(segments):
            out["segments"] = [s[:4] for s in segments]
            out["widths"] = sorted({s[4] for s in segments})
        else:
            out["shape"] = "compound"
    else:
        out["shape"] = type(shape).__name__
    return out


def write(board):
    b = pcbnew.LoadBoard(board)
    out = {}
    for d in b.Drawings():
        if d.Type() == pcbnew.PCB_TEXT_T:
            out[d.m_Uuid.AsString()] = text(d, "board")
    for fp in b.GetFootprints():
        for f in fp.GetFields():
            out[f.m_Uuid.AsString()] = text(f, "field")
        for d in fp.GraphicalItems():
            if d.Type() == pcbnew.PCB_TEXT_T:
                out[d.m_Uuid.AsString()] = text(d, "footprint")
    with open(os.path.splitext(board)[0] + ".texts", "w") as f:
        json.dump(out, f, sort_keys=True, separators=(",", ":"))
        f.write("\n")


# --- drawn texts

H = {"L": pcbnew.GR_TEXT_H_ALIGN_LEFT, "C": pcbnew.GR_TEXT_H_ALIGN_CENTER, "R": pcbnew.GR_TEXT_H_ALIGN_RIGHT}
V = {"T": pcbnew.GR_TEXT_V_ALIGN_TOP, "C": pcbnew.GR_TEXT_V_ALIGN_CENTER, "B": pcbnew.GR_TEXT_V_ALIGN_BOTTOM}

STRINGS = [
    "KiCad", "Ag|jy", "~{OVER}bar", "x^{2}_{i} ~{a_{b}c}", "~{nested ^{sup _{sub}}}", "http://example.com/a b",
    "tab\there\tand\tthere", "\tlead tab", "a{slash}b{dblquote}c{brace}", "~{} ^{} _{}", "~{unterminated", "}{~{",
    "Ünïcødé Ωμ €", "中文字", "emoji \U0001F600 here", "  ", " lead", "trail ", "", "x", "~", "{", "$", "a~b^c_d",
    "a${}b", "W" * 30,
]


def add_text(board, parent, s, at, size=(1.0, 1.0), thickness=0.15, angle=0.0, h="C", v="C", mirror=False, bold=False,
             italic=False, spacing=1.0, layer=pcbnew.F_SilkS, upright=True, hidden=False, knockout=False, face=None):
    t = pcbnew.PCB_TEXT(parent)
    t.SetText(s)
    t.SetLayer(layer)
    t.SetTextSize(pcbnew.VECTOR2I(int(round(size[0] * MM)), int(round(size[1] * MM))))
    t.SetTextThickness(int(round(thickness * MM)))
    t.SetPosition(pcbnew.VECTOR2I(int(round(at[0] * MM)), int(round(at[1] * MM))))
    t.SetTextAngle(pcbnew.EDA_ANGLE(angle, pcbnew.DEGREES_T))
    t.SetHorizJustify(H[h])
    t.SetVertJustify(V[v])
    t.SetMirrored(mirror)
    t.SetBoldFlag(bold)
    t.SetItalicFlag(italic)
    t.SetLineSpacing(spacing)
    t.SetIsKnockout(knockout)
    if face:
        t.SetFontProp(face)
    if parent is not board:
        t.SetKeepUpright(upright)
        t.SetVisible(not hidden)
    parent.Add(t)
    return t


def draw(path):
    board = pcbnew.NewBoard(path)
    x0, y0 = 20.0, 20.0
    # justifications, mirrored or not, at angles on and off the axes
    for i, angle in enumerate([0, 90, 180, 270, 30, 200.5, 333.3]):
        for j, (h, v) in enumerate((h, v) for h in "LCR" for v in "TCB"):
            for k, mirror in enumerate([False, True]):
                add_text(board, board, "Hj" if (i + j + k) % 3 else "Tx 1", (x0 + j * 12 + k * 6, y0 + i * 8), angle=angle,
                         h=h, v=v, mirror=mirror, layer=pcbnew.B_SilkS if mirror else pcbnew.F_SilkS)
    y = y0 + 90
    # strings
    for i, s in enumerate(STRINGS):
        add_text(board, board, s, (x0 + (i % 4) * 40, y + (i // 4) * 6), h="L", angle=[0, 15, 90][i % 3])
    y += 50
    # several lines
    for i, (s, spacing) in enumerate([("one\ntwo\nthree", 1.0), ("one\ntwo", 1.5), ("a\n\nb\n", 0.8),
                                      ("\nstarts empty", 1.0), ("x^{2}\n~{y}\nz_{3}", 1.25), ("\n", 1.0)]):
        for j, (h, v) in enumerate([("L", "T"), ("C", "C"), ("R", "B"), ("L", "B")]):
            add_text(board, board, s, (x0 + j * 25, y + i * 15), h=h, v=v, spacing=spacing, angle=[0, 90, 22.5, 180][j],
                     mirror=j == 3)
    y += 95
    # pen widths, bold and italic, sizes
    for i, (size, thickness, bold, italic) in enumerate([
            ((1, 1), 0, False, False), ((1, 1), 0, True, False), ((1, 1), 0.000001, False, False),
            ((1, 1), 0.5, False, False), ((1.5, 1.5), 0.3, True, True), ((1, 1), 0.15, False, True),
            ((2, 0.8), 0.12, False, False), ((0.5, 2.5), 0, True, True), ((0.0001, 0.0001), 0, False, False),
            ((1.27, 1.27), 0.2032, True, False), ((3.333, 2.111), 0.333, False, True), ((0.8, 0.8), 0.25, False, False)]):
        for j, angle in enumerate([0, 30, 270]):
            add_text(board, board, "Bold~{IT}" if bold else "plain^{2}", (x0 + j * 30, y + i * 6), size=size,
                     thickness=thickness, bold=bold, italic=italic, angle=angle, h="R" if j == 1 else "C",
                     v="T" if j == 2 else "C")
    y += 80
    # unsupported: knockout, an outline font
    add_text(board, board, "KNOCKOUT", (x0, y), knockout=True)
    add_text(board, board, "Outline", (x0 + 30, y), face="DejaVu Sans")
    y += 10
    # footprints turned and flipped, their fields and texts
    n = 0
    for flipped in [False, True]:
        for i, angle in enumerate([0, 90, 180, 270, 135, -30, 33.3, 179.9]):
            n += 1
            fp = pcbnew.FOOTPRINT(board)
            at = (x0 + i * 16, y + (20 if flipped else 0))
            fp.SetPosition(pcbnew.VECTOR2I(int(at[0] * MM), int(at[1] * MM)))
            fp.SetFPIDAsString(f"L{n % 3}:N{n}" if n % 4 else f"F{n}")
            board.Add(fp)
            fp.SetReference(f"U{n}")
            fp.SetValue(f"V{n}~{{X}}" if n % 2 else f"{n}k")
            ref, val = fp.Reference(), fp.Value()
            ref.SetPosition(pcbnew.VECTOR2I(int(at[0] * MM), int((at[1] - 2) * MM)))
            ref.SetTextAngle(pcbnew.EDA_ANGLE([0, 90, 180, 270, 135][i % 5], pcbnew.DEGREES_T))
            ref.SetHorizJustify(H["LCR"[i % 3]])
            ref.SetTextThickness(int(0.15 * MM))
            ref.SetTextSize(pcbnew.VECTOR2I(MM, MM))
            val.SetPosition(pcbnew.VECTOR2I(int(at[0] * MM), int((at[1] + 2) * MM)))
            val.SetVertJustify(V["TCB"[i % 3]])
            val.SetKeepUpright(i % 2 == 0)
            val.SetTextAngle(pcbnew.EDA_ANGLE([200, 0, 91, 300][i % 4], pcbnew.DEGREES_T))
            if i % 3 == 0:
                val.SetBoldFlag(True)
            for j, s in enumerate(["${REFERENCE}", "${VALUE}-${FOOTPRINT_NAME}", "${FOOTPRINT_LIBRARY}:${Value}",
                                   "a\nb"]):
                add_text(board, fp, s, (at[0] + 3, at[1] - 3 + j * 2), h="LRC"[j % 3], angle=[0, 120, 250, 15][j],
                         upright=(i + j) % 2 == 0, hidden=j == 3 and i % 4 == 0, italic=j == 2,
                         layer=pcbnew.F_Fab if j == 1 else pcbnew.F_SilkS)
            user = pcbnew.PCB_FIELD(fp, pcbnew.FIELD_T_USER, "Extra")
            user.SetText("F${REFERENCE}")
            user.SetLayer(pcbnew.F_Fab)
            user.SetTextThickness(int(0.1 * MM))
            user.SetPosition(pcbnew.VECTOR2I(int((at[0] - 3) * MM), int((at[1] + 4) * MM)))
            user.SetTextAngle(pcbnew.EDA_ANGLE(angle + 100, pcbnew.DEGREES_T))
            user.SetVisible(i % 3 != 1)
            fp.Add(user)
            if angle:
                fp.SetOrientationDegrees(angle)
            if flipped:
                fp.Flip(fp.GetPosition(), pcbnew.FLIP_DIRECTION_TOP_BOTTOM if i % 2 else pcbnew.FLIP_DIRECTION_LEFT_RIGHT)
    pcbnew.SaveBoard(path, board)


def main():
    args = sys.argv[1:]
    if args and args[0] == "--draw":
        draw(args[1])
        write(args[1])
        return
    for board in args:
        write(board)


if __name__ == "__main__":
    main()
