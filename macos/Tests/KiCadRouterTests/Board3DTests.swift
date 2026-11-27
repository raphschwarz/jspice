import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// The board as KiCad's 3D viewer builds it, against the port's (Board3D): tools/kicad-reference/board3d.py has
/// KiCad's own functions make each layer's polygons in BOARD_ADAPTER::createLayers' order and clip and hole them as
/// RENDER_3D_OPENGL::reload does (NAME.board3d next to NAME.kicad_pcb: the board's outline, each slab's polygons,
/// outline and holes, their points), and Board3D must give the same, point for point. KICAD_BOARD3D_REFERENCE names a
/// folder of such boards (or several, separated by colons); with none, Fixtures/boards, copper, silk, flashing and
/// board3d (a board of masks' and pastes' margins, pads on the silkscreen, tracks with mask openings, vias tented and
/// not, blind and buried vias, unplated holes and slots, a zone on a mask, a footprint on the back, and a stackup of
/// its own). The layers' heights and colours are checked against what board_adapter.cpp's InitSettings and
/// GetLayerColors make of the drawn board's stackup, worked out by hand.
final class Board3DTests: XCTestCase {
    private static var folders: [URL] {
        if let f = ProcessInfo.processInfo.environment["KICAD_BOARD3D_REFERENCE"] {
            return f.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        return ["boards", "copper", "silk", "flashing", "board3d"].compactMap {
            Bundle.module.url(forResource: $0, withExtension: nil, subdirectory: "Fixtures")
        }
    }

    private static func points(_ json: Any?) -> [[[IPoint]]] {
        (json as? [[[[NSNumber]]]] ?? []).map { $0.map { $0.map { IPoint($0[0].intValue, $0[1].intValue) } } }
    }

    private static func board(_ file: URL) throws -> Board3D {
        let pro = file.deletingPathExtension().appendingPathExtension("kicad_pro")
        return Board3D(board: try KiCadBoard.read(file), projectURL: FileManager.default.fileExists(atPath: pro.path) ? pro : nil)
    }

    func testLayersBuiltAsKiCadBuildsThem() throws {
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
        var boards = 0, slabs = 0, polygons = 0, points = 0
        var differences: [String] = []
        for file in files {
            let ref = file.deletingPathExtension().appendingPathExtension("board3d")
            guard let data = try? Data(contentsOf: ref), let theirs = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let ours = try Self.board(file)
            boards += 1
            let name = file.deletingPathExtension().lastPathComponent
            if !ours.unsupported.isEmpty { differences.append("\(name): the port does not make \(ours.unsupported.sorted())") }
            if Self.points(theirs["outline"]) != ours.boardPolygon.polygons.map({ $0.map(\.points) }) {
                differences.append("\(name): the board's outline differs")
            }
            if (theirs["valid"] as? Bool) != ours.outlineValid { differences.append("\(name): the outline's validity differs") }
            for slab in theirs["slabs"] as? [[String: Any]] ?? [] {
                let kind = slab["kind"] as? String ?? "", layer = slab["layer"] as? String
                let match = ours.slabs.first { s in
                    switch kind {
                    case "copper": return s.kind == .copper && s.layer == layer
                    case "tech": return [.silkscreen, .solderpaste, .adhesive].contains(s.kind) && s.layer == layer
                    case "soldermask": return s.kind == .soldermask && s.layer == layer
                    case "platedHoles": return s.kind == .platedHoles
                    default: return s.kind == .body
                    }
                }
                let k = Self.points(slab["polygons"])
                // (an inner copper layer KiCad does not draw under an opaque board, which the port leaves out)
                guard let match else {
                    if !(kind == "copper" && layer != "F.Cu" && layer != "B.Cu") { differences.append("\(name) \(kind) \(layer ?? ""): none in the port") }
                    continue
                }
                slabs += 1
                polygons += k.count
                points += k.joined().map(\.count).reduce(0, +)
                let o = match.polygons.polygons.map { $0.map(\.points) }
                if k != o {
                    let first = zip(k, o).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                    differences.append("\(name) \(kind) \(layer ?? ""): KiCad's \(k.count) polygons, ours \(o.count)"
                                       + (first.map { ", first different #\($0)" } ?? ""))
                }
            }
        }
        print("Board3DTests: \(boards) boards, \(slabs) slabs, \(polygons) polygons, \(points) points")
        XCTAssertGreaterThan(boards, 0)
        XCTAssertTrue(differences.isEmpty, "\(differences.count) differences from KiCad's:\n" + differences.prefix(30).joined(separator: "\n"))
    }

    /// What a pixel of a render from one side shows, as the port's slabs would have it: the topmost of the
    /// adhesive, silkscreen and paste, else the mask (over copper or over the board), else copper (a pad, a track, a
    /// plated hole's wall), else the board, else nothing
    enum Seen: Int, CaseIterable { case nothing, board, copper, maskOverBoard, maskOverCopper, paste, silkscreen, adhesive }

    /// Each pixel centre inside a polygon set (even-odd along each row; the set's outlines do not overlap)
    private static func raster(_ set: PolySet, width w: Int, height h: Int, ax: Double, bx: Double, ay: Double, by: Double) -> [Bool] {
        var out = [Bool](repeating: false, count: w * h)
        var edges: [(Double, Double, Double, Double)] = []
        for poly in set.polygons {
            for chain in poly {
                let p = chain.points
                for k in p.indices {
                    let a = p[k], b = p[(k + 1) % p.count]
                    edges.append((Double(a.x), Double(a.y), Double(b.x), Double(b.y)))
                }
            }
        }
        for j in 0..<h {
            let y = ay * Double(j) + by
            var xs: [Double] = []
            for e in edges where (e.1 <= y) != (e.3 <= y) {
                xs.append(e.0 + (y - e.1) * (e.2 - e.0) / (e.3 - e.1))
            }
            xs.sort()
            var k = 0
            while k + 1 < xs.count {
                let c0 = (xs[k] - bx) / ax, c1 = (xs[k + 1] - bx) / ax
                let lo = max(0, Int(min(c0, c1).rounded(.up))), hi = min(w - 1, Int(max(c0, c1).rounded(.down)))
                if lo <= hi { for i in lo...hi { out[j * w + i] = true } }
                k += 2
            }
        }
        return out
    }

    /// kicad-cli's renders of boards from the top and the bottom (tools/kicad-reference/board3d.py --render: KiCad's
    /// 3D viewer itself, its BOARD_ADAPTER and raytracer, orthographic, its colours flat at basic quality, the layers
    /// the board's plot settings plot; NAME.render next to the board, each pixel's colour taken to the nearest of the
    /// few colours it is made of) against what the port's slabs show at each pixel's centre: each kind of thing the
    /// port shows (seen in 500 pixels or more) must be drawn in one colour of KiCad's, and each in its own, at more
    /// than 99.9% of the pixels further than two pixels from where the port's slabs change what is seen (about 65 µm
    /// at these renders' 31 pixels to the millimetre: the faces KiCad draws are not its polygons, a hole's plating
    /// stops half way in copper, its edges are antialiased). Where the far side's copper is bare of mask, KiCad's
    /// render shows it faintly through the board: those pixels are left out.
    func testSilhouettesAsKiCadRendersThem() throws {
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
        var renders = 0
        for file in files {
            let ref = file.deletingPathExtension().appendingPathExtension("render")
            guard let data = try? Data(contentsOf: ref), let sides = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
                continue
            }
            // (the layers the boards' plot settings plot, as the renders show them: not the adhesive)
            var settings = Board3D.Settings()
            settings.visible.remove(.adhesive)
            let pro = file.deletingPathExtension().appendingPathExtension("kicad_pro")
            let b = Board3D(board: try KiCadBoard.read(file), projectURL: FileManager.default.fileExists(atPath: pro.path) ? pro : nil,
                            settings: settings)
            let name = file.deletingPathExtension().lastPathComponent
            for (side, r) in sides.sorted(by: { $0.key < $1.key }) {
                renders += 1
                let w = (r["width"] as! NSNumber).intValue, h = (r["height"] as! NSNumber).intValue
                let ax = (r["ax"] as! NSNumber).doubleValue, bx = (r["bx"] as! NSNumber).doubleValue
                let ay = (r["ay"] as! NSNumber).doubleValue, by = (r["by"] as! NSNumber).doubleValue
                let palette = r["palette"] as! [[NSNumber]]
                // KiCad's pixels
                var seen = [UInt8](repeating: 0, count: w * h)
                for (j, row) in (r["rows"] as! [String]).enumerated() {
                    var i = 0
                    var letter: UInt8 = 0, count = 0
                    func flush() { for _ in 0..<count { seen[j * w + i] = letter; i += 1 } }
                    for ch in row.utf8 {
                        if ch >= 97 {
                            if count > 0 { flush() }
                            (letter, count) = (ch - 97, 0)
                        } else {
                            count = count * 10 + Int(ch - 48)
                        }
                    }
                    flush()
                }
                // the port's
                let front = side == "top"
                func slab(_ kind: Board3D.Kind, _ layer: String?) -> [Bool] {
                    let s = b.slabs.first { $0.kind == kind && $0.layer == layer }?.polygons ?? PolySet()
                    return Self.raster(s, width: w, height: h, ax: ax, bx: bx, ay: ay, by: by)
                }
                let p = front ? "F." : "B."
                let adhesive = slab(.adhesive, p + "Adhes"), silk = slab(.silkscreen, p + "SilkS"), paste = slab(.solderpaste, p + "Paste")
                let mask = slab(.soldermask, p + "Mask"), copper = slab(.copper, p + "Cu"), barrels = slab(.platedHoles, nil)
                let body = slab(.body, nil)
                // (the far side's copper bare of mask shows faintly through the board in KiCad's renders: left out)
                let q = front ? "B." : "F."
                let farCopper = slab(.copper, q + "Cu"), farMask = slab(.soldermask, q + "Mask")
                var ours = [Seen?](repeating: .nothing, count: w * h)
                var hidden = 0
                for k in 0..<(w * h) {
                    let cu = copper[k] || barrels[k]
                    ours[k] = adhesive[k] ? .adhesive : silk[k] ? .silkscreen : paste[k] ? .paste
                        : mask[k] ? (cu ? .maskOverCopper : .maskOverBoard) : cu ? .copper : body[k] ? .board : .nothing
                    if farCopper[k] && !farMask[k] && ours[k] != .nothing && ours[k] != .copper {
                        ours[k] = nil
                        hidden += 1
                    }
                }
                // each kind against KiCad's colours, away from where what is seen changes
                let radius = 2
                var tally = [[Int]](repeating: [Int](repeating: 0, count: palette.count), count: Seen.allCases.count)
                for j in radius..<(h - radius) {
                    pixels: for i in radius..<(w - radius) {
                        guard let s = ours[j * w + i] else { continue }
                        for dj in -radius...radius { for di in -radius...radius where ours[(j + dj) * w + i + di] != s { continue pixels } }
                        tally[s.rawValue][Int(seen[j * w + i])] += 1
                    }
                }
                var total = 0, agreed = 0
                var colours: [Seen: Int] = [:]
                var report: [String] = []
                for s in Seen.allCases {
                    let row = tally[s.rawValue]
                    let n = row.reduce(0, +)
                    guard n > 0, let best = row.indices.max(by: { row[$0] < row[$1] }) else { continue }
                    total += n
                    agreed += row[best]
                    // (a kind seen in a few pixels only is not asked a colour of its own)
                    if n >= 500 { colours[s] = best }
                    let rgba = palette[best].map(\.intValue)
                    report.append("\(s): \(n) px, \(String(format: "%.3f", 100 * Double(row[best]) / Double(n)))% of them \(rgba)")
                }
                let share = Double(agreed) / Double(max(total, 1))
                print("Board3DTests: \(name) from the \(side): \(String(format: "%.4f", 100 * share))% of \(total) pixels agree "
                      + "(\(hidden) over the far side's bare copper left out); "
                      + report.joined(separator: "; "))
                XCTAssertGreaterThan(share, 0.999, "\(name) from the \(side)")
                XCTAssertEqual(Set(colours.values).count, colours.count, "\(name) from the \(side): two kinds in one colour \(colours)")
            }
        }
        XCTAssertGreaterThan(renders, 0)
    }

