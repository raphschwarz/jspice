import XCTest
@testable import CircuitKit

/// Every kind of part is complete: named, with terminals and sane parameters, and decided on by each place that has to
/// know about it (the boards, the exports, the layout, the pacing). A kind that is forgotten somewhere fails here,
/// named, with what it is missing. See macos/docs/adding-a-part.md.
final class PartCatalogTests: XCTestCase {
    private let kinds = ElementKind.allCases

    /// A part of each kind with its default parameters, its terminals on nets of their own
    private func part(_ kind: ElementKind) -> NetlistPart {
        let name = self.name(kind)
        return NetlistPart(kind: kind, name: name, connections: Dictionary(
            kind.terminalNames.enumerated().map { ($0.element, "\(name)_\($0.element)") }, uniquingKeysWith: { a, _ in a }))
    }

    private func element(_ kind: ElementKind) -> Element {
        Element(kind: kind, name: name(kind), a: .zero, b: kind.defaultOffset)
    }

    /// A name of its own for the part of each kind: its prefix and its kind's place in the list ("U43")
    private func name(_ kind: ElementKind) -> String {
        kind.namePrefix + String((ElementKind.allCases.firstIndex(of: kind) ?? 0) + 1)
    }

    // MARK: - The kind itself

    func testEveryKindIsNamedAndHasTerminals() {
        var names: [String: ElementKind] = [:]
        for kind in kinds {
            let facts = kind.facts
            XCTAssertFalse(facts.displayName.isEmpty, "\(kind): no display name")
            if let other = names[facts.displayName] { XCTFail("\(kind) and \(other) share the display name \(facts.displayName)") }
            names[facts.displayName] = kind
            // a name is its prefix and a number ("R1", "MIC2"), so a prefix of letters alone is never read as another's
            XCTAssertTrue(!facts.namePrefix.isEmpty && facts.namePrefix.allSatisfy { $0.isASCII && $0.isUppercase },
                          "\(kind): name prefix \"\(facts.namePrefix)\" is not one to four capital letters")
            XCTAssertLessThanOrEqual(facts.namePrefix.count, 4, "\(kind): name prefix \(facts.namePrefix) is too long")
            XCTAssertTrue(ElementCategory.allCases.contains(facts.category))
            // a block's terminals are its ports'
            guard kind != .block else { continue }
            XCTAssertFalse(facts.terminalNames.isEmpty, "\(kind): no terminals")
            XCTAssertFalse(facts.terminalNames.contains(""), "\(kind): a terminal without a name")
            XCTAssertEqual(Set(facts.terminalNames).count, facts.terminalCount, "\(kind): two terminals share a name: \(facts.terminalNames)")
            // the canvas draws a post at each terminal
            XCTAssertEqual(element(kind).posts.count, facts.terminalCount, "\(kind): \(element(kind).posts.count) posts for \(facts.terminalCount) terminals")
        }
    }

    /// Units SI writes so that it reads them back as another value, known and not yet changed: each is a finding
    private static let unitsSIMisreads: [String: String] = [
        // "10 m1/V": read with the RKM code's digit after the prefix as 10.1 m
        "1/V": "nmos, pmos, njfet, pjfet lambda",
        // metres: "10 m" reads as 10 milli
        "m": "balancedCable length",
    ]

