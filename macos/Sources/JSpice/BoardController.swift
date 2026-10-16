import AppKit
import SwiftUI
import CircuitKit
import KiCadKit
import KiCadLink
import JSpiceAutomation

/// The circuit's printed circuit board, kept in step with the schematic as it is drawn, as Eagle and Fusion keep theirs:
/// each change to the schematic goes to the board (to KiCad's PCB editor as one undoable change while it has the board
/// open, else to the board's file), and what is changed on the board (a part renamed, given another value or
/// footprint, deleted) comes back to the schematic as an undoable change of its own. Selecting parts in either
/// selects them in the other. The board is laid out and routed in KiCad's PCB editor; this is what joins it to the
/// schematic, and what the PCB view shows of it.
@MainActor
final class BoardController: ObservableObject {
    /// What a schematic part is on the board
    struct OnBoard: Hashable {
        var reference: String
        var footprint: String
        var value: String
        /// An electrolytic's + terminal
        var plus: String?
    }

    enum Availability: Equatable {
        /// KiCad is not installed, or too old
        case noKiCad(String)
        /// The circuit has not been saved: its board goes beside its file
        case unsaved
        case noBoard
        case board
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        var date: Date
        var text: String
    }

    @Published private(set) var availability: Availability = .unsaved
    @Published private(set) var picture: KiCadBoardPicture?
    /// Whether KiCad's PCB editor has the board open and JSpice reaches it through KiCad's API
    @Published private(set) var isLive = false
    /// Whether KiCad's PCB editor has the board open, reached or not
    @Published private(set) var isOpenInKiCad = false
    /// The schematic's parts each footprint stands for, by the footprint's id
    @Published private(set) var partsOfFootprint: [String: [UUID]] = [:]
    /// What each schematic part is on the board (worked out from the schematic, board or no board)
    @Published private(set) var onBoard: [UUID: OnBoard] = [:]
    /// The board's net of each of the schematic's wires and net labels
    private var wireNets: [UUID: String] = [:]
    /// The net last highlighted in KiCad's editor
    private var highlighted: String?
    @Published private(set) var unassigned: [String] = []
    @Published private(set) var notes: [String] = []
    /// Parts deleted on the board, waiting for the user's word: delete them from the schematic too, or put them back
    @Published private(set) var removed: [PCBSync.Change] = []
    /// What bringing the board up to date with the schematic would change
    @Published private(set) var pending: [String] = []
    /// What the updates did, both ways, the latest first
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var warnings: [String] = []
    /// What is being done, while it is
    @Published private(set) var busy: String?
    @Published var failure: String?
    @Published private(set) var drc: KiCadFabrication.DRCReport?
    @Published private(set) var apiEnabled = true

    weak var editor: EditorState?
    /// Where the board's work is done, one piece at a time (AI agents' board tools too, through the automation bridge)
    let worker = BoardWorker()
    private(set) var fileURL: URL?
    private var debounce: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    /// The selection that came from KiCad last, and the one sent to it last, neither to go back where it came from
    private var fromKiCad: Set<UUID>?
    private var toKiCad: Set<UUID> = []
    /// KiCad's selection when last asked for
    private var polled: Set<UUID>?

    /// Whether the board has been looked for yet
    private var connected = false

    /// The circuit's board file, once the circuit has a file
    var boardFile: URL? { fileURL.map { BoardLink.boardFile(for: $0, design: editor?.circuit.pcb) } }

    var boardName: String { shownName ?? boardFile?.lastPathComponent ?? "" }
    /// The name of a board shown without KiCad (`show`)
    private var shownName: String?

    // MARK: - Connecting

