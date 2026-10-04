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
        case .wire, .ground, .nmos, .pmos: return 0
        case .resistor, .inductor: return 2
        case .memristor: return 2.2
        case .lamp, .probe: return 1.4
        case .capacitor, .dcVoltage: return 0.5
        case .acVoltage, .squareVoltage, .currentSource: return 1.6
        case .toggleSwitch, .pushButton: return 1.6
        case .diode, .led: return 1
        }
    }

    static func draw(_ element: Element, posts: [CGPoint], at a: CGPoint, _ b: CGPoint, unit u: CGFloat, style: SymbolStyle,
                     in ctx: CGContext) {
        switch element.kind {
        case .ground:
            drawGround(at: a, toward: b, unit: u, style: style, in: ctx)
        case .nmos, .pmos:
            drawTransistor(element, at: a, b, unit: u, style: style, in: ctx)
        default:
            drawTwoTerminal(element, at: a, b, unit: u, style: style, in: ctx)
        }
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
        case .acVoltage, .squareVoltage, .currentSource, .probe:
            ctx.setFillColor(style.fill.withAlpha(style.fill.a * 0.08).cgColor)
            ctx.fillEllipse(in: CGRect(x: c - h, y: -h, width: body, height: body))
        default:
            break
        }

        var thickPlate: CGPath?
        switch kind {
        case .resistor:
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
        case .acVoltage, .squareVoltage:
            // the waveform inside is drawn upright afterwards
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
        case .diode, .led:
            path.move(to: CGPoint(x: c - h, y: -0.5 * u))
            path.addLine(to: CGPoint(x: c - h, y: 0.5 * u))
            path.addLine(to: CGPoint(x: c + h, y: 0))
            path.closeSubpath()
            path.move(to: CGPoint(x: c + h, y: -0.5 * u))
            path.addLine(to: CGPoint(x: c + h, y: 0.5 * u))
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
        case .wire, .ground, .nmos, .pmos:
            break
        }

        let start = length > 0 ? (c - h) / length : 0
        let end = length > 0 ? (c + h) / length : 1
        stroke(path, width: style.lineWidth, from: colorA, to: colorB, start: start, end: end, length: length, in: ctx)
        if let thickPlate {
            stroke(thickPlate, width: style.lineWidth * 2.4, from: colorA, to: colorA, start: 0, end: 1, length: length, in: ctx)
        }

        switch kind {
        case .toggleSwitch, .pushButton:
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
        if kind == .acVoltage || kind == .squareVoltage {
            // the waveform stays upright whatever the source's direction
            let glyph = CGMutablePath()
            if kind == .acVoltage {
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
        if kind == .probe {
            // the letter stays upright whatever the probe's direction
            let v = CGMutablePath()
            v.move(to: CGPoint(x: mid.x - 0.25 * u, y: mid.y - 0.3 * u))
            v.addLine(to: CGPoint(x: mid.x, y: mid.y + 0.3 * u))
            v.addLine(to: CGPoint(x: mid.x + 0.25 * u, y: mid.y - 0.3 * u))
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
        ctx.translateBy(x: a.x, y: a.y)
        ctx.rotate(by: atan2(b.y - a.y, b.x - a.x))

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

    // MARK: - Hit testing and dots

    /// Segments that represent the element for hit testing, in screen coordinates
    static func segments(_ element: Element, a: CGPoint, b: CGPoint, posts: [CGPoint], unit u: CGFloat) -> [(CGPoint, CGPoint)] {
        switch element.kind {
        case .ground:
            let length = max(hypot(b.x - a.x, b.y - a.y), 1)
            let end = CGPoint(x: a.x + (b.x - a.x) / length * u, y: a.y + (b.y - a.y) / length * u)
            return [(a, end)]
        case .nmos, .pmos:
            return posts.count == 3 ? [(a, b), (posts[1], posts[2])] : [(a, b)]
        default:
            return [(a, b)]
        }
    }

    /// The path current dots travel, from the side the current is measured from, and the part of it hidden by the body
    static func dotPath(_ element: Element, a: CGPoint, b: CGPoint, posts: [CGPoint], unit u: CGFloat)
        -> (from: CGPoint, to: CGPoint, hidden: ClosedRange<CGFloat>?)? {
        switch element.kind {
        case .ground, .probe:
            return nil
        case .toggleSwitch, .pushButton:
            return element.closed ? (a, b, nil) : nil
        case .nmos, .pmos:
            return posts.count == 3 ? (posts[1], posts[2], nil) : nil
        case .wire:
            return (a, b, nil)
        default:
            let length = hypot(b.x - a.x, b.y - a.y)
            let half = min(length, bodyLength(element.kind) * u) / 2 + 0.15 * u
            return (a, b, (length / 2 - half)...(length / 2 + half))
        }
    }
}
