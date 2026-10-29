// Ported from KiCad 10.0.7: pcbnew/pcbexpr_functions.cpp (the rules' functions: existsOnLayer, isPlated, the
// courtyard intersections with collidesWithCourtyard, testFootprintSelector and searchFootprintsNearItem,
// intersectsArea, intersectsKeepout and enclosedByArea with getDeflatedZoneOutline, collidesWithArea and
// searchAreas, the group, footprint and sheet memberships, the via types, isCoupledDiffPair, inDiffPair, getField,
// hasNetclass, hasExactNetclass, hasComponentClass, fromTo), pcbnew/footprint_courtyard_index.cpp (the footprints a
// courtyard search finds), pcbnew/drc/drc_engine.cpp (MatchDpSuffix) and common/netclass.cpp
// (ContainsNetclassWithName).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// The built-in functions of KiCad's rules (PCBEXPR_BUILTIN_FUNCTIONS), by their names in lower case
enum RuleFunctions {
    static func lookup(_ name: String) -> RuleFunction? { table[name] }

    /// The functions that depend on where items are, not only on what they are
    static let geometryDependent: Set<String> = ["insidecourtyard", "insidefrontcourtyard", "insidebackcourtyard",
                                                 "intersectscourtyard", "intersectsfrontcourtyard", "intersectsbackcourtyard",
                                                 "insidearea", "intersectsarea", "intersectskeepout", "enclosedbyarea"]

    private static let table: [String: RuleFunction] = [
        "existsonlayer": existsOnLayer,
        "isplated": isPlated,
        "insidecourtyard": { intersectsCourtyard($0, $1, .both) },
        "insidefrontcourtyard": { intersectsCourtyard($0, $1, .front) },
        "insidebackcourtyard": { intersectsCourtyard($0, $1, .back) },
        "intersectscourtyard": { intersectsCourtyard($0, $1, .both) },
        "intersectsfrontcourtyard": { intersectsCourtyard($0, $1, .front) },
        "intersectsbackcourtyard": { intersectsCourtyard($0, $1, .back) },
        "insidearea": { intersectsArea($0, $1, forKeepout: true) },
        "intersectsarea": { intersectsArea($0, $1, forKeepout: false) },
        "intersectskeepout": { intersectsArea($0, $1, forKeepout: true) },
        "enclosedbyarea": enclosedByArea,
        "ismicrovia": { viaTest($0, $1) { $0 == .microVia } },
        "isblindvia": { viaTest($0, $1) { $0 == .blind } },
        "isburiedvia": { viaTest($0, $1) { $0 == .buried } },
        "isblindburiedvia": { viaTest($0, $1) { $0 == .blind || $0 == .buried } },
        "memberof": memberOfGroup,
        "memberofgroup": memberOfGroup,
        "memberoffootprint": memberOfFootprint,
        "memberofsheet": { memberOfSheet($0, $1, children: false) },
        "memberofsheetorchildren": { memberOfSheet($0, $1, children: true) },
        "fromto": fromTo,
        "iscoupleddiffpair": isCoupledDiffPair,
        "indiffpair": inDiffPair,
        "getfield": getField,
        "hasnetclass": hasNetclass,
        "hasexactnetclass": hasExactNetclass,
        "hascomponentclass": hasComponentClass,
    ]

    /// The result every function pushes first: 0, made something else after (immediately or when read)
    private static func result(_ ctx: RuleContext) -> RuleValue {
        let r = RuleValue(0)
        ctx.push(r)
        return r
    }

    // MARK: Layers and plating

    static func existsOnLayer(_ ctx: RuleContext, _ vref: RuleVarRef?) {
        let item = vref?.object(ctx)
        let arg = ctx.pop()
        let r = result(ctx)
        guard let item else { return }
        if arg.asString().isEmpty {
            if ctx.hasErrorCallback { ctx.reportError("Missing layer name argument to existsOnLayer().") }
            return
        }
        let board = ctx.board
        r.setDeferred { () -> Double in
            let mask = board?.layersMatching(arg.asString()) ?? KiLayerSet()
            return item.layerSet.intersects(mask) ? 1 : 0
        }
    }

