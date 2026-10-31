import AppKit
import SwiftUI
import KiCadKit
import KiCadRouter

/// The properties sheet open (E, as KiCad's Properties): a zone's or rule area's, a footprint's, or a pad's, with the
/// properties as the dialog shows them when it opens
enum PCBPropertiesSheet: Identifiable {
    case zone(String, ZoneProperties)
    case footprint(String, FootprintProperties)
    case pad(String, PadProperties)

    var id: String {
        switch self {
        case .zone(let uuid, _), .footprint(let uuid, _), .pad(let uuid, _): return uuid
        }
    }
}

// MARK: - Properties and locks

extension PCBEditing {
    /// The properties sheet opened (E): the selected zone's; else, `atPointer`, the pad under the pointer (of the
    /// footprint selected, or of any while none is); else the one footprint selected, or the one under the pointer
    func editProperties(footprints: Set<String>, atPointer: Bool = true) {
        guard !isRouting, !isDragging else { return }
        let zone = zoneSelection, at = atPointer ? pointer : nil
        Task {
            await settled()
            if !isReady { await prepareNow() }
            if let zone {
                guard let p = await engine.run({ $0.zoneProperties(zone) }), !p.isTeardrop else { return NSSound.beep() }
                propertiesSheet = .zone(zone, p)
                return
            }
            if let at, let found = await engine.run({ s -> (pad: String, owner: String)? in
                guard let pad = s.pad(at: at), let fp = s.board.footprints.first(where: { $0.pads.contains { $0.uuid == pad } }) else { return nil }
                return (pad, fp.uuid)
            }), footprints.isEmpty || footprints == [found.owner] {
                // (a pad of a padstack of its own by layer, which JSpice does not edit: refused)
                let pad = found.pad
                guard let p = await engine.run({ $0.padProperties(pad) }) else { return NSSound.beep() }
                propertiesSheet = .pad(pad, p)
                return
            }
            var footprint = footprints.count == 1 ? footprints.first : nil
            if footprint == nil, footprints.isEmpty, let at { footprint = controller?.picture?.footprint(at: at)?.uuid }
            guard let footprint, let p = await engine.run({ $0.footprintProperties(footprint) }) else { return }
            propertiesSheet = .footprint(footprint, p)
        }
    }

    /// What the zone properties dialog would refuse in `p` (its message), nil for nothing
    func zonePropertiesProblem(_ uuid: String, _ p: ZoneProperties) async -> String? {
        await engine.run { $0.zonePropertiesProblem(uuid, p) }
    }

    func footprintPropertiesProblem(_ uuid: String, _ p: FootprintProperties) async -> String? {
        await engine.run { $0.footprintPropertiesProblem(uuid, p) }
    }

    func padPropertiesProblem(_ uuid: String, _ p: PadProperties) async -> String? {
        await engine.run { $0.padPropertiesProblem(uuid, p) }
    }

    /// A field added to the footprint's, as the dialog's Add Field adds one (row `row`)
    func newFootprintField(_ uuid: String, row: Int) async -> FootprintProperties.Field? {
        await engine.run { $0.newFootprintField(uuid, row: row) }
    }

    /// The sheet's properties set as its dialog's OK sets them, as one change ("Edit Zone Properties", "Edit
    /// Footprint Properties", "Edit Pad Properties"), the board's zones filled again
    func applyProperties(_ sheet: PCBPropertiesSheet) {
        propertiesSheet = nil
        Task {
            let refilled = RefillMark()
            let made = await place { session -> BoardEditing.Edit? in
                let edit: BoardEditing.Edit?
                switch sheet {
                case .zone(let uuid, let p): edit = session.setZoneProperties(uuid, p)
                case .footprint(let uuid, let p): edit = session.setFootprintProperties(uuid, p)
                case .pad(let uuid, let p): edit = session.setPadProperties(uuid, p)
                }
                refilled.value = edit?.refilled ?? true
                return edit
            }
            if made && !refilled.value { await fillZonesNow() }
            await refreshZoneOutline()
        }
    }

