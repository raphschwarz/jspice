import Foundation

/// What is true of a kind of part across JSpice: the facts that are otherwise spread over the library, the simulator,
/// the schematic layout, the boards and the exports, gathered in one place to be asked and checked.
///
/// Nothing is decided here. Each fact is read from the function that decides it, and the decisions that used to hide
/// in a `default:` arm are each one exhaustive switch beside the code that uses them, so the compiler asks about a new
/// kind there: `Breadboard.mount`, `Pacing.role`, `SpiceNetlist.exportForm`, `SchematicLayout.flow`,
/// `KiCadNetlist.footprint`. `PartCatalogTests` checks the facts against each other and against what the code does
/// with a part of each kind; macos/docs/adding-a-part.md lists the places to touch.
public struct PartFacts: Sendable {
    /// How the simulator runs the part (see `Circuit.flattened`)
    public enum Simulation: Sendable, Equatable {
        /// By equations of its own in `Simulator`
        case direct
        /// As a small circuit of other parts put in its place (a tube's capacitances, a transformer's windings, a
        /// microphone's, the audio chips'), with its default parameters
        case expanded
        /// As another kind of part: a loop probe as a 0 V source
        case asAnotherPart
        /// As its block's parts
        case block
    }

    /// Where the part goes on a stripboard or a perfboard (which takes the stripboard's layout)
    public enum StripboardPlace: Sendable, Equatable {
        case onBoard
        /// A control on the panel, wired to the board (`Stripboard.onPanel`)
        case onPanel
        /// Wired from off the board, as on a breadboard
        case offBoard
        case notAPart
    }

    /// What the part is in a KiCad netlist (`KiCadNetlist.export`)
    public enum KiCadFootprint: Sendable, Equatable {
        /// A footprint from KiCad's libraries
        case footprint(String)
        /// None that JSpice knows: left for KiCad's footprint assignment (`Export.unassigned`)
        case unassigned
        /// Wired from off the board, on a pin header of this many pins
        case header(pins: Int)
        /// Not in the netlist
        case none
    }

    /// How the app's `SymbolRenderer` draws it (decided there by an exhaustive switch; this is the same choice made
    /// from the part's package, for the engine's tests)
    public enum Symbol: Sendable, Equatable {
        /// The generic chip body: a box with its package's pins down its sides
        case chipBody
        /// A symbol of its own (a resistor's zigzag, an op-amp's triangle, a 555's box)
        case ownSymbol
    }

    public let kind: ElementKind
    /// Offered in the library and the quick-add palette
    public let isPlaceable: Bool
    public let displayName: String
    public let namePrefix: String
    public let category: ElementCategory
    /// "R", or "⇧U"; nil for a part picked only from the library or the palette
    public let shortcutLabel: String?
    /// The terminals' names in the order of `Element.posts` (a block's come from its ports: none here)
    public let terminalNames: [String]
    public let params: [ParamSpec]
    public let models: [PartModel]
    public let simulation: Simulation
    /// Where `Pacing` takes its time scales from
    public let pacing: Pacing.Role
    /// How `SchematicLayout` places it
    public let layout: SchematicLayout.Flow
    /// How the breadboard takes it when its model has no package
    public let breadboard: Breadboard.Mount
    /// The chip package its default model goes in on a board ("TL072", "CD4013"), if any
    public let breadboardPackage: String?
    public let stripboard: StripboardPlace
    public let kicad: KiCadFootprint
    public let spice: SpiceNetlist.ExportForm
    public let symbol: Symbol

    public var terminalCount: Int { terminalNames.count }

    /// A breadboard puts it in its holes (in two holes, its legs in a row, or in a chip package)
    public var hasBreadboardFootprint: Bool {
        breadboard == .twoLead || breadboard == .inline || breadboardPackage != nil
    }

    /// The export writes it into the deck (as a device, as equations or as a subcircuit)
    public var exportsToSpice: Bool { spice == .device || spice == .equations || spice == .subcircuit }

    public init(_ kind: ElementKind) {
        self.kind = kind
        isPlaceable = kind.isPlaceable
        displayName = kind.displayName
        namePrefix = kind.namePrefix
        category = kind.category
        shortcutLabel = kind.shortcutLabel
        terminalNames = kind.terminalNames
        params = kind.params
        models = kind.models
        pacing = Pacing.role(of: kind)
        layout = SchematicLayout.flow(kind)
        breadboard = Breadboard.mount(kind)
        spice = SpiceNetlist.exportForm(kind)
        // (a block's box comes from its ports)
        symbol = kind == .block || (kind.chipPackage != nil && kind != .timer555) ? .chipBody : .ownSymbol

        let element = Element(kind: kind, name: kind.namePrefix + "1", a: .zero, b: kind.defaultOffset)
        if kind == .block {
            simulation = .block
        } else {
            let flat = Circuit(elements: [element]).flattened()
            simulation = flat.elements.count > 1 ? .expanded : flat.elements.first?.kind != kind ? .asAnotherPart : .direct
        }

        let part = NetlistPart(kind: kind, name: element.name, connections: Dictionary(
            kind.terminalNames.enumerated().map { ($0.element, "n\($0.offset)") }, uniquingKeysWith: { a, _ in a }))
        let package = Breadboard.package(part)
        breadboardPackage = package?.title
        switch breadboard {
        case .notAPart: stripboard = .notAPart
        case _ where Stripboard.onPanel.contains(kind): stripboard = .onPanel
        case .twoLead, .inline: stripboard = .onBoard
        case .chip, .offBoard: stripboard = package != nil ? .onBoard : .offBoard
        }

        func footprint(_ text: String) -> KiCadFootprint { text.isEmpty ? .unassigned : .footprint(text) }
        if let package {
            kicad = .footprint(KiCadNetlist.dip(package.pins))
        } else {
            switch breadboard {
            case .twoLead:
                let (style, title, _) = Breadboard.describe(part, [:])
                kicad = footprint(KiCadNetlist.footprint(style, part, title: title))
            case .inline:
                let (_, style, title, _) = Breadboard.inline(part, facing: "")
                kicad = footprint(KiCadNetlist.footprint(style, part, title: title))
            case .chip, .offBoard:
                kicad = .header(pins: kind.terminalNames.count)
            case .notAPart:
                kicad = .none
            }
        }
    }
}

extension ElementKind {
    /// What is true of this kind across JSpice (see `PartFacts`)
    public var facts: PartFacts { PartFacts(self) }
}

/// Every kind's facts
public enum PartCatalog {
    public static var all: [PartFacts] { ElementKind.allCases.map(PartFacts.init) }

    /// The kinds a board leaves off it, wired by leads: sources, supplies, modules, breakout boards, the parts too big
    /// or too hot for it
    public static var offBreadboard: [ElementKind] { all.filter { $0.breadboard != .notAPart && !$0.hasBreadboardFootprint }.map(\.kind) }

    /// The kinds the SPICE export leaves out, with a comment
    public static var withoutSpiceEquivalent: [ElementKind] { all.filter { $0.spice == .noEquivalent }.map(\.kind) }
}