    func testEveryParameterIsSane() {
        for kind in kinds {
            var keys = Set<String>()
            for spec in kind.params {
                let what = "\(kind).\(spec.key)"
                XCTAssertFalse(spec.key.isEmpty || spec.name.isEmpty, "\(kind): a parameter without a key or a name")
                XCTAssertTrue(keys.insert(spec.key).inserted, "\(what): two parameters with this key")
                XCTAssertTrue(spec.range.contains(spec.defaultValue), "\(what): default \(spec.defaultValue) outside its range \(spec.range)")
                if spec.logarithmic {
                    XCTAssertGreaterThan(spec.range.lowerBound, 0, "\(what): a logarithmic slider from \(spec.range.lowerBound)")
                }
                if !spec.choices.isEmpty {
                    XCTAssertTrue(spec.choices.contains { $0.value == spec.defaultValue }, "\(what): default \(spec.defaultValue) is none of its choices")
                    for choice in spec.choices {
                        XCTAssertTrue(spec.range.contains(choice.value), "\(what): choice \(choice.name) outside its range")
                    }
                }
                // its unit is one SI writes and reads back: "4.7 kΩ" is 4700 again (a unit starting with a prefix's letter
                // would be read as that prefix)
                let text = SI.format(spec.defaultValue, unit: spec.unit)
                if Self.unitsSIMisreads[spec.unit] != nil {
                    continue
                } else if let back = SI.parse(text) {
                    XCTAssertEqual(back, spec.defaultValue, accuracy: abs(spec.defaultValue) * 5e-3 + 1e-300,
                                   "\(what): \"\(text)\" reads back as \(back)")
                } else {
                    XCTFail("\(what): \"\(text)\" does not read back")
                }
            }
        }
    }

    func testEveryModelSetsParametersTheKindHas() {
        for kind in kinds {
            let keys = Set(kind.params.map(\.key))
            var names = Set<String>()
            for model in kind.models {
                XCTAssertTrue(names.insert(model.name.lowercased()).inserted, "\(kind): two models named \(model.name)")
                let unknown = model.values.keys.filter { !keys.contains($0) }.sorted()
                XCTAssertEqual(unknown, [], "\(kind) model \(model.name) sets parameters the kind does not have")
                for (key, value) in model.values {
                    guard let spec = kind.params.first(where: { $0.key == key }), !spec.choices.isEmpty else { continue }
                    XCTAssertTrue(spec.choices.contains { $0.value == value }, "\(kind) model \(model.name): \(key) = \(value) is none of its choices")
                }
            }
        }
    }

    /// "The first one matches the parameter defaults" (`ElementKind.models`): a part placed fresh is its first model
    func testAFreshPartIsItsFirstModel() {
        var mismatched: [String] = []
        for kind in kinds {
            guard let first = kind.models.first else { continue }
            let fresh = element(kind)
            if fresh.model?.name != first.name {
                let differing = first.values.filter { abs(fresh[param: $0.key] - $0.value) > 1e-9 * abs($0.value) }.keys.sorted()
                mismatched.append("\(kind): \(first.name) differs from the defaults in \(differing)")
            }
        }
        XCTAssertEqual(mismatched, [])
    }

    // MARK: - Shortcuts

    /// The keys that play notes when a keyboard source is in the circuit (macos/docs/shortcuts.md, Playing), and the
    /// canvas's own single keys
    private static let musicalKeys: Set<Character> = Set("awsedftgyhujkolp;zx")
    private static let canvasKeys: Set<Character> = ["f", "/", "?", " "]

    func testShortcutsAreUniqueAndKnownToClashOnlyWhereIntended() {
        var plain: [Character: ElementKind] = [:]
        var shifted: [Character: ElementKind] = [:]
        for kind in kinds {
            if let key = kind.shortcut {
                XCTAssertTrue(kind.isPlaceable, "\(kind): a shortcut for a part that cannot be placed")
                XCTAssertEqual(String(key), String(key).lowercased(), "\(kind): shortcut \(key) is a capital (⇧ is shiftShortcut)")
                if let other = plain[key] { XCTFail("\(kind) and \(other) share the shortcut \(key)") }
                plain[key] = kind
                XCTAssertFalse(Self.canvasKeys.contains(key), "\(kind): shortcut \(key) is the canvas's own")
                XCTAssertNil(kind.shiftShortcut, "\(kind) has both a key and a ⇧ key")
            }
            if let key = kind.shiftShortcut {
                XCTAssertTrue(kind.isPlaceable, "\(kind): a ⇧ shortcut for a part that cannot be placed")
                if let other = shifted[key] { XCTFail("\(kind) and \(other) share the shortcut ⇧\(key)") }
                shifted[key] = kind
            }
        }
        // the piano keys take over from the part keys only while a keyboard source plays (as in GarageBand): these
        // part keys are the ones they shadow. A new part key on a piano key is a decision: add it here.
        let shadowed = plain.filter { Self.musicalKeys.contains($0.key) }.map { "\($0.key)" }.sorted()
        XCTAssertEqual(shadowed, ["a", "d", "e", "g", "h", "j", "k", "l", "o", "p", "s", "t", "u", "w", "x", "y", "z"])
    }