    static func isPlated(_ ctx: RuleContext, _ vref: RuleVarRef?) {
        let r = result(ctx)
        guard let item = vref?.object(ctx) else { return }
        if item.kind == .pad && item.padAttribute == .pth { r.set(1) } else if item.kind == .via { r.set(1) }
    }

    static func viaTest(_ ctx: RuleContext, _ vref: RuleVarRef?, _ test: (Via.ViaType) -> Bool) {
        let item = vref?.object(ctx)
        let r = result(ctx)
        if let item, item.kind == .via, let t = item.viaType, test(t) { r.set(1) }
    }

    // MARK: Courtyards

    enum Side { case both, front, back }

    /// testFootprintSelector: a footprint by its reference or (a selector with a colon) its library link, a
    /// component class by ${CLASS:NAME}
    static func testFootprintSelector(_ fp: RuleItem, _ selector: String, _ ctx: RuleContext) -> Bool {
        if selector.isEmpty { return false }
        if selector.hasPrefix("$") && selector.hasSuffix("}") && selector.uppercased().hasPrefix("${CLASS:") {
            if ctx.board?.hasComponentClasses == true { ctx.unsupported("component classes") }
            return false
        }
        if WildMatch.matches(fp.reference, selector) { return true }
        if selector.contains(":") && WildMatch.matches(fp.fpid, selector) { return true }
        return false
    }

    /// SHAPE_POLY_SET::BBox: the box round its outlines
    static func polyBox(_ set: PolySet) -> IBox? {
        var box: IBox?
        for poly in set.polygons where poly[0].pointCount > 0 {
            if box == nil { box = poly[0].bbox } else { box!.merge(poly[0].bbox) }
        }
        return box
    }

    /// collidesWithCourtyard: a footprint's courtyard on a side against the item's shape (a zone's outline)
    static func collidesWithCourtyard(_ item: RuleItem, _ ctx: RuleContext, _ fp: RuleItem, front: Bool) -> Bool {
        guard let yards = fp.courtyards else { return false }
        let courtyard = front ? yards.front : yards.back
        guard !courtyard.polygons.isEmpty else { return false }
        guard let box = item.bbox, let cbox = polyBox(courtyard), cbox.intersects(box) else { return false }
        var set = courtyard
        set.cacheTriangulation()
        if item.kind == .zone {
            // (its outline, not its fill, which the filler asks the rules about: the courtyard's triangles each
            // against the outline's)
            guard var outline = item.zoneOutline else { return false }
            outline.cacheTriangulation()
            if !outline.isTriangulationUpToDate {
                // (what is left of a triangulation that failed goes by what KiCad cut of it before, and when)
                ctx.unsupported("the outline of a zone KiCad cannot cut into triangles against a courtyard")
            }
            for tpoly in set.triangulatedPolygons {
                for i in tpoly.triangles.indices {
                    let (a, b, c) = tpoly.triangle(i)
                    if BoardDRC.polySetCollide(outline, [.simple(LineChain([a, b, c], closed: true))], compound: true, wantActual: false) {
                        return true
                    }
                }
            }
            return false
        }
        guard let shapes = item.effectiveShape?(ctx.layer) else {
            ctx.unsupported("the shape of a \(item.kind.typeName.lowercased()) against a courtyard")
            return false
        }
        return BoardDRC.polySetCollide(set, shapes, compound: item.compoundShape, wantActual: false)
    }

