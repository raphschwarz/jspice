import Foundation
import KiCadKit
import SwiftProtobuf

/// A footprint of a board file as KiCad's API carries one (kiapi.board.types.FootprintInstance), to make it in the PCB
/// editor whole: its pads (their padstacks, drills and nets), drawings, texts, fields and 3D models, each where it is on
/// the board (the API's footprints carry their items in board coordinates, in nanometres), its link to the schematic.
/// What it cannot carry faithfully (a footprint's zones, text boxes, dimensions, groups) it refuses, and the
/// board goes to the editor by its file instead.
public enum KiCadFootprintMessage {
    public struct Unsupported: Error, CustomStringConvertible {
        public var description: String
    }

    // MARK: - Units and layers

    static func nm(_ mm: Double) -> Int64 { Int64((mm * 1e6).rounded()) }

    static func vector(_ p: KiCadPoint) -> Kiapi_Common_Types_Vector2 {
        var v = Kiapi_Common_Types_Vector2()
        v.xNm = nm(p.x)
        v.yNm = nm(p.y)
        return v
    }

    static func distance(_ mm: Double) -> Kiapi_Common_Types_Distance {
        var d = Kiapi_Common_Types_Distance()
        d.valueNm = nm(mm)
        return d
    }

    static func angle(_ degrees: Double) -> Kiapi_Common_Types_Angle {
        var a = Kiapi_Common_Types_Angle()
        a.valueDegrees = degrees
        return a
    }

    static let layerNumbers: [String: Int] = {
        var map: [String: Int] = ["F.Cu": 3, "B.Cu": 34, "B.Adhes": 35, "F.Adhes": 36, "B.Paste": 37, "F.Paste": 38,
                                  "B.SilkS": 39, "F.SilkS": 40, "B.Mask": 41, "F.Mask": 42, "Dwgs.User": 43, "Cmts.User": 44,
                                  "Eco1.User": 45, "Eco2.User": 46, "Edge.Cuts": 47, "Margin": 48, "B.CrtYd": 49, "F.CrtYd": 50,
                                  "B.Fab": 51, "F.Fab": 52, "Rescue": 62]
        for n in 1...30 { map["In\(n).Cu"] = 3 + n }
        for n in 1...9 { map["User.\(n)"] = 52 + n }
        for n in 10...45 { map["User.\(n)"] = 53 + n }
        return map
    }()

    /// A layer's number in the API (BoardLayer)
    public static func layer(_ name: String) throws -> Kiapi_Board_Types_BoardLayer {
        guard let n = layerNumbers[name], let layer = Kiapi_Board_Types_BoardLayer(rawValue: n) else {
            throw Unsupported(description: "the layer \(name)")
        }
        return layer
    }

    /// A pad's layers, its wildcards (*.Cu, *.Mask) spelled out
    static func layers(_ names: [String]) throws -> [Kiapi_Board_Types_BoardLayer] {
        var out: [Kiapi_Board_Types_BoardLayer] = []
        for name in names {
            switch name {
            case "*.Cu": out += (["F.Cu"] + (1...30).map { "In\($0).Cu" } + ["B.Cu"]).compactMap { try? layer($0) }
            case "F&B.Cu": out += [try layer("F.Cu"), try layer("B.Cu")]
            case "*.Mask": out += [try layer("F.Mask"), try layer("B.Mask")]
            case "*.Paste": out += [try layer("F.Paste"), try layer("B.Paste")]
            case "*.SilkS": out += [try layer("F.SilkS"), try layer("B.SilkS")]
            default: out.append(try layer(name))
            }
        }
        return out
    }

    // MARK: - The footprint

