#!/usr/bin/env python3
"""Boards of silkscreen for checking the port's (KiCadRouter's BoardDRC) silkscreen checks against KiCad's
(silk_overlap, silk_over_copper, silk_edge_clearance): silkscreen of every kind (drawings of each shape, filled or
not, board texts, footprints' fields shown and hidden and their texts, a zone, a pad on the silkscreen) over pads,
vias tented and not, tracks and arcs with solder mask of their own, drawings, texts and a zone on the mask layers,
an unplated slot; against itself (drawings of one footprint, and the board's own, left out), outside the board,
across its edges, a rounded corner, a cut-out, a margin, and over the board's edge without touching it, as a text of
strokes either side does. Saved through KiCad (which writes its project too); drc.py then writes kicad-cli's DRC of
it.

    silk.py OUT.kicad_pcb [--clearance MM] [--web MM] [--random SEED]

--clearance gives the silkscreen a clearance (min_silk_clearance; KiCad's reports then say how near each is); --web a
solder mask minimum web width, which has KiCad test silkscreen against the whole board's mask instead; --random adds
random silkscreen, pads, vias and tracks to the drawn board.
"""

import random
import sys

import pcbnew

MM = 1_000_000


def vec(x, y):
    return pcbnew.VECTOR2I(int(round(x * MM)), int(round(y * MM)))


