import Foundation

/// The USB controller in device mode (rp2040js's RPUSBController without its host mode): the firmware's endpoint
/// buffers in DPRAM are handed to the host, `RPUSBCDC`, after a delay
final class RPUSBController: RPPeripheral {
    private static let endpointCount = 16
    private static let ep1InControl = 0x8, ep0InBufferControl = 0x80, ep0OutBufferControl = 0x84
    private static let ep15OutBufferControl = 0xFC
    private static let ctrlDoubleBuffer: UInt32 = 1 << 30, ctrlInterruptPerTransfer: UInt32 = 1 << 29
    private static let bufAvailable: UInt32 = 1 << 10, bufFull: UInt32 = 1 << 15, bufLengthMask: UInt32 = 0x3FF
    private static let buf1Shift: UInt32 = 16, buf1Offset = 64
    private static let simTiming: UInt32 = 1 << 31, hostNDevice: UInt32 = 1 << 1, controllerEnable: UInt32 = 1
    private static let sieDataSeqError: UInt32 = 1 << 31, sieAckRec: UInt32 = 1 << 30, sieStallRec: UInt32 = 1 << 29
    private static let sieNakRec: UInt32 = 1 << 28, sieRxTimeout: UInt32 = 1 << 27, sieRxOverflow: UInt32 = 1 << 26
    private static let sieBitStuffError: UInt32 = 1 << 25, sieCRCError: UInt32 = 1 << 24, sieBusReset: UInt32 = 1 << 19
    private static let sieTransComplete: UInt32 = 1 << 18, sieSetupRec: UInt32 = 1 << 17, sieConnected: UInt32 = 1 << 16
    private static let sieResume: UInt32 = 1 << 11, sieSuspended: UInt32 = 1 << 4, sieVBusDetected: UInt32 = 1
    private static let sieWriteClearMask: UInt32 = sieDataSeqError | sieAckRec | sieStallRec | sieNakRec | sieRxTimeout
        | sieRxOverflow | sieBitStuffError | sieConnected | sieCRCError | sieBusReset | sieTransComplete | sieSetupRec
        | sieResume
    private static let intrBuffStatus: UInt32 = 1 << 4
    /// Device mode: each SIE_STATUS bit and the interrupt it raises
    private static let deviceInterrupts: [(UInt32, UInt32)] = [
        (sieSetupRec, 1 << 16), (sieResume, 1 << 15), (sieSuspended, 1 << 14), (sieConnected, 1 << 13),
        (sieBusReset, 1 << 12), (sieVBusDetected, 1 << 11), (sieStallRec, 1 << 10), (sieCRCError, 1 << 9),
        (sieBitStuffError, 1 << 8), (sieRxOverflow, 1 << 7), (sieRxTimeout, 1 << 6), (sieDataSeqError, 1 << 5),
    ]

    private final class EndpointAlarm {
        var alarm: RPAlarm!
        var buffers: [[UInt8]] = []

        func schedule(_ buffer: [UInt8], _ delayNanos: Double) {
            buffers.append(buffer)
            alarm.schedule(delayNanos)
        }
    }

    private var addrEndp: UInt32 = 0
    private var mainCtrl: UInt32 = 0
    private var intRaw: UInt32 = 0
    private var intEnable: UInt32 = 0
    private var intForce: UInt32 = 0
    private var sieStatus: UInt32 = 0
    private var buffStatus: UInt32 = 0
    private var sieCtrl: UInt32 = 0
    private var sofFrameNumber: UInt32 = 0
    private var devAddrCtrl: UInt32 = 0
    private var intEpAddrCtrl = [UInt32](repeating: 0, count: 15)
    private var intEpCtrl: UInt32 = 0
    private var usbPwr: UInt32 = 0
    private var nakPoll: UInt32 = 0
    private var epAbort: UInt32 = 0
    private var epAbortDone: UInt32 = 0
    private var epStallArm: UInt32 = 0
    private var epStatusStallNak: UInt32 = 0
    private var hostMode = false
    private var readAlarms: [EndpointAlarm] = []
    private var writeAlarms: [EndpointAlarm] = []
    private var resetAlarm: RPAlarm!

    var onUSBEnabled: (() -> Void)?
    var onResetReceived: (() -> Void)?
    var onEndpointWrite: ((Int, [UInt8]) -> Void)?
    var onEndpointRead: ((Int, Int) -> Void)?
    let readDelayMicroseconds: Double = 10
    let writeDelayMicroseconds: Double = 10

