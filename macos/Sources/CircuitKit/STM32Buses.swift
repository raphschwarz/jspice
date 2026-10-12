import CortexM4
import Foundation

/// How a converter wired to an STM32 is reached, as the firmware has set the chip up: each of its terminals must be on
/// a pin carrying the matching signal of one port (by the pin's alternate function, ST's pin data), and that port
/// must run in a mode the part's datasheet allows. What does not hold is said, so that a board whose wiring or
/// firmware would not work does not seem to.
enum STM32BusLink: Equatable {
    /// Frames on an I²S port
    case i2s(port: Int)
    /// Words on an SPI port, each begun when the chip's pin `sync` falls (-1: none wired)
    case spi(port: Int, sync: Int)
    /// A codec's control port on an I²C bus
    case i2c(bus: Int)
}

struct STM32BusCheck {
    let chip: STM32Microcontroller
    let pinNames: [String]

    /// What a pin carries now, and its port
    func signal(_ pin: Int) -> (STM32Signal, Int) {
        var instance: Int32 = 0
        let signal = stm32_pin_signal(chip.chip, Int32(pin), &instance)
        return (signal, Int(instance))
    }

    func name(_ pin: Int) -> String { pin >= 0 && pin < pinNames.count ? pinNames[pin].uppercased() : "pin \(pin)" }

    /// "SPI2's SCK", "a GPIO output"
    func describe(_ pin: Int) -> String {
        let (signal, port) = self.signal(pin)
        switch signal {
        case STM32_SIGNAL_INPUT: return "a GPIO input"
        case STM32_SIGNAL_OUTPUT: return "a GPIO output"
        case STM32_SIGNAL_ANALOG: return "an analog input"
        case STM32_SIGNAL_SPI_SCK: return "SPI\(port)'s SCK"
        case STM32_SIGNAL_SPI_MISO: return "SPI\(port)'s MISO"
        case STM32_SIGNAL_SPI_MOSI: return "SPI\(port)'s MOSI"
        case STM32_SIGNAL_SPI_NSS: return "SPI\(port)'s NSS"
        case STM32_SIGNAL_I2S_CK: return "I2S\(port)'s CK"
        case STM32_SIGNAL_I2S_SD: return "I2S\(port)'s SD"
        case STM32_SIGNAL_I2S_WS: return "I2S\(port)'s WS"
        case STM32_SIGNAL_I2S_MCK: return "I2S\(port)'s MCK"
        case STM32_SIGNAL_I2S_EXTSD: return "I2S\(port)'s full-duplex SD (I2S\(port)ext)"
        case STM32_SIGNAL_I2C_SCL: return "I2C\(port)'s SCL"
        case STM32_SIGNAL_I2C_SDA: return "I2C\(port)'s SDA"
        case STM32_SIGNAL_USART_TX: return "USART\(port)'s TX"
        case STM32_SIGNAL_USART_RX: return "USART\(port)'s RX"
        default: return "another alternate function (a timer's, say)"
        }
    }

    func config(_ port: Int) -> STM32SPIConfig {
        var config = STM32SPIConfig()
        _ = stm32_spi_config(chip.chip, Int32(port), &config)
        return config
    }

