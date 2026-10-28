import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// The board edited as the PCB view edits it (BoardEditing): tracks routed by pointer moves and clicks, finished,
/// stopped, vias placed, tracks taken away; each change handed back as the board before and after it. The board the
/// session leaves goes through kicad-cli's DRC where KiCad is installed.
final class BoardEditingTests: XCTestCase {
    static func boards() throws -> [URL] {
        let folder = try XCTUnwrap(Bundle.module.url(forResource: "boards", withExtension: nil, subdirectory: "Fixtures"))
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
    }

    static func project(_ file: URL) -> [String: Any]? {
        (try? Data(contentsOf: file.deletingPathExtension().appendingPathExtension("kicad_pro")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func mm(_ p: IPoint) -> KiCadPoint { KiCadPoint(Double(p.x) / 1e6, Double(p.y) / 1e6) }

    func testASessionOfRoutingHandsBackEachChange() throws {
        var edits = 0, placed = 0
        var finalBoards: [(URL, KiCadBoard)] = []
        for file in try Self.boards() {
            let board = try KiCadBoard.read(file)
            let session = BoardEditing(board: board, project: Self.project(file))
            XCTAssertFalse(session.layers.isEmpty)
            XCTAssertEqual(session.layers.first, "F.Cu")
            var last = board.text
            for (k, (a, b, layer)) in BoardRoutingTests.pairs(session.router.world, seed: file.lastPathComponent).enumerated() {
                let from = Self.mm(a), to = Self.mm(b)
                guard session.start(at: from, layer: session.layers[layer]) else { continue }
                XCTAssertTrue(session.isRouting)
                // a pad's centre is where the pointer goes on it (magnetic pads)
                XCTAssertEqual(session.snap(KiCadPoint(to.x + 0.01, to.y - 0.01), layer: session.layers[layer]), b)
                for t in [0.3, 0.6] {
                    let preview = session.move(to: KiCadPoint(from.x + (to.x - from.x) * t + 0.4, from.y + (to.y - from.y) * t - 0.3))
                    XCTAssertNotNil(preview)
                    XCTAssertEqual(preview?.net, session.routedNet)
                }
                if k == 1 {
                    // a via on the way, and the track on from it on the other side
                    session.placeVia()
                    _ = session.fix(at: KiCadPoint(from.x + (to.x - from.x) * 0.6 + 0.4, from.y + (to.y - from.y) * 0.6 - 0.3))
                }
                session.move(to: to)
                // a click on the other pad finishes it; a track that could not get there is finished by a double click
                // there, or kept as far as it is fixed (Escape)
                let edit = session.fix(at: to) ?? (k % 2 == 0 ? session.finish(at: to) : session.stop())
                XCTAssertFalse(session.isRouting)
                guard let edit else { continue }
                edits += 1
                placed += edit.added.count
                XCTAssertEqual(edit.before.text, last, "each change is made from the board the last one left")
                XCTAssertEqual(edit.after.text, session.board.text)
                for uuid in edit.added { XCTAssertTrue(edit.after.copperItems.contains { $0.value("uuid") == uuid }) }
                last = edit.after.text
            }
            // the tracks of the first change taken away again
            if let first = session.board.copperItems.compactMap({ $0.value("uuid") }).first(where: { !board.text.contains($0) }) {
                let edit = try XCTUnwrap(session.remove([first]))
                XCTAssertEqual(edit.removed, [first])
                XCTAssertEqual(edit.before.text, last)
                XCTAssertFalse(edit.after.copperItems.contains { $0.value("uuid") == first })
                edits += 1
            }
            // the same board read again: nothing to do; another: routing on it
            let router = session.router
            session.load(session.board.copy())
            XCTAssertTrue(session.router === router)
            finalBoards.append((file, session.board))
        }
        print("BoardEditingTests: \(edits) changes, \(placed) tracks and vias placed")
        XCTAssertGreaterThan(placed, 0)

        guard let kicad = KiCadInstallation.find(), kicad.major >= KiCadInstallation.minimumMajor else {
            if ProcessInfo.processInfo.environment["JSPICE_REQUIRE_KICAD"] != nil { return XCTFail("KiCad 10's kicad-cli is needed") }
            return
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-editing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for (file, board) in finalBoards {
            let copy = work.appendingPathComponent(file.lastPathComponent)
            try board.write(to: copy)
            let pro = file.deletingPathExtension().appendingPathExtension("kicad_pro")
            try? FileManager.default.copyItem(at: pro, to: copy.deletingPathExtension().appendingPathExtension("kicad_pro"))
            let original = Set(try KiCadBoard.read(file).copperItems.compactMap { $0.value("uuid") })
            let added = Set(board.copperItems.compactMap { $0.value("uuid") }).subtracting(original)
            let report = try KiCadFabrication(installation: kicad).drc(copy, refillZones: false)
            let ours = report.violations.filter { v in
                BoardRoutingTests.routerViolations.contains(v.type) && v.items.contains { added.contains($0.uuid) }
            }
            XCTAssert(ours.isEmpty, "\(file.lastPathComponent): " + ours.map { "\($0.type): \($0.description)" }.joined(separator: "; "))
        }
    }

    /// A blind, buried or micro via dragged keeps its type: the board's file has it again after "via", as KiCad
    /// writes it
    func testADraggedViaKeepsItsType() throws {
        let file = try XCTUnwrap(Self.boards().first)
        var kept = 0
        for type in ["blind", "buried", "micro"] {
            let board = try KiCadBoard.read(file)
            guard let box = board.edgeBounds else { return XCTFail("no outline") }
            // (somewhere along the edge clear of the parts, a step at a time)
            var placed: (KiCadPoint, String)?
            for i in 1..<40 where placed == nil {
                let p = KiCadPoint(box.minX + 1.5 + Double(i) * (box.maxX - box.minX - 3) / 40, box.minY + 1.5)
                let uuid = KiCadBoard.newUUID()
                let via = SExpr("via", SExpr("at", p.x, p.y), SExpr("size", 0.6), SExpr("drill", 0.3), SExpr("layers", "F.Cu", "B.Cu"),
                                SExpr("net", ""), SExpr("uuid", uuid))
                via.items.insert(SExpr(symbol: type), at: 1)
                let trial = board.copy()
                trial.addCopper(via)
                let session = BoardEditing(board: trial)
                guard session.startDrag(at: p, layer: "F.Cu") != nil else { continue }
                session.drag(to: KiCadPoint(p.x + 0.3, p.y + 0.4))
                guard let edit = session.fixDrag(at: KiCadPoint(p.x + 0.3, p.y + 0.4)) else {
                    session.cancelDrag()
                    continue
                }
                XCTAssertEqual(edit.name, "Drag Via")
                XCTAssertEqual(edit.removed, [uuid])
                let moved = try XCTUnwrap(edit.after.copperItems.first { $0.head == "via" && edit.added.contains($0.value("uuid") ?? "") })
                XCTAssertEqual(moved.text(at: 0), type, "the via dragged is \(type) still")
                placed = (p, uuid)
            }
            if placed != nil { kept += 1 }
        }
        XCTAssertEqual(kept, 3)
    }

    /// Tracks routed shoving what is in their way (KiCad's shove mode): the preview shows the tracks and vias pushed
    /// aside where they now go, and which of the board's it moved; the change takes those out and puts in the shoved;
    /// KiCad's DRC finds nothing wrong with what was routed and shoved
    func testATrackShovesWhatIsInItsWay() throws {
        var shoves = 0, shown = 0
        var finalBoards: [(URL, KiCadBoard)] = []
        for file in try Self.boards() {
            let board = try KiCadBoard.read(file)
            let session = BoardEditing(board: board, project: Self.project(file))
            session.mode = .shove
            for (a, b, layer) in BoardRoutingTests.pairs(session.router.world, seed: file.lastPathComponent) {
                let from = Self.mm(a), to = Self.mm(b)
                guard session.start(at: from, layer: session.layers[layer]) else { continue }
                XCTAssertEqual(session.router.mode, .shove)
                let before = session.board
                for t in [0.25, 0.5, 0.75] {
                    let preview = try XCTUnwrap(session.move(to: KiCadPoint(from.x + (to.x - from.x) * t + 0.3, from.y + (to.y - from.y) * t - 0.2)))
                    if !preview.moved.isEmpty {
                        shown += 1
                        XCTAssertFalse(preview.shovedTracks.isEmpty && preview.shovedVias.isEmpty, "what was shoved is shown where it goes")
                        for uuid in preview.moved { XCTAssertTrue(before.copperItems.contains { $0.value("uuid") == uuid }) }
                    }
                }
                session.move(to: to)
                guard let edit = session.fix(at: to) ?? session.stop() else { continue }
                if !edit.removed.isEmpty { shoves += 1 }
                for uuid in edit.removed { XCTAssertFalse(edit.after.copperItems.contains { $0.value("uuid") == uuid }) }
                for uuid in edit.added { XCTAssertTrue(edit.after.copperItems.contains { $0.value("uuid") == uuid }) }
            }
            finalBoards.append((file, session.board))
        }
        print("BoardEditingTests: \(shoves) tracks shoved others aside (\(shown) previews showed it)")
        XCTAssertGreaterThan(shoves, 0)
        XCTAssertGreaterThan(shown, 0)
        guard let kicad = KiCadInstallation.find(), kicad.major >= KiCadInstallation.minimumMajor else {
            if ProcessInfo.processInfo.environment["JSPICE_REQUIRE_KICAD"] != nil { return XCTFail("KiCad 10's kicad-cli is needed") }
            return
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-shove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for (file, board) in finalBoards {
            let copy = work.appendingPathComponent(file.lastPathComponent)
            try board.write(to: copy)
            let pro = file.deletingPathExtension().appendingPathExtension("kicad_pro")
            try? FileManager.default.copyItem(at: pro, to: copy.deletingPathExtension().appendingPathExtension("kicad_pro"))
            let original = Set(try KiCadBoard.read(file).copperItems.compactMap { $0.value("uuid") })
            let added = Set(board.copperItems.compactMap { $0.value("uuid") }).subtracting(original)
            let report = try KiCadFabrication(installation: kicad).drc(copy, refillZones: false)
            let ours = report.violations.filter { v in
                BoardRoutingTests.routerViolations.contains(v.type) && v.items.contains { added.contains($0.uuid) }
            }
            XCTAssert(ours.isEmpty, "\(file.lastPathComponent): " + ours.map { "\($0.type): \($0.description)" }.joined(separator: "; "))
        }
    }

    /// Tracks and vias dragged as KiCad's drag tool drags them, walking round and shoving what is in their way: a
    /// track by its middle, by its end (its corner), at free angles; a via with the tracks on it. The preview shows
    /// the dragged where it goes and which of the board's tracks it takes away; the change ("Drag Track", "Drag Via")
    /// takes those out and puts in the new; KiCad's DRC finds no clearance fault in what was dragged and shoved (their
    /// sizes are theirs as they were, some of them under these boards' minimums).
    func testTracksAndViasAreDraggedClearOfWhatIsInTheirWay() throws {
        var drags = 0, kept = 0, viaDrags = 0, shoves = 0, cornerDrags = 0
        var finalBoards: [(URL, KiCadBoard, BoardWorld)] = []
        for file in try Self.boards() {
            let session = BoardEditing(board: try KiCadBoard.read(file), project: Self.project(file))
            // (the board's tracks, and some more routed, to drag and to drag into)
            _ = session.routeConnections(most: 12)
            let world = session.router.world
            var rng = BoardRoutingTests.SplitMix(seed: UInt64(truncatingIfNeeded: file.lastPathComponent.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) }))
            let tracks = world.items.filter { $0.kind == .track && ($0.net ?? 0) != 0 && $0.a.distance($0.b) > 1_000_000 && $0.source != nil }
            let vias = world.items.filter { $0.kind == .via && ($0.net ?? 0) != 0 && $0.source != nil }
            // (a few of each, in an order of their own)
            func some(_ items: [WorldItem], _ count: Int) -> [WorldItem] {
                var items = items
                for i in items.indices.reversed() { items.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
                return Array(items.prefix(count))
            }
            let picks = some(tracks, 14) + some(vias, 5)
            for (k, w) in picks.enumerated() {
                // (the board as the drags before left it: the track or via still there?)
                guard let uuid = w.source, session.board.copperItems.contains(where: { $0.value("uuid") == uuid }) else { continue }
                session.mode = k % 3 == 1 ? .walkaround : .shove
                let layer = session.router.layerName(w.kind == .via ? w.layers.start : w.layer)
                // (into another net's track or via near by, mostly, to shove or walk round it; else across)
                let others = session.router.world.items.filter { o in
                    (o.kind == .track || o.kind == .via) && o.net != w.net
                        && (o.kind == .via ? o.layers : LayerRange(o.layer)).overlaps(w.kind == .via ? w.layers : LayerRange(w.layer))
                }
                func centre(_ o: WorldItem) -> IPoint { o.kind == .via ? o.a : IPoint((o.a.x + o.b.x) / 2, (o.a.y + o.b.y) / 2) }
                let grab: IPoint
                var way: IPoint
                if w.kind == .via {
                    grab = w.a
                    way = IPoint(700_000, -500_000)
                    let near = others.map { centre($0) - grab }.filter { $0.norm > 300_000 && $0.norm < 2_500_000 }
                    if k % 3 != 2, let v = near.min(by: { $0.norm < $1.norm }) { way = v }
                } else {
                    // (by its middle; or by its end, now and then)
                    let d = w.b - w.a
                    let n = (Double(d.x) * Double(d.x) + Double(d.y) * Double(d.y)).squareRoot()
                    let ux = Double(d.x) / n, uy = Double(d.y) / n
                    grab = k % 4 == 3 ? w.b : IPoint((w.a.x + w.b.x) / 2, (w.a.y + w.b.y) / 2)
                    way = IPoint(Int(-uy * 900_000), Int(ux * 900_000))
                    if k % 2 == 1 { way = -way }
                    // (onto the nearest, where it is nearest)
                    let onto = others.map { o in (o.kind == .via ? o.a : Seg(o.a, o.b).nearestPoint(grab)) - grab }
                        .filter { $0.norm > 300_000 && $0.norm < 5_000_000 }
                    if k != 5, let v = onto.min(by: { $0.norm < $1.norm }) { way = v }
                }
                let preview = try XCTUnwrap(session.startDrag(at: Self.mm(grab), layer: layer, freeAngle: k == 6), "\(uuid) to drag")
                XCTAssertTrue(session.isRouting)
                if w.kind == .via && session.router.isDraggingVia { viaDrags += 1 }
                if k % 4 == 3 { cornerDrags += 1 }
                drags += 1
                XCTAssertFalse(preview.violates)
                let before = session.board.copy()
                var last = preview
                for t in [0.4, 0.8, 1.0] {
                    last = try XCTUnwrap(session.drag(to: Self.mm(grab + IPoint(Int(Double(way.x) * t), Int(Double(way.y) * t)))))
                    for moved in last.moved { XCTAssertTrue(before.copperItems.contains { $0.value("uuid") == moved }) }
                }
                XCTAssertEqual(last.net, session.router.world.items.first { $0.source == uuid }.flatMap { $0.net.flatMap { world.netNames[$0] } })
                guard let edit = session.fixDrag(at: Self.mm(grab + way)) else {
                    // (could not get past what is in the way: the drag dropped)
                    session.cancelDrag()
                    XCTAssertFalse(session.isRouting)
                    continue
                }
                kept += 1
                XCTAssertFalse(session.isRouting)
                XCTAssertEqual(edit.name, session.router.isDraggingVia ? "Drag Via" : "Drag Track")
                XCTAssertTrue(edit.removed.contains(uuid) || !last.moved.contains(uuid))
                for uuid in edit.removed { XCTAssertFalse(edit.after.copperItems.contains { $0.value("uuid") == uuid }) }
                for uuid in edit.added { XCTAssertTrue(edit.after.copperItems.contains { $0.value("uuid") == uuid }) }
                // (another net's track or via taken away: shoved aside)
                func net(_ id: String) -> String? { edit.before.copperItems.first { $0.value("uuid") == id }?.value("net") }
                if edit.removed.contains(where: { net($0) != net(uuid) }) { shoves += 1 }
            }
            finalBoards.append((file, session.board, session.router.world))
        }
        print("BoardEditingTests: \(kept) of \(drags) drags kept (\(viaDrags) of vias, \(cornerDrags) by a corner), \(shoves) shoving")
        XCTAssertGreaterThan(kept, 0)
        XCTAssertGreaterThan(viaDrags, 0)
        XCTAssertGreaterThan(shoves, 0)
        guard let kicad = KiCadInstallation.find(), kicad.major >= KiCadInstallation.minimumMajor else {
            if ProcessInfo.processInfo.environment["JSPICE_REQUIRE_KICAD"] != nil { return XCTFail("KiCad 10's kicad-cli is needed") }
            return
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for (file, board, world) in finalBoards {
            let copy = work.appendingPathComponent(file.lastPathComponent)
            try board.write(to: copy)
            let pro = file.deletingPathExtension().appendingPathExtension("kicad_pro")
            try? FileManager.default.copyItem(at: pro, to: copy.deletingPathExtension().appendingPathExtension("kicad_pro"))
            let original = Set(try KiCadBoard.read(file).copperItems.compactMap { $0.value("uuid") })
            let added = Set(board.copperItems.compactMap { $0.value("uuid") }).subtracting(original)
            let report = try KiCadFabrication(installation: kicad).drc(copy, refillZones: false)
            let ours = report.violations.filter { v in
                guard Self.clearanceViolations.contains(v.type) && v.items.contains(where: { added.contains($0.uuid) }) else { return false }
                // (a hole clearance of 0: KiCad's router takes tracks along a hole's very edge, which its DRC finds touching
                // it, as BoardRoutingTests counts apart; one cutting into the hole is wrong)
                if v.type == "hole_clearance", v.description.contains("hole clearance 0 mm"),
                   let overlap = BoardRoutingTests.holeOverlap(v, board: board, world: world), overlap < 1_000 {
                    return false
                }
                return true
            }
            XCTAssert(ours.isEmpty, "\(file.lastPathComponent): " + ours.map { "\($0.type): \($0.description)" }.joined(separator: "; "))
        }
    }

    /// Differential pairs routed as KiCad's Route Differential Pair routes them (BoardEditing's startPair) on the
    /// boards of Fixtures/pairboards (boards.py --pairs): each pair from the connector's pads to the chip's, the
    /// pointer taken there by a way of its own, walking round and shoving, at the width and gap of its net class; and
    /// refused where KiCad refuses one (a pad of a net that is no pair's, nothing under the pointer). kicad-cli's DRC
    /// finds no clearance, crossing or short with what the pairs put on the boards.
    func testDifferentialPairsAreRoutedAsKiCadsRouterRoutesThem() throws {
        let folder = try XCTUnwrap(Bundle.module.url(forResource: "pairboards", withExtension: nil, subdirectory: "Fixtures"))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
        var pairs = 0, finished = 0, shoving = 0, vias = 0
        var finalBoards: [(URL, KiCadBoard)] = []
        for file in files {
            let project = Self.project(file)
            let session = BoardEditing(board: try KiCadBoard.read(file), project: project)
            let world = session.router.world
            func pads(_ net: String, _ footprint: String) -> [WorldItem] {
                world.items.filter { $0.kind == .pad && $0.footprint == footprint && $0.net.flatMap { world.netNames[$0] } == net }
            }
            // (the positive nets whose negative nets are the board's too)
            let positives = world.netNames.values.filter { name in
                let (polarity, coupled) = WorldResolver.matchDpSuffix(name)
                return polarity == 1 && world.netNames.values.contains(coupled)
            }.sorted()
            XCTAssertEqual(positives.count, 2, file.lastPathComponent)
            for (k, positive) in positives.enumerated() {
                let negative = WorldResolver.matchDpSuffix(positive).complement
                guard let from = pads(negative, "J1").first, let to = pads(positive, "U1").first,
                      let start = from.pos, let end = to.pos else { return XCTFail("\(file.lastPathComponent): \(positive)'s pads") }
                session.mode = k == 0 ? .walkaround : .shove
                let layer = session.router.layerName(to.layers.start)
                let started = try XCTUnwrap(session.startPair(at: Self.mm(start), layer: layer),
                                            "\(file.lastPathComponent) \(positive): \(session.failureReason)")
                pairs += 1
                XCTAssertTrue(session.isRoutingPair)
                XCTAssertEqual(started.positiveNet, positive)
                XCTAssertEqual(started.negativeNet, negative)
                // (the net class's diff pair width and gap)
                let nc = world.netClasses.effective(positive)
                XCTAssertEqual(started.width, Double(max(world.minTrackWidth, nc.diffPairWidth ?? 0)) / 1e6)
                XCTAssertEqual(started.gap, Double(max(world.rules.clearance, nc.diffPairGap ?? 0)) / 1e6)
                // (out along the way and on to the chip's pads; the first pair, walking round, down to the other side
                // through vias in the middle and back up further on. Not the second, shoving: a shove that pushes the
                // pair's vias aside leaves KiCad's pair placer committing them where they were, off its tracks.)
                let before = session.board.copy()
                let other = session.router.layerName(to.layers.start == 0 ? world.copperLayers - 1 : 0)
                var preview = started
                var stuck = false
                for (i, t) in [0.3, 0.55, 0.8].enumerated() where !stuck {
                    let p = IPoint(start.x + Int(Double(end.x - start.x) * t), start.y + Int(Double(end.y - start.y) * t)
                                   + (i == 1 ? 1_500_000 : 0))
                    preview = try XCTUnwrap(session.movePair(to: Self.mm(p)))
                    if k == 1 && preview.clear && !preview.positive.isEmpty {
                        // (shoving: fixed where it got clear, what it shoved with it, and on from there)
                        XCTAssertNil(session.fix(at: Self.mm(p)))
                    }
                    if k == 0 && i > 0 {
                        preview = try XCTUnwrap(session.placePairVias(to: i == 1 ? other : layer))
                        XCTAssertNotNil(preview.positiveVia)
                        XCTAssertNil(session.fix(at: Self.mm(p)))
                        // (the vias not placed, the pair not clear there: it is left there, as with Escape; on to the
                        // pads, KiCad's would put its vias on them, as close as they are)
                        stuck = session.router.router.isPlacingVia
                    }
                }
                for moved in preview.moved { XCTAssertTrue(before.copperItems.contains { $0.value("uuid") == moved }) }
                if !stuck { preview = try XCTUnwrap(session.movePair(to: Self.mm(end))) }
                let edit: BoardEditing.Edit
                if !stuck, let done = session.fix(at: Self.mm(end)) {
                    finished += 1
                    edit = done
                } else {
                    // (not there: what is fixed of it kept, as Escape keeps it)
                    guard let kept = session.stop() else { continue }
                    edit = kept
                }
                XCTAssertFalse(session.isRouting)
                XCTAssertEqual(edit.name, "Route Differential Pair")
                for uuid in edit.removed { XCTAssertFalse(edit.after.copperItems.contains { $0.value("uuid") == uuid }) }
                for uuid in edit.added { XCTAssertTrue(edit.after.copperItems.contains { $0.value("uuid") == uuid }) }
                // (the pair's two nets' tracks; another net's taken away: shoved aside)
                let nets = Set(edit.after.copperItems.filter { edit.added.contains($0.value("uuid") ?? "") }.compactMap { $0.value("net") })
                XCTAssertTrue(nets.isSubset(of: [positive, negative]) || !edit.removed.isEmpty, "\(nets)")
                XCTAssertTrue(nets.contains(positive) && nets.contains(negative), "\(file.lastPathComponent) \(positive): \(nets)")
                func net(_ id: String) -> String? { edit.before.copperItems.first { $0.value("uuid") == id }?.value("net") }
                if edit.removed.contains(where: { ![positive, negative].contains(net($0)) }) { shoving += 1 }
                vias += edit.after.copperItems.filter { $0.head == "via" && edit.added.contains($0.value("uuid") ?? "") }.count
            }
            // (refused as KiCad refuses: a pad of a net that is no pair's; nothing under the pointer)
            if let single = world.items.first(where: { $0.kind == .pad && $0.net.flatMap { world.netNames[$0] } == "GND" }), let p = single.pos {
                XCTAssertNil(session.startPair(at: Self.mm(p), layer: session.router.layerName(single.layers.start)))
                XCTAssertTrue(session.failureReason.hasPrefix("Unable to find complementary differential pair nets."), session.failureReason)
            }
            XCTAssertNil(session.startPair(at: KiCadPoint(101.3, 51.3), layer: "F.Cu"))
            XCTAssertEqual(session.failureReason, "Cannot start a differential pair in the middle of nowhere.")
            XCTAssertFalse(session.isRouting)
            finalBoards.append((file, session.board))
        }
        print("BoardEditingTests: \(finished) of \(pairs) pairs finished on the chip's pads, \(shoving) shoving, \(vias) vias")
        XCTAssertGreaterThan(finished, 0)
        guard let kicad = KiCadInstallation.find(), kicad.major >= KiCadInstallation.minimumMajor else {
            if ProcessInfo.processInfo.environment["JSPICE_REQUIRE_KICAD"] != nil { return XCTFail("KiCad 10's kicad-cli is needed") }
            return
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-pairs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for (file, board) in finalBoards {
            let copy = work.appendingPathComponent(file.lastPathComponent)
            try board.write(to: copy)
            let pro = file.deletingPathExtension().appendingPathExtension("kicad_pro")
            try? FileManager.default.copyItem(at: pro, to: copy.deletingPathExtension().appendingPathExtension("kicad_pro"))
            let original = Set(try KiCadBoard.read(file).copperItems.compactMap { $0.value("uuid") })
            let added = Set(board.copperItems.compactMap { $0.value("uuid") }).subtracting(original)
            let report = try KiCadFabrication(installation: kicad).drc(copy, refillZones: false)
            let ours = report.violations.filter { v in
                Self.clearanceViolations.contains(v.type) && v.items.contains(where: { added.contains($0.uuid) })
            }
            XCTAssert(ours.isEmpty, "\(file.lastPathComponent): " + ours.map { "\($0.type): \($0.description)" }.joined(separator: "; "))
        }
    }

    /// What KiCad's DRC finds of copper too close to other copper, to holes or to the edge
    static let clearanceViolations: Set<String> = ["clearance", "hole_clearance", "copper_edge_clearance", "hole_to_hole",
                                                   "tracks_crossing", "shorting_items", "holes_co_located"]

    /// The pointer snapped as KiCad's router tool snaps it (TOOL_BASE::snapToItem): to a pad's centre; to a track's
    /// end within half its width of it; else to a point of the track by the grid; else to the grid
    func testThePointerSnapsAsKiCadsRouterToolSnapsIt() throws {
        var tracks = 0
        for file in try Self.boards() {
            let session = BoardEditing(board: try KiCadBoard.read(file), project: Self.project(file))
            let router = session.router
            let world = router.world
            for w in world.items where w.kind == .track && w.net != nil && w.a.distance(w.b) > Double(4 * router.grid) {
                let (point, item) = router.startPoint(at: w.a + IPoint(w.width / 4, 0), layer: w.layer)
                guard let segment = item as? Segment, segment.seg.a == w.a || segment.seg.b == w.a else { continue }
                tracks += 1
                XCTAssertEqual(point, w.a, "near its end: the track's end")
                let middle = IPoint((w.a.x + w.b.x) / 2 + 7_000, (w.a.y + w.b.y) / 2 - 3_000)
                let (on, picked) = router.startPoint(at: middle, layer: w.layer)
                if let s = picked as? Segment, s.seg.a == w.a || s.seg.b == w.a {
                    XCTAssertLessThanOrEqual(s.seg.squaredDistance(on), 4, "by its middle: a point on the track")
                }
            }
            for w in world.items where w.kind == .pad && w.net != nil {
                guard let pos = w.pos, let pad = router.startPoint(at: pos + IPoint(10_000, -10_000), layer: w.layers.start).item as? Solid,
                      pad.pos == pos else { continue }
                XCTAssertEqual(router.startPoint(at: pos + IPoint(10_000, -10_000), layer: w.layers.start).point, pos, "on a pad: its centre")
            }
            // nothing there: the grid
            let empty = IPoint(-50_123_456, -50_987_654)
            XCTAssertNil(router.startPoint(at: empty, layer: 0).item)
            XCTAssertEqual(router.startPoint(at: empty, layer: 0).point, IPoint(-50_100_000, -51_000_000))
        }
        XCTAssertGreaterThan(tracks, 0)
    }

    /// Footprints moved, turned and turned over, each a change of its own; the router then sees their pads where they
    /// went
    func testFootprintsArePlaced() throws {
        let file = try XCTUnwrap(Self.boards().first)
        let session = BoardEditing(board: try KiCadBoard.read(file), project: Self.project(file))
        let footprint = try XCTUnwrap(session.board.footprints.first { $0.pads.contains { $0.isCopper && $0.net != nil } })
        let uuid = footprint.uuid, start = footprint.position, turn = footprint.rotation
        let pad = try XCTUnwrap(footprint.pads.first { $0.isCopper && $0.net != nil })
        let offset = KiCadPoint(pad.position.x - start.x, pad.position.y - start.y)

        let moved = try XCTUnwrap(session.moveFootprint(uuid, to: KiCadPoint(start.x + 2.5, start.y - 1.25)))
        XCTAssertEqual(moved.footprints, [uuid])
        XCTAssertEqual(moved.added, [])
        XCTAssertTrue(moved.name.hasPrefix("Move"))
        let now = try XCTUnwrap(moved.after.footprint(uuid: uuid))
        XCTAssertEqual(now.position.x, start.x + 2.5, accuracy: 1e-9)
        XCTAssertEqual(now.rotation, turn)
        XCTAssertEqual(try XCTUnwrap(moved.before.footprint(uuid: uuid)).position, start, "the board before it is as it was")
        // the router sees the pad where it went
        let there = KiCadPoint(start.x + 2.5 + offset.x, start.y - 1.25 + offset.y)
        let layer = pad.layers.contains("B.Cu") && !pad.layers.contains("F.Cu") && !pad.layers.contains("*.Cu") ? "B.Cu" : "F.Cu"
        XCTAssertTrue(session.router.startPoint(at: BoardEditing.nm(there), layer: session.router.layer(layer) ?? 0).item is Solid)
        XCTAssertNil(session.moveFootprint(uuid, to: now.position), "not moved: no change")

        let rotated = try XCTUnwrap(session.rotateFootprint(uuid))
        XCTAssertEqual(try XCTUnwrap(rotated.after.footprint(uuid: uuid)).rotation,
                       (turn + 90).truncatingRemainder(dividingBy: 360) > 180 ? turn + 90 - 360 : turn + 90, accuracy: 1e-9)
        XCTAssertEqual(rotated.before.text, moved.after.text)

        let side = now.layer
        let flipped = try XCTUnwrap(session.flipFootprint(uuid))
        XCTAssertNotEqual(try XCTUnwrap(flipped.after.footprint(uuid: uuid)).layer, side)
        XCTAssertEqual(session.board.text, flipped.after.text)
    }

    /// Every connection routed in one go: one change, the connections left fewer
    func testEveryConnectionIsRoutedAsOneChange() throws {
        let file = try XCTUnwrap(Self.boards().last)
        let board = try KiCadBoard.read(file)
        let session = BoardEditing(board: board, project: Self.project(file))
        let before = KiCadConnectivity(board).ratsnest().count
        let routed = session.routeConnections()
        print("BoardEditingTests: \(routed.routed.count) of \(before) connections routed, \(routed.left) left")
        XCTAssertFalse(routed.routed.isEmpty)
        XCTAssertLessThan(routed.left, before)
        let edit = try XCTUnwrap(routed.edit)
        XCTAssertEqual(edit.before.text, board.text)
        XCTAssertEqual(edit.after.text, session.board.text)
        XCTAssertFalse(edit.added.isEmpty)
        XCTAssertFalse(session.isRouting)
        // only one net, and nothing on a net left out
        let again = BoardEditing(board: board, project: Self.project(file))
        let net = try XCTUnwrap(KiCadConnectivity(board).ratsnest().first?.net)
        let one = again.routeConnections(nets: [net])
        XCTAssertTrue((one.routed + one.failed).allSatisfy { $0.hasPrefix(net + ":") })
        XCTAssertTrue(again.routeConnections(skip: Set(KiCadConnectivity(board).ratsnest().map(\.net))).routed.isEmpty)
    }

    /// One line of the ratsnest routed, as a click on it routes it: that connection made, as one change
    func testOneConnectionIsRouted() throws {
        let file = try XCTUnwrap(Self.boards().first)
        let board = try KiCadBoard.read(file)
        let session = BoardEditing(board: board, project: Self.project(file))
        let wires = KiCadConnectivity(board).ratsnest()
        var routed = 0
        for wire in wires {
            let before = session.board.text
            guard let edit = session.routeConnection(wire) else {
                XCTAssertEqual(session.board.text, before, "a connection not routed leaves the board as it was")
                continue
            }
            routed += 1
            XCTAssertEqual(edit.name, "Route Connection")
            XCTAssertEqual(edit.before.text, before)
            XCTAssertEqual(edit.after.text, session.board.text)
            XCTAssertFalse(edit.added.isEmpty)
            XCTAssertFalse(session.isRouting)
            let left = KiCadConnectivity(session.board).ratsnest()
            XCTAssertFalse(left.contains { $0.net == wire.net && Set([$0.from, $0.to]) == Set([wire.from, wire.to]) },
                           "\(wire.net) \(wire.ends) is routed")
        }
        print("BoardEditingTests: \(routed) of \(wires.count) connections routed one at a time")
        XCTAssertGreaterThan(routed, 0)
    }

    /// Each change filling the board's zones again (refillsZones): a ground pour added and filled with it, then a
    /// track taken away and the pour filled again round where it was; each fill KiCad's own, where KiCad is installed
    /// (it fills the same board, and its fills are compared point for point)
    func testEachChangeFillsTheZonesAgain() throws {
        let kicad = KiCadInstallation.find().flatMap { $0.major >= KiCadInstallation.minimumMajor ? $0 : nil }
        var checked = 0, compared = 0
        for file in try Self.boards().prefix(4) {
            let session = BoardEditing(board: try KiCadBoard.read(file), project: Self.project(file))
            session.refillsZones = true
            guard let net = session.groundNets.first, let pour = session.addPour(net: net, layers: ["B.Cu"]) else { continue }
            XCTAssertTrue(pour.refilled)
            let zone = try XCTUnwrap(pour.after.zones.first { $0.uuid == pour.zones.first })
            XCTAssertFalse(zone.fills.isEmpty, "\(file.lastPathComponent): the pour filled as it is added")
            XCTAssertEqual(session.board.zones.first { $0.uuid == zone.uuid }?.fills.count, zone.fills.count,
                           "the router goes on from the board as filled")
            var edits = [pour]
            if let track = pour.after.tracks.first(where: { $0.layer == "B.Cu" && $0.net != net }) ?? pour.after.tracks.first,
               let removed = session.remove([track.uuid]) {
                XCTAssertTrue(removed.refilled)
                edits.append(removed)
            }
            checked += edits.count
            guard let kicad else { continue }
            for edit in edits {
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-refill-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: work) }
                let copy = work.appendingPathComponent(file.lastPathComponent)
                try edit.after.write(to: copy)
                try? FileManager.default.copyItem(at: file.deletingPathExtension().appendingPathExtension("kicad_pro"),
                                                  to: copy.deletingPathExtension().appendingPathExtension("kicad_pro"))
                try KiCadFabrication(installation: kicad).fillZones(copy)
                let theirs = try KiCadBoard.read(copy)
                for ours in edit.after.zones where !ours.isRuleArea {
                    let k = try XCTUnwrap(theirs.zones.first { $0.uuid == ours.uuid })
                    XCTAssertTrue(ours.fills.map(\.layer) == k.fills.map(\.layer) && ours.fills.map(\.points) == k.fills.map(\.points),
                                  "\(file.lastPathComponent) \(edit.name): \(ours.net)'s fill is not KiCad's")
                    compared += 1
                }
            }
        }
        print("BoardEditingTests: \(checked) changes filling the zones again, \(compared) fills compared with KiCad's")
        XCTAssertGreaterThan(checked, 0)
    }

    /// A ground pour added, filled by KiCad, and taken away again
    func testAPourIsAddedAndFilledByKiCad() throws {
        let file = try XCTUnwrap(Self.boards().first)
        let session = BoardEditing(board: try KiCadBoard.read(file), project: Self.project(file))
        let net = try XCTUnwrap(session.groundNets.first ?? session.router.world.netNames.values.sorted().first)
        let edit = try XCTUnwrap(session.addPour(net: net, layers: ["B.Cu"]))
        XCTAssertEqual(edit.zones.count, 1)
        let zone = try XCTUnwrap(edit.after.zones.first { $0.uuid == edit.zones[0] })
        XCTAssertEqual(zone.net, net)
        XCTAssertEqual(zone.layers, ["B.Cu"])
        XCTAssertEqual(zone.outline.count, 4)
        XCTAssertTrue(zone.fills.isEmpty)
        // KiCad reads it, fills it and saves the board
        if let kicad = KiCadInstallation.find(), kicad.major >= KiCadInstallation.minimumMajor {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-pour-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let copy = work.appendingPathComponent(file.lastPathComponent)
            try edit.after.write(to: copy)
            try? FileManager.default.copyItem(at: file.deletingPathExtension().appendingPathExtension("kicad_pro"),
                                              to: copy.deletingPathExtension().appendingPathExtension("kicad_pro"))
            try KiCadFabrication(installation: kicad).fillZones(copy)
            let filled = try KiCadBoard.read(copy)
            let back = try XCTUnwrap(filled.zones.first { $0.uuid == zone.uuid })
            XCTAssertFalse(back.fills.isEmpty, "KiCad filled the pour")
            XCTAssertEqual(back.net, net)
        }
        let removed = try XCTUnwrap(session.removeZones([zone.uuid]))
        XCTAssertEqual(removed.zones, [zone.uuid])
        XCTAssertFalse(removed.after.zones.contains { $0.uuid == zone.uuid })
    }

    /// The outline drawn round the parts: drawn where there was none, then drawn again round a part moved out, with
    /// the pour drawn to it
    func testTheOutlineIsFittedToTheParts() throws {
        let file = try XCTUnwrap(Self.boards().first)
        let board = try KiCadBoard.read(file)
        for node in board.edgeDrawings { board.root.remove(node) }
        let session = BoardEditing(board: board, project: Self.project(file))
        let drawn = try XCTUnwrap(session.fitOutline())
        XCTAssertTrue(drawn.outline)
        XCTAssertEqual(drawn.after.edgeDrawings.count, 1)
        XCTAssertNil(session.fitOutline(), "already round the parts")
        let pour = try XCTUnwrap(session.addPour(net: try XCTUnwrap(session.router.world.netNames.values.sorted().first), layers: ["B.Cu"]))
        let edge = try XCTUnwrap(pour.after.edgeBounds)
        let footprint = try XCTUnwrap(session.board.footprints.first)
        _ = try XCTUnwrap(session.moveFootprints([footprint.uuid], by: KiCadPoint(edge.maxX - footprint.position.x + 20, 0)))
        let fitted = try XCTUnwrap(session.fitOutline())
        let box = try XCTUnwrap(fitted.after.edgeBounds)
        XCTAssertGreaterThan(box.maxX, edge.maxX + 15)
        XCTAssertEqual(box.maxX, box.maxX.rounded(), "on whole millimetres")
        let zone = try XCTUnwrap(fitted.after.zones.first { $0.uuid == pour.zones.first })
        XCTAssertEqual(zone.outline.map(\.x).max(), box.maxX, "the pour follows the outline")
        // carried onto a copy of the board as it was before
        let elsewhere = fitted.before.copy()
        elsewhere.carryOutline(from: fitted.before, to: fitted.after)
        elsewhere.carryZones(from: fitted.before, to: fitted.after)
        XCTAssertEqual(elsewhere.edgeBounds?.maxX, box.maxX)
        XCTAssertEqual(elsewhere.zones.first { $0.uuid == zone.uuid }?.outline.map(\.x).max(), box.maxX)
    }

    /// The outline given a size and rounded corners: KiCad's rectangle with a corner radius, whose corners the
    /// router's world has as KiCad's has them (arcs, BoardWorldTests checking them against KiCad's), and which
    /// KiCad's DRC takes for a good outline
    func testTheOutlineIsSizedAndRounded() throws {
        let file = try XCTUnwrap(Self.boards().first)
        let board = try KiCadBoard.read(file)
        // (a footprint's own lines on the edge, which leave KiCad an outline not closed, taken away)
        for footprint in board.root.items where footprint.head == "footprint" {
            footprint.items.removeAll { ($0.head ?? "").hasPrefix("fp_") && $0.value("layer") == "Edge.Cuts" }
        }
        let session = BoardEditing(board: board, project: Self.project(file))
        let (was, _) = try XCTUnwrap(BoardEditing.outlineRectangle(session.board))
        let edit = try XCTUnwrap(session.setOutline(width: was.width + 4, height: was.height + 2, radius: 3))
        XCTAssertEqual(edit.name, "Change Board Outline")
        XCTAssertTrue(edit.outline)
        let (box, radius) = try XCTUnwrap(BoardEditing.outlineRectangle(edit.after))
        XCTAssertEqual(box, KiCadBox(minX: was.minX, minY: was.minY, maxX: was.minX + was.width + 4, maxY: was.minY + was.height + 2))
        XCTAssertEqual(radius, 3)
        XCTAssertEqual(edit.after.outline.first?.cornerRadius, 3)
        let uuid = try XCTUnwrap(edit.after.root.items.first { $0.head == "gr_rect" }?.value("uuid"))
        let edges = session.router.world.items.filter { $0.kind == .edge && $0.source == uuid }.compactMap(\.shape)
        XCTAssertEqual(edges.filter { if case .arc = $0 { return true } else { return false } }.count, 4, "its corners' arcs")
        XCTAssertEqual(edges.filter { if case .segment = $0 { return true } else { return false } }.count, 4, "its sides")
        XCTAssertNil(session.setOutline(width: was.width + 4, height: was.height + 2, radius: 3), "already so")
        let square = try XCTUnwrap(session.setOutline(width: was.width + 4, height: was.height + 2, radius: 0))
        XCTAssertNil(square.after.root.items.first { $0.head == "gr_rect" }?["radius"])
        // KiCad reads the rounded outline as a board's edge
        if let kicad = KiCadInstallation.find(), kicad.major >= KiCadInstallation.minimumMajor {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-outline-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let copy = work.appendingPathComponent(file.lastPathComponent)
            try edit.after.write(to: copy)
            let report = try KiCadFabrication(installation: kicad).drc(copy, refillZones: false)
            XCTAssertFalse(report.violations.contains { $0.type == "invalid_outline" }, report.violations.map(\.description).joined(separator: "; "))
        }
    }

    /// Mounting holes from KiCad's library in the outline's corners: board-only parts, numbered as KiCad numbers holes,
    /// in the router's world (their unplated holes), carried onto the board's file as it then is, and read by KiCad
    func testMountingHolesGoInTheCorners() throws {
        guard let kicad = KiCadInstallation.find(), kicad.major >= KiCadInstallation.minimumMajor else {
            if ProcessInfo.processInfo.environment["JSPICE_REQUIRE_KICAD"] != nil { return XCTFail("KiCad 10 is needed") }
            throw XCTSkip("KiCad's footprint libraries are not installed")
        }
        let (_, libID, inset) = try XCTUnwrap(BoardEditing.mountingHoles.first { $0.screw == "M3" })
        let footprint = try KiCadFootprintLibrary(installation: kicad).footprint(libID)
        let file = try XCTUnwrap(Self.boards().first)
        let board = try KiCadBoard.read(file)
        for f in board.root.items where f.head == "footprint" {
            f.items.removeAll { ($0.head ?? "").hasPrefix("fp_") && $0.value("layer") == "Edge.Cuts" }
        }
        let session = BoardEditing(board: board, project: Self.project(file))
        let holesBefore = session.router.world.items.filter { $0.kind == .pad && $0.npth }.count
        let edit = try XCTUnwrap(session.addMountingHoles(footprint, libID: libID, inset: inset))
        XCTAssertEqual(edit.name, "Add Mounting Holes")
        XCTAssertEqual(edit.footprints.count, 4)
        let holes = edit.after.footprints.filter { edit.footprints.contains($0.uuid) }
        XCTAssertEqual(Set(holes.map(\.reference)), ["H1", "H2", "H3", "H4"])
        XCTAssertTrue(holes.allSatisfy { $0.attributes.contains("board_only") && $0.libID == libID })
        let (box, _) = try XCTUnwrap(edit.after.outlineRectangle)
        XCTAssertTrue(holes.contains { $0.position == KiCadPoint(box.minX + inset, box.minY + inset) })
        XCTAssertTrue(holes.contains { $0.position == KiCadPoint(box.maxX - inset, box.maxY - inset) })
        XCTAssertEqual(session.router.world.items.filter { $0.kind == .pad && $0.npth }.count, holesBefore + 4)
        XCTAssertNil(session.addMountingHoles(footprint, libID: libID, inset: inset), "each corner has one")
        // carried onto a copy of the board as it was before
        let elsewhere = edit.before.copy()
        elsewhere.carryFootprints(from: edit.before, to: edit.after)
        XCTAssertEqual(Set(elsewhere.footprints.map(\.uuid)), Set(edit.after.footprints.map(\.uuid)))
        // KiCad reads them: no hole too near the edge or another's copper
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-holes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let copy = work.appendingPathComponent(file.lastPathComponent)
        try edit.after.write(to: copy)
        try? FileManager.default.copyItem(at: file.deletingPathExtension().appendingPathExtension("kicad_pro"),
                                          to: copy.deletingPathExtension().appendingPathExtension("kicad_pro"))
        let report = try KiCadFabrication(installation: kicad).drc(copy, refillZones: false)
        let refs = Set(holes.map(\.reference))
        let theirs = report.violations.filter { v in
            ["copper_edge_clearance", "hole_clearance", "hole_to_hole", "clearance"].contains(v.type)
                && v.items.contains { item in refs.contains { item.description.contains("of " + $0) } }
        }
        XCTAssert(theirs.isEmpty, theirs.map(\.description).joined(separator: "; "))
    }

    /// Stitching vias for a net poured on both sides: where KiCad filled both pours, clear of everything else as the
    /// router keeps a via, free vias; KiCad fills the pours round them again and its DRC finds nothing wrong with them
    func testPoursAreStitched() throws {
        guard let kicad = KiCadInstallation.find(), kicad.major >= KiCadInstallation.minimumMajor else {
            if ProcessInfo.processInfo.environment["JSPICE_REQUIRE_KICAD"] != nil { return XCTFail("KiCad 10 is needed") }
            throw XCTSkip("no kicad-cli")
        }
        let file = try XCTUnwrap(Self.boards().last)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-stitch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let copy = work.appendingPathComponent(file.lastPathComponent)
        try? FileManager.default.copyItem(at: file.deletingPathExtension().appendingPathExtension("kicad_pro"),
                                          to: copy.deletingPathExtension().appendingPathExtension("kicad_pro"))
        let session = BoardEditing(board: try KiCadBoard.read(file), project: Self.project(file))
        let net = try XCTUnwrap(session.groundNets.first ?? session.router.world.netNames.values.sorted().first)
        XCTAssertNil(session.stitchVias(net: net), "no pours yet")
        let poured = try XCTUnwrap(session.addPour(net: net, layers: [try XCTUnwrap(session.layers.first), try XCTUnwrap(session.layers.last)]))
        try poured.after.write(to: copy)
        let fabrication = KiCadFabrication(installation: kicad)
        try fabrication.fillZones(copy)
        session.load(try KiCadBoard.read(copy))
        let edit = try XCTUnwrap(session.stitchVias(net: net))
        XCTAssertEqual(edit.name, "Stitch \(net) Pours")
        let vias = edit.after.vias.filter { edit.added.contains($0.uuid) }
        XCTAssertFalse(vias.isEmpty)
        XCTAssertTrue(vias.allSatisfy { $0.net == net && $0.node.value("free") == "yes" })
        print("BoardEditingTests: \(vias.count) stitching vias for \(net)")
        XCTAssertNil(session.stitchVias(net: net), "stitched already")
        try edit.after.write(to: copy)
        try fabrication.fillZones(copy)
        let report = try fabrication.drc(copy, refillZones: false)
        let added = Set(edit.added)
        let wrong = report.violations.filter { v in
            (BoardRoutingTests.routerViolations.contains(v.type) || v.type == "via_dangling") && v.items.contains { added.contains($0.uuid) }
        }
        XCTAssert(wrong.isEmpty, wrong.map { "\($0.type): \($0.description) — \($0.items.map(\.description))" }.joined(separator: "; "))
    }

    /// A keepout zone and another net's arc track in the way of a track: kept clear of (the keepout cut into KiCad's
    /// triangles, the arc the port's stand-in for KiCad's arc items)
    func testKeepoutsAndArcTracksAreKeptClearOf() throws {
        let file = try XCTUnwrap(Self.boards().first)
        let board = try KiCadBoard.read(file)
        for node in board.copperItems { board.root.remove(node) }
        let box = try XCTUnwrap(board.edgeBounds)
        // a clear run along the board's middle: a keepout across it on the left, an arc of another net on the right
        let y = (box.minY + box.maxY) / 2, x0 = box.minX + 3, x1 = box.maxX - 3
        let kx = x0 + (x1 - x0) * 0.3, ax = x0 + (x1 - x0) * 0.7
        board.root.items.append(try SExpr.parse("""
            (zone (net 0) (net_name "") (layers "F.Cu" "B.Cu") (uuid "keepout-1") (hatch edge 0.5)
              (connect_pads (clearance 0)) (min_thickness 0.25) (filled_areas_thickness no)
              (keepout (tracks not_allowed) (vias not_allowed) (pads allowed) (copperpour allowed) (footprints allowed))
              (fill (thermal_gap 0.5) (thermal_bridge_width 0.5))
              (polygon (pts (xy \(kx - 1) \(y - 2)) (xy \(kx + 1) \(y - 2)) (xy \(kx + 1) \(y + 2)) (xy \(kx - 1) \(y + 2)))))
            """))
        let net = try XCTUnwrap(KiCadConnectivity(board).ratsnest().first?.net)
        board.addCopper(SExpr("arc", SExpr("start", ax, y - 2), SExpr("mid", ax + 1, y), SExpr("end", ax, y + 2), SExpr("width", 0.3),
                              SExpr("layer", "F.Cu"), board.netList(net, pad: false), SExpr("uuid", "arc-1")))
        let router = BoardRouter(board: board)
        XCTAssertFalse(router.unsupported.contains { $0.hasPrefix("keepout zone") })
        XCTAssertFalse(router.unsupported.contains { $0.hasPrefix("arc track") })
        // (the rectangle in two triangles, on each of its two layers)
        let zone = try XCTUnwrap(router.world.items.firstIndex { $0.kind == .keepout })
        XCTAssertEqual(router.world.items[zone].zoneLayers, [0, 1])
        XCTAssertTrue(router.iface.malformedZones.isEmpty)
        let triangles = try XCTUnwrap(router.router.world).index.all.filter { router.iface.worldItem($0)?.kind == .keepout }
        XCTAssertEqual(triangles.map(\.layer), [0, 0, 1, 1])
        let a = IPoint(Int(x0 * 1e6), Int(y * 1e6)), b = IPoint(Int(x1 * 1e6), Int(y * 1e6))
        guard router.start(at: a, layer: 0, width: 200_000) else { return XCTFail("no start") }
        router.move(to: b)
        let p = try XCTUnwrap(router.preview)
        let points = p.tail.points + p.head.points
        XCTAssertGreaterThan(points.count, 2, "the track goes round")
        let keepout = Shape.simple(LineChain([IPoint(Int((kx - 1) * 1e6), Int((y - 2) * 1e6)), IPoint(Int((kx + 1) * 1e6), Int((y - 2) * 1e6)),
                                              IPoint(Int((kx + 1) * 1e6), Int((y + 2) * 1e6)), IPoint(Int((kx - 1) * 1e6), Int((y + 2) * 1e6))], closed: true))
        let arc = Shape.arc(ShapeArc(start: IPoint(Int(ax * 1e6), Int((y - 2) * 1e6)), mid: IPoint(Int((ax + 1) * 1e6), Int(y * 1e6)),
                                     end: IPoint(Int(ax * 1e6), Int((y + 2) * 1e6)), width: 300_000))
        for (u, v) in zip(points, points.dropFirst()) {
            let track = Shape.segment(Seg(u, v), width: 200_000)
            XCTAssertFalse(track.collide(keepout, clearance: 0), "through the keepout: \(u) \(v)")
            XCTAssertFalse(track.collide(arc, clearance: 0), "over the arc: \(u) \(v)")
        }
    }

    /// Arc tracks on a board (Fixtures/arcboards, boards.py --arcs): a track routed with rounded corners puts its
    /// corners in as arc tracks, as KiCad writes them; the pointer snaps to an arc's end, and a track started there
    /// takes its width; an arc is dragged as KiCad's router drags one, the board's arc replaced by the new one
    func testRoundedCornersGoInAsArcTracksAndArcsAreDragged() throws {
        let folder = try XCTUnwrap(Bundle.module.url(forResource: "arcboards", withExtension: nil, subdirectory: "Fixtures"))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
        var rounded = 0, started = 0, dragged = 0, bent = 0
        for file in files {
            let board = try KiCadBoard.read(file)
            let session = BoardEditing(board: board, project: Self.project(file))
            session.cornerMode = .rounded45
            for (a, b, layer) in BoardRoutingTests.pairs(session.router.world, seed: file.lastPathComponent) {
                let from = Self.mm(a), to = Self.mm(b)
                guard session.start(at: from, layer: session.layers[layer]) else { continue }
                session.move(to: KiCadPoint((from.x + to.x) / 2 + 1.1, (from.y + to.y) / 2 - 0.7))
                session.move(to: to)
                guard let edit = session.fix(at: to) ?? session.finish(at: to) else { continue }
                let arcs = edit.after.copperItems.filter { $0.head == "arc" && edit.added.contains($0.value("uuid") ?? "") }
                for arc in arcs {
                    XCTAssertEqual(arc.arguments.compactMap(\.head), ["start", "mid", "end", "width", "layer", "net", "uuid"])
                }
                rounded += arcs.count
            }
            // the board's own arcs: the pointer near one's end snaps to it, and a track started on it (where the arc is
            // what the router tool picks there, not a pad or another track) is as wide
            for node in session.board.copperItems where node.head == "arc" {
                guard let m = node["mid"], let e = node["end"], let layer = node.value("layer"), let l = session.router.layer(layer),
                      let w = node["width"]?.number(at: 0) else { continue }
                let mid = KiCadPoint(m.number(at: 0)!, m.number(at: 1)!), end = KiCadPoint(e.number(at: 0)!, e.number(at: 1)!)
                if session.router.startPoint(at: BoardEditing.nm(end), layer: l).item is Arc {
                    XCTAssertEqual(session.snap(KiCadPoint(end.x + w / 8, end.y - w / 8), layer: layer), BoardEditing.nm(end))
                }
                guard session.router.startPoint(at: BoardEditing.nm(mid), layer: l).item is Arc,
                      session.start(at: mid, layer: layer) else { continue }
                XCTAssertEqual(session.router.router.sizes.trackWidth, Int((w * 1e6).rounded()))
                session.cancel()
                started += 1
                break
            }
            // one dragged by its middle
            for node in session.board.copperItems where node.head == "arc" {
                guard let m = node["mid"], let layer = node.value("layer"), let l = session.router.layer(layer),
                      let uuid = node.value("uuid") else { continue }
                let mid = KiCadPoint(m.number(at: 0)!, m.number(at: 1)!)
                // (an arc the drag picks there, as the router tool picks it: the track whose end is nearest)
                guard session.router.dragStartPoint(at: BoardEditing.nm(mid), layer: l).item is Arc,
                      session.startDrag(at: mid, layer: layer) != nil else { continue }
                let shown = session.drag(to: KiCadPoint(mid.x + 0.2, mid.y + 0.15))
                XCTAssertTrue(shown?.moved.contains(uuid) ?? false)
                guard let edit = session.fixDrag(at: KiCadPoint(mid.x + 0.2, mid.y + 0.15)) else {
                    session.cancelDrag()
                    continue
                }
                XCTAssertTrue(edit.removed.contains(uuid))
                // (an arc bent, drawn as the polyline a track's chain keeps of it, and written as an arc track; one the
                // drag walked round something with goes as segments, as KiCad's dragger leaves it)
                if shown?.tracks.contains(where: { $0.points.count > 2 }) ?? false {
                    XCTAssertTrue(edit.after.copperItems.contains { $0.head == "arc" && edit.added.contains($0.value("uuid") ?? "") })
                    bent += 1
                }
                dragged += 1
                break
            }
        }
        print("BoardEditingTests: \(rounded) arcs put on rounding corners, \(started) tracks started on arcs, \(dragged) arcs dragged (\(bent) bent)")
        XCTAssertGreaterThan(rounded, 0)
        XCTAssertGreaterThan(started, 0)
        XCTAssertGreaterThan(bent, 0)
    }

    /// Net classes read from the project, changed and added, as KiCad keeps them; the router takes the new widths
    func testNetClassesAreChangedAndTheRouterTakesThem() throws {
        var project = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(KiCadProject.projectFile(
            name: "t", netClasses: [.standard, KiCadProject.NetClass(name: "Power", trackWidth: 0.5, clearance: 0.2, viaDiameter: 0.8,
                                                                   viaDrill: 0.4, patterns: ["GND", "+*V"])]).utf8)) as? [String: Any])
        var classes = KiCadProject.netClasses(in: project)
        XCTAssertEqual(classes.map(\.name), ["Default", "Power"])
        XCTAssertEqual(classes[1].patterns, ["GND", "+*V"])
        XCTAssertEqual(classes[1].trackWidth, 0.5)

        var power = classes[1]
        power.trackWidth = 0.8
        power.patterns = ["GND"]
        KiCadProject.setNetClass(power, in: &project)
        KiCadProject.setNetClass(KiCadProject.NetClass(name: "Signal", trackWidth: 0.15, clearance: 0.15, patterns: ["SIG*"]), in: &project)
        classes = KiCadProject.netClasses(in: project)
        XCTAssertEqual(classes.map(\.name), ["Default", "Power", "Signal"])
        XCTAssertEqual(classes[1].trackWidth, 0.8)
        XCTAssertEqual(classes[1].patterns, ["GND"])
        XCTAssertEqual(classes[2].patterns, ["SIG*"])

        // the router reads them: a GND track 0.8 mm wide
        let file = try XCTUnwrap(Self.boards().first)
        let board = try KiCadBoard.read(file)
        let session = BoardEditing(board: board, project: nil)
        session.load(board, project: project)
        XCTAssertEqual(session.router.sizes(for: nil, net: "GND").trackWidth, 800_000)
        XCTAssertEqual(session.router.sizes(for: nil, net: "SIG1").trackWidth, max(150_000, session.router.world.minTrackWidth))
    }
}
