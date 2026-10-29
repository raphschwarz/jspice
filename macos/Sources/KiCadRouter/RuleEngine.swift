// Ported from KiCad 10.0.7: pcbnew/drc/drc_engine.cpp (DRC_ENGINE: loadImplicitRules, loadRules, compileRules,
// InitEngine's falling back on the implicit rules when the user's do not parse, EvalRules with its net ties, local
// overrides, the net class clearances' fast way, its inheritance from a pad's footprint, the clearance's local
// clearances and board minimum, EvalZoneConnection, ProcessAssertions, HasRulesForConstraintType,
// QueryWorstConstraint, HasConditionalConstraint, HasUserDefinedPhysicalConstraint) and
// common/project/net_settings.cpp (the net classes the implicit rules are made of, composite ones among them).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// KiCad's design rules engine (DRC_ENGINE) on a board: the implicit rules it makes of the board's setup, net
/// classes and keepout areas, and the rules of the user's own (a .kicad_dru), each constraint type's in order, and
/// how EvalRules resolves which constraint applies to an item, or to two
final class DesignRuleEngine {
    /// What the implicit rules take from the board's design settings (BOARD_DESIGN_SETTINGS)
    struct Setup {
        var minClearance = 0
        var trackMinWidth = 0
        var minConnection = 0
        var minThroughDrill = 0
        var viasMinAnnularWidth = 0
        var viasMinSize = 0
        var holeToHoleMin = 0
        var minResolvedSpokes = 2
        var silkClearance = 0
        var minSilkTextHeight = 800_000
        var minSilkTextThickness = 80_000
        var holeClearance = 0
        var copperEdgeClearance = 0
        var microViasMinDrill = 0
        var microViasMinSize = 0
    }

    /// One constraint of a rule, with what decides where it applies (DRC_ENGINE_CONSTRAINT)
    struct Entry {
        let layerTest: KiLayerSet
        let condition: RuleCondition?
        let constraint: DRCConstraint
        let parentRule: DesignRule
        /// An implicit keepout rule's zone
        let implicitKeepoutZone: RuleItem?
    }

    let board: RuleBoard
    let setup: Setup
    private(set) var rules: [DesignRule] = []
    private var constraintMap: [DRCConstraintType: [Entry]] = [:]
    /// The user's rules, as their file has them (none if it has an error)
    private(set) var userRules: [DesignRule] = []
    /// The user's rules file's error, if it has one: KiCad then goes by its implicit rules alone
    private(set) var rulesError: RulesError?
    private(set) var hasExplicitClearanceRules = false
    private(set) var hasDiffPairClearanceOverrides = false
    private(set) var hasGeometryDependentRules = false
    /// Each net class's clearance, for the fast way to a net class clearance (m_netclassClearances)
    private var netclassClearances: [String: Int] = [:]
    /// The keepout zones the implicit rules are made of, by uuid
    private var keepoutZones: [String: RuleItem] = [:]

    /// The engine on `board`: the implicit rules of `setup`, `netClasses` (the nets' effective classes among
    /// `nets`) and `keepouts` (the board's rule areas then its footprints', in order), then the rules of
    /// `rulesText`, a .kicad_dru's
    init(board: RuleBoard, setup: Setup, netClasses: NetClasses, nets: [String], keepouts: [RuleItem], rulesText: String?) {
        self.board = board
        self.setup = setup
        loadImplicitRules(netClasses, nets, keepouts)
        var user: [DesignRule] = []
        if let text = rulesText {
            if text.contains("${") {
                // (KiCad expands the board's text variables in it first, and cross references; the port does not)
                board.unsupported.insert("text variables in the design rules")
            }
            var parser = DesignRulesParser(text)
            parser.userLayerNames = board.userLayerNames
            do {
                user = try parser.parse()
            } catch let e as RulesError {
                // (loadRules threw: none of the file's rules)
                rulesError = e
            } catch {}
        }
        rules += user
        do {
            try compileRules()
            userRules = user
        } catch let e as RulesError {
            // InitEngine's retry with the implicit rules alone: made and compiled again, into the constraints the
            // failed compilation left (those of the rules before the one that failed, the user's among them, stay)
            rulesError = e
            rules = []
            loadImplicitRules(netClasses, nets, keepouts)
            try? compileRules()
            userRules = user
        } catch {}
    }

    // MARK: - Implicit rules (loadImplicitRules)

