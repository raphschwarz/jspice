// Pads' properties set as KiCad's pad properties dialog sets them (KiCad 10.0.8: pcbnew/dialogs/
// dialog_pad_properties.cpp, DIALOG_PAD_PROPERTIES's initValues, updatePadLayersList, onPadShapeSelection,
// transferDataToPad and TransferDataFromWindow; pcbnew/pad.cpp, PAD::Flip, SetAttribute and CanHaveNumber;
// pcbnew/pad_utils.cpp, GetDefaultIpcRoundingRatio), written as pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.cpp
// writes a pad (format( PAD ), formatLayers). Copyright The KiCad Developers, see KiCad's AUTHORS.txt. GNU General
// Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// A pad's properties as KiCad's pad properties dialog shows them (lengths in mm, angles in degrees): a pad of a
/// footprint on the back as it would be on the front (the dialog turns its copy over: its layers, offset, trapezoid
/// and chamfered corners as on the front)
public struct PadProperties: Equatable, Sendable {
    /// The dialog's pad types: an aperture is a surface pad on no copper
    public enum PadType: String, Sendable, CaseIterable {
        case throughHole = "thru_hole", smd, connector = "connect", npth = "np_thru_hole", aperture
    }
    /// The dialog's shapes (a chamfered one written as roundrect, a custom one keeping its primitives)
    public enum Shape: String, Sendable, CaseIterable {
        case circle, oval, rect, trapezoid, roundrect, chamferedRect, chamferedRoundRect, customCircle, customRect
    }
    /// The dialog's choice of copper layers, by pad type: a plated hole's on all of them, on the outer ones and
    /// those connected, on those connected only, or on none; an unplated hole's on both outer ones, the front, the
    /// back or none; a surface pad's on the front or the back
    public enum CopperLayers: Sendable, CaseIterable { case all, outerAndConnected, connectedOnly, none, front, back, frontAndBack }
    public enum Corner: String, Sendable, CaseIterable {
        case topLeft = "top_left", topRight = "top_right", bottomLeft = "bottom_left", bottomRight = "bottom_right"
    }

    public var number = ""
    public var net: String?
    public var type = PadType.smd
    public var shape = Shape.rect
    /// Where it is on the board
    public var position = KiCadPoint.zero
    /// Its angle to its footprint's
    public var orientation = 0.0
    public var size = KiCadPoint(1, 1)
    /// A trapezoid's: its sides' difference, along x (the y size varying) or along y
    public var trapezoidDelta = 0.0
    public var trapezoidAlongY = false
    /// Its shape's offset from its hole, nil for none
    public var offset: KiCadPoint?
    public var oblongHole = false
    public var drill = KiCadPoint(0, 0)
    /// A rounded rectangle's corners' radius to its smaller side (0 to 0.5); a chamfered one's chamfers' and which
    /// corners
    public var cornerRatio = 0.0
    public var chamferRatio = 0.0
    public var chamferedCorners: Set<Corner> = []
    public var clearance: Double?
    public var solderMaskMargin: Double?
    public var solderPasteMargin: Double?
    public var solderPasteRatio: Double?
    public var zoneConnection = ZoneConnection.inherited
    public var thermalSpokeWidth: Double?
    public var thermalGap: Double?
    public var thermalSpokeAngle = 90.0
    public var copperLayers = CopperLayers.front
    /// Its technical layers, of the dialog's (technicalLayerNames)
    public var technicalLayers: Set<String> = []
    /// Its fabrication property, as KiCad writes it (pad_prop_bga...), nil for none
    public var fabricationProperty: String?

    public static let technicalLayerNames = ["F.Adhes", "B.Adhes", "F.Paste", "B.Paste", "F.SilkS", "B.SilkS", "F.Mask", "B.Mask",
                                             "Eco1.User", "Eco2.User", "Dwgs.User"]

    public init() {}

    /// The thermal spokes' angle KiCad takes for a pad of `shape` (45° for a round one, 90° else), which it writes
    /// only where it is not so
    public static func defaultSpokeAngle(_ shape: Shape) -> Double { shape == .circle || shape == .customCircle ? 45 : 90 }

