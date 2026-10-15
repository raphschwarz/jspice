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
    /// An I²C target (an MCP4725) answering on a bus
    case i2cDevice(bus: Int)
    /// A part shifting its output onto an SPI port's MISO on SCK's edges (a 74HC165): the port reads the pin
    case misoFromPin(port: Int)
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
            // (a codec set up by its pins alone, address 0, has none)
            if codec && format != 0 && pin(6) >= 0 {
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
                    if let issue = expect(0, label: "MCLK", STM32_SIGNAL_I2S_MCK, port, as: "\(i2s)'s MCK (the \(model) runs from its master clock)") {
                        return (nil, issue)
                    }
                }
                return (.i2s(port: port), nil)
            }
            let (link, issue) = audio()
            return ((link.map { [$0] } ?? []) + control, issue ?? controlIssue)
        case .spiAdc where pin(1) >= 0 && self.signal(pin(1)).0 == STM32_SIGNAL_OUTPUT:
            // (clocked by the firmware's own GPIO writes: it follows the pins bit by bit)
            return ([], nil)
        case .dac, .dualDac, .shiftRegister:
            // parts that take their bits from the pins edge by edge (an MCP4921 or MCP4822: CS, SCK, SDI, LDAC; a
            // 74HC595: SER, SRCLK, RCLK), on SCK's rising edge: clocked by the firmware's GPIO writes, or by an SPI
            // port, whose frames reach the pins edge by edge, in a mode that has the data steady on the rising edge
            let shift = part == .shiftRegister
            let (clock, data) = shift ? (1, 0) : (1, 2)
            let clockLabel = shift ? "SRCLK" : "SCK", dataLabel = shift ? "SER" : "SDI"
            let c = pin(clock)
            guard c >= 0 else { return ([], nil) }
            let (signal, port) = self.signal(c)
            // its latch (CS or RCLK) and LDAC: the firmware's to drive (a CD4015 has none)
            let latches = shift ? (model.hasPrefix("CD4015") ? [] : [(2, "RCLK")]) : [(0, "CS"), (3, "LDAC")]
            for (terminal, label) in latches where pin(terminal) >= 0 {
                let (latch, _) = self.signal(pin(terminal))
                if latch != STM32_SIGNAL_OUTPUT && latch != STM32_SIGNAL_SPI_NSS {
                    return ([], "\(who): its \(label) is on \(self.name(pin(terminal))), which the firmware has as \(describe(pin(terminal))), not as a pin it drives.")
                }
            }
            if signal == STM32_SIGNAL_OUTPUT { return ([], nil) }
            guard signal == STM32_SIGNAL_SPI_SCK else {
                return ([], "\(who): its \(clockLabel) is on \(self.name(c)), which the firmware has as \(describe(c)), neither an SPI port's SCK nor a GPIO output: nothing clocks it.")
            }
            let spi = "SPI\(port)"
            if let issue = expect(data, label: dataLabel, STM32_SIGNAL_SPI_MOSI, port, as: "\(spi)'s MOSI") { return ([], issue) }
            let settings = config(port)
            let mode = Int(settings.cpol) * 2 + Int(settings.cpha)
            if mode == 1 || mode == 2 {
                return ([], "\(who): \(spi) runs in SPI mode \(mode) (CPOL \(settings.cpol), CPHA \(settings.cpha)), changing its data on SCK's rising edge, where the \(model) takes it: mode 0 or 3 has it steady there.")
            }
            if !shift && settings.lsb_first {
                return ([], "\(who): \(spi) sends LSB first; the \(model) takes its words MSB first.")
            }
            return ([], nil)
        case .shiftIn:
            // a 74HC165: SH/LD, CLK, CLK INH, SER, D0-D7, QH. Its loads and its clock inhibit are the firmware's to
            // drive; its clock an SPI port's SCK, with QH on that port's MISO, read in mode 0 or 3 (QH read before each
            // rising edge shifts the next stage onto it), or a GPIO output, the firmware reading QH itself
            for (terminal, label) in [(0, "SH/LD"), (2, "CLK INH")] where pin(terminal) >= 0 {
                let (load, _) = self.signal(pin(terminal))
                if load != STM32_SIGNAL_OUTPUT {
                    return ([], "\(who): its \(label) is on \(self.name(pin(terminal))), which the firmware has as \(describe(pin(terminal))), not as a pin it drives.")
                }
            }
            let c = pin(1)
            guard c >= 0 else { return ([], nil) }
            let (clock, port) = self.signal(c)
            if clock == STM32_SIGNAL_OUTPUT { return ([], nil) }
            guard clock == STM32_SIGNAL_SPI_SCK else {
                return ([], "\(who): its CLK is on \(self.name(c)), which the firmware has as \(describe(c)), neither an SPI port's SCK nor a GPIO output: nothing clocks it.")
            }
            let spi = "SPI\(port)"
            guard pin(12) >= 0 else { return ([], nil) }
            if let issue = expect(12, label: "QH", STM32_SIGNAL_SPI_MISO, port, as: "\(spi)'s MISO") { return ([], issue) }
            let settings = config(port)
            let mode = Int(settings.cpol) * 2 + Int(settings.cpha)
            if mode == 1 || mode == 2 {
                return ([], "\(who): \(spi) runs in SPI mode \(mode) (CPOL \(settings.cpol), CPHA \(settings.cpha)), reading MISO on SCK's falling edge, after the \(model) has shifted on the rising one: it would miss D7. Mode 0 or 3 reads QH before each shift.")
            }
            return ([.misoFromPin(port: port)], nil)
        case .i2cDac, .ledDriver:
            // an MCP4725 or a PCA9685: SCL and SDA on one of the chip's I²C buses (or GPIO pins, the firmware
            // bit-banging them)
            guard pin(0) >= 0 else { return ([], nil) }
            let (scl, bus) = self.signal(pin(0))
            if scl == STM32_SIGNAL_OUTPUT { return ([], nil) }
            if chip.model == STM32_F373 {
                return ([], "\(who): the model does not run the STM32F373's I²C, so the \(model) cannot be reached.")
            }
            guard scl == STM32_SIGNAL_I2C_SCL else {
                return ([], "\(who): its SCL is on \(self.name(pin(0))), which the firmware has as \(describe(pin(0))), not as an I²C bus's SCL.")
            }
            if let issue = expect(1, label: "SDA", STM32_SIGNAL_I2C_SDA, bus, as: "I2C\(bus)'s SDA") { return ([], issue) }
            return ([.i2cDevice(bus: bus)], nil)
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
