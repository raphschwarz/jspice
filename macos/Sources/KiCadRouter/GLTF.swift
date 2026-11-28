// A reader of binary glTF 2.0 files (.glb) as the Khronos Group's glTF 2.0 specification has them, for the meshes
// kicad-cli's exporters write (STEPModels.swift): not from KiCad's code.

import Foundation

/// A binary glTF 2.0 file: its nodes (each with its own matrix), meshes (each primitive's positions, normals and
/// triangles) and materials (their metallic-roughness factors). What it does not read: textures, skins, morph
/// targets, cameras, sparse accessors, buffers outside the file, extensions; primitives of points and lines are kept
/// but have no triangles.
public struct GLTFAsset: Sendable {
    public struct Node: Sendable {
        public var name: String
        public var children: [Int]
        public var mesh: Int?
        /// The node's own matrix: its "matrix", or its translation, rotation and scale as T * R * S
        public var matrix: Matrix4
    }

    public struct Primitive: Sendable {
        /// 0 points, 1 lines, 2 line loop, 3 line strip, 4 triangles, 5 triangle strip, 6 triangle fan
        public var mode: Int
        /// x, y, z of each vertex in turn
        public var positions: [Float]
        public var normals: [Float]?
        /// The triangles' corners, three a triangle, as indices into the vertices
        public var triangles: [Int]
        public var material: Int?
        public var vertexCount: Int { positions.count / 3 }
        public var triangleCount: Int { triangles.count / 3 }
    }

    public struct Mesh: Sendable {
        public var name: String
        public var primitives: [Primitive]
    }

    public struct Material: Sendable {
        public var name: String
        /// Linear red, green, blue and alpha
        public var baseColor: [Double]
        public var metallic: Double
        public var roughness: Double
        public var emissive: [Double]
        public var alphaMode: String
        public var doubleSided: Bool
    }

    public var nodes: [Node] = []
    public var meshes: [Mesh] = []
    public var materials: [Material] = []
    /// The scene's root nodes
    public var scene: [Int] = []
    /// asset.generator, and asset.extras' strings (kicad-cli's "generator", "pcb_name"...)
    public var generator = ""
    public var extras: [String: String] = [:]

    public enum ReadError: Error, CustomStringConvertible {
        case notGLB, malformed(String)
        public var description: String {
            switch self {
            case .notGLB: return "not a binary glTF 2.0 file"
            case .malformed(let m): return "glTF: \(m)"
            }
        }
    }

    public static func read(_ url: URL) throws -> GLTFAsset { try GLTFAsset(glb: try Data(contentsOf: url)) }

    /// The file's JSON chunk and its first binary chunk read
    public init(glb data: Data) throws {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        guard bytes.count >= 12, u32(0) == 0x4654_6C67, u32(4) == 2 else { throw ReadError.notGLB }
        let length = min(Int(u32(8)), bytes.count)
        var at = 12
        var json: [String: Any]?
        var binary: ArraySlice<UInt8>?
        while at + 8 <= length {
            let size = Int(u32(at)), kind = u32(at + 4)
            guard at + 8 + size <= length else { throw ReadError.malformed("a chunk runs past the end of the file") }
            let chunk = bytes[(at + 8)..<(at + 8 + size)]
            if kind == 0x4E4F_534A {
                var parser = JSONReader(bytes: Array(chunk))
                json = try parser.document() as? [String: Any]
            } else if kind == 0x004E_4942, binary == nil {
                binary = chunk
            }
            at += 8 + size
        }
        guard let json else { throw ReadError.malformed("no JSON chunk") }
        try self.init(json: json, binary: binary.map { Array($0) } ?? [])
    }

