// Ported from KiCad 10.0.7: thirdparty/rtree/geometry/rtree.h (Guttman's R-tree, quadratic split, spherical volumes)
// and libs/kimath/include/geometry/shape_index.h. Original algorithm by Antonin Guttman and Michael Stonebraker
// (1983); ANSI C by Melinda Green (1994); C++ by Greg Douglas (2004); Copyright (C) 2013 CERN; Copyright The KiCad
// Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// KiCad's R-tree of boxes, in two dimensions with eight branches a node: the same tree for the same insertions and
/// removals, so that a search visits what it finds in the order KiCad's does (the router's ties go by that order)
public final class RTree<Element: AnyObject> {
    struct Rect {
        var minX, minY, maxX, maxY: Int
    }

    struct Branch {
        var rect: Rect
        var child: Node?
        var data: Element?
    }

    final class Node {
        var count = 0
        var level = -1
        var branches: [Branch] = []
        var isInternal: Bool { level > 0 }
    }

    static var maxNodes: Int { 8 }
    static var minNodes: Int { 4 }

    private var root: Node
    /// (float's pi, as KiCad's table has it)
    private let unitSphereVolume = Double(Float(3.141593))

    public init() {
        root = Node()
        root.level = 0
    }

    public func insert(_ box: IBox, _ data: Element) {
        insertRect(Rect(minX: box.minX, minY: box.minY, maxX: box.maxX, maxY: box.maxY), Branch(rect: Rect(minX: 0, minY: 0, maxX: 0, maxY: 0), child: nil, data: data), &root, 0)
    }

    @discardableResult
    public func remove(_ box: IBox, _ data: Element) -> Bool {
        removeRect(Rect(minX: box.minX, minY: box.minY, maxX: box.maxX, maxY: box.maxY), data, &root)
    }

    /// Visits what overlaps `box`, until `visit` says to stop; how many it visited
    @discardableResult
    public func search(_ box: IBox, _ visit: (Element) -> Bool) -> Int {
        var found = 0
        _ = search(root, Rect(minX: box.minX, minY: box.minY, maxX: box.maxX, maxY: box.maxY), &found, visit)
        return found
    }

    public func removeAll() {
        root = Node()
        root.level = 0
    }

    // MARK: - KiCad's (Guttman's) algorithms

    private func insertRectRec(_ rect: Rect, _ leaf: Branch, _ node: Node, _ newNode: inout Node?, _ level: Int) -> Bool {
        if node.level > level {
            let index = pickBranch(rect, node)
            var otherNode: Node?
            if !insertRectRec(rect, leaf, node.branches[index].child!, &otherNode, level) {
                node.branches[index].rect = combine(rect, node.branches[index].rect)
                return false
            }
            node.branches[index].rect = nodeCover(node.branches[index].child!)
            let branch = Branch(rect: nodeCover(otherNode!), child: otherNode, data: nil)
            return addBranch(branch, node, &newNode)
        } else if node.level == level {
            var branch = leaf
            branch.rect = rect
            return addBranch(branch, node, &newNode)
        }
        return false
    }

    @discardableResult
    private func insertRect(_ rect: Rect, _ leaf: Branch, _ root: inout Node, _ level: Int) -> Bool {
        var newNode: Node?
        if insertRectRec(rect, leaf, root, &newNode, level) {
            // the root split: a new root, a level up
            let newRoot = Node()
            newRoot.level = root.level + 1
            var none: Node?
            _ = addBranch(Branch(rect: nodeCover(root), child: root, data: nil), newRoot, &none)
            _ = addBranch(Branch(rect: nodeCover(newNode!), child: newNode, data: nil), newRoot, &none)
            root = newRoot
            return true
        }
        return false
    }

    private func nodeCover(_ node: Node) -> Rect {
        var rect = Rect(minX: 0, minY: 0, maxX: 0, maxY: 0)
        for index in 0..<node.count {
            rect = index == 0 ? node.branches[index].rect : combine(rect, node.branches[index].rect)
        }
        return rect
    }

