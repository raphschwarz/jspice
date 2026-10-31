import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// Footprints' and pads' properties set as KiCad's footprint and pad properties dialogs set them
/// (BoardEditing.setFootprintProperties, setPadProperties) and items locked and unlocked as its Lock and Unlock do
/// (setLocked), each as one change, on boards (Fixtures/zoneedits, footprints on both sides at several angles with pads
/// of every shape, and Fixtures/boards' random ones; KICAD_BOARD_REFERENCE's too, where it names some): KiCad's pcbnew
/// reads every property back as set (tools/kicad-reference/properties.py), and writes each footprint changed as the
/// port wrote it (read and saved again by KiCad); and kicad-cli's DRC finds on the boards what BoardDRC finds
/// (drc.py, DRCTests.compare). Locked items left alone as KiCad leaves them: not moved, turned, turned over, dragged
/// or deleted, their zones' outlines not edited, unless locks are overridden; a locked track still dragged, as KiCad's
/// router's "Drag Anyway" drags it, and its tuning pattern locked with it.
final class PropertiesTests: XCTestCase {
    typealias Rand = ZoneEditingTests.Rand

    func testLockedItemsAreLeftAsKiCadLeavesThem() throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "zoneedits/zones", withExtension: "kicad_pcb", subdirectory: "Fixtures"))
        let board = try KiCadBoard.read(file)
        let session = BoardEditing(board: board)
        let r1 = try XCTUnwrap(session.board.footprints.first { $0.reference == "R1" }).uuid
        let r2 = try XCTUnwrap(session.board.footprints.first { $0.reference == "R2" }).uuid
        XCTAssertTrue(session.isLocked(r2), "R2 is drawn locked")
        XCTAssertFalse(session.isLocked(r1))
        // a pad, as a pad's properties are asked for, picked where it is
        let r1Pad = try XCTUnwrap(session.board.footprints.first { $0.reference == "R1" }?.pads.first)
        XCTAssertEqual(session.pad(at: r1Pad.position), r1Pad.uuid)
        XCTAssertNil(session.pad(at: KiCadPoint(-50, -50)))
        // a pad on no copper (an aperture) keeps no number, as PAD::CanHaveNumber has it
        let apertures = BoardEditing(board: try KiCadBoard.read(file))
        var aperture = try XCTUnwrap(apertures.padProperties(r1Pad.uuid))
        (aperture.type, aperture.copperLayers, aperture.technicalLayers, aperture.number) = (.aperture, .none, ["F.Paste"], "EP")
        XCTAssertNotNil(apertures.setPadProperties(r1Pad.uuid, aperture))
        XCTAssertEqual(apertures.padProperties(r1Pad.uuid)?.number, "")
        XCTAssertEqual(apertures.padProperties(r1Pad.uuid)?.type, .aperture)
        // a locked footprint is not moved, turned, turned over or dragged; the others with it are
        XCTAssertNil(session.moveFootprint(r2, to: KiCadPoint(1, 1)))
        XCTAssertNil(session.rotateFootprints([r2]))
        XCTAssertNil(session.flipFootprints([r2]))
        XCTAssertNil(session.startFootprintDrag([r2], at: KiCadPoint(40, 15)))
        let moved = try XCTUnwrap(session.moveFootprints([r1, r2], by: KiCadPoint(1, 0)))
        XCTAssertEqual(moved.footprints, [r1])
        // its pads are locked with it
        let pad = try XCTUnwrap(session.board.footprint(uuid: r2)?.pads.first).uuid
        XCTAssertTrue(session.isLocked(pad))
        // a locked track and via are not deleted
        let lockedTracks = session.board.copperItems.filter { $0.value("locked") == "yes" }.compactMap { $0.value("uuid") }
        XCTAssertEqual(lockedTracks.count, 2)
        XCTAssertNil(session.remove(Set(lockedTracks)))
        // nor cut, nor anything selected with them (KiCad 10.0.8's Cut stops when locks block its selection; its
        // 10.0.7 copied nothing and then deleted the whole selection), unless locks are overridden
        XCTAssertNil(session.cut(lockedTracks + [r1], reference: .zero))
        XCTAssertNotNil(session.board.footprint(uuid: r1))
        XCTAssertEqual(session.board.copperItems.filter { $0.value("locked") == "yes" }.count, 2)
        let cutter = BoardEditing(board: try KiCadBoard.read(file))
        cutter.overridesLocks = true
        let cut = try XCTUnwrap(cutter.cut(lockedTracks + [r1], reference: .zero))
        XCTAssertEqual(cut.edit?.name, "Cut")
        XCTAssertNil(cutter.board.footprint(uuid: r1))
        // unlocked, they are: Unlock as one change
        let unlock = try XCTUnwrap(session.setLocked(Set(lockedTracks + [r2]), false))
        XCTAssertEqual(unlock.name, "Unlock")
        XCTAssertFalse(session.isLocked(r2))
        XCTAssertNotNil(session.moveFootprint(r2, to: KiCadPoint(41, 16)))
        // locked again, as KiCad writes each lock
        let lock = try XCTUnwrap(session.setLocked(Set(lockedTracks + [r2]), true))
        XCTAssertEqual(lock.name, "Lock")
        XCTAssertNil(session.setLocked(Set(lockedTracks), true), "already locked: nothing changes")
        let via = try XCTUnwrap(session.board.root.all("via").first)
        XCTAssertEqual(via.items.firstIndex { $0.head == "locked" }, (via.items.firstIndex { $0.head == "layers" } ?? -9) + 1)
        // a locked track is dragged ("Drag Anyway"), and stays locked in the router after
        session.overridesLocks = true
        XCTAssertNotNil(session.moveFootprint(r2, to: KiCadPoint(40, 15)))
        session.overridesLocks = false
        // toggled: unlocked if any is locked
        XCTAssertEqual(session.toggleLocked(Set([r1, r2]))?.name, "Unlock")
        XCTAssertEqual(session.toggleLocked(Set([r1, r2]))?.name, "Lock")
    }

    // MARK: - Against KiCad

    static func boards() throws -> [URL] {
        var files = ["zoneedits/zones"].compactMap { Bundle.module.url(forResource: $0, withExtension: "kicad_pcb", subdirectory: "Fixtures") }
        files += try BoardEditingTests.boards()
        if let folder = ProcessInfo.processInfo.environment["KICAD_BOARD_REFERENCE"] {
            let more = try folder.split(separator: ":").flatMap { try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: String($0)), includingPropertiesForKeys: nil) }
                .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
            files += more.prefix(10)
        }
        return files
    }

    /// Random new properties for a footprint, as a user might give it in the dialog
    static func randomFootprint(_ was: FootprintProperties, _ session: BoardEditing, _ uuid: String, rng: inout Rand) -> FootprintProperties {
        var p = was
        for i in p.fields.indices where rng.bool(0.5) {
            var f = p.fields[i]
            if f.name == "Value" || rng.bool(0.2) { f.text = rng.pick(["10k", "4.7µF", "JSpice \"edited\"", f.text]) }
            if rng.bool(0.3) { f.visible.toggle() }
            if rng.bool(0.4) { f.offset = KiCadPoint((f.offset.x + rng.range(-1, 1) * 1000).rounded() / 1000, (f.offset.y + rng.range(-1, 1) * 1000).rounded() / 1000) }
            if rng.bool(0.3) { f.width = rng.pick([0.8, 1, 1.27]); f.height = rng.pick([0.8, 1, 1.5]) }
            if rng.bool(0.3) { f.thickness = rng.pick([0.1, 0.15, 0.2]) }
            if rng.bool(0.2) { f.italic.toggle() }
            if rng.bool(0.2) { f.layer = rng.pick(["F.SilkS", "B.SilkS", "F.Fab", "B.Fab", "Cmts.User"]) }
            if rng.bool(0.3) { f.angle = rng.pick([0, 90, 180, 270, 45]) }
            if rng.bool(0.2) { f.keepUpright.toggle() }
            // (a knockout only on a hidden field: BoardDRC does not make a knockout text's shape, and a hidden one's
            // is not checked)
            if !f.visible && rng.bool(0.2) { f.knockout.toggle() }
            if rng.bool(0.2) { f.mirrored.toggle() }
            p.fields[i] = f
        }
        if rng.bool(0.3), var f = session.newFootprintField(uuid, row: p.fields.count) {
            f.text = "added"
            p.fields.append(f)
        }
        if rng.bool(0.2), let i = p.fields.indices.last(where: { !["Reference", "Value", "Datasheet", "Description", "Footprint"].contains(p.fields[$0].name) }) {
            p.fields.remove(at: i)
        }
        if rng.bool(0.4) { p.position = KiCadPoint(((p.position.x + rng.range(-2, 2)) * 1000).rounded() / 1000, ((p.position.y + rng.range(-2, 2)) * 1000).rounded() / 1000) }
        if rng.bool(0.4) { p.orientation = rng.pick([0, 90, -90, 180, 45, 30]) }
        if rng.bool(0.25) { p.onBack.toggle() }
        if rng.bool(0.2) { p.locked.toggle() }
        if rng.bool(0.3) { p.mounting = rng.pick(FootprintProperties.Mounting.allCases) }
        if rng.bool(0.3) { p.boardOnly.toggle() }
        if rng.bool(0.3) { p.excludeFromBOM.toggle() }
        if rng.bool(0.3) { p.excludeFromPositionFiles.toggle() }
        if rng.bool(0.3) { p.doNotPopulate.toggle() }
        if rng.bool(0.2) { p.allowSolderMaskBridges.toggle() }
        if rng.bool(0.3) { p.clearance = rng.bool(0.3) ? nil : rng.pick([0.1, 0.25, 0.4]) }
        if rng.bool(0.3) { p.solderMaskMargin = rng.bool(0.3) ? nil : rng.pick([0, 0.05, -0.02]) }
        if rng.bool(0.3) { p.solderPasteMargin = rng.bool(0.3) ? nil : rng.pick([0, -0.05]) }
        if rng.bool(0.2) { p.solderPasteRatio = rng.bool(0.3) ? nil : rng.pick([-0.1, -0.05]) }
        if rng.bool(0.3) { p.zoneConnection = rng.pick([.inherited, .none, .thermal, .full]) }
        return p
    }

    /// Random new properties for a pad, as a user might give it in the dialog
    /// (`removesLayers`: a plated pad may be kept only on the layers connected to it, which BoardDRC does not check as
    /// KiCad does, and leaves the board out of its comparison for: on every other board only)
    static func randomPad(_ was: PadProperties, nets: [String], free: Bool, removesLayers: Bool, rng: inout Rand) -> PadProperties {
        var p = was
        let custom = p.shape == .customCircle || p.shape == .customRect
        // (the dialog's number greyed out for a pad that can have none: an unplated hole, a pad on no copper)
        let numbered = p.type != .npth && p.type != .aperture && !(p.type == .throughHole && p.copperLayers == .none)
        if rng.bool(0.2), numbered { p.number = rng.pick(["1", "2", "A1", "EP"]) }
        // (a pad's net changed only where no track or via meets it: KiCad gives a track the net of what it joins as
        // it reads the board, which BoardDRC does not)
        if free && rng.bool(0.2) { p.net = nets.isEmpty || rng.bool(0.2) ? nil : rng.pick(nets) }
        if !custom && rng.bool(0.3) {
            p.shape = rng.pick([.circle, .oval, .rect, .trapezoid, .roundrect, .chamferedRect, .chamferedRoundRect])
            if p.shape == .roundrect || p.shape == .chamferedRoundRect { p.cornerRatio = PadProperties.defaultCornerRatio(p.size) }
            if p.shape == .chamferedRect || p.shape == .chamferedRoundRect {
                p.chamferRatio = 0.2
                p.chamferedCorners = Set(PadProperties.Corner.allCases.filter { _ in rng.bool() })
                if p.chamferedCorners.isEmpty { p.chamferedCorners = [.topLeft] }
            }
            if p.shape == .trapezoid { p.trapezoidDelta = rng.pick([0.2, -0.3]); p.trapezoidAlongY = rng.bool() }
            p.thermalSpokeAngle = PadProperties.defaultSpokeAngle(p.shape)
        }
        if rng.bool(0.3) { p.size = KiCadPoint(rng.pick([0.8, 1.2, 1.6, 2]), rng.pick([0.8, 1.0, 1.5])) }
        if p.shape == .trapezoid { p.trapezoidDelta = min(abs(p.trapezoidDelta), (p.trapezoidAlongY ? p.size.x : p.size.y) * 0.5) * (p.trapezoidDelta < 0 ? -1 : 1) }
        if rng.bool(0.3) { p.orientation = rng.pick([0, 90, 45, 180, -30]) }
        if rng.bool(0.3) { p.position = KiCadPoint(((p.position.x + rng.range(-0.5, 0.5)) * 1000).rounded() / 1000, ((p.position.y + rng.range(-0.5, 0.5)) * 1000).rounded() / 1000) }
        if rng.bool(0.2) { p.offset = rng.bool(0.3) ? nil : KiCadPoint(rng.pick([0, 0.1, -0.2]), rng.pick([0.15, 0, -0.1])) }
        if p.type == .throughHole || p.type == .npth {
            if rng.bool(0.3) {
                p.oblongHole = rng.bool(0.3)
                let d = min(p.size.x, p.size.y) * 0.5
                p.drill = KiCadPoint(d, p.oblongHole ? d * 1.5 : d)
            }
            if p.type == .throughHole && rng.bool(0.3) {
                let layers: PadProperties.CopperLayers = rng.pick([.all, .outerAndConnected, .connectedOnly])
                p.copperLayers = removesLayers ? layers : .all
            }
        }
        if rng.bool(0.3) { p.clearance = rng.bool(0.3) ? nil : rng.pick([0.1, 0.2]) }
        if rng.bool(0.3) { p.solderMaskMargin = rng.bool(0.3) ? nil : rng.pick([0.05, 0]) }
        if rng.bool(0.2) { p.solderPasteMargin = rng.bool(0.3) ? nil : -0.03 }
        if rng.bool(0.3) { p.zoneConnection = rng.pick([.inherited, .none, .thermal, .full]) }
        if rng.bool(0.3) { p.thermalSpokeWidth = rng.bool(0.3) ? nil : rng.pick([0.25, 0.4]) }
        if rng.bool(0.3) { p.thermalGap = rng.bool(0.3) ? nil : rng.pick([0.3, 0.5]) }
        if rng.bool(0.2) { p.thermalSpokeAngle = rng.pick([45, 90, 30]) }
        if rng.bool(0.3) {
            for l in ["F.Paste", "F.SilkS", "B.Mask", "Eco1.User", "Dwgs.User"] where rng.bool(0.3) {
                if p.technicalLayers.contains(l) { p.technicalLayers.remove(l) } else { p.technicalLayers.insert(l) }
            }
        }
        if rng.bool(0.1) { p.fabricationProperty = rng.pick([nil, "pad_prop_testpoint", "pad_prop_heatsink"]) }
        return p
    }

    func testFootprintsAndPadsAsKiCadReadsAndWritesThem() throws {
        guard ZoneEditingTests.kicadPresent else {
            if ProcessInfo.processInfo.environment["JSPICE_REQUIRE_KICAD"] != nil { return XCTFail("KiCad 10's pcbnew module is needed") }
            throw XCTSkip("KiCad's pcbnew module is not installed")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-properties-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { if ProcessInfo.processInfo.environment["PROPERTIES_KEEP"] == nil { try? FileManager.default.removeItem(at: work) } }
        var rng = Rand(state: 20261030)
        var written: [URL] = []
        var edits = 0, refused = 0
        var changedFootprints: [String: Set<String>] = [:]
        var locks: [String: [String: Bool]] = [:]
        for (n, file) in try Self.boards().enumerated() {
            let name = "edited-\(n)"
            let original = try ZoneEditingTests.copy(file, to: work, as: "original-\(n)")
            let board = try KiCadBoard.read(original)
            let session = BoardEditing(board: board, project: BoardEditingTests.project(original))
            let nets = Array(board.netNames).sorted()
            for fp in board.footprints where rng.bool(0.7) {
                let uuid = fp.uuid
                // its pads
                for pad in session.board.footprint(uuid: uuid)?.pads ?? [] where rng.bool(0.5) {
                    guard let was = session.padProperties(pad.uuid) else { continue }
                    let wiredNets = Set(session.board.tracks.compactMap(\.net) + session.board.vias.compactMap(\.net))
                    let wanted = Self.randomPad(was, nets: nets.filter { !wiredNets.contains($0) }, free: !wiredNets.contains(was.net ?? ""),
                                                 removesLayers: n % 2 == 1, rng: &rng)
                    if let problem = session.padPropertiesProblem(pad.uuid, wanted) {
                        XCTAssertNil(session.setPadProperties(pad.uuid, wanted), problem)
                        refused += 1
                    } else if let edit = session.setPadProperties(pad.uuid, wanted) {
                        XCTAssertEqual(edit.name, "Edit Pad Properties")
                        edits += 1
                        changedFootprints[name, default: []].insert(uuid)
                        // what the dialog shows of it again is what it was given
                        let now = try XCTUnwrap(session.padProperties(pad.uuid))
                        Self.assertSame(now, wanted, "\(name) pad \(pad.uuid)")
                    }
                }
                // the footprint
                guard let was = session.footprintProperties(uuid) else { continue }
                let wanted = Self.randomFootprint(was, session, uuid, rng: &rng)
                if let problem = session.footprintPropertiesProblem(uuid, wanted) {
                    XCTAssertNil(session.setFootprintProperties(uuid, wanted), problem)
                    refused += 1
                } else if let edit = session.setFootprintProperties(uuid, wanted) {
                    XCTAssertEqual(edit.name, "Edit Footprint Properties")
                    edits += 1
                    changedFootprints[name, default: []].insert(uuid)
                }
            }
            // some items locked, some unlocked
            let lockable = session.board.copperItems.compactMap { $0.value("uuid") } + session.board.footprints.map(\.uuid)
                + session.board.zones.map(\.uuid)
            let chosen = Set(lockable.filter { _ in rng.bool(0.15) })
            if !chosen.isEmpty, let edit = session.setLocked(chosen, rng.bool(0.6)) {
                edits += 1
                for f in edit.footprints { changedFootprints[name, default: []].insert(f) }
            }
            for uuid in lockable { locks[name, default: [:]][uuid] = session.isLocked(uuid) }
            let out = work.appendingPathComponent(name + ".kicad_pcb")
            try session.board.write(to: out)
            for ext in ["kicad_pro", "kicad_dru"] {
                let src = original.deletingPathExtension().appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: src.path) {
                    try FileManager.default.copyItem(at: src, to: out.deletingPathExtension().appendingPathExtension(ext))
                }
            }
            written.append(out)
        }
        // KiCad's reading of what the port wrote: every footprint's and pad's properties as the port has them
        let read = try XCTUnwrap(try ZoneEditingTests.run("properties.py", ["read"] + written.map(\.path)).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        var footprintsRead = 0, padsRead = 0, locksRead = 0, footprintsWritten = 0
        for file in written {
            let name = file.deletingPathExtension().lastPathComponent
            let board = try KiCadBoard.read(file)
            let session = BoardEditing(board: board)
            let theirs = try XCTUnwrap(read[file.path] as? [String: Any])
            let fps = try XCTUnwrap(theirs["footprints"] as? [String: [String: Any]])
            for fp in board.footprints {
                guard let k = fps[fp.uuid], let ours = session.footprintProperties(fp.uuid) else { continue }
                footprintsRead += 1
                Self.assertSame(ours, k, "\(name) \(fp.reference)")
                for pad in fp.pads {
                    guard let kp = (k["pads"] as? [String: [String: Any]])?[pad.uuid], let op = session.padProperties(pad.uuid) else { continue }
                    padsRead += 1
                    Self.assertSame(op, kp, flipped: fp.layer == "B.Cu", footprintAngle: fp.rotation, "\(name) \(fp.reference) pad \(pad.number)")
                }
            }
            let theirLocks = theirs["locked"] as? [String: Bool] ?? [:]
            for (uuid, locked) in locks[name] ?? [:] {
                if let k = theirLocks[uuid] {
                    locksRead += 1
                    XCTAssertEqual(k, locked, "\(name) \(uuid) locked")
                } else if let k = fps[uuid]?["locked"] as? Bool {
                    locksRead += 1
                    XCTAssertEqual(k, locked, "\(name) footprint \(uuid) locked")
                }
            }
            // KiCad's own writing of what it read: each footprint changed as the port wrote it
            let saved = work.appendingPathComponent(name + "-kicad.kicad_pcb")
            XCTAssertNotNil(try ZoneEditingTests.run("properties.py", ["resave", file.path, saved.path]))
            let resaved = try KiCadBoard.read(saved)
            for uuid in changedFootprints[name] ?? [] {
                guard let ours = board.footprint(uuid: uuid)?.node, let k = resaved.footprint(uuid: uuid)?.node else { continue }
                footprintsWritten += 1
                XCTAssertTrue(Self.sameAsKiCad(ours, k), "\(name) footprint \(uuid) as KiCad writes it:\n\(ours.compact)\n\(k.compact)")
            }
        }
        // (a board on which KiCad, reading it, gave a track the net of a pad it now meets, which BoardDRC does not,
        // left out of the comparison of their checks, and counted)
        let checked = try written.filter { file in
            let nets = (read[file.path] as? [String: Any])?["nets"] as? [String: String] ?? [:]
            let board = try KiCadBoard.read(file)
            let ours: [(String, String)] = board.tracks.map { ($0.uuid, $0.net ?? "") } + board.vias.map { ($0.uuid, $0.net ?? "") }
            return ours.allSatisfy { item in nets[item.0] == nil || nets[item.0] == item.1 }
        }
        for file in checked { XCTAssertNotNil(try ZoneEditingTests.run("drc.py", [file.path]), "drc.py \(file.lastPathComponent)") }
        let (drcSummary, _, drcDifferences) = try DRCTests.compare(checked)
        print("PropertiesTests: \(written.count) boards, \(edits) changes (\(refused) refused as KiCad refuses them); KiCad read \(footprintsRead) "
              + "footprints, \(padsRead) pads and \(locksRead) locks as set, wrote \(footprintsWritten) footprints changed as the port does; DRC (\(written.count - checked.count) boards left out, "
              + "their tracks given other nets by KiCad as it read them): \(drcSummary)")
        XCTAssertGreaterThan(edits, 0)
        XCTAssertTrue(drcDifferences.isEmpty, "\(drcDifferences.count) differences from KiCad's DRC:\n" + drcDifferences.prefix(30).joined(separator: "\n"))
    }

    /// Whether a footprint's node is as KiCad writes it, `theirs`: what KiCad writes of the footprint once it has read
    /// it is not quite what it read, and these are let be: its drawings and pads in the order KiCad sorts them as it
    /// writes them (FOOTPRINT::cmp_drawings, cmp_pads: by layer, shape and place), which the port does not; a
    /// nanometre's difference in where an item is on a footprint turned off square (KiCad keeps items on the board,
    /// and turns them back onto the footprint to write them); an angle a whole turn from another the same (KiCad
    /// reads a text's into [0°, 360°))
    static func sameAsKiCad(_ ours: SExpr, _ theirs: SExpr) -> Bool {
        func same(_ a: SExpr, _ b: SExpr, angle: Bool = false) -> Bool {
            switch (a.kind, b.kind) {
            case (.list, .list):
                guard a.head == b.head, a.items.count == b.items.count else { return false }
                if a.head == "footprint" {
                    // (in any order)
                    var left = b.items
                    for x in a.items {
                        guard let i = left.firstIndex(where: { same(x, $0) }) else { return false }
                        left.remove(at: i)
                    }
                    return true
                }
                return zip(a.items, b.items).enumerated().allSatisfy { i, p in same(p.0, p.1, angle: a.head == "at" && i == 3) }
            case (.list, _), (_, .list):
                return false
            default:
                if a.text == b.text { return true }
                guard let x = Double(a.text), let y = Double(b.text) else { return false }
                if angle { return PropertiesTests.sameAngle(x, y) }
                return abs(x - y) <= 1.5e-6
            }
        }
        return same(ours, theirs)
    }

    static func near(_ a: Double, _ b: Double, _ tolerance: Double = 1) -> Bool { abs(a - b) <= tolerance }

    static func iu(_ mm: Double) -> Int { BoardWorld.iu(mm) }

    /// The angles' difference, a whole number of turns apart taken as none
    static func sameAngle(_ a: Double, _ b: Double) -> Bool {
        let d = (a - b).truncatingRemainder(dividingBy: 360)
        return abs(d) < 1e-6 || abs(abs(d) - 360) < 1e-6
    }

    static func assertSame(_ ours: FootprintProperties, _ k: [String: Any], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        func int(_ key: String) -> Int? { (k[key] as? NSNumber)?.intValue }
        func bool(_ key: String) -> Bool? { k[key] as? Bool }
        let pos = (k["position"] as? [NSNumber])?.map(\.intValue) ?? []
        XCTAssertEqual(pos, [iu(ours.position.x), iu(ours.position.y)], "\(what) position", file: file, line: line)
        XCTAssertTrue(sameAngle((k["orientation"] as? NSNumber)?.doubleValue ?? .nan, ours.orientation), "\(what) orientation", file: file, line: line)
        XCTAssertEqual(k["layer"] as? String, ours.onBack ? "B.Cu" : "F.Cu", "\(what) side", file: file, line: line)
        XCTAssertEqual(bool("locked"), ours.locked, "\(what) locked", file: file, line: line)
        let attrs = int("attributes") ?? 0
        XCTAssertEqual(attrs & 3, ours.mounting == .throughHole ? 1 : ours.mounting == .smd ? 2 : 0, "\(what) mounting", file: file, line: line)
        XCTAssertEqual(bool("boardOnly"), ours.boardOnly, "\(what) board only", file: file, line: line)
        XCTAssertEqual(bool("excludeFromBOM"), ours.excludeFromBOM, "\(what) BOM", file: file, line: line)
        XCTAssertEqual(bool("excludeFromPos"), ours.excludeFromPositionFiles, "\(what) position files", file: file, line: line)
        XCTAssertEqual(bool("dnp"), ours.doNotPopulate, "\(what) DNP", file: file, line: line)
        XCTAssertEqual(bool("maskBridges"), ours.allowSolderMaskBridges, "\(what) mask bridges", file: file, line: line)
        XCTAssertEqual(int("clearance"), ours.clearance.map(iu), "\(what) clearance", file: file, line: line)
        XCTAssertEqual(int("maskMargin"), ours.solderMaskMargin.map(iu), "\(what) mask margin", file: file, line: line)
        XCTAssertEqual(int("pasteMargin"), ours.solderPasteMargin.map(iu), "\(what) paste margin", file: file, line: line)
        XCTAssertEqual((k["pasteRatio"] as? NSNumber)?.doubleValue, ours.solderPasteRatio, "\(what) paste ratio", file: file, line: line)
        XCTAssertEqual(int("zoneConnection"), ours.zoneConnection.rawValue, "\(what) zone connection", file: file, line: line)
        let fields = k["fields"] as? [[String: Any]] ?? []
        XCTAssertEqual(fields.map { $0["name"] as? String ?? "" }, ours.fields.map(\.name), "\(what) fields", file: file, line: line)
        for (f, kf) in zip(ours.fields, fields) {
            let w = "\(what) field \(f.name)"
            XCTAssertEqual(kf["text"] as? String, f.text, "\(w) text", file: file, line: line)
            XCTAssertEqual(kf["visible"] as? Bool, f.visible, "\(w) shown", file: file, line: line)
            let off = (kf["offset"] as? [NSNumber])?.map(\.doubleValue) ?? []
            // (KiCad keeps a field where it is on the board, and turns it back onto the footprint: a nanometre's rounding)
            XCTAssertTrue(off.count == 2 && near(off[0], Double(iu(f.offset.x))) && near(off[1], Double(iu(f.offset.y))), "\(w) offset \(off) \(f.offset)", file: file, line: line)
            XCTAssertEqual((kf["width"] as? NSNumber)?.intValue, iu(f.width), "\(w) width", file: file, line: line)
            XCTAssertEqual((kf["height"] as? NSNumber)?.intValue, iu(f.height), "\(w) height", file: file, line: line)
            if let t = f.thickness { XCTAssertEqual((kf["thickness"] as? NSNumber)?.intValue, iu(t), "\(w) thickness", file: file, line: line) }
            XCTAssertEqual(kf["italic"] as? Bool, f.italic, "\(w) italic", file: file, line: line)
            XCTAssertEqual(kf["layer"] as? String, f.layer, "\(w) layer", file: file, line: line)
            XCTAssertTrue(sameAngle((kf["angle"] as? NSNumber)?.doubleValue ?? .nan, f.angle + ours.orientation), "\(w) angle", file: file, line: line)
            XCTAssertEqual(kf["keepUpright"] as? Bool, f.keepUpright, "\(w) upright", file: file, line: line)
            XCTAssertEqual(kf["knockout"] as? Bool, f.knockout, "\(w) knockout", file: file, line: line)
            XCTAssertEqual(kf["mirrored"] as? Bool, f.mirrored, "\(w) mirrored", file: file, line: line)
        }
    }

    static let shapeCodes: [PadProperties.Shape: Int] = [.circle: 0, .rect: 1, .oval: 2, .trapezoid: 3, .roundrect: 4, .chamferedRect: 5,
                                                         .chamferedRoundRect: 5, .customCircle: 6, .customRect: 6]
    static let typeCodes: [PadProperties.PadType: Int] = [.throughHole: 0, .smd: 1, .connector: 2, .npth: 3, .aperture: 1]
    static let corners: [PadProperties.Corner: Int] = [.topLeft: 1, .topRight: 2, .bottomLeft: 4, .bottomRight: 8]
    static let properties: [String: Int] = ["pad_prop_bga": 1, "pad_prop_fiducial_glob": 2, "pad_prop_fiducial_loc": 3, "pad_prop_testpoint": 4,
                                            "pad_prop_heatsink": 5, "pad_prop_castellated": 6, "pad_prop_mechanical": 7, "pad_prop_pressfit": 8]

    /// A pad's properties as KiCad's pcbnew reads them, against the port's (as its dialog shows them: on a footprint
    /// on the back, as on the front)
    static func assertSame(_ ours: PadProperties, _ k: [String: Any], flipped: Bool, footprintAngle: Double, _ what: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        func int(_ key: String) -> Int? { (k[key] as? NSNumber)?.intValue }
        func pair(_ key: String) -> [Int] { (k[key] as? [NSNumber])?.map(\.intValue) ?? [] }
        let sign = flipped ? -1 : 1
        XCTAssertEqual(k["number"] as? String, ours.number, "\(what) number", file: file, line: line)
        XCTAssertEqual(int("attribute"), typeCodes[ours.type], "\(what) type", file: file, line: line)
        XCTAssertEqual(int("shape"), shapeCodes[ours.shape], "\(what) shape", file: file, line: line)
        let pos = pair("position")
        XCTAssertTrue(pos.count == 2 && near(Double(pos[0]), Double(iu(ours.position.x))) && near(Double(pos[1]), Double(iu(ours.position.y))),
                      "\(what) position \(pos) \(ours.position)", file: file, line: line)
        XCTAssertTrue(sameAngle((k["relativeOrientation"] as? NSNumber)?.doubleValue ?? .nan, ours.orientation), "\(what) orientation", file: file, line: line)
        let round = ours.shape == .circle || ours.shape == .customCircle
        XCTAssertEqual(pair("size"), [iu(ours.size.x), iu(round ? ours.size.x : ours.size.y)], "\(what) size", file: file, line: line)
        let delta = ours.shape == .trapezoid ? (ours.trapezoidAlongY ? [0, iu(ours.trapezoidDelta) * sign] : [iu(ours.trapezoidDelta), 0]) : [0, 0]
        XCTAssertEqual(pair("delta"), delta, "\(what) delta", file: file, line: line)
        XCTAssertEqual(pair("offset"), ours.offset.map { [iu($0.x), iu($0.y) * sign] } ?? [0, 0], "\(what) offset", file: file, line: line)
        if ours.type == .throughHole || ours.type == .npth {
            XCTAssertEqual(pair("drill"), [iu(ours.drill.x), iu(ours.oblongHole ? ours.drill.y : ours.drill.x)], "\(what) drill", file: file, line: line)
            XCTAssertEqual(int("drillShape"), ours.oblongHole ? 2 : 1, "\(what) drill shape", file: file, line: line)
        }
        if [.roundrect, .chamferedRoundRect].contains(ours.shape) {
            XCTAssertEqual((k["roundRatio"] as? NSNumber)?.doubleValue ?? .nan, ours.cornerRatio, accuracy: 1e-9, "\(what) rounding", file: file, line: line)
        }
        if [.chamferedRect, .chamferedRoundRect].contains(ours.shape) {
            XCTAssertEqual((k["chamferRatio"] as? NSNumber)?.doubleValue ?? .nan, ours.chamferRatio, accuracy: 1e-9, "\(what) chamfer", file: file, line: line)
            let mirrored = flipped ? Set(ours.chamferedCorners.compactMap { BoardEditing.flippedCorner[$0] }) : ours.chamferedCorners
            XCTAssertEqual(int("chamfers"), mirrored.reduce(0) { $0 | (corners[$1] ?? 0) }, "\(what) chamfered corners", file: file, line: line)
        }
        XCTAssertEqual(int("clearance"), ours.clearance.map(iu), "\(what) clearance", file: file, line: line)
        XCTAssertEqual(int("zoneConnection"), ours.zoneConnection.rawValue, "\(what) zone connection", file: file, line: line)
        XCTAssertEqual(int("spokeWidth"), ours.thermalSpokeWidth.map(iu), "\(what) spoke width", file: file, line: line)
        XCTAssertEqual(int("thermalGap"), ours.thermalGap.map(iu), "\(what) thermal gap", file: file, line: line)
        XCTAssertEqual((k["spokeAngle"] as? NSNumber)?.doubleValue ?? .nan, ours.thermalSpokeAngle, accuracy: 1e-9, "\(what) spoke angle", file: file, line: line)
        XCTAssertEqual(int("maskMargin"), ours.solderMaskMargin.map(iu), "\(what) mask margin", file: file, line: line)
        XCTAssertEqual(int("pasteMargin"), ours.solderPasteMargin.map(iu), "\(what) paste margin", file: file, line: line)
        XCTAssertEqual(k["net"] as? String ?? "", ours.net ?? "", "\(what) net", file: file, line: line)
        XCTAssertEqual(int("property"), ours.fabricationProperty.flatMap { properties[$0] } ?? 0, "\(what) fabrication property", file: file, line: line)
        // its layers: its technical ones as the dialog has them (turned over on the back), its copper by its choice
        let layers = Set(k["layers"] as? [String] ?? [])
        let technical = Set(ours.technicalLayers.map { flipped ? KiCadFootprint.flipLayer($0) : $0 })
        XCTAssertEqual(layers.intersection(PadProperties.technicalLayerNames), technical, "\(what) technical layers", file: file, line: line)
        if ours.type == .throughHole {
            XCTAssertEqual(layers.contains("In1.Cu") && layers.contains("F.Cu"), ours.copperLayers != .none, "\(what) copper", file: file, line: line)
            XCTAssertEqual(k["removeUnconnected"] as? Bool, ours.copperLayers == .outerAndConnected || ours.copperLayers == .connectedOnly,
                           "\(what) unused layers removed", file: file, line: line)
        }
    }

    /// The dialog's showing of the pad it was given is what it was given (as it keeps it: whole nanometres, the
    /// hole's and shape's that mean something)
    static func assertSame(_ now: PadProperties, _ wanted: PadProperties, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(now.shape, wanted.shape, "\(what) shape", file: file, line: line)
        XCTAssertEqual(now.number, wanted.type == .npth ? "" : wanted.number, "\(what) number", file: file, line: line)
        XCTAssertEqual(now.thermalSpokeAngle, wanted.thermalSpokeAngle, "\(what) spoke angle", file: file, line: line)
        XCTAssertEqual(now.zoneConnection, wanted.zoneConnection, "\(what) zone connection", file: file, line: line)
        XCTAssertEqual(now.technicalLayers, wanted.technicalLayers.intersection(PadProperties.technicalLayerNames), "\(what) technical layers", file: file, line: line)
    }
}
