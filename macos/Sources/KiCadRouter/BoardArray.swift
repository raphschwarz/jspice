// Create Array, as KiCad's PCB editor makes one (KiCad 10.0.8: pcbnew/tools/array_tool.cpp, ARRAY_TOOL::CreateArray and
// onDialogClosed, TransformItem; common/array_options.cpp, ARRAY_GRID_OPTIONS and ARRAY_CIRCULAR_OPTIONS' GetTransform,
// getGridCoords and gtItemPosRelativeToItem0; pcbnew/dialogs/dialog_create_array.cpp, what the dialog's fields make
// of the options; pcbnew/tools/board_reannotate_tool.cpp, ReannotateDuplicates; include/math/vector2d.h, VECTOR2's
// arithmetic, to the nanometre; the items' SetPosition and GetPosition, pcbnew/pcb_track.h, zone.h, pcb_generator.h,
// pcb_group.cpp and common/eda_shape.cpp). GNU General Public License version 3 or later, as KiCad (see
// KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// What KiCad's Create Array dialog asks for: a grid or a circle of copies, whether the selection itself is arranged in
/// it instead, and whether the copies' footprints keep their references or get references of their own
public struct ArrayOptions: Sendable, Equatable {
    /// ARRAY_GRID_OPTIONS: `columns` by `rows` (the dialog's horizontal and vertical counts), `spacing` apart (mm),
    /// each row `offset` on from the last (and each column, across), every `stagger` rows (or columns) shifted on by a
    /// stagger's part of the spacing (back if negative), the whole centred on the selection or starting from it
    public struct Grid: Sendable, Equatable {
        public var columns: Int, rows: Int
        public var spacing: KiCadPoint
        public var offset = KiCadPoint.zero
        public var stagger = 1
        public var staggerRows = true
        public var centred = false
        /// The order the copies are made in: along the rows first (KiCad's horizontal, then vertical), or the columns
        public var horizontalThenVertical = true
        public var reverseAlternate = false

        public init(columns: Int, rows: Int, spacing: KiCadPoint, offset: KiCadPoint = .zero, stagger: Int = 1, staggerRows: Bool = true,
                    centred: Bool = false) {
            (self.columns, self.rows, self.spacing, self.offset) = (columns, rows, spacing, offset)
            (self.stagger, self.staggerRows, self.centred) = (stagger, staggerRows, centred)
        }
    }

    /// ARRAY_CIRCULAR_OPTIONS: `count` copies round `centre` (mm), `angle` degrees apart (0: a full circle's even
    /// share), the first `angleOffset` round, clockwise or not, each turned with its place or not
    public struct Circular: Sendable, Equatable {
        public var centre: KiCadPoint
        public var count: Int
        public var angle: Double
        public var angleOffset = 0.0
        public var clockwise = true
        public var rotateItems = false

        public init(centre: KiCadPoint, count: Int, angle: Double, angleOffset: Double = 0, clockwise: Bool = true,
                    rotateItems: Bool = false) {
            (self.centre, self.count, self.angle) = (centre, count, angle)
            (self.angleOffset, self.clockwise, self.rotateItems) = (angleOffset, clockwise, rotateItems)
        }
    }

    public enum Layout: Sendable, Equatable {
        case grid(Grid), circular(Circular)
    }

    public var layout: Layout
    /// The selection itself moved into the array's places (KiCad's Arrange selection) rather than copied
    public var arrange = false
    /// The copies' footprints given references of their own (Assign unique reference designators, KiCad's default)
    public var uniqueReferences = true

    public init(_ layout: Layout, arrange: Bool = false, uniqueReferences: Bool = true) {
        (self.layout, self.arrange, self.uniqueReferences) = (layout, arrange, uniqueReferences)
    }

    /// How many places the array has (GetArraySize)
    public var size: Int {
        switch layout {
        case .grid(let g): return g.columns * g.rows
        case .circular(let c): return c.count
        }
    }