    /// The items selected (tracks, vias, texts, `footprints`, the zone) locked, or unlocked where all of them are, as
    /// KiCad's Toggle Lock (L) does it, as one change ("Lock", "Unlock")
    func toggleLock(footprints: Set<String>) {
        var uuids = selection.union(footprints)
        if let zone = zoneSelection { uuids.insert(zone) }
        guard !uuids.isEmpty, !isRouting else { return }
        Task {
            if await place({ $0.toggleLocked(uuids) }) == false { NSSound.beep() }
            await refreshZoneOutline()
        }
    }

    /// The select tool's keys for zones, properties and locks: E properties, L lock, F1 (or Insert) a zone's corner
    /// created at the pointer, Esc a zone's drag dropped (or the zone deselected, the rest of Esc going on); whether
    /// the key was taken
    func propertiesKey(_ press: KeyPress, footprints: Set<String>) -> Bool {
        guard tool == .select, !isRouting else { return false }
        let f1 = Character(UnicodeScalar(NSF1FunctionKey)!), insert = Character(UnicodeScalar(NSInsertFunctionKey)!)
        if press.key == .escape {
            if zoneDrag != nil {
                cancelZoneDrag()
                return true
            }
            deselectZone()
            return false
        }
        if press.key.character == f1 || press.key.character == insert {
            guard zoneSelection != nil else { return false }
            addZoneCorner()
            return true
        }
        switch press.characters.lowercased() {
        case "e":
            editProperties(footprints: footprints)
            return true
        case "l":
            toggleLock(footprints: footprints)
            return true
        default:
            return false
        }
    }
}

/// Whether the change made on the session's queue filled the zones again (set there, read here once it is done)
private final class RefillMark: @unchecked Sendable {
    var value = true
}

/// The select tool's buttons for the zone or footprint selected: its properties, and its lock; the sheets they open
struct PCBPropertiesBar: View {
    @ObservedObject var editing: PCBEditing

    var body: some View {
        HStack(spacing: 8) {
            if editing.tool == .select && (editing.zoneSelection != nil || editing.footprintSelection.count == 1) {
                Button("Properties…") { editing.editProperties(footprints: editing.footprintSelection, atPointer: false) }
                    .help(editing.zoneSelection != nil
                          ? "The zone's properties, as KiCad's zone properties dialog sets them (E; E over a pad, the pad's)"
                          : "The footprint's properties, as KiCad's footprint properties dialog sets them (E; E over a pad, the pad's)")
            }
            if editing.tool == .select && (editing.zoneSelection != nil || !editing.footprintSelection.isEmpty || !editing.selection.isEmpty) {
                Button("Toggle Lock") { editing.toggleLock(footprints: editing.footprintSelection) }
                    .help("The items selected locked (or unlocked, where all are), as KiCad's Toggle Lock (L): a locked item is not moved, dragged or deleted")
            }
            Color.clear.frame(width: 0, height: 0)
                .sheet(item: $editing.propertiesSheet) { sheet in
                    switch sheet {
                    case .zone(let uuid, let p): PCBZonePropertiesSheet(editing: editing, uuid: uuid, p: p)
                    case .footprint(let uuid, let p): PCBFootprintPropertiesSheet(editing: editing, uuid: uuid, p: p)
                    case .pad(let uuid, let p): PCBPadPropertiesSheet(editing: editing, uuid: uuid, p: p)
                    }
                }
        }
    }
}

// MARK: - The sheets

/// A length (mm) typed into a sheet
private struct PCBLengthField: View {
    let title: String
    @Binding var value: Double
    var unit = "mm"

