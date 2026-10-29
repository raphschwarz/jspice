// Ported from KiCad 10.0.7: what KiCad's rule conditions read of a board's items: pcbnew/pcbexpr_evaluator.cpp
// (PCBEXPR_UCODE::CreateVarRef: A, B, AB, L and null, the property a field names), the properties KiCad's classes
// register for its property manager (common/eda_item.cpp's Type and the KICAD_T names, pcbnew/board_item.cpp,
// board_connected_item.cpp, pcb_track.cpp, pad.cpp, footprint.cpp, zone.cpp, pcb_shape.cpp, pcb_field.cpp,
// common/eda_shape.cpp, common/eda_text.cpp and the rest: their names, types, the enums' names, the properties a
// class masks), common/properties/property_mgr.cpp (GetProperty: names compared without case),
// pcbnew/board_connected_item.cpp (GetEffectiveNetClass, IsConnected), pcbnew/pcb_track.cpp (GetBoundingBox).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// A board item as KiCad's design rules see it (a BOARD_ITEM through the property manager, its parents, its shapes):
/// what conditions, assertions and the rules engine ask of it
final class RuleItem {
    /// KICAD_T, the item types of a board
    enum Kind: Hashable, Sendable {
        case track, arc, via, pad, zone, shape, footprint, field, text, textBox, dimension, table, tableCell, barcode,
             target, generator, group, point, referenceImage

        /// ENUM_MAP<KICAD_T>'s name (an arc's is a track's, a field's a text's)
        var typeName: String {
            switch self {
            case .track, .arc: return "Track"
            case .via: return "Via"
            case .pad: return "Pad"
            case .zone: return "Zone"
            case .shape: return "Graphic"
            case .footprint: return "Footprint"
            case .field, .text: return "Text"
            case .textBox: return "Text Box"
            case .dimension: return "Dimension"
            case .table: return "Table"
            case .tableCell: return "Table Cell"
            case .barcode: return "Barcode"
            case .target: return "Target"
            case .generator: return "Generator"
            case .group: return "Group"
            case .point: return "Point"
            case .referenceImage: return "Reference Image"
            }
        }

        /// A BOARD_CONNECTED_ITEM (what dynamic_cast finds one): tracks, arcs, vias, pads, zones, drawings
        var isConnectedClass: Bool { [.track, .arc, .via, .pad, .zone, .shape].contains(self) }
    }

    /// A net class as an item has it (NETCLASS): its name, and the classes it is made of (one, or several in order)
    struct NetClassRef: Equatable {
        var name: String
        var constituents: [String]
        /// The name of the class each value comes from (its parent), for the implicit rules' names
        var clearanceParent = "Default"
    }