    /// The rounding the dialog suggests for a pad of `size` made rounded (PAD_UTILS::GetDefaultIpcRoundingRatio: a
    /// quarter of its smaller side, 0.25 mm at most)
    public static func defaultCornerRatio(_ size: KiCadPoint) -> Double {
        let minSize = Double(min(BoardWorld.iu(size.x), BoardWorld.iu(size.y)))
        return minSize > 0 ? min(250_000, minSize * 0.25) / minSize : 0.25
    }
}

extension BoardEditing {
    /// A footprint's pad of that id, and the footprint
    func padNode(_ uuid: String) -> (pad: SExpr, footprint: KiCadFootprint)? {
        for fp in router.board.footprints {
            if let pad = fp.node.all("pad").first(where: { $0.value("uuid") == uuid }) { return (pad, fp) }
        }
        return nil
    }

    /// The pad at `p` (mm): the smallest of those whose shape holds it; nil where there is none
    public func pad(at p: KiCadPoint) -> String? {
        router.board.footprints.flatMap(\.pads).filter { KiCadPolygon.contains($0.outline, p) }
            .min { Self.ringArea($0.outline) < Self.ringArea($1.outline) }?.uuid
    }

    /// A pad's layers by name as KiCad reads them ("*.Cu" kept for every copper layer, F&B.Cu the outer two, "*.X"
    /// both sides')
    static func padLayers(_ pad: SExpr) -> Set<String> {
        var out = Set<String>()
        for n in pad["layers"]?.arguments.map(\.text) ?? [] {
            switch n {
            case "*.Cu": out.insert("*.Cu")
            case "F&B.Cu": out.formUnion(["F.Cu", "B.Cu"])
            case _ where n.hasPrefix("*."): out.formUnion(["F" + n.dropFirst(), "B" + n.dropFirst()])
            default: out.insert(n)
            }
        }
        return out
    }

    static let flippedCorner: [PadProperties.Corner: PadProperties.Corner] = [.topLeft: .bottomLeft, .bottomLeft: .topLeft,
                                                                              .topRight: .bottomRight, .bottomRight: .topRight]