    /// The footprint as KiCad's API carries one
    public static func instance(_ footprint: KiCadFootprint) throws -> Kiapi_Board_Types_FootprintInstance {
        let node = footprint.node
        let placement = footprint.placement
        for unsupported in ["zone", "fp_text_box", "dimension", "group", "barcode", "image", "table"] where node[unsupported] != nil {
            throw Unsupported(description: "a footprint's \(unsupported)")
        }
        var instance = Kiapi_Board_Types_FootprintInstance()
        instance.id.value = footprint.uuid
        instance.position = vector(footprint.position)
        instance.orientation = angle(footprint.rotation)
        instance.layer = try layer(footprint.layer)
        instance.locked = footprint.isLocked ? .lsLocked : .lsUnlocked

        var definition = Kiapi_Board_Types_Footprint()
        let lib = KiCadFootprintLibrary.split(footprint.libID)
        definition.id.libraryNickname = lib?.library ?? ""
        definition.id.entryName = lib?.name ?? footprint.libID
        definition.anchor = vector(footprint.position)
        var attributes = Kiapi_Board_Types_FootprintAttributes()
        attributes.description_p = node.value("descr") ?? ""
        attributes.keywords = node.value("tags") ?? ""
        let attrs = footprint.attributes
        attributes.mountingStyle = attrs.contains("smd") ? .fmsSmd : attrs.contains("through_hole") ? .fmsThroughHole : .fmsUnspecified
        attributes.notInSchematic = attrs.contains("board_only")
        attributes.excludeFromPositionFiles = attrs.contains("exclude_from_pos_files")
        attributes.excludeFromBillOfMaterials = attrs.contains("exclude_from_bom")
        attributes.exemptFromCourtyardRequirement = attrs.contains("allow_missing_courtyard")
        attributes.doNotPopulate = attrs.contains("dnp")
        attributes.allowSoldermaskBridges = attrs.contains("allow_soldermask_bridges")
        definition.attributes = attributes
        instance.attributes = attributes
        definition.jumpers.duplicateNamesAreJumpered = node["duplicate_pad_numbers_are_jumpers"]?.text(at: 0) == "yes"

        var items: [Google_Protobuf_Any] = []
        let pads = footprint.pads
        for child in node.items {
            switch child.head {
            case "property":
                guard let name = child.text(at: 0) else { continue }
                let field = try self.field(child, placement: placement, name: name)
                switch name {
                case "Reference": instance.referenceField = field; definition.referenceField = field
                case "Value": instance.valueField = field; definition.valueField = field
                case "Datasheet": instance.datasheetField = field; definition.datasheetField = field
                case "Description": instance.descriptionField = field; definition.descriptionField = field
                default: items.append(try Google_Protobuf_Any(message: field))
                }
            case "fp_text":
                items.append(try Google_Protobuf_Any(message: text(child, placement: placement)))
            case "fp_line", "fp_rect", "fp_arc", "fp_circle", "fp_poly", "fp_curve":
                items.append(try Google_Protobuf_Any(message: shape(child, placement: placement)))
            case "pad":
                guard let p = pads.first(where: { $0.node === child }) else { continue }
                items.append(try Google_Protobuf_Any(message: pad(p, placement: placement)))
            case "model":
                items.append(try Google_Protobuf_Any(message: model(child)))
            case "point":
                // a footprint's points are where they are on the board, in the file as in the API
                var point = Kiapi_Board_Types_ReferencePoint()
                if let id = child.value("uuid") { point.id.value = id }
                point.layer = try layer(child.value("layer") ?? "F.Fab")
                point.position = self.point(child["at"], nil)
                point.size = distance(child["size"]?.number(at: 0) ?? 1.27)
                point.locked = .lsUnlocked
                items.append(try Google_Protobuf_Any(message: point))
            default:
                continue
            }
        }
        definition.items = items
        instance.definition = definition
        instance.symbolPath = sheetPath(footprint.path)
        instance.symbolSheetName = node.value("sheetname") ?? ""
        instance.symbolSheetFilename = node.value("sheetfile") ?? ""
        instance.symbolFootprintFilters = footprint.property("ki_fp_filters") ?? ""
        return instance
    }

    /// The path of the symbol a footprint is linked to ("/<sheet>/<symbol>"), as the API carries it: the ids after the
    /// root sheet
    public static func sheetPath(_ path: String?) -> Kiapi_Common_Types_SheetPath {
        var sheet = Kiapi_Common_Types_SheetPath()
        guard let path, !path.isEmpty else { return sheet }
        sheet.path = path.split(separator: "/").map { KiCadAPI.kiid(String($0)) }
        sheet.pathHumanReadable = "/"
        return sheet
    }

    // MARK: - Texts

    static func textAttributes(_ node: SExpr, angle degrees: Double) -> Kiapi_Common_Types_TextAttributes {
        var a = Kiapi_Common_Types_TextAttributes()
        let effects = node["effects"]
        let font = effects?["font"]
        // (size height width)
        let height = font?["size"]?.number(at: 0) ?? 1, width = font?["size"]?.number(at: 1) ?? height
        a.size = vector(KiCadPoint(width, height))
        // (no thickness: KiCad's own, as the file leaves it)
        a.strokeWidth = distance(font?["thickness"]?.number(at: 0) ?? 0)
        a.angle = angle(degrees)
        a.bold = font?.flag("bold") ?? false
        a.italic = font?.flag("italic") ?? false
        a.fontName = font?.value("face") ?? ""
        let justify = effects?["justify"]?.arguments.map(\.text) ?? []
        a.horizontalAlignment = justify.contains("left") ? .haLeft : justify.contains("right") ? .haRight : .haCenter
        a.verticalAlignment = justify.contains("top") ? .vaTop : justify.contains("bottom") ? .vaBottom : .vaCenter
        a.mirrored = justify.contains("mirror")
        a.visible = !(node.flag("hide") || (effects?.flag("hide") ?? false))
        a.keepUpright = !(node.flag("unlocked") || (node["at"]?.arguments.contains { $0.text == "unlocked" } ?? false))
        a.lineSpacing = 1
        return a
    }

