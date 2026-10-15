import Foundation

/// What KiCad makes from a board for checking it and having it made, all through kicad-cli: the design rules check,
/// Gerbers and drill files for the board house, the position file and the bill of materials for assembly, a STEP
/// model for the enclosure, a 3D picture
public struct KiCadFabrication: Sendable {
    public let installation: KiCadInstallation

    public init(installation: KiCadInstallation) { self.installation = installation }

    // MARK: - Design rules check

    public struct Violation: Sendable, Hashable {
        public struct Item: Sendable, Hashable {
            public var description: String
            public var position: KiCadPoint?
            public var uuid: String
        }

        /// KiCad's key for the rule, "clearance", "unconnected_items", "shorting_items"…
        public var type: String
        public var description: String
        /// error, warning or exclusion
        public var severity: String
        public var items: [Item]
    }

    public struct DRCReport: Sendable {
        public var violations: [Violation]
        /// The connections not yet routed
        public var unconnected: [Violation]
        /// The schematic's and the board's differences, where KiCad could check them
        public var parity: [Violation]
        public var kicadVersion: String

        public var errors: [Violation] { violations.filter { $0.severity == "error" } }
        public var isClean: Bool { violations.isEmpty && unconnected.isEmpty }
    }

    /// Runs KiCad's design rules check on `board` (zones refilled first, as the PCB editor does before checking)
    public func drc(_ board: URL, refillZones: Bool = true) throws -> DRCReport {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = folder.appendingPathComponent("drc.json")
        var arguments = ["pcb", "drc", "--format", "json", "--units", "mm", "--severity-error", "--severity-warning",
                         "-o", out.path]
        if refillZones { arguments.append("--refill-zones") }
        try run(arguments + [board.path])
        return try Self.parseDRC(Data(contentsOf: out))
    }