    private func implicitRule(_ name: String, _ source: ImplicitSource) -> DesignRule {
        let r = DesignRule(name: name, implicit: source)
        rules.append(r)
        return r
    }

    private func loadImplicitRules(_ netClasses: NetClasses, _ nets: [String], _ keepouts: [RuleItem]) {
        func constraint(_ type: DRCConstraintType, min: Int? = nil, opt: Int? = nil, max: Int? = nil) -> DRCConstraint {
            var c = DRCConstraint(type)
            if let min { c.value.setMin(min) }
            if let opt { c.value.setOpt(opt) }
            if let max { c.value.setMax(max) }
            return c
        }
        // 1) global defaults
        var rule = implicitRule("board setup constraints", .boardSetup)
        rule.add(constraint(.trackWidth, min: setup.trackMinWidth))
        rule.add(constraint(.connectionWidth, min: setup.minConnection))
        rule.add(constraint(.holeSize, min: setup.minThroughDrill))
        rule.add(constraint(.annularWidth, min: setup.viasMinAnnularWidth))
        rule.add(constraint(.viaDiameter, min: setup.viasMinSize))
        rule.add(constraint(.holeToHole, min: setup.holeToHoleMin))
        rule = implicitRule("board setup constraints zone fill strategy", .boardSetup)
        rule.add(constraint(.minResolvedSpokes, min: setup.minResolvedSpokes))
        let silk = KiLayerSet([KiLayer.fSilkS, KiLayer.bSilkS])
        rule = implicitRule("board setup constraints silk", .boardSetup)
        rule.layerCondition = silk
        rule.add(constraint(.silkClearance, min: setup.silkClearance))
        rule = implicitRule("board setup constraints silk text height", .boardSetup)
        rule.layerCondition = silk
        rule.add(constraint(.textHeight, min: setup.minSilkTextHeight))
        rule = implicitRule("board setup constraints silk text thickness", .boardSetup)
        rule.layerCondition = silk
        rule.add(constraint(.textThickness, min: setup.minSilkTextThickness))
        rule = implicitRule("board setup constraints hole", .boardSetup)
        rule.add(constraint(.holeClearance, min: setup.holeClearance))
        rule = implicitRule("board setup constraints edge", .boardSetup)
        rule.add(constraint(.edgeClearance, min: setup.copperEdgeClearance))
        // (KiCad sets the hole to hole constraint's minimum here, not the courtyard's: the courtyard's has none)
        rule = implicitRule("board setup constraints courtyard", .boardSetup)
        rule.add(constraint(.courtyardClearance))
        // 2a) micro vias
        let uVia = implicitRule("board setup constraints micro-via", .boardSetup)
        uVia.condition = RuleCondition("A.Via_Type == 'Micro'")
        uVia.add(constraint(.holeSize, min: setup.microViasMinDrill))
        uVia.add(constraint(.viaDiameter, min: setup.microViasMinSize))
        // 2b) barcodes
        let barcode = implicitRule("barcode visual separation default", .barcodeDefaults)
        barcode.add(constraint(.physicalClearance, min: 1_000_000))
        barcode.condition = RuleCondition("A.Type == 'Barcode'")
        // 3) the net classes' rules: each class's clearance and width rules sorted by their minimums, then the
        // others
        var clearanceRules: [DesignRule] = []
        var itemRules: [DesignRule] = []
        func makeNetclassRules(_ nc: NetClasses.ResolvedClass) {
            let ncName = nc.name.replacingOccurrences(of: "'", with: "\\'")
            func rule(_ name: String, _ expr: String) -> DesignRule {
                let r = DesignRule(name: name, implicit: .netClass)
                r.condition = RuleCondition(expr)
                return r
            }
            if let c = nc.clearance {
                let r = rule("netclass '\(nc.parent(\.clearance))'", "A.hasExactNetclass('\(ncName)')")
                clearanceRules.append(r)
                r.add(constraint(.clearance, min: c))
                netclassClearances[nc.name] = c
            }
            if let w = nc.trackWidth {
                let r = rule("netclass '\(nc.parent(\.trackWidth))'", "A.hasExactNetclass('\(ncName)')")
                clearanceRules.append(r)
                r.add(constraint(.trackWidth, min: setup.trackMinWidth, opt: w))
            }
            if let w = nc.diffPairWidth {
                let r = rule("netclass '\(nc.parent(\.diffPairWidth))' (diff pair)", "A.hasExactNetclass('\(ncName)') && A.inDiffPair('*')")
                itemRules.append(r)
                r.add(constraint(.trackWidth, min: setup.trackMinWidth, opt: w))
            }
            if let g = nc.diffPairGap {
                let r = rule("netclass '\(nc.parent(\.diffPairGap))' (diff pair)", "A.hasExactNetclass('\(ncName)')")
                itemRules.append(r)
                r.add(constraint(.diffPairGap, min: setup.minClearance, opt: g))
                // (a narrower gap than the class's clearance overrides it between the pair's two)
                if g < (nc.clearance ?? -1) {
                    let r2 = rule("netclass '\(nc.parent(\.diffPairGap))' (diff pair)", "A.hasExactNetclass('\(ncName)') && AB.isCoupledDiffPair()")
                    itemRules.append(r2)
                    r2.add(constraint(.clearance, min: g))
                    hasDiffPairClearanceOverrides = true
                }
            }
            if let d = nc.viaDiameter {
                let r = rule("netclass '\(nc.parent(\.viaDiameter))'", "A.hasExactNetclass('\(ncName)') && A.Via_Type != 'Micro'")
                itemRules.append(r)
                r.add(constraint(.viaDiameter, min: setup.viasMinSize, opt: d))
            }
            if let d = nc.viaDrill {
                let r = rule("netclass '\(nc.parent(\.viaDrill))'", "A.hasExactNetclass('\(ncName)') && A.Via_Type != 'Micro'")
                itemRules.append(r)
                r.add(constraint(.holeSize, min: setup.minThroughDrill, opt: d))
            }
            if let d = nc.microViaDiameter {
                let r = rule("netclass '\(nc.parent(\.microViaDiameter))' (uvia)", "A.hasExactNetclass('\(ncName)') && A.Via_Type == 'Micro'")
                itemRules.append(r)
                // (KiCad sets its minimum twice, the class's value last)
                r.add(constraint(.viaDiameter, min: d))
            }
            if let d = nc.microViaDrill {
                let r = rule("netclass '\(nc.parent(\.microViaDrill))' (uvia)", "A.hasExactNetclass('\(ncName)') && A.Via_Type == 'Micro'")
                itemRules.append(r)
                r.add(constraint(.holeSize, min: setup.microViasMinDrill, opt: d))
            }
        }
        makeNetclassRules(netClasses.resolvedDefault)
        for name in netClasses.classes.keys.sorted() { makeNetclassRules(netClasses.resolved(name)) }
        for c in netClasses.composites(nets) { makeNetclassRules(c) }
        if netClasses.hasTuningProfiles { board.unsupported.insert("tuning profiles") }
        Clipper.introSort(&clearanceRules) { $0.constraints[0].value.min < $1.constraints[0].value.min }
        rules += clearanceRules
        rules += itemRules
        // 5) keepout areas
        for zone in keepouts where zone.isKeepoutZone {
            let ref = zone.parentFootprint.map { $0.reference.isEmpty ? "<no reference designator>" : $0.reference }
            let name = zone.zoneName.isEmpty ? (ref.map { "keepout area of \($0)" } ?? "keepout area")
                : (ref.map { "keepout area '\(zone.zoneName)' of \($0)" } ?? "keepout area '\(zone.zoneName)'")
            let r = implicitRule(name, .keepout)
            r.implicitZone = zone.uuid
            keepoutZones[zone.uuid] = zone
            r.condition = RuleCondition("A.intersectsKeepout('\(zone.uuid)')")
            r.layerCondition = zone.layerSet
            var flags: DisallowFlags = []
            if zone.keepoutTracks { flags.insert(.tracks) }
            if zone.keepoutVias { flags.insert(.vias) }
            if zone.keepoutPads { flags.insert(.pads) }
            if zone.keepoutZoneFills { flags.insert(.zones) }
            if zone.keepoutFootprints { flags.insert(.footprints) }
            var c = DRCConstraint(.disallow)
            c.disallowFlags = flags
            r.add(c)
        }
    }

