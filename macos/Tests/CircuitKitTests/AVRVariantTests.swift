import XCTest
@testable import CircuitKit

/// The ATmega2560 (Arduino Mega) and the ATtiny85: the same emulator with their layouts, checked against simavr and in
/// circuits
final class AVRVariantTests: XCTestCase {
    private func firmware(_ base64: String) -> [UInt8] {
        [UInt8](Data(base64Encoded: base64.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: ""))!)
    }

    private func index(_ circuit: Circuit, _ name: String) -> Int {
        circuit.elements.firstIndex { $0.name == name }!
    }

    func testMegaMatchesSimavrInstructionByInstruction() {
        // timers 3-5, Serial1, ADC8-15 (MUX5), INT0 and ELPM; simavr 1.6 reads 0 V on ADC8-ADC15
        let avr = AVR(firmware: firmware(Self.megaFirmware), variant: .atmega2560)
        avr.supply = 3.3  // simavr's AVCC
        var volts = [Double](repeating: 2.5, count: 70)
        for pin in 62..<70 { volts[pin] = 0 }
        avr.pinVoltages = volts
        AVRTests.compareWithSimavr(avr, [
            AVRTests.Checkpoint(instructions: 1000, cycle: 1588, pc: 849, sreg: 53, sp: 8703,
                       registers: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 4, 0, 0, 0, 0, 0, 0, 0, 228, 2, 255, 33, 86, 30]),
            AVRTests.Checkpoint(instructions: 100000, cycle: 146885, pc: 1719, sreg: 130, sp: 8686,
                       registers: [121, 0, 0, 0, 0, 0, 0, 0, 116, 34, 0, 0, 3, 0, 0, 0, 0, 3, 169, 128, 0, 0, 164, 34, 0, 0, 0, 0, 91, 9, 0, 6]),
            AVRTests.Checkpoint(instructions: 1000000, cycle: 1832451, pc: 937, sreg: 2, sp: 8697,
                       registers: [121, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 13, 0, 2, 0, 1, 2, 6, 0, 37, 0, 91, 9, 0, 6]),
        ])
        XCTAssertTrue(String(decoding: avr.serialOutput, as: UTF8.self).hasPrefix("775\r\n0\r\n0\r\nfar flash\r\n3\r\n14\r\n"))
        XCTAssertEqual(String(decoding: avr.usarts[1].output, as: UTF8.self), "serial one\r\n")
    }

    func testTinyMatchesSimavrInstructionByInstruction() {
        // timers 0 and 1, the ADC, INT0, EEPROM, no MUL
        let avr = AVR(firmware: firmware(Self.tinyFirmware), variant: .attiny85)
        avr.supply = 3.3  // simavr's VCC
        avr.pinVoltages = [Double](repeating: 2.5, count: 6)
        AVRTests.compareWithSimavr(avr, [
            AVRTests.Checkpoint(instructions: 1000, cycle: 1527, pc: 519, sreg: 128, sp: 599,
                       registers: [161, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 42, 8, 2, 0, 42, 0, 1, 0, 55, 0, 42, 2, 100, 0]),
            AVRTests.Checkpoint(instructions: 100000, cycle: 128018, pc: 424, sreg: 130, sp: 593,
                       registers: [124, 0, 0, 0, 0, 0, 0, 0, 64, 59, 0, 0, 1, 0, 0, 0, 0, 0, 204, 128, 0, 0, 96, 62, 0, 0, 0, 0, 0, 0, 4, 0]),
            AVRTests.Checkpoint(instructions: 1000000, cycle: 1274068, pc: 453, sreg: 181, sp: 595,
                       registers: [124, 0, 0, 0, 0, 0, 0, 0, 184, 109, 2, 0, 1, 0, 0, 0, 0, 0, 190, 128, 0, 0, 56, 252, 0, 0, 0, 0, 0, 0, 4, 0]),
        ])
    }

    func testMegaPWMPinsFollowTheirTimers() {
        // analogWrite(pin, 10 + i * 17) on 2, 3, 5-13, 44, 45, 46: Timer0 (4, 13) fast PWM, the others phase correct
        let avr = AVR(firmware: firmware(Self.megaFirmware), variant: .atmega2560)
        avr.run(cycles: 16_000 * 20)
        let pins: [Int] = [2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 44, 45, 46]
        let all: [Int] = [2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 44, 45, 46]
        var high = [Int: Int]()
        var samples = 0
        let start = avr.cycles
        while avr.cycles - start < 16_000 * 40 {
            avr.run(cycles: 32)
            samples += 1
            let states = avr.pinStates
            for pin in pins where states[pin] == .output(high: true) { high[pin, default: 0] += 1 }
        }
        for pin in pins {
            let value = Double(10 + all.firstIndex(of: pin)! * 17)
            let expected = pin == 4 ? (value + 1) / 256 : value / 255
            XCTAssertEqual(Double(high[pin] ?? 0) / Double(samples), expected, accuracy: 0.01, "duty of pin \(pin)")
        }
    }

    func testMegaBarGraphLightsLEDsByThePot() {
        let circuit = Examples.megaBarGraph.circuit
        let simulator = Simulator(circuit: circuit, timeStep: 1e-4)
        let chip = index(circuit, "U1")
        while simulator.time < 0.3 && !simulator.isFailed { simulator.step() }
        XCTAssertFalse(simulator.isFailed, simulator.problems.joined(separator: " "))
        // 0.65 of 5 V: 666 of 1023, three LEDs of five
        let text = String(decoding: simulator.chip(chip)?.serialOutput ?? [], as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("A8 = 66"), text)
        XCTAssertTrue(text.contains("LEDs lit: 3"), text)
        let lit = (1...5).map { simulator.current(index(circuit, "D\($0)")) > 1e-3 }
        XCTAssertEqual(lit, [true, true, true, false, false])
    }

    func testTinyDimmerFollowsThePot() {
        let circuit = Examples.tinyDimmer.circuit
        let simulator = Simulator(circuit: circuit, timeStep: 1e-5)
        let led = index(circuit, "D1")
        while simulator.time < 0.05 && !simulator.isFailed { simulator.step() }
        XCTAssertFalse(simulator.isFailed, simulator.problems.joined(separator: " "))
        // the pot in the middle: analogRead 512, analogWrite 128: on half the time
        var on = 0
        var samples = 0
        while simulator.time < 0.1 {
            simulator.step()
            samples += 1
            if simulator.current(led) > 1e-3 { on += 1 }
        }
        XCTAssertEqual(Double(on) / Double(samples), 129.0 / 256, accuracy: 0.04)
    }

    func testEveryBoardsPinsAreDrawnOnTheirSides() {
        for board in Board.allCases {
            let element = Element(kind: board.kind, a: GridPoint(0, 0), b: GridPoint(0, board.length))
            XCTAssertEqual(element.posts.count, board.terminalNames.count, board.title)
            XCTAssertEqual(Set(element.posts).count, element.posts.count, "\(board.title): no two pins in one place")
            XCTAssertEqual(board.pinLabels.count, board.terminalNames.count)
            let variant = board.avrVariant
            XCTAssertEqual(variant?.pinCount, board.terminalNames.count, board.title)
        }
    }

    func testTinyPinMapIsTheOneInTheTools() throws {
        let tools = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/avr-reference/variants/tiny85/pins_arduino.h")
        XCTAssertEqual(try String(contentsOf: tools, encoding: .utf8), Board.attiny85.variantHeader + "\n")
    }

    // MARK: - Firmware

    /// tools/avr-reference/sketches/megasmall.ino, built with build.py for the Mega
    static let megaFirmware = """
        DJQ3AwyU5AQMlA8FDJQ6BQyUZQUMlJAFDJS7BQyU5gUMlBEGDJRoAwyUaAMMlGgDDJRoAwyUbw4MlGgDDJRoAwyUaAMMlGgDDJRoAwyUaAMMlGgD
        DJRoAwyUaAMMlD0GDJRoAwyUgQoMlLcKDJRoAwyUaAMMlGgDDJRoAwyUaAMMlGgDDJRoAwyUaAMMlGgDDJQYCwyUTgsMlGgDDJRoAwyUaAMMlGgD
        DJRoAwyUaAMMlGgDDJRoAwyUaAMMlGgDDJRoAwyUaAMMlGgDDJSvCwyU5QsMlGgDDJRGDAyUfAwMlGgDDJR9CAyUHgkMlL4EDJQWCAyUkAQMlCoJ
        DJRMCQyUdQgMlJgIDJTFBwyUsgkMlCoIDJQHCAyUnggMlLYHDJThCgyUWwkMlKwIDJSGCAyUSAgMlKYIDJSUCAyU0gkMlDQIDJTZBwyU4QcMlP0H
        DJQgCAyUeQgMlOkHDJSIBAyUeAsMlIILDJRrCAyU8wcMlOsKDJSiCAyU1wQMlHEIDJSrCAyUGQwMlLsHDJRqAwyUkAgMlIoIDJSwCAyUaQQMlKYM
        DJSuBwyUzwcMlDgJDJSACAyUygQMlJwEDJQPDAyUsAwMlKkEDJTdDAyUPghmYXIgZmxhc2gABwgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAABQYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQIDBAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKCwIJDA0OCAcDBAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAASERAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAECECAgCAgQIEAQIECAAgECAQgEAgEBAgQIECBAgIBAIBAIBAIBgAQCAYBAIBAIBAIBCAQCAQECBAgQIECAAQIECBAg
        QIAFBQUFBwUICAgIAgICAgoKCAgEBAQEAQEBAQEBAQEDAwMDAwMDAwQHBwcMDAwMDAwMDAICAgIGBgYGBgYGBgsLCwsLCwsLAAAiACUAKAArAC4A
        MQA0AAIBAAAFAQgBCwEAACEAJAAnACoALQAwADMAAQEAAAQBBwEKAQIA6wqCCxkMsAwRJB++z+/R4t6/zb8A4Ay/EuCg4LLg5uH+4QDgC78CwAeQ
        DZKgNLEH2fck4KDksuABwB2SqTyyB+H3E+DH49PgAOAGwCGXAQmAL/4BDpQBD8Mz0QeA4AgHqfcOlNAODJQJDwyUAACAkUECkJFCAqCRQwKwkUQC
        AZahHbEdgJNBApCTQgKgk0MCsJNEAgiVDpSHBqsBvAEq4DDgjuSS4A6U+g1g4o7kkuAOlBkNQJFBAlCRQgJgkUMCcJFEAirgMOCO5JLgDpToDWCR
        QAJhcI3gDpTwCICRQAKPX4CTQAKGMBDw+JT/z2XgcOCA4JDgDJS4Bg+TH5PPk9+TANAfkh+SzbfetybgQOBS7GHgcOCO5JLgDpQfCibgQOhV4mDg
        cOCL7pLgDpQfCg3hEuCK4JDgmoOJg2mBeoHYAY2RjQEOlHYH6YH6gXGW+oPpg+g/8QWJ92LgheEOlLQIQeBQ4Grmc+CC4A6UagSG4w6UUwdK4FDg
        vAGO5JLgDpTWDY/jDpRTB0rgUOC8AY7kkuAOlNYNheQOlFMHSuBQ4LwBjuSS4A6U1g1i4XLgi+6S4A6UJA2A7ZHgoOC7J4mDmoOrg7yDmeCdg4mB
        moGrgbyBq7/8AWeRjuSS4A6U0gmdgZFQnYOJgZqBq4G8gQGWoR2xHYmDmoOrg7yDnYGREeTPjuSS4A6UIA1i43TggOCZJ25ff0+PT59Pi7/7AWeR
        SuBQ4I7kkuAOlA4O5+Dz4GSRiu2R4KDguycBlqEdsR2rv/wBh5FoD3cndx9K4FDgjuSS4A+QD5APkA+QD5Dfkc+RH5EPkQyU1g0IlYgwCPB2wOgv
        8ODuD/8f4FD+T3GDYIOBUIcwCPA9wOgv8OCIJ+9X+0+PTwyUAQ++BIgEkAScBKkEygTXBICRaQCMf0grQJNpAOiaCJWAkWkAg39ED1UfRA9VH0gr
        QJNpAOmaCJWAkWkAj3x04EQPVR96leH3SCtAk2kA6poIlYCRaQCPc2bgRA9VH2qV4fdIK0CTaQDrmgiVgJFqAIx/SCtAk2oA7JoIlYCRagCDf0QP
        VR9ED1UfSCtAk2oA7ZoIlYCRagCPfCTgRA9VHyqV4fdIK0CTagDumgiVgJFqAI9zluBED1UfmpXh90grQJNqAO+aCJUfkg+SD7YPkhEkC7YPki+T
        P5NPk1+Tb5N/k4+Tn5Ovk7+T75P/k+CRBALwkQUCGZX/ke+Rv5GvkZ+Rj5F/kW+RX5FPkT+RL5EPkAu+D5APvg+QH5AYlR+SD5IPtg+SESQLtg+S
        L5M/k0+TX5Nvk3+Tj5Ofk6+Tv5Pvk/+T4JEGAvCRBwIZlf+R75G/ka+Rn5GPkX+Rb5FfkU+RP5EvkQ+QC74PkA++D5AfkBiVH5IPkg+2D5IRJAu2
        D5Ivkz+TT5Nfk2+Tf5OPk5+Tr5O/k++T/5PgkQgC8JEJAhmV/5Hvkb+Rr5GfkY+Rf5FvkV+RT5E/kS+RD5ALvg+QD74PkB+QGJUfkg+SD7YPkhEk
        C7YPki+TP5NPk1+Tb5N/k4+Tn5Ovk7+T75P/k+CRCgLwkQsCGZX/ke+Rv5GvkZ+Rj5F/kW+RX5FPkT+RL5EPkAu+D5APvg+QH5AYlR+SD5IPtg+S
        ESQLtg+SL5M/k0+TX5Nvk3+Tj5Ofk6+Tv5Pvk/+T4JEAAvCRAQIZlf+R75G/ka+Rn5GPkX+Rb5FfkU+RP5EvkQ+QC74PkA++D5AfkBiVH5IPkg+2
        D5IRJAu2D5Ivkz+TT5Nfk2+Tf5OPk5+Tr5O/k++T/5PgkQIC8JEDAhmV/5Hvkb+Rr5GfkY+Rf5FvkV+RT5E/kS+RD5ALvg+QD74PkB+QGJUfkg+S
        D7YPkhEkC7YPki+TP5NPk1+Tb5N/k4+Tn5Ovk7+T75P/k+CRDALwkQ0CGZX/ke+Rv5GvkZ+Rj5F/kW+RX5FPkT+RL5EPkAu+D5APvg+QH5AYlR+S
        D5IPtg+SESQLtg+SL5M/k0+TX5Nvk3+Tj5Ofk6+Tv5Pvk/+T4JEOAvCRDwIZlf+R75G/ka+Rn5GPkX+Rb5FfkU+RP5EvkQ+QC74PkA++D5AfkBiV
        CJUfkg+SD7YPkhEkL5M/k4+Tn5Ovk7+TgJFGApCRRwKgkUgCsJFJAjCRRQIj4CMPLTdY9QGWoR2xHSCTRQKAk0YCkJNHAqCTSAKwk0kCgJFKApCR
        SwKgkUwCsJFNAgGWoR2xHYCTSgKQk0sCoJNMArCTTQK/ka+Rn5GPkT+RL5EPkA++D5AfkBiVJugjDwKWoR2xHdLPL7f4lGCRRgJwkUcCgJFIApCR
        SQIvvwiVP7f4lICRSgKQkUsCoJFMArCRTQImtaibBcAvPxnwAZahHbEdP7+6L6kvmC+IJ7wBzQFiD3EdgR2RHULgZg93H4gfmR9KldH3CJWPkp+S
        r5K/ks+S35Lvkv+SawF8AQ6UkwZLAVwBwRTRBOEE8QTp8A6UPAYOlJMGaBl5CYoJmwloPnNAgQWRBXDzIeDCGtEI4QjxCIjuiA6D4JgeoRyxHMEU
        0QThBPEEKff/kO+Q35DPkL+Qr5CfkI+QCJV4lIS1gmCEvYS1gWCEvYW1gmCFvYW1gWCFve7m8OCAgYFggIPh6PDgEIKAgYJggIOAgYFggIPg6PDg
        gIGBYICD4evw4ICBhGCAg+Dr8OCAgYFggIPh6fDggIGCYICDgIGBYICD4Onw4ICBgWCAg+Hq8OCAgYJggIOAgYFggIPg6vDggIGBYICD4eLx4ICB
        gmCAg4CBgWCAg+Di8eCAgYFggIPq5/DggIGEYICDgIGCYICDgIGBYICDgIGAaICDEJLBAAiVhjMI8IZTIJF7AJgvmHAnf5IrkJN7ACCREAKQ5Cmf
        kAERJIdwgiuAk3wAgJF6AIBkgJN6AICRegCG/fzPgJF4AJCReQAIlR+Tz5Pfkxgv6wFh4A6UtAgglzn0YOCBL9+Rz5EfkQyU8AjPP9EFEfRh4PXP
        4S/w4OJa+k/kkeFQ4jEI8LPA8OCIJ+RW+E+PTwyUAQ+uB7YHuwfFB88HSAjZB+EH6QfzB/0HBwgWCCAISAgqCDQIPgiEtYBohL3Hvd+Rz5EfkQiV
        hLWAYoS9yL33z4CRgACAaICTgADQk4kAwJOIAO3PgJGAAIBigJOAANCTiwDAk4oA48+AkYAAiGCAk4AA0JONAMCTjADZz4CRsACAaICTsADAk7MA
        0c+AkbAAgGKAk7AAwJO0AMnPgJGQAIBogJOQANCTmQDAk5gAv8+AkZAAgGKAk5AA0JObAMCTmgC1z4CRkACIYICTkADQk50AwJOcAKvPgJGgAIBo
        gJOgAICRoACPe4CToADQk6kAwJOoAJzPgJGgAIBigJOgANCTqwDAk6oAks+AkaAAiGCAk6AA0JOtAMCTrACIz4CRIAGAaICTIAHQkykBwJMoAX7P
        gJEgAYBigJMgAdCTKwHAkyoBdM+AkSABiGCAkyAB0JMtAcCTLAFqz8A40QUM8D7PM8+BUIIxCPBawOgv8OCIJ+da90+PTwyUAQ95CH0IawhxCHUI
        qwiACIYIigiQCJQImAieCKIIqwimCKwIsAiAkYAAj3eAk4AACJWAkYAAj335z4CRgACHf/XPhLWPd4S9CJWEtY99+8+AkbAAj3eAk7AACJWAkbAA
        j335z4CRkACPd4CTkAAIlYCRkACPffnPgJGQAId/9c+AkaAAj3eAk6AACJWAkaAAj335z4CRoACHf/XPgJEgAY93gJMgAQiVgJEgAY99+c+AkSAB
        h3/1z8+T35OQ4PwB7FX6TySRhlGaT/wBhJGII8nwkOCID5kf/AHmW/lPpZG0kfwB4F35T8WR1JFhEQ3An7f4lIyRIJWCI4yTiIEoIyiDn7/fkc+R
        CJViMFH0n7f4lDyRgi+AlYMjjJPogS4r78+Pt/iU7JEuKyyTj7/qzx+Tz5PfkygvMOD5AeJa+k+EkfkB7FX6T9SR+QHmUfpPxJHMI6nwFi+BEQ6U
        TQjsL/Dg7g//H+Bd+U+lkbSRj7f4lOyREREIwNCV3iPck4+/35HPkR+RCJXeK/jP/AGRjSKNiS+Q4IBcn0+CG5EJj3OZJwiV/AGRjYKNmBcx8IKN
        6A/xHYWNkOAIlY/vn+8IlfwBkY2CjZgXYfCija4Pvy+xHV2WjJGSjZ9fn3OSj5DgCJWP75/vCJX8AVONRI0lLzDghC+Q4IIbkwtUFxDwz5YIlQGX
        CJWB7prgiStJ8IDgkOCJKynwDpThCoERDpQAAIjnm+CJK0nwgOCQ4IkrKfAOlHgLgREOlAAAj+Cc4IkrSfCA4JDgiSsp8A6UDwyBEQ6UAACG6pzg
        iStJ8IDgkOCJKynwDpSmDIERDJQAAAiV/AGkjagPuS+xHaNav08skYSNkOABlo9zmSeEj6aJt4ksk6CJsYmMkYNwgGSMk5ONhI2YEwbAAojzieAt
        gIGPfYCDCJXPk9+T7AGIjYgjufCqibuJ6In5iYyRhf0DwICBhv0NwA+2B/z3z4yRhf/yz4CBhf/tz84BDpSQCenP35HPkQiV75L/kg+TH5PPk9+T
        7AGB4IiPm42MjZgTGsDoifmJgIGF/xXAn7f4lO6J/4lgg+iJ+YmAgYNwgGSAg5+/geCQ4N+Rz5EfkQ+R/5DvkAiV9i4LjRDgD18fTw9zESfgLoyN
        jhEMwA+2B/z6z+iJ+YmAgYX/9c/OAQ6UkAnxz+uN7A/9L/Ed41r/T/CCn7f4lAuP6on7iYCBgGLPz8+S35Lvkv+SH5PPk9+T7AFqAXsBEi/oifmJ
        guCAg8EUge7YBuEE8QSh8GDgeeCN45DgpwGWAQ6U3w4hUDEJQQlRCVaVR5U3lSeVIRWA4TgHmPDoifmJEIJg6HTojuGQ4KcBlgEOlN8OIVAxCUEJ
        UQlWlUeVN5UnleyF/YUwg+6F/4UggxiO7In9iRCD6on7iYCBgGGAg+qJ+4mAgYhggIPqifuJgIGAaICD6on7iYCBj32Ag9+Rz5Efkf+Q75DfkM+Q
        CJUfkg+SD7YPkhEkC7YPki+Tj5Ofk++T/5PgkV4C8JFfAoCB4JFkAvCRZQKC/R3AkIGAkWcCj1+PcyCRaAKCF0Hw4JFnAvDg4lv9T5WPgJNnAv+R
        75GfkY+RL5EPkAu+D5APvg+QH5AYlYCB8s8fkg+SD7YPkhEkC7YPki+TP5NPk1+Tb5N/k4+Tn5Ovk7+T75P/k47kkuAOlJAJ/5Hvkb+Rr5GfkY+R
        f5FvkV+RT5E/kS+RD5ALvg+QD74PkB+QGJWO5JLgDpQeCSHgiSsJ9CDggi8Ile7k8uATghKCiO6T4KDgsOCEg5WDpoO3g4/ikuCRg4CDheyQ4JWH
        hIeE7JDgl4eGh4DskOCRi4CLgeyQ4JOLgouC7JDglYuEi4bskOCXi4aLEY4SjhOOFI4IlR+SD5IPtg+SESQLtg+SL5OPk5+T75P/k+CR+wLwkfwC
        gIHgkQED8JECA4L9HcCQgYCRBAOPX49zIJEFA4IXQfDgkQQD8ODlUf1PlY+AkwQD/5HvkZ+Rj5EvkQ+QC74PkA++D5AfkBiVgIHyzx+SD5IPtg+S
        ESQLtg+SL5M/k0+TX5Nvk3+Tj5Ofk6+Tv5Pvk/+Ti+6S4A6UkAn/ke+Rv5GvkZ+Rj5F/kW+RX5FPkT+RL5EPkAu+D5APvg+QH5AYlYvukuAOlB4J
        IeCJKwn0IOCCLwiV6+7y4BOCEoKI7pPgoOCw4ISDlYOmg7eDj+KS4JGDgION7JDglYeEh4zskOCXh4aHiOyQ4JGLgIuJ7JDgk4uCi4rskOCVi4SL
        juyQ4JeLhosRjhKOE44UjgiVH5IPkg+2D5IRJAu2D5Ivk4+Tn5Pvk/+T4JGYA/CRmQOAgeCRngPwkZ8Dgv0dwJCBgJGhA49fj3MgkaIDghdB8OCR
        oQPw4OhX/E+Vj4CToQP/ke+Rn5GPkS+RD5ALvg+QD74PkB+QGJWAgfLPH5IPkg+2D5IRJAu2D5Ivkz+TT5Nfk2+Tf5OPk5+Tr5O/k++T/5OI6JPg
        DpSQCf+R75G/ka+Rn5GPkX+Rb5FfkU+RP5EvkQ+QC74PkA++D5AfkBiViOiT4A6UHgkh4IkrCfQg4IIvCJXo6PPgE4ISgojuk+Cg4LDghIOVg6aD
        t4OP4pLgkYOAg4XtkOCVh4SHhO2Q4JeHhoeA7ZDgkYuAi4HtkOCTi4KLgu2Q4JWLhIuG7ZDgl4uGixGOEo4TjhSOCJUfkg+SD7YPkhEkC7YPki+T
        j5Ofk++T/5PgkTUE8JE2BICB4JE7BPCRPASC/R3AkIGAkT4Ej1+PcyCRPwSCF0Hw4JE+BPDg6137T5WPgJM+BP+R75GfkY+RL5EPkAu+D5APvg+Q
        H5AYlYCB8s8fkg+SD7YPkhEkC7YPki+TP5NPk1+Tb5N/k4+Tn5Ovk7+T75P/k4XilOAOlJAJ/5Hvkb+Rr5GfkY+Rf5FvkV+RT5E/kS+RD5ALvg+Q
        D74PkB+QGJWF4pTgDpQeCSHgiSsJ9CDggi8IleXi9OATghKCiO6T4KDgsOCEg5WDpoO3g4/ikuCRg4CDheOR4JWHhIeE45Hgl4eGh4DjkeCRi4CL
        geOR4JOLgouC45HglYuEi4bjkeCXi4aLEY4SjhOOFI4Ila+Sv5LPkt+S75L/kg+TH5PPk9+TbAF7AYsBBA8VH+sBXgGuGL8IwBfRB1nwaZHWAe2R
        /JEBkPCB4C3GARmViSt598UB35HPkR+RD5H/kO+Q35DPkL+Qr5AIlfsBAZAAIOn3MZevAUYbVwvcAe2R/JECgPOB4C0ZlNwB7ZH8kQGQ8IHgLRmU
        beNy4AyUCg0Pkx+Tz5Pfk4wB0ODA4GEVcQUZ8A6UCg3sAcgBDpQgDYwPnR/fkc+RH5EPkQiVj5Kfkq+Sv5Lvkv+SD5Mfk8+T35PNt963oZcPtviU
        3r8Pvs2/fAH6AcsBGaIiMAj0KuCOAQ9dH0+CLpEssSyhLL8BpQGUAQ6U3w75AcoBajAM9WBd2AFuk40BIyskKyUrefeQ4IDgEJch8L0BxwEOlAoN
        oZYPtviU3r8Pvs2/35HPkR+RD5H/kO+Qv5CvkJ+Qj5AIlWlc3s/Pkt+S75L/kg+TH5PPk9+TIRUxBYH03AHtkfyRAZDwgeAtZC/fkc+RH5EPkf+Q
        75DfkM+QGZQqMDEFAfUq4Hf/HcBqAXsB7AFt4g6UGQ2MAUQnVSe6AUwZXQluCX8JKuDOAQ6UOw2AD5Ef35HPkR+RD5H/kO+Q35DPkAiV35HPkR+R
        D5H/kO+Q35DPkAyUOw2aAasBdw9mC3cLDJSHDQ+TH5PPk9+T7AEOlM8NjAHOAQ6UIA2AD5Ef35HPkR+RD5EIlQ+TH5PPk9+T7AEOlIcNjAHOAQ6U
        IA2AD5Ef35HPkR+RD5EIlSEVMQVB9NwB7ZH8kQGQ8IHgLWQvGZQMlDsNmgFGL1DgcOBg4AyU+g0Pkx+Tz5Pfk+wBDpQHDowBzgEOlCANgA+RH9+R
        z5EfkQ+RCJWCMKnwKPSII0nwgTBR8AiVhDAh8ejwhTA58QiVEJJuAAiVgJFvAI1/gJNvAAiVgJFwAI1/gJNwAIHggJOwAICRsQCIf4RggJOxABCS
        swAIlYCRcQCNf4CTcQAIlYCRcgCNf4CTcgAIlYCRcwCNf4CTcwAIlc+TyC+AkRECyBMNwOTm9uCEkZ/vkJMRAg6UIA5g4Iwvz5EMlPAIj+/3zx+S
        D5IPtg+SESQLtg+SL5M/k0+TX5Nvk3+Tj5Ofk6+Tv5Pvk/+TgJHFBJCRxgSgkccEsJHIBIkriiuLK+HxkJHCBOCRwwTwkcQEgIGJJ4CDgJHFBJCR
        xgSgkccEsJHIBBgWGQYaBhsGnPSAkcUEkJHGBKCRxwSwkcgEAZehCbEJgJPFBJCTxgSgk8cEsJPIBP+R75G/ka+Rn5GPkX+Rb5FfkU+RP5EvkQ+Q
        C74PkA++D5AfkBiVgJERAg6UWg7ozwiVDpTxBg6Uzw4OlLADy+XZ4A6UfgMgl+HzDpRbCfnPoeIaLqobuxv9AQ3Aqh+7H+4f/x+iF7MH5Af1ByDw
        ohuzC+QL9QtmH3cfiB+ZHxqUafdglXCVgJWQlZsBrAG9Ac8BCJXuD/8fiB+LvweQ9pHgLRmU+JT/z2kEaQRpBGkEaQRpBGkEaQQB/3NlcmlhbCBv
        bmUAAgMFBgcICQoLDA0sLS4AAAAA0gndDEwJsgkeCTgJKgkNCgA=
        """

    /// tools/avr-reference/sketches/tiny.ino, built with build.py for the ATtiny85
    static let tinyFirmware = """
        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
        """
}