    override init(chip: RP2040, name: String) {
        super.init(chip: chip, name: name)
        for endpoint in 0..<RPUSBController.endpointCount {
            let read = EndpointAlarm()
            read.alarm = chip.clock.createAlarm { [unowned self, unowned read] in
                if !read.buffers.isEmpty { self.finishRead(endpoint, read.buffers.removeFirst()) }
            }
            readAlarms.append(read)
            let write = EndpointAlarm()
            write.alarm = chip.clock.createAlarm { [unowned self, unowned write] in
                let buffers = write.buffers
                write.buffers = []
                for buffer in buffers { self.onEndpointWrite?(endpoint, buffer) }
            }
            writeAlarms.append(write)
        }
        resetAlarm = chip.clock.createAlarm { [unowned self] in
            self.sieStatus |= RPUSBController.sieBusReset
            self.sieStatusUpdated()
        }
    }

    private var intStatus: UInt32 { (intRaw & intEnable) | intForce }

    override func readUint32(_ offset: UInt32) -> UInt32 {
        if offset >= 0x04 && offset <= 0x3C && offset & 3 == 0 { return intEpAddrCtrl[Int(offset - 0x04) >> 2] }
        switch offset {
        case 0x00: return hostMode ? devAddrCtrl : addrEndp & 0b1111000000001111111
        case 0x40: return mainCtrl
        case 0x44: return 0
        case 0x48: return sofFrameNumber & 0x7FF
        case 0x4C: return sieCtrl
        case 0x50: return sieStatus
        case 0x54: return intEpCtrl
        case 0x58: return buffStatus
        case 0x5C: return 0
        case 0x60: return epAbort
        case 0x64: return epAbortDone
        case 0x68: return epStallArm
        case 0x6C: return nakPoll
        case 0x70: return epStatusStallNak
        case 0x78: return usbPwr
        case 0x8C: return intRaw
        case 0x90: return intEnable
        case 0x94: return intForce
        case 0x98: return intStatus
        default: return super.readUint32(offset)
        }
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        if offset >= 0x04 && offset <= 0x3C && offset & 3 == 0 {
            intEpAddrCtrl[Int(offset - 0x04) >> 2] = value
            return
        }
        switch offset {
        case 0x00:
            if hostMode { devAddrCtrl = value } else { addrEndp = value }
        case 0x40:
            mainCtrl = value & (RPUSBController.simTiming | RPUSBController.controllerEnable | RPUSBController.hostNDevice)
            hostMode = value & RPUSBController.hostNDevice != 0
            // no device is ever plugged into a host-mode controller here
            if value & RPUSBController.controllerEnable != 0 && !hostMode { onUSBEnabled?() }
        case 0x44:
            sofFrameNumber = value & 0x7FF
        case 0x4C:
            sieCtrl = value
        case 0x54:
            intEpCtrl = value
        case 0x58:
            buffStatus &= ~rawWriteValue
            buffStatusUpdated()
        case 0x60:
            epAbort = value
            epAbortDone |= value
        case 0x64:
            epAbortDone &= ~rawWriteValue
        case 0x68:
            epStallArm = value
        case 0x6C:
            nakPoll = value
        case 0x70:
            epStatusStallNak &= ~rawWriteValue
        case 0x74:
            // the SDK busy-waits in hw_enumeration_fix_force_ls_j() for the line to show the device connected
            if value & (1 << 2) != 0 && value & 1 == 0 { sieStatus |= RPUSBController.sieConnected }
        case 0x78:
            usbPwr = value
            if value & (1 << 2) != 0 {
                if value & (1 << 3) != 0 {
                    sieStatus |= RPUSBController.sieVBusDetected
                } else {
                    sieStatus &= ~RPUSBController.sieVBusDetected
                }
            }
        case 0x50:
            sieStatus &= ~(rawWriteValue & RPUSBController.sieWriteClearMask)
            if rawWriteValue & RPUSBController.sieBusReset != 0 {
                if !hostMode { onResetReceived?() }
                sieStatus &= ~(0x3 << 2)
                sieStatus |= (1 << 2) | RPUSBController.sieConnected
            }
            sieStatusUpdated()
        case 0x90:
            intEnable = value & 0xFFFFF
            checkInterrupts()
        case 0x94:
            intForce = value & 0xFFFFF
            checkInterrupts()
        default:
            super.writeUint32(offset, value)
        }
    }

