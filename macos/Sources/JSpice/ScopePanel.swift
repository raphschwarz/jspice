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
                    ScopeRow(editor: editor, spec: spec, element: element,
                             sources: circuit.elements.filter { $0.kind.isVoltageSource || $0.kind == .currentSource })
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
    /// The sources a frequency response can be driven from
    let sources: [Element]
    @State private var response = ResponseCache()
    @Environment(\.colorScheme) private var colorScheme

    /// The source a frequency response is driven from: the one chosen, or the circuit's first signal source
    private var source: Element? {
        if let id = spec.sourceID, let chosen = sources.first(where: { $0.id == id }) { return chosen }
        let preference: [ElementKind] = [.acVoltage, .squareVoltage, .keyboardPitch, .noiseVoltage, .currentSource, .keyboardGate, .dcVoltage]
        for kind in preference {
            if let found = sources.first(where: { $0.kind == kind }) { return found }
        }
        return nil
    }

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
                    if canPlotResponse(element.kind) {
                        Divider()
                        Text("Frequency Response").tag(ScopeChoice.response)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                if spec.plot == .frequencyResponse {
                    Picker("From", selection: Binding(get: { source?.id }, set: { editor.setScopeSource(spec.id, $0) })) {
                        ForEach(sources) { source in
                            Text(source.name.isEmpty ? source.kind.displayName : source.name).tag(Optional(source.id))
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .help("The source the response is measured from")
                }
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    let trace = editor.simulation.simulator.trace(spec.id)
                    if spec.plot == .frequencyResponse {
                        let result = response.update(editor.simulation.simulator, elementID: element.id, sourceID: source?.id)
                        if let note = result.note {
                            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        } else if let peak = result.peak {
                            // a resonance's peak, or else the passband's gain and its −3 dB corner
                            VStack(alignment: .leading, spacing: 0) {
                                Text(String(format: "%+.1f dB", result.gains[peak] + 0)).foregroundStyle(voltageColor)
                                    .font(.title3.monospacedDigit().weight(.medium))
                                if result.hasResonance {
                                    Text("peak at \(SI.format(ResponseCache.frequencies[peak], unit: "Hz"))")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if let corner = result.corner {
                                    Text("−3 dB at \(SI.format(corner, unit: "Hz"))")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("flat from 10 Hz to 100 kHz").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else if spec.plot == .currentVersusVoltage {
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
            if spec.plot == .frequencyResponse {
                ResponsePlot(editor: editor, cache: response, elementID: element.id, sourceID: source?.id,
                             gainColor: voltageColor, phaseColor: phaseColor)
            } else {
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
        }
        .frame(height: spec.plot == .time ? 118 : 160)
    }

    private enum ScopeChoice: Hashable {
        case quantity(Quantity)
        case curve
        case response
    }

    private var selection: ScopeChoice {
        switch spec.plot {
        case .currentVersusVoltage: return .curve
        case .frequencyResponse: return .response
        case .time: return .quantity(spec.quantity)
        }
    }

    private func choose(_ choice: ScopeChoice) {
        switch choice {
        case .curve:
            editor.setScopePlot(spec.id, .currentVersusVoltage)
        case .response:
            editor.setScopePlot(spec.id, .frequencyResponse)
        case .quantity(let quantity):
            if spec.plot != .time { editor.setScopePlot(spec.id, .time) }
            editor.setScopeQuantity(spec.id, quantity)
        }
    }

    private var voltageColor: Color {
        colorScheme == .dark ? Color(red: 0.224, green: 0.529, blue: 0.898) : Color(red: 0.165, green: 0.471, blue: 0.839)
    }

    private var phaseColor: Color {
        colorScheme == .dark ? Color(red: 0.851, green: 0.349, blue: 0.149) : Color(red: 0.922, green: 0.408, blue: 0.204)
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
        // where the signal swings widely within a column (an audio-rate signal in a long window), the band is the
        // signal, so it is drawn stronger and no line runs through its middle, which would mean nothing
        let wide: (Int) -> Bool = { maximums[$0] - minimums[$0] > (high - low) * 0.08 }
        let fast = (0..<count).filter(wide).count * 2 > count
        context.fill(envelope, with: .color(color.opacity(fast ? 0.55 : 0.25)))

        var line = Path()
        var drawing = false
        for i in 0..<count {
            guard !wide(i) else {
                drawing = false
                continue
            }
            let point = CGPoint(x: x(i), y: y((minimums[i] + maximums[i]) / 2))
            if drawing { line.addLine(to: point) } else { line.move(to: point) }
            drawing = true
        }
        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }
}

/// A frequency response around the circuit's operating point. A copy of the circuit, with the driving source held
/// still, settles in the background, a little at each update and only as long as it takes, and follows every change to
/// the circuit (a knob turned, a part added). The response is worked out from it at most five times a second, and
/// again only when the linearised circuit or the probe has changed.
final class ResponseCache {
    /// 10 Hz to 100 kHz, 30 points a decade
    static let frequencies = FrequencySweep.logarithmic(from: 10, to: 100_000, pointsPerDecade: 30)

    struct Response {
        /// Gain in dB and phase in degrees at each of `frequencies`
        var gains: [Double] = []
        var phases: [Double] = []
        /// Why there is nothing to show
        var note: String?

        var peak: Int? { gains.indices.max { gains[$0] < gains[$1] } }

        /// Where the gain first crosses 3 dB below the peak, interpolated on the log-frequency scale
        var corner: Double? {
            guard let peak else { return nil }
            let level = gains[peak] - 3
            for k in 1..<max(1, gains.count) where (gains[k - 1] < level) != (gains[k] < level) {
                let f = (gains[k - 1] - level) / (gains[k - 1] - gains[k])
                return ResponseCache.frequencies[k - 1] * pow(ResponseCache.frequencies[k] / ResponseCache.frequencies[k - 1], f)
            }
            return nil
        }

        /// Whether the peak stands out from both ends, as a resonance does, rather than being a flat passband
        var hasResonance: Bool {
            guard let peak, let first = gains.first, let last = gains.last else { return false }
            return gains[peak] > max(first, last) + 0.5
        }
    }

    private struct Key: Equatable {
        var input: Int
        var plus: Int
        var minus: Int
    }

    /// The quiet copy, the circuit it was given, and how much longer it needs to settle (in circuit time)
    private var shadow: Simulator?
    private var shadowCircuit: Circuit?
    private var unsettled = 0.0
    private var model: SmallSignalModel?
    private var key: Key?
    private var checked = Date.distantPast
    private(set) var response = Response(note: "Working it out…")

    func update(_ simulator: Simulator, elementID: UUID, sourceID: UUID?) -> Response {
        guard Date().timeIntervalSince(checked) >= 0.18 else { return response }
        checked = Date()
        let circuit = simulator.circuit
        guard let sourceID, let input = circuit.elements.firstIndex(where: { $0.id == sourceID }) else {
            return set(Response(note: "Add a source to drive the circuit from"))
        }
        guard let index = circuit.elements.firstIndex(where: { $0.id == elementID }) else { return response }
        var quiet = Simulator.quiet(circuit, holding: input)
        quiet.scopes = []
        if quiet != shadowCircuit {
            let settling = Simulator.settling(quiet)
            if let shadow {
                // keeps the state of the parts that remain, so a turned knob settles from where it was
                shadow.load(quiet)
                shadow.setTimeStep(settling.timeStep)
            } else {
                shadow = Simulator(circuit: quiet, timeStep: settling.timeStep)
            }
            shadowCircuit = quiet
            unsettled = max(settling.duration, 10 * settling.timeStep)
        }
        guard let shadow else { return response }
        if unsettled > 0 {
            // a slice of the settling at a time, so the window stays responsive: the curve moves to where it settles
            let progress = shadow.advance(by: unsettled, deadline: ProcessInfo.processInfo.systemUptime + 0.01)
            unsettled -= progress.simulatedTime
        }
        guard let (plus, minus) = shadow.acrossNodes(index) else { return set(Response(note: "This part has no voltage to plot")) }
        guard let model = shadow.smallSignalModel() else { return set(Response(note: "Nothing to show while the circuit can't be solved")) }
        let key = Key(input: input, plus: plus, minus: minus)
        if model == self.model && key == self.key { return response }
        self.model = model
        self.key = key
        guard let values = model.response(input: input, plus: plus, minus: minus, frequencies: Self.frequencies) else {
            return set(Response(note: "The circuit can't be linearised here"))
        }
        return set(Response(gains: values.map { 20 * log10(max($0.magnitude, 1e-12)) }, phases: FrequencySweep.unwrappedPhases(values)))
    }

    private func set(_ new: Response) -> Response {
        if new.note != nil {
            model = nil
            key = nil
        }
        response = new
        return new
    }
}

/// A Bode plot: gain (solid, dB on the left) and phase (dashed, degrees on the right) against frequency on a log
/// scale, with a readout under the pointer
private struct ResponsePlot: View {
    let editor: EditorState
    let cache: ResponseCache
    let elementID: UUID
    let sourceID: UUID?
    let gainColor: Color
    let phaseColor: Color
    @State private var pointer: CGPoint?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let response = cache.update(editor.simulation.simulator, elementID: elementID, sourceID: sourceID)
            Canvas { context, size in draw(context, size, response) }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): pointer = location
            case .ended: pointer = nil
            }
        }
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize, _ response: ResponseCache.Response) {
        let frequencies = ResponseCache.frequencies
        let gains = response.gains
        let phases = response.phases
        let labelFont = Font.caption2.monospacedDigit()
        let plot = CGRect(x: 58, y: 10, width: max(10, size.width - 108), height: max(10, size.height - 28))
        let low = log10(frequencies.first ?? 10), high = log10(frequencies.last ?? 100_000)
        let x: (Double) -> CGFloat = { plot.minX + CGFloat((log10($0) - low) / (high - low)) * plot.width }
        let grid = Color.secondary.opacity(0.25)
        context.stroke(Path(plot), with: .color(grid), lineWidth: 1)

        // decades
        var decade = pow(10, low.rounded(.up))
        while decade <= pow(10, high) * 1.0001 {
            var line = Path()
            line.move(to: CGPoint(x: x(decade), y: plot.minY))
            line.addLine(to: CGPoint(x: x(decade), y: plot.maxY))
            context.stroke(line, with: .color(grid), lineWidth: 1)
            context.draw(Text(SI.format(decade, unit: "Hz")).font(labelFont).foregroundStyle(.secondary),
                         at: CGPoint(x: x(decade), y: plot.maxY + 3), anchor: .top)
            decade *= 10
        }
        guard gains.count == frequencies.count, gains.count > 1, let peak = gains.max(), let floor = gains.min() else { return }

        // gain: a span of 20 to 80 dB, in steps of 10 or 20
        let top = ((peak + 2) / 10).rounded(.up) * 10
        let bottom = min(top - 20, max(((floor - 2) / 10).rounded(.down) * 10, top - 80))
        // (not clamped: the curve runs off the plot where it falls below it, rather than along its floor)
        let y: (Double) -> CGFloat = { plot.maxY - CGFloat((max($0, bottom - 1000) - bottom) / (top - bottom)) * plot.height }
        let step = top - bottom > 40 ? 20.0 : 10.0
        var level = top
        while level >= bottom - 0.001 {
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y(level)))
            line.addLine(to: CGPoint(x: plot.maxX, y: y(level)))
            context.stroke(line, with: .color(level == 0 ? Color.secondary.opacity(0.5) : grid), lineWidth: 1)
            context.draw(Text(String(format: "%+.0f dB", level + 0)).font(labelFont).foregroundStyle(gainColor),
                         at: CGPoint(x: plot.minX - 6, y: y(level)), anchor: .trailing)
            level -= step
        }

        // phase: whole quarter turns either side, at least half a turn
        var phaseLow = ((phases.min() ?? 0) / 90).rounded(.down) * 90
        var phaseHigh = ((phases.max() ?? 0) / 90).rounded(.up) * 90
        if phaseHigh - phaseLow < 180 {
            let middle = ((phaseHigh + phaseLow) / 2 / 90).rounded() * 90
            (phaseLow, phaseHigh) = (middle - 90, middle + 90)
        }
        let yPhase: (Double) -> CGFloat = { plot.maxY - CGFloat(($0 - phaseLow) / (phaseHigh - phaseLow)) * plot.height }
        context.draw(Text(String(format: "%.0f°", phaseHigh + 0)).font(labelFont).foregroundStyle(phaseColor),
                     at: CGPoint(x: plot.maxX + 6, y: plot.minY), anchor: .leading)
        context.draw(Text(String(format: "%.0f°", phaseLow + 0)).font(labelFont).foregroundStyle(phaseColor),
                     at: CGPoint(x: plot.maxX + 6, y: plot.maxY), anchor: .leading)

        var phaseLine = Path()
        var gainLine = Path()
        for k in frequencies.indices {
            let gainPoint = CGPoint(x: x(frequencies[k]), y: y(gains[k]))
            let phasePoint = CGPoint(x: x(frequencies[k]), y: yPhase(phases[k]))
            if k == 0 {
                gainLine.move(to: gainPoint)
                phaseLine.move(to: phasePoint)
            } else {
                gainLine.addLine(to: gainPoint)
                phaseLine.addLine(to: phasePoint)
            }
        }
        var clipped = context
        clipped.clip(to: Path(plot.insetBy(dx: -1, dy: -1)))
        clipped.stroke(phaseLine, with: .color(phaseColor.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3]))
        clipped.stroke(gainLine, with: .color(gainColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

        // the readout under the pointer
        guard let pointer, plot.contains(pointer) else { return }
        let position = low + Double((pointer.x - plot.minX) / plot.width) * (high - low)
        let k = min(frequencies.count - 1, max(0, Int(((position - low) / (high - low) * Double(frequencies.count - 1)).rounded())))
        var marker = Path()
        marker.move(to: CGPoint(x: x(frequencies[k]), y: plot.minY))
        marker.addLine(to: CGPoint(x: x(frequencies[k]), y: plot.maxY))
        context.stroke(marker, with: .color(Color.secondary.opacity(0.6)), lineWidth: 1)
        context.fill(Path(ellipseIn: CGRect(x: x(frequencies[k]) - 3.5, y: y(gains[k]) - 3.5, width: 7, height: 7)), with: .color(gainColor))
        let text = "\(SI.format(frequencies[k], unit: "Hz"))   " + String(format: "%+.1f dB   %.0f°", gains[k], phases[k])
        let leftSide = x(frequencies[k]) > plot.midX
        context.draw(Text(text).font(labelFont.weight(.semibold)).foregroundStyle(.primary),
                     at: CGPoint(x: x(frequencies[k]) + (leftSide ? -6 : 6), y: plot.minY + 2), anchor: leftSide ? .topTrailing : .topLeading)
    }
}
