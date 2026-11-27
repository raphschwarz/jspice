// Ported from KiCad 10.0.8: plugins/3d/vrml (the VRML plugin's reading of VRML 2.0 files: wrlproc.cpp's tokens,
// v2/vrml2_base.cpp's nodes, DEF and USE, v2/vrml2_transform.cpp (a Transform's fields, the unit conversion of 1 VRML
// unit = 0.1 inch to millimetres, given up from a top level Transform with a scale of its own), v2/vrml2_coords.cpp
// (points converted likewise), v2/vrml2_faceset.cpp and wrlfacet.cpp (an IndexedFaceSet's faces, each cut into a fan
// of triangles, turned by its ccw), v2/vrml2_shape.cpp, vrml2_appearance.cpp, vrml2_material.cpp, vrml2_color.cpp,
// vrml2_switch.cpp and vrml2_inline.cpp) and common/filename_resolver.cpp (FILENAME_RESOLVER::ResolvePath: where a
// footprint's model file is).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// A 3D model in a VRML 2.0 file as KiCad's VRML plugin reads it: each shape's triangles in millimetres (the file's
/// transforms applied), with its material. What KiCad's plugin reads that this one does not (VRML 1.0, X3D, a gzipped
/// .wrz, a Box and the other primitive shapes, line and point sets) is left out, and said in `unsupported`.
public struct VRMLModel: Sendable {
    public struct Mesh: Sendable {
        /// x, y, z of each triangle's corners in turn (three corners a triangle), mm
        public var positions: [Float] = []
        /// r, g, b of each corner, where the shape has colours of its own (a Color node)
        public var colors: [Float]?
        /// The material's diffuse colour and transparency (0 opaque), specular colour and shininess
        public var diffuse: (Float, Float, Float) = (0.8, 0.8, 0.8)
        public var specular: (Float, Float, Float) = (0, 0, 0)
        public var emissive: (Float, Float, Float) = (0, 0, 0)
        public var shininess: Float = 0.2
        public var transparency: Float = 0
        public var triangleCount: Int { positions.count / 9 }
    }

    public var meshes: [Mesh] = []
    public var unsupported: Set<String> = []

    public enum LoadError: Error, CustomStringConvertible {
        case unreadable(String), notVRML2(String), malformed(String)
        public var description: String {
            switch self {
            case .unreadable(let f): return "\(f) cannot be read"
            case .notVRML2(let f): return "\(f) is not a VRML 2.0 file"
            case .malformed(let m): return "VRML: \(m)"
            }
        }
    }

    /// LoadVRML: a .wrl file, its Inline files read (but not theirs), with the unit conversion
    public static func load(_ url: URL) throws -> VRMLModel {
        try load(url, inline: true, unitConversion: true)
    }

    static func load(_ url: URL, inline: Bool, unitConversion: Bool) throws -> VRMLModel {
        guard let data = try? Data(contentsOf: url) else { throw LoadError.unreadable(url.path) }
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix("#VRML V2.0") else { throw LoadError.notVRML2(url.lastPathComponent) }
        var reader = Reader(text: text, base: url.deletingLastPathComponent(), inline: inline, unitConversion: unitConversion)
        let nodes = try reader.readAll()
        var model = VRMLModel()
        model.unsupported = reader.unsupported
        for node in nodes { reader.translate(node, Matrix4.identity, &model, parentIsBase: true) }
        return model
    }

    /// Parses VRML text, as the model reads it, from a string
    public static func parse(_ text: String) throws -> VRMLModel {
        var reader = Reader(text: text, base: nil, inline: false, unitConversion: true)
        let nodes = try reader.readAll()
        var model = VRMLModel()
        model.unsupported = reader.unsupported
        for node in nodes { reader.translate(node, Matrix4.identity, &model, parentIsBase: true) }
        return model
    }

    // MARK: - The nodes

    final class Node {
        let type: String
        var fields: [String: Value] = [:]
        var children: [Node] = []
        init(_ type: String) { self.type = type }
    }