    // MARK: - Simulation and pacing

    func testPacingDecidesOnEveryKind() {
        for kind in kinds {
            let facts = kind.facts
            let alone = Circuit(elements: [element(kind)])
            let scales = Pacing.timeScales(of: alone)
            switch facts.pacing {
            case .own, .resistanceAndOwn:
                XCTAssertFalse(scales.isEmpty, "\(kind): Pacing.role says it has a time of its own, but timeScales finds none")
            case .none, .resistance:
                XCTAssertEqual(scales, [], "\(kind): Pacing.role says it has no time of its own, but timeScales finds \(scales)")
            case .throughItsParts:
                // (a loudspeaker is its parts only with a load chosen: some of its models)
                let expands = facts.simulation != .direct || kind.models.contains { model in
                    Circuit(elements: [Element(kind: kind, a: .zero, b: kind.defaultOffset, params: model.values)]).flattened().elements.count > 1
                }
                XCTAssertTrue(expands, "\(kind): paced through its parts, but simulated directly")
            }
            if facts.pacing == .resistance || facts.pacing == .resistanceAndOwn {
                var withCapacitor = alone
                withCapacitor.elements.append(Element(kind: .capacitor, a: GridPoint(0, 10), b: GridPoint(4, 10), params: ["capacitance": 1]))
                let paired = Pacing.timeScales(of: withCapacitor)
                XCTAssertGreaterThanOrEqual(paired.count, 2, "\(kind): a resistance the capacitor is not paired with")
            }
        }
    }

    func testSimulationAndExportAgreeOnTheExpandedParts() {
        for kind in kinds {
            let facts = kind.facts
            if kind.isExpandedPart {
                XCTAssertEqual(facts.simulation, .expanded, "\(kind): isExpandedPart, but its circuit is not put in its place")
                XCTAssertEqual(facts.spice, .subcircuit, "\(kind): simulated as its parts, which the export should write as a subcircuit")
                XCTAssertEqual(facts.pacing, .throughItsParts, "\(kind): simulated as its parts, which pacing reads")
            }
            if facts.spice == .subcircuit && kind != .block {
                XCTAssertTrue(kind.isExpandedPart, "\(kind): exported as a subcircuit of the parts it is not expanded into")
            }
        }
    }

    // MARK: - Layout

    func testTheLayoutKnowsHowToPlaceEveryKind() {
        for kind in kinds {
            let facts = kind.facts
            let inputs = SchematicLayout.inputs[kind], outputs = SchematicLayout.outputs[kind]
            switch facts.layout {
            case .directed:
                XCTAssertNotNil(inputs, "\(kind): directed, but has no inputs in SchematicLayout.inputs")
                XCTAssertNotNil(outputs, "\(kind): directed, but has no outputs in SchematicLayout.outputs")
            case .source:
                XCTAssertTrue(SchematicLayout.sources.contains(kind))
                XCTAssertEqual(facts.terminalCount, 2, "\(kind): a source of \(facts.terminalCount) terminals")
            case .twoTerminal:
                XCTAssertEqual(facts.terminalCount, 2, "\(kind): placed as a two-terminal part with \(facts.terminalCount) terminals")
                XCTAssertNil(inputs, "\(kind): has inputs in SchematicLayout.inputs, but is not directed")
            case .drawn, .block:
                XCTAssertNil(inputs, "\(kind)")
            }
            let names = Set(facts.terminalNames)
            for name in (inputs ?? []) + (outputs ?? []) where !names.contains(name) {
                XCTFail("\(kind): SchematicLayout names a terminal \(name) it does not have (\(facts.terminalNames))")
            }
        }
    }

    func testEveryPlaceableKindLaysOutAlone() throws {
        for kind in kinds where kind.isPlaceable && SchematicLayout.flow(kind) != .drawn {
            let circuit = try SchematicLayout.layout([part(kind)])
            XCTAssertEqual(circuit.elements.filter { $0.kind == kind }.count, 1, "\(kind): not in its own layout")
        }
    }