    init(json: [String: Any], binary: [UInt8]) throws {
        func list(_ key: String, _ dict: [String: Any] = json) -> [[String: Any]] { dict[key] as? [[String: Any]] ?? [] }
        func doubles(_ v: Any?) -> [Double]? { (v as? [Any])?.compactMap { $0 as? Double } }
        func int(_ v: Any?) -> Int? { (v as? Double).flatMap { $0.isFinite && $0 == $0.rounded() && abs($0) < 1e15 ? Int($0) : nil } }
        if let asset = json["asset"] as? [String: Any] {
            generator = asset["generator"] as? String ?? ""
            for (k, v) in asset["extras"] as? [String: Any] ?? [:] { if let s = v as? String { extras[k] = s } }
        }
        let accessors = list("accessors"), views = list("bufferViews")

        /// An accessor's components, element by element, as doubles (integers as they are, not normalized)
        func read(_ index: Int) throws -> (values: [Double], width: Int) {
            guard index >= 0, index < accessors.count else { throw ReadError.malformed("no accessor \(index)") }
            let a = accessors[index]
            let widths = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16]
            guard let type = a["type"] as? String, let n = widths[type], let kind = int(a["componentType"]),
                  let count = int(a["count"]) else { throw ReadError.malformed("accessor \(index) has no type or count") }
            if a["sparse"] != nil { throw ReadError.malformed("sparse accessors are not read") }
            let sizes = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4]
            guard let size = sizes[kind] else { throw ReadError.malformed("accessor \(index): component type \(kind)") }
            guard let v = int(a["bufferView"]) else { return (Array(repeating: 0, count: count * n), n) }
            guard v >= 0, v < views.count else { throw ReadError.malformed("no buffer view \(v)") }
            let view = views[v]
            if let buffer = int(view["buffer"]), buffer != 0 { throw ReadError.malformed("buffers other than the file's own are not read") }
            let start = (int(view["byteOffset"]) ?? 0) + (int(a["byteOffset"]) ?? 0)
            let stride = int(view["byteStride"]).flatMap { $0 > 0 ? $0 : nil } ?? n * size
            guard count == 0 || start + (count - 1) * stride + n * size <= binary.count else {
                throw ReadError.malformed("accessor \(index) runs past the binary chunk")
            }
            var out = [Double]()
            out.reserveCapacity(count * n)
            binary.withUnsafeBytes { raw in
                for i in 0..<count {
                    for c in 0..<n {
                        let o = start + i * stride + c * size
                        switch kind {
                        case 5120: out.append(Double(raw.load(fromByteOffset: o, as: Int8.self)))
                        case 5121: out.append(Double(raw[o]))
                        case 5122: out.append(Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: Int16.self))))
                        case 5123: out.append(Double(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt16.self))))
                        case 5125: out.append(Double(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))))
                        default:
                            let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))
                            out.append(Double(Float(bitPattern: bits)))
                        }
                    }
                }
            }
            return (out, n)
        }

        for (mi, mesh) in list("meshes").enumerated() {
            var prims: [Primitive] = []
            for p in list("primitives", mesh) {
                guard let attributes = p["attributes"] as? [String: Any], let position = int(attributes["POSITION"]) else {
                    throw ReadError.malformed("mesh \(mi): a primitive has no positions")
                }
                let pos = try read(position)
                guard pos.width == 3 else { throw ReadError.malformed("mesh \(mi): positions are not VEC3") }
                var normals: [Float]?
                if let n = int(attributes["NORMAL"]) {
                    let nv = try read(n)
                    if nv.width == 3 { normals = nv.values.map { Float($0) } }
                }
                let vertexCount = pos.values.count / 3
                let corners: [Int]
                if let i = int(p["indices"]) {
                    corners = try read(i).values.map { Int($0) }
                    guard !corners.contains(where: { $0 < 0 || $0 >= vertexCount }) else {
                        throw ReadError.malformed("mesh \(mi): an index past its vertices")
                    }
                } else {
                    corners = Array(0..<vertexCount)
                }
                let mode = int(p["mode"]) ?? 4
                prims.append(Primitive(mode: mode, positions: pos.values.map { Float($0) }, normals: normals,
                                       triangles: Self.triangles(mode, corners), material: int(p["material"])))
            }
            meshes.append(Mesh(name: mesh["name"] as? String ?? "", primitives: prims))
        }
        for m in list("materials") {
            let pbr = m["pbrMetallicRoughness"] as? [String: Any] ?? [:]
            materials.append(Material(name: m["name"] as? String ?? "", baseColor: doubles(pbr["baseColorFactor"]) ?? [1, 1, 1, 1],
                                      metallic: pbr["metallicFactor"] as? Double ?? 1,
                                      roughness: pbr["roughnessFactor"] as? Double ?? 1,
                                      emissive: doubles(m["emissiveFactor"]) ?? [0, 0, 0], alphaMode: m["alphaMode"] as? String ?? "OPAQUE",
                                      doubleSided: m["doubleSided"] as? Bool ?? false))
        }
        for n in list("nodes") {
            let matrix: Matrix4
            if let m = doubles(n["matrix"]), m.count == 16 {
                matrix = Matrix4(columns: m)
            } else {
                matrix = Self.trs(doubles(n["translation"]) ?? [0, 0, 0], doubles(n["rotation"]) ?? [0, 0, 0, 1], doubles(n["scale"]) ?? [1, 1, 1])
            }
            nodes.append(Node(name: n["name"] as? String ?? "", children: (n["children"] as? [Any])?.compactMap { int($0) } ?? [],
                              mesh: int(n["mesh"]), matrix: matrix))
        }
        for n in nodes {
            for c in n.children where c < 0 || c >= nodes.count { throw ReadError.malformed("no node \(c)") }
            if let m = n.mesh, m < 0 || m >= meshes.count { throw ReadError.malformed("no mesh \(m)") }
        }
        let scenes = list("scenes")
        if !scenes.isEmpty {
            let s = min(max(int(json["scene"]) ?? 0, 0), scenes.count - 1)
            scene = (scenes[s]["nodes"] as? [Any])?.compactMap { int($0) }.filter { $0 >= 0 && $0 < nodes.count } ?? []
        }
    }

    /// A primitive's triangles as the specification makes them of its corners
    static func triangles(_ mode: Int, _ c: [Int]) -> [Int] {
        let n = c.count
        var out: [Int] = []
        switch mode {
        case 4:
            out = Array(c[0..<(n - n % 3)])
        case 5 where n >= 3:
            for i in 0..<(n - 2) { out += [c[i], c[i + 1 + i % 2], c[i + 2 - i % 2]] }
        case 6 where n >= 3:
            for i in 0..<(n - 2) { out += [c[i + 1], c[i + 2], c[0]] }
        default:
            break
        }
        return out
    }

    /// T * R * S: the rotation a unit quaternion (x, y, z, w)
    static func trs(_ t: [Double], _ q: [Double], _ s: [Double]) -> Matrix4 {
        guard t.count == 3, q.count == 4, s.count == 3 else { return .identity }
        let (x, y, z, w) = (q[0], q[1], q[2], q[3])
        // (the rotation's rows)
        let r = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                 [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                 [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]
        var m = (0..<3).map { col in (0..<3).map { row in r[row][col] * s[col] } + [0.0] }
        m.append([t[0], t[1], t[2], 1])
        return Matrix4(m: m)
    }

    /// Each node's matrix in the scene (its parents' times its own), nil for a node not in the scene
    public func worldMatrices() -> [Matrix4?] {
        var world = [Matrix4?](repeating: nil, count: nodes.count)
        func walk(_ i: Int, _ parent: Matrix4?, _ depth: Int) {
            guard depth < 1000, world[i] == nil else { return }
            let m = parent.map { $0 * nodes[i].matrix } ?? nodes[i].matrix
            world[i] = m
            for c in nodes[i].children { walk(c, m, depth + 1) }
        }
        for i in scene { walk(i, nil, 0) }
        return world
    }

    /// The node's parent, by index
    public func parents() -> [Int?] {
        var out = [Int?](repeating: nil, count: nodes.count)
        for (i, n) in nodes.enumerated() { for c in n.children { out[c] = i } }
        return out
    }
}