    func setFile(_ url: URL?) {
        guard url != fileURL || !connected else { return }
        connected = true
        let before = boardFile
        fileURL = url
        // renamed, or saved as another file: it keeps its board, rather than looking for one under its new name
        if let before, let url, let editor, before != boardFile, FileManager.default.fileExists(atPath: before.path),
           let after = boardFile, !FileManager.default.fileExists(atPath: after.path) {
            let sameFolder = before.deletingLastPathComponent().standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL
            // an edit, so that the circuit is saved with it
            editor.editBoard("Keep the Board") { $0.board = sameFolder ? before.lastPathComponent : before.path }
        }
        let file = boardFile
        Task { await connect(file) }
    }

    private func connect(_ file: URL?) async {
        let found = try? await worker.run { w -> (Availability, Bool) in
            w.link = nil
            w.synced = nil
            w.fingerprint = nil
            guard let installation = BoardWorker.installation else {
                return (.noKiCad(BoardLink(boardFile: URL(fileURLWithPath: "/"), installation: nil).problem ?? ""), false)
            }
            if let problem = installation.problem { return (.noKiCad(problem), false) }
            guard let file else { return (.unsaved, true) }
            let link = BoardLink(boardFile: file, installation: installation)
            w.link = link
            return (link.exists ? .board : .noBoard, link.apiEnabled)
        }
        guard let found else { return }
        availability = found.0
        apiEnabled = found.1
        if availability == .board {
            watch()
            await update()
        } else {
            CrossProbeHub.shared.unregister(self)
            watcher?.cancel()
            picture = nil
            await schematicChanged()
        }
    }

    /// Shows `board` as it is, without KiCad or a link to it (the screenshots' PCB view)
    func show(_ board: KiCadBoard, name: String) {
        connected = true
        shownName = name
        let circuit = editor?.circuit ?? Circuit()
        let built = PCBNetlistBuilder.netlist(circuit, design: circuit.pcb)
        let top = BoardLink.topLevel(circuit)
        var byPath: [String: [UUID]] = [:]
        for component in built.netlist.components {
            for path in component.paths { byPath[path] = (built.parts[component.reference] ?? []).map { top[$0] ?? $0 } }
        }
        var parts: [String: [UUID]] = [:]
        for footprint in board.footprints { if let path = footprint.path, let ids = byPath[path] { parts[footprint.uuid] = ids } }
        partsOfFootprint = parts
        picture = KiCadBoardPicture(board)
        availability = .board
        publish(built)
    }

    /// Stops following the board (the window is closing)
    func close() {
        watcher?.cancel()
        debounce?.cancel()
        CrossProbeHub.shared.unregister(self)
    }

    // MARK: - Schematic to board

