// A board's stackup edited as the Board Setup dialog's Physical Stackup and Board Finish pages edit it (KiCad 10.0.7:
// pcbnew/board_stackup_manager/panel_board_stackup.cpp, buildLayerStackPanel and lazyBuildRowUI: the rows of the
// layers the board has; onAddDielectricLayer and onRemoveDielectricLayer, a dielectric's sublayers;
// onMaterialChange with dielectric_material.cpp, DIELECTRIC_SUBSTRATE_LIST: a material of KiCad's lists, its epsilon
// R and loss tangent with it; transferDataFromUIToStackup and TransferDataFromWindow: the values as the controls give
// them back, the enabled layers kept, the board's thickness the stackup's; panel_board_finish.cpp
// and stackup_predefined_prms.cpp: the copper finishes, impedance control and edges). GNU General Public License
// version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardStackup {
    /// A material of KiCad's lists (DIELECTRIC_SUBSTRATE): its name, epsilon R and loss tangent
    public struct Material: Sendable, Equatable {
        public var name: String
        public var epsilonR: Double
        public var lossTangent: Double
    }

    /// The materials the page's material dialog offers for a kind of layer (substrateMaterial, solderMaskMaterial,
    /// silkscreenMaterial), "Not specified" first
    public static func materials(_ kind: Kind) -> [Material] {
        switch kind {
        case .dielectric:
            return [(notSpecified, 0.0, 0.0), ("FR4", 4.5, 0.02), ("FR408-HR", 3.69, 0.0091), ("Polyimide", 3.2, 0.004),
                    ("Kapton", 3.2, 0.004), ("Polyolefin", 1.0, 0.0), ("Al", 8.7, 0.001), ("PTFE", 2.1, 0.0002),
                    ("Teflon", 2.1, 0.0002), ("Ceramic", 1.0, 0.0)].map { Material(name: $0.0, epsilonR: $0.1, lossTangent: $0.2) }
        case .solderMask:
            return [notSpecified, "Epoxy", "Liquid Ink", "Dry Film"].map { Material(name: $0, epsilonR: 3.3, lossTangent: 0) }
        case .silkscreen:
            return [notSpecified, "Liquid Photo", "Direct Printing"].map { Material(name: $0, epsilonR: 1.0, lossTangent: 0) }
        default:
            return []
        }
    }

    /// The copper finishes the Board Finish page offers (copperFinishType), "User defined" aside
    public static let finishes = [notSpecified, "ENIG", "ENEPIG", "HAL SnPb", "HAL lead-free", "Hard gold", "Immersion tin",
                                  "Immersion nickel", "Immersion silver", "Immersion gold", "HT_OSP", "OSP", "None"]

    /// The colors the page offers for a kind of layer by name ("Not specified" first); any other is a user defined
    /// "#RRGGBBAA"
    public static func colors(_ kind: Kind) -> [String] { Array(standardColors(kind).dropLast()) }

    /// A material of the list given a sublayer, as the material dialog gives it (its name, epsilon R and loss
    /// tangent); a name not in the list given alone
    public mutating func setMaterial(_ name: String, item: Int, sublayer: Int = 0) {
        guard items.indices.contains(item), items[item].sublayers.indices.contains(sublayer) else { return }
        items[item].sublayers[sublayer].material = name
        if let m = Self.materials(items[item].kind).first(where: { $0.name == name }), items[item].hasEpsilonR {
            items[item].sublayers[sublayer].epsilonR = m.epsilonR
            items[item].sublayers[sublayer].lossTangent = m.lossTangent
        }
    }

    /// A sublayer added to a dielectric (onAddDielectricLayer: a new one after the last, of the defaults of a new
    /// dielectric layer, AddDielectricPrms)
    public mutating func addSublayer(item: Int) {
        guard items.indices.contains(item), items[item].kind == .dielectric else { return }
        items[item].sublayers.append(Item(.dielectric).sublayers[0])
    }

    /// A dielectric's sublayer taken away (onRemoveDielectricLayer: never its last)
    public mutating func removeSublayer(item: Int, sublayer: Int) {
        guard items.indices.contains(item), items[item].kind == .dielectric, items[item].sublayers.count > 1,
              items[item].sublayers.indices.contains(sublayer) else { return }
        items[item].sublayers.remove(at: sublayer)
    }

    /// What the page writes of the stackup as it shows it (transferDataFromUIToStackup): epsilon R and loss tangent as
    /// their fields give them back, materials not specified written so, colors through their boxes
    func throughControls() -> BoardStackup {
        var out = self
        for i in out.items.indices {
            let kind = out.items[i].kind
            for j in out.items[i].sublayers.indices {
                if out.items[i].hasEpsilonR {
                    out.items[i].sublayers[j].epsilonR = Self.doubleThroughDialog(max(0, out.items[i].sublayers[j].epsilonR))
                    out.items[i].sublayers[j].lossTangent = Self.doubleThroughDialog(max(0, out.items[i].sublayers[j].lossTangent))
                }
                if out.items[i].isMaterialEditable && !Self.isSpecified(out.items[i].sublayers[j].material) {
                    out.items[i].sublayers[j].material = Self.notSpecified
                }
                if out.items[i].isColorEditable {
                    out.items[i].sublayers[j].color = Self.colorThroughDialog(out.items[i].sublayers[j].color, kind)
                }
                if !out.items[i].isThicknessEditable || kind != .dielectric { out.items[i].sublayers[j].thicknessLocked = false }
            }
            if kind == .dielectric && out.items[i].typeName != "core" { out.items[i].typeName = "prepreg" }
        }
        return out
    }
}