    var body: some View {
        GridRow {
            Text(title)
            HStack(spacing: 4) {
                TextField("", value: $value, format: .number.precision(.fractionLength(0...4))).frame(width: 80)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}

/// A length (mm) a sheet may leave unset (empty: as the footprint, the board's rules or KiCad say)
private struct PCBOptionalLengthField: View {
    let title: String
    @Binding var value: Double?
    var unit = "mm"

    var body: some View {
        GridRow {
            Text(title)
            HStack(spacing: 4) {
                TextField("", value: $value, format: .number.precision(.fractionLength(0...4))).frame(width: 80)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}

/// A sheet's foot: what its dialog would refuse, and Cancel and OK (checked first, as the dialog checks)
private struct PCBSheetButtons: View {
    @ObservedObject var editing: PCBEditing
    let problem: String?
    let ok: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let problem {
            Text(problem).font(.caption).foregroundStyle(.red)
        }
        HStack {
            Spacer()
            Button("Cancel") { editing.propertiesSheet = nil; dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("OK", action: ok)
                .keyboardShortcut(.defaultAction)
        }
    }
}

private let zoneConnectionTitles: [(ZoneConnection, String)] = [(.full, "Solid"), (.thermal, "Thermal reliefs"),
                                                                 (.thtThermal, "Reliefs for plated holes only"), (.none, "None")]

/// A zone's or rule area's properties, as KiCad's zone properties dialogs show and set them
struct PCBZonePropertiesSheet: View {
    @ObservedObject var editing: PCBEditing
    let uuid: String
    @State var p: ZoneProperties
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(p.isRuleArea ? "Rule Area Properties" : "Copper Zone Properties").font(.headline)
            HStack(alignment: .top, spacing: 24) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Name")
                        TextField("", text: $p.name).frame(width: 160)
                    }
                    if !p.isRuleArea {
                        GridRow {
                            Text("Net")
                            Picker("", selection: $p.net) {
                                Text("<no net>").tag(String?.none)
                                ForEach(editing.nets, id: \.self) { Text($0).tag(String?.some($0)) }
                            }
                            .labelsHidden().frame(width: 160)
                        }
                        GridRow {
                            Text("Priority")
                            Stepper(value: $p.priority, in: 0...1000) { Text("\(p.priority)") }
                        }
                    }
                    GridRow {
                        Text("Layers")
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(editing.layers, id: \.self) { layer in
                                Toggle(PCBEditBar.title(layer), isOn: Binding(
                                    get: { p.layers.contains(layer) },
                                    set: { on in p.layers = editing.layers.filter { $0 == layer ? on : p.layers.contains($0) } }))
                            }
                        }
                    }
                    GridRow {
                        Text("")
                        Toggle("Locked", isOn: $p.locked)
                    }
                }
                if p.isRuleArea { ruleArea } else { copperZone }
            }
            PCBSheetButtons(editing: editing, problem: problem) {
                let p = p
                Task {
                    problem = await editing.zonePropertiesProblem(uuid, p)
                    if problem == nil { editing.applyProperties(.zone(uuid, p)) }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620)
    }

    private var copperZone: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            PCBLengthField(title: "Clearance", value: $p.clearance)
            PCBLengthField(title: "Minimum width", value: $p.minWidth)
            GridRow {
                Text("Pad connections")
                Picker("", selection: $p.padConnection) {
                    ForEach(zoneConnectionTitles, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().fixedSize()
            }
            PCBLengthField(title: "Thermal relief gap", value: $p.thermalGap)
            PCBLengthField(title: "Thermal spoke width", value: $p.spokeWidth)
            GridRow {
                Text("Fill")
                Picker("", selection: $p.hatched) {
                    Text("Solid").tag(false)
                    Text("Hatched").tag(true)
                }
                .labelsHidden().fixedSize()
            }
            if p.hatched {
                PCBLengthField(title: "Hatch width", value: $p.hatchThickness)
                PCBLengthField(title: "Hatch gap", value: $p.hatchGap)
                PCBLengthField(title: "Hatch orientation", value: $p.hatchOrientation, unit: "°")
                GridRow {
                    Text("Smoothing effort")
                    Picker("", selection: $p.hatchSmoothingLevel) {
                        ForEach(0..<4) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                PCBLengthField(title: "Smoothing amount", value: $p.hatchSmoothingValue, unit: "")
                PCBLengthField(title: "Remove holes smaller than", value: $p.hatchHoleMinArea, unit: "of a hole")
            }
            GridRow {
                Text("Remove islands")
                Picker("", selection: $p.islandRemoval) {
                    Text("Always").tag(ZoneProperties.IslandRemoval.always)
                    Text("Never").tag(ZoneProperties.IslandRemoval.never)
                    Text("Below area limit").tag(ZoneProperties.IslandRemoval.area)
                }
                .labelsHidden().fixedSize()
            }
            if p.islandRemoval == .area {
                PCBLengthField(title: "Minimum island area", value: $p.minIslandArea, unit: "mm²")
            }
            GridRow {
                Text("Corner smoothing")
                Picker("", selection: $p.smoothing) {
                    Text("None").tag(ZoneProperties.Smoothing.none)
                    Text("Chamfer").tag(ZoneProperties.Smoothing.chamfer)
                    Text("Fillet").tag(ZoneProperties.Smoothing.fillet)
                }
                .labelsHidden().fixedSize()
            }
            if p.smoothing != .none {
                PCBLengthField(title: p.smoothing == .chamfer ? "Chamfer" : "Fillet radius", value: $p.cornerRadius)
            }
            outlineDisplay
        }
    }

    private var ruleArea: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Keep out")
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Tracks", isOn: $p.keepout.tracks)
                    Toggle("Vias", isOn: $p.keepout.vias)
                    Toggle("Pads", isOn: $p.keepout.pads)
                    Toggle("Copper zones", isOn: $p.keepout.copperPour)
                    Toggle("Footprints", isOn: $p.keepout.footprints)
                }
            }
            GridRow {
                Text("Placement")
                Toggle("Place footprints of", isOn: $p.placementEnabled)
            }
            if p.placementEnabled {
                GridRow {
                    Text("")
                    Picker("", selection: $p.placementSource) {
                        Text("Sheet").tag(ZoneProperties.PlacementSource.sheetname)
                        Text("Component class").tag(ZoneProperties.PlacementSource.componentClass)
                        Text("Group").tag(ZoneProperties.PlacementSource.group)
                    }
                    .labelsHidden().fixedSize()
                }
                GridRow {
                    Text("")
                    TextField("", text: $p.placementSourceName).frame(width: 160)
                }
            }
            outlineDisplay
        }
    }

