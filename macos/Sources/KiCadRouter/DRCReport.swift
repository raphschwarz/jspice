// Ported from KiCad 10.0.7: common/rc_item.cpp (GetJsonViolation: the items a report names, as they describe
// themselves), pcbnew/board.cpp (FillItemMap, GetLayerName), pcbnew/board_item.cpp (LayerMaskDescribe) and the items'
// GetItemDescription: pcbnew/pcb_track.cpp, pcbnew/pad.cpp, pcbnew/pcb_shape.cpp, pcbnew/pcb_text.cpp,
// pcbnew/pcb_field.cpp, pcbnew/zone.cpp and pcbnew/footprint.cpp.
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// (a check holds the board it was made of, its own copy, which it only reads: it may run anywhere)
extension BoardDRC: @unchecked Sendable {}

extension BoardDRC {
    /// The checks BoardDRC makes, by KiCad's keys: the rest of KiCad's (texts' sizes, footprints against
    /// their libraries, zones' own checks, the schematic's) it leaves to kicad-cli
    public static let checksMade: [String] = [
        "track_width", "via_diameter", "drill_out_of_range", "microvia_drill_out_of_range", "annular_width", "hole_to_hole",
        "holes_co_located", "clearance", "hole_clearance", "shorting_items", "tracks_crossing", "copper_edge_clearance",
        "track_dangling", "via_dangling", "unconnected_items", "items_not_allowed",
        "courtyards_overlap", "missing_courtyard", "malformed_courtyard", "pth_inside_courtyard", "npth_inside_courtyard",
        "solder_mask_bridge", "isolated_copper", "starved_thermal",
        "invalid_outline", "zones_intersect", "silk_overlap", "silk_over_copper", "silk_edge_clearance",
    ]

    /// The check as KiCad's report gives it: the violations, and the connections still to make apart, each item
    /// described as KiCad describes it and placed where KiCad places it (in millimetres)
    public func report() -> KiCadFabrication.DRCReport {
        let found = run()
        let info = itemDescriptions()
        func violation(_ v: DRCViolation) -> KiCadFabrication.Violation {
            KiCadFabrication.Violation(type: v.type, description: v.description, severity: v.severity, items: v.items.map { uuid in
                KiCadFabrication.Violation.Item(description: info[uuid]?.description ?? uuid, position: info[uuid]?.position, uuid: uuid)
            })
        }
        return KiCadFabrication.DRCReport(violations: found.filter { $0.type != "unconnected_items" }.map(violation),
                                          unconnected: found.filter { $0.type == "unconnected_items" }.map(violation),
                                          parity: [], kicadVersion: "")
    }

