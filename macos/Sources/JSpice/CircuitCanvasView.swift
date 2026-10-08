import AppKit
import SwiftUI
import QuartzCore
import CircuitKit

/// SwiftUI wrapper of the schematic canvas.
struct CircuitCanvas: NSViewRepresentable {
    @ObservedObject var editor: EditorState
    /// Passed in so SwiftUI redraws the canvas when the circuit changes while paused
    var circuit: Circuit

    func makeNSView(context: Context) -> CircuitCanvasView {
        CircuitCanvasView(editor: editor)
    }

    func updateNSView(_ view: CircuitCanvasView, context: Context) {
        view.needsDisplay = true
    }
}

/// The schematic editor: draws the circuit with live voltages and currents and turns mouse and keyboard input into edits.
final class CircuitCanvasView: NSView {
    let editor: EditorState
    private var refreshLink: CADisplayLink?
    private var drag: Drag?
    private var lastFitRequest = 0
    private var mouseLocation: CGPoint?
    /// For a click on a switch: toggle it on mouse up if the mouse did not move
    private var pendingToggle: UUID?

    private enum Drag {
        case placing(Element)
        case moving(start: GridPoint, original: Circuit, ids: Set<UUID>, moved: Bool)
        case endpoint(id: UUID, isA: Bool)
        case rubberBand(start: CGPoint, current: CGPoint, initial: Set<UUID>)
        case panning(last: CGPoint)
        case pressing(UUID)
    }

