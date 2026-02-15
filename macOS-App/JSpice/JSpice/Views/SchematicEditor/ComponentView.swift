import SwiftUI

// MARK: - Component View (renders a single component on the canvas)

struct ComponentView: View {
    let component: SchematicComponent
    let isSelected: Bool
    @ObservedObject var editorState: SchematicEditorState

    private let componentSize: CGFloat = 60
    private let pinRadius: CGFloat = 4

    var body: some View {
        ZStack {
            // Component body
            componentSymbol
                .rotationEffect(.degrees(component.rotation))
                .scaleEffect(x: component.isMirrored ? -1 : 1, y: 1)

            // Pins
            ForEach(Array(component.absolutePinPositions.enumerated()), id: \.offset) { index, position in
                Circle()
                    .fill(pinColor(index: index))
                    .frame(width: pinRadius * 2, height: pinRadius * 2)
                    .offset(
                        x: position.x - component.position.x,
                        y: position.y - component.position.y
                    )
            }

            // Label
            Text(component.label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .offset(y: componentSize / 2 + 10)

            // Value display
            if let valueText = primaryValueText {
                Text(valueText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .offset(y: componentSize / 2 + 22)
            }
        }
        .frame(width: componentSize * 1.5, height: componentSize * 1.5)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                .padding(-4)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Component Symbol

    @ViewBuilder
    private var componentSymbol: some View {
        switch component.type {
        case .resistor:
            ResistorSymbol(size: componentSize)
        case .capacitor:
            CapacitorSymbol(size: componentSize)
        case .inductor:
            InductorSymbol(size: componentSize)
        case .diode:
            DiodeSymbol(size: componentSize)
        case .npnBJT:
            BJTSymbol(size: componentSize, isNPN: true)
        case .pnpBJT:
            BJTSymbol(size: componentSize, isNPN: false)
        case .nmosFET:
            MOSFETSymbol(size: componentSize, isNMOS: true)
        case .pmosFET:
            MOSFETSymbol(size: componentSize, isNMOS: false)
        case .opAmp:
            OpAmpSymbol(size: componentSize)
        case .dcVoltageSource:
            VoltageSourceSymbol(size: componentSize, isAC: false)
        case .acVoltageSource, .signalGenerator:
            VoltageSourceSymbol(size: componentSize, isAC: true)
        case .dcCurrentSource:
            CurrentSourceSymbol(size: componentSize)
        case .ground:
            GroundSymbol(size: componentSize)
        default:
            GenericComponentSymbol(size: componentSize, label: component.type.displayName)
        }
    }

    // MARK: - Pin color

    private func pinColor(index: Int) -> Color {
        let pinID = "\(component.id)_\(index)"
        if editorState.hoveredPinID == pinID {
            return .green
        }
        return .blue.opacity(0.8)
    }

    // MARK: - Value text

    private var primaryValueText: String? {
        switch component.type {
        case .resistor:
            return formatEngineering(component.parameters["resistance"]?.value ?? 1000, unit: "Ω")
        case .capacitor:
            return formatEngineering(component.parameters["capacitance"]?.value ?? 1e-6, unit: "F")
        case .inductor:
            return formatEngineering(component.parameters["inductance"]?.value ?? 1e-3, unit: "H")
        case .dcVoltageSource:
            return formatEngineering(component.parameters["voltage"]?.value ?? 5, unit: "V")
        case .dcCurrentSource:
            return formatEngineering(component.parameters["current"]?.value ?? 0.001, unit: "A")
        case .acVoltageSource:
            let amp = component.parameters["amplitude"]?.value ?? 1
            let freq = component.parameters["frequency"]?.value ?? 1000
            return "\(formatEngineering(amp, unit: "V")) \(formatEngineering(freq, unit: "Hz"))"
        default:
            return nil
        }
    }

    private func formatEngineering(_ value: Double, unit: String) -> String {
        let absValue = abs(value)
        let sign = value < 0 ? "-" : ""

        if absValue >= 1e9 { return "\(sign)\(String(format: "%.1f", absValue / 1e9))G\(unit)" }
        if absValue >= 1e6 { return "\(sign)\(String(format: "%.1f", absValue / 1e6))M\(unit)" }
        if absValue >= 1e3 { return "\(sign)\(String(format: "%.1f", absValue / 1e3))k\(unit)" }
        if absValue >= 1 { return "\(sign)\(String(format: "%.1f", absValue))\(unit)" }
        if absValue >= 1e-3 { return "\(sign)\(String(format: "%.1f", absValue * 1e3))m\(unit)" }
        if absValue >= 1e-6 { return "\(sign)\(String(format: "%.1f", absValue * 1e6))μ\(unit)" }
        if absValue >= 1e-9 { return "\(sign)\(String(format: "%.1f", absValue * 1e9))n\(unit)" }
        if absValue >= 1e-12 { return "\(sign)\(String(format: "%.1f", absValue * 1e12))p\(unit)" }
        return "\(sign)\(String(format: "%.2e", absValue))\(unit)"
    }
}

// MARK: - Component Symbols

struct ResistorSymbol: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            // Zigzag resistor shape
            Path { path in
                let w = size * 0.6
                let h = size * 0.2
                let steps = 6
                let stepWidth = w / CGFloat(steps)
                path.move(to: CGPoint(x: -w/2 - size * 0.15, y: 0))
                path.addLine(to: CGPoint(x: -w/2, y: 0))
                for i in 0..<steps {
                    let x = -w/2 + CGFloat(i) * stepWidth
                    let yDir: CGFloat = i.isMultiple(of: 2) ? -1 : 1
                    path.addLine(to: CGPoint(x: x + stepWidth/2, y: h * yDir))
                    path.addLine(to: CGPoint(x: x + stepWidth, y: 0))
                }
                path.addLine(to: CGPoint(x: w/2 + size * 0.15, y: 0))
            }
            .stroke(Color.primary, lineWidth: 1.5)
        }
    }
}

