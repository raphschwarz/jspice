import Foundation

/// KiCad's footprint libraries, found as KiCad finds them: through the footprint library tables (the user's global
/// fp-lib-table, then the project's beside its board), each library a .pretty folder of .kicad_mod files, their paths
/// written with KiCad's variables (${KICAD10_FOOTPRINT_DIR}, ${KIPRJMOD}…)
public final class KiCadFootprintLibrary: @unchecked Sendable {
    public struct Library: Sendable, Hashable {
        public var name: String
        public var folder: URL
        public var description: String
    }

    public enum LoadError: Error, CustomStringConvertible {
        case badID(String)
        case noLibrary(String)
        case noFootprint(String)

        public var description: String {
            switch self {
            case .badID(let id): return "\"\(id)\" is not a footprint's Library:Name"
            case .noLibrary(let lib): return "No footprint library \"\(lib)\" is in KiCad's library tables"
            case .noFootprint(let id): return "The footprint \(id) is not in its library"
            }
        }
    }

    /// The libraries by name, the project's over the global ones
    public private(set) var libraries: [String: Library] = [:]
    private var cache: [String: SExpr] = [:]
    private let lock = NSLock()

    public init(libraries: [Library]) {
        for library in libraries { self.libraries[library.name] = library }
    }

    /// The libraries `installation`'s KiCad would use for the board in `projectFolder`: the user's table (or KiCad's
    /// default one, before KiCad has made the user's), and the project's
    public convenience init(installation: KiCadInstallation, projectFolder: URL? = nil,
                            environment: [String: String] = ProcessInfo.processInfo.environment) {
        var vars = installation.variables(environment: environment)
        if let projectFolder { vars["KIPRJMOD"] = projectFolder.path }
        var tables: [URL] = []
        let user = installation.settings(environment: environment).appendingPathComponent("fp-lib-table")
        if FileManager.default.fileExists(atPath: user.path) {
            tables.append(user)
        } else if let template = installation.templates?.appendingPathComponent("fp-lib-table") {
            tables.append(template)
        }
        if let projectFolder { tables.append(projectFolder.appendingPathComponent("fp-lib-table")) }
        var libraries: [Library] = []
        for table in tables {
            guard let text = try? String(contentsOf: table, encoding: .utf8) else { continue }
            libraries += KiCadFootprintLibrary.parseTable(text, variables: vars)
        }
        // without any table, the stock folders themselves
        if libraries.isEmpty, let stock = installation.footprints,
           let names = try? FileManager.default.contentsOfDirectory(atPath: stock.path) {
            libraries = names.filter { $0.hasSuffix(".pretty") }.sorted().map {
                Library(name: String($0.dropLast(7)), folder: stock.appendingPathComponent($0), description: "")
            }
        }
        self.init(libraries: libraries)
    }

    /// The KiCad libraries of a fp-lib-table, their paths' variables filled in (a library whose variable is unknown is
    /// left out, as KiCad cannot load it either). A row of type Table brings in another table's libraries, as KiCad
    /// 10's own global table brings in the stock one.
    public static func parseTable(_ text: String, variables: [String: String], visited: Set<String> = []) -> [Library] {
        guard let table = try? SExpr.parse(text) else { return [] }
        var libraries: [Library] = []
        for lib in table.all("lib") {
            guard let name = lib.value("name"), let uri = lib.value("uri"), let path = expand(uri, variables) else { continue }
            if lib["disabled"] != nil && lib["disabled"]?.text(at: 0) != "no" { continue }
            switch lib.value("type") ?? "KiCad" {
            case "KiCad":
                libraries.append(Library(name: name, folder: URL(fileURLWithPath: path), description: lib.value("descr") ?? ""))
            case "Table":
                let file = URL(fileURLWithPath: path).standardizedFileURL.path
                guard !visited.contains(file), let nested = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
                libraries += parseTable(nested, variables: variables, visited: visited.union([file]))
            default:
                continue
            }
        }
        return libraries
    }

