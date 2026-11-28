// The footprint editor, as KiCad 10.0.8's (pcbnew/footprint_edit_frame.cpp, FOOTPRINT_EDIT_FRAME: its board holding one
// footprint, ReloadFootprint, updateEnabledLayers; pcbnew/footprint_editor_utils.cpp, LoadFootprintFromLibrary;
// pcbnew/load_select_footprint.cpp, LoadFootprintFromBoard and PCB_BASE_FRAME::loadFootprint; pcbnew/
// footprint_libraries_utils.cpp, SaveFootprint, SaveFootprintInLibrary, SaveFootprintAs, SaveFootprintToBoard and
// RevertFootprint; pcbnew/tools/pad_tool.cpp, PAD_TOOL::PlacePad and EnumeratePads, with pcbnew/collectors.cpp,
// GENERAL_COLLECTOR::Collect and Inspect of pads, pcbnew/pad.cpp, PAD::HitTest and CanHaveNumber, and pcbnew/
// footprint.cpp, FOOTPRINT::GetNextPadNumber, with common/string_utils.cpp, GetTrailingInt, and common/refdes_utils.cpp,
// GetRefDesPrefix; pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp, parsePAD, clearing the numbers of pads
// that can have none; pcbnew/pad.cpp, PAD's constructor (the master pad) and ImportSettingsFrom; the
// footprint's items moved, turned and taken away as pcbnew/pcb_shape.cpp, pad.cpp, pcb_text.cpp and zone.cpp's Move and
// Rotate move and turn them, and copied as pcbnew/tools/edit_tool.cpp's EDIT_TOOL::Duplicate and pcbnew/footprint.cpp's
// FOOTPRINT::DuplicateItem copy them). Copyright The KiCad Developers, see KiCad's AUTHORS.txt. GNU General Public
// License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// A footprint being edited, as KiCad's footprint editor edits one: on a board of its own (the editor's BOARD, its one
/// footprint at 0, 0, unturned, on the front), loaded from a library or from a board, its pads, drawings, texts and
/// properties edited (with the board editor's own dialogs' logic, BoardEditing's, where KiCad's footprint editor shares
/// it), checked (FootprintChecks), and saved into a library as KiCad writes it (FootprintFormat) or back onto its board
/// (FootprintExchange). Each change is kept for undo.
public final class FootprintEditor {
    /// The editor's board, which holds the footprint alone
    public private(set) var board: KiCadBoard
    /// The board footprint it was loaded from (FOOTPRINT::GetLink), nil for one from a library
    public private(set) var link: String?
    /// The ids its items had on that board, by the ids they were given here (m_boardFootprintUuids)
    public private(set) var boardUUIDs: [String: String] = [:]
    /// Its name when loaded (m_footprintNameWhenLoaded): saving under another name takes the old one out of its library
    public private(set) var nameWhenLoaded: String
    /// The footprint as loaded or last saved (m_originalFootprintCopy), which Revert goes back to
    public private(set) var original: SExpr
    /// The number the last pad placed or renumbered was given (PAD_TOOL's m_lastPadNumber)
    public var lastPadNumber = "1"
    /// The pads the last Renumber Pads run left renumbered (selected, as EnumeratePads leaves them while it runs),
    /// by id
    public private(set) var renumberedPads: [String] = []
    /// The pad new pads are made from (BOARD_DESIGN_SETTINGS::m_Pad_Master: a PAD as its constructor makes one, then
    /// each pad placed)
    public private(set) var masterPad: SExpr = FootprintEditor.defaultMasterPad()
    /// Whether it has changed since it was loaded or saved
    public private(set) var isModified = false
    private var undoStack: [(name: String, board: KiCadBoard)] = []
    private var redoStack: [(name: String, board: KiCadBoard)] = []

    /// The footprint itself
    public var footprint: SExpr { board.root.all("footprint")[0] }

    /// Its library and name, "Library:Name" (its FPID)
    public var libID: String { footprint.text(at: 0) ?? "" }

    /// Its name without its library's
    public var name: String { KiCadFootprintLibrary.split(libID)?.name ?? libID }

    /// Its library's name ("" for none)
    public var libraryName: String { KiCadFootprintLibrary.split(libID)?.library ?? "" }

    // MARK: - Loading

    /// The footprint editor's board holding `footprint`: F.Cu, the inner layers (In1.Cu, which stands for all of them:
    /// EXPAND_INNER_LAYERS) and B.Cu, and every technical and user layer (updateEnabledLayers)
    public static func holderBoard(_ footprint: SExpr) -> KiCadBoard {
        let layers: [(Int, String, String, String?)] = [
            (0, "F.Cu", "signal", nil), (4, "In1.Cu", "signal", "Inner layers"), (2, "B.Cu", "signal", nil),
            (9, "F.Adhes", "user", "F.Adhesive"), (11, "B.Adhes", "user", "B.Adhesive"), (13, "F.Paste", "user", nil),
            (15, "B.Paste", "user", nil), (5, "F.SilkS", "user", "F.Silkscreen"), (7, "B.SilkS", "user", "B.Silkscreen"),
            (1, "F.Mask", "user", nil), (3, "B.Mask", "user", nil), (17, "Dwgs.User", "user", "User.Drawings"),
            (19, "Cmts.User", "user", "User.Comments"), (21, "Eco1.User", "user", "User.Eco1"),
            (23, "Eco2.User", "user", "User.Eco2"), (25, "Edge.Cuts", "user", nil), (27, "Margin", "user", nil),
            (31, "F.CrtYd", "user", "F.Courtyard"), (29, "B.CrtYd", "user", "B.Courtyard"), (35, "F.Fab", "user", nil),
            (33, "B.Fab", "user", nil),
        ]
        let list = SExpr("layers", layers.map { id, name, kind, user -> SExprConvertible in
            var items: [SExprConvertible] = [id, name, Keyword(kind)]
            if let user { items.append(user) }
            return SExpr(list: items.map(\.sexpr))
        })
        let root = SExpr("kicad_pcb", SExpr("version", KiCadBoard.formatVersion), SExpr("generator", "pcbnew"),
                         SExpr("generator_version", "10.0"), SExpr("general", SExpr("thickness", 1.6), SExpr("legacy_teardrops", Keyword("no"))),
                         SExpr("paper", "A4"), list, SExpr("setup", SExpr("pad_to_mask_clearance", 0)), footprint)
        return KiCadBoard(root)
    }

