// Items locked and unlocked as KiCad's Lock and Unlock lock them (KiCad 10.0.7: pcbnew/tools/board_editor_control.cpp,
// BOARD_EDITOR_CONTROL::modifyLockSelected), and a locked one known as KiCad knows it (BOARD_ITEM::IsLocked, PAD::IsLocked,
// pcbnew/tools/pcb_selection_tool.cpp, HasLockedDescendant), written as pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.cpp
// writes it. Copyright The KiCad Developers, see KiCad's AUTHORS.txt. GNU General Public License version 3 or later, as
// KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardEditing {
    /// The board's items Lock and Unlock reach, by id: its footprints, tracks, arcs, vias, zones, own drawings and
    /// texts, and tuning patterns
    func lockableNodes(_ uuids: Set<String>) -> [SExpr] {
        let heads = Set(["footprint", "segment", "arc", "via", "zone", "gr_text", "gr_text_box", "generated"]).union(KiCadDrawing.heads)
        return router.board.root.items.filter { heads.contains($0.head ?? "") && uuids.contains($0.value("uuid") ?? "") }
    }

    /// Whether the item of that id is locked as KiCad has it (its own flag, or a locked group's or tuning pattern's it
    /// is in; a pad its footprint's)
    public func isLocked(_ uuid: String) -> Bool {
        if let node = lockableNodes([uuid]).first { return isLockedNode(node) }
        if let (_, fp) = padNode(uuid) { return isLocked(fp.uuid) }
        return false
    }

    /// The ids of those KiCad's selection for a move, turn, flip or deletion keeps (FilterCollectorForLockedItems: the
    /// locked left out, unless overridesLocks)
    func unlocked(_ uuids: [String]) -> [String] { overridesLocks ? uuids : uuids.filter { !isLocked($0) } }

    /// Items locked (or, `locked` false, unlocked), as KiCad's Lock and Unlock do them: footprints, tracks, arcs, vias,
    /// zones and the board's own drawings and texts (pads left as they are, which KiCad does not lock alone), the
    /// tuning pattern a track is of with it, a footprint unlocked with all its items; written as KiCad writes each
    /// item's lock, as one change ("Lock", "Unlock"); nil if it changes nothing
    public func setLocked(_ uuids: Set<String>, _ locked: Bool) -> Edit? {
        guard !isRouting else { return nil }
        var nodes = lockableNodes(uuids)
        // (a track's tuning pattern, locked or unlocked with it)
        let members = Set(nodes.filter { ["segment", "arc"].contains($0.head ?? "") }.compactMap { $0.value("uuid") })
        for g in router.board.root.all("generated") where !nodes.contains(where: { $0 === g }) {
            if g["members"]?.arguments.contains(where: { members.contains($0.text) }) == true { nodes.append(g) }
        }
        guard !nodes.isEmpty else { return nil }
        let was = nodes.map(\.compact)
        for node in nodes {
            Self.setLockFlag(node, locked)
            if !locked && node.head == "footprint" {
                for child in node.items where child.isList { Self.removeLockFlag(child) }
            }
        }
        guard nodes.map(\.compact) != was else { return nil }
        router.boardChanged()
        let footprints = nodes.filter { $0.head == "footprint" }.compactMap { $0.value("uuid") }
        let zones = nodes.filter { $0.head == "zone" }.compactMap { $0.value("uuid") }
        let changed = nodes.filter { ["segment", "arc", "via"].contains($0.head ?? "") }.compactMap { $0.value("uuid") }
        let drawings = nodes.filter { ($0.head ?? "").hasPrefix("gr_") }.compactMap { $0.value("uuid") }
        return change(locked ? "Lock" : "Unlock", footprints: footprints, zones: zones, changed: changed, drawings: drawings)
    }

    /// Lock and Unlock's toggle (KiCad's Toggle Lock): every item unlocked if any is locked, else every one locked
    public func toggleLocked(_ uuids: Set<String>) -> Edit? {
        setLocked(uuids, !uuids.contains { isLocked($0) })
    }

    static func removeLockFlag(_ node: SExpr) {
        node.items.removeAll { $0.head == "locked" || ($0.kind == .symbol && $0.text == "locked") }
    }

    /// An item's (locked yes) put where KiCad writes it for its kind, or taken away
    static func setLockFlag(_ node: SExpr, _ locked: Bool) {
        removeLockFlag(node)
        guard locked else { return }
        let flag = SExpr("locked", Keyword("yes"))
        switch node.head ?? "" {
        case "footprint", "gr_text", "gr_text_box":
            // (after its library id, or its text)
            node.items.insert(flag, at: min(2, node.items.count))
        case "segment", "arc":
            node.insert(flag, after: ["start", "mid", "end", "width"])
        case "via":
            node.insert(flag, after: ["at", "size", "drill", "backdrill", "tertiary_drill", "front_post_machining", "back_post_machining",
                                      "layers", "remove_unused_layers", "keep_end_layers", "start_end_only"])
        case "zone":
            // (after its net)
            let at = node.items.lastIndex { $0.head == "net" || $0.head == "net_name" }.map { $0 + 1 } ?? 1
            node.items.insert(flag, at: min(at, node.items.count))
        case "generated":
            node.insert(flag, after: ["uuid", "type", "name", "layer"])
        default:
            // (a drawing's, after its stroke and fill)
            node.insert(flag, after: ["start", "mid", "end", "center", "pts", "radius", "width", "stroke", "fill"])
        }
    }
}
