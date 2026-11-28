// Footprints' STEP (and IGES) models as KiCad 10.0.8 makes them triangles, through kicad-cli: pcbnew/exporters/step/
// exporter_step.cpp (EXPORTER_STEP::buildFootprint3DShapes: a footprint's models, its reference the component's name,
// none for a model not shown or not found; buildBoard3DShapes: the origin, the user's), step_pcb_model.cpp
// (STEP_PCB_MODEL::AddComponent: each model a component named by its footprint's reference, located by
// getModelLocation (on top: its footprint's position and turn, then its offset raised by BOARD_OFFSET and the board's
// top copper, then its rotation negated, z, y, x), its file read once for each scale (getModelLabel) and scaled
// (rescaleShapes); performMeshing: the shapes cut into triangles, 0.14 mm and 30° as the 3D viewer's plugin cuts
// them; WriteGLTF: OpenCASCADE's glTF writer given millimetres (SetInputLengthUnit( 0.001 )) and z up
// (RWMesh_CoordinateSystem_Zup), so the file is in metres with y up, KiCad's (x, y, z) its (x, z, -y)) and
// pcbnew/pcbnew_jobs_handler.cpp (JobExportStep); with plugins/3d/oce/loadmodel.cpp (DATA::GetColor: the appearance the
// 3D viewer gives a STEP model's colour, in sRGB, and a shape without one) and common/advanced_config.cpp (the
// viewer's plugin's deflections, the same as the exporter's).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// A model read from a file of a kind the port cannot read itself (STEP, IGES), as KiCad's own code makes it
/// triangles: kicad-cli exports a board of one footprint for each file, each at the origin, unturned, unscaled, as
/// a binary glTF file, and each footprint's triangles are taken back to its model's own millimetres (x, y, z as the
/// model's file has them, z up), where Board3D's transforms place them as the 3D viewer places its models.
public struct MeshModel: Sendable {
    public struct Mesh: Sendable {
        /// x, y, z of each triangle's corners in turn (three corners a triangle), mm
        public var positions: [Float] = []
        /// The normal at each corner, as the file has it (or the triangle's, where it has none)
        public var normals: [Float] = []
        /// The appearance KiCad's 3D viewer gives it (DATA::GetColor): its colour (sRGB) and transparency, a
        /// specular colour and shininess; for a shape with no colour, grey
        public var diffuse: (Float, Float, Float) = (0.6, 0.6, 0.6)
        public var specular: (Float, Float, Float) = (0.04, 0.04, 0.04)
        public var ambient: (Float, Float, Float) = (0.1, 0.1, 0.1)
        public var shininess: Float = 0.05
        public var transparency: Float = 0
        public var triangleCount: Int { positions.count / 9 }
    }

    public var meshes: [Mesh] = []
    public var triangleCount: Int { meshes.map(\.triangleCount).reduce(0, +) }

    /// The file kinds kicad-cli's exporter reads (STEP_PCB_MODEL::fileType's, VRML aside, which the port reads)
    public static func isExported(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return ["step", "stp", "stpz", "iges", "igs", "wrz"].contains(url.pathExtension.lowercased())
            || name.hasSuffix(".step.gz") || name.hasSuffix(".stp.gz")
    }

    // MARK: - The models from KiCad's export

    /// KiCad's (x, y, z) from the glTF file's: its (x, y, z) are KiCad's (x, z, -y), in metres
    static let fromGLTF = Matrix4(m: [[1000, 0, 0, 0], [0, 0, 1000, 0], [0, -1000, 0, 0], [0, 0, 0, 1]])

    /// Each component in a glTF file kicad-cli wrote, by its name (its footprint's reference), the nearest the
    /// scene's root of those of a name (a footprint with two models: the first)
    public static func components(_ asset: GLTFAsset) -> [String: MeshModel] {
        var out: [String: MeshModel] = [:]
        for (name, model) in componentList(asset) where out[name] == nil { out[name] = model }
        return out
    }

    /// The named nodes from the scene's root down, those nearer it first (each component, and anything named under
    /// them, but not OpenCASCADE's labels, "=>[0:1:1:3]"), each with its meshes: each triangle's corners moved by
    /// the matrices from the node down to it (its own mesh too), the node's own taken out, in KiCad's millimetres
    public static func componentList(_ asset: GLTFAsset) -> [(name: String, model: MeshModel)] {
        let world = asset.worldMatrices()
        var out: [(name: String, model: MeshModel)] = []
        var queue = asset.scene, at = 0
        var seen = Set<Int>()
        while at < queue.count {
            let i = queue[at]
            at += 1
            guard seen.insert(i).inserted else { continue }
            let node = asset.nodes[i]
            queue += node.children
            guard !node.name.isEmpty, !node.name.hasPrefix("=>"), let w = world[i], let inverse = w.affineInverse else { continue }
            var model = MeshModel()
            var stack = [i]
            var below = Set<Int>()
            while let n = stack.popLast() {
                guard below.insert(n).inserted, let wn = world[n] else { continue }
                stack += asset.nodes[n].children.reversed()
                guard let mi = asset.nodes[n].mesh else { continue }
                // (from the mesh's own coordinates to the component's, then to KiCad's millimetres)
                let m = fromGLTF * (inverse * wn)
                for p in asset.meshes[mi].primitives where !p.triangles.isEmpty {
                    model.meshes.append(mesh(p, m, asset.materials))
                }
            }
            out.append((node.name, model))
        }
        return out
    }

