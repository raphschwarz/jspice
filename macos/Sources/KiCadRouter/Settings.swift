// Ported from KiCad 10.0.7: pcbnew/router/pns_routing_settings.h, pns_routing_settings.cpp and pns_sizes_settings.h.
// Copyright (C) 2013-2014 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// How the router routes (KiCad's PNS_MODE)
public enum RouterMode: Int, Sendable {
    /// Collisions marked, not avoided
    case markObstacles = 0
    /// What is in the way pushed aside
    case shove
    /// What is in the way walked round
    case walkaround
}

/// How hard the optimizer works (KiCad's PNS_OPTIMIZATION_EFFORT)
public enum OptimizationEffort: Int, Sendable { case low = 0, medium, full }

/// The router's settings, KiCad's defaults (KiCad's ROUTING_SETTINGS)
public struct RoutingSettings: Sendable {
    public var mode: RouterMode = .walkaround
    public var optimizerEffort: OptimizationEffort = .medium
    public var removeLoops = true
    public var smartPads = true
    public var shoveVias = true
    public var suggestFinish = false
    public var followMouseSetting = true
    public var startDiagonal = false
    public var shoveIterationLimit = 250
    /// Milliseconds
    public var shoveTimeLimit = 1000
    public var walkaroundIterationLimit = 40
    public var jumpOverObstacles = false
    public var smoothDraggedSegments = true
    public var allowDRCViolationsSetting = false
    public var freeAngleMode = false
    public var snapToTracks = false
    public var snapToPads = false
    public var optimizeEntireDraggedTrack = false
    public var cornerMode: Direction45.CornerMode = .mitered45
    public var walkaroundHugLengthThreshold = 1.5
    public var autoPosture = true
    public var fixAllSegments = true
    public var viaForcePropIterationLimit = 40

    public init() {}

    public var followMouse: Bool { followMouseSetting && mode != .markObstacles }
    public var allowDRCViolations: Bool { mode == .markObstacles && allowDRCViolationsSetting }
    public var initialDirection: Direction45 { Direction45(startDiagonal ? .ne : .n) }
}

/// The sizes of what is routed: track width, via, clearance (KiCad's SIZES_SETTINGS)
public struct SizesSettings: Sendable {
    public var clearance = 0
    public var minClearance = 0
    public var trackWidth = 155_000
    public var trackWidthIsExplicit = true
    public var boardMinTrackWidth = 0
    public var viaType: Via.ViaType = .through
    public var viaDiameter = 600_000
    public var viaDrill = 250_000
    public var diffPairWidth = 125_000
    public var diffPairGap = 180_000
    public var diffPairViaGap = 180_000
    public var diffPairViaGapSameAsTraceGap = true
    public var holeToHole = 0
    public var layerPairs: [Int: Int] = [:]

    public init() {}

    public func pairedLayer(_ layer: Int) -> Int? { layerPairs[layer] }

    public mutating func clearLayerPairs() { layerPairs.removeAll() }

    public mutating func addLayerPair(_ l1: Int, _ l2: Int) {
        let top = min(l1, l2), bottom = max(l1, l2)
        layerPairs[bottom] = top
        layerPairs[top] = bottom
    }
}
