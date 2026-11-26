import XCTest
@testable import CircuitKit

/// The inspector's arrow-key stepping through standard values, and editing several selected parts at once
final class ParameterEditingTests: XCTestCase {
    private func spec(_ kind: ElementKind, _ key: String) throws -> ParamSpec {
        try XCTUnwrap(kind.params.first { $0.key == key })
    }

    func testESeriesSteps() {
        XCTAssertEqual(ESeries.step(4700, series: 12, up: true), 5600)
        XCTAssertEqual(ESeries.step(5600, series: 12, up: false), 4700)
        XCTAssertEqual(ESeries.step(4700, series: 24, up: true), 5100)
        XCTAssertEqual(ESeries.step(4700, series: 24, up: false), 4300)
        // across a decade
        XCTAssertEqual(ESeries.step(8200, series: 12, up: true), 10_000)
        XCTAssertEqual(ESeries.step(10_000, series: 12, up: false), 8200)
        XCTAssertEqual(ESeries.step(1000, series: 12, up: false), 820)
        // between two values: to the next one in that direction, not past it
        XCTAssertEqual(ESeries.step(5000, series: 12, up: true), 5600)
        XCTAssertEqual(ESeries.step(5000, series: 12, up: false), 4700)
        // a value typed off by rounding is still on the series
        XCTAssertEqual(ESeries.step(4700.000000001, series: 12, up: true), 5600)
        // small values come out as typed
        XCTAssertEqual(ESeries.step(4.7e-6, series: 12, up: true), 5.6e-6)
        XCTAssertEqual(ESeries.step(100e-9, series: 12, up: false), 82e-9)
        XCTAssertEqual(ESeries.step(1e-12, series: 12, up: true), 1.2e-12)
        XCTAssertNil(ESeries.step(0, series: 12, up: true))
        XCTAssertNil(ESeries.step(100, series: 7, up: true))
        XCTAssertEqual(ESeries.nearest(4900, series: 12), 4700)
        XCTAssertEqual(ESeries.nearest(5300, series: 24), 5100)
    }

    func testStepsResistanceCapacitanceAndInductanceThroughTheSeries() throws {
        let resistance = try spec(.resistor, "resistance")
        XCTAssertTrue(ParameterStepping.usesESeries(resistance))
        XCTAssertEqual(ParameterStepping.step(4700, resistance, up: true), 5600)
        XCTAssertEqual(ParameterStepping.step(5600, resistance, up: false), 4700)
        XCTAssertEqual(ParameterStepping.step(4700, resistance, up: true, finer: true), 5100)
        let capacitance = try spec(.capacitor, "capacitance")
        XCTAssertTrue(ParameterStepping.usesESeries(capacitance))
        XCTAssertEqual(ParameterStepping.step(10e-6, capacitance, up: true), 12e-6)
        let inductance = try spec(.inductor, "inductance")
        XCTAssertEqual(ParameterStepping.step(1, inductance, up: false), 0.82)
        // a rated power or a voltage is not a series value
        XCTAssertFalse(ParameterStepping.usesESeries(try spec(.resistor, "ratedPower")))
        XCTAssertFalse(ParameterStepping.usesESeries(try spec(.capacitor, "initialVoltage")))
        // from nothing, up goes to the slider's lowest value
        XCTAssertEqual(ParameterStepping.step(0, resistance, up: true), resistance.range.lowerBound)
    }

    func testStepsOtherParametersByARoundAmount() throws {
        // logarithmic: 1, 2, 5
        let rated = try spec(.resistor, "ratedPower")
        XCTAssertEqual(ParameterStepping.step(0.25, rated, up: true), 0.5)
        XCTAssertEqual(ParameterStepping.step(0.5, rated, up: true), 1)
        XCTAssertEqual(ParameterStepping.step(1, rated, up: false), 0.5)
        XCTAssertEqual(ParameterStepping.step(0.25, rated, up: false), 0.2)
        // linear: a round hundredth of the slider's range, onto its multiples
        let wiper = try spec(.potentiometer, "position")
        XCTAssertEqual(ParameterStepping.linearStep(wiper), 0.01)
        XCTAssertEqual(ParameterStepping.step(0.5, wiper, up: true), 0.51)
        XCTAssertEqual(ParameterStepping.step(0.537, wiper, up: true), 0.54)
        XCTAssertEqual(ParameterStepping.step(0.537, wiper, up: false), 0.53)
        XCTAssertEqual(ParameterStepping.step(0.5, wiper, up: true, finer: true), 0.501)
        // not below a range that starts at 0
        XCTAssertEqual(ParameterStepping.step(0, wiper, up: false), 0)
        let initial = try spec(.capacitor, "initialVoltage")   // -50...50
        XCTAssertEqual(ParameterStepping.linearStep(initial), 1)
        XCTAssertEqual(ParameterStepping.step(0, initial, up: false), -1)
        XCTAssertFalse(ParameterStepping.hint(initial).isEmpty)
        XCTAssertTrue(ParameterStepping.hint(try spec(.resistor, "resistance")).contains("E12"))
    }

