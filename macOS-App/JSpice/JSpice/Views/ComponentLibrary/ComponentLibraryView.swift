import SwiftUI

// MARK: - Component Library (Left Sidebar)

struct ComponentLibraryView: View {
    @ObservedObject var editorState: SchematicEditorState
    @Binding var document: CircuitDocument
    @State private var searchText = ""
    @State private var expandedCategories: Set<String> = Set(ComponentCategory.allCases.map(\.rawValue))

    private var filteredCategories: [(ComponentCategory, [ComponentType])] {
        ComponentCategory.allCases.compactMap { category in
            let components = category.components.filter { type in
                searchText.isEmpty || type.displayName.localizedCaseInsensitiveContains(searchText)
            }
            return components.isEmpty ? nil : (category, components)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Components", systemImage: "cpu")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search components...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.quaternary)
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // Component categories
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredCategories, id: \.0) { category, components in
                        CategorySection(
                            category: category,
                            components: components,
                            isExpanded: expandedCategories.contains(category.rawValue),
                            onToggle: {
                                if expandedCategories.contains(category.rawValue) {
                                    expandedCategories.remove(category.rawValue)
                                } else {
                                    expandedCategories.insert(category.rawValue)
                                }
                            },
                            onAddComponent: { type in
                                addComponentToCanvas(type)
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(.ultraThinMaterial)
    }

    private func addComponentToCanvas(_ type: ComponentType) {
        let position = CGPoint(
            x: 200 - editorState.panOffset.width / editorState.zoom,
            y: 200 - editorState.panOffset.height / editorState.zoom
        )
        var component = SchematicComponent(type: type, position: position)

        // Auto-label
        let prefix: String
        switch type {
        case .resistor: prefix = "R"
        case .capacitor: prefix = "C"
        case .inductor: prefix = "L"
        case .diode: prefix = "D"
        case .npnBJT, .pnpBJT: prefix = "Q"
        case .nmosFET, .pmosFET: prefix = "M"
        case .dcVoltageSource, .acVoltageSource: prefix = "V"
        case .dcCurrentSource: prefix = "I"
        default: prefix = "X"
        }
        let count = document.components.filter { $0.type == type }.count
        component.label = "\(prefix)\(count + 1)"

        document.addComponent(component)
        editorState.selectComponent(component.id)
    }
}

// MARK: - Category Section

struct CategorySection: View {
    let category: ComponentCategory
    let components: [ComponentType]
    let isExpanded: Bool
    let onToggle: () -> Void
    let onAddComponent: (ComponentType) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Category header
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    Image(systemName: category.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(category.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Text("\(components.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .cornerRadius(4)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(components) { type in
                    ComponentLibraryItem(type: type, onAdd: onAddComponent)
                }
            }
        }
    }
}

// MARK: - Component Library Item

struct ComponentLibraryItem: View {
    let type: ComponentType
    let onAdd: (ComponentType) -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Component icon
            Image(systemName: type.symbolName)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(type.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                Text("\(type.pinCount) pins")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // Quick-add button
            if isHovered {
                Button(action: { onAdd(type) }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.accentColor)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.leading, 24)
        .padding(.vertical, 4)
        .background(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
        .cornerRadius(4)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onDrag {
            NSItemProvider(object: type.rawValue as NSString)
        }
    }
}