    static func intersectsCourtyard(_ ctx: RuleContext, _ vref: RuleVarRef?, _ side: Side) {
        let arg = ctx.pop()
        let r = result(ctx)
        if arg.asString().isEmpty {
            if ctx.hasErrorCallback { ctx.reportError("Missing footprint argument (A, B, or reference designator) to intersectsCourtyard().") }
            return
        }
        guard let item = vref?.object(ctx) else { return }
        let a = ctx.items.0, b = ctx.items.1
        r.setDeferred { () -> Double in
            let selector = arg.asString()
            func test(_ fp: RuleItem) -> Bool {
                switch side {
                case .both: return collidesWithCourtyard(item, ctx, fp, front: true) || collidesWithCourtyard(item, ctx, fp, front: false)
                case .front: return collidesWithCourtyard(item, ctx, fp, front: !fp.flipped)
                case .back: return collidesWithCourtyard(item, ctx, fp, front: fp.flipped)
                }
            }
            // searchFootprintsNearItem: A or B the items themselves, else the footprints whose courtyards' box meets
            // the item's
            if selector == "A" { return a?.kind == .footprint && test(a!) ? 1 : 0 }
            if selector == "B" { return b?.kind == .footprint && test(b!) ? 1 : 0 }
            guard let box = item.bbox else { return 0 }
            for fp in ctx.board?.footprints ?? [] {
                guard let yards = fp.courtyards else { continue }
                var cbox: IBox?
                for c in [yards.front, yards.back] where !c.polygons.isEmpty {
                    if let b = polyBox(c) { if cbox == nil { cbox = b } else { cbox!.merge(b) } }
                }
                guard let cb = cbox, cb.intersects(box) else { continue }
                if testFootprintSelector(fp, selector, ctx) && test(fp) { return 1 }
            }
            return 0
        }
    }

    // MARK: Areas

    /// getDeflatedZoneOutline: an area's outline shrunk by the DRC's epsilon, so that touching is not colliding
    static func deflatedOutline(_ area: RuleItem, _ board: RuleBoard) -> PolySet {
        if let o = board.deflatedOutlines[area.uuid] { return o }
        var o = area.zoneOutline ?? PolySet()
        o.clearArcs()
        o.inflate(-board.epsilon, .allowAcuteCorners, maxError: 20_000)
        o.cacheTriangulation()
        board.deflatedOutlines[area.uuid] = o
        return o
    }

    /// collidesWithArea
    static func collidesWithArea(_ item: RuleItem, _ layer: Int, _ ctx: RuleContext, _ area: RuleItem, forKeepout: Bool) -> Bool {
        guard let board = ctx.board else { return false }
        let outline = deflatedOutline(area, board)
        if item.holeProxy {
            if item.kind == .pad, let h = item.holeShape {
                return BoardDRC.polySetCollide(outline, [h], compound: false, wantActual: false)
            } else if item.kind == .via, let h = item.holeShape {
                let overlap = item.layerSet.intersection(area.layerSet)
                if !overlap.isEmpty && (ctx.layer == KiLayer.undefined || overlap.contains(ctx.layer)) {
                    return BoardDRC.polySetCollide(outline, [h], compound: false, wantActual: false)
                }
            }
            return false
        }
        if item.kind == .footprint {
            guard let yards = item.courtyards else { return false }
            if yards.malformedFront || yards.malformedBack { return false }
            if area.layerSet.intersects(.front), let o = yards.front.polygons.first?[0],
               BoardDRC.polySetCollide(outline, [.chain(o)], compound: true, wantActual: false) {
                return true
            }
            if area.layerSet.intersects(.back), let o = yards.back.polygons.first?[0],
               BoardDRC.polySetCollide(outline, [.chain(o)], compound: true, wantActual: false) {
                return true
            }
            return false
        }
        if item.kind == .zone {
            if forKeepout {
                guard item.zoneFilled, let fill = item.zoneFills[layer], !fill.isEmpty else { return false }
                return BoardDRC.fillCollides(fill, outline)
            }
            // (the area's outline against the zone's, triangle by triangle)
            guard var zo = item.zoneOutline else { return false }
            zo.cacheTriangulation()
            if !zo.isTriangulationUpToDate {
                ctx.unsupported("the outline of a zone KiCad cannot cut into triangles against a rule area")
            }
            for tpoly in outline.triangulatedPolygons {
                for i in tpoly.triangles.indices {
                    let (a, b, c) = tpoly.triangle(i)
                    if BoardDRC.polySetCollide(zo, [.simple(LineChain([a, b, c], closed: true))], compound: true, wantActual: false) {
                        return true
                    }
                }
            }
            return false
        }
        guard area.layerSet.contains(layer) else { return false }
        guard let shapes = item.effectiveShape?(layer) else {
            ctx.unsupported("the shape of a \(item.kind.typeName.lowercased()) against a rule area")
            return false
        }
        return BoardDRC.polySetCollide(outline, shapes, compound: item.compoundShape, wantActual: false)
    }

