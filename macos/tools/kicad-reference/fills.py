#!/usr/bin/env python3
"""KiCad's zone fills of boards, for checking the port's (KiCadRouter's ZoneFiller) against: through KiCad's pcbnew
module, each board's zones (BOARD::Zones, not its footprints' own) filled by its ZONE_FILLER, as the GUI's Fill All
Zones and pcbnew.ZONE_FILLER(board).Fill(board.Zones()) fill them, and each zone's filled polygons on each of its
layers (each polygon's outline and holes, their points; whether it is an island kept by the zone's island removal
mode) written next to the board as BOARD.fills (JSON), the zones by their uuids. With --twice, each board filled a
second time from its first fill too, and any difference between the two said (KiCad's filler runs on threads).

    fills.py [--twice] BOARD.kicad_pcb...

With --draw, a board of zones taking KiCad's filler down the ways random boards do not, saved, its zones filled, and
then its fills written as above: thermal reliefs on pads of every shape (round, oval, rectangle, rounded and
chamfered rectangle, trapezoid, custom with and without spoke templates) turned to several angles, pads joined solid,
not at all and through-hole only by the zone, their footprint and themselves, pads of their own clearance, thermal
gap and spoke width and angle, zones of several priorities of one net and of others, keepouts of copper pours,
islands removed always, never and below an area, a zone too thin in places for its minimum width, the board's edge
with a cut-out and unplated holes, tracks, arc tracks, vias, texts and drawings of other nets in the zones, a
footprint's own zone, zones on several layers and on no copper, corner smoothing, and a hatched fill.

    fills.py --draw OUT.kicad_pcb
"""

import json
import math
import os
import sys

import pcbnew

MM = 1_000_000


def vec(x, y):
    return pcbnew.VECTOR2I(int(x), int(y))


def pts(chain):
    return [[chain.CPoint(k).x, chain.CPoint(k).y] for k in range(chain.PointCount())]


def fills(board):
    out = {}
    for z in board.Zones():
        if z.GetIsRuleArea():
            continue
        layers = {}
        for layer in z.GetLayerSet().Seq():
            if not z.HasFilledPolysForLayer(layer):
                continue
            p = z.GetFilledPolysList(layer)
            layers[board.GetStandardLayerName(layer)] = [
                {"polygon": [pts(p.Outline(i))] + [pts(p.CHole(i, j)) for j in range(p.HoleCount(i))],
                 "island": z.IsIsland(layer, i)} for i in range(p.OutlineCount())]
        out[z.m_Uuid.AsString()] = layers
    return out


def fill(board):
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())


def write(path, twice=False):
    board = pcbnew.LoadBoard(path)
    fill(board)
    first = fills(board)
    if twice:
        fill(board)
        second = fills(board)
        if second != first:
            print(f"{path}: filled twice, not the same:", [u for u in first if first[u] != second.get(u)])
    with open(os.path.splitext(path)[0] + ".fills", "w") as f:
        json.dump(first, f, separators=(",", ":"))
        f.write("\n")


def main():
    args = sys.argv[1:]
    if args and args[0] == "--draw":
        draw(args[1])
        write(args[1])
        return
    twice = bool(args) and args[0] == "--twice"
    for path in args[1:] if twice else args:
        write(path, twice)


def draw(path):
    raise SystemExit("--draw: not yet")


if __name__ == "__main__":
    main()
