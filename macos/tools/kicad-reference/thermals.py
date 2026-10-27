#!/usr/bin/env python3
"""A board of thermal reliefs, for checking the port's (KiCadRouter's BoardDRC) starved thermals against KiCad's:
pads of a zone's net in its fill, filled by KiCad's own zone filler, their spokes cut off by tracks of other nets
and the board's edge, so that some have fewer than the board asks (three here, not KiCad's two), and the ways
KiCad's check goes round that: pads joined solidly or not at all (by the pad, by its footprint), a pad with a
thermal gap of its own, plated holes in a zone that relieves them only (thru_hole_only) beside surface pads it
joins solidly, spokes drawn by hand (a track, a copper drawing of the net), a custom pad with spoke templates of
its own, and pads with spokes into islands that touch nothing else; and around them, pads at random places among
random tracks. Saved through KiCad (which writes its project too); drc.py then writes kicad-cli's DRC of it.

    thermals.py OUT.kicad_pcb [SEED]
"""

import random
import sys

import pcbnew

MM = 1_000_000


def vec(x, y):
    return pcbnew.VECTOR2I(int(x), int(y))


def track(board, a, b, net, width=250_000, layer=pcbnew.F_Cu):
    t = pcbnew.PCB_TRACK(board)
    t.SetStart(vec(*a))
    t.SetEnd(vec(*b))
    t.SetWidth(width)
    t.SetLayer(layer)
    t.SetNet(net)
    board.Add(t)
    return t