    @ViewBuilder private var outlineDisplay: some View {
        GridRow {
            Text("Outline display")
            Picker("", selection: $p.borderStyle) {
                Text("Line").tag(ZoneProperties.BorderStyle.none)
                Text("Hatched").tag(ZoneProperties.BorderStyle.edge)
                Text("Fully hatched").tag(ZoneProperties.BorderStyle.full)
            }
            .labelsHidden().fixedSize()
        }
        if p.borderStyle != .none {
            PCBLengthField(title: "Outline hatch pitch", value: $p.borderHatchPitch)
        }
    }
}

/// The layers a footprint's field may be on, as the dialog's grid offers them
private let fieldLayers = ["F.SilkS", "B.SilkS", "F.Fab", "B.Fab", "F.Cu", "B.Cu", "F.CrtYd", "B.CrtYd", "F.Mask", "B.Mask",
                           "Dwgs.User", "Cmts.User", "Eco1.User", "Eco2.User"]

/// A footprint's properties, as KiCad's footprint properties dialog shows and sets them: its fields (the grid), its
/// place, side and lock, its attributes, and its clearances
struct PCBFootprintPropertiesSheet: View {
    @ObservedObject var editing: PCBEditing
    let uuid: String
    @State var p: FootprintProperties
    @State private var problem: String?

