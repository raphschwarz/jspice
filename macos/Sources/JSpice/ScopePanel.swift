import SwiftUI
import CircuitKit

/// Scope traces under the canvas: one row per scoped quantity, newest values on the right.
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
                Picker("Quantity", selection: Binding(get: { spec.quantity }, set: { editor.setScopeQuantity(spec.id, $0) })) {
                    ForEach(scopeQuantities(for: element.kind)) { quantity in
                        Text(quantity.name).tag(quantity)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    Text(SI.format(editor.simulation.simulator.trace(spec.id)?.lastValue ?? 0, unit: spec.quantity.unit))
                        .font(.title3.monospacedDigit().weight(.medium))
                        .foregroundStyle(color)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 160, alignment: .leading)
            .padding(10)
            Divider()
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                Canvas { context, size in draw(context, size) }
            }
        }
        .frame(height: 118)
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
