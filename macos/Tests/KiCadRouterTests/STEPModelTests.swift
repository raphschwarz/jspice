import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// Footprints' STEP models as the 3D view shows them: made triangles by KiCad's own exporter (kicad-cli pcb export
/// glb, MeshModel.export), read back by GLTFAsset and placed by Board3D's transforms. On Fixtures/stepmodels (board3d.py
/// --step-models: footprints with STEP models of our own made by kicad-cli's STEP export, placed every way, on both
/// sides, two on one footprint; one with a VRML model, one not fitted, one whose model is missing):
/// - the reader against tools/kicad-reference/glb.py, the glTF 2.0 specification read with Python's standard library
///   alone: every node's world matrix, every mesh's triangles and the box round each node's, every material, the same
///   to the last bit; on the models' own export and on KiCad's export of the whole board, and on a file made here
///   that takes the reader down the ways kicad-cli's files do not;
/// - each model's triangles, placed as the port places them, against KiCad's export of the whole board, where KiCad's
///   exporter places them (getModelLocation): the same triangles, corner for corner, but for the height the exporter
///   puts each side's models at, which is taken out (the same for every model on a side);
/// - each model's triangles within its footprint's courtyard (BoardDRC's), and above its side of the board.
/// They need KiCad's kicad-cli (JSPICE_REQUIRE_KICAD: fail without it).
final class STEPModelTests: XCTestCase {
    static var fixture: URL? { Bundle.module.url(forResource: "stepmodels", withExtension: nil, subdirectory: "Fixtures") }

    static func installation() -> KiCadInstallation? {
        guard let i = KiCadInstallation.find(), i.problem == nil else { return nil }
        return i
    }

    static func needKiCad() -> Bool {
        if ProcessInfo.processInfo.environment["JSPICE_REQUIRE_KICAD"] != nil { XCTFail("KiCad 10's kicad-cli is needed") }
        return false
    }

    static func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stepmodels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The fixture's board, its 3D view, and its models' files as the port finds them
    static func board() throws -> (KiCadBoard, Board3D, URL, ModelResolver) {
        let folder = try XCTUnwrap(fixture)
        let file = folder.appendingPathComponent("board.kicad_pcb")
        let board = try KiCadBoard.read(file)
        let b = Board3D(board: board, projectURL: folder.appendingPathComponent("board.kicad_pro"))
        return (board, b, file, ModelResolver(variables: [:], projectFolder: folder))
    }