    enum Value {
        case numbers([Double])
        case node(Node)
        case nodes([Node])
        case strings([String])
        case bool(Bool)
    }

    struct Reader {
        var tokens: [Substring] = []
        var at = 0
        var defs: [String: Node] = [:]
        let base: URL?
        let inline: Bool
        /// WRL2BASE's m_applyUnitConversion: 1 VRML unit taken as 0.1 inch until a top level Transform with a scale
        /// says the file is in millimetres already
        var unitConversion: Bool
        var unsupported: Set<String> = []
        var depth = 0

        init(text: String, base: URL?, inline: Bool, unitConversion: Bool) {
            self.base = base
            self.inline = inline
            self.unitConversion = unitConversion
            tokens = Self.tokenize(text)
        }

        /// WRLPROC's tokens: words, numbers, strings, and the brackets and braces alone; comments and commas left out
        static func tokenize(_ text: String) -> [Substring] {
            // (by bytes: a file's line ends may be \r\n, which Swift takes as one character)
            var out: [Substring] = []
            let bytes = Array(text.utf8)
            let n = bytes.count
            func isSpace(_ b: UInt8) -> Bool { b == 32 || b == 9 || b == 10 || b == 13 || b == 11 || b == 12 || b == 44 }
            func isBracket(_ b: UInt8) -> Bool { b == 123 || b == 125 || b == 91 || b == 93 }
            func token(_ a: Int, _ b: Int) -> Substring { Substring(String(decoding: bytes[a..<b], as: UTF8.self)) }
            var i = 0
            while i < n {
                let c = bytes[i]
                if c == 35 {
                    // (#: a comment to the end of the line)
                    while i < n && bytes[i] != 10 && bytes[i] != 13 { i += 1 }
                } else if isSpace(c) {
                    i += 1
                } else if isBracket(c) {
                    out.append(token(i, i + 1))
                    i += 1
                } else if c == 34 {
                    var j = i + 1
                    while j < n && bytes[j] != 34 {
                        if bytes[j] == 92 { j += 1 }
                        j += 1
                    }
                    out.append(token(i, min(j + 1, n)))
                    i = j + 1
                } else {
                    var j = i
                    while j < n, !isSpace(bytes[j]), !isBracket(bytes[j]), bytes[j] != 35, bytes[j] != 34 { j += 1 }
                    out.append(token(i, j))
                    i = j
                }
            }
            return out
        }

        var peek: Substring? { at < tokens.count ? tokens[at] : nil }

        mutating func next() throws -> Substring {
            guard at < tokens.count else { throw LoadError.malformed("unexpected end of file") }
            defer { at += 1 }
            return tokens[at]
        }

        mutating func expect(_ t: String) throws {
            let n = try next()
            guard n == t else { throw LoadError.malformed("expected \(t), found \(n)") }
        }

        /// WRL2BASE::Read: the top level's nodes
        mutating func readAll() throws -> [Node] {
            var out: [Node] = []
            while let t = peek {
                // (a ROUTE's three words, a PROTO's declaration: discarded)
                if t == "ROUTE" {
                    at += 4
                    continue
                }
                if t == "PROTO" || t == "EXTERNPROTO" {
                    unsupported.insert("PROTO")
                    at += 2
                    try skipBlock("[", "]")
                    if peek == "{" { try skipBlock("{", "}") }
                    continue
                }
                if let n = try readNode(parentIsBase: true) { out.append(n) }
            }
            return out
        }

        /// A node: DEF name Type { ... }, USE name, or Type { ... }; nil for one discarded
        mutating func readNode(parentIsBase: Bool = false) throws -> Node? {
            var t = try next()
            if t == "USE" {
                let name = String(try next())
                guard let n = defs[name] else { throw LoadError.malformed("USE of \(name), not defined") }
                return n
            }
            var defName: String?
            if t == "DEF" {
                defName = String(try next())
                t = try next()
            }
            let type = String(t)
            let node = Node(type)
            if let defName { defs[defName] = node }
            try expect("{")
            depth += 1
            defer { depth -= 1 }
            while let f = peek, f != "}" {
                let field = String(try next())
                try readField(field, of: node, parentIsBase: parentIsBase)
            }
            try expect("}")
            return node
        }