    /// What the `n`th place does to an item at `position` (GetTransform): its move (nm) and its turn (degrees)
    func transform(_ n: Int, _ position: IPoint) -> (offset: IPoint, rotation: Double) {
        switch layout {
        case .grid(let g):
            let delta = IPoint(BoardWorld.iu(g.spacing.x), BoardWorld.iu(g.spacing.y))
            let off = IPoint(BoardWorld.iu(g.offset.x), BoardWorld.iu(g.offset.y))
            // (getGridCoords)
            let axis = g.horizontalThenVertical ? g.columns : g.rows
            var x = n % axis
            let y = n / axis
            if g.reverseAlternate && y % 2 == 1 { x = axis - x - 1 }
            var coords = IPoint(x, y)
            if !g.horizontalThenVertical { coords = IPoint(coords.y, coords.x) }
            var point = IPoint(coords.x * delta.x + coords.y * off.x, coords.y * delta.y + coords.x * off.y)
            if abs(g.stagger) > 1 {
                let stagger = abs(g.stagger)
                let index = (g.staggerRows ? coords.y : coords.x) % stagger
                let staggerDelta = IPoint(g.staggerRows ? delta.x : off.x, g.staggerRows ? off.y : delta.y)
                // (VECTOR2I * double / int: in doubles, cut toward zero as VECTOR2I takes them)
                let k = Double(g.stagger < 0 ? -index : index)
                point = point + IPoint(Int(Double(staggerDelta.x) * k / Double(stagger)), Int(Double(staggerDelta.y) * k / Double(stagger)))
            }
            if g.centred {
                let extentX = (g.columns - 1) * delta.x + (g.rows - 1) * off.x
                let extentY = (g.rows - 1) * delta.y + (g.columns - 1) * off.y
                point = point - IPoint(KiMath.round(Double(extentX) / 2), KiMath.round(Double(extentY) / 2))
            }
            return (point, 0)
        case .circular(let c):
            var angle = c.angle == 0 ? 360.0 * Double(n) / Double(c.count) : c.angle * Double(n)
            angle += c.angleOffset
            if c.clockwise { angle = -angle }
            let centre = IPoint(BoardWorld.iu(c.centre.x), BoardWorld.iu(c.centre.y))
            let moved = KiMath.rotate(position, around: centre, EDAAngle(degrees: angle))
            return (moved - position, c.rotateItems ? angle : 0)
        }
    }
}