    private func dpram32(_ offset: Int) -> UInt32 { chip.usbDPRAM.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    private func setDPRAM32(_ offset: Int, _ value: UInt32) { chip.usbDPRAM.storeBytes(of: value, toByteOffset: offset, as: UInt32.self) }

    private func dpramSlice(_ offset: Int, _ length: Int) -> [UInt8] {
        let start = min(max(offset, 0), RP2040.dpramSize)
        let end = min(start + length, RP2040.dpramSize)
        return [UInt8](UnsafeRawBufferPointer(start: chip.usbDPRAM + start, count: end - start))
    }

    private func endpointControl(_ endpoint: Int, out: Bool) -> UInt32 {
        dpram32(RPUSBController.ep1InControl + 8 * (endpoint - 1) + (out ? 4 : 0))
    }

    private func endpointBufferOffset(_ endpoint: Int, out: Bool) -> Int {
        endpoint == 0 ? 0x100 : Int(endpointControl(endpoint, out: out) & 0xFFC0)
    }

    /// The firmware wrote a word of DPRAM: a buffer control word marked available starts a transfer
    func dpramUpdated(_ offset: Int, _ written: UInt32) {
        if hostMode { return }
        var value = written
        guard value & RPUSBController.bufAvailable != 0, offset >= RPUSBController.ep0InBufferControl,
              offset <= RPUSBController.ep15OutBufferControl else { return }
        let endpoint = (offset - RPUSBController.ep0InBufferControl) >> 3
        let out = offset & 4 != 0
        var doubleBuffer = false
        var interrupt = true
        if endpoint != 0 {
            let control = endpointControl(endpoint, out: out)
            doubleBuffer = control & RPUSBController.ctrlDoubleBuffer != 0
            interrupt = control & RPUSBController.ctrlInterruptPerTransfer != 0
        }
        let delay = writeDelayMicroseconds * 1000
        if doubleBuffer && (value >> RPUSBController.buf1Shift) & RPUSBController.bufAvailable != 0 {
            let length = Int((value >> RPUSBController.buf1Shift) & RPUSBController.bufLengthMask)
            let bufferOffset = endpointBufferOffset(endpoint, out: out) + RPUSBController.buf1Offset
            value &= ~(RPUSBController.bufAvailable << RPUSBController.buf1Shift)
            setDPRAM32(offset, value)
            if out {
                onEndpointRead?(endpoint, length)
            } else {
                value &= ~(RPUSBController.bufFull << RPUSBController.buf1Shift)
                setDPRAM32(offset, value)
                let buffer = dpramSlice(bufferOffset, length)
                indicateBufferReady(endpoint, out: false)
                writeAlarms[endpoint].schedule(buffer, delay)
            }
        }
        let length = Int(value & RPUSBController.bufLengthMask)
        let bufferOffset = endpointBufferOffset(endpoint, out: out)
        value &= ~RPUSBController.bufAvailable
        setDPRAM32(offset, value)
        if out {
            onEndpointRead?(endpoint, length)
        } else {
            value &= ~RPUSBController.bufFull
            setDPRAM32(offset, value)
            let buffer = dpramSlice(bufferOffset, length)
            if interrupt || !doubleBuffer { indicateBufferReady(endpoint, out: false) }
            writeAlarms[endpoint].schedule(buffer, delay)
        }
    }

    func endpointReadDone(_ endpoint: Int, _ buffer: [UInt8]) {
        readAlarms[endpoint].schedule(buffer, readDelayMicroseconds * 1000)
    }

    private func finishRead(_ endpoint: Int, _ buffer: [UInt8]) {
        let bufferOffset = endpointBufferOffset(endpoint, out: true)
        let controlOffset = RPUSBController.ep0OutBufferControl + endpoint * 8
        var control = dpram32(controlOffset)
        let requested = Int(control & RPUSBController.bufLengthMask)
        let length = min(buffer.count, requested)
        control |= RPUSBController.bufFull
        control = (control & ~RPUSBController.bufLengthMask) | (UInt32(length) & RPUSBController.bufLengthMask)
        setDPRAM32(controlOffset, control)
        for i in 0..<length where bufferOffset + i < RP2040.dpramSize {
            chip.usbDPRAM.storeBytes(of: buffer[i], toByteOffset: bufferOffset + i, as: UInt8.self)
        }
        indicateBufferReady(endpoint, out: true)
    }

    private func checkInterrupts() { chip.setInterrupt(RPIRQ.usbctrl, intStatus != 0) }

    func resetDevice() { resetAlarm.schedule(10_000_000) }

    func sendSetupPacket(_ packet: [UInt8]) {
        for (i, byte) in packet.enumerated() { chip.usbDPRAM.storeBytes(of: byte, toByteOffset: i, as: UInt8.self) }
        sieStatus |= RPUSBController.sieSetupRec
        sieStatusUpdated()
    }

    private func indicateBufferReady(_ endpoint: Int, out: Bool) {
        buffStatus |= 1 << UInt32(endpoint * 2 + (out ? 1 : 0))
        buffStatusUpdated()
    }

    private func buffStatusUpdated() {
        if buffStatus != 0 { intRaw |= RPUSBController.intrBuffStatus } else { intRaw &= ~RPUSBController.intrBuffStatus }
        checkInterrupts()
    }

    private func sieStatusUpdated() {
        // (host mode maps other bits, but nothing here runs one)
        if !hostMode {
            for (sieBit, intBit) in RPUSBController.deviceInterrupts {
                if sieStatus & sieBit != 0 { intRaw |= intBit } else { intRaw &= ~intBit }
            }
        }
        checkInterrupts()
    }
}

/// The computer at the other end of the Pico's USB cable: it enumerates the firmware's CDC serial port, collects what
/// the firmware sends and feeds it what is typed (rp2040js's USBCDC)
final class RPUSBCDC {
    private static let configurationDescriptorSize = 9
    private let usb: RPUSBController
    private var txFIFO = RPFIFO(512)
    private var initialized = false
    private var descriptorsSize: Int?
    private var descriptors: [UInt8] = []
    private var outEndpoint = -1
    private var inEndpoint = -1
    var onSerialData: (([UInt8]) -> Void)?