    init(footprint: SExpr, link: String?, boardUUIDs: [String: String]) {
        board = Self.holderBoard(footprint)
        self.link = link
        self.boardUUIDs = boardUUIDs
        original = footprint.copy()
        nameWhenLoaded = KiCadFootprintLibrary.split(footprint.text(at: 0) ?? "")?.name ?? footprint.text(at: 0) ?? ""
    }

    /// The footprint `node` of library `libID` ("Library:Name") opened for editing, as LoadFootprintFromLibrary opens
    /// it: as loadFootprint loads it in the footprint editor (FootprintLoad keeping its ids, a copy whose mandatory
    /// fields have ids of their own, its items without ids given new ones, on no net), its empty reference or value
    /// made "Ref**" or "Val**"
    public convenience init(library node: SExpr, libID: String) {
        let fp = node.copy()
        fp.items[1] = SExpr(string: libID)
        for field in fp.all("property") where FootprintFormat.mandatory.contains(field.text(at: 0) ?? "") { field.remove("uuid") }
        let formatted = FootprintFormat.formatted(fp, library: false, sorted: false)
        Self.clearNets(formatted)
        Self.clearNumbers(formatted)
        let view = KiCadFootprint(formatted, board: KiCadBoard(SExpr(list: [SExpr(symbol: "kicad_pcb"), formatted])))
        if view.reference.isEmpty { view.reference = "Ref**" }
        if view.value.isEmpty { view.value = "Val**" }
        self.init(footprint: formatted, link: nil, boardUUIDs: [:])
    }

    /// The footprint of `board` of id `uuid` opened for editing, as LoadFootprintFromBoard opens it (Edit Footprint):
    /// a copy linked to it, unlocked (and its pads), every item given a new id (the board's kept to give back when it
    /// is saved to the board), on no net, put at 0, 0, onto the front (FLIP_DIRECTION::TOP_BOTTOM, the PCB editor's
    /// default) and turned to 0° (SetOrientation), its texts then kept upright; nil for no footprint of that id
    public convenience init?(board: KiCadBoard, footprint uuid: String) {
        guard let source = board.root.all("footprint").first(where: { $0.value("uuid") == uuid }) else { return nil }
        let fp = source.copy()
        BoardItems.unlock(fp)
        for pad in fp.all("pad") { BoardItems.unlock(pad) }
        var ids: [String: String] = [:]
        func renew(_ item: SExpr) {
            guard let old = item.value("uuid") else { return }
            let new = KiCadBoard.newUUID()
            ids[new] = old
            item.set(SExpr("uuid", new))
        }
        renew(fp)
        var renamed: [String: String] = [:]
        for item in fp.items where item.kind == .list && item["uuid"] != nil {
            let old = item.value("uuid") ?? ""
            renew(item)
            renamed[old] = item.value("uuid")
        }
        for group in fp.all("group") {
            guard let members = group["members"] else { continue }
            for i in 1..<members.items.count { members.items[i] = SExpr(string: renamed[members.items[i].text] ?? members.items[i].text) }
        }
        Self.clearNets(fp)
        Self.clearNumbers(fp)
        let view = KiCadFootprint(fp, board: KiCadBoard(SExpr(list: [SExpr(symbol: "kicad_pcb"), fp])))
        // (PlaceFootprint, then SetPosition( 0, 0 ))
        BoardItems.translate(fp, by: IPoint(0, 0) - BoardItems.position(fp))
        if view.layer != "F.Cu" { view.flip(leftRight: false) }
        if view.rotation != 0 {
            BoardItems.rotateFootprint(fp, about: IPoint(0, 0), degrees: -view.rotation, keepUpright: ["fp_text"])
        }
        self.init(footprint: fp, link: uuid, boardUUIDs: ids)
    }

    /// The numbers of its pads that can have none (PAD::CanHaveNumber: unplated holes, apertures) made none, as
    /// KiCad's parser (parsePAD) makes them as it reads a footprint, of a library or of a board
    static func clearNumbers(_ fp: SExpr) {
        for pad in fp.all("pad") where !canHaveNumber(pad) && pad.items.count > 1 && pad.items[1].text != "" {
            pad.items[1] = SExpr(string: "")
        }
    }