    // MARK: - compileRules

    /// compileRules: each rule's condition compiled (one KiCad reports an error of throws, the constraints of the rules
    /// before it already added) and its constraints added to their types' lists, which this does not empty first
    private func compileRules() throws {
        for rule in rules {
            var condition: RuleCondition?
            if let c = rule.condition, !c.expression.isEmpty {
                condition = c
                let ok = c.compile()
                if !ok || !c.errors.isEmpty { throw RulesError(message: "Parse error in rule '\(rule.name)'", line: 0, offset: 0) }
            }
            for c in rule.constraints {
                let zone = rule.isImplicit && c.type == .disallow ? rule.implicitZone.flatMap { keepoutZones[$0] } : nil
                constraintMap[c.type, default: []].append(Entry(layerTest: rule.layerCondition, condition: condition, constraint: c,
                                                                parentRule: rule, implicitKeepoutZone: zone))
            }
        }
        hasExplicitClearanceRules = false
        hasGeometryDependentRules = false
        for (type, entries) in constraintMap {
            for e in entries where !e.parentRule.isImplicit {
                if type == .clearance { hasExplicitClearanceRules = true }
                if e.condition?.hasGeometryDependentFunctions == true { hasGeometryDependentRules = true }
            }
        }
    }

    // MARK: - Queries