    let kind: Kind
    var uuid: String
    /// BOARD_ITEM::IsConnected: a track, via or pad; a zone that is no rule area; a board drawing on copper
    var connected = false
    /// GetNetCode (-1 for none) and GetNetname
    var netCode = -1
    var netName = ""
    /// GetEffectiveNetClass
    var netClass = NetClassRef(name: "Default", constituents: ["Default"])
    /// GetLayer and GetLayerSet (KiCad's layer ids)
    var layer = KiLayer.undefined
    var layerSet = KiLayerSet()
    /// IsOnCopperLayer
    var isOnCopper = false
    /// The footprint it belongs to (GetParentFootprint)
    var parentFootprint: RuleItem?
    /// The names of the groups it is in, the innermost first (GetParentGroup and on)
    var groups: [String] = []
    /// An item the router made, whose answers KiCad does not keep (ROUTER_TRANSIENT)
    var transient = false
    /// Asked about as its hole (HOLE_PROXY)
    var holeProxy = false
    /// HasHole, HasDrilledHole, and GetEffectiveHoleShape
    var hasHole = false
    var hasDrilledHole = false
    var holeShape: Shape?
    /// GetBoundingBox (its right and bottom one past, as KiCad's [pos, dim) boxes are, where KiCad's are)
    var bbox: IBox? {
        get {
            if bboxCache == nil, let p = bboxProvider {
                bboxCache = p()
                bboxProvider = nil
            }
            return bboxCache
        }
        set { bboxCache = newValue }
    }
    private var bboxCache: IBox?
    /// A footprint's box, made when first asked
    var bboxProvider: (() -> IBox?)?
    /// GetEffectiveShape on a layer, its pieces; nil where the port does not make it
    var effectiveShape: ((Int) -> [Shape]?)?
    /// Whether its effective shape is a compound (its pieces collided as triangles are)
    var compoundShape = false
    /// TransformShapeToPolygon on a layer, the error outside (no clearance); nil where the port does not make it
    var polygon: ((Int) -> PolySet?)?
    /// Its properties' values, by the property's name
    var properties: [String: RulePropertyValue] = [:]
    // a via's
    var viaType: Via.ViaType?
    // a pad's
    var padAttribute: BoardWorld.Pad.Attribute?
    /// GetClearanceOverrides: a pad's own clearance or its footprint's, and where it comes from
    var clearanceOverride: (value: Int, source: String)?
    /// GetLocalClearance: a zone's
    var localClearance: (value: Int, source: String)?
    /// The nets its footprint ties it to (FOOTPRINT::GetNetTieCache)
    var netTieNets: Set<Int> = []
    /// A pad's own zone connection, thermal gap and spoke width (its local overrides), and a footprint's zone
    /// connection
    var zoneConnection = RuleZoneConnection.inherited
    var thermalGapOverride: Int?
    var spokeWidthOverride: Int?
    // a zone's
    var zoneName = ""
    var isRuleArea = false
    var keepoutTracks = false, keepoutVias = false, keepoutPads = false, keepoutZoneFills = false, keepoutFootprints = false
    var isTeardrop = false
    var zoneOutline: PolySet?
    var zoneFilled = false
    /// Its fill on each layer (KiCad's ids)
    var zoneFills: [Int: [LineChain]] = [:]
    var zonePriority = 0
    var zonePadConnection = RuleZoneConnection.thermal
    var zoneThermalGap = 0
    var zoneSpokeWidth = 0
    var zoneMinThickness = 0
    // a footprint's
    var reference = ""
    var fpid = ""
    var flipped = false
    /// FOOTPRINT::GetCourtyard's caches, made when first asked
    var courtyardProvider: (() -> Courtyards)?
    private var courtyardCache: Courtyards?
    var courtyards: Courtyards? {
        get {
            if courtyardCache == nil, let p = courtyardProvider { courtyardCache = p() }
            return courtyardCache
        }
        set { courtyardCache = newValue }
    }
    var sheetName = ""
    var fields: [String: String] = [:]
    /// The index of the footprint (among the board's), for a footprint
    var footprintIndex: Int?

    init(_ kind: Kind, uuid: String) {
        self.kind = kind
        self.uuid = uuid
    }

    /// HasKeepoutParametersSet
    var hasKeepoutParameters: Bool { keepoutTracks || keepoutVias || keepoutPads || keepoutFootprints || keepoutZoneFills }

    /// isKeepoutZone( item, checkFlags ) of the rules engine
    var isKeepoutZone: Bool { kind == .zone && isRuleArea && hasKeepoutParameters }
}

/// The board the rules are evaluated on: its layers and their names, its nets, its zones and footprints (for the
/// functions that look them up), its epsilon and error, and what the port could not evaluate as KiCad does
final class RuleBoard {
    let copperLayers: Int
    /// GetEnabledLayers
    var enabledLayers: KiLayerSet
    /// The user names of its layers (the layer map's second entries)
    var userLayerNames: [Int: String] = [:]
    var netNames: Set<String> = []
    /// Its zones, rule areas among them, the board's then each footprint's
    var zones: [RuleItem] = []
    var footprints: [RuleItem] = []
    var epsilon = 500
    var maxError = 5000
    /// Whether its project assigns component classes (which the port does not)
    var hasComponentClasses = false
    /// What the port could not evaluate as KiCad does
    var unsupported: Set<String> = []
    /// The items locked (BOARD_ITEM::IsLocked), and the drawings' and texts' widths (EDA_SHAPE::GetRectangleWidth,
    /// which is 0 but for a rectangle; EDA_TEXT::GetTextWidth), by uuid
    var lockedItems: Set<String> = []
    var itemWidths: [String: Int] = [:]
    private var layerExpressionCache: [String: KiLayerSet] = [:]
    /// Deflated outlines of areas, by uuid (getDeflatedZoneOutline)
    var deflatedOutlines: [String: PolySet] = [:]
    /// m_IntersectsAreaCache: whether an item collides with an area on a layer, as first asked (by intersectsArea or
    /// intersectsKeepout, which share it: which of the two asked it is kept too)
    struct AreaKey: Hashable {
        let area: ObjectIdentifier, item: ObjectIdentifier
        let layer: Int
    }
    var intersectsAreaCache: [AreaKey: (collides: Bool, forKeepout: Bool)] = [:]

