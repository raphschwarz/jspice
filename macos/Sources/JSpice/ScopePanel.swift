import SwiftUI
import CircuitKit

/// Scope traces under the canvas: one row per scoped quantity, newest values on the right, or a part's current plotted
/// against its voltage.
struct ScopePanel: View {
    @ObservedObject var editor: EditorState
    let circuit: Circuit

    var body: some View {
        VStack(spacing: 0) {
            ForEach(circuit.scopes) { spec in
                if let element = circuit[spec.elementID] {
                    ScopeRow(editor: editor, spec: spec, element: element)
                    if spec.id != circuit.scopes.last?.id { Divider() }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct ScopeRow: View {
    let editor: EditorState
    let spec: ScopeSpec
    let element: Element
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(element.name.isEmpty ? element.kind.displayName : element.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        editor.removeScope(spec.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this scope")
                }
                Picker("Quantity", selection: Binding(get: { selection }, set: choose)) {
                    ForEach(scopeQuantities(for: element.kind)) { quantity in
                        Text(quantity.name).tag(ScopeChoice.quantity(quantity))
                    }
                    if canPlotCurve(element.kind) {
                        Divider()
                        Text("I–V Curve").tag(ScopeChoice.curve)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    let trace = editor.simulation.simulator.trace(spec.id)
                    if spec.plot == .currentVersusVoltage {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(SI.format(trace?.lastVoltage ?? 0, unit: "V")).foregroundStyle(voltageColor)
                            Text(SI.format(trace?.lastValue ?? 0, unit: "A")).foregroundStyle(color)
                        }
                        .font(.body.monospacedDigit().weight(.medium))
                    } else {
                        Text(SI.format(trace?.lastValue ?? 0, unit: spec.quantity.unit))
                            .font(.title3.monospacedDigit().weight(.medium))
                            .foregroundStyle(color)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: 160, alignment: .leading)
            .padding(10)
            Divider()
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                Canvas { context, size in
                    if spec.plot == .currentVersusVoltage {
                        drawCurve(context, size)
                    } else {
                        draw(context, size)
                    }
                }
            }
        }
        .frame(height: spec.plot == .currentVersusVoltage ? 160 : 118)
    }

    private enum ScopeChoice: Hashable {
        case quantity(Quantity)
        case curve
    }

    private var selection: ScopeChoice {
        spec.plot == .currentVersusVoltage ? .curve : .quantity(spec.quantity)
    }

    private func choose(_ choice: ScopeChoice) {
        switch choice {
        case .curve:
            editor.setScopePlot(spec.id, .currentVersusVoltage)
        case .quantity(let quantity):
            if spec.plot != .time { editor.setScopePlot(spec.id, .time) }
            editor.setScopeQuantity(spec.id, quantity)
        }
    }

    private var voltageColor: Color {
        colorScheme == .dark ? Color(red: 0.224, green: 0.529, blue: 0.898) : Color(red: 0.165, green: 0.471, blue: 0.839)
    }

    /// Symmetric range around zero when the values straddle it, padded so the curve does not touch the frame
    private static func range(_ values: [Double]) -> (low: Double, high: Double) {
        var low = values.min() ?? 0
        var high = values.max() ?? 0
        if low > 0 { low = 0 }
        if high < 0 { high = 0 }
        if high - low < 1e-12 {
            low -= 1e-9
            high += 1e-9
        }
        let pad = (high - low) * 0.08
        return (low - pad, high + pad)
    }

    /// Current against voltage, older points fading out, with a dot at the present operating point
    private func drawCurve(_ context: GraphicsContext, _ size: CGSize) {
        guard let trace = editor.simulation.simulator.trace(spec.id) else { return }
        let voltages = trace.voltages
        let currents = trace.currents
        let labelFont = Font.caption2.monospacedDigit()
        let plot = CGRect(x: 58, y: 10, width: max(10, size.width - 72), height: max(10, size.height - 28))
        let (vLow, vHigh) = Self.range(voltages)
        let (iLow, iHigh) = Self.range(currents)
        let x: (Double) -> CGFloat = { plot.minX + CGFloat(($0 - vLow) / (vHigh - vLow)) * plot.width }
        let y: (Double) -> CGFloat = { plot.maxY - CGFloat(($0 - iLow) / (iHigh - iLow)) * plot.height }

        // frame and axes through zero
        context.stroke(Path(plot), with: .color(Color.secondary.opacity(0.25)), lineWidth: 1)
        var axes = Path()
        axes.move(to: CGPoint(x: plot.minX, y: y(0)))
        axes.addLine(to: CGPoint(x: plot.maxX, y: y(0)))
        axes.move(to: CGPoint(x: x(0), y: plot.minY))
        axes.addLine(to: CGPoint(x: x(0), y: plot.maxY))
        context.stroke(axes, with: .color(Color.secondary.opacity(0.5)), lineWidth: 1)

        let shown = { (low: Double, high: Double) in (low + (high - low) * 0.08 / 1.16, high - (high - low) * 0.08 / 1.16) }
        let (iMin, iMax) = shown(iLow, iHigh)
        let (vMin, vMax) = shown(vLow, vHigh)
        context.draw(Text(SI.format(iMax, unit: "A")).font(labelFont).foregroundStyle(.secondary),
                     at: CGPoint(x: plot.minX - 6, y: y(iMax)), anchor: .trailing)
        context.draw(Text(SI.format(iMin, unit: "A")).font(labelFont).foregroundStyle(.secondary),
                     at: CGPoint(x: plot.minX - 6, y: y(iMin)), anchor: .trailing)
        context.draw(Text(SI.format(vMin, unit: "V")).font(labelFont).foregroundStyle(.secondary),
                     at: CGPoint(x: x(vMin), y: plot.maxY + 3), anchor: .top)
        context.draw(Text(SI.format(vMax, unit: "V")).font(labelFont).foregroundStyle(.secondary),
                     at: CGPoint(x: x(vMax), y: plot.maxY + 3), anchor: .top)

        let count = min(voltages.count, currents.count)
        guard count > 1 else { return }
        // draw in a few segments so the oldest part of the loop fades
        let segments = 6
        for s in 0..<segments {
            let start = max(0, s * (count - 1) / segments)
            let end = (s + 1) * (count - 1) / segments
            guard end > start else { continue }
            var path = Path()
            path.move(to: CGPoint(x: x(voltages[start]), y: y(currents[start])))
            for i in (start + 1)...end { path.addLine(to: CGPoint(x: x(voltages[i]), y: y(currents[i]))) }
            let opacity = 0.25 + 0.75 * Double(s + 1) / Double(segments)
            context.stroke(path, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        let point = CGPoint(x: x(trace.lastVoltage), y: y(trace.lastValue))
        context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(color))
    }

    /// Validated categorical colours, stepped separately for light and dark backgrounds
    private var color: Color {
        let dark = colorScheme == .dark
        switch spec.quantity {
        case .voltage: return dark ? Color(red: 0.224, green: 0.529, blue: 0.898) : Color(red: 0.165, green: 0.471, blue: 0.839)
        case .current: return dark ? Color(red: 0.851, green: 0.349, blue: 0.149) : Color(red: 0.922, green: 0.408, blue: 0.204)
        case .power: return dark ? Color(red: 0.098, green: 0.620, blue: 0.439) : Color(red: 0.106, green: 0.686, blue: 0.478)
        case .resistance: return dark ? Color(red: 0.565, green: 0.522, blue: 0.914) : Color(red: 0.290, green: 0.227, blue: 0.655)
        }
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        guard let trace = editor.simulation.simulator.trace(spec.id) else { return }
        let minimums = trace.minimums
        let maximums = trace.maximums
        let labelFont = Font.caption2.monospacedDigit()
        let plot = CGRect(x: 58, y: 10, width: max(10, size.width - 72), height: max(10, size.height - 26))

        var low = minimums.min() ?? 0
        var high = maximums.max() ?? 0
        // include zero when the signal is near it, so a 0 to 5 V signal reads as such
        if low > 0 && low < high * 0.25 { low = 0 }
        if high < 0 && high > low * 0.25 { high = 0 }
        if high - low < max(abs(high), abs(low), 1e-12) * 1e-6 {
            let pad = max(abs(high) * 0.1, 1e-9)
            low -= pad
            high += pad
        }
        let pad = (high - low) * 0.08
        low -= pad
        high += pad
        let y: (Double) -> CGFloat = { plot.maxY - CGFloat(($0 - low) / (high - low)) * plot.height }

        // frame, zero line and labels
        let grid = Color.secondary.opacity(0.25)
        context.stroke(Path(plot), with: .color(grid), lineWidth: 1)
        if low < 0 && high > 0 {
            var zero = Path()
            zero.move(to: CGPoint(x: plot.minX, y: y(0)))
            zero.addLine(to: CGPoint(x: plot.maxX, y: y(0)))
            context.stroke(zero, with: .color(Color.secondary.opacity(0.5)), lineWidth: 1)
        }
        let unit = spec.quantity.unit
        context.draw(Text(SI.format(high - pad, unit: unit)).font(labelFont).foregroundStyle(.secondary),
                     at: CGPoint(x: plot.minX - 6, y: y(high - pad)), anchor: .trailing)
        context.draw(Text(SI.format(low + pad, unit: unit)).font(labelFont).foregroundStyle(.secondary),
                     at: CGPoint(x: plot.minX - 6, y: y(low + pad)), anchor: .trailing)
        context.draw(Text("last \(SI.format(trace.window, unit: "s"))").font(labelFont).foregroundStyle(.secondary),
                     at: CGPoint(x: plot.maxX, y: plot.maxY + 3), anchor: .topTrailing)

        let count = minimums.count
        guard count > 1 else { return }
        let capacity = CGFloat(ScopeTrace.capacity - 1)
        let x: (Int) -> CGFloat = { plot.maxX - CGFloat(count - 1 - $0) / capacity * plot.width }

        // envelope of fast changes, then the trace itself
        var envelope = Path()
        envelope.move(to: CGPoint(x: x(0), y: y(maximums[0])))
        for i in 1..<count { envelope.addLine(to: CGPoint(x: x(i), y: y(maximums[i]))) }
        for i in stride(from: count - 1, through: 0, by: -1) { envelope.addLine(to: CGPoint(x: x(i), y: y(minimums[i]))) }
        envelope.closeSubpath()
        context.fill(envelope, with: .color(color.opacity(0.25)))

        var line = Path()
        line.move(to: CGPoint(x: x(0), y: y((minimums[0] + maximums[0]) / 2)))
        for i in 1..<count { line.addLine(to: CGPoint(x: x(i), y: y((minimums[i] + maximums[i]) / 2))) }
        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }
}