    init(editor: EditorState) {
        self.editor = editor
        super.init(frame: .zero)
        editor.canvas = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// A click on an inactive window acts at once (to flip a switch, for example) instead of only activating the window
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshLink?.invalidate()
        refreshLink = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(displayRefresh(_:)))
        link.add(to: .main, forMode: .common)
        refreshLink = link
        window?.makeFirstResponder(self)
        // the window in front is the one AI agents work on
        EditorRegistry.active = editor
        // moved between windows: watch only the new one
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification,
                                               object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey(_:)), name: NSWindow.didResignKeyNotification,
                                               object: window)
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        EditorRegistry.active = editor
    }

    /// Another window or app takes the keyboard: the keys held now will never be seen coming up
    @objc private func windowResignedKey(_ notification: Notification) {
        releaseSoundingKeys()
    }

    override func removeFromSuperview() {
        refreshLink?.invalidate()
        refreshLink = nil
        super.removeFromSuperview()
    }

    @objc private func displayRefresh(_ link: CADisplayLink) {
        editor.simulation.tick(at: link.timestamp)
        if editor.simulation.isRunning || drag != nil { needsDisplay = true }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // keep the circuit fitted (for example when scopes appear below) until the user moves the view
        if !editor.viewAdjusted { lastFitRequest = -1 }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // MARK: - Coordinates

    private var unit: CGFloat { editor.unit }

    func screen(_ p: GridPoint) -> CGPoint {
        CGPoint(x: editor.pan.x + CGFloat(p.x) * unit, y: editor.pan.y + CGFloat(p.y) * unit)
    }

    func grid(_ p: CGPoint) -> GridPoint {
        GridPoint(Int(((p.x - editor.pan.x) / unit).rounded()), Int(((p.y - editor.pan.y) / unit).rounded()))
    }

    private func location(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    /// Centres the circuit and picks a zoom that shows all of it
    private func fitCircuit() {
        guard bounds.width > 10, bounds.height > 10 else { return }
        guard let box = editor.circuit.bounds else {
            editor.zoom = 1.25
            editor.pan = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
            return
        }
        // room around the parts for their labels
        let width = CGFloat(box.max.x - box.min.x + 10) * EditorState.gridSize
        let height = CGFloat(box.max.y - box.min.y + 6) * EditorState.gridSize
        let zoom = min(2.5, max(0.4, min(bounds.width / width, bounds.height / height)))
        editor.zoom = zoom
        let unit = EditorState.gridSize * zoom
        editor.pan = CGPoint(x: bounds.width / 2 - CGFloat(box.min.x + box.max.x) / 2 * unit,
                             y: bounds.height / 2 - CGFloat(box.min.y + box.max.y) / 2 * unit)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        editor.viewSize = bounds.size
        if lastFitRequest != editor.fitRequest {
            lastFitRequest = editor.fitRequest
            fitCircuit()
        }
        let palette = CanvasPalette.forAppearance(effectiveAppearance)
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB).map { RGBA($0.redComponent, $0.greenComponent, $0.blueComponent) }
            ?? RGBA(0, 0.48, 1)
        ctx.setFillColor(palette.background.cgColor)
        ctx.fill(bounds)
        drawGrid(ctx, palette)

        let circuit = editor.circuit
        let simulator = editor.simulation.simulator
        // the simulator may still hold the previous circuit for a moment after an edit
        let live = simulator.circuit.elements.map(\.id) == circuit.elements.map(\.id)
        let voltageScale = editor.simulation.voltageScale
        let lineWidth = max(1.3, unit * 0.12)

        for (index, element) in circuit.elements.enumerated() {
            let posts = element.posts.map(screen)
            let a = screen(element.a)
            let b = screen(element.b)
            let voltages = live ? simulator.terminalVoltages(index) : []
            let colors = voltages.isEmpty
                ? Array(repeating: palette.neutral, count: posts.count)
                : voltages.map { palette.color(forVoltage: $0, scale: voltageScale) }
            var style = SymbolStyle(lineWidth: lineWidth, terminalColors: colors, fill: palette.neutral, accent: accent)
            if live {
                style.brightness = element.kind == .analogSwitch ? simulator.switchConduction(index) : simulator.brightness(index)
                style.memristorState = simulator.memristorState(index)
            }
            if element.kind == .probe { style.fill = palette.text }

            if editor.selection.contains(element.id) || editor.hovered == element.id {
                let highlight = editor.selection.contains(element.id) ? accent.withAlpha(0.35) : accent.withAlpha(0.15)
                var glow = style
                glow.lineWidth = lineWidth + max(6, unit * 0.45)
                glow.terminalColors = Array(repeating: highlight, count: posts.count)
                glow.fill = highlight
                glow.brightness = 0
                glow.memristorState = 0
                SymbolRenderer.draw(element, posts: posts, at: a, b, unit: unit, style: glow, in: ctx)
            }
            SymbolRenderer.draw(element, posts: posts, at: a, b, unit: unit, style: style, in: ctx)
        }

        if editor.showCurrent && live { drawCurrentDots(ctx, circuit, palette) }
        drawTerminals(ctx, circuit, palette)
        drawLabels(circuit, live: live, palette)
        drawSelectionHandles(ctx, circuit, accent)
        drawDragFeedback(ctx, palette, accent, lineWidth)
    }

    private func drawGrid(_ ctx: CGContext, _ palette: CanvasPalette) {
        let step = unit < 9 ? 2 : 1
        let spacing = unit * CGFloat(step)
        guard spacing > 4 else { return }
        let startX = editor.pan.x.truncatingRemainder(dividingBy: spacing) - spacing
        let startY = editor.pan.y.truncatingRemainder(dividingBy: spacing) - spacing
        let r = max(0.6, min(1.1, unit / 22))
        let major = max(1.1, min(1.7, unit / 14))
        // every fourth point (a standard part's length) is a little stronger, to help line things up
        let every = 4 / step
        func index(_ v: CGFloat, _ origin: CGFloat) -> Int { Int(((v - origin) / spacing).rounded()) }
        // all the dots of each kind in one path, filled once: thousands of separate fills were the canvas's largest
        // cost at low zoom
        let minor = CGMutablePath()
        let strong = CGMutablePath()
        var y = startY
        while y < bounds.maxY + spacing {
            let row = index(y, editor.pan.y)
            var x = startX
            while x < bounds.maxX + spacing {
                let column = index(x, editor.pan.x)
                if row % every == 0 && column % every == 0 {
                    strong.addEllipse(in: CGRect(x: x - major, y: y - major, width: 2 * major, height: 2 * major))
                } else {
                    minor.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                }
                x += spacing
            }
            y += spacing
        }
        ctx.addPath(minor)
        ctx.setFillColor(palette.grid.cgColor)
        ctx.fillPath()
        ctx.addPath(strong)
        ctx.setFillColor(palette.grid.withAlpha(min(1, palette.grid.a * 1.8)).cgColor)
        ctx.fillPath()
    }

    private func drawCurrentDots(_ ctx: CGContext, _ circuit: Circuit, _ palette: CanvasPalette) {
        let spacing = unit
        let radius = max(1.6, unit * 0.13)
        ctx.setFillColor(palette.dot.cgColor)
        for element in circuit.elements {
            guard let phase = editor.simulation.dotPhase[element.id], phase != 0 else { continue }
            let posts = element.posts.map(screen)
            guard let path = SymbolRenderer.dotPath(element, a: screen(element.a), b: screen(element.b), posts: posts, unit: unit) else { continue }
            let dx = path.to.x - path.from.x
            let dy = path.to.y - path.from.y
            let length = hypot(dx, dy)
            guard length > 1 else { continue }
            var offset = (phase * spacing).truncatingRemainder(dividingBy: spacing)
            if offset < 0 { offset += spacing }
            var distance = offset
            while distance < length {
                if !(path.hidden?.contains(distance) ?? false) {
                    let x = path.from.x + dx * distance / length
                    let y = path.from.y + dy * distance / length
                    ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
                }
                distance += spacing
            }
        }
    }

    /// Filled dots where three or more terminals meet, red rings on terminals that connect to nothing
    private func drawTerminals(_ ctx: CGContext, _ circuit: Circuit, _ palette: CanvasPalette) {
        var count: [GridPoint: Int] = [:]
        for element in circuit.elements {
            for post in element.posts { count[post, default: 0] += 1 }
        }
        let r = max(2.2, unit * 0.16)
        for (point, n) in count {
            let p = screen(point)
            if n >= 3 {
                ctx.setFillColor(palette.neutral.mixed(with: palette.text, 0.4).cgColor)
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            } else if n == 1 {
                ctx.setStrokeColor(palette.unconnected.withAlpha(0.8).cgColor)
                ctx.setLineWidth(1.2)
                ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }
        }
    }

    private func valueLabel(_ element: Element, index: Int, live: Bool) -> String? {
        let simulator = editor.simulation.simulator
        switch element.kind {
        case .probe:
            return live ? SI.format(simulator.voltageAcross(index), unit: "V") : "— V"
        case .ammeter:
            return live ? SI.format(simulator.current(index), unit: "A") : "— A"
        case .resistor: return SI.format(element[param: "resistance"], unit: "Ω")
        case .potentiometer:
            return "\(SI.format(element[param: "resistance"], unit: "Ω")) · \(Int((element[param: "position"] * 100).rounded())) %"
        case .zener: return SI.format(element[param: "breakdown"], unit: "V")
        case .speaker: return "±" + SI.format(element[param: "fullScale"], unit: "V")
        case .lamp: return SI.format(element[param: "resistance"], unit: "Ω")
        case .capacitor: return SI.format(element[param: "capacitance"], unit: "F")
        case .inductor: return SI.format(element[param: "inductance"], unit: "H")
        case .dcVoltage: return SI.format(element[param: "voltage"], unit: "V")
        case .acVoltage:
            return "\(SI.format(element[param: "amplitude"], unit: "V")) \(SI.format(element[param: "frequency"], unit: "Hz"))"
        case .squareVoltage:
            return "\(SI.format(element[param: "high"], unit: "V")) \(SI.format(element[param: "frequency"], unit: "Hz"))"
        case .currentSource: return SI.format(element[param: "current"], unit: "A")
        case .keyboardPitch:
            return live ? SI.format(simulator.voltageAcross(index), unit: "V") : "1 V/oct"
        case .keyboardGate: return "Gate " + SI.format(element[param: "high"], unit: "V")
        case .noiseVoltage: return "Noise " + SI.format(element[param: "amplitude"], unit: "V")
        case .audioInput:
            return element[param: "input"] >= 0.5 ? "Live in" : (element.audio?.name ?? AudioClip.guitarRiff.name)
        case .memristor:
            return live ? SI.format(simulator.value(.resistance, of: index), unit: "Ω") : SI.format(element[param: "roff"], unit: "Ω")
        case .opAmp, .ota, .timer555, .schmittInverter, .unbufferedInverter, .analogSwitch, .njfet, .multiplier, .delayLine,
             .digitalDelay, .vactrol, .comparator, .triode, .pentode, .transformer,
             .vcf, .envelope, .vca, .sampleHold, .logicGate, .flipFlop, .decadeCounter, .binaryCounter, .analogMux, .analogSelector, .pll, .dac:
            // the real part it behaves like
            return element.model?.name ?? "Custom"
        case .atmega328p, .atmega2560, .attiny85, .rp2040:
            let chip = element.kind.board?.chip ?? ""
            return element.firmware == nil ? chip + " · no sketch" : chip
        case .vco:
            let waveform = element.kind.params[0].choices.first { $0.value == element[param: "waveform"].rounded() }?.name ?? ""
            return [element.model?.name ?? "VCO", waveform.lowercased()].joined(separator: " ")
        case .divider:
            return element.model?.name ?? "÷\(Int(element[param: "division"].rounded()))"
        default: return nil
        }
    }

    private func drawLabels(_ circuit: Circuit, live: Bool, _ palette: CanvasPalette) {
        guard unit >= 9 else { return }
        let fontSize = max(9, min(15, unit * 0.68))
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor(cgColor: palette.text.cgColor) ?? .labelColor,
        ]
        let probeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize * 1.15, weight: .semibold),
            .foregroundColor: NSColor(cgColor: palette.text.cgColor) ?? .labelColor,
        ]
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize * 0.85),
            .foregroundColor: NSColor(cgColor: palette.secondaryText.cgColor) ?? .secondaryLabelColor,
        ]
        // where labels must not go: the bodies of the parts, and the labels already placed
        var bodies: [(id: UUID, rect: CGRect)] = []
        // grid points taken by each part's terminals and ends, to see what arches over an amplifier
        var taken: [GridPoint: Int] = [:]
        for element in circuit.elements where element.kind != .wire && element.kind != .netLabel {
            let extent = element.extentPoints
            guard let first = extent.first else { continue }
            var (minX, maxX, minY, maxY) = (first.x, first.x, first.y, first.y)
            for p in extent.dropFirst() {
                minX = min(minX, p.x)
                maxX = max(maxX, p.x)
                minY = min(minY, p.y)
                maxY = max(maxY, p.y)
            }
            let corner1 = screen(GridPoint(minX, minY))
            let corner2 = screen(GridPoint(maxX, maxY))
            let rect = CGRect(x: min(corner1.x, corner2.x), y: min(corner1.y, corner2.y),
                              width: abs(corner2.x - corner1.x), height: abs(corner2.y - corner1.y))
            // two-terminal parts are thin lines: give them their symbol's width
            bodies.append((element.id, rect.insetBy(dx: rect.width < unit ? -0.45 * unit : 0, dy: rect.height < unit ? -0.45 * unit : 0)))
        }
        for element in circuit.elements where element.kind != .wire && element.kind != .ground {
            for p in Set(element.posts + [element.a, element.b]) { taken[p, default: 0] += 1 }
        }
        var placed: [CGRect] = []
        for (index, element) in circuit.elements.enumerated() {
            guard element.kind != .wire, element.kind != .ground, element.kind != .netLabel else { continue }
            // instruments always show their reading
            let isProbe = element.kind == .probe || element.kind == .ammeter
            guard editor.showValues || isProbe else { continue }
            let a = screen(element.a)
            let b = screen(element.b)
            var lines: [NSAttributedString] = []
            if !element.name.isEmpty && !isProbe { lines.append(NSAttributedString(string: element.name, attributes: nameAttributes)) }
            if let value = valueLabel(element, index: index, live: live) {
                lines.append(NSAttributedString(string: value, attributes: isProbe ? probeAttributes : valueAttributes))
            }
            guard !lines.isEmpty else { continue }

            // place the text beside the part: above horizontal parts, to the right of vertical ones, except where a
            // potentiometer's wiper is in the way
            var anchor = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let alongX = abs(b.x - a.x) >= abs(b.y - a.y)
            var horizontal = alongX
            var otherSide = false
            if element.kind.isTransistor || element.kind.isTube {
                // beside the channel, on the side away from the gate
                let away: CGFloat = b.x >= a.x ? 1 : -1
                anchor = CGPoint(x: b.x + (horizontal ? 0.6 * away * unit : 0), y: b.y)
                otherSide = horizontal && away < 0
                horizontal = false
            } else if element.kind == .timer555 || element.chipPackage != nil {
                // centred above the chip
                let points = element.extentPoints.map(screen)
                anchor = CGPoint(x: (points.map(\.x).min()! + points.map(\.x).max()!) / 2, y: points.map(\.y).min()! - 0.4 * unit)
                horizontal = true
            } else if element.kind == .ota || element.kind.drivesOutput || element.kind == .logicGate {
                // below the triangle when a feedback part arches over it
                let left = min(element.a.x, element.b.x)
                let right = max(element.a.x, element.b.x)
                let own = Set(element.posts + [element.a, element.b])
                otherSide = (left...right).contains { x in
                    ((element.a.y - 4)...(element.a.y - 2)).contains { y in
                        let p = GridPoint(x, y)
                        return (taken[p] ?? 0) > (own.contains(p) ? 1 : 0)
                    }
                }
            } else if element.kind == .potentiometer || element.kind == .analogSwitch {
                let wiper = screen(element.wiper)
                otherSide = horizontal ? wiper.y < anchor.y : wiper.x > anchor.x
            }
            let sizes = lines.map { $0.size() }
            let totalHeight = sizes.reduce(0) { $0 + $1.height }
            let offset: CGFloat
            switch element.kind {
            // a vertical transistor's collector and emitter leads reach two units to the side
            case _ where element.kind.isTransistor || element.kind.isTube: offset = alongX ? 0.4 * unit : 2.3 * unit
            case .timer555, .atmega328p, .atmega2560, .attiny85, .rp2040, .flipFlop, .decadeCounter, .binaryCounter, .analogMux,
                 .analogSelector, .pll, .dac: offset = 0
            case _ where element.kind.drivesOutput || element.kind == .ota || element.kind == .logicGate: offset = 1.9 * unit
            case .vactrol, .transformer: offset = 1.9 * unit
            default: offset = (isProbe ? 1.0 : 1.05) * unit
            }
            let width = sizes.map(\.width).max() ?? 0
            /// The block of lines on one side of the part, `extra` further out
            func block(_ side: Bool, _ extra: CGFloat) -> CGRect {
                if horizontal {
                    let y = side ? anchor.y + offset + extra : anchor.y - offset - totalHeight - extra
                    return CGRect(x: anchor.x - width / 2, y: y, width: width, height: totalHeight)
                }
                let x = side ? anchor.x - offset - extra - width : anchor.x + offset + extra
                return CGRect(x: x, y: anchor.y - totalHeight / 2, width: width, height: totalHeight)
            }
            /// How much of the block other labels and parts cover
            func overlap(_ rect: CGRect) -> CGFloat {
                let inner = rect.insetBy(dx: 1, dy: 1)
                func area(_ other: CGRect) -> CGFloat {
                    let common = other.intersection(inner)
                    return common.isNull ? 0 : common.width * common.height
                }
                return placed.reduce(0) { $0 + area($1) }
                    + bodies.reduce(0) { $0 + ($1.id == element.id ? 0 : area($1.rect)) }
            }
            // the usual side, else the other side, else a little further out; if nothing is clear, the least covered
            let step = fontSize * 1.1
            let candidates = [(otherSide, 0.0), (!otherSide, 0.0), (otherSide, step), (!otherSide, step), (otherSide, 2 * step)]
                .map { block($0.0, CGFloat($0.1)) }
            let scored = candidates.map { ($0, overlap($0)) }
            let chosen = scored.first { $0.1 == 0 }?.0 ?? scored.min { $0.1 < $1.1 }?.0 ?? block(otherSide, 0)
            placed.append(chosen)
            var y = chosen.minY
            for (line, size) in zip(lines, sizes) {
                let x = horizontal ? chosen.midX - size.width / 2 : (chosen.maxX <= anchor.x ? chosen.maxX - size.width : chosen.minX)
                line.draw(at: CGPoint(x: x, y: y))
                y += size.height
            }
        }
    }

    private func drawSelectionHandles(_ ctx: CGContext, _ circuit: Circuit, _ accent: RGBA) {
        let selected = circuit.elements.filter { editor.selection.contains($0.id) }
        if selected.count > 1 {
            // a dashed, rounded box around everything selected
            let points = selected.flatMap(\.extentPoints).map(screen)
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
            let pad = max(8, unit * 0.7)
            let box = CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + 2 * pad, height: maxY - minY + 2 * pad)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.setFillColor(accent.withAlpha(0.05).cgColor)
            ctx.fillPath()
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.setStrokeColor(accent.withAlpha(0.7).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [5, 4])
            ctx.strokePath()
            ctx.restoreGState()
            return
        }
        guard let element = selected.first, element.kind != .ground else { return }
        // round handles on the two ends that set the part's length and direction
        let r = max(3.5, unit * 0.22)
        for point in [element.a, element.b] {
            let p = screen(point)
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: CGColor(gray: 0, alpha: 0.35))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillEllipse(in: rect)
            ctx.restoreGState()
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: rect)
        }
    }

    private func drawDragFeedback(_ ctx: CGContext, _ palette: CanvasPalette, _ accent: RGBA, _ lineWidth: CGFloat) {
        switch drag {
        case .placing(let element)?:
            let posts = element.posts.map(screen)
            let style = SymbolStyle(lineWidth: lineWidth, terminalColors: Array(repeating: accent, count: posts.count),
                                    fill: accent, accent: accent)
            SymbolRenderer.draw(element, posts: posts, at: screen(element.a), screen(element.b), unit: unit, style: style, in: ctx)
        case .rubberBand(let start, let current, _)?:
            let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                              width: abs(current.x - start.x), height: abs(current.y - start.y))
            ctx.setFillColor(accent.withAlpha(0.1).cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(accent.withAlpha(0.8).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        default:
            break
        }
        // a ghost of the part a click would place, and the grid point it starts from
        if let kind = editor.tool, drag == nil, let mouse = mouseLocation {
            let start = grid(mouse)
            let ghost = constrained(newElement(kind, at: start, placed: true))
            let posts = ghost.posts.map(screen)
            let faint = accent.withAlpha(0.45)
            let style = SymbolStyle(lineWidth: lineWidth, terminalColors: Array(repeating: faint, count: posts.count),
                                    fill: faint, accent: accent)
            SymbolRenderer.draw(ghost, posts: posts, at: screen(ghost.a), screen(ghost.b), unit: unit, style: style, in: ctx)
            let p = screen(start)
            ctx.setFillColor(accent.withAlpha(0.9).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
        }
    }

    // MARK: - Hit testing

    private func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// The element nearest to `point`, within a few points. Non-wire parts win over wires at the same distance.
    func element(at point: CGPoint) -> Element? {
        var best: (element: Element, distance: CGFloat)?
        let tolerance = max(6, unit * 0.45)
        for element in editor.circuit.elements {
            let posts = element.posts.map(screen)
            let segments = SymbolRenderer.segments(element, a: screen(element.a), b: screen(element.b), posts: posts, unit: unit)
            var d = segments.map { distance(point, toSegment: $0.0, $0.1) }.min() ?? .infinity
            if element.kind == .wire { d += 1.5 }
            if d < tolerance && d < (best?.distance ?? .infinity) { best = (element, d) }
        }
        return best?.element
    }

    /// An end of the selected element close to `point`
    private func endpoint(at point: CGPoint) -> (id: UUID, isA: Bool)? {
        guard editor.selection.count == 1, let element = editor.selectedElement, element.kind != .ground, element.kind != .netLabel else { return nil }
        let tolerance = max(6, unit * 0.35)
        if hypot(point.x - screen(element.b).x, point.y - screen(element.b).y) < tolerance { return (element.id, false) }
        if hypot(point.x - screen(element.a).x, point.y - screen(element.a).y) < tolerance { return (element.id, true) }
        return nil
    }

    /// Transistors, op-amps and potentiometers stay horizontal or vertical (transistors two grid units long); grounds
    /// always point one grid unit away from their terminal
    /// A part of the chosen kind starting at `point`: as a click would place it, or (not placed) with no length yet. The
    /// block tool places the block chosen in the library.
    private func newElement(_ kind: ElementKind, at point: GridPoint, placed: Bool) -> Element {
        var element = Element(kind: kind, a: point, b: point)
        if kind == .block {
            element.block = editor.blockToPlace
            element.name = editor.blockToPlace?.name ?? ""
        }
        if placed { element.b = point + defaultOffset(of: element) }
        return element
    }

    /// Where a click puts a part's second point: a block runs down the page as long as its pins need
    private func defaultOffset(of element: Element) -> GridPoint {
        element.kind == .block ? GridPoint(0, element.fixedLength ?? 2) : element.kind.defaultOffset
    }

    private func constrained(_ element: Element) -> Element {
        var element = element
        guard element.kind.isAxisAligned || element.kind == .ground || element.kind == .netLabel || element.kind == .port else { return element }
        let d = element.b - element.a
        if d == .zero { return element }
        let horizontal = abs(d.x) >= abs(d.y)
        let direction = horizontal ? GridPoint(d.x.signum(), 0) : GridPoint(0, d.y.signum())
        if element.kind == .ground || element.kind == .netLabel || element.kind == .port {
            element.b = element.a + direction
        } else if let fixed = element.fixedLength {
            element.b = element.a + direction * fixed
        } else {
            element.b = element.a + direction * max(2, horizontal ? abs(d.x) : abs(d.y))
        }
        return element
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = location(event)
        let gridPoint = grid(point)
        pendingToggle = nil

        if event.modifierFlags.contains(.option) && editor.tool == nil && element(at: point) == nil {
            drag = .panning(last: point)
            return
        }
        if let kind = editor.tool {
            drag = .placing(newElement(kind, at: gridPoint, placed: false))
            needsDisplay = true
            return
        }
        if event.clickCount == 2, element(at: point) != nil {
            editor.showInspector = true
            return
        }
        if let end = endpoint(at: point) {
            editor.beginInteraction()
            drag = .endpoint(id: end.id, isA: end.isA)
            return
        }
        if let hit = element(at: point) {
            if event.modifierFlags.contains(.shift) {
                if editor.selection.contains(hit.id) { editor.selection.remove(hit.id) } else { editor.selection.insert(hit.id) }
            } else if !editor.selection.contains(hit.id) {
                editor.selection = [hit.id]
            }
            if hit.kind == .pushButton {
                editor.setPressed(hit.id, true)
                drag = .pressing(hit.id)
                return
            }
            if hit.kind == .toggleSwitch && !event.modifierFlags.contains(.shift) { pendingToggle = hit.id }
            drag = .moving(start: gridPoint, original: editor.circuit, ids: editor.selection, moved: false)
            needsDisplay = true
            return
        }
        let additive = event.modifierFlags.contains(.shift)
        if !additive { editor.selection = [] }
        drag = .rubberBand(start: point, current: point, initial: editor.selection)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = location(event)
        mouseLocation = point
        switch drag {
        case .placing(var element)?:
            element.b = grid(point)
            drag = .placing(constrained(element))
        case .moving(let start, let original, let ids, let moved)?:
            let delta = grid(point) - start
            if delta != .zero || moved {
                if !moved { editor.beginInteraction() }
                var next = original
                next.move(ids, by: delta)
                editor.setDuringInteraction(next)
                drag = .moving(start: start, original: original, ids: ids, moved: true)
                pendingToggle = nil
            }
        case .endpoint(let id, let isA)?:
            var next = editor.circuit
            next.update(id) { element in
                if isA { element.a = grid(point) } else { element.b = grid(point) }
                if element.kind.isAxisAligned || element.kind == .ground || element.kind == .netLabel || element.kind == .port {
                    element = constrained(element)
                }
            }
            if let element = next[id], element.a != element.b { editor.setDuringInteraction(next) }
        case .rubberBand(let start, _, let initial)?:
            drag = .rubberBand(start: start, current: point, initial: initial)
            let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
            var selected = initial
            for element in editor.circuit.elements {
                let points = element.extentPoints.map(screen)
                if points.contains(where: { rect.contains($0) }) { selected.insert(element.id) }
            }
            if selected != editor.selection { editor.selection = selected }
        case .panning(let last)?:
            editor.viewAdjusted = true
            editor.pan = CGPoint(x: editor.pan.x + point.x - last.x, y: editor.pan.y + point.y - last.y)
            drag = .panning(last: point)
        case .pressing?, nil:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .placing(var element)?:
            if element.a == element.b { element.b = element.a + defaultOffset(of: element) }
            element = constrained(element)
            if element.a != element.b {
                let id = editor.add(element)
                editor.selection = [id]
            }
        case .moving(_, _, let ids, let moved)?:
            if moved {
                // terminals dropped onto the middle of a wire join it
                editor.connectDuringInteraction(ids)
                editor.endInteraction("Move")
            } else if let id = pendingToggle {
                editor.toggleSwitch(id)
            }
        case .endpoint(let id, _)?:
            editor.connectDuringInteraction([id])
            editor.endInteraction("Resize")
        case .pressing(let id)?:
            editor.setPressed(id, false)
        default:
            break
        }
        drag = nil
        pendingToggle = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = location(event)
        mouseLocation = point
        let hovered = editor.tool == nil ? element(at: point)?.id : nil
        if hovered != editor.hovered { editor.hovered = hovered }
        if let id = hovered, let kind = editor.circuit[id]?.kind, kind.isSwitch || kind == .potentiometer {
            NSCursor.pointingHand.set()
        } else if editor.tool != nil {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        mouseLocation = nil
        if editor.hovered != nil { editor.hovered = nil }
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        // scrolling over a potentiometer turns it, like a knob
        // (not the momentum after a flick to pan, which would turn whatever pot slides under the pointer)
        if !event.modifierFlags.contains(.command), editor.tool == nil, event.momentumPhase.isEmpty,
           let hit = element(at: location(event)), hit.kind == .potentiometer {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.004 : event.scrollingDeltaY * 0.04
            editor.turnPotentiometer(hit.id, by: Double(delta))
            needsDisplay = true
            return
        }
        if event.modifierFlags.contains(.command) {
            editor.changeZoom(by: exp(-event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)), around: location(event))
        } else {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            editor.viewAdjusted = true
            editor.pan = CGPoint(x: editor.pan.x + event.scrollingDeltaX * scale, y: editor.pan.y + event.scrollingDeltaY * scale)
        }
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        editor.changeZoom(by: 1 + event.magnification, around: location(event))
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = location(event)
        guard let hit = element(at: point) else { return nil }
        if !editor.selection.contains(hit.id) { editor.selection = [hit.id] }
        let menu = NSMenu()
        if hit.kind == .toggleSwitch {
            menu.addItem(item(hit.closed ? "Open Switch" : "Close Switch") { [weak self] in self?.editor.toggleSwitch(hit.id) })
            menu.addItem(.separator())
        }
        for quantity in scopeQuantities(for: hit.kind) {
            menu.addItem(item("Add \(quantity.name) Scope") { [weak self] in self?.editor.addScope(hit.id, quantity) })
        }
        if canPlotCurve(hit.kind) {
            menu.addItem(item("Add I–V Curve Scope") { [weak self] in self?.editor.addScope(hit.id, .current, plot: .currentVersusVoltage) })
        }
        if canPlotResponse(hit.kind) {
            menu.addItem(item("Add Frequency Response") { [weak self] in self?.editor.addScope(hit.id, .voltage, plot: .frequencyResponse) })
        }
        if let quantity = scopeQuantities(for: hit.kind).first, canPlotSpectrum(hit.kind) {
            menu.addItem(item("Add Spectrum") { [weak self] in self?.editor.addScope(hit.id, quantity, plot: .spectrum) })
        }
        if MIDIMapping.mappable.contains(hit.kind) {
            menu.addItem(.separator())
            let learning = editor.midiLearning == EditorState.MIDITarget(part: hit.id, inner: nil)
            menu.addItem(item(learning ? "Cancel MIDI Learn" : "MIDI Learn") { [weak self] in self?.editor.learnMIDI(part: hit.id) })
            if let mapping = editor.circuit.midiMapping(part: hit.id) {
                menu.addItem(item("Forget \(mapping.label)") { [weak self] in self?.editor.forgetMIDI(part: hit.id) })
            }
        }
        if hit.kind == .block {
            menu.addItem(.separator())
            menu.addItem(item("Open Block") { [weak self] in self?.editor.openBlock(hit.id) })
            if let name = hit.block?.name, BlockLibrary.block(named: name) != nil {
                menu.addItem(item("Update from Library") { [weak self] in self?.editor.updateBlockFromLibrary(hit.id) })
            }
        }
        menu.addItem(.separator())
        menu.addItem(item("Rotate") { [weak self] in self?.editor.rotateSelection() })
        if hit.kind.canFlip {
            menu.addItem(item("Flip") { [weak self] in self?.editor.flipSelection() })
        }
        menu.addItem(item("Delete") { [weak self] in self?.editor.deleteSelection() })
        return menu
    }

    private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ClosureTarget.invoke), keyEquivalent: "")
        let target = ClosureTarget(action)
        item.target = target
        item.representedObject = target
        return item
    }

    // MARK: - Keyboard

    /// Musical typing: key codes of the keys that play notes, as semitones above the keyboard's base note. The middle
    /// row plays the white keys from A (C) to ; (E an octave up), the row above the black keys, as in Logic and GarageBand.
    static let musicalKeys: [UInt16: Int] = [
        0: 0, 13: 1, 1: 2, 14: 3, 2: 4, 3: 5, 17: 6, 5: 7, 16: 8, 4: 9, 32: 10, 38: 11, 40: 12, 31: 13, 37: 14, 35: 15, 41: 16,
    ]
    /// Keys held down, with the note each one started (so moving the octave does not leave notes hanging)
    private var soundingKeys: [UInt16: Int] = [:]

    /// Plays or releases a note for a musical-typing key; true if the key was one
    private func playKey(_ event: NSEvent, down: Bool) -> Bool {
        let simulation = editor.simulation
        if down {
            guard simulation.playsComputerKeyboard,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
            if event.keyCode == 6 || event.keyCode == 7 {
                // Z and X: an octave down or up
                if !event.isARepeat { simulation.shiftKeyboard(octaves: event.keyCode == 6 ? -1 : 1) }
                return true
            }
            guard let offset = Self.musicalKeys[event.keyCode] else { return false }
            if !event.isARepeat && soundingKeys[event.keyCode] == nil {
                let note = simulation.keyboardBase + offset
                soundingKeys[event.keyCode] = note
                simulation.noteOn(note)
            }
            return true
        }
        guard let note = soundingKeys.removeValue(forKey: event.keyCode) else { return false }
        simulation.noteOff(note)
        return true
    }

    private func releaseSoundingKeys() {
        for note in soundingKeys.values { editor.simulation.noteOff(note) }
        soundingKeys = [:]
    }

    override func keyUp(with event: NSEvent) {
        if playKey(event, down: false) { return }
        super.keyUp(with: event)
    }

    override func resignFirstResponder() -> Bool {
        releaseSoundingKeys()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if playKey(event, down: true) { return }
        // during a drag only Esc counts: it abandons the drag, putting things back where they were
        if let current = drag {
            guard event.keyCode == 53 else { return }
            switch current {
            case .pressing(let id):
                editor.setPressed(id, false)
            case .moving, .endpoint:
                editor.cancelInteraction()
            case .rubberBand(_, _, let initial):
                editor.selection = initial
            case .placing, .panning:
                break
            }
            drag = nil
            needsDisplay = true
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        switch event.keyCode {
        case 51, 117:
            editor.deleteSelection()
            return
        case 53:
            drag = nil
            editor.midiLearning = nil
            editor.tool = nil
            editor.selection = []
            needsDisplay = true
            return
        case 49:
            // held down, Space would run and pause at the key-repeat rate
            if !event.isARepeat { editor.simulation.toggleRunning() }
            return
        default:
            break
        }
        let shift = event.modifierFlags.contains(.shift)
        if modifiers.isEmpty {
            switch event.keyCode {
            case 123, 124, 125, 126:
                // arrows nudge the selection a grid unit, five with ⇧
                guard !editor.selection.isEmpty else { break }
                let step = shift ? 5 : 1
                let delta: GridPoint
                switch event.keyCode {
                case 123: delta = GridPoint(-step, 0)
                case 124: delta = GridPoint(step, 0)
                case 125: delta = GridPoint(0, step)
                default: delta = GridPoint(0, -step)
                }
                editor.nudgeSelection(by: delta)
                return
            case 48:
                // Tab and ⇧Tab step through the parts
                editor.selectNext(backward: shift)
                needsDisplay = true
                return
            default:
                break
            }
            if event.characters == "?" {
                editor.showShortcuts = true
                return
            }
            if event.characters == "/" {
                editor.showQuickAdd = true
                return
            }
        }
        if modifiers.isEmpty, !shift, event.charactersIgnoringModifiers?.lowercased() == "f", !editor.selection.isEmpty {
            editor.flipSelection()
            return
        }
        if modifiers.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased().first,
           let kind = ElementKind.allCases.first(where: { (shift ? $0.shiftShortcut : $0.shortcut) == key }) {
            guard !event.isARepeat else { return }
            editor.tool = editor.tool == kind ? nil : kind
            needsDisplay = true
            return
        }
        super.keyDown(with: event)
    }

    @objc func delete(_ sender: Any?) { editor.deleteSelection() }
    @objc func copy(_ sender: Any?) { editor.copySelection() }
    @objc func cut(_ sender: Any?) { editor.cutSelection() }
    @objc func paste(_ sender: Any?) { editor.paste() }
    @objc override func selectAll(_ sender: Any?) { editor.selectAll() }
}

