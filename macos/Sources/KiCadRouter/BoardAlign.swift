// Align and distribute, as KiCad's PCB editor does them (KiCad 10.0.8: pcbnew/tools/align_distribute_tool.cpp,
// ALIGN_DISTRIBUTE_TOOL: GetSelections, selectTarget, AlignTop, AlignBottom, AlignLeft, AlignRight, AlignCenterX,
// AlignCenterY, DistributeItems, doDistributeGaps and doDistributeCenters, with getBoundingBox; libs/kimath/src/geometry/
// distribute.cpp, GetDeltasForDistributeByGaps and GetDeltasForDistributeByPoints; libs/kimath/include/math/box2.h,
// BOX2's GetCenter and Contains). GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardEditing {
    /// KiCad's align and distribute actions
    public enum Alignment: String, Sendable, CaseIterable {
        case top, bottom, left, right, centerX, centerY
        case distributeHorizontallyCenters, distributeHorizontallyGaps, distributeVerticallyCenters, distributeVerticallyGaps

        /// What KiCad calls the change it makes (its commit's name)
        public var name: String {
            switch self {
            case .top: return "Align to Top"
            case .bottom: return "Align to Bottom"
            case .left: return "Align to Left"
            case .right: return "Align to Right"
            case .centerX: return "Align to Middle"
            case .centerY: return "Align to Center"
            case .distributeHorizontallyCenters: return "Distribute Horizontally by Centers"
            case .distributeHorizontallyGaps: return "Distribute Horizontally with Even Gaps"
            case .distributeVerticallyCenters: return "Distribute Vertically by Centers"
            case .distributeVerticallyGaps: return "Distribute Vertically with Even Gaps"
            }
        }

        /// KiCad's menu's name for it
        public var title: String {
            switch self {
            case .centerX: return "Align to Horizontal Center"
            case .centerY: return "Align to Vertical Center"
            default: return name
            }
        }

        public var distributes: Bool { rawValue.hasPrefix("distribute") }
    }

    /// The items `uuids` aligned or distributed as KiCad's tool does it with the pointer at `cursor` (mm), by their
    /// boxes (a footprint's without its texts), as one change named as KiCad names it. Aligning (two or more): to the
    /// edge or centre of a locked item (the one under the pointer, else the first in the edge's order), else of the
    /// item under the pointer, else of the outermost; the locked ones stay. Distributing (three or more, none locked:
    /// KiCad then does nothing): the ones between the outermost two moved to even centres or gaps between them. Nil if
    /// that moves nothing, or an item is one the port does not box (a group, a dimension, a table).
    public func align(_ uuids: [String], _ how: Alignment, cursor: KiCadPoint) -> Edit? {
        guard !isRouting else { return nil }
        let board = router.board
        let footprintBoxes = Dictionary(BoxSelection(board: board, project: project).footprints.map { ($0.uuid, $0.box) },
                                        uniquingKeysWith: { a, _ in a })
        var items: [(node: SExpr, box: IBox)] = []
        // (a footprint's text selected on its own, KiCad's box can take one: aligned on its own by its box, moved
        // only if its footprint is not selected too)
        var parents: [ObjectIdentifier: SExpr] = [:]
        for id in uuids {
            if let node = BoardItems.item(board, id) {
                guard let box = BoardItems.boundingBox(node, footprintBoxes: footprintBoxes, board: board) else { return nil }
                items.append((node, box))
                continue
            }
            for fp in board.root.all("footprint") {
                guard let text = fp.items.first(where: { ($0.head == "property" || $0.head == "fp_text") && $0.value("uuid") == id }),
                      let box = BoardWorld.textStrokes(text, footprint: fp)?.boundingBox else { continue }
                items.append((text, box))
                parents[ObjectIdentifier(text)] = fp
            }
        }
        let selected = Set(uuids)
        func moves(_ node: SExpr) -> Bool {
            guard let fp = parents[ObjectIdentifier(node)] else { return true }
            return !selected.contains(fp.value("uuid") ?? "")
        }
        let c = Self.nm(cursor)
        func contains(_ b: IBox) -> Bool { b.minX <= c.x && c.x <= b.maxX && b.minY <= c.y && c.y <= b.maxY }
        var moved: [(SExpr, IPoint)] = []
        if how.distributes {
            // (FilterCollectorForHierarchy: a footprint's text left out where its footprint is selected)
            items = items.filter { moves($0.node) }
            guard items.count >= 3, !items.contains(where: { BoardItems.isLocked($0.node) }) else { return nil }
            let horizontal = how == .distributeHorizontallyCenters || how == .distributeHorizontallyGaps
            let deltas: [Int]
            if how == .distributeHorizontallyGaps || how == .distributeVerticallyGaps {
                items = Self.sorted(items) { horizontal ? $0.minX : $0.minY }
                deltas = Self.deltasForGaps(items.map { horizontal ? ($0.box.minX, $0.box.maxX) : ($0.box.minY, $0.box.maxY) })
            } else {
                items = Self.sorted(items) { horizontal ? $0.center.x : $0.center.y }
                deltas = Self.deltasForPoints(items.map { horizontal ? $0.box.center.x : $0.box.center.y })
            }
            for i in 1..<(items.count - 1) where deltas[i] != 0 {
                moved.append((items[i].node, horizontal ? IPoint(deltas[i], 0) : IPoint(0, deltas[i])))
            }
        } else {
            guard items.count >= 2 else { return nil }
            // (each kind's edge, the order its items are sorted in, and which way the move goes)
            let value: (IBox) -> Int
            let before: (IBox, IBox) -> Bool
            let vertical: Bool
            switch how {
            case .top: (value, vertical) = ({ $0.minY }, true); before = { $0.minY < $1.minY }
            case .bottom: (value, vertical) = ({ $0.maxY }, true); before = { $0.maxY > $1.maxY }
            case .left: (value, vertical) = ({ $0.minX }, false); before = { $0.minX < $1.minX }
            case .right: (value, vertical) = ({ $0.maxX }, false); before = { $0.maxX > $1.maxX }
            case .centerX: (value, vertical) = ({ $0.center.x }, false); before = { $0.center.x < $1.center.x }
            default: (value, vertical) = ({ $0.center.y }, true); before = { $0.center.y < $1.center.y }
            }
            let locked = items.filter { BoardItems.isLocked($0.node) }.sorted { before($0.box, $1.box) }
            let free = items.filter { !BoardItems.isLocked($0.node) }.sorted { before($0.box, $1.box) }
            guard !free.isEmpty else { return nil }
            // (selectTarget: a locked item, the one under the pointer first; else the item under the pointer; else
            // the first)
            let target: Int
            if !locked.isEmpty {
                target = value((locked.first { contains($0.box) } ?? locked[0]).box)
            } else {
                target = value((free.first { contains($0.box) } ?? free[0]).box)
            }
            for item in free {
                let d = target - value(item.box)
                if d != 0 && moves(item.node) { moved.append((item.node, vertical ? IPoint(0, d) : IPoint(d, 0))) }
            }
        }
        guard !moved.isEmpty else { return nil }
        var footprints: [String] = [], zones: [String] = [], copper: [String] = [], drawings: [String] = []
        for (node, d) in moved {
            if let fp = parents[ObjectIdentifier(node)] {
                // (a footprint's text: moved on the board, written again relative to its footprint)
                BoardItems.moveFootprintText(node, of: fp, by: d)
                footprints.append(fp.value("uuid") ?? "")
                continue
            }
            BoardItems.translate(node, by: d)
            let id = node.value("uuid") ?? ""
            switch node.head ?? "" {
            case "footprint": footprints.append(id)
            case "zone": zones.append(id)
            case "segment", "arc", "via": copper.append(id)
            default: drawings.append(id)
            }
        }
        let nets = propagateNets()
        router.boardChanged()
        return change(how.name, footprints: footprints, zones: zones, changed: copper + nets.copper,
                      drawings: drawings + nets.drawings)
    }

    /// The items sorted by `key` of their boxes (std::sort's order of those of equal keys aside)
    static func sorted(_ items: [(node: SExpr, box: IBox)], by key: (IBox) -> Int) -> [(node: SExpr, box: IBox)] {
        items.enumerated().sorted { a, b in
            let ka = key(a.element.box), kb = key(b.element.box)
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
    }

    /// GetDeltasForDistributeByGaps: the moves that leave even gaps between the items' spans (start, end), the first
    /// and last staying where they are
    static func deltasForGaps(_ spans: [(Int, Int)]) -> [Int] {
        var deltas = [Int](repeating: 0, count: spans.count)
        guard spans.count >= 3 else { return deltas }
        var totalGap = spans[spans.count - 1].0 - spans[0].1
        for i in 1..<(spans.count - 1) { totalGap -= spans[i].1 - spans[i].0 }
        let perItemGap = Double(totalGap) / Double(spans.count - 1)
        var targetPos = spans[0].1
        for i in 1..<(spans.count - 1) {
            let (start, end) = spans[i]
            deltas[i] = targetPos - start + KiMath.round(Double(i) * perItemGap)
            targetPos += end - start
        }
        return deltas
    }

    /// GetDeltasForDistributeByPoints: the moves that space the items' centres evenly between the first and last
    static func deltasForPoints(_ positions: [Int]) -> [Int] {
        var deltas = [Int](repeating: 0, count: positions.count)
        guard positions.count >= 3 else { return deltas }
        let start = positions[0]
        let gap = Double(positions[positions.count - 1] - start) / Double(positions.count - 1)
        for i in 1..<(positions.count - 1) { deltas[i] = start + KiMath.round(Double(i) * gap) - positions[i] }
        return deltas
    }
}