    static func boardText(_ node: SExpr, text: String, placement: KiCadPlacement) throws -> Kiapi_Board_Types_BoardText {
        var t = Kiapi_Board_Types_BoardText()
        if let id = node.value("uuid") { t.id.value = id }
        let at = node["at"]
        t.text.position = vector(placement.apply(KiCadPoint(at?.number(at: 0) ?? 0, at?.number(at: 1) ?? 0)))
        t.text.text = text
        t.text.attributes = textAttributes(node, angle: at?.number(at: 2) ?? 0)
        t.layer = try layer(node.value("layer") ?? "F.Fab")
        t.knockout = node["layer"]?.arguments.contains { $0.text == "knockout" } ?? false
        t.locked = .lsUnlocked
        return t
    }

    static func field(_ node: SExpr, placement: KiCadPlacement, name: String) throws -> Kiapi_Board_Types_Field {
        var field = Kiapi_Board_Types_Field()
        field.name = name
        field.text = try boardText(node, text: node.text(at: 1) ?? "", placement: placement)
        field.visible = field.text.text.attributes.visible
        return field
    }

    static func text(_ node: SExpr, placement: KiCadPlacement) throws -> Kiapi_Board_Types_BoardText {
        try boardText(node, text: node.text(at: 1) ?? "", placement: placement)
    }

    // MARK: - Drawings

    static func stroke(_ node: SExpr) -> Kiapi_Common_Types_GraphicAttributes {
        var g = Kiapi_Common_Types_GraphicAttributes()
        g.stroke.width = distance(node["stroke"]?["width"]?.number(at: 0) ?? node["width"]?.number(at: 0) ?? 0.12)
        switch node["stroke"]?["type"]?.text(at: 0) ?? "solid" {
        case "default": g.stroke.style = .slsDefault
        case "dash": g.stroke.style = .slsDash
        case "dot": g.stroke.style = .slsDot
        case "dash_dot": g.stroke.style = .slsDashdot
        case "dash_dot_dot": g.stroke.style = .slsDashdotdot
        default: g.stroke.style = .slsSolid
        }
        let fill = node["fill"]?.text(at: 0) ?? node["fill"]?["type"]?.text(at: 0)
        g.fill.fillType = fill == "yes" || fill == "solid" ? .gftFilled : .gftUnfilled
        return g
    }

    static func point(_ list: SExpr?, _ placement: KiCadPlacement?) -> Kiapi_Common_Types_Vector2 {
        let p = KiCadPoint(list?.number(at: 0) ?? 0, list?.number(at: 1) ?? 0)
        return vector(placement?.apply(p) ?? p)
    }