    /// KIID::SniffTest: whether a string reads as a uuid
    static func isUUID(_ s: String) -> Bool {
        let chars = Array(s.lowercased())
        guard chars.count == 36 else { return false }
        for (i, c) in chars.enumerated() {
            if [8, 13, 18, 23].contains(i) {
                if c != "-" { return false }
            } else if !c.isHexDigit {
                return false
            }
        }
        return true
    }

    /// searchAreas: A or B (if a zone), a zone by its uuid, or the zones whose names match
    static func searchAreas(_ ctx: RuleContext, _ arg: String, _ f: (RuleItem?) -> Bool) -> Bool {
        if arg == "A" { return f(ctx.items.0?.kind == .zone ? ctx.items.0 : nil) }
        if arg == "B" { return f(ctx.items.1?.kind == .zone ? ctx.items.1 : nil) }
        let zones = ctx.board?.zones ?? []
        if isUUID(arg) {
            guard let z = zones.first(where: { $0.uuid.lowercased() == arg.lowercased() }) else { return false }
            return f(z)
        }
        for z in zones where WildMatch.matches(z.zoneName, arg) {
            if f(z) { return true }
        }
        return false
    }

    static func intersectsArea(_ ctx: RuleContext, _ vref: RuleVarRef?, forKeepout: Bool) {
        let arg = ctx.pop()
        let r = result(ctx)
        if arg.asString().isEmpty {
            if ctx.hasErrorCallback {
                ctx.reportError("Missing rule-area argument (A, B, or rule-area name) to \(forKeepout ? "intersectsKeepout()" : "intersectsArea()").")
            }
            return
        }
        guard let item = vref?.object(ctx) else { return }
        r.setDeferred { () -> Double in
            let layer = ctx.layer
            let res = searchAreas(ctx, arg.asString()) { area in
                // (not the item itself, nor the footprint the area is of)
                guard let area, area !== item, area.parentFootprint !== item else { return false }
                var areaLayers = area.layerSet
                if ctx.constraint == .silkClearance {
                    // (silkscreen clearances are tested across a side's layers)
                    if (area.layerSet.contains(KiLayer.fSilkS) && KiLayerSet.front.union(.frontTech).contains(layer))
                        || (area.layerSet.contains(KiLayer.bSilkS) && KiLayerSet.back.union(.backTech).contains(layer)) {
                        areaLayers.insert(layer)
                    }
                }
                let common = areaLayers.intersection(item.layerSet)
                guard !common.isEmpty else { return false }
                guard let abox = area.bbox, let ibox = item.bbox, abox.intersects(ibox) else { return false }
                let testLayers = layer != KiLayer.undefined ? [layer] : common.layers
                // (each layer's answer as the board's cache has it, for an item KiCad keeps answers of: a copper zone's
                // differs between the two functions, by its fill or by its outline, and the cache gives whichever was
                // asked first, which goes by the order KiCad's checks ask in)
                var toCompute: [Int] = []
                if !item.transient, let board = ctx.board {
                    for l in testLayers {
                        if let cached = board.intersectsAreaCache[RuleBoard.AreaKey(area: ObjectIdentifier(area), item: ObjectIdentifier(item), layer: l)] {
                            if cached.forKeepout != forKeepout && item.kind == .zone {
                                ctx.unsupported("a zone's collision with a rule area asked both as a keepout's and as an area's")
                            }
                            if cached.collides { return true }
                        } else {
                            toCompute.append(l)
                        }
                    }
                } else {
                    toCompute = testLayers
                }
                var any = false
                let scoped = RuleItem.withLayerSet(area, areaLayers)
                for l in toCompute {
                    let collides = collidesWithArea(item, l, ctx, scoped, forKeepout: forKeepout)
                    if !item.transient, let board = ctx.board {
                        board.intersectsAreaCache[RuleBoard.AreaKey(area: ObjectIdentifier(area), item: ObjectIdentifier(item), layer: l)] =
                            (collides, forKeepout)
                    }
                    if collides { any = true }
                }
                return any
            }
            return res ? 1 : 0
        }
    }