    /// HasRulesForConstraintType
    func hasRules(_ type: DRCConstraintType) -> Bool { !(constraintMap[type] ?? []).isEmpty }

    /// The constraint types the user's rules have
    var userConstraintTypes: Set<DRCConstraintType> {
        Set(constraintMap.filter { $0.value.contains { !$0.parentRule.isImplicit } }.keys)
    }

    /// QueryWorstConstraint: the greatest minimum among the constraints of a type (only those with no condition, if
    /// asked), nil if none is above 0
    func worstConstraint(_ type: DRCConstraintType, unconditionalOnly: Bool = false) -> DRCConstraint? {
        var worst = 0
        var found: DRCConstraint?
        for e in constraintMap[type] ?? [] {
            if unconditionalOnly && e.condition != nil { continue }
            let current = e.constraint.value.min
            if current > worst {
                worst = current
                found = e.constraint
            }
        }
        return worst > 0 ? found : nil
    }

    /// BOARD_DESIGN_SETTINGS::GetBiggestClearanceValue: the board's minimums and each clearance type's worst
    /// constraint (where a type has none above 0, the one found before it counted again, as KiCad's query leaves it)
    func biggestClearanceValue(_ s: BoardDRC.Settings) -> Int {
        var biggest = max(s.minClearance, s.holeClearance, s.holeToHole, s.edgeClearance)
        var constraint = DRCConstraint(.null)
        for t in [DRCConstraintType.clearance, .physicalClearance, .physicalHoleClearance, .holeClearance, .edgeClearance, .holeToHole] {
            if let c = worstConstraint(t) { constraint = c }
            biggest = max(biggest, constraint.value.min)
        }
        return min(biggest, BoardWorld.maximumClearance)
    }

    /// HasConditionalConstraint: a rule of the user's with a condition, of a type
    func hasConditionalConstraint(_ type: DRCConstraintType) -> Bool {
        (constraintMap[type] ?? []).contains { $0.condition != nil && !$0.parentRule.isImplicit }
    }

    /// HasUserDefinedPhysicalConstraint
    var hasUserDefinedPhysicalConstraint: Bool {
        hasConditionalConstraint(.physicalClearance) || hasConditionalConstraint(.physicalHoleClearance)
    }

    // MARK: - EvalRules

    /// isKeepoutZone( item, false ) or not on copper: "non copper" to EvalRules
    private static func nonCopper(_ i: RuleItem?) -> Bool {
        guard let i else { return false }
        return !i.isOnCopper || i.isKeepoutZone
    }

    /// The disallow mask of an item: what kind of thing it is to a disallow constraint
    private static func disallowMask(_ a: RuleItem) -> DisallowFlags {
        if a.holeProxy { return .holes }
        switch a.kind {
        case .via:
            switch a.viaType ?? .through {
            case .microVia: return .microVias
            case .blind: return .blindVias
            case .buried: return .buriedVias
            default: return .throughVias
            }
        case .track, .arc: return .tracks
        case .pad: return .pads
        case .footprint: return .footprints
        case .shape, .barcode: return .graphics
        case .field, .text, .textBox, .table: return .texts
        case .zone: return a.isTeardrop ? .tracks : .zones
        default: return []
        }
    }