def pad_fp(board, ref, x, y, net, size=(1_500_000, 1_000_000), shape=pcbnew.PAD_SHAPE_RECT, tht=False, angle=0):
    fp = pcbnew.FOOTPRINT(board)
    fp.SetReference(ref)
    pad = pcbnew.PAD(fp)
    pad.SetNumber("1")
    pad.SetShape(pcbnew.PADSTACK.ALL_LAYERS, shape)
    pad.SetSize(pcbnew.PADSTACK.ALL_LAYERS, vec(*size))
    if tht:
        pad.SetAttribute(pcbnew.PAD_ATTRIB_PTH)
        pad.SetDrillSize(vec(size[0] // 2, size[0] // 2))
        pad.SetLayerSet(pad.PTHMask())
    else:
        pad.SetAttribute(pcbnew.PAD_ATTRIB_SMD)
        pad.SetLayerSet(pad.SMDMask())
    fp.Add(pad)
    fp.SetPosition(vec(x, y))
    if angle:
        fp.SetOrientationDegrees(angle)
    board.Add(fp)
    pad.SetNet(net)
    return fp, pad


def zone(board, net, layer, x0, y0, x1, y1, connection=pcbnew.ZONE_CONNECTION_THERMAL, priority=0):
    z = pcbnew.ZONE(board)
    z.SetLayer(layer)
    z.SetNet(net)
    z.SetAssignedPriority(priority)
    z.SetPadConnection(connection)
    z.SetThermalReliefGap(500_000)
    z.SetThermalReliefSpokeWidth(400_000)
    poly = z.Outline()
    poly.NewOutline()
    for x, y in [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]:
        poly.Append(x, y)
    board.Add(z)
    return z


def main():
    out = sys.argv[1]
    rng = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 7)
    board = pcbnew.NewBoard(out)
    board.SetCopperLayerCount(2)
    board.GetDesignSettings().m_MinResolvedSpokes = 3
    x0, y0, x1, y1 = 100 * MM, 50 * MM, 170 * MM, 110 * MM
    for a, b in [((x0, y0), (x1, y0)), ((x1, y0), (x1, y1)), ((x1, y1), (x0, y1)), ((x0, y1), (x0, y0))]:
        s = pcbnew.PCB_SHAPE(board)
        s.SetShape(pcbnew.SHAPE_T_SEGMENT)
        s.SetLayer(pcbnew.Edge_Cuts)
        s.SetWidth(100_000)
        s.SetStart(vec(*a))
        s.SetEnd(vec(*b))
        board.Add(s)
    nets = {}
    for name in ["GND", "VCC", "SIG", "SIG2"]:
        n = pcbnew.NETINFO_ITEM(board, name)
        board.Add(n)
        nets[name] = n
    gnd, vcc, sig = nets["GND"], nets["VCC"], nets["SIG"]
    zone(board, gnd, pcbnew.F_Cu, x0 + MM, y0 + MM, x1 - MM, y1 - MM)
    zone(board, vcc, pcbnew.B_Cu, x0 + MM, y0 + MM, x1 - MM, y1 - MM, pcbnew.ZONE_CONNECTION_THT_THERMAL)

    def blocked(ref, x, y, sides, d=1_600_000, **kw):
        """A pad of the zone's net with tracks of another across its sides (of 'tblr'), `d` from its centre (far
        enough off for a strip of fill between, or not)"""
        fp, pad = pad_fp(board, ref, x, y, gnd, **kw)
        for s in sides:
            if s == "t":
                track(board, (x - 2 * MM, y - d), (x + 2 * MM, y - d), sig)
            if s == "b":
                track(board, (x - 2 * MM, y + d), (x + 2 * MM, y + d), sig)
            if s == "l":
                track(board, (x - d - 300_000, y - 2 * MM), (x - d - 300_000, y + 2 * MM), sig)
            if s == "r":
                track(board, (x + d + 300_000, y - 2 * MM), (x + d + 300_000, y + 2 * MM), sig)
        return fp, pad

    col = [x0 + 6 * MM + i * 6 * MM for i in range(10)]
    row = [y0 + 6 * MM + i * 7 * MM for i in range(8)]
    # four spokes, three, two, one
    blocked("U1", col[0], row[0], "")
    blocked("U2", col[1], row[0], "t")
    blocked("U3", col[2], row[0], "tb")
    blocked("U4", col[3], row[0], "tbl")
    # joined solidly or not at all: by the pad, by its footprint
    _, p = blocked("U5", col[4], row[0], "tb")
    p.SetLocalZoneConnection(pcbnew.ZONE_CONNECTION_FULL)
    fp, _ = blocked("U6", col[5], row[0], "tb")
    fp.SetLocalZoneConnection(pcbnew.ZONE_CONNECTION_NONE)
    fp, _ = blocked("U7", col[6], row[0], "tb")
    fp.SetLocalZoneConnection(pcbnew.ZONE_CONNECTION_THERMAL)
    # a thermal gap of the pad's own
    _, p = blocked("U8", col[7], row[0], "tb", d=1_100_000)
    p.SetThermalGap(300_000)
    _, p = blocked("U9", col[8], row[0], "tbl", d=1_100_000)
    p.SetThermalGap(700_000)
    _, p = blocked("U26", col[7], row[1], "t")
    p.SetThermalGap(300_000)
    _, p = blocked("U27", col[8], row[1], "t")
    p.SetThermalGap(700_000)
    # tracks near enough to cut the spokes off: two left, one, none
    blocked("U23", col[9], row[0], "tb", d=1_100_000)
    blocked("U24", col[9], row[1], "tbl", d=1_100_000)
    blocked("U25", col[9], row[2], "tblr", d=1_100_000)
    # turned, round, oval
    blocked("U10", col[0], row[1], "tb", angle=45)
    blocked("U11", col[1], row[1], "tb", shape=pcbnew.PAD_SHAPE_CIRCLE, size=(1_200_000, 1_200_000))
    blocked("U12", col[2], row[1], "t", shape=pcbnew.PAD_SHAPE_OVAL, size=(2_000_000, 1_000_000), angle=30)
    blocked("U13", col[3], row[1], "tb", shape=pcbnew.PAD_SHAPE_ROUNDRECT)
    # spokes drawn by hand: a track of the net from inside the pad out into the fill, a copper drawing
    fp, p = blocked("U14", col[4], row[1], "tb")
    track(board, (col[4], row[1]), (col[4] + 2_500_000, row[1] + 300_000), gnd, width=300_000)
    fp, p = blocked("U15", col[5], row[1], "tbl")
    s = pcbnew.PCB_SHAPE(board)
    s.SetShape(pcbnew.SHAPE_T_SEGMENT)
    s.SetLayer(pcbnew.F_Cu)
    s.SetWidth(300_000)
    s.SetStart(vec(col[5] + 200_000, row[1]))
    s.SetEnd(vec(col[5] + 2_800_000, row[1] - 400_000))
    s.SetNet(gnd)
    board.Add(s)
    # a via of the net beside a pad, a track ending in the pad but not in the fill
    fp, p = blocked("U16", col[6], row[1], "tbl")
    track(board, (col[6], row[1]), (col[6], row[1] - 1_550_000), gnd, width=200_000)
    # by the board's edge: the zone's own outline cuts spokes off
    blocked("U17", x0 + MM + 300_000, row[2], "")
    blocked("U18", col[3], y0 + MM + 200_000, "")
    blocked("U19", x1 - MM - 900_000, y1 - MM - 600_000, "t")
    # plated holes in the back zone (thermal reliefs for them only), surface pads in it joined solidly
    for i, sides in enumerate(["", "t", "tb", "tbl"]):
        fp, pad = pad_fp(board, f"H{i + 1}", col[i], row[3], vcc, size=(1_700_000, 1_700_000),
                         shape=pcbnew.PAD_SHAPE_CIRCLE, tht=True)
        for s in sides:
            d = 1_800_000
            a, b = {"t": ((-2 * MM, -d), (2 * MM, -d)), "b": ((-2 * MM, d), (2 * MM, d)),
                    "l": ((-d, -2 * MM), (-d, 2 * MM))}[s]
            track(board, (col[i] + a[0], row[3] + a[1]), (col[i] + b[0], row[3] + b[1]), sig, layer=pcbnew.B_Cu)
    fp, pad = pad_fp(board, "H5", col[4], row[3], vcc)
    fp.Flip(fp.GetPosition(), pcbnew.FLIP_DIRECTION_TOP_BOTTOM)
    track(board, (col[4] - 2 * MM, row[3] - 1_600_000), (col[4] + 2 * MM, row[3] - 1_600_000), sig, layer=pcbnew.B_Cu)
    track(board, (col[4] - 2 * MM, row[3] + 1_600_000), (col[4] + 2 * MM, row[3] + 1_600_000), sig, layer=pcbnew.B_Cu)
    # islands that touch the pad only: a pocket closed by tracks of another net round three sides and the pad on
    # the fourth, and the pad's other spokes some of them cut off
    for i, sides in enumerate(["", "t", "tb"]):
        x, y = col[5 + i], row[3]
        fp, p = pad_fp(board, f"U{20 + i}", x, y, gnd)
        r = x + 750_000 + 1_000_000
        track(board, (x + 500_000, y - 1_000_000), (r + 2 * MM, y - 1_000_000), sig, width=300_000)
        track(board, (x + 500_000, y + 1_000_000), (r + 2 * MM, y + 1_000_000), sig, width=300_000)
        track(board, (r + 2 * MM, y - 1_000_000), (r + 2 * MM, y + 1_000_000), sig, width=300_000)
        for s in sides:
            yy = y - 1_600_000 if s == "t" else y + 1_600_000
            track(board, (x - 2 * MM, yy), (x + 300_000, yy), sig)
    # a custom pad with spoke templates of its own (two of them), its spokes some cut off
    for i, sides in enumerate(["", "t", "tb"]):
        x, y = col[i], row[4]
        fp, p = pad_fp(board, f"C{i + 1}", x, y, gnd, size=(1_000_000, 1_000_000))
        p.SetShape(pcbnew.PADSTACK.ALL_LAYERS, pcbnew.PAD_SHAPE_CUSTOM)
        p.SetAnchorPadShape(pcbnew.PADSTACK.ALL_LAYERS, pcbnew.PAD_SHAPE_RECT)
        for a, b in [((0, 0), (0, -1_500_000)), ((0, 0), (1_500_000, 0))]:
            v = pcbnew.PCB_SHAPE(None, pcbnew.SHAPE_T_SEGMENT)
            v.SetStart(vec(*a))
            v.SetEnd(vec(*b))
            v.SetWidth(300_000)
            v.SetIsProxyItem(True)
            p.AddPrimitiveShape(pcbnew.F_Cu, v)
            v.thisown = False  # (the pad holds it now)
        for s in sides:
            yy = y - 1_600_000 if s == "t" else y + 1_600_000
            track(board, (x - 2 * MM, yy), (x + 2 * MM, yy), sig)
    # pads at random places among random tracks of other nets
    for i in range(30):
        x = rng.randint(x0 + 3 * MM, x1 - 3 * MM)
        y = rng.randint(row[5], y1 - 2 * MM)
        pad_fp(board, f"R{i + 1}", x, y, gnd, size=(rng.choice([800_000, 1_200_000, 1_600_000]),
                                                       rng.choice([600_000, 1_000_000])),
               shape=rng.choice([pcbnew.PAD_SHAPE_RECT, pcbnew.PAD_SHAPE_CIRCLE, pcbnew.PAD_SHAPE_OVAL]),
               angle=rng.choice([0, 0, 90, 45, 15]))
    for _ in range(25):
        a = (rng.randint(x0 + 2 * MM, x1 - 2 * MM), rng.randint(row[5] - MM, y1 - MM))
        b = (a[0] + rng.randint(-8, 8) * MM, a[1] + rng.randint(-3, 3) * MM)
        track(board, a, b, nets[rng.choice(["SIG", "SIG2"])], width=rng.choice([200_000, 250_000, 400_000]))
    board.BuildConnectivity()
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    pcbnew.SaveBoard(out, board)


if __name__ == "__main__":
    main()
