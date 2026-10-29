// Ported from KiCad 10.0.7: pcbnew/router/pns_component_dragger.h and pns_component_dragger.cpp (a footprint's pads
// dragged with the tracks on them).
// Copyright (C) 2013-2020 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// What drags (KiCad's DRAG_ALGO): a track's segment, corner, arc or via (Dragger), or a footprint's pads with the
/// tracks on them (ComponentDragger). Each move is made in a branch of the world from before the drag.
protocol DragAlgo: AnyObject {
    /// Drags what is dragged to `p`; whether it got there
    func drag(_ p: IPoint) -> Bool
    /// The drag kept, if it may be (`forceCommit`: whatever it collides with); whether it was
    func fixRoute(forceCommit: Bool) -> Bool
    /// The world as the drag leaves it (KiCad's CurrentNode)
    var currentNode: Node { get }
    /// What the last move dragged (KiCad's Traces)
    var traces: [Item] { get }
    /// The nets of what is dragged (KiCad's CurrentNets)
    var currentNets: [NetHandle?] { get }
    /// The layer of what is dragged (KiCad's CurrentLayer)
    var currentLayer: Int { get }
    /// Whether the drag marks obstacles, its first move having failed (KiCad's GetForceMarkObstaclesMode)
    var forceMarkObstaclesMode: Bool { get }
    /// Whether the last move worked, as GetForceMarkObstaclesMode reports it
    var dragStatus: Bool { get }
}

extension Dragger: DragAlgo {}

/// A footprint's pads (and its zones' and drawings' solids) dragged by the pointer, the tracks on its pads with
/// them (KiCad's PNS::COMPONENT_DRAGGER): each pad moved by the pointer's offset from where the drag started; a
/// track from one of the dragged pads to another moved whole with them; the line out of a pad to anywhere else
/// reshaped round its end, which is dragged with the pad as a line's corner is dragged (on the 45° directions). What
/// is in the way is not walked round or shoved: the drag is kept only if what it moved collides with nothing (or
/// where violations are allowed, or forced).
public final class ComponentDragger: DragAlgo {
    unowned let router: Router
    var settings: RoutingSettings { router.settings }

    /// A line dragged with a pad: the line as it was, the pad, the end of the line (`offset` from the pad's centre,
    /// for a line ending inside the pad), where it was and where it goes now (KiCad's DRAGGED_CONNECTION)
    private struct DraggedConnection {
        var origLine: Line
        var attachedPad: Solid
        var pOrig = IPoint.zero
        var pNext = IPoint.zero
        var offset = IPoint.zero
    }

    private var world: Node
    /// The pads (and other solids) dragged, each once (KiCad's m_solids)
    private var solids: [Solid] = []
    /// The tracks moved whole with the pads, each once (KiCad's m_fixedItems)
    private var fixedItems: [Item] = []
    /// The lines dragged with the pads (KiCad's m_conns)
    private var conns: [DraggedConnection] = []
    /// What the drag was started with (KiCad's m_initialDraggedItems)
    private var initialDraggedItems: [Item] = []
    /// What the last move dragged (KiCad's m_draggedItems): the pads moved, the tracks moved whole, the lines
    public private(set) var traces: [Item] = []
    private var current: Node?
    /// Where the drag started (KiCad's m_p0)
    public private(set) var startPoint = IPoint.zero
    /// KiCad's m_dragStatus, which nothing sets: false
    public private(set) var dragStatus = false
    /// The pads (and other solids) the last move moved, each with its copy where it went (as the drag kept hands
    /// them to the board's side, which moves their footprints by the offsets between them)
    public private(set) var moved: [(original: Solid, copy: Solid)] = []

    init(router: Router, world: Node) {
        self.router = router
        self.world = world
    }

    /// KiCad's SetWorld
    func setWorld(_ node: Node) { world = node }