class Board:
    def __init__(self, path):
        self.path = path
        self.board = pcbnew.NewBoard(path)
        self.board.SetCopperLayerCount(2)
        self.nets = {}
        self.n = 0

    def net(self, name):
        if name not in self.nets:
            n = pcbnew.NETINFO_ITEM(self.board, name)
            self.board.Add(n)
            self.nets[name] = n
        return self.nets[name]

    def shape(self, kind, layer, pts, width=0.12, filled=False, parent=None, radius=0.0):
        parent = parent or self.board
        if parent is not self.board:
            # (a footprint's drawing given where it is in the footprint, placed with it before it is turned)
            o = parent.GetPosition()
            pts = [(x + o.x / MM, y + o.y / MM) for x, y in pts]
        s = pcbnew.PCB_SHAPE(parent)
        s.SetShape(kind)
        s.SetLayer(layer)
        s.SetWidth(int(round(width * MM)))
        if kind == pcbnew.SHAPE_T_SEGMENT or kind == pcbnew.SHAPE_T_RECTANGLE:
            s.SetStart(vec(*pts[0]))
            s.SetEnd(vec(*pts[1]))
            if radius:
                s.SetCornerRadius(int(round(radius * MM)))
        elif kind == pcbnew.SHAPE_T_CIRCLE:
            s.SetCenter(vec(*pts[0]))
            s.SetEnd(vec(*pts[1]))
        elif kind == pcbnew.SHAPE_T_ARC:
            s.SetArcGeometry(vec(*pts[0]), vec(*pts[1]), vec(*pts[2]))
        elif kind == pcbnew.SHAPE_T_POLY:
            s.SetPolyPoints([vec(*p) for p in pts])
        elif kind == pcbnew.SHAPE_T_BEZIER:
            s.SetStart(vec(*pts[0]))
            s.SetBezierC1(vec(*pts[1]))
            s.SetBezierC2(vec(*pts[2]))
            s.SetEnd(vec(*pts[3]))
            s.RebuildBezierToSegmentsPointsList(self.board.GetDesignSettings().m_MaxError)
        s.SetFilled(filled)
        parent.Add(s)
        return s

    def line(self, a, b, layer=pcbnew.F_SilkS, width=0.12, parent=None):
        return self.shape(pcbnew.SHAPE_T_SEGMENT, layer, [a, b], width, parent=parent)

    def text(self, s, at, layer=pcbnew.F_SilkS, size=1.0, thickness=0.15, angle=0.0, parent=None):
        parent = parent or self.board
        t = pcbnew.PCB_TEXT(parent)
        t.SetText(s)
        t.SetLayer(layer)
        t.SetTextSize(vec(size, size))
        t.SetTextThickness(int(round(thickness * MM)))
        t.SetPosition(vec(*at))
        t.SetTextAngle(pcbnew.EDA_ANGLE(angle, pcbnew.DEGREES_T))
        parent.Add(t)
        return t

    def footprint(self, at, ref=None, angle=0.0, back=False, ref_layer=None, ref_at=None):
        self.n += 1
        fp = pcbnew.FOOTPRINT(self.board)
        fp.SetPosition(vec(*at))
        self.board.Add(fp)
        fp.SetReference(ref or f"U{self.n}")
        fp.SetValue(f"V{self.n}")
        r = fp.Reference()
        r.SetLayer(ref_layer if ref_layer is not None else pcbnew.F_SilkS)
        r.SetPosition(vec(*(ref_at or (at[0], at[1] - 2.5))))
        r.SetTextSize(vec(1, 1))
        r.SetTextThickness(int(0.15 * MM))
        fp.Value().SetLayer(pcbnew.F_Fab)
        fp.Value().SetPosition(vec(at[0], at[1] + 2.5))
        fp._angle, fp._back = angle, back
        return fp

    def place(self, fp):
        if fp._angle:
            fp.SetOrientationDegrees(fp._angle)
        if fp._back:
            fp.Flip(fp.GetPosition(), pcbnew.FLIP_DIRECTION_TOP_BOTTOM)

    def pad(self, fp, at, size=(1.2, 0.8), shape=pcbnew.PAD_SHAPE_RECT, kind="smd", drill=None, number="1",
            net=None, layers=None, angle=0.0):
        p = pcbnew.PAD(fp)
        p.SetNumber(number)
        p.SetShape(pcbnew.PADSTACK.ALL_LAYERS, shape)
        p.SetSize(pcbnew.PADSTACK.ALL_LAYERS, vec(*size))
        if kind == "pth":
            p.SetAttribute(pcbnew.PAD_ATTRIB_PTH)
            p.SetDrillSize(vec(*(drill or (size[0] / 2, size[0] / 2))))
            p.SetLayerSet(p.PTHMask())
        elif kind == "npth":
            p.SetAttribute(pcbnew.PAD_ATTRIB_NPTH)
            d = drill or size
            p.SetDrillSize(vec(*d))
            if d[0] != d[1]:
                p.SetDrillShape(pcbnew.PAD_DRILL_SHAPE_OBLONG)
            p.SetLayerSet(p.UnplatedHoleMask())
        else:
            p.SetAttribute(pcbnew.PAD_ATTRIB_SMD)
            p.SetLayerSet(p.SMDMask())
        if layers is not None:
            ls = pcbnew.LSET()
            for l in layers:
                ls.AddLayer(l)
            p.SetLayerSet(ls)
        fp.Add(p)
        p.SetFPRelativePosition(vec(*at))
        if angle:
            p.SetFPRelativeOrientation(pcbnew.EDA_ANGLE(angle, pcbnew.DEGREES_T))
        if net:
            p.SetNet(self.net(net))
        return p

    def via(self, at, tented_front=True, tented_back=True, size=0.8, drill=0.4, net="GND"):
        v = pcbnew.PCB_VIA(self.board)
        v.SetPosition(vec(*at))
        v.SetWidth(int(size * MM))
        v.SetDrill(int(drill * MM))
        v.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu)
        v.SetFrontTentingMode(pcbnew.TENTING_MODE_TENTED if tented_front else pcbnew.TENTING_MODE_NOT_TENTED)
        v.SetBackTentingMode(pcbnew.TENTING_MODE_TENTED if tented_back else pcbnew.TENTING_MODE_NOT_TENTED)
        self.board.Add(v)
        v.SetNet(self.net(net))
        return v

    def track(self, a, b, layer=pcbnew.F_Cu, width=0.25, mask=False, margin=None, mid=None, net="SIG"):
        t = pcbnew.PCB_ARC(self.board) if mid else pcbnew.PCB_TRACK(self.board)
        t.SetStart(vec(*a))
        if mid:
            t.SetMid(vec(*mid))
        t.SetEnd(vec(*b))
        t.SetWidth(int(width * MM))
        t.SetLayer(layer)
        if mask:
            t.SetHasSolderMask(True)
        if margin is not None:
            t.SetLocalSolderMaskMargin(int(margin * MM))
        self.board.Add(t)
        t.SetNet(self.net(net))
        return t

    def zone(self, layer, pts, net=None):
        z = pcbnew.ZONE(self.board)
        z.SetLayer(layer)
        if net:
            z.SetNet(self.net(net))
        poly = z.Outline()
        poly.NewOutline()
        for x, y in pts:
            poly.Append(int(x * MM), int(y * MM))
        self.board.Add(z)
        return z