    init(copperLayers: Int, enabledLayers: KiLayerSet) {
        self.copperLayers = copperLayers
        self.enabledLayers = enabledLayers
    }

    /// The layers whose canonical or user name matches a pattern (m_LayerExpressionCache)
    func layersMatching(_ pattern: String) -> KiLayerSet {
        if let m = layerExpressionCache[pattern] { return m }
        var mask = KiLayerSet()
        for l in 0..<KiLayer.count {
            if WildMatch.matches(KiLayer.name(l), pattern) || (userLayerNames[l].map { WildMatch.matches($0, pattern) } ?? false) {
                mask.insert(l)
            }
        }
        layerExpressionCache[pattern] = mask
        return mask
    }

    /// FindNet
    func findNet(_ name: String) -> Bool { netNames.contains(name) }
}

// MARK: - Properties

/// The properties conditions read (PROPERTY_MANAGER's, as KiCad's classes register them): the names KiCad knows,
/// the types its variable references take them as, and, for those the port reads, which item types have them and
/// how each reads
enum RuleProperties {
    /// Every property name KiCad's board item classes register (lower case)
    static let known: Set<String> = Set([
        "Allow Teardrops To Span Two Tracks", "Angle", "Arrow Direction", "Associated Layer", "Auto Thickness",
        "Automatically Update Net", "Back covering", "Back plugging", "Back Post-machining", "Back Post-machining Angle",
        "Back Post-machining Depth", "Back Post-machining Size", "Back tenting", "Backdrill Mode", "Barcode Type",
        "Best Length Ratio", "Best Width Ratio", "Bold", "Border", "Border Color", "Border Style", "Border Width",
        "Bottom Backdrill Must-Cut", "Bottom Backdrill Size", "Bottom Counterbore Depth", "Bottom Countersink Angle",
        "Bottom Post-machining", "Bottom Post-machining Size", "Capping", "Cell Separators", "Center X", "Center Y",
        "Clearance", "Clearance Override", "Color", "Column Width", "Component Class", "Copper Layers", "Corner Radius",
        "Corner Radius %", "Corner Radius Ratio", "Corner Radius Size", "Crossbar Height", "Curved Teardrops",
        "Diameter", "Do not Populate", "Enable", "Enable Teardrops", "End X", "End Y", "Error Correction",
        "Exclude From Bill of Materials", "Exclude From Position Files", "Exempt From Courtyard Requirement",
        "Extension Line Overshoot", "External Border", "Fabrication Property", "Fill", "Fill Color", "Fill Mode",
        "Filling", "Font", "Front covering", "Front plugging", "Front Post-machining", "Front Post-machining Angle",
        "Front Post-machining Depth", "Front Post-machining Size", "Front tenting", "Hatch Gap",
        "Hatch Minimum Hole Ratio", "Hatch Orientation", "Hatch Width", "Header Border", "Height", "Hole",
        "Hole Shape", "Hole Size X", "Hole Size Y", "Horizontal Justification", "Hyperlink", "Initial Side", "Italic",
        "Keep Aligned with Dimension", "Keep Out Footprints", "Keep Out Pads", "Keep Out Tracks", "Keep Out Vias",
        "Keep Out Zone Fills", "Keep Upright", "Keywords", "Knockout", "Layer", "Layer Bottom", "Layer Top",
        "Leader Length", "Library Description", "Library Link", "Line Color", "Line Style", "Line Width", "Locked",
        "Margin Bottom", "Margin Left", "Margin Right", "Margin Top", "Margin X", "Margin Y", "Max Amplitude",
        "Max Length", "Max Width", "Max Width Ratio", "Min Amplitude", "Min Spacing", "Minimum Island Area",
        "Minimum Width", "Mirrored", "Name", "Net", "Net Class", "NetClass", "NetName", "Not in Schematic",
        "Number Box", "Orientation", "Override Custom Rules", "Override Text", "Pad Connections", "Pad Number",
        "Pad Shape", "Pad To Die Delay", "Pad To Die Length", "Pad Type", "Parent", "Pin Name", "Pin Type",
        "Position X", "Position Y", "Precision", "Prefer Zone Connections", "Prefix", "Priority", "Radius",
        "Reference", "Remove Islands", "Rounded", "Row Height", "Row Separators", "Scale", "Separators Color",
        "Separators Style", "Separators Width", "Shape", "Show Text", "Single-sided", "Size", "Size X", "Size Y",
        "Smoothing Amount", "Smoothing Effort", "Soldermask", "Soldermask Margin Override",
        "Solderpaste Margin Override", "Solderpaste Margin Ratio Override", "Source Name", "Source Type", "Start X",
        "Start Y", "Suffix", "Suppress Trailing Zeroes", "Target Delay", "Target Length", "Target Skew",
        "Target Skew Delay", "Text", "Text Frame", "Text Size", "Thermal Relief Gap", "Thermal Relief Spoke Angle",
        "Thermal Relief Spoke Width", "Thermal Spoke Template", "Thickness", "Top Backdrill Must-Cut",
        "Top Backdrill Size", "Top Counterbore Depth", "Top Countersink Angle", "Top Post-machining",
        "Top Post-machining Size", "Transform Offset X", "Transform Offset Y", "Tuning Mode", "Type", "Units",
        "Units Format", "Update Order", "Vertical Justification", "Via Type", "Visible", "Width",
        "Zone Connection Style",
    ].map { $0.lowercased() })