    /// Each board item's description as KiCad's DRC report gives it (BOARD_ITEM::GetItemDescription), and its position
    func itemDescriptions() -> [String: (description: String, position: KiCadPoint?)] {
        var out: [String: (description: String, position: KiCadPoint?)] = [:]
        func mm(_ p: IPoint) -> KiCadPoint { KiCadPoint(Double(p.x) / 1e6, Double(p.y) / 1e6) }
        func net(_ node: SExpr) -> String {
            let n = Self.netName(node)
            return n.isEmpty ? "<no net>" : n
        }
        func length(_ v: Double) -> String { String(format: "%.4f mm", v / 1e6) }
        let layerName = layerNames()
        func trackLayer(_ node: SExpr) -> String {
            let l = BoardWorld.itemLayer(node) ?? ""
            return layerName[l] ?? l
        }
        let drawingKinds = ["line": "Segment", "rect": "Rectangle", "circle": "Circle", "arc": "Arc", "poly": "Polygon", "curve": "Curve"]
        func drawing(_ node: SExpr, of reference: String?, placement: BoardWorld.FootprintPlacement?) {
            guard let head = node.head, var kind = drawingKinds[String(head.dropFirst(3))], let uuid = node.value("uuid") else { return }
            // (a footprint's rectangle turned off square is a polygon)
            if head == "fp_rect", let placement, placement.orientation.normalized.degrees.truncatingRemainder(dividingBy: 90) != 0 {
                kind = "Polygon"
            }
            let layer = BoardWorld.itemLayer(node) ?? ""
            let onCopper = world.layerIndex[layer] != nil
            var d = kind + (onCopper ? " [\(net(node))]" : "")
            if let reference { d += " of \(reference)" }
            d += " on \(layerName[layer] ?? layer)"
            let at = world.readDrawing(node, placement: placement).map { $0.kind == .poly ? $0.poly.first ?? $0.start : $0.start }
            out[uuid] = (d, at.map(mm))
        }
        // (the board itself: "PCB", at the origin)
        out[Self.boardUUID] = ("PCB", KiCadPoint(0, 0))
        for node in board.root.items {
            guard let uuid = node.value("uuid") else { continue }
            switch node.head ?? "" {
            case "segment":
                let s = BoardWorld.point(node["start"]), e = BoardWorld.point(node["end"])
                out[uuid] = ("Track [\(net(node))] on \(trackLayer(node)), length \(length(s.distance(e)))", mm(s))
            case "arc":
                let s = BoardWorld.point(node["start"])
                let a = ShapeArc(start: s, mid: BoardWorld.point(node["mid"]), end: BoardWorld.point(node["end"]))
                out[uuid] = ("Track (arc) [\(net(node))] on \(trackLayer(node)), length \(length(a.length))", mm(s))
            case "via":
                let layers = node["layers"]?.arguments.map(\.text) ?? ["F.Cu", "B.Cu"]
                let kind = node.arguments.contains { $0.text == "blind" } ? "Blind via"
                    : node.arguments.contains { $0.text == "buried" } ? "Buried via"
                    : node.arguments.contains { $0.text == "micro" } ? "Micro via" : "Via"
                out[uuid] = ("\(kind) [\(net(node))] on \(layers.first ?? "") - \(layers.last ?? "")", mm(BoardWorld.point(node["at"])))
            case "zone":
                out[uuid] = (zoneDescription(node, net: net(node), layerName), zoneCorner(node).map(mm))
            case "gr_text":
                // (PCB_TEXT::GetItemDescription: its text as shown)
                let t = BoardWorld.textStrokes(node, footprint: nil)
                let layer = node.value("layer") ?? ""
                out[uuid] = ("PCB text '\(t?.shownText ?? BoardText.textArgument(node, 0) ?? "")' on \(layerName[layer] ?? layer)",
                             mm(BoardWorld.point(node["at"])))
            default:
                drawing(node, of: nil, placement: nil)
            }
        }
        for (i, fp) in board.root.all("footprint").enumerated() {
            let placement = BoardWorld.FootprintPlacement(fp)
            let reference = placement.reference
            if let uuid = fp.value("uuid") {
                out[uuid] = ("Footprint \(reference.isEmpty ? "<no reference designator>" : reference)", mm(placement.position))
            }
            for (j, node) in fp.all("pad").enumerated() {
                guard let uuid = node.value("uuid") else { continue }
                let p = footprints[i].pads[j]
                let number = p.number.isEmpty ? "" : " \(p.number)"
                let d: String
                switch p.pad.attribute {
                case .pth: d = "PTH pad\(number) [\(net(node))] of \(reference)"
                case .npth: d = "NPTH pad\(number) of \(reference)"
                case .smd, .conn: d = "Pad\(number) [\(net(node))] of \(reference) on \(layerMaskDescribe(layerSet(node), layerName))"
                }
                out[uuid] = (d, mm(p.pad.pos))
            }
            for node in fp.items {
                if node.head == "zone", let uuid = node.value("uuid") {
                    out[uuid] = (zoneDescription(node, net: net(node), layerName), zoneCorner(node).map(mm))
                } else if node.head == "property" || node.head == "fp_text", let uuid = node.value("uuid") {
                    out[uuid] = (textDescription(node, fp, reference), mm(placement.apply(BoardWorld.point(node["at"]))))
                } else {
                    drawing(node, of: reference, placement: placement)
                }
            }
        }
        return out
    }

    /// BOARD::FillItemMap: the items KiCad's report can name, which are all but footprints' fields of their own (other
    /// than their references and values) and footprints' zones; a violation's other items its report leaves out
    func reportableItems() -> Set<String> {
        var out: Set<String> = [Self.boardUUID]
        for node in board.root.items {
            guard let uuid = node.value("uuid") else { continue }
            out.insert(uuid)
            guard node.head == "footprint" else { continue }
            for item in node.items {
                guard let u = item.value("uuid") else { continue }
                if item.head == "zone" { continue }
                if item.head == "property", item.text(at: 0) != "Reference" && item.text(at: 0) != "Value" { continue }
                out.insert(u)
            }
        }
        return out
    }

