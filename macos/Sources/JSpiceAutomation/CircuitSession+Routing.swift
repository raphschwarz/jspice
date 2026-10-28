import Foundation
import KiCadKit
import KiCadLink
import KiCadRouter

/// The board routed by AI agents with the router the PCB view routes with (KiCad's, brought over): each connection
/// still to route, a track from one end to the other, walking round what is in the way at the board's clearances, as
/// a person routing it in the app would; and tracks taken off again. The tracks go to the board as one change: to
/// KiCad's open editor (its Undo takes it back), else to the board's file.
extension CircuitSession {
    static let routingTools: [Tool] = [
        Tool(name: "pcb_route",
             description: "Routes the board's connections still to route with KiCad's interactive router (JSpice's PCB view's Route tool): for each connection, a track from one pad to the other, in 45° lines, walking round pads, tracks and holes in the way at the board's clearances, as wide as its net class's tracks (the supplies' and ground's wider). A connection the router cannot get through on its layer (the top unless layer says otherwise, or the side a one-sided pad is on) is tried on the other side, and is left unrouted if that fails too. The tracks go to the board as one change: in KiCad's open editor (its Undo takes them back), else in the board's file. Returns what was routed, what was not, and how many connections are left; pcb_drc checks the result. Ground and supplies are often better left to a pour.",
             inputSchema: schema(["nets": ["type": "array", "items": ["type": "string"], "description": "Only these nets (by default every net with a connection to route)"],
                                  "skip_nets": ["type": "array", "items": ["type": "string"], "description": "Nets to leave unrouted (such as \"GND\", for a pour)"],
                                  "layer": string("\"top\" (the default), \"bottom\", or a copper layer's name (\"In1.Cu\")"),
                                  "width_mm": ["type": "number", "description": "The tracks' width (by default their net class's)"],
                                  "max": ["type": "integer", "description": "At most this many connections (default 200)"]]),
             run: { session, arguments in try session.pcbRoute(arguments) }),
        Tool(name: "pcb_pour",
             description: "Pours copper of a net (by default the ground net) over the whole board on the layers given (by default the bottom), as KiCad's zones: kept clear of other nets' copper, joined to the net's pads by thermal reliefs, and filled as KiCad fills them (by KiCad in its open editor; else in the board's file by JSpice's port of KiCad's zone filler, or KiCad's command line for what the port does not fill yet; filled_by says which). fill_only fills the board's zones again (after routing changes them) without adding one. Returns the zones and the connections left to route.",
             inputSchema: schema(["net": string("The net to pour (default: the board's ground net, GND)"),
                                  "layers": ["type": "array", "items": ["type": "string"], "description": "\"top\", \"bottom\" or copper layer names (default: bottom)"],
                                  "fill_only": ["type": "boolean", "description": "Only fill the board's zones again"],
                                  "stitch_pitch_mm": ["type": "number", "description": "Then stitching vias of the net every this many mm where its pours are filled on both sides and there is room (5 is usual), and the pours filled again round them"]]),
             run: { session, arguments in try session.pcbPour(arguments) }),
        Tool(name: "pcb_net_class",
             description: "The board's net classes (the widths and gaps the router routes each net with, kept in the board's KiCad project): with no name, lists them; with a name, sets that class's track width, clearance, via diameter and drill (mm) and the nets it takes (names or patterns such as \"+*V\"), adding the class if the board has none of that name. Refused while KiCad has the board open (change them in its Board Setup then).",
             inputSchema: schema(["name": string("The net class (\"Default\", \"Power\"…)"),
                                  "track_width_mm": ["type": "number"], "clearance_mm": ["type": "number"],
                                  "via_diameter_mm": ["type": "number"], "via_drill_mm": ["type": "number"],
                                  "nets": ["type": "array", "items": ["type": "string"], "description": "The nets the class takes, by name or pattern"]]),
             run: { session, arguments in try session.pcbNetClass(arguments) }),
        Tool(name: "pcb_outline",
             description: "The board's outline, a rectangle: with fit, drawn round the parts (margin_mm away, 5 by default, its corners on whole millimetres); else width_mm by height_mm from its top left corner (a board with no outline gets one beside its parts), its corners rounded to corner_radius_mm (0: square; by default as they are). Pours drawn to the outline follow it and are filled again. Refused when the outline is not one rectangle (round cut-outs aside). The change goes to the board as pcb_route's do. With no arguments, describes the outline.",
             inputSchema: schema(["fit": ["type": "boolean", "description": "Draw it round the parts"],
                                  "margin_mm": ["type": "number", "description": "With fit, how far from the parts (default 5)"],
                                  "width_mm": ["type": "number"], "height_mm": ["type": "number"],
                                  "corner_radius_mm": ["type": "number", "description": "Its corners' radius, 0 for square corners"]]),
             run: { session, arguments in try session.pcbOutline(arguments) }),
        Tool(name: "pcb_mounting_holes",
             description: "Mounting holes (KiCad's MountingHole footprints, unplated, for M2, M2.5, M3 or M4 screws) in the corners of the board's rectangular outline, a few millimetres in from its sides: board-only parts, H1, H2…, which the schematic's updates leave alone. A corner with a hole already is left as it is. The change goes to the board as pcb_route's do.",
             inputSchema: schema(["screw": string("M2, M2.5, M3 (the default) or M4")]),
             run: { session, arguments in try session.pcbMountingHoles(arguments) }),
        Tool(name: "pcb_unroute",
             description: "Takes tracks and vias off the board: those of the nets named, or all of them. As one change, as pcb_route makes its own.",
             inputSchema: schema(["nets": ["type": "array", "items": ["type": "string"], "description": "The nets whose tracks and vias to take off"],
                                  "all": ["type": "boolean", "description": "Every track and via on the board"]]),
             run: { session, arguments in try session.pcbUnroute(arguments) }),
    ]