    /// A drawing's shape, its points on the board (a pad's own drawings stay about the pad: `placement` nil)
    static func graphic(_ node: SExpr, placement: KiCadPlacement?) throws -> Kiapi_Common_Types_GraphicShape {
        var shape = Kiapi_Common_Types_GraphicShape()
        shape.attributes = stroke(node)
        let kind = (node.head ?? "").split(separator: "_").last.map(String.init) ?? ""
        switch kind {
        case "line":
            var s = Kiapi_Common_Types_GraphicSegmentAttributes()
            s.start = point(node["start"], placement)
            s.end = point(node["end"], placement)
            shape.segment = s
        case "rect":
            // a rectangle stays square to the board only on a footprint turned by quarters
            if let placement, (placement.rotation / 90).rounded() != placement.rotation / 90 {
                throw Unsupported(description: "a rectangle turned off square")
            }
            let a = point(node["start"], placement), b = point(node["end"], placement)
            var r = Kiapi_Common_Types_GraphicRectangleAttributes()
            r.topLeft = vector(KiCadPoint(Double(min(a.xNm, b.xNm)) / 1e6, Double(min(a.yNm, b.yNm)) / 1e6))
            r.bottomRight = vector(KiCadPoint(Double(max(a.xNm, b.xNm)) / 1e6, Double(max(a.yNm, b.yNm)) / 1e6))
            if let radius = node["radius"]?.number(at: 0) { r.cornerRadius = distance(radius) }
            shape.rectangle = r
        case "arc":
            var a = Kiapi_Common_Types_GraphicArcAttributes()
            a.start = point(node["start"], placement)
            a.mid = point(node["mid"], placement)
            a.end = point(node["end"], placement)
            shape.arc = a
        case "circle":
            var c = Kiapi_Common_Types_GraphicCircleAttributes()
            c.center = point(node["center"], placement)
            c.radiusPoint = point(node["end"], placement)
            shape.circle = c
        case "poly":
            var line = Kiapi_Common_Types_PolyLine()
            line.closed = true
            for p in node["pts"]?.items ?? [] {
                var n = Kiapi_Common_Types_PolyLineNode()
                if p.head == "xy" {
                    n.point = point(p, placement)
                } else if p.head == "arc" {
                    var arc = Kiapi_Common_Types_ArcStartMidEnd()
                    arc.start = point(p["start"], placement)
                    arc.mid = point(p["mid"], placement)
                    arc.end = point(p["end"], placement)
                    n.arc = arc
                } else { continue }
                line.nodes.append(n)
            }
            var polygon = Kiapi_Common_Types_PolygonWithHoles()
            polygon.outline = line
            var set = Kiapi_Common_Types_PolySet()
            set.polygons = [polygon]
            shape.polygon = set
        case "curve":
            let pts = node["pts"]?.items.filter { $0.head == "xy" } ?? []
            guard pts.count == 4 else { throw Unsupported(description: "a curve of \(pts.count) points") }
            var b = Kiapi_Common_Types_GraphicBezierAttributes()
            b.start = point(pts[0], placement)
            b.control1 = point(pts[1], placement)
            b.control2 = point(pts[2], placement)
            b.end = point(pts[3], placement)
            shape.bezier = b
        default:
            throw Unsupported(description: "a drawing \(node.head ?? "")")
        }
        return shape
    }

    static func shape(_ node: SExpr, placement: KiCadPlacement) throws -> Kiapi_Board_Types_BoardGraphicShape {
        var s = Kiapi_Board_Types_BoardGraphicShape()
        s.shape = try graphic(node, placement: placement)
        s.layer = try layer(node.value("layer") ?? "F.SilkS")
        if let id = node.value("uuid") { s.id.value = id }
        s.locked = node.flag("locked") ? .lsLocked : .lsUnlocked
        return s
    }

    // MARK: - Pads

    /// The pin of the schematic a pad stands for, as the API carries it
    public static func pin(_ pad: KiCadPad) -> Kiapi_Board_Types_SymbolPinInfo {
        var info = Kiapi_Board_Types_SymbolPinInfo()
        info.name = pad.pinFunction ?? ""
        let type = pad.pinType ?? ""
        info.noConnect = type.contains("no_connect")
        let types: [String: Kiapi_Common_Types_ElectricalPinType] = [
            "input": .eptInput, "output": .eptOutput, "bidirectional": .eptBidirectional, "tri_state": .eptTristate,
            "passive": .eptPassive, "free": .eptFree, "unspecified": .eptUnspecified, "power_in": .eptPowerInput,
            "power_out": .eptPowerOutput, "open_collector": .eptOpenCollector, "open_emitter": .eptOpenEmitter,
            "no_connect": .eptNoConnect,
        ]
        info.type = types[String(type.split(separator: "+").first ?? "")] ?? .eptUnknown
        return info
    }