    /// A property the port reads: its name, the type KiCad's variable references take it as, the item types that
    /// have it, and how it reads of each (nil where the port does not read it)
    struct Property {
        let name: String
        let type: RuleValue.VarType
        let isEnum: Bool
        let optional: Bool
        let kinds: Set<RuleItem.Kind>
        let reader: (RuleItem, RuleContext) -> RulePropertyValue?

        func read(_ item: RuleItem, _ ctx: RuleContext) -> RulePropertyValue? { reader(item, ctx) }
    }

    /// The item types a BOARD_ITEM's property is on (all of them), less those that mask it
    private static let allKinds: Set<RuleItem.Kind> = [.track, .arc, .via, .pad, .zone, .shape, .footprint, .field, .text, .textBox,
                                                        .dimension, .table, .tableCell, .barcode, .target, .generator, .group,
                                                        .point, .referenceImage]

    private static func stored(_ name: String) -> (RuleItem, RuleContext) -> RulePropertyValue? {
        { item, _ in item.properties[name] }
    }

    static let supported: [String: Property] = {
        var m: [String: Property] = [:]
        func add(_ p: Property) { m[p.name.lowercased()] = p }
        // BOARD_ITEM's Layer: masked on pads and vias (a pad's reads its footprint's), a zone's its one layer
        add(Property(name: "Layer", type: .string, isEnum: true, optional: false,
                     kinds: allKinds.subtracting([.pad, .via, .tableCell]),
                     reader: { item, _ in
                         switch item.kind {
                         case .track, .arc, .shape, .footprint, .field, .text, .zone: return .layer(item.layer)
                         default: return nil
                         }
                     }))
        add(Property(name: "Locked", type: .numeric, isEnum: false, optional: false, kinds: allKinds.subtracting([.pad]),
                     reader: { item, ctx in
                         if let v = item.properties["Locked"] { return v }
                         guard let board = ctx.board else { return nil }
                         return .bool(board.lockedItems.contains(item.uuid))
                     }))
        add(Property(name: "Width", type: .numeric, isEnum: false, optional: false,
                     kinds: [.track, .arc, .shape, .field, .text, .barcode, .referenceImage, .target, .generator],
                     reader: { item, ctx in
                         switch item.kind {
                         case .track, .arc: return item.properties["Width"]
                         case .shape, .field, .text:
                             if let v = item.properties["Width"] { return v }
                             return ctx.board?.itemWidths[item.uuid].map { .int($0) }
                         default: return nil
                         }
                     }))
        add(Property(name: "Via Type", type: .string, isEnum: true, optional: false, kinds: [.via], reader: stored("Via Type")))
        add(Property(name: "Diameter", type: .numeric, isEnum: false, optional: false, kinds: [.via], reader: stored("Diameter")))
        add(Property(name: "Hole", type: .numeric, isEnum: false, optional: false, kinds: [.via], reader: stored("Hole")))
        for name in ["Pad Type", "Pad Shape", "Fabrication Property"] {
            add(Property(name: name, type: .string, isEnum: true, optional: false, kinds: [.pad], reader: stored(name)))
        }
        for name in ["Pad Number", "Pin Name", "Pin Type"] {
            add(Property(name: name, type: .string, isEnum: false, optional: false, kinds: [.pad], reader: stored(name)))
        }
        for name in ["Size X", "Size Y", "Hole Size X", "Hole Size Y"] {
            add(Property(name: name, type: .numeric, isEnum: false, optional: false, kinds: [.pad], reader: stored(name)))
        }
        add(Property(name: "Reference", type: .string, isEnum: false, optional: false, kinds: [.footprint], reader: stored("Reference")))
        add(Property(name: "Library Link", type: .string, isEnum: false, optional: false, kinds: [.footprint],
                     reader: stored("Library Link")))
        add(Property(name: "Name", type: .string, isEnum: false, optional: false, kinds: [.field, .group, .zone],
                     reader: { item, _ in item.kind == .zone ? .string(item.zoneName) : item.properties["Name"] }))
        add(Property(name: "Priority", type: .numeric, isEnum: false, optional: false, kinds: [.zone],
                     reader: { item, _ in .int(item.zonePriority) }))
        add(Property(name: "Net Class", type: .string, isEnum: false, optional: false,
                     kinds: [.track, .arc, .via, .pad, .zone, .shape], reader: { item, _ in .string(item.netClass.name) }))
        return m
    }()