    /// The fields KiCad keeps on every footprint, which cannot be renamed or deleted
    private static let mandatory: Set<String> = ["Reference", "Value", "Datasheet", "Description", "Footprint"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Footprint Properties").font(.headline)
            fields
            HStack {
                Button("Add Field") {
                    Task { if let f = await editing.newFootprintField(uuid, row: p.fields.count) { p.fields.append(f) } }
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 24) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    PCBLengthField(title: "Position X", value: $p.position.x)
                    PCBLengthField(title: "Position Y", value: $p.position.y)
                    PCBLengthField(title: "Orientation", value: $p.orientation, unit: "°")
                    GridRow {
                        Text("Side")
                        Picker("", selection: $p.onBack) {
                            Text("Front").tag(false)
                            Text("Back").tag(true)
                        }
                        .labelsHidden().fixedSize()
                    }
                    GridRow {
                        Text("")
                        Toggle("Locked", isOn: $p.locked)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Component type")
                        Picker("", selection: $p.mounting) {
                            Text("Through hole").tag(FootprintProperties.Mounting.throughHole)
                            Text("SMD").tag(FootprintProperties.Mounting.smd)
                            Text("Unspecified").tag(FootprintProperties.Mounting.unspecified)
                        }
                        .labelsHidden().fixedSize()
                    }
                    GridRow {
                        Text("")
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Not in schematic", isOn: $p.boardOnly)
                            Toggle("Exclude from position files", isOn: $p.excludeFromPositionFiles)
                            Toggle("Exclude from bill of materials", isOn: $p.excludeFromBOM)
                            Toggle("Do not populate", isOn: $p.doNotPopulate)
                            Toggle("Allow bridged solder mask apertures", isOn: $p.allowSolderMaskBridges)
                        }
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    PCBOptionalLengthField(title: "Pad clearance", value: $p.clearance)
                    PCBOptionalLengthField(title: "Solder mask margin", value: $p.solderMaskMargin)
                    PCBOptionalLengthField(title: "Solder paste margin", value: $p.solderPasteMargin)
                    PCBOptionalLengthField(title: "Solder paste ratio", value: Binding(
                        get: { p.solderPasteRatio.map { $0 * 100 } }, set: { p.solderPasteRatio = $0.map { $0 / 100 } }), unit: "%")
                    GridRow {
                        Text("Zone connection")
                        Picker("", selection: $p.zoneConnection) {
                            Text("From the board's rules").tag(ZoneConnection.inherited)
                            Text("Solid").tag(ZoneConnection.full)
                            Text("Thermal reliefs").tag(ZoneConnection.thermal)
                            Text("None").tag(ZoneConnection.none)
                        }
                        .labelsHidden().fixedSize()
                    }
                }
            }
            Text("Empty clearances and margins are the pads' own, or the board's rules'.")
                .font(.caption).foregroundStyle(.secondary)
            PCBSheetButtons(editing: editing, problem: problem) {
                let p = p
                Task {
                    problem = await editing.footprintPropertiesProblem(uuid, p)
                    if problem == nil { editing.applyProperties(.footprint(uuid, p)) }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 900)
    }

    private var fields: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    ForEach(["Name", "Text", "Shown", "Width", "Height", "Pen", "Italic", "Layer", "X", "Y", "Angle", "Upright", "Knockout", ""], id: \.self) {
                        Text($0).foregroundStyle(.secondary)
                    }
                }
                ForEach(p.fields.indices, id: \.self) { i in
                    GridRow {
                        TextField("", text: $p.fields[i].name).frame(width: 90)
                            .disabled(Self.mandatory.contains(p.fields[i].name) && p.fields[i].uuid != nil)
                        TextField("", text: $p.fields[i].text).frame(width: 140)
                        Toggle("", isOn: $p.fields[i].visible).labelsHidden()
                        TextField("", value: $p.fields[i].width, format: .number.precision(.fractionLength(0...4))).frame(width: 56)
                        TextField("", value: $p.fields[i].height, format: .number.precision(.fractionLength(0...4))).frame(width: 56)
                        TextField("auto", value: $p.fields[i].thickness, format: .number.precision(.fractionLength(0...4))).frame(width: 56)
                        Toggle("", isOn: $p.fields[i].italic).labelsHidden()
                        Picker("", selection: $p.fields[i].layer) {
                            ForEach(Array(Set(fieldLayers + [p.fields[i].layer])).sorted(), id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(width: 100)
                        TextField("", value: $p.fields[i].offset.x, format: .number.precision(.fractionLength(0...4))).frame(width: 64)
                        TextField("", value: $p.fields[i].offset.y, format: .number.precision(.fractionLength(0...4))).frame(width: 64)
                        TextField("", value: $p.fields[i].angle, format: .number.precision(.fractionLength(0...2))).frame(width: 52)
                        Toggle("", isOn: $p.fields[i].keepUpright).labelsHidden()
                        Toggle("", isOn: $p.fields[i].knockout).labelsHidden()
                        Button { p.fields.remove(at: i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .disabled(Self.mandatory.contains(p.fields[i].name) && p.fields[i].uuid != nil)
                    }
                }
            }
        }
        .frame(minHeight: 120, maxHeight: 220)
    }
}

/// A pad's properties, as KiCad's pad properties dialog shows and sets them (a pad on the back seen from the front,
/// as the dialog shows it)
struct PCBPadPropertiesSheet: View {
    @ObservedObject var editing: PCBEditing
    let uuid: String
    @State var p: PadProperties
    @State private var problem: String?