    /// Reads kicad-cli's DRC report (https://schemas.kicad.org/drc.v1.json)
    public static func parseDRC(_ data: Data) throws -> DRCReport {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KiCadCLI.Failure(description: "KiCad's DRC report could not be read")
        }
        func violations(_ key: String) -> [Violation] {
            (json[key] as? [[String: Any]] ?? []).map { v in
                let items = (v["items"] as? [[String: Any]] ?? []).map { item -> Violation.Item in
                    let pos = item["pos"] as? [String: Double]
                    return Violation.Item(description: item["description"] as? String ?? "",
                                          position: pos.flatMap { p in p["x"].flatMap { x in p["y"].map { KiCadPoint(x, $0) } } },
                                          uuid: item["uuid"] as? String ?? "")
                }
                return Violation(type: v["type"] as? String ?? "", description: v["description"] as? String ?? "",
                                 severity: v["severity"] as? String ?? "", items: items)
            }
        }
        return DRCReport(violations: violations("violations"), unconnected: violations("unconnected_items"),
                         parity: violations("schematic_parity"), kicadVersion: json["kicad_version"] as? String ?? "")
    }

    // MARK: - Fabrication files

    /// Who the files are for: their names and formats as each asks for them
    public enum Maker: String, CaseIterable, Sendable, Identifiable {
        /// KiCad's own names and formats, which any board house takes
        case generic
        /// JLCPCB: Protel extensions, one drill file, and for assembly their BOM and CPL columns
        case jlcpcb
        /// PCBWay: Protel extensions and separate plated and unplated drill files
        case pcbway
        /// OSH Park: Protel extensions
        case oshpark

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .generic: return "Any board house (KiCad's names)"
            case .jlcpcb: return "JLCPCB"
            case .pcbway: return "PCBWay"
            case .oshpark: return "OSH Park"
            }
        }
    }

    public struct Package: Sendable {
        /// The folder of files
        public var folder: URL
        /// The Gerbers and drill files zipped for upload
        public var zip: URL?
        public var gerbers: [URL]
        public var drill: [URL]
        public var positions: URL?
        public var bom: URL?
        public var step: URL?
        public var render: URL?
        public var drc: DRCReport?
    }

    /// The layers a board house needs: the copper layers the board has, mask, silkscreen, paste and the edge
    public static func fabricationLayers(_ board: KiCadBoard) -> [String] {
        let copper = KiCadConnectivity(board).copperLayers
        return copper + ["F.Mask", "B.Mask", "F.SilkS", "B.SilkS", "F.Paste", "B.Paste", "Edge.Cuts"]
    }

    /// Plots the board's Gerbers into `folder` (zones refilled first; with the extensions board houses read layers by,
    /// .GTL, .GBL…, unless `kicadNames`)
    @discardableResult
    public func gerbers(_ board: URL, layers: [String], into folder: URL, kicadNames: Bool = false) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        var arguments = ["pcb", "export", "gerbers", "-o", folder.path + "/", "-l", layers.joined(separator: ","), "--subtract-soldermask"]
        if kicadNames { arguments.append("--no-protel-ext") }
        if installation.major >= 10 { arguments.append("--check-zones") }
        try run(arguments + [board.path])
        return newFiles(in: folder, since: before)
    }

    /// Writes the drill files (Excellon, millimetres, with a map), plated and unplated holes in separate files if
    /// `separate`
    @discardableResult
    public func drill(_ board: URL, into folder: URL, separate: Bool = true, map: Bool = true) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        var arguments = ["pcb", "export", "drill", "-o", folder.path + "/", "--format", "excellon", "--excellon-units", "mm",
                         "--excellon-zeros-format", "decimal", "--drill-origin", "absolute"]
        if separate { arguments.append("--excellon-separate-th") }
        if map { arguments += ["--generate-map", "--map-format", "pdf"] }
        try run(arguments + [board.path])
        return newFiles(in: folder, since: before)
    }

    /// Writes the position file for pick and place (CSV, millimetres, both sides)
    public func positions(_ board: URL, to file: URL, excludeDNP: Bool = true) throws {
        var arguments = ["pcb", "export", "pos", "-o", file.path, "--side", "both", "--format", "csv", "--units", "mm"]
        if excludeDNP { arguments.append("--exclude-dnp") }
        try run(arguments + [board.path])
    }

    /// Writes the board and its parts as a STEP model
    public func step(_ board: URL, to file: URL) throws {
        try run(["pcb", "export", "step", "-o", file.path, "--force", "--subst-models", "--no-dnp", board.path])
    }

    /// Renders the board in 3D, as KiCad's 3D viewer shows it, from `side` (top or bottom)
    public func render(_ board: URL, to file: URL, side: String = "top", width: Int = 1600, height: Int = 1000) throws {
        try run(["pcb", "render", "-o", file.path, "--side", side, "-w", String(width), "-h", String(height),
                 "--quality", "high", "--background", "opaque", board.path])
    }

    /// Plots layers as one SVG, as the board looks from the front
    public func svg(_ board: URL, layers: [String], to file: URL) throws {
        try run(["pcb", "export", "svg", "-o", file.path, "-l", layers.joined(separator: ","), "--mode-single",
                 "--exclude-drawing-sheet", "--fit-page-to-board", board.path])
    }

    /// The whole set for a board house, in `folder`: the DRC's findings, Gerbers and drill files (zipped together for
    /// upload), the position file and the bill of materials for assembly (as `maker` names their columns), a STEP
    /// model and a 3D picture
    public func package(_ boardFile: URL, into folder: URL, maker: Maker = .generic, bom: [BOMLine] = [],
                        step includeStep: Bool = true, render includeRender: Bool = true) throws -> Package {
        let board = try KiCadBoard.read(boardFile)
        let name = boardFile.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let gerberFolder = folder.appendingPathComponent("gerbers")
        try? fm.removeItem(at: gerberFolder)
        let report = try? drc(boardFile)
        let gerbers = try self.gerbers(boardFile, layers: Self.fabricationLayers(board), into: gerberFolder, kicadNames: maker == .generic)
        let drill = try self.drill(boardFile, into: gerberFolder, separate: maker != .jlcpcb)
        var package = Package(folder: folder, gerbers: gerbers, drill: drill, drc: report)
        let zip = folder.appendingPathComponent("\(name)-gerbers.zip")
        try? fm.removeItem(at: zip)
        if (try? KiCadFabrication.zip(gerberFolder, to: zip)) != nil { package.zip = zip }

        let pos = folder.appendingPathComponent("\(name)-positions.csv")
        try positions(boardFile, to: pos)
        if maker == .jlcpcb, let text = try? String(contentsOf: pos, encoding: .utf8) {
            try Self.jlcpcbPositions(text).write(to: pos, atomically: true, encoding: .utf8)
        }
        package.positions = pos
        if !bom.isEmpty {
            let file = folder.appendingPathComponent("\(name)-bom.csv")
            try Self.bomCSV(bom, maker: maker).write(to: file, atomically: true, encoding: .utf8)
            package.bom = file
        }
        if includeStep {
            let file = folder.appendingPathComponent("\(name).step")
            if (try? step(boardFile, to: file)) != nil { package.step = file }
        }
        if includeRender {
            let file = folder.appendingPathComponent("\(name)-3d.png")
            if (try? render(boardFile, to: file)) != nil { package.render = file }
        }
        return package
    }

    // MARK: - Assembly files

    /// A line of the bill of materials: the parts alike, with their references
    public struct BOMLine: Sendable, Hashable {
        public var references: [String]
        public var value: String
        public var footprint: String
        public var description: String
        /// The board house's part number (an LCSC number for JLCPCB), if known
        public var partNumber: String

        public init(references: [String], value: String, footprint: String, description: String = "", partNumber: String = "") {
            (self.references, self.value, self.footprint, self.description, self.partNumber) = (references, value, footprint, description, partNumber)
        }
    }

    /// The board's footprints gathered into lines (same value and footprint), DNP and BOM-excluded ones left out
    public static func bom(_ board: KiCadBoard) -> [BOMLine] {
        var lines: [String: BOMLine] = [:]
        for footprint in board.footprints {
            let attrs = footprint.attributes
            guard !attrs.contains("dnp"), !attrs.contains("exclude_from_bom"), !attrs.contains("board_only") else { continue }
            let key = footprint.value + "|" + footprint.libID
            lines[key, default: BOMLine(references: [], value: footprint.value, footprint: footprint.libID,
                                        description: footprint.property("Description") ?? "",
                                        partNumber: footprint.property("LCSC") ?? "")].references.append(footprint.reference)
        }
        return lines.values.map { line in
            var l = line
            l.references.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            return l
        }.sorted { $0.references[0].localizedStandardCompare($1.references[0]) == .orderedAscending }
    }

    static func csvField(_ text: String) -> String {
        text.contains(",") || text.contains("\"") ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }

    /// The bill of materials as CSV, with the columns `maker` asks for
    public static func bomCSV(_ lines: [BOMLine], maker: Maker) -> String {
        var rows: [[String]]
        switch maker {
        case .jlcpcb:
            rows = [["Comment", "Designator", "Footprint", "LCSC Part #"]]
            rows += lines.map { [$0.value, $0.references.joined(separator: ","), $0.footprint.split(separator: ":").last.map(String.init) ?? "", $0.partNumber] }
        default:
            rows = [["References", "Quantity", "Value", "Footprint", "Description"]]
            rows += lines.map { [$0.references.joined(separator: ","), String($0.references.count), $0.value, $0.footprint, $0.description] }
        }
        return rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// KiCad's position file in JLCPCB's columns: Designator, Mid X, Mid Y, Layer, Rotation
    public static func jlcpcbPositions(_ kicad: String) -> String {
        var lines = kicad.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return kicad }
        lines.removeFirst()
        var out = ["Designator,Mid X,Mid Y,Layer,Rotation"]
        for line in lines {
            let f = parseCSVLine(line)
            // Ref,Val,Package,PosX,PosY,Rot,Side
            guard f.count >= 7 else { continue }
            let side = f[6].lowercased() == "bottom" ? "Bottom" : "Top"
            out.append([f[0], f[3] + "mm", f[4] + "mm", side, f[5]].map(csvField).joined(separator: ","))
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                fields.append(field); field = ""
            } else {
                field.append(c)
            }
            i += 1
        }
        fields.append(field)
        chars.removeAll()
        return fields
    }

    // MARK: - Running kicad-cli

    func run(_ arguments: [String]) throws {
        let result = try KiCadCLI.run(installation.cli, arguments)
        // 0 done; 5 rules violated (only with --exit-code-violations)
        guard result.status == 0 || result.status == 5 else {
            let detail = (result.error + "\n" + result.output).trimmingCharacters(in: .whitespacesAndNewlines)
            throw KiCadCLI.Failure(description: "kicad-cli \(arguments.prefix(3).joined(separator: " ")) failed (\(result.status)): \(detail)")
        }
    }

    func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-kicad-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func newFiles(in folder: URL, since before: Set<String>) -> [URL] {
        let now = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return now.filter { !before.contains($0) }.sorted().map { folder.appendingPathComponent($0) }
    }

    /// Zips a folder's files (not the folder itself), as board houses take them
    public static func zip(_ folder: URL, to file: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        for tool in ["/usr/bin/zip", "/bin/zip"] where FileManager.default.isExecutableFile(atPath: tool) {
            let result = try KiCadCLI.run(URL(fileURLWithPath: tool), ["-q", "-j", file.path] + files.map { folder.appendingPathComponent($0).path })
            if result.status == 0 { return }
        }
        #if os(macOS)
        let result = try KiCadCLI.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", folder.path, file.path])
        if result.status == 0 { return }
        #endif
        throw KiCadCLI.Failure(description: "The Gerbers could not be zipped")
    }
}
