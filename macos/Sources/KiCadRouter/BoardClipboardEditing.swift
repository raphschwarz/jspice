// Copy, cut, paste and duplicate on the board being edited, each pasted or duplicated selection one change, as KiCad's
// PCB editor makes them (KiCad 10.0.7: pcbnew/tools/edit_tool.cpp, EDIT_TOOL::copyToClipboard, cutToClipboard,
// Duplicate and DeleteItems; pcbnew/tools/pcb_control.cpp, PCB_CONTROL::Paste, pruneItemLayers and placeBoardItems;
// pcbnew/board.cpp, BOARD::MapNets and GetUniqueZoneName; pcbnew/board_item.cpp and footprint.cpp, Duplicate;
// pcbnew/pcb_group.cpp, DeepDuplicate; pcbnew/pcb_track.cpp, PCB_VIA::HasValidLayerPair; include/layer_range.h; pcbnew/
// board_commit.cpp, BOARD_COMMIT::Push, with pcbnew/connectivity/connectivity_algo.cpp's PropagateNets: the nets a
// change's tracks, vias and drawings on copper take). GNU General Public License version 3 or later, as KiCad (see
// KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardEditing {
    /// The point KiCad picks the items up by with the pointer at `cursor` (mm: BestDragOrigin, the reference point of
    /// a copy, or `moving`, of the move after a duplicate): `snapDistance` is KiCad's 50 pixels at the view's scale
    /// (mm), `grid` the grid's size (mm)
    public func dragOrigin(_ uuids: [String], cursor: KiCadPoint, snapDistance: Double, grid: Double = 0.001,
                           moving: Bool = false) -> KiCadPoint {
        let g = BoardWorld.iu(grid)
        let p = BoardClipboard.bestDragOrigin(router.board, items: uuids, cursor: Self.nm(cursor),
                                              lineSnapMinCornerDistance: snapDistance * 1e6, grid: IPoint(g, g), moving: moving)
        return Self.mm(p)
    }

    /// The clipboard's text of the items `uuids` (the board's footprints, tracks, vias, zones, drawings, texts, groups
    /// and tuning patterns, in the order they were selected), about `reference` (mm), as KiCad's Copy writes it; nil
    /// when none of them is on the board
    public func copy(_ uuids: [String], reference: KiCadPoint) -> String? {
        BoardClipboard.text(router.board, items: uuids, reference: Self.nm(reference))
    }

    /// The items copied (`copy`) and taken away, as KiCad's Cut: the text, and the change ("Cut")
    public func cut(_ uuids: [String], reference: KiCadPoint) -> (text: String, edit: Edit?)? {
        guard !isRouting, let text = copy(uuids, reference: reference) else { return nil }
        return (text, removeItems(Set(uuids), name: "Cut"))
    }

    /// Items of the board taken away, by id, as KiCad's Delete takes them: a group or a tuning pattern with its
    /// members, an item in a group left out of it; one change named `name`
    func removeItems(_ uuids: Set<String>, name: String) -> Edit? {
        let board = router.board
        var gone = Set<String>()
        for id in uuids {
            guard let node = BoardItems.item(board, id) else { continue }
            gone.insert(id)
            if node.head == "group" || node.head == "generated" {
                for m in BoardItems.descendants(node, in: board) { if let mid = m.value("uuid") { gone.insert(mid) } }
            }
        }
        guard !gone.isEmpty else { return nil }
        var footprints: [String] = [], zones: [String] = [], drawings: [String] = [], copper = Set<String>()
        for node in board.root.items where BoardItems.heads.contains(node.head ?? "") {
            guard let id = node.value("uuid"), gone.contains(id) else { continue }
            switch node.head ?? "" {
            case "segment", "arc", "via": copper.insert(id); continue
            case "footprint": footprints.append(id)
            case "zone": zones.append(id)
            case "group", "generated": break
            default: drawings.append(id)
            }
            board.root.remove(node)
        }
        // (the groups that kept some of their members let go of those gone)
        for group in board.root.items where group.head == "group" {
            if BoardItems.members(group).contains(where: gone.contains) {
                BoardItems.remapMembers(group, [:], kept: Set(BoardItems.members(group)).subtracting(gone))
            }
        }
        board.root.items.removeAll { $0.head == "group" && BoardItems.members($0).isEmpty }
        router.boardChanged()
        if !copper.isEmpty { router.remove(copper) }
        return change(name, footprints: footprints, zones: zones, drawings: drawings)
    }

    // MARK: - Paste

    /// What KiCad's Paste makes of the clipboard's `text` with the pointer at `point` (mm, its reference point put
    /// there, as KiCad's move after a paste puts it), as one change ("Paste"): its items with ids of their own, on
    /// the board's nets of the same names (new nets where the board has none of them; none if `clearNets`), each
    /// footprint's link to its symbol let go and its reference kept, made unique or made REF** (`annotations`), each
    /// zone's name one the board does not have, and what is on layers the board has not left out (an item on some
    /// of them kept on the others). Text that is not KiCad's: a text of its own on `layer` (KiCad's "Paste Text").
    /// The edit's footprints, changed (tracks and vias), zones, drawings and generators are what was pasted.
    public func paste(_ text: String, at point: KiCadPoint, annotations: BoardClipboard.Annotations = .keep, clearNets: Bool = false,
                      layer: String = "F.Cu") -> Edit? {
        guard !isRouting else { return nil }
        let board = router.board
        let at = Self.nm(point)
        guard let clip = BoardClipboard.read(text) else {
            guard !text.isEmpty else { return nil }
            let node = BoardClipboard.plainText(text, layer: layer)
            BoardItems.translate(node, by: at)
            board.addDrawing(node)
            router.boardChanged()
            return change("Paste Text", drawings: [node.value("uuid") ?? ""])
        }
        let isBoard = clip.layers != nil
        var items = clip.items.map { $0.copy() }
        // (the clipboard's own groups' members, as its board has them)
        func members(_ group: SExpr) -> [SExpr] {
            var out: [SExpr] = [], seen = Set<String>()
            func visit(_ g: SExpr) {
                for id in BoardItems.members(g) where seen.insert(id).inserted {
                    guard let m = items.first(where: { $0.value("uuid") == id }) else { continue }
                    out.append(m)
                    if m.head == "group" || m.head == "generated" { visit(m) }
                }
            }
            visit(group)
            return out
        }
        // the nets, by name (BOARD::MapNets: the board's of that name, or a new one), or none
        for item in items {
            if clearNets && isBoard {
                item.remove("net")
                for pad in item.all("pad") { pad.remove("net") }
                continue
            }
            // (a board that numbers its nets, KiCad 9's, numbers them here too)
            guard board.numbersNets else { continue }
            for (list, pad) in [(item["net"], false)] + item.all("pad").map({ ($0["net"], true) }) {
                guard let list, let name = list.text(at: list.items.count >= 3 ? 1 : 0) else { continue }
                list.items = board.netList(name, pad: pad).items
            }
        }
        if annotations == .remove {
            for item in items where item.head == "footprint" { KiCadFootprint(item, board: board).setProperty("Reference", "REF**") }
        }
        // what is on layers the board does not have left out (pruneItemLayers); a footprint, group or generator kept
        let enabled = BoardClipboard.enabledLayers(board)
        let copperCount = enabled.filter { $0.hasSuffix(".Cu") }.count
        var dropped = Set<String>()
        items = items.filter { item in
            switch item.head ?? "" {
            case "footprint", "group", "generated": return true
            default: break
            }
            if item.head == "via" {
                // (the via's layers as KiCad has them once it is the board's, PCB_VIA::GetLayerSet over the board's
                // copper; its pair valid if its ends are no deeper than the board's copper count allows,
                // HasValidLayerPair; its pair then made of what of them the board has, SetLayerSet)
                let ends = (item["layers"]?.arguments.compactMap(\.text) ?? []).map(BoardEditing.layerID)
                guard ends.count == 2, ends.allSatisfy({ $0 <= 2 || $0 <= 2 * copperCount }) else {
                    if let id = item.value("uuid") { dropped.insert(id) }
                    return false
                }
                let through = !item.arguments.contains { $0.kind == .symbol && ["blind", "buried", "micro"].contains($0.text) }
                if !through {
                    let set = BoardClipboard.viaLayers(ends[0], ends[1], copperCount: copperCount)
                        .filter { enabled.contains(BoardClipboard.copperName($0)) }.sorted()
                    guard !set.isEmpty else {
                        if let id = item.value("uuid") { dropped.insert(id) }
                        return false
                    }
                    var top: Int?, bottom = ends[1], bottomFound = false
                    for l in set {
                        if top == nil && l != 2 { top = l }
                        if !bottomFound { bottom = l }
                        if l == 2 { bottomFound = true }
                    }
                    let pair = [top ?? ends[0], bottom].map(BoardClipboard.copperName)
                    item.set(SExpr("layers", pair))
                }
                return true
            }
            // (its wildcards spelt out to the clipboard board's layers)
            let mine = BoardClipboard.layers(of: item, enabled: clip.layers?.arguments.compactMap { $0.text(at: 0) } ?? enabled)
            let allowed = mine.filter(enabled.contains)
            if allowed.isEmpty {
                if let id = item.value("uuid") { dropped.insert(id) }
                return false
            }
            if allowed.count < mine.count { BoardClipboard.setLayers(item, allowed, enabled: enabled) }
            return true
        }
        // new ids for everything (ResetUuid, with the items' own), the groups' members by their new ids
        var ids: [String: String] = [:]
        for item in items { BoardItems.renew(item, &ids) }
        let kept = Set(items.compactMap { $0.value("uuid") })
        for item in items where item.head == "group" || item.head == "generated" { BoardItems.remapMembers(item, ids, kept: kept) }
        items.removeAll { $0.head == "group" && BoardItems.members($0).isEmpty }
        let names = Set(board.zones.compactMap(\.name))
        for item in items {
            switch item.head ?? "" {
            case "footprint":
                item.remove("path")
                item.items.removeAll { ["version", "generator", "generator_version"].contains($0.head ?? "") }
            case "zone":
                if let name = item.value("name") {
                    item.set(SExpr("name", BoardClipboard.uniqueZoneName(name, inUse: names.contains)))
                }
            default:
                break
            }
        }
        if annotations == .unique {
            // (the selection after the paste: what is not a member of a group pasted with it)
            let inGroups = Set(items.filter { $0.head == "group" || $0.head == "generated" }.flatMap(BoardItems.members))
            let selected = items.filter { !inGroups.contains($0.value("uuid") ?? "") }
            BoardClipboard.reannotateDuplicates(selected, existing: board.root.all("footprint"), board: board, members: members)
        }
        for item in items where item.head != "group" { BoardItems.translate(item, by: at) }
        return place(items, "Paste")
    }

    /// The items put on the board where KiCad's file keeps their kinds, as one change named `name`
    func place(_ items: [SExpr], _ name: String) -> Edit? {
        guard !items.isEmpty else { return nil }
        let board = router.board
        var footprints: [String] = [], zones: [String] = [], drawings: [String] = [], copper: [String] = []
        for item in items {
            let id = item.value("uuid") ?? ""
            switch item.head ?? "" {
            case "footprint":
                board.add(item)
                footprints.append(id)
            case "segment", "arc", "via":
                board.addCopper(item)
                copper.append(id)
            case "zone":
                let all = board.root.items
                let after = all.lastIndex { $0.head == "zone" } ?? all.lastIndex { ["segment", "arc", "via"].contains($0.head ?? "") }
                let at = after.map { $0 + 1 }
                    ?? all.firstIndex { ["group", "generated", "embedded_fonts", "embedded_files"].contains($0.head ?? "") } ?? all.count
                board.root.items.insert(item, at: at)
                zones.append(id)
            case "group", "generated":
                let all = board.root.items
                let at = all.lastIndex { $0.head == "group" || $0.head == "generated" }.map { $0 + 1 }
                    ?? all.firstIndex { ["embedded_fonts", "embedded_files"].contains($0.head ?? "") } ?? all.count
                board.root.items.insert(item, at: at)
                if item.head == "group" { drawings.append(id) }
            default:
                board.addDrawing(item)
                drawings.append(id)
            }
        }
        let nets = propagateNets()
        router.boardChanged()
        return change(name, footprints: footprints, zones: zones, changed: copper + nets.copper,
                      drawings: drawings + nets.drawings)
    }

    /// The board's tracks, vias and drawings on copper given the nets KiCad's connectivity gives them as the change is
    /// committed (BOARD_COMMIT::Push, RecalculateRatsnest: CN_CONNECTIVITY_ALGO::PropagateNets, a cluster's pads' net
    /// to its tracks, vias and drawings), as BoardDRC's port of it has them; those it changed, by id
    func propagateNets() -> (copper: [String], drawings: [String]) {
        let board = router.board
        let drc = BoardDRC(board: board, project: project, designRules: designRules)
        let copper = drc.makeCopper()
        _ = drc.buildConnectivity(copper)
        var changed: [String] = []
        let tracks = Dictionary(board.tracks.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let vias = Dictionary(board.vias.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        for item in copper.items where item.kind == .track || item.kind == .arc || item.kind == .via {
            let now = item.netName.isEmpty ? nil : item.netName
            if let t = tracks[item.uuid], t.net != now {
                t.setNet(now)
                changed.append(item.uuid)
            } else if let v = vias[item.uuid], v.net != now {
                v.setNet(now)
                changed.append(item.uuid)
            }
        }
        // (and its drawings on copper, connected items as its tracks are: KiCad writes a drawing's net after its layer,
        // and none when it has none)
        let drawings = Dictionary(board.root.items.filter { $0.head?.hasPrefix("gr_") == true }.map { ($0.value("uuid") ?? "", $0) },
                                  uniquingKeysWith: { a, _ in a })
        var drawn: [String] = []
        for item in copper.drawings {
            guard let node = drawings[item.uuid], BoardDRC.netName(node) != item.netName else { continue }
            if item.netName.isEmpty {
                node.remove("net")
            } else {
                node.set(board.netList(item.netName, pad: false), after: ["layer", "layers"])
            }
            drawn.append(item.uuid)
        }
        return (changed, drawn)
    }

    // MARK: - Duplicate

    /// The items `uuids` duplicated (KiCad's Duplicate, Ctrl+D, and Duplicate and Increment, which in the board's
    /// editor increments no pad numbers: a pad is not duplicated on its own there), the copies moved by `delta` (mm,
    /// where KiCad's move after it takes them), as one change ("Duplicate"): each a copy with ids of its own, of
    /// the same nets, reference and link to its symbol, in the group its original is in; a group's or tuning
    /// pattern's members duplicated with it. Nil for a tuning pattern alone, as KiCad's.
    public func duplicate(_ uuids: [String], by delta: KiCadPoint = .zero) -> Edit? {
        guard !isRouting else { return nil }
        let board = router.board
        let originals = uuids.compactMap { BoardItems.item(board, $0) }
        guard !originals.isEmpty, !(originals.count == 1 && originals[0].head == "generated") else { return nil }
        let d = Self.nm(delta)
        var made: [SExpr] = []
        var joins: [(group: SExpr, member: String)] = []
        for original in originals {
            var ids: [String: String] = [:]
            if original.head == "group" || original.head == "generated" {
                // (DeepDuplicate: the members, all the way down, and the group, by their new ids)
                let copies = ([original] + BoardItems.descendants(original, in: board)).map { $0.copy() }
                for c in copies { BoardItems.renew(c, &ids) }
                for c in copies where c.head == "group" || c.head == "generated" { BoardItems.remapMembers(c, ids) }
                made += copies
            } else {
                let c = original.copy()
                BoardItems.renew(c, &ids)
                made.append(c)
            }
            // (BOARD_ITEM::Duplicate( addToParentGroup ): the copy in its original's group)
            if let id = original.value("uuid"), let group = BoardItems.parentGroup(board, id), let new = ids[id] {
                joins.append((group, new))
            }
        }
        for item in made where item.head != "group" { BoardItems.translate(item, by: d) }
        for (group, member) in joins {
            guard let list = group["members"] else { continue }
            let now = (BoardItems.members(group) + [member]).sorted()
            list.items = [list.items[0]] + now.map { SExpr(string: $0) }
        }
        return place(made, "Duplicate")
    }
}

extension BoardClipboard {
    /// A text of the clipboard's words that is not KiCad's (PCB_CONTROL::Paste: a PCB_TEXT of them, on the active
    /// layer, of EDA_TEXT's defaults), at 0, 0
    static func plainText(_ text: String, layer: String) -> SExpr {
        SExpr("gr_text", text, SExpr("at", 0.0, 0.0, 0.0), SExpr("layer", layer), SExpr("uuid", KiCadBoard.newUUID()),
              SExpr("effects", SExpr("font", SExpr("size", 1.27, 1.27))))
    }

    /// An item put on `layers` alone (BOARD_ITEM::SetLayerSet); a zone whose layers change is left unfilled, its
    /// properties of the layers gone dropped (ZONE::SetLayerSet)
    static func setLayers(_ item: SExpr, _ layers: [String], enabled: [String]) {
        if item.head == "zone" {
            BoardEditing.setZoneLayers(item, Set(layers), enabled: Set(enabled), ids: [:])
            return
        }
        let node = layers.count == 1 ? SExpr("layer", layers[0]) : SExpr("layers", layers)
        if let i = item.items.firstIndex(where: { $0.head == "layers" || $0.head == "layer" }) { item.items[i] = node }
    }

    /// A copper layer's name by its id (layerID's other way)
    static func copperName(_ id: Int) -> String { id == 0 ? "F.Cu" : id == 2 ? "B.Cu" : "In\((id - 2) / 2).Cu" }

    /// The copper layers (ids) of a via from `start` to `end` on a board of `copperCount` copper layers
    /// (PCB_VIA::GetLayerSet: LAYER_RANGE's walk from one to the other in the board's stack, no more than its count)
    static func viaLayers(_ start: Int, _ end: Int, copperCount: Int) -> [Int] {
        let count = max(copperCount, 2)
        let lastInner = 2 * (count - 2) + 2
        func next(_ l: Int, stop: Int, reverse: Bool) -> Int {
            if reverse {
                if l == 2 { return count == 2 ? 0 : lastInner }
                if l == stop || l == -1 { return -1 }
                if l == 4 { return 0 }
                return l - 2
            }
            if l == 0 && count == 2 { return 2 }
            if l == stop || l == -1 { return -1 }
            if l == lastInner { return 2 }
            if l == 0 { return 4 }
            return l + 2
        }
        let reverse = start == 2 && end != 2 ? true : (end == 2 || end >= start) ? false : true
        // (the range's end: an iterator at its stop, moved on once)
        let past = next(end, stop: end, reverse: false)
        var out: [Int] = []
        var l = start, left = count
        while l != past && l != -1 {
            out.append(l)
            left -= 1
            if left <= 0 { break }
            l = next(l, stop: end, reverse: reverse)
        }
        return out
    }
}
