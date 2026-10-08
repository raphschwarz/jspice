import SwiftUI
import CircuitKit

/// A hardware-style front panel for the circuit's controls, like a plugin's interface: a knob for each potentiometer,
/// a toggle for each switch, a button for each push button and a lamp for each LED, in the order they appear on the
/// schematic from left to right, then a level meter for each speaker. Double-click a label to rename the part.
struct FrontPanel: View {
    @ObservedObject var editor: EditorState
    let circuit: Circuit

    /// One thing on the panel: a part of the circuit, or a part inside one of its blocks (labelled with the block's
    /// name), placed where its block is
    struct Control: Identifiable {
        let element: Element
        /// The block part it is inside
        let blockID: UUID?
        let label: String
        let place: GridPoint
        /// Its id in the simulation (a block's parts have ids of their own there)
        var id: UUID { blockID.map { UUID.inBlock($0, part: element.id) } ?? element.id }
    }

    private static let shown: Set<ElementKind> = [.potentiometer, .toggleSwitch, .pushButton, .led, .speaker]
    private static let playable: Set<ElementKind> = [.potentiometer, .toggleSwitch, .pushButton]

    /// The parts that appear on the panel: controls and lamps left to right as on the schematic (those inside a block
    /// where the block is), then the output meters
    static func controls(of circuit: Circuit) -> [Control] {
        var controls = circuit.elements.filter { shown.contains($0.kind) }.map {
            Control(element: $0, blockID: nil, label: $0.name, place: GridPoint(min($0.a.x, $0.b.x), min($0.a.y, $0.b.y)))
        }
        for block in circuit.elements where block.kind == .block {
            for inner in block.block?.circuit.elements ?? [] where shown.contains(inner.kind) && inner.kind != .speaker {
                controls.append(Control(element: inner, blockID: block.id, label: "\(block.name) \(inner.name)",
                                        place: GridPoint(min(block.a.x, block.b.x), min(block.a.y, block.b.y))))
            }
        }
        func key(_ c: Control) -> (Int, Int, Int) { (c.element.kind == .speaker ? 1 : 0, c.place.x, c.place.y) }
        return controls.sorted { key($0) < key($1) }
    }

    /// How a MIDI mapping names the control: the part on the schematic, or the block part and the part inside it
    static func midiTarget(_ control: Control) -> EditorState.MIDITarget {
        control.blockID.map { EditorState.MIDITarget(part: $0, inner: control.element.id) }
            ?? EditorState.MIDITarget(part: control.element.id, inner: nil)
    }

    static func hasControls(_ circuit: Circuit) -> Bool {
        circuit.elements.contains {
            playable.contains($0.kind) || ($0.block?.circuit.elements.contains { playable.contains($0.kind) } ?? false)
        }
    }

    var body: some View {
        let controls = Self.controls(of: circuit)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 26) {
                ForEach(controls) { control in
                    let target = Self.midiTarget(control)
                    let learning = editor.midiLearning == target
                    let mapping = circuit.midiMapping(part: target.part, inner: target.inner)
                    VStack(spacing: 6) {
                        self.control(for: control)
                            .frame(height: 74)
                            .overlay {
                                if learning {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.orange, lineWidth: 2)
                                        .padding(-4)
                                }
                            }
                        PanelLabel(name: control.label) { name in
                            if let block = control.blockID {
                                editor.updateInsideBlock(block, control.element.id, actionName: "Rename") { $0.name = name }
                            } else {
                                editor.rename(control.element.id, to: name)
                            }
                        }
                        if learning || mapping != nil {
                            Text(learning ? "Move a MIDI control" : mapping?.label ?? "")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(learning ? Color.orange : Color.white.opacity(0.45))
                        }
                    }
                    .frame(minWidth: 64)
                    .contextMenu {
                        if Self.playable.contains(control.element.kind) {
                            Button(learning ? "Cancel MIDI Learn" : "MIDI Learn") { editor.learnMIDI(part: target.part, inner: target.inner) }
                            if let mapping {
                                Button("Forget \(mapping.label)") { editor.forgetMIDI(part: target.part, inner: target.inner) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 14)
        }
        .frame(height: 128)
        .background(Faceplate())
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func control(for control: Control) -> some View {
        let element = control.element
        switch element.kind {
        case .potentiometer:
            Knob(position: element[param: "position"],
                 turn: { turn(control, by: $0) },
                 reset: { turn(control, by: 0.5 - element[param: "position"]) })
        case .toggleSwitch:
            ToggleSwitch(on: element.closed) {
                if let block = control.blockID {
                    editor.playInsideBlock(block, element.id) { $0.closed.toggle() }
                } else {
                    editor.toggleSwitch(element.id)
                }
            }
        case .pushButton:
            PushButton(pressed: element.closed) { pressed in
                if let block = control.blockID {
                    editor.playInsideBlock(block, element.id) { $0.closed = pressed }
                } else {
                    editor.setPressed(element.id, pressed)
                }
            }
        case .led:
            PanelLamp(simulation: editor.simulation, elementID: control.id,
                      color: LEDColor(rawValue: Int(element[param: "color"])) ?? .red)
        default:
            LevelMeter(simulation: editor.simulation)
        }
    }

    private func turn(_ control: Control, by delta: Double) {
        if let block = control.blockID {
            editor.playInsideBlock(block, control.element.id) { $0[param: "position"] = min(1, max(0, $0[param: "position"] + delta)) }
        } else {
            editor.turnPotentiometer(control.element.id, by: delta)
        }
    }
}

// MARK: - Faceplate

/// Dark anodised aluminium with a fine brushed grain and a screw in each corner
private struct Faceplate: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.24), Color(white: 0.15), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                // brushed grain: faint horizontal lines of varying brightness
                var y: CGFloat = 0
                var k = 0
                while y < size.height {
                    let shade = 0.5 + 0.5 * sin(Double(k) * 12.9898).truncatingRemainder(dividingBy: 1)
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                                 with: .color(.white.opacity(0.012 + 0.02 * shade)))
                    y += 2
                    k += 1
                }
            }
            // a highlight along the top edge and a shadow along the bottom
            VStack(spacing: 0) {
                Rectangle().fill(.white.opacity(0.14)).frame(height: 1)
                Spacer()
                Rectangle().fill(.black.opacity(0.5)).frame(height: 1)
            }
            GeometryReader { geometry in
                let inset: CGFloat = 12
                ForEach(0..<4, id: \.self) { corner in
                    Screw()
                        .frame(width: 9, height: 9)
                        .position(x: corner % 2 == 0 ? inset : geometry.size.width - inset,
                                  y: corner < 2 ? inset : geometry.size.height - inset)
                }
            }
        }
    }
}

