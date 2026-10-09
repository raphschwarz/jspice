import Foundation

extension AVRVariant {
    /// The SPI: SPCR, then SPSR and SPDR; its pins
    struct SPI: Sendable {
        let control: Int
        let vector: Int
        let sck: Int
        let mosi: Int
        let miso: Int
        let ss: Int
        var status: Int { control + 1 }
        var dataRegister: Int { control + 2 }
    }

    /// The two-wire interface (I²C): TWBR, then TWSR, TWAR, TWDR, TWCR; its pins
    struct TWI: Sendable {
        let rate: Int
        let vector: Int
        let sda: Int
        let scl: Int
        var status: Int { rate + 1 }
        var dataRegister: Int { rate + 3 }
        var control: Int { rate + 4 }
    }
}

/// The SPI as a master: a byte written to SPDR goes out on MOSI, a bit per SCK clock at the rate SPCR and SPSR set,
/// while MISO is sampled in; SPIF is set when the eighth bit is in. (As a slave it does nothing: nothing in a circuit
/// clocks it.)
final class AVRSPI {
    let spec: AVRVariant.SPI
    unowned(unsafe) let avr: AVR
    /// The clock and data out, while the SPI drives them
    private(set) var sck = false
    private(set) var mosi = false
    private var outgoing: UInt8 = 0
    private var incoming: UInt8 = 0
    private var received: UInt8 = 0
    /// Half clock periods done in the present transfer (16 in all); -1 when idle
    private var half = -1
    private var halfPeriod = 2
    private(set) var nextEvent = Int.max
    /// SPIF is cleared by reading SPSR while it is set, then accessing SPDR
    private var statusSeen = false

    init(spec: AVRVariant.SPI, avr: AVR) {
        self.spec = spec
        self.avr = avr
    }

    private var control: UInt8 { avr.data[spec.control] }
    var enabled: Bool { control & 0x40 != 0 }
    var master: Bool { control & 0x50 == 0x50 }
    private var lsbFirst: Bool { control & 0x20 != 0 }
    private var polarity: Bool { control & 0x08 != 0 }
    private var phase: Bool { control & 0x04 != 0 }

    func reset() {
        sck = false
        mosi = false
        half = -1
        nextEvent = Int.max
        received = 0
        statusSeen = false
    }

    func adopt(_ other: AVRSPI) {
        sck = other.sck
        mosi = other.mosi
        outgoing = other.outgoing
        incoming = other.incoming
        received = other.received
        half = other.half
        halfPeriod = other.halfPeriod
        nextEvent = other.nextEvent
        statusSeen = other.statusSeen
    }

    func writeControl(_ value: UInt8) {
        avr.data[spec.control] = value
        if !enabled || !master {
            half = -1
            nextEvent = Int.max
        }
        if half < 0 { sck = polarity }
        avr.interruptsChanged = true
    }

    func readStatus() -> UInt8 {
        let value = avr.data[spec.status]
        if value & 0x80 != 0 { statusSeen = true }
        return value
    }

    func writeStatus(_ value: UInt8) {
        // only SPI2X can be written
        avr.data[spec.status] = avr.data[spec.status] & 0xFE | value & 0x01
    }

    private func clearFlagIfSeen() {
        if statusSeen {
            avr.data[spec.status] &= ~0xC0
            statusSeen = false
            avr.interruptsChanged = true
        }
    }

    func readData() -> UInt8 {
        clearFlagIfSeen()
        return received
    }

    func writeData(_ value: UInt8) {
        clearFlagIfSeen()
        guard half < 0 else {
            avr.data[spec.status] |= 0x40  // WCOL
            return
        }
        guard enabled && master else { return }
        let rate = [4, 16, 64, 128][Int(control & 3)] / (avr.data[spec.status] & 1 != 0 ? 2 : 1)
        halfPeriod = rate / 2
        outgoing = value
        incoming = 0
        sck = polarity
        // without clock phase, the first bit is out before the first edge
        if !phase { mosi = nextBit() }
        half = 0
        nextEvent = avr.cycles + halfPeriod
    }

    private func nextBit() -> Bool {
        let bit: Bool
        if lsbFirst {
            bit = outgoing & 1 != 0
            outgoing >>= 1
        } else {
            bit = outgoing & 0x80 != 0
            outgoing <<= 1
        }
        return bit
    }

