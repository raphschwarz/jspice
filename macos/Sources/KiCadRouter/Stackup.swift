// Ported from KiCad 10.0.7: pcbnew/board_stackup_manager/board_stackup.h and board_stackup.cpp
// (BOARD_STACKUP_ITEM, BOARD_STACKUP::BuildDefaultStackupList, GetLayerDistance), the stackup as
// pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp reads it (parseBoardStackup), and
// pcbnew/length_delay_calculation/length_delay_calculation.cpp (StackupHeight).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// A board's stackup, as a length tuning measures through it (KiCad's BOARD_STACKUP): its copper layers and the
/// dielectrics between them, top to bottom, each with its sublayers' thicknesses (the mask, paste and silkscreen
/// layers, which the distance between copper layers leaves out, left out)
public struct Stackup: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        /// The copper layer's router layer; nil for a dielectric
        public var copper: Int?
        /// Its thickness, each sublayer's (a dielectric can have several), in nm
        public var thicknesses: [Int]
    }

    /// A copper layer's thickness where none is given (BOARD_STACKUP_ITEM::GetCopperDefaultThickness)
    public static let copperDefaultThickness = 35_000
    /// A solder mask's (GetMaskDefaultThickness)
    public static let maskDefaultThickness = 10_000

    public var items: [Item]

    public init(items: [Item]) { self.items = items }

    /// The stackup KiCad builds for a board with none of its own (BuildDefaultStackupList, of the board's settings):
    /// its copper layers of the default thickness, and between each two a dielectric, the board's thickness less its
    /// copper and its masks' (`masks`: how many of its mask layers the board has) shared out between them
    public static func defaultStackup(boardThickness: Int, copperLayers: Int, masks: Int) -> Stackup {
        let names = BoardStackup.copperNames(copperLayers)
        let settings = BoardStackup.BoardSettings(enabledLayers: Set(names + ["F.Mask", "B.Mask"].prefix(masks)),
                                                  copperLayers: copperLayers, thickness: boardThickness)
        let index = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
        return Stackup(BoardStackup.defaultStackup(settings), layerIndex: index)
    }

    /// The copper layers and dielectrics of a board's full stackup (BoardStackup), its copper layers by `layerIndex`
    /// (its masks, pastes and silkscreens, not between copper layers, left out)
    public init(_ stackup: BoardStackup, layerIndex: [String: Int]) {
        items = stackup.items.compactMap { item in
            switch item.kind {
            case .copper: return Item(copper: item.layer.flatMap { layerIndex[$0] }, thicknesses: item.sublayers.map(\.thickness))
            case .dielectric: return Item(copper: nil, thicknesses: item.sublayers.map(\.thickness))
            default: return nil
            }
        }
    }

    /// The stackup a board's file gives (its setup's (stackup ...), as parseBoardStackup reads it, BoardStackup.parse:
    /// each of its layers by the name of a layer of the board, its copper layers' thicknesses their own or the default;
    /// anything else a dielectric, with its sublayers, each with its thickness or none), its copper layers by
    /// `layerIndex`; nil if it gives none
    public static func read(_ board: KiCadBoard, layerIndex: [String: Int]) -> Stackup? {
        guard let node = board.root["setup"]?["stackup"] else { return nil }
        return Stackup(BoardStackup.parse(node, enabledLayers: BoardStackup.BoardSettings(board).enabledLayers), layerIndex: layerIndex)
    }

    /// The board's thickness between two copper layers (router layers), as KiCad counts it (GetLayerDistance): the
    /// upper layer's copper, the dielectrics and copper layers between, and the lower layer's copper, an inner copper
    /// layer at either end half counted
    public func layerDistance(_ first: Int, _ second: Int, copperLayers: Int) -> Int {
        if first == second { return 0 }
        let (a, b) = first < second ? (first, second) : (second, first)
        func isOuter(_ layer: Int) -> Bool { layer == 0 || layer == copperLayers - 1 }
        var total = 0
        var start = false
        var half = false
        for item in items {
            if !start, let c = item.copper, c == a {
                start = true
                // (only half of an inner copper layer)
                if !isOuter(a) { half = true }
            } else if !start {
                continue
            }
            if start, let c = item.copper, c == b {
                if !isOuter(b) { half = true }
            }
            for t in item.thicknesses { total += half ? t / 2 : t }
            half = false
            if let c = item.copper, c == b { break }
        }
        return total
    }

    /// The board's thickness between each two of its copper layers, by router layer, as a length tuning counts it for
    /// a via (LENGTH_DELAY_CALCULATION::StackupHeight): the board's stackup, or the one KiCad builds for it; none at
    /// all if the board does not use heights for lengths
    public static func heights(_ board: KiCadBoard, project: [String: Any]?, layerIndex: [String: Int],
                               copperLayers: Int) -> [[Int]] {
        let rules = ((project?["board"] as? [String: Any])?["design_settings"] as? [String: Any])?["rules"] as? [String: Any]
        if (rules?["use_height_for_length_calcs"] as? Bool) == false {
            return Array(repeating: Array(repeating: 0, count: copperLayers), count: copperLayers)
        }
        let stackup = read(board, layerIndex: layerIndex) ?? {
            // (KiCad's board thickness, 1.6 mm if the board says none; its masks, those of its layers)
            let thickness = board.root["general"]?["thickness"].map { BoardWorld.iu($0, 0) } ?? 1_600_000
            let layers = (board.root["layers"]?.arguments ?? []).compactMap { $0.text(at: 0) }
            let masks = ["F.Mask", "B.Mask"].filter(layers.contains).count
            return defaultStackup(boardThickness: thickness, copperLayers: copperLayers, masks: masks)
        }()
        return (0..<copperLayers).map { a in (0..<copperLayers).map { b in stackup.layerDistance(a, b, copperLayers: copperLayers) } }
    }
}
