#!/usr/bin/env python3
"""A KiCad board as KiCad's router sees it, written as a scene for router.cpp and KiCadRouterTests: each item KiCad's
PNS_KICAD_IFACE_BASE::SyncWorld puts in the router's world (KiCad 10.0.7, pcbnew/router/pns_kicad_iface.cpp), in the
order it puts them there, with the shapes KiCad itself makes of them, and what the rule resolver asks of their board
items: net class clearances, local clearance overrides, which layers a pad or via is flashed on.

It runs in KiCad's own Python (its pcbnew module): the board is read, and its pads' and drawings' shapes worked out,
by KiCad's code. What it does with them follows SyncWorld, syncPad, syncTrack, syncVia, syncZone, syncGraphicalItem
and syncTextItem.

    board-scene.py BOARD.kicad_pcb [OUT.json]
"""

import json
import sys

import pcbnew


def pt(v):
    return [v.x, v.y]


def chain_points(c):
    return [pt(c.CPoint(i)) for i in range(c.PointCount())]


def shape_json(s, width=None):
    """A router shape as router.cpp reads it"""
    s = s.Cast() if type(s).__name__ in ("SHAPE", "SwigPyObject") else s
    t = s.Type()
    if t == pcbnew.SH_CIRCLE:
        return {"circle": pt(s.GetCenter()), "r": s.GetRadius()}
    if t == pcbnew.SH_RECT:
        return {"rect": pt(s.GetPosition()), "size": pt(s.GetSize())}
    if t == pcbnew.SH_SEGMENT:
        return {"segment": [pt(s.GetSeg().A), pt(s.GetSeg().B)], "w": s.GetWidth() if width is None else width}
    if t == pcbnew.SH_SIMPLE:
        return {"simple": chain_points(s.Vertices())}
    if t == pcbnew.SH_LINE_CHAIN:
        return {"chain": chain_points(s)}
    if t == pcbnew.SH_ARC:
        return {"arc": [pt(s.GetP0()), pt(s.GetArcMid()), pt(s.GetP1())], "w": s.GetWidth() if width is None else width}
    raise ValueError(f"no scene form for shape type {t}")


def subshapes(shape):
    """A compound shape's pieces, or the shape (cast to what it is); the shape must be kept while they are used"""
    c = shape.Cast()
    return [s.Cast() for s in c.GetSubshapes()] if c.Type() == pcbnew.SH_COMPOUND else [c]