def draw(b, clearance, web, seed):
    board = b.board
    ds = board.GetDesignSettings()
    if clearance is not None:
        ds.m_SilkClearance = int(round(clearance * MM))
    if web is not None:
        ds.m_SolderMaskMinWidth = int(round(web * MM))
    E, M = pcbnew.Edge_Cuts, pcbnew.Margin
    F, B = pcbnew.F_SilkS, pcbnew.B_SilkS
    # the outline: sides, a rounded corner, a round cut-out; a margin inside it
    b.line((20, 20), (120, 20), E, 0.05)
    b.line((120, 20), (120, 80), E, 0.05)
    b.shape(pcbnew.SHAPE_T_ARC, E, [(120, 80), (117.0711, 87.0711), (110, 90)], 0.05)
    b.line((110, 90), (20, 90), E, 0.05)
    b.line((20, 90), (20, 20), E, 0.05)
    b.shape(pcbnew.SHAPE_T_CIRCLE, E, [(100, 40), (104, 40)], 0.05)
    b.shape(pcbnew.SHAPE_T_RECTANGLE, M, [(23, 23), (117, 87)], 0.1)

    # pads under silkscreen: lines, a text, an arc, a circle, rectangles (filled, rounded), a polygon, a curve
    fp = b.footprint((32, 32))
    for i, (shape, kind) in enumerate([(pcbnew.PAD_SHAPE_RECT, "smd"), (pcbnew.PAD_SHAPE_CIRCLE, "pth"),
                                       (pcbnew.PAD_SHAPE_OVAL, "pth"), (pcbnew.PAD_SHAPE_ROUNDRECT, "smd")]):
        b.pad(fp, (-3 + 2 * i, 0), size=(1.2, 1.6) if shape == pcbnew.PAD_SHAPE_OVAL else (1.2, 1.2), shape=shape,
              kind=kind, number=str(i + 1), net=f"N{i}")
    b.line((-4.2, -0.3), (2.6, 0.4), F, parent=fp)
    b.shape(pcbnew.SHAPE_T_ARC, F, [(-3.8, 1.4), (-2, 0.4), (-0.2, 1.4)], parent=fp)
    b.place(fp)
    fp = b.footprint((45, 32), angle=30)
    for i in range(4):
        b.pad(fp, (-3 + 2 * i, 0), size=(1.0, 1.4), number=str(i + 1), net="GND" if i % 2 else "SIG")
    b.shape(pcbnew.SHAPE_T_RECTANGLE, F, [(-3.6, -0.5), (-2.4, 0.5)], filled=True, parent=fp)
    b.shape(pcbnew.SHAPE_T_RECTANGLE, F, [(-1.8, -1.0), (0.4, 1.0)], radius=0.4, parent=fp)
    b.shape(pcbnew.SHAPE_T_CIRCLE, F, [(3, 0), (3.6, 0)], filled=True, parent=fp)
    b.shape(pcbnew.SHAPE_T_POLY, F, [(-4, 1.5), (4, 1.5), (0, 0.3), (-4, 1.5)], width=0.1, filled=True, parent=fp)
    b.shape(pcbnew.SHAPE_T_BEZIER, F, [(-4, -2), (-1, 1), (1, -3), (4, 0.2)], parent=fp)
    b.place(fp)
    # a text over pads, on the back too
    fp = b.footprint((58, 32), ref_at=(58, 32))
    for i in range(3):
        b.pad(fp, (-1.5 + 1.5 * i, 0), size=(0.8, 0.8), number=str(i + 1), net="SIG")
    b.place(fp)
    fp = b.footprint((70, 32), back=True, ref_layer=pcbnew.F_SilkS, ref_at=(70, 32))
    for i in range(3):
        b.pad(fp, (-1.5 + 1.5 * i, 0), size=(0.8, 0.8), number=str(i + 1), net="SIG")
    b.line((-2.5, 0.2), (2.5, -0.2), F, parent=fp)
    b.place(fp)
    # an unplated hole and an unplated slot under silkscreen, the slot across a line too
    fp = b.footprint((82, 32))
    b.pad(fp, (-2, 0), size=(1.5, 1.5), shape=pcbnew.PAD_SHAPE_CIRCLE, kind="npth")
    b.pad(fp, (2, 0), size=(1.0, 2.4), shape=pcbnew.PAD_SHAPE_OVAL, kind="npth", drill=(1.0, 2.4))
    b.line((-3, 0.3), (3, 0.3), F, parent=fp)
    b.place(fp)

    # vias: tented, not tented on the front, not on the back; tracks and an arc with solder mask, one of a margin
    # of its own, one of a negative one
    b.line((26, 44), (40, 45), F)
    b.via((28, 44.2))
    b.via((32, 44.5), tented_front=False)
    b.via((36, 44.8), tented_back=False)
    b.line((26, 46), (40, 46.5), B)
    b.via((30, 46.2), tented_back=False)
    b.track((26, 48), (40, 48), mask=True)
    b.track((26, 49.5), (40, 49.5), mask=True, margin=0.2)
    b.track((26, 51), (40, 51), mask=True, margin=-0.05, width=0.4)
    b.track((26, 52.5), (40, 52.5), layer=pcbnew.B_Cu, mask=True)
    b.track((42, 48), (48, 48), mid=(45, 50.5), mask=True, margin=0.1)
    b.line((30, 47), (31, 53.5), F)
    b.line((35, 47.6), (36, 53.2), B)
    b.line((44, 49.2), (47, 49.4), F)
    b.line((38, 49.83), (39.5, 49.83), F, width=0.1)

    # mask drawings, a mask text and a mask zone under silkscreen; a silkscreen zone under a text
    b.shape(pcbnew.SHAPE_T_RECTANGLE, pcbnew.F_Mask, [(52, 44), (56, 47)], filled=True)
    b.shape(pcbnew.SHAPE_T_CIRCLE, pcbnew.B_Mask, [(60, 46), (61.5, 46)], filled=True)
    b.text("MASK", (66, 46), layer=pcbnew.F_Mask)
    b.zone(pcbnew.F_Mask, [(72, 44), (78, 44), (78, 48), (72, 48)])
    b.zone(pcbnew.F_SilkS, [(82, 44), (88, 44), (88, 48), (82, 48)])
    b.line((50, 45.5), (90, 45.8), F)
    b.line((58, 46.1), (62, 46.1), B)
    b.text("ZONE", (85, 49))

    # silkscreen against silkscreen: the board's own drawings (left out), one footprint's (left out), two
    # footprints', drawings and texts, fields shown and hidden (a user field KiCad's report leaves out)
    b.line((24, 58), (34, 58), F)
    b.line((29, 56), (29, 60), F)
    b.text("BOARD", (29, 62))
    b.line((26, 62), (33, 62.3), F)
    fp = b.footprint((40, 58), ref_at=(40, 61.5))
    b.line((-3, 0), (3, 0), F, parent=fp)
    b.line((0, -2), (0, 2), F, parent=fp)
    fp.Value().SetLayer(pcbnew.F_SilkS)
    fp.Value().SetPosition(vec(40, 60.5))
    b.place(fp)
    fp2 = b.footprint((44, 58), ref_at=(44, 55))
    b.line((-3, 0.5), (3, -0.5), F, parent=fp2)
    user = pcbnew.PCB_FIELD(fp2, pcbnew.FIELD_T_USER, "Shown")
    user.SetText("S${REFERENCE}")
    user.SetLayer(pcbnew.F_SilkS)
    user.SetPosition(vec(45, 58))
    user.SetTextSize(vec(1, 1))
    user.SetTextThickness(int(0.15 * MM))
    fp2.Add(user)
    hidden = pcbnew.PCB_FIELD(fp2, pcbnew.FIELD_T_USER, "Hidden")
    hidden.SetText("HHH")
    hidden.SetLayer(pcbnew.F_SilkS)
    hidden.SetPosition(vec(41, 57.8))
    hidden.SetVisible(False)
    fp2.Add(hidden)
    b.text("txt", (43, 57.9), parent=fp2)
    b.place(fp2)
    # a pad on the silkscreen layer too
    fp = b.footprint((52, 58))
    b.pad(fp, (0, 0), size=(1.6, 1.0), layers=[pcbnew.F_Cu, pcbnew.F_Mask, pcbnew.F_SilkS], net="SIG")
    b.pad(fp, (3, 0), size=(1.6, 1.0), layers=[pcbnew.F_SilkS], number="2")
    b.line((-1, 0.2), (4, 0.2), F)
    b.place(fp)
    # the back's
    fp = b.footprint((60, 58), back=True, ref_layer=pcbnew.B_SilkS, ref_at=(60, 58))
    b.pad(fp, (-1.5, 0), number="1", net="SIG")
    b.pad(fp, (1.5, 0), number="2", net="GND")
    b.line((-3, 0), (3, 0), B, parent=fp)
    b.place(fp)
    b.text("BACK", (63, 58.5), layer=B)

    # outside the board and over its edges: overlapping outside (not checked), a pad outside under silkscreen, a
    # pad half outside; lines across the sides, the rounded corner, the cut-out and the margin
    b.line((5, 50), (15, 50), F)
    b.line((10, 48), (10, 52), F)
    fp = b.footprint((14, 60), ref_at=(14, 57))
    b.pad(fp, (0, 0), number="1", net="SIG")
    b.pad(fp, (6, 0), size=(1.2, 1.0), number="2", net="SIG")
    b.line((-1, 0), (7, 0.1), F, parent=fp)
    b.place(fp)
    b.line((60, 18), (62, 23), F)
    b.line((118, 84), (122, 88), F)
    b.line((96, 40.2), (104.5, 40.5), F)
    b.line((22, 70), (26, 70.2), B)
    b.text("EDGE", (120, 60), angle=90)
    b.shape(pcbnew.SHAPE_T_CIRCLE, F, [(100, 52), (101, 52)])
    # across an edge without touching it: strokes either side of it (a text, a footprint's drawings)
    b.text("I   I", (20, 66), size=1.2)
    b.text("I    I", (120.1, 30), size=1.0, angle=90)
    b.text("II  II", (20, 30), size=1.0)
    fp = b.footprint((70, 20), ref_at=(70, 24))
    b.line((-1, -1), (1, -1), F, parent=fp)
    b.line((-1, 1), (1, 1), F, parent=fp)
    b.place(fp)
    # across the cut-out and the rounded corner, whose outline is points off their arcs (the nearest of them on the
    # drawing or not); near a corner, the outline's nearest point a corner two drawings meet at (which of them KiCad
    # names goes by where they are in its memory)
    b.text("I      I", (104, 40), size=0.8)
    b.text("I      I", (103.7588, 41.3681), size=0.8, angle=-20)
    b.text("I      I", (117.3, 87.3), size=1.0, angle=-45)
    b.text("I      I", (19.3, 19.3), size=1.0, angle=-45)
    b.text("L   L", (20.6, 20.6), size=1.0, angle=45)

    if seed is not None:
        rng = random.Random(seed)
        for i in range(60):
            x, y = rng.uniform(25, 115), rng.uniform(62, 88)
            fp = b.footprint((x, y), angle=rng.choice([0, 0, 90, 45, 180]), back=rng.random() < 0.3,
                             ref_at=(x + rng.uniform(-2, 2), y + rng.uniform(-2, 2)))
            for j in range(rng.randint(1, 3)):
                b.pad(fp, (rng.uniform(-2, 2), rng.uniform(-1, 1)), size=(rng.uniform(0.5, 1.6), rng.uniform(0.5, 1.6)),
                      shape=rng.choice([pcbnew.PAD_SHAPE_RECT, pcbnew.PAD_SHAPE_CIRCLE, pcbnew.PAD_SHAPE_OVAL,
                                        pcbnew.PAD_SHAPE_ROUNDRECT]),
                      kind=rng.choice(["smd", "smd", "pth"]), number=str(j + 1), net=rng.choice(["SIG", "GND"]))
            for j in range(rng.randint(0, 3)):
                a = (rng.uniform(-3, 3), rng.uniform(-2, 2))
                c = (a[0] + rng.uniform(-3, 3), a[1] + rng.uniform(-2, 2))
                if rng.random() < 0.3:
                    b.shape(pcbnew.SHAPE_T_CIRCLE, F, [a, (a[0] + rng.uniform(0.2, 1.5), a[1])], parent=fp,
                            filled=rng.random() < 0.3)
                elif rng.random() < 0.3:
                    b.shape(pcbnew.SHAPE_T_ARC, F, [a, ((a[0] + c[0]) / 2 + rng.uniform(-1, 1), (a[1] + c[1]) / 2 + 0.7), c],
                            parent=fp)
                else:
                    b.line(a, c, F, parent=fp, width=rng.choice([0.1, 0.12, 0.15, 0.2]))
            b.place(fp)
        for i in range(25):
            a = (rng.uniform(15, 125), rng.uniform(60, 95))
            c = (a[0] + rng.uniform(-6, 6), a[1] + rng.uniform(-4, 4))
            if rng.random() < 0.25:
                b.text(rng.choice(["R1", "SILK", "x", "Ag", "I I"]), a, layer=rng.choice([F, B]), size=rng.uniform(0.6, 1.5),
                       angle=rng.choice([0, 90, 30]))
            elif rng.random() < 0.3:
                b.via(a, tented_front=rng.random() < 0.5, tented_back=rng.random() < 0.5)
            elif rng.random() < 0.3:
                b.track(a, c, mask=True, margin=rng.choice([None, 0.05, 0.1]))
            else:
                b.line(a, c, rng.choice([F, F, B]), width=rng.choice([0.1, 0.12, 0.15]))
    board.BuildConnectivity()
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    pcbnew.SaveBoard(b.path, board)


def main():
    args = sys.argv[1:]
    out = args[0]
    clearance = web = seed = None
    i = 1
    while i < len(args):
        if args[i] == "--clearance":
            clearance = float(args[i + 1])
        elif args[i] == "--web":
            web = float(args[i + 1])
        elif args[i] == "--random":
            seed = int(args[i + 1])
        i += 2
    draw(Board(out), clearance, web, seed)


if __name__ == "__main__":
    main()
