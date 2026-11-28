#!/usr/bin/env python3
"""Each layer of boards as KiCad's 3D viewer builds it, for checking the port's (KiCadRouter's Board3D) against:
through KiCad's pcbnew module, BOARD_ADAPTER::createLayers' polygons made by KiCad's own functions in createLayers'
order (the board's outline by GetBoardPolygonOutlines( poly, true, nullptr, false, true ); each copper layer's tracks
and vias flashed on it by their TransformShapeToPolygon, its footprints' pads by TransformPadsToPolySet, their texts
and fields shown by TransformTextToPolySet, their drawings by TransformShapeToPolySet, the board's drawings and texts,
its zones by TransformSolidAreasShapesToPolygon; the technical layers' drawings, a mask's openings over vias not
tented and over tracks with a mask of their own as createTrackWithMargin draws them, the pads on a silkscreen as
buildPadOutlineAsPolygon draws them, the others' by TransformPadsToPolySet with their mask and paste margins; the
holes' polygons, vias' as TransformCircleToPolygon makes them and pads' by TransformHoleToPolygon), each simplified;
then what RENDER_3D_OPENGL::reload makes of them (each layer clipped to the board and its holes taken out, the board
body with its holes, the masks as the board less their openings, the plated holes' walls). This script only puts
KiCad's functions together in createLayers' order: the functions are KiCad's, the order is read off board_adapter.cpp
and create_layer_items.cpp. Written next to each board as BOARD.board3d (JSON: each slab's kind, layer and
polygons, each its outline and holes, their points; the board's outline and whether it was made).

    board3d.py BOARD.kicad_pcb...

With --draw, a board taking the 3D viewer down the ways random boards do not, saved and then written as above: pads
with mask and paste margins of their own and their footprints' (absolute, relative, negative), a board's margins,
pads on the silkscreen (round, rectangular, oval, rounded), tracks and an arc with a mask opening of their own and a
margin, vias tented and not on each side, a blind via on four layers, plated and unplated holes and slots, a zone on
a mask layer and copper zones, texts and drawings on every layer, a drawing on copper with a mask opening, a
footprint on the back, and a stackup with colours and a finish.

    board3d.py --draw OUT.kicad_pcb

With --render, kicad-cli's renders of boards from the top and the bottom, for comparing what the port shows at each
pixel (render()); with --models, a board of footprints with a model of our own and KiCad's VRML export of it with the
models in it (models()); with --step-models, a board of footprints with STEP models of our own, made by kicad-cli's
STEP export (step_models()).

    board3d.py --render BOARD.kicad_pcb...
    board3d.py --models OUT.kicad_pcb
    board3d.py --step-models OUT.kicad_pcb
"""

import json
import os
import sys

import pcbnew

MM = 1_000_000
PLATING = 20_000


def vec(x, y):
    return pcbnew.VECTOR2I(int(round(x)), int(round(y)))


def pts(chain):
    return [[chain.CPoint(k).x, chain.CPoint(k).y] for k in range(chain.PointCount())]


def polys(p):
    return [[pts(p.Outline(i))] + [pts(p.CHole(i, j)) for j in range(p.HoleCount(i))] for i in range(p.OutlineCount())]


