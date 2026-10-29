import AppKit
import SwiftUI
import KiCadKit
import KiCadRouter

/// The board laid out here, in the PCB view: tracks routed with KiCad's router (brought over from KiCad, walking round
/// what is in the way and keeping KiCad's clearances), tracks and vias selected and taken away. Each change goes to
/// the board as the schematic's do: to KiCad's PCB editor as one change of its own while it has the board open, else
/// to the board's file; and each can be undone and redone here.
@MainActor
final class PCBEditing: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case select, route, pair, via, zone, tune, text, footprint
        var id: Self { self }
        var title: String {
            switch self {
            case .select: return "Select"
            case .route: return "Route"
            case .pair: return "Route Differential Pair"
            case .via: return "Add Via"
            case .zone: return "Draw Zone"
            case .tune: return "Tune Length"
            case .text: return "Add Text"
            case .footprint: return "Place Footprint"
            }
        }
        var symbol: String {
            switch self {
            case .select: return "cursorarrow"
            case .route: return "point.topleft.down.to.point.bottomright.curvepath"
            case .pair: return "equal"
            case .via: return "smallcircle.filled.circle"
            case .zone: return "pentagon"
            case .tune: return "waveform.path"
            case .text: return "character.textbox"
            case .footprint: return "cpu"
            }
        }
        /// Whether it routes (a track, or a pair)
        var routes: Bool { self == .route || self == .pair }
    }

    /// What the zone tool draws: a copper zone of a net (as KiCad's Add Filled Zone), or a rule area keeping things
    /// out (as its Add Rule Area)
    enum ZoneKind: String, CaseIterable, Identifiable {
        case copper, keepout
        var id: Self { self }
    }

    @Published var tool: Tool = .select {
        didSet { if tool != oldValue { toolChanged() } }
    }
    /// The copper layer tracks are routed on
    @Published var layer = "F.Cu" {
        didSet { if layer != oldValue { layerChanged() } }
    }
    @Published private(set) var layers = ["F.Cu", "B.Cu"]
    /// New tracks' width in mm, nil for their net class's (or the pre-defined size chosen, `sizeChoice`)
    @Published var width: Double? {
        didSet { if width != oldValue { widthChanged() } }
    }
    /// The project's pre-defined track width and via size new tracks and vias take (KiCad's track width menu): the
    /// net class's (0), or the project's i-th; a width of the list above (`width`) goes before it
    @Published var sizeChoice = BoardEditing.SizeChoice() {
        didSet { if sizeChoice != oldValue { sizeChoiceChanged() } }
    }
    /// A copper layer count asked for that removes layers with items on them, waiting for the user's word, as KiCad's
    /// Board Setup waits for it: the count, and how many items it lists as on the layers removed
    @Published var copperLayersToConfirm: (count: Int, items: Int)?
    /// Whether a track shoves other nets' tracks and vias in its way aside (KiCad's shove mode) or walks round them;
    /// the next track started takes it
    @Published var shove = UserDefaults.standard.bool(forKey: PCBEditing.shoveKey) {
        didSet { UserDefaults.standard.set(shove, forKey: Self.shoveKey) }
    }
    static let shoveKey = "pcbRouterShove"
    /// The corners new tracks take (KiCad's track corner mode): 45° or 90°, mitred or rounded into arcs; the next
    /// track, pair or drag started takes it
    @Published var corners = Direction45.CornerMode(rawValue: UserDefaults.standard.integer(forKey: PCBEditing.cornersKey)) ?? .mitered45 {
        didSet { UserDefaults.standard.set(corners.rawValue, forKey: Self.cornersKey) }
    }
    static let cornersKey = "pcbRouterCorners"
    /// The differential pair being routed, as it now goes
    @Published private(set) var pairPreview: BoardEditing.PairPreview?
    /// The track being routed, as it now goes
    @Published private(set) var preview: BoardEditing.Preview?
    @Published private(set) var isRouting = false
    /// The tracks and vias selected, by id
    @Published var selection: Set<String> = []
    /// Footprints selected here, by id (besides those of the parts selected in the schematic: these include parts the
    /// schematic does not have, mounting holes and logos)
    @Published var footprintSelection: Set<String> = []
    /// Footprints being dragged, and how far so far
    @Published private(set) var dragging: (uuids: [String], delta: KiCadPoint)?
    /// Whether the footprints being dragged are the board's texts instead
    @Published private(set) var draggingTexts = false
    /// The words the text tool places, and the layer it places them on
    @Published var textToPlace = "Text"
    @Published var textLayer = "F.SilkS"
    /// The footprint the footprint tool places (Library:Name), and those of KiCad's libraries found for the words
    /// typed in to look for one
    @Published var footprintToPlace: String?
    @Published private(set) var footprintMatches: [String] = []
    /// The box being drawn to select with (a drag from where there is nothing to drag, as KiCad's), and whether it
    /// takes what it touches (drawn right to left, KiCad's greedy selection) or only what is wholly in it
    @Published private(set) var selectionArea: (from: KiCadPoint, to: KiCadPoint, touching: Bool)?
    /// A track or via being dragged with the router (KiCad's drag), as it now goes
    @Published private(set) var dragPreview: BoardEditing.DragPreview?
    @Published private(set) var isDragging = false
    /// What the last action could not do, or how to go on
    @Published private(set) var message: String?
    @Published private(set) var undoName: String?
    @Published private(set) var redoName: String?
    @Published private(set) var isReady = false
    /// JSpice's own design rules check of the board, made again each time it changes
    @Published private(set) var quickDRC: KiCadFabrication.DRCReport?
    /// The connection still to route under the pointer, which the select tool routes when it is clicked
    @Published var hoveredAirwire: KiCadConnectivity.Airwire?
    /// The zone being drawn: its corners so far (mm), and where the pointer is, for the side still to place
    @Published private(set) var zoneCorners: [KiCadPoint] = []
    @Published private(set) var zonePointer: KiCadPoint?
    /// What the zone tool draws, the net of a copper zone (nil: the board's ground net), and what a rule area
    /// keeps out
    @Published var zoneKind = ZoneKind.copper
    @Published var zoneNet: String?
    @Published var zoneKeepout = KiCadBoard.Keepout()
    /// The board's nets, for a zone's
    @Published private(set) var nets: [String] = []
    /// A via clicked where the fills of several nets' zones meet, waiting for one of them to be chosen (KiCad's
    /// "Select Net:")
    @Published var viaNetChoice: (at: KiCadPoint, nets: [String])?
    /// What the tune tool tunes (KiCad's Tune Length of a Single Track, of a Differential Pair, Tune Skew), and the
    /// length (mm) or skew (mm) to reach
    @Published var tuneMode = BoardRouter.TuningMode.single {
        didSet { if tuneMode != oldValue, tuning != nil { cancelTuning() } }
    }
    @Published var tuneLength = 50.0 {
        didSet { if tuneLength != oldValue { tuneSettingsChanged() } }
    }
    @Published var tuneSkew = 0.0 {
        didSet { if tuneSkew != oldValue { tuneSettingsChanged() } }
    }
    /// The tuning under way, as it now goes: its meandered line (a pair's two), how its length compares with what is
    /// asked, and its length (or skew)
    @Published private(set) var tuning: BoardEditing.TuningPreview?
    /// The board's tuning patterns (KiCad's, kept in the board: each tuning kept is one), as the session has them
    @Published private(set) var patterns: [BoardEditing.TuningPatternInfo] = []
    /// The tuning pattern selected (its uuid), as KiCad selects one: a click on one of its tracks
    @Published var patternSelection: String?

    static let widths: [Double] = [0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.8, 1.0, 1.5, 2.0]
    /// Vias' diameters and drills to choose from (mm)
    struct ViaSize: Hashable {
        let diameter: Double, drill: Double
    }
    static let viaSizes = [(0.4, 0.2), (0.45, 0.25), (0.5, 0.3), (0.6, 0.3), (0.7, 0.35), (0.8, 0.4), (1.0, 0.5), (1.2, 0.6)].map { ViaSize(diameter: $0.0, drill: $0.1) }

    weak var controller: BoardController?
    private let engine = PCBRouteEngine()
    private var undoStack: [BoardEditing.Edit] = []
    private var redoStack: [BoardEditing.Edit] = []
    private var pendingMove: KiCadPoint?
    private var moving = false
    /// A change on its way to the board, which the next waits for
    private var applying: Task<Void, Never>?
    /// The design rules checks begun
    private var checks = 0
    /// The last change made here
    private var lastTaken: BoardEditing.Edit?

    // MARK: - The board

    /// The board taken up for editing, as the board link has it (KiCad's editor's, or its file's)
    func prepare() { Task { await prepareNow() } }

    func prepareNow() async {
        guard let controller, let (board, project) = await controller.boardForEditing() else { return }
        await take(board, project: project)
        if !layers.contains(layer) { layer = layers.first ?? "F.Cu" }
        isReady = true
    }

    /// The board taken up by the session (its copper layers), and checked. Each change fills the board's zones again
    /// as KiCad's filler does, unless KiCad's editor has the board open (and fills its own).
    private func take(_ board: KiCadBoard, project: [String: Any]?) async {
        layers = await engine.load(board, project: project)
        nets = await engine.run { Array(Set($0.router.world.netNames.values)).filter { !$0.isEmpty }.sorted() } ?? []
        patterns = await engine.run { $0.tuningPatterns } ?? []
        if let chosen = patternSelection, !patterns.contains(where: { $0.uuid == chosen }) { patternSelection = nil }
        let refills = !(controller?.isLive ?? false) && !(controller?.isOpenInKiCad ?? false)
        let choice = sizeChoice
        _ = await engine.run { session -> Bool? in
            session.refillsZones = refills
            session.sizeChoice = choice
            return true
        }
        await check()
    }

    /// The board checked as it now is, off the router's queue; a check overtaken by the next one is dropped
    private func check() async {
        checks += 1
        let serial = checks
        guard let drc = await engine.run({ $0.designRulesCheck() }) else { return }
        let report = await Task.detached(priority: .utility) { drc.report() }.value
        if serial == checks { quickDRC = report }
    }

    /// Once the changes made so far have gone to the board (a track stopped among them)
    func settled() async {
        await stopping?.value
        await applying?.value
    }

    /// The board changed elsewhere (in KiCad, or by the schematic's update): taken up anew, unless a track is being
    /// routed on it (which carries over onto the board as it then is)
    func boardChanged(_ board: KiCadBoard, project: [String: Any]?) {
        guard isReady, !isRouting, tuning == nil else { return }
        Task { await take(board, project: project) }
    }

    /// The board's rules changed (its net classes): the router takes them
    func rulesChanged(_ project: [String: Any]) {
        guard isReady else { return }
        Task {
            layers = await engine.reload(project: project)
            await check()
        }
    }

    func close() {
        engine.close()
        quickDRC = nil
        isReady = false
        isRouting = false
        preview = nil
        undoStack = []
        redoStack = []
        updateNames()
    }

    // MARK: - Tools

    private func toolChanged() {
        message = nil
        zoneCorners = []
        zonePointer = nil
        if tuning != nil { cancelTuning() }
        if isRouting { stop() }
        if tool != .select { patternSelection = nil }
        if tool == .tune {
            selection = []
            if !isReady { prepare() }
            message = "Click a track to tune its length, move along it, click to keep the meanders (a tuned track: its pattern's end dragged); 1 2 spacing, 3 4 amplitude, Esc drops it"
        }
        if tool == .via {
            selection = []
            if !isReady { prepare() }
            message = "Click to place a via: it takes the net of the track, pad or zone it is put on"
        }
        if tool == .zone {
            selection = []
            if !isReady { prepare() }
            message = "Click the zone's corners, double-click the last; ⌫ takes the last back, Esc drops it"
        }
        if tool.routes {
            selection = []
            if !isReady { prepare() }
            message = startMessage
        }
        if isDragging { cancelDrag() }
    }

    private func layerChanged() {
        // routing: a via to the new layer, placed at the next click (as KiCad's layer switch places one)
        guard isRouting, !isSettingLayer else { return }
        let to = layer
        if routingPair {
            Task { showPair(await engine.run { $0.placePairVias(to: to) }) }
        } else {
            Task { show(await engine.run { $0.placeVia(to: to) }) }
        }
    }

    private func widthChanged() {
        guard isRouting else { return }
        let w = width
        Task { show(await engine.run { $0.setWidth(w) }) }
    }

    /// The next width up, or down
    func stepWidth(_ step: Int) {
        let current = width ?? preview?.width ?? 0.25
        let i = Self.widths.firstIndex { $0 >= current - 1e-9 } ?? Self.widths.count - 1
        width = Self.widths[max(0, min(Self.widths.count - 1, i + step))]
    }

    /// The next copper layer, or the previous
    func stepLayer(_ step: Int) {
        guard let i = layers.firstIndex(of: layer), !layers.isEmpty else { return }
        layer = layers[(i + step + layers.count) % layers.count]
    }

    // MARK: - Routing

    /// The pointer over the board, at `p` (mm)
    func pointerMoved(_ p: KiCadPoint) {
        pointer = p
        if tool == .zone && !zoneCorners.isEmpty { zonePointer = Self.onGrid(p) }
        if tool == .tune && tuning != nil { return tuneMoved(to: p) }
        if isDragging && followsPointer { return dragMoved(to: p) }
        guard isRouting else { return }
        pendingMove = p
        guard !moving else { return }
        moving = true
        Task {
            // only the latest place the pointer has got to is routed to
            while let next = pendingMove {
                pendingMove = nil
                if routingPair {
                    let shown = await engine.run { $0.movePair(to: next) }
                    if isRouting, let shown { pairPreview = shown }
                } else {
                    let shown = await engine.run { $0.move(to: next) }
                    if isRouting { preview = shown }
                }
            }
            moving = false
        }
    }

    /// A click at `p`: a track started there, or the one being routed fixed there; `double`: finished there
    func click(at p: KiCadPoint, double: Bool = false) {
        guard tool.routes else { return }
        // (a click while one is being dealt with waits its turn, and the pointer's moves before it are done with)
        if isRouting { pendingMove = nil }
        let previous = clicking
        clicking = Task {
            await previous?.value
            await clickNow(at: p, double: double)
        }
    }
    private var clicking: Task<Void, Never>?

    /// The pointer moved to `p`, waited for (for scripts: the screenshots, the self-test)
    func moveNow(to p: KiCadPoint) async {
        guard isRouting else { return }
        if routingPair {
            let shown = await engine.run { $0.movePair(to: p) }
            if isRouting, let shown { pairPreview = shown }
            return
        }
        let shown = await engine.run { $0.move(to: p) }
        if isRouting { preview = shown }
    }

    /// A click at `p`, waited for
    func clickNow(at p: KiCadPoint, double: Bool = false) async {
        if !isRouting && tool == .pair {
            guard !double else { return }
            let layer = self.layer, mode: RouterMode = shove ? .shove : .walkaround, corners = self.corners
            await applying?.value
            if !isReady { await prepareNow() }
            let started = await engine.run { session -> (BoardEditing.PairPreview?, String)? in
                session.mode = mode
                session.cornerMode = corners
                let shown = session.startPair(at: p, layer: layer)
                return (shown.flatMap { _ in session.movePair(to: p) } ?? shown, session.failureReason)
            }
            guard let (shown, reason) = started else { return }
            if let shown {
                isRouting = true
                routingPair = true
                showPair(shown)
                message = "Click to fix the pair, double-click to finish it. V: vias, /: posture, Esc: stop."
            } else {
                NSSound.beep()
                message = reason.isEmpty ? "A differential pair can't start there." : reason
            }
            return
        }
        if routingPair {
            let edit = await engine.run { session -> (BoardEditing.Edit?, BoardEditing.PairPreview?)? in
                let e = double ? session.finish(at: p) : session.fix(at: p)
                return (e, session.currentPairPreview)
            }
            guard let (made, shown) = edit else { return }
            if let made {
                routingEnded()
                take(made)
            } else {
                showPair(shown)
            }
            return
        }
        if !isRouting {
            guard !double else { return }
            let layer = self.layer, width = self.width, mode: RouterMode = shove ? .shove : .walkaround, corners = self.corners
            await applying?.value
            if !isReady { await prepareNow() }
            let started = await engine.run { session -> (Bool, String, BoardEditing.Preview?)? in
                session.mode = mode
                session.cornerMode = corners
                let l = session.startLayer(at: p, preferring: layer)
                guard session.start(at: p, layer: l, width: width) else { return (false, l, nil) }
                return (true, l, session.move(to: p))
            }
            guard let (ok, startLayer, shown) = started else { return }
            if ok {
                if startLayer != self.layer { self.layer = startLayer }
                isRouting = true
                preview = shown
                message = "Click to fix the track, double-click to finish it. V: via, /: posture, ⌫: back, Esc: stop."
            } else {
                NSSound.beep()
                message = "A track can't start there: another net's copper is there, or too close."
            }
            return
        }
        let edit = await engine.run { session -> (BoardEditing.Edit?, BoardEditing.Preview?)? in
            let e = double ? session.finish(at: p) : session.fix(at: p)
            return (e, session.preview)
        }
        guard let (made, shown) = edit else { return }
        if let made {
            routingEnded()
            take(made)
        } else {
            preview = shown
            if let shown { layerFollows(shown) }
        }
    }

    /// The layer shown as the router's, once a via has taken the track to another
    private func layerFollows(_ shown: BoardEditing.Preview) {
        if shown.layer != layer {
            // (set without placing another via)
            isSettingLayer = true
            layer = shown.layer
            isSettingLayer = false
        }
    }
    private var isSettingLayer = false
    /// Whether what is being routed is a differential pair
    private var routingPair = false

    /// A via at the track's end (the pair's two), to the next layer (the other side, on two)
    func placeVia() {
        guard isRouting else { return }
        if routingPair {
            Task { showPair(await engine.run { $0.placePairVias() }) }
        } else {
            Task { show(await engine.run { $0.placeVia() }) }
        }
    }

    func flipPosture() {
        guard isRouting else { return }
        if routingPair {
            Task {
                showPair(await engine.run { session -> BoardEditing.PairPreview? in
                    session.flipPosture()
                    return session.currentPairPreview
                })
            }
        } else {
            Task { show(await engine.run { $0.flipPosture() }) }
        }
    }

    /// The last fixed part of the track taken back
    func undoSegment() {
        guard isRouting else { return }
        Task { show(await engine.run { $0.undoSegment() }) }
    }

    /// The track routed on to where its net goes next, and finished there (KiCad's End)
    func finishToRatsnest() {
        guard isRouting else { return }
        Task {
            guard let made = await engine.run({ $0.finishToRatsnest() }) else {
                NSSound.beep()
                message = "The track can't get to the rest of its net from here."
                return
            }
            routingEnded()
            take(made)
        }
    }

    /// Routing stopped, what is fixed of the track kept (Escape)
    func stop() {
        guard isRouting else { return }
        pendingMove = nil
        let previous = stopping
        stopping = Task {
            await previous?.value
            await stopNow()
        }
    }
    private var stopping: Task<Void, Never>?

    /// Routing stopped, waited for
    func stopNow() async {
        guard isRouting else { return }
        pendingMove = nil
        let made = await engine.run { $0.stop() }
        routingEnded()
        if let made { take(made) }
    }

    private func show(_ shown: BoardEditing.Preview?) {
        guard let shown else { return }
        preview = shown
        layerFollows(shown)
    }

    /// The pair as it now goes, and its layer the one shown
    private func showPair(_ shown: BoardEditing.PairPreview?) {
        guard let shown else { return }
        pairPreview = shown
        if shown.layer != layer {
            isSettingLayer = true
            layer = shown.layer
            isSettingLayer = false
        }
    }

    private func routingEnded() {
        isRouting = false
        routingPair = false
        preview = nil
        pairPreview = nil
        message = tool.routes ? startMessage : nil
    }

    /// How to start with the routing tool chosen
    private var startMessage: String {
        tool == .pair ? "Click a pad of a differential pair's net (a net named like USB_P and USB_N, or D+ and D-) to route the pair."
                      : "Click a pad or track to start a track."
    }

    // MARK: - Dragging tracks and vias

    /// Where the pointer last was over the board
    private(set) var pointer: KiCadPoint?
    /// Whether the drag follows the pointer until a click (started by a key), not a press of the button
    private var followsPointer = false
    private var dragStart: Task<Bool, Never>?
    private var pendingDrag: KiCadPoint?
    private var dragMoving = false
    /// Whether the drag is of several tracks together (the selection's), with the port of KiCad's MULTI_DRAGGER
    private var draggingSeveral = false

    /// Starts dragging the track or via at `p` (mm) with the router, as KiCad's drag (D) drags it (its free angle
    /// drag, G, with `freeAngle`): walking round what is in its way, or shoving it aside, as tracks are routed;
    /// `follow`, the drag goes with the pointer until a click (a key started it), else until the button is let go.
    /// Whether there was a track or via there to drag.
    @discardableResult
    func startDrag(at p: KiCadPoint, freeAngle: Bool = false, follow: Bool = false, several: [String] = []) async -> Bool {
        guard !isRouting, !isDragging else { return false }
        let layer = self.layer, mode: RouterMode = shove ? .shove : .walkaround, corners = self.corners
        await applying?.value
        if !isReady { await prepareNow() }
        let started = await engine.run { session -> (preview: BoardEditing.DragPreview, several: Bool)? in
            session.mode = mode
            session.cornerMode = corners
            // (several tracks selected, one of them under the pointer: all of them dragged together, KiCad's
            // MULTI_DRAGGER; else the one there)
            if !several.isEmpty, let together = session.startMultiDrag(several, at: p, layer: layer) { return (together, true) }
            return session.startDrag(at: p, layer: layer, freeAngle: freeAngle).map { ($0, false) }
        }
        guard let started else { return false }
        let shown = started.preview
        draggingSeveral = started.several
        selection = []
        isDragging = true
        followsPointer = follow
        dragPreview = shown
        message = follow ? "Move to drag, click to keep it there. Esc: drop it." : nil
        return true
    }

    /// The drag key (D, or G for its free angle drag) at the pointer
    func dragAtPointer(freeAngle: Bool) {
        guard let p = pointer, !isDragging else { return }
        Task {
            let started = await startDrag(at: p, freeAngle: freeAngle, follow: true)
            if !started {
                NSSound.beep()
                message = "Put the pointer on a track or via to drag it."
            }
        }
    }

    /// The pointer moved to `p` (mm), dragging: only the latest place it has got to dragged to
    func dragMoved(to p: KiCadPoint) {
        pendingDrag = p
        guard !dragMoving else { return }
        dragMoving = true
        Task {
            if let start = dragStart { _ = await start.value }
            while let next = pendingDrag {
                pendingDrag = nil
                let several = draggingSeveral
                let shown = await engine.run { several ? $0.multiDrag(to: next) : $0.drag(to: next) }
                if isDragging, let shown { dragPreview = shown }
            }
            dragMoving = false
        }
    }

    /// The drag kept where it has got to with the pointer at `p` (a click, or the button let go); dropped, the
    /// board as it was, if it could not get past what is in its way there
    func fixDrag(at p: KiCadPoint) async {
        if let start = dragStart { _ = await start.value }
        guard isDragging else { return }
        pendingDrag = nil
        let several = draggingSeveral
        let made = await engine.run { session -> BoardEditing.Edit? in
            if several {
                session.multiDrag(to: p)
                if let made = session.fixMultiDrag(at: p) { return made }
                session.cancelMultiDrag()
                return nil
            }
            session.drag(to: p)
            if let made = session.fixDrag(at: p) { return made }
            session.cancelDrag()
            return nil
        }
        dragEnded(kept: made != nil)
        if let made { take(made) }
    }

    /// The drag dropped, the board as it was (Escape)
    func cancelDrag() {
        guard isDragging else { return }
        pendingDrag = nil
        let several = draggingSeveral
        Task {
            _ = await engine.run { session -> Bool? in
                if several { session.cancelMultiDrag() } else { session.cancelDrag() }
                return true
            }
            dragEnded(kept: true)
        }
    }

    private func dragEnded(kept: Bool) {
        isDragging = false
        draggingSeveral = false
        followsPointer = false
        dragPreview = nil
        if kept {
            message = nil
        } else {
            NSSound.beep()
            message = "The drag can't get past what is in its way there."
        }
    }

    // MARK: - Selecting and deleting

    /// The track or via at `p` selected (added to the selection, or taken from it, `extending`); whether there was one
    @discardableResult
    func select(at p: KiCadPoint, in picture: KiCadBoardPicture, slop: Double, extending: Bool) -> Bool {
        let order = [layer] + layers.filter { $0 != layer }
        guard let uuid = picture.copper(at: p, layers: order, slop: slop) else {
            if !extending { selection = [] }
            return false
        }
        if extending { selection.formSymmetricDifference([uuid]) } else { selection = [uuid] }
        return true
    }

    func deleteSelection() { Task { await deleteSelectionNow() } }

    func deleteSelectionNow() async {
        if selection.isEmpty, patternSelection != nil {
            deleteSelectedPattern()
            return
        }
        guard !selection.isEmpty, !isRouting else { return }
        let uuids = selection
        selection = []
        await applying?.value
        if !isReady { await prepareNow() }
        guard let made = await engine.run({ $0.remove(uuids) }) else { return }
        take(made)
    }

    // MARK: - Routing every connection

    /// Every connection still to route routed, as one change (`groundToo` false: the ground nets left for a pour)
    func routeAll(groundToo: Bool = true) {
        guard !isRouting else { return }
        let layer = self.layer, width = self.width
        Task {
            await applying?.value
            if !isReady { await prepareNow() }
            message = "Routing every connection…"
            let routed = await engine.run { session -> BoardEditing.Routed? in
                let ground = groundToo ? [] : Set(session.router.world.netNames.values.filter { $0.uppercased().contains("GND") })
                return session.routeConnections(skip: ground, layer: layer, width: width)
            }
            guard let routed else { return }
            if let edit = routed.edit { take(edit) }
            message = "Routed \(routed.routed.count) connection\(routed.routed.count == 1 ? "" : "s")"
                + (routed.failed.isEmpty ? "" : "; \(routed.failed.count) could not be routed") + "; \(routed.left) left to route."
        }
    }

    /// One connection routed (a line of the ratsnest clicked), as Route All routes each: on this layer, else the other
    /// side
    func routeConnection(_ wire: KiCadConnectivity.Airwire) { Task { await routeConnectionNow(wire) } }

    /// One connection routed, waited for
    func routeConnectionNow(_ wire: KiCadConnectivity.Airwire) async {
        guard !isRouting else { return }
        let layer = self.layer, width = self.width
        hoveredAirwire = nil
        await applying?.value
        if !isReady { await prepareNow() }
        if let made = await engine.run({ $0.routeConnection(wire, layer: layer, width: width) }) {
            take(made)
            message = nil
        } else {
            NSSound.beep()
            message = "The router can't get \(wire.net) through from \(wire.ends.first ?? "here") to \(wire.ends.last ?? "there") on either side."
        }
    }

    // MARK: - Pours

    /// A ground pour over the whole board on `layers`, filled as KiCad fills it (`net`: the board's ground net if nil)
    /// The teardrop settings being edited in the Teardrops sheet (the board's, as its project keeps them), shown
    /// while it is open
    @Published var teardropSettings: TeardropSettings?

    /// The Teardrops sheet opened on the board's teardrop settings
    func editTeardrops() {
        Task {
            await applying?.value
            if !isReady { await prepareNow() }
            teardropSettings = await engine.run { $0.teardropSettings } ?? TeardropSettings()
        }
    }

    /// Teardrops made on the board with `settings`, as KiCad's Set Teardrops dialog adds them (its zones filled
    /// again with them), as one change; the settings kept in the board's project
    func addTeardrops(_ settings: TeardropSettings) {
        teardropSettings = nil
        Task {
            await applying?.value
            if !isReady { await prepareNow() }
            guard let made = await engine.run({ $0.addTeardrops(settings: settings) }) else {
                NSSound.beep()
                message = "No teardrops to make there: none of the pads, vias or track ends asked for take one, or the board has what JSpice does not make teardrops round yet (padstacks, curved custom pads, texts in other fonts on copper)."
                return
            }
            take(made)
            if let kept = made.teardropSettings { controller?.setTeardropSettings(kept) }
            if !made.refilled { await fillZonesNow() }
            message = nil
        }
    }

    /// Every teardrop taken away, as the Set Teardrops dialog's "remove all teardrops" does, as one change
    func removeTeardrops() {
        Task {
            await applying?.value
            if !isReady { await prepareNow() }
            guard let made = await engine.run({ $0.removeTeardrops() }) else {
                NSSound.beep()
                message = "The board has no teardrops."
                return
            }
            take(made)
            if let kept = made.teardropSettings { controller?.setTeardropSettings(kept) }
            if !made.refilled { await fillZonesNow() }
            message = nil
        }
    }

    func addPour(net: String? = nil, layers: [String]) {
        Task {
            await applying?.value
            if !isReady { await prepareNow() }
            let made = await engine.run { session -> BoardEditing.Edit? in
                guard let n = net ?? session.groundNets.first else { return nil }
                return session.addPour(net: n, layers: layers)
            }
            guard let made else {
                NSSound.beep()
                message = "The board has no ground net to pour: name the schematic's ground GND."
                return
            }
            take(made)
            if !made.refilled { await fillZonesNow() }
        }
    }

    /// The board's pours taken away
    func removePours() {
        Task {
            await applying?.value
            if !isReady { await prepareNow() }
            guard let made = await engine.run({ s in s.removeZones(Set(s.board.zones.filter { !$0.isRuleArea }.map(\.uuid))) }) else { return }
            take(made)
        }
    }

    /// The board's zones filled anew (B, as in KiCad)
    func fillZones() { Task { await fillZonesNow() } }

    /// Stitching vias for the ground pours, every 5 mm where both sides' are filled (as KiCad last filled them) and
    /// the router finds room, as one change; KiCad then fills the pours round them
    func stitchPours() {
        guard !isRouting else { return }
        Task {
            await applying?.value
            if !isReady { await prepareNow() }
            let made = await engine.run { session -> BoardEditing.Edit? in
                guard let net = session.groundNets.first else { return nil }
                return session.stitchVias(net: net)
            }
            guard let made else {
                NSSound.beep()
                message = "Stitching vias go where the ground is poured and filled on both sides: pour it on both, then fill the zones (B)."
                return
            }
            take(made)
            message = "\(made.added.count) stitching via\(made.added.count == 1 ? "" : "s") placed; filling the pours round them."
            if !made.refilled { await fillZonesNow() }
        }
    }

    func fillZonesNow() async {
        guard let controller, !isRouting else { return }
        await applying?.value
        if let (board, project) = await controller.fillZones() {
            await take(board, project: project)
        }
    }

    // MARK: - Vias and sizes

    /// A click with the via tool at `p`: a via placed there as KiCad's Add Vias places one (snapped onto the track,
    /// pad or drawing there, of its net or the zone's, refused where the design rules keep it off), as one change;
    /// `net` the one chosen where several zones' fills meet
    func viaClick(at p: KiCadPoint, net: String? = nil) {
        guard tool == .via, !isRouting else { return }
        viaNetChoice = nil
        Task {
            await applying?.value
            if !isReady { await prepareNow() }
            guard let placed = await engine.run({ $0.placeVia(at: p, net: net) }) else { return }
            switch placed {
            case .placed(let edit, _):
                message = nil
                take(edit)
                if !edit.refilled { await fillZonesNow() }
            case .violatesDRC:
                NSSound.beep()
                message = "Via location violates DRC."
            case .ambiguous(let nets):
                viaNetChoice = (p, nets)
            }
        }
    }

    /// The tracks' width (mm) of those selected set, or the vias' diameter and drill (mm), as one change
    func resizeSelection(width: Double? = nil, via: (diameter: Double, drill: Double)? = nil) {
        let chosen = selection
        guard !chosen.isEmpty, !isRouting else { return }
        Task {
            let changed = await place { $0.setSizes(chosen, width: width, viaDiameter: via?.diameter, viaDrill: via?.drill) }
            if !changed {
                NSSound.beep()
                message = "The tracks and vias selected are that size already."
            } else if lastTaken?.refilled != true {
                await fillZonesNow()
            }
        }
    }

    // MARK: - Tuning lengths

    /// The length or skew to reach, on `base` (the settings KiCad's tool of the mode starts with, the board's
    /// project's: its tuning pattern defaults; or the pattern's own, one being edited)
    nonisolated static func tuneSettings(_ base: MeanderSettings, mode: BoardRouter.TuningMode, length: Double, skew: Double) -> MeanderSettings {
        var settings = base
        if mode == .skew {
            settings.setTargetSkew(Int((skew * 1e6).rounded()))
        } else {
            settings.setTargetLength(Int((length * 1e6).rounded()))
        }
        return settings
    }

    /// A click with the tune tool at `p`: a tuning started on the track (or pair) there, or the one under way kept
    /// there, as one change
    func tuneClick(at p: KiCadPoint) {
        guard tool == .tune, !isRouting else { return }
        let previous = clicking
        clicking = Task {
            await previous?.value
            if tuning == nil {
                let (mode, length, skew, layer) = (tuneMode, tuneLength, tuneSkew, layer)
                let started = await engine.run { session -> (BoardEditing.TuningPreview?, String) in
                    let settings = Self.tuneSettings(session.defaultTuningSettings(mode), mode: mode, length: length, skew: skew)
                    // (a track of a pattern: the pattern's end dragged, as KiCad's point editor drags it)
                    return (session.startTuning(at: p, layer: layer, mode: mode, settings: settings), session.failureReason)
                }
                if let preview = started?.0 {
                    tuning = preview
                    message = nil
                } else {
                    NSSound.beep()
                    message = started?.1.isEmpty == false ? started?.1 : "There is no track there to tune."
                }
                return
            }
            pendingTune = nil
            guard let made = await engine.run({ $0.fixTuning(at: p) }) else { return }
            tuning = nil
            take(made)
        }
    }

    private var pendingTune: KiCadPoint?
    private var tuneMoving = false

    /// The pointer moved to `p`, tuning: the meanders fitted to the stretch up to it (only the latest place it got to)
    private func tuneMoved(to p: KiCadPoint) {
        pendingTune = p
        guard !tuneMoving else { return }
        tuneMoving = true
        Task {
            while let next = pendingTune {
                pendingTune = nil
                let shown = await engine.run { $0.moveTuning(to: next) }
                if tuning != nil, let shown { tuning = shown }
            }
            tuneMoving = false
        }
    }

    /// The meanders' spacing (1 wider, 2 narrower) or amplitude (3 higher, 4 lower) a step, as KiCad's keys step them
    func stepTuning(spacing: Int = 0, amplitude: Int = 0) {
        guard tuning != nil else { return }
        Task {
            let shown = await engine.run { session -> BoardEditing.TuningPreview? in
                if spacing != 0 { return session.stepTuningSpacing(spacing) }
                return session.stepTuningAmplitude(amplitude)
            }
            if tuning != nil, let shown { tuning = shown }
        }
    }

    private func tuneSettingsChanged() {
        guard tuning != nil else { return }
        let (mode, length, skew) = (tuneMode, tuneLength, tuneSkew)
        Task {
            let shown = await engine.run { session -> BoardEditing.TuningPreview? in
                let base = session.tuningPatternPreview?.settings ?? session.defaultTuningSettings(mode)
                return session.updateTuningSettings(Self.tuneSettings(base, mode: mode, length: length, skew: skew))
            }
            if tuning != nil, let shown { tuning = shown }
        }
    }

    // MARK: - Tuning patterns

    /// The tuning pattern selected, as the session has it
    var selectedPattern: BoardEditing.TuningPatternInfo? { patterns.first { $0.uuid == patternSelection } }

    /// The tuning pattern a click at `p` selects (KiCad's: its tracks are not selectable on their own, a click on one
    /// selects the pattern), nil if there is none there
    func pattern(at p: KiCadPoint, in picture: KiCadBoardPicture, slop: Double) -> String? {
        let order = [layer] + layers.filter { $0 != layer }
        guard let uuid = picture.copper(at: p, layers: order, slop: slop) else { return nil }
        return patterns.first { $0.members.contains(uuid) }?.uuid
    }

    /// The selected pattern's target (mm: the length to reach, a skew pattern's skew), within KiCad's 0.1 mm either
    /// side (none: a length as long as the meanders make it), the pattern tuned again with it, as its properties panel
    /// changes it: one change
    func setPatternTarget(_ value: Double?) {
        guard let pattern = selectedPattern, !isRouting, tuning == nil else { return }
        let uuid = pattern.uuid
        var settings = pattern.settings
        if let value {
            settings = Self.tuneSettings(pattern.settings, mode: pattern.mode, length: value, skew: value)
        } else if pattern.mode != .skew {
            settings.setTargetLength(MeanderSettings.lengthUnconstrained)
        }
        Task {
            if !(await place { $0.editTuningPattern(uuid, settings: settings) }) {
                NSSound.beep()
                message = "The pattern is tuned to that already."
            }
        }
    }

    /// The selected pattern's meanders' largest amplitude (mm), tuned again with it: one change
    func setPatternAmplitude(_ value: Double) {
        guard let pattern = selectedPattern, !isRouting, tuning == nil, value > 0 else { return }
        let uuid = pattern.uuid
        var settings = pattern.settings
        settings.maxAmplitude = Int((value * 1e6).rounded())
        if settings.minAmplitude > settings.maxAmplitude { settings.minAmplitude = settings.maxAmplitude }
        Task { _ = await place { $0.editTuningPattern(uuid, settings: settings) } }
    }

    /// The board's tuning patterns tuned again, each in turn (KiCad's Edit > Update All Tuning Patterns): one change
    func updateAllPatterns() {
        guard !isRouting, tuning == nil else { return }
        Task {
            if !(await place { $0.updateAllTuningPatterns() }) { message = "The tuning patterns are as they would be tuned already." }
        }
    }

    /// The selected pattern deleted, its line made straight again along the line it was placed over (KiCad's Delete
    /// of a pattern): one change
    func deleteSelectedPattern() {
        guard let uuid = patternSelection, !isRouting else { return }
        patternSelection = nil
        Task { _ = await place { $0.removeTuningPattern(uuid) } }
    }

    /// The tuning dropped (Esc), the track as it was
    func cancelTuning() {
        guard tuning != nil else { return }
        tuning = nil
        pendingTune = nil
        Task { _ = await engine.run { session -> Bool? in session.cancelTuning(); return true } }
    }

    // MARK: - Drawing zones

    /// A point on the 0.05 mm grid footprints are moved on
    static func onGrid(_ p: KiCadPoint) -> KiCadPoint {
        let grid = 0.05
        return KiCadPoint((p.x / grid).rounded() * grid, (p.y / grid).rounded() * grid)
    }

    /// A click with the zone tool at `p`: a corner of the zone being drawn (on the grid); `double`: its last, the zone
    /// (or rule area) then made on the layer chosen, filled as it is made
    func zoneClick(at p: KiCadPoint, double: Bool) {
        guard tool == .zone, !isRouting else { return }
        let corner = Self.onGrid(p)
        if zoneCorners.last != corner { zoneCorners.append(corner) }
        zonePointer = corner
        guard double else { return }
        let outline = zoneCorners
        zoneCorners = []
        zonePointer = nil
        guard outline.count >= 3 else {
            NSSound.beep()
            message = "A zone needs three corners or more: click them, then double-click the last."
            return
        }
        let (kind, layer, keepout, chosen) = (zoneKind, layer, zoneKeepout, zoneNet)
        Task {
            let made = await place { session -> BoardEditing.Edit? in
                switch kind {
                case .copper:
                    guard let net = chosen ?? session.groundNets.first else { return nil }
                    return session.addZone(net: net, layers: [layer], outline: outline)
                case .keepout:
                    return session.addRuleArea(layers: [layer], outline: outline, keepout: keepout)
                }
            }
            if !made {
                NSSound.beep()
                message = "Choose the zone's net first: the board has no ground net."
            } else if lastTaken?.refilled != true {
                await fillZonesNow()
            }
        }
    }

    /// The zone's last corner taken back (⌫); whether there was one
    @discardableResult
    func undoZoneCorner() -> Bool {
        guard tool == .zone, !zoneCorners.isEmpty else { return false }
        zoneCorners.removeLast()
        if zoneCorners.isEmpty { zonePointer = nil }
        return true
    }

    /// The zone being drawn dropped (Esc); whether there was one
    @discardableResult
    func cancelZone() -> Bool {
        guard !zoneCorners.isEmpty else { return false }
        zoneCorners = []
        zonePointer = nil
        return true
    }

    // MARK: - Placing

    /// A drag from `start` to `now` (mm) with the select tool: the footprint there (with the others selected, if it is
    /// one of them) following it, on a 0.05 mm grid
    /// A track or via there is dragged with the router instead (until the button is let go).
    /// From where there is nothing to drag, a box is drawn to select with (`leftward`: drawn right to left on the
    /// screen, taking what it touches).
    /// A footprint is dragged with the tracks on its pads, as KiCad's router drags one (its D on a footprint, the
    /// port of COMPONENT_DRAGGER), unless `moveOnly` (⌥, KiCad's move): then the tracks stay where they are.
    func dragChanged(from start: KiCadPoint, to now: KiCadPoint, in picture: KiCadBoardPicture, selected: Set<String>, leftward: Bool,
                     moveOnly: Bool = false) {
        guard tool == .select, !isRouting, !dropsUntilLetGo else { return }
        if draggingWithTracks {
            footprintDragMoved(to: now)
            return
        }
        if selectionArea != nil {
            selectionArea = (start, now, leftward)
            return
        }
        if isDragging || dragStart != nil {
            if !followsPointer { dragMoved(to: now) }
            return
        }
        if dragging == nil, let hit = picture.copper(at: start, layers: [layer] + layers.filter { $0 != layer }, slop: 0) {
            // (a track of several selected: the selected tracks all dragged together)
            let tracks = Set(picture.tracks.map(\.uuid))
            let several = selection.contains(hit) && selection.filter(tracks.contains).count > 1
                ? [hit] + selection.filter { tracks.contains($0) && $0 != hit }.sorted() : []
            dragStart = Task {
                let started = await startDrag(at: start, several: several)
                dragStart = nil
                return started
            }
            dragMoved(to: now)
            return
        }
        if dragging == nil, let text = PCBTextStrokes.shared.text(at: start, in: picture, layers: Set(picture.texts.map(\.layer))) {
            dragging = (selection.contains(text) ? picture.texts.map(\.uuid).filter(selection.contains) : [text], .zero)
            draggingTexts = true
        }
        if dragging == nil {
            guard let footprint = picture.footprint(at: start) else {
                selectionArea = (start, now, leftward)
                return
            }
            let uuids = selected.contains(footprint.uuid) ? Array(selected) : [footprint.uuid]
            dragging = (uuids, .zero)
            if !moveOnly {
                draggingWithTracks = true
                footprintDragStart = Task { await startFootprintDrag(uuids, at: start) }
                footprintDragMoved(to: now)
                return
            }
        }
        let grid = 0.05
        dragging?.delta = KiCadPoint(((now.x - start.x) / grid).rounded() * grid, ((now.y - start.y) / grid).rounded() * grid)
    }

    /// The drag let go: the footprints moved there (the track or via dragged kept there); a footprint dragged with
    /// its tracks kept there if it collides with nothing, or `force`d (⌘, KiCad's Ctrl)
    func dragEnded(at p: KiCadPoint, force: Bool = false) {
        if dropsUntilLetGo {
            dropsUntilLetGo = false
            return
        }
        if (isDragging || dragStart != nil) && !followsPointer {
            Task { await fixDrag(at: p) }
            return
        }
        if draggingWithTracks {
            Task { await fixFootprintDrag(at: p, force: force) }
            return
        }
        guard let (uuids, delta) = dragging else { return }
        dragging = nil
        let texts = draggingTexts
        draggingTexts = false
        guard delta != .zero else { return }
        Task { await place { texts ? $0.moveDrawings(uuids, by: delta) : $0.moveFootprints(uuids, by: delta) } }
    }

    // MARK: - Dragging footprints with their tracks

    /// Whether the footprints being dragged take the tracks on their pads with them (the router's footprint drag)
    @Published private(set) var draggingWithTracks = false
    /// The footprint drag as it now goes: the tracks it takes away, and those that go in their place
    @Published private(set) var footprintDragPreview: BoardEditing.FootprintDragPreview?
    private var footprintDragStart: Task<Void, Never>?
    private var pendingFootprintDrag: KiCadPoint?
    private var footprintDragMoving = false
    /// A footprint drag dropped while the button is still down: the rest of that drag of the pointer does nothing
    private var dropsUntilLetGo = false

    /// The footprint drag's tracks, as a track drag's are drawn (outlined in red while what it moves collides)
    var footprintDragTracks: BoardEditing.DragPreview? {
        guard let f = footprintDragPreview else { return nil }
        return BoardEditing.DragPreview(moved: f.moved, tracks: f.tracks, violates: f.collides)
    }

    /// Starts dragging footprints with their tracks with the router, the pointer at `p`; where the router has nothing
    /// of them to drag (no pads), they are moved on their own instead
    private func startFootprintDrag(_ uuids: [String], at p: KiCadPoint) async {
        let layer = self.layer, mode: RouterMode = shove ? .shove : .walkaround, corners = self.corners
        await applying?.value
        if !isReady { await prepareNow() }
        let shown = await engine.run { session -> BoardEditing.FootprintDragPreview? in
            session.mode = mode
            session.cornerMode = corners
            return session.startFootprintDrag(uuids, at: p, layer: layer, warpsCursor: false)
        }
        guard draggingWithTracks else { return }
        if let shown {
            footprintDragPreview = shown
            dragging?.delta = shown.offset
        } else {
            draggingWithTracks = false
        }
    }

    /// The pointer moved to `p` (mm), dragging footprints: only the latest place it has got to dragged to
    private func footprintDragMoved(to p: KiCadPoint) {
        pendingFootprintDrag = p
        guard !footprintDragMoving else { return }
        footprintDragMoving = true
        Task {
            await footprintDragStart?.value
            while let next = pendingFootprintDrag {
                pendingFootprintDrag = nil
                guard draggingWithTracks else { break }
                let shown = await engine.run { $0.dragFootprint(to: next) }
                if draggingWithTracks, let shown {
                    footprintDragPreview = shown
                    dragging?.delta = shown.offset
                }
            }
            footprintDragMoving = false
        }
    }

    /// The footprint drag kept with the pointer at `p`, as one change, if what it moved collides with nothing (or
    /// `force`d); else dropped, the board as it was
    private func fixFootprintDrag(at p: KiCadPoint, force: Bool) async {
        await footprintDragStart?.value
        pendingFootprintDrag = nil
        guard draggingWithTracks else {
            // (nothing the router could drag: the footprints moved on their own, as far as they got)
            if let (uuids, delta) = dragging, delta != .zero {
                dragging = nil
                await place { $0.moveFootprints(uuids, by: delta) }
            }
            dragging = nil
            return
        }
        let made = await engine.run { session -> BoardEditing.Edit? in
            session.dragFootprint(to: p)
            if let made = session.fixFootprintDrag(at: p, force: force) { return made }
            session.cancelFootprintDrag()
            return nil
        }
        endFootprintDrag()
        if let made {
            take(made)
            message = nil
        } else {
            NSSound.beep()
            message = "The part would come too near something there: hold ⌘ as you let go to put it there anyway, or ⌥ to move it without its tracks."
        }
    }

    /// The footprint drag dropped (Esc); whether there was one
    @discardableResult
    func cancelFootprintDrag() -> Bool {
        guard draggingWithTracks else { return false }
        endFootprintDrag()
        dropsUntilLetGo = true
        Task { _ = await engine.run { session -> Bool? in session.cancelFootprintDrag(); return true } }
        return true
    }

    private func endFootprintDrag() {
        draggingWithTracks = false
        footprintDragPreview = nil
        footprintDragStart = nil
        dragging = nil
    }

    /// How a box drawn to select with changes the selection, by the keys held as it is let go (KiCad's
    /// setModifiersState, ⌘ for Ctrl): none, it is what the box takes; ⇧ adds to it; ⌘ adds what is not selected and
    /// takes away what is; ⌘⇧ takes away
    enum AreaSelection {
        case replace, add, toggle, remove

        init(shift: Bool, command: Bool) {
            self = shift && command ? .remove : command ? .toggle : shift ? .add : .replace
        }
    }

    /// The box drawn to select with let go: the tracks and vias it takes (KiCad's SelectMultiple, the board as it
    /// now is) selected as `mode` says; the footprints selected then, from those selected before (`footprints`), or
    /// nil if no box was being drawn
    func endSelectionArea(footprints: Set<String>, mode: AreaSelection) async -> Set<String>? {
        guard let area = selectionArea else { return nil }
        selectionArea = nil
        await applying?.value
        if !isReady { await prepareNow() }
        guard let taken = await engine.run({ $0.itemsInBox(from: area.from, to: area.to, touching: area.touching) }) else {
            return footprints
        }
        let (copper, parts) = taken
        func apply(_ taken: [String], to selected: Set<String>) -> Set<String> {
            switch mode {
            case .replace: return Set(taken)
            case .add: return selected.union(taken)
            case .toggle: return selected.symmetricDifference(taken)
            case .remove: return selected.subtracting(taken)
            }
        }
        selection = apply(copper, to: selection)
        return apply(parts, to: footprints)
    }

    /// Footprints turned 90° counterclockwise (R), and the board's texts selected about their own positions
    func rotate(_ uuids: Set<String>) {
        let texts = Set(controller?.picture?.texts.map(\.uuid) ?? []).intersection(selection)
        guard !uuids.isEmpty || !texts.isEmpty else { return }
        Task {
            if !uuids.isEmpty { await place { $0.rotateFootprints(uuids.sorted()) } }
            if !texts.isEmpty { await place { $0.rotateTexts(texts.sorted()) } }
        }
    }

    // MARK: - Texts and footprints placed on their own

    /// A click with the text tool at `p`: the words typed in placed there (on the grid), on the text tool's layer,
    /// as KiCad's Add Text places them (of the layer's text style, the project's)
    func textClick(at p: KiCadPoint) {
        guard tool == .text, !isRouting else { return }
        let words = textToPlace, layer = textLayer
        Task {
            if await place({ $0.addText(words, at: Self.onGrid(p), layer: layer) }) {
                message = nil
            } else {
                NSSound.beep()
                message = "Type the text to place beside the tool first."
            }
        }
    }

    /// The footprints of KiCad's libraries whose ids hold each of `query`'s words, to choose one to place from
    func searchFootprints(_ query: String) {
        Task {
            let found = await controller?.searchFootprints(query) ?? []
            footprintMatches = found
            if footprintToPlace == nil || !found.contains(footprintToPlace ?? "") { footprintToPlace = found.first }
        }
    }

    /// A click with the footprint tool at `p`: the footprint chosen placed there (on the grid), as KiCad's Place
    /// Footprint places one: on the front, its pads on no net, its reference the library's; a part of the board alone
    func footprintClick(at p: KiCadPoint) {
        guard tool == .footprint, !isRouting else { return }
        guard let libID = footprintToPlace else {
            NSSound.beep()
            message = "Look for a footprint beside the tool first, and choose one."
            return
        }
        Task {
            guard let footprint = await controller?.footprint(libID) else {
                NSSound.beep()
                message = "KiCad's footprint libraries have no \(libID)."
                return
            }
            if await place({ $0.addFootprint(footprint, libID: libID, at: Self.onGrid(p)) }) { message = nil }
        }
    }

    /// Footprints turned over to the other side (F)
    func flip(_ uuids: Set<String>) {
        guard !uuids.isEmpty else { return }
        Task { await place { $0.flipFootprints(uuids.sorted()) } }
    }

    /// The board's outline drawn round its parts again (and the pours drawn to it with it)
    func fitOutline() {
        Task {
            await place { $0.fitOutline() }
            if undoName == "Fit Outline to Parts", lastTaken?.refilled != true { await fillZonesNow() }
        }
    }

    /// The board's outline made a rectangle `width` by `height` (mm), its corners rounded to `radius` (mm), and its
    /// pours filled again within it
    func setOutline(width: Double, height: Double, radius: Double) {
        Task {
            await place { $0.setOutline(width: width, height: height, radius: radius) }
            if undoName == "Change Board Outline", lastTaken?.refilled != true { await fillZonesNow() }
        }
    }

    /// The tracks and vias of the nets of those selected, all of them (I, as KiCad selects a net's copper)
    func selectNets(in picture: KiCadBoardPicture) {
        let nets = Set(picture.tracks.filter { selection.contains($0.uuid) }.compactMap(\.net)
                       + picture.vias.filter { selection.contains($0.uuid) }.compactMap(\.net))
        guard !nets.isEmpty else { return }
        selection = Set(picture.tracks.filter { $0.net.map(nets.contains) ?? false }.map(\.uuid)
                        + picture.vias.filter { $0.net.map(nets.contains) ?? false }.map(\.uuid))
    }

    /// A change to the footprints' places (or the board's outline, or parts of the board alone), made and sent to the
    /// board; whether there was one
    @discardableResult
    func place(_ body: @escaping (BoardEditing) -> BoardEditing.Edit?) async -> Bool {
        guard !isRouting, !isDragging else { return false }
        await applying?.value
        if !isReady { await prepareNow() }
        guard let made = await engine.run(body) else { return false }
        take(made)
        return true
    }

    /// Mounting holes for `screw` (M2, M2.5, M3, M4: KiCad's library's) in the corners of the board's outline
    func addMountingHoles(screw: String) {
        guard let (_, libID, inset) = BoardEditing.mountingHoles.first(where: { $0.screw == screw }) else { return }
        Task {
            guard let footprint = await controller?.footprint(libID) else {
                NSSound.beep()
                message = "KiCad's footprint libraries have no \(libID)."
                return
            }
            if await place({ $0.addMountingHoles(footprint, libID: libID, inset: inset) }) {
                message = nil
            } else {
                NSSound.beep()
                message = "Mounting holes go in the corners of a rectangular outline, where it has none yet."
            }
        }
    }

    // MARK: - Changes

    /// A change made here, sent to the board
    private func take(_ edit: BoardEditing.Edit) {
        lastTaken = edit
        undoStack.append(edit)
        redoStack = []
        updateNames()
        send(edit.after, from: edit.before, name: edit.name)
    }

    func undo() {
        guard !isRouting, !isDragging, let edit = undoStack.popLast() else { return }
        redoStack.append(edit)
        updateNames()
        send(edit.before, from: edit.after, name: "Undo " + edit.name)
    }

    func redo() {
        guard !isRouting, !isDragging, let edit = redoStack.popLast() else { return }
        undoStack.append(edit)
        updateNames()
        send(edit.after, from: edit.before, name: edit.name)
    }

    private func updateNames() {
        undoName = undoStack.last?.name
        redoName = redoStack.last?.name
    }

    /// The board made `after` (from `before`) where it is kept; the session goes on from the board as it then is
    private func send(_ after: KiCadBoard, from before: KiCadBoard, name: String) {
        guard let controller else { return }
        let previous = applying
        applying = Task {
            await previous?.value
            if let board = await controller.boardEdited(after, from: before, name: name) {
                await take(board.board, project: board.project)
            } else {
                // the board could not take it: back to the board as it was
                if let (board, project) = await controller.boardForEditing() { await take(board, project: project) }
                undoStack.removeAll { $0.after === after || $0.before === after }
                redoStack.removeAll { $0.after === after || $0.before === after }
                updateNames()
            }
        }
    }
}

