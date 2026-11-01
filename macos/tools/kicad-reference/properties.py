#!/usr/bin/env python3
"""Zones', footprints', pads' and other items' properties as KiCad reads, sets and writes them, for checking the port's
zone point editor and properties dialogs (KiCadRouter's BoardZoneEditing.swift, BoardProperties.swift,
BoardFootprintProperties.swift, BoardPadProperties.swift, BoardLocking.swift) against.

    properties.py read BOARD.kicad_pcb...
        each board as KiCad's pcbnew module reads it (JSON on standard output, the boards by their paths): each zone's
        and rule area's name, net, layers, priority, lock, clearance, minimum width, pad connection, thermal gap and
        spoke width, fill mode and hatch (thickness, gap, orientation, smoothing, smallest hole, border), island
        removal and its area, corner smoothing and radius, outline display and its pitch, keepouts and placement, and
        its outline (the outline and each hole, their corners); each footprint's position, angle, side, lock,
        attributes (mounting, board only, excluded from the BOM and position files, DNP, solder mask bridges),
        clearance, zone connection, solder mask and paste margins and its fields (name, text, shown, place on the
        footprint, size, pen, italic, bold, layer, angle, kept upright, knockout, mirrored) and pads (number, type,
        shape, place on the board and on the footprint, angle, size, trapezoid delta, hole and its shape, offset,
        layers, rounding and chamfers, clearance, zone connection, thermal spoke width, gap and angle, margins, net,
        fabrication property, unused layers removed); each track's, via's and drawing's lock; and each track's and
        via's net (KiCad gives a track the net of the pads it joins as it reads a board, CONNECTIVITY_DATA's
        PropagateNets, so that it may not be the one the board has).
    properties.py resave IN.kicad_pcb OUT.kicad_pcb
        the board read by KiCad and written again by it (pcbnew.SaveBoard), for comparing what the port writes with
        what KiCad writes of the same.
    properties.py apply PLAN.json
        each board of the plan read by KiCad, the plan's changes made to it with KiCad's own code, and written by it:
        a zone's settings given it by ZONE_SETTINGS (operator<< of the zone, the plan's values set, ExportSetting,
        its net set as PCB_EDIT_FRAME::Edit_Zone_Params sets it), its outline changed by SHAPE_POLY_SET's own
        SetVertex, InsertVertex, RemoveVertex, RemoveContour and RemoveNullSegments as the point editor changes it,
        unfilled (ZONE::UnFill), and zones moved (ZONE::Move). The plan: a list of {"board", "out", "ops"}.
    properties.py --draw OUT.kicad_pcb
        a board of zones and footprints for editing (Tests/KiCadRouterTests/Fixtures/zoneedits): on four copper
        layers, zones with holes, of several nets, layers, priorities, fill modes and smoothings, one locked, rule
        areas (one with a hole, one on two layers), footprints on both sides turned to 0, 90, 30 and 45 degrees with
        pads of every shape (rectangle, rounded, chamfered, oval, round, trapezoid, custom, plated and unplated holes,
        offsets), tracks and vias, some of them locked.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import pcbnew  # noqa: E402

import fills  # noqa: E402

MM = 1_000_000


def layer_names(lset):
    return [pcbnew.LSET.Name(layer) for layer in lset.Seq()]


def opt(v):
    return None if v is None else int(v)


def zone_props(z):
    o = z.Outline()
    outline = []
    if o.OutlineCount():
        outline.append([[o.COutline(0).CPoint(k).x, o.COutline(0).CPoint(k).y] for k in range(o.COutline(0).PointCount())])
        for j in range(o.HoleCount(0)):
            h = o.CHole(0, j)
            outline.append([[h.CPoint(k).x, h.CPoint(k).y] for k in range(h.PointCount())])
    return {
        "name": z.GetZoneName(), "net": z.GetNetname(), "layers": layer_names(z.GetLayerSet()),
        "priority": z.GetAssignedPriority(), "locked": z.IsLocked(), "clearance": opt(z.GetLocalClearance()),
        "minThickness": z.GetMinThickness(), "padConnection": int(z.GetPadConnection()),
        "thermalGap": z.GetThermalReliefGap(), "spokeWidth": z.GetThermalReliefSpokeWidth(),
        "hatched": int(z.GetFillMode()) == int(pcbnew.ZONE_FILL_MODE_HATCH_PATTERN),
        "hatchThickness": z.GetHatchThickness(), "hatchGap": z.GetHatchGap(),
        "hatchOrientation": z.GetHatchOrientation().AsDegrees(), "hatchSmoothingLevel": z.GetHatchSmoothingLevel(),
        "hatchSmoothingValue": z.GetHatchSmoothingValue(), "hatchHoleMinArea": z.GetHatchHoleMinArea(),
        "hatchBorderAlgorithm": z.GetHatchBorderAlgorithm(), "islandRemoval": int(z.GetIslandRemovalMode()),
        "minIslandArea": int(z.GetMinIslandArea()), "smoothing": int(z.GetCornerSmoothingType()),
        "cornerRadius": z.GetCornerRadius(), "borderStyle": int(z.GetHatchStyle()), "borderPitch": z.GetBorderHatchPitch(),
        "ruleArea": z.GetIsRuleArea(), "keepout": [z.GetDoNotAllowTracks(), z.GetDoNotAllowVias(), z.GetDoNotAllowPads(),
                                                   z.GetDoNotAllowZoneFills(), z.GetDoNotAllowFootprints()],
        "placementEnabled": z.GetPlacementAreaEnabled(), "placementSourceType": int(z.GetPlacementAreaSourceType()),
        "placementSource": z.GetPlacementAreaSource(), "teardrop": z.IsTeardropArea(), "filled": z.IsFilled(),
        "outline": outline,
    }


def field_props(f):
    return {
        "uuid": f.m_Uuid.AsString(), "name": f.GetName(), "text": f.GetText(), "visible": f.IsVisible(),
        "offset": [f.GetFPRelativePosition().x, f.GetFPRelativePosition().y], "width": f.GetTextWidth(),
        "height": f.GetTextHeight(), "thickness": f.GetTextThickness(), "autoThickness": f.GetAutoThickness(),
        "italic": f.IsItalic(), "bold": f.IsBold(), "layer": pcbnew.LSET.Name(f.GetLayer()),
        "angle": f.GetTextAngle().AsDegrees(), "keepUpright": f.IsKeepUpright(), "knockout": f.IsKnockout(),
        "mirrored": f.IsMirrored(), "hJustify": int(f.GetHorizJustify()), "vJustify": int(f.GetVertJustify()),
    }


def pad_props(p):
    al = pcbnew.PADSTACK.ALL_LAYERS
    return {
        "number": p.GetNumber(), "attribute": int(p.GetAttribute()), "shape": int(p.GetShape(al)),
        "anchor": int(p.GetAnchorPadShape(al)), "position": [p.GetPosition().x, p.GetPosition().y],
        "relative": [p.GetFPRelativePosition().x, p.GetFPRelativePosition().y],
        "orientation": p.GetOrientation().AsDegrees(), "relativeOrientation": p.GetFPRelativeOrientation().AsDegrees(),
        "size": [p.GetSize(al).x, p.GetSize(al).y], "delta": [p.GetDelta(al).x, p.GetDelta(al).y],
        "drill": [p.GetDrillSize().x, p.GetDrillSize().y], "drillShape": int(p.GetDrillShape()),
        "offset": [p.GetOffset(al).x, p.GetOffset(al).y], "layers": layer_names(p.GetLayerSet()),
        "roundRatio": p.GetRoundRectRadiusRatio(al), "chamferRatio": p.GetChamferRectRatio(al),
        "chamfers": int(p.GetChamferPositions(al)), "clearance": opt(p.GetLocalClearance()),
        "zoneConnection": int(p.GetLocalZoneConnection()), "spokeWidth": opt(p.GetLocalThermalSpokeWidthOverride()),
        "thermalGap": opt(p.GetLocalThermalGapOverride()), "spokeAngle": p.GetThermalSpokeAngle().AsDegrees(),
        "maskMargin": opt(p.GetLocalSolderMaskMargin()), "pasteMargin": opt(p.GetLocalSolderPasteMargin()),
        "pasteRatio": p.GetLocalSolderPasteMarginRatio(), "net": p.GetNetname(), "property": int(p.GetProperty()),
        "removeUnconnected": p.GetRemoveUnconnected(), "keepTopBottom": p.GetKeepTopBottom(), "locked": p.IsLocked(),
    }


def footprint_props(fp):
    return {
        "reference": fp.GetReference(), "value": fp.GetValue(), "position": [fp.GetPosition().x, fp.GetPosition().y],
        "orientation": fp.GetOrientation().AsDegrees(), "layer": pcbnew.LSET.Name(fp.GetLayer()), "locked": fp.IsLocked(),
        "attributes": int(fp.GetAttributes()), "boardOnly": fp.IsBoardOnly(), "excludeFromBOM": fp.IsExcludedFromBOM(),
        "excludeFromPos": fp.IsExcludedFromPosFiles(), "dnp": fp.IsDNP(), "maskBridges": fp.AllowSolderMaskBridges(),
        "missingCourtyard": fp.AllowMissingCourtyard(), "clearance": opt(fp.GetLocalClearance()),
        "zoneConnection": int(fp.GetLocalZoneConnection()), "maskMargin": opt(fp.GetLocalSolderMaskMargin()),
        "pasteMargin": opt(fp.GetLocalSolderPasteMargin()), "pasteRatio": fp.GetLocalSolderPasteMarginRatio(),
        "fields": [field_props(f) for f in fp.GetFields()],
        "pads": {p.m_Uuid.AsString(): pad_props(p) for p in fp.Pads()},
    }


def read(path):
    board = pcbnew.LoadBoard(path)
    out = {"zones": {}, "footprints": {}, "locked": {}, "nets": {}}
    for z in board.Zones():
        if not z.IsTeardropArea():
            out["zones"][z.m_Uuid.AsString()] = zone_props(z)
    for fp in board.GetFootprints():
        out["footprints"][fp.m_Uuid.AsString()] = footprint_props(fp)
    for t in board.GetTracks():
        out["locked"][t.m_Uuid.AsString()] = t.IsLocked()
        out["nets"][t.m_Uuid.AsString()] = t.GetNetname()
    for d in board.GetDrawings():
        out["locked"][d.m_Uuid.AsString()] = d.IsLocked()
        # (a drawing on copper is connected: the net KiCad gives it as it reads the board)
        if isinstance(d, pcbnew.PCB_SHAPE) and d.IsOnCopperLayer():
            out["nets"][d.m_Uuid.AsString()] = d.GetNetname()
    return out


# MARK: - The plan's changes made by KiCad

def lset(names):
    ls = pcbnew.LSET()
    for n in names:
        ls.AddLayer(pcbnew.LSET.NameToLayer(n))
    return ls


def settings(board, z, s):
    """Edit_Zone_Params: the board's default zone settings, the zone's taken (operator<<), the dialog's values set, then
    ExportSetting and the net"""
    zs = pcbnew.ZONE_SETTINGS()
    zs.CopyFrom(board.GetDesignSettings().GetDefaultZoneSettings(), True)
    zs << z
    zs.m_Name = s["name"]
    zs.m_Layers = lset(s["layers"])
    zs.m_ZonePriority = s["priority"]
    zs.m_Locked = s["locked"]
    zs.m_ZoneClearance = s["clearance"]
    zs.m_ZoneMinThickness = s["minThickness"]
    zs.SetPadConnection(s["padConnection"])
    zs.m_ThermalReliefGap = s["thermalGap"]
    zs.m_ThermalReliefSpokeWidth = s["spokeWidth"]
    zs.m_FillMode = pcbnew.ZONE_FILL_MODE_HATCH_PATTERN if s["hatched"] else pcbnew.ZONE_FILL_MODE_POLYGONS
    zs.m_HatchThickness = s["hatchThickness"]
    zs.m_HatchGap = s["hatchGap"]
    zs.m_HatchOrientation = pcbnew.EDA_ANGLE(s["hatchOrientation"], pcbnew.DEGREES_T)
    zs.m_HatchSmoothingLevel = s["hatchSmoothingLevel"]
    zs.m_HatchSmoothingValue = s["hatchSmoothingValue"]
    zs.m_HatchHoleMinArea = s["hatchHoleMinArea"]
    zs.m_HatchBorderAlgorithm = s["hatchBorderAlgorithm"]
    zs.SetIslandRemovalMode(s["islandRemoval"])
    zs.SetMinIslandArea(s["minIslandArea"])
    zs.SetCornerSmoothingType(s["smoothing"])
    zs.SetCornerRadius(s["cornerRadius"])
    zs.m_ZoneBorderDisplayStyle = s["borderStyle"]
    zs.m_BorderHatchPitch = s["borderPitch"]
    tracks, vias, pads, fills_, footprints = s["keepout"]
    zs.SetDoNotAllowTracks(tracks)
    zs.SetDoNotAllowVias(vias)
    zs.SetDoNotAllowPads(pads)
    zs.SetDoNotAllowZoneFills(fills_)
    zs.SetDoNotAllowFootprints(footprints)
    zs.SetPlacementAreaEnabled(s["placementEnabled"])
    zs.SetPlacementAreaSourceType(s["placementSourceType"])
    zs.SetPlacementAreaSource(s["placementSource"])
    net = board.FindNet(s["net"]) if s["net"] else None
    zs.m_Netcode = net.GetNetCode() if net else 0
    zs.ExportSetting(z)
    found = board.FindNet(zs.m_Netcode)
    if found:
        z.SetNetCode(found.GetNetCode())


def outline(z, op):
    poly = z.Outline()
    kind = op["kind"]
    if kind == "setVertices":
        for i, (x, y) in enumerate(op["points"]):
            poly.SetVertex(i, pcbnew.VECTOR2I(x, y))
        # (POLYGON_POINT_EDIT_BEHAVIOR::RemoveNullSegmentsIfPolygonSurvives, as FinalizeItem has it in 10.0.8)
        cleaned = pcbnew.SHAPE_POLY_SET(poly)
        cleaned.RemoveNullSegments()
        if cleaned.TotalVertices() >= 3:
            poly.RemoveNullSegments()
    elif kind == "insertVertex":
        poly.InsertVertex(op["index"], pcbnew.VECTOR2I(*op["point"]))
    elif kind == "removeVertex":
        poly.RemoveVertex(op["index"])
    elif kind == "removeContour":
        poly.RemoveContour(op["contour"])
    z.UnFill()


def apply(plan):
    for entry in plan:
        board = pcbnew.LoadBoard(entry["board"])
        zones = {z.m_Uuid.AsString(): z for z in board.Zones()}
        for op in entry["ops"]:
            z = zones[op["zone"]]
            if op["op"] == "settings":
                settings(board, z, op["settings"])
            elif op["op"] == "outline":
                outline(z, op)
            elif op["op"] == "move":
                z.Move(pcbnew.VECTOR2I(*op["offset"]))
        pcbnew.SaveBoard(entry["out"], board)


# MARK: - The board to edit

def draw(path):
    board = pcbnew.NewBoard(path)
    board.SetCopperLayerCount(4)
    nets = {}
    for name in ("GND", "VCC", "SIG", "CLK"):
        n = pcbnew.NETINFO_ITEM(board, name)
        board.Add(n)
        nets[name] = n
    fills.box_edges(board, 0, 0, 110, 80)
    f = pcbnew
    # footprints on both sides, turned, with pads of every shape
    r1 = fills.footprint(board, "R1", (20, 15))
    fills.pad(r1, "1", nets["SIG"], "rect", (1.2, 1.4))
    fills.pad(r1, "2", nets["GND"], "roundrect", (1.2, 1.4))
    r1.Pads()[1].SetFPRelativePosition(fills.vec(*fills.mm(2.0, 0)))
    r2 = fills.footprint(board, "R2", (40, 15))
    fills.pad(r2, "1", nets["VCC"], "chamfered", (1.5, 1.0))
    fills.pad(r2, "2", nets["GND"], "oval", (1.0, 1.8), drill=(0.6, 0.6))
    r2.Pads()[1].SetFPRelativePosition(fills.vec(*fills.mm(0, 2.5)))
    r2.SetOrientationDegrees(90)
    r3 = fills.footprint(board, "R3", (60, 15), layer=f.B_Cu)
    fills.pad(r3, "1", nets["SIG"], "trapezoid", (1.6, 1.2), layer=f.B_Cu)
    fills.pad(r3, "2", nets["CLK"], "chamfered", (1.4, 1.0), layer=f.B_Cu)
    r3.Pads()[1].SetFPRelativePosition(fills.vec(*fills.mm(2.5, 0.5)))
    r4 = fills.footprint(board, "R4", (80, 15), layer=f.B_Cu)
    fills.pad(r4, "1", nets["GND"], "circle", (1.7, 1.7), drill=(1.0, 1.0))
    fills.pad(r4, "2", nets["VCC"], "oval", (1.4, 2.0), drill=(0.7, 1.2), offset=(0.1, 0.2))
    r4.Pads()[1].SetFPRelativePosition(fills.vec(*fills.mm(3.0, 0)))
    r4.SetOrientationDegrees(30)
    j1 = fills.footprint(board, "J1", (95, 40))
    fills.pad(j1, "1", nets["SIG"], "rect", (1.7, 1.7), drill=(1.0, 1.0))
    fills.pad(j1, "", None, "circle", (2.2, 2.2), drill=(2.2, 2.2), npth=True)
    j1.Pads()[1].SetFPRelativePosition(fills.vec(*fills.mm(0, 3.0)))
    j1.SetOrientationDegrees(45)
    c1 = fills.footprint(board, "C1", (20, 65))
    fills.pad(c1, "1", nets["GND"], "custom", (1.0, 1.0), anchor="rect",
              primitives=[[(-0.5, -0.5), (1.5, -0.5), (1.5, 0.5), (-0.5, 0.5)]])
    fills.pad(c1, "2", nets["CLK"], "roundrect", (1.0, 1.6), clearance=0.3, connection=f.ZONE_CONNECTION_FULL)
    c1.Pads()[1].SetFPRelativePosition(fills.vec(*fills.mm(3.0, 0)))
    for fp in (r1, r2, r3, r4, j1, c1):
        fp.Reference().SetVisible(True)
        fp.Value().SetText("V" + fp.GetReference())
    r2.SetLocked(True)
    # tracks and vias, one of each locked
    fills.track(board, (21, 15), (30, 30), nets["SIG"])
    fills.track(board, (30, 30), (55, 30), nets["SIG"])
    fills.via(board, (55, 30), nets["SIG"])
    fills.track(board, (55, 30), (60, 15), nets["SIG"], layer=f.B_Cu)
    tracks = list(board.GetTracks())
    tracks[1].SetLocked(True)
    tracks[2].SetLocked(True)
    # zones with holes, of several nets and layers
    fills.zone(board, nets["GND"], [f.F_Cu], [(5, 5), (105, 5), (105, 75), (5, 75)], name="GND top",
               holes=[[(10, 40), (30, 40), (30, 55), (10, 55)], [(60, 45), (75, 45), (68, 60)]])
    fills.zone(board, nets["VCC"], [f.B_Cu], [(5, 40), (50, 35), (60, 75), (25, 78), (5, 70)], priority=1,
               hatch=(1.0, 1.5, 30, 1, 0.3))
    fills.zone(board, nets["SIG"], [f.In1_Cu, f.In2_Cu], [(60, 5), (105, 5), (105, 35), (80, 38), (60, 30)],
               holes=[[(85, 12), (95, 12), (95, 22), (85, 22)]], smoothing=(f.ZONE_SETTINGS.CORNER_SMOOTHING_FILLET, 1.0))
    fills.zone(board, nets["GND"], [f.B_Cu], [(65, 45), (100, 45), (100, 70), (65, 70)], priority=2,
               smoothing=(f.ZONE_SETTINGS.CORNER_SMOOTHING_CHAMFER, 2.0), islands=f.ISLAND_REMOVAL_MODE_AREA, min_island=4.0)
    fills.zone(board, None, [f.F_Cu], [(35, 45), (55, 45), (55, 60), (35, 60)], keepout=(True, True, False, True),
               holes=[[(40, 50), (50, 50), (45, 56)]])
    fills.zone(board, None, [f.F_Cu, f.B_Cu], [(5, 20), (15, 20), (15, 30), (5, 30)], keepout=(False, True, True, False))
    zones = list(board.Zones())
    zones[3].SetLocked(True)
    pcbnew.SaveBoard(path, board)


def main():
    args = sys.argv[1:]
    if args[0] == "--draw":
        draw(args[1])
    elif args[0] == "read":
        json.dump({p: read(p) for p in args[1:]}, sys.stdout)
    elif args[0] == "resave":
        pcbnew.SaveBoard(args[2], pcbnew.LoadBoard(args[1]))
    elif args[0] == "apply":
        with open(args[1]) as f:
            apply(json.load(f))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
