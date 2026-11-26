// Ported from KiCad 10.0.8: pcbnew/pad.cpp (PAD::FlashLayer), pcbnew/pcb_track.cpp (PCB_VIA::FlashLayer), pcbnew/pad.h
// and pcbnew/pcb_track.h (ConditionallyFlashed, GetRemoveUnconnected), pcbnew/connectivity/connectivity_data.cpp
// (CONNECTIVITY_DATA::IsConnectedOnLayer) and pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp (a pad's and a
// via's unconnected layer mode and zone layer connections as parsePAD and parsePCB_VIA read them).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardDRC {
    /// PADSTACK::UNCONNECTED_LAYER_MODE: which copper layers a pad or via is kept on where nothing connects to it
    enum UnconnectedLayerMode {
        case keepAll, removeAll, removeExceptStartAndEnd, startEndOnly

        /// A pad's, as parsePAD reads it: (remove_unused_layers) sets it to remove all or keep all, then
        /// (keep_end_layers) to keep the ends or remove all, in the order the file has them
        init(pad node: SExpr) {
            var mode = UnconnectedLayerMode.keepAll
            for item in node.items {
                switch item.head {
                case "remove_unused_layers": mode = Self.maybeAbsentBool(item) ? .removeAll : .keepAll
                case "keep_end_layers": mode = Self.maybeAbsentBool(item) ? .removeExceptStartAndEnd : .removeAll
                default: break
                }
            }
            self = mode
        }

        /// A via's, as parsePCB_VIA reads it: each of (remove_unused_layers), (keep_end_layers) and (start_end_only)
        /// that is yes sets it, in the order the file has them
        init(via node: SExpr) {
            var mode = UnconnectedLayerMode.keepAll
            for item in node.items {
                switch item.head {
                case "remove_unused_layers": if Self.maybeAbsentBool(item) { mode = .removeAll }
                case "keep_end_layers": if Self.maybeAbsentBool(item) { mode = .removeExceptStartAndEnd }
                case "start_end_only": if Self.maybeAbsentBool(item) { mode = .startEndOnly }
                default: break
                }
            }
            self = mode
        }

        /// parseMaybeAbsentBool( true ): yes with nothing after the name
        static func maybeAbsentBool(_ item: SExpr) -> Bool { item.text(at: 0).map { $0 == "yes" } ?? true }

        /// ConditionallyFlashed: whether it is flashed on a layer only where something connects to it there (its
        /// drill's start and end layers, a pad's F.Cu and B.Cu, `start` and `end`)
        func conditionallyFlashed(_ layer: Int, start: Int, end: Int) -> Bool {
            switch self {
            case .keepAll: return false
            case .removeAll: return true
            case .removeExceptStartAndEnd, .startEndOnly: return layer != start && layer != end
            }
        }
    }

    /// ZONE_LAYER_OVERRIDE: what the zone filler last found of a layer a pad or via is flashed on only where
    /// something connects to it: flashed there whatever connects (a zone of its net reaches it), or not to be joined
    /// to a zone there
    enum ZoneLayerOverride { case none, forceFlashed, forceNoZoneConnection }

    /// A pad's or via's zone layer connections as parsePAD and parsePCB_VIA read them (by router layer): with
    /// (zone_layer_connections ...), each of its copper layers `layers` not to be joined to a zone but those it names,
    /// flashed; without it, none
    func zoneLayerOverrides(_ node: SExpr, layers: [Int]) -> [Int: ZoneLayerOverride] {
        var out: [Int: ZoneLayerOverride] = [:]
        for item in node.items where item.head == "zone_layer_connections" {
            for l in layers { out[l] = .forceNoZoneConnection }
            for name in item.arguments.map(\.text) {
                if let l = world.layerIndex[name] { out[l] = .forceFlashed }
            }
        }
        return out
    }

    /// The unconnected layer mode of a pad or via, keep all for anything else
    func unconnectedLayers(_ it: CopperItem) -> UnconnectedLayerMode {
        switch it.kind {
        case .pad: return it.pad?.unconnectedLayers ?? .keepAll
        case .via: return it.via?.unconnectedLayers ?? .keepAll
        default: return .keepAll
        }
    }

    /// PAD::ConditionallyFlashed and PCB_VIA::ConditionallyFlashed of a copper layer (a pad's drill from F.Cu to B.Cu,
    /// a via's from its top layer to its bottom one)
    func conditionallyFlashed(_ it: CopperItem, _ layer: Int) -> Bool {
        switch it.kind {
        case .pad: return unconnectedLayers(it).conditionallyFlashed(layer, start: 0, end: world.copperLayers - 1)
        case .via:
            guard let v = it.via else { return false }
            return v.unconnectedLayers.conditionallyFlashed(layer, start: v.layers.start, end: v.layers.end)
        default: return false
        }
    }

    /// Whether the copper has a pad or via whose flashing on a layer the connectivity decides: a plated pad or a via
    /// that does not keep all its layers (GetRemoveUnconnected)
    func hasConditionalFlashing(_ c: Copper) -> Bool {
        c.items.contains { it in
            switch it.kind {
            case .pad: return it.pad?.pad.attribute == .pth && unconnectedLayers(it) != .keepAll
            case .via: return unconnectedLayers(it) != .keepAll
            default: return false
            }
        }
    }

    /// CONNECTIVITY_DATA::IsConnectedOnLayer( item, layer, { PCB_TRACE_T, PCB_ARC_T, PCB_VIA_T, PCB_PAD_T } ), as
    /// PAD::FlashLayer and PCB_VIA::FlashLayer ask it: whether a track, arc, via or pad of its net the connectivity
    /// joins it to is on the layer, not itself, not of its footprint, and not, for a pad, another pad that also flashes
    /// only where connected. (KiCad's tests of a zone's island there are never reached: the types asked for are not a
    /// zone's.)
    func isConnectedOnLayer(_ cn: Connectivity, _ it: CopperItem, _ layer: Int) -> Bool {
        // (lyIdx, B.Cu the greatest, as CN_ITEM's layers have it)
        let ly = cnLayer(layer)
        for citem in cn.entries[ObjectIdentifier(it)] ?? [] {
            for connected in citem.connected {
                let other = connected.parent
                guard connected.startLayer <= ly && connected.endLayer >= ly,
                      [.track, .arc, .via, .pad].contains(other.kind), connected.net == it.net else { continue }
                if other === it { continue }
                if let f = it.footprint, other.footprint == f { continue }
                if it.kind == .pad && other.kind == .pad {
                    // (flashesConditionally: by the mode alone, REMOVE_EXCEPT_START_AND_END or REMOVE_ALL)
                    let a = unconnectedLayers(it), b = unconnectedLayers(other)
                    if (a == .removeAll || a == .removeExceptStartAndEnd) && (b == .removeAll || b == .removeExceptStartAndEnd) { continue }
                }
                return true
            }
        }
        return false
    }

    /// PAD::FlashLayer of a copper layer: not where it is not, nor an unplated hole's pad no bigger than its hole;
    /// a plated pad's by its unconnected layer mode: on F.Cu and B.Cu when it keeps its ends, then where the zone
    /// filler forced it flashed, or (`onlyCheckIfPermitted`, CanFlashLayer) wherever it may be, else where the
    /// connectivity joins it to something there (`cn`)
    func padFlashLayer(_ it: CopperItem, _ layer: Int, _ cn: Connectivity?, onlyCheckIfPermitted: Bool = false) -> Bool {
        guard let p = it.pad, world.flash(p.pad, world.copper(p.pad.layers), layer) else { return false }
        guard p.pad.attribute == .pth else { return true }
        let last = world.copperLayers - 1
        switch p.unconnectedLayers {
        case .keepAll: return true
        case .startEndOnly: return layer == 0 || layer == last
        case .removeExceptStartAndEnd where layer == 0 || layer == last: return true
        case .removeExceptStartAndEnd, .removeAll: break
        }
        if it.zoneLayerOverrides[layer] == .forceFlashed || onlyCheckIfPermitted { return true }
        guard let cn else { return true }
        return isConnectedOnLayer(cn, it, layer)
    }

    /// PCB_VIA::FlashLayer of a copper layer: not where it is not; by its unconnected layer mode, on its drill's start
    /// and end layers where it keeps them (only there for START_END_ONLY), then where the zone filler forced it
    /// flashed, else where the connectivity joins it to something there
    func viaFlashLayer(_ it: CopperItem, _ layer: Int, _ cn: Connectivity?) -> Bool {
        guard let v = it.via, layer >= v.layers.start && layer <= v.layers.end else { return false }
        switch v.unconnectedLayers {
        case .keepAll: return true
        case .removeExceptStartAndEnd where layer == v.layers.start || layer == v.layers.end: return true
        case .removeExceptStartAndEnd, .removeAll: break
        case .startEndOnly: return layer == v.layers.start || layer == v.layers.end
        }
        if it.zoneLayerOverrides[layer] == .forceFlashed { return true }
        guard let cn else { return true }
        return isConnectedOnLayer(cn, it, layer)
    }

    /// Each plated pad's and via's layers flashed (FlashLayer) where the connectivity decides them, as the checks
    /// then ask of them, and its shapes on each layer as GetEffectiveShape gives them then: a pad's hole where it is
    /// not flashed, a via's hole's round
    func applyFlashing(_ c: Copper, _ cn: Connectivity) {
        for it in c.items {
            switch it.kind {
            case .pad:
                guard let p = it.pad, p.pad.attribute == .pth, p.unconnectedLayers != .keepAll else { continue }
                it.flashed = Set(it.layers.filter { padFlashLayer(it, $0, cn) })
                setPadShapes(it)
            case .via:
                guard let v = it.via, v.unconnectedLayers != .keepAll else { continue }
                it.flashed = Set(it.layers.filter { viaFlashLayer(it, $0, cn) })
                setViaShapes(it)
            default:
                break
            }
        }
    }

    /// A pad's shape on each layer by where it is flashed (a plated pad's hole where it is not), and as the R-tree
    /// holds it (its hole too)
    func setPadShapes(_ item: CopperItem) {
        guard let p = item.pad else { return }
        for l in p.hasHole ? kicadLayerOrder : item.layers {
            let shapes = p.pad.attribute == .pth && !item.flashed.contains(l) ? item.hole.map { [$0] } ?? [] : item.outline
            item.shapes[l] = shapes
            item.indexed[l] = shapes + (item.hole.map { [$0] } ?? [])
        }
    }

    /// A via's shape on each of its layers: its copper's round where it is flashed, else its hole's (PCB_VIA::
    /// GetEffectiveShape)
    func setViaShapes(_ item: CopperItem) {
        guard let v = item.via else { return }
        for l in item.layers {
            item.shapes[l] = [.circle(center: v.start, radius: (item.flashed.contains(l) ? v.diameter : v.drill) / 2)]
            item.indexed[l] = item.shapes[l]
        }
    }
}