        mutating func skipBlock(_ open: String, _ close: String) throws {
            try expect(open)
            var level = 1
            while level > 0 {
                let t = try next()
                if t == open { level += 1 } else if t == close { level -= 1 }
            }
        }

        mutating func numbers() throws -> [Double] {
            if peek == "[" {
                at += 1
                var out: [Double] = []
                while let t = peek, t != "]" {
                    at += 1
                    guard let v = Double(t) else { throw LoadError.malformed("not a number: \(t)") }
                    out.append(v)
                }
                try expect("]")
                return out
            }
            var out: [Double] = []
            while let t = peek, let v = Double(t) {
                at += 1
                out.append(v)
            }
            return out
        }

        mutating func bool() throws -> Bool {
            let t = try next()
            return t == "TRUE" || t == "true"
        }

        mutating func strings() throws -> [String] {
            func unquote(_ s: Substring) -> String { String(s.dropFirst().dropLast()) }
            if peek == "[" {
                at += 1
                var out: [String] = []
                while let t = peek, t != "]" {
                    at += 1
                    out.append(unquote(t))
                }
                try expect("]")
                return out
            }
            return [unquote(try next())]
        }

        mutating func children() throws -> [Node] {
            var out: [Node] = []
            if peek == "[" {
                at += 1
                while let t = peek, t != "]" { if let n = try readNode() { out.append(n) } }
                try expect("]")
            } else if let n = try readNode() {
                out.append(n)
            }
            return out
        }

        /// A node's field, read as its node type reads it; a field of a node type not read, discarded with its value
        mutating func readField(_ field: String, of node: Node, parentIsBase: Bool) throws {
            switch (node.type, field) {
            case ("Transform", "children"), ("Group", "children"), ("Switch", "choice"), ("Switch", "children"):
                node.children = try children()
            case ("Transform", "scale"):
                let v = try numbers()
                node.fields[field] = .numbers(v)
                // (a top level Transform scaled: the file is in millimetres, as KiCad's own exports are)
                let tol = 0.001
                if parentIsBase && v.count == 3 && (abs(v[0] - 1) > tol || abs(v[1] - 1) > tol || abs(v[2] - 1) > tol) {
                    unitConversion = false
                }
            case ("Transform", "translation"), ("Transform", "center"):
                var v = try numbers()
                if unitConversion { v = v.map { Double(Float($0) * 2.54) } }
                node.fields[field] = .numbers(v)
            case ("Transform", "rotation"), ("Transform", "scaleOrientation"):
                node.fields[field] = .numbers(try numbers())
            case ("Shape", "appearance"), ("Shape", "geometry"), ("Appearance", "material"), ("IndexedFaceSet", "coord"),
                 ("IndexedFaceSet", "color"), ("IndexedFaceSet", "normal"), ("IndexedFaceSet", "texCoord"), ("Appearance", "texture"),
                 ("Appearance", "textureTransform"):
                if peek == "NULL" {
                    at += 1
                } else if let n = try readNode() {
                    node.fields[field] = .node(n)
                }
            case ("Coordinate", "point"):
                var v = try numbers()
                if unitConversion { v = v.map { Double(Float($0) * 2.54) } }
                node.fields[field] = .numbers(v)
            case ("IndexedFaceSet", "ccw"), ("IndexedFaceSet", "solid"), ("IndexedFaceSet", "convex"),
                 ("IndexedFaceSet", "colorPerVertex"), ("IndexedFaceSet", "normalPerVertex"):
                node.fields[field] = .bool(try bool())
            case ("Inline", "url"):
                node.fields[field] = .strings(try strings())
            case ("Inline", "bboxCenter"), ("Inline", "bboxSize"), ("Group", "bboxCenter"), ("Group", "bboxSize"),
                 ("Transform", "bboxCenter"), ("Transform", "bboxSize"):
                _ = try numbers()
            case ("Switch", "whichChoice"):
                node.fields[field] = .numbers(try numbers())
            case ("Material", _), ("Color", "color"):
                node.fields[field] = .numbers(try numbers())
            case ("IndexedFaceSet", "coordIndex"), ("IndexedFaceSet", "colorIndex"):
                node.fields[field] = .numbers(try numbers())
            default:
                // (a field the plugin does not use, or of a node it discards)
                try skipValue()
            }
        }

