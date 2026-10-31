// Ported from KiCad 10.0.8: pcbnew/tools/board_inspection_tool.cpp (highlightNet: the net of the item under the
// pointer, HighlightNet's toggle, ClearHighlight), pcbnew/collectors.cpp and collectors.h (GENERAL_COLLECTOR::Inspect
// and Collect, GENERAL_COLLECTORS_GUIDE: the items at a point, those on the preferred layer first, what the display's
// visibility leaves out), pcbnew/pcb_base_frame.cpp (GetCollectorsGuide), pcbnew/board.cpp (BOARD::Visit's order),
// pcbnew/tools/pcb_selection_tool.cpp (itemPassesFilter, the selection filter), pcbnew/zone.cpp (HitTestForCorner,
// HitTestForEdge, HitTestFilledArea), libs/kimath/src/geometry/shape_poly_set.cpp (CollideVertex, CollideEdge) and
// pcbnew/pcb_painter.cpp (PCB_RENDER_SETTINGS::GetColor: highlighted nets brightened, the rest darkened; the high
// contrast mode's dimming of inactive layers).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// What KiCad's Highlight Net (the ` key, or a click with the highlight modifier) picks at a point of a board: the
/// pads, tracks, arcs, vias and copper drawings of a net there (the zones' only where there are none), on the active
/// layer before the others, as the display shows them (hidden tracks, vias and footprints' pads left out, hidden
/// layers' tracks and zone fills, everything off the active layer in high contrast), the first one's net
public struct NetHighlight {
    /// What the pointer finds items with (GENERAL_COLLECTORS_GUIDE of the frame's display)
    public struct Guide: Sendable {
        public var appearance: KiCadBoardAppearance
        /// How far from an item a point still hits it: five of the view's pixels (KiROUND( 5 * OnePixelInIU ))
        public var accuracy: Int

        public init(appearance: KiCadBoardAppearance, accuracy: Int) {
            self.appearance = appearance
            self.accuracy = accuracy
        }

        /// The accuracy at a view's scale (screen points to the millimetre)
        public static func accuracy(pointsPerMillimetre scale: Double) -> Int { KiMath.round(5 * 1e6 / scale) }
    }

    private let drc: BoardDRC
    private let copper: BoardDRC.Copper
    /// The footprints' sides (FOOTPRINT::GetSide: their layer, F.Cu or B.Cu), by index
    private let footprintBack: [Bool]
    private var boundingRadii: [ObjectIdentifier: Int] = [:]
    private var polygons: [ObjectIdentifier: PolySet] = [:]
    private var fills: [ObjectIdentifier: [Int: PolySet]] = [:]

    public init(board: KiCadBoard, project: [String: Any]? = nil) {
        drc = BoardDRC(board: board, project: project)
        let c = drc.makeCopper()
        // (the nets KiCad's connectivity propagates as it reads the board)
        _ = drc.buildConnectivity(c)
        copper = c
        footprintBack = board.root.all("footprint").map { $0.value("layer") == "B.Cu" }
        for item in copper.items where item.kind == .pad {
            guard let p = item.pad else { continue }
            boundingRadii[ObjectIdentifier(item)] = Teardrops.boundingRadius(p, drc.world)
        }
    }

    /// A router layer's KiCad id
    private func kiLayer(_ r: Int) -> Int { KiLayer.fromRouter(r, copperLayers: drc.world.copperLayers) }

    /// The KiCad ids of an item's copper layers (GetLayerSet & AllCuMask)
    private func layers(_ item: BoardDRC.CopperItem) -> [Int] {
        switch item.kind {
        case .pad:
            guard let p = item.pad else { return [] }
            return drc.world.copper(p.pad.layers).map(kiLayer)
        default: return item.layers.map(kiLayer)
        }
    }

