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

    var body: some View {
        HStack(spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                if let layout {
                    let size = BoardGeometry(width: layout.width).size
                    Canvas { context, _ in draw(context, layout) }
                        .frame(width: size.width, height: size.height)
                        .overlay { BoardHoverReadout { readout(layout, at: $0) } }
                        .padding(20)
                } else {
                    ProgressView("Laying out the board…").padding(40)
                }
            }
            .defaultScrollAnchor(.topLeading)
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            if let layout { sidePanel(layout).frame(width: 300) }
        }
        .task(id: circuit) {
            // a knob turned or a note played changes the circuit many times a second: lay out the board once it rests
            if layout != nil { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let circuit = circuit
            let job = Task.detached(priority: .userInitiated) { () -> (Breadboard.Layout, [String]) in
                let layout = Breadboard.layout(circuit)
                return (layout, Breadboard.verify(layout))
            }
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            // a newer circuit's layout is on its way: this one is out of date
            guard !Task.isCancelled else { return }
            layout = result.0
            problems = result.1
        }
    }

    // MARK: - Side panel

    private func sidePanel(_ layout: Breadboard.Layout) -> some View {
        BoardSidePanel(problems: problems,
                       supplies: Breadboard.Rail.allCases.compactMap { rail in layout.rails[rail].map { (rail.name.capitalized, $0) } },
                       notes: layout.notes,
                       parts: layout.placements.map { placement in
                           (placement.name + "  " + placement.title,
                            placement.legs.filter { !$0.net.isEmpty }.map { "\($0.name) \($0.hole)" }.joined(separator: " · "), placement.note)
                       },
                       offBoard: layout.offBoard.map { item in
                           ("\(item.name): \(item.title)", item.wires.map { "\($0.name) → \($0.hole)" }.joined(separator: " · "))
                       },
                       bom: layout.bom)
    }

    // MARK: - Drawing

    private func readout(_ layout: Breadboard.Layout, at pointer: CGPoint) -> String? {
        guard let hole = BoardGeometry(width: layout.width).hole(near: pointer) else { return nil }
        let net = layout.nets[hole] ?? stripNet(hole, layout)
        return "\(hole.description)" + (net.map { "  ·  \($0.isEmpty ? "free pin" : $0)" } ?? "")
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
        for placement in layout.placements {
            PartPainter.draw(context, placement.style, name: placement.name, title: placement.title,
                             legs: placement.legs.map { (name: $0.name, point: g.point($0.hole)) }, pitch: g.pitch)
        }
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

/// Draws a part as it looks on a board, seen from above, its legs in the holes at `legs`
enum PartPainter {
    static func draw(_ context: GraphicsContext, _ style: Breadboard.Style, name: String, title: String,
                     legs: [(name: String, point: CGPoint)], pitch p: CGFloat) {
        let points = legs.map(\.point)
        guard let first = points.first, let last = points.last else { return }
        let middle = CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2)
        let length = hypot(last.x - first.x, last.y - first.y)
        let angle = atan2(last.y - first.y, last.x - first.x)
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
        /// The context turned so the legs run left to right along x, centred on the middle
        var along: GraphicsContext {
            var c = context
            c.translateBy(x: middle.x, y: middle.y)
            c.rotate(by: .radians(angle))
            return c
        }
        /// A body along the leads, `length` long
        func partBody(_ length: CGFloat, _ thickness: CGFloat, _ color: Color, bands: [Color] = []) {
            let c = along
            let rect = CGRect(x: -length / 2, y: -thickness / 2, width: length, height: thickness)
            c.fill(Path(roundedRect: rect, cornerRadius: thickness / 2), with: .color(color))
            for (k, band) in bands.enumerated() {
                let x = -length / 2 + length * (0.2 + 0.16 * CGFloat(k))
                c.fill(Path(CGRect(x: x, y: -thickness / 2, width: length * 0.08, height: thickness)), with: .color(band))
            }
        }
        /// A mark on the body, towards the leg named `leg`
        func mark(towards leg: String, _ distance: CGFloat, _ size: CGFloat, _ color: Color) {
            guard let k = legs.firstIndex(where: { $0.name == leg }) else { return }
            let toward = points[k]
            let d = hypot(toward.x - middle.x, toward.y - middle.y)
            guard d > 0 else { return }
            let at = CGPoint(x: middle.x + (toward.x - middle.x) / d * distance, y: middle.y + (toward.y - middle.y) / d * distance)
            context.fill(Path(ellipseIn: square(at, size)), with: .color(color))
        }
        var labelAt = CGPoint(x: middle.x, y: points.map(\.y).min()! - p * 1.25)
        switch style {
        case .resistor(let ohms):
            leads()
            partBody(min(length * 0.7, p * 2.6), p * 0.7, Color(red: 0.85, green: 0.76, blue: 0.6), bands: bands(ohms))
        case .ceramic:
            leads()
            context.fill(Path(ellipseIn: square(middle, p * 0.8)), with: .color(Color(red: 0.95, green: 0.75, blue: 0.2)))
        case .electrolytic:
            leads()
            context.fill(Path(ellipseIn: square(middle, p * 1.5)), with: .color(Color(red: 0.15, green: 0.25, blue: 0.55)))
            mark(towards: "−", p * 0.5, p * 0.35, .white.opacity(0.85))
        case .inductor:
            leads()
            partBody(min(length * 0.7, p * 1.8), p * 0.8, Color(red: 0.3, green: 0.55, blue: 0.35))
        case .diode, .zener:
            leads()
            partBody(min(length * 0.6, p * 1.3), p * 0.5, style == .diode ? Color(white: 0.15) : Color(red: 0.9, green: 0.45, blue: 0.2))
            mark(towards: "cathode", p * 0.45, p * 0.3, Color(white: 0.85))
        case .led(let color):
            leads()
            let colors: [Color] = [.red, .green, .blue, .yellow, Color(white: 0.95)]
            context.fill(Path(ellipseIn: square(middle, p * 1.2)), with: .color(colors[min(max(color, 0), 4)].opacity(0.85)))
            if let anode = legs.first(where: { $0.name == "anode" }) {
                label("+", at: CGPoint(x: anode.point.x + p * 0.45, y: anode.point.y - p * 0.45))
            }
        case .lamp:
            leads()
            context.fill(Path(ellipseIn: square(middle, p * 1.1)), with: .color(.yellow.opacity(0.6)))
        case .toggle, .button:
            leads()
            context.fill(Path(roundedRect: square(middle, p * 1.2), cornerRadius: 2), with: .color(Color(white: 0.25)))
        case .transistor(let pinout):
            // a TO-92 seen from above, beside its legs, its flat face towards them
            let c = along
            let rect = CGRect(x: -length / 2 - p * 0.45, y: -p * 1.0, width: length + p * 0.9, height: p * 0.85)
            var shape = Path()
            shape.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            shape.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            shape.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - p * 0.6))
            c.fill(shape, with: .color(Color(white: 0.12)))
            // the legs' letters on the flat side
            let normal = CGPoint(x: -sin(angle), y: cos(angle))
            for (k, point) in points.enumerated() where k < pinout.count {
                label(String(Array(pinout)[k]), at: CGPoint(x: point.x + normal.x * p * 0.62, y: point.y + normal.y * p * 0.62), color: .secondary)
            }
            if abs(sin(angle)) > 0.5 { labelAt = CGPoint(x: middle.x + p * 1.6, y: points.map(\.y).min()! - p * 0.8) }
        case .pot:
            let rect = CGRect(x: first.x - p * 0.4, y: first.y - p * 1.9, width: last.x - first.x + p * 0.8, height: p * 1.7)
            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color(red: 0.2, green: 0.35, blue: 0.7)))
            context.fill(Path(ellipseIn: square(CGPoint(x: rect.midX, y: rect.midY), p * 1.1)), with: .color(Color(white: 0.85)))
            labelAt.y = points.map(\.y).min()! - p * 2.3
        case .vactrol:
            along.fill(Path(roundedRect: CGRect(x: -length / 2 - p * 0.3, y: -p * 0.45, width: length + p * 0.6, height: p * 0.9), cornerRadius: 4),
                       with: .color(Color(white: 0.1)))
            if abs(sin(angle)) > 0.5 { labelAt = CGPoint(x: middle.x + p * 1.2, y: points.map(\.y).min()! - p * 0.8) }
        case .dip:
            let xs = points.map(\.x), ys = points.map(\.y)
            let wide = xs.max()! - xs.min()! >= ys.max()! - ys.min()!
            let rect = wide
                ? CGRect(x: xs.min()! - p * 0.4, y: ys.min()! + p * 0.3, width: xs.max()! - xs.min()! + p * 0.8, height: ys.max()! - ys.min()! - p * 0.6)
                : CGRect(x: xs.min()! + p * 0.3, y: ys.min()! - p * 0.4, width: xs.max()! - xs.min()! - p * 0.6, height: ys.max()! - ys.min()! + p * 0.8)
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Color(white: 0.13)))
            // the notch at the pin-1 end, and pin 1's dot
            let notch = wide ? CGPoint(x: rect.minX, y: rect.midY) : CGPoint(x: rect.midX, y: rect.minY)
            context.fill(Path(ellipseIn: square(notch, p * 0.5)), with: .color(Color(white: 0.6)))
            context.fill(Path(ellipseIn: square(CGPoint(x: first.x + (first.x < rect.midX ? p * 0.8 : -p * 0.8) * (wide ? 0 : 1),
                                                        y: first.y + (first.y < rect.midY ? p * 0.8 : -p * 0.8) * (wide ? 1 : 0)), p * 0.22)),
                         with: .color(Color(white: 0.6)))
            var c = context
            c.translateBy(x: rect.midX, y: rect.midY)
            if !wide { c.rotate(by: .degrees(90)) }
            c.draw(Text(title.components(separatedBy: " (").first ?? title).font(.system(size: 9, weight: .bold)).foregroundStyle(.white), at: .zero)
            labelAt = wide ? CGPoint(x: middle.x, y: ys.min()! - p * 0.9) : CGPoint(x: middle.x, y: rect.minY - p * 0.6)
        }
        label(name, at: labelAt)
    }

    static func square(_ c: CGPoint, _ s: CGFloat) -> CGRect { CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s) }

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

