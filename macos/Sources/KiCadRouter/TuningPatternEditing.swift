// Length tuning on a board edited here, kept in the board as KiCad keeps it: a tuning pattern placed as KiCad's
// Tune Length tools place one (DRAWING_TOOL::PlaceTuningPattern: CreateNew, applyCommonSettings, the pattern's end
// following the pointer, the amplitude and spacing stepped, the settings changed; the click that keeps it), a
// pattern's end dragged as its point editor drags it (PCB_POINT_EDITOR with GENERATOR_POINT_EDIT_BEHAVIOR:
// MakeEditPoints, UpdateFromEditPoints), a pattern's properties changed as its properties panel changes them
// (GENERATOR_TOOL's listener: EditStart, Update, EditFinish), every pattern tuned again as Edit > Update All Tuning
// Patterns tunes them (GENERATOR_TOOL::RegenerateAllOfType), and a pattern deleted as EDIT_TOOL deletes one
// (genRemove) (pcbnew/generators/pcb_tuning_pattern.cpp, pcbnew/tools/generator_tool.cpp, pcbnew/tools/
// pcb_point_editor.cpp, pcbnew/tools/edit_tool.cpp, KiCad 10.0.7).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt. GNU General Public License version 3 or later, as KiCad
// (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// A tuning pattern being placed (Tune Length's first click made) or edited (its end or origin dragged)
struct PatternSession {
    enum Kind {
        /// Placed: the tool's own settings (applyCommonSettings' meanderSettings)
        case placing(tool: MeanderSettings)
        /// Its end (or origin) dragged, as the point editor drags its edit point
        case dragging(end: Bool)
    }

    var pattern: TuningPattern
    var kind: Kind
    /// Where the pointer last was
    var pointer: IPoint
}

extension BoardEditing {
    /// A length tuning as it is drawn: the tuned line (a pair's two, positive first), its width and layer, its nets,
    /// how its length compares with what is asked, and the length (a skew tuning's skew), in mm
    public struct TuningPreview: Sendable, Equatable {
        public enum Status: Sendable { case tooShort, tooLong, tuned }

        public var lines: [[KiCadPoint]]
        public var width: Double
        public var layer: String
        public var nets: [String]
        public var status: Status
        public var length: Double
    }

    /// A tuning pattern of the board, as KiCad lists one (its properties, and its row in the generators' list): its
    /// uuid, what it tunes, its nets (a pair's both), its layer, its target (a skew tuning's skew), what its last
    /// tuning came to and how that compares with the target, its tracks, and its outline (mm)
    public struct TuningPatternInfo: Sendable {
        public var uuid: String
        public var mode: BoardRouter.TuningMode
        public var nets: [String]
        public var layer: String
        public var target: (min: Double, opt: Double, max: Double)
        public var status: TuningPreview.Status
        public var length: Double
        public var settings: MeanderSettings
        public var members: [String]
        public var origin: KiCadPoint
        public var end: KiCadPoint
        public var outline: [KiCadPoint]
        public var baseLine: [KiCadPoint]
    }

    static func previewStatus(_ s: TuningPattern.Status) -> TuningPreview.Status {
        s == .tooShort ? .tooShort : s == .tooLong ? .tooLong : .tuned
    }

    func info(_ p: TuningPattern) -> TuningPatternInfo {
        var nets = [p.lastNetName]
        if p.mode != .single, let coupled = router.dpCoupledNet(p.lastNetName) { nets.append(coupled) }
        let t = p.mode == .skew ? (p.settings.targetSkew.min, p.settings.targetSkew.opt, p.settings.targetSkew.max)
            : (p.settings.targetLength.min, p.settings.targetLength.opt, p.settings.targetLength.max)
        return TuningPatternInfo(uuid: p.uuid, mode: p.mode.tuningMode, nets: nets, layer: p.layer,
                                 target: (Double(t.0) / 1e6, Double(t.1) / 1e6, Double(t.2) / 1e6),
                                 status: Self.previewStatus(p.status), length: Double(p.tuningLength) / 1e6, settings: p.settings,
                                 members: p.members, origin: Self.mm(p.origin), end: Self.mm(p.end),
                                 outline: p.outline.points.map(Self.mm), baseLine: p.baseLine?.points.map(Self.mm) ?? [])
    }

    /// The board's tuning patterns, in its file's order
    public var tuningPatterns: [TuningPatternInfo] { router.patternMemory.all(router.board).map(info) }

    /// The settings KiCad's Tune Length tool of `mode` starts with: its defaults, as the board's project sets them
    /// (its tuning_pattern_settings); the target none
    public func defaultTuningSettings(_ mode: BoardRouter.TuningMode) -> MeanderSettings {
        TuningPattern.defaultSettings(TuningPattern.Mode(mode), project: project)
    }

