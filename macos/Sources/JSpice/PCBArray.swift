import AppKit
import SwiftUI
import KiCadKit
import KiCadRouter

extension PCBEditing {
    /// Create Array (KiCad's Ctrl+T): its sheet opened for the items selected, with the dialog's defaults (a 5 by 5
    /// grid at 2.54 mm; a circle of 4 at 90° about the pointer)
    func openArray(footprints: Set<String>) {
        let uuids = selectedItems(footprints: footprints)
        guard !uuids.isEmpty, !isRouting else { return NSSound.beep() }
        editorSheet = .array(ArrayOptions(.grid(.init(columns: 5, rows: 5, spacing: KiCadPoint(2.54, 2.54)))), items: uuids)
    }

    /// The array made of `items` (or the items arranged in it), as one change ("Create Array", "Arrange selection")
    func createArray(_ options: ArrayOptions, items: [String]) {
        Task { if await place({ $0.createArray(items, options: options) }) == false { NSSound.beep() } }
    }
}

/// Create Array, as KiCad's dialog asks for one: a grid (counts, spacings, offsets, a stagger by rows or columns,
/// centred on the items or starting at them) or a circle (its centre, how many, the angle between them or a full
/// circle, the first's angle, which way round, the items turned with it or not); the items copied into it or
/// themselves arranged in it; the copies' references kept or made unique
struct PCBArraySheet: View {
    @ObservedObject var editing: PCBEditing
    let items: [String]
    @State private var circular: Bool
    @State private var columns: Int
    @State private var rows: Int
    @State private var spacingX: Double
    @State private var spacingY: Double
    @State private var offsetX: Double
    @State private var offsetY: Double
    @State private var stagger: Int
    @State private var staggerRows: Bool
    @State private var centred: Bool
    @State private var centreX: Double
    @State private var centreY: Double
    @State private var count: Int
    @State private var angle: Double
    @State private var fullCircle = false
    @State private var angleOffset: Double
    @State private var clockwise: Bool
    @State private var rotateItems: Bool
    @State private var arrange: Bool
    @State private var uniqueReferences: Bool
    @Environment(\.dismiss) private var dismiss

    init(editing: PCBEditing, options: ArrayOptions, items: [String]) {
        self.editing = editing
        self.items = items
        let grid: ArrayOptions.Grid, circle: ArrayOptions.Circular
        switch options.layout {
        case .grid(let g):
            grid = g
            circle = .init(centre: editing.pointer.map(PCBEditing.onGrid) ?? .zero, count: 4, angle: 90)
            _circular = State(initialValue: false)
        case .circular(let c):
            grid = .init(columns: 5, rows: 5, spacing: KiCadPoint(2.54, 2.54))
            circle = c
            _circular = State(initialValue: true)
        }
        _columns = State(initialValue: grid.columns)
        _rows = State(initialValue: grid.rows)
        _spacingX = State(initialValue: grid.spacing.x)
        _spacingY = State(initialValue: grid.spacing.y)
        _offsetX = State(initialValue: grid.offset.x)
        _offsetY = State(initialValue: grid.offset.y)
        _stagger = State(initialValue: grid.stagger)
        _staggerRows = State(initialValue: grid.staggerRows)
        _centred = State(initialValue: grid.centred)
        _centreX = State(initialValue: circle.centre.x)
        _centreY = State(initialValue: circle.centre.y)
        _count = State(initialValue: circle.count)
        _angle = State(initialValue: circle.angle)
        _angleOffset = State(initialValue: circle.angleOffset)
        _clockwise = State(initialValue: circle.clockwise)
        _rotateItems = State(initialValue: circle.rotateItems)
        _arrange = State(initialValue: options.arrange)
        _uniqueReferences = State(initialValue: options.uniqueReferences)
    }

