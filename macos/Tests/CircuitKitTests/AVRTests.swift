import XCTest
@testable import CircuitKit

/// The ATmega328P emulator, running real Arduino sketches compiled with avr-gcc 7.3 and the Arduino AVR core (the
/// sketches are at the end of this file). The simavr checkpoints were recorded by running the same firmware in simavr
/// one instruction at a time; in its simavr mode the emulator must be in exactly the same state at those points.
final class AVRTests: XCTestCase {
    struct Checkpoint {
        let instructions: Int
        let cycle: Int
        let pc: Int
        let sreg: Int
        let sp: Int
        let registers: [Int]
    }

    private func firmware(_ base64: String) -> [UInt8] {
        [UInt8](Data(base64Encoded: base64.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: ""))!)
    }

    /// Runs in simavr mode, counting an interrupt entry with the instruction before it as simavr does
    static func compareWithSimavr(_ avr: AVR, _ checkpoints: [Checkpoint], file: StaticString = #filePath, line: UInt = #line) {
        avr.simavrMode()
        var instructions = 0
        for checkpoint in checkpoints {
            while instructions < checkpoint.instructions {
                avr.step()
                if avr.interruptReady { avr.step() }
                instructions += 1
            }
            XCTAssertEqual(avr.cycles, checkpoint.cycle, "cycle after \(instructions)", file: file, line: line)
            XCTAssertEqual(avr.pc, checkpoint.pc, "pc after \(instructions)", file: file, line: line)
            XCTAssertEqual(Int(avr.statusRegister), checkpoint.sreg, "SREG after \(instructions)", file: file, line: line)
            XCTAssertEqual(avr.stackPointer, checkpoint.sp, "SP after \(instructions)", file: file, line: line)
            XCTAssertEqual(avr.registers.map { Int($0) }, checkpoint.registers, "registers after \(instructions)", file: file, line: line)
        }
    }

    func testMatchesSimavrInstructionByInstruction() {
        let kitchen = AVR(firmware: firmware(Self.kitchen))
        kitchen.supply = 3.3  // simavr's AVCC
        kitchen.pinVoltages = [Double](repeating: 2.5, count: 20)
        Self.compareWithSimavr(kitchen, [
            Checkpoint(instructions: 1000, cycle: 1572, pc: 1592, sreg: 2, sp: 2301,
                   registers: [47, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 232, 3, 0, 0, 104, 0, 61, 1]),
            Checkpoint(instructions: 100000, cycle: 139274, pc: 2594, sreg: 130, sp: 2240,
                   registers: [204, 0, 1, 0, 0, 0, 0, 3, 98, 117, 220, 68, 98, 117, 220, 68, 6, 0, 0, 0, 160, 255, 0, 0, 96, 252, 0, 0, 61, 1, 38, 0]),
            Checkpoint(instructions: 1000000, cycle: 1369420, pc: 737, sreg: 130, sp: 2289,
                   registers: [30, 0, 0, 0, 0, 0, 0, 0, 172, 77, 1, 0, 1, 0, 0, 0, 0, 0, 123, 128, 0, 0, 123, 83, 0, 0, 0, 0, 206, 4, 193, 0]),
        ])
        let blink = AVR(firmware: firmware(Self.blink))
        Self.compareWithSimavr(blink, [Checkpoint(instructions: 500000, cycle: 687060, pc: 342, sreg: 130, sp: 2287,
                   registers: [162, 0, 0, 0, 0, 0, 0, 0, 32, 164, 0, 0, 58, 0, 0, 0, 0, 0, 217, 128, 0, 0, 217, 41, 0, 0, 0, 0, 163, 2, 0, 0])])
    }

    func testSketchPrintsWhatItComputes() {
        // integer, long, float and PROGMEM work, Serial, analogRead and micros(), on the chip's own timing
        let avr = AVR(firmware: firmware(Self.kitchen))
        avr.pinVoltages = [Double](repeating: 2.5, count: 20)
        avr.run(cycles: 16_000 * 60)
        let text = String(decoding: avr.serialOutput, as: UTF8.self)
        XCTAssertEqual(text, "flash string\r\n123458023\r\n2021822266\r\n100046\r\n610\r\n0.86603\r\n1.414214\r\n18.9087\r\n3141590.00\r\n-1763.668\r\n9939\r\n2306FB5D\r\n-4294\r\n101101\r\n512\r\n512\r\n13\r\n14332\r\n17636\r\n20908\r\n24180\r\n27456\r\n30744\r\n34016\r\n37288\r\n40560\r\n43832\r\n47120\r\n50392\r\n53664\r\n56936\r\n")
    }

    func testBlinkTogglesPin13() {
        let avr = AVR(firmware: firmware(Self.blink))
        XCTAssertEqual(avr.pinStates[13], .input(pullUp: false), "inputs at reset")
        var changes: [Double] = []
        var last: PinState?
        while Double(avr.cycles) < 16e6 * 0.55 {
            avr.run(cycles: 160)
            let state = avr.pinStates[13]
            if case .output = state, state != last { changes.append(Double(avr.cycles) / 16e6) }
            last = state
        }
        // low (pinMode), high, then every 100 ms low and high again
        XCTAssertEqual(changes.count, 7)
        for k in 2..<changes.count { XCTAssertEqual(changes[k] - changes[k - 1], 0.1, accuracy: 0.001) }
        XCTAssertEqual(avr.pinStates[12], .input(pullUp: false))
    }

    func testPWMDutyAndFrequencyFollowTheDatasheet() {
        let avr = AVR(firmware: firmware(Self.pwm))
        avr.run(cycles: 16_000 * 20)
        let pins = [9, 5, 6, 10, 8]
        var high = [Int: Int]()
        var rises = [Int: Int]()
        var previous = [Int: Bool]()
        var samples = 0
        let start = avr.cycles
        while avr.cycles - start < 16_000 * 100 {
            avr.run(cycles: 16)
            samples += 1
            let states = avr.pinStates
            for pin in pins {
                let isHigh = states[pin] == .output(high: true)
                if isHigh { high[pin, default: 0] += 1 }
                if isHigh && previous[pin] == false { rises[pin, default: 0] += 1 }
                previous[pin] = isHigh
            }
        }
        // Timer1 (pins 9, 10) phase correct at 490 Hz: OCR / 255; Timer0 (5, 6) fast PWM at 977 Hz: (OCR + 1) / 256;
        // tone(8, 440) toggles pin 8 from Timer2's compare interrupt
        let expected: [(Int, Double, Double)] = [(9, 77 / 255, 490.2), (10, 250 / 255, 490.2), (5, 201 / 256, 976.6),
                                                  (6, 11 / 256, 976.6), (8, 0.5, 440)]
        for (pin, duty, frequency) in expected {
            XCTAssertEqual(Double(high[pin] ?? 0) / Double(samples), duty, accuracy: 0.004, "duty of pin \(pin)")
            XCTAssertEqual(Double(rises[pin] ?? 0) / 0.1, frequency, accuracy: frequency * 0.05, "frequency of pin \(pin)")
        }
    }

    func testExternalInterruptCountsPresses() {
        let avr = AVR(firmware: firmware(Self.interrupt))
        var volts = [Double](repeating: 5, count: 20)
        avr.pinVoltages = volts
        avr.run(cycles: 16_000 * 5)
        XCTAssertEqual(avr.pinStates[2], .input(pullUp: true))
        for _ in 0..<3 {
            volts[2] = 0
            avr.pinVoltages = volts
            avr.run(cycles: 16_000 * 2)
            volts[2] = 5
            avr.pinVoltages = volts
            avr.run(cycles: 16_000 * 20)
        }
        XCTAssertEqual(String(decoding: avr.serialOutput, as: UTF8.self), "0\r\n1\r\n2\r\n3\r\n")
        XCTAssertEqual(avr.pinStates[13], .output(high: true), "three presses: odd")
    }

    func testEmulatesFasterThanRealTime() {
        let avr = AVR(firmware: firmware(Self.kitchen))
        avr.run(cycles: 16_000 * 200)  // past setup, into the loop of Serial.println(micros())
        let start = Date()
        avr.run(cycles: 16_000_000)
        let wall = Date().timeIntervalSince(start)
        print("one second of ATmega328P time took \(wall) s")
        XCTAssertLessThan(wall, 1, "16 MHz in real time")
    }

    // MARK: - Firmware

    static let blink = """
        DJReAAyUoQAMlMgADJSGAAyUhgAMlIYADJSGAAyUMQQMlIYADJSGAAyUhgAMlIYADJSGAAyUhgAMlIYADJSGAAyU8AAMlIYADJRAAwyUcgMMlI
        YADJSGAAyUhgAMlIYADJSGAAyUhgAAAAAIAAIBAAADBAcAAAAAAAAAAAECBAgQIECAAQIECBAgAQIECBAgBAQEBAQEBAQCAgICAgIDAwMDAwMA
        AAAAJQAoACsAAAAAACQAJwAqAAIAogMRJB++z+/Y4N6/zb8R4KDgseDq5PngAsAFkA2SqDGxB9n3IeCo4bHgAcAdkqU8sgfh9xDgzuXQ4ATAIZ
        f+AQ6UnQTNNdEHyfcOlI4EDJSjBAyUAABh4I3gDJT8AWHgjeAOlDgCZOZw4IDgkOAOlF8BYOCN4A6UOAJk5nDggOCQ4AyUXwEIlR+SD5IPtg+S
        ESQvkz+TT5Nfk2+Tf5OPk5+Tr5O/k++T/5PgkQAB8JEBAQmV/5Hvkb+Rr5GfkY+Rf5FvkV+RT5E/kS+RD5APvg+QH5AYlR+SD5IPtg+SESQvkz
        +TT5Nfk2+Tf5OPk5+Tr5O/k++T/5PgkQIB8JEDAQmV/5Hvkb+Rr5GfkY+Rf5FvkV+RT5E/kS+RD5APvg+QH5AYlQiVH5IPkg+2D5IRJC+TP5OP
        k5+Tr5O/k4CRGQGQkRoBoJEbAbCRHAEwkRgBI+AjDy03WPUBlqEdsR0gkxgBgJMZAZCTGgGgkxsBsJMcAYCRHQGQkR4BoJEfAbCRIAEBlqEdsR
        2Akx0BkJMeAaCTHwGwkyABv5GvkZ+Rj5E/kS+RD5APvg+QH5AYlSboIw8ClqEdsR3Szz+3+JSAkR0BkJEeAaCRHwGwkSABJrWomwXALz8Z8AGW
        oR2xHT+/ui+pL5gviCe8Ac0BYg9xHYEdkR1C4GYPdx+IH5kfSpXR9wiVj5Kfkq+Sv5LPkt+S75L/kmsBfAEOlDoBSwFcAcEU0QThBPEE6fAOlO
        8ADpQ6AWgZeQmKCZsJaD5zQIEFkQVw8yHgwhrRCOEI8QiI7ogOg+CYHqEcsRzBFNEE4QTxBCn3/5DvkN+Qz5C/kK+Qn5CPkAiVeJSEtYJghL2E
        tYFghL2FtYJghb2FtYFghb3u5vDggIGBYICD4ejw4BCCgIGCYICDgIGBYICD4Ojw4ICBgWCAg+Hr8OCAgYRggIPg6/DggIGBYICD6ufw4ICBhG
        CAg4CBgmCAg4CBgWCAg4CBgGiAgxCSwQAIlYMwgfAo9IEwmfCCMKnwCJWHMKnwiDDJ8IQwsfSAkYAAj30DwICRgACPd4CTgAAIlYS1j3eEvQiV
        hLWPffvPgJGwAI93gJOwAAiVgJGwAI99+c/Pk9+TkOD8AeRY/08kkYBXn0/8AYSRiCPJ8JDgiA+ZH/wB4lX/T6WRtJH8AexV/0/FkdSRYRENwJ
        +3+JSMkSCVgiOMk4iBKCMog5+/35HPkQiVYjBR9J+3+JQ8kYIvgJWDI4yT6IEuK+/Pj7f4lOyRLissk4+/6s8fk8+T35MoLzDg+QHoWf9PhJH5
        AeRY/0/UkfkB4Ff/T8SRzCOp8BYvgREOlNMB7C/w4O4P/x/sVf9PpZG0kY+3+JTskRERCMDQld4j3JOPv9+Rz5EfkQiV3iv4z/wBkY0ijYkvkO
        CAXJ9PghuRCY9zmScIlfwBkY2CjZgXMfCCjegP8R2FjZDgCJWP75/vCJX8AZGNgo2YF2Hwoo2uD78vsR1dloyRko2fX59zko+Q4AiVj++f7wiV
        /AFTjUSNJS8w4IQvkOCCG5MLVBcQ8M+WCJUBlwiViOmT4IkrSfCA4JDgiSsp8A6UmAOBEQyUAAAIlfwBpI2oD7kvsR2jWr9PLJGEjZDgAZaPc5
        knhI+mibeJLJOgibGJjJGDcIBkjJOTjYSNmBMGwAKI84ngLYCBj32AgwiVz5Pfk+wBiI2II7nwqom7ieiJ+YmMkYX9A8CAgYb9DcAPtgf898+M
        kYX/8s+AgYX/7c/OAQ6UsQLpz9+Rz5EIle+S/5IPkx+Tz5Pfk+wBgeCIj5uNjI2YExrA6In5iYCBhf8VwJ+3+JTuif+JYIPoifmJgIGDcIBkgI
        Ofv4HgkODfkc+RH5EPkf+Q75AIlfYuC40Q4A9fH08PcxEn4C6MjY4RDMAPtgf8+s/oifmJgIGF//XPzgEOlLEC8c/rjewP/S/xHeNa/0/wgp+3
        +JQLj+qJ+4mAgYBiz88fkg+SD7YPkhEkL5OPk5+T75P/k+CRMQHwkTIBgIHgkTcB8JE4AYL9G8CQgYCROgGPX49zIJE7AYIXQfDgkToB8ODvXf
        5PlY+AkzoB/5HvkZ+Rj5EvkQ+QD74PkB+QGJWAgfTPH5IPkg+2D5IRJC+TP5NPk1+Tb5N/k4+Tn5Ovk7+T75P/k4HikeAOlLEC/5Hvkb+Rr5Gf
        kY+Rf5FvkV+RT5E/kS+RD5APvg+QH5AYlYHikeAOlGYCIeCJKwn0IOCCLwiV4eLx4BOCEoKI7pPgoOCw4ISDlYOmg7eDieCR4JGDgIOF7JDglY
        eEh4TskOCXh4aHgOyQ4JGLgIuB7JDgk4uCi4LskOCVi4SLhuyQ4JeLhosRjhKOE44UjgiVr5K/ks+S35Lvkv+SD5Mfk8+T35NsAXsBiwEEDxUf
        6wFeAa4YvwjAF9EHWfBpkdYB7ZH8kQGQ8IHgLcYBCZWJK3n3xQHfkc+RH5EPkf+Q75DfkM+Qv5CvkAiVgTA58BjwgjBR8AiVEJJuAAiVgJFvAI
        1/gJNvAAiVgJFwAI1/gJNwAIHggJOwAICRsQCIf4RggJOxABCSswAIlc+TyC+AkQQByBMNwOjr8OCEkZ/vkJMEAQ6U/ANg4Iwvz5EMlDgCj+/3
        zx+SD5IPtg+SESQvkz+TT5Nfk2+Tf5OPk5+Tr5O/k++T/5OAkcEBkJHCAaCRwwGwkcQBiSuKK4sr0fGQkb4B4JG/AfCRwAGAgYkngIOAkcEBkJ
        HCAaCRwwGwkcQBGBYZBhoGGwac9ICRwQGQkcIBoJHDAbCRxAEBl6EJsQmAk8EBkJPCAaCTwwGwk8QB/5Hvkb+Rr5GfkY+Rf5FvkV+RT5E/kS+R
        D5APvg+QH5AYlYCRBAEOlBwE6s8IlQ6UmAEOlI0EDpSIAMPq0uAOlIwAIJfh8w6UowL5z+4P/x8FkPSR4C0JlPiU/8+gAKAA/wAAAADzAs8DlA
        LTAmYCgAJyAgA=
        """

    static let kitchen = """
        DJRpAAyUHwIMlEYCDJSRAAyUkQAMlJEADJSRAAyU4ggMlJEADJSRAAyUkQAMlJEADJSRAAyUkQAMlJEADJSRAAyUbgIMlJEADJTNBQyU/wUMlJ
        EADJSRAAyUkQAMlJEADJSRAAyUkQBmbGFzaCBzdHJpbmcAAAAACAACAQAAAwQHAAAAAAAAAAABAgQIECBAgAECBAgQIAECBAgQIAQEBAQEBAQE
        AgICAgICAwMDAwMDAAAAACMAJgApAAAAAAAlACgAKwAAAAAAJAAnACoAAi8GESQfvs/v2ODev82/EeCg4LHg6OX44QLABZANkqQzsQfZ9yHgpO
        Ox4AHAHZKhPrIH4fcQ4Mnm0OAEwCGX/gEOlA4MyDbRB8n3DpQ/CQyUKgwMlAAAYg9zH4QflR8Ilc+S35Lvkv+SawF8AcoBuQGnAZYBDpSKC/+Q
        75DfkM+QCJUhFTEFQQVRBRHwDpTQC8oBuQEIlc+S35Lvkv+Sz5Pfk9gvyC/BLNEsdgHCMHD00XDHAbYBbQ9xHYEdkR3fkc+R/5DvkN+Qz5AIlY
        /vjA8OlLMAwlDGDtce6B75HubPZ+Bw4A6UmguGMJEFQPSEX55P/AGAgQguAAyZCwiVg+aQ4AiVz5Lfku+S/5IPkx+Tz5Pfk8233rdklw+2+JTe
        vw++zb8m4EDgUuxh4HDgjeOR4A6UawVh4I3gDpT+A23kcOCJ4A6UeANo7HDgheAOlHgDb+Fw4IvgDpR4A2jmcODOAQGWDpQjDL4Bb19/T43jke
        AOlKMGAOAR4NgB7ZH9kY0BIu004EDgUOBl4X3si+WX4AmVqwG8ASrgMOCN45HgDpRnB7HgBjAbBzn3j+AOlLMAqwG8ASrgMOCN45HgDpSlByXg
        MOBB7VPrbeV/443jkeAOlJsIJuAw4EPvVOBl63/jjeOR4A6Umwgk4DDgROBV5GfpceSN45HgDpSbCCLgMOBI5V/rb+N65I3jkeAOlJsII+Aw4E
        LmVeds7XTsjeOR4A6UmwgO7B/v8SzhLMgBDpTYAJgBI3AzJ6wBJJ/AASWfkA00n5ANESSYATWVJ5U1lSeVghuTC+gO+R4PXx9PAjMRBSH3SuBQ
        4LcBjeOR4A6UVQfBLNEsdgFF7F3pbOFx6JoBqwEsJT0lTiVfJWPpceCA4JHgDpSKC6sBvAGP78ga2AroCvgKqOzKFtEE4QTxBDn3IOEw4I3jke
        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
        f8+s/oifmJgIGF//XPzgEOlNwE8c/rjewP/S/xHeNa/0/wgp+3+JQLj+qJ+4mAgYBiz8/Pkt+S75L/kh+Tz5Pfk+wBagF7ARIv6In5iYLggIPB
        FIHu2AbhBPEEofBg4HngjeOQ4KcBlgEOlK4LIVAxCUEJUQlWlUeVN5UnlSEVgOE4B5jw6In5iRCCYOh06I7hkOCnAZYBDpSuCyFQMQlBCVEJVp
        VHlTeVJ5Xshf2FMIPuhf+FIIMYjuyJ/YkQg+qJ+4mAgYBhgIPqifuJgIGIYICD6on7iYCBgGiAg+qJ+4mAgY99gIPfkc+RH5H/kO+Q35DPkAiV
        H5IPkg+2D5IRJC+Tj5Ofk++T/5PgkU0B8JFOAYCB4JFTAfCRVAGC/RvAkIGAkVYBj1+PcyCRVwGCF0Hw4JFWAfDg41z+T5WPgJNWAf+R75GfkY
        +RL5EPkA++D5AfkBiVgIH0zx+SD5IPtg+SESQvkz+TT5Nfk2+Tf5OPk5+Tr5O/k++T/5ON45HgDpTcBP+R75G/ka+Rn5GPkX+Rb5FfkU+RP5Ev
        kQ+QD74PkB+QGJWN45HgDpSRBCHgiSsJ9CDggi8Ile3j8eATghKCiO6T4KDgsOCEg5WDpoO3g4bhkeCRg4CDheyQ4JWHhIeE7JDgl4eGh4DskO
        CRi4CLgeyQ4JOLgouC7JDglYuEi4bskOCXi4aLEY4SjhOOFI4Ila+Sv5LPkt+S75L/kg+TH5PPk9+TbAF7AYsBBA8VH+sBXgGuGL8IwBfRB1nw
        aZHWAe2R/JEBkPCB4C3GAQmViSt598UB35HPkR+RD5H/kO+Q35DPkL+Qr5AIlfsBAZAAIOn3MZevAUYbVwvcAe2R/JECgPOB4C0JlNwB7ZH8kQ
        GQ8IHgLQmUZOJx4AyUiQYPkx+Tz5Pfk4wB0ODA4GEVcQUZ8A6UiQbsAcgBDpSfBowPnR/fkc+RH5EPkQiVj5Kfkq+Sv5Lvkv+SD5Mfk8+T35PN
        t963oZcPtviU3r8Pvs2/fAH6AcsBGaIiMAj0KuCOAQ9dH0+CLpEssSyhLL8BpQGUAQ6Urgv5AcoBajAM9WBd2AFuk40BIyskKyUrefeQ4IDgEJ
        ch8L0BxwEOlIkGoZYPtviU3r8Pvs2/35HPkR+RD5H/kO+Qv5CvkJ+Qj5AIlWlc3s/Pkt+S75L/kg+TH5PPk9+TIRUxBYH03AHtkfyRAZDwgeAt
        ZC/fkc+RH5EPkf+Q75DfkM+QCZQqMDEFAfUq4Hf/HcBqAXsB7AFt4g6UmAaMAUQnVSe6AUwZXQluCX8JKuDOAQ6UugaAD5Ef35HPkR+RD5H/kO
        +Q35DPkAiV35HPkR+RD5H/kO+Q35DPkAyUugaaAasBdw9mC3cLDJQGBw+TH5PPk9+T7AEOlE4HjAHOAQ6UnwaAD5Ef35HPkR+RD5EIlQ+TH5PP
        k9+T7AEOlAYHjAHOAQ6UnwaAD5Ef35HPkR+RD5EIlSEVMQVB9NwB7ZH8kQGQ8IHgLWQvCZQMlLoGmgFGL1DgcOBg4AyUeQcPkx+Tz5Pfk+wBDp
        SGB4wBzgEOlJ8GgA+RH9+Rz5EfkQ+RCJWaAasBcOBg4AyUeQcPkx+Tz5Pfk+wBDpR5B4wBzgEOlJ8GgA+RH9+Rz5EfkQ+RCJUvkj+ST5Jfkm+S
        f5KPkp+Sr5K/ks+S35Lvkv+SH5PPk9+T7AFqAXsBci6rAZYBywG2AQ6UhQtn4nHggREmwEYBVwHolLf4L+8/70/nX+fFAbQBDpSFC4ERDMAv7z
        /vT+df58UBtAEOlLsJa+Jx4BgWZPAv7z/vT+df5McBtgEOlBMLGBa09G/iceDOAd+Rz5Efkf+Q75DfkM+Qv5CvkJ+Qj5B/kG+QX5BPkD+QL5AM
        lIkGL+8/70/nX+zHAbYBDpS7CYf94M8g4DDgqQHHAbYBDpS7CTEsISyH/wnAbeLOAQ6UmAYcAff68JT3+PCUEOBg4HDggOCf43EWQfAg4DDgQO
        JR5A6UwAkfX/bPpwGWAQ6UTwkrATwBDpQyCksBXAEq4LwBpAHOAQ6UugZ8AeIM8xwRI7HxxQG0AQ6UYQqbAawBwwGyAQ6UTglLAVwBbuLOAQ6U
        mAboDvkeEVAQ8SDgMOBA4lHkxQG0AQ6UGAsrATwBDpQyCksBSuBQ4M4BDpSfB+gO+R60AZDggOAOlGEKmwGsAcMBsgEOlE4JSwFcAdzPxwHfkc
        +RH5H/kO+Q35DPkL+Qr5CfkI+Qf5BvkF+QT5A/kC+QCJUPkx+Tz5Pfk+wBDpS3B4wBzgEOlJ8GgA+RH9+Rz5EfkQ+RCJWBMDnwGPCCMFHwCJUQ
        km4ACJWAkW8AjX+Ak28ACJWAkXAAjX+Ak3AAgeCAk7AAgJGxAIh/hGCAk7EAEJKzAAiVz5PIL4CRCwHIEw3A7+zw4ISRn++QkwsBDpStCGDgjC
        /PkQyUOgSP7/fPH5IPkg+2D5IRJC+TP5NPk1+Tb5N/k4+Tn5Ovk7+T75P/k4CR3QGQkd4BoJHfAbCR4AGJK4oriyvR8ZCR2gHgkdsB8JHcAYCB
        iSeAg4CR3QGQkd4BoJHfAbCR4AEYFhkGGgYbBpz0gJHdAZCR3gGgkd8BsJHgAQGXoQmxCYCT3QGQk94BoJPfAbCT4AH/ke+Rv5GvkZ+Rj5F/kW
        +RX5FPkT+RL5EPkA++D5AfkBiVgJELAQ6UzQjqzwiVDpQiAw6UPgkOlOoAzuzU4A6UBAIgl+HzDpTOBPnPUFi7J6onDpRmCQyU2QoOlMsKOPAO
        lNIKIPA59J8/GfQm9AyUyAoO9OCV5/sMlMIK6S8OlOoKWPO6F2IHcweEB5UHIPB59Kb1DJQMCw704JULLrovoC0LAbkBkAEMAcoBoAERJP8nWR
        uZ8Fk/UPRQPmjxGhbwQKIvIy80L0QnWF/zz0aVN5UnlaeV8EBTlcn3fvQfFroLYgtzC4QLuvCRUKHw/w+7H2Yfdx+IH8L3DsC6D2Ifcx+EH0j0
        h5V3lWeVt5X3lZ4/CPCwz5OViA8I8Jkn7g+XlYeVCJUOlJ4KCPSB4AiVDpTUCQyU2QoOlNIKWPAOlMsKQPAp9F8/KfAMlMIKUREMlA0LDJTICg
        6U6gpo85kjsfNVI5HzlRtVC7snqidiF3MHhAc48J9fX08iDzMfRB+qH6nzNdAOLjrw4Ogy0JFQUEDmlQAcyvcr0P4vKdBmD3cfiB+7HyYXNwdI
        B6sHsOgJ8LsLgC2/Af8nk1hfTzrwnj9RBXjwDJTCCgyUDQtfP+TzmD7U84aVd5VnlbeV95WfX8n3iA+RHZaVh5WX+QiV4eBmD3cfiB+7H2IXcw
        eEB7oHIPBiG3MLhAu6C+4fiPfglQiVDpTyCojwn1eY8LkvmSe3UbDw4fBmD3cfiB+ZHxrwupXJ9xTAsTCR8A6UDAux4AiVDJQMC2cveC+IJ7hf
        OfC5P8zzhpV3lWeVs5XZ9z70kJWAlXCVYZV/T49Pn08IleiUCcCX+z70kJWAlXCVYZV/T49Pn0+ZI6nw+S+W6bsnk5X2lYeVd5VnlbeV8RH4z/
        r0uw8R9GD/G8BvX39Pj0+fTxbAiCMR8JbpEcB3IyHwnuiHL3YvBcBmI3HwluiGL3DgYOAq8JqVZg93H4gf2veID5aVh5WX+QiVmQ8ACFUPqgvg
        6P7vFhYXBugH+QfA8BIWEwbkB/UHmPBiG3MLhAuVCzn0CiZh8CMrJCslKyH0CJUKJgn0oUCmlY/vgR2BHQiVl/mfZ4DocOBg4AiVn++A7AiVAC
        QKlBYWFwYYBgkGCJUAJAqUEhYTBhQGBQYIlQkuA5QADBH0iCNS8LsPQPS/KxH0YP8EwG9ff0+PT59PCJVX/ZBYRA9VH1nwXz9x8EeViA+X+5kf
        YfCfP3nwh5UIlRIWEwYUBlUf8s9GlfHfCMAWFhcGGAaZH/HPhpVxBWEFCJQIleiUuydmJ3cnywGX+QiVDpSeCgj0j+8IlQ6UKwsMlNkKDpTLCj
        jwDpTSCiDwlSMR8AyUwgoMlMgKESQMlA0LDpTqCnDzlZ/B85UPUOBVH2Kf8AFyn7sn8A2xHWOfqifwDbEdqh9kn2YnsA2hHWYfgp8iJ7ANoR1i
        H3OfsA2hHWIfg5+gDWEdIh90nzMnoA1hHSMfhJ9gDSEdgi92L2ovESSfV1BAmvDx8IgjSvDuD/8fux9mH3cfiB+RUFBAqfeeP1EFgPAMlMIKDJ
        QNC18/5POYPtTzhpV3lWeVt5X3leeVn1/B9/4riA+RHZaVh5WX+QiVDpSeCogLmQsIldsBj5Ofkw6U7wu/ka+Rop+ADZEdo5+QDbKfkA0RJAiV
        l/sHLhb0AJQH0Hf9CdAOlPoLB/wF0D70kJWBlZ9PCJVwlWGVf08IlaHiGi6qG7sb/QENwKofux/uH/8fohezB+QH9Qcg8KIbswvkC/ULZh93H4
        gfmR8alGn3YJVwlYCVkJWbAawBvQHPAQiVBS6X+x70AJQOlOcLV/0H0A6UrgsH/APQTvQMlOcLUJVAlTCVIZU/T09PX08IlZCVgJVwlWGVf0+P
        T59PCJUOlBQMpZ+QDbSfkA2kn4ANkR0RJAiVqhu7G1HhB8CqH7sfphe3BxDwphu3C4gfmR9alan3gJWQlbwBzQEIle4P/x8FkPSR4C0JlKKfsA
        Gzn8ABo59wDYEdESSRHbKfcA2BHREkkR0IlfsB3AEFkA2SACDh9wiV+JT/z5MAmACpAB4CHgIB/woVIS80RAAAAAAeBVwGvwT+BJEEqwSdBA0K
        AG5hbgBpbmYAb3ZmAAA=
        """

    static let pwm = """
        DJReAAyUsAAMlNcADJSGAAyUhgAMlIYADJSGAAyUrAYMlIYADJSGAAyUhgAMlIYADJSGAAyUhgAMlIYADJSGAAyU/gAMlIYADJRNAwyUfwMMlI
        YADJSGAAyUhgAMlIYADJSGAAyUhgAAAAAIAAIBAAADBAcAAAAAAAAAAAECBAgQIECAAQIECBAgAQIECBAgBAQEBAQEBAQCAgICAgIDAwMDAwMA
        AAAAJQAoACsAAAAAACQAJwAqAAIArwMRJB++z+/Y4N6/zb8R4KDgseDm7/7gAsAFkA2SqDGxB9n3IeCo4bHgAcAdkqM9sgfh9xDgzuXQ4ATAIZ
        f+AQ6UZAfNNdEHyfcOlAkHDJR5BwyUAABt5HDgieAOlIMBaOxw4IXgDpSDAW/hcOCL4A6UgwFg6HDgg+AOlIMBauBw4IbgDpSDAWrvcOCK4A6U
        gwEg4DDgqQFo63HgiOAMlAkECJUIlR+SD5IPtg+SESQvkz+TT5Nfk2+Tf5OPk5+Tr5O/k++T/5PgkQAB8JEBAQmV/5Hvkb+Rr5GfkY+Rf5FvkV
        +RT5E/kS+RD5APvg+QH5AYlR+SD5IPtg+SESQvkz+TT5Nfk2+Tf5OPk5+Tr5O/k++T/5PgkQIB8JEDAQmV/5Hvkb+Rr5GfkY+Rf5FvkV+RT5E/
        kS+RD5APvg+QH5AYlR+SD5IPtg+SESQvkz+Tj5Ofk6+Tv5OAkRkBkJEaAaCRGwGwkRwBMJEYASPgIw8tN1j1AZahHbEdIJMYAYCTGQGQkxoBoJ
        MbAbCTHAGAkR0BkJEeAaCRHwGwkSABAZahHbEdgJMdAZCTHgGgkx8BsJMgAb+Rr5GfkY+RP5EvkQ+QD74PkB+QGJUm6CMPApahHbEd0s94lIS1
        gmCEvYS1gWCEvYW1gmCFvYW1gWCFve7m8OCAgYFggIPh6PDgEIKAgYJggIOAgYFggIPg6PDggIGBYICD4evw4ICBhGCAg+Dr8OCAgYFggIPq5/
        DggIGEYICDgIGCYICDgIGBYICDgIGAaICDEJLBAAiVH5PPk9+TGC/rAWHgDpQJAiCXOfRg4IEv35HPkR+RDJRFAs8/0QUR9GHg9c/hL/Dg6Fn/
        T+SR4zAx8UD04TCx8OIw4fDAONEFfPfkz+cwKfHoMFnx5DCx94CRgACAYoCTgADQk4sAwJOKAATAhLWAaIS9x73fkc+RH5EIlYS1gGKEvci998
        +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
        """

    static let interrupt = """
        DJReAAyU8QAMlBgBDJSGAAyUhgAMlIYADJSGAAyUSwUMlIYADJSGAAyUhgAMlIYADJSGAAyUhgAMlIYADJSGAAyUPwEMlIYADJSTAwyUxQMMlI
        YADJSGAAyUhgAMlIYADJSGAAyUhgAAAAAIAAIBAAADBAcAAAAAAAAAAAECBAgQIECAAQIECBAgAQIECBAgBAQEBAQEBAQCAgICAgIDAwMDAwMA
        AAAAJQAoACsAAAAAACQAJwAqAAIA9QMRJB++z+/Y4N6/zb8R4KDgseDi7PvgAsAFkA2SrDGxB9n3IeCs4bHgAcAdkqs8sgfh9xDgzuXQ4ATAIZ
        f+AQ6U2QXNNdEHyfcOlKgFDJTfBQyUAACAkRwBkJEdAQGWkJMdAYCTHAEIlWLgguAOlO0BYeCN4A6U7QFC4FDgaOhw4IDgDpTRACbgQOhV4mDg
        cOCH4pHgDJQxA2CRHAFwkR0BYXCN4A6UKQIgkRwBMJEdAYCRAAGQkQEBKBc5B5HwgJEcAZCRHQGQkwEBgJMAAWCRHAFwkR0BSuBQ4IfikeAMlA
        QFCJUIlYIw6PToL/Dg7g//H+5f/k9xg2CDgTBB8ICRaQCMf0grQJNpAOiaCJWAkWkAg39ED1UfRA9VH0grQJNpAOmaCJUfkg+SD7YPkhEkL5M/
        k0+TX5Nvk3+Tj5Ofk6+Tv5Pvk/+T4JECAfCRAwEJlf+R75G/ka+Rn5GPkX+Rb5FfkU+RP5EvkQ+QD74PkB+QGJUfkg+SD7YPkhEkL5M/k0+TX5
        Nvk3+Tj5Ofk6+Tv5Pvk/+T4JEEAfCRBQEJlf+R75G/ka+Rn5GPkX+Rb5FfkU+RP5EvkQ+QD74PkB+QGJUfkg+SD7YPkhEkL5M/k4+Tn5Ovk7+T
        gJEfAZCRIAGgkSEBsJEiATCRHgEj4CMPLTdY9QGWoR2xHSCTHgGAkx8BkJMgAaCTIQGwkyIBgJEjAZCRJAGgkSUBsJEmAQGWoR2xHYCTIwGQky
        QBoJMlAbCTJgG/ka+Rn5GPkT+RL5EPkA++D5AfkBiVJugjDwKWoR2xHdLPeJSEtYJghL2EtYFghL2FtYJghb2FtYFghb3u5vDggIGBYICD4ejw
        4BCCgIGCYICDgIGBYICD4Ojw4ICBgWCAg+Hr8OCAgYRggIPg6/DggIGBYICD6ufw4ICBhGCAg4CBgmCAg4CBgWCAg4CBgGiAgxCSwQAIlYMwgf
        Ao9IEwmfCCMKnwCJWHMKnwiDDJ8IQwsfSAkYAAj30DwICRgACPd4CTgAAIlYS1j3eEvQiVhLWPffvPgJGwAI93gJOwAAiVgJGwAI99+c/Pk9+T
        kOD8AeRY/08kkYBXn0/8AYSRiCPJ8JDgiA+ZH/wB4lX/T6WRtJH8AexV/0/FkdSRYRENwJ+3+JSMkSCVgiOMk4iBKCMog5+/35HPkQiVYjBR9J
        +3+JQ8kYIvgJWDI4yT6IEuK+/Pj7f4lOyRLissk4+/6s8fk8+T35MoLzDg+QHoWf9PhJH5AeRY/0/UkfkB4Ff/T8SRzCOp8BYvgREOlMQB7C/w
        4O4P/x/sVf9PpZG0kY+3+JTskRERCMDQld4j3JOPv9+Rz5EfkQiV3iv4z/wBkY0ijYkvkOCAXJ9PghuRCY9zmScIlfwBkY2CjZgXMfCCjegP8R
        2FjZDgCJWP75/vCJX8AZGNgo2YF2Hwoo2uD78vsR1dloyRko2fX59zko+Q4AiVj++f7wiV/AFTjUSNJS8w4IQvkOCCG5MLVBcQ8M+WCJUBlwiV
        i+6T4IkrSfCA4JDgiSsp8A6U6wOBEQyUAAAIlfwBpI2oD7kvsR2jWr9PLJGEjZDgAZaPc5knhI+mibeJLJOgibGJjJGDcIBkjJOTjYSNmBMGwA
        KI84ngLYCBj32AgwiVz5Pfk+wBiI2II7nwqom7ieiJ+YmMkYX9A8CAgYb9DcAPtgf898+MkYX/8s+AgYX/7c/OAQ6UogLpz9+Rz5EIle+S/5IP
        kx+Tz5Pfk+wBgeCIj5uNjI2YExrA6In5iYCBhf8VwJ+3+JTuif+JYIPoifmJgIGDcIBkgIOfv4HgkODfkc+RH5EPkf+Q75AIlfYuC40Q4A9fH0
        8PcxEn4C6MjY4RDMAPtgf8+s/oifmJgIGF//XPzgEOlKIC8c/rjewP/S/xHeNa/0/wgp+3+JQLj+qJ+4mAgYBiz8/Pkt+S75L/kh+Tz5Pfk+wB
        agF7ARIv6In5iYLggIPBFIHu2AbhBPEEofBg4HngjeOQ4KcBlgEOlLcFIVAxCUEJUQlWlUeVN5UnlSEVgOE4B5jw6In5iRCCYOh06I7hkOCnAZ
        YBDpS3BSFQMQlBCVEJVpVHlTeVJ5Xshf2FMIPuhf+FIIMYjuyJ/YkQg+qJ+4mAgYBhgIPqifuJgIGIYICD6on7iYCBgGiAg+qJ+4mAgY99gIPf
        kc+RH5H/kO+Q35DPkAiVH5IPkg+2D5IRJC+Tj5Ofk++T/5PgkTcB8JE4AYCB4JE9AfCRPgGC/RvAkIGAkUABj1+PcyCRQQGCF0Hw4JFAAfDg6V
        3+T5WPgJNAAf+R75GfkY+RL5EPkA++D5AfkBiVgIH0zx+SD5IPtg+SESQvkz+TT5Nfk2+Tf5OPk5+Tr5O/k++T/5OH4pHgDpSiAv+R75G/ka+R
        n5GPkX+Rb5FfkU+RP5EvkQ+QD74PkB+QGJWH4pHgDpRXAiHgiSsJ9CDggi8Ilefi8eATghKCiO6T4KDgsOCEg5WDpoO3g4vgkeCRg4CDheyQ4J
        WHhIeE7JDgl4eGh4DskOCRi4CLgeyQ4JOLgouC7JDglYuEi4bskOCXi4aLEY4SjhOOFI4Ila+Sv5LPkt+S75L/kg+TH5PPk9+TbAF7AYsBBA8V
        H+sBXgGuGL8IwBfRB1nwaZHWAe2R/JEBkPCB4C3GAQmViSt598UB35HPkR+RD5H/kO+Q35DPkL+Qr5AIlfsBAZAAIOn3MZevAUYbVwvcAe2R/J
        ECgPOB4C0JlNwB7ZH8kQGQ8IHgLQmUaeFx4AyUTwSPkp+Sr5K/ku+S/5IPkx+Tz5Pfk8233rehlw+2+JTevw++zb98AfoBywEZoiIwCPQq4I4B
        D10fT4IukSyxLKEsvwGlAZQBDpS3BfkBygFqMAz1YF3YAW6TjQEjKyQrJSt595DggOAQlyHwvQHHAQ6UTwShlg+2+JTevw++zb/fkc+RH5EPkf
        +Q75C/kK+Qn5CPkAiVaVzez8+S35Lvkv+SD5Mfk8+T35MhFTEFgfTcAe2R/JEBkPCB4C1kL9+Rz5EfkQ+R/5DvkN+Qz5AJlCowMQUB9Srgd/8d
        wGoBewHsAW3iDpReBIwBRCdVJ7oBTBldCW4Jfwkq4M4BDpRpBIAPkR/fkc+RH5EPkf+Q75DfkM+QCJXfkc+RH5EPkf+Q75DfkM+QDJRpBJoBqw
        F3D2YLdwsMlLUED5Mfk8+T35PsAQ6U/QSMAc4BDpRlBIAPkR/fkc+RH5EPkQiVgTA58BjwgjBR8AiVEJJuAAiVgJFvAI1/gJNvAAiVgJFwAI1/
        gJNwAIHggJOwAICRsQCIf4RggJOxABCSswAIlc+TyC+AkQYByBMNwOjr8OCEkZ/vkJMGAQ6UFgVg4Iwvz5EMlCkCj+/3zx+SD5IPtg+SESQvkz
        +TT5Nfk2+Tf5OPk5+Tr5O/k++T/5OAkccBkJHIAaCRyQGwkcoBiSuKK4sr0fGQkcQB4JHFAfCRxgGAgYkngIOAkccBkJHIAaCRyQGwkcoBGBYZ
        BhoGGwac9ICRxwGQkcgBoJHJAbCRygEBl6EJsQmAk8cBkJPIAaCTyQGwk8oB/5Hvkb+Rr5GfkY+Rf5FvkV+RT5E/kS+RD5APvg+QH5AYlYCRBg
        EOlDYF6s8IlQ6UiQEOlKcFDpSSAMTp0uAOlKoAIJfh8w6UlAL5z6HiGi6qG7sb/QENwKofux/uH/8fohezB+QH9Qcg8KIbswvkC/ULZh93H4gf
        mR8alGn3YJVwlYCVkJWbAawBvQHPAQiV7g//HwWQ9JHgLQmU+JT/z///0ADQAP8AAAAA5AIiBIUCxAJXAnECYwINCgA=
        """
}