    /// The board's tuning pattern of `uuid`, as its file has it
    public func tuningPattern(_ uuid: String) -> TuningPattern? { router.patternMemory.all(router.board).first { $0.uuid == uuid } }

    /// The tuning pattern the pointer at `p` is over (KiCad's HitTest: within its outline, or over one of its
    /// tracks), the first of the board's; nil if none
    public func tuningPattern(at p: KiCadPoint) -> String? {
        let q = Self.nm(p)
        for pattern in router.patternMemory.all(router.board) {
            if pattern.outline.pointInside(q) { return pattern.uuid }
            if pattern.members.contains(where: { m in router.board.copperItems.contains { $0.value("uuid") == m && Self.hits($0, q) } }) {
                return pattern.uuid
            }
        }
        return nil
    }

    /// Whether `p` is on the track (within half its width of its line)
    static func hits(_ node: SExpr, _ p: IPoint) -> Bool {
        let w = node["width"].map { BoardWorld.iu($0, 0) } ?? 0
        let nearest = BoardRouter.BoardTrack(node: node).nearestPoint(p)
        return (nearest - p).squaredNorm <= (w / 2) * (w / 2)
    }

    /// The pattern of `uuid` whose member the track or arc `uuid` is, if any
    func pattern(ofMember uuid: String) -> TuningPattern? {
        router.patternMemory.all(router.board).first { $0.members.contains(uuid) }
    }

    // MARK: - Placing, as Tune Length places a pattern

    /// Starts tuning the length of the track at `p` on `layer` (the one a track is on taken first), or of the
    /// differential pair it is a line of, or the pair's skew, as KiCad's Tune Length of a Single Track, Tune Length of
    /// a Differential Pair and Tune Skew of a Differential Pair start a tuning pattern with their first click there
    /// (CreateNew: the target from the board's rules, then the tool's settings, `settings` or the project's for the
    /// mode; the pattern's origin and end the point of the track nearest the pointer). A track that is one of a
    /// pattern's is that pattern edited instead, its end (or its origin, if that is nearer) dragged from there, as
    /// KiCad's point editor drags it. What it measures before the pointer moves is shown as KiCad shows it (a pattern
    /// of no length tuned). Nil if there is no track there, `failureReason` saying so as KiCad's placer says it.
    /// `moveTuning` takes the pattern's end to the pointer, `fixTuning` keeps it, `cancelTuning` drops it.
    public func startTuning(at p: KiCadPoint, layer: String, mode: BoardRouter.TuningMode = .single,
                            settings: MeanderSettings? = nil) -> TuningPreview? {
        guard !isRouting, patternSession == nil, let l = router.layer(layer) else { return nil }
        let q = Self.nm(p)
        router.router.failureReason = ""
        let item = router.pickSingleItem(q, net: nil, layer: -1, topLayer: l, ignorePads: true)
        guard let item, item.kind == .segment || item.kind == .arc,
              let uuid = router.iface.resolver.info[ObjectIdentifier(item)]?.source,
              let node = router.board.copperItems.first(where: { $0.value("uuid") == uuid }) else {
            router.router.failureReason = "Please select a track whose length you want to tune."
            return nil
        }
        // (a track of a pattern: the pattern selected, its nearer end dragged)
        if var pattern = pattern(ofMember: uuid) {
            let toEnd = (pattern.end - q).squaredNorm <= (pattern.origin - q).squaredNorm
            router.patternEditStart(&pattern)
            router.patternUpdate(&pattern)
            patternSession = PatternSession(pattern: pattern, kind: .dragging(end: toEnd), pointer: q)
            return tuningPreview
        }
        // (CreateNew, then applyCommonSettings: the tool's settings in place of the rules' target)
        let patternMode = TuningPattern.Mode(mode)
        var pattern = TuningPattern(mode: patternMode, layer: node.value("layer") ?? layer)
        pattern.settings = TuningPattern.defaultSettings(patternMode, project: project)
        let track = BoardRouter.BoardTrack(node: node)
        if patternMode == .skew {
            if let c = router.tuningConstraint(.diffPairSkew, track: track, coupled: nil, layer: router.layer(pattern.layer) ?? l) {
                BoardRouter.applyConstraint(c, to: &pattern.settings, skew: true)
            }
        } else if let c = router.tuningConstraint(.length, track: track, coupled: nil, layer: router.layer(pattern.layer) ?? l) {
            BoardRouter.applyConstraint(c, to: &pattern.settings, skew: false)
        }
        pattern.isNew = true
        let tool = settings ?? TuningPattern.defaultSettings(patternMode, project: project)
        pattern.settings = tool
        // (the point of the track nearest the pointer: its shape's Collide with a clearance too large to miss)
        let closest: IPoint
        if let arc = item as? Arc {
            var actual: Int?, location: IPoint?
            _ = arc.arc.collide(q, clearance: Int(Int32.max) / 2, actual: &actual, location: &location)
            closest = location ?? arc.arc.nearestPoint(q)
        } else {
            closest = (item as! Segment).seg.nearestPoint(q)
        }
        pattern.origin = closest
        pattern.end = closest
        patternSession = PatternSession(pattern: pattern, kind: .placing(tool: tool), pointer: q)
        hoverStatus()
        return tuningPreview
    }

