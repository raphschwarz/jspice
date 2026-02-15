import SwiftUI

// MARK: - Grid Background

struct GridBackgroundView: View {
    let zoom: CGFloat
    let offset: CGSize

    private let minorGridSize: CGFloat = 10
    private let majorGridInterval: Int = 5

    var body: some View {
        Canvas { context, size in
            let scaledGrid = minorGridSize * zoom

            // Don't render grid if too zoomed out
            guard scaledGrid > 3 else { return }

            let offsetX = offset.width.truncatingRemainder(dividingBy: scaledGrid)
            let offsetY = offset.height.truncatingRemainder(dividingBy: scaledGrid)

            let cols = Int(size.width / scaledGrid) + 2
            let rows = Int(size.height / scaledGrid) + 2

            let startCol = -Int(offset.width / scaledGrid) - 1
            let startRow = -Int(offset.height / scaledGrid) - 1

            // Minor grid dots
            if scaledGrid > 6 {
                for col in 0..<cols {
                    for row in 0..<rows {
                        let gridCol = startCol + col
                        let gridRow = startRow + row
                        let isMajor = gridCol.isMultiple(of: majorGridInterval) &&
                                       gridRow.isMultiple(of: majorGridInterval)

                        if !isMajor {
                            let x = CGFloat(col) * scaledGrid + offsetX
                            let y = CGFloat(row) * scaledGrid + offsetY

                            let rect = CGRect(
                                x: x - 0.5,
                                y: y - 0.5,
                                width: 1,
                                height: 1
                            )
                            context.fill(
                                Path(ellipseIn: rect),
                                with: .color(.secondary.opacity(0.2))
                            )
                        }
                    }
                }
            }

            // Major grid dots
            let majorGrid = scaledGrid * CGFloat(majorGridInterval)
            let majorOffsetX = offset.width.truncatingRemainder(dividingBy: majorGrid)
            let majorOffsetY = offset.height.truncatingRemainder(dividingBy: majorGrid)
            let majorCols = Int(size.width / majorGrid) + 2
            let majorRows = Int(size.height / majorGrid) + 2

            for col in 0..<majorCols {
                for row in 0..<majorRows {
                    let x = CGFloat(col) * majorGrid + majorOffsetX
                    let y = CGFloat(row) * majorGrid + majorOffsetY

                    let dotSize: CGFloat = 2
                    let rect = CGRect(
                        x: x - dotSize / 2,
                        y: y - dotSize / 2,
                        width: dotSize,
                        height: dotSize
                    )
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(.secondary.opacity(0.4))
                    )
                }
            }

            // Origin crosshair
            let originX = offset.width
            let originY = offset.height
            if originX > -20 && originX < size.width + 20 &&
               originY > -20 && originY < size.height + 20 {
                var crosshair = Path()
                crosshair.move(to: CGPoint(x: originX - 10, y: originY))
                crosshair.addLine(to: CGPoint(x: originX + 10, y: originY))
                crosshair.move(to: CGPoint(x: originX, y: originY - 10))
                crosshair.addLine(to: CGPoint(x: originX, y: originY + 10))
                context.stroke(crosshair, with: .color(.secondary.opacity(0.5)), lineWidth: 0.5)
            }
        }
    }
}

// MARK: - Wire Views

struct WireView: View {
    let wire: Wire
    let document: CircuitDocument
    let isSelected: Bool

    var body: some View {
        Path { path in
            guard let startComponent = document.component(withID: wire.startComponentID),
                  let endComponent = document.component(withID: wire.endComponentID) else { return }

            let startPins = startComponent.absolutePinPositions
            let endPins = endComponent.absolutePinPositions

            guard wire.startPinIndex < startPins.count,
                  wire.endPinIndex < endPins.count else { return }

            let start = startPins[wire.startPinIndex]
            let end = endPins[wire.endPinIndex]

            path.move(to: start)

            if wire.waypoints.isEmpty {
                // Orthogonal routing: go horizontal then vertical
                let midX = (start.x + end.x) / 2
                path.addLine(to: CGPoint(x: midX, y: start.y))
                path.addLine(to: CGPoint(x: midX, y: end.y))
            } else {
                for waypoint in wire.waypoints {
                    path.addLine(to: waypoint)
                }
            }

            path.addLine(to: end)
        }
        .stroke(
            isSelected ? Color.accentColor : Color.primary,
            style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1.5, lineCap: .round, lineJoin: .round)
        )
    }
}

struct WirePreviewView: View {
    let from: CGPoint
    let to: CGPoint

    var body: some View {
        Path { path in
            path.move(to: from)
            // Orthogonal routing preview
            let midX = (from.x + to.x) / 2
            path.addLine(to: CGPoint(x: midX, y: from.y))
            path.addLine(to: CGPoint(x: midX, y: to.y))
            path.addLine(to: to)
        }
        .stroke(
            Color.accentColor.opacity(0.6),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [5, 3])
        )
    }
}