    /// A pad's properties as KiCad's pad properties dialog shows them (initValues); nil for no pad of that id, or one
    /// of a padstack of its own (by layer), which the port does not edit
    public func padProperties(_ uuid: String) -> PadProperties? {
        guard let (pad, fp) = padNode(uuid), pad["padstack"] == nil else { return nil }
        var p = PadProperties()
        let flipped = fp.layer == "B.Cu"
        p.number = pad.text(at: 0) ?? ""
        p.net = router.board.netName(pad["net"])
        let type = pad.text(at: 1) ?? "smd"
        var layers = Set(Self.padLayers(pad).map { flipped && $0 != "*.Cu" ? KiCadFootprint.flipLayer($0) : $0 })
        let copper = layers.filter { $0.hasSuffix(".Cu") && $0 != "*.Cu" }
        let allCopper = layers.contains("*.Cu")
        p.type = PadProperties.PadType(rawValue: type) ?? .smd
        if p.type == .smd && copper.isEmpty && !allCopper { p.type = .aperture }
        let shape = pad.text(at: 2) ?? "rect"
        let chamfers = Set((pad["chamfer"]?.arguments.map(\.text) ?? []).compactMap(PadProperties.Corner.init))
        let rratio = pad["roundrect_rratio"]?.number(at: 0) ?? 0
        let anchor = pad["options"]?.value("anchor") ?? "circle"
        switch shape {
        case "circle": p.shape = .circle
        case "oval": p.shape = .oval
        case "trapezoid": p.shape = .trapezoid
        case "roundrect":
            // (a roundrect with chamfers is KiCad's CHAMFERED_RECT, the dialog's chamfered rounded one where rounded too)
            p.shape = chamfers.isEmpty ? .roundrect : rratio > 0 ? .chamferedRoundRect : .chamferedRect
        case "custom": p.shape = anchor == "rect" ? .customRect : .customCircle
        default: p.shape = .rect
        }
        // (where it is on the board: its footprint's position and its own on the footprint, turned)
        let rel = BoardWorld.point(pad["at"])
        p.position = Self.mm(KiMath.rotate(rel, EDAAngle(degrees: fp.rotation)) + Self.nm(fp.position))
        p.orientation = (pad["at"]?.number(at: 2) ?? 0) - fp.rotation
        p.size = KiCadPoint(Self.mm(pad["size"], 0), Self.mm(pad["size"], 1))
        let sign = flipped ? -1.0 : 1.0
        if let d = pad["rect_delta"] {
            let (dx, dy) = (Self.mm(d, 0), Self.mm(d, 1) * sign)
            p.trapezoidAlongY = dx == 0 && dy != 0
            p.trapezoidDelta = p.trapezoidAlongY ? dy : dx
        }
        if let drill = pad["drill"] {
            let numbers = drill.arguments.filter { $0.kind == .symbol }.compactMap { Double($0.text) }
            p.oblongHole = drill.arguments.contains { $0.kind == .symbol && $0.text == "oval" }
            if let x = numbers.first { p.drill = KiCadPoint(Self.iu(x), Self.iu(numbers.count > 1 ? numbers[1] : x)) }
            if let o = drill["offset"] { p.offset = KiCadPoint(Self.mm(o, 0), Self.mm(o, 1) * sign) }
        }
        if p.offset == .zero { p.offset = nil }
        // (a rounding only where it means something: PadHasMeaningfulRoundingRadius)
        p.cornerRatio = shape == "roundrect" ? rratio : 0
        p.chamferRatio = pad["chamfer_ratio"]?.number(at: 0) ?? 0
        p.chamferedCorners = flipped ? Set(chamfers.compactMap { Self.flippedCorner[$0] }) : chamfers
        p.clearance = pad["clearance"].map { Self.mm($0, 0) }
        p.solderMaskMargin = pad["solder_mask_margin"].map { Self.mm($0, 0) }
        p.solderPasteMargin = pad["solder_paste_margin"].map { Self.mm($0, 0) }
        p.solderPasteRatio = pad["solder_paste_margin_ratio"]?.number(at: 0)
        p.zoneConnection = pad.value("zone_connect").flatMap(Int.init).flatMap(ZoneConnection.init) ?? .inherited
        p.thermalSpokeWidth = pad["thermal_bridge_width"].map { Self.mm($0, 0) }
        p.thermalGap = pad["thermal_gap"].map { Self.mm($0, 0) }
        p.thermalSpokeAngle = pad["thermal_bridge_angle"]?.number(at: 0) ?? PadProperties.defaultSpokeAngle(p.shape)
        // (updatePadLayersList)
        let removeUnused = pad.value("remove_unused_layers") == "yes", keepEnds = pad.value("keep_end_layers") == "yes"
        switch p.type {
        case .throughHole:
            p.copperLayers = !allCopper && copper.isEmpty ? .none : !removeUnused ? .all : keepEnds ? .outerAndConnected : .connectedOnly
        case .npth:
            let f = allCopper || copper.contains("F.Cu"), b = allCopper || copper.contains("B.Cu")
            p.copperLayers = f && b ? .frontAndBack : f ? .front : b ? .back : .none
        case .smd, .connector:
            p.copperLayers = copper.contains("B.Cu") && !copper.contains("F.Cu") ? .back : .front
        case .aperture:
            p.copperLayers = .none
        }
        layers.remove("*.Cu")
        p.technicalLayers = layers.intersection(PadProperties.technicalLayerNames)
        p.fabricationProperty = pad.value("property")
        return p
    }

