import SwiftUI
import AppKit
import CircuitKit

/// The circuit as it would be built on a breadboard: every part in its holes, the jumpers, the rails, what is wired
/// from off the board, and the bill of materials, with a check that the board connects exactly the schematic's nets.
struct BreadboardView: View {
    @ObservedObject var editor: EditorState
    let circuit: Circuit
    @State private var layout: Breadboard.Layout?
    @State private var problems: [String] = []
    @State private var pointer: CGPoint?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                if let layout {
                    let size = BoardGeometry(width: layout.width).size
                    Canvas { context, _ in draw(context, layout) }
                        .frame(width: size.width, height: size.height)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location): pointer = location
                            case .ended: pointer = nil
                            }
                        }
                        .overlay(alignment: .topLeading) { readout(layout) }
                        .padding(20)
                } else {
                    ProgressView("Laying out the board…").padding(40)
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            if let layout { sidePanel(layout).frame(width: 300) }
        }
        .task(id: circuit) {
            let circuit = circuit
            let result = await Task.detached(priority: .userInitiated) { () -> (Breadboard.Layout, [String]) in
                let layout = Breadboard.layout(circuit)
                return (layout, Breadboard.verify(layout))
            }.value
            layout = result.0
            problems = result.1
        }
    }

    // MARK: - Side panel

    private func sidePanel(_ layout: Breadboard.Layout) -> some View {
        List {
            Section {
                if problems.isEmpty {
                    Label("Every connection checked against the schematic", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            Section("Rails") {
                ForEach(Breadboard.Rail.allCases, id: \.self) { rail in
                    if let net = layout.rails[rail] { LabeledContent(rail.name.capitalized, value: net) }
                }
            }
            if !layout.notes.isEmpty {
                Section("Notes") {
                    ForEach(layout.notes, id: \.self) { Text($0).font(.callout) }
                }
            }
            Section("Parts") {
                ForEach(Array(layout.placements.enumerated()), id: \.offset) { _, placement in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(placement.name)  \(placement.title)").font(.callout.weight(.medium))
                        Text(placement.legs.filter { !$0.net.isEmpty }.map { "\($0.name) \($0.hole)" }.joined(separator: " · "))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let note = placement.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if !layout.offBoard.isEmpty {
                Section("Off the board") {
                    ForEach(Array(layout.offBoard.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.name): \(item.title)").font(.callout.weight(.medium))
                            Text(item.wires.map { "\($0.name) → \($0.hole)" }.joined(separator: " · "))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                ForEach(Array(layout.bom.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(item.quantity) ×").monospacedDigit().frame(width: 34, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.description)
                            if !item.parts.isEmpty { Text(item.parts.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Bill of materials")
                    Spacer()
                    Button("Copy CSV") { copyBOM(layout) }.buttonStyle(.borderless).controlSize(.small)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func copyBOM(_ layout: Breadboard.Layout) {
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let lines = ["Quantity,Part,Designators"] + layout.bom.map { "\($0.quantity),\(quoted($0.description)),\(quoted($0.parts.joined(separator: " ")))" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Drawing

    private func readout(_ layout: Breadboard.Layout) -> some View {
        Group {
            if let pointer, let hole = BoardGeometry(width: layout.width).hole(near: pointer) {
                let net = layout.nets[hole] ?? stripNet(hole, layout)
                Text("\(hole.description)" + (net.map { "  ·  \($0.isEmpty ? "free pin" : $0)" } ?? ""))
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8)
            }
        }
    }

    /// The net of a free hole: the net of anything in its strip or on its rail
    private func stripNet(_ hole: Breadboard.Hole, _ layout: Breadboard.Layout) -> String? {
        for (other, net) in layout.nets {
            switch (hole, other) {
            case let (.strip(c1, r1), .strip(c2, r2)) where c1 == c2 && (r1 < 5) == (r2 < 5): return net
            case let (.rail(a, _), .rail(b, _)) where a == b: return net
            default: continue
            }
        }
        return nil
    }

    private func draw(_ context: GraphicsContext, _ layout: Breadboard.Layout) {
        let g = BoardGeometry(width: layout.width)
        let p = g.pitch
        // the board
        context.fill(Path(roundedRect: CGRect(origin: .zero, size: g.size), cornerRadius: 8), with: .color(Color(red: 0.95, green: 0.94, blue: 0.9)))
        context.fill(Path(CGRect(x: 0, y: g.channel - p * 0.35, width: g.size.width, height: p * 0.7)), with: .color(Color(red: 0.88, green: 0.87, blue: 0.83)))
        for rail in Breadboard.Rail.allCases {
            let y = g.railY(rail)
            let positive = rail == .topPositive || rail == .bottomPositive
            var line = Path()
            let offset = (rail == .topPositive || rail == .bottomNegative) ? -p * 0.55 : p * 0.55
            line.move(to: CGPoint(x: g.x(1) - p, y: y + offset))
            line.addLine(to: CGPoint(x: g.x(layout.width) + p, y: y + offset))
            context.stroke(line, with: .color(positive ? .red.opacity(0.7) : .blue.opacity(0.7)), lineWidth: 1.2)
            if let net = layout.rails[rail] {
                context.draw(Text(net).font(.system(size: 9, weight: .semibold)).foregroundStyle(positive ? Color.red : Color.blue),
                             at: CGPoint(x: g.x(1) - p * 1.2, y: y), anchor: .trailing)
            }
        }
        // holes
        var holes = Path()
        for column in 1...layout.width {
            for row in 0..<10 { holes.addRect(square(g.point(.strip(column: column, row: row)), p * 0.32)) }
            for rail in Breadboard.Rail.allCases { holes.addRect(square(g.point(.rail(rail, column: column)), p * 0.32)) }
            if column % 5 == 0 || column == 1 {
                context.draw(Text("\(column)").font(.system(size: 8)).foregroundStyle(.secondary),
                             at: CGPoint(x: g.x(column), y: g.rowY(0) - p * 0.75))
            }
        }
        context.fill(holes, with: .color(Color(white: 0.35)))
        for row in 0..<10 {
            context.draw(Text(String(Character(UnicodeScalar(UInt8(97 + row))))).font(.system(size: 8)).foregroundStyle(.secondary),
                         at: CGPoint(x: g.x(1) - p * 0.8, y: g.rowY(row)))
        }

        // jumpers, arched
        for jumper in layout.jumpers {
            let a = g.point(jumper.from), b = g.point(jumper.to)
            var path = Path()
            path.move(to: a)
            let lift = min(max(abs(a.x - b.x), abs(a.y - b.y)) * 0.25, p * 1.5)
            path.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - lift))
            context.stroke(path, with: .color(wireColor(jumper.net, layout)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        }
        // off-board wires: a short lead off the hole with the item's name
        for item in layout.offBoard {
            for wire in item.wires {
                let a = g.point(wire.hole)
                var path = Path()
                path.move(to: a)
                path.addLine(to: CGPoint(x: a.x + p * 0.6, y: a.y - p * 0.8))
                context.stroke(path, with: .color(wireColor(wire.net, layout)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                context.draw(Text("\(item.name) \(wire.name)").font(.system(size: 7)).foregroundStyle(.secondary),
                             at: CGPoint(x: a.x + p * 0.7, y: a.y - p * 0.9), anchor: .bottomLeading)
            }
        }
        for placement in layout.placements { drawPart(context, placement, g) }
    }

    private func square(_ c: CGPoint, _ s: CGFloat) -> CGRect { CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s) }

    private func wireColor(_ net: String, _ layout: Breadboard.Layout) -> Color {
        if net == "GND" { return .blue }
        if let rail = layout.rails.first(where: { $0.value == net })?.key {
            return rail == .topPositive || rail == .bottomPositive ? (net.hasPrefix("−") || net.hasPrefix("-") ? .black : .red) : .blue
        }
        let palette: [Color] = [.orange, .green, .purple, .yellow, .teal, .brown, .pink, .mint, .indigo, .cyan]
        let hash = net.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }

    private func drawPart(_ context: GraphicsContext, _ placement: Breadboard.Placement, _ g: BoardGeometry) {
        let p = g.pitch
        let points = placement.legs.map { g.point($0.hole) }
        guard let first = points.first, let last = points.last else { return }
        let middle = CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2)
        func leads() {
            for point in points {
                var lead = Path()
                lead.move(to: point)
                lead.addLine(to: middle)
                context.stroke(lead, with: .color(Color(white: 0.55)), lineWidth: 1.4)
            }
        }
        func label(_ text: String, at point: CGPoint, color: Color = .primary) {
            context.draw(Text(text).font(.system(size: 8, weight: .semibold)).foregroundStyle(color), at: point)
        }
        let angle = atan2(last.y - first.y, last.x - first.x)
        /// A body along the leads, `length` long
        func partBody(_ length: CGFloat, _ thickness: CGFloat, _ color: Color, bands: [Color] = [], corner: CGFloat? = nil) {
            var c = context
            c.translateBy(x: middle.x, y: middle.y)
            c.rotate(by: .radians(angle))
            let rect = CGRect(x: -length / 2, y: -thickness / 2, width: length, height: thickness)
            c.fill(Path(roundedRect: rect, cornerRadius: corner ?? thickness / 2), with: .color(color))
            for (k, band) in bands.enumerated() {
                let x = -length / 2 + length * (0.2 + 0.16 * CGFloat(k))
                c.fill(Path(CGRect(x: x, y: -thickness / 2, width: length * 0.08, height: thickness)), with: .color(band))
            }
        }
        switch placement.style {
        case .resistor(let ohms):
            leads()
            partBody(min(hypot(last.x - first.x, last.y - first.y) * 0.7, p * 2.6), p * 0.7, Color(red: 0.85, green: 0.76, blue: 0.6), bands: Self.bands(ohms))
        case .ceramic:
            leads()
            context.fill(Path(ellipseIn: square(middle, p * 0.8)), with: .color(Color(red: 0.95, green: 0.75, blue: 0.2)))
        case .electrolytic:
            leads()
            context.fill(Path(ellipseIn: square(middle, p * 1.5)), with: .color(Color(red: 0.15, green: 0.25, blue: 0.55)))
            if let minus = placement.legs.firstIndex(where: { $0.name == "−" }) {
                let toward = points[minus]
                let d = hypot(toward.x - middle.x, toward.y - middle.y)
                if d > 0 {
                    let mark = CGPoint(x: middle.x + (toward.x - middle.x) / d * p * 0.5, y: middle.y + (toward.y - middle.y) / d * p * 0.5)
                    context.fill(Path(ellipseIn: square(mark, p * 0.35)), with: .color(.white.opacity(0.85)))
                }
            }
        case .inductor:
            leads()
            partBody(p * 1.8, p * 0.8, Color(red: 0.3, green: 0.55, blue: 0.35))
        case .diode, .zener:
            leads()
            partBody(p * 1.3, p * 0.5, placement.style == .diode ? Color(white: 0.15) : Color(red: 0.9, green: 0.45, blue: 0.2))
            if let cathode = placement.legs.firstIndex(where: { $0.name == "cathode" }) {
                let toward = points[cathode]
                let d = hypot(toward.x - middle.x, toward.y - middle.y)
                if d > 0 {
                    let band = CGPoint(x: middle.x + (toward.x - middle.x) / d * p * 0.45, y: middle.y + (toward.y - middle.y) / d * p * 0.45)
                    context.fill(Path(ellipseIn: square(band, p * 0.3)), with: .color(Color(white: 0.85)))
                }
            }
        case .led(let color):
            leads()
            let colors: [Color] = [.red, .green, .blue, .yellow, Color(white: 0.95)]
            context.fill(Path(ellipseIn: square(middle, p * 1.2)), with: .color(colors[min(max(color, 0), 4)].opacity(0.85)))
            if let anode = placement.legs.first(where: { $0.name == "anode" }) {
                label("+", at: CGPoint(x: g.point(anode.hole).x, y: g.point(anode.hole).y - p * 0.6))
            }
        case .lamp:
            leads()
            context.fill(Path(ellipseIn: square(middle, p * 1.1)), with: .color(.yellow.opacity(0.6)))
        case .toggle, .button:
            leads()
            context.fill(Path(roundedRect: square(middle, p * 1.2), cornerRadius: 2), with: .color(Color(white: 0.25)))
        case .transistor(let pinout):
            // a TO-92 seen from above, flat face towards the front
            let rect = CGRect(x: first.x - p * 0.45, y: first.y - p * 1.0, width: last.x - first.x + p * 0.9, height: p * 0.85)
            var shape = Path()
            shape.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            shape.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            shape.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - p * 0.6))
            context.fill(shape, with: .color(Color(white: 0.12)))
            for (k, point) in points.enumerated() where k < pinout.count {
                label(String(Array(pinout)[k]), at: CGPoint(x: point.x, y: point.y + p * 0.62), color: .secondary)
            }
        case .pot:
            let rect = CGRect(x: first.x - p * 0.4, y: first.y - p * 1.9, width: last.x - first.x + p * 0.8, height: p * 1.7)
            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color(red: 0.2, green: 0.35, blue: 0.7)))
            context.fill(Path(ellipseIn: square(CGPoint(x: rect.midX, y: rect.midY), p * 1.1)), with: .color(Color(white: 0.85)))
        case .vactrol:
            let rect = CGRect(x: first.x - p * 0.3, y: first.y - p * 0.45, width: last.x - first.x + p * 0.6, height: p * 0.9)
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Color(white: 0.1)))
        case .dip:
            let xs = points.map(\.x), ys = points.map(\.y)
            let rect = CGRect(x: xs.min()! - p * 0.4, y: ys.min()! + p * 0.3, width: xs.max()! - xs.min()! + p * 0.8, height: ys.max()! - ys.min()! - p * 0.6)
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Color(white: 0.13)))
            // the notch at the pin-1 end, and pin 1's dot
            context.fill(Path(ellipseIn: CGRect(x: rect.minX - p * 0.25, y: rect.midY - p * 0.25, width: p * 0.5, height: p * 0.5)),
                         with: .color(Color(red: 0.88, green: 0.87, blue: 0.83)))
            context.fill(Path(ellipseIn: square(CGPoint(x: rect.minX + p * 0.4, y: rect.maxY - p * 0.35), p * 0.22)), with: .color(Color(white: 0.6)))
            context.draw(Text(placement.title.components(separatedBy: " (").first ?? placement.title)
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.white), at: CGPoint(x: rect.midX, y: rect.midY))
        }
        if case .dip = placement.style {
            label(placement.name, at: CGPoint(x: middle.x, y: points.map(\.y).min()! - p * 0.9))
        } else {
            label(placement.name, at: CGPoint(x: middle.x, y: points.map(\.y).min()! - p * (placement.style == .pot ? 2.3 : 1.25)))
        }
    }

    /// A resistor's four colour bands: two digits, the multiplier, and gold for 5 %
    static func bands(_ ohms: Double) -> [Color] {
        let colors: [Color] = [.black, .brown, .red, .orange, .yellow, .green, .blue, .purple, .gray, .white]
        guard ohms > 0, ohms.isFinite else { return [] }
        var exponent = Int(floor(log10(ohms))) - 1
        var digits = Int((ohms / pow(10, Double(exponent))).rounded())
        if digits >= 100 { digits /= 10; exponent += 1 }
        let gold = Color(red: 0.8, green: 0.65, blue: 0.2)
        let multiplier = exponent >= 0 && exponent <= 9 ? colors[exponent] : exponent == -1 ? gold : Color(white: 0.75)
        return [colors[digits / 10 % 10], colors[digits % 10], multiplier, gold]
    }
}

/// Where the board's holes are drawn
struct BoardGeometry {
    let width: Int
    let pitch: CGFloat = 16
    var left: CGFloat { pitch * 3 }

    func x(_ column: Int) -> CGFloat { left + CGFloat(column - 1) * pitch }

    var top: CGFloat { pitch * 1.2 }
    func railY(_ rail: Breadboard.Rail) -> CGFloat {
        switch rail {
        case .topPositive: return top
        case .topNegative: return top + pitch
        case .bottomNegative: return rowY(9) + pitch * 2
        case .bottomPositive: return rowY(9) + pitch * 3
        }
    }
    func rowY(_ row: Int) -> CGFloat { top + pitch * 3.2 + CGFloat(row) * pitch + (row >= 5 ? pitch : 0) }
    var channel: CGFloat { (rowY(4) + rowY(5)) / 2 }
    var size: CGSize { CGSize(width: x(width) + pitch * 2, height: railY(.bottomPositive) + pitch * 1.2) }

    func point(_ hole: Breadboard.Hole) -> CGPoint {
        switch hole {
        case .strip(let column, let row): return CGPoint(x: x(column), y: rowY(row))
        case .rail(let rail, let column): return CGPoint(x: x(column), y: railY(rail))
        }
    }

    func hole(near point: CGPoint) -> Breadboard.Hole? {
        let column = Int(((point.x - left) / pitch).rounded()) + 1
        guard column >= 1, column <= width else { return nil }
        var candidates: [Breadboard.Hole] = (0..<10).map { .strip(column: column, row: $0) }
        candidates += Breadboard.Rail.allCases.map { .rail($0, column: column) }
        let best = candidates.min { abs(self.point($0).y - point.y) < abs(self.point($1).y - point.y) }
        return best.flatMap { abs(self.point($0).y - point.y) < pitch * 0.5 ? $0 : nil }
    }
}