// MARK: - Board setup

extension PCBEditing {
    /// The pre-defined size chosen, taken by the session, and by the track being routed from here on (as KiCad's
    /// width menu changes it while routing)
    private func sizeChoiceChanged() {
        let choice = sizeChoice, routing = isRouting && !routingPair
        Task {
            let shown = await engine.run { session -> BoardEditing.Preview? in
                session.sizeChoice = choice
                guard routing else { return nil }
                return session.setWidth(session.chosenTrackWidth().map { Double($0) / 1e6 })
            }
            if routing { show(shown) }
        }
    }

    /// The board's copper layer count set to `count` as KiCad's Board Setup sets it (its items on the layers removed
    /// taken away, its stackup brought to the new layers), as one change; where layers with items on them would go,
    /// asked first (copperLayersToConfirm), as KiCad asks
    func requestCopperLayers(_ count: Int) {
        guard !isRouting, !isDragging else { return }
        Task {
            await applying?.value
            if !isReady { await prepareNow() }
            let items = await engine.run { $0.itemsOnRemovedLayers(copperLayers: count) } ?? []
            if items.isEmpty {
                await setCopperLayersNow(count)
            } else {
                copperLayersToConfirm = (count, items.count)
            }
        }
    }

    /// The copper layer count waiting for the user's word set
    func confirmCopperLayers() {
        guard let (count, _) = copperLayersToConfirm else { return }
        copperLayersToConfirm = nil
        Task { await setCopperLayersNow(count) }
    }