/// What a board needs beside its picture: whether it checks out, its supplies, notes, each part's holes, what is wired
/// from off it, and the bill of materials
struct BoardSidePanel: View {
    let problems: [String]
    let supplies: [(String, String)]
    let notes: [String]
    let parts: [(String, String, String?)]
    let offBoard: [(String, String)]
    let bom: [Breadboard.Item]

    var body: some View {
        List {
            Section {
                if problems.isEmpty {
                    Label("Every connection checked against the schematic", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            if !supplies.isEmpty {
                Section("Supplies") {
                    ForEach(Array(supplies.enumerated()), id: \.offset) { _, supply in LabeledContent(supply.0, value: supply.1) }
                }
            }
            if !notes.isEmpty {
                Section("Notes") {
                    ForEach(notes, id: \.self) { Text($0).font(.callout) }
                }
            }
            Section("Parts") {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(part.0).font(.callout.weight(.medium))
                        Text(part.1).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let note = part.2 { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if !offBoard.isEmpty {
                Section("Off the board") {
                    ForEach(Array(offBoard.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.0).font(.callout.weight(.medium))
                            Text(item.1).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                ForEach(Array(bom.enumerated()), id: \.offset) { _, item in
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
                    Button("Copy CSV") { copyBOM() }.buttonStyle(.borderless).controlSize(.small)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func copyBOM() {
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let lines = ["Quantity,Part,Designators"] + bom.map { "\($0.quantity),\(quoted($0.description)),\(quoted($0.parts.joined(separator: " ")))" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

/// The hole under the pointer and what is on it, over a board: kept apart from the board's own view, so that moving
/// the pointer redraws only this and not every hole and part
struct BoardHoverReadout: View {
    let text: (CGPoint) -> String?
    @State private var pointer: CGPoint?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): pointer = location
                case .ended: pointer = nil
                }
            }
            .overlay(alignment: .topLeading) {
                if let pointer, let line = text(pointer) {
                    Text(line)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
    }
}