    /// The schematic changed: once it rests, the board is brought up to date with it
    func circuitChanged() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.schematicChanged()
        }
    }

    private func schematicChanged() async {
        guard let editor else { return }
        let circuit = editor.circuit
        let hasBoard = availability == .board
        // the board's netlist (a simulation from rest for the electrolytics, among the rest) only for a circuit with a
        // board, or while the PCB view is showing
        guard hasBoard || editor.board == .pcb else {
            if !onBoard.isEmpty { onBoard = [:] }
            return
        }
        guard let found = try? await worker.run({ w -> (PCBNetlistBuilder.Result, Bool) in
            let built = PCBNetlistBuilder.netlist(circuit, design: circuit.pcb)
            return (built, built.netlist != w.synced)
        }) else { return }
        publish(found.0)
        // knobs turned and switches thrown change the circuit but not its netlist: only a different netlist goes to the board
        if hasBoard && found.1 { await update() }
    }

    private func publish(_ built: PCBNetlistBuilder.Result) {
        var parts: [UUID: OnBoard] = [:]
        let top = BoardLink.topLevel(editor?.circuit ?? Circuit())
        for component in built.netlist.components where !component.excludeFromBoard {
            for id in built.parts[component.reference] ?? [] where top[id] == id {
                parts[id] = OnBoard(reference: component.reference, footprint: component.footprint, value: component.value,
                                    plus: built.design.polarity[id.uuidString])
            }
        }
        if parts != onBoard { onBoard = parts }
        wireNets = built.wireNets
        if built.unassigned != unassigned { unassigned = built.unassigned }
        if built.notes != notes { notes = built.notes }
    }

    /// Brings the board and the schematic together, both ways: the board's changes back to the schematic, then the
    /// schematic's to the board. `putBack` names parts deleted on the board that are to go back on it; `force` writes
    /// the board's file even though KiCad has it open without its API.
    func update(putBack: Set<UUID> = [], force: Bool = false) async {
        guard availability == .board, let editor else { return }
        let circuit = editor.circuit
        busy = "Updating the board…"
        defer { busy = nil }
        do {
            let done = try await worker.run { w -> Done in
                guard let link = w.link else { throw BoardLink.Failure.noBoard }
                let outcome = try link.sync(circuit, putBack: putBack, force: force)
                return w.finish(outcome, link)
            }
            take(done, from: circuit)
            failure = nil
        } catch {
            failure = "\(error)"
        }
    }

    /// What an update did, taken in: its picture of the board, and the schematic as the board's changes leave it
    private func take(_ done: Done, from circuit: Circuit) {
        let result = done.outcome.result
        picture = done.picture
        partsOfFootprint = done.outcome.partsOfFootprint
        isLive = done.live
        isOpenInKiCad = done.open
        removed = result.removed
        // what KiCad's netlist updater could not do (a footprint its libraries lack), and what could not come back
        warnings = (result.report.errors + result.report.warnings).map(\.text) + result.warnings
        pending = []
        var lines = result.applied.map { "From the board: \($0)" } + result.report.actions.map(\.text)
        if done.outcome.live == .reloaded { lines.append("KiCad's PCB editor read the board again from its file") }
        let now = Date()
        log = (lines.reversed().map { LogEntry(date: now, text: $0) } + log).prefix(60).map { $0 }
        guard let editor, result.circuitChanged else { return }
        guard editor.circuit == circuit else {
            // the schematic changed meanwhile: the board's changes come back with the next update, which that change makes
            circuitChanged()
            return
        }
        if result.applied.isEmpty {
            editor.keepBoardRecord(result.circuit)
        } else {
            editor.edit(result.applied.count == 1 ? "Change from the Board" : "Changes from the Board") { $0 = result.circuit }
        }
    }

    // MARK: - Board to schematic

    /// Looks at the board every two seconds: changed (in KiCad's editor, or its file saved), what changed on it comes
    /// back to the schematic
    private func watch() {
        // KiCad's selections listened for while there is a board
        CrossProbeHub.shared.register(self)
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                await self.look()
            }
        }
    }

    private func look() async {
        guard availability == .board, busy == nil, let editor else { return }
        let circuit = editor.circuit
        let pollSelection = !CrossProbeHub.shared.isListening
        let parts = partsOfFootprint
        guard let seen = try? await worker.run({ w -> Seen? in
            guard let link = w.link else { return nil }
            guard link.exists else { return Seen(gone: true) }
            var seen = Seen()
            seen.live = link.live() != nil
            seen.open = link.isOpenInKiCad
            if pollSelection && seen.live { seen.selection = link.selectedParts(partsOfFootprint: parts) }
            let fingerprint = link.fingerprint()
            guard fingerprint != w.fingerprint else { return seen }
            w.fingerprint = fingerprint
            // the board changed: what bringing the two together would do, done on a copy
            let board = try link.board().board
            let check = board.copy()
            let result = PCBSync.sync(circuit, board: check, library: try link.footprints())
            seen.board = (KiCadBoardPicture(board), BoardLink.parts(result, board, result.circuit))
            seen.back = result.applied.map(\.description)
            seen.removed = result.removed
            seen.pending = result.report.actions.map(\.text)
            seen.schematicAhead = PCBNetlistBuilder.netlist(circuit, design: circuit.pcb).netlist != w.synced
            return seen
        }) else { return }
        if seen.gone {
            availability = .noBoard
            picture = nil
            watcher?.cancel()
            return
        }
        isLive = seen.live
        isOpenInKiCad = seen.open
        // KiCad's selection, asked for where JSpice cannot hear it: taken when it changes
        if let selection = seen.selection, selection != polled {
            polled = selection
            selectedInKiCad(parts: selection)
        }
        guard let board = seen.board else { return }
        picture = board.0
        partsOfFootprint = board.1
        pending = seen.pending
        let removedChanged = seen.removed != removed
        removed = seen.removed
        // the board's changes come back now; the schematic's go when it changes, or when an update the board would not
        // take (KiCad had it open out of reach) can now be made
        if !seen.back.isEmpty || removedChanged || (seen.schematicAhead && !seen.pending.isEmpty) { await update() }
    }

    /// Deletes from the schematic parts deleted on the board, as one undoable change
    func deleteFromSchematic(_ change: PCBSync.Change) {
        guard let editor, case .removed(_, let reference) = change else { return }
        editor.edit("Delete \(reference) as on the Board") { PCBSync.delete(change, from: &$0) }
        editor.selection.subtract(change.parts)
    }

    /// Puts back on the board parts deleted on it
    func putBack(_ change: PCBSync.Change) {
        Task { await update(putBack: Set(change.parts)) }
    }

    // MARK: - Making and opening the board

    /// A new board for the circuit, beside its file, its parts arranged as the schematic has them
    func createBoard() {
        guard let editor, let fileURL else { return }
        let circuit = editor.circuit
        let title = fileURL.deletingPathExtension().lastPathComponent
        busy = "Making the board…"
        Task {
            defer { busy = nil }
            do {
                let done = try await worker.run { w -> Done in
                    guard let link = w.link else { throw BoardLink.Failure.noBoard }
                    return w.finish(try link.create(circuit, title: title), link)
                }
                availability = .board
                failure = nil
                take(done, from: circuit)
                watch()
            } catch {
                failure = "\(error)"
            }
        }
    }

    /// Opens the board in KiCad's PCB editor, where it is laid out and routed, first offering to turn on KiCad's API
    /// (without it, the board cannot be kept in step while KiCad has it open)
    func openInKiCad() {
        guard availability == .board else { return }
        if !apiEnabled && !askToEnableAPI() { return }
        Task {
            do {
                try await worker.run { w in try w.link?.openInKiCad() }
                failure = nil
            } catch {
                failure = "\(error)"
            }
        }
    }

    /// Asks to turn on KiCad's API; false if the user would rather not open KiCad after all
    private func askToEnableAPI() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Keep the board in step while KiCad has it open?"
        alert.informativeText = "JSpice changes the board in KiCad's PCB editor as you change the schematic, and brings KiCad's changes back, through KiCad's API, which is off until it is turned on. If KiCad is running now, turn it on in KiCad's Preferences ▸ Plugins instead (Enable KiCad API)."
        alert.addButton(withTitle: "Turn On KiCad's API")
        alert.addButton(withTitle: "Open Without It")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            enableAPI()
            return true
        case .alertSecondButtonReturn:
            // asked once: the board's file is changed while KiCad does not have it open
            apiEnabled = true
            return true
        default:
            return false
        }
    }

    func enableAPI() {
        Task {
            do {
                try await worker.run { w in try w.link?.enableAPI() }
                apiEnabled = true
            } catch {
                failure = "\(error)"
            }
        }
    }

    // MARK: - Checking and making

    /// KiCad's design rules check of the board
    func checkDesignRules() {
        guard availability == .board else { return }
        busy = "Checking the design rules…"
        Task {
            defer { busy = nil }
            do {
                drc = try await worker.run { w -> KiCadFabrication.DRCReport in
                    guard let link = w.link else { throw BoardLink.Failure.noBoard }
                    return try link.drc()
                }
                failure = nil
            } catch {
                failure = "\(error)"
            }
        }
    }

    /// The files a board house needs to make the board (Gerbers, drill files, assembly files), in a folder the user
    /// chooses
    func fabricate(_ maker: KiCadFabrication.Maker) {
        guard availability == .board, let boardFile else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = boardFile.deletingLastPathComponent()
        panel.prompt = "Make Files Here"
        panel.message = "Choose where to put the files for \(maker == .generic ? "the board house" : maker.title): they go in a folder of their own there."
        guard panel.runModal() == .OK, let base = panel.url else { return }
        let name = boardFile.deletingPathExtension().lastPathComponent
        let folder = base.appendingPathComponent("\(name) \(maker == .generic ? "fabrication" : maker.title)")
        busy = "Making the fabrication files…"
        Task {
            defer { busy = nil }
            do {
                let package = try await worker.run { w -> KiCadFabrication.Package in
                    guard let link = w.link else { throw BoardLink.Failure.noBoard }
                    return try link.fabricate(into: folder, maker: maker)
                }
                failure = nil
                if let report = package.drc { drc = report }
                showMade(package, maker: maker)
            } catch {
                failure = "\(error)"
            }
        }
    }

    private func showMade(_ package: KiCadFabrication.Package, maker: KiCadFabrication.Maker) {
        let alert = NSAlert()
        alert.messageText = "The fabrication files are made"
        var lines = ["\(package.gerbers.count) Gerber files and \(package.drill.count) drill files" + (package.zip != nil ? ", zipped for upload" : "") + "."]
        if package.positions != nil { lines.append("Pick-and-place positions" + (package.bom != nil ? " and the bill of materials" : "") + " for assembly.") }
        if package.step != nil { lines.append("A STEP model of the board for enclosure design.") }
        if let report = package.drc, !report.isClean {
            lines.append("The design rules check found \(report.violations.count) problems and \(report.unconnected.count) unrouted connections: see the PCB view.")
        }
        if maker != .generic { lines.append("Upload the zip to \(maker.title).") }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([package.zip ?? package.folder])
        }
    }

    // MARK: - Cross-probing

    /// The schematic's selection changed: the same parts selected in KiCad's editor
    func selectionChanged(_ selection: Set<UUID>) {
        // wires of one net selected: the net highlighted in KiCad's editor, as KiCad's schematic editor highlights it
        if isOpenInKiCad || isLive {
            let nets = Set(selection.compactMap { wireNets[$0] })
            let net = nets.count == 1 && selection.allSatisfy({ wireNets[$0] != nil }) ? nets.first : nil
            if net != highlighted {
                highlighted = net
                Task.detached { KiCadCrossProbe.highlight(net: net) }
            }
        }
        guard isLive, selection != fromKiCad, selection != toKiCad else { return }
        toKiCad = selection
        let parts = partsOfFootprint
        Task { try? await worker.run { w in w.link?.select(selection, partsOfFootprint: parts) } }
    }

    /// Footprints selected in KiCad's editor, by reference
    func selectedInKiCad(references: [String]) {
        guard isLive, let picture else { return }
        let wanted = Set(references)
        let footprints = picture.footprints.filter { wanted.contains($0.reference) }.map(\.uuid)
        selectedInKiCad(parts: Set(footprints.flatMap { partsOfFootprint[$0] ?? [] }))
    }

    private func selectedInKiCad(parts: Set<UUID>) {
        guard let editor, !parts.isEmpty, parts != editor.selection else { return }
        // KiCad saying back what JSpice selected there (all of it that has a footprint) is not a new selection
        if parts.isSubset(of: toKiCad) { return }
        fromKiCad = parts
        editor.selection = parts
    }

    /// Selects in the schematic the parts a footprint stands for (clicked in the PCB view)
    func select(footprint uuid: String?, extending: Bool) {
        guard let editor else { return }
        let parts = Set(uuid.flatMap { partsOfFootprint[$0] } ?? [])
        if extending {
            editor.selection.formSymmetricDifference(parts)
        } else {
            editor.selection = parts
        }
    }

    // MARK: - Footprints

    /// KiCad's footprint libraries, for choosing a part's footprint
    func footprintLibrary() async -> KiCadFootprintLibrary? {
        try? await worker.run { w in try w.library() }
    }
}