    static func enclosedByArea(_ ctx: RuleContext, _ vref: RuleVarRef?) {
        let arg = ctx.pop()
        let r = result(ctx)
        if arg.asString().isEmpty {
            if ctx.hasErrorCallback { ctx.reportError("Missing rule-area argument (A, B, or rule-area name) to enclosedByArea().") }
            return
        }
        guard let item = vref?.object(ctx) else { return }
        r.setDeferred { () -> Double in
            let layer = ctx.layer
            let res = searchAreas(ctx, arg.asString()) { area in
                guard let area, area !== item, area.parentFootprint !== item else { return false }
                if item.kind != .footprint && !area.layerSet.intersects(item.layerSet) { return false }
                guard let abox = area.bbox, let ibox = item.bbox, abox.intersects(ibox) else { return false }
                var shape: PolySet
                if item.kind == .zone {
                    shape = item.zoneOutline ?? PolySet()
                } else if item.kind == .footprint {
                    ctx.unsupported("a footprint enclosed by a rule area")
                    return false
                } else if let p = item.polygon?(layer) {
                    shape = p
                } else {
                    ctx.unsupported("the polygon of a \(item.kind.typeName.lowercased()) enclosed by a rule area")
                    return false
                }
                if shape.polygons.isEmpty { return false }
                shape.clearArcs()
                shape.booleanSubtract(area.zoneOutline ?? PolySet())
                return shape.polygons.isEmpty
            }
            return res ? 1 : 0
        }
    }

    // MARK: Memberships

    static func memberOfGroup(_ ctx: RuleContext, _ vref: RuleVarRef?) {
        let arg = ctx.pop()
        let r = result(ctx)
        if arg.asString().isEmpty {
            if ctx.hasErrorCallback { ctx.reportError("Missing group name argument to memberOfGroup().") }
            return
        }
        guard let item = vref?.object(ctx) else { return }
        r.setDeferred { () -> Double in
            // (an item of a footprint that is in no group of its own: the footprint's groups)
            let groups = item.groups.isEmpty ? item.parentFootprint?.groups ?? [] : item.groups
            return groups.contains { WildMatch.matches($0, arg.asString()) } ? 1 : 0
        }
    }

    static func memberOfFootprint(_ ctx: RuleContext, _ vref: RuleVarRef?) {
        let arg = ctx.pop()
        let r = result(ctx)
        if arg.asString().isEmpty {
            if ctx.hasErrorCallback { ctx.reportError("Missing footprint argument (reference designator) to memberOfFootprint().") }
            return
        }
        guard let item = vref?.object(ctx) else { return }
        r.setDeferred { () -> Double in
            if let fp = item.parentFootprint, testFootprintSelector(fp, arg.asString(), ctx) { return 1 }
            return 0
        }
    }