    init(usb: RPUSBController) {
        self.usb = usb
        usb.onUSBEnabled = { [unowned self] in self.usb.resetDevice() }
        usb.onResetReceived = { [unowned self] in self.usb.sendSetupPacket(RPUSBCDC.setupPacket(0, 0, 0, 5, 1, 0, 0)) }
        usb.onEndpointWrite = { [unowned self] endpoint, buffer in self.endpointWrite(endpoint, buffer) }
        usb.onEndpointRead = { [unowned self] endpoint, size in
            if endpoint == self.outEndpoint {
                var buffer: [UInt8] = []
                for _ in 0..<min(size, self.txFIFO.itemCount) { buffer.append(UInt8(truncatingIfNeeded: self.txFIFO.pull())) }
                self.usb.endpointReadDone(self.outEndpoint, buffer)
            }
        }
    }

    static func setupPacket(_ direction: Int, _ type: Int, _ recipient: Int, _ request: Int, _ value: Int, _ index: Int,
                            _ length: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: direction << 7 | type << 5 | recipient), UInt8(truncatingIfNeeded: request),
         UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: index),
         UInt8(truncatingIfNeeded: index >> 8), UInt8(truncatingIfNeeded: length), UInt8(truncatingIfNeeded: length >> 8)]
    }

    /// GET_DESCRIPTOR for the configuration descriptor
    private static func configurationRequest(_ length: Int) -> [UInt8] { setupPacket(1, 0, 0, 6, 2 << 8, 0, length) }

    static func endpointNumbers(_ descriptors: [UInt8]) -> (in: Int, out: Int) {
        var index = 0
        var found = false
        var result = (in: -1, out: -1)
        while index < descriptors.count {
            let length = Int(descriptors[index])
            if length < 2 || descriptors.count < index + length { break }
            let type = descriptors[index + 1]
            if type == 4 && length == 9 {
                found = descriptors[index + 4] == 2 && descriptors[index + 5] == 10
            }
            if found && type == 5 && length == 7 {
                let address = Int(descriptors[index + 2])
                if descriptors[index + 3] & 0x3 == 2 {
                    if address & 0x80 != 0 { result.in = address & 0xF } else { result.out = address & 0xF }
                }
            }
            index += length
        }
        return result
    }

    private func endpointWrite(_ endpoint: Int, _ buffer: [UInt8]) {
        if endpoint == 0 && buffer.isEmpty {
            if descriptorsSize == nil {
                usb.sendSetupPacket(RPUSBCDC.configurationRequest(RPUSBCDC.configurationDescriptorSize))
            } else if !initialized {
                // SET_CONTROL_LINE_STATE with DTR and RTS: the terminal is open
                usb.sendSetupPacket(RPUSBCDC.setupPacket(0, 1, 0, 0x22, 0x3, 0, 0))
                initialized = true
            }
        }
        if endpoint == 0 && buffer.count > 1 {
            if buffer.count == RPUSBCDC.configurationDescriptorSize && buffer[1] == 2 && descriptorsSize == nil {
                let size = Int(buffer[3]) << 8 | Int(buffer[2])
                descriptorsSize = size
                usb.sendSetupPacket(RPUSBCDC.configurationRequest(size))
            } else if let size = descriptorsSize, descriptors.count < size {
                descriptors += buffer
            }
            if descriptorsSize == descriptors.count {
                let endpoints = RPUSBCDC.endpointNumbers(descriptors)
                inEndpoint = endpoints.in
                outEndpoint = endpoints.out
                // SET_CONFIGURATION 1
                usb.sendSetupPacket(RPUSBCDC.setupPacket(0, 0, 0, 9, 1, 0, 0))
            }
        }
        if endpoint == inEndpoint { onSerialData?(buffer) }
    }

    func sendSerialByte(_ value: UInt8) { txFIFO.push(UInt32(value)) }

    func resetInput() { txFIFO.reset() }

    var pendingInput: [UInt8] { txFIFO.items.map { UInt8(truncatingIfNeeded: $0) } }
}

extension RPUSBCDC {
    /// Replaces what waits to be sent to the firmware
    func setPendingInput(_ bytes: [UInt8]) {
        resetInput()
        for byte in bytes { sendSerialByte(byte) }
    }
}
