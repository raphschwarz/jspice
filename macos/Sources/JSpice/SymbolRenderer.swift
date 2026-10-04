import AppKit
import CircuitKit

/// An sRGB colour that can be blended, for voltage colouring.
struct RGBA: Equatable {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1

    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    func mixed(with other: RGBA, _ t: CGFloat) -> RGBA {
        RGBA(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t, a + (other.a - a) * t)
    }

    func withAlpha(_ alpha: CGFloat) -> RGBA { RGBA(r, g, b, alpha) }
}

/// Colours of the schematic canvas in light and dark mode.
struct CanvasPalette {
    let background: RGBA
    let grid: RGBA
    /// A conductor at 0 V
    let neutral: RGBA
    let positive: RGBA
    let negative: RGBA
    let dot: RGBA
    let text: RGBA
    let secondaryText: RGBA
    let unconnected: RGBA
    let isDark: Bool

    static let light = CanvasPalette(
        background: RGBA(0.985, 0.985, 0.98), grid: RGBA(0.78, 0.78, 0.76), neutral: RGBA(0.45, 0.45, 0.48),
        positive: RGBA(0.06, 0.62, 0.30), negative: RGBA(0.86, 0.20, 0.22), dot: RGBA(0.96, 0.58, 0.0),
        text: RGBA(0.1, 0.1, 0.1), secondaryText: RGBA(0.42, 0.42, 0.44), unconnected: RGBA(0.86, 0.20, 0.22), isDark: false)

    static let dark = CanvasPalette(
        background: RGBA(0.09, 0.09, 0.10), grid: RGBA(0.30, 0.30, 0.32), neutral: RGBA(0.56, 0.56, 0.60),
        positive: RGBA(0.20, 0.84, 0.42), negative: RGBA(1.0, 0.38, 0.38), dot: RGBA(1.0, 0.84, 0.04),
        text: RGBA(0.95, 0.95, 0.95), secondaryText: RGBA(0.68, 0.68, 0.70), unconnected: RGBA(1.0, 0.38, 0.38), isDark: true)

    static func forAppearance(_ appearance: NSAppearance) -> CanvasPalette {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }

    /// Green for positive, red for negative, grey at 0 V
    func color(forVoltage v: Double, scale: Double) -> RGBA {
        let t = CGFloat(max(-1, min(1, v / max(scale, 1e-9))))
        return neutral.mixed(with: t >= 0 ? positive : negative, abs(t))
    }
}

/// What the renderer needs to know about an element beyond its geometry.
struct SymbolStyle {
    var lineWidth: CGFloat
    /// Colours of the a/b terminals (gate/drain/source for transistors)
    var terminalColors: [RGBA]
    var fill: RGBA
    var brightness: Double = 0
    var memristorState: Double = 0
    var accent: RGBA
}

/// Draws schematic symbols with CoreGraphics. Two-terminal parts are drawn in a local frame where the part runs along the
/// x axis from 0 to its length, so every symbol is written once and works at any angle.
enum SymbolRenderer {
    /// Length of the drawn body along the element, in grid units; the rest is leads
    static func bodyLength(_ kind: ElementKind) -> CGFloat {
        switch kind {
        case .wire, .ground, .netLabel, .nmos, .pmos, .npn, .pnp, .njfet, .opAmp, .ota, .timer555: return 0
        case .schmittInverter: return 1.8
        case .analogSwitch: return 1.6
        case .resistor, .potentiometer, .inductor: return 2
        case .memristor: return 2.2
        case .lamp, .probe, .ammeter, .speaker: return 1.4
        case .capacitor, .dcVoltage: return 0.5
        case .acVoltage, .squareVoltage, .currentSource, .keyboardPitch, .keyboardGate: return 1.6
        case .toggleSwitch, .pushButton: return 1.6
        case .diode, .zener, .led: return 1
        }
    }