private struct Screw: View {
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.62), Color(white: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().strokeBorder(.black.opacity(0.5), lineWidth: 0.5)
            Rectangle().fill(.black.opacity(0.55)).frame(height: 1.2).rotationEffect(.degrees(35))
        }
        .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
    }
}

/// An engraved part name; double-click to rename the part
private struct PanelLabel: View {
    let name: String
    let rename: (String) -> Void
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("Name", text: $text)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 80)
                    .focused($focused)
                    .onSubmit(finish)
                    .onChange(of: focused) { _, isFocused in if !isFocused { finish() } }
                    .onAppear { focused = true }
            } else {
                Text(name.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color(white: 0.82))
                    .shadow(color: .black.opacity(0.8), radius: 0, y: -0.7)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        text = name
                        editing = true
                    }
                    .help("Double-click to rename")
            }
        }
        .frame(height: 16)
    }

    private func finish() {
        guard editing else { return }
        editing = false
        if text != name { rename(text) }
    }
}

// MARK: - Controls

/// A knurled metal knob with a pointer and a lit arc for its setting; drag up or down to turn it, double-click to
/// centre it
private struct Knob: View {
    let position: Double
    let turn: (Double) -> Void
    let reset: () -> Void
    @State private var lastDrag: CGFloat = 0

    /// The knob turns through 270°, from 7:30 to 4:30
    private var angle: Double { -135 + 270 * min(1, max(0, position)) }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                // scale: eleven ticks around the knob
                ForEach(0...10, id: \.self) { tick in
                    Capsule()
                        .fill(Color(white: tick == 0 || tick == 10 ? 0.75 : 0.5))
                        .frame(width: 1.5, height: tick % 5 == 0 ? 6 : 4)
                        .offset(y: -30)
                        .rotationEffect(.degrees(-135 + 27 * Double(tick)))
                }
                // the setting, lit
                Circle()
                    .trim(from: 0, to: 0.75 * min(1, max(0, position)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .frame(width: 50, height: 50)
                    .shadow(color: .accentColor.opacity(0.6), radius: 3)
                // knurled skirt
                Circle()
                    .fill(AngularGradient(colors: [Color(white: 0.55), Color(white: 0.25), Color(white: 0.6), Color(white: 0.2),
                                                   Color(white: 0.55)], center: .center))
                    .frame(width: 40, height: 40)
                    .overlay {
                        ForEach(0..<24, id: \.self) { k in
                            Rectangle()
                                .fill(.black.opacity(0.25))
                                .frame(width: 0.8, height: 3)
                                .offset(y: -18.5)
                                .rotationEffect(.degrees(Double(k) * 15 + angle))
                        }
                    }
                    .shadow(color: .black.opacity(0.7), radius: 3, y: 2)
                // cap and pointer, turning together
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.34), Color(white: 0.16)], center: UnitPoint(x: 0.4, y: 0.35),
                                         startRadius: 1, endRadius: 18))
                    .frame(width: 30, height: 30)
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.7))
                Capsule()
                    .fill(.white)
                    .frame(width: 2.5, height: 10)
                    .offset(y: -9)
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: 64, height: 64)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    // 160 points of travel for the whole range; up turns it up
                    let delta = -(drag.translation.height - lastDrag) / 160
                    lastDrag = drag.translation.height
                    if delta != 0 { turn(delta) }
                }
                .onEnded { _ in lastDrag = 0 })
            .onTapGesture(count: 2, perform: reset)
            .help("Drag up or down to turn; double-click to centre")
            Text(String(format: "%.1f", 10 * position))
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(Color(white: 0.6))
        }
    }
}