    /// Footprints' models as KiCad reads and places them: tools/kicad-reference/board3d.py --models writes a board of
    /// footprints with a model of our own (Fixtures/board3d/models/part.wrl, in tenths of an inch as KiCad's library
    /// models are: faces of three, four and five points, one shape turned clockwise, a Transform of its own) placed
    /// every way (turned, moved, scaled, rotated about each axis, on the back), and KiCad's VRML export of it with the
    /// models in it (models-kicad.wrl: KiCad's VRML plugin's triangles, placed by EXPORTER_PCB_VRML about the board's
    /// centre, in tenths of an inch under a scale of 2.54). The port's model, read by VRMLModel and placed by Board3D's
    /// transforms (get3dModelsFromFootprint's), must have the same triangles, each corner within 2 µm, facing the same
    /// way: but for the height the exporter puts a footprint at (GetLayerZ of its copper, half the board's thickness
    /// either way, where the viewer puts it on its paste), which is taken out.
    func testModelsPlacedAsKiCadPlacesThem() throws {
        // (KICAD_MODELS_BOARD names another such board, its export beside it, its models any: then each of our
        // triangles is looked for among all of the export's, the board's own among them)
        let other = ProcessInfo.processInfo.environment["KICAD_MODELS_BOARD"].map { URL(fileURLWithPath: $0) }
        guard let file = other ?? Bundle.module.url(forResource: "models", withExtension: "kicad_pcb", subdirectory: "Fixtures/board3d"),
              let exported = other.map({ $0.deletingPathExtension().appendingPathExtension("wrl") }).map({ URL(fileURLWithPath: $0.path
                  .replacingOccurrences(of: ".wrl", with: "-kicad.wrl")) })
                  ?? Bundle.module.url(forResource: "models-kicad", withExtension: "wrl", subdirectory: "Fixtures/board3d") else {
            return XCTFail("no models board")
        }
        let board = try KiCadBoard.read(file)
        let b = Board3D(board: board, projectURL: nil)
        XCTAssertEqual(b.models.count, 5)
        let resolver = ModelResolver(variables: [:], projectFolder: file.deletingLastPathComponent())
        // the exporter's: in mm about the board's centre (120, 65), y up
        let kicad = try VRMLModel.load(exported)
        func isPart(_ m: VRMLModel.Mesh) -> Bool {
            (abs(m.diffuse.0 - 0.2) < 1e-4 && abs(m.diffuse.1 - 0.25) < 1e-4) || (abs(m.diffuse.0 - 0.8) < 1e-4 && abs(m.diffuse.1 - 0.75) < 1e-4)
        }
        typealias P = (Double, Double, Double)
        var theirs: [[P]] = []
        for m in kicad.meshes where other != nil || isPart(m) {
            for t in 0..<m.triangleCount {
                theirs.append((0..<3).map { k in
                    let o = 9 * t + 3 * k
                    return (Double(m.positions[o]), Double(m.positions[o + 1]), Double(m.positions[o + 2]))
                })
            }
        }
        let thickness = (board.root["general"]?["thickness"]?.number(at: 0) ?? 1.6)
        var ours: [[P]] = []
        for model in b.models {
            guard let url = resolver.resolve(model.filename, libraryFolder: nil) else { return XCTFail("\(model.filename) not found") }
            let part = try VRMLModel.load(url)
            XCTAssertTrue(part.unsupported.isEmpty, "\(part.unsupported)")
            let m = Matrix4(columns: model.transform)
            let back = board.root.all("footprint").first { $0.value("uuid") == model.footprint }?.value("layer") == "B.Cu"
            let viewerZ = (back ? b.layerZ["B.Paste"]!.bottom : b.layerZ["F.Paste"]!.top) / 1e6
            let dz = (back ? -thickness / 2 : thickness / 2) - viewerZ
            for mesh in part.meshes {
                for t in 0..<mesh.triangleCount {
                    ours.append((0..<3).map { k in
                        let o = 9 * t + 3 * k
                        let p = m.apply((Double(mesh.positions[o]), Double(mesh.positions[o + 1]), Double(mesh.positions[o + 2])))
                        return (p.0 - 120, p.1 + 65, p.2 + dz)
                    })
                }
            }
        }
        if other == nil { XCTAssertEqual(ours.count, theirs.count, "triangles") }
        func centroid(_ t: [P]) -> P { ((t[0].0 + t[1].0 + t[2].0) / 3, (t[0].1 + t[1].1 + t[2].1) / 3, (t[0].2 + t[1].2 + t[2].2) / 3) }
        func normal(_ t: [P]) -> P {
            let u = (t[1].0 - t[0].0, t[1].1 - t[0].1, t[1].2 - t[0].2), v = (t[2].0 - t[0].0, t[2].1 - t[0].1, t[2].2 - t[0].2)
            return (u.1 * v.2 - u.2 * v.1, u.2 * v.0 - u.0 * v.2, u.0 * v.1 - u.1 * v.0)
        }
        func dist(_ a: P, _ b: P) -> Double { ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)).squareRoot() }
        var unmatched = 0, worst = 0.0
        var used = Set<Int>()
        for t in ours {
            let c = centroid(t)
            // (the nearest of KiCad's not yet matched, its corners each near one of ours, facing the same way)
            let n1 = normal(t)
            let candidates = theirs.indices.filter {
                let n2 = normal(theirs[$0])
                return !used.contains($0) && dist(centroid(theirs[$0]), c) < 0.01 && n1.0 * n2.0 + n1.1 * n2.1 + n1.2 * n2.2 > 0
            }
            guard let k = candidates.min(by: { dist(centroid(theirs[$0]), c) < dist(centroid(theirs[$1]), c) }) else {
                unmatched += 1
                if other != nil { print("Board3DTests: unmatched, area \((n1.0 * n1.0 + n1.1 * n1.1 + n1.2 * n1.2).squareRoot() / 2) mm²") }
                continue
            }
            let corners = t.map { p in theirs[k].map { dist($0, p) }.min()! }
            worst = max(worst, corners.max()!)
            used.insert(k)
        }
        print("Board3DTests: \(ours.count) triangles of \(b.models.count) models, \(unmatched) unmatched, corners within \(worst * 1000) µm")
        XCTAssertEqual(unmatched, 0)
        XCTAssertLessThan(worst, 0.002)
    }

    /// KiCad's library models (KICAD_VRML_MODELS names a folder of .wrl files, searched through; none: nothing to do)
    /// read with every shape made and nothing the reader leaves out
    func testLibraryModelsRead() throws {
        guard let folder = ProcessInfo.processInfo.environment["KICAD_VRML_MODELS"] else { return }
        let files = FileManager.default.enumerator(atPath: folder)?.compactMap { $0 as? String }.filter { $0.hasSuffix(".wrl") } ?? []
        for f in files.sorted() {
            let m = try VRMLModel.load(URL(fileURLWithPath: folder).appendingPathComponent(f))
            var lo = [Float](repeating: .infinity, count: 3), hi = [Float](repeating: -.infinity, count: 3)
            for mesh in m.meshes {
                for (k, v) in mesh.positions.enumerated() { lo[k % 3] = min(lo[k % 3], v); hi[k % 3] = max(hi[k % 3], v) }
            }
            print("Board3DTests: \(f): \(m.meshes.count) shapes, \(m.meshes.map(\.triangleCount).reduce(0, +)) triangles, "
                  + "x \(lo[0])...\(hi[0]), y \(lo[1])...\(hi[1]), z \(lo[2])...\(hi[2]) mm")
            XCTAssertFalse(m.meshes.isEmpty, f)
            XCTAssertTrue(m.unsupported.isEmpty, "\(f): \(m.unsupported)")
        }
    }

    /// InitSettings on the drawn board's stackup: the body its dielectrics and inner copper, the outer copper and
    /// the masks their own; the copper spaced evenly through the body, the technical layers out from the copper
    func testHeightsFromTheStackup() throws {
        guard let file = Bundle.module.url(forResource: "drawn", withExtension: "kicad_pcb", subdirectory: "Fixtures/board3d") else {
            return XCTFail("no drawn board")
        }
        let b = try Self.board(file)
        func mm(_ v: Double) -> Double { v / 1e6 }
        XCTAssertEqual(mm(b.bodyThickness), 0.2 + 0.018 + 1.0 + 0.018 + 0.2, accuracy: 1e-9)
        XCTAssertEqual(mm(b.frontCopperThickness), 0.035, accuracy: 1e-9)
        XCTAssertEqual(mm(b.backCopperThickness), 0.07, accuracy: 1e-9)
        XCTAssertEqual(mm(b.frontMaskThickness), 0.012, accuracy: 1e-9)
        XCTAssertEqual(mm(b.backMaskThickness), 0.02, accuracy: 1e-9)
        let half = 1.436 / 2
        let expected: [String: (Double, Double)] = [
            "F.Cu": (half, half + 0.035), "In1.Cu": (half - 1.436 / 3, half - 1.436 / 3 + 0.035),
            "In2.Cu": (half - 2 * 1.436 / 3, half - 2 * 1.436 / 3 - 0.07), "B.Cu": (-half, -half - 0.07),
            "F.Mask": (half + 0.035, half + 0.035 + 0.012), "B.Mask": (-half - 0.07, -half - 0.07 - 0.02),
            "F.Paste": (half + 0.035, half + 0.035 + 0.04), "B.Paste": (-half - 0.07, -half - 0.07 - 0.04),
            "F.SilkS": (half + 0.035 + 0.0275, half + 0.035 + 0.0275 + 0.025),
            "B.SilkS": (-half - 0.07 - 0.0275, -half - 0.07 - 0.0275 - 0.025),
            "F.Adhes": (half + 0.035 + 0.055, half + 0.035 + 0.055 + 0.025),
            "B.Adhes": (-half - 0.07 - 0.055, -half - 0.07 - 0.055 - 0.025),
        ]
        for (layer, (bottom, top)) in expected {
            guard let z = b.layerZ[layer] else { XCTFail("no \(layer)"); continue }
            XCTAssertEqual(mm(z.bottom), bottom, accuracy: 1e-9, layer)
            XCTAssertEqual(mm(z.top), top, accuracy: 1e-9, layer)
        }
        // (renderSolderMaskLayer: a mask from its copper side out, as thick as a technical layer)
        let front = b.slabs.first { $0.kind == .soldermask && $0.layer == "F.Mask" }!
        XCTAssertEqual(mm(front.bottom), half + 0.035, accuracy: 1e-9)
        XCTAssertEqual(mm(front.top), half + 0.035 + 0.025, accuracy: 1e-9)
        let back = b.slabs.first { $0.kind == .soldermask && $0.layer == "B.Mask" }!
        XCTAssertEqual(mm(back.bottom), -half - 0.07 - 0.02, accuracy: 1e-9)
        XCTAssertEqual(mm(back.top), -half - 0.07 - 0.02 + 0.025, accuracy: 1e-9)
        let barrels = b.slabs.first { $0.kind == .platedHoles }!
        XCTAssertEqual(mm(barrels.bottom), -half - 0.07, accuracy: 1e-9)
        XCTAssertEqual(mm(barrels.top), half + 0.035, accuracy: 1e-9)
        // a blind via from F.Cu to In2.Cu, a buried one from In1.Cu to In2.Cu
        let vias = b.slabs.filter { $0.kind == .viaBarrel }.map { (mm($0.bottom), mm($0.top)) }.sorted { $0.1 > $1.1 }
        XCTAssertEqual(vias.count, 2)
        if vias.count == 2 {
            XCTAssertEqual(vias[0].0, half - 2 * 1.436 / 3 - 0.07, accuracy: 1e-9)
            XCTAssertEqual(vias[0].1, half + 0.035, accuracy: 1e-9)
            XCTAssertEqual(vias[1].1, half - 1.436 / 3 + 0.035, accuracy: 1e-9)
        }
        // the inner copper is not drawn under a board this opaque
        XCTAssertFalse(b.slabs.contains { $0.layer == "In1.Cu" })
    }

    /// GetLayerColors with the stackup's colours: named and #RRGGBBAA ones, an unspecified silkscreen white, the
    /// dielectrics mixed (an unspecified one black), ENIG gold
    func testColorsFromTheStackup() throws {
        guard let file = Bundle.module.url(forResource: "drawn", withExtension: "kicad_pcb", subdirectory: "Fixtures/board3d") else {
            return XCTFail("no drawn board")
        }
        let c = try Self.board(file).colors
        func check(_ a: Board3D.Color, _ e: (Double, Double, Double, Double), _ what: String) {
            XCTAssertEqual(a.r, e.0, accuracy: 1e-12, what)
            XCTAssertEqual(a.g, e.1, accuracy: 1e-12, what)
            XCTAssertEqual(a.b, e.2, accuracy: 1e-12, what)
            XCTAssertEqual(a.a, e.3, accuracy: 1e-12, what)
        }
        check(c.silkscreenTop, (11 / 255, 11 / 255, 11 / 255, 1), "front silkscreen")
        check(c.silkscreenBottom, (245 / 255, 245 / 255, 245 / 255, 1), "back silkscreen")
        check(c.soldermaskTop, (2 / 255, 59 / 255, 162 / 255, 0.83), "front mask")
        check(c.soldermaskBottom, (32 / 255, 32 / 255, 160 / 255, 212 / 255), "back mask")
        check(c.copper, (178 / 255, 156 / 255, 0, 1), "finish")
        // FR4 natural, then an unspecified dielectric (black), then PTFE natural, each mixed over the ones above
        var a = 0.83 + (1 - 0.83) * 0.83 / 2
        a += (1 - a) * 1 / 2
        a += (1 - a) * 0.9 / 2
        check(c.board, (252 / 255 * 0.9, 252 / 255 * 0.9, 250 / 255 * 0.9, a), "board")
    }
}
