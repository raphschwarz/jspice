import Foundation
import CircuitKit
import KiCadKit
import KiCadLink
import KiCadRouter

/// Where a circuit's board is changed when something else holds it too: an app window's own link to its board, through
/// which a session driving that window changes the board, so that the two never change it at once
public protocol BoardHost: AnyObject {
    func withBoard<T>(_ body: (BoardLink) throws -> T) throws -> T
}

/// A circuit's printed circuit board: a KiCad project beside the circuit's file (circuit.kicad_pcb and
/// circuit.kicad_pro), kept in step with the circuit both ways (PCBSync). While KiCad's PCB editor has the board open
/// (with KiCad's API on), the board is changed there, as one undoable change, and read from there; otherwise its file
/// is. KiCad's editor is where the board is laid out and routed; this is what joins it to the schematic.
public final class BoardLink {
    public enum Failure: Error, CustomStringConvertible {
        case noKiCad(String)
        /// KiCad has the board open but cannot be reached: changing its file now would be lost
        case openUnreachable
        case noBoard
        /// KiCad has the project open, and would keep its own settings
        case projectOpen
        /// The same, of the project's pre-defined sizes
        case sizesProjectOpen

        public var description: String {
            switch self {
            case .noKiCad(let why): return why
            case .projectOpen:
                return "KiCad has the board open: change its net classes in KiCad's Board Setup (Net Classes), or close the board in KiCad and change them here."
            case .sizesProjectOpen:
                return "KiCad has the board open: change its pre-defined sizes in KiCad's Board Setup (Pre-defined Sizes), or close the board in KiCad and change them here."
            case .openUnreachable:
                return "KiCad has the board open, but JSpice cannot reach it: turn on KiCad's API (Preferences ▸ Plugins ▸ Enable KiCad API) so the board can be kept in step while it is open."
            case .noBoard: return "The circuit has no board yet."
            }
        }
    }

    /// A change taken to the board, and how
    public struct Outcome {
        public var result: PCBSync.Result
        /// The board as it now is
        public var board: KiCadBoard
        /// nil when the board's file was changed, else how the open editor was
        public var live: KiCadLiveBoard.Applied?
        /// The schematic's parts each footprint stands for (the top-level parts: a block's, for a part inside one)
        public var partsOfFootprint: [String: [UUID]]
    }

    public let boardFile: URL
    public let installation: KiCadInstallation?
    private var liveBoard: KiCadLiveBoard?
    private var library: KiCadFootprintLibrary?
    private let lock = NSLock()

    public init(boardFile: URL, installation: KiCadInstallation? = KiCadInstallation.find()) {
        self.boardFile = boardFile
        self.installation = installation
    }

    /// The board of the circuit saved at `circuitFile`: where its design says, or beside it with its name
    public static func boardFile(for circuitFile: URL, design: PCBDesign?) -> URL {
        let folder = circuitFile.deletingLastPathComponent()
        if let path = design?.board, !path.isEmpty {
            return path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
        }
        return folder.appendingPathComponent(circuitFile.deletingPathExtension().lastPathComponent + ".kicad_pcb")
    }

    public var projectFile: URL { boardFile.deletingPathExtension().appendingPathExtension("kicad_pro") }

    public var exists: Bool { FileManager.default.fileExists(atPath: boardFile.path) }

    /// KiCad's lock on the board, while its editor has it open
    public var isOpenInKiCad: Bool {
        let lock = boardFile.deletingLastPathComponent().appendingPathComponent("~" + boardFile.lastPathComponent + ".lck")
        return FileManager.default.fileExists(atPath: lock.path)
    }

    /// Why the board cannot be laid out here, if it cannot
    public var problem: String? {
        guard let installation else {
            return "KiCad is not installed. JSpice lays out boards with KiCad 10 or later: install it from kicad.org (on a Mac, KiCad.app goes in /Applications/KiCad)."
        }
        return installation.problem
    }

    func kicad() throws -> KiCadInstallation {
        if let problem { throw Failure.noKiCad(problem) }
        return installation!
    }

    /// KiCad's footprint libraries, as KiCad finds them for this board
    public func footprints() throws -> KiCadFootprintLibrary {
        lock.lock()
        defer { lock.unlock() }
        if let library { return library }
        let made = KiCadFootprintLibrary(installation: try kicad(), projectFolder: boardFile.deletingLastPathComponent())
        library = made
        return made
    }