/*
 The sketches, as compiled:

// blink.ino
void setup() {
  pinMode(13, OUTPUT);
}

void loop() {
  digitalWrite(13, HIGH);
  delay(100);
  digitalWrite(13, LOW);
  delay(100);
}

// kitchen.ino
#include <avr/pgmspace.h>
const char message[] PROGMEM = "flash string";
volatile uint8_t ticks = 0;
typedef long (*Operation)(long, long);
long add(long a, long b) { return a + b; }
long mul(long a, long b) { return a * b; }
long dv(long a, long b) { return b ? a / b : 0; }
Operation operations[] = {add, mul, dv};

unsigned long fib(unsigned char n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

int classify(int v) {
  switch (v % 7) {
    case 0: return 10; case 1: return 21; case 2: return 33; case 3: return 47;
    case 4: return 52; case 5: return 68; default: return 99;
  }
}

void setup() {
  Serial.begin(115200);
  pinMode(13, OUTPUT);
  analogWrite(9, 77);
  analogWrite(5, 200);
  analogWrite(11, 31);
  char buffer[20];
  strcpy_P(buffer, message);
  Serial.println(buffer);
  long x = 123456789L;
  for (int i = 0; i < 3; i++) Serial.println(operations[i](x, 1234));
  Serial.println(fib(15));
  float f = 3.14159f;
  Serial.println(sin(f / 3), 5);
  Serial.println(sqrt(2.0), 6);
  Serial.println(pow(1.5, 7.25), 4);
  Serial.println(f * 1e6, 2);
  Serial.println(-12345.678f / 7.0f, 3);
  int sum = 0;
  for (int i = -50; i < 50; i++) sum += classify(i) * (i & 3) - (i >> 2);
  Serial.println(sum);
  uint32_t h = 2166136261UL;
  for (uint8_t i = 0; i < 200; i++) { h ^= i; h *= 16777619UL; }
  Serial.println(h, HEX);
  int16_t s16 = -30000; s16 = s16 / 7 + (s16 % 13);
  Serial.println(s16);
  uint8_t bits = 0xA5; bits = (bits << 3) | (bits >> 5);
  Serial.println(bits, BIN);
  Serial.println(analogRead(A0));
  Serial.println(analogRead(A3));
  Serial.println(millis());
}

void loop() {
  digitalWrite(13, !digitalRead(13));
  Serial.println(micros());
  delay(3);
}

// pwm.ino
void setup() {
  analogWrite(9, 77);
  analogWrite(5, 200);
  analogWrite(11, 31);
  analogWrite(3, 128);
  analogWrite(6, 10);
  analogWrite(10, 250);
  tone(8, 440);
}
void loop() {}

// interrupt.ino
volatile int presses = 0;
void count() { presses++; }
void setup() {
  pinMode(2, INPUT_PULLUP);
  pinMode(13, OUTPUT);
  attachInterrupt(digitalPinToInterrupt(2), count, FALLING);
  Serial.begin(9600);
}
void loop() {
  digitalWrite(13, presses & 1);
  static int last = -1;
  if (presses != last) { last = presses; Serial.println(presses); }
}

*/