    /// EvalRules: the constraint of a type that applies to `a` (and `b`) on `layer` (KiLayer.undefined for any)
    func evalRules(_ type: DRCConstraintType, _ aIn: RuleItem?, _ bIn: RuleItem?, layer: Int) -> DRCConstraint {
        var a = aIn, b = bIn
        let ac = a.flatMap { $0.connected ? $0 : nil }
        let bc = b.flatMap { $0.connected ? $0 : nil }
        let aNonCopper = Self.nonCopper(a), bNonCopper = Self.nonCopper(b)
        var pad: RuleItem?, zone: RuleItem?, parentFootprint: RuleItem?
        let inheritable: Set<DRCConstraintType> = [.zoneConnection, .thermalReliefGap, .thermalSpokeWidth, .solderMaskExpansion,
                                                   .solderPasteAbsMargin, .solderPasteRelMargin]
        if inheritable.contains(type) {
            if a?.kind == .pad { pad = a } else if a?.kind == .zone { zone = a }
            if b?.kind == .pad { pad = b } else if b?.kind == .zone { zone = b }
            parentFootprint = pad?.parentFootprint
        }
        var constraint = DRCConstraint(type)

        func apply(_ e: Entry) {
            let c = e.constraint
            if c.value.hasMin {
                constraint.implicitMin = e.parentRule.isImplicit
                constraint.value.setMin(c.value.min)
            }
            if c.value.hasOpt { constraint.value.setOpt(c.value.opt) }
            if c.value.hasMax { constraint.value.setMax(c.value.max) }
            switch c.type {
            case .clearance, .courtyardClearance, .silkClearance, .holeClearance, .edgeClearance, .physicalClearance, .physicalHoleClearance:
                if constraint.value.min > BoardWorld.maximumClearance { constraint.value.setMin(BoardWorld.maximumClearance) }
            default:
                break
            }
            constraint.disallowFlags = c.disallowFlags
            constraint.zoneConnection = c.zoneConnection
            constraint.parentRule = c.parentRule
            constraint.skewWithinDiffPairs = c.skewWithinDiffPairs
            constraint.spaceDomain = c.spaceDomain
            constraint.timeDomain = c.timeDomain
        }

        let footprints = (a?.parentFootprint, b?.parentFootprint)
        // a footprint's net tie: no clearance between its items and the nets it ties them to
        if type == .clearance && ((ac == nil) != (bc == nil) || (footprints.0 != nil && footprints.0 === footprints.1))
            && !aNonCopper && !bNonCopper {
            let children = [a, b], alt = [bc, ac]
            for ii in 0..<2 {
                guard let child = children[ii], child.parentFootprint != nil, let other = alt[ii] else { continue }
                if child.netTieNets.contains(other.netCode) {
                    constraint.name = "net tie"
                    constraint.value.setMin(0)
                    return constraint
                }
            }
        }
        // local overrides take precedence over everything but the board's minimum
        if type == .clearance || type == .holeClearance {
            let oa = ac != nil && !bNonCopper ? ac!.clearanceOverride : nil
            let ob = bc != nil && !aNonCopper ? bc!.clearanceOverride : nil
            if oa != nil || ob != nil {
                var value = 0, source = ""
                if let oa { (value, source) = oa }
                if let ob, ob.value > value { (value, source) = ob }
                if value != 0 {
                    if type == .clearance {
                        if value < setup.minClearance { (value, source) = (setup.minClearance, "board minimum") }
                    } else if value < setup.holeClearance {
                        (value, source) = (setup.holeClearance, "board minimum hole")
                    }
                    constraint.name = source
                    constraint.value.setMin(value)
                    return constraint
                }
            }
        } else if type == .zoneConnection {
            if let pad, pad.zoneConnection != .inherited {
                constraint.name = "pad"
                constraint.zoneConnection = pad.zoneConnection
                return constraint
            }
        } else if type == .thermalReliefGap {
            if let pad, let g = pad.thermalGapOverride, g > 0 {
                constraint.name = "pad"
                constraint.value.setMin(g)
                return constraint
            }
        } else if type == .thermalSpokeWidth {
            if let pad, var w = pad.spokeWidthOverride, w > 0 {
                if let zone, zone.zoneMinThickness > w { w = zone.zoneMinThickness }
                constraint.name = "pad"
                constraint.value.setMin(w)
                return constraint
            }
        } else if [.solderMaskExpansion, .solderPasteAbsMargin, .solderPasteRelMargin].contains(type) {
            board.unsupported.insert("solder mask and paste margins by rule")
        }

        // (within one call the items, layer and type are fixed: a condition's result goes by its expression)
        var conditionCache: [String: Bool] = [:]
        func checkCondition(_ e: Entry) -> Bool {
            guard let cond = e.condition else { return true }
            if let r = conditionCache[cond.expression] { return r }
            let r = cond.evaluate(a, b, constraint: e.constraint.type, layer: layer, board: board)
            conditionCache[cond.expression] = r
            return r
        }

        func process(_ e: Entry) {
            let implicit = e.parentRule.isImplicit
            let c = e.constraint
            if implicit && e.parentRule.implicitSource == .netClass {
                if c.type == .clearance && (aNonCopper || bNonCopper) { return }
                if !checkCondition(e) { return }
            }
            if c.type == .clearance {
                if aNonCopper || bNonCopper { return }
            } else if c.type == .disallow {
                guard let a else { return }
                // (a footprint's own keepout never applies to it)
                if let z = e.implicitKeepoutZone, a === z.parentFootprint { return }
                if c.disallowFlags.intersection(Self.disallowMask(a)).isEmpty { return }
                var itemLayers = a.layerSet
                if a.kind == .footprint, let yards = a.courtyards {
                    if !yards.front.polygons.isEmpty { itemLayers = itemLayers.union(.front) }
                    if !yards.back.polygons.isEmpty { itemLayers = itemLayers.union(.back) }
                }
                if !e.layerTest.intersects(itemLayers) { return }
            }
            if (layer >= 0 && layer < KiLayer.count && !e.layerTest.contains(layer)) || !board.enabledLayers.intersects(e.layerTest) {
                return
            } else if c.type == .holeToHole && !(a?.hasDrilledHole ?? false) && !(b?.hasDrilledHole ?? false) {
                return
            } else if e.condition == nil || e.condition!.expression.isEmpty {
                apply(e)
            } else {
                let matched = implicit && e.parentRule.implicitSource == .netClass ? true : checkCondition(e)
                if matched { apply(e) }
            }
        }

        // the fast way to a net class clearance, with no clearance rules of the user's and no diff pair overrides
        if type == .clearance && !hasExplicitClearanceRules && !hasDiffPairClearanceOverrides && !aNonCopper && (b == nil || !bNonCopper) {
            var clearance = 0
            if let ac, let v = netclassClearances[ac.netClass.name] { clearance = v }
            if let bc, let v = netclassClearances[bc.netClass.name] { clearance = max(clearance, v) }
            if clearance > 0 {
                constraint.value.setMin(clearance)
                constraint.implicitMin = true
            }
        } else {
            for e in constraintMap[type] ?? [] { process(e) }
        }
        if let p = constraint.parentRule, !p.isImplicit { return constraint }

        // what a pad inherits from its footprint: the rules asked of the footprint
        if let pad, let fp = parentFootprint, inheritable.contains(type) {
            if a === pad { a = fp } else { b = fp }
            conditionCache = [:]
            if let entries = constraintMap[type] {
                for e in entries { process(e) }
                if let p = constraint.parentRule, !p.isImplicit { return constraint }
            }
        }

        if type == .clearance {
            // (local clearances, a zone's, max'ed with the net classes': no implicit rule can be)
            var clearance = constraint.value.min
            if let ac, let local = ac.localClearance, local.value > clearance {
                clearance = local.value
                constraint.parentRule = nil
                constraint.name = local.source
                constraint.value.setMin(clearance)
            }
            if let bc, let local = bc.localClearance, local.value > clearance {
                clearance = local.value
                constraint.parentRule = nil
                constraint.name = local.source
                constraint.value.setMin(clearance)
            }
            if !aNonCopper && !bNonCopper && clearance < setup.minClearance {
                constraint.parentRule = nil
                constraint.name = "board minimum"
                constraint.value.setMin(setup.minClearance)
            }
            return constraint
        } else if type == .diffPairGap {
            if constraint.value.min < setup.minClearance {
                constraint.parentRule = nil
                constraint.name = "board minimum"
                constraint.value.setMin(setup.minClearance)
            }
            return constraint
        } else if type == .zoneConnection {
            if let pad, let fp = parentFootprint, pad.kind == .pad, fp.zoneConnection != .inherited {
                constraint.parentRule = nil
                constraint.name = "footprint"
                constraint.zoneConnection = fp.zoneConnection
                return constraint
            }
            if let zone {
                constraint.parentRule = nil
                constraint.name = "zone"
                constraint.zoneConnection = zone.zonePadConnection
                return constraint
            }
        } else if type == .thermalReliefGap {
            if let zone {
                constraint.parentRule = nil
                constraint.name = "zone"
                constraint.value.setMin(zone.zoneThermalGap)
                return constraint
            }
        } else if type == .thermalSpokeWidth {
            if let zone {
                constraint.parentRule = nil
                constraint.name = "zone"
                constraint.value.setMin(zone.zoneSpokeWidth)
                return constraint
            }
        }
        if constraint.parentRule == nil {
            constraint.type = .null
            constraint.disallowFlags = []
        }
        return constraint
    }