        /// A field's value of any kind, read and kept as numbers, a node or nodes where it is one of those
        mutating func skipValue() throws {
            guard let t = peek else { return }
            if t == "[" {
                // (a list of numbers, strings or nodes)
                at += 1
                var level = 1
                while level > 0 {
                    let n = try next()
                    if n == "[" || n == "{" { level += 1 } else if n == "]" || n == "}" { level -= 1 }
                }
            } else if t.first == "\"" || t == "TRUE" || t == "FALSE" || t == "NULL" {
                at += 1
            } else if Double(t) != nil {
                while let n = peek, Double(n) != nil { at += 1 }
            } else if t == "USE" {
                at += 2
            } else {
                // a node
                if t == "DEF" { at += 2 } else { at += 1 }
                try skipBlock("{", "}")
            }
        }

        /// The value of a numeric field read into a node
        func values(_ node: Node, _ field: String) -> [Double]? {
            if case .numbers(let v)? = node.fields[field] { return v }
            return nil
        }

        func child(_ node: Node, _ field: String) -> Node? {
            if case .node(let n)? = node.fields[field] { return n }
            return nil
        }

        // MARK: - The scene graph's triangles (TranslateToSG)

        /// A node's shapes, `m` the transforms above it
        mutating func translate(_ node: Node, _ m: Matrix4, _ model: inout VRMLModel, parentIsBase: Bool = false) {
            switch node.type {
            case "Transform":
                // the VRML transform: T C R SR S -SR -C
                func vec(_ f: String, _ d: [Double]) -> [Double] { values(node, f).flatMap { $0.count >= 3 ? $0 : nil } ?? d }
                let t = vec("translation", [0, 0, 0]), c = vec("center", [0, 0, 0]), s = vec("scale", [1, 1, 1])
                let r = values(node, "rotation").flatMap { $0.count >= 4 ? $0 : nil } ?? [0, 0, 1, 0]
                let so = values(node, "scaleOrientation").flatMap { $0.count >= 4 ? $0 : nil } ?? [0, 0, 1, 0]
                var x = m * Matrix4.translation(t[0], t[1], t[2]) * Matrix4.translation(c[0], c[1], c[2])
                x = x * Self.axisRotation(r) * Self.axisRotation(so) * Matrix4.scale(s[0], s[1], s[2])
                x = x * Self.axisRotation([so[0], so[1], so[2], -so[3]]) * Matrix4.translation(-c[0], -c[1], -c[2])
                for ch in node.children { translate(ch, x, &model) }
            case "Group":
                for ch in node.children { translate(ch, m, &model) }
            case "Switch":
                let which = Int(values(node, "whichChoice")?.first ?? -1)
                if which >= 0 && which < node.children.count { translate(node.children[which], m, &model) }
            case "Inline":
                guard inline, let base, case .strings(let urls)? = node.fields["url"], let first = urls.first else {
                    unsupported.insert("Inline")
                    return
                }
                let url = first.hasPrefix("/") ? URL(fileURLWithPath: first) : base.appendingPathComponent(first)
                guard let sub = try? VRMLModel.load(url, inline: false, unitConversion: unitConversion) else { return }
                for var mesh in sub.meshes {
                    mesh.positions = Self.transformed(mesh.positions, m)
                    model.meshes.append(mesh)
                }
                model.unsupported.formUnion(sub.unsupported)
            case "Shape":
                if let mesh = shape(node, m) { model.meshes.append(mesh) }
            default:
                break
            }
        }