    /// The board's layers' names as KiCad gives them (BOARD::GetLayerName: the user's name for one where the board
    /// has it), by their own names
    func layerNames() -> [String: String] {
        var out: [String: String] = [:]
        for l in board.root["layers"]?.arguments ?? [] {
            guard let name = l.text(at: 0) else { continue }
            out[name] = l.text(at: 2).flatMap { $0.isEmpty ? nil : $0 } ?? name
        }
        return out
    }

    /// BOARD_ITEM::LayerMaskDescribe: all the board's copper, or its first copper layer, else its first technical
    /// layer, else its first layer, of the board's layers it is on ("and others" if it is on more of those)
    func layerMaskDescribe(_ layers: Set<String>, _ names: [String: String]) -> String {
        let enabled = layers.filter { names[$0] != nil || world.layerIndex[$0] != nil }
        let copper = enabled.filter { world.layerIndex[$0] != nil }
        if copper.count == world.copperLayers { return "all copper layers" }
        let tech = enabled.intersection(Self.frontMask.union(Self.backMask).subtracting(["F.Cu", "B.Cu"]))
        for group in [copper, tech, enabled] {
            guard let first = group.min(by: { (Self.layerID($0) ?? Int.max) < (Self.layerID($1) ?? Int.max) }) else { continue }
            return (names[first] ?? first) + (group.count > 1 ? " and others" : "")
        }
        return "no layers"
    }

    /// PCB_FIELD::GetItemDescription and PCB_TEXT's of a footprint's text: the field's name, or its text as shown
    private func textDescription(_ node: SExpr, _ fp: SExpr, _ reference: String) -> String {
        let shown = BoardWorld.textStrokes(node, footprint: fp)?.shownText ?? BoardText.textArgument(node, 1) ?? ""
        var field: String?
        if node.head == "property" {
            field = node.text(at: 0)
        } else if node.text(at: 0) == "reference" {
            field = "Reference"
        } else if node.text(at: 0) == "value" {
            field = "Value"
        }
        guard let field else { return "Footprint text of \(reference) (\(shown))" }
        switch field {
        case "Reference": return "Reference field of \(reference)"
        case "Value": return "Value field of \(reference) (\(shown))"
        case "Footprint": return "Footprint field of \(reference) (\(shown))"
        case "Datasheet": return "Datasheet field of \(reference) (\(shown))"
        case "": return "Field of \(reference) (\(shown))"
        default: return "\(field) field of \(reference) (\(shown))"
        }
    }

    /// ZONE::GetItemDescription (a footprint's zone's says nothing of its footprint)
    private func zoneDescription(_ node: SExpr, net: String, _ layerName: [String: String]) -> String {
        // (its layers in KiCad's order of them: the copper ones F.Cu, B.Cu, then the inner ones, then the rest)
        let named = node["layers"]?.arguments.map(\.text) ?? node.value("layer").map { [$0] } ?? []
        let byIndex = Dictionary(uniqueKeysWithValues: world.layerIndex.map { ($0.value, $0.key) })
        let others = named.filter { world.layerIndex[$0] == nil }.sorted { (Self.layerID($0) ?? Int.max) < (Self.layerID($1) ?? Int.max) }
        let layers = (kicadLayerOrder.compactMap { byIndex[$0] }.filter(named.contains) + others).map { layerName[$0] ?? $0 }
        var on: String
        switch layers.count {
        case 0: on = ""
        case 1: on = "on \(layers[0])"
        case 2: on = "on \(layers[0]) and \(layers[1])"
        case 3: on = "on \(layers[0]), \(layers[1]) and \(layers[2])"
        default: on = "on \(layers[0]), \(layers[1]) and \(layers.count - 2) more"
        }
        let name = node.value("name").flatMap { $0.isEmpty ? nil : $0 }
        if node["keepout"] != nil { return name.map { "Rule area '\($0)' \(on)" } ?? "Rule Area \(on)" }
        let priority = node.value("priority") ?? "0"
        return (name.map { "Zone '\($0)' [\(net)] " } ?? "Zone [\(net)] ") + "\(on), priority \(priority)"
    }

    private func zoneCorner(_ node: SExpr) -> IPoint? {
        node["polygon"]?["pts"]?.arguments.first { $0.head == "xy" }.map(BoardWorld.point)
    }
}