    /// FOOTPRINT::ClearAllNets: its pads', zones' and drawings' nets let go of
    static func clearNets(_ fp: SExpr) {
        for item in fp.items where item.head == "pad" || item.head == "zone" || BoardWorld.footprintShapeHeads.contains(item.head ?? "") {
            item.remove("net")
            item.remove("net_name")
        }
    }

    /// A PAD as its constructor makes it: plated through, round, 60 mils across, its hole 30 mils, on every copper
    /// layer and both masks (PTHMask)
    static func defaultMasterPad() -> SExpr {
        SExpr("pad", "", Keyword("thru_hole"), Keyword("circle"), SExpr("at", 0.0, 0.0), SExpr("size", 1.524, 1.524),
              SExpr("drill", 0.762), SExpr("layers", "*.Cu", "*.Mask"), SExpr("remove_unused_layers", Keyword("no")))
    }

    // MARK: - Changes

    /// A change made to the footprint by `body` (on its node), kept for undo where it changed anything
    @discardableResult
    func change(_ name: String, _ body: (SExpr) -> Void) -> Bool {
        let before = board.copy()
        body(footprint)
        guard board.text != before.text else { return false }
        undoStack.append((name, before))
        redoStack.removeAll()
        isModified = true
        return true
    }

    /// The board edited as a change of the PCB editor's own (a dialog's of BoardEditing), taken as one of ours
    @discardableResult
    func take(_ edit: BoardEditing.Edit?, _ name: String) -> Bool {
        guard let edit, let fp = edit.after.root.all("footprint").first else { return false }
        return change(name) { node in node.items = fp.copy().items }
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append((last.name, board.copy()))
        board = last.board
        isModified = true
    }

    public func redo() {
        guard let last = redoStack.popLast() else { return }
        undoStack.append((last.name, board.copy()))
        board = last.board
        isModified = true
    }

    /// RevertFootprint: back to the footprint as last loaded or saved
    public func revert() {
        board = Self.holderBoard(original.copy())
        undoStack.removeAll()
        redoStack.removeAll()
        isModified = false
    }

    /// The footprint's item of id `uuid` (a field, drawing, text, pad, zone, point or group)
    public func item(_ uuid: String) -> SExpr? {
        footprint.items.first { $0.kind == .list && $0.head != "uuid" && $0.value("uuid") == uuid }
    }

    /// The footprint's item at `p` (mm), within `slop` of it: a pad whose shape holds it (the smallest), else a
    /// drawing it is on (its pen's width and the slop about its lines, or inside it, filled), else a text or field
    /// whose place it is near; its id
    public func item(at p: KiCadPoint, slop: Double) -> String? {
        let view = KiCadFootprint(footprint, board: board)
        let pads = view.pads.filter { KiCadPolygon.contains($0.outline, p) }
        if let pad = pads.min(by: { BoardEditing.ringArea($0.outline) < BoardEditing.ringArea($1.outline) }) { return pad.uuid }
        for drawing in view.drawings.reversed() {
            let pts = drawing.points
            guard pts.count >= 2 else { continue }
            let closed = ["rect", "circle", "poly"].contains(drawing.kind)
            if closed && drawing.isFilled && KiCadPolygon.contains(pts, p) { return drawing.node.value("uuid") }
            let edges = zip(pts, pts.dropFirst() + (closed ? [pts[0]] : []))
            if edges.contains(where: { KiCadPolygon.distance(p, toSegment: $0.0, $0.1) <= drawing.width / 2 + slop }) {
                return drawing.node.value("uuid")
            }
        }
        for text in footprint.items.reversed() where text.head == "fp_text" || text.head == "property" {
            guard !(text.head == "property" && text.flag("hide")), let at = text["at"] else { continue }
            let size = text["effects"]?["font"]?["size"]?.number(at: 0) ?? 1
            let q = KiCadPoint(at.number(at: 0) ?? 0, at.number(at: 1) ?? 0)
            if q.distance(to: p) <= max(size, slop) { return text.value("uuid") }
        }
        return nil
    }

    /// The footprint's pads, each by its id: its number
    public var padNumbers: [String: String] {
        Dictionary(footprint.all("pad").compactMap { pad in pad.value("uuid").map { ($0, pad.text(at: 0) ?? "") } }, uniquingKeysWith: { a, _ in a })
    }

    /// FootprintChecks.run of the footprint, as the footprint checker runs them
    public func check() -> [FootprintChecks.Violation] { FootprintChecks.run(board) }

    // MARK: - Moving, turning, deleting

    /// The board-level head the port's BoardItems moves and turns a footprint's drawing by (the footprint at 0, 0 and
    /// unturned, its drawings' points are the board's)
    static let boardHeads = ["fp_line": "gr_line", "fp_rect": "gr_rect", "fp_circle": "gr_circle", "fp_arc": "gr_arc",
                             "fp_poly": "gr_poly", "fp_curve": "gr_curve"]

    /// The items moved by `delta` (mm), as EDIT_TOOL moves a footprint's items (each one's Move: a pad's, a text's and
    /// a field's place, a drawing's points, a zone's corners, a point's place)
    @discardableResult
    public func move(_ uuids: [String], by delta: KiCadPoint) -> Bool {
        let d = BoardEditing.nm(delta)
        return change("Move") { _ in
            for id in uuids { if let node = item(id) { Self.translate(node, by: d) } }
        }
    }