    static func memberOfSheet(_ ctx: RuleContext, _ vref: RuleVarRef?, children: Bool) {
        let arg = ctx.pop()
        let r = result(ctx)
        if arg.asString().isEmpty {
            if ctx.hasErrorCallback {
                ctx.reportError("Missing sheet name argument to \(children ? "memberOfSheetOrChildren()" : "memberOfSheet()").")
            }
            return
        }
        guard let item = vref?.object(ctx) else { return }
        r.setDeferred { () -> Double in
            guard let fp = item.parentFootprint ?? (item.kind == .footprint ? item : nil) else { return 0 }
            var sheetName = fp.sheetName
            var refName = arg.asString()
            if sheetName.hasSuffix("/") { sheetName.removeLast() }
            if refName.hasSuffix("/") { refName.removeLast() }
            if !children {
                if WildMatch.matches(sheetName, refName) { return 1 }
                if (WildMatch.matches(refName, "/") || refName.isEmpty) && sheetName.isEmpty { return 1 }
                return 0
            }
            // (wxSplit: the path's parts, an empty one before a leading slash)
            let sheetPath = sheetName.isEmpty ? [] : sheetName.components(separatedBy: "/")
            let refPath = refName.isEmpty ? [] : refName.components(separatedBy: "/")
            if refPath.count > sheetPath.count { return 0 }
            if (WildMatch.matches(refName, "/") || refName.isEmpty) && sheetName.isEmpty { return 1 }
            for i in refPath.indices where !WildMatch.matches(sheetPath[i], refPath[i]) { return 0 }
            return 1
        }
    }

    static func fromTo(_ ctx: RuleContext, _ vref: RuleVarRef?) {
        let item = vref?.object(ctx)
        _ = ctx.pop()
        _ = ctx.pop()
        _ = result(ctx)
        // (its from-to cache, of the connectivity's paths between pads, is not ported)
        if item != nil { ctx.unsupported("fromTo()") }
    }

    // MARK: Differential pairs

    /// MatchDpSuffix: the polarity of a net name's last letter that is not a digit or an underscore (1 for + or P,
    /// -1 for - or N, 0 for none), the net it is coupled with, and its base name
    static func matchDpSuffix(_ name: String) -> (polarity: Int, complement: String, base: String) {
        let chars = Array(name.unicodeScalars)
        var rv = 0, count = 0
        var complement = ""
        var i = chars.count - 1
        while i >= 0 && rv == 0 {
            let ch = chars[i]
            if ("0"..."9").contains(ch) || ch == "_" {
                i -= 1
                count += 1
                continue
            }
            switch ch {
            case "+": (complement, rv) = ("-", 1)
            case "-": (complement, rv) = ("+", -1)
            case "N": (complement, rv) = ("P", -1)
            case "P": (complement, rv) = ("N", 1)
            default: break
            }
            if rv == 0 { break }
            i -= 1
            count += 1
        }
        guard rv != 0 && count >= 1 else { return (rv, complement, "") }
        var base = String.UnicodeScalarView(chars.prefix(chars.count - count))
        let baseName = String(base)
        base.append(contentsOf: complement.unicodeScalars)
        base.append(contentsOf: chars.suffix(count - 1))
        return (rv, String(base), baseName)
    }

    static func isCoupledDiffPair(_ ctx: RuleContext, _ vref: RuleVarRef?) {
        let a = ctx.items.0.flatMap { $0.kind.isConnectedClass ? $0 : nil }
        let b = ctx.items.1.flatMap { $0.kind.isConnectedClass ? $0 : nil }
        let r = result(ctx)
        r.setDeferred { () -> Double in
            guard let a else { return 0 }
            let (polarity, coupled, _) = matchDpSuffix(a.netName)
            guard polarity != 0 else { return 0 }
            if [.diffPairGap, .length, .skew].contains(ctx.constraint) {
                // (asked only of a pair, B not always given)
                if ctx.board?.findNet(coupled) == true { return 1 }
            }
            if let b, b.netName == coupled { return 1 }
            return 0
        }
    }

