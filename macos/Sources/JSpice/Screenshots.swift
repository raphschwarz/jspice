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
        /// Redraw the example with Tidy Up first
        var tidy = false
        /// A part being placed (shows the tool HUD)
        var tool: ElementKind?
        /// The quick-add palette open
        var quickAdd = false
    }

    static let shots: [Shot] = [
        Shot(name: "1-led-light", example: "led", dark: false, seconds: 1, select: .led),
        Shot(name: "2-rc-light", example: "rc", dark: false, seconds: 2.5, select: .capacitor, closeSwitches: true),
        Shot(name: "3-lowpass-dark", example: "lowpass", dark: true, seconds: 3),
        Shot(name: "4-cmos-dark", example: "cmos", dark: true, seconds: 1, select: .nmos),
        Shot(name: "5-memristor-light", example: "memristor", dark: false, seconds: 4, select: .memristor),
        Shot(name: "6-lc-dark", example: "lc", dark: true, seconds: 2, closeSwitches: true),
        Shot(name: "7-new-light", example: nil, dark: false, seconds: 0.5),
        Shot(name: "9-blinker-dark", example: "blinker", dark: true, seconds: 3, select: .npn),
        Shot(name: "10-opamp-light", example: "opamp", dark: false, seconds: 2, select: .opAmp),
        Shot(name: "11-dimmer-light", example: "dimmer", dark: false, seconds: 1.5, select: .potentiometer),
        Shot(name: "12-zener-dark", example: "zener", dark: true, seconds: 2),
        Shot(name: "13-lfo-dark", example: "lfo", dark: true, seconds: 3, select: .opAmp),
        Shot(name: "14-vca-light", example: "vca", dark: false, seconds: 3, select: .ota),
        Shot(name: "15-555-light", example: "555", dark: false, seconds: 3, select: .timer555),
        Shot(name: "16-sample-hold-dark", example: "sh", dark: true, seconds: 3, select: .analogSwitch),
        Shot(name: "17-schmitt-light", example: "schmitt", dark: false, seconds: 2, select: .schmittInverter),
        Shot(name: "18-netlist-light", example: "netlist", dark: false, seconds: 1),
        Shot(name: "20-tidy-lfo-dark", example: "lfo", dark: true, seconds: 2, tidy: true),
        Shot(name: "21-tidy-555-light", example: "555", dark: false, seconds: 2, tidy: true),
        Shot(name: "22-tidy-vca-light", example: "vca", dark: false, seconds: 2, tidy: true),
        Shot(name: "23-tremolo-dark", example: "tremolo", dark: true, seconds: 1.5, select: .speaker),
        Shot(name: "24-beeper-light", example: "beeper", dark: false, seconds: 1, select: .timer555),
        Shot(name: "25-synth-light", example: "synth", dark: false, seconds: 1, select: .ota),
        Shot(name: "26-vco-dark", example: "vco", dark: true, seconds: 1, select: .pnp),
        Shot(name: "27-filter-light", example: "vcf", dark: false, seconds: 1, select: .potentiometer),
        Shot(name: "28-voice-dark", example: "voice", dark: true, seconds: 1, select: .keyboardGate),
        Shot(name: "29-acid-light", example: "acid", dark: false, seconds: 1, select: .keyboardPitch),
        Shot(name: "30-panel-dark", example: "tone", dark: true, seconds: 1.5),
        Shot(name: "31-chorus-light", example: "chorus", dark: false, seconds: 0.5, select: .delayLine),
        Shot(name: "32-fuzz-dark", example: "fuzz", dark: true, seconds: 0.5, select: .npn),
        Shot(name: "33-lpg-light", example: "lpg", dark: false, seconds: 0.6, select: .vactrol),
        Shot(name: "34-ringmod-dark", example: "ringmod", dark: true, seconds: 0.3, select: .multiplier),
        Shot(name: "35-quickadd-light", example: "overdrive", dark: false, seconds: 0.5, quickAdd: true),
        Shot(name: "36-tool-dark", example: "opamp", dark: true, seconds: 0.5, tool: .resistor),
        Shot(name: "37-chipvoice-dark", example: "chipvoice", dark: true, seconds: 1, select: .vcf),
        Shot(name: "38-random-light", example: "random", dark: false, seconds: 1.5, select: .sampleHold),
        Shot(name: "39-pwm-dark", example: "pwm", dark: true, seconds: 1, select: .comparator),
        Shot(name: "40-arduino-knob-light", example: "arduino-knob", dark: false, seconds: 1, select: .atmega328p),
        Shot(name: "41-arduino-melody-dark", example: "arduino-melody", dark: true, seconds: 1, select: .atmega328p),
        Shot(name: "42-mega-bargraph-light", example: "arduino-mega-bargraph", dark: false, seconds: 0.5, select: .atmega2560),
        Shot(name: "43-attiny85-dimmer-dark", example: "attiny85-dimmer", dark: true, seconds: 0.5, select: .attiny85),
        Shot(name: "44-pico-knob-light", example: "pico-knob", dark: false, seconds: 2.5, select: .rp2040),
    ]

    static func run(outputDirectory: String, selfTest: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate(output: URL(fileURLWithPath: outputDirectory, isDirectory: true), selfTest: selfTest)
        self.delegate = delegate
        app.delegate = delegate
        app.run()
    }

    private final class Delegate: NSObject, NSApplicationDelegate {
        let output: URL
        let selfTest: Bool

        init(output: URL, selfTest: Bool) {
            self.output = output
            self.selfTest = selfTest
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            Task { @MainActor in
                if selfTest {
                    let passed = await InteractionTest.run(screenshots: output)
                    exit(passed ? 0 : 1)
                }
                await ScreenshotRunner.capture(to: output)
                NSApp.terminate(nil)
            }
        }
    }

    /// A Sallen-Key low-pass filter as an AI agent would describe it, laid out from its netlist
    private static func netlistDemo() -> Circuit {
        let parts = [
            NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": 1, "frequency": 200], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 10_000], connections: ["a": "in", "b": "mid"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 10_000], connections: ["a": "mid", "b": "plus"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 22e-9], connections: ["a": "mid", "b": "out"]),
            NetlistPart(kind: .capacitor, name: "C2", params: ["capacitance": 10e-9], connections: ["a": "plus", "b": "GND"]),
            NetlistPart(kind: .opAmp, name: "U1", params: Examples.model(.opAmp, "TL072"),
                        connections: ["plus": "plus", "minus": "out", "out": "out"]),
        ]
        return (try? SchematicLayout.layout(parts)) ?? Circuit()
    }

    private static func capture(to directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for shot in shots {
            NSApp.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
            let example = shot.example.flatMap { Examples.example($0) }
            var circuit = example?.circuit ?? (shot.example == "netlist" ? netlistDemo() : Circuit())
            if shot.tidy, let tidied = try? SchematicLayout.tidy(circuit) { circuit = tidied }
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
            editor.tool = shot.tool

            let controller = NSHostingController(rootView: EditorView(document: document, editor: editor))
            controller.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.title = example?.title ?? "Untitled"
            window.setContentSize(NSSize(width: 1440, height: 900))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            if shot.quickAdd {
                try? await Task.sleep(nanoseconds: 300_000_000)
                editor.showQuickAdd = true
            }

            // let it lay out and simulate in real time
            try? await Task.sleep(nanoseconds: UInt64((shot.seconds + 1) * 1_000_000_000))
            InteractionTest.capture(window, to: directory.appendingPathComponent("\(shot.name).png"))
            window.orderOut(nil)
            window.close()
        }
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
