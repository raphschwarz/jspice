import Foundation
import CircuitKit
import KiCadKit

/// The circuit's printed circuit board, for AI agents: made in KiCad beside the circuit's file, kept in step with the
/// schematic both ways (BoardLink), checked and made ready for a board house. Driving the app, the window's own link to
/// its board is used (and the window keeps the board in step as the circuit changes); in the jspice-mcp server, the
/// circuit's file is saved again with what the board's updates record.
extension CircuitSession {
    static let pcbTools: [Tool] = [
        Tool(name: "pcb_status",
             description: "How the circuit's printed circuit board stands: whether it has one (a KiCad project beside the circuit's saved file) and whether KiCad's PCB editor has it open; each part's reference, value and footprint as the board has them (or would); whether the schematic and board agree, what bringing them together would change each way, parts deleted on the board waiting for a decision; the connections still to route, the board's size and copper layers, and each footprint's place.",
             inputSchema: schema([:]), run: { session, _ in try session.pcbStatus() }),
        Tool(name: "pcb_create",
             description: "Makes the circuit's printed circuit board: a KiCad project (circuit.kicad_pcb and .kicad_pro) beside the circuit's file, each part on a footprint from KiCad's libraries (through-hole or surface-mount where the part has no footprint of its own, chips' units packed into packages, supplies and off-board parts on pin headers), placed in the schematic's order inside an outline, the supplies and ground in a Power net class with wider tracks. Needs KiCad 10 or later installed, and the circuit saved (pass path to save it).",
             inputSchema: schema(["style": string("\"through_hole\" (the default) or \"surface_mount\": the footprints of parts without one of their own"),
                                  "copper_layers": ["type": "integer", "description": "2 (the default), 4 or 6"],
                                  "path": string("Where to save the circuit first, if it has no file yet (a .jspice file)")]),
             run: { session, arguments in try session.pcbCreate(arguments) }),
        Tool(name: "pcb_update",
             description: "Brings the board and the schematic together, as Eagle's forward and back annotation does: what was changed on the board since they were last together (a part renamed, given another value or footprint, marked not to be fitted) comes back to the schematic, then the board takes the schematic's changes (parts added, exchanged and removed, nets reconnected, the tracks following their pads). Where both changed the same thing the schematic's change stands. While KiCad's PCB editor has the board open (with KiCad's API on) the change is made there, as one change its Undo takes back; else in the board's file. A part deleted on the board is left off it until put_back or delete_from_schematic names it.",
             inputSchema: schema(["put_back": ["type": "array", "items": ["type": "string"], "description": "References of parts deleted on the board to put back on it"],
                                  "delete_from_schematic": ["type": "array", "items": ["type": "string"], "description": "References of parts deleted on the board to delete from the schematic too"],
                                  "force": ["type": "boolean", "description": "Write the board's file even though KiCad has it open out of reach (its API off): KiCad sees the change only when it reads the file again"]]),
             run: { session, arguments in try session.pcbUpdate(arguments) }),
        Tool(name: "pcb_part",
             description: "A part as its board has it: its footprint from KiCad's libraries (\"Library:Name\", such as \"Resistor_SMD:R_1206_3216Metric\"; \"\" for JSpice's own choice), whether it is on the board (a part off it is wired to it from elsewhere), whether it is fitted, and a transistor's pinout (its legs in the order of the footprint's pads: \"EBC\", \"CBE\", \"GDS\"). Returns the part's reference, value and footprint. pcb_update takes the change to the board (the app does so by itself).",
             inputSchema: schema(["part": string("The part's name in the schematic"),
                                  "footprint": string("Library:Name, or \"\" for JSpice's choice"),
                                  "on_board": ["type": "boolean", "description": "false to leave it off the board"],
                                  "fitted": ["type": "boolean", "description": "false to keep its place on the board but leave it out of the assembly"],
                                  "pinout": string("A transistor's legs in pad order, or \"\" for its footprint's own"),
                                  "lcsc": string("The part's LCSC number (\"C25804\"), for JLCPCB's assembly: the board's LCSC field and the bill of materials' part number; \"\" for none"),
                                  "plus": string("An electrolytic's + terminal, \"a\" or \"b\" (settled by the circuit's resting voltages when it first goes on the board, then kept)")],
                                 required: ["part"]),
             run: { session, arguments in try session.pcbPart(arguments) }),
        Tool(name: "pcb_footprints",
             description: "Searches KiCad's footprint libraries: footprints whose Library:Name contains every word of search (\"0805 resistor\", \"SOIC-8\", \"TO-220 vertical\"), or a library's footprints; with neither, the libraries.",
             inputSchema: schema(["search": string("Words the footprint's Library:Name contains"),
                                  "library": string("One library to list or search (optional)")]),
             run: { session, arguments in try session.pcbFootprints(arguments) }),
        Tool(name: "pcb_drc",
             description: "KiCad's design rules check of the board (as saved, or as KiCad's editor has it open): each violation with its severity and the items involved and where, the connections not yet routed, and the board's differences from the schematic. The zones are filled first.",
             inputSchema: schema([:]), run: { session, _ in try session.pcbDRC() }),
        Tool(name: "pcb_render",
             description: "A picture of the board as made (KiCad's 3D view, ray traced, with the parts' 3D models), from the top or the bottom, as a PNG file: to look at the layout.",
             inputSchema: schema(["side": string("\"top\" (the default) or \"bottom\""),
                                  "path": string("The PNG file to write (optional)")]),
             run: { session, arguments in try session.pcbRender(arguments) }),
        Tool(name: "pcb_fabricate",
             description: "The files a board house needs to make the board, in a folder: Gerbers for every layer and the drill files (zipped for upload), pick-and-place positions and the bill of materials for assembly, a STEP model, a picture, and the design rules check. maker sets the names and formats: \"jlcpcb\" (Protel extensions, one drill file, JLCPCB's BOM and CPL columns), \"pcbway\", \"oshpark\", or \"generic\" (KiCad's own names).",
             inputSchema: schema(["maker": string("\"jlcpcb\", \"pcbway\", \"oshpark\" or \"generic\" (the default)"),
                                  "folder": string("Where to put the files (by default a folder beside the board)")]),
             run: { session, arguments in try session.pcbFabricate(arguments) }),
        Tool(name: "pcb_open",
             description: "Opens the board in KiCad's PCB editor on this computer, where it is laid out and routed. With KiCad's API on, JSpice then changes the board there as the schematic changes; enable_api turns it on (KiCad reads it as it starts).",
             inputSchema: schema(["enable_api": ["type": "boolean", "description": "Turn on KiCad's API first"]]),
             run: { session, arguments in try session.pcbOpen(arguments) }),
    ]

