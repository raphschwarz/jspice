import XCTest
@testable import CircuitKit

/// The ATmega328P as a part of a circuit: its pins driving and reading the circuit, its firmware kept across edits
final class MicrocontrollerTests: XCTestCase {
    private func index(_ circuit: Circuit, _ name: String) -> Int {
        circuit.elements.firstIndex { $0.name == name }!
    }

    private func run(_ simulator: Simulator, until time: Double) {
        while simulator.time < time && !simulator.isFailed { simulator.step() }
        XCTAssertFalse(simulator.isFailed, simulator.problems.joined(separator: " "))
    }

    func testBlinkLightsTheLEDInRealTime() {
        let circuit = Examples.arduinoBlink.circuit
        let pacing = Pacing.suggest(for: circuit)
        XCTAssertEqual(pacing.speed, 1, "real time")
        let simulator = Simulator(circuit: circuit, timeStep: pacing.timeStep)
        XCTAssertTrue(simulator.problems.isEmpty, simulator.problems.joined(separator: " "))
        let led = index(circuit, "D1")
        run(simulator, until: 0.25)
        // 5 V through 220 Ω and a red LED's 1.9 V: about 14 mA
        XCTAssertEqual(simulator.current(led), (5 - 1.9) / 245, accuracy: 0.003, "on for the first half second")
        run(simulator, until: 0.75)
        XCTAssertLessThan(abs(simulator.current(led)), 1e-5, "off for the next")
        run(simulator, until: 1.25)
        XCTAssertGreaterThan(simulator.current(led), 0.01, "on again")
    }

    func testKnobReadsThePotAndDrivesTheLED() {
        let circuit = Examples.arduinoKnob.circuit
        let simulator = Simulator(circuit: circuit, timeStep: 2e-5)
        let chip = index(circuit, "U1")
        let led = index(circuit, "D1")
        run(simulator, until: 0.25)
        // the pot at 0.6 of 5 V: 3 V on A0 reads 614 of 1023
        let text = String(decoding: simulator.chip(chip)?.serialOutput ?? [], as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("A0 = 614\r\n"), text)
        // PWM at 614 / 4 = 153 of 255: the LED is on 60 % of the time
        var on = 0
        var samples = 0
        while simulator.time < 0.3 {
            simulator.step()
            samples += 1
            if simulator.current(led) > 1e-3 { on += 1 }
        }
        XCTAssertEqual(Double(on) / Double(samples), 153.0 / 255, accuracy: 0.03)
    }

    func testMelodyPlaysItsFirstNote() {
        let circuit = Examples.arduinoMelody.circuit
        let simulator = Simulator(circuit: circuit, timeStep: 1 / 96_000)
        let speaker = index(circuit, "SPK1")
        var rises: [Double] = []
        var previous = 0.0
        while simulator.time < 0.15 && !simulator.isFailed {
            simulator.step()
            let v = simulator.voltageAcross(speaker)
            if previous < 2.5 && v >= 2.5 { rises.append(simulator.time) }
            previous = v
        }
        XCTAssertGreaterThan(rises.count, 20)
        let frequency = Double(rises.count - 1) / (rises.last! - rises.first!)
        XCTAssertEqual(frequency, 262, accuracy: 3, "middle C")
    }

    func testTheChipKeepsRunningThroughEditsAndRestartsWithNewFirmware() {
        let circuit = Examples.arduinoBlink.circuit
        let simulator = Simulator(circuit: circuit, timeStep: 5e-5)
        let chip = index(circuit, "U1")
        run(simulator, until: 0.1)
        let cycles = simulator.chip(chip)?.cycles ?? 0
        XCTAssertEqual(Double(cycles), simulator.time * AVR.clock, accuracy: 100)
        // an edit elsewhere: the same chip carries on
        var edited = circuit
        edited.add(Element(kind: .resistor, a: GridPoint(80, 80), b: GridPoint(84, 80)))
        simulator.load(edited)
        XCTAssertEqual(simulator.chip(chip)?.cycles, cycles)
        // new firmware: a fresh chip
        edited.update(edited.elements[chip].id) { $0.firmware = ArduinoSketches.firmware(ArduinoSketches.fadeFirmware) }
        simulator.load(edited)
        XCTAssertEqual(simulator.chip(chip)?.cycles, 0)
        // no firmware: no chip, its pins are inputs
        edited.update(edited.elements[chip].id) { $0.firmware = nil }
        simulator.load(edited)
        XCTAssertNil(simulator.chip(chip))
        simulator.step()
        XCTAssertFalse(simulator.isFailed)
    }

