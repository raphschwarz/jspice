import XCTest
@testable import KiCadLink
import KiCadKit

/// A board open in KiCad's PCB editor changed where it stands, checked against what the editor then has (skipped
/// where no KiCad is running with its API on)
final class LiveBoardTests: XCTestCase {
    var live: KiCadLiveBoard!
    var library: KiCadFootprintLibrary!
    var made: [String] = []

    override func setUpWithError() throws {
        guard let installation = KiCadInstallation.find(), installation.problem == nil else { throw XCTSkip("KiCad is not installed") }
        for socket in KiCadAPI.sockets() {
            guard let api = try? KiCadAPI(socket: socket), let document = try? api.openBoards().first else { continue }
            let file = URL(fileURLWithPath: document.project.path).appendingPathComponent(document.boardFilename)
            live = KiCadLiveBoard(api: api, document: document, file: file)
        }
        guard live != nil else { throw XCTSkip("No KiCad is running with a board open and its API on") }
        library = KiCadFootprintLibrary(installation: installation)
    }

    override func tearDownWithError() throws {
        // the board as it was
        if let live, !made.isEmpty { try live.api.commit(live.document, message: "Test done") { try live.api.delete(made, in: live.document) } }
    }

    /// A footprint's items, ids aside, each number to the nanometre or two, angles a turn apart as one
    static func differences(_ ours: SExpr, _ theirs: SExpr) -> [String] {
        func items(_ f: SExpr) -> [String] {
            f.items.filter { !["uuid", "units"].contains($0.head ?? "") }.map { item -> SExpr in
                // a rectangle is its two corners, which KiCad may give either way round
                guard item.head == "fp_rect", let s = item["start"], let e = item["end"],
                      let x0 = s.number(at: 0), let y0 = s.number(at: 1), let x1 = e.number(at: 0), let y1 = e.number(at: 1) else { return item }
                let r = item.copy()
                r.set(SExpr("start", min(x0, x1), min(y0, y1)))
                r.set(SExpr("end", max(x0, x1), max(y0, y1)))
                return r
            }.map {
                $0.compact.replacingOccurrences(of: #"\(uuid "[0-9a-f-]+"\)"#, with: "(uuid)", options: .regularExpression)
            }.sorted()
        }
        func tokens(_ s: String) -> [String] {
            s.replacingOccurrences(of: "(", with: " ( ").replacingOccurrences(of: ")", with: " ) ").split(separator: " ").map(String.init)
        }
        func same(_ x: String, _ y: String) -> Bool {
            let (tx, ty) = (tokens(x), tokens(y))
            guard tx.count == ty.count else { return false }
            for (p, q) in zip(tx, ty) where p != q {
                guard let u = Double(p), let v = Double(q) else { return false }
                let d = abs(u - v)
                if d > 3e-6 && abs(d - 360) > 3e-6 { return false }
            }
            return true
        }
        var rest = items(theirs)
        var out: [String] = []
        for x in items(ours) {
            if let j = rest.firstIndex(where: { same(x, $0) }) { rest.remove(at: j) } else { out.append("ours:  " + x) }
        }
        return out + rest.map { "KiCad: " + $0 }
    }

    func testFootprintsAreMadeChangedAndRemovedInTheEditorAsOneChangeEach() throws {
        let before = try live.snapshot()
        let after = before.copy()
        let parts: [(String, String, KiCadPoint, Double, Bool)] = [
            ("Resistor_SMD:R_0805_2012Metric", "TR1", KiCadPoint(20, 120), 0, false),
            ("Package_DIP:DIP-8_W7.62mm", "TU1", KiCadPoint(40, 120), 90, false),
            ("Package_TO_SOT_THT:TO-92_Inline", "TQ1", KiCadPoint(60, 120), 0, true),
            ("Capacitor_THT:CP_Radial_D5.0mm_P2.00mm", "TC1", KiCadPoint(80, 120), 37, false),
            ("Package_TO_SOT_SMD:SOT-23", "TQ2", KiCadPoint(100, 120), -143, true),
            ("Mounting_Wuerth:Mounting_Wuerth_WA-SMSI-M2.5_H3.5mm_9774035151", "TH1", KiCadPoint(120, 120), 0, false),
            ("LED_THT:LED_D5.0mm", "TD1", KiCadPoint(140, 120), 180, false),
            ("Connector_PinHeader_2.54mm:PinHeader_1x04_P2.54mm_Vertical", "TJ1", KiCadPoint(160, 120), 270, false),
        ]
        for (id, ref, at, rotation, back) in parts {
            let node = try library.placeable(id, reference: ref, value: "test", at: at, rotation: 0)
            after.add(node)
            let footprint = after.footprints.last!
            if back { footprint.flip() }
            footprint.move(to: at, rotation: rotation)
            footprint.path = "/" + KiCadBoard.newUUID()
            for (k, pad) in footprint.pads.enumerated() where pad.isCopper && !pad.number.isEmpty {
                pad.setNet(k % 2 == 0 ? "TEST_A" : "TEST_B")
                pad.setPin(function: "pin\(k)", type: k % 2 == 0 ? "input" : "passive")
            }
            made.append(footprint.uuid)
        }
        XCTAssertEqual(try live.apply(from: before, to: after, message: "Test: add"), .live(count: parts.count), live.reloadReason ?? "")
        var now = try live.snapshot()
        for uuid in made {
            let ours = try XCTUnwrap(after.footprint(uuid: uuid)), theirs = try XCTUnwrap(now.footprint(uuid: uuid), uuid)
            XCTAssertEqual(Self.differences(ours.node, theirs.node), [], ours.libID)
        }

        // changed in place: a value, a reference, a pad's net, a field, a footprint not to be fitted
        let changed = now.copy()
        let r = try XCTUnwrap(changed.footprints.first { $0.reference == "TR1" })
        r.value = "4.7k"
        r.reference = "TR9"
        r.pads[0].setNet("TEST_C")
        r.setProperty("Tolerance", "1%")
        var attributes = r.attributes
        attributes.insert("dnp")
        r.attributes = attributes
        XCTAssertEqual(try live.apply(from: now, to: changed, message: "Test: change"), .live(count: 1))
        now = try live.snapshot()
        let after2 = try XCTUnwrap(now.footprint(uuid: r.uuid))
        XCTAssertEqual(after2.reference, "TR9")
        XCTAssertEqual(after2.value, "4.7k")
        XCTAssertEqual(after2.pads[0].net, "TEST_C")
        XCTAssertEqual(after2.property("Tolerance"), "1%")
        XCTAssertTrue(after2.attributes.contains("dnp"))
        XCTAssertEqual(after2.position, r.position)

        // exchanged for another footprint, and turned over: made again in place under their own ids, in one change
        let swapped = now.copy()
        let dip = try XCTUnwrap(swapped.footprint(uuid: made[1]))
        swapped.add(try library.placeable("Package_SO:SOIC-8_3.9x4.9mm_P1.27mm", reference: dip.reference, value: "test", at: dip.position))
        let soic = try XCTUnwrap(swapped.footprints.last)
        soic.move(to: dip.position, rotation: dip.rotation)
        soic.node.set(SExpr("uuid", dip.uuid))
        soic.path = dip.path
        for pad in soic.pads { pad.setNet(dip.pads(numbered: pad.number).first?.net) }
        swapped.remove(dip)
        try XCTUnwrap(swapped.footprint(uuid: made[2])).flip()
        XCTAssertEqual(try live.apply(from: now, to: swapped, message: "Test: exchange"), .live(count: 2), live.reloadReason ?? "")
        now = try live.snapshot()
        for uuid in made[1...2] {
            let ours = try XCTUnwrap(swapped.footprint(uuid: uuid)), theirs = try XCTUnwrap(now.footprint(uuid: uuid))
            XCTAssertEqual(Self.differences(ours.node, theirs.node), [], ours.libID)
        }
        XCTAssertEqual(now.footprints.filter { $0.uuid == made[1] }.count, 1)

        // removed
        let removed = now.copy()
        removed.remove(try XCTUnwrap(removed.footprint(uuid: made[0])))
        XCTAssertEqual(try live.apply(from: now, to: removed, message: "Test: remove"), .live(count: 1))
        XCTAssertNil(try live.snapshot().footprint(uuid: made[0]))
        made.removeFirst()
    }

    /// Tracks and vias routed here: made in the editor, changed, and taken away, each as one change
    func testTracksAndViasAreMadeChangedAndRemovedInTheEditor() throws {
        let before = try live.snapshot()
        let after = before.copy()
        let net = before.footprints.flatMap(\.pads).compactMap(\.net).first ?? ""
        let segment = KiCadBoard.newUUID(), arc = KiCadBoard.newUUID(), via = KiCadBoard.newUUID()
        after.addCopper(SExpr("segment", SExpr("start", 20.0, 150.0), SExpr("end", 30.5, 155.25), SExpr("width", 0.3),
                              SExpr("layer", "F.Cu"), after.netList(net, pad: false), SExpr("uuid", segment)))
        after.addCopper(SExpr("arc", SExpr("start", 30.5, 155.25), SExpr("mid", 33.0, 152.0), SExpr("end", 36.0, 155.25),
                              SExpr("width", 0.25), SExpr("layer", "B.Cu"), after.netList(net, pad: false), SExpr("uuid", arc)))
        after.addCopper(SExpr("via", SExpr("at", 30.5, 155.25), SExpr("size", 0.8), SExpr("drill", 0.4),
                              SExpr("layers", "F.Cu", "B.Cu"), after.netList(net, pad: false), SExpr("uuid", via)))
        made += [segment, arc, via]
        XCTAssertEqual(try live.apply(from: before, to: after, message: "Test: route"), .live(count: 3), live.reloadReason ?? "")
        var now = try live.snapshot()
        func node(_ board: KiCadBoard, _ uuid: String) -> SExpr? { board.copperItems.first { $0.value("uuid") == uuid } }
        for uuid in made {
            let ours = try XCTUnwrap(node(after, uuid)), theirs = try XCTUnwrap(node(now, uuid), uuid)
            XCTAssertEqual(Self.differences(SExpr("footprint", ours), SExpr("footprint", theirs)), [], ours.head ?? "")
        }

        // moved
        let moved = now.copy()
        try XCTUnwrap(node(moved, segment)).set(SExpr("end", 31.0, 156.0))
        XCTAssertEqual(try live.apply(from: now, to: moved, message: "Test: move"), .live(count: 1), live.reloadReason ?? "")
        now = try live.snapshot()
        XCTAssertEqual(try XCTUnwrap(node(now, segment))["end"]?.compact, "(end 31 156)")

        // taken away
        let removed = now.copy()
        for uuid in made { removed.root.remove(try XCTUnwrap(node(removed, uuid))) }
        XCTAssertEqual(try live.apply(from: now, to: removed, message: "Test: unroute"), .live(count: 3))
        now = try live.snapshot()
        for uuid in made { XCTAssertNil(node(now, uuid)) }
        made.removeAll()
    }
}
