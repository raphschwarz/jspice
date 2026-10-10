import SwiftUI
import CircuitKit

/// The circuit as it would be built on perfboard: a pad round every hole, every part in its holes, the trails that
/// join pads on the copper side (seen through the board), the wire links on the parts' side, and what is wired from off
/// the board, with the bill of materials and a check that the board connects exactly the schematic's nets.
struct PerfboardView: View {
    @ObservedObject var editor: EditorState
    let circuit: Circuit
    @State private var layout: Perfboard.Layout?
    @State private var problems: [String] = []

    private let pitch: CGFloat = 16
    private var origin: CGPoint { CGPoint(x: pitch * 3, y: pitch * 2) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if let layout {
                        Button("Printable Sheet…", systemImage: "printer") {
                            editor.exportBoardSheet({ BoardSVG.perfboard(layout, title: $0) }, board: "perfboard")
                        }
                        .help("Save the board at its true size (0.1 in between holes), its parts' holes and bill of materials as an SVG drawing to print and build from")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            ScrollView([.horizontal, .vertical]) {
                if let layout {
                    Canvas { context, _ in draw(context, layout) }
                        .frame(width: origin.x + CGFloat(layout.columns) * pitch + pitch * 2,
                               height: origin.y + CGFloat(layout.rows) * pitch + pitch)
                        .overlay { BoardHoverReadout { readout(layout, at: $0) } }
                        .padding(20)
                } else {
                    ProgressView("Laying out the board…").padding(40)
                }
            }
            .defaultScrollAnchor(.topLeading)
            .background(Color(nsColor: .underPageBackgroundColor))
            }
            Divider()
            if let layout {
                BoardSidePanel(problems: problems,
                               supplies: layout.buses.sorted { $0.key < $1.key }.map { ("Row " + Stripboard.letters($0.key), $0.value) },
                               notes: layout.notes,
                               parts: layout.placements.map { placement in
                                   (placement.name + "  " + placement.title,
                                    placement.legs.filter { !$0.net.isEmpty }.map { "\($0.name) \($0.hole)" }.joined(separator: " · "), placement.note)
                               },
                               offBoard: layout.offBoard.map { item in
                                   ("\(item.name): \(item.title)", item.wires.map { "\($0.name) → \($0.hole)" }.joined(separator: " · "))
                               },
                               bom: layout.bom)
                    .frame(width: 300)
            }
        }
        .task(id: circuit) {
            // a knob turned or a note played changes the circuit many times a second: lay out the board once it rests
            if layout != nil { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let circuit = circuit
            let job = Task.detached(priority: .userInitiated) { () -> (Perfboard.Layout, [String]) in
                let layout = Perfboard.layout(circuit)
                return (layout, Perfboard.verify(layout))
            }
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            // a newer circuit's layout is on its way: this one is out of date
            guard !Task.isCancelled else { return }
            layout = result.0
            problems = result.1
        }
    }

    private func point(_ hole: Perfboard.Hole) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(hole.column) * pitch + pitch / 2, y: origin.y + CGFloat(hole.row) * pitch + pitch / 2)
    }

    private func readout(_ layout: Perfboard.Layout, at pointer: CGPoint) -> String? {
        let column = Int(floor((pointer.x - origin.x) / pitch)), row = Int(floor((pointer.y - origin.y) / pitch))
        guard column >= 0, column < layout.columns, row >= 0, row < layout.rows else { return nil }
        let hole = Perfboard.Hole(row: row, column: column)
        let net = layout.net(at: hole).map { $0.isEmpty ? "free pin" : $0 }
        return hole.description + (net.map { "  ·  \($0)" } ?? "")
    }

    private func draw(_ context: GraphicsContext, _ layout: Perfboard.Layout) {
        let p = pitch
        let board = CGRect(x: origin.x - p * 0.5, y: origin.y - p * 0.5, width: CGFloat(layout.columns + 1) * p, height: CGFloat(layout.rows + 1) * p)
        context.fill(Path(roundedRect: board, cornerRadius: 4), with: .color(Color(red: 0.87, green: 0.8, blue: 0.62)))
        // a copper pad round every hole
        var pads = Path(), holes = Path()
        for row in 0..<layout.rows {
            for column in 0..<layout.columns {
                let c = point(Perfboard.Hole(row: row, column: column))
                pads.addEllipse(in: PartPainter.square(c, p * 0.72))
                holes.addEllipse(in: PartPainter.square(c, p * 0.28))
            }
            let y = point(Perfboard.Hole(row: row, column: 0)).y
            context.draw(Text(Stripboard.letters(row)).font(.system(size: 8)).foregroundStyle(.secondary), at: CGPoint(x: origin.x - p * 0.9, y: y))
            if let net = layout.buses[row] {
                context.draw(Text(net).font(.system(size: 9, weight: .semibold)).foregroundStyle(net == "GND" ? Color.blue : Color.red),
                             at: CGPoint(x: origin.x - p * 1.4, y: y), anchor: .trailing)
            }
        }
        context.fill(pads, with: .color(Color(red: 0.85, green: 0.55, blue: 0.3).opacity(0.75)))
        // the trails on the copper side, seen through the board: tinned wire over the pads
        for trail in layout.trails {
            let a = point(Perfboard.Hole(row: trail.row, column: trail.from)), b = point(Perfboard.Hole(row: trail.row, column: trail.to))
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            context.stroke(path, with: .color(Color(white: 0.72)), style: StrokeStyle(lineWidth: p * 0.42, lineCap: .round))
            context.stroke(path, with: .color(wireColor(trail.net, layout).opacity(0.55)), style: StrokeStyle(lineWidth: p * 0.14, lineCap: .round))
        }
        context.fill(holes, with: .color(Color(white: 0.2)))
        for column in stride(from: 0, to: layout.columns, by: 5) {
            context.draw(Text("\(column + 1)").font(.system(size: 8)).foregroundStyle(.secondary),
                         at: CGPoint(x: point(Perfboard.Hole(row: 0, column: column)).x, y: origin.y - p * 0.9))
        }
        // links on the parts' side: bare wire, or a coloured sleeve when long
        for link in layout.links {
            let a = point(link.from), b = point(link.to)
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            let long = abs(link.from.row - link.to.row) + abs(link.from.column - link.to.column) > 2
            context.stroke(path, with: .color(long ? wireColor(link.net, layout) : Color(white: 0.6)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        }
        // off-board wires
        for item in layout.offBoard {
            for wire in item.wires {
                let a = point(wire.hole)
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
                             legs: placement.legs.map { (name: $0.name, point: point($0.hole)) }, pitch: p)
        }
    }

    private func wireColor(_ net: String, _ layout: Perfboard.Layout) -> Color {
        if net == "GND" { return .blue }
        if layout.buses.values.contains(net) { return net.hasPrefix("−") || net.hasPrefix("-") ? .black : .red }
        let palette: [Color] = [.orange, .green, .purple, .yellow, .teal, .brown, .pink, .mint, .indigo, .cyan]
        let hash = net.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }
}