    /// Why KiCad's pad properties dialog would not take `p` (transferDataToPad's and CheckPad's refusals the port
    /// makes), nil if it would
    public func padPropertiesProblem(_ uuid: String, _ p: PadProperties) -> String? {
        guard let (pad, _) = padNode(uuid), pad["padstack"] == nil else { return "No such pad, or one of a padstack of its own." }
        let custom = p.shape == .customCircle || p.shape == .customRect
        if custom != (pad.text(at: 2) == "custom") { return "A pad is not made custom, or not custom, here." }
        if let w = p.thermalSpokeWidth, w < 0 { return "Thermal spoke width must be at least 0 mm." }
        if Self.iu(p.size.x) <= 0 || (p.shape != .circle && p.shape != .customCircle && Self.iu(p.size.y) <= 0) {
            return "Error: Pad must have a positive size."
        }
        if p.type == .throughHole && (Self.iu(p.drill.x) <= 0 || (p.oblongHole && Self.iu(p.drill.y) <= 0)) {
            return "Error: Through hole pad has no hole."
        }
        if p.shape == .trapezoid {
            // (a delta as large as the pad: KiCad clamps it and keeps the dialog open)
            let d = BoardWorld.iu(p.trapezoidDelta)
            if abs(d) > BoardWorld.iu(p.trapezoidAlongY ? p.size.x : p.size.y) { return "Trapezoid delta is too large for the pad's size." }
        }
        switch p.type {
        case .smd, .connector:
            if p.copperLayers != .front && p.copperLayers != .back { return "A surface pad's copper is on the front or the back." }
        case .npth:
            if ![.frontAndBack, .front, .back, .none].contains(p.copperLayers) { return "An unplated hole's copper is on its sides or none." }
        case .throughHole:
            if ![.all, .outerAndConnected, .connectedOnly, .none].contains(p.copperLayers) { return "A plated hole's copper is on its layers or none." }
        case .aperture:
            break
        }
        if let net = p.net, !net.isEmpty, !router.board.netNames.contains(net), !router.world.netNames.values.contains(net) {
            return "No net \(net) on the board."
        }
        return nil
    }

