import SwiftUI

// MARK: - Editor State

@MainActor
final class SchematicEditorState: ObservableObject {
    @Published var selectedComponentIDs: Set<UUID> = []
    @Published var selectedWireIDs: Set<UUID> = []
    @Published var zoom: CGFloat = 1.0
    @Published var panOffset: CGSize = .zero
    @Published var isDraggingComponent: Bool = false
    @Published var isDrawingWire: Bool = false
    @Published var wireStartPoint: WireEndpoint?
    @Published var currentMousePosition: CGPoint = .zero
    @Published var draggedComponentType: ComponentType?
    @Published var hoveredPinID: String?

    struct WireEndpoint {
        let componentID: UUID
        let pinIndex: Int
        let position: CGPoint
    }

    var selectedComponentID: UUID? {
        selectedComponentIDs.count == 1 ? selectedComponentIDs.first : nil
    }

    func selectComponent(_ id: UUID, addToSelection: Bool = false) {
        if addToSelection {
            selectedComponentIDs.insert(id)
        } else {
            selectedComponentIDs = [id]
        }
        selectedWireIDs.removeAll()
    }

    func selectWire(_ id: UUID) {
        selectedWireIDs = [id]
        selectedComponentIDs.removeAll()
    }

    func clearSelection() {
        selectedComponentIDs.removeAll()
        selectedWireIDs.removeAll()
    }
}

// MARK: - Schematic Editor View

struct SchematicEditorView: View {
    @Binding var document: CircuitDocument
    @ObservedObject var editorState: SchematicEditorState
    @State private var dragOffset: CGSize = .zero
    @State private var componentDragStart: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background grid
                GridBackgroundView(
                    zoom: editorState.zoom,
                    offset: editorState.panOffset
                )

                // Canvas content (components + wires)
                canvasContent
                    .scaleEffect(editorState.zoom)
                    .offset(editorState.panOffset)
            }
            .clipped()
            .contentShape(Rectangle())
            // Pan gesture
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        if !editorState.isDraggingComponent && !editorState.isDrawingWire {
                            editorState.panOffset = CGSize(
                                width: editorState.panOffset.width + value.translation.width - dragOffset.width,
                                height: editorState.panOffset.height + value.translation.height - dragOffset.height
                            )
                            dragOffset = value.translation
                        }
                    }
                    .onEnded { _ in
                        dragOffset = .zero
                    }
            )
            // Zoom gesture
            .onScrollGesture { delta in
                let zoomDelta = delta > 0 ? 1.05 : 0.95
                editorState.zoom = max(0.1, min(5.0, editorState.zoom * zoomDelta))
            }
            // Click to deselect
            .onTapGesture {
                editorState.clearSelection()
            }
            // Drop target for components from library
            .onDrop(of: [.text], isTargeted: nil) { providers, location in
                handleDrop(providers: providers, at: location, in: geometry)
            }
            // Keyboard shortcuts
            .onDeleteCommand {
                deleteSelected()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Canvas Content

    @ViewBuilder
    private var canvasContent: some View {
        // Wires (drawn first, behind components)
        ForEach(document.wires) { wire in
            WireView(
                wire: wire,
                document: document,
                isSelected: editorState.selectedWireIDs.contains(wire.id)
            )
            .onTapGesture {
                editorState.selectWire(wire.id)
            }
        }

        // Wire being drawn
        if editorState.isDrawingWire, let start = editorState.wireStartPoint {
            WirePreviewView(
                from: start.position,
                to: editorState.currentMousePosition
            )
        }

        // Components
        ForEach(document.components) { component in
            ComponentView(
                component: component,
                isSelected: editorState.selectedComponentIDs.contains(component.id),
                editorState: editorState
            )
            .position(component.position)
            .gesture(componentDragGesture(for: component))
            .onTapGesture {
                editorState.selectComponent(component.id)
            }
        }
    }

    // MARK: - Component Drag

    private func componentDragGesture(for component: SchematicComponent) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if componentDragStart == nil {
                    componentDragStart = component.position
                }
                editorState.isDraggingComponent = true
                if let index = document.components.firstIndex(where: { $0.id == component.id }),
                   let startPos = componentDragStart {
                    // Use translation relative to drag start, scaled by zoom
                    let newPosition = CGPoint(
                        x: startPos.x + value.translation.width / editorState.zoom,
                        y: startPos.y + value.translation.height / editorState.zoom
                    )
                    document.components[index].position = snapToGrid(newPosition)
                }
            }
            .onEnded { _ in
                componentDragStart = nil
                editorState.isDraggingComponent = false
            }
    }

    // MARK: - Drop handling

    private func handleDrop(providers: [NSItemProvider], at location: CGPoint, in geometry: GeometryProxy) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.text", options: nil) { data, _ in
                guard let data = data as? Data,
                      let typeString = String(data: data, encoding: .utf8),
                      let componentType = ComponentType(rawValue: typeString) else { return }

                Task { @MainActor in
                    let canvasPoint = screenToCanvas(location, in: geometry)
                    var newComponent = SchematicComponent(
                        type: componentType,
                        position: snapToGrid(canvasPoint)
                    )
                    newComponent = assignUniqueLabel(newComponent, in: document)
                    document.addComponent(newComponent)
                    editorState.selectComponent(newComponent.id)
                }
            }
        }
        return true
    }

    // MARK: - Helpers

    private func snapToGrid(_ point: CGPoint, gridSize: CGFloat = 10) -> CGPoint {
        CGPoint(
            x: round(point.x / gridSize) * gridSize,
            y: round(point.y / gridSize) * gridSize
        )
    }

    private func screenToCanvas(_ point: CGPoint, in geometry: GeometryProxy) -> CGPoint {
        CGPoint(
            x: (point.x - editorState.panOffset.width) / editorState.zoom,
            y: (point.y - editorState.panOffset.height) / editorState.zoom
        )
    }

    private func deleteSelected() {
        for id in editorState.selectedComponentIDs {
            document.removeComponent(id: id)
        }
        for id in editorState.selectedWireIDs {
            document.removeWire(id: id)
        }
        editorState.clearSelection()
    }

    private func assignUniqueLabel(_ component: SchematicComponent, in document: CircuitDocument) -> SchematicComponent {
        let prefix: String
        switch component.type {
        case .resistor: prefix = "R"
        case .capacitor: prefix = "C"
        case .inductor: prefix = "L"
        case .diode: prefix = "D"
        case .npnBJT, .pnpBJT: prefix = "Q"
        case .nmosFET, .pmosFET: prefix = "M"
        case .opAmp: prefix = "U"
        case .dcVoltageSource, .acVoltageSource: prefix = "V"
        case .dcCurrentSource: prefix = "I"
        case .signalGenerator: prefix = "SIG"
        case .vcvs, .vccs, .ccvs, .cccs: prefix = "E"
        case .ground: prefix = "GND"
        }

        let existingCount = document.components.filter { $0.type == component.type }.count
        var modified = component
        modified.label = "\(prefix)\(existingCount + 1)"
        return modified  // Note: This creates a new copy since SchematicComponent is a struct
    }
}

// MARK: - Scroll Gesture Extension

extension View {
    func onScrollGesture(action: @escaping (CGFloat) -> Void) -> some View {
        self.background(ScrollGestureView(action: action))
    }
}

struct ScrollGestureView: NSViewRepresentable {
    let action: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollCaptureNSView {
        let view = ScrollCaptureNSView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: ScrollCaptureNSView, context: Context) {
        nsView.action = action
    }
}

class ScrollCaptureNSView: NSView {
    var action: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        action?(event.deltaY)
    }
}
