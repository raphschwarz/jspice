import Foundation
import KiCadKit

/// (a check holds the board it was made of, its own copy, which it only reads: it may run anywhere)
extension BoardDRC: @unchecked Sendable {}

extension BoardDRC {
    /// The checks BoardDRC makes, by KiCad's keys: the rest of KiCad's (silkscreen, solder mask,
    /// zones' own checks, the schematic's) it leaves to kicad-cli
    public static let checksMade: [String] = [
        "track_width", "via_diameter", "drill_out_of_range", "microvia_drill_out_of_range", "annular_width", "hole_to_hole",
        "holes_co_located", "clearance", "hole_clearance", "shorting_items", "tracks_crossing", "copper_edge_clearance",
        "track_dangling", "via_dangling", "unconnected_items", "items_not_allowed",
        "courtyards_overlap", "missing_courtyard", "malformed_courtyard", "pth_inside_courtyard", "npth_inside_courtyard",
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
        let drawingKinds = ["line": "Segment", "rect": "Rectangle", "circle": "Circle", "arc": "Arc", "poly": "Polygon", "curve": "Bezier"]
        func drawing(_ node: SExpr, of reference: String?, placement: BoardWorld.FootprintPlacement?) {
            guard let head = node.head, let kind = drawingKinds[String(head.dropFirst(3))], let uuid = node.value("uuid") else { return }
            let layer = node.value("layer") ?? ""
            let onCopper = world.layerIndex[layer] != nil
            var d = kind + (onCopper ? " [\(net(node))]" : "")
            if let reference { d += " of \(reference)" }
            d += " on \(layer)"
            let at = world.readDrawing(node, placement: placement).map { $0.kind == .poly ? $0.poly.first ?? $0.start : $0.start }
            out[uuid] = (d, at.map(mm))
        }
        for node in board.root.items {
            guard let uuid = node.value("uuid") else { continue }
            switch node.head ?? "" {
            case "segment":
                let s = BoardWorld.point(node["start"]), e = BoardWorld.point(node["end"])
                out[uuid] = ("Track [\(net(node))] on \(node.value("layer") ?? ""), length \(length(s.distance(e)))", mm(s))
            case "arc":
                let s = BoardWorld.point(node["start"])
                let a = ShapeArc(start: s, mid: BoardWorld.point(node["mid"]), end: BoardWorld.point(node["end"]))
                out[uuid] = ("Track (arc) [\(net(node))] on \(node.value("layer") ?? ""), length \(length(a.length))", mm(s))
            case "via":
                let layers = node["layers"]?.arguments.map(\.text) ?? ["F.Cu", "B.Cu"]
                let kind = node.arguments.contains { $0.text == "blind" } ? "Blind via"
                    : node.arguments.contains { $0.text == "buried" } ? "Buried via"
                    : node.arguments.contains { $0.text == "micro" } ? "Micro via" : "Via"
                out[uuid] = ("\(kind) [\(net(node))] on \(layers.first ?? "") - \(layers.last ?? "")", mm(BoardWorld.point(node["at"])))
            case "zone":
                out[uuid] = (zoneDescription(node, net: net(node)), zoneCorner(node).map(mm))
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
                case .smd, .conn: d = "Pad\(number) [\(net(node))] of \(reference) on \(node["layers"]?.text(at: 0) ?? "")"
                }
                out[uuid] = (d, mm(p.pad.pos))
            }
            for node in fp.items {
                if node.head == "zone", let uuid = node.value("uuid") {
                    out[uuid] = (zoneDescription(node, net: net(node)), zoneCorner(node).map(mm))
                } else {
                    drawing(node, of: reference, placement: placement)
                }
            }
        }
        return out
    }

    /// ZONE::GetItemDescription (a footprint's zone's says nothing of its footprint)
    private func zoneDescription(_ node: SExpr, net: String) -> String {
        // (its layers in KiCad's order of them: the copper ones F.Cu, B.Cu, then the inner ones, then the rest)
        let named = node["layers"]?.arguments.map(\.text) ?? node.value("layer").map { [$0] } ?? []
        let byIndex = Dictionary(uniqueKeysWithValues: world.layerIndex.map { ($0.value, $0.key) })
        let layers = kicadLayerOrder.compactMap { byIndex[$0] }.filter(named.contains) + named.filter { world.layerIndex[$0] == nil }
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