class Adapter:
    def __init__(self, board):
        self.b = board
        ds = board.GetDesignSettings()
        self.err = ds.m_MaxError
        self.inside = pcbnew.ERROR_INSIDE
        self.count = max(2, board.GetCopperLayerCount())
        self.copper = [l for l in pcbnew.LSET.AllCuMask(self.count).CuStack()]
        self.mask_exp = ds.m_SolderMaskExpansion
        self.silk_width = ds.GetLineThickness(pcbnew.F_SilkS)

    def enabled(self, layer):
        return self.b.IsLayerEnabled(layer)

    def circle(self, buf, center, radius):
        # TransformCircleToPolygon, through a filled circle of no width (EDA_SHAPE::TransformShapeToPolygon)
        s = pcbnew.PCB_SHAPE(self.b, pcbnew.SHAPE_T_CIRCLE)
        s.SetCenter(center)
        s.SetEnd(vec(center.x + radius, center.y))
        s.SetWidth(0)
        s.SetFilled(True)
        s.TransformShapeToPolygon(buf, pcbnew.F_Cu, 0, self.err, self.inside)

    def oval(self, buf, a, b, width):
        # TransformOvalToPolygon, through a segment drawing that wide
        s = pcbnew.PCB_SHAPE(self.b, pcbnew.SHAPE_T_SEGMENT)
        s.SetStart(a)
        s.SetEnd(b)
        s.SetWidth(width)
        s.TransformShapeToPolygon(buf, pcbnew.F_Cu, 0, self.err, self.inside)

    def ring(self, buf, center, radius, width):
        # TransformRingToPolygon, through a circle drawing that wide, not filled
        s = pcbnew.PCB_SHAPE(self.b, pcbnew.SHAPE_T_CIRCLE)
        s.SetCenter(center)
        s.SetEnd(vec(center.x + radius, center.y))
        s.SetWidth(width)
        s.SetFilled(False)
        s.TransformShapeToPolygon(buf, pcbnew.F_Cu, 0, self.err, self.inside)

    def drawings(self, layer, buf):
        for item in self.b.GetDrawings():
            if not item.IsOnLayer(layer):
                continue
            cls = item.GetClass()
            if cls == "PCB_SHAPE":
                margin = item.GetSolderMaskExpansion() if pcbnew.IsSolderMaskLayer(layer) and item.HasSolderMask() else 0
                item.TransformShapeToPolySet(buf, layer, margin, self.err, self.inside)
            elif cls == "PCB_TEXT":
                item.TransformTextToPolySet(buf, 0, self.err, self.inside)

    def fp_texts(self, fp, layer, buf):
        for item in fp.GraphicalItems():
            if item.GetClass() == "PCB_TEXT" and item.IsOnLayer(layer):
                item.TransformTextToPolySet(buf, 0, self.err, self.inside)
        for field in fp.GetFields():
            if field.IsOnLayer(layer) and field.IsVisible():
                field.TransformTextToPolySet(buf, 0, self.err, self.inside)

    def fp_shapes(self, fp, layer, buf):
        for item in fp.GraphicalItems():
            if item.GetClass() == "PCB_SHAPE" and item.IsOnLayer(layer):
                margin = item.GetSolderMaskExpansion() if pcbnew.IsSolderMaskLayer(layer) and item.HasSolderMask() else 0
                item.TransformShapeToPolySet(buf, layer, margin, self.err, self.inside)

    def zones(self, layer, buf):
        for z in self.b.Zones():
            if z.IsOnLayer(layer):
                z.TransformSolidAreasShapesToPolygon(layer, buf)

    def build(self):
        b = self.b
        out = {}
        # createBoardPolygon
        outline = pcbnew.SHAPE_POLY_SET()
        valid = b.GetBoardPolygonOutlines(outline, True, None, False, True)
        out["outline"] = polys(outline)
        out["valid"] = bool(valid)
        tracks = [t for t in b.GetTracks() if t.GetClass() == "PCB_VIA" or self.enabled(t.GetLayer())]
        layer_ids = [l for l in self.copper if self.enabled(l)]
        # the vias' holes
        th_od = pcbnew.SHAPE_POLY_SET()
        hole_od = {}
        for layer in layer_ids:
            od = pcbnew.SHAPE_POLY_SET()
            for t in tracks:
                if t.GetClass() != "PCB_VIA" or not t.IsOnLayer(layer):
                    continue
                outer = t.GetDrillValue() // 2 + PLATING
                if t.GetViaType() != pcbnew.VIATYPE_THROUGH:
                    self.circle(od, t.GetStart(), outer)
                elif layer == layer_ids[0]:
                    self.circle(th_od, t.GetStart(), outer)
            hole_od[layer] = od
        layers = {}
        for layer in layer_ids:
            poly = pcbnew.SHAPE_POLY_SET()
            for t in tracks:
                if not t.IsOnLayer(layer):
                    continue
                if t.GetClass() == "PCB_VIA" and not t.FlashLayer(layer):
                    continue
                t.TransformShapeToPolygon(poly, layer, 0, self.err, self.inside)
            for fp in b.GetFootprints():
                fp.TransformPadsToPolySet(poly, layer, 0, self.err, self.inside)
                self.fp_texts(fp, layer, poly)
                self.fp_shapes(fp, layer, poly)
            self.drawings(layer, poly)
            self.zones(layer, poly)
            poly.Simplify()
            layers[layer] = poly
        npth_od = pcbnew.SHAPE_POLY_SET()
        for fp in b.GetFootprints():
            for pad in fp.Pads():
                if not pad.HasHole():
                    continue
                if pad.GetAttribute() != pcbnew.PAD_ATTRIB_NPTH:
                    pad.TransformHoleToPolygon(th_od, PLATING, self.err, self.inside)
                else:
                    pad.TransformHoleToPolygon(npth_od, 0, self.err, self.inside)
        th_od.Simplify()
        npth_od.Simplify()
        for od in hole_od.values():
            od.Simplify()
        for layer in [pcbnew.B_Adhes, pcbnew.F_Adhes, pcbnew.B_Paste, pcbnew.F_Paste, pcbnew.B_SilkS, pcbnew.F_SilkS,
                      pcbnew.B_Mask, pcbnew.F_Mask]:
            if not self.enabled(layer):
                continue
            poly = pcbnew.SHAPE_POLY_SET()
            self.drawings(layer, poly)
            if layer in (pcbnew.F_Mask, pcbnew.B_Mask):
                cu = pcbnew.F_Cu if layer == pcbnew.F_Mask else pcbnew.B_Cu
                for t in b.GetTracks():
                    if not t.IsOnLayer(layer):
                        continue
                    if t.GetClass() == "PCB_VIA":
                        if not t.FlashLayer(cu):
                            continue
                        t.TransformShapeToPolygon(poly, cu, t.GetSolderMaskExpansion(), self.err, self.inside)
                    else:
                        # createTrackWithMargin( track, container, layer, track->GetSolderMaskExpansion() )
                        t.TransformShapeToPolygon(poly, cu, t.GetSolderMaskExpansion(), self.err, self.inside)
            for fp in b.GetFootprints():
                if layer in (pcbnew.F_SilkS, pcbnew.B_SilkS):
                    for pad in fp.Pads():
                        if not pad.IsOnLayer(layer):
                            continue
                        if pad.GetShape(layer) == pcbnew.PAD_SHAPE_CIRCLE:
                            self.ring(poly, pad.ShapePos(layer), pad.GetSize(layer).x // 2, self.silk_width)
                        else:
                            path = pad.GetEffectivePolygon(layer, self.inside).COutline(0)
                            n = path.PointCount()
                            for ii in range(n):
                                self.oval(poly, path.CPoint(ii), path.CPoint((ii + 1) % n), self.silk_width)
                else:
                    fp.TransformPadsToPolySet(poly, layer, 0, self.err, self.inside)
                self.fp_texts(fp, layer, poly)
                self.fp_shapes(fp, layer, poly)
            self.zones(layer, poly)
            poly.Simplify()
            layers[layer] = poly
        # reload: what is drawn
        slabs = []
        for layer in self.copper:
            if layer not in layers:
                continue
            p = layers[layer].CloneDropTriangulation()
            p.BooleanIntersection(outline)
            p.BooleanSubtract(th_od)
            p.BooleanSubtract(npth_od)
            if hole_od[layer].OutlineCount() > 0:
                p.BooleanSubtract(hole_od[layer])
            slabs.append({"kind": "copper", "layer": pcbnew.LSET.Name(layer), "polygons": polys(p)})
        for layer in [pcbnew.F_Paste, pcbnew.B_Paste, pcbnew.F_SilkS, pcbnew.B_SilkS, pcbnew.F_Adhes, pcbnew.B_Adhes]:
            if layer not in layers:
                continue
            p = layers[layer].CloneDropTriangulation()
            p.BooleanIntersection(outline)
            p.BooleanSubtract(th_od)
            p.BooleanSubtract(npth_od)
            slabs.append({"kind": "tech", "layer": pcbnew.LSET.Name(layer), "polygons": polys(p)})
        outer = pcbnew.SHAPE_POLY_SET()
        inner = pcbnew.SHAPE_POLY_SET()
        for t in b.GetTracks():
            if t.GetClass() == "PCB_VIA" and t.GetViaType() == pcbnew.VIATYPE_THROUGH:
                self.circle(outer, t.GetPosition(), t.GetDrill() // 2 + PLATING)
                self.circle(inner, t.GetPosition(), t.GetDrill() // 2)
        for fp in b.GetFootprints():
            for pad in fp.Pads():
                if pad.GetAttribute() != pcbnew.PAD_ATTRIB_NPTH and pad.HasHole():
                    pad.TransformHoleToPolygon(outer, PLATING, self.err, self.inside)
                    pad.TransformHoleToPolygon(inner, 0, self.err, self.inside)
        if outer.OutlineCount() > 0:
            outer.BooleanSubtract(inner)
            outer.BooleanIntersection(outline)
            slabs.append({"kind": "platedHoles", "polygons": polys(outer)})
        body = outline.CloneDropTriangulation()
        body.BooleanSubtract(th_od)
        body.BooleanSubtract(npth_od)
        slabs.append({"kind": "body", "polygons": polys(body)})
        for layer in [pcbnew.B_Mask, pcbnew.F_Mask]:
            m = outline.CloneDropTriangulation()
            if layer in layers:
                o = layers[layer].CloneDropTriangulation()
                o.BooleanIntersection(outline)
                m.BooleanSubtract(o)
            m.BooleanSubtract(th_od)
            slabs.append({"kind": "soldermask", "layer": pcbnew.LSET.Name(layer), "polygons": polys(m)})
        out["slabs"] = slabs
        return out


def write(path):
    board = pcbnew.LoadBoard(path)
    out = Adapter(board).build()
    with open(os.path.splitext(path)[0] + ".board3d", "w") as f:
        json.dump(out, f, separators=(",", ":"))
        f.write("\n")


# MARK: - the drawn board

def draw(path):
    board = pcbnew.NewBoard(path)
    board.SetCopperLayerCount(4)
    ds = board.GetDesignSettings()
    ds.m_SolderMaskExpansion = int(0.03 * MM)
    ds.m_SolderPasteMargin = int(-0.02 * MM)
    ds.m_SolderPasteMarginRatio = -0.05
    x0, y0, x1, y1 = 100 * MM, 50 * MM, 150 * MM, 90 * MM

    def shape(kind, layer, width=0.15 * MM, filled=False, parent=None):
        s = pcbnew.PCB_SHAPE(parent or board, kind)
        s.SetLayer(layer)
        s.SetWidth(int(width))
        s.SetFilled(filled)
        return s

    edge = shape(pcbnew.SHAPE_T_RECTANGLE, pcbnew.Edge_Cuts, 0.1 * MM)
    edge.SetStart(vec(x0, y0))
    edge.SetEnd(vec(x1, y1))
    board.Add(edge)
    cut = shape(pcbnew.SHAPE_T_CIRCLE, pcbnew.Edge_Cuts, 0.1 * MM)
    cut.SetCenter(vec(145 * MM, 85 * MM))
    cut.SetEnd(vec(147 * MM, 85 * MM))
    board.Add(cut)
    nets = {}

    def net(name):
        if name not in nets:
            n = pcbnew.NETINFO_ITEM(board, name)
            board.Add(n)
            nets[name] = n
        return nets[name]

    def footprint(ref, x, y, angle=0.0, back=False):
        fp = pcbnew.FOOTPRINT(board)
        fp.SetReference(ref)
        fp.SetValue("V" + ref)
        fp.SetPosition(vec(x, y))
        fp.Reference().SetPosition(vec(x, y - 2.5 * MM))
        fp.Value().SetPosition(vec(x, y + 2.5 * MM))
        fp.Value().SetLayer(pcbnew.F_Fab)
        board.Add(fp)
        return fp

    def pad(fp, number, shape_, attr, dx, dy, sx, sy, layers, drill=None, oblong=False, angle=0.0, n=None):
        p = pcbnew.PAD(fp)
        p.SetNumber(number)
        p.SetShape(pcbnew.F_Cu, shape_)
        p.SetAttribute(attr)
        p.SetSize(pcbnew.F_Cu, vec(sx, sy))
        if shape_ == pcbnew.PAD_SHAPE_ROUNDRECT:
            p.SetRoundRectRadiusRatio(pcbnew.F_Cu, 0.25)
        p.SetLayerSet(layers)
        if drill:
            p.SetDrillShape(pcbnew.PAD_DRILL_SHAPE_OBLONG if oblong else pcbnew.PAD_DRILL_SHAPE_CIRCLE)
            p.SetDrillSize(vec(*drill))
        p.SetPosition(vec(fp.GetPosition().x + dx, fp.GetPosition().y + dy))
        p.SetOrientationDegrees(angle)
        if n:
            p.SetNet(net(n))
        fp.Add(p)
        return p

    smd = pcbnew.PAD.SMDMask()
    pth = pcbnew.PAD.PTHMask()
    npth = pcbnew.PAD.UnplatedHoleMask()
    # SMD pads of every shape, with margins of their own and their footprint's
    u1 = footprint("U1", 110 * MM, 60 * MM)
    u1.SetAttributes(pcbnew.FP_SMD)
    a = pad(u1, "1", pcbnew.PAD_SHAPE_RECT, pcbnew.PAD_ATTRIB_SMD, -3 * MM, 0, 1.2 * MM, 0.8 * MM, smd, n="A")
    a.SetLocalSolderMaskMargin(int(0.1 * MM))
    b = pad(u1, "2", pcbnew.PAD_SHAPE_ROUNDRECT, pcbnew.PAD_ATTRIB_SMD, -1 * MM, 0, 1.0 * MM, 1.6 * MM, smd, angle=30, n="B")
    b.SetLocalSolderPasteMargin(int(-0.1 * MM))
    c = pad(u1, "3", pcbnew.PAD_SHAPE_OVAL, pcbnew.PAD_ATTRIB_SMD, 1 * MM, 0, 0.8 * MM, 1.8 * MM, smd, n="C")
    c.SetLocalSolderPasteMarginRatio(0.1)
    d = pad(u1, "4", pcbnew.PAD_SHAPE_CIRCLE, pcbnew.PAD_ATTRIB_SMD, 3 * MM, 0, 1.0 * MM, 1.0 * MM, smd, n="D")
    d.SetLocalSolderMaskMargin(int(-0.2 * MM))
    e = pad(u1, "5", pcbnew.PAD_SHAPE_TRAPEZOID, pcbnew.PAD_ATTRIB_SMD, 0, 2.5 * MM, 1.4 * MM, 1.0 * MM, smd)
    e.SetDelta(pcbnew.F_Cu, vec(0.3 * MM, 0))
    u1.SetLocalSolderPasteMargin(int(0.05 * MM))
    # a pad on the silkscreen of each shape
    silk = pcbnew.LSET()
    silk.AddLayer(pcbnew.F_SilkS)
    for i, s in enumerate([pcbnew.PAD_SHAPE_CIRCLE, pcbnew.PAD_SHAPE_RECT, pcbnew.PAD_SHAPE_OVAL, pcbnew.PAD_SHAPE_ROUNDRECT]):
        pad(u1, "S%d" % i, s, pcbnew.PAD_ATTRIB_SMD, (-4.5 + 3 * i) * MM, -2.5 * MM, 1.4 * MM, 0.9 * MM, silk, angle=15 * i)
    # through-hole pads and an unplated hole and slot
    j1 = footprint("J1", 125 * MM, 60 * MM)
    j1.SetAttributes(pcbnew.FP_THROUGH_HOLE)
    pad(j1, "1", pcbnew.PAD_SHAPE_RECT, pcbnew.PAD_ATTRIB_PTH, 0, 0, 1.7 * MM, 1.7 * MM, pth, drill=(1.0 * MM, 1.0 * MM), n="A")
    pad(j1, "2", pcbnew.PAD_SHAPE_OVAL, pcbnew.PAD_ATTRIB_PTH, 2.54 * MM, 0, 1.7 * MM, 2.4 * MM, pth,
        drill=(1.0 * MM, 1.6 * MM), oblong=True, n="B")
    pad(j1, "", pcbnew.PAD_SHAPE_CIRCLE, pcbnew.PAD_ATTRIB_NPTH, 5.5 * MM, 0, 2.0 * MM, 2.0 * MM, npth, drill=(2.0 * MM, 2.0 * MM))
    pad(j1, "", pcbnew.PAD_SHAPE_OVAL, pcbnew.PAD_ATTRIB_NPTH, 8 * MM, 0, 1.2 * MM, 2.2 * MM, npth,
        drill=(1.2 * MM, 2.2 * MM), oblong=True, angle=45)
    pad(j1, "3", pcbnew.PAD_SHAPE_CIRCLE, pcbnew.PAD_ATTRIB_NPTH, 0, 3 * MM, 2.6 * MM, 2.6 * MM, npth, drill=(1.5 * MM, 1.5 * MM))
    # a footprint on the back, turned
    q1 = footprint("Q1", 135 * MM, 75 * MM)
    q1.SetAttributes(pcbnew.FP_SMD)
    pad(q1, "1", pcbnew.PAD_SHAPE_RECT, pcbnew.PAD_ATTRIB_SMD, -1.5 * MM, 0, 1.0 * MM, 1.4 * MM, smd, n="A")
    pad(q1, "2", pcbnew.PAD_SHAPE_ROUNDRECT, pcbnew.PAD_ATTRIB_SMD, 1.5 * MM, 0, 1.0 * MM, 1.4 * MM, smd, n="B")
    line = shape(pcbnew.SHAPE_T_SEGMENT, pcbnew.F_SilkS, 0.12 * MM, parent=q1)
    line.SetStart(vec(133 * MM, 73.5 * MM))
    line.SetEnd(vec(137 * MM, 73.5 * MM))
    q1.Add(line)
    txt = pcbnew.PCB_TEXT(q1)
    txt.SetText("Q1 text")
    txt.SetLayer(pcbnew.F_SilkS)
    txt.SetPosition(vec(135 * MM, 77 * MM))
    q1.Add(txt)
    q1.SetOrientationDegrees(30)
    q1.Flip(q1.GetPosition(), pcbnew.FLIP_DIRECTION_TOP_BOTTOM)
    # tracks, an arc and vias
    def track(a, b_, layer, width, n, mask=False, margin=None):
        t = pcbnew.PCB_TRACK(board)
        t.SetStart(vec(*a))
        t.SetEnd(vec(*b_))
        t.SetLayer(layer)
        t.SetWidth(int(width))
        t.SetNet(net(n))
        if mask:
            t.SetHasSolderMask(True)
        if margin is not None:
            t.SetLocalSolderMaskMargin(int(margin))
        board.Add(t)
        return t

    track((105 * MM, 70 * MM), (120 * MM, 70 * MM), pcbnew.F_Cu, 0.3 * MM, "A")
    track((105 * MM, 72 * MM), (120 * MM, 74 * MM), pcbnew.F_Cu, 0.4 * MM, "B", mask=True)
    track((105 * MM, 76 * MM), (120 * MM, 76 * MM), pcbnew.B_Cu, 0.5 * MM, "C", mask=True, margin=0.1 * MM)
    track((105 * MM, 78 * MM), (120 * MM, 80 * MM), pcbnew.In1_Cu, 0.25 * MM, "D")
    arc = pcbnew.PCB_ARC(board)
    arc.SetStart(vec(105 * MM, 84 * MM))
    arc.SetMid(vec(110 * MM, 81 * MM))
    arc.SetEnd(vec(115 * MM, 84 * MM))
    arc.SetLayer(pcbnew.F_Cu)
    arc.SetWidth(int(0.35 * MM))
    arc.SetNet(net("A"))
    arc.SetHasSolderMask(True)
    board.Add(arc)

    def via(x, y, size, drill, n, kind=pcbnew.VIATYPE_THROUGH, top=pcbnew.F_Cu, bottom=pcbnew.B_Cu, tent=None):
        v = pcbnew.PCB_VIA(board)
        v.SetPosition(vec(x, y))
        v.SetViaType(kind)
        v.SetLayerPair(top, bottom)
        v.SetWidth(pcbnew.F_Cu, int(size))
        v.SetDrill(int(drill))
        v.SetNet(net(n))
        if tent is not None:
            v.SetFrontTentingMode(tent[0])
            v.SetBackTentingMode(tent[1])
        board.Add(v)
        return v

    via(125 * MM, 70 * MM, 0.8 * MM, 0.4 * MM, "A")
    via(127 * MM, 70 * MM, 0.8 * MM, 0.4 * MM, "A", tent=(pcbnew.TENTING_MODE_NOT_TENTED, pcbnew.TENTING_MODE_TENTED))
    via(129 * MM, 70 * MM, 0.9 * MM, 0.5 * MM, "B", tent=(pcbnew.TENTING_MODE_TENTED, pcbnew.TENTING_MODE_NOT_TENTED))
    via(131 * MM, 70 * MM, 0.6 * MM, 0.3 * MM, "B", kind=pcbnew.VIATYPE_BLIND, top=pcbnew.F_Cu, bottom=pcbnew.In2_Cu,
        tent=(pcbnew.TENTING_MODE_NOT_TENTED, pcbnew.TENTING_MODE_NOT_TENTED))
    via(133 * MM, 70 * MM, 0.6 * MM, 0.3 * MM, "C", kind=pcbnew.VIATYPE_BURIED, top=pcbnew.In1_Cu, bottom=pcbnew.In2_Cu)
    # drawings and texts on the layers
    for i, layer in enumerate([pcbnew.F_Cu, pcbnew.B_Cu, pcbnew.F_SilkS, pcbnew.B_SilkS, pcbnew.F_Mask, pcbnew.B_Mask,
                               pcbnew.F_Paste, pcbnew.B_Paste, pcbnew.F_Adhes, pcbnew.B_Adhes]):
        r = shape(pcbnew.SHAPE_T_RECTANGLE, layer, 0.2 * MM, filled=(i % 2 == 0))
        r.SetStart(vec(102 * MM + 4 * i * MM, 86 * MM))
        r.SetEnd(vec(104.5 * MM + 4 * i * MM, 88 * MM))
        board.Add(r)
        t = pcbnew.PCB_TEXT(board)
        t.SetText("L%d" % i)
        t.SetLayer(layer)
        t.SetPosition(vec(103 * MM + 4 * i * MM, 84.5 * MM))
        t.SetTextSize(vec(1 * MM, 1 * MM))
        t.SetTextThickness(int(0.15 * MM))
        if pcbnew.IsBackLayer(layer):
            t.SetMirrored(True)
        board.Add(t)
    # a copper drawing with a mask opening of its own
    cmask = shape(pcbnew.SHAPE_T_CIRCLE, pcbnew.F_Cu, 0.3 * MM)
    cmask.SetCenter(vec(140 * MM, 60 * MM))
    cmask.SetEnd(vec(141.5 * MM, 60 * MM))
    cmask.SetHasSolderMask(True)
    cmask.SetLocalSolderMaskMargin(int(0.15 * MM))
    board.Add(cmask)
    # zones: copper on both sides, one on the front mask
    def zone(layer, pts_, n=None):
        z = pcbnew.ZONE(board)
        z.SetLayer(layer)
        if n:
            z.SetNet(net(n))
        o = z.Outline()
        o.NewOutline()
        for p in pts_:
            o.Append(vec(*p))
        z.SetMinThickness(int(0.2 * MM))
        board.Add(z)
        return z

    zone(pcbnew.F_Cu, [(140 * MM, 70 * MM), (148 * MM, 70 * MM), (148 * MM, 80 * MM), (140 * MM, 80 * MM)], "A")
    zone(pcbnew.B_Cu, [(101 * MM, 51 * MM), (149 * MM, 51 * MM), (149 * MM, 89 * MM), (101 * MM, 89 * MM)], "C")
    zone(pcbnew.F_Mask, [(141 * MM, 52 * MM), (148 * MM, 52 * MM), (144 * MM, 57 * MM)])
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    board.Save(path)
    # (a stackup of its own with colours and a finish, written into the board as saved and read back through KiCad:
    # KiCad's Python module cannot reach the stackup)
    stackup = """(stackup
			(layer "F.SilkS" (type "Top Silk Screen") (color "Black"))
			(layer "F.Paste" (type "Top Solder Paste"))
			(layer "F.Mask" (type "Top Solder Mask") (color "Blue") (thickness 0.012))
			(layer "F.Cu" (type "copper") (thickness 0.035))
			(layer "dielectric 1" (type "prepreg") (color "FR4 natural") (thickness 0.2) (material "FR4") (epsilon_r 4.5) (loss_tangent 0.02))
			(layer "In1.Cu" (type "copper") (thickness 0.018))
			(layer "dielectric 2" (type "core") (thickness 1.0) (material "FR4") (epsilon_r 4.5) (loss_tangent 0.02))
			(layer "In2.Cu" (type "copper") (thickness 0.018))
			(layer "dielectric 3" (type "prepreg") (color "PTFE natural") (thickness 0.2) (material "FR4") (epsilon_r 4.5) (loss_tangent 0.02))
			(layer "B.Cu" (type "copper") (thickness 0.07))
			(layer "B.Mask" (type "Bottom Solder Mask") (color "#2020A0D4") (thickness 0.02))
			(layer "B.Paste" (type "Bottom Solder Paste"))
			(layer "B.SilkS" (type "Bottom Silk Screen"))
			(copper_finish "ENIG")
			(dielectric_constraints no)
		)
		"""
    with open(path) as f:
        text = f.read()
    text = text.replace("(setup\n\t\t", "(setup\n\t\t" + stackup, 1)
    with open(path, "w") as f:
        f.write(text)
    board = pcbnew.LoadBoard(path)
    board.Save(path)


# MARK: - footprints' models

# A model of our own in VRML 2.0, as KiCad's library models are written (KiCad StepUp's way: materials defined in
# shapes of their own, then faces of three and four points using them), in tenths of an inch: a body with a sloped
# top, a pin of five-sided faces turned clockwise, and a part of it under a Transform of its own (turned, moved and
# scaled), its points converted as KiCad converts them
MODEL = """#VRML V2.0 utf8
# a test part for board3d.py
Shape { appearance Appearance { material DEF BODY Material {
  ambientIntensity 0.3 diffuseColor 0.2 0.25 0.3 specularColor 0.1 0.1 0.1 emissiveColor 0 0 0 transparency 0.0 shininess 0.4 } } }
Shape { appearance Appearance { material DEF PIN Material {
  diffuseColor 0.8 0.75 0.6 transparency 0.2 shininess 0.7 } } }
Shape { geometry IndexedFaceSet { creaseAngle 0.5
  coordIndex [0,1,2,3,-1, 7,6,5,4,-1, 0,4,5,1,-1, 1,5,6,2,-1, 2,6,7,3,-1, 3,7,4,0,-1]
  coord Coordinate { point [-0.2 -0.1 0.01, 0.2 -0.1 0.01, 0.2 0.1 0.01, -0.2 0.1 0.01,
                            -0.2 -0.1 0.08, 0.2 -0.1 0.1, 0.2 0.1 0.1, -0.2 0.1 0.08] } }
  appearance Appearance { material USE BODY } }
Shape { geometry IndexedFaceSet { ccw FALSE
  coordIndex [0,1,2,3,4,-1, 4,3,2,1,0,-1]
  coord Coordinate { point [0.25 -0.03 0, 0.3 -0.03 0, 0.32 0 0.02, 0.3 0.03 0, 0.25 0.03 0] } }
  appearance Appearance { material USE PIN } }
Transform { translation -0.3 0 0.02 rotation 0 0 1 0.5236 scale 1 1 2
  children [ Shape { geometry IndexedFaceSet { coordIndex [0,1,2,-1, 0,2,3,-1]
    coord Coordinate { point [-0.03 -0.03 0, 0.03 -0.03 0, 0.03 0.03 0, -0.03 0.03 0] } }
    appearance Appearance { material USE PIN } } ] }
"""


def models(path):
    """A board of footprints with our model, placed every way (turned, moved, scaled, rotated about each axis, on the
    back), then KiCad's VRML export of it with the models in it (kicad-cli pcb export vrml, millimetres: the models as
    KiCad's VRML plugin reads them, placed as EXPORTER_PCB_VRML places them) as BOARD-kicad.wrl."""
    import subprocess
    folder = os.path.dirname(os.path.abspath(path))
    os.makedirs(os.path.join(folder, "models"), exist_ok=True)
    with open(os.path.join(folder, "models", "part.wrl"), "w") as f:
        f.write(MODEL)
    board = pcbnew.NewBoard(path)
    edge = pcbnew.PCB_SHAPE(board, pcbnew.SHAPE_T_RECTANGLE)
    edge.SetLayer(pcbnew.Edge_Cuts)
    edge.SetWidth(int(0.1 * MM))
    edge.SetStart(vec(100 * MM, 50 * MM))
    edge.SetEnd(vec(140 * MM, 80 * MM))
    board.Add(edge)
    placements = [
        ("M1", 110, 60, 0, False, (0, 0, 0), (0, 0, 0), (1, 1, 1)),
        ("M2", 120, 60, 30, False, (1, -0.5, 0.2), (0, 0, 45), (1, 1, 1)),
        ("M3", 130, 60, -60, False, (0.5, 0.5, 0), (20, 10, -30), (1.5, 1, 0.5)),
        ("M4", 110, 72, 0, True, (0, 0, 0), (0, 0, 0), (1, 1, 1)),
        ("M5", 125, 72, 120, True, (0.5, -1, 0.3), (0, 0, 15), (1, 2, 1)),
    ]
    for ref, x, y, angle, back, offset, rotation, scale in placements:
        fp = pcbnew.FOOTPRINT(board)
        fp.SetReference(ref)
        fp.SetPosition(vec(x * MM, y * MM))
        fp.SetAttributes(pcbnew.FP_SMD)
        p = pcbnew.PAD(fp)
        p.SetNumber("1")
        p.SetAttribute(pcbnew.PAD_ATTRIB_SMD)
        p.SetShape(pcbnew.F_Cu, pcbnew.PAD_SHAPE_RECT)
        p.SetSize(pcbnew.F_Cu, vec(1 * MM, 1 * MM))
        p.SetLayerSet(pcbnew.PAD.SMDMask())
        p.SetPosition(vec(x * MM, y * MM))
        fp.Add(p)
        m = pcbnew.FP_3DMODEL()
        m.m_Filename = "${KIPRJMOD}/models/part.wrl"
        m.m_Offset = pcbnew.VECTOR3D(*offset)
        m.m_Rotation = pcbnew.VECTOR3D(*rotation)
        m.m_Scale = pcbnew.VECTOR3D(*scale)
        fp.Add3DModel(m)
        board.Add(fp)
        fp.SetOrientationDegrees(angle)
        if back:
            fp.Flip(fp.GetPosition(), pcbnew.FLIP_DIRECTION_TOP_BOTTOM)
    board.Save(path)
    out = os.path.splitext(path)[0] + "-kicad.wrl"
    subprocess.run(["kicad-cli", "pcb", "export", "vrml", "--units", "mm", "-f", "-o", out, path], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# MARK: - footprints' STEP models

def step_part(folder, name, outline, holes, thickness, pads=()):
    """A STEP model of our own: a small board (its outline, holes and pads) exported by kicad-cli pcb export step, its
    body from z 0 up (the pads, where it has them, on its top), about its origin; written as folder/NAME.step"""
    import subprocess
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, name + ".kicad_pcb")
        board = pcbnew.NewBoard(path)
        board.GetDesignSettings().SetBoardThickness(int(thickness * MM))
        for i in range(len(outline)):
            a, b_ = outline[i], outline[(i + 1) % len(outline)]
            s = pcbnew.PCB_SHAPE(board, pcbnew.SHAPE_T_SEGMENT)
            s.SetLayer(pcbnew.Edge_Cuts)
            s.SetWidth(int(0.05 * MM))
            s.SetStart(vec(a[0] * MM, a[1] * MM))
            s.SetEnd(vec(b_[0] * MM, b_[1] * MM))
            board.Add(s)
        for cx, cy, r in holes:
            s = pcbnew.PCB_SHAPE(board, pcbnew.SHAPE_T_CIRCLE)
            s.SetLayer(pcbnew.Edge_Cuts)
            s.SetWidth(int(0.05 * MM))
            s.SetCenter(vec(cx * MM, cy * MM))
            s.SetEnd(vec((cx + r) * MM, cy * MM))
            board.Add(s)
        if pads:
            fp = pcbnew.FOOTPRINT(board)
            fp.SetReference("P")
            fp.SetAttributes(pcbnew.FP_SMD)
            for n, (x, y, w, h) in enumerate(pads):
                p = pcbnew.PAD(fp)
                p.SetNumber(str(n + 1))
                p.SetAttribute(pcbnew.PAD_ATTRIB_SMD)
                p.SetShape(pcbnew.F_Cu, pcbnew.PAD_SHAPE_RECT)
                p.SetSize(pcbnew.F_Cu, vec(w * MM, h * MM))
                p.SetLayerSet(pcbnew.PAD.SMDMask())
                p.SetPosition(vec(x * MM, y * MM))
                fp.Add(p)
            board.Add(fp)
        board.Save(path)
        args = ["kicad-cli", "pcb", "export", "step", "--include-pads" if pads else "--board-only", "--user-origin", "0x0mm",
                "-f", "-o", os.path.join(folder, name + ".step"), path]
        subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def placed(p, offset, rotation, scale):
    """A model's point in its footprint's frame (x right, y up, z up), as get3dModelsFromFootprint places it: scaled,
    turned about x, y, then z by its rotation negated, moved by its offset"""
    import math
    x, y, z = p[0] * scale[0], p[1] * scale[1], p[2] * scale[2]
    c, s = math.cos(-math.radians(rotation[0])), math.sin(-math.radians(rotation[0]))
    y, z = y * c - z * s, y * s + z * c
    c, s = math.cos(-math.radians(rotation[1])), math.sin(-math.radians(rotation[1]))
    x, z = x * c + z * s, -x * s + z * c
    c, s = math.cos(-math.radians(rotation[2])), math.sin(-math.radians(rotation[2]))
    x, y = x * c - y * s, x * s + y * c
    return x + offset[0], y + offset[1], z + offset[2]


def step_models(path):
    """A board of footprints with STEP models of our own (models/a.step: an L-shaped body with a round hole, a 0.5 mm
    board; models/b.step: a body with two pads on it, in two colours), placed every way (turned, moved, scaled,
    rotated about each axis, on the back, two on one footprint), each footprint's courtyard the box round its models'
    boxes (their outlines' boxes from 0 to the part's thickness, placed as above) and 0.1 mm more; with a footprint of
    a VRML model (models/part.wrl), one not fitted (which the 3D viewer leaves out, but the exporter does not) and one
    whose model is not there."""
    folder = os.path.dirname(os.path.abspath(path))
    models_ = os.path.join(folder, "models")
    os.makedirs(models_, exist_ok=True)
    parts = {
        "a": ([(-1, -0.6), (1, -0.6), (1, 0.6), (0, 0.6), (0, 0), (-1, 0)], [(0.5, 0, 0.2)], 0.5, ()),
        "b": ([(-0.8, -0.4), (0.8, -0.4), (0.8, 0.4), (-0.8, 0.4)], [], 0.3, [(-0.6, 0, 0.3, 0.6), (0.6, 0, 0.3, 0.6)]),
    }
    for name, (outline, holes, thickness, pads) in parts.items():
        step_part(models_, name, outline, holes, thickness, pads)
    with open(os.path.join(models_, "part.wrl"), "w") as f:
        f.write(MODEL)
    board = pcbnew.NewBoard(path)
    edge = pcbnew.PCB_SHAPE(board, pcbnew.SHAPE_T_RECTANGLE)
    edge.SetLayer(pcbnew.Edge_Cuts)
    edge.SetWidth(int(0.1 * MM))
    edge.SetStart(vec(100 * MM, 50 * MM))
    edge.SetEnd(vec(140 * MM, 80 * MM))
    board.Add(edge)
    none = ((0, 0, 0), (0, 0, 0), (1, 1, 1))
    placements = [
        ("S1", 110, 58, 0, False, "", [("a", *none)]),
        ("S2", 120, 58, 30, False, "", [("b", (1, -0.5, 0.2), (0, 0, 45), (1, 1, 1))]),
        ("S3", 130, 58, -60, False, "", [("a", (0.5, 0.5, 0), (20, 10, -30), (1.5, 1, 0.5))]),
        ("S4", 110, 70, 90, True, "", [("a", *none)]),
        ("S5", 125, 70, 120, True, "", [("b", (0.5, -1, 0.3), (0, 0, 15), (1, 2, 1))]),
        ("S6", 134, 70, 0, False, "", [("a", *none), ("b", (0, 0, 0.5), (0, 0, 90), (1, 1, 1))]),
        ("W1", 104, 76, 0, False, "", [("part.wrl", *none)]),
        ("D1", 136, 54, 0, False, "dnp", [("a", *none)]),
        ("X1", 104, 54, 0, False, "", [("missing", *none)]),
    ]
    for ref, x, y, angle, back, attr, models in placements:
        fp = pcbnew.FOOTPRINT(board)
        fp.SetReference(ref)
        fp.SetPosition(vec(x * MM, y * MM))
        fp.SetAttributes(pcbnew.FP_SMD)
        if attr == "dnp":
            fp.SetDNP(True)
        lo, hi = [1e9, 1e9], [-1e9, -1e9]
        for name, offset, rotation, scale in models:
            m = pcbnew.FP_3DMODEL()
            m.m_Filename = "${KIPRJMOD}/models/" + (name if "." in name else name + ".step")
            m.m_Offset = pcbnew.VECTOR3D(*offset)
            m.m_Rotation = pcbnew.VECTOR3D(*rotation)
            m.m_Scale = pcbnew.VECTOR3D(*scale)
            fp.Add3DModel(m)
            outline, _, thickness, _ = parts.get(name, ([(-1, -1), (1, 1)], [], 0.5, ()))
            for px in (min(p[0] for p in outline), max(p[0] for p in outline)):
                for py in (min(p[1] for p in outline), max(p[1] for p in outline)):
                    for pz in (0, thickness):
                        q = placed((px, py, pz), offset, rotation, scale)
                        # (the footprint's frame on the board: y down)
                        lo = [min(lo[0], q[0]), min(lo[1], -q[1])]
                        hi = [max(hi[0], q[0]), max(hi[1], -q[1])]
        crt = pcbnew.PCB_SHAPE(fp, pcbnew.SHAPE_T_RECTANGLE)
        crt.SetLayer(pcbnew.F_CrtYd)
        crt.SetWidth(int(0.05 * MM))
        crt.SetStart(vec((x + lo[0] - 0.1) * MM, (y + lo[1] - 0.1) * MM))
        crt.SetEnd(vec((x + hi[0] + 0.1) * MM, (y + hi[1] + 0.1) * MM))
        fp.Add(crt)
        board.Add(fp)
        fp.SetOrientationDegrees(angle)
        if back:
            fp.Flip(fp.GetPosition(), pcbnew.FLIP_DIRECTION_TOP_BOTTOM)
    board.Save(path)


# MARK: - KiCad's renders

def render(path, width=2000, height=1600):
    """kicad-cli's render of the board from the top and from the bottom (KiCad's 3D viewer itself, BOARD_ADAPTER and
    its raytracer: orthographic, basic quality, the stackup's colours, the layers its plot settings plot shown, the
    background transparent), each pixel's colour taken to the nearest of the colours that cover at least 0.05% of the image, and
    where the board's outline falls in it (its edges found to a fraction of a pixel by how much of the edge pixels it
    covers). Written next to the board as BOARD.render (JSON: for each side the image's size, the palette, each row's
    runs of palette entries as letters and counts, and each pixel centre's place on the board: x = ax * column + bx,
    y = ay * row + by, in nm)."""
    import subprocess
    import tempfile
    from PIL import Image

    board = pcbnew.LoadBoard(path)
    outline = pcbnew.SHAPE_POLY_SET()
    board.GetBoardPolygonOutlines(outline, True, None, False, True)
    box = outline.BBox()
    minx, miny = box.GetX(), box.GetY()
    maxx, maxy = minx + box.GetWidth(), miny + box.GetHeight()
    out = {}
    for side in ["top", "bottom"]:
        with tempfile.TemporaryDirectory() as tmp:
            png = os.path.join(tmp, side + ".png")
            subprocess.run(["kicad-cli", "pcb", "render", "--side", side, "--width", str(width), "--height", str(height),
                            "--quality", "basic", "--background", "transparent", "--use-board-stackup-colors",
                            "--preset", "follow_plot_settings", "-o", png, path], check=True, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
            im = Image.open(png).convert("RGBA")
            w, h = im.size
            px = im.load()
        # the outline's edges: in each row and column crossing the board in one run, where its first and last pixels
        # are covered from
        def edges(n, m, at):
            lo, hi = [], []
            for j in range(m):
                alphas = [at(i, j) for i in range(n)]
                on = [i for i in range(n) if alphas[i] > 0]
                if not on or on[-1] - on[0] + 1 != len(on) or len(on) < n // 4:
                    continue
                first, last = on[0], on[-1]
                lo.append(first + 1 - alphas[first] / 255.0)
                hi.append(last + alphas[last] / 255.0)
            lo.sort()
            hi.sort()
            # (the median, away from the corners and any hole)
            return lo[len(lo) // 2], hi[len(hi) // 2]
        left, right = edges(w, h, lambda i, j: px[i, j][3])
        top, bottom = edges(h, w, lambda i, j: px[j, i][3])
        ax = (maxx - minx) / (right - left)
        ay = (maxy - miny) / (bottom - top)
        if side == "top":
            bx = minx + (0.5 - left) * ax
        else:
            # (from below the board's left is on the right)
            ax = -ax
            bx = maxx - (0.5 - left) * -ax
        by = miny + (0.5 - top) * ay
        counts = {}
        for j in range(h):
            for i in range(w):
                c = px[i, j]
                if c[3] < 128:
                    c = (0, 0, 0, 0)
                counts[c] = counts.get(c, 0) + 1
        palette = sorted([c for c, n in counts.items() if n >= w * h * 0.0005], key=lambda c: -counts[c])

        def nearest(c):
            if c[3] < 128:
                return palette.index((0, 0, 0, 0))
            return min(range(len(palette)), key=lambda k: sum((c[q] - palette[k][q]) ** 2 for q in range(4)))
        cache = {}
        rows = []
        letters = "abcdefghijklmnopqrstuvwxyz"
        for j in range(h):
            row, last, run = [], None, 0
            for i in range(w):
                c = px[i, j]
                k = cache.get(c)
                if k is None:
                    k = cache[c] = nearest(c)
                if k == last:
                    run += 1
                else:
                    if last is not None:
                        row.append(letters[last] + str(run))
                    last, run = k, 1
            row.append(letters[last] + str(run))
            rows.append("".join(row))
        out[side] = {"width": w, "height": h, "palette": [list(c) for c in palette], "rows": rows,
                     "ax": ax, "bx": bx, "ay": ay, "by": by}
    with open(os.path.splitext(path)[0] + ".render", "w") as f:
        json.dump(out, f, separators=(",", ":"))
        f.write("\n")


def main():
    args = sys.argv[1:]
    if args and args[0] == "--draw":
        draw(args[1])
        write(args[1])
        return
    if args and args[0] == "--models":
        models(args[1])
        return
    if args and args[0] == "--step-models":
        step_models(args[1])
        return
    if args and args[0] == "--render":
        for path in args[1:]:
            render(path)
        return
    for path in args:
        write(path)


if __name__ == "__main__":
    main()
