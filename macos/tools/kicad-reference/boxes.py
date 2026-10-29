#!/usr/bin/env python3
"""What KiCad's box selection takes on boards, for checking the port's (KiCadKit's KiCadBoardPicture.items(in:touching:))
against: rectangles drawn on each board, through KiCad's pcbnew Python module, and for each the tracks, arcs, vias and
footprints whose HitTest( BOX2I, aContained ) is true with aContained (a box drawn left to right, taking what is
wholly in it) and without (drawn right to left, taking what it touches), as PCB_SELECTION_TOOL::SelectMultiple asks
them; written next to the board as BOARD.boxes (JSON), the items by their uuids. A third of the rectangles are
anywhere on the board, of any size; the others are round an item's box (a track's, a via's, a footprint's or one of
its pads' or drawings'), each side moved in or out by up to 0.6 mm, to come near what it takes or leaves.

    boxes.py BOARD.kicad_pcb...
"""

import json
import random
import sys
import zlib

import pcbnew

MM = 1_000_000


def box(x0, y0, x1, y1):
    return pcbnew.BOX2I(pcbnew.VECTOR2I(int(x0), int(y0)), pcbnew.VECTOR2L(int(x1 - x0), int(y1 - y0)))


def write(path):
    board = pcbnew.LoadBoard(path)
    tracks = list(board.GetTracks())
    footprints = list(board.GetFootprints())
    items = [(t.m_Uuid.AsString(), t) for t in tracks] + [(f.m_Uuid.AsString(), f) for f in footprints]
    near = [t.GetBoundingBox() for t in tracks] + [f.GetBoundingBox(False) for f in footprints]
    for f in footprints:
        near += [p.GetBoundingBox() for p in f.Pads()]
        near += [d.GetBoundingBox() for d in f.GraphicalItems() if d.GetClass() != "PCB_TEXT"]
    whole = board.GetBoundingBox()
    rng = random.Random(zlib.crc32(path.split("/")[-1].encode()))
    boxes = []
    for k in range(160):
        if k % 3 == 0 or not near:
            x0, x1 = sorted(rng.randint(whole.GetLeft(), whole.GetRight()) for _ in range(2))
            y0, y1 = sorted(rng.randint(whole.GetTop(), whole.GetBottom()) for _ in range(2))
        else:
            b = rng.choice(near)
            d = int(0.6 * MM)
            x0, x1 = b.GetLeft() + rng.randint(-d, d), b.GetRight() + rng.randint(-d, d)
            y0, y1 = b.GetTop() + rng.randint(-d, d), b.GetBottom() + rng.randint(-d, d)
            x0, x1 = sorted((x0, x1))
            y0, y1 = sorted((y0, y1))
        r = box(x0, y0, x1, y1)
        boxes.append({"box": [x0, y0, x1, y1],
                      "inside": sorted(u for u, i in items if i.HitTest(r, True, 0)),
                      "touching": sorted(u for u, i in items if i.HitTest(r, False, 0))})
    with open(path[: -len(".kicad_pcb")] + ".boxes", "w") as out:
        json.dump({"boxes": boxes}, out, indent=0)
        out.write("\n")


if __name__ == "__main__":
    for path in sys.argv[1:]:
        write(path)
