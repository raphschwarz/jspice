// The board in 3D as KiCad 10.0.8's 3D viewer shows it: its layers as KiCadRouter's Board3D builds them (BOARD_ADAPTER
// and RENDER_3D_OPENGL's reload), drawn in SceneKit with materials after RENDER_3D_OPENGL::setupMaterials and
// setLayerMaterial (3d-viewer/3d_rendering/opengl/render_3d_opengl.cpp: the copper's specular colour and shininess
// from its colour, the mask's transparency from its colour's alpha, the board's epoxy), lit by a headlight and lights
// above and below the board as init_lights sets them, on the background's gradient, with the footprints' models
// placed as get3dModelsFromFootprint places them: VRML models read by the port, STEP and IGES ones made triangles by
// KiCad's own exporter (kicad-cli's glTF export, KiCadRouter's STEPModels.swift) in the appearance
// plugins/3d/oce/loadmodel.cpp gives them.
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import AppKit
import SceneKit
import SwiftUI
import simd
import KiCadKit
import KiCadRouter

/// What the 3D view draws, made from the board on the editing session's queue
struct PCB3DContent: @unchecked Sendable {
    var slabs: [Board3D.Slab]
    var colors: Board3D.Colors
    var models: [Board3D.Model]
    var unsupported: [String]
    /// The board's outline's box (nm)
    var box: IBox
    /// The footprints' library names, by uuid, for finding their models beside their libraries
    var libraries: [String: String]
}

extension PCBEditing {
    /// The 3D view of the board as it is now, in a window of its own
    func open3DView(boardFile: URL?, title: String) {
        guard !isRouting, !isDragging else { return NSSound.beep() }
        Task {
            await settled()
            if !isReady { await prepareNow() }
            let content = await engine.run { session -> PCB3DContent? in
                let b = Board3D(board: session.board, project: session.projectSettings)
                var box = IBox(minX: 0, minY: 0, maxX: 0, maxY: 0)
                for (i, p) in b.boardPolygon.polygons.enumerated() { if i == 0 { box = p[0].bbox } else { box.merge(p[0].bbox) } }
                var libraries: [String: String] = [:]
                for fp in session.board.root.all("footprint") {
                    guard let uuid = fp.value("uuid"), let id = fp.text(at: 0), let colon = id.firstIndex(of: ":") else { continue }
                    libraries[uuid] = String(id[..<colon])
                }
                return PCB3DContent(slabs: b.slabs, colors: b.colors, models: b.models, unsupported: b.unsupported.sorted(), box: box,
                                    libraries: libraries)
            }
            guard let content else { return NSSound.beep() }
            PCB3DWindow.show(content, boardFile: boardFile, title: title)
        }
    }
}

/// The 3D view's windows (kept while they are open)
@MainActor
enum PCB3DWindow {
    private static var open: [NSWindow] = []

    static func show(_ content: PCB3DContent, boardFile: URL?, title: String) {
        let view = PCB3DView(content: content, boardFile: boardFile)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title.isEmpty ? "3D View" : "\(title) — 3D View"
        window.setContentSize(NSSize(width: 960, height: 680))
        window.isReleasedWhenClosed = false
        window.center()
        open.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
            MainActor.assumeIsolated { open.removeAll { $0 === note.object as? NSWindow } }
        }
        window.makeKeyAndOrderFront(nil)
    }
}

/// The board in 3D: drag to turn it, drag with the right button or Option held (or two fingers on a trackpad) to
/// move it, scroll or pinch to zoom; the layers and models shown or not
struct PCB3DView: View {
    let content: PCB3DContent
    let boardFile: URL?
    @StateObject private var scene = PCB3DScene()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("Board", isOn: $scene.showBoard)
                Toggle("Copper", isOn: $scene.showCopper)
                Toggle("Solder Mask", isOn: $scene.showMask)
                Toggle("Silkscreen", isOn: $scene.showSilkscreen)
                Toggle("Paste", isOn: $scene.showPaste)
                Toggle("Models", isOn: $scene.showModels)
                Spacer()
                Button("Top") { scene.look(fromTop: true) }
                    .help("Look at the board from above")
                Button("Bottom") { scene.look(fromTop: false) }
                    .help("Look at the board from below")
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 12)
            .frame(height: 34)
            Divider()
            PCB3DSceneView(scene: scene)
            Divider()
            HStack {
                Text(scene.status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 26)
        }
        .onAppear { scene.build(content, boardFile: boardFile) }
    }
}