    static func translate(_ node: SExpr, by d: IPoint) {
        switch node.head ?? "" {
        case "pad", "property", "fp_text", "point":
            BoardItems.shift(node["at"], d)
        case "zone":
            BoardItems.shiftZone(node, d)
        case let head where boardHeads[head] != nil:
            node.items[0] = SExpr(symbol: boardHeads[head]!)
            BoardItems.translate(node, by: d)
            node.items[0] = SExpr(symbol: head)
        default:
            break
        }
    }

    /// The items turned about `center` (mm) by `degrees` counterclockwise, as each one's Rotate turns it (a pad's
    /// place and angle, PAD::Rotate; a text's place and angle, PCB_TEXT::Rotate, Normalize'd; a drawing's points, a
    /// rectangle turned off square made a polygon; a zone's corners)
    @discardableResult
    public func rotate(_ uuids: [String], about center: KiCadPoint, degrees: Double) -> Bool {
        let c = BoardEditing.nm(center)
        return change("Rotate") { _ in
            for id in uuids { if let node = item(id) { Self.rotate(node, about: c, degrees: degrees) } }
        }
    }

    static func rotate(_ node: SExpr, about c: IPoint, degrees: Double) {
        let angle = EDAAngle(degrees: degrees)
        switch node.head ?? "" {
        case "pad":
            guard let a = node["at"] else { return }
            BoardItems.turn(a, about: c, angle)
            let turned = BoardItems.normalize360((a.number(at: 2) ?? 0) + degrees)
            var values = Array(a.items.prefix(3))
            if turned != 0 { values.append(turned.sexpr) }
            a.items = values
        case "property", "fp_text":
            guard let a = node["at"] else { return }
            BoardItems.turn(a, about: c, angle)
            let turned = BoardItems.normalize360((a.number(at: 2) ?? 0) + degrees)
            a.items = Array(a.items.prefix(3)) + [turned.sexpr] + a.items.dropFirst(4)
        case "zone", "point":
            BoardItems.rotate(node, about: c, degrees: degrees, in: KiCadBoard(SExpr(list: [SExpr(symbol: "kicad_pcb")])))
        case let head where boardHeads[head] != nil:
            node.items[0] = SExpr(symbol: boardHeads[head]!)
            BoardItems.rotate(node, about: c, degrees: degrees, in: KiCadBoard(SExpr(list: [SExpr(symbol: "kicad_pcb")])))
            let now = node.head ?? ""
            node.items[0] = SExpr(symbol: boardHeads.first { $0.value == now }?.key ?? head)
        default:
            break
        }
    }

    /// The items taken out of the footprint (Delete), but for its reference and value, which every footprint keeps
    @discardableResult
    public func delete(_ uuids: [String]) -> Bool {
        change("Delete") { fp in
            let ids = Set(uuids)
            fp.items.removeAll { item in
                guard let id = item.value("uuid"), ids.contains(id), item.kind == .list else { return false }
                if item.head == "property", ["Reference", "Value"].contains(item.text(at: 0) ?? "") { return false }
                return item.head != "uuid"
            }
            // (BOARD_COMMIT::Push: an item taken away leaves its group)
            for group in fp.all("group") {
                group["members"]?.items.removeAll { $0.kind == .string && ids.contains($0.text) }
            }
        }
    }

    /// Copies of the items, moved by `delta` (mm), each a new id, put after the footprint's items of their kind
    /// (EDIT_TOOL::Duplicate's copies, FOOTPRINT::DuplicateItem: a pad's keeps its number); with `increment`
    /// (Duplicate and Increment), a pad's copy that can have a number given the footprint's next one after the last
    /// pad number (GetNextPadNumber); their ids
    @discardableResult
    public func duplicate(_ uuids: [String], by delta: KiCadPoint, increment: Bool = false) -> [String] {
        var made: [String] = []
        change("Duplicate") { fp in
            let d = BoardEditing.nm(delta)
            for id in uuids {
                guard let node = item(id), node.head != "property" else { continue }
                let copy = node.copy()
                let new = KiCadBoard.newUUID()
                copy.set(SExpr("uuid", new))
                if increment && copy.head == "pad" && Self.canHaveNumber(copy) {
                    let number = Self.nextPadNumber(fp, after: lastPadNumber)
                    copy.items[1] = SExpr(string: number)
                    lastPadNumber = number
                }
                Self.translate(copy, by: d)
                let i = fp.items.lastIndex { $0.head == copy.head } ?? fp.items.count - 1
                fp.items.insert(copy, at: i + 1)
                made.append(new)
            }
        }
        return made
    }

    // MARK: - Pads

    /// PAD::CanHaveNumber: a pad on copper that is not an unplated hole or an aperture
    static func canHaveNumber(_ pad: SExpr) -> Bool {
        let attribute = pad.text(at: 1) ?? ""
        guard attribute != "np_thru_hole" else { return false }
        let layers = pad["layers"]?.arguments.map(\.text) ?? []
        return layers.contains { $0.hasSuffix(".Cu") }
    }

    /// FOOTPRINT::GetNextPadNumber: `last`'s prefix (UTIL::GetRefDesPrefix) and the first number from its trailing
    /// one (GetTrailingInt) no pad of the footprint has
    public static func nextPadNumber(_ fp: SExpr, after last: String) -> String {
        let used = Set(fp.all("pad").compactMap { $0.text(at: 0) })
        let prefix = BoardClipboard.refDesPrefix(last)
        var number = trailingInt(last)
        while used.contains("\(prefix)\(number)") { number &+= 1 }
        return "\(prefix)\(number)"
    }