    /// The pad given properties `p`, as KiCad's pad properties dialog gives them (transferDataToPad and
    /// TransferDataFromWindow): a surface pad's hole none, an unplated one's number and net none (an aperture's, or any
    /// pad's on no copper, its number none, PAD::CanHaveNumber), its layers those of
    /// the dialog's choices (its other layers dropped), its rounding kept to 0.5 at most; one of a footprint on the
    /// back turned over again after (PAD::Flip: its layers, offset, trapezoid and chamfered corners back to the back,
    /// its angle to its footprint's negated); written as KiCad writes a pad, as one change ("Edit Pad Properties").
    /// Nil where the dialog would refuse it (padPropertiesProblem) or it changes nothing.
    public func setPadProperties(_ uuid: String, _ p: PadProperties) -> Edit? {
        guard !isRouting, padPropertiesProblem(uuid, p) == nil, let (pad, fp) = padNode(uuid) else { return nil }
        let was = pad.compact
        let flipped = fp.layer == "B.Cu"
        let custom = p.shape == .customCircle || p.shape == .customRect
        func n(_ v: Double) -> Double { Self.iu(v) }
        let attribute = p.type == .aperture ? "smd" : p.type.rawValue
        let shapeName: String
        switch p.shape {
        case .circle: shapeName = "circle"
        case .oval: shapeName = "oval"
        case .rect: shapeName = "rect"
        case .trapezoid: shapeName = "trapezoid"
        case .roundrect, .chamferedRect, .chamferedRoundRect: shapeName = "roundrect"
        case .customCircle, .customRect: shapeName = "custom"
        }
        // its size (a circle's, and a custom pad's round anchor's, round), the trapezoid's delta, its hole, its offset
        let round = p.shape == .circle || p.shape == .customCircle
        let size = round ? KiCadPoint(n(p.size.x), n(p.size.x)) : KiCadPoint(n(p.size.x), n(p.size.y))
        var delta = KiCadPoint.zero
        if p.shape == .trapezoid {
            if p.trapezoidAlongY { delta.y = n(p.trapezoidDelta) } else { delta.x = n(p.trapezoidDelta) }
        }
        var drill = p.oblongHole ? KiCadPoint(n(p.drill.x), n(p.drill.y)) : KiCadPoint(n(p.drill.x), n(p.drill.x))
        if p.type == .smd || p.type == .connector || p.type == .aperture { drill = .zero }
        var offset = p.offset.map { KiCadPoint(n($0.x), n($0.y)) } ?? .zero
        // (turned over again on a footprint on the back: MIRROR of the offset and delta)
        if flipped {
            delta.y = -delta.y
            offset.y = -offset.y
        }
        // its corners
        var rratio = 0.0, chamferRatio = 0.0
        var corners: Set<PadProperties.Corner> = []
        switch p.shape {
        case .roundrect: rratio = min(max(p.cornerRatio, 0), 0.5)
        case .chamferedRect: chamferRatio = p.chamferRatio; corners = p.chamferedCorners
        case .chamferedRoundRect: chamferRatio = p.chamferRatio; rratio = min(max(p.cornerRatio, 0), 0.5); corners = p.chamferedCorners
        default: break
        }
        if flipped { corners = Set(corners.compactMap { Self.flippedCorner[$0] }) }
        // its layers
        var layers = Set<String>()
        var removeUnused: Bool?, keepEnds = false
        switch p.type {
        case .throughHole:
            if p.copperLayers != .none { layers.insert("*.Cu") }
            removeUnused = p.copperLayers == .outerAndConnected || p.copperLayers == .connectedOnly
            keepEnds = p.copperLayers == .outerAndConnected
        case .npth:
            switch p.copperLayers {
            case .frontAndBack: layers.formUnion(["F.Cu", "B.Cu"])
            case .front: layers.insert("F.Cu")
            case .back: layers.insert("B.Cu")
            default: break
            }
        case .smd, .connector:
            layers.insert(p.copperLayers == .back ? "B.Cu" : "F.Cu")
        case .aperture:
            break
        }
        layers.formUnion(p.technicalLayers.intersection(PadProperties.technicalLayerNames))
        if flipped { layers = Set(layers.map { $0 == "*.Cu" ? $0 : KiCadFootprint.flipLayer($0) }) }
        // its place: on the board, as the dialog has it, then on the footprint (GetFPRelativePosition); its angle to the
        // footprint's (on the back, negated as the pad turns over)
        let relative = KiMath.rotate(Self.nm(p.position) - Self.nm(fp.position), EDAAngle(degrees: -fp.rotation))
        let angle = KiCadFootprint.normalize360((flipped ? -p.orientation : p.orientation) + fp.rotation)
        // the pad, as KiCad writes one
        // (its number none where it can have none, PAD::CanHaveNumber: an unplated hole's, or an aperture's, a pad on no
        // copper, which the dialog's number is greyed out for and KiCad's parser clears as it reads it)
        let canHaveNumber = p.type != .npth && layers.contains { $0.hasSuffix(".Cu") }
        var items: [SExprConvertible] = [canHaveNumber ? p.number : "", Keyword(attribute), Keyword(shapeName)]
        var at: [SExprConvertible] = [Double(relative.x) / 1e6, Double(relative.y) / 1e6]
        if angle != 0 { at.append(angle) }
        items.append(SExpr("at", at))
        items.append(SExpr("size", size.x, size.y))
        if delta != .zero { items.append(SExpr("rect_delta", delta.x, delta.y)) }
        if drill.x > 0 || drill.y > 0 || offset != .zero {
            var d: [SExprConvertible] = []
            if p.oblongHole { d.append(Keyword("oval")) }
            if drill.x > 0 { d.append(drill.x) }
            if drill.y > 0 && drill.x != drill.y { d.append(drill.y) }
            if offset != .zero { d.append(SExpr("offset", offset.x, offset.y)) }
            items.append(SExpr("drill", d))
        }
        for head in ["backdrill", "tertiary_drill", "front_post_machining", "back_post_machining"] {
            if let x = pad[head] { items.append(x.copy()) }
        }
        if let prop = p.fabricationProperty { items.append(SExpr("property", Keyword(prop))) }
        items.append(SExpr("layers", Self.padLayerList(layers, board: router.board).map { $0 as SExprConvertible }))
        if let removeUnused {
            items.append(SExpr("remove_unused_layers", Keyword(removeUnused ? "yes" : "no")))
            if removeUnused {
                items.append(SExpr("keep_end_layers", Keyword(keepEnds ? "yes" : "no")))
                items.append(pad["zone_layer_connections"]?.copy() ?? SExpr("zone_layer_connections", [SExprConvertible]()))
            }
        }
        if shapeName == "roundrect" { items.append(SExpr("roundrect_rratio", rratio)) }
        if p.shape == .chamferedRect || p.shape == .chamferedRoundRect {
            items.append(SExpr("chamfer_ratio", chamferRatio))
            let order: [PadProperties.Corner] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
            items.append(SExpr("chamfer", order.filter(corners.contains).map { Keyword($0.rawValue) as SExprConvertible }))
        }
        if p.type != .npth, let net = p.net, !net.isEmpty { items.append(router.board.netList(net, pad: true)) }
        for head in ["pinfunction", "pintype", "die_length", "die_delay"] { if let x = pad[head] { items.append(x.copy()) } }
        if let v = p.solderMaskMargin { items.append(SExpr("solder_mask_margin", n(v))) }
        if let v = p.solderPasteMargin { items.append(SExpr("solder_paste_margin", n(v))) }
        if let v = p.solderPasteRatio { items.append(SExpr("solder_paste_margin_ratio", v)) }
        if let v = p.clearance { items.append(SExpr("clearance", n(v))) }
        if p.zoneConnection != .inherited { items.append(SExpr("zone_connect", p.zoneConnection.rawValue)) }
        if let v = p.thermalSpokeWidth { items.append(SExpr("thermal_bridge_width", n(v))) }
        if p.thermalSpokeAngle != PadProperties.defaultSpokeAngle(p.shape) { items.append(SExpr("thermal_bridge_angle", p.thermalSpokeAngle)) }
        if let v = p.thermalGap { items.append(SExpr("thermal_gap", n(v))) }
        if custom {
            if let x = pad["options"] { items.append(x.copy()) }
            if let x = pad["primitives"] { items.append(x.copy()) }
        }
        for head in ["teardrops", "tenting", "uuid"] { if let x = pad[head] { items.append(x.copy()) } }
        let fresh = SExpr("pad", items)
        guard fresh.compact != was else { return nil }
        pad.items = fresh.items
        router.boardChanged()
        return change("Edit Pad Properties", footprints: [fp.uuid])
    }