    func setCopperLayersNow(_ count: Int) async {
        guard await place({ $0.setCopperLayerCount(count) }) else { return }
        await applying?.value
        if !layers.contains(layer) { layer = layers.first ?? "F.Cu" }
        message = "\(count) copper layers: the stackup brought to them as KiCad's Board Setup brings it"
    }
}

/// The session, off the main thread: the router takes its time on a crowded board
final class PCBRouteEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.knowm.jspice.router", qos: .userInteractive)
    // touched only on the queue
    private var session: BoardEditing?

    func run<T>(_ body: @escaping (BoardEditing) -> T?) async -> T? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.session.flatMap(body)) }
        }
    }

    /// The board taken up (anew, if it changed), its copper layers
    func load(_ board: KiCadBoard, project: [String: Any]?) async -> [String] {
        await withCheckedContinuation { continuation in
            queue.async {
                if let session = self.session { session.load(board, project: project) } else { self.session = BoardEditing(board: board, project: project) }
                continuation.resume(returning: self.session?.layers ?? [])
            }
        }
    }

    /// The board taken up again with these project settings (its rules changed)
    func reload(project: [String: Any]) async -> [String] {
        await withCheckedContinuation { continuation in
            queue.async {
                if let session = self.session { session.load(session.board.copy(), project: project) }
                continuation.resume(returning: self.session?.layers ?? [])
            }
        }
    }

    func close() { queue.async { self.session = nil } }
}