    /// A path with its ${VARIABLES} filled in, unless one is unknown
    static func expand(_ text: String, _ variables: [String: String]) -> String? {
        var out = ""
        var rest = Substring(text)
        while let start = rest.range(of: "${") {
            out += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].firstIndex(of: "}") else { return nil }
            let name = String(rest[start.upperBound..<end])
            guard let value = variables[name] else { return nil }
            out += value
            rest = rest[rest.index(after: end)...]
        }
        return out + rest
    }

    /// Splits "Library:Name"
    public static func split(_ libID: String) -> (library: String, name: String)? {
        guard let colon = libID.firstIndex(of: ":") else { return nil }
        let (lib, name) = (String(libID[..<colon]), String(libID[libID.index(after: colon)...]))
        guard !lib.isEmpty, !name.isEmpty else { return nil }
        return (lib, name)
    }

    /// The footprint as its library has it (a copy each time)
    public func footprint(_ libID: String) throws -> SExpr {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[libID] { return cached.copy() }
        guard let (lib, name) = KiCadFootprintLibrary.split(libID) else { throw LoadError.badID(libID) }
        guard let library = libraries[lib] else { throw LoadError.noLibrary(lib) }
        let file = library.folder.appendingPathComponent(name + ".kicad_mod")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { throw LoadError.noFootprint(libID) }
        let node = try SExpr.parse(text)
        cache[libID] = node
        return node.copy()
    }

    /// Whether the footprint can be found
    public func has(_ libID: String) -> Bool {
        guard let (lib, name) = KiCadFootprintLibrary.split(libID), let library = libraries[lib] else { return false }
        return FileManager.default.fileExists(atPath: library.folder.appendingPathComponent(name + ".kicad_mod").path)
    }

    /// The names of a library's footprints
    public func footprints(in library: String) -> [String] {
        guard let folder = libraries[library]?.folder,
              let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return files.filter { $0.hasSuffix(".kicad_mod") }.map { String($0.dropLast(10)) }.sorted()
    }

    /// The footprint made ready to place on a board, as KiCad loads one from its library (FOOTPRINT_EDIT_FRAME's
    /// LoadFootprint and BOARD_NETLIST_UPDATER::addNewFootprint): named Library:Name, with a new id for it and each of
    /// its items, the board's mandatory fields, its reference and value, placed at `position` turned by `rotation`,
    /// its pads on no net
    public func placeable(_ libID: String, reference: String, value: String, at position: KiCadPoint, rotation: Double = 0) throws -> SExpr {
        try KiCadFootprintLibrary.placeable(footprint(libID), libID: libID, reference: reference, value: value,
                                            at: position, rotation: rotation)
    }

    public static func placeable(_ footprint: SExpr, libID: String, reference: String, value: String,
                                 at position: KiCadPoint, rotation: Double = 0) -> SExpr {
        let node = footprint
        node.items[1] = SExpr(string: libID)
        for head in ["version", "generator", "generator_version", "uuid", "at", "path", "locked"] { node.remove(head) }
        // what KiCad leaves out or fills in as it loads a footprint: empty tags and descriptions, the fill of a pad's
        // drawn shapes
        for head in ["tags", "descr"] where node.value(head)?.isEmpty == true { node.remove(head) }
        // a field given twice: the last one stands
        var seen = Set<String>()
        for item in node.items.reversed() where item.head == "property" {
            guard let name = item.text(at: 0) else { continue }
            if !seen.insert(name).inserted { node.remove(item) }
        }
        for pad in node.all("pad") {
            for primitive in pad["primitives"]?.arguments ?? [] where ["gr_circle", "gr_rect", "gr_poly"].contains(primitive.head ?? "") {
                if primitive["fill"] == nil { primitive.items.append(SExpr("fill", Keyword("no"))) }
            }
        }
        if node["layer"] == nil { node.items.insert(SExpr("layer", "F.Cu"), at: 2) }
        let layerIndex = node.items.firstIndex { $0.head == "layer" } ?? 1
        node.items.insert(SExpr("uuid", KiCadBoard.newUUID()), at: layerIndex + 1)
        node.items.insert(SExpr("at", 0.0, 0.0), at: layerIndex + 2)
        // the mandatory fields, after the value, as KiCad adds them
        let properties = node.all("property")
        for name in ["Datasheet", "Description"] where !properties.contains(where: { $0.text(at: 0) == name }) {
            let field = SExpr("property", name, "", SExpr("at", 0.0, 0.0, 0.0), SExpr("layer", "F.Fab"),
                              SExpr("hide", Keyword("yes")), SExpr("effects", SExpr("font", SExpr("size", 1.27, 1.27))))
            let after = node.items.lastIndex { item in
                item.head == "property" && ["Reference", "Value", "Datasheet", "Description"].contains(item.text(at: 0) ?? "")
            }
            node.items.insert(field, at: (after ?? node.items.count - 1) + 1)
        }
        // a new id for every item, where KiCad writes it (each footprint placed has its own), the groups' members
        // following theirs
        var renamed: [String: String] = [:]
        for item in node.items {
            if let old = item.value("uuid") {
                let new = KiCadBoard.newUUID()
                renamed[old] = new
                item.set(SExpr("uuid", new))
            }
            switch item.head {
            case "property", "fp_text", "fp_text_box":
                if item["uuid"] == nil {
                    let i = item.items.firstIndex { $0.head == "effects" } ?? item.items.count
                    item.items.insert(SExpr("uuid", KiCadBoard.newUUID()), at: i)
                }
            case "fp_line", "fp_rect", "fp_arc", "fp_circle", "fp_poly", "fp_curve", "pad", "dimension", "point", "group":
                if item["uuid"] == nil { item.items.append(SExpr("uuid", KiCadBoard.newUUID())) }
            case "zone":
                // a library's zone (a keep-out, mostly) as KiCad keeps one on a board: on no net, its id after its layers
                item.items.removeAll { ($0.head == "net" && ($0.text(at: 0) == "0" || $0.text(at: 0) == "")) || ($0.head == "net_name" && $0.text(at: 0) == "") }
                item.remove("filled_areas_thickness")
                if item["uuid"] == nil, let i = item.items.firstIndex(where: { $0.head == "layer" || $0.head == "layers" }) {
                    item.items.insert(SExpr("uuid", KiCadBoard.newUUID()), at: i + 1)
                }
                if let fill = item["fill"], fill["island_removal_mode"] == nil { fill.items.append(SExpr("island_removal_mode", 0)) }
            default: break
            }
            if item.head == "pad" {
                item.remove("net")
                // a pad that drops unused layers gets its (empty) list of layers that still meet zones
                if item["remove_unused_layers"]?.text(at: 0) == "yes", item["zone_layer_connections"] == nil {
                    let i = item.items.lastIndex { $0.head == "keep_end_layers" || $0.head == "remove_unused_layers" }!
                    item.items.insert(SExpr(list: [SExpr(symbol: "zone_layer_connections")]), at: i + 1)
                }
            }
        }
        for group in node.all("group") {
            guard let members = group["members"] else { continue }
            for i in 1..<members.items.count { members.items[i] = SExpr(string: renamed[members.items[i].text] ?? members.items[i].text) }
        }
        let board = KiCadBoard(SExpr(list: [SExpr(symbol: "kicad_pcb"), node]))
        let placed = KiCadFootprint(node, board: board)
        placed.setProperty("Reference", reference)
        placed.setProperty("Value", value)
        placed.move(to: position, rotation: rotation)
        return node
    }
}