    func testTheHintNamesValuesTheParserAccepts() {
        for example in ["4.7k", "10u", "2M2", "100n"] {
            XCTAssertTrue(ParameterStepping.parseHint.contains(example))
            XCTAssertNotNil(SI.parse(example), example)
        }
        XCTAssertEqual(SI.parse("2M2"), 2.2e6)
        XCTAssertNil(SI.parse("abc"))
    }

    private func part(_ kind: ElementKind, _ params: [String: Double] = [:]) -> Element {
        Element(kind: kind, a: GridPoint(0, 0), b: GridPoint(4, 0), params: params)
    }

    func testOneKindEditsItsOwnParameters() {
        let common = MultiEdit.commonParams([.resistor])
        XCTAssertEqual(common.map(\.key), ["resistance", "ratedPower"], "a resistor's parameters but the advanced one")
    }

    func testMixedKindsShareOnlyParametersWithTheSameKeyAndUnit() {
        // a resistor and a potentiometer: both have a resistance in Ω
        XCTAssertEqual(MultiEdit.commonParams([.resistor, .potentiometer]).map(\.key), ["resistance"])
        // a resistor and a capacitor have nothing in common
        XCTAssertEqual(MultiEdit.commonParams([.resistor, .capacitor]), [])
        XCTAssertEqual(MultiEdit.commonParams([]), [])
        // the same key in another unit is not in common
        for kinds in [[ElementKind.resistor, .lamp], [.npn, .nmos], [.capacitor, .inductor]] {
            for spec in MultiEdit.commonParams(kinds) {
                for kind in kinds {
                    XCTAssertTrue(kind.params.contains { $0.key == spec.key && $0.unit == spec.unit && !$0.advanced }, "\(kinds) \(spec.key)")
                }
            }
        }
    }

    func testCommonValuesAndModels() {
        let a = part(.resistor, ["resistance": 1000]), b = part(.resistor, ["resistance": 1000]), c = part(.resistor, ["resistance": 2200])
        XCTAssertEqual(MultiEdit.commonValue([a, b], "resistance"), 1000)
        XCTAssertNil(MultiEdit.commonValue([a, b, c], "resistance"))
        XCTAssertFalse(MultiEdit.commonModel([a, c]).mixed, "resistors have no models: all custom")
        if let first = ElementKind.opAmp.models.first, let second = ElementKind.opAmp.models.dropFirst().first {
            let x = part(.opAmp, first.values), y = part(.opAmp, first.values), z = part(.opAmp, second.values)
            XCTAssertEqual(MultiEdit.commonModel([x, y]).model?.name, first.name)
            XCTAssertTrue(MultiEdit.commonModel([x, y, z]).mixed)
        }
    }

    func testSettingAValueOnSeveralParts() {
        var circuit = Circuit()
        let r1 = circuit.add(part(.resistor, ["resistance": 1000]))
        let r2 = circuit.add(part(.resistor, ["resistance": 2200]))
        let c1 = circuit.add(part(.capacitor, ["capacitance": 1e-6]))
        let wire = circuit.add(part(.wire))
        let ids: Set<UUID> = [r1, r2, c1, wire]
        XCTAssertEqual(MultiEdit.parts(ids, in: circuit).map(\.id), [r1, r2, c1], "wires are left out")
        XCTAssertEqual(MultiEdit.kinds(of: MultiEdit.parts(ids, in: circuit)), [.resistor, .capacitor])
        MultiEdit.set("resistance", to: 4700, of: ids, in: &circuit)
        XCTAssertEqual(circuit[r1]?[param: "resistance"], 4700)
        XCTAssertEqual(circuit[r2]?[param: "resistance"], 4700)
        XCTAssertNil(circuit[c1]?.params["resistance"], "a capacitor is not given a resistance")
        XCTAssertNil(circuit[wire]?.params["resistance"])
    }

    func testSummaryCountsByKind() {
        var circuit = Circuit()
        var ids: Set<UUID> = []
        ids.insert(circuit.add(part(.capacitor)))
        for _ in 0..<6 { ids.insert(circuit.add(part(.resistor))) }
        ids.insert(circuit.add(part(.capacitor)))
        ids.insert(circuit.add(part(.wire)))
        XCTAssertEqual(MultiEdit.summary(ids, in: circuit), "6 resistors, 2 capacitors, 1 wire")
        XCTAssertEqual(MultiEdit.counted(3, .opAmp), "3 op-amps")
        XCTAssertEqual(MultiEdit.counted(2, .npn), "2 NPN transistors")
        XCTAssertEqual(MultiEdit.counted(2, .led), "2 LEDs")
        XCTAssertEqual(MultiEdit.counted(1, .njfet), "1 N-JFET")
        XCTAssertEqual(MultiEdit.counted(2, .toggleSwitch), "2 switches")
        XCTAssertEqual(MultiEdit.counted(2, .atmega328p), "2 × ATmega328P (Arduino Uno)")
        XCTAssertEqual(MultiEdit.counted(2, .attiny85), "2 ATtiny85s")
    }
}