    private func addBranch(_ branch: Branch, _ node: Node, _ newNode: inout Node?) -> Bool {
        if node.count < Self.maxNodes {
            if node.branches.count > node.count {
                node.branches[node.count] = branch
            } else {
                node.branches.append(branch)
            }
            node.count += 1
            return false
        }
        newNode = splitNode(node, branch)
        return true
    }

    private func disconnectBranch(_ node: Node, _ index: Int) {
        node.branches[index] = node.branches[node.count - 1]
        node.count -= 1
    }

    private func pickBranch(_ rect: Rect, _ node: Node) -> Int {
        var first = true
        var bestIncr = -1.0, bestArea = 0.0
        var best = 0
        for index in 0..<node.count {
            let cur = node.branches[index].rect
            let area = volume(cur)
            let increase = volume(combine(rect, cur)) - area
            if increase < bestIncr || first {
                best = index
                bestArea = area
                bestIncr = increase
                first = false
            } else if increase == bestIncr && area < bestArea {
                best = index
                bestArea = area
                bestIncr = increase
            }
        }
        return best
    }

    private func combine(_ a: Rect, _ b: Rect) -> Rect {
        Rect(minX: min(a.minX, b.minX), minY: min(a.minY, b.minY), maxX: max(a.maxX, b.maxX), maxY: max(a.maxY, b.maxY))
    }

    /// KiCad's RectSphericalVolume (RTREE_USE_SPHERICAL_VOLUME is set)
    private func volume(_ r: Rect) -> Double {
        let hx = (Double(r.maxX) - Double(r.minX)) * 0.5
        let hy = (Double(r.maxY) - Double(r.minY)) * 0.5
        return (hx * hx + hy * hy) * unitSphereVolume
    }

    private struct PartitionVars {
        var partition: [Int]
        var total = 0
        var minFill = 0
        var taken: [Bool]
        var count = [0, 0]
        var cover = [Rect(minX: 0, minY: 0, maxX: 0, maxY: 0), Rect(minX: 0, minY: 0, maxX: 0, maxY: 0)]
        var area = [0.0, 0.0]
        var branchBuf: [Branch]
        var coverSplit = Rect(minX: 0, minY: 0, maxX: 0, maxY: 0)
        var coverSplitArea = 0.0
    }

    private func splitNode(_ node: Node, _ branch: Branch) -> Node {
        let level = node.level
        // the node's branches and the new one
        var buf = Array(node.branches[0..<Self.maxNodes])
        buf.append(branch)
        var vars = PartitionVars(partition: Array(repeating: -1, count: buf.count), taken: Array(repeating: false, count: buf.count),
                                 branchBuf: buf)
        vars.coverSplit = buf[0].rect
        for index in 1..<buf.count { vars.coverSplit = combine(vars.coverSplit, buf[index].rect) }
        vars.coverSplitArea = volume(vars.coverSplit)
        node.count = 0
        node.level = -1
        choosePartition(&vars, Self.minNodes)
        let newNode = Node()
        newNode.level = level
        node.level = level
        var none: Node?
        for index in 0..<vars.total {
            _ = addBranch(vars.branchBuf[index], vars.partition[index] == 0 ? node : newNode, &none)
        }
        return newNode
    }