    /// GetTrailingInt: the number the text ends with (its code points from the last back while they are ASCII
    /// digits), 0 if none, in an int that wraps round as KiCad's does where the digits are too many for it
    static func trailingInt(_ text: String) -> Int32 {
        var number: Int32 = 0, base: Int32 = 1
        for ch in text.unicodeScalars.reversed() {
            guard ch.value >= 0x30 && ch.value <= 0x39 else { break }
            number &+= Int32(ch.value - 0x30) &* base
            base &*= 10
        }
        return number
    }

    /// A pad placed at `position` (mm), as PAD_TOOL::PlacePad places one: made from the master pad
    /// (PAD::ImportSettingsFrom), numbered the footprint's next number after the last one placed where it can have a
    /// number, put after the footprint's pads; the master pad then made from it; its id
    @discardableResult
    public func placePad(at position: KiCadPoint) -> String {
        let pad = masterPad.copy()
        if Self.canHaveNumber(pad) {
            let number = Self.nextPadNumber(footprint, after: lastPadNumber)
            pad.items[1] = SExpr(string: number)
            lastPadNumber = number
        } else {
            pad.items[1] = SExpr(string: "")
        }
        let p = BoardEditing.nm(position)
        var at: [SExprConvertible] = [BoardItems.mm(p.x), BoardItems.mm(p.y)]
        if let angle = masterPad["at"]?.number(at: 2), angle != 0 { at.append(angle) }
        pad.set(SExpr("at", at))
        let id = KiCadBoard.newUUID()
        pad.set(SExpr("uuid", id))
        change("Place pad") { fp in
            let i = fp.items.lastIndex { $0.head == "pad" } ?? fp.items.lastIndex { BoardItems.footprintDrawings[$0.head ?? ""] != nil || $0.head == "property" || $0.head == "attr" || $0.head == "duplicate_pad_numbers_are_jumpers" } ?? fp.items.count - 1
            fp.items.insert(pad, at: i + 1)
        }
        setMaster(from: pad)
        return id
    }

    /// The master pad made from `pad` (PlaceItem: m_Pad_Master->ImportSettingsFrom( *pad ); its number and id aside)
    public func setMaster(from pad: SExpr) {
        let master = pad.copy()
        master.items[1] = SExpr(string: "")
        master.remove("uuid")
        master.remove("net")
        masterPad = master
    }

    /// What the Renumber Pads tool is told of the pointer, as KiCad's TOOL_DISPATCHER tells it (each with where the
    /// pointer is then, nm): the pointer moved, the left button pressed, moved with it held (once past the drag
    /// threshold), let go after a drag, or clicked (pressed and let go without a drag)
    public enum PadEnumerationEvent: Hashable, Sendable {
        case motion(IPoint), down(IPoint), drag(IPoint), up(IPoint), click(IPoint)

        var position: IPoint {
            switch self {
            case .motion(let p), .down(let p), .drag(let p), .up(let p), .click(let p): return p
            }
        }
    }

    /// The pads under a point as the Renumber Pads tool's GENERAL_COLLECTOR collects them (Collect of PCB_PAD_T with
    /// the frame's guide, whose accuracy is five pixels): each pad PAD::HitTest finds at `p` within `accuracy`, those
    /// on the active layer first, then the others, each in the order the footprint holds them; their indexes
    public func padsHit(at p: IPoint, accuracy: Int, activeLayer: String) -> [Int] {
        padHitTester(accuracy: accuracy, activeLayer: activeLayer)(p)
    }

    /// padsHit, the pads' shapes made once
    func padHitTester(accuracy: Int, activeLayer: String) -> (IPoint) -> [Int] {
        let drc = BoardDRC(board: board)
        let nodes = footprint.all("pad")
        let pads = drc.footprints.first?.pads ?? []
        let world = drc.world
        let radii = pads.map { Teardrops.boundingRadius($0, world) }
        let polygons = pads.map { world.padPolygon($0.pad, primitives: $0.primitives, errorLocation: .inside) ?? PolySet() }
        let onLayer = nodes.map { Self.padIsOnLayer($0, activeLayer) }
        return { p in
            var primary: [Int] = [], secondary: [Int] = []
            for i in pads.indices where Teardrops.padHitTest(pads[i], p, accuracy, nil, world, boundingRadius: radii[i], polygon: { polygons[i] }) {
                if onLayer[i] { primary.append(i) } else { secondary.append(i) }
            }
            return primary + secondary
        }
    }

    /// PAD::IsOnLayer: its layer set (its file's names, *.Cu every copper layer, *.Mask both masks and the like) holds
    /// `layer`
    static func padIsOnLayer(_ pad: SExpr, _ layer: String) -> Bool {
        for name in pad["layers"]?.arguments.map(\.text) ?? [] {
            if name == layer { return true }
            if name == "F&B.Cu" && (layer == "F.Cu" || layer == "B.Cu") { return true }
            if name == "*.Cu" && layer.hasSuffix(".Cu") { return true }
            if name == "*In.Cu" && layer.hasPrefix("In") && layer.hasSuffix(".Cu") { return true }
            if name.hasPrefix("*."), name != "*.Cu", layer == "F" + name.dropFirst() || layer == "B" + name.dropFirst() { return true }
        }
        return false
    }