    /// Where a change to the board went
    static func place(_ live: KiCadLiveBoard.Applied?) -> String {
        switch live {
        case nil: return "the board's file"
        case .reloaded?: return "KiCad's PCB editor, which read the board's file again"
        default: return "KiCad's PCB editor, as one change its Undo takes back"
        }
    }

    func pcbRoute(_ arguments: [String: Any]) throws -> Any {
        let only = (arguments["nets"] as? [String]).map(Set.init)
        let skip = Set(arguments["skip_nets"] as? [String] ?? [])
        let width = try Self.number(arguments["width_mm"], "width_mm")
        if let width, !(0.05...10).contains(width) { throw ToolError("width_mm should be between 0.05 and 10") }
        let most = Int(try Self.number(arguments["max"], "max") ?? 200)
        return try withBoard { link -> Any in
            guard link.exists else { throw ToolError("The circuit has no board yet: pcb_create makes one") }
            let board = try link.board().board
            let session = BoardEditing(board: board, project: link.projectSettings())
            let layer: String
            switch (arguments["layer"] as? String ?? "top").lowercased() {
            case "top", "front", "f.cu": layer = "F.Cu"
            case "bottom", "back", "b.cu": layer = "B.Cu"
            default:
                let name = arguments["layer"] as? String ?? ""
                guard session.layers.contains(name) else {
                    throw ToolError("layer should be \"top\", \"bottom\" or one of \(session.layers.joined(separator: ", "))")
                }
                layer = name
            }
            if let only {
                let nets = Set(KiCadConnectivity(board).ratsnest().map(\.net))
                let missing = only.subtracting(nets)
                if missing == only { throw ToolError("No connections to route on \(missing.sorted().joined(separator: ", ")): pcb_status lists those left") }
            }
            let routing = session.routeConnections(nets: only, skip: skip, layer: layer, width: width, most: most)
            let added = routing.edit?.added.count ?? 0
            var result: [String: Any] = ["routed": routing.routed, "not_routed": routing.failed, "tracks_and_vias_added": added,
                                         "unrouted": routing.left]
            if added > 0 {
                let (_, live) = try link.apply(session.board, from: board, message: "Route (JSpice)")
                result["changed_in"] = Self.place(live)
                result["next"] = "pcb_drc checks the board; pcb_unroute takes tracks off again"
            }
            return result
        }
    }