    /// The net of the item `highlightNet` takes at `p` (nil where it takes none: highlighting is then turned off),
    /// its code and name
    public mutating func pick(at p: IPoint, guide: Guide) -> (code: Int, name: String)? {
        let a = guide.appearance
        let preferred = a.activeLayer
        var primary: [BoardDRC.CopperItem] = [], secondary: [BoardDRC.CopperItem] = []
        func visible(_ id: Int) -> Bool { a.visibleLayers.contains(id) }
        func footprintHidden(_ item: BoardDRC.CopperItem) -> Bool {
            guard let f = item.footprint else { return false }
            return footprintBack[f] ? !a.isVisible(.footprintsBack) : !a.isVisible(.footprintsFront)
        }
        func inspect(_ item: BoardDRC.CopperItem) {
            if footprintHidden(item) { return }
            let ls = layers(item)
            let onPreferred = ls.contains(preferred)
            switch item.kind {
            case .pad, .via:
                if item.kind == .via && !a.isVisible(.vias) { return }
                guard hitTest(item, p, guide.accuracy) else { return }
                if onPreferred { primary.append(item) } else { secondary.append(item) }
            case .track, .arc, .shape:
                if (item.kind == .track || item.kind == .arc) && !a.isVisible(.tracks) { return }
                // (a drawing of no net is not a net's)
                if item.kind == .shape && item.net == 0 { return }
                guard let layer = ls.first, visible(layer), hitTest(item, p, guide.accuracy) else { return }
                if onPreferred { primary.append(item) } else { secondary.append(item) }
            case .zone:
                if item.net == 0 { return }
                guard zoneHit(item, p, guide.accuracy, visible) else { return }
                if onPreferred { primary.append(item) } else { secondary.append(item) }
            }
        }
        // (BOARD::Visit: the footprints' pads, the board's drawings, then its tracks, arcs and vias)
        for pads in copper.footprintPads { for pad in pads { inspect(pad) } }
        for d in copper.drawings where d.footprint == nil { inspect(d) }
        for t in copper.tracks { inspect(t) }
        var collected = primary + secondary
        if collected.isEmpty {
            primary = []
            secondary = []
            // (the zones: the footprints' first, then the board's)
            for z in copper.zones where z.footprint != nil { inspect(z) }
            for z in copper.zones where z.footprint == nil { inspect(z) }
            collected = primary + secondary
        }
        // the selection filter (locked items let through), then what is not on copper or, in high contrast, not on
        // the active layer
        let filter = a.selectionFilter
        collected = collected.filter { item in
            switch item.kind {
            case .pad: return filter["pads"] ?? true
            case .via: return filter["vias"] ?? true
            case .track, .arc: return filter["tracks"] ?? true
            case .zone: return filter["zones"] ?? true
            case .shape: return filter["graphics"] ?? true
            }
        }
        collected = collected.filter { item in
            let ls = layers(item)
            if ls.isEmpty { return false }
            if a.highContrast != .normal && !ls.contains(preferred) { return false }
            return true
        }
        guard let target = collected.first else { return nil }
        return (target.netCode, target.netName)
    }

    // MARK: - Hit tests

    private mutating func hitTest(_ item: BoardDRC.CopperItem, _ p: IPoint, _ accuracy: Int) -> Bool {
        switch item.kind {
        case .pad:
            guard let pp = item.pad else { return false }
            let key = ObjectIdentifier(item)
            if polygons[key] == nil {
                polygons[key] = drc.world.padPolygon(pp.pad, primitives: pp.primitives, errorLocation: .inside) ?? PolySet()
            }
            let poly = polygons[key]!
            return Teardrops.padHitTest(pp, p, accuracy, nil, drc.world, boundingRadius: boundingRadii[key] ?? 0) { poly }
        case .via: return Teardrops.viaHitTest(item, p, accuracy)
        case .track, .arc: return Teardrops.trackHitTest(item, p, accuracy)
        case .shape:
            guard let d = item.drawing else { return false }
            return BoardDRC.hitTest(d, p, accuracy)
        case .zone: return false
        }
    }

    /// The zone's outline's corners (within twice the accuracy) or edges (within it) at `p`, else its fill on a layer
    /// shown
    private mutating func zoneHit(_ zone: BoardDRC.CopperItem, _ p: IPoint, _ accuracy: Int, _ visible: (Int) -> Bool) -> Bool {
        let corner = 2 * accuracy
        for poly in zone.zoneOutline.polygons {
            for chain in poly {
                for q in chain.points where (q - p).squaredNorm <= corner * corner { return true }
            }
        }
        for poly in zone.zoneOutline.polygons {
            for chain in poly {
                for i in 0..<chain.segmentCount where chain.segment(i).squaredDistance(p) <= accuracy * accuracy { return true }
            }
        }
        let key = ObjectIdentifier(zone)
        for l in zone.layers.sorted(by: { kiLayer($0) < kiLayer($1) }) where visible(kiLayer(l)) {
            if fills[key]?[l] == nil {
                fills[key, default: [:]][l] = PolySet((zone.fills[l] ?? []).map { [$0] })
            }
            if fills[key]![l]!.contains(p) { return true }
        }
        return false
    }

    // MARK: - Colours

    /// PCB_RENDER_SETTINGS::GetColor of a copper item of net `net` on a layer of colour `color`: with nets
    /// highlighted, an item of one of them brightened and the others darkened; in high contrast (and no highlighted
    /// item), one off the active layer mixed into the background (dimmed) or gone (hidden)
    public static func color(_ color: KiCadColorTheme.RGBA, net: Int?, highlighted: Set<Int>, onActiveLayer: Bool,
                             highContrast: KiCadBoardAppearance.HighContrast, edgeCuts: Bool = false) -> KiCadColorTheme.RGBA? {
        var c = color
        let isHighlighted = !highlighted.isEmpty && net.map(highlighted.contains) == true
        if !highlighted.isEmpty {
            c = isHighlighted ? KiCadColorTheme.brightened(c, KiCadColorTheme.highlightFactor)
                              : KiCadColorTheme.darkened(c, 1 - KiCadColorTheme.highlightFactor)
        }
        if highContrast != .normal && !isHighlighted && !onActiveLayer {
            // (the board's edges not quite: they help working on another layer)
            let factor = edgeCuts ? max(KiCadColorTheme.hiContrastFactor, 0.3) : KiCadColorTheme.hiContrastFactor
            if highContrast == .hidden && !edgeCuts { return nil }
            c = KiCadColorTheme.mix(c, KiCadColorTheme.background, factor)
        }
        return c
    }
}