    /// The footprint's pads renumbered as PAD_TOOL::EnumeratePads renumbers them, the pointer doing what `events` say,
    /// DIALOG_ENUM_PADS' prefix, start and step given (KiCad's dialog takes 0 to 999 for each), as one change: at each
    /// click or drag, the pads under the points every 0.1 mm along the way from where the pointer was at the event
    /// before back to where it is (padsHit, from where it is now), but those that can have no number
    /// (CanHaveNumber), a pad met twice in a row once; each of them not yet renumbered in the run given the prefix and
    /// the next number (one given back first, then from the start by the step), and each renumbered already, where the
    /// event is a click, given back the number it had (the number it was given then the next given back). Each number
    /// given or given back is the last pad number (PAD_TOOL's, which pads placed next go on from). False if nothing
    /// changed
    @discardableResult
    public func enumeratePads(_ events: [PadEnumerationEvent], start: Int = 1, step: Int = 1, prefix: String = "",
                              accuracy: Int, activeLayer: String = "F.SilkS") -> Bool {
        guard !footprint.all("pad").isEmpty else { return false }
        let hit = padHitTester(accuracy: accuracy, activeLayer: activeLayer)
        return change("Renumber Pads") { fp in
            let pads = fp.all("pad")
            var next = start
            var stored: [Int] = []
            var old: [String: (Int, String)] = [:]
            var selected = Set<Int>()
            var oldMousePos = IPoint.zero
            var isFirstPoint = true
            for event in events {
                let mousePos = event.position
                defer { oldMousePos = mousePos }
                let isClick: Bool
                switch event {
                case .click: isClick = true
                case .drag: isClick = false
                default: continue
                }
                if isFirstPoint {
                    oldMousePos = mousePos
                    isFirstPoint = false
                }
                // (a line of test points 0.1 mm apart back to where the pointer was: the distance an int, the step
                // VECTOR2I / int, rounded)
                let distance = (mousePos - oldMousePos).norm
                let segments = distance / 100_000 + 1
                let lineStep = (mousePos - oldMousePos).divided(by: Double(segments))
                var collected: [Int] = []
                for j in 0..<segments {
                    let testPoint = IPoint(mousePos.x - j * lineStep.x, mousePos.y - j * lineStep.y)
                    for i in hit(testPoint) where Self.canHaveNumber(pads[i]) { collected.append(i) }
                }
                // (std::list::unique: those met twice in a row once)
                var unique: [Int] = []
                for i in collected where unique.last != i { unique.append(i) }
                for i in unique {
                    let pad = pads[i]
                    if !selected.contains(i) {
                        let value: Int
                        if !stored.isEmpty { value = stored.removeFirst() } else { value = next; next += step }
                        let number = "\(prefix)\(value)"
                        old[number] = (value, pad.text(at: 0) ?? "")
                        pad.items[1] = SExpr(string: number)
                        lastPadNumber = number
                        selected.insert(i)
                    } else if isClick {
                        if let (value, was) = old[pad.text(at: 0) ?? ""] {
                            old[pad.text(at: 0) ?? ""] = nil
                            stored.append(value)
                            pad.items[1] = SExpr(string: was)
                            lastPadNumber = was
                        }
                        selected.remove(i)
                    }
                }
            }
            renumberedPads = selected.sorted().map { pads[$0].value("uuid") ?? "" }
        }
    }

    // MARK: - Drawing

    /// The pens and texts new graphics and texts take (FOOTPRINT_EDITOR_SETTINGS' design settings: KiCad's own)
    public var lineWidths: LineWidths { LineWidths() }
    public var textDefaults: TextDefaults { TextDefaults(project: nil) }

    /// A graphic drawn (a GraphicTool's) put in the footprint, as DRAWING_TOOL adds one in the footprint editor (a
    /// PCB_SHAPE of the footprint's); its id
    @discardableResult
    public func addShape(_ shape: BoardShape) -> String {
        let id = KiCadBoard.newUUID()
        let head = Self.boardHeads.first { $0.value == BoardShape.heads[shape.kind] }!.key
        let node = SExpr(head, SExpr("layer", shape.layer), SExpr("uuid", id))
        shape.write(into: node)
        change(BoardEditing.drawName(shape)) { fp in
            let i = fp.items.lastIndex { BoardItems.footprintDrawings[$0.head ?? ""] != nil } ?? fp.items.lastIndex { $0.head == "property" || $0.head == "attr" || $0.head == "duplicate_pad_numbers_are_jumpers" } ?? 1
            fp.items.insert(node, at: i + 1)
        }
        return id
    }

    /// A text of the footprint's (PCB_TEXT) placed at `position` (mm) on `layer`, in the style the editor's settings
    /// give texts on that layer (mirrored on the back, kept upright as KiCad's default text is), as DRAWING_TOOL::
    /// PlaceText puts one in a footprint; its id
    @discardableResult
    public func addText(_ text: String, at position: KiCadPoint, layer: String, angle: Double = 0) -> String {
        let style = textDefaults.style(layer)
        let id = KiCadBoard.newUUID()
        let p = BoardEditing.nm(position)
        var font: [SExprConvertible] = [SExpr("size", style.height, style.width), SExpr("thickness", style.thickness)]
        if style.bold { font.append(SExpr("bold", Keyword("yes"))) }
        if style.italic { font.append(SExpr("italic", Keyword("yes"))) }
        var effects: [SExprConvertible] = [SExpr("font", font)]
        if style.mirrored { effects.append(SExpr("justify", Keyword("mirror"))) }
        var items: [SExprConvertible] = [Keyword("user"), text, SExpr("at", BoardItems.mm(p.x), BoardItems.mm(p.y), angle)]
        if !style.upright { items.append(SExpr("unlocked", Keyword("yes"))) }
        items += [SExpr("layer", layer), SExpr("uuid", id), SExpr("effects", effects)]
        let node = SExpr("fp_text", items)
        change("Place Text") { fp in
            let i = fp.items.lastIndex { BoardItems.footprintDrawings[$0.head ?? ""] != nil } ?? fp.items.lastIndex { $0.head == "property" } ?? 1
            fp.items.insert(node, at: i + 1)
        }
        return id
    }