struct CapacitorSymbol: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            // Two parallel plates
            Path { path in
                let gap: CGFloat = 4
                let plateH = size * 0.4
                // Left wire
                path.move(to: CGPoint(x: -size * 0.35, y: 0))
                path.addLine(to: CGPoint(x: -gap, y: 0))
                // Left plate
                path.move(to: CGPoint(x: -gap, y: -plateH/2))
                path.addLine(to: CGPoint(x: -gap, y: plateH/2))
                // Right plate
                path.move(to: CGPoint(x: gap, y: -plateH/2))
                path.addLine(to: CGPoint(x: gap, y: plateH/2))
                // Right wire
                path.move(to: CGPoint(x: gap, y: 0))
                path.addLine(to: CGPoint(x: size * 0.35, y: 0))
            }
            .stroke(Color.primary, lineWidth: 2)
        }
    }
}

struct InductorSymbol: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Path { path in
                let w = size * 0.6
                let bumps = 4
                let bumpWidth = w / CGFloat(bumps)
                path.move(to: CGPoint(x: -w/2 - size * 0.1, y: 0))
                path.addLine(to: CGPoint(x: -w/2, y: 0))
                for i in 0..<bumps {
                    let x = -w/2 + CGFloat(i) * bumpWidth
                    path.addArc(
                        center: CGPoint(x: x + bumpWidth/2, y: 0),
                        radius: bumpWidth/2,
                        startAngle: .degrees(180),
                        endAngle: .degrees(0),
                        clockwise: true
                    )
                }
                path.addLine(to: CGPoint(x: w/2 + size * 0.1, y: 0))
            }
            .stroke(Color.primary, lineWidth: 1.5)
        }
    }
}

struct DiodeSymbol: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Path { path in
                let triSize = size * 0.25
                // Left wire
                path.move(to: CGPoint(x: -size * 0.35, y: 0))
                path.addLine(to: CGPoint(x: -triSize, y: 0))
                // Triangle
                path.move(to: CGPoint(x: -triSize, y: -triSize))
                path.addLine(to: CGPoint(x: triSize, y: 0))
                path.addLine(to: CGPoint(x: -triSize, y: triSize))
                path.closeSubpath()
                // Bar
                path.move(to: CGPoint(x: triSize, y: -triSize))
                path.addLine(to: CGPoint(x: triSize, y: triSize))
                // Right wire
                path.move(to: CGPoint(x: triSize, y: 0))
                path.addLine(to: CGPoint(x: size * 0.35, y: 0))
            }
            .stroke(Color.primary, lineWidth: 1.5)
        }
    }
}

struct BJTSymbol: View {
    let size: CGFloat
    let isNPN: Bool
    var body: some View {
        ZStack {
            Path { path in
                let r = size * 0.2
                // Base line (vertical)
                path.move(to: CGPoint(x: -r, y: -r))
                path.addLine(to: CGPoint(x: -r, y: r))
                // Base wire
                path.move(to: CGPoint(x: -size * 0.35, y: 0))
                path.addLine(to: CGPoint(x: -r, y: 0))
                // Collector
                path.move(to: CGPoint(x: -r, y: -r * 0.5))
                path.addLine(to: CGPoint(x: r, y: -r * 1.2))
                path.addLine(to: CGPoint(x: r, y: -size * 0.35))
                // Emitter
                path.move(to: CGPoint(x: -r, y: r * 0.5))
                path.addLine(to: CGPoint(x: r, y: r * 1.2))
                path.addLine(to: CGPoint(x: r, y: size * 0.35))
            }
            .stroke(Color.primary, lineWidth: 1.5)

            // Circle outline
            Circle()
                .stroke(Color.primary, lineWidth: 1)
                .frame(width: size * 0.55, height: size * 0.55)
        }
    }
}