    private func choosePartition(_ v: inout PartitionVars, _ minFill: Int) {
        v.count = [0, 0]
        v.area = [0, 0]
        v.total = v.branchBuf.count
        v.minFill = minFill
        for index in 0..<v.total {
            v.taken[index] = false
            v.partition[index] = -1
        }
        pickSeeds(&v)
        while v.count[0] + v.count[1] < v.total && v.count[0] < v.total - v.minFill && v.count[1] < v.total - v.minFill {
            var biggestDiff = -1.0
            var chosen = 0, betterGroup = 0
            for index in 0..<v.total where !v.taken[index] {
                let cur = v.branchBuf[index].rect
                let growth0 = volume(combine(cur, v.cover[0])) - v.area[0]
                let growth1 = volume(combine(cur, v.cover[1])) - v.area[1]
                var diff = growth1 - growth0
                let group: Int
                if diff >= 0 {
                    group = 0
                } else {
                    group = 1
                    diff = -diff
                }
                if diff > biggestDiff {
                    biggestDiff = diff
                    chosen = index
                    betterGroup = group
                } else if diff == biggestDiff && v.count[group] < v.count[betterGroup] {
                    chosen = index
                    betterGroup = group
                }
            }
            classify(chosen, betterGroup, &v)
        }
        if v.count[0] + v.count[1] < v.total {
            let group = v.count[0] >= v.total - v.minFill ? 1 : 0
            for index in 0..<v.total where !v.taken[index] { classify(index, group, &v) }
        }
    }

    private func pickSeeds(_ v: inout PartitionVars) {
        var seed0 = 0, seed1 = 0
        let area = v.branchBuf.map { volume($0.rect) }
        var worst = -v.coverSplitArea - 1
        for a in 0..<(v.total - 1) {
            for b in (a + 1)..<v.total {
                let waste = volume(combine(v.branchBuf[a].rect, v.branchBuf[b].rect)) - area[a] - area[b]
                if waste >= worst {
                    worst = waste
                    seed0 = a
                    seed1 = b
                }
            }
        }
        classify(seed0, 0, &v)
        classify(seed1, 1, &v)
    }

    private func classify(_ index: Int, _ group: Int, _ v: inout PartitionVars) {
        v.partition[index] = group
        v.taken[index] = true
        v.cover[group] = v.count[group] == 0 ? v.branchBuf[index].rect : combine(v.branchBuf[index].rect, v.cover[group])
        v.area[group] = volume(v.cover[group])
        v.count[group] += 1
    }

    private func removeRect(_ rect: Rect, _ data: Element, _ root: inout Node) -> Bool {
        var reInsert: [Node] = []
        if !removeRectRec(rect, data, root, &reInsert) {
            // the nodes left too empty, their branches put back in (last taken out first, as KiCad's list)
            for node in reInsert.reversed() {
                for index in 0..<node.count {
                    insertRect(node.branches[index].rect, node.branches[index], &root, node.level)
                }
            }
            if root.count == 1 && root.isInternal {
                root = root.branches[0].child!
            }
            return false
        }
        return true
    }

    private func removeRectRec(_ rect: Rect, _ data: Element, _ node: Node, _ reInsert: inout [Node]) -> Bool {
        if node.isInternal {
            for index in 0..<node.count where overlap(rect, node.branches[index].rect) {
                let child = node.branches[index].child!
                if !removeRectRec(rect, data, child, &reInsert) {
                    if child.count >= Self.minNodes {
                        node.branches[index].rect = nodeCover(child)
                    } else {
                        reInsert.append(child)
                        disconnectBranch(node, index)
                    }
                    return false
                }
            }
            return true
        }
        for index in 0..<node.count where node.branches[index].data === data {
            disconnectBranch(node, index)
            return false
        }
        return true
    }

    private func overlap(_ a: Rect, _ b: Rect) -> Bool {
        !(a.minX > b.maxX || b.minX > a.maxX || a.minY > b.maxY || b.minY > a.maxY)
    }

    private func search(_ node: Node, _ rect: Rect, _ found: inout Int, _ visit: (Element) -> Bool) -> Bool {
        if node.isInternal {
            for index in 0..<node.count where overlap(rect, node.branches[index].rect) {
                if !search(node.branches[index].child!, rect, &found, visit) { return false }
            }
        } else {
            for index in 0..<node.count where overlap(rect, node.branches[index].rect) {
                found += 1
                if !visit(node.branches[index].data!) { return false }
            }
        }
        return true
    }
}