    private func sample() {
        let bit: UInt8 = avr.pinLevel(spec.miso) ? 1 : 0
        if lsbFirst {
            incoming = incoming >> 1 | bit << 7
        } else {
            incoming = incoming << 1 | bit
        }
    }

    /// The next half clock period's edge
    func advance() {
        half += 1
        let leading = half % 2 == 1
        sck = leading ? !polarity : polarity
        // clock phase 0: sample on the leading edge, shift on the trailing one; phase 1 the other way round
        if leading == !phase {
            sample()
        } else if half < 16 {
            mosi = nextBit()
        }
        if half == 16 {
            received = incoming
            half = -1
            nextEvent = Int.max
            avr.data[spec.status] |= 0x80
            avr.interruptsChanged = true
        } else {
            nextEvent += halfPeriod
        }
    }
}

/// The two-wire interface as a bus master: START, a byte out (an address or data) or in, with the acknowledge bit,
/// and STOP, bit by bit on SDA and SCL at the rate TWBR and the prescaler set, with the status codes of the datasheet.
/// SDA and SCL are open drain: pulled low, or let go to whatever pulls them up. Nothing answers on its own: an address
/// is acknowledged only if something in the circuit holds SDA low. (Slave mode does nothing.)
final class AVRTWI {
    let spec: AVRVariant.TWI
    unowned(unsafe) let avr: AVR
    /// Whether the TWI pulls each line low
    private(set) var sdaLow = false
    private(set) var sclLow = false

    private enum Step {
        case lines(sda: Bool?, scl: Bool?)  // true: pulled low
        case wait
        case sampleBit
        case done(status: UInt8, setsFlag: Bool)
    }
    private var steps: [Step] = []
    private var stepIndex = 0
    private(set) var nextEvent = Int.max
    private var shift: UInt8 = 0
    private var acknowledged = false
    /// After an address with the read bit, bytes come in rather than go out
    private var reading = false
    /// The next byte written is an address (after a START)
    private var addressNext = false
    /// A START has been sent and no STOP since
    private var busOwned = false

    init(spec: AVRVariant.TWI, avr: AVR) {
        self.spec = spec
        self.avr = avr
    }

    var enabled: Bool { avr.data[spec.control] & 0x04 != 0 }

    func reset() {
        sdaLow = false
        sclLow = false
        steps = []
        stepIndex = 0
        nextEvent = Int.max
        reading = false
        addressNext = false
        busOwned = false
        avr.data[spec.status] = 0xF8
        avr.data[spec.rate + 2] = 0xFE  // TWAR
        avr.data[spec.dataRegister] = 0xFF
    }

    func adopt(_ other: AVRTWI) {
        sdaLow = other.sdaLow
        sclLow = other.sclLow
        steps = other.steps
        stepIndex = other.stepIndex
        nextEvent = other.nextEvent
        shift = other.shift
        acknowledged = other.acknowledged
        reading = other.reading
        addressNext = other.addressNext
        busOwned = other.busOwned
    }

    private var halfPeriod: Int {
        let d = avr.data
        let prescale = [1, 4, 16, 64][Int(d[spec.status] & 3)]
        return max((16 + 2 * Int(d[spec.rate]) * prescale) / 2, 1)
    }

    func readStatus() -> UInt8 { avr.data[spec.status] }

    func writeStatus(_ value: UInt8) {
        avr.data[spec.status] = avr.data[spec.status] & 0xF8 | value & 0x03
    }

    func writeData(_ value: UInt8) {
        // TWDR can only be written while TWINT is set
        if avr.data[spec.control] & 0x80 != 0 {
            avr.data[spec.dataRegister] = value
        } else {
            avr.data[spec.control] |= 0x08  // TWWC
        }
    }