func scopeQuantities(for kind: ElementKind) -> [Quantity] {
    switch kind {
    case .memristor: return [.voltage, .current, .resistance, .power]
    case .wire, .toggleSwitch, .pushButton, .ammeter: return [.current]
    case .probe, .netLabel, .speaker: return [.voltage]
    case .ground, .atmega328p, .atmega2560, .attiny85, .rp2040, .flipFlop, .decadeCounter, .binaryCounter, .analogMux,
         .analogSelector, .pll, .dac: return []
    case .opAmp, .ota, .timer555, .schmittInverter, .unbufferedInverter, .multiplier, .comparator, .delayLine, .digitalDelay, .vco,
         .vcf, .envelope,
         .vca, .sampleHold,
         .divider, .logicGate:
        return [.voltage, .current]
    case .analogSwitch: return [.voltage, .current, .resistance]
    default: return [.voltage, .current, .power]
    }
}

/// Two-terminal parts with a meaningful current-voltage relation
func canPlotCurve(_ kind: ElementKind) -> Bool {
    switch kind {
    case .resistor, .lamp, .capacitor, .inductor, .diode, .zener, .led, .memristor: return true
    default: return false
    }
}

/// Parts whose voltage can be plotted against frequency: anything with a voltage, apart from the sources that drive it
/// Parts with a voltage or current whose spectrum means something: everything a scope can show over time
func canPlotSpectrum(_ kind: ElementKind) -> Bool {
    !scopeQuantities(for: kind).isEmpty
}

func canPlotResponse(_ kind: ElementKind) -> Bool {
    scopeQuantities(for: kind).contains(.voltage) && !kind.isVoltageSource && kind != .currentSource
}

/// Lets a menu item run a closure
final class ClosureTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}