/// What an update or a new board leaves: worked out off the main thread
struct Done {
    var outcome: BoardLink.Outcome
    var picture: KiCadBoardPicture
    var live: Bool
    var open: Bool
}

/// What a look at the board found
private struct Seen {
    var gone = false
    var live = false
    var open = false
    var selection: Set<UUID>?
    var board: (KiCadBoardPicture, [String: [UUID]])?
    var back: [String] = []
    var removed: [PCBSync.Change] = []
    var pending: [String] = []
    var schematicAhead = false
}

/// The board's work, off the main thread and one piece at a time: KiCad's API, the board's files and kicad-cli all
/// take their time
final class BoardWorker: @unchecked Sendable, BoardHost {
    /// KiCad as installed, looked for once
    static let installation = KiCadInstallation.find()

    private let queue = DispatchQueue(label: "org.knowm.jspice.board", qos: .userInitiated)
    // touched only on the queue
    var link: BoardLink?
    /// The schematic's netlist when the board was last brought up to date with it
    var synced: PCBNetlist?
    /// The board as last looked at (BoardLink.fingerprint)
    var fingerprint: String?
    private var standalone: KiCadFootprintLibrary?

    @discardableResult
    func run<T>(_ body: @escaping (BoardWorker) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body(self) }) }
        }
    }

    /// An update made: what it leaves, and the board as now seen
    func finish(_ outcome: BoardLink.Outcome, _ link: BoardLink) -> Done {
        let circuit = outcome.result.circuit
        synced = PCBNetlistBuilder.netlist(circuit, design: circuit.pcb).netlist
        fingerprint = link.fingerprint()
        let live = outcome.live != nil || link.live() != nil
        return Done(outcome: outcome, picture: KiCadBoardPicture(outcome.board), live: live, open: link.isOpenInKiCad)
    }

    /// The window's board for an AI agent's board tool, in turn with the window's own work on it
    func withBoard<T>(_ body: (BoardLink) throws -> T) throws -> T {
        try queue.sync {
            guard let link else {
                throw ToolError(Self.installation == nil ? "KiCad is not installed: JSpice lays out boards with KiCad 10 or later"
                                                         : "Save the circuit first: its board goes beside its file")
            }
            return try body(link)
        }
    }

    func library() throws -> KiCadFootprintLibrary? {
        if let link { return try link.footprints() }
        if standalone == nil, let installation = Self.installation { standalone = KiCadFootprintLibrary(installation: installation) }
        return standalone
    }
}

/// KiCad's PCB editor's selections, heard for every window: KiCad sends them to one port, which one listener holds
@MainActor
final class CrossProbeHub {
    static let shared = CrossProbeHub()
    private var probe: KiCadCrossProbe?
    private var controllers: [ObjectIdentifier: () -> BoardController?] = [:]

    /// Whether JSpice hears KiCad's selections (another program, KiCad's own schematic editor, may hold the port)
    var isListening: Bool { probe != nil }

    func register(_ controller: BoardController) {
        controllers[ObjectIdentifier(controller)] = { [weak controller] in controller }
        if probe == nil {
            probe = KiCadCrossProbe { references in
                Task { @MainActor in CrossProbeHub.shared.heard(references) }
            }
        }
    }

    func unregister(_ controller: BoardController) {
        controllers[ObjectIdentifier(controller)] = nil
    }

    private func heard(_ references: [String]) {
        for controller in controllers.values.compactMap({ $0() }) { controller.selectedInKiCad(references: references) }
    }
}