    static func draw(_ element: Element, posts: [CGPoint], at a: CGPoint, _ b: CGPoint, unit u: CGFloat, style: SymbolStyle,
                     in ctx: CGContext) {
        switch element.kind {
        case .ground:
            drawGround(at: a, toward: b, unit: u, style: style, in: ctx)
        case .netLabel:
            drawNetLabel(element.name, at: a, toward: b, unit: u, style: style, in: ctx)
        case .nmos, .pmos:
            drawTransistor(element, at: a, b, unit: u, style: style, in: ctx)
        case .npn, .pnp:
            drawBipolar(element, at: a, b, unit: u, style: style, in: ctx)
        case .njfet:
            drawJFET(element, at: a, b, unit: u, style: style, in: ctx)
        case .opAmp, .ota:
            drawOpAmp(element, posts: posts, at: a, b, unit: u, style: style, in: ctx)
        case .timer555:
            drawTimer(posts: posts, at: a, b, unit: u, style: style, in: ctx)
        case .analogSwitch:
            drawTwoTerminal(element, at: a, b, unit: u, style: style, in: ctx)
            if posts.count == 3 { drawControl(from: posts[2], at: a, b, unit: u, style: style, in: ctx) }
        case .potentiometer:
            drawTwoTerminal(element, at: a, b, unit: u, style: style, in: ctx)
            if posts.count == 3 { drawWiper(from: posts[2], toward: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), unit: u, style: style, in: ctx) }
        default:
            drawTwoTerminal(element, at: a, b, unit: u, style: style, in: ctx)
        }
    }

    /// Rotates (and for flipped parts mirrors) the context so the element runs along +x from `a`
    private static func enterFrame(of element: Element, at a: CGPoint, _ b: CGPoint, in ctx: CGContext) {
        ctx.translateBy(x: a.x, y: a.y)
        ctx.rotate(by: atan2(b.y - a.y, b.x - a.x))
        if element.flipped && element.kind.canFlip { ctx.scaleBy(x: 1, y: -1) }
    }

    // MARK: - Two-terminal parts

    private static func drawTwoTerminal(_ element: Element, at a: CGPoint, _ b: CGPoint, unit u: CGFloat, style: SymbolStyle,
                                        in ctx: CGContext) {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0.5 else { return }
        let kind = element.kind
        let body = min(length, bodyLength(kind) * u)
        let c = length / 2
        let h = body / 2
        let colorA = style.terminalColors.first ?? style.fill
        let colorB = style.terminalColors.count > 1 ? style.terminalColors[1] : colorA

        ctx.saveGState()
        ctx.translateBy(x: a.x, y: a.y)
        ctx.rotate(by: atan2(b.y - a.y, b.x - a.x))

        let path = CGMutablePath()
        if kind == .wire {
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: length, y: 0))
        } else {
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: c - h, y: 0))
            path.move(to: CGPoint(x: c + h, y: 0))
            path.addLine(to: CGPoint(x: length, y: 0))
        }

        // fills and glows go underneath the outline
        switch kind {
        case .lamp:
            glow(at: CGPoint(x: c, y: 0), radius: h * 2.6, color: RGBA(1, 0.85, 0.35), amount: style.brightness, in: ctx)
            ctx.setFillColor(RGBA(1, 0.9, 0.5, CGFloat(style.brightness) * 0.85).cgColor)
            ctx.fillEllipse(in: CGRect(x: c - h, y: -h, width: body, height: body))
        case .led:
            let (r, g, bl) = (LEDColor(rawValue: Int(element[param: "color"])) ?? .red).rgb
            glow(at: CGPoint(x: c, y: 0), radius: u * 2.2, color: RGBA(r, g, bl), amount: style.brightness, in: ctx)
        case .diode:
            break
        case .memristor:
            // the "on" region grows with the state
            let inner = body - 0.35 * u
            ctx.setFillColor(style.accent.withAlpha(0.28).cgColor)
            ctx.fill(CGRect(x: c - h, y: -0.3 * u, width: max(0, inner * CGFloat(style.memristorState)), height: 0.6 * u))
        case .acVoltage, .squareVoltage, .currentSource, .probe, .ammeter, .keyboardPitch, .keyboardGate:
            ctx.setFillColor(style.fill.withAlpha(style.fill.a * 0.08).cgColor)
            ctx.fillEllipse(in: CGRect(x: c - h, y: -h, width: body, height: body))
        default:
            break
        }

        var thickPlate: CGPath?
        switch kind {
        case .resistor, .potentiometer:
            let amplitude = 0.32 * u
            for j in 0..<6 {
                let x = c - h + body * CGFloat(2 * j + 1) / 12
                if j == 0 { path.move(to: CGPoint(x: c - h, y: 0)) }
                path.addLine(to: CGPoint(x: x, y: j % 2 == 0 ? -amplitude : amplitude))
            }
            path.addLine(to: CGPoint(x: c + h, y: 0))
        case .lamp:
            path.addEllipse(in: CGRect(x: c - h, y: -h, width: body, height: body))
            let d = h * 0.7071
            path.move(to: CGPoint(x: c - d, y: -d))
            path.addLine(to: CGPoint(x: c + d, y: d))
            path.move(to: CGPoint(x: c - d, y: d))
            path.addLine(to: CGPoint(x: c + d, y: -d))
        case .capacitor:
            for x in [c - h, c + h] {
                path.move(to: CGPoint(x: x, y: -0.75 * u))
                path.addLine(to: CGPoint(x: x, y: 0.75 * u))
            }
        case .inductor:
            let r = body / 8
            path.move(to: CGPoint(x: c - h, y: 0))
            for k in 0..<4 {
                path.addArc(center: CGPoint(x: c - h + r * CGFloat(2 * k + 1), y: 0), radius: r,
                            startAngle: .pi, endAngle: 0, clockwise: false)
            }
        case .dcVoltage:
            // long thin plate is +, at the b end
            path.move(to: CGPoint(x: c + h, y: -0.8 * u))
            path.addLine(to: CGPoint(x: c + h, y: 0.8 * u))
            let minus = CGMutablePath()
            minus.move(to: CGPoint(x: c - h, y: -0.38 * u))
            minus.addLine(to: CGPoint(x: c - h, y: 0.38 * u))
            thickPlate = minus
            addPlus(to: path, at: CGPoint(x: c + h + 0.4 * u, y: -0.75 * u), size: 0.16 * u)
        case .acVoltage, .squareVoltage, .keyboardPitch, .keyboardGate:
            // the waveform (or keys) inside is drawn upright afterwards
            path.addEllipse(in: CGRect(x: c - h, y: -h, width: body, height: body))
            addPlus(to: path, at: CGPoint(x: c + h + 0.3 * u, y: -0.8 * u), size: 0.16 * u)
        case .currentSource:
            path.addEllipse(in: CGRect(x: c - h, y: -h, width: body, height: body))
            path.move(to: CGPoint(x: c - 0.45 * u, y: 0))
            path.addLine(to: CGPoint(x: c + 0.45 * u, y: 0))
            path.move(to: CGPoint(x: c + 0.2 * u, y: -0.22 * u))
            path.addLine(to: CGPoint(x: c + 0.45 * u, y: 0))
            path.addLine(to: CGPoint(x: c + 0.2 * u, y: 0.22 * u))
        case .toggleSwitch:
            // closed, the lever rests on top of the far contact, so it still reads as a switch
            path.move(to: CGPoint(x: c - h, y: 0))
            path.addLine(to: element.closed ? CGPoint(x: c + h, y: -0.2 * u) : CGPoint(x: c + h * 0.85, y: -0.75 * u))
        case .pushButton:
            let bar: CGFloat = element.closed ? -0.15 * u : -0.55 * u
            path.move(to: CGPoint(x: c - h, y: bar))
            path.addLine(to: CGPoint(x: c + h, y: bar))
            path.move(to: CGPoint(x: c, y: bar))
            path.addLine(to: CGPoint(x: c, y: bar - 0.5 * u))
            path.move(to: CGPoint(x: c - 0.25 * u, y: bar - 0.5 * u))
            path.addLine(to: CGPoint(x: c + 0.25 * u, y: bar - 0.5 * u))
        case .diode, .zener, .led:
            path.move(to: CGPoint(x: c - h, y: -0.5 * u))
            path.addLine(to: CGPoint(x: c - h, y: 0.5 * u))
            path.addLine(to: CGPoint(x: c + h, y: 0))
            path.closeSubpath()
            if kind == .zener {
                // cathode bar with bent ends
                path.move(to: CGPoint(x: c + h - 0.22 * u, y: -0.62 * u))
                path.addLine(to: CGPoint(x: c + h, y: -0.5 * u))
                path.addLine(to: CGPoint(x: c + h, y: 0.5 * u))
                path.addLine(to: CGPoint(x: c + h + 0.22 * u, y: 0.62 * u))
            } else {
                path.move(to: CGPoint(x: c + h, y: -0.5 * u))
                path.addLine(to: CGPoint(x: c + h, y: 0.5 * u))
            }
            if kind == .led {
                for offset in [CGFloat(0), 0.35] {
                    let start = CGPoint(x: c - 0.05 * u + offset * u, y: -0.65 * u)
                    let end = CGPoint(x: start.x + 0.35 * u, y: start.y - 0.35 * u)
                    path.move(to: start)
                    path.addLine(to: end)
                    path.move(to: CGPoint(x: end.x - 0.17 * u, y: end.y))
                    path.addLine(to: end)
                    path.addLine(to: CGPoint(x: end.x, y: end.y + 0.17 * u))
                }
            }
        case .memristor:
            path.addRect(CGRect(x: c - h, y: -0.3 * u, width: body, height: 0.6 * u))
        case .probe:
            path.addEllipse(in: CGRect(x: c - h, y: -h, width: body, height: body))
            // "+" marks the terminal measured against the other
            addPlus(to: path, at: CGPoint(x: c - h - 0.35 * u, y: -0.65 * u), size: 0.16 * u)
        case .ammeter:
            path.addEllipse(in: CGRect(x: c - h, y: -h, width: body, height: body))
        case .speaker:
            // magnet and cone, opening to one side of the leads
            path.addRect(CGRect(x: c - h, y: -0.3 * u, width: 0.5 * u, height: 0.6 * u))
            path.move(to: CGPoint(x: c - h + 0.5 * u, y: -0.3 * u))
            path.addLine(to: CGPoint(x: c + h, y: -0.75 * u))
            path.addLine(to: CGPoint(x: c + h, y: 0.75 * u))
            path.addLine(to: CGPoint(x: c - h + 0.5 * u, y: 0.3 * u))
        case .analogSwitch:
            // closed while the control input is high
            path.move(to: CGPoint(x: c - h, y: 0))
            path.addLine(to: style.brightness > 0.5 ? CGPoint(x: c + h, y: -0.2 * u) : CGPoint(x: c + h * 0.85, y: -0.75 * u))
        case .schmittInverter:
            // triangle, output bubble, and the hysteresis glyph inside
            let r = 0.17 * u
            let tip = c + h - 2 * r
            path.move(to: CGPoint(x: c - h, y: -0.8 * u))
            path.addLine(to: CGPoint(x: c - h, y: 0.8 * u))
            path.addLine(to: CGPoint(x: tip, y: 0))
            path.closeSubpath()
            path.addEllipse(in: CGRect(x: tip, y: -r, width: 2 * r, height: 2 * r))
            let x0 = c - h + 0.22 * u
            path.move(to: CGPoint(x: x0, y: 0.2 * u))
            path.addLine(to: CGPoint(x: x0 + 0.4 * u, y: 0.2 * u))
            path.addLine(to: CGPoint(x: x0 + 0.4 * u, y: -0.2 * u))
            path.move(to: CGPoint(x: x0 + 0.2 * u, y: 0.2 * u))
            path.addLine(to: CGPoint(x: x0 + 0.2 * u, y: -0.2 * u))
            path.addLine(to: CGPoint(x: x0 + 0.6 * u, y: -0.2 * u))
        case .wire, .ground, .netLabel, .nmos, .pmos, .npn, .pnp, .njfet, .opAmp, .ota, .timer555:
            break
        }

        let start = length > 0 ? (c - h) / length : 0
        let end = length > 0 ? (c + h) / length : 1
        stroke(path, width: style.lineWidth, from: colorA, to: colorB, start: start, end: end, length: length, in: ctx)
        if let thickPlate {
            stroke(thickPlate, width: style.lineWidth * 2.4, from: colorA, to: colorA, start: 0, end: 1, length: length, in: ctx)
        }

        switch kind {
        case .toggleSwitch, .pushButton, .analogSwitch:
            for (x, color) in [(c - h, colorA), (c + h, colorB)] {
                ctx.setFillColor(color.cgColor)
                let r = max(2, 0.18 * u)
                ctx.fillEllipse(in: CGRect(x: x - r, y: -r, width: 2 * r, height: 2 * r))
            }
        case .memristor:
            ctx.setFillColor(colorB.cgColor)
            ctx.fill(CGRect(x: c + h - 0.35 * u, y: -0.3 * u, width: 0.35 * u, height: 0.6 * u))
        default:
            break
        }
        ctx.restoreGState()

        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        if kind == .acVoltage || kind == .squareVoltage || kind.isKeyboard {
            // the waveform stays upright whatever the source's direction
            let glyph = CGMutablePath()
            if kind == .keyboardPitch {
                // three piano keys
                glyph.addRect(CGRect(x: mid.x - 0.45 * u, y: mid.y - 0.3 * u, width: 0.9 * u, height: 0.6 * u))
                for dx in [-0.15, 0.15] {
                    glyph.move(to: CGPoint(x: mid.x + CGFloat(dx) * u, y: mid.y - 0.3 * u))
                    glyph.addLine(to: CGPoint(x: mid.x + CGFloat(dx) * u, y: mid.y + 0.3 * u))
                }
            } else if kind == .keyboardGate {
                // a single gate pulse
                let wave: [(CGFloat, CGFloat)] = [(-0.45, 0.25), (-0.25, 0.25), (-0.25, -0.25), (0.25, -0.25), (0.25, 0.25), (0.45, 0.25)]
                glyph.addLines(between: wave.map { CGPoint(x: mid.x + $0.0 * u, y: mid.y + $0.1 * u) })
            } else if kind == .acVoltage {
                for i in 0...24 {
                    let t = CGFloat(i) / 24
                    let point = CGPoint(x: mid.x - 0.5 * u + t * u, y: mid.y - 0.28 * u * sin(2 * .pi * t))
                    if i == 0 { glyph.move(to: point) } else { glyph.addLine(to: point) }
                }
            } else {
                let wave: [(CGFloat, CGFloat)] = [(-0.45, 0.25), (-0.45, -0.25), (0, -0.25), (0, 0.25), (0.45, 0.25), (0.45, -0.25)]
                glyph.addLines(between: wave.map { CGPoint(x: mid.x + $0.0 * u, y: mid.y + $0.1 * u) })
            }
            ctx.addPath(glyph)
            ctx.setStrokeColor(colorA.mixed(with: colorB, 0.5).cgColor)
            ctx.setLineWidth(style.lineWidth)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.strokePath()
        }
        if kind == .probe || kind == .ammeter {
            // the letter stays upright whatever the instrument's direction
            let v = CGMutablePath()
            if kind == .probe {
                v.move(to: CGPoint(x: mid.x - 0.25 * u, y: mid.y - 0.3 * u))
                v.addLine(to: CGPoint(x: mid.x, y: mid.y + 0.3 * u))
                v.addLine(to: CGPoint(x: mid.x + 0.25 * u, y: mid.y - 0.3 * u))
            } else {
                v.move(to: CGPoint(x: mid.x - 0.25 * u, y: mid.y + 0.3 * u))
                v.addLine(to: CGPoint(x: mid.x, y: mid.y - 0.3 * u))
                v.addLine(to: CGPoint(x: mid.x + 0.25 * u, y: mid.y + 0.3 * u))
                v.move(to: CGPoint(x: mid.x - 0.14 * u, y: mid.y + 0.06 * u))
                v.addLine(to: CGPoint(x: mid.x + 0.14 * u, y: mid.y + 0.06 * u))
            }
            ctx.addPath(v)
            ctx.setStrokeColor(style.fill.cgColor)
            ctx.setLineWidth(style.lineWidth)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }
    }

    private static func addPlus(to path: CGMutablePath, at point: CGPoint, size: CGFloat) {
        path.move(to: CGPoint(x: point.x - size, y: point.y))
        path.addLine(to: CGPoint(x: point.x + size, y: point.y))
        path.move(to: CGPoint(x: point.x, y: point.y - size))
        path.addLine(to: CGPoint(x: point.x, y: point.y + size))
    }

    /// Strokes `path` with a colour that changes from `colorA` to `colorB` across the body (between `start` and `end`,
    /// as fractions of the element's length), so a voltage drop is visible along the part.
    private static func stroke(_ path: CGPath, width: CGFloat, from colorA: RGBA, to colorB: RGBA, start: CGFloat, end: CGFloat,
                               length: CGFloat, in ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if colorA == colorB {
            ctx.setStrokeColor(colorA.cgColor)
            ctx.strokePath()
        } else {
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            let locations: [CGFloat] = [0, max(0, min(1, start)), max(0, min(1, end)), 1]
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                         colors: [colorA.cgColor, colorA.cgColor, colorB.cgColor, colorB.cgColor] as CFArray,
                                         locations: locations) {
                ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: length, y: 0),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        }
        ctx.restoreGState()
    }

    private static func glow(at center: CGPoint, radius: CGFloat, color: RGBA, amount: Double, in ctx: CGContext) {
        guard amount > 0.01 else { return }
        let strength = CGFloat(min(1, amount))
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [color.withAlpha(0.75 * strength).cgColor, color.withAlpha(0).cgColor] as CFArray,
                                        locations: [0, 1]) else { return }
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    // MARK: - Ground

    private static func drawGround(at a: CGPoint, toward b: CGPoint, unit u: CGFloat, style: SymbolStyle, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: a.x, y: a.y)
        ctx.rotate(by: atan2(b.y - a.y, b.x - a.x))
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 0.5 * u, y: 0))
        for (x, half) in [(0.5, 0.6), (0.75, 0.38), (1.0, 0.16)] as [(CGFloat, CGFloat)] {
            path.move(to: CGPoint(x: x * u, y: -half * u))
            path.addLine(to: CGPoint(x: x * u, y: half * u))
        }
        let color = style.terminalColors.first ?? style.fill
        stroke(path, width: style.lineWidth, from: color, to: color, start: 0, end: 1, length: u, in: ctx)
        ctx.restoreGState()
    }

    /// Net label: a lead from its terminal and a tag with the net's name; every label with that name is connected
    private static func drawNetLabel(_ name: String, at a: CGPoint, toward b: CGPoint, unit u: CGFloat, style: SymbolStyle,
                                     in ctx: CGContext) {
        let length = max(hypot(b.x - a.x, b.y - a.y), 1)
        let direction = CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
        let color = style.terminalColors.first ?? style.fill
        let start = CGPoint(x: a.x + direction.x * 0.6 * u, y: a.y + direction.y * 0.6 * u)
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(style.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: a)
        ctx.addLine(to: start)
        ctx.strokePath()
        // the tag: a box with a point towards the terminal, sized to the name, always upright
        let text = name.isEmpty ? "?" : name
        let size = max(5, 0.62 * u)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ]))
        let textWidth = u >= 7 ? CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) : 0.6 * u
        let width = textWidth + 0.7 * u
        let height = 0.95 * u
        let horizontal = abs(direction.x) >= abs(direction.y)
        let tag = CGMutablePath()
        let centre: CGPoint
        if horizontal {
            let sign: CGFloat = direction.x >= 0 ? 1 : -1
            let x0 = start.x
            let x1 = start.x + sign * 0.35 * u
            let x2 = start.x + sign * width
            tag.move(to: CGPoint(x: x0, y: start.y))
            tag.addLine(to: CGPoint(x: x1, y: start.y - height / 2))
            tag.addLine(to: CGPoint(x: x2, y: start.y - height / 2))
            tag.addLine(to: CGPoint(x: x2, y: start.y + height / 2))
            tag.addLine(to: CGPoint(x: x1, y: start.y + height / 2))
            tag.closeSubpath()
            centre = CGPoint(x: (x1 + x2) / 2, y: start.y)
        } else {
            let sign: CGFloat = direction.y >= 0 ? 1 : -1
            let y1 = start.y + sign * 0.3 * u
            let y2 = start.y + sign * (0.3 * u + height)
            tag.move(to: start)
            tag.addLine(to: CGPoint(x: start.x - width / 2, y: y1))
            tag.addLine(to: CGPoint(x: start.x - width / 2, y: y2))
            tag.addLine(to: CGPoint(x: start.x + width / 2, y: y2))
            tag.addLine(to: CGPoint(x: start.x + width / 2, y: y1))
            tag.closeSubpath()
            centre = CGPoint(x: start.x, y: (y1 + y2) / 2)
        }
        ctx.addPath(tag)
        ctx.setFillColor(color.withAlpha(0.14).cgColor)
        ctx.fillPath()
        ctx.addPath(tag)
        ctx.strokePath()
        ctx.restoreGState()
        if u >= 7 {
            drawText(text, at: centre, size: size, color: style.fill, anchor: 0.5, bold: true, in: ctx)
        }
    }

    // MARK: - Transistors

    /// Gate at `a`, channel at `b`; drain and source two grid units either side of `b`
    private static func drawTransistor(_ element: Element, at a: CGPoint, _ b: CGPoint, unit u: CGFloat, style: SymbolStyle,
                                       in ctx: CGContext) {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0.5 else { return }
        let isN = element.kind == .nmos
        let colors = style.terminalColors.count == 3 ? style.terminalColors : [style.fill, style.fill, style.fill]
        let (gateColor, drainColor, sourceColor) = (colors[0], colors[1], colors[2])
        let L = length
        // drain above the channel for NMOS, below for PMOS (in the element's frame)
        let drainY: CGFloat = (isN ? -2 : 2) * u
        let sourceY = -drainY
        let side: (CGFloat) -> CGFloat = { $0 >= 0 ? 1 : -1 }
        let channelX = L - 0.3 * u
        let plateX = L - 0.55 * u

        ctx.saveGState()
        enterFrame(of: element, at: a, b, in: ctx)

        let gate = CGMutablePath()
        gate.move(to: .zero)
        gate.addLine(to: CGPoint(x: isN ? plateX : plateX - 0.32 * u, y: 0))
        if !isN { gate.addEllipse(in: CGRect(x: plateX - 0.32 * u, y: -0.16 * u, width: 0.32 * u, height: 0.32 * u)) }
        gate.move(to: CGPoint(x: plateX, y: -0.7 * u))
        gate.addLine(to: CGPoint(x: plateX, y: 0.7 * u))
        stroke(gate, width: style.lineWidth, from: gateColor, to: gateColor, start: 0, end: 1, length: L, in: ctx)

        let channel = CGMutablePath()
        for (from, to) in [(-0.8, -0.35), (-0.2, 0.2), (0.35, 0.8)] as [(CGFloat, CGFloat)] {
            channel.move(to: CGPoint(x: channelX, y: from * u))
            channel.addLine(to: CGPoint(x: channelX, y: to * u))
        }
        stroke(channel, width: style.lineWidth * 1.3, from: drainColor.mixed(with: sourceColor, 0.5),
               to: drainColor.mixed(with: sourceColor, 0.5), start: 0, end: 1, length: L, in: ctx)

        let stubDrain = 0.575 * u * side(drainY)
        let drain = CGMutablePath()
        drain.move(to: CGPoint(x: channelX, y: stubDrain))
        drain.addLine(to: CGPoint(x: L, y: stubDrain))
        drain.addLine(to: CGPoint(x: L, y: drainY))
        stroke(drain, width: style.lineWidth, from: drainColor, to: drainColor, start: 0, end: 1, length: L, in: ctx)

        let stubSource = 0.575 * u * side(sourceY)
        let source = CGMutablePath()
        source.move(to: CGPoint(x: channelX, y: stubSource))
        source.addLine(to: CGPoint(x: L, y: stubSource))
        source.addLine(to: CGPoint(x: L, y: sourceY))
        source.move(to: CGPoint(x: channelX, y: 0))
        source.addLine(to: CGPoint(x: L, y: 0))
        source.addLine(to: CGPoint(x: L, y: stubSource))
        // arrow on the body connection: into the channel for NMOS, out of it for PMOS
        let tip = isN ? channelX + 0.04 * u : L - 0.04 * u
        let back: CGFloat = isN ? 0.2 * u : -0.2 * u
        source.move(to: CGPoint(x: tip + back, y: -0.13 * u))
        source.addLine(to: CGPoint(x: tip, y: 0))
        source.addLine(to: CGPoint(x: tip + back, y: 0.13 * u))
        stroke(source, width: style.lineWidth, from: sourceColor, to: sourceColor, start: 0, end: 1, length: L, in: ctx)

        ctx.restoreGState()
    }

    /// Bipolar transistor: base at `a`, collector and emitter two grid units either side of `b`
    private static func drawBipolar(_ element: Element, at a: CGPoint, _ b: CGPoint, unit u: CGFloat, style: SymbolStyle,
                                    in ctx: CGContext) {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0.5 else { return }
        let isN = element.kind == .npn
        let colors = style.terminalColors.count == 3 ? style.terminalColors : [style.fill, style.fill, style.fill]
        let (baseColor, collectorColor, emitterColor) = (colors[0], colors[1], colors[2])
        let L = length
        let barX = L - 0.55 * u
        // collector above the bar for NPN, below for PNP (in the element's frame)
        let collectorY: CGFloat = (isN ? -2 : 2) * u
        let emitterY = -collectorY
        let side: (CGFloat) -> CGFloat = { $0 >= 0 ? 1 : -1 }

        ctx.saveGState()
        enterFrame(of: element, at: a, b, in: ctx)

        let base = CGMutablePath()
        base.move(to: .zero)
        base.addLine(to: CGPoint(x: barX, y: 0))
        stroke(base, width: style.lineWidth, from: baseColor, to: baseColor, start: 0, end: 1, length: L, in: ctx)
        let bar = CGMutablePath()
        bar.move(to: CGPoint(x: barX, y: -0.75 * u))
        bar.addLine(to: CGPoint(x: barX, y: 0.75 * u))
        stroke(bar, width: style.lineWidth * 1.8, from: baseColor, to: baseColor, start: 0, end: 1, length: L, in: ctx)

        let collector = CGMutablePath()
        collector.move(to: CGPoint(x: barX, y: 0.35 * u * side(collectorY)))
        collector.addLine(to: CGPoint(x: L, y: 0.95 * u * side(collectorY)))
        collector.addLine(to: CGPoint(x: L, y: collectorY))
        stroke(collector, width: style.lineWidth, from: collectorColor, to: collectorColor, start: 0, end: 1, length: L, in: ctx)

        let start = CGPoint(x: barX, y: 0.35 * u * side(emitterY))
        let end = CGPoint(x: L, y: 0.95 * u * side(emitterY))
        let emitter = CGMutablePath()
        emitter.move(to: start)
        emitter.addLine(to: end)
        emitter.addLine(to: CGPoint(x: L, y: emitterY))
        // the arrow shows conventional current: out along the emitter for NPN, in for PNP
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length2 = max(hypot(dx, dy), 0.001)
        let direction = CGPoint(x: dx / length2 * (isN ? 1 : -1), y: dy / length2 * (isN ? 1 : -1))
        let tip = CGPoint(x: start.x + dx * (isN ? 0.8 : 0.35), y: start.y + dy * (isN ? 0.8 : 0.35))
        let back = CGPoint(x: tip.x - direction.x * 0.3 * u, y: tip.y - direction.y * 0.3 * u)
        let normal = CGPoint(x: -direction.y * 0.16 * u, y: direction.x * 0.16 * u)
        emitter.move(to: CGPoint(x: back.x + normal.x, y: back.y + normal.y))
        emitter.addLine(to: tip)
        emitter.addLine(to: CGPoint(x: back.x - normal.x, y: back.y - normal.y))
        stroke(emitter, width: style.lineWidth, from: emitterColor, to: emitterColor, start: 0, end: 1, length: L, in: ctx)
        ctx.restoreGState()
    }

    /// Op-amp or OTA: inputs one grid unit either side of `a` (− then +), output at `b`; an OTA's bias input enters
    /// the triangle from below its middle, and a circle on its output marks it as a current source
    private static func drawOpAmp(_ element: Element, posts: [CGPoint], at a: CGPoint, _ b: CGPoint, unit u: CGFloat,
                                  style: SymbolStyle, in ctx: CGContext) {
        let L = hypot(b.x - a.x, b.y - a.y)
        guard L > 0.5 else { return }
        let isOTA = element.kind == .ota
        let colors = style.terminalColors.count >= 3 ? style.terminalColors : [style.fill, style.fill, style.fill, style.fill]
        let left = min(0.6 * u, L * 0.2)
        let tipX = max(left + u, L - 0.6 * u)

        ctx.saveGState()
        enterFrame(of: element, at: a, b, in: ctx)

        let triangle = CGMutablePath()
        triangle.move(to: CGPoint(x: left, y: -1.7 * u))
        triangle.addLine(to: CGPoint(x: left, y: 1.7 * u))
        triangle.addLine(to: CGPoint(x: tipX, y: 0))
        triangle.closeSubpath()
        ctx.addPath(triangle)
        ctx.setFillColor(style.fill.withAlpha(style.fill.a * 0.08).cgColor)
        ctx.fillPath()

        let marks = CGMutablePath()
        marks.addPath(triangle)
        // − above, + below
        marks.move(to: CGPoint(x: left + 0.25 * u, y: -u))
        marks.addLine(to: CGPoint(x: left + 0.6 * u, y: -u))
        addPlus(to: marks, at: CGPoint(x: left + 0.42 * u, y: u), size: 0.17 * u)
        stroke(marks, width: style.lineWidth, from: style.fill, to: style.fill, start: 0, end: 1, length: L, in: ctx)

        for (y, color) in [(-u, colors[0]), (u, colors[1])] {
            let lead = CGMutablePath()
            lead.move(to: CGPoint(x: 0, y: y))
            lead.addLine(to: CGPoint(x: left, y: y))
            stroke(lead, width: style.lineWidth, from: color, to: color, start: 0, end: 1, length: L, in: ctx)
        }
        let output = CGMutablePath()
        output.move(to: CGPoint(x: tipX, y: 0))
        output.addLine(to: CGPoint(x: L, y: 0))
        if isOTA {
            let r = 0.28 * u
            let centre = min(tipX + r + 0.05 * u, L - r)
            output.move(to: CGPoint(x: centre + r, y: 0))
            output.addEllipse(in: CGRect(x: centre - r, y: -r, width: 2 * r, height: 2 * r))
            output.addEllipse(in: CGRect(x: centre - r * 0.45, y: -r, width: 2 * r, height: 2 * r))
        }
        stroke(output, width: style.lineWidth, from: colors[2], to: colors[2], start: 0, end: 1, length: L, in: ctx)
        if isOTA {
            // bias input: from below the triangle's middle up to its edge, with an arrow into it
            let x = L / 2
            let edge = 1.7 * u * max(0, (tipX - x) / max(tipX - left, 0.001))
            let bias = CGMutablePath()
            bias.move(to: CGPoint(x: x, y: 2 * u))
            bias.addLine(to: CGPoint(x: x, y: edge))
            bias.move(to: CGPoint(x: x - 0.17 * u, y: edge + 0.32 * u))
            bias.addLine(to: CGPoint(x: x, y: edge))
            bias.addLine(to: CGPoint(x: x + 0.17 * u, y: edge + 0.32 * u))
            let color = colors.count > 3 ? colors[3] : style.fill
            stroke(bias, width: style.lineWidth, from: color, to: color, start: 0, end: 1, length: L, in: ctx)
        }
        ctx.restoreGState()
    }

    /// N-channel JFET: gate at `a` with an arrow into the channel; drain and source two grid units either side of `b`
    private static func drawJFET(_ element: Element, at a: CGPoint, _ b: CGPoint, unit u: CGFloat, style: SymbolStyle,
                                 in ctx: CGContext) {
        let L = hypot(b.x - a.x, b.y - a.y)
        guard L > 0.5 else { return }
        let colors = style.terminalColors.count == 3 ? style.terminalColors : [style.fill, style.fill, style.fill]
        let (gateColor, drainColor, sourceColor) = (colors[0], colors[1], colors[2])
        let barX = L - 0.55 * u
        ctx.saveGState()
        enterFrame(of: element, at: a, b, in: ctx)
        let gate = CGMutablePath()
        gate.move(to: .zero)
        gate.addLine(to: CGPoint(x: barX, y: 0))
        gate.move(to: CGPoint(x: barX - 0.38 * u, y: -0.17 * u))
        gate.addLine(to: CGPoint(x: barX - 0.05 * u, y: 0))
        gate.addLine(to: CGPoint(x: barX - 0.38 * u, y: 0.17 * u))
        stroke(gate, width: style.lineWidth, from: gateColor, to: gateColor, start: 0, end: 1, length: L, in: ctx)
        let bar = CGMutablePath()
        bar.move(to: CGPoint(x: barX, y: -0.85 * u))
        bar.addLine(to: CGPoint(x: barX, y: 0.85 * u))
        stroke(bar, width: style.lineWidth * 1.8, from: drainColor.mixed(with: sourceColor, 0.5),
               to: drainColor.mixed(with: sourceColor, 0.5), start: 0, end: 1, length: L, in: ctx)
        for (y, color) in [(-1.0, drainColor), (1.0, sourceColor)] as [(CGFloat, RGBA)] {
            let lead = CGMutablePath()
            lead.move(to: CGPoint(x: barX, y: 0.6 * u * y))
            lead.addLine(to: CGPoint(x: L, y: 0.6 * u * y))
            lead.addLine(to: CGPoint(x: L, y: 2 * u * y))
            stroke(lead, width: style.lineWidth, from: color, to: color, start: 0, end: 1, length: L, in: ctx)
        }
        ctx.restoreGState()
    }

    /// The analog switch's control input: a dashed line from its terminal to the lever
    private static func drawControl(from control: CGPoint, at a: CGPoint, _ b: CGPoint, unit u: CGFloat, style: SymbolStyle,
                                    in ctx: CGContext) {
        let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = middle.x - control.x
        let dy = middle.y - control.y
        let distance = hypot(dx, dy)
        guard distance > u else { return }
        let end = CGPoint(x: middle.x - dx / distance * 0.5 * u, y: middle.y - dy / distance * 0.5 * u)
        let color = style.terminalColors.count == 3 ? style.terminalColors[2] : style.fill
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(style.lineWidth)
        ctx.setLineCap(.round)
        ctx.move(to: control)
        ctx.addLine(to: CGPoint(x: control.x + dx / distance * 0.6 * u, y: control.y + dy / distance * 0.6 * u))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [0.22 * u, 0.18 * u])
        ctx.move(to: CGPoint(x: control.x + dx / distance * 0.6 * u, y: control.y + dy / distance * 0.6 * u))
        ctx.addLine(to: end)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Box of a 555 in screen space: corners, unit vector along the chip, unit vector towards the DIS–CTRL side
    static func timerBox(posts: [CGPoint], at a: CGPoint, _ b: CGPoint, unit u: CGFloat) -> (corners: [CGPoint], along: CGPoint, side: CGPoint)? {
        guard posts.count == 8 else { return nil }
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0.5 else { return nil }
        let along = CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
        // DIS is pin 7: one unit along the chip and three to its side
        let dis = posts[6]
        let side = CGPoint(x: (dis.x - a.x - along.x * u) / (3 * u), y: (dis.y - a.y - along.y * u) / (3 * u))
        func point(_ t: CGFloat, _ s: CGFloat) -> CGPoint {
            CGPoint(x: a.x + along.x * t * u + side.x * s * u, y: a.y + along.y * t * u + side.y * s * u)
        }
        return ([point(0.3, 2), point(4.7, 2), point(4.7, -2), point(0.3, -2)], along, side)
    }

    /// 555 timer: a box with its eight pins, labelled
    private static func drawTimer(posts: [CGPoint], at a: CGPoint, _ b: CGPoint, unit u: CGFloat, style: SymbolStyle,
                                  in ctx: CGContext) {
        guard let box = timerBox(posts: posts, at: a, b, unit: u) else { return }
        let colors = style.terminalColors.count == 8 ? style.terminalColors : Array(repeating: style.fill, count: 8)
        let outline = CGMutablePath()
        outline.addLines(between: box.corners)
        outline.closeSubpath()
        ctx.saveGState()
        ctx.addPath(outline)
        ctx.setFillColor(style.fill.withAlpha(style.fill.a * 0.08).cgColor)
        ctx.fillPath()
        ctx.addPath(outline)
        ctx.setStrokeColor(style.fill.cgColor)
        ctx.setLineWidth(style.lineWidth)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.setLineCap(.round)
        // pin leads: DIS, THR, TRIG, CTRL (pins 7, 6, 2, 5) on the `side` side, the rest opposite
        let names = ["GND", "TRIG", "OUT", "RST", "CTRL", "THR", "DIS", "VCC"]
        let leftSide: Set<Int> = [1, 4, 5, 6]
        for (k, pin) in posts.enumerated() {
            let direction: CGFloat = leftSide.contains(k) ? -1 : 1
            let inner = CGPoint(x: pin.x + box.side.x * direction * u, y: pin.y + box.side.y * direction * u)
            ctx.setStrokeColor(colors[k].cgColor)
            ctx.move(to: pin)
            ctx.addLine(to: inner)
            ctx.strokePath()
            guard u >= 9 else { continue }
            // the name just inside the box, upright
            let label = CGPoint(x: inner.x + box.side.x * direction * 0.25 * u, y: inner.y + box.side.y * direction * 0.25 * u)
            let outward = CGPoint(x: -box.side.x * direction, y: -box.side.y * direction)
            let anchor: CGFloat = outward.x > 0.5 ? 1 : (outward.x < -0.5 ? 0 : 0.5)
            let offsetY: CGFloat = abs(outward.x) > 0.5 ? 0 : (outward.y > 0 ? -0.35 * u : 0.35 * u)
            drawText(names[k], at: CGPoint(x: label.x, y: label.y + offsetY), size: 0.5 * u, color: style.fill.withAlpha(0.75),
                     anchor: anchor, in: ctx)
        }
        if u >= 9 {
            let centre = CGPoint(x: (box.corners[0].x + box.corners[2].x) / 2, y: (box.corners[0].y + box.corners[2].y) / 2)
            drawText("555", at: centre, size: 0.75 * u, color: style.fill, anchor: 0.5, bold: true, in: ctx)
        }
        ctx.restoreGState()
    }

    /// Draws upright text centred vertically on `point`; `anchor` 0 puts the text's start at the point, 1 its end
    static func drawText(_ text: String, at point: CGPoint, size: CGFloat, color: RGBA, anchor: CGFloat, bold: Bool = false,
                         in ctx: CGContext) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        ctx.saveGState()
        // the canvas has y pointing down: flip the glyphs back upright
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: point.x - width * anchor, y: point.y + (ascent - descent) / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// The potentiometer's wiper: an arrow from its terminal to the resistor
    private static func drawWiper(from wiper: CGPoint, toward middle: CGPoint, unit u: CGFloat, style: SymbolStyle, in ctx: CGContext) {
        let dx = middle.x - wiper.x
        let dy = middle.y - wiper.y
        let distance = hypot(dx, dy)
        guard distance > 0.6 * u else { return }
        let direction = CGPoint(x: dx / distance, y: dy / distance)
        let tip = CGPoint(x: middle.x - direction.x * 0.42 * u, y: middle.y - direction.y * 0.42 * u)
        let back = CGPoint(x: tip.x - direction.x * 0.35 * u, y: tip.y - direction.y * 0.35 * u)
        let normal = CGPoint(x: -direction.y * 0.2 * u, y: direction.x * 0.2 * u)
        let path = CGMutablePath()
        path.move(to: wiper)
        path.addLine(to: tip)
        path.move(to: CGPoint(x: back.x + normal.x, y: back.y + normal.y))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: back.x - normal.x, y: back.y - normal.y))
        let color = style.terminalColors.count == 3 ? style.terminalColors[2] : style.fill
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(style.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Hit testing and dots

    /// Segments that represent the element for hit testing, in screen coordinates
    static func segments(_ element: Element, a: CGPoint, b: CGPoint, posts: [CGPoint], unit u: CGFloat) -> [(CGPoint, CGPoint)] {
        switch element.kind {
        case .ground:
            let length = max(hypot(b.x - a.x, b.y - a.y), 1)
            let end = CGPoint(x: a.x + (b.x - a.x) / length * u, y: a.y + (b.y - a.y) / length * u)
            return [(a, end)]
        case .nmos, .pmos, .npn, .pnp, .njfet:
            return posts.count == 3 ? [(a, b), (posts[1], posts[2])] : [(a, b)]
        case .opAmp:
            return posts.count == 3 ? [(posts[0], posts[1]), (a, b)] : [(a, b)]
        case .ota:
            let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            return posts.count == 4 ? [(posts[0], posts[1]), (a, b), (middle, posts[3])] : [(a, b)]
        case .timer555:
            guard let box = timerBox(posts: posts, at: a, b, unit: u) else { return [(a, b)] }
            let c = box.corners
            var result = [(c[0], c[1]), (c[1], c[2]), (c[2], c[3]), (c[3], c[0])]
            // lines across the box, so a click anywhere inside it selects the chip
            for k in 1...4 {
                let t = CGFloat(k) / 5
                result.append((CGPoint(x: c[0].x + (c[1].x - c[0].x) * t, y: c[0].y + (c[1].y - c[0].y) * t),
                               CGPoint(x: c[3].x + (c[2].x - c[3].x) * t, y: c[3].y + (c[2].y - c[3].y) * t)))
            }
            return result
        case .potentiometer, .analogSwitch:
            let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            return posts.count == 3 ? [(a, b), (middle, posts[2])] : [(a, b)]
        default:
            return [(a, b)]
        }
    }

    /// The path current dots travel, from the side the current is measured from, and the part of it hidden by the body
    static func dotPath(_ element: Element, a: CGPoint, b: CGPoint, posts: [CGPoint], unit u: CGFloat)
        -> (from: CGPoint, to: CGPoint, hidden: ClosedRange<CGFloat>?)? {
        switch element.kind {
        case .ground, .netLabel, .probe:
            return nil
        case .toggleSwitch, .pushButton:
            return element.closed ? (a, b, nil) : nil
        case .nmos, .pmos, .npn, .pnp, .njfet:
            return posts.count == 3 ? (posts[1], posts[2], nil) : nil
        case .timer555:
            // the output lead
            guard let box = timerBox(posts: posts, at: a, b, unit: u) else { return nil }
            let pin = posts[2]
            return (CGPoint(x: pin.x + box.side.x * u, y: pin.y + box.side.y * u), pin, nil)
        case .schmittInverter:
            // current flows from the output only
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0 else { return nil }
            let start = min(length, (length + bodyLength(.schmittInverter) * u) / 2)
            return (CGPoint(x: a.x + (b.x - a.x) * start / length, y: a.y + (b.y - a.y) * start / length), b, nil)
        case .opAmp, .ota:
            // the output lead, from the triangle's tip
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0 else { return nil }
            let tip = max(min(0.6 * u, length * 0.2) + u, length - 0.6 * u)
            let start = CGPoint(x: a.x + (b.x - a.x) * tip / length, y: a.y + (b.y - a.y) * tip / length)
            return (start, b, nil)
        case .wire:
            return (a, b, nil)
        default:
            let length = hypot(b.x - a.x, b.y - a.y)
            let half = min(length, bodyLength(element.kind) * u) / 2 + 0.15 * u
            return (a, b, (length / 2 - half)...(length / 2 + half))
        }
    }
}