struct MOSFETSymbol: View {
    let size: CGFloat
    let isNMOS: Bool
    var body: some View {
        ZStack {
            Path { path in
                let r = size * 0.2
                // Gate
                path.move(to: CGPoint(x: -size * 0.35, y: 0))
                path.addLine(to: CGPoint(x: -r * 1.2, y: 0))
                path.move(to: CGPoint(x: -r * 1.2, y: -r))
                path.addLine(to: CGPoint(x: -r * 1.2, y: r))
                // Channel
                path.move(to: CGPoint(x: -r * 0.6, y: -r))
                path.addLine(to: CGPoint(x: -r * 0.6, y: r))
                // Drain
                path.move(to: CGPoint(x: -r * 0.6, y: -r * 0.6))
                path.addLine(to: CGPoint(x: r, y: -r * 0.6))
                path.addLine(to: CGPoint(x: r, y: -size * 0.35))
                // Source
                path.move(to: CGPoint(x: -r * 0.6, y: r * 0.6))
                path.addLine(to: CGPoint(x: r, y: r * 0.6))
                path.addLine(to: CGPoint(x: r, y: size * 0.35))
            }
            .stroke(Color.primary, lineWidth: 1.5)

            Circle()
                .stroke(Color.primary, lineWidth: 1)
                .frame(width: size * 0.55, height: size * 0.55)
        }
    }
}

struct OpAmpSymbol: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Path { path in
                let triSize = size * 0.35
                // Triangle body
                path.move(to: CGPoint(x: -triSize, y: -triSize))
                path.addLine(to: CGPoint(x: triSize, y: 0))
                path.addLine(to: CGPoint(x: -triSize, y: triSize))
                path.closeSubpath()
            }
            .stroke(Color.primary, lineWidth: 1.5)

            // + and - labels
            Text("+")
                .font(.system(size: 10, weight: .bold))
                .position(x: -size * 0.2, y: -size * 0.12)
            Text("−")
                .font(.system(size: 10, weight: .bold))
                .position(x: -size * 0.2, y: size * 0.12)
        }
    }
}

struct VoltageSourceSymbol: View {
    let size: CGFloat
    let isAC: Bool
    var body: some View {
        ZStack {
            // Circle
            Circle()
                .stroke(Color.primary, lineWidth: 1.5)
                .frame(width: size * 0.4, height: size * 0.4)

            // Wires
            Path { path in
                path.move(to: CGPoint(x: -size * 0.35, y: 0))
                path.addLine(to: CGPoint(x: -size * 0.2, y: 0))
                path.move(to: CGPoint(x: size * 0.2, y: 0))
                path.addLine(to: CGPoint(x: size * 0.35, y: 0))
            }
            .stroke(Color.primary, lineWidth: 1.5)

            if isAC {
                // AC wave symbol
                Path { path in
                    path.move(to: CGPoint(x: -6, y: 0))
                    path.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: -3, y: -6))
                    path.addQuadCurve(to: CGPoint(x: 6, y: 0), control: CGPoint(x: 3, y: 6))
                }
                .stroke(Color.primary, lineWidth: 1.2)
            } else {
                // + and - labels
                Text("+")
                    .font(.system(size: 8, weight: .bold))
                    .offset(x: -5, y: -1)
                Text("−")
                    .font(.system(size: 8, weight: .bold))
                    .offset(x: 5, y: -1)
            }
        }
    }
}

struct CurrentSourceSymbol: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary, lineWidth: 1.5)
                .frame(width: size * 0.4, height: size * 0.4)

            // Arrow
            Path { path in
                path.move(to: CGPoint(x: -8, y: 0))
                path.addLine(to: CGPoint(x: 8, y: 0))
                path.move(to: CGPoint(x: 4, y: -4))
                path.addLine(to: CGPoint(x: 8, y: 0))
                path.addLine(to: CGPoint(x: 4, y: 4))
            }
            .stroke(Color.primary, lineWidth: 1.5)

            // Wires
            Path { path in
                path.move(to: CGPoint(x: -size * 0.35, y: 0))
                path.addLine(to: CGPoint(x: -size * 0.2, y: 0))
                path.move(to: CGPoint(x: size * 0.2, y: 0))
                path.addLine(to: CGPoint(x: size * 0.35, y: 0))
            }
            .stroke(Color.primary, lineWidth: 1.5)
        }
    }
}

struct GroundSymbol: View {
    let size: CGFloat
    var body: some View {
        Path { path in
            let w = size * 0.3
            // Vertical line
            path.move(to: CGPoint(x: 0, y: -size * 0.15))
            path.addLine(to: CGPoint(x: 0, y: 0))
            // Three horizontal lines (decreasing width)
            path.move(to: CGPoint(x: -w, y: 0))
            path.addLine(to: CGPoint(x: w, y: 0))
            path.move(to: CGPoint(x: -w * 0.65, y: 5))
            path.addLine(to: CGPoint(x: w * 0.65, y: 5))
            path.move(to: CGPoint(x: -w * 0.3, y: 10))
            path.addLine(to: CGPoint(x: w * 0.3, y: 10))
        }
        .stroke(Color.primary, lineWidth: 1.5)
    }
}

struct GenericComponentSymbol: View {
    let size: CGFloat
    let label: String
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.primary, lineWidth: 1.5)
                .frame(width: size * 0.5, height: size * 0.35)

            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
    }
}