    private static let types: [(PadProperties.PadType, String)] = [(.throughHole, "Through-hole"), (.smd, "SMD"),
                                                                    (.connector, "Edge connector"), (.npth, "NPTH, mechanical"),
                                                                    (.aperture, "SMD aperture")]
    private static let shapes: [(PadProperties.Shape, String)] = [(.circle, "Circular"), (.oval, "Oval"), (.rect, "Rectangular"),
                                                                   (.trapezoid, "Trapezoidal"), (.roundrect, "Rounded rectangle"),
                                                                   (.chamferedRect, "Chamfered rectangle"),
                                                                   (.chamferedRoundRect, "Chamfered with other corners rounded"),
                                                                   (.customCircle, "Custom (circular base)"), (.customRect, "Custom (rectangular base)")]
    private static let properties: [(String?, String)] = [(nil, "None"), ("pad_prop_bga", "BGA pad"), ("pad_prop_fiducial_glob", "Fiducial, global to board"),
                                                          ("pad_prop_fiducial_loc", "Fiducial, local to footprint"), ("pad_prop_testpoint", "Test point pad"),
                                                          ("pad_prop_heatsink", "Heatsink pad"), ("pad_prop_castellated", "Castellated pad"),
                                                          ("pad_prop_mechanical", "Mechanical pad"), ("pad_prop_pressfit", "Press-fit pad")]

