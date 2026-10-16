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
        case select, route
        var id: Self { self }
        var title: String { self == .select ? "Select" : "Route" }
        var symbol: String { self == .select ? "cursorarrow" : "point.topleft.down.to.point.bottomright.curvepath" }
    }

    @Published var tool: Tool = .select {
        didSet { if tool != oldValue { toolChanged() } }
    }
    /// The copper layer tracks are routed on
    @Published var layer = "F.Cu" {
        didSet { if layer != oldValue { layerChanged() } }
    }
    @Published private(set) var layers = ["F.Cu", "B.Cu"]
    /// New tracks' width in mm, nil for their net class's
    @Published var width: Double? {
        didSet { if width != oldValue { widthChanged() } }
    }
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
    /// What the last action could not do, or how to go on
    @Published private(set) var message: String?
    @Published private(set) var undoName: String?
    @Published private(set) var redoName: String?
    @Published private(set) var isReady = false
    /// The connection still to route under the pointer, which the select tool routes when it is clicked
    @Published var hoveredAirwire: KiCadConnectivity.Airwire?

    static let widths: [Double] = [0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.8, 1.0, 1.5, 2.0]

    weak var controller: BoardController?
    private let engine = PCBRouteEngine()
    private var undoStack: [BoardEditing.Edit] = []
    private var redoStack: [BoardEditing.Edit] = []
    private var pendingMove: KiCadPoint?
    private var moving = false
    /// A change on its way to the board, which the next waits for
    private var applying: Task<Void, Never>?

    // MARK: - The board

    /// The board taken up for editing, as the board link has it (KiCad's editor's, or its file's)
    func prepare() { Task { await prepareNow() } }

    func prepareNow() async {
        guard let controller, let (board, project) = await controller.boardForEditing() else { return }
        layers = await engine.load(board, project: project)
        if !layers.contains(layer) { layer = layers.first ?? "F.Cu" }
        isReady = true
    }

    /// Once the changes made so far have gone to the board (a track stopped among them)
    func settled() async {
        await stopping?.value
        await applying?.value
    }

    /// The board changed elsewhere (in KiCad, or by the schematic's update): taken up anew, unless a track is being
    /// routed on it (which carries over onto the board as it then is)
    func boardChanged(_ board: KiCadBoard, project: [String: Any]?) {
        guard isReady, !isRouting else { return }
        Task { layers = await engine.load(board, project: project) }
    }

    /// The board's rules changed (its net classes): the router takes them
    func rulesChanged(_ project: [String: Any]) {
        guard isReady else { return }
        Task { layers = await engine.reload(project: project) }
    }

    func close() {
        engine.close()
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
        if tool == .route {
            selection = []
            if !isReady { prepare() }
            message = "Click a pad or track to start a track."
        } else if isRouting {
            stop()
        }
    }

    private func layerChanged() {
        // routing: a via to the new layer, placed at the next click (as KiCad's layer switch places one)
        guard isRouting, !isSettingLayer else { return }
        let to = layer
        Task { show(await engine.run { $0.placeVia(to: to) }) }
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
        guard isRouting else { return }
        pendingMove = p
        guard !moving else { return }
        moving = true
        Task {
            // only the latest place the pointer has got to is routed to
            while let next = pendingMove {
                pendingMove = nil
                let shown = await engine.run { $0.move(to: next) }
                if isRouting { preview = shown }
            }
            moving = false
        }
    }

    /// A click at `p`: a track started there, or the one being routed fixed there; `double`: finished there
    func click(at p: KiCadPoint, double: Bool = false) {
        guard tool == .route else { return }
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
        let shown = await engine.run { $0.move(to: p) }
        if isRouting { preview = shown }
    }

    /// A click at `p`, waited for
    func clickNow(at p: KiCadPoint, double: Bool = false) async {
        if !isRouting {
            guard !double else { return }
            let layer = self.layer, width = self.width
            await applying?.value
            if !isReady { await prepareNow() }
            let started = await engine.run { session -> (Bool, String, BoardEditing.Preview?)? in
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

    /// A via at the track's end, to the next layer (the other side, on two)
    func placeVia() {
        guard isRouting else { return }
        Task { show(await engine.run { $0.placeVia() }) }
    }

    func flipPosture() {
        guard isRouting else { return }
        Task { show(await engine.run { $0.flipPosture() }) }
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

    private func routingEnded() {
        isRouting = false
        preview = nil
        message = tool == .route ? "Click a pad or track to start a track." : nil
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

    /// A ground pour over the whole board on `layers`, filled by KiCad (`net`: the board's ground net if nil)
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
            await fillZonesNow()
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

    /// The board's zones filled anew by KiCad (B, as in KiCad)
    func fillZones() { Task { await fillZonesNow() } }

    func fillZonesNow() async {
        guard let controller, !isRouting else { return }
        await applying?.value
        if let (board, project) = await controller.fillZones() {
            layers = await engine.load(board, project: project)
        }
    }

    // MARK: - Placing

    /// A drag from `start` to `now` (mm) with the select tool: the footprint there (with the others selected, if it is
    /// one of them) following it, on a 0.05 mm grid
    func dragChanged(from start: KiCadPoint, to now: KiCadPoint, in picture: KiCadBoardPicture, selected: Set<String>) {
        guard tool == .select, !isRouting else { return }
        if dragging == nil {
            guard let footprint = picture.footprint(at: start) else { return }
            dragging = (selected.contains(footprint.uuid) ? Array(selected) : [footprint.uuid], .zero)
        }
        let grid = 0.05
        dragging?.delta = KiCadPoint(((now.x - start.x) / grid).rounded() * grid, ((now.y - start.y) / grid).rounded() * grid)
    }

    /// The drag let go: the footprints moved there
    func dragEnded() {
        guard let (uuids, delta) = dragging else { return }
        dragging = nil
        guard delta != .zero else { return }
        Task { await place { $0.moveFootprints(uuids, by: delta) } }
    }

    /// Footprints turned 90° counterclockwise (R)
    func rotate(_ uuids: Set<String>) {
        guard !uuids.isEmpty else { return }
        Task { await place { $0.rotateFootprints(uuids.sorted()) } }
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
            if undoName == "Fit Outline to Parts" { await fillZonesNow() }
        }
    }

    /// The board's outline made a rectangle `width` by `height` (mm), its corners rounded to `radius` (mm), and its
    /// pours filled again within it
    func setOutline(width: Double, height: Double, radius: Double) {
        Task {
            await place { $0.setOutline(width: width, height: height, radius: radius) }
            if undoName == "Change Board Outline" { await fillZonesNow() }
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
        guard !isRouting else { return false }
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
        undoStack.append(edit)
        redoStack = []
        updateNames()
        send(edit.after, from: edit.before, name: edit.name)
    }

    func undo() {
        guard !isRouting, let edit = undoStack.popLast() else { return }
        redoStack.append(edit)
        updateNames()
        send(edit.before, from: edit.after, name: "Undo " + edit.name)
    }

    func redo() {
        guard !isRouting, let edit = redoStack.popLast() else { return }
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
                layers = await engine.load(board.board, project: board.project)
            } else {
                // the board could not take it: back to the board as it was
                if let (board, project) = await controller.boardForEditing() { layers = await engine.load(board, project: project) }
                undoStack.removeAll { $0.after === after || $0.before === after }
                redoStack.removeAll { $0.after === after || $0.before === after }
                updateNames()
            }
        }
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