/// The scene: the board's slabs and its models, a camera looking at the board
@MainActor
final class PCB3DScene: ObservableObject {
    let scene = SCNScene()
    let camera = SCNNode()
    var target = SCNVector3(0, 0, 0)
    var size: CGFloat = 50
    private let boardNode = SCNNode(), copperNode = SCNNode(), maskNode = SCNNode(), silkNode = SCNNode(), pasteNode = SCNNode()
    private let modelsNode = SCNNode()
    @Published var showBoard = true { didSet { boardNode.isHidden = !showBoard } }
    @Published var showCopper = true { didSet { copperNode.isHidden = !showCopper } }
    @Published var showMask = true { didSet { maskNode.isHidden = !showMask } }
    @Published var showSilkscreen = true { didSet { silkNode.isHidden = !showSilkscreen } }
    @Published var showPaste = true { didSet { pasteNode.isHidden = !showPaste } }
    @Published var showModels = true { didSet { modelsNode.isHidden = !showModels } }
    @Published var status = "Building the board…"
    weak var view: SCNView?

    private var built = false

    func build(_ content: PCB3DContent, boardFile: URL?) {
        guard !built else { return }
        built = true
        let box = content.box
        // (the scene in millimetres about the board's centre, y up as KiCad's 3D view has it)
        let cx = Double(box.minX + box.maxX) / 2e6, cy = -Double(box.minY + box.maxY) / 2e6
        let root = SCNNode()
        root.position = SCNVector3(CGFloat(-cx), CGFloat(-cy), 0)
        scene.rootNode.addChildNode(root)
        for n in [boardNode, copperNode, maskNode, silkNode, pasteNode, modelsNode] { root.addChildNode(n) }
        size = CGFloat(max(Double(box.maxX - box.minX), Double(box.maxY - box.minY)) / 1e6)
        if size <= 0 { size = 50 }
        // the background (KiCad's gradient, top to bottom)
        scene.background.contents = Self.gradient(content.colors.backgroundTop, content.colors.backgroundBottom)
        // the slabs
        for slab in content.slabs {
            guard let geometry = Self.extrude(slab) else { continue }
            geometry.materials = [Self.material(slab, content.colors)]
            let node = SCNNode(geometry: geometry)
            switch slab.kind {
            case .body: boardNode.addChildNode(node)
            case .copper, .platedHoles, .viaBarrel: copperNode.addChildNode(node)
            case .soldermask: maskNode.addChildNode(node)
            case .silkscreen, .adhesive: silkNode.addChildNode(node)
            case .solderpaste: pasteNode.addChildNode(node)
            }
        }
        // the lights: a headlight with the camera, and one above and one below the board (init_lights)
        let cam = SCNCamera()
        cam.automaticallyAdjustsZRange = true
        cam.fieldOfView = 30
        camera.camera = cam
        let head = SCNLight()
        head.type = .omni
        head.color = NSColor(white: 0.3, alpha: 1)
        camera.light = head
        scene.rootNode.addChildNode(camera)
        for z in [1.0, -1.0] {
            let light = SCNLight()
            light.type = .directional
            light.color = NSColor(white: 0.7, alpha: 1)
            let node = SCNNode()
            node.light = light
            // (a little off the vertical, as init_lights tilts them)
            node.position = SCNVector3(size * 0.03, size * 0.03, CGFloat(z) * size)
            node.look(at: SCNVector3(0, 0, 0))
            scene.rootNode.addChildNode(node)
        }
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = NSColor(white: 0.084 * 3, alpha: 1)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)
        look(fromTop: true)
        status = content.unsupported.isEmpty ? "Loading the models…" : "Not made as KiCad makes them: " + content.unsupported.joined(separator: ", ")
        loadModels(content, boardFile: boardFile)
    }

    /// The camera above (or below) the board, tilted a little, at a distance that shows all of it
    func look(fromTop: Bool) {
        let d = size * 2.2
        camera.position = SCNVector3(0, fromTop ? -d * 0.35 : d * 0.35, fromTop ? d : -d)
        camera.look(at: target, up: SCNVector3(0, fromTop ? 1 : -1, 0), localFront: SCNVector3(0, 0, -1))
        view?.defaultCameraController.target = target
    }

    // MARK: - The models

    /// Each footprint's models, found as KiCad finds them and read on another thread: VRML models by the port's own
    /// reader, shown first; then STEP and IGES models made triangles by KiCad's own code, kicad-cli's glTF export
    /// (MeshModel.export, which keeps what it exported in the caches folder), where KiCad is installed; what is not
    /// shown, and why, said in the window
    private func loadModels(_ content: PCB3DContent, boardFile: URL?) {
        let project = boardFile?.deletingLastPathComponent()
        let models = content.models
        let unsupported = content.unsupported
        let libraries = content.libraries
        Task.detached(priority: .userInitiated) {
            var vars: [String: String] = [:]
            var libraryFolders: [String: URL] = [:]
            let installation = KiCadInstallation.find()
            if let installation {
                vars = installation.variables()
                let table = KiCadFootprintLibrary(installation: installation, projectFolder: project)
                for (name, lib) in table.libraries { libraryFolders[name] = lib.folder }
            }
            let resolver = ModelResolver(variables: vars, projectFolder: project)
            var cache: [URL: VRMLModel] = [:]
            var placed: [(VRMLModel, [Double], Double)] = []
            var exported: [(URL, [Double], Double)] = []
            var notFound = 0, notRead: [String: Int] = [:], failed = 0
            for m in models {
                let folder = libraries[m.footprint].flatMap { libraryFolders[$0] }
                guard let url = resolver.resolve(m.filename, libraryFolder: folder) else {
                    notFound += 1
                    continue
                }
                let ext = url.pathExtension.lowercased()
                if MeshModel.isExported(url) {
                    exported.append((url.standardizedFileURL, m.transform, m.opacity))
                    continue
                }
                guard ext == "wrl" else {
                    notRead[ext.isEmpty ? "?" : ext, default: 0] += 1
                    continue
                }
                if cache[url] == nil { cache[url] = try? VRMLModel.load(url) }
                guard let model = cache[url] else {
                    failed += 1
                    continue
                }
                placed.append((model, m.transform, m.opacity))
            }
            let (unread, missing, unreadable) = (notRead, notFound, failed)
            func notes(shown: Int, more: [String]) -> String {
                var notes = ["\(shown) of \(models.count) footprint models shown"] + more
                for (ext, n) in unread.sorted(by: { $0.key < $1.key }) { notes.append("\(n) .\(ext) not shown (only VRML, STEP and IGES models are read)") }
                if missing > 0 { notes.append("\(missing) not found") }
                if unreadable > 0 { notes.append("\(unreadable) could not be read") }
                if !unsupported.isEmpty { notes.append("not made as KiCad makes them: " + unsupported.joined(separator: ", ")) }
                return notes.joined(separator: "; ")
            }
            let built = placed.map { Self.modelNode($0.0, transform: $0.1, opacity: $0.2) }
            let stepFiles = Set(exported.map(\.0))
            let waiting = exported.isEmpty ? [] : ["\(exported.count) STEP models being made by KiCad (kicad-cli)…"]
            let first = notes(shown: placed.count, more: waiting)
            await MainActor.run {
                for n in built { self.modelsNode.addChildNode(n) }
                self.status = first
            }
            guard !exported.isEmpty else { return }
            // the STEP models, by KiCad's exporter: each file once
            var more: [String] = []
            var meshes: [URL: MeshModel] = [:]
            var stepFailed = 0
            if let installation, installation.problem == nil {
                do {
                    let export = try MeshModel.export(Array(stepFiles), installation: installation, cache: MeshModel.defaultCache)
                    meshes = export.models
                } catch {
                    more.append("STEP models not shown: \(error)")
                }
            } else {
                let why = installation?.problem ?? "KiCad is not installed"
                more.append("\(exported.count) STEP models not shown (KiCad's kicad-cli makes them: \(why))")
            }
            var stepNodes: [SCNNode] = []
            if !meshes.isEmpty || more.isEmpty {
                for (url, transform, opacity) in exported {
                    guard let mesh = meshes[url] else {
                        stepFailed += 1
                        continue
                    }
                    stepNodes.append(Self.modelNode(mesh, transform: transform, opacity: opacity))
                }
                if stepFailed > 0 { more.append("\(stepFailed) STEP models KiCad could not read") }
            }
            let text = notes(shown: placed.count + stepNodes.count, more: more)
            let shown = stepNodes
            await MainActor.run {
                for n in shown { self.modelsNode.addChildNode(n) }
                self.status = text
            }
        }
    }

    /// A model's node: Board3D's transform, column-major (SceneKit's rows are its columns)
    nonisolated static func placedNode(_ t: [Double]) -> SCNNode {
        let node = SCNNode()
        node.transform = SCNMatrix4(m11: CGFloat(t[0]), m12: CGFloat(t[1]), m13: CGFloat(t[2]), m14: CGFloat(t[3]),
                                    m21: CGFloat(t[4]), m22: CGFloat(t[5]), m23: CGFloat(t[6]), m24: CGFloat(t[7]),
                                    m31: CGFloat(t[8]), m32: CGFloat(t[9]), m33: CGFloat(t[10]), m34: CGFloat(t[11]),
                                    m41: CGFloat(t[12]), m42: CGFloat(t[13]), m43: CGFloat(t[14]), m44: CGFloat(t[15]))
        return node
    }

    /// A mesh's geometry: its triangles' corners (x, y, z each), their normals (or each triangle's own), their
    /// colours where it has them
    nonisolated static func geometry(positions p: [Float], normals given: [Float]?, colors: [Float]?) -> SCNGeometry {
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = []
        vertices.reserveCapacity(p.count / 3)
        normals.reserveCapacity(p.count / 3)
        var k = 0
        while k + 8 < p.count {
            let a = SIMD3<Float>(p[k], p[k + 1], p[k + 2]), b = SIMD3<Float>(p[k + 3], p[k + 4], p[k + 5])
            let c = SIMD3<Float>(p[k + 6], p[k + 7], p[k + 8])
            var n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            if len > 0 { n /= len }
            for (j, v) in [a, b, c].enumerated() {
                vertices.append(SCNVector3(CGFloat(v.x), CGFloat(v.y), CGFloat(v.z)))
                if let given, k + 3 * j + 2 < given.count {
                    let o = k + 3 * j
                    normals.append(SCNVector3(CGFloat(given[o]), CGFloat(given[o + 1]), CGFloat(given[o + 2])))
                } else {
                    normals.append(SCNVector3(CGFloat(n.x), CGFloat(n.y), CGFloat(n.z)))
                }
            }
            k += 9
        }
        var sources = [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)]
        if let colors {
            let data = colors.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(data: data, semantic: .color, vectorCount: colors.count / 3, usesFloatComponents: true,
                                             componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                             dataStride: 3 * MemoryLayout<Float>.size))
        }
        let element = SCNGeometryElement(indices: (0..<Int32(vertices.count)).map { $0 }, primitiveType: .triangles)
        return SCNGeometry(sources: sources, elements: [element])
    }

    /// A model's material: its diffuse, specular and emissive colours (sRGB) and shininess, its transparency and the
    /// footprint's opacity for it, both sides drawn
    nonisolated static func material(diffuse: (Float, Float, Float), specular: (Float, Float, Float), emissive: (Float, Float, Float),
                                     shininess: Float, transparency: Float, opacity: Double) -> SCNMaterial {
        func color(_ c: (Float, Float, Float)) -> NSColor { NSColor(srgbRed: CGFloat(c.0), green: CGFloat(c.1), blue: CGFloat(c.2), alpha: 1) }
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = color(diffuse)
        material.specular.contents = color(specular)
        material.emission.contents = color(emissive)
        material.shininess = CGFloat(shininess)
        material.transparency = CGFloat((1 - Double(transparency)) * opacity)
        material.isDoubleSided = true
        return material
    }

    nonisolated static func modelNode(_ model: VRMLModel, transform t: [Double], opacity: Double) -> SCNNode {
        let node = placedNode(t)
        for mesh in model.meshes {
            let g = Self.geometry(positions: mesh.positions, normals: nil, colors: mesh.colors)
            g.materials = [Self.material(diffuse: mesh.diffuse, specular: mesh.specular, emissive: mesh.emissive, shininess: mesh.shininess,
                                    transparency: mesh.transparency, opacity: opacity)]
            node.addChildNode(SCNNode(geometry: g))
        }
        return node
    }

    /// A STEP model as KiCad made it triangles, with its normals and the appearance KiCad's viewer gives it
    nonisolated static func modelNode(_ model: MeshModel, transform t: [Double], opacity: Double) -> SCNNode {
        let node = placedNode(t)
        for mesh in model.meshes {
            let g = Self.geometry(positions: mesh.positions, normals: mesh.normals, colors: nil)
            g.materials = [Self.material(diffuse: mesh.diffuse, specular: mesh.specular, emissive: (0, 0, 0), shininess: mesh.shininess,
                                    transparency: mesh.transparency, opacity: opacity)]
            node.addChildNode(SCNNode(geometry: g))
        }
        return node
    }

    // MARK: - The slabs

    /// A slab as SceneKit triangles: its polygons cut into triangles (SHAPE_POLY_SET's triangulation, as KiCad cuts a
    /// layer's polygons) for its top and bottom, and a wall along each outline and hole; in millimetres, y up
    static func extrude(_ slab: Board3D.Slab) -> SCNGeometry? {
        var set = slab.polygons
        guard set.outlineCount > 0 else { return nil }
        set.cacheTriangulation(partition: true)
        let top = CGFloat(slab.top / 1e6), bottom = CGFloat(slab.bottom / 1e6)
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = []
        func v(_ p: IPoint, _ z: CGFloat) -> SCNVector3 { SCNVector3(CGFloat(Double(p.x) / 1e6), CGFloat(-Double(p.y) / 1e6), z) }
        // (the side towards the board's middle is not drawn where something lies on it: a mask's, a copper layer's,
        // as KiCad pushes the body and masks back by their depth so they do not fight)
        let middle = (slab.top + slab.bottom) / 2
        let drawTop = !(slab.kind == .soldermask || slab.kind == .copper) || middle >= 0
        let drawBottom = !(slab.kind == .soldermask || slab.kind == .copper) || middle < 0
        if set.isTriangulationUpToDate {
            for tpoly in set.triangulatedPolygons {
                for k in tpoly.triangles.indices {
                    let (a, b, c) = tpoly.triangle(k)
                    if drawTop {
                        vertices += [v(a, top), v(b, top), v(c, top)]
                        normals += Array(repeating: SCNVector3(0, 0, 1), count: 3)
                    }
                    if drawBottom {
                        vertices += [v(a, bottom), v(c, bottom), v(b, bottom)]
                        normals += Array(repeating: SCNVector3(0, 0, -1), count: 3)
                    }
                }
            }
        }
        for poly in set.polygons {
            for chain in poly {
                let pts = chain.points
                guard pts.count > 1 else { continue }
                for i in pts.indices {
                    let a = pts[i], b = pts[(i + 1) % pts.count]
                    if a == b { continue }
                    let dx = Double(b.x - a.x), dy = -Double(b.y - a.y)
                    let len = (dx * dx + dy * dy).squareRoot()
                    let n = SCNVector3(CGFloat(dy / len), CGFloat(-dx / len), 0)
                    vertices += [v(a, bottom), v(b, bottom), v(b, top), v(a, bottom), v(b, top), v(a, top)]
                    normals += Array(repeating: n, count: 6)
                }
            }
        }
        guard !vertices.isEmpty else { return nil }
        let element = SCNGeometryElement(indices: (0..<Int32(vertices.count)).map { $0 }, primitiveType: .triangles)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)], elements: [element])
    }

    static func nsColor(_ c: Board3D.Color, alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(alpha))
    }

    /// setupMaterials and setLayerMaterial: copper with a specular colour and shininess from its colour; the mask
    /// its colour, its alpha its opacity, its specular the colour squared; paste and silkscreen theirs; the board's
    /// epoxy its colour, its alpha its opacity
    static func material(_ slab: Board3D.Slab, _ colors: Board3D.Colors) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.isDoubleSided = true
        let c = slab.color
        m.diffuse.contents = nsColor(c)
        switch slab.kind {
        case .copper, .platedHoles, .viaBarrel:
            m.specular.contents = NSColor(srgbRed: CGFloat(c.r * 0.75 + 0.25), green: CGFloat(c.g * 0.75 + 0.25), blue: CGFloat(c.b * 0.75 + 0.25),
                                          alpha: 1)
            // (0.1 to 0.4, from how far its red is from its green)
            let f = 0.40 - min(max((abs(c.r - c.g) - 0.15) / 0.85 * 0.30, 0), 0.30)
            m.shininess = CGFloat(f)
        case .soldermask:
            m.specular.contents = NSColor(srgbRed: CGFloat(c.r * c.r), green: CGFloat(c.g * c.g), blue: CGFloat(c.b * c.b), alpha: 1)
            m.shininess = 0.8
            m.transparency = CGFloat(c.a)
        case .solderpaste:
            m.specular.contents = NSColor(srgbRed: CGFloat(c.r * c.r), green: CGFloat(c.g * c.g), blue: CGFloat(c.b * c.b), alpha: 1)
            m.shininess = 0.1
        case .silkscreen, .adhesive:
            m.specular.contents = NSColor(srgbRed: CGFloat(c.r * c.r + 0.1), green: CGFloat(c.g * c.g + 0.1), blue: CGFloat(c.b * c.b + 0.1),
                                          alpha: 1)
            m.shininess = 0.078125
        case .body:
            m.specular.contents = NSColor(srgbRed: 18 / 255, green: 3 / 255, blue: 20 / 255, alpha: 1)
            m.shininess = 0.1
            m.transparency = CGFloat(c.a)
        }
        return m
    }

    /// OglDrawBackground's gradient, the top colour at the top
    static func gradient(_ top: Board3D.Color, _ bottom: Board3D.Color) -> NSImage {
        let (from, to) = (nsColor(bottom), nsColor(top))
        return NSImage(size: NSSize(width: 4, height: 256), flipped: false) { rect in
            NSGradient(starting: from, ending: to)?.draw(in: rect, angle: 90)
            return true
        }
    }
}