    /// The part's links, or why it has none (`issue`); `pins` holds, for each of its terminals, the chip's pin on the
    /// same node (-1: none)
    func resolve(part: ElementKind, name: String, model: String, format: Int, pins: [Int]) -> (links: [STM32BusLink], issue: String?) {
        func pin(_ terminal: Int) -> Int { terminal < pins.count ? pins[terminal] : -1 }
        let who = "\(name) (\(model))"
        /// The port whose `want` signal the clock terminal's pin carries, or why not
        func clockPort(_ terminal: Int, label: String, want: STM32Signal, bus: String) -> (Int?, String?) {
            let p = pin(terminal)
            guard p >= 0 else { return (nil, nil) }  // not wired to this chip
            let (signal, port) = self.signal(p)
            guard signal == want else {
                return (nil, "\(who): its \(label) is on \(self.name(p)), which the firmware has as \(describe(p)), not as \(bus)'s clock. No data reaches it.")
            }
            return (port, nil)
        }
        func expect(_ terminal: Int, label: String, _ want: STM32Signal, _ port: Int, as role: String) -> String? {
            let p = pin(terminal)
            guard p >= 0 else { return "\(who): its \(label) is not wired to the chip; \(role) has to reach it." }
            let (signal, at) = self.signal(p)
            guard signal == want && at == port else {
                return "\(who): its \(label) is on \(self.name(p)), which the firmware has as \(describe(p)), not as \(role)."
            }
            return nil
        }
        switch part {
        case .i2sDac, .codec, .cvDac where format < 2:
            let codec = part == .codec
            // a codec's control port, on whichever I²C bus its SCLK and SDIN are: set up apart from its audio (a
            // firmware writes the codec's registers before it starts its frames)
            var control: [STM32BusLink] = []
            var controlIssue: String?
            if codec && pin(6) >= 0 {
                let (scl, bus) = self.signal(pin(6))
                if chip.model == STM32_F373 {
                    controlIssue = "\(who): the model does not run the STM32F373's I²C, so its control port cannot be reached."
                } else if scl != STM32_SIGNAL_I2C_SCL {
                    controlIssue = "\(who): its SCLK is on \(self.name(pin(6))), which the firmware has as \(describe(pin(6))), not as an I²C bus's SCL."
                } else if let issue = expect(7, label: "SDIN", STM32_SIGNAL_I2C_SDA, bus, as: "I2C\(bus)'s SDA") {
                    controlIssue = issue
                } else {
                    control = [.i2c(bus: bus)]
                }
            }
            func audio() -> (STM32BusLink?, String?) {
                let clock = codec ? 1 : 0, data = codec ? 2 : 1, frame = codec ? 3 : 2
                let (found, issue) = clockPort(clock, label: codec ? "BCLK" : part == .cvDac ? "SCLK" : "BCK",
                                          want: STM32_SIGNAL_I2S_CK, bus: "an I2S port")
                guard let port = found else { return (nil, issue) }
                let i2s = "I2S\(port)"
                if let issue = expect(data, label: codec ? "DACDAT" : "DIN", STM32_SIGNAL_I2S_SD, port, as: "\(i2s)'s SD")
                    ?? expect(frame, label: codec ? "DACLRC" : part == .cvDac ? "SYNC" : "LRCK", STM32_SIGNAL_I2S_WS, port, as: "\(i2s)'s WS") {
                    return (nil, issue)
                }
                let settings = config(port)
                if !settings.transmitting {
                    return (nil, "\(who): \(i2s) is set to receive; nothing is sent to it.")
                }
                if part == .i2sDac && settings.i2s_standard >= 2 {
                    return (nil, "\(who): \(i2s) sends \(settings.i2s_standard == 3 ? "PCM" : "LSB-justified") frames; the \(model) takes I²S or left-justified ones (its FMT pin).")
                }
                if codec {
                    if pin(4) >= 0, let issue = expect(4, label: "ADCDAT", STM32_SIGNAL_I2S_EXTSD, port, as: "\(i2s)'s full-duplex SD (I2S\(port)ext)") {
                        return (nil, issue)
                    }
                    if let issue = expect(0, label: "MCLK", STM32_SIGNAL_I2S_MCK, port, as: "\(i2s)'s MCK (the WM8731 runs from its master clock)") {
                        return (nil, issue)
                    }
                }
                return (.i2s(port: port), nil)
            }
            let (link, issue) = audio()
            return ((link.map { [$0] } ?? []) + control, issue ?? controlIssue)
        case .cvDac, .spiAdc:
            let adc = part == .spiAdc
            let (found, issue) = clockPort(adc ? 1 : 0, label: adc ? "CLK" : "SCLK", want: STM32_SIGNAL_SPI_SCK, bus: "an SPI port")
            guard let port = found else { return ([], issue) }
            let spi = "SPI\(port)"
            if let issue = expect(adc ? 2 : 1, label: "DIN", STM32_SIGNAL_SPI_MOSI, port, as: "\(spi)'s MOSI") { return ([], issue) }
            if adc, let issue = expect(3, label: "DOUT", STM32_SIGNAL_SPI_MISO, port, as: "\(spi)'s MISO") { return ([], issue) }
            let sync = pin(adc ? 0 : 2)
            let label = adc ? "CS" : "SYNC"
            if sync >= 0 {
                let (signal, _) = self.signal(sync)
                if signal != STM32_SIGNAL_OUTPUT && signal != STM32_SIGNAL_SPI_NSS {
                    return ([], "\(who): its \(label) is on \(self.name(sync)), which the firmware has as \(describe(sync)): nothing frames its words.")
                }
            } else if adc {
                return ([], "\(who): its CS is not wired to the chip; it starts a conversion only when CS falls.")
            }
            let settings = config(port)
            if !settings.master {
                return ([], "\(who): \(spi) is a slave; the \(model) needs the chip to clock it.")
            }
            if settings.lsb_first {
                return ([], "\(who): \(spi) sends LSB first; the \(model) takes its words MSB first.")
            }
            // the edge the part takes its data on: the ADCs on SCLK's rising edge (modes 0 and 3), the DACs on its
            // falling edge (modes 1 and 2)
            let mode = Int(settings.cpol) * 2 + Int(settings.cpha)
            let fallingEdge = mode == 1 || mode == 2
            if adc == fallingEdge {
                return ([], "\(who): \(spi) runs in SPI mode \(mode) (CPOL \(settings.cpol), CPHA \(settings.cpha)), shifting data so that the \(model) reads it on the wrong edge; it takes data on SCLK's \(adc ? "rising edge (mode 0 or 3)" : "falling edge (mode 1 or 2)").")
            }
            return ([.spi(port: port, sync: sync)], nil)
        default:
            return ([], nil)
        }
    }
}