extension Matrix4 {
    /// The inverse of an affine matrix (its last row 0, 0, 0, 1); nil where it has none
    public var affineInverse: Matrix4? {
        let a = m[0][0], b = m[1][0], c = m[2][0]
        let d = m[0][1], e = m[1][1], f = m[2][1]
        let g = m[0][2], h = m[1][2], k = m[2][2]
        let det = a * (e * k - f * h) - b * (d * k - f * g) + c * (d * h - e * g)
        guard det != 0, det.isFinite else { return nil }
        // the 3x3's inverse, row by row
        let r = [[(e * k - f * h) / det, (c * h - b * k) / det, (b * f - c * e) / det],
                 [(f * g - d * k) / det, (a * k - c * g) / det, (c * d - a * f) / det],
                 [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]]
        let t = (m[3][0], m[3][1], m[3][2])
        var out = Matrix4.identity
        for col in 0..<3 { for row in 0..<3 { out.m[col][row] = r[row][col] } }
        for row in 0..<3 { out.m[3][row] = -(r[row][0] * t.0 + r[row][1] * t.1 + r[row][2] * t.2) }
        return out
    }
}

/// JSON as RFC 8259 has it, its numbers read as Double(String) reads them (correctly rounded, as the file's writer
/// meant them: Foundation's JSONSerialization does not round every number so on every platform): objects as
/// [String: Any], arrays as [Any], numbers as Double, true and false as Bool, null as NSNull
struct JSONReader {
    let bytes: [UInt8]
    var at = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func document() throws -> Any {
        let v = try value(0)
        space()
        guard at == bytes.count || bytes[at...].allSatisfy({ $0 == 0 }) else { throw GLTFAsset.ReadError.malformed("JSON: text after the value") }
        return v
    }

