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
            func wanted(_ wire: KiCadConnectivity.Airwire) -> Bool { (only?.contains(wire.net) ?? true) && !skip.contains(wire.net) }
            var routed: [String] = [], failed: [String] = []
            var tried = Set<KiCadConnectivity.Airwire>()
            var added = 0
            var wires = KiCadConnectivity(session.board).ratsnest()
            while routed.count + failed.count < most, let wire = wires.first(where: { wanted($0) && !tried.contains($0) }) {
                tried.insert(wire)
                let name = "\(wire.net): \(wire.ends.isEmpty ? "tracks" : wire.ends.joined(separator: " to "))"
                // its layer, then the other side
                var done = false
                for l in [layer, layer == "F.Cu" ? "B.Cu" : "F.Cu"] where !done {
                    let start = session.startLayer(at: wire.from, preferring: l)
                    guard session.start(at: wire.from, layer: start, width: width) else { continue }
                    session.move(to: wire.to)
                    if let edit = session.fix(at: wire.to) {
                        added += edit.added.count
                        done = true
                    } else {
                        session.cancel()
                    }
                }
                if done { routed.append(name) } else { failed.append(name) }
                wires = KiCadConnectivity(session.board).ratsnest()
            }
            var result: [String: Any] = ["routed": routed, "not_routed": failed, "tracks_and_vias_added": added,
                                         "unrouted": wires.count]
            if added > 0 {
                let (_, live) = try link.apply(session.board, from: board, message: "Route (JSpice)")
                result["changed_in"] = Self.place(live)
                result["next"] = "pcb_drc checks the board; pcb_unroute takes tracks off again"
            }
            return result
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