    /// KiCad's export of the whole board, its models in place
    static func exportBoard(_ file: URL, _ installation: KiCadInstallation, into folder: URL) throws -> URL {
        let glb = folder.appendingPathComponent("board.glb")
        // (its status is 2 where it could not add a model, as here: the VRML model, which OpenCASCADE before 7.9
        // does not read, and the one missing)
        let run = try KiCadCLI.run(installation.cli, MeshModel.exportArguments(board: file, glb: glb), in: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: glb.path), run.error)
        return glb
    }

    // MARK: - The reader against glb.py

    static func hex(_ v: Any?) -> Double? { (v as? String).flatMap { Double($0) } }

    /// The reader's file against glb.py's reading of it: the differences, and how many numbers were compared
    static func compare(_ glb: URL) throws -> (differences: [String], numbers: Int, triangles: Int) {
        let asset = try GLTFAsset.read(glb)
        guard let data = try ZoneEditingTests.run("glb.py", [glb.path]),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (["glb.py did not read \(glb.lastPathComponent)"], 0, 0)
        }
        var out: [String] = []
        var numbers = 0, triangles = 0
        func same(_ a: Double, _ b: Double?, _ what: String) {
            numbers += 1
            if b == nil || a.bitPattern != b!.bitPattern { out.append("\(what): \(a) against \(b.map { "\($0)" } ?? "nil")") }
        }
        let nodes = json["nodes"] as? [[String: Any]] ?? []
        let world = asset.worldMatrices()
        if nodes.count != asset.nodes.count { out.append("\(asset.nodes.count) nodes against \(nodes.count)") }
        for (i, (n, theirs)) in zip(asset.nodes, nodes).enumerated() {
            if n.name != theirs["name"] as? String { out.append("node \(i): name \(n.name)") }
            if (n.mesh ?? -1) != theirs["mesh"] as? Int { out.append("node \(i): mesh") }
            if n.children != (theirs["children"] as? [Int] ?? []) { out.append("node \(i): children") }
            guard let w = world[i] else {
                if theirs["world"] != nil { out.append("node \(i) not in the scene") }
                continue
            }
            let tw = theirs["world"] as? [Any] ?? []
            if tw.count != 16 { out.append("node \(i): no world matrix"); continue }
            for (k, v) in w.columns.enumerated() { same(v, hex(tw[k]), "node \(i) world[\(k)]") }
            guard let mi = n.mesh else { continue }
            var lo = [Double](repeating: .infinity, count: 3), hi = [Double](repeating: -.infinity, count: 3)
            var count = 0
            for p in asset.meshes[mi].primitives {
                count += p.triangleCount
                for c in p.triangles {
                    let q = w.apply((Double(p.positions[3 * c]), Double(p.positions[3 * c + 1]), Double(p.positions[3 * c + 2])))
                    lo = [min(lo[0], q.0), min(lo[1], q.1), min(lo[2], q.2)]
                    hi = [max(hi[0], q.0), max(hi[1], q.1), max(hi[2], q.2)]
                }
            }
            triangles += count
            if count != theirs["triangles"] as? Int { out.append("node \(i): \(count) triangles against \(theirs["triangles"] ?? "none")") }
            if count > 0 {
                let tb = theirs["bounds"] as? [Any] ?? []
                if tb.count != 6 { out.append("node \(i): no bounds"); continue }
                for (k, v) in (lo + hi).enumerated() { same(v, hex(tb[k]), "node \(i) bounds[\(k)]") }
            }
        }
        let meshes = json["meshes"] as? [[String: Any]] ?? []
        if meshes.count != asset.meshes.count { out.append("\(asset.meshes.count) meshes against \(meshes.count)") }
        for (i, (m, theirs)) in zip(asset.meshes, meshes).enumerated() {
            if m.name != theirs["name"] as? String { out.append("mesh \(i): name") }
            let prims = theirs["primitives"] as? [[String: Any]] ?? []
            if prims.count != m.primitives.count { out.append("mesh \(i): \(m.primitives.count) primitives against \(prims.count)"); continue }
            for (k, (p, tp)) in zip(m.primitives, prims).enumerated() {
                let what = "mesh \(i) primitive \(k)"
                if p.mode != tp["mode"] as? Int { out.append("\(what): mode") }
                if p.vertexCount != tp["vertices"] as? Int { out.append("\(what): vertices") }
                if (p.normals != nil) != (tp["normals"] as? Bool) { out.append("\(what): normals") }
                if (p.material ?? -1) != tp["material"] as? Int { out.append("\(what): material") }
                if p.triangleCount != tp["triangles"] as? Int { out.append("\(what): \(p.triangleCount) triangles against \(tp["triangles"] ?? "none")") }
                if p.triangleCount > 0 {
                    if Array(p.triangles.prefix(3)) != (tp["first"] as? [Int] ?? []) { out.append("\(what): first triangle") }
                    if Array(p.triangles.suffix(3)) != (tp["last"] as? [Int] ?? []) { out.append("\(what): last triangle") }
                }
            }
        }
        let materials = json["materials"] as? [[String: Any]] ?? []
        if materials.count != asset.materials.count { out.append("\(asset.materials.count) materials against \(materials.count)") }
        for (i, (m, theirs)) in zip(asset.materials, materials).enumerated() {
            let tc = theirs["baseColor"] as? [Any] ?? []
            if tc.count != m.baseColor.count { out.append("material \(i): base colour"); continue }
            for (k, v) in m.baseColor.enumerated() { same(v, hex(tc[k]), "material \(i) base colour[\(k)]") }
            same(m.metallic, hex(theirs["metallic"]), "material \(i) metallic")
            same(m.roughness, hex(theirs["roughness"]), "material \(i) roughness")
        }
        if asset.scene != (json["scene"] as? [Int] ?? []) { out.append("scene") }
        return (out, numbers, triangles)
    }

    func testReaderAsTheSpecificationReadsIt() throws {
        guard let installation = Self.installation() else { _ = Self.needKiCad(); return }
        let (_, b, file, resolver) = try Self.board()
        let tmp = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let files = b.models.compactMap { resolver.resolve($0.filename, libraryFolder: nil) }.filter(MeshModel.isExported)
        let export = try MeshModel.export(files, installation: installation, cache: tmp)
        let models = try XCTUnwrap(export.glb, "the export was not kept")
        let whole = try Self.exportBoard(file, installation, into: tmp)
        for glb in [models, whole] {
            let (differences, numbers, triangles) = try Self.compare(glb)
            print("STEPModelTests: \(glb.lastPathComponent): \(numbers) numbers, \(triangles) triangles compared, "
                  + "\(differences.count) differences")
            XCTAssertEqual(differences, [], glb.lastPathComponent)
            XCTAssertGreaterThan(triangles, 0)
        }
    }

    /// A file of our own, in the ways kicad-cli's do not go: matrices and scales, nested nodes, a node outside the
    /// scene, bytes, shorts and ints for indices, no indices, interleaved vertices, strips, fans and lines, no
    /// material, a material with factors of its own
    func testReaderOnAFileOfOurOwn() throws {
        var bin = Data()
        func align() { while bin.count % 4 != 0 { bin.append(0) } }
        func floats(_ v: [Float]) -> Int {
            align()
            let at = bin.count
            for f in v { withUnsafeBytes(of: f.bitPattern.littleEndian) { bin.append(contentsOf: $0) } }
            return at
        }
        var views: [[String: Any]] = [], accessors: [[String: Any]] = []
        func view(_ at: Int, _ length: Int, stride: Int? = nil) -> Int {
            var v: [String: Any] = ["buffer": 0, "byteOffset": at, "byteLength": length]
            if let stride { v["byteStride"] = stride }
            views.append(v)
            return views.count - 1
        }
        func accessor(_ view: Int, _ offset: Int, _ kind: Int, _ count: Int, _ type: String) -> Int {
            accessors.append(["bufferView": view, "byteOffset": offset, "componentType": kind, "count": count, "type": type])
            return accessors.count - 1
        }
        // a square's four corners, then the same interleaved with normals
        let square: [Float] = [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0.5]
        let pv = view(floats(square), 48)
        let positions = accessor(pv, 0, 5126, 4, "VEC3")
        var interleaved: [Float] = []
        for k in 0..<5 { interleaved += [Float(k) * 0.3, Float(k % 2), 0.25 * Float(k), 0, 0, 1] }
        let iv = view(floats(interleaved), 120, stride: 24)
        let ip = accessor(iv, 0, 5126, 5, "VEC3"), inorm = accessor(iv, 12, 5126, 5, "VEC3")
        align()
        let b8 = bin.count
        bin.append(contentsOf: [0, 1, 2, 0, 2, 3] as [UInt8])
        let i8 = accessor(view(b8, 6), 0, 5121, 6, "SCALAR")
        align()
        let b16 = bin.count
        for v in [UInt16(0), 1, 2, 3, 4] { withUnsafeBytes(of: v.littleEndian) { bin.append(contentsOf: $0) } }
        let i16 = accessor(view(b16, 10), 0, 5123, 5, "SCALAR")
        align()
        let b32 = bin.count
        for v in [UInt32(4), 3, 2, 1, 0, 2, 4] { withUnsafeBytes(of: v.littleEndian) { bin.append(contentsOf: $0) } }
        let i32 = accessor(view(b32, 28), 0, 5125, 7, "SCALAR")
        align()
        let meshes: [[String: Any]] = [
            ["name": "square", "primitives": [["attributes": ["POSITION": positions], "indices": i8, "material": 0]]],
            ["name": "strips", "primitives": [["attributes": ["POSITION": ip, "NORMAL": inorm], "indices": i16, "mode": 5],
                                             ["attributes": ["POSITION": ip], "indices": i32, "mode": 6, "material": 1],
                                             ["attributes": ["POSITION": ip], "mode": 4],
                                             ["attributes": ["POSITION": positions], "mode": 1]]],
        ]
        let nodes: [[String: Any]] = [
            ["name": "root", "children": [1, 3], "translation": [10, -2, 0.5], "rotation": [0, 0, 0.3826834323650898, 0.9238795325112867]],
            ["name": "a", "children": [2], "matrix": [2, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0.1, 0.2, 0.3, 1], "mesh": 0],
            ["name": "b", "mesh": 1, "scale": [1.5, 0.5, 2], "rotation": [0.18257418583505536, 0.3651483716701107, 0.5477225575051661, 0.7302967433402214]],
            ["name": "c", "mesh": 1, "translation": [-1, 0, 0]],
            ["name": "outside", "mesh": 0],
        ]
        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "STEPModelTests"],
            "scene": 0, "scenes": [["nodes": [0]]], "nodes": nodes, "meshes": meshes, "accessors": accessors, "bufferViews": views,
            "buffers": [["byteLength": bin.count]],
            "materials": [["name": "red", "pbrMetallicRoughness": ["baseColorFactor": [0.8, 0.1, 0.05, 0.5], "metallicFactor": 0.25,
                                                                   "roughnessFactor": 0.75]],
                          ["name": "plain"]],
        ]
        var text = try JSONSerialization.data(withJSONObject: json)
        while text.count % 4 != 0 { text.append(0x20) }
        var glb = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { glb.append(contentsOf: $0) } }
        u32(0x4654_6C67); u32(2); u32(12 + 8 + text.count + 8 + bin.count)
        u32(text.count); u32(0x4E4F_534A); glb.append(text)
        u32(bin.count); u32(0x004E_4942); glb.append(bin)
        let tmp = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("ours.glb")
        try glb.write(to: file)
        let asset = try GLTFAsset.read(file)
        XCTAssertEqual(asset.meshes[1].primitives.map(\.triangleCount), [3, 5, 1, 0])
        XCTAssertNil(asset.worldMatrices()[4])
        guard (try? ZoneEditingTests.run("glb.py", [file.path])) ?? nil != nil else {
            if ProcessInfo.processInfo.environment["JSPICE_REQUIRE_KICAD"] != nil { XCTFail("python3 is needed") }
            return
        }
        let (differences, numbers, triangles) = try Self.compare(file)
        print("STEPModelTests: ours.glb: \(numbers) numbers, \(triangles) triangles compared, \(differences.count) differences")
        XCTAssertEqual(differences, [])
    }

    // MARK: - The models placed

    /// The port's models placed: each footprint's (by reference) models' triangles, corner by corner, in the 3D
    /// view's millimetres (x, y against the board's y, z up from the board's middle)
    static func placed(_ b: Board3D, _ board: KiCadBoard, _ export: MeshModel.Export, _ resolver: ModelResolver)
        -> [String: [[(Double, Double, Double)]]] {
        var out: [String: [[(Double, Double, Double)]]] = [:]
        for model in b.models {
            guard let url = resolver.resolve(model.filename, libraryFolder: nil), let mesh = export.models[url] else { continue }
            let m = Matrix4(columns: model.transform)
            var corners: [(Double, Double, Double)] = []
            for part in mesh.meshes {
                var k = 0
                while k + 2 < part.positions.count {
                    corners.append(m.apply((Double(part.positions[k]), Double(part.positions[k + 1]), Double(part.positions[k + 2]))))
                    k += 3
                }
            }
            out[model.reference, default: []].append(corners)
        }
        return out
    }

    func testModelsPlacedAsKiCadPlacesThem() throws {
        guard let installation = Self.installation() else { _ = Self.needKiCad(); return }
        let (board, b, file, resolver) = try Self.board()
        let tmp = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // what the 3D view shows: not the footprint not fitted; the VRML model read by the port; one not found
        XCTAssertEqual(b.models.map(\.reference), ["S1", "S6", "S6", "S3", "X1", "W1", "S2", "S4", "S5"])
        let urls = b.models.map { resolver.resolve($0.filename, libraryFolder: nil) }
        XCTAssertEqual(urls.filter { $0 == nil }.count, 1)
        let files = urls.compactMap { $0 }.filter(MeshModel.isExported)
        XCTAssertEqual(files.count, 7)
        let export = try MeshModel.export(files, installation: installation, cache: nil)
        XCTAssertEqual(export.failed, [])
        XCTAssertEqual(export.models.count, 2)
        let ours = Self.placed(b, board, export, resolver)
        // KiCad's, its models placed by its exporter
        let whole = try GLTFAsset.read(try Self.exportBoard(file, installation, into: tmp))
        var theirs: [String: [[(Double, Double, Double)]]] = [:]
        let world = whole.worldMatrices()
        var queue = whole.scene, at = 0
        while at < queue.count {
            let i = queue[at]
            at += 1
            queue += whole.nodes[i].children
            let name = whole.nodes[i].name
            guard ["S1", "S2", "S3", "S4", "S5", "S6", "D1"].contains(name) else { continue }
            var corners: [(Double, Double, Double)] = []
            var stack = [i]
            while let n = stack.popLast() {
                stack += whole.nodes[n].children.reversed()
                guard let mi = whole.nodes[n].mesh, let w = world[n] else { continue }
                let m = MeshModel.fromGLTF * w
                for p in whole.meshes[mi].primitives {
                    for c in p.triangles {
                        corners.append(m.apply((Double(p.positions[3 * c]), Double(p.positions[3 * c + 1]), Double(p.positions[3 * c + 2]))))
                    }
                }
            }
            theirs[name, default: []].append(corners)
        }
        // the footprint not fitted is exported, but not shown
        XCTAssertNotNil(theirs["D1"])
        XCTAssertNil(ours["D1"])
        var heights: [Bool: [Double]] = [:]
        var compared = 0, boxes = 0, unmatched = 0, worstXY = 0.0, worstZ = 0.0
        for ref in ["S1", "S2", "S3", "S4", "S5", "S6"] {
            guard let o = ours[ref], let t = theirs[ref], o.count == t.count else {
                XCTFail("\(ref): \(ours[ref]?.count ?? 0) models against KiCad's \(theirs[ref]?.count ?? 0)")
                continue
            }
            let back = board.root.all("footprint").first { BoardWorld.FootprintPlacement($0).reference == ref }?.value("layer") == "B.Cu"
            let scaled = Set(board.root.all("footprint").filter { BoardWorld.FootprintPlacement($0).reference == ref }
                .flatMap { $0.all("model") }.map { m -> Bool in
                    guard let v = m["scale"]?["xyz"] else { return false }
                    return (0..<3).contains { (v.number(at: $0) ?? 1) != 1 }
                })
            for (a, k) in zip(o, t) {
                guard let first = a.first, let kfirst = k.first else { XCTFail("\(ref): no triangles"); continue }
                if scaled.contains(true) {
                    // (a model scaled: KiCad's exporter scales the shape before cutting it into triangles, the viewer
                    // after, so the triangles differ; their boxes do not, the parts' extremes being corners)
                    func box(_ c: [(Double, Double, Double)]) -> [Double] {
                        [c.map(\.0).min()!, c.map(\.1).min()!, c.map(\.2).min()!, c.map(\.0).max()!, c.map(\.1).max()!, c.map(\.2).max()!]
                    }
                    let (ba, bk) = (box(a), box(k))
                    let dz = bk[2] - ba[2]
                    heights[back, default: []].append(dz)
                    for i in [0, 1, 3, 4] { worstXY = max(worstXY, abs(ba[i] - bk[i])) }
                    worstZ = max(worstZ, abs(bk[5] - ba[5] - dz))
                    boxes += 1
                    continue
                }
                XCTAssertEqual(a.count, k.count, "\(ref): triangles")
                let dz = kfirst.2 - first.2
                heights[back, default: []].append(dz)
                // (each of our triangles matched with KiCad's nearest not yet matched, its corners in their order:
                // the two files' triangles are the same but not always in the same order)
                var used = Set<Int>()
                for t in stride(from: 0, to: a.count - 2, by: 3) {
                    func distance(_ u: Int) -> Double {
                        (0..<3).map { c in
                            let (p, q) = (a[t + c], k[u + c])
                            return max(abs(p.0 - q.0), abs(p.1 - q.1), abs(q.2 - p.2 - dz))
                        }.max()!
                    }
                    guard let u = stride(from: 0, to: k.count - 2, by: 3).filter({ !used.contains($0) }).min(by: { distance($0) < distance($1) }) else {
                        unmatched += 1
                        continue
                    }
                    used.insert(u)
                    for c in 0..<3 {
                        let (p, q) = (a[t + c], k[u + c])
                        worstXY = max(worstXY, abs(p.0 - q.0), abs(p.1 - q.1))
                        worstZ = max(worstZ, abs(q.2 - p.2 - dz))
                        compared += 1
                    }
                }
            }
        }
        print("STEPModelTests: \(compared) corners and \(boxes) scaled models' boxes placed (\(unmatched) unmatched), within \(worstXY * 1e6) nm across and \(worstZ * 1e6) nm in height of KiCad's, "
              + "KiCad's heights less the viewer's: \(heights)")
        XCTAssertGreaterThan(compared, 0)
        XCTAssertEqual(unmatched, 0)
        XCTAssertLessThan(worstXY, 1e-4)
        XCTAssertLessThan(worstZ, 1e-4)
        // (each side's models raised, or lowered, by the same height)
        for (_, dz) in heights { XCTAssertLessThan((dz.max() ?? 0) - (dz.min() ?? 0), 1e-4) }
        XCTAssertEqual(heights.count, 2)
    }

    func testModelsWithinTheirCourtyards() throws {
        guard let installation = Self.installation() else { _ = Self.needKiCad(); return }
        let (board, b, _, resolver) = try Self.board()
        let files = b.models.compactMap { resolver.resolve($0.filename, libraryFolder: nil) }.filter(MeshModel.isExported)
        let export = try MeshModel.export(files, installation: installation, cache: nil)
        let drc = BoardDRC(board: board)
        let footprints = board.root.all("footprint")
        let top = b.layerZ["F.Paste"]!.top / 1e6, bottom = b.layerZ["B.Paste"]!.bottom / 1e6
        var corners = 0, outside = 0, wrong = 0, models = 0
        for model in b.models {
            guard let url = resolver.resolve(model.filename, libraryFolder: nil), let mesh = export.models[url] else { continue }
            guard let index = footprints.firstIndex(where: { $0.value("uuid") == model.footprint }) else { XCTFail("no footprint"); continue }
            let back = footprints[index].value("layer") == "B.Cu"
            let courtyard = drc.courtyards(index).courtyard(back: back)
            XCTAssertGreaterThan(courtyard.outlineCount, 0, model.reference)
            let m = Matrix4(columns: model.transform)
            models += 1
            // (a model turned about x or y dips below the board where it is turned: its height is not checked)
            let node = footprints[index].all("model").first { $0.text(at: 0) == model.filename }
            let rotate = node?["rotate"]?["xyz"]
            let flat = (rotate?.number(at: 0) ?? 0) == 0 && (rotate?.number(at: 1) ?? 0) == 0
            for part in mesh.meshes {
                var k = 0
                while k + 2 < part.positions.count {
                    let p = m.apply((Double(part.positions[k]), Double(part.positions[k + 1]), Double(part.positions[k + 2])))
                    k += 3
                    corners += 1
                    if !courtyard.pointInside(IPoint(Int((p.0 * 1e6).rounded()), Int((-p.1 * 1e6).rounded()))) { outside += 1 }
                    // (on its side of the board, within a millimetre and a half of it)
                    if flat, back ? !(p.2 <= bottom + 1e-6 && p.2 >= bottom - 1.5) : !(p.2 >= top - 1e-6 && p.2 <= top + 1.5) { wrong += 1 }
                }
            }
        }
        print("STEPModelTests: \(models) models, \(corners) corners: \(outside) outside their courtyards, \(wrong) off their side")
        XCTAssertEqual(models, 7)
        XCTAssertEqual(outside, 0)
        XCTAssertEqual(wrong, 0)
        // the appearance KiCad's viewer gives them: the colours from the STEP files, in sRGB
        for (_, mesh) in export.models {
            for part in mesh.meshes {
                XCTAssertEqual(part.specular.0, 0.12)
                XCTAssertEqual(part.positions.count, part.normals.count)
            }
        }
    }

    /// The cache: a second export of the same files reads the file the first kept, and KiCad is not run
    func testExportKeptAndReadAgain() throws {
        guard let installation = Self.installation() else { _ = Self.needKiCad(); return }
        let (_, b, _, resolver) = try Self.board()
        let tmp = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let files = b.models.compactMap { resolver.resolve($0.filename, libraryFolder: nil) }.filter(MeshModel.isExported)
        let first = try MeshModel.export(files, installation: installation, cache: tmp)
        XCTAssertFalse(first.messages.isEmpty)
        // (a kicad-cli that is not there: the cache alone answers)
        var gone = installation
        gone.cli = tmp.appendingPathComponent("no-kicad-cli")
        let second = try MeshModel.export(files.reversed(), installation: gone, cache: tmp)
        XCTAssertEqual(second.glb, first.glb)
        XCTAssertEqual(second.messages, "")
        XCTAssertEqual(Set(second.models.keys), Set(first.models.keys))
        for (url, m) in first.models { XCTAssertEqual(second.models[url]?.triangleCount, m.triangleCount) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp.path).filter { $0.hasSuffix(".glb") }.count, 1)
    }
}
