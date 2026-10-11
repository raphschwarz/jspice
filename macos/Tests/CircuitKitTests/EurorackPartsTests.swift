import XCTest
@testable import CircuitKit

/// The parts on Eurorack modules' bills of materials (Mutable Instruments' and 4ms'): models found by every name they
/// go by, and the new ones at their datasheets' figures
final class EurorackPartsTests: XCTestCase {
    private func part(_ kind: ElementKind, _ name: String, _ params: [String: Double] = [:], _ connections: [String: String]) -> NetlistPart {
        NetlistPart(kind: kind, name: name, params: params, connections: connections)
    }

    private func r(_ name: String, _ ohms: Double, _ a: String, _ b: String) -> NetlistPart {
        part(.resistor, name, ["resistance": ohms], ["a": a, "b": b])
    }

    private func dc(_ name: String, _ volts: Double, plus: String, minus: String = "GND") -> NetlistPart {
        part(.dcVoltage, name, ["voltage": volts], ["plus": plus, "minus": minus])
    }

    private func probe(_ name: String, _ plus: String, _ minus: String = "GND") -> NetlistPart {
        part(.probe, name, [:], ["plus": plus, "minus": minus])
    }

    /// The named probe's reading after `seconds`
    private func settle(_ parts: [NetlistPart], seconds: Double = 1e-3, watch: String,
                        file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        let circuit = try SchematicLayout.layout(parts)
        let simulator = Simulator(circuit: circuit, timeStep: 1e-5)
        let index = try XCTUnwrap(circuit.elements.firstIndex { $0.name == watch }, watch, file: file, line: line)
        while simulator.time < seconds {
            simulator.step()
            XCTAssertFalse(simulator.isFailed, simulator.problems.joined(separator: " "), file: file, line: line)
            if simulator.isFailed { break }
        }
        return simulator.voltageAcross(index)
    }

    /// The voltage across a diode (or a Zener, reversed) fed `amps` from 12 V through a resistor
    private func diodeVoltage(_ kind: ElementKind, _ model: String, amps: Double, nominal: Double) throws -> Double {
        let params = try XCTUnwrap(kind.model(named: model)).values
        return try settle([
            dc("V1", 12, plus: "+12V"),
            r("R1", (12 - nominal) / amps, "+12V", "k"),
            kind == .zener ? part(kind, "D1", params, ["anode": "GND", "cathode": "k"])
                           : part(kind, "D1", params, ["anode": "k", "cathode": "GND"]),
            probe("VD", "k"),
        ], watch: "VD")
    }

    func testEveryModelIsTheOneItsValuesShow() {
        for kind in ElementKind.allCases {
            for model in kind.models {
                let element = Element(kind: kind, a: .zero, b: GridPoint(4, 0), params: model.values)
                XCTAssertEqual(element.model?.name, model.name, "\(kind)")
            }
        }
    }

    func testAliasesFindTheirModels() {
        XCTAssertEqual(ElementKind.opAmp.model(named: "TL082")?.name, "TL072")
        XCTAssertEqual(ElementKind.opAmp.model(named: "tl084")?.name, "TL074")
        XCTAssertEqual(ElementKind.opAmp.model(named: "NJM4558")?.name, "JRC4558")
        XCTAssertEqual(ElementKind.opAmp.model(named: "MCP6004")?.name, "MCP6002")
        XCTAssertEqual(ElementKind.diode.model(named: "BAT54S")?.name, "BAT54")
        XCTAssertEqual(ElementKind.vca.model(named: "V2164")?.name, "SSM2164")
        XCTAssertEqual(ElementKind.zener.model(named: "LM4040A25")?.name, "LM4040-2.5")
        XCTAssertEqual(Examples.model(.opAmp, "OPA4171"), Examples.model(.opAmp, "OPA2171"))
        XCTAssertNil(ElementKind.opAmp.model(named: "TL999"))
        XCTAssertTrue(ElementKind.opAmp.searchTerms.contains("LME49720"))
        XCTAssertEqual(ElementKind.opAmp.model(named: "TL072")?.title, "TL072 / TL082")
        // no name twice within a kind: an alias would hide a model or another alias
        for kind in ElementKind.allCases {
            let names = kind.models.flatMap { [$0.name] + $0.aliases }.map { $0.lowercased() }
            XCTAssertEqual(Set(names).count, names.count, "\(kind)")
        }
    }

    func testSchottkyDiodesAtTheirDatasheetsForwardVoltages() throws {
        // BAT54: at most 0.32 V at 1 mA and 0.40 V at 10 mA
        let bat54 = try diodeVoltage(.diode, "BAT54", amps: 1e-3, nominal: 0.3)
        XCTAssertEqual(bat54, 0.29, accuracy: 0.03)
        XCTAssertLessThan(try diodeVoltage(.diode, "BAT54", amps: 10e-3, nominal: 0.35), 0.40)
        // 1N5819: at most 0.6 V at 1 A, well under a silicon diode's at 1 mA
        XCTAssertLessThan(try diodeVoltage(.diode, "1N5819", amps: 1, nominal: 0.5), 0.6)
        XCTAssertEqual(try diodeVoltage(.diode, "1N5819", amps: 1e-3, nominal: 0.2), 0.22, accuracy: 0.04)
    }

    func testLM4040HoldsItsVoltageOverItsCurrentRange() throws {
        let nominal = try diodeVoltage(.zener, "LM4040-2.5", amps: 100e-6, nominal: 2.5)
        XCTAssertEqual(nominal, 2.5, accuracy: 0.001)
        let low = try diodeVoltage(.zener, "LM4040-2.5", amps: 60e-6, nominal: 2.5)
        let high = try diodeVoltage(.zener, "LM4040-2.5", amps: 15e-3, nominal: 2.5)
        XCTAssertLessThan(abs(low - 2.5), 0.002)
        XCTAssertGreaterThan(high, 2.5)
        XCTAssertLessThan(high - 2.5, 0.01, "within 10 mV at 15 mA")
        XCTAssertEqual(try diodeVoltage(.zener, "LM4040-10", amps: 1e-3, nominal: 10), 10, accuracy: 0.01)
    }

    func testRailToRailOpAmpOnThreePointThreeVoltsStaysWithinItsRails() throws {
        // a follower driven past each rail: the MCP6002's output stops within 25 mV of 3.3 V and of 0 V
        func follower(_ input: Double) throws -> Double {
            try settle([
                dc("VIN", input, plus: "in"),
                part(.opAmp, "U1", Examples.model(.opAmp, "MCP6004"), ["plus": "in", "minus": "out", "out": "out"]),
                r("RL", 10_000, "out", "GND"),
                probe("OUT", "out"),
            ], watch: "OUT")
        }
        XCTAssertEqual(try follower(5), 3.275, accuracy: 0.01)
        XCTAssertEqual(try follower(-2), 0.025, accuracy: 0.01)
        XCTAssertEqual(try follower(1.2), 1.2, accuracy: 0.005)
        // and the breadboard puts it on 3.3 V and ground
        let package = try XCTUnwrap(Breadboard.package(part(.opAmp, "U1", Examples.model(.opAmp, "MCP6002"), [:])))
        XCTAssertEqual(package.title, "MCP6002")
        XCTAssertTrue(package.supplies.contains { $0.pin == 8 && $0.supply == .volts(3.3) }, "\(package.supplies)")
        XCTAssertTrue(package.supplies.contains { $0.pin == 4 && $0.supply == .ground }, "\(package.supplies)")
    }
}