        static func transformed(_ positions: [Float], _ m: Matrix4) -> [Float] {
            var out = positions
            var k = 0
            while k + 2 < out.count {
                let p = m.apply((Double(out[k]), Double(out[k + 1]), Double(out[k + 2])))
                (out[k], out[k + 1], out[k + 2]) = (Float(p.0), Float(p.1), Float(p.2))
                k += 3
            }
            return out
        }

        /// A rotation about an axis (x, y, z, angle in radians), as a matrix
        static func axisRotation(_ r: [Double]) -> Matrix4 {
            var (x, y, z) = (r[0], r[1], r[2])
            let a = r[3]
            let len = (x * x + y * y + z * z).squareRoot()
            guard len > 0, a != 0 else { return .identity }
            (x, y, z) = (x / len, y / len, z / len)
            let c = cos(a), s = sin(a), t = 1 - c
            // columns
            return Matrix4(m: [[t * x * x + c, t * x * y + s * z, t * x * z - s * y, 0],
                               [t * x * y - s * z, t * y * y + c, t * y * z + s * x, 0],
                               [t * x * z + s * y, t * y * z - s * x, t * z * z + c, 0],
                               [0, 0, 0, 1]])
        }

        /// WRL2SHAPE and WRL2FACESET's TranslateToSG: an IndexedFaceSet's faces (split at -1, those of fewer than three
        /// points dropped), each cut into a fan of triangles from its first point, turned by its ccw; nothing if an
        /// index is out of its points; its material's colours
        mutating func shape(_ node: Node, _ m: Matrix4) -> Mesh? {
            guard let geometry = child(node, "geometry") else { return nil }
            guard geometry.type == "IndexedFaceSet" else {
                unsupported.insert(geometry.type)
                return nil
            }
            guard let coord = child(geometry, "coord"), let raw = values(coord, "point") else { return nil }
            let index = values(geometry, "coordIndex")?.map { Int($0) } ?? []
            let count = raw.count / 3
            guard index.count >= 3, count >= 3, !index.contains(where: { $0 >= count }) else { return nil }
            var mesh = Mesh()
            if let appearance = child(node, "appearance"), let material = child(appearance, "material") {
                func rgb(_ f: String, _ d: (Float, Float, Float)) -> (Float, Float, Float) {
                    guard let v = values(material, f), v.count >= 3 else { return d }
                    return (Float(v[0]), Float(v[1]), Float(v[2]))
                }
                mesh.diffuse = rgb("diffuseColor", (0.8, 0.8, 0.8))
                mesh.specular = rgb("specularColor", (0, 0, 0))
                mesh.emissive = rgb("emissiveColor", (0, 0, 0))
                mesh.shininess = Float(values(material, "shininess")?.first ?? 0.2)
                mesh.transparency = Float(values(material, "transparency")?.first ?? 0)
            }
            let ccw: Bool
            if case .bool(let b)? = geometry.fields["ccw"] { ccw = b } else { ccw = true }
            var perVertex = true
            if case .bool(let b)? = geometry.fields["colorPerVertex"] { perVertex = b }
            let colors = child(geometry, "color").flatMap { values($0, "color") }
            let colorIndex = values(geometry, "colorIndex")?.map { Int($0) } ?? []
            func color(_ i: Int) -> (Float, Float, Float) {
                guard let colors, colors.count >= 3 else { return (0.8, 0.8, 0.8) }
                let k = max(0, min(i, colors.count / 3 - 1))
                return (Float(colors[3 * k]), Float(colors[3 * k + 1]), Float(colors[3 * k + 2]))
            }
            let points = (0..<count).map { m.apply((raw[3 * $0], raw[3 * $0 + 1], raw[3 * $0 + 2])) }
            var out: [Float] = []
            var cols: [Float] = []
            var face: [(Int, (Float, Float, Float))] = []
            var faceNumber = 0
            func flush() {
                defer { face.removeAll() }
                guard face.count >= 3 else { return }
                for k in 1..<(face.count - 1) {
                    let tri = ccw ? [face[0], face[k], face[k + 1]] : [face[0], face[k + 1], face[k]]
                    for (p, c) in tri {
                        let q = points[p]
                        out += [Float(q.0), Float(q.1), Float(q.2)]
                        cols += [c.0, c.1, c.2]
                    }
                }
            }
            for (iCoord, idx) in index.enumerated() {
                if idx < 0 {
                    flush()
                    faceNumber += 1
                    continue
                }
                var c: (Float, Float, Float) = (0, 0, 0)
                if colors != nil {
                    if !perVertex {
                        c = color(colorIndex.isEmpty ? faceNumber : colorIndex[min(faceNumber, colorIndex.count - 1)])
                    } else {
                        c = color(colorIndex.isEmpty ? idx : colorIndex[min(iCoord, colorIndex.count - 1)])
                    }
                }
                face.append((idx, c))
            }
            flush()
            guard !out.isEmpty else { return nil }
            mesh.positions = out
            if colors != nil { mesh.colors = cols }
            return mesh
        }
    }
}