    /// EvalZoneConnection: the zone connection, a thermal relief through a hole only for a plated through hole pad
    func evalZoneConnection(_ a: RuleItem, _ b: RuleItem, layer: Int) -> DRCConstraint {
        var c = evalRules(.zoneConnection, a, b, layer: layer)
        if c.zoneConnection == .thtThermal {
            let pad = a.kind == .pad ? a : b.kind == .pad ? b : nil
            c.zoneConnection = pad?.padAttribute == .pth ? .thermal : .full
        }
        return c
    }

    /// ProcessAssertions: each assertion of the rules whose condition the item meets, failed where its test is false
    func processAssertions(_ a: RuleItem, failed: (DRCConstraint) -> Void) {
        for e in constraintMap[.assertion] ?? [] {
            let applies = e.condition == nil || e.condition!.expression.isEmpty
                || e.condition!.evaluate(a, nil, constraint: e.constraint.type, layer: a.layer, board: board)
            guard applies else { continue }
            if !(e.constraint.test?.evaluate(a, nil, constraint: e.constraint.type, layer: a.layer, board: board) ?? false) {
                failed(e.constraint)
            }
        }
    }
}

// MARK: - Net classes as the implicit rules see them

extension NetClasses {
    /// A net class with its values and, for each, the class it comes from (a composite's from its constituents')
    struct ResolvedClass {
        var name: String
        var clearance: Int?, trackWidth: Int?, diffPairWidth: Int?, diffPairGap: Int?, viaDiameter: Int?, viaDrill: Int?
        var microViaDiameter: Int?, microViaDrill: Int?
        var parents: [PartialKeyPath<ResolvedClass>: String] = [:]

