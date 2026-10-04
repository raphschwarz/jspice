import AppKit
import SwiftUI
import CircuitKit

/// `JSpice --screenshots <directory>` opens example circuits in real windows, lets them simulate, saves a PNG of each
/// window and quits. Used by CI to check the interface without a person at the screen.
@MainActor
enum ScreenshotRunner {
    private static var delegate: Delegate?

    struct Shot {
        let name: String
        let example: String?
        let dark: Bool
        let seconds: Double
        var select: ElementKind?
        var closeSwitches = false
    }

    static let shots: [Shot] = [
        Shot(name: "1-led-light", example: "led", dark: false, seconds: 1, select: .led),
        Shot(name: "2-rc-light", example: "rc", dark: false, seconds: 2.5, select: .capacitor, closeSwitches: true),
        Shot(name: "3-lowpass-dark", example: "lowpass", dark: true, seconds: 3),
        Shot(name: "4-cmos-dark", example: "cmos", dark: true, seconds: 1, select: .nmos),
        Shot(name: "5-memristor-light", example: "memristor", dark: false, seconds: 4, select: .memristor),
        Shot(name: "6-lc-dark", example: "lc", dark: true, seconds: 2, closeSwitches: true),
        Shot(name: "7-new-light", example: nil, dark: false, seconds: 0.5),
    ]

    static func run(outputDirectory: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate(output: URL(fileURLWithPath: outputDirectory, isDirectory: true))
        self.delegate = delegate
        app.delegate = delegate
        app.run()
    }

    private final class Delegate: NSObject, NSApplicationDelegate {
        let output: URL

        init(output: URL) {
            self.output = output
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            Task { @MainActor in
                await ScreenshotRunner.capture(to: output)
                NSApp.terminate(nil)
            }
        }
    }

    private static func capture(to directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for shot in shots {
            NSApp.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
            let example = shot.example.flatMap { Examples.example($0) }
            var circuit = example?.circuit ?? Circuit()
            if shot.closeSwitches {
                for i in circuit.elements.indices where circuit.elements[i].kind == .toggleSwitch {
                    circuit.elements[i].closed = true
                }
            }
            let document = CircuitDocument(circuit: circuit)
            let editor = EditorState(document: document)
            if let kind = shot.select, let element = circuit.elements.first(where: { $0.kind == kind }) {
                editor.selection = [element.id]
            }

            let controller = NSHostingController(rootView: EditorView(document: document, editor: editor))
            controller.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.title = example?.title ?? "Untitled"
            window.setContentSize(NSSize(width: 1440, height: 900))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()

            // let it lay out and simulate in real time
            try? await Task.sleep(nanoseconds: UInt64((shot.seconds + 1) * 1_000_000_000))
            save(window, to: directory.appendingPathComponent("\(shot.name).png"))
            window.orderOut(nil)
            window.close()
        }
    }

    /// Captures the window as the window server shows it (drawing the view hierarchy offscreen leaves out AppKit controls)
    private static func save(_ window: NSWindow, to url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.path]
        try? process.run()
        process.waitUntilExit()
    }
}

/// `JSpice --render-icon <directory>` writes the app icon as an .iconset folder for `iconutil`.
enum IconRenderer {
    static func writeIconSet(to path: String) {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sizes: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, size) in sizes {
            if let data = render(size: size) {
                try? data.write(to: directory.appendingPathComponent("\(name).png"))
            }
        }
    }

    static func render(size: Int) -> Data? {
        let s = CGFloat(size)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // macOS icon grid: an 824/1024 rounded square, centred
        let inset = s * 100 / 1024
        let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let shape = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.1, blue: 0.25, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        if let gradient = CGGradient(colorsSpace: space,
                                     colors: [CGColor(srgbRed: 0.16, green: 0.45, blue: 0.95, alpha: 1),
                                              CGColor(srgbRed: 0.07, green: 0.13, blue: 0.42, alpha: 1)] as CFArray,
                                     locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
        }
        // grid dots
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.12))
        let spacing = tile.width / 10
        let dot = max(0.6, s * 0.006)
        for i in 1..<10 {
            for j in 1..<10 {
                ctx.fillEllipse(in: CGRect(x: tile.minX + CGFloat(i) * spacing - dot, y: tile.minY + CGFloat(j) * spacing - dot,
                                           width: 2 * dot, height: 2 * dot))
            }
        }
        // a resistor in a wire, with current flowing through it
        let y = tile.midY
        let left = tile.minX + tile.width * 0.1
        let right = tile.maxX - tile.width * 0.1
        let bodyHalf = tile.width * 0.2
        let amplitude = tile.width * 0.1
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: y))
        path.addLine(to: CGPoint(x: tile.midX - bodyHalf, y: y))
        for k in 0..<6 {
            let x = tile.midX - bodyHalf + 2 * bodyHalf * CGFloat(2 * k + 1) / 12
            path.addLine(to: CGPoint(x: x, y: y + (k % 2 == 0 ? amplitude : -amplitude)))
        }
        path.addLine(to: CGPoint(x: tile.midX + bodyHalf, y: y))
        path.addLine(to: CGPoint(x: right, y: y))
        ctx.addPath(path)
        ctx.setLineWidth(max(1, s * 0.035))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(CGColor(srgbRed: 0.45, green: 0.95, blue: 0.6, alpha: 1))
        ctx.strokePath()
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.84, blue: 0.1, alpha: 1))
        let r = max(1, s * 0.03)
        for x in [left + tile.width * 0.08, tile.midX + bodyHalf + tile.width * 0.1] {
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
        ctx.restoreGState()

        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