    /// What a pattern of no length placed there would tune to, as KiCad shows it before the pattern has an end
    /// (updateHoverStatus: a copy of the pattern edited and tuned, kept on the router to be drawn, the pattern as it was)
    private func hoverStatus() {
        guard var dummy = patternSession?.pattern else { return }
        router.patternEditStart(&dummy)
        router.patternUpdate(&dummy)
    }

    /// The pattern placed tuned again where it now ends, as the tool tunes it (updateTuningPattern: not while it ends
    /// where it starts)
    private func updateTuningPattern() {
        guard var s = patternSession else { return }
        if case .placing = s.kind {
            if s.pattern.origin != s.pattern.end {
                router.patternEditStart(&s.pattern)
                router.patternUpdate(&s.pattern)
            }
        } else {
            router.patternUpdate(&s.pattern)
        }
        patternSession = s
    }

    /// The pointer moved to `p`, tuning: the pattern's end taken there (its side the side of its line the pointer is
    /// on), tuned again; or, editing a pattern, the end (or origin) dragged there
    @discardableResult
    public func moveTuning(to p: KiCadPoint) -> TuningPreview? {
        guard var s = patternSession else { return nil }
        let q = Self.nm(p)
        s.pointer = q
        switch s.kind {
        case .placing:
            s.pattern.end = q
            s.pattern.updateSideFromEnd = true
        case .dragging(let end):
            // (UpdateFromEditPoints: a pair's edit points on the line between its two lines)
            var offsetStart = IPoint.zero, offsetEnd = IPoint.zero
            if s.pattern.mode == .diffPair, let c = s.pattern.baseLineCoupled, c.segmentCount > 0 {
                let a = c.point(0) - s.pattern.origin, b = c.lastPoint - s.pattern.end
                offsetStart = IPoint(a.x / 2, a.y / 2)
                offsetEnd = IPoint(b.x / 2, b.y / 2)
            }
            if end { s.pattern.end = q - offsetEnd } else { s.pattern.origin = q - offsetStart }
        }
        patternSession = s
        updateTuningPattern()
        return tuningPreview
    }

    /// The meanders' amplitude a step up (1) or down (-1), tuned again (the tool's Increase and Decrease Amplitude)
    @discardableResult
    public func stepTuningAmplitude(_ sign: Int) -> TuningPreview? {
        guard var s = patternSession, let placer = router.router.meanderPlacer else { return nil }
        placer.amplitudeStep(sign)
        s.pattern.setMaxAmplitude(placer.meanderSettings.maxAmplitude)
        if case .placing(var tool) = s.kind {
            tool.maxAmplitude = placer.meanderSettings.maxAmplitude
            s.kind = .placing(tool: tool)
        }
        patternSession = s
        updateTuningPattern()
        return tuningPreview
    }

    /// The meanders' spacing a step up (1) or down (-1), tuned again (the tool's Increase and Decrease Spacing)
    @discardableResult
    public func stepTuningSpacing(_ sign: Int) -> TuningPreview? {
        guard var s = patternSession, let placer = router.router.meanderPlacer else { return nil }
        placer.spacingStep(sign)
        s.pattern.settings.spacing = placer.meanderSettings.spacing
        if case .placing(var tool) = s.kind {
            tool.spacing = placer.meanderSettings.spacing
            s.kind = .placing(tool: tool)
        }
        patternSession = s
        updateTuningPattern()
        return tuningPreview
    }

    /// The tuning's settings changed (the length or skew to reach, the meanders' sizes, corners and sides), tuned
    /// again: the tool's settings, given to the pattern placed (the tool's settings dialog: applyCommonSettings);
    /// the pattern edited's own
    @discardableResult
    public func updateTuningSettings(_ settings: MeanderSettings) -> TuningPreview? {
        guard var s = patternSession else { return nil }
        if case .placing = s.kind { s.kind = .placing(tool: settings) }
        s.pattern.settings = settings
        patternSession = s
        if case .placing = s.kind, s.pattern.origin == s.pattern.end {
            hoverStatus()
        } else {
            updateTuningPattern()
        }
        return tuningPreview
    }