    func pcbPour(_ arguments: [String: Any]) throws -> Any {
        try withBoard { link -> Any in
            guard link.exists else { throw ToolError("The circuit has no board yet: pcb_create makes one") }
            var result: [String: Any] = [:]
            if arguments["fill_only"] as? Bool != true {
                let before = try link.board().board
                let session = BoardEditing(board: before, project: link.projectSettings())
                let names = (arguments["layers"] as? [String] ?? ["bottom"]).map { name -> String in
                    switch name.lowercased() {
                    case "top", "front": return session.layers.first ?? "F.Cu"
                    case "bottom", "back": return session.layers.last ?? "B.Cu"
                    default: return name
                    }
                }
                for name in names where !session.layers.contains(name) {
                    throw ToolError("No copper layer \(name): the board's are \(session.layers.joined(separator: ", "))")
                }
                guard let net = (arguments["net"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? session.groundNets.first else {
                    throw ToolError("The board has no ground net: name one with net")
                }
                guard Set(session.router.world.netNames.values).contains(net) else { throw ToolError("The board has no net \(net)") }
                guard let edit = session.addPour(net: net, layers: names) else { throw ToolError("The board has no outline to pour within") }
                let (_, live) = try link.apply(edit.after, from: before, message: "Add \(net) Pour (JSpice)")
                result["changed_in"] = Self.place(live)
                result["added"] = ["net": net, "layers": names]
            }
            var (board, engine) = try link.fillZonesReporting()
            result["filled_by"] = engine.rawValue
            if let pitch = try Self.number(arguments["stitch_pitch_mm"], "stitch_pitch_mm") {
                guard pitch >= 1 else { throw ToolError("stitch_pitch_mm should be 1 or more") }
                let session = BoardEditing(board: board, project: link.projectSettings())
                guard let net = (arguments["net"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? session.groundNets.first else {
                    throw ToolError("The board has no ground net: name one with net")
                }
                if let edit = session.stitchVias(net: net, pitch: pitch) {
                    _ = try link.apply(edit.after, from: board, message: edit.name + " (JSpice)")
                    board = try link.fillZones()
                    result["stitching_vias"] = edit.added.count
                } else {
                    result["stitching_vias"] = 0
                    result["stitching_note"] = "No room: \(net) must be poured and filled on both the top and the bottom"
                }
            }
            result["zones"] = board.zones.filter { !$0.isRuleArea }.map { z -> [String: Any] in
                ["net": z.net ?? "", "layers": z.layers, "filled": !z.fills.isEmpty]
            }
            result["unrouted"] = KiCadConnectivity(board).ratsnest().count
            result["next"] = "pcb_drc checks the board"
            return result
        }
    }

    func pcbNetClass(_ arguments: [String: Any]) throws -> Any {
        try withBoard { link -> Any in
            guard link.exists else { throw ToolError("The circuit has no board yet: pcb_create makes one") }
            func describe(_ classes: [KiCadProject.NetClass]) -> [[String: Any]] {
                classes.map { ["name": $0.name, "track_width_mm": $0.trackWidth, "clearance_mm": $0.clearance,
                               "via_diameter_mm": $0.viaDiameter, "via_drill_mm": $0.viaDrill, "nets": $0.patterns] }
            }
            guard let name = (arguments["name"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else {
                return ["net_classes": describe(link.netClasses())]
            }
            var nc = link.netClasses().first { $0.name == name } ?? KiCadProject.NetClass(name: name, trackWidth: 0.25, clearance: 0.2)
            if let v = try Self.number(arguments["track_width_mm"], "track_width_mm") { nc.trackWidth = v }
            if let v = try Self.number(arguments["clearance_mm"], "clearance_mm") { nc.clearance = v }
            if let v = try Self.number(arguments["via_diameter_mm"], "via_diameter_mm") { nc.viaDiameter = v }
            if let v = try Self.number(arguments["via_drill_mm"], "via_drill_mm") { nc.viaDrill = v }
            if let nets = arguments["nets"] as? [String] { nc.patterns = nets }
            guard nc.trackWidth > 0, nc.clearance >= 0, nc.viaDrill > 0, nc.viaDiameter > nc.viaDrill else {
                throw ToolError("Widths must be positive, and a via wider than its drill")
            }
            try link.setNetClass(nc)
            return ["net_classes": describe(link.netClasses()), "next": "pcb_route routes with them"]
        }
    }

    func pcbOutline(_ arguments: [String: Any]) throws -> Any {
        let fit = arguments["fit"] as? Bool ?? false
        let margin = try Self.number(arguments["margin_mm"], "margin_mm") ?? 5
        let width = try Self.number(arguments["width_mm"], "width_mm")
        let height = try Self.number(arguments["height_mm"], "height_mm")
        let radius = try Self.number(arguments["corner_radius_mm"], "corner_radius_mm")
        func describe(_ board: KiCadBoard) -> [String: Any] {
            if let (box, r) = board.outlineRectangle {
                return ["x_mm": box.minX, "y_mm": box.minY, "width_mm": box.width, "height_mm": box.height, "corner_radius_mm": r]
            }
            guard let box = board.edgeBounds, !board.outline.isEmpty else { return ["none": true] }
            return ["x_mm": box.minX, "y_mm": box.minY, "width_mm": box.width, "height_mm": box.height, "rectangle": false]
        }
        return try withBoard { link -> Any in
            guard link.exists else { throw ToolError("The circuit has no board yet: pcb_create makes one") }
            let before = try link.board().board
            guard fit || width != nil || height != nil || radius != nil else { return ["outline": describe(before)] }
            let session = BoardEditing(board: before, project: link.projectSettings())
            let edit: BoardEditing.Edit?
            if fit {
                guard margin >= 0 else { throw ToolError("margin_mm can't be negative") }
                guard before.outline.isEmpty || before.outlineRectangle != nil else {
                    throw ToolError("The board's outline is not one rectangle: change it in KiCad (pcb_open)")
                }
                edit = session.fitOutline(margin: margin)
            } else {
                let now = before.outlineRectangle
                if now == nil && !before.outline.isEmpty {
                    throw ToolError("The board's outline is not one rectangle: change it in KiCad (pcb_open)")
                }
                guard let w = width ?? now?.box.width, let h = height ?? now?.box.height else {
                    throw ToolError("The board has no outline yet: give width_mm and height_mm, or fit")
                }
                let r = radius ?? now?.radius ?? 0
                guard w > 0, h > 0, r >= 0, r <= min(w, h) / 2 else {
                    throw ToolError("width_mm and height_mm should be positive, and corner_radius_mm between 0 and half the shorter side")
                }
                edit = session.setOutline(width: w, height: h, radius: r)
            }
            guard let edit else { return ["changed": false, "outline": describe(before)] }
            var (board, live) = try link.apply(edit.after, from: before, message: edit.name + " (JSpice)")
            if board.zones.contains(where: { !$0.isRuleArea }) { board = try link.fillZones() }
            return ["changed_in": Self.place(live), "outline": describe(board)]
        }
    }

    func pcbMountingHoles(_ arguments: [String: Any]) throws -> Any {
        let screw = arguments["screw"] as? String ?? "M3"
        guard let (_, libID, inset) = BoardEditing.mountingHoles.first(where: { $0.screw.lowercased() == screw.lowercased() }) else {
            throw ToolError("screw should be one of \(BoardEditing.mountingHoles.map(\.screw).joined(separator: ", "))")
        }
        return try withBoard { link -> Any in
            guard link.exists else { throw ToolError("The circuit has no board yet: pcb_create makes one") }
            let before = try link.board().board
            guard before.outlineRectangle != nil else { throw ToolError("The board's outline is not one rectangle: pcb_outline draws one") }
            let footprint = try link.footprints().footprint(libID)
            let session = BoardEditing(board: before, project: link.projectSettings())
            guard let edit = session.addMountingHoles(footprint, libID: libID, inset: inset) else {
                return ["added": [], "note": "Each corner has a mounting hole already"]
            }
            let (_, live) = try link.apply(edit.after, from: before, message: edit.name + " (JSpice)")
            let holes = edit.after.footprints.filter { edit.footprints.contains($0.uuid) }
            return ["added": holes.map { ["reference": $0.reference, "x_mm": $0.position.x, "y_mm": $0.position.y] },
                    "footprint": libID, "changed_in": Self.place(live)]
        }
    }

    func pcbUnroute(_ arguments: [String: Any]) throws -> Any {
        let nets = Set(arguments["nets"] as? [String] ?? [])
        let all = arguments["all"] as? Bool ?? false
        guard all || !nets.isEmpty else { throw ToolError("Name the nets whose tracks to take off, or pass all") }
        return try withBoard { link -> Any in
            guard link.exists else { throw ToolError("The circuit has no board yet: pcb_create makes one") }
            let before = try link.board().board
            let after = before.copy()
            var removed = 0
            for node in after.copperItems where all || nets.contains(after.netName(node["net"]) ?? "") {
                after.root.remove(node)
                removed += 1
            }
            var result: [String: Any] = ["removed": removed]
            if removed > 0 {
                let (board, live) = try link.apply(after, from: before, message: "Unroute (JSpice)")
                result["changed_in"] = Self.place(live)
                result["unrouted"] = KiCadConnectivity(board).ratsnest().count
            }
            return result
        }
    }
}