    // MARK: - The board

    /// Does `body` with the circuit's board: the app window's, or the server's own beside the circuit's file
    func withBoard<T>(_ body: (BoardLink) throws -> T) throws -> T {
        if let boardHost { return try boardHost.withBoard(body) }
        guard let fileURL else {
            throw ToolError("The circuit has no file yet: save it (save_circuit, or pass path), and its board goes beside it")
        }
        let file = BoardLink.boardFile(for: fileURL, design: circuit.pcb)
        if ownBoard?.boardFile != file { ownBoard = BoardLink(boardFile: file) }
        guard let link = ownBoard else { throw ToolError("No board") }
        if let problem = link.problem { throw ToolError(problem) }
        return try body(link)
    }

    /// The circuit as an update left it (the board's changes brought back, and its record of the update); in the
    /// jspice-mcp server, saved to its file
    func took(_ outcome: BoardLink.Outcome, _ action: String) {
        guard outcome.result.circuitChanged else { return }
        replace(outcome.result.circuit, action)
        saveOwnFile()
    }

    func saveOwnFile() {
        guard boardHost == nil, let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(circuit).write(to: fileURL)
    }

    /// The parts of the schematic, by name, that the board's components stand for
    func partNames(_ ids: [UUID]) -> [String] {
        let top = BoardLink.topLevel(circuit)
        var seen = Set<UUID>()
        return ids.compactMap { top[$0] }.filter { seen.insert($0).inserted }.compactMap { circuit[$0]?.name }
    }