    /// A click at `p`, tuning: the pattern kept (EditStart, Update and EditFinish, as the tool's second click keeps
    /// it; a drag's end, as the point editor finishes it), the change ("Tune Length", "Tune Skew"; "Edit Tuning
    /// Pattern"); nil if there was nothing to keep (the pointer not moved since it started)
    public func fixTuning(at p: KiCadPoint) -> Edit? {
        guard var s = patternSession else { return nil }
        let q = Self.nm(p)
        if q != s.pointer {
            moveTuning(to: p)
            s = patternSession!
        }
        patternSession = nil
        let name: String
        switch s.kind {
        case .placing:
            name = s.pattern.mode == .skew ? "Tune Skew" : "Tune Length"
            router.patternEditStart(&s.pattern)
            router.patternUpdate(&s.pattern)
        case .dragging:
            name = "Edit Tuning Pattern"
        }
        router.patternEditFinish(&s.pattern)
        return change(name)
    }

    /// The tuning dropped, the board as it was (EditCancel)
    public func cancelTuning() {
        guard var s = patternSession else { return }
        patternSession = nil
        s.pattern.inEdit = true
        router.patternEditCancel(&s.pattern)
    }

    /// Whether a pattern is being placed or edited
    public var isTuning: Bool { patternSession != nil }

    /// What is being tuned, as it now is
    public var tuningPreview: TuningPreview? {
        guard let t = router.tuning else { return nil }
        let nets = router.router.currentNets.map { $0.flatMap { router.world.netNames[$0] } ?? "" }
        return TuningPreview(lines: t.lines.map { $0.points.map(Self.mm) }, width: Double(t.width) / 1e6,
                             layer: router.layerName(t.layer), nets: nets, status: Self.previewStatus(t.status),
                             length: Double(t.length) / 1e6)
    }

    /// The pattern being placed or edited, as it now is (its outline, origin and end, for drawing)
    public var tuningPatternPreview: TuningPatternInfo? { patternSession.map { info($0.pattern) } }

    // MARK: - Patterns edited, tuned again and taken away

    /// The tuning pattern of `uuid` given new settings (its target, its meanders' sizes, corners and sides), a new
    /// origin or end, or a width, and tuned again, as its properties panel changes it (the property set, then
    /// EditStart, Update and EditFinish): one change, "Edit Tuning Pattern"; nil if there is no such pattern or
    /// nothing changed
    public func editTuningPattern(_ uuid: String, settings: MeanderSettings? = nil, origin: KiCadPoint? = nil,
                                  end: KiCadPoint? = nil, width: Double? = nil) -> Edit? {
        guard !isRouting, patternSession == nil, var p = tuningPattern(uuid) else { return nil }
        if let settings { p.settings = settings }
        if let origin { p.origin = Self.nm(origin) }
        if let end { p.end = Self.nm(end) }
        if let width { p.trackWidth = KiMath.round(width * 1e6) }
        router.patternEditStart(&p)
        router.patternUpdate(&p)
        router.patternEditFinish(&p)
        return change("Edit Tuning Pattern")
    }

    /// Every tuning pattern of the board tuned again in turn, in the board's order, as Edit > Update All Tuning
    /// Patterns tunes them (EditStart, Update and EditFinish of each): one change, "Update Tuning Patterns"; nil if
    /// nothing changed
    public func updateAllTuningPatterns() -> Edit? {
        guard !isRouting, patternSession == nil else { return nil }
        var added: [String] = [], removed: [String] = []
        for uuid in router.patternMemory.all(router.board).map(\.uuid) {
            guard var p = tuningPattern(uuid) else { continue }
            router.patternEditStart(&p)
            router.patternUpdate(&p)
            router.patternEditFinish(&p)
            // (what a pattern made and the next took off again was not made)
            for r in router.lastRemoved {
                if let i = added.firstIndex(of: r) { added.remove(at: i) } else { removed.append(r) }
            }
            added += router.lastAdded
        }
        router.lastAdded = added
        router.lastRemoved = removed
        return change("Update Tuning Patterns")
    }

    /// The tuning pattern of `uuid` deleted, its line made straight along its base line again (Remove, as KiCad's
    /// Delete of the pattern alone does it): one change, "Delete"; nil if there is no such pattern
    public func removeTuningPattern(_ uuid: String) -> Edit? {
        guard !isRouting, patternSession == nil, let p = tuningPattern(uuid) else { return nil }
        router.patternRemove(p)
        return change("Delete")
    }

    /// The tuning patterns made, changed or taken away from `before` to `after`, by id
    static func generatorsChanged(_ before: KiCadBoard, _ after: KiCadBoard) -> [String] {
        func byID(_ b: KiCadBoard) -> [String: String] {
            Dictionary(b.root.all("generated").map { ($0.value("uuid") ?? "", $0.compact) }, uniquingKeysWith: { a, _ in a })
        }
        let old = byID(before), new = byID(after)
        return Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }.sorted()
    }
}