/// Where KiCad finds a footprint's 3D model file (FILENAME_RESOLVER::ResolvePath): the name with its variables filled
/// in (${VAR} and $(VAR): KiCad's own, the user's, the project's KIPRJMOD), as it is if that file exists; else
/// relative to the project's folder, to the footprint's library's folder, and to ${KICAD10_3DMODEL_DIR}. KiCad's
/// aliases (":alias:path", from its 3D search paths) and files embedded in the board or footprint (kicad-embed://)
/// are not found.
public struct ModelResolver: Sendable {
    public var variables: [String: String]
    public var projectFolder: URL?

    public init(variables: [String: String], projectFolder: URL?) {
        self.variables = variables
        self.projectFolder = projectFolder
        if let projectFolder, self.variables["KIPRJMOD"] == nil { self.variables["KIPRJMOD"] = projectFolder.path }
    }

    /// ExpandEnvVarSubstitutions: each ${NAME} and $(NAME) known replaced, the others left as they are
    public func expand(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "$", s.index(after: i) < s.endIndex, s[s.index(after: i)] == "{" || s[s.index(after: i)] == "(" {
                let close: Character = s[s.index(after: i)] == "{" ? "}" : ")"
                let start = s.index(i, offsetBy: 2)
                if let end = s[start...].firstIndex(of: close) {
                    let name = String(s[start..<end])
                    if let v = variables[name] ?? ProcessInfo.processInfo.environment[name] {
                        out += v
                        i = s.index(after: end)
                        continue
                    }
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    /// The file, or nil where KiCad would not find it either
    public func resolve(_ filename: String, libraryFolder: URL?) -> URL? {
        guard !filename.isEmpty else { return nil }
        let fm = FileManager.default
        let name = expand(filename.replacingOccurrences(of: "\\", with: "/"))
        if name.hasPrefix("kicad-embed://") { return nil }
        if name.hasPrefix("/"), fm.fileExists(atPath: name) { return URL(fileURLWithPath: name).standardizedFileURL }
        if filename.hasPrefix("${") || filename.hasPrefix("$(") { return nil }
        guard !name.hasPrefix(":") else { return nil }
        for folder in [projectFolder, libraryFolder] {
            if let f = folder?.appendingPathComponent(name), fm.fileExists(atPath: f.path) { return f.standardizedFileURL }
        }
        let models = expand("${KICAD10_3DMODEL_DIR}")
        if !models.hasPrefix("$") {
            let f = URL(fileURLWithPath: models).appendingPathComponent(name)
            if fm.fileExists(atPath: f.path) { return f.standardizedFileURL }
        }
        return nil
    }
}