    /// The options as the dialog's OK takes them (a full circle's angle 360° over the count)
    private var options: ArrayOptions {
        let layout: ArrayOptions.Layout
        if circular {
            layout = .circular(.init(centre: KiCadPoint(centreX, centreY), count: count,
                                     angle: fullCircle ? 360 / Double(max(count, 1)) : angle, angleOffset: angleOffset,
                                     clockwise: clockwise, rotateItems: rotateItems))
        } else {
            layout = .grid(.init(columns: columns, rows: rows, spacing: KiCadPoint(spacingX, spacingY),
                                 offset: KiCadPoint(offsetX, offsetY), stagger: stagger, staggerRows: staggerRows,
                                 centred: centred))
        }
        return ArrayOptions(layout, arrange: arrange, uniqueReferences: uniqueReferences)
    }

    /// Counts that make no array (KiCad's dialog takes any number; the port makes none of fewer than one place)
    private var problem: String? {
        if circular ? count < 1 : columns < 1 || rows < 1 { return "The counts must be at least 1." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Array").font(.headline)
            Picker("", selection: $circular) {
                Text("Grid Array").tag(false)
                Text("Circular Array").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Grid(alignment: .leading, verticalSpacing: 6) {
                if circular {
                    numberRow("Center position X", $centreX, "mm")
                    numberRow("Center position Y", $centreY, "mm")
                    countRow("Item count", $count)
                    GridRow {
                        Text("Angle between items")
                        HStack(spacing: 4) {
                            TextField("", value: $angle, format: .number.precision(.fractionLength(0...4))).frame(width: 80)
                                .disabled(fullCircle)
                            Text("°").foregroundStyle(.secondary)
                            Toggle("Full circle", isOn: $fullCircle)
                        }
                    }
                    numberRow("First item angle", $angleOffset, "°")
                    GridRow {
                        Text("Direction")
                        Picker("", selection: $clockwise) {
                            Text("Clockwise").tag(true)
                            Text("Counterclockwise").tag(false)
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }
                    GridRow {
                        Text("")
                        Toggle("Rotate items", isOn: $rotateItems)
                    }
                } else {
                    countRow("Horizontal count", $columns)
                    countRow("Vertical count", $rows)
                    numberRow("Horizontal spacing", $spacingX, "mm")
                    numberRow("Vertical spacing", $spacingY, "mm")
                    numberRow("Horizontal offset", $offsetX, "mm")
                    numberRow("Vertical offset", $offsetY, "mm")
                    countRow("Stagger", $stagger)
                    GridRow {
                        Text("Stagger by")
                        Picker("", selection: $staggerRows) {
                            Text("Rows").tag(true)
                            Text("Columns").tag(false)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    GridRow {
                        Text("Position")
                        Picker("", selection: $centred) {
                            Text("Source items remain in place").tag(false)
                            Text("Centre on source items").tag(true)
                        }
                        .labelsHidden()
                        .frame(width: 240)
                    }
                }
            }
            Picker("", selection: $arrange) {
                Text("Duplicate selection").tag(false)
                Text("Arrange selection").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .help("Copies of the items placed in the array, or the items themselves arranged in it (as many as it has places, in the order they were selected)")
            Picker("", selection: $uniqueReferences) {
                Text("Keep existing reference designators").tag(false)
                Text("Assign unique reference designators").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(arrange)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { editing.editorSheet = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    guard problem == nil else { return NSSound.beep() }
                    let made = options
                    editing.editorSheet = nil
                    dismiss()
                    editing.createArray(made, items: items)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func numberRow(_ title: String, _ value: Binding<Double>, _ unit: String) -> some View {
        GridRow {
            Text(title)
            HStack(spacing: 4) {
                TextField("", value: value, format: .number.precision(.fractionLength(0...4))).frame(width: 80)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }

    private func countRow(_ title: String, _ value: Binding<Int>) -> some View {
        GridRow {
            Text(title)
            TextField("", value: value, format: .number).frame(width: 80)
        }
    }
}