    // MARK: - Properties

    /// A session of the board editor's own on the editor's board, for the dialogs the footprint editor shares with it
    var session: BoardEditing { BoardEditing(board: board) }

    /// A pad's properties, as the pad properties dialog shows them (BoardEditing.padProperties)
    public func padProperties(_ uuid: String) -> PadProperties? { session.padProperties(uuid) }

    /// A pad's properties set as the pad properties dialog sets them (BoardEditing.setPadProperties)
    @discardableResult
    public func setPadProperties(_ uuid: String, _ p: PadProperties) -> Bool {
        take(session.setPadProperties(uuid, p), "Edit Pad Properties")
    }

    /// The footprint's properties as its properties dialog shows them (BoardEditing.footprintProperties)
    public var footprintProperties: FootprintProperties? { session.footprintProperties(footprint.value("uuid") ?? "") }

    /// The footprint's properties set as its properties dialog sets them (fields, attributes, clearances)
    @discardableResult
    public func setFootprintProperties(_ p: FootprintProperties) -> Bool {
        take(session.setFootprintProperties(footprint.value("uuid") ?? "", p), "Edit Footprint Properties")
    }

    /// What only the footprint editor's properties dialog sets (DIALOG_FOOTPRINT_PROPERTIES_FP_EDITOR): its name, its
    /// description and keywords, written as format( FOOTPRINT ) writes them (left out empty)
    @discardableResult
    public func setLibraryProperties(name: String? = nil, description: String, keywords: String) -> Bool {
        change("Edit Footprint Properties") { fp in
            if let name, !name.isEmpty {
                let lib = libraryName
                fp.items[1] = SExpr(string: lib.isEmpty ? name : "\(lib):\(name)")
            }
            for (head, text) in [("descr", description), ("tags", keywords)] {
                fp.remove(head)
                guard !text.isEmpty else { continue }
                fp.insert(SExpr(head, text), after: ["descr", "at", "uuid", "layer"])
            }
        }
    }

    /// The footprint's net tie pad groups (each a list of pad numbers, ", " between them: FOOTPRINT's
    /// m_netTiePadGroups as the dialog's grid gives them)
    @discardableResult
    public func setNetTiePadGroups(_ groups: [String]) -> Bool {
        change("Edit Footprint Properties") { fp in
            fp.remove("net_tie_pad_groups")
            let kept = groups.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !kept.isEmpty else { return }
            let node = SExpr("net_tie_pad_groups", kept.map { $0 as SExprConvertible })
            fp.insert(node, after: Array(FootprintFormat.headerOrder.prefix { $0 != "net_tie_pad_groups" }) + ["property"])
        }
    }

    // MARK: - Saving

    /// The footprint as FootprintSave writes it into a library (FootprintFormat.libraryText), under `name`
    public func libraryText() -> String {
        let fp = footprint.copy()
        fp.items[1] = SExpr(string: name)
        return FootprintFormat.libraryText(fp)
    }

    public enum SaveError: Error, CustomStringConvertible {
        case noLibrary(String)
        case readOnly(String)
        case noName
        case noBoardFootprint

        public var description: String {
            switch self {
            case .noLibrary(let lib): return "No footprint library \"\(lib)\" is in the library tables."
            case .readOnly(let lib): return "Library '\(lib)' is read only."
            case .noName: return "Footprint must have a name."
            case .noBoardFootprint: return "Unable to find the footprint on the main board.\nCannot save."
            }
        }
    }

    /// The file a footprint of `name` is saved in, in a library's folder (FootprintSave: ReplaceIllegalFileNameChars,
    /// '_' for each)
    public static func fileURL(_ name: String, in folder: URL) -> URL {
        let illegal = Set("\\/:\"<>|*?")
        let file = String(name.map { illegal.contains($0) || $0.asciiValue.map { $0 < 32 } == true ? "_" : $0 })
        return folder.appendingPathComponent(file + ".kicad_mod")
    }

    /// SaveFootprintInLibrary: the footprint saved into the library `library` of `libraries` as FootprintSave saves it
    /// (the library's folder made if it is not there: FP_CACHE::Save), written atomically
    func saveInLibrary(_ library: String, _ libraries: KiCadFootprintLibrary) throws {
        guard let lib = libraries.libraries[library] else { throw SaveError.noLibrary(library) }
        let fm = FileManager.default
        if !fm.fileExists(atPath: lib.folder.path) { try fm.createDirectory(at: lib.folder, withIntermediateDirectories: true) }
        guard fm.isWritableFile(atPath: lib.folder.path) else { throw SaveError.readOnly(library) }
        try libraryText().write(to: Self.fileURL(name, in: lib.folder), atomically: true, encoding: .utf8)
        libraries.forget(library: library)
    }