    mutating func space() { while at < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[at]) { at += 1 } }

    func fail(_ what: String) -> GLTFAsset.ReadError { .malformed("JSON: \(what) at byte \(at)") }

    mutating func value(_ depth: Int) throws -> Any {
        space()
        guard depth < 512, at < bytes.count else { throw fail("a value expected") }
        switch bytes[at] {
        case UInt8(ascii: "{"):
            at += 1
            var out: [String: Any] = [:]
            space()
            if at < bytes.count, bytes[at] == UInt8(ascii: "}") { at += 1; return out }
            while true {
                space()
                guard at < bytes.count, bytes[at] == UInt8(ascii: "\"") else { throw fail("a name expected") }
                let key = try string()
                space()
                guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { throw fail("':' expected") }
                at += 1
                out[key] = try value(depth + 1)
                space()
                guard at < bytes.count else { throw fail("'}' expected") }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                guard bytes[at] == UInt8(ascii: "}") else { throw fail("'}' expected") }
                at += 1
                return out
            }
        case UInt8(ascii: "["):
            at += 1
            var out: [Any] = []
            space()
            if at < bytes.count, bytes[at] == UInt8(ascii: "]") { at += 1; return out }
            while true {
                out.append(try value(depth + 1))
                space()
                guard at < bytes.count else { throw fail("']' expected") }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                guard bytes[at] == UInt8(ascii: "]") else { throw fail("']' expected") }
                at += 1
                return out
            }
        case UInt8(ascii: "\""):
            return try string()
        case UInt8(ascii: "t"): return try word("true", true)
        case UInt8(ascii: "f"): return try word("false", false)
        case UInt8(ascii: "n"): return try word("null", NSNull())
        default:
            let start = at
            while at < bytes.count, "+-.eE0123456789".utf8.contains(bytes[at]) { at += 1 }
            guard at > start, let v = Double(String(decoding: bytes[start..<at], as: UTF8.self)) else { throw fail("a number expected") }
            return v
        }
    }

    mutating func word(_ w: String, _ v: Any) throws -> Any {
        let u = Array(w.utf8)
        guard at + u.count <= bytes.count, Array(bytes[at..<(at + u.count)]) == u else { throw fail("\(w) expected") }
        at += u.count
        return v
    }

    mutating func string() throws -> String {
        at += 1
        var out = [UInt8]()
        while at < bytes.count {
            let b = bytes[at]
            at += 1
            if b == UInt8(ascii: "\"") { return String(decoding: out, as: UTF8.self) }
            guard b == UInt8(ascii: "\\") else { out.append(b); continue }
            guard at < bytes.count else { break }
            let e = bytes[at]
            at += 1
            switch e {
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var code = try hex4()
                if (0xD800..<0xDC00).contains(code), at + 1 < bytes.count, bytes[at] == UInt8(ascii: "\\"), bytes[at + 1] == UInt8(ascii: "u") {
                    at += 2
                    let low = try hex4()
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                }
                out += Array(String(Character(Unicode.Scalar(UInt32(code)) ?? "?")).utf8)
            default: out.append(e)
            }
        }
        throw fail("an unterminated string")
    }

    mutating func hex4() throws -> Int {
        guard at + 4 <= bytes.count, let v = Int(String(decoding: bytes[at..<(at + 4)], as: UTF8.self), radix: 16) else { throw fail("\\u expected 4 hex digits") }
        at += 4
        return v
    }
}