        /// GetXParent()->GetHumanReadableName()
        func parent(_ k: PartialKeyPath<ResolvedClass>) -> String { parents[k] ?? name }
    }

    private static let valueKeys: [(KeyPath<NetClass, Int?>, WritableKeyPath<ResolvedClass, Int?>)] = [
        (\.clearance, \.clearance), (\.trackWidth, \.trackWidth), (\.diffPairWidth, \.diffPairWidth),
        (\.diffPairGap, \.diffPairGap), (\.viaDiameter, \.viaDiameter), (\.viaDrill, \.viaDrill),
        (\.microViaDiameter, \.microViaDiameter), (\.microViaDrill, \.microViaDrill),
    ]

    private static func resolve(_ c: NetClass) -> ResolvedClass {
        var r = ResolvedClass(name: c.name)
        for (from, to) in valueKeys { r[keyPath: to] = c[keyPath: from] }
        return r
    }

    var resolvedDefault: ResolvedClass { Self.resolve(defaultClass) }

    func resolved(_ name: String) -> ResolvedClass { Self.resolve(classes[name]!) }

    /// The composite classes of the nets (GetCompositeNetclasses: one for each set of classes a net has more than one
    /// of, or one lacking a value the default class fills), by name
    func composites(_ nets: [String]) -> [ResolvedClass] {
        var out: [String: ResolvedClass] = [:]
        for net in nets {
            let constituents = effectiveConstituents(net)
            guard constituents.count > 1 else { continue }
            let name = constituents.map(\.name).joined(separator: ",")
            if out[name] != nil { continue }
            // makeEffectiveNetclass: from the least important constituent up, each value the class's that has it
            var r = ResolvedClass(name: name)
            for c in constituents.reversed() {
                for (from, to) in Self.valueKeys where c[keyPath: from] != nil {
                    r[keyPath: to] = c[keyPath: from]
                    r.parents[to] = c.name
                }
            }
            out[name] = r
        }
        return out.keys.sorted().map { out[$0]! }
    }
}