    /// The copper layers' choices the pad's type has, as the dialog's (updatePadLayersList)
    private var copperChoices: [(PadProperties.CopperLayers, String)] {
        switch p.type {
        case .throughHole:
            return [(.all, "All copper layers"), (.outerAndConnected, "Front, back and connected layers"),
                    (.connectedOnly, "Connected layers only"), (.none, "None")]
        case .npth:
            return [(.frontAndBack, "Front and back layers"), (.front, "Front layer"), (.back, "Back layer"), (.none, "None")]
        case .smd, .connector:
            return [(.front, "Front layer"), (.back, "Back layer")]
        case .aperture:
            return [(.none, "None")]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pad Properties").font(.headline)
            HStack(alignment: .top, spacing: 24) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Pad type")
                        Picker("", selection: $p.type) {
                            ForEach(Self.types, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .labelsHidden().fixedSize()
                        .onChange(of: p.type) { _, _ in
                            if !copperChoices.contains(where: { $0.0 == p.copperLayers }) { p.copperLayers = copperChoices[0].0 }
                        }
                    }
                    GridRow {
                        Text("Pad number")
                        TextField("", text: $p.number).frame(width: 100).disabled(p.type == .npth)
                    }
                    GridRow {
                        Text("Net")
                        Picker("", selection: $p.net) {
                            Text("<no net>").tag(String?.none)
                            ForEach(editing.nets, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        .labelsHidden().frame(width: 160).disabled(p.type == .npth)
                    }
                    GridRow {
                        Text("Shape")
                        Picker("", selection: $p.shape) {
                            ForEach(Self.shapes, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    PCBLengthField(title: "Position X", value: $p.position.x)
                    PCBLengthField(title: "Position Y", value: $p.position.y)
                    PCBLengthField(title: "Size X", value: $p.size.x)
                    PCBLengthField(title: "Size Y", value: $p.size.y)
                    PCBLengthField(title: "Orientation", value: $p.orientation, unit: "°")
                    if p.shape == .trapezoid {
                        PCBLengthField(title: "Trapezoid delta", value: $p.trapezoidDelta)
                        GridRow {
                            Text("")
                            Picker("", selection: $p.trapezoidAlongY) {
                                Text("Along X").tag(false)
                                Text("Along Y").tag(true)
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                    if [.roundrect, .chamferedRoundRect].contains(p.shape) {
                        PCBLengthField(title: "Corner size", value: Binding(get: { p.cornerRatio * 100 }, set: { p.cornerRatio = $0 / 100 }), unit: "%")
                    }
                    if [.chamferedRect, .chamferedRoundRect].contains(p.shape) {
                        PCBLengthField(title: "Chamfer size", value: Binding(get: { p.chamferRatio * 100 }, set: { p.chamferRatio = $0 / 100 }), unit: "%")
                        GridRow {
                            Text("Chamfered")
                            HStack {
                                ForEach([(PadProperties.Corner.topLeft, "Top left"), (.topRight, "Top right"),
                                         (.bottomLeft, "Bottom left"), (.bottomRight, "Bottom right")], id: \.0) { corner, title in
                                    Toggle(title, isOn: Binding(get: { p.chamferedCorners.contains(corner) },
                                                                set: { if $0 { p.chamferedCorners.insert(corner) } else { p.chamferedCorners.remove(corner) } }))
                                }
                            }
                        }
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    if p.type == .throughHole || p.type == .npth {
                        GridRow {
                            Text("Hole")
                            Picker("", selection: $p.oblongHole) {
                                Text("Circular").tag(false)
                                Text("Oval").tag(true)
                            }
                            .labelsHidden().fixedSize()
                        }
                        PCBLengthField(title: p.oblongHole ? "Hole size X" : "Hole diameter", value: $p.drill.x)
                        if p.oblongHole { PCBLengthField(title: "Hole size Y", value: $p.drill.y) }
                    }
                    GridRow {
                        Text("Offset")
                        Toggle("Shape offset from hole", isOn: Binding(get: { p.offset != nil },
                                                                       set: { p.offset = $0 ? (p.offset ?? .zero) : nil }))
                    }
                    if p.offset != nil {
                        PCBLengthField(title: "Offset X", value: Binding(get: { p.offset?.x ?? 0 }, set: { p.offset?.x = $0 }))
                        PCBLengthField(title: "Offset Y", value: Binding(get: { p.offset?.y ?? 0 }, set: { p.offset?.y = $0 }))
                    }
                    GridRow {
                        Text("Copper layers")
                        Picker("", selection: $p.copperLayers) {
                            ForEach(copperChoices, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    GridRow {
                        Text("Technical layers")
                        LazyVGrid(columns: [GridItem(.fixed(110)), GridItem(.fixed(110))], alignment: .leading, spacing: 2) {
                            ForEach(PadProperties.technicalLayerNames, id: \.self) { layer in
                                Toggle(layer, isOn: Binding(get: { p.technicalLayers.contains(layer) },
                                                            set: { if $0 { p.technicalLayers.insert(layer) } else { p.technicalLayers.remove(layer) } }))
                            }
                        }
                    }
                    GridRow {
                        Text("Fabrication property")
                        Picker("", selection: $p.fabricationProperty) {
                            ForEach(Self.properties, id: \.1) { Text($0.1).tag($0.0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    PCBOptionalLengthField(title: "Pad clearance", value: $p.clearance)
                    PCBOptionalLengthField(title: "Solder mask margin", value: $p.solderMaskMargin)
                    PCBOptionalLengthField(title: "Solder paste margin", value: $p.solderPasteMargin)
                    PCBOptionalLengthField(title: "Solder paste ratio", value: Binding(
                        get: { p.solderPasteRatio.map { $0 * 100 } }, set: { p.solderPasteRatio = $0.map { $0 / 100 } }), unit: "%")
                    GridRow {
                        Text("Zone connection")
                        Picker("", selection: $p.zoneConnection) {
                            Text("From the footprint").tag(ZoneConnection.inherited)
                            Text("Solid").tag(ZoneConnection.full)
                            Text("Thermal reliefs").tag(ZoneConnection.thermal)
                            Text("None").tag(ZoneConnection.none)
                        }
                        .labelsHidden().fixedSize()
                    }
                    PCBOptionalLengthField(title: "Thermal relief gap", value: $p.thermalGap)
                    PCBOptionalLengthField(title: "Thermal spoke width", value: $p.thermalSpokeWidth)
                    PCBLengthField(title: "Thermal spoke angle", value: $p.thermalSpokeAngle, unit: "°")
                }
            }
            Text("Empty clearances, margins and thermal settings are the footprint's, or the board's rules'.")
                .font(.caption).foregroundStyle(.secondary)
            PCBSheetButtons(editing: editing, problem: problem) {
                let p = p
                Task {
                    problem = await editing.padPropertiesProblem(uuid, p)
                    if problem == nil { editing.applyProperties(.pad(uuid, p)) }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 1000)
    }
}