    /// The vref types of the properties the port does not read, as KiCad's union of its classes' would make them
    /// (only whether KiCad knows the name matters for those: reading one is not supported)
    static func lookup(_ property: String, _ kind: RuleItem.Kind) -> Property? {
        if let p = supported[property] { return p.kinds.contains(kind) ? p : nil }
        guard known.contains(property) else { return nil }
        // (a property KiCad has that the port does not read: unsupported wherever it is asked)
        return Property(name: property, type: .string, isEnum: false, optional: false, kinds: allKinds, reader: { _, _ in nil })
    }

    /// PCBEXPR_UCODE::CreateVarRef: the reference an item name and a field make, nil for an item KiCad does not know
    /// ("Unrecognized item"), one of type VT_PARSE_ERROR for a property it does not ("Unrecognized property")
    static func makeVarRef(_ variable: String, _ field: String) -> RuleVarRef? {
        if variable.lowercased() == "null" {
            let v = RuleVarRef(.property, 0)
            v.type = .null
            return v
        }
        let specials: [(String, RuleVarRef.Kind)] = [("netclass", .netClass), ("componentclass", .componentClass),
                                                      ("netname", .netName), ("type", .type)]
        for (name, kind) in specials where field.lowercased() == name {
            if variable == "A" { return RuleVarRef(kind, 0) }
            if variable == "B" { return RuleVarRef(kind, 1) }
            return nil
        }
        let index: Int
        switch variable {
        case "A", "AB": index = 0
        case "B": index = 1
        case "L": index = 2
        default: return nil
        }
        let vref = RuleVarRef(.property, index)
        if field.isEmpty { return vref }
        var name = field.replacingOccurrences(of: "_", with: " ").lowercased()
        if name == "origin x" { name = "start x" } else if name == "origin y" { name = "start y" }
        vref.property = name
        if let p = supported[name] {
            vref.type = p.type
            vref.isEnum = p.isEnum
            vref.isOptional = p.optional
        } else if known.contains(name) {
            vref.type = .string
        } else {
            vref.type = .parseError
        }
        return vref
    }
}

extension RuleItem {
    /// PCB_TRACK::GetBoundingBox of a track: its ends' box out to its width's half rounded up, one more right and
    /// below
    static func trackBox(_ a: IPoint, _ b: IPoint, width: Int) -> IBox {
        let r = (width + 1) / 2
        return IBox(minX: min(a.x, b.x) - r, minY: min(a.y, b.y) - r, maxX: max(a.x, b.x) + r + 1, maxY: max(a.y, b.y) + r + 1)
    }

    /// PCB_TRACK::GetBoundingBox of an arc: its effective shape's box, out to its width's half rounded up again
    static func arcBox(_ shapeBox: IBox, width: Int) -> IBox {
        let r = (width + 1) / 2
        return IBox(minX: shapeBox.minX - r, minY: shapeBox.minY - r, maxX: shapeBox.maxX + r + 1, maxY: shapeBox.maxY + r + 1)
    }

    /// PCB_VIA::GetBoundingBox
    static func viaBox(_ c: IPoint, diameter: Int) -> IBox {
        let r = (diameter + 1) / 2
        return IBox(minX: c.x - r, minY: c.y - r, maxX: c.x + r + 1, maxY: c.y + r + 1)
    }
}