    func writeControl(_ value: UInt8) {
        let d = avr.data
        let clearing = value & 0x80 != 0
        // writing 1 to TWINT clears it; TWWC is read only
        var stored = value & 0x77 | d[spec.control] & 0x80
        if clearing { stored &= ~0x80 }
        d[spec.control] = stored & ~0x08 | d[spec.control] & 0x08
        avr.interruptsChanged = true
        guard value & 0x04 != 0 else {
            // disabled: the TWI lets go of the lines
            steps = []
            nextEvent = Int.max
            sdaLow = false
            sclLow = false
            busOwned = false
            return
        }
        guard clearing, steps.isEmpty else { return }
        let start = value & 0x20 != 0
        let stop = value & 0x10 != 0
        if stop { sendStop() }
        if start {
            sendStart()
        } else if !stop {
            if reading && !addressNext { receiveByte(acknowledge: value & 0x40 != 0) } else { sendByte() }
        }
        if !steps.isEmpty {
            stepIndex = 0
            nextEvent = avr.cycles
            advance()
        }
    }

    private func sendStart() {
        let repeated = busOwned
        if repeated {
            // let SDA go while SCL is low, raise SCL, then START
            steps += [.lines(sda: false, scl: nil), .wait, .lines(sda: nil, scl: false), .wait]
        }
        steps += [.lines(sda: true, scl: nil), .wait, .lines(sda: nil, scl: true), .wait,
                  .done(status: repeated ? 0x10 : 0x08, setsFlag: true)]
        addressNext = true
        busOwned = true
    }

    private func sendStop() {
        steps += [.lines(sda: true, scl: nil), .wait, .lines(sda: nil, scl: false), .wait, .lines(sda: false, scl: nil), .wait,
                  .done(status: 0xF8, setsFlag: false)]
        busOwned = false
        reading = false
    }

    private func sendByte() {
        let value = avr.data[spec.dataRegister]
        for bit in (0..<8).reversed() {
            let low = value & (1 << bit) == 0
            steps += [.lines(sda: low, scl: nil), .wait, .lines(sda: nil, scl: false), .wait, .lines(sda: nil, scl: true)]
        }
        // the ninth clock: SDA let go, sampled for the acknowledge
        steps += [.lines(sda: false, scl: nil), .wait, .lines(sda: nil, scl: false), .wait, .sampleBit, .lines(sda: nil, scl: true)]
        let status: UInt8
        if addressNext {
            reading = value & 1 != 0
            status = reading ? 0x40 : 0x18
        } else {
            status = 0x28
        }
        addressNext = false
        // the status for "not acknowledged" is 8 more
        steps.append(.done(status: status, setsFlag: true))
    }

    private func receiveByte(acknowledge: Bool) {
        shift = 0
        for _ in 0..<8 {
            steps += [.lines(sda: false, scl: nil), .wait, .lines(sda: nil, scl: false), .wait, .sampleBit, .lines(sda: nil, scl: true)]
        }
        steps += [.lines(sda: acknowledge, scl: nil), .wait, .lines(sda: nil, scl: false), .wait, .lines(sda: nil, scl: true)]
        steps.append(.done(status: acknowledge ? 0x50 : 0x58, setsFlag: true))
    }

    /// Runs the steps due now
    func advance() {
        while stepIndex < steps.count {
            switch steps[stepIndex] {
            case let .lines(sda, scl):
                if let sda { sdaLow = sda }
                if let scl { sclLow = scl }
                // SDA moving as SCL falls: the parts on the bus see SCL low first, not a START or STOP
                if stepIndex + 1 < steps.count, case .lines = steps[stepIndex + 1] { avr.twiLinesMoved(at: nextEvent) }
            case .wait:
                stepIndex += 1
                nextEvent = avr.cycles + halfPeriod
                return
            case .sampleBit:
                let high = avr.pinLevel(spec.sda) && !sdaLow
                shift = shift << 1 | (high ? 1 : 0)
                acknowledged = !high
            case let .done(status, setsFlag):
                var code = status
                // a byte sent: the acknowledge decides the status; a byte received: it goes to TWDR
                if [0x18, 0x40, 0x28].contains(status) && !acknowledged { code += 8 }
                if status == 0x50 || status == 0x58 { avr.data[spec.dataRegister] = shift }
                avr.data[spec.status] = code | avr.data[spec.status] & 0x03
                if setsFlag { avr.data[spec.control] |= 0x80 }
                if status == 0xF8 { avr.data[spec.control] &= ~0x10 }  // TWSTO clears when the STOP is out
                if code == 0x20 || code == 0x48 { reading = false }
                avr.interruptsChanged = true
            }
            stepIndex += 1
        }
        steps = []
        stepIndex = 0
        nextEvent = Int.max
    }
}