    /// FOOTPRINT_EDIT_FRAME::SaveFootprint: a footprint from a board saved back onto it (use `saveToBoard`); else into
    /// its library, the footprint of the name it was loaded under taken out of the library where it was renamed
    public func save(in libraries: KiCadFootprintLibrary) throws {
        guard link == nil else { throw SaveError.noBoardFootprint }
        guard !libraryName.isEmpty, !name.isEmpty else { throw SaveError.noName }
        try saveInLibrary(libraryName, libraries)
        if nameWhenLoaded != name, let lib = libraries.libraries[libraryName] {
            try? FileManager.default.removeItem(at: Self.fileURL(nameWhenLoaded, in: lib.folder))
        }
        nameWhenLoaded = name
        original = footprint.copy()
        isModified = false
    }

    /// FOOTPRINT_EDIT_FRAME::SaveFootprintAs: the footprint named `name` in library `library` (its value too where it
    /// was its old name) and saved there; no longer a board's footprint once saved so
    public func saveAs(library: String, name newName: String, in libraries: KiCadFootprintLibrary) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !library.isEmpty else { throw SaveError.noLibrary(library) }
        guard !trimmed.isEmpty else { throw SaveError.noName }
        guard libraries.libraries[library] != nil else { throw SaveError.noLibrary(library) }
        rename(trimmed, library: library)
        try saveInLibrary(library, libraries)
        link = nil
        boardUUIDs = [:]
        nameWhenLoaded = trimmed
        original = footprint.copy()
        isModified = false
    }

    /// What SaveFootprintAs does to the footprint before saving it: named `newName` of library `library`, its value
    /// too where it was its old name
    public func rename(_ newName: String, library: String) {
        let updateValue = KiCadFootprint(footprint, board: board).value == name
        change("Save As") { fp in
            fp.items[1] = SExpr(string: library.isEmpty ? newName : "\(library):\(newName)")
            if updateValue { KiCadFootprint(fp, board: board).value = newName }
        }
    }

    /// FOOTPRINT_EDIT_FRAME::SaveFootprintToBoard: the board's footprint this one was loaded from exchanged for it
    /// (PCB_EDIT_FRAME::ExchangeFootprint, every reset on: FootprintExchange), its items given back the ids they had on
    /// the board (new ones for those that are new); a copy of `target` as it then is, nil where the footprint is not
    /// on it
    public func saveToBoard(_ target: KiCadBoard, flipLeftRight: Bool = false) -> KiCadBoard? {
        let out = target.copy()
        return exchange(onto: out, flipLeftRight: flipLeftRight) ? out : nil
    }

    /// SaveFootprintToBoard on `target` itself: whether its footprint was there to exchange
    @discardableResult
    public func exchange(onto target: KiCadBoard, flipLeftRight: Bool = false) -> Bool {
        guard let link, let existing = target.root.all("footprint").first(where: { $0.value("uuid") == link }) else { return false }
        let fp = footprint.copy()
        func fix(_ item: SExpr) {
            guard let id = item.value("uuid") else { return }
            item.set(SExpr("uuid", boardUUIDs[id] ?? KiCadBoard.newUUID()))
        }
        fix(fp)
        var renamed: [String: String] = [:]
        for item in fp.items where item.kind == .list && item["uuid"] != nil {
            let old = item.value("uuid") ?? ""
            fix(item)
            renamed[old] = item.value("uuid")
        }
        for group in fp.all("group") {
            guard let members = group["members"] else { continue }
            for i in 1..<members.items.count { members.items[i] = SExpr(string: renamed[members.items[i].text] ?? members.items[i].text) }
        }
        FootprintExchange.exchange(existing, for: fp, on: target, options: .init(), flipLeftRight: flipLeftRight)
        original = footprint.copy()
        isModified = false
        return true
    }
}

extension BoardEditing {
    /// The board's footprint `editor` was loaded from exchanged for the editor's (its Save: Update Footprint on
    /// Board, FOOTPRINT_EDIT_FRAME::SaveFootprintToBoard), as one change ("Update Footprint"); nil where it is no
    /// longer on the board
    public func updateFootprint(from editor: FootprintEditor) -> Edit? {
        guard !isRouting, let uuid = editor.link, editor.exchange(onto: router.board) else { return nil }
        router.boardChanged()
        return change("Update Footprint", footprints: [uuid])
    }

    /// The board's footprints `uuids` (all of them, nil) updated from their libraries as Update Footprints from
    /// Library updates them (FootprintExchange.updateFromLibrary), as one change ("Update Footprint"), and what its
    /// dialog would report
    public func updateFootprintsFromLibrary(_ library: KiCadFootprintSource, options: FootprintExchange.Options = .updateDialog,
                                            uuids: Set<String>? = nil) -> (edit: Edit?, report: FootprintExchange.Report) {
        guard !isRouting else { return (nil, FootprintExchange.Report()) }
        let report = FootprintExchange.updateFromLibrary(router.board, library: library, options: options) { fp in
            uuids?.contains(fp.uuid) ?? true
        }
        router.boardChanged()
        let changed = router.board.footprints.map(\.uuid).filter { uuids?.contains($0) ?? true }
        return (change("Update Footprint", footprints: changed), report)
    }
}