    /// The open editor's board, connecting to it if KiCad has opened it since
    public func live() -> KiCadLiveBoard? {
        lock.lock()
        defer { lock.unlock() }
        if let liveBoard, liveBoard.isOpen { return liveBoard }
        liveBoard = KiCadLiveBoard.find(file: boardFile)
        return liveBoard
    }

    /// The board as it stands: the open editor's (unsaved changes and all), else its file's
    public func board() throws -> (board: KiCadBoard, live: KiCadLiveBoard?) {
        if let live = live(), let board = try? live.snapshot() { return (board, live) }
        guard exists else { throw Failure.noBoard }
        return (try KiCadBoard.read(boardFile), nil)
    }

    /// A new board for `circuit`, and its project, beside the circuit's file
    public func create(_ circuit: Circuit, title: String) throws -> Outcome {
        let library = try footprints()
        let (board, result) = PCBSync.newBoard(circuit, title: title, library: library)
        try FileManager.default.createDirectory(at: boardFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try board.write(to: boardFile)
        if !FileManager.default.fileExists(atPath: projectFile.path) {
            try KiCadProject.projectFile(name: boardFile.deletingPathExtension().lastPathComponent,
                                         netClasses: Self.netClasses(result.netlist))
                .write(to: projectFile, atomically: true, encoding: .utf8)
        }
        return Outcome(result: result, board: board, live: nil, partsOfFootprint: Self.parts(result, board, circuit))
    }

    /// The net classes of a new board: KiCad's default, and wider tracks for the supplies and ground
    static func netClasses(_ netlist: PCBNetlist) -> [KiCadProject.NetClass] {
        var power = Set<String>(["GND"])
        for c in netlist.components { for pin in c.pins.values where pin.type.hasPrefix("power") { power.insert(pin.net) } }
        return [.standard, KiCadProject.NetClass(name: "Power", trackWidth: 0.5, clearance: 0.2, viaDiameter: 0.8, viaDrill: 0.4,
                                                 patterns: power.sorted())]
    }

    /// Brings the board and the circuit together (PCBSync.sync): in the open editor if KiCad has it open, else in its
    /// file. `force` changes the file even though KiCad has it open (KiCad will not see the change until it reads
    /// the file again).
    public func sync(_ circuit: Circuit, putBack: Set<UUID> = [], force: Bool = false) throws -> Outcome {
        let library = try footprints()
        if let live = live() {
            let before = try live.snapshot()
            let after = before.copy()
            var options = NetlistUpdater.Options()
            // the editor gives the tracks their pads' nets itself as the change is made
            options.propagateNets = false
            let result = PCBSync.sync(circuit, board: after, library: library, putBack: putBack, options: options)
            let applied = try live.apply(from: before, to: after, message: "Update from JSpice's schematic")
            return Outcome(result: result, board: after, live: applied, partsOfFootprint: Self.parts(result, after, result.circuit))
        }
        guard exists else { throw Failure.noBoard }
        let board = try KiCadBoard.read(boardFile)
        let before = board.text
        let result = PCBSync.sync(circuit, board: board, library: library, putBack: putBack)
        if board.text != before {
            if isOpenInKiCad && !force { throw Failure.openUnreachable }
            try board.write(to: boardFile)
        }
        return Outcome(result: result, board: board, live: nil, partsOfFootprint: Self.parts(result, board, result.circuit))
    }

    /// The board changed here, its tracks and vias (routed in the PCB view, or taken away) and its footprints' places,
    /// `before` being the board the change was made on: in the open editor as one undoable change, else in the board's
    /// file. A file changed since `before` was read (the schematic's update) keeps its own changes and takes these. The
    /// board as it now is, and how the editor took it (nil: the file was written).
    public func apply(_ after: KiCadBoard, from before: KiCadBoard, message: String) throws -> (board: KiCadBoard, live: KiCadLiveBoard.Applied?) {
        if let live = live() {
            let applied = try live.apply(from: before, to: after, message: message)
            return ((try? live.snapshot()) ?? after, applied)
        }
        guard exists else { throw Failure.noBoard }
        if isOpenInKiCad { throw Failure.openUnreachable }
        let current = try KiCadBoard.read(boardFile)
        let board: KiCadBoard
        if current.text == before.text {
            board = after
        } else {
            current.carryFootprints(from: before, to: after)
            current.carryPlacement(from: before, to: after)
            current.carryCopper(from: before, to: after)
            current.carryZones(from: before, to: after)
            current.carryOutline(from: before, to: after)
            current.carryDrawings(from: before, to: after)
            current.carrySetup(from: before, to: after)
            board = current
        }
        try board.write(to: boardFile)
        return (board, nil)
    }

    /// What filled a board's zones
    public enum FillEngine: String {
        /// KiCad itself: its open editor, or its command line in the board's file
        case kicad = "KiCad"
        /// KiCadRouter's ZoneFiller, the port of KiCad's zone filler, in the board's file
        case port = "JSpice"
    }

    /// The board's zones filled as KiCad fills them. The board as it then is.
    public func fillZones() throws -> KiCadBoard { try fillZonesReporting().board }

    /// The board's zones filled as KiCad fills them: in the open editor by KiCad (its API); else in its file by the
    /// port of KiCad's zone filler (ZoneFiller), or by KiCad's command line where the board has what the port does not
    /// fill yet (its `unsupported`: a design rules file of its own, padstacks...) and KiCad is installed, or where
    /// `engine` asks for KiCad. The board as it then is, and what filled it.
    public func fillZonesReporting(engine: FillEngine? = nil) throws -> (board: KiCadBoard, engine: FillEngine) {
        if let live = live() {
            try live.api.refillZones(live.document)
            return (try live.snapshot(), .kicad)
        }
        guard exists else { throw Failure.noBoard }
        if isOpenInKiCad { throw Failure.openUnreachable }
        if engine != .kicad {
            let board = try KiCadBoard.read(boardFile)
            let filler = ZoneFiller(board: board, project: projectSettings())
            if engine == .port || filler.unsupported.isEmpty || problem != nil {
                let filled = filler.refilledBoard(board)
                try filled.write(to: boardFile)
                return (filled, .port)
            }
        }
        try KiCadFabrication(installation: kicad()).fillZones(boardFile)
        return (try KiCadBoard.read(boardFile), .kicad)
    }

    /// The board's net classes: the widths and gaps its tracks are routed with
    public func netClasses() -> [KiCadProject.NetClass] { KiCadProject.netClasses(in: projectSettings()) }

    /// A net class's widths and gaps set in the board's project file (KiCad, if it has the project open, keeps its
    /// own until it opens it again: refused then). The project's settings as they then are.
    @discardableResult
    public func setNetClass(_ netClass: KiCadProject.NetClass) throws -> [String: Any] {
        if isOpenInKiCad { throw Failure.projectOpen }
        var project = projectSettings() ?? [:]
        KiCadProject.setNetClass(netClass, in: &project)
        let data = try JSONSerialization.data(withJSONObject: project, options: [.prettyPrinted, .sortedKeys])
        try (String(decoding: data, as: UTF8.self) + "\n").write(to: projectFile, atomically: true, encoding: .utf8)
        return project
    }

    /// The project's pre-defined track widths and via sizes set in its file as KiCad's Board Setup writes them (refused
    /// while KiCad has the project open, as a net class is). The project's settings as they then are.
    @discardableResult
    public func setPredefinedSizes(_ sizes: KiCadProject.PredefinedSizes) throws -> [String: Any] {
        if isOpenInKiCad { throw Failure.sizesProjectOpen }
        var project = projectSettings() ?? [:]
        KiCadProject.setPredefinedSizes(sizes, in: &project)
        let data = try JSONSerialization.data(withJSONObject: project, options: [.prettyPrinted, .sortedKeys])
        try (String(decoding: data, as: UTF8.self) + "\n").write(to: projectFile, atomically: true, encoding: .utf8)
        return project
    }

    /// The board's project settings (its .kicad_pro: design rules and net classes), as JSON
    public func projectSettings() -> [String: Any]? {
        (try? Data(contentsOf: projectFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// The schematic's parts each footprint of `board` stands for: top-level parts (the block for a part inside one)
    public static func parts(_ result: PCBSync.Result, _ board: KiCadBoard, _ circuit: Circuit) -> [String: [UUID]] {
        let top = topLevel(circuit)
        var byPath: [String: [UUID]] = [:]
        for component in result.netlist.components {
            let parts = (result.parts[component.reference] ?? []).map { top[$0] ?? $0 }
            for path in component.paths { byPath[path] = parts }
        }
        var out: [String: [UUID]] = [:]
        for footprint in board.footprints { if let path = footprint.path, let parts = byPath[path] { out[footprint.uuid] = parts } }
        return out
    }

    /// Every part's id, inside blocks too (as the flattened circuit has them), to the top-level part it is or is in
    public static func topLevel(_ circuit: Circuit) -> [UUID: UUID] {
        var map: [UUID: UUID] = [:]
        for element in circuit.elements {
            map[element.id] = element.id
            if element.kind == .block, let block = element.block {
                for inner in topLevel(block.circuit).keys { map[UUID.inBlock(element.id, part: inner)] = element.id }
            }
        }
        return map
    }

    // MARK: - KiCad

    /// Opens the board in KiCad's PCB editor (its own window, where the board is laid out and routed)
    public func openInKiCad() throws {
        let kicad = try kicad()
        guard exists else { throw Failure.noBoard }
        guard let editor = kicad.pcbEditor else { throw Failure.noKiCad("KiCad's PCB editor was not found beside \(kicad.cli.path).") }
        let process = Process()
        #if os(macOS)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", editor.path, boardFile.path]
        #else
        process.executableURL = editor
        process.arguments = [boardFile.path]
        #endif
        try process.run()
    }

    /// Whether KiCad's API is on (kicad_common.json's api.enable_server), which the live link needs
    public var apiEnabled: Bool {
        guard let installation, let data = try? Data(contentsOf: commonSettings(installation)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let api = json["api"] as? [String: Any] else { return false }
        return api["enable_server"] as? Bool ?? false
    }

    func commonSettings(_ installation: KiCadInstallation) -> URL {
        installation.settings().appendingPathComponent("kicad_common.json")
    }

    /// Turns KiCad's API on, as Preferences ▸ Plugins ▸ Enable KiCad API does (KiCad running reads it as it next
    /// starts; turning it on in its preferences takes effect at once)
    public func enableAPI() throws {
        let installation = try kicad()
        let file = commonSettings(installation)
        var json = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var api = json["api"] as? [String: Any] ?? [:]
        api["enable_server"] = true
        json["api"] = api
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }

    /// Something that changes when the board does: the open editor's board's text, or the file's date and size
    public func fingerprint() -> String? {
        if let live = live(), let text = try? live.api.text(of: live.document) {
            var hasher = Hasher()
            hasher.combine(text)
            return "live \(hasher.finalize())"
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: boardFile.path) else { return nil }
        return "file \((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) \(attributes[.size] ?? 0)"
    }

    // MARK: - Cross-probing

    /// Selects in KiCad's editor the footprints of these parts
    public func select(_ parts: Set<UUID>, partsOfFootprint: [String: [UUID]]) {
        guard let live = live() else { return }
        let footprints = partsOfFootprint.filter { !parts.isDisjoint(with: $0.value) }.keys.sorted()
        try? live.api.select(footprints, in: live.document)
    }

    /// The parts whose footprints are selected in KiCad's editor
    public func selectedParts(partsOfFootprint: [String: [UUID]]) -> Set<UUID>? {
        guard let live = live(), let selected = try? live.api.selectedFootprints(live.document) else { return nil }
        return Set(selected.flatMap { partsOfFootprint[$0] ?? [] })
    }

    // MARK: - Checking and making

    /// The board saved as the editor has it, for kicad-cli to read
    func saved() throws -> URL {
        if let live = live() { try live.api.save(live.document) }
        guard exists else { throw Failure.noBoard }
        return boardFile
    }

    /// KiCad's design rules check of the board (saved first, if the editor has it)
    public func drc() throws -> KiCadFabrication.DRCReport {
        try KiCadFabrication(installation: kicad()).drc(saved())
    }

    /// JSpice's own design rules check of the board as its file has it (KiCad's checks of copper clearances, track
    /// widths, holes and annular rings, the board's edges, dangling tracks and vias and connections still to make,
    /// brought over from KiCad: BoardDRC.checksMade), in a moment and without KiCad; its zones as they were filled
    public func quickDRC() throws -> KiCadFabrication.DRCReport {
        guard exists else { throw Failure.noBoard }
        return BoardDRC(board: try KiCadBoard.read(boardFile), project: projectSettings()).report()
    }

    /// A picture of the board as made, from above or below (KiCad's 3D view, ray traced)
    public func render(to file: URL, side: String = "top") throws {
        try KiCadFabrication(installation: kicad()).render(saved(), to: file, side: side)
    }

    /// The files a board house needs, in `folder`
    public func fabricate(into folder: URL, maker: KiCadFabrication.Maker) throws -> KiCadFabrication.Package {
        let file = try saved()
        let board = try KiCadBoard.read(file)
        return try KiCadFabrication(installation: kicad()).package(file, into: folder, maker: maker, bom: KiCadFabrication.bom(board))
    }
}