extension BoardEditing {
    /// The board's stackup as Board Setup's Physical Stackup page shows it: a row for each layer of the board's
    /// stackup (or of the one KiCad makes for it if its file has none), its values as the page's controls hold them
    public var boardSetupStackup: BoardStackup {
        let settings = BoardStackup.BoardSettings(router.board)
        return BoardStackup.read(router.board).stackup.throughBoardSetup(settings, copperLayers: settings.copperLayers)
    }

    /// The board's stackup made `stackup` (the page's, `boardSetupStackup`, edited: its layers' thicknesses, locks,
    /// types, materials, epsilon R and loss tangents, colors and sublayers; the finish, impedance control and edges)
    /// as the dialog's OK makes it: the values as its controls give them back, written into the board's setup as
    /// KiCad writes a stackup, and the board's thickness the stackup's, as one change ("Edit Board Stackup"); nil if
    /// it does not have the page's layers, a thickness is negative (KiCad's "A layer thickness is < 0"), or nothing
    /// changes
    public func setStackup(_ stackup: BoardStackup) -> Edit? {
        guard !isRouting else { return nil }
        let page = boardSetupStackup
        guard stackup.items.count == page.items.count,
              zip(stackup.items, page.items).allSatisfy({ BoardStackup.same($0, $1) && $0.kind == $1.kind }),
              !stackup.items.contains(where: { $0.sublayers.isEmpty || $0.sublayers.contains { $0.thickness < 0 } }) else { return nil }
        let made = stackup.throughControls()
        let board = router.board
        let before = (board.root["setup"]?["stackup"]?.compact, board.root["general"]?["thickness"]?.compact)
        Self.writeStackup(made, to: board)
        guard before != (board.root["setup"]?["stackup"]?.compact, board.root["general"]?["thickness"]?.compact) else { return nil }
        router.boardChanged()
        return change("Edit Board Stackup", setup: true)
    }

    /// A stackup written into a board's file as KiCad writes it: first in the board's setup, and the board's
    /// thickness its own (BuildBoardThicknessFromStackup)
    static func writeStackup(_ stackup: BoardStackup, to board: KiCadBoard) {
        if let node = stackup.node {
            let setup = board.root["setup"] ?? {
                let s = SExpr("setup")
                board.root.insert(s, after: ["layers"])
                return s
            }()
            if let i = setup.items.firstIndex(where: { $0.head == "stackup" }) {
                setup.items[i] = node
            } else {
                setup.items.insert(node, at: 1)
            }
        }
        let general = board.root["general"] ?? {
            let g = SExpr("general")
            board.root.insert(g, after: ["generator_version", "generator", "version"])
            return g
        }()
        let thickness = SExpr("thickness", Keyword(BoardStackup.formatLength(stackup.boardThickness)))
        if let i = general.items.firstIndex(where: { $0.head == "thickness" }) {
            general.items[i] = thickness
        } else {
            general.items.insert(thickness, at: min(1, general.items.count))
        }
    }
}