    /// Starts dragging `primitives` (the solids of a footprint's pads, zones and drawings) from `p` (KiCad's Start):
    /// finds the tracks on the pads, those to move whole with them and the lines to drag their ends of. Always true.
    func start(_ p: IPoint, _ primitives: [Item]) -> Bool {
        current = nil
        initialDraggedItems = primitives
        startPoint = p
        var seenItems = Set<ObjectIdentifier>()
        func contains(_ item: Item) -> Bool { primitives.contains { $0 === item } }

        func addLinked(_ solid: Solid, _ joint: Joint, _ item: LinkedItem, _ offset: IPoint = .zero) {
            if !seenItems.insert(ObjectIdentifier(item)).inserted { return }
            // (a track straight from one dragged pad to another: moved whole)
            let otherEnd = joint.pos == item.anchor(0) ? item.anchor(1) : item.anchor(0)
            if let otherJoint = world.findJoint(otherEnd, layer: item.layer, net: item.net), otherJoint.linkCount(.solid) > 0 {
                for otherItem in otherJoint.links where contains(otherItem) {
                    addFixed(item)
                    return
                }
            }
            var segIndex = 0
            let origLine = world.assembleLine(item, originSegmentIndex: &segIndex)
            let cn = DraggedConnection(origLine: origLine, attachedPad: solid, offset: offset)
            // (a line from one dragged pad to another: moved whole too)
            let line = cn.origLine.cLine
            let jA = world.findJoint(line.point(0), layer: item.layer, net: item.net)
            let jB = world.findJoint(line.lastPoint, layer: item.layer, net: item.net)
            // (KiCad asserts that one of them is `joint`)
            let jSearch = jA === joint ? jB : jA
            if let jSearch, jSearch.linkCount(.solid) > 0 {
                for otherItem in jSearch.links where contains(otherItem) {
                    for link in cn.origLine.links { addFixed(link) }
                    return
                }
            }
            conns.append(cn)
        }

        for item in primitives {
            guard let solid = item as? Solid else { continue }
            if !solids.contains(where: { $0 === solid }) { solids.append(solid) }
            if !item.isRoutable { continue }
            guard let jt = world.findJoint(solid.pos, solid) else { continue }
            for link in jt.links where link.ofKind([.segment, .arc]) {
                addLinked(solid, jt, link as! LinkedItem)
            }
            // (tracks ending inside the pad's hull, off its centre, by their places, then nets and layers, as
            // tools/kicad-reference has KiCad take them: KiCad takes them from its hash map of joints)
            let extraJoints = world.queryJoints(solid.hull().bbox, layers: solid.layers, kinds: [.segment, .arc]).sorted { a, b in
                if a.pos.x != b.pos.x { return a.pos.x < b.pos.x }
                if a.pos.y != b.pos.y { return a.pos.y < b.pos.y }
                if a.net != b.net { return (a.net ?? Int.min) < (b.net ?? Int.min) }
                return a.layers.start < b.layers.start
            }
            for extraJoint in extraJoints where extraJoint.net == jt.net && extraJoint.linkCount() == 1 {
                let li = extraJoint.links[0] as! LinkedItem
                // (a track of the pad's net collides with it only where a rule of the user's is net-blind, which
                // these have none of)
                if li.collide(solid, world, layer: solid.layer) {
                    addLinked(solid, extraJoint, li, extraJoint.pos - solid.pos)
                }
            }
        }
        return true
    }

    private func addFixed(_ item: Item) {
        if !fixedItems.contains(where: { $0 === item }) { fixedItems.append(item) }
    }

    /// Drags the pads to `p`, and with them the tracks moved whole and the lines' ends (KiCad's Drag). Always true.
    @discardableResult
    func drag(_ p: IPoint) -> Bool {
        world.killChildren()
        let node = world.branch()
        current = node
        for item in initialDraggedItems { node.remove(item) }
        traces.removeAll()
        moved.removeAll()
        let d = p - startPoint
        // (the pads, and the tracks moved whole, in the order they were made, as tools/kicad-reference has KiCad take
        // them: KiCad takes them from sets of pointers)
        for s in Node.bySerial(solids) as! [Solid] {
            let pNext = d + s.pos
            let snew = s.clone() as! Solid
            snew.setPos(pNext)
            traces.append(snew)
            moved.append((s, snew))
            node.add(snew)
            if !s.isRoutable { continue }
            for i in conns.indices where conns[i].attachedPad === s {
                conns[i].pOrig = s.pos + conns[i].offset
                conns[i].pNext = pNext + conns[i].offset
            }
        }
        for item in Node.bySerial(fixedItems) {
            node.remove(item)
            switch item {
            case let s as Segment:
                let sNew = s.clone() as! Segment
                sNew.setEnds(d + s.seg.a, d + s.seg.b)
                traces.append(sNew)
                // (one the branch has already, of the same net between the same points, it refuses: KiCad frees it
                // and keeps it among what it dragged, which tools/kicad-reference leaves out as undefined)
                node.add(sNew)
            case let a as Arc:
                let aNew = a.clone() as! Arc
                aNew.move(d)
                traces.append(aNew)
                node.add(aNew)
            default:
                // (KiCad: "Unexpected item type in COMPONENT_DRAGGER::m_fixedItems")
                break
            }
        }
        for cn in conns {
            let lNew = cn.origLine.copy()
            lNew.unmark()
            lNew.clearLinks()
            lNew.dragCorner(cn.pNext, cn.origLine.cLine.find(cn.pOrig))
            Router.dbg("cdrag-new-fanout:\(lNew.cLine.points.map { " (\($0.x),\($0.y))" }.joined())")
            traces.append(lNew.copy())
            node.remove(cn.origLine.copy())
            node.add(lNew)
        }
        return true
    }

    /// The drag kept, if it may be (KiCad's FixRoute): where violations are allowed (marking obstacles), forced, or
    /// where what it moved collides with nothing. Whether it was kept.
    func fixRoute(forceCommit: Bool) -> Bool {
        let node = currentNode
        if settings.allowDRCViolations || forceCommit || node.checkColliding(traces) == nil {
            router.commitRouting(node)
            return true
        }
        return false
    }

    /// The world as the drag leaves it (KiCad's CurrentNode)
    public var currentNode: Node { current ?? world }

    /// The nets of what is dragged (KiCad's CurrentNets: none, for a footprint)
    public var currentNets: [NetHandle?] { [] }

    /// The layer of what is dragged (KiCad's CurrentLayer: none, for a footprint)
    public var currentLayer: Int { -1 }

    /// KiCad's GetForceMarkObstaclesMode: never
    public var forceMarkObstaclesMode: Bool { false }
}