    static func inDiffPair(_ ctx: RuleContext, _ vref: RuleVarRef?) {
        let argv = ctx.pop()
        let item = vref?.object(ctx)
        let r = result(ctx)
        if argv.asString().isEmpty {
            if ctx.hasErrorCallback { ctx.reportError("Missing diff-pair name argument to inDiffPair().") }
            return
        }
        guard let item, ctx.board != nil else { return }
        r.setDeferred { () -> Double in
            guard item.connected else { return 0 }
            let arg = argv.asString()
            let (polarity, coupled, base) = matchDpSuffix(item.netName)
            if polarity != 0 && ctx.board?.findNet(coupled) == true {
                if WildMatch.matches(base, arg) { return 1 }
                if base.hasSuffix("_"), let u = base.lastIndex(of: "_"), WildMatch.matches(String(base[..<u]), arg) { return 1 }
            }
            return 0
        }
    }

    // MARK: Fields and classes

    static func getField(_ ctx: RuleContext, _ vref: RuleVarRef?) {
        let arg = ctx.pop()
        let item = vref?.object(ctx)
        let r = RuleValue("")
        ctx.push(r)
        guard let item, ctx.board != nil else { return }
        r.setDeferred { () -> String in
            guard item.kind == .footprint else { return "" }
            return item.fields[arg.asString()] ?? ""
        }
    }

    static func hasNetclass(_ ctx: RuleContext, _ vref: RuleVarRef?) {
        let arg = ctx.pop()
        let r = result(ctx)
        if arg.asString().isEmpty {
            if ctx.hasErrorCallback { ctx.reportError("Missing netclass name argument to hasNetclass()") }
            return
        }
        guard let item = vref?.object(ctx) else { return }
        r.setDeferred { () -> Double in
            guard item.connected else { return 0 }
            return item.netClass.constituents.contains { WildMatch.matches($0, arg.asString()) } ? 1 : 0
        }
    }

    static func hasExactNetclass(_ ctx: RuleContext, _ vref: RuleVarRef?) {
        let arg = ctx.pop()
        let r = result(ctx)
        if arg.asString().isEmpty {
            if ctx.hasErrorCallback { ctx.reportError("Missing netclass name argument to hasExactNetclass()") }
            return
        }
        guard let item = vref?.object(ctx) else { return }
        r.setDeferred { () -> Double in
            guard item.connected else { return 0 }
            return item.netClass.name == arg.asString() ? 1 : 0
        }
    }

    static func hasComponentClass(_ ctx: RuleContext, _ vref: RuleVarRef?) {
        let arg = ctx.pop()
        let r = result(ctx)
        if arg.asString().isEmpty {
            if ctx.hasErrorCallback { ctx.reportError("Missing component class name argument to hasComponentClass()") }
            return
        }
        guard let item = vref?.object(ctx) else { return }
        r.setDeferred { () -> Double in
            guard item.kind == .footprint || item.parentFootprint != nil else { return 0 }
            // (a board with no component classes assigned: every footprint's class is empty)
            if ctx.board?.hasComponentClasses == true { ctx.unsupported("component classes") }
            return 0
        }
    }
}

extension RuleItem {
    /// A rule area's copy with another layer set (SCOPED_LAYERSET), the copy's uuid the area's
    static func withLayerSet(_ area: RuleItem, _ layers: KiLayerSet) -> RuleItem {
        guard layers != area.layerSet else { return area }
        let a = RuleItem(area.kind, uuid: area.uuid)
        a.layerSet = layers
        a.zoneOutline = area.zoneOutline
        a.bbox = area.bbox
        a.parentFootprint = area.parentFootprint
        return a
    }
}