extension BoardEditing {
    /// KiCad's Create Array on the items `uuids` (in the order they were selected), as one change ("Create Array",
    /// or "Arrange selection"): copies of them (as Duplicate makes them) in each place of the array but the last,
    /// and the items themselves moved to its last (ARRAY_TOOL goes through the places backwards, the items last); each
    /// place's footprints, from the second place on, given references the board and the places before do not have if
    /// asked. Arranging, each item in turn taken to the next place, from the first item's position. Nil where a
    /// circle turns an item the port does not turn as KiCad does (BoardItems.rotatable).
    public func createArray(_ uuids: [String], options: ArrayOptions) -> Edit? {
        guard !isRouting, options.size > 0 else { return nil }
        let board = router.board
        let selection = uuids.compactMap { BoardItems.item(board, $0) }
        guard !selection.isEmpty else { return nil }
        if case .circular(let c) = options.layout, c.rotateItems,
           !(selection + selection.flatMap { BoardItems.descendants($0, in: board) }).allSatisfy(BoardItems.rotatable) {
            return nil
        }
        let size = options.size
        func members(_ g: SExpr, among pool: [SExpr]) -> [SExpr] {
            var out: [SExpr] = [], seen = Set<String>()
            func visit(_ n: SExpr) {
                for id in BoardItems.members(n) where seen.insert(id).inserted {
                    guard let m = pool.first(where: { $0.value("uuid") == id }) ?? BoardItems.item(board, id) else { continue }
                    out.append(m)
                    if m.head == "group" || m.head == "generated" { visit(m) }
                }
            }
            visit(g)
            return out
        }
        /// The originals of the copies made, by the copies' ids
        var copyOf: [String: String] = [:]
        let footprintBoxes = Dictionary(BoxSelection(board: board, project: project).footprints.map { ($0.uuid, $0.box) },
                                        uniquingKeysWith: { a, _ in a })
        /// Where KiCad has an item (GetPosition): a group's the centre of its members' boxes (PCB_GROUP::GetPosition,
        /// its bounding box's centre; a footprint member's box the port's, without its texts)
        func position(_ item: SExpr, _ group: [SExpr]) -> IPoint {
            guard item.head == "group" else { return BoardItems.position(item) }
            var box: IBox?
            for m in group where m.head != "group" && m.head != "generated" {
                let key = m.head == "footprint" ? (copyOf[m.value("uuid") ?? ""] ?? "") : ""
                var boxes = footprintBoxes
                if !key.isEmpty, let b = footprintBoxes[key] {
                    let shift = BoardWorld.point(m["at"]) - BoardWorld.point(BoardItems.item(board, key)?["at"])
                    boxes[m.value("uuid") ?? ""] = IBox(minX: b.minX + shift.x, minY: b.minY + shift.y,
                                                        maxX: b.maxX + shift.x, maxY: b.maxY + shift.y)
                }
                guard let b = BoardItems.boundingBox(m, footprintBoxes: boxes, board: board) else { continue }
                if box == nil { box = b } else { box!.merge(b) }
            }
            return box?.center ?? .zero
        }
        /// TransformItem: moved by the place's offset, then turned about where it then is
        func transform(_ item: SExpr, _ n: Int, pool: [SExpr]) {
            let group = item.head == "group" || item.head == "generated" ? members(item, among: pool) : []
            let (offset, rotation) = options.transform(n, position(item, group))
            BoardItems.translate(item, by: offset)
            for m in group where m.head != "group" && m.head != "generated" { BoardItems.translate(m, by: offset) }
            for m in group where m.head == "generated" { BoardItems.translate(m, by: offset) }
            if rotation != 0 {
                let about = position(item, group)
                if group.isEmpty {
                    BoardItems.rotate(item, about: about, degrees: rotation, in: board)
                } else {
                    let angle = EDAAngle(degrees: rotation)
                    for m in group where m.head != "group" && m.head != "generated" {
                        BoardItems.rotate(m, about: about, degrees: rotation, in: board)
                    }
                    for g in [item] + group where g.head == "generated" {
                        BoardItems.turn(g["origin"]?["xy"], about: about, angle)
                        BoardItems.turn(g["end"]?["xy"], about: about, angle)
                        BoardItems.turnPoints(g["base_line"]?["pts"], about: about, angle)
                        BoardItems.turnPoints(g["base_line_coupled"]?["pts"], about: about, angle)
                    }
                }
            }
        }
        if options.arrange {
            var first: SExpr?
            func grouped(_ n: SExpr) -> [SExpr] { n.head == "group" || n.head == "generated" ? members(n, among: []) : [] }
            for (index, item) in selection.prefix(size).enumerated() {
                if let first {
                    // (a group put there with its members, from where its box's centre is)
                    let p = position(first, grouped(first))
                    if item.head == "group" {
                        BoardItems.translateWithMembers(item, by: p - position(item, grouped(item)), in: board)
                    } else {
                        BoardItems.setPosition(item, p, in: board)
                    }
                } else {
                    first = item
                }
                transform(item, index, pool: [])
            }
            let nets = propagateNets()
            router.boardChanged()
            let arranged = selection.prefix(size)
            func ids(_ heads: Set<String>, _ among: Bool) -> [String] {
                arranged.filter { heads.contains($0.head ?? "") == among }.compactMap { $0.value("uuid") }
            }
            return change("Arrange selection", footprints: ids(["footprint"], true), zones: ids(["zone"], true),
                          changed: ids(["segment", "arc", "via"], true) + nets.copper,
                          drawings: ids(["footprint", "zone", "segment", "arc", "via", "generated"], false) + nets.drawings)
        }
        var made: [SExpr] = []
        var added: [SExpr] = []
        var joins: [(group: SExpr, member: String)] = []
        for place in stride(from: size - 1, through: 0, by: -1) {
            var block: [SExpr] = []
            for item in selection {
                if place == 0 {
                    // (the item itself, to the last place)
                    transform(item, size - 1, pool: [])
                    block.append(item)
                    continue
                }
                var ids: [String: String] = [:]
                let copies: [SExpr]
                if item.head == "group" || item.head == "generated" {
                    copies = ([item] + BoardItems.descendants(item, in: board)).map { $0.copy() }
                    for c in copies { BoardItems.renew(c, &ids) }
                    for c in copies where c.head == "group" || c.head == "generated" { BoardItems.remapMembers(c, ids) }
                } else {
                    copies = [item.copy()]
                    BoardItems.renew(copies[0], &ids)
                }
                for (old, new) in ids { copyOf[new] = old }
                if let id = item.value("uuid"), let group = BoardItems.parentGroup(board, id), let new = ids[id] { joins.append((group, new)) }
                transform(copies[0], size - place - 1, pool: copies)
                made += copies
                block.append(copies[0])
            }
            if options.uniqueReferences && place != size - 1 {
                BoardClipboard.reannotateDuplicates(block, existing: board.root.all("footprint") + added, board: board) { g in
                    members(g, among: made)
                }
            }
            added += block
        }
        for (group, member) in joins {
            guard let list = group["members"] else { continue }
            let now = (BoardItems.members(group) + [member]).sorted()
            list.items = [list.items[0]] + now.map { SExpr(string: $0) }
        }
        guard var edit = place(made, "Create Array") else { return nil }
        // (the items themselves moved too)
        edit.footprints += selection.filter { $0.head == "footprint" }.compactMap { $0.value("uuid") }
        return edit
    }
}

extension BoardItems {
    /// The item put at `p` as KiCad's SetPosition puts it: a footprint, via, text or shape moved there whole (a group
    /// is left to its caller, which has its box's centre); a track's start alone moved there (PCB_TRACK::SetPosition,
    /// PCB_ARC's too), a tuning pattern's origin alone (PCB_GENERATOR::SetPosition); a zone not at all
    /// (ZONE::SetPosition does nothing)
    static func setPosition(_ node: SExpr, _ p: IPoint, in board: KiCadBoard) {
        switch node.head ?? "" {
        case "segment", "arc":
            guard let s = node["start"] else { return }
            s.items[1] = mm(p.x).sexpr
            s.items[2] = mm(p.y).sexpr
        case "via":
            shift(node["at"], p - BoardWorld.point(node["at"]))
        case "zone":
            return
        case "generated":
            shift(node["origin"]?["xy"], p - position(node))
        default:
            translate(node, by: p - position(node))
        }
    }
}