/// A bat-handle toggle switch on a hex nut: up is on
private struct ToggleSwitch: View {
    let on: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            Text("ON").font(.system(size: 8, weight: .bold)).foregroundStyle(Color(white: on ? 0.85 : 0.45))
            ZStack {
                // the nut
                RegularPolygon(sides: 6)
                    .fill(LinearGradient(colors: [Color(white: 0.7), Color(white: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 26, height: 26)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                Circle()
                    .fill(Color(white: 0.18))
                    .frame(width: 12, height: 12)
                // the bat, leaning up or down
                Capsule()
                    .fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.55)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 7, height: 26)
                    .offset(y: on ? -12 : 12)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: on ? 3 : -1)
                    .animation(.spring(response: 0.18, dampingFraction: 0.6), value: on)
            }
            .frame(width: 44, height: 50)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            Text("OFF").font(.system(size: 8, weight: .bold)).foregroundStyle(Color(white: on ? 0.45 : 0.85))
        }
        .help("Click to flip")
    }
}

/// A momentary push button: held down while the mouse is
private struct PushButton: View {
    let pressed: Bool
    let press: (Bool) -> Void

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.22)], startPoint: .top, endPoint: .bottom))
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            Circle()
                .fill(RadialGradient(colors: [Color(red: 0.95, green: 0.35, blue: 0.3), Color(red: 0.6, green: 0.08, blue: 0.06)],
                                     center: UnitPoint(x: 0.4, y: pressed ? 0.5 : 0.35), startRadius: 1, endRadius: 16))
                .frame(width: 28, height: 28)
                .scaleEffect(pressed ? 0.92 : 1)
                .shadow(color: .black.opacity(pressed ? 0.2 : 0.6), radius: pressed ? 0.5 : 2, y: pressed ? 0 : 2)
        }
        .frame(width: 64, height: 64)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !pressed { press(true) } }
            .onEnded { _ in press(false) })
        .help("Hold to press")
    }
}

/// An LED as a panel lamp, glowing with the simulated LED's current
private struct PanelLamp: View {
    @ObservedObject var simulation: SimulationController
    let elementID: UUID
    let color: LEDColor

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !simulation.isRunning)) { _ in
            // (a lamp inside a block is a part of the simulation's flattened circuit)
            let index = simulation.simulator.flatIndex(of: elementID)
            let brightness = index.map { simulation.simulator.brightness($0) } ?? 0
            let hue = lampColor
            ZStack {
                Circle().fill(Color(white: 0.1)).frame(width: 26, height: 26)
                Circle()
                    .fill(RadialGradient(colors: [hue.opacity(0.35 + 0.65 * brightness), hue.opacity(0.15 + 0.5 * brightness)],
                                         center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: 10))
                    .frame(width: 18, height: 18)
                    .shadow(color: hue.opacity(brightness), radius: 10 * brightness)
                Circle()
                    .fill(.white.opacity(0.35))
                    .frame(width: 5, height: 5)
                    .offset(x: -3, y: -3)
            }
            .frame(width: 64, height: 64)
        }
    }

    private var lampColor: Color {
        switch color {
        case .red: return Color(red: 1, green: 0.2, blue: 0.15)
        case .yellow: return Color(red: 1, green: 0.85, blue: 0.2)
        case .green: return Color(red: 0.3, green: 1, blue: 0.35)
        case .blue: return Color(red: 0.3, green: 0.55, blue: 1)
        case .white: return .white
        }
    }
}

/// The speaker's output level: a column of lit segments, green to red, red meaning the output clips
private struct LevelMeter: View {
    @ObservedObject var simulation: SimulationController
    private let segments = 12

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !simulation.isRunning)) { _ in
            let level = simulation.outputLevel
            VStack(spacing: 2) {
                ForEach((0..<segments).reversed(), id: \.self) { k in
                    // the top two segments light above full scale
                    let threshold = Double(k + 1) / Double(segments - 2)
                    let lit = level >= threshold * 0.999
                    RoundedRectangle(cornerRadius: 1)
                        .fill(segmentColor(k).opacity(lit ? 1 : 0.15))
                        .frame(width: 16, height: 3.5)
                        .shadow(color: lit ? segmentColor(k).opacity(0.8) : .clear, radius: 2)
                }
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.07)))
            .frame(width: 64, height: 74)
        }
        .help("Output level: red means the sound clips")
    }

    private func segmentColor(_ k: Int) -> Color {
        if k >= segments - 2 { return Color(red: 1, green: 0.25, blue: 0.2) }
        if k >= segments - 4 { return Color(red: 1, green: 0.8, blue: 0.2) }
        return Color(red: 0.3, green: 0.95, blue: 0.4)
    }
}

private struct RegularPolygon: Shape {
    let sides: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        for k in 0..<sides {
            let angle = 2 * Double.pi * Double(k) / Double(sides) - .pi / 2
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if k == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