    // MARK: - Boards

    func testTheBreadboardDecidesOnEveryKind() {
        for kind in kinds {
            let facts = kind.facts
            let parts = [part(kind)] + kind.models.map { NetlistPart(kind: kind, name: "X", params: $0.values) }
            let packaged = parts.filter { Breadboard.package($0) != nil }
            switch facts.breadboard {
            case .chip:
                XCTAssertFalse(packaged.isEmpty, "\(kind): Breadboard.mount says a chip, but no model of it has a package")
            case .inline where kind == .vactrol:
                break
            case .twoLead, .inline, .offBoard, .notAPart:
                XCTAssertEqual(packaged.count, 0, "\(kind): has a package, but Breadboard.mount says \(facts.breadboard)")
            }
            switch facts.breadboard {
            case .twoLead:
                XCTAssertEqual(facts.terminalCount, 2, "\(kind): two leads for \(facts.terminalCount) terminals")
                let (_, title, _) = Breadboard.describe(part(kind), [:])
                if kind != .pushButton { XCTAssertNotEqual(title, "push button", "\(kind): Breadboard.describe draws it as a push button") }
            case .inline:
                let order = Breadboard.inline(part(kind), facing: "").order
                XCTAssertEqual(Set(order), Set(facts.terminalNames), "\(kind): Breadboard.inline's legs \(order) are not its terminals")
            case .chip, .offBoard, .notAPart:
                break
            }
            if facts.breadboard == .offBoard || (facts.breadboard == .chip && facts.breadboardPackage == nil) {
                XCTAssertFalse(Breadboard.offBoardTitle(part(kind)).isEmpty, "\(kind)")
            }
        }
    }

    /// JSpice's own modules, which no real chip is: wired to the board as "a module" (`Breadboard.offBoardTitle`). A
    /// real part off the board says what it is and how it is wired.
    private static let modulesOffTheBoard: Set<ElementKind> = [.vco, .vcf, .envelope, .vca, .sampleHold, .divider, .delayLine,
                                                               .digitalDelay, .memristor, .behavioralSource]

    func testEveryRealPartOffTheBoardSaysWhatItIs() {
        for kind in kinds where kind.facts.breadboard == .offBoard {
            let generic = Breadboard.offBoardTitle(part(kind)) == kind.displayName + ": a module wired to the board"
            XCTAssertEqual(generic, Self.modulesOffTheBoard.contains(kind),
                           generic ? "\(kind): off the board with no title of its own (Breadboard.offBoardTitle)"
                                   : "\(kind): has a title of its own now: take it out of modulesOffTheBoard")
        }
    }

    /// One part of every kind, each on nets of its own, on every board: each where `Breadboard.mount` puts it, and
    /// every board connected exactly as drawn
    func testOnePartOfEveryKindGoesWhereItsFactsSay() throws {
        let placeable = kinds.filter { $0.isPlaceable && $0.facts.breadboard != .notAPart }
        let circuit = try SchematicLayout.layout(placeable.map { part($0) })
        let plan = Breadboard.plan(circuit)
        for kind in placeable {
            let facts = kind.facts
            let name = self.name(kind)
            let found: String
            if plan.packs.contains(where: { $0.units.contains { $0.part.name == name && $0.part.kind == kind } }) {
                found = "chip"
            } else if plan.twoLead.contains(where: { $0.name == name && $0.kind == kind }) {
                found = "twoLead"
            } else if plan.inline.contains(where: { $0.name == name && $0.kind == kind }) {
                found = "inline"
            } else if plan.off.contains(where: { $0.name == name && $0.kind == kind }) {
                found = "off"
            } else {
                found = "nowhere"
            }
            let expected = facts.breadboardPackage != nil ? "chip"
                : facts.breadboard == .twoLead ? "twoLead" : facts.breadboard == .inline ? "inline" : "off"
            XCTAssertEqual(found, expected, "\(kind) (\(name)) on the breadboard")
        }
        XCTAssertEqual(Breadboard.verify(Breadboard.layout(circuit)), [], "breadboard")
        let strip = Stripboard.layout(circuit)
        XCTAssertEqual(Stripboard.verify(strip), [], "stripboard")
        XCTAssertEqual(Perfboard.verify(Perfboard.layout(from: strip)), [], "perfboard")
        let onStrip = Set(strip.placements.flatMap { [$0.name] + $0.title.components(separatedBy: CharacterSet(charactersIn: "(), ")) })
        for kind in placeable where kind.facts.stripboard == .onBoard {
            XCTAssertTrue(onStrip.contains(name(kind)),"\(kind): not on the stripboard, which its facts say it is")
        }
        // KiCad: the parts left for its footprint assignment are exactly those the facts say
        let export = KiCadNetlist.export(circuit)
        let unassigned = Set(placeable.filter { $0.facts.kicad == .unassigned }.map { name($0) })
        XCTAssertEqual(Set(export.unassigned), unassigned, "KiCad parts without a footprint")
    }