    static func rounded(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    func outcomeSummary(_ outcome: BoardLink.Outcome, _ link: BoardLink) -> [String: Any] {
        let result = outcome.result
        let place: String
        switch outcome.live {
        case nil: place = "the board's file"
        case .reloaded?: place = "KiCad's PCB editor, which read the board's file again"
        default: place = "KiCad's PCB editor, as one change its Undo takes back"
        }
        return ["board": link.boardFile.path, "changed_in": place,
                "from_board": result.applied.map(\.description),
                "to_board": result.report.actions.map(\.text),
                "problems": (result.report.errors + result.report.warnings).map(\.text) + result.warnings,
                "deleted_on_board": result.removed.map(\.description),
                "unassigned_footprints": result.unassigned, "notes": result.notes,
                "footprints": outcome.board.footprints.count,
                "unrouted": KiCadConnectivity(outcome.board).ratsnest().count]
    }

    // MARK: - Tools

    func pcbStatus() throws -> Any {
        let design = circuit.pcb ?? PCBDesign()
        let built = PCBNetlistBuilder.netlist(circuit, design: design)
        var result: [String: Any] = [
            "style": design.style == .surfaceMount ? "surface_mount" : "through_hole",
            "parts": built.netlist.components.map { c -> [String: Any] in
                ["reference": c.reference, "value": c.value, "footprint": c.footprint, "on_board": !c.excludeFromBoard,
                 "fitted": !c.doNotPopulate, "schematic": partNames(built.parts[c.reference] ?? [])]
            },
            "unassigned_footprints": built.unassigned, "notes": built.notes,
        ]
        guard boardHost != nil || fileURL != nil else {
            result["board"] = NSNull()
            result["next"] = "Save the circuit (save_circuit), then pcb_create makes its board beside it"
            return result
        }
        try withBoard { link in
            result["board"] = link.boardFile.path
            result["open_in_kicad"] = link.isOpenInKiCad
            result["kicad_api_on"] = link.apiEnabled
            guard link.exists else {
                result["exists"] = false
                result["copper_layers"] = design.copperLayers
                result["next"] = "pcb_create makes the board"
                return
            }
            let (board, live) = try link.board()
            let check = PCBSync.sync(circuit, board: board.copy(), library: try link.footprints())
            let picture = KiCadBoardPicture(board)
            result["exists"] = true
            result["live_in_kicad"] = live != nil
            result["in_step"] = check.applied.isEmpty && check.removed.isEmpty && check.report.actions.isEmpty
            result["to_board"] = check.report.actions.map(\.text)
            result["from_board"] = check.applied.map(\.description)
            result["deleted_on_board"] = check.removed.map(\.description)
            result["unrouted"] = picture.airwires.count
            result["unrouted_connections"] = picture.airwires.prefix(60).map { "\($0.net): \($0.ends.joined(separator: " to "))" }
            if let size = picture.boardSize { result["size_mm"] = [Self.rounded(size.width), Self.rounded(size.height)] }
            result["copper_layers"] = picture.copperLayers
            result["tracks"] = board.tracks.count
            result["vias"] = board.vias.count
            result["zones"] = board.zones.count
            result["footprints"] = board.footprints.map { f -> [String: Any] in
                ["reference": f.reference, "value": f.value, "footprint": f.libID,
                 "at_mm": [Self.rounded(f.position.x), Self.rounded(f.position.y)], "rotation": f.rotation,
                 "side": f.isOnBack ? "bottom" : "top", "locked": f.isLocked, "linked_to_schematic": f.path != nil]
            }
        }
        return result
    }

    func pcbCreate(_ arguments: [String: Any]) throws -> Any {
        if let path = arguments["path"] as? String, !path.isEmpty, boardHost == nil {
            _ = try save(["path": path])
        }
        var design = circuit.pcb ?? PCBDesign()
        if let style = arguments["style"] as? String {
            switch style.lowercased().replacingOccurrences(of: "-", with: "_") {
            case "through_hole", "throughhole", "tht": design.style = .throughHole
            case "surface_mount", "surfacemount", "smd", "smt": design.style = .surfaceMount
            default: throw ToolError("style should be \"through_hole\" or \"surface_mount\", not \"\(style)\"")
            }
        }
        if let layers = try Self.number(arguments["copper_layers"], "copper_layers") {
            guard [2, 4, 6].contains(Int(layers)) else { throw ToolError("copper_layers should be 2, 4 or 6") }
            design.copperLayers = Int(layers)
        }
        if design != (circuit.pcb ?? PCBDesign()) { change("Board Settings") { $0.pcb = design } }
        let title = fileURL?.deletingPathExtension().lastPathComponent ?? "Circuit"
        return try withBoard { link -> Any in
            guard !link.exists else {
                throw ToolError("The circuit already has a board (\(link.boardFile.path)): pcb_update brings it up to date with the schematic")
            }
            let outcome = try link.create(circuit, title: title)
            took(outcome, "Make Board")
            var summary = outcomeSummary(outcome, link)
            summary["project"] = link.projectFile.path
            summary["next"] = "Lay out and route the board in KiCad's PCB editor (pcb_open); pcb_status and pcb_drc check it"
            return summary
        }
    }

    func pcbUpdate(_ arguments: [String: Any]) throws -> Any {
        let putBack = arguments["put_back"] as? [String] ?? []
        let delete = arguments["delete_from_schematic"] as? [String] ?? []
        let force = arguments["force"] as? Bool ?? false
        return try withBoard { link -> Any in
            guard link.exists else { throw ToolError("The circuit has no board yet: pcb_create makes one") }
            var waiting: [PCBSync.Change] = []
            if !putBack.isEmpty || !delete.isEmpty {
                waiting = PCBSync.sync(circuit, board: try link.board().board.copy(), library: try link.footprints()).removed
            }
            func changes(_ references: [String]) throws -> [PCBSync.Change] {
                try references.map { reference in
                    guard let change = waiting.first(where: { if case .removed(_, reference) = $0 { return true } else { return false } }) else {
                        let names = waiting.compactMap { c -> String? in if case .removed(_, let r) = c { return r } else { return nil } }
                        throw ToolError("\(reference) is not a part deleted on the board" + (names.isEmpty ? "" : ": those are \(names.joined(separator: ", "))"))
                    }
                    return change
                }
            }
            let back = try changes(putBack), gone = try changes(delete)
            if !gone.isEmpty { change("Delete as on the Board") { circuit in for c in gone { PCBSync.delete(c, from: &circuit) } } }
            let outcome = try link.sync(circuit, putBack: Set(back.flatMap(\.parts)), force: force)
            took(outcome, "Update Board")
            return outcomeSummary(outcome, link)
        }
    }

    func pcbPart(_ arguments: [String: Any]) throws -> Any {
        let name = try Self.text(arguments, "part")
        let element = circuit.elements[try index(ofPart: name)]
        let id = element.id.uuidString
        var design = circuit.pcb ?? PCBDesign()
        var footprint: String?
        if let text = arguments["footprint"] as? String {
            let libID = text.trimmingCharacters(in: .whitespaces)
            if libID.isEmpty {
                design.footprints[id] = nil
            } else {
                guard KiCadFootprintLibrary.split(libID) != nil else {
                    throw ToolError("A footprint is Library:Name, such as \"Resistor_SMD:R_1206_3216Metric\" (pcb_footprints finds them)")
                }
                design.footprints[id] = libID
                footprint = libID
            }
        }
        if let on = arguments["on_board"] as? Bool { if on { design.offBoard.remove(id) } else { design.offBoard.insert(id) } }
        if let fitted = arguments["fitted"] as? Bool { if fitted { design.doNotPopulate.remove(id) } else { design.doNotPopulate.insert(id) } }
        if let pinout = arguments["pinout"] as? String {
            let legs = pinout.uppercased().trimmingCharacters(in: .whitespaces)
            guard legs.allSatisfy({ "EBCGDS".contains($0) }) else { throw ToolError("A pinout is the legs' letters in pad order: E, B, C or G, D, S") }
            design.pinouts[id] = legs.isEmpty ? nil : legs
        }
        if let number = arguments["lcsc"] as? String {
            let trimmed = number.trimmingCharacters(in: .whitespaces)
            design.partNumbers[id] = trimmed.isEmpty ? nil : trimmed
        }
        if let plus = arguments["plus"] as? String {
            guard element.terminalNames.contains(plus) else { throw ToolError("plus should be one of \(element.terminalNames.joined(separator: ", "))") }
            design.polarity[id] = plus
        }
        if design != (circuit.pcb ?? PCBDesign()) {
            change("Change \(name) on the Board") { $0.pcb = design }
            saveOwnFile()
        }
        let built = PCBNetlistBuilder.netlist(circuit, design: circuit.pcb)
        var result: [String: Any] = ["part": name]
        if let c = built.netlist.components.first(where: { (built.parts[$0.reference] ?? []).contains(element.id) }) {
            result["reference"] = c.reference
            result["value"] = c.value
            result["footprint"] = c.footprint
            result["on_board"] = !c.excludeFromBoard
            result["fitted"] = !c.doNotPopulate
            if let plus = built.design.polarity[id] { result["plus"] = plus }
            if let number = c.fields.first(where: { $0.0 == "LCSC" })?.1 { result["lcsc"] = number }
        } else {
            result["on_board"] = false
        }
        if let footprint, let library = try? footprintLibrary(), !library.has(footprint) {
            result["warning"] = "KiCad's libraries have no \(footprint): pcb_footprints finds the ones they have"
        }
        result["next"] = boardHost != nil ? "The app takes the change to the board" : "pcb_update takes the change to the board"
        return result
    }

    /// KiCad's footprint libraries, as the board would use them
    func footprintLibrary() throws -> KiCadFootprintLibrary {
        if boardHost != nil || fileURL != nil { return try withBoard { try $0.footprints() } }
        guard let installation = KiCadInstallation.find() else { throw ToolError("KiCad is not installed: JSpice lays out boards with KiCad 10 or later") }
        return KiCadFootprintLibrary(installation: installation)
    }

    func pcbFootprints(_ arguments: [String: Any]) throws -> Any {
        let library = try footprintLibrary()
        let words = (arguments["search"] as? String ?? "").lowercased().split(separator: " ").map(String.init)
        let only = (arguments["library"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let only, library.libraries[only] == nil { throw ToolError("No footprint library \(only)") }
        if only == nil && words.isEmpty { return ["libraries": library.libraries.keys.sorted()] }
        let names = (only.map { [$0] } ?? library.libraries.keys.sorted()).flatMap { lib in library.footprints(in: lib).map { lib + ":" + $0 } }
        let found = names.filter { id in let l = id.lowercased(); return words.allSatisfy { l.contains($0) } }
        return ["footprints": Array(found.prefix(80)), "more": max(0, found.count - 80)]
    }

    func pcbDRC() throws -> Any {
        let report = try withBoard { try $0.drc() }
        func item(_ v: KiCadFabrication.Violation) -> [String: Any] {
            ["type": v.type, "severity": v.severity, "description": v.description,
             "items": v.items.map { i -> [String: Any] in
                 var d: [String: Any] = ["description": i.description]
                 if let p = i.position { d["at_mm"] = [Self.rounded(p.x), Self.rounded(p.y)] }
                 return d
             }]
        }
        return ["clean": report.isClean, "errors": report.errors.count, "warnings": report.violations.count - report.errors.count,
                "violations": report.violations.prefix(100).map(item), "unrouted": report.unconnected.count,
                "unrouted_items": report.unconnected.prefix(40).map(item),
                "schematic_differences": report.parity.prefix(40).map(item), "kicad": report.kicadVersion]
    }

    func pcbRender(_ arguments: [String: Any]) throws -> Any {
        let side = (arguments["side"] as? String ?? "top").lowercased()
        guard side == "top" || side == "bottom" else { throw ToolError("side should be \"top\" or \"bottom\"") }
        return try withBoard { link -> Any in
            let path = (arguments["path"] as? String).flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            let file = path.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
                .appendingPathComponent(link.boardFile.deletingPathExtension().lastPathComponent + "-\(side).png")
            try link.render(to: file, side: side)
            return ["image": file.path]
        }
    }

    func pcbFabricate(_ arguments: [String: Any]) throws -> Any {
        let name = (arguments["maker"] as? String ?? "generic").lowercased().replacingOccurrences(of: " ", with: "")
        guard let maker = KiCadFabrication.Maker(rawValue: name) else {
            throw ToolError("maker should be \"jlcpcb\", \"pcbway\", \"oshpark\" or \"generic\", not \"\(name)\"")
        }
        return try withBoard { link -> Any in
            let folder = (arguments["folder"] as? String).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? link.boardFile.deletingLastPathComponent()
                    .appendingPathComponent(link.boardFile.deletingPathExtension().lastPathComponent + "-" + (maker == .generic ? "fabrication" : maker.rawValue))
            let package = try link.fabricate(into: folder, maker: maker)
            var result: [String: Any] = ["folder": package.folder.path, "gerbers": package.gerbers.map(\.lastPathComponent),
                                         "drill": package.drill.map(\.lastPathComponent)]
            if let zip = package.zip { result["zip"] = zip.path }
            if let file = package.positions { result["positions"] = file.path }
            if let file = package.bom { result["bom"] = file.path }
            if let file = package.step { result["step"] = file.path }
            if let file = package.render { result["picture"] = file.path }
            if let drc = package.drc {
                result["drc"] = ["clean": drc.isClean, "errors": drc.errors.count, "unrouted": drc.unconnected.count] as [String: Any]
            }
            return result
        }
    }

    func pcbOpen(_ arguments: [String: Any]) throws -> Any {
        try withBoard { link -> Any in
            guard link.exists else { throw ToolError("The circuit has no board yet: pcb_create makes one") }
            if arguments["enable_api"] as? Bool == true { try link.enableAPI() }
            try link.openInKiCad()
            var result: [String: Any] = ["opened": link.boardFile.path, "kicad_api_on": link.apiEnabled]
            if !link.apiEnabled {
                result["note"] = "KiCad's API is off: while KiCad has the board open, JSpice cannot change it there (enable_api, or KiCad's Preferences ▸ Plugins ▸ Enable KiCad API)"
            }
            return result
        }
    }
}