    /// A pad's layers as formatLayers writes them (not enumerated): "*.Cu" for every copper layer of the board, or for
    /// the outer two alone; both sides' adhesive, paste, silkscreen, mask, courtyard and fabrication each as one; the
    /// rest by name in the order of KiCad's layers' ids
    static func padLayerList(_ layers: Set<String>, board: KiCadBoard) -> [String] {
        let boardCopper = Set(boardLayers(board).filter { $0.hasSuffix(".Cu") })
        var left = layers
        var out: [String] = []
        let copper = left.contains("*.Cu") ? boardCopper : left.intersection(boardCopper)
        if left.contains("*.Cu") || (!copper.isEmpty && copper == boardCopper) || copper == ["F.Cu", "B.Cu"] {
            // (and no copper layer by name after it, the board's inner ones or others)
            out.append("*.Cu")
            left = left.filter { !$0.hasSuffix(".Cu") }
        }
        for kind in ["Adhes", "Paste", "SilkS", "Mask", "CrtYd", "Fab"] where left.contains("F.\(kind)") && left.contains("B.\(kind)") {
            out.append("*.\(kind)")
            left.subtract(["F.\(kind)", "B.\(kind)"])
        }
        return out + left.sorted { (BoardDRC.layerID($0) ?? 1000, $0) < (BoardDRC.layerID($1) ?? 1000, $1) }
    }
}