    // MARK: - SPICE

    /// Exported parts whose deck JSpice's own importer does not read back as it was written, and why
    private static let notReadBack: [ElementKind: String] = [:]

    /// Parts exported as the subcircuit they are simulated as, which leaves out parts of it SPICE has no equivalent
    /// for (their behavioural blocks): the deck runs, but not as JSpice does
    private static let exportedInPart: [ElementKind: [String]] = [
        .compander: ["Level Detector", "VCA"], .toneControl: ["VCA"], .barGraphDriver: ["Comparator"],
        .functionGenerator: ["Multiplier", "VCO"], .bbdClock: ["VCO"], .multiTapDelay: ["BBD Delay Line"],
        .reverbBrick: ["Spring Reverb Tank"], .analogEngine: ["Level Detector", "VCA"],
    ]

    func testEveryKindIsExportedOrSaysWhyNot() throws {
        var inPart: [ElementKind: [String]] = [:]
        for kind in kinds where kind != .block {
            let facts = kind.facts
            var circuit = Circuit(elements: [element(kind)])
            if kind == .behavioralSource { circuit.elements[0].code = "V(in1)" }
            let deck = SpiceNetlist.export(circuit)
            let left = deck.contains("* \(name(kind)): a \(kind.displayName) has no SPICE equivalent here, left out")
            let inner = deck.split(separator: "\n").filter { $0.hasSuffix("has no SPICE equivalent here, left out") && !$0.hasPrefix("* \(name(kind)):") }
            if !inner.isEmpty {
                inPart[kind] = Set(inner.compactMap { line in
                    line.range(of: ": a ").map { String(line[$0.upperBound...].dropLast(" has no SPICE equivalent here, left out".count)) }
                }).sorted()
            }
            XCTAssertEqual(left, facts.spice == .noEquivalent,
                           left ? "\(kind): left out of the deck, but SpiceNetlist.exportForm says \(facts.spice)"
                                : "\(kind): written into the deck, but SpiceNetlist.exportForm says it has no equivalent")
            let elements = deck.split(separator: "\n").filter { line in
                !line.hasPrefix("*") && !line.hasPrefix(".") && !line.trimmingCharacters(in: .whitespaces).isEmpty
                    && !line.hasPrefix("+")
            }
            switch facts.spice {
            case .device, .equations, .subcircuit, .placeholder:
                XCTAssertFalse(elements.isEmpty, "\(kind): exported as \(facts.spice), but the deck has no element for it")
            case .nothing, .noEquivalent:
                XCTAssertEqual(elements, [], "\(kind): the deck writes elements for it, but exportForm says \(facts.spice)")
            }
            guard facts.exportsToSpice || facts.spice == .placeholder, Self.notReadBack[kind] == nil else { continue }
            let (imported, warnings) = try SpiceNetlist.circuit(from: deck)
            XCTAssertEqual(warnings, [], "\(kind): its exported deck reads back with warnings")
            XCTAssertFalse(imported.elements.isEmpty, "\(kind): its exported deck reads back empty")
        }
        XCTAssertEqual(inPart, Self.exportedInPart, "parts exported as subcircuits that leave out parts of themselves")
    }
}