    static func pad(_ pad: KiCadPad, placement: KiCadPlacement) throws -> Kiapi_Board_Types_Pad {
        let node = pad.node
        var p = Kiapi_Board_Types_Pad()
        if !pad.uuid.isEmpty { p.id.value = pad.uuid }
        p.number = pad.number
        p.locked = node.flag("locked") ? .lsLocked : .lsUnlocked
        p.net.name = pad.net ?? ""
        switch pad.type {
        case "thru_hole": p.type = .ptPth
        case "smd": p.type = .ptSmd
        case "connect": p.type = .ptEdgeConnector
        case "np_thru_hole": p.type = .ptNpth
        default: throw Unsupported(description: "a pad of type \(pad.type)")
        }
        p.position = vector(pad.position)
        if let clearance = node["clearance"]?.number(at: 0) { p.copperClearanceOverride = distance(clearance) }
        if let length = node["die_length"]?.number(at: 0) { p.padToDieLength = distance(length) }
        p.symbolPin = self.pin(pad)

        var stack = Kiapi_Board_Types_PadStack()
        stack.type = .pstNormal
        stack.layers = try layers(pad.layers)
        stack.angle = angle(pad.angle)
        if let drill = node["drill"] {
            var d = Kiapi_Board_Types_DrillProperties()
            let oval = drill.text(at: 0) == "oval"
            let numbers = drill.arguments.filter { $0.kind == .symbol && Double($0.text) != nil }.compactMap { Double($0.text) }
            let w = numbers.first ?? 0, h = numbers.count > 1 ? numbers[1] : w
            d.diameter = vector(KiCadPoint(w, h))
            d.shape = oval ? .dsOblong : .dsCircle
            d.startLayer = .blFCu
            d.endLayer = .blBCu
            stack.drill = d
        }
        let remove = node["remove_unused_layers"]?.text(at: 0) == "yes"
        let keepEnds = node["keep_end_layers"]?.text(at: 0) == "yes"
        stack.unconnectedLayerRemoval = !remove ? .ulrKeep : keepEnds ? .ulrRemoveExceptStartAndEnd : .ulrRemove

        var copper = Kiapi_Board_Types_PadStackLayer()
        copper.layer = .blFCu
        let (w, h) = pad.size
        copper.size = vector(KiCadPoint(w, h))
        switch pad.shape {
        case "circle": copper.shape = .pssCircle
        case "rect": copper.shape = .pssRectangle
        case "oval": copper.shape = .pssOval
        case "trapezoid": copper.shape = .pssTrapezoid
        case "roundrect":
            copper.shape = node["chamfer"] != nil ? .pssChamferedrect : .pssRoundrect
        case "custom": copper.shape = .pssCustom
        default: throw Unsupported(description: "a pad shaped \(pad.shape)")
        }
        copper.cornerRoundingRatio = node["roundrect_rratio"]?.number(at: 0) ?? 0
        if let chamfer = node["chamfer"] {
            copper.chamferRatio = node["chamfer_ratio"]?.number(at: 0) ?? 0.2
            let corners = Set(chamfer.arguments.map(\.text))
            copper.chamferedCorners.topLeft = corners.contains("top_left")
            copper.chamferedCorners.topRight = corners.contains("top_right")
            copper.chamferedCorners.bottomLeft = corners.contains("bottom_left")
            copper.chamferedCorners.bottomRight = corners.contains("bottom_right")
        }
        if let delta = node["rect_delta"] {
            copper.trapezoidDelta = vector(KiCadPoint(delta.number(at: 0) ?? 0, delta.number(at: 1) ?? 0))
        }
        if let offset = node["drill"]?["offset"] {
            copper.offset = vector(KiCadPoint(offset.number(at: 0) ?? 0, offset.number(at: 1) ?? 0))
        }
        if pad.shape == "custom" {
            copper.customAnchorShape = node["options"]?["anchor"]?.text(at: 0) == "rect" ? .pssRectangle : .pssCircle
            for primitive in node["primitives"]?.arguments ?? [] {
                var s = Kiapi_Board_Types_BoardGraphicShape()
                // the primitives stay where they are on the pad, unturned
                s.shape = try graphic(primitive, placement: nil)
                if primitive["width"] != nil { s.shape.attributes.stroke.width = distance(primitive["width"]?.number(at: 0) ?? 0) }
                s.layer = .blFCu
                copper.customShapes.append(s)
            }
        }
        stack.copperLayers = [copper]
        p.padStack = stack
        return p
    }

    // MARK: - 3D models

    static func model(_ node: SExpr) throws -> Kiapi_Board_Types_Footprint3DModel {
        var m = Kiapi_Board_Types_Footprint3DModel()
        m.filename = node.text(at: 0) ?? ""
        func xyz(_ name: String, _ fallback: Double) -> Kiapi_Common_Types_Vector3D {
            var v = Kiapi_Common_Types_Vector3D()
            let list = node[name]?["xyz"]
            v.xNm = list?.number(at: 0) ?? fallback
            v.yNm = list?.number(at: 1) ?? fallback
            v.zNm = list?.number(at: 2) ?? fallback
            return v
        }
        m.offset = xyz("offset", 0)
        m.scale = xyz("scale", 1)
        m.rotation = xyz("rotate", 0)
        m.visible = !node.flag("hide")
        m.opacity = node["opacity"]?.number(at: 0) ?? 1
        return m
    }
}