/// The SceneKit view, with KiCad's 3D viewer's ways of moving round the board: drag to turn it about its centre,
/// right-drag or Option-drag (or two fingers on a trackpad) to move it, the scroll wheel or a pinch to zoom
struct PCB3DSceneView: NSViewRepresentable {
    @ObservedObject var scene: PCB3DScene

    func makeNSView(context: Context) -> PCB3DSCNView {
        let view = PCB3DSCNView()
        view.scene = scene.scene
        view.pointOfView = scene.camera
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .black
        view.defaultCameraController.pointOfView = scene.camera
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.target = scene.target
        view.defaultCameraController.automaticTarget = false
        view.defaultCameraController.worldUp = SCNVector3(0, 0, 1)
        view.defaultCameraController.inertiaEnabled = true
        scene.view = view
        view.owner = scene
        return view
    }

    func updateNSView(_ view: PCB3DSCNView, context: Context) {}
}

final class PCB3DSCNView: SCNView {
    weak var owner: PCB3DScene?
    private var last: CGPoint?
    private var panning = false

    private var controller: SCNCameraController { defaultCameraController }

    /// How far a point's move moves the board: the board's size over the view's, as near as the camera is
    private var panScale: Float {
        guard let camera = pointOfView else { return 0.05 }
        let t = controller.target
        let d = SCNVector3(camera.position.x - t.x, camera.position.y - t.y, camera.position.z - t.z)
        let distance = Float((d.x * d.x + d.y * d.y + d.z * d.z).squareRoot())
        return distance / Float(max(bounds.height, 1)) * 0.55
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        panning = event.modifierFlags.contains(.option)
        last = p
        if !panning { controller.beginInteraction(p, withViewport: bounds.size) }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if panning {
            pan(to: p)
        } else {
            controller.continueInteraction(p, withViewport: bounds.size, sensitivity: 1)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !panning { controller.endInteraction(p, withViewport: bounds.size, velocity: .zero) }
        last = nil
        panning = false
    }

    override func rightMouseDown(with event: NSEvent) { last = convert(event.locationInWindow, from: nil) }
    override func rightMouseDragged(with event: NSEvent) { pan(to: convert(event.locationInWindow, from: nil)) }
    override func otherMouseDown(with event: NSEvent) { last = convert(event.locationInWindow, from: nil) }
    override func otherMouseDragged(with event: NSEvent) { pan(to: convert(event.locationInWindow, from: nil)) }

    private func pan(to p: CGPoint) {
        guard let l = last else { last = p; return }
        let s = panScale
        controller.translateInCameraSpaceBy(x: Float(l.x - p.x) * s, y: Float(l.y - p.y) * s, z: 0)
        last = p
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            // (two fingers on a trackpad: move the board)
            let s = panScale
            controller.translateInCameraSpaceBy(x: Float(-event.scrollingDeltaX) * s, y: Float(event.scrollingDeltaY) * s, z: 0)
        } else {
            zoom(Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1))
        }
    }

    override func magnify(with event: NSEvent) { zoom(Float(event.magnification)) }

    /// Nearer the target by a fraction of the distance to it
    private func zoom(_ fraction: Float) {
        guard let camera = pointOfView else { return }
        let t = controller.target
        let d = SCNVector3(camera.position.x - t.x, camera.position.y - t.y, camera.position.z - t.z)
        let distance = Float((d.x * d.x + d.y * d.y + d.z * d.z).squareRoot())
        controller.dolly(toTarget: max(min(fraction, 0.5), -0.5) * distance)
    }
}