    /// A primitive's triangles moved by `m`, with their normals, and the appearance its material gives it
    static func mesh(_ p: GLTFAsset.Primitive, _ m: Matrix4, _ materials: [GLTFAsset.Material]) -> Mesh {
        var mesh = Mesh()
        // (normals by the matrix's 3x3 inverse transposed)
        var n: Matrix4?
        if let inv = m.affineInverse {
            var t = Matrix4.identity
            for c in 0..<3 { for r in 0..<3 { t.m[c][r] = inv.m[r][c] } }
            n = t
        }
        mesh.positions.reserveCapacity(p.triangles.count * 3)
        mesh.normals.reserveCapacity(p.triangles.count * 3)
        var k = 0
        while k + 2 < p.triangles.count {
            var corners: [(Double, Double, Double)] = []
            for c in p.triangles[k..<(k + 3)] {
                let q = m.apply((Double(p.positions[3 * c]), Double(p.positions[3 * c + 1]), Double(p.positions[3 * c + 2])))
                corners.append(q)
                mesh.positions += [Float(q.0), Float(q.1), Float(q.2)]
            }
            // the triangle's own normal, for corners with none
            let u = (corners[1].0 - corners[0].0, corners[1].1 - corners[0].1, corners[1].2 - corners[0].2)
            let v = (corners[2].0 - corners[0].0, corners[2].1 - corners[0].1, corners[2].2 - corners[0].2)
            let face = unit((u.1 * v.2 - u.2 * v.1, u.2 * v.0 - u.0 * v.2, u.0 * v.1 - u.1 * v.0))
            for c in p.triangles[k..<(k + 3)] {
                var normal = face
                if let normals = p.normals, let n, 3 * c + 2 < normals.count {
                    let a = (Double(normals[3 * c]), Double(normals[3 * c + 1]), Double(normals[3 * c + 2]))
                    let d = unit(n.apply(a))
                    if d != (0, 0, 0) { normal = d }
                }
                mesh.normals += [Float(normal.0), Float(normal.1), Float(normal.2)]
            }
            k += 3
        }
        // DATA::GetColor: a colour of its own, in sRGB (OCC_COLOR_SPACE), its alpha the opacity; else the default grey
        if let i = p.material, i >= 0, i < materials.count {
            let c = materials[i].baseColor
            if c.count >= 3 {
                mesh.diffuse = (srgb(c[0]), srgb(c[1]), srgb(c[2]))
                mesh.transparency = Float(1 - (c.count >= 4 ? c[3] : 1))
                mesh.specular = (0.12, 0.12, 0.12)
                mesh.shininess = 0.1
            }
        }
        return mesh
    }

    static func unit(_ v: (Double, Double, Double)) -> (Double, Double, Double) {
        let l = (v.0 * v.0 + v.1 * v.1 + v.2 * v.2).squareRoot()
        return l > 0 && l.isFinite ? (v.0 / l, v.1 / l, v.2 / l) : (0, 0, 0)
    }

    /// Quantity_Color's linear RGB to sRGB (Convert_LinearRGB_To_sRGB)
    static func srgb(_ c: Double) -> Float {
        Float(c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055)
    }

    // MARK: - kicad-cli

    /// The board kicad-cli exports: one footprint for each file, M1, M2..., at the origin on the front, its model
    /// unmoved, unturned, unscaled (in KiCad 8's format, which every KiCad since reads)
    public static func exportBoard(_ files: [URL]) -> String {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func uuid(_ kind: Int, _ i: Int) -> String { String(format: "\"00000000-0000-0000-%04d-%012d\"", kind, i) }
        var text = """
        (kicad_pcb (version 20240108) (generator "jspice") (generator_version "8.0")
          (general (thickness 1.6))
          (layers (0 "F.Cu" signal) (31 "B.Cu" signal) (37 "F.SilkS" user) (44 "Edge.Cuts" user))
          (gr_rect (start -1 -1) (end 1 1) (stroke (width 0.1) (type default)) (fill none) (layer "Edge.Cuts") (uuid \(uuid(0, 1))))
        """
        for (i, file) in files.enumerated() {
            text += """

              (footprint "jspice:M\(i + 1)" (layer "F.Cu") (uuid \(uuid(1, i + 1))) (at 0 0)
                (property "Reference" "M\(i + 1)" (at 0 0 0) (layer "F.SilkS") (uuid \(uuid(2, i + 1))) (effects (font (size 1 1))))
                (attr smd)
                (model \(quoted(file.path)) (offset (xyz 0 0 0)) (scale (xyz 1 1 1)) (rotate (xyz 0 0 0))))
            """
        }
        return text + "\n)\n"
    }