class Scene:
    def __init__(self, board):
        self.board = board
        self.n = board.GetCopperLayerCount()
        self.items = []
        self.unsupported = []
        self.ds = board.GetDesignSettings()

    def pns(self, layer):
        """GetPNSLayerFromBoardLayer"""
        if layer == pcbnew.F_Cu:
            return 0
        if layer == pcbnew.B_Cu:
            return self.n - 1
        return layer // 2 - 1

    def board_layer(self, pns):
        """GetBoardLayerFromPNSLayer"""
        if pns == 0:
            return pcbnew.F_Cu
        if pns == self.n - 1:
            return pcbnew.B_Cu
        return (pns + 1) * 2

    def copper_layers(self):
        return [self.board_layer(i) for i in range(self.n)]

    def add(self, item):
        self.items.append(item)

    # syncPad
    def pad(self, pad, footprint):
        lmsk = [l for l in pad.GetLayerSet().CuStack() if l in self.copper_layers()]
        if not lmsk and pad.GetDrillSize().x == 0:
            return
        attr = pad.GetAttribute()
        layers = [0, self.n - 1]
        if attr in (pcbnew.PAD_ATTRIB_SMD, pcbnew.PAD_ATTRIB_CONN):
            if not lmsk:
                return
            layers = [self.pns(lmsk[0])] * 2
        elif attr not in (pcbnew.PAD_ATTRIB_PTH, pcbnew.PAD_ATTRIB_NPTH):
            return
        padstack = pad.Padstack()
        mode = padstack.Mode()
        if mode == pcbnew.PADSTACK.MODE_NORMAL:
            unique = [pcbnew.PADSTACK.ALL_LAYERS]
        elif mode == pcbnew.PADSTACK.MODE_FRONT_INNER_BACK:
            unique = [pcbnew.F_Cu, pcbnew.PADSTACK.INNER_LAYERS, pcbnew.B_Cu]
        else:
            unique = list(padstack.UniqueLayers())
        for layer in unique:
            if mode == pcbnew.PADSTACK.MODE_FRONT_INNER_BACK and layer not in (pcbnew.F_Cu, pcbnew.B_Cu) and self.n <= 2:
                continue
            if mode == pcbnew.PADSTACK.MODE_CUSTOM:
                solid_layers = [self.pns(layer)] * 2
            elif mode == pcbnew.PADSTACK.MODE_FRONT_INNER_BACK:
                solid_layers = [self.pns(layer)] * 2 if layer in (pcbnew.F_Cu, pcbnew.B_Cu) else [1, self.n - 2]
            else:
                solid_layers = layers
            shape = pad.GetEffectiveShape(layer, pcbnew.FLASHING_ALWAYS_FLASHED)
            subs = subshapes(shape)  # (shape kept alive while subs are read)
            if len(subs) == 1:
                s = shape_json(subs[0])
            else:
                poly = pad.GetEffectivePolygon(layer, pcbnew.ERROR_OUTSIDE)
                if not poly.OutlineCount():
                    continue
                s = {"simple": chain_points(poly.Outline(0))}
            item = {"kind": "pad", "net": pad.GetNetCode(), "layers": solid_layers, "pos": pt(pad.GetPosition()),
                    "offset": pt(pad.ShapePos(layer) - pad.GetPosition()), "shape": s,
                    "npth": attr == pcbnew.PAD_ATTRIB_NPTH, "freePad": pad.IsFreePad(),
                    "copper": pad.IsOnCopperLayer(), "drilled": pad.HasDrilledHole(),
                    "npthSlot": attr == pcbnew.PAD_ATTRIB_NPTH and pad.GetDrillSizeX() != pad.GetDrillSizeY(),
                    "flashed": [pad.FlashLayer(l) for l in self.copper_layers()],
                    "footprint": footprint.GetReference()}
            override = pad.GetClearanceOverrides(None)
            if override is not None:
                item["clearanceOverride"] = override
            if pad.GetDrillSize().x > 0:
                item["hole"] = shape_json(pad.GetEffectiveHoleShape())
            self.add(item)

    # syncGraphicalItem
    def graphic(self, shape):
        layer = shape.GetLayer()
        edge = layer in (pcbnew.Edge_Cuts, pcbnew.Margin)
        if not edge and layer not in self.copper_layers():
            return
        # (the effective shape kept while its pieces are read: they are KiCad's, held by it)
        effective = shape.GetEffectiveShape(layer)
        subs = subshapes(effective)
        for s in subs:
            j = shape_json(s)
            if layer == pcbnew.Edge_Cuts and ("segment" in j or "arc" in j):
                j["w"] = 0
            item = {"kind": "edge" if edge else "graphic", "shape": j, "net": shape.GetNetCode(),
                    "layers": [0, self.n - 1] if edge else [self.pns(layer)] * 2,
                    "copper": shape.IsOnCopperLayer(), "compound": len(subs) > 1}
            self.add(item)

    # syncTextItem
    def text(self, item, layer):
        if layer not in self.copper_layers():
            return
        if item.GetClass() == "PCB_FIELD" and not item.IsVisible():
            return
        buffer = pcbnew.SHAPE_POLY_SET()
        item.TransformShapeToPolygon(buffer, item.GetLayer(), 0, item.GetMaxError(), pcbnew.ERROR_OUTSIDE)
        buffer.Simplify()
        if not buffer.OutlineCount():
            return
        self.add({"kind": "text", "layers": [self.pns(layer)] * 2, "shape": {"simple": chain_points(buffer.Outline(0))},
                  "copper": True})
        self.unsupported.append(f"text on {pcbnew.LayerName(layer) if hasattr(pcbnew, 'LayerName') else layer}")

    # syncZone (the outline only: router.cpp triangulates it with KiCad's code, as syncZone does, the triangles
    # being out of reach of KiCad's Python)
    def zone(self, zone, footprint=None):
        if not zone.GetIsRuleArea() or not zone.HasKeepoutParametersSet():
            return
        poly = zone.Outline()
        polygons = []
        for i in range(poly.OutlineCount()):
            polygons.append([chain_points(poly.Outline(i))] + [chain_points(poly.Hole(i, h)) for h in range(poly.HoleCount(i))])
        keepout = {"tracks": zone.GetDoNotAllowTracks(), "vias": zone.GetDoNotAllowVias(),
                   "pads": zone.GetDoNotAllowPads(), "footprints": zone.GetDoNotAllowFootprints(),
                   "footprint": footprint.GetReference() if footprint else None}
        layers = [self.pns(l) for l in self.copper_layers() if zone.GetLayerSet().Contains(l)]
        self.add({"kind": "keepout", "layers": layers, "polygons": polygons, "keepout": keepout})
        self.unsupported.append("keepout zone")

    def drawing(self, item):
        cls = item.GetClass()
        if cls in ("PCB_SHAPE", "PCB_TEXTBOX"):
            self.graphic(item)
        elif cls in ("PCB_TEXT", "PCB_TABLE"):
            self.text(item, item.GetLayer())
        elif cls.startswith("PCB_DIM") and item.GetLayer() in self.copper_layers():
            self.unsupported.append("dimension on copper")
        elif cls == "PCB_BARCODE" and item.GetLayer() in self.copper_layers():
            self.unsupported.append("barcode on copper")

    def sync(self):
        for item in self.board.GetDrawings():
            self.drawing(item)
        for zone in self.board.Zones():
            self.zone(zone)
        worst = self.board.GetMaxClearanceValue()
        for footprint in self.board.GetFootprints():
            for pad in footprint.Pads():
                self.pad(pad, footprint)
                override = pad.GetClearanceOverrides(None)
                if override is not None:
                    worst = max(worst, override)
                if pad.GetProperty() == pcbnew.PAD_PROP_CASTELLATED:
                    self.unsupported.append("castellated pad")
            self.text(footprint.Reference(), footprint.Reference().GetLayer())
            self.text(footprint.Value(), footprint.Value().GetLayer())
            for zone in footprint.Zones():
                self.zone(zone, footprint)
            for field in footprint.GetFields():
                self.text(field, field.GetLayer())
            for item in footprint.GraphicalItems():
                self.drawing(item)
        for t in self.board.GetTracks():
            cls = t.GetClass()
            if cls == "PCB_TRACK":
                self.add({"kind": "track", "net": t.GetNetCode(), "layer": self.pns(t.GetLayer()), "a": pt(t.GetStart()),
                          "b": pt(t.GetEnd()), "width": t.GetWidth(), "locked": t.IsLocked()})
            elif cls == "PCB_ARC":
                self.add({"kind": "arc", "net": t.GetNetCode(), "layer": self.pns(t.GetLayer()), "start": pt(t.GetStart()),
                          "mid": pt(t.GetMid()), "end": pt(t.GetEnd()), "width": t.GetWidth(), "locked": t.IsLocked()})
                self.unsupported.append("arc track")
            elif cls == "PCB_VIA":
                v = pcbnew.Cast_to_PCB_VIA(t) if hasattr(pcbnew, "Cast_to_PCB_VIA") else t
                if v.Padstack().Mode() != pcbnew.PADSTACK.MODE_NORMAL:
                    self.unsupported.append("via padstack")
                self.add({"kind": "via", "net": v.GetNetCode(), "pos": pt(v.GetPosition()),
                          "layers": [self.pns(v.TopLayer()), self.pns(v.BottomLayer())],
                          "diameter": v.GetWidth(pcbnew.PADSTACK.ALL_LAYERS), "drill": v.GetDrillValue(),
                          "free": v.GetIsFree(), "locked": v.IsLocked(),
                          "flashed": [v.FlashLayer(l) for l in self.copper_layers()]})
        nets = self.board.GetNetInfo().NetsByNetcode()
        settings = self.ds.m_NetSettings
        net_clearance = {}
        for code, net in nets.items():
            nc = settings.GetEffectiveNetClass(net.GetNetname())
            net_clearance[str(code)] = nc.GetClearance() if nc.HasClearance() else 0
        rules = {"board": True, "minClearance": self.ds.m_MinClearance, "holeClearance": self.ds.m_HoleClearance,
                 "holeToHole": self.ds.m_HoleToHoleMin, "edgeClearance": self.ds.m_CopperEdgeClearance,
                 "epsilon": self.ds.GetDRCEpsilon(), "maxClearance": worst, "netClearance": net_clearance,
                 "maxError": self.ds.m_MaxError}
        net_names = {str(code): net.GetNetname() for code, net in nets.items()}
        return {"layers": self.n, "rules": rules, "items": self.items, "netNames": net_names,
                "unsupported": sorted(set(self.unsupported))}


def main():
    board = pcbnew.LoadBoard(sys.argv[1])
    scene = Scene(board).sync()
    text = json.dumps(scene, separators=(",", ":"))
    if len(sys.argv) > 2:
        with open(sys.argv[2], "w") as f:
            f.write(text)
    else:
        print(text)


if __name__ == "__main__":
    main()