    func testTidyKeepsTheProgram() throws {
        let tidied = try SchematicLayout.tidy(Examples.arduinoFade.circuit)
        let chip = try XCTUnwrap(tidied.elements.first { $0.kind == .atmega328p })
        XCTAssertEqual(chip.code, ArduinoSketches.fadeCode)
        XCTAssertEqual(chip.firmware, ArduinoSketches.firmware(ArduinoSketches.fadeFirmware))
    }

    func testTheCircuitFileKeepsTheProgram() throws {
        let circuit = Examples.arduinoKnob.circuit
        let decoded = try JSONDecoder().decode(Circuit.self, from: JSONEncoder().encode(circuit))
        XCTAssertEqual(decoded, circuit)
        let lfo = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Examples.lfo.circuit)) as? [String: Any])
        let elements = try XCTUnwrap(lfo["elements"] as? [[String: Any]])
        XCTAssertFalse(elements.contains { $0["firmware"] != nil || $0["code"] != nil }, "other parts store no program")
    }

    func testPrototypesLetFunctionsBeUsedBeforeTheyAreDefined() {
        let sketch = """
            #include <Servo.h>
            // a comment with a fake() { function
            const char *text = "not() { a function";
            int counter = 0;

            void setup() {
              blinkTwice(13);
            }

            void loop() {
              counter = add(counter, 1);
            }

            void blinkTwice(int pin) {
              for (int i = 0; i < 2; i++) { digitalWrite(pin, HIGH); }
            }

            long add(long a, long b) { return a + b; }
            """
        let (prototypes, first) = SketchBuilder.prototypes(sketch)
        XCTAssertEqual(prototypes, ["void setup();", "void loop();", "void blinkTwice(int pin);", "long add(long a, long b);"])
        let output = SketchBuilder.preprocess(sketch)
        XCTAssertTrue(output.hasPrefix("#include <Arduino.h>\n#line 1 \"sketch.ino\"\n#include <Servo.h>"))
        // the prototypes go just before the first function, and the line numbers carry on from there
        XCTAssertEqual(Array(sketch)[first...].prefix(12).map(String.init).joined(), "void setup()")
        XCTAssertTrue(output.contains("long add(long a, long b);\n#line 6 \"sketch.ino\"\nvoid setup() {"), output)
    }

    func testDiagnosticsUseTheSketchsLines() {
        let output = """
            sketch.ino: In function 'void loop()':
            sketch.ino:12:5: error: 'foo' was not declared in this scope
            sketch.ino:3:1: warning: unused variable 'x'
            """
        XCTAssertEqual(SketchBuilder.parseDiagnostics(output), [
            .init(line: 12, column: 5, isError: true, message: "'foo' was not declared in this scope"),
            .init(line: 3, column: 1, isError: false, message: "unused variable 'x'"),
        ])
    }

    /// Compiles a sketch end to end when a toolchain is installed (CI installs one through Chip Support)
    func testCompilesAndRunsASketchWhenAToolchainIsInstalled() throws {
        guard let toolchain = AVRToolchain.find() else {
            if ProcessInfo.processInfo.environment["JSPICE_REQUIRE_TOOLCHAIN"] != nil { XCTFail("no AVR toolchain found") }
            throw XCTSkip("no AVR toolchain installed")
        }
        let failed = SketchBuilder.build("void setup() { undefinedThing(); }\nvoid loop() {}\n", toolchain: toolchain)
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(failed.errors.first?.line, 1, failed.log)
        let result = SketchBuilder.build(ArduinoSketches.knobCode, toolchain: toolchain)
        let firmware = try XCTUnwrap(result.firmware, result.log)
        let chip = AVR(firmware: [UInt8](firmware))
        chip.pinVoltages = [Double](repeating: 2.5, count: AVR.pinCount)
        chip.run(cycles: 16_000 * 120)
        XCTAssertTrue(String(decoding: chip.serialOutput, as: UTF8.self).hasPrefix("A0 = 512\r\n"))
    }
}