    /// kicad-cli's arguments for exporting `board` to `glb`: the models alone (no board body, no copper), about the
    /// board's own origin
    public static func exportArguments(board: URL, glb: URL) -> [String] {
        ["pcb", "export", "glb", "--no-board-body", "--user-origin", "0x0mm", "--force", "--output", glb.path, board.path]
    }

    public struct ExportError: Error, CustomStringConvertible {
        public var description: String
    }

    /// What became of the files: each one's triangles, and the files KiCad could not read (its messages)
    public struct Export: Sendable {
        public var models: [URL: MeshModel] = [:]
        public var failed: [URL] = []
        public var messages = ""
        /// The glTF file it read
        public var glb: URL?
    }

    /// The files made triangles by kicad-cli (the board above exported, in a folder of its own, run where the
    /// caller runs it: not on the main thread), the glTF file kept in `cache` named by what went into it (the
    /// files' contents and KiCad's version), so that the same models are not exported again
    public static func export(_ files: [URL], installation: KiCadInstallation, cache: URL?) throws -> Export {
        var result = Export()
        let unique = Array(Set(files.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        guard !unique.isEmpty else { return result }
        let board = exportBoard(unique)
        var hash = FNV1a()
        hash.add(installation.version)
        hash.add(board)
        for f in unique {
            if let data = try? Data(contentsOf: f) { hash.add(data) } else { hash.add("unreadable") }
        }
        let key = String(format: "%016llx", hash.value)
        let fm = FileManager.default
        let cached = cache?.appendingPathComponent("\(key).glb")
        if let cached, fm.fileExists(atPath: cached.path), let asset = try? GLTFAsset.read(cached) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: cached.path)
            result.glb = cached
            collect(asset, unique, &result)
            return result
        }
        let folder = fm.temporaryDirectory.appendingPathComponent("jspice-models-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let boardFile = folder.appendingPathComponent("models.kicad_pcb"), glb = folder.appendingPathComponent("models.glb")
        try board.write(to: boardFile, atomically: true, encoding: .utf8)
        let run = try KiCadCLI.run(installation.cli, exportArguments(board: boardFile, glb: glb), in: folder)
        result.messages = (run.output + run.error).trimmingCharacters(in: .whitespacesAndNewlines)
        // (kicad-cli says it failed where it could not add a model, but writes the others)
        guard fm.fileExists(atPath: glb.path) else {
            throw ExportError(description: "kicad-cli could not export the models (status \(run.status)): " + String(result.messages.suffix(400)))
        }
        let asset = try GLTFAsset.read(glb)
        if let cached {
            try? fm.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staged = cached.deletingLastPathComponent().appendingPathComponent(".\(key)-\(UUID().uuidString).glb")
            if (try? fm.copyItem(at: glb, to: staged)) != nil {
                try? fm.removeItem(at: cached)
                if (try? fm.moveItem(at: staged, to: cached)) != nil { result.glb = cached } else { try? fm.removeItem(at: staged) }
            }
            prune(cached.deletingLastPathComponent(), keeping: cacheLimit)
        }
        collect(asset, unique, &result)
        return result
    }

    /// How many exports the cache keeps (the oldest let go first)
    public static let cacheLimit = 40

    static func prune(_ folder: URL, keeping limit: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let files = names.filter { $0.pathExtension == "glb" && !$0.lastPathComponent.hasPrefix(".") }
        guard files.count > limit else { return }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        for f in files.sorted(by: { date($0) < date($1) }).prefix(files.count - limit) { try? fm.removeItem(at: f) }
    }

    static func collect(_ asset: GLTFAsset, _ files: [URL], _ result: inout Export) {
        let components = components(asset)
        for (i, f) in files.enumerated() {
            if let m = components["M\(i + 1)"], !m.meshes.isEmpty { result.models[f] = m } else { result.failed.append(f) }
        }
    }

    /// Where the app keeps the exported models: the user's caches folder
    public static var defaultCache: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("JSpice/STEPModels", isDirectory: true)
    }
}

/// FNV-1a, 64 bits: the cache's names
struct FNV1a {
    var value: UInt64 = 0xcbf2_9ce4_8422_2325
    mutating func add(_ data: Data) {
        data.withUnsafeBytes { raw in
            for b in raw { value = (value ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        }
        add(UInt64(data.count))
    }
    mutating func add(_ s: String) { add(Data(s.utf8)) }
    mutating func add(_ n: UInt64) {
        var v = n
        for _ in 0..<8 {
            value = (value ^ (v & 0xFF)) &* 0x0000_0100_0000_01B3
            v >>= 8
        }
    }
}
