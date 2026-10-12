import CortexM4
import Foundation

/// A GDB server for an STM32 part (the remote serial protocol, as OpenOCD or an ST-Link's server speaks it): connect
/// with `arm-none-eabi-gdb firmware.elf -ex "target extended-remote localhost:3333"` and debug the firmware as it runs
/// in the circuit. Breakpoints (as many as 16, `break`, `hbreak`), stepping, continuing, Ctrl-C, registers (the core's,
/// its FPU's, MSP, PSP and the masks), memory (a peripheral's registers read as the core would read them: a data
/// register read takes its data), `load` into flash, and `monitor reset` (`monitor halt`, `monitor resume`).
///
/// While halted the core runs no instructions, but its clock and its peripherals run on with the circuit (as on a chip
/// whose debug freeze bits are clear): a timer keeps counting, an I²S port underruns. The core only moves as the
/// circuit runs: a `continue` or `step` with the simulation stopped waits for it.
public final class GDBServer: @unchecked Sendable {
    public let port: UInt16
    private let lock = NSLock()
    private var target: STM32Microcontroller
    private var listener: Int32 = -1
    private var client: Int32 = -1
    private var stopping = false
    /// The breakpoints GDB has set, and the chip they were set in (they are set again in a chip reset or replaced)
    private var breakpoints = Set<UInt32>()
    private var armed: ObjectIdentifier?
    /// Waiting for the core to halt, after a continue or a step, to tell GDB
    private var waiting = false

    /// Whether a debugger is connected
    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return client >= 0
    }

    /// Listens on localhost's `port` (3333, as OpenOCD does, by default)
    public init(target: STM32Microcontroller, port: UInt16 = 3333) throws {
        self.target = target
        self.port = port
        listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw GDBServerError("can't open a socket") }
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 1) == 0 else {
            close(listener)
            throw GDBServerError("port \(port) is in use")
        }
        let thread = Thread { [weak self] in self?.serve() }
        thread.name = "GDB server on port \(port)"
        thread.start()
    }

    deinit { stop() }

    /// The chip to debug from now on (the circuit's part was made anew): the breakpoints go with it
    public func retarget(_ chip: STM32Microcontroller) {
        lock.lock()
        target = chip
        lock.unlock()
    }

    /// Stops listening, lets the chip run on and closes the connection
    public func stop() {
        lock.lock()
        let wasStopping = stopping
        stopping = true
        let (l, c) = (listener, client)
        listener = -1
        lock.unlock()
        guard !wasStopping else { return }
        withChip { core, _ in
            for address in breakpoints { _ = cm4_set_breakpoint(core, address, false) }
            cm4_resume(core)
        }
        if c >= 0 { shutdown(c, SHUT_RDWR) }
        if l >= 0 { shutdown(l, SHUT_RDWR); close(l) }
    }

    // MARK: - The chip

    /// The chip's core and the chip, while it does not run (its lock held), its breakpoints set
    @discardableResult
    private func withChip<T>(_ body: (OpaquePointer, OpaquePointer) -> T) -> T {
        lock.lock()
        let chip = target
        lock.unlock()
        return chip.debug { stm32, identity in
            let core = stm32_core(stm32)!
            if armed != identity {
                armed = identity
                for address in breakpoints { _ = cm4_set_breakpoint(core, address, true) }
            }
            return body(core, stm32)
        }
    }

    // MARK: - The connection

    private func serve() {
        while true {
            lock.lock()
            let (l, done) = (listener, stopping)
            lock.unlock()
            if done || l < 0 { return }
            let fd = accept(l, nil, nil)
            guard fd >= 0 else { continue }
            var yes: Int32 = 1
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            client = fd
            lock.unlock()
            // GDB attaches to a halted target
            withChip { core, _ in cm4_halt(core) }
            converse(fd)
            close(fd)
            lock.lock()
            client = -1
            lock.unlock()
            // (detached or gone: the chip runs on, its breakpoints cleared)
            withChip { core, _ in
                for address in breakpoints { _ = cm4_set_breakpoint(core, address, false) }
                cm4_resume(core)
            }
            breakpoints = []
            waiting = false
        }
    }

    private func converse(_ fd: Int32) {
        var input: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 10)
            if ready > 0 {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { return }
                input += buffer[0..<count]
            } else if ready < 0 && errno != EINTR {
                return
            }
            // packets: $data#checksum; a lone 0x03 asks to halt
            while let first = input.first {
                if first == 0x03 {
                    input.removeFirst()
                    withChip { core, _ in cm4_halt(core) }
                    continue
                }
                if first != UInt8(ascii: "$") {
                    input.removeFirst()  // an acknowledgement
                    continue
                }
                guard let hash = input.firstIndex(of: UInt8(ascii: "#")), input.count >= hash + 3 else { break }
                let packet = String(decoding: input[1..<hash], as: UTF8.self)
                input.removeFirst(hash + 3)
                send(fd, "+")
                guard let reply = respond(to: packet) else { return }
                if !waiting { sendPacket(fd, reply) }
            }
            // a continue or step done: the core halted
            if waiting, withChip({ core, _ in cm4_halted(core) }) {
                waiting = false
                sendPacket(fd, "S05")
            }
            lock.lock()
            let done = stopping
            lock.unlock()
            if done { return }
        }
    }

    private func send(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            sent += n
        }
    }

    private func sendPacket(_ fd: Int32, _ data: String) {
        let sum = data.utf8.reduce(UInt8(0)) { $0 &+ $1 }
        send(fd, "$" + data + "#" + String(format: "%02x", sum))
    }

    // MARK: - The protocol

    /// The reply to a packet (nil: the connection ends); a continue or step sets `waiting`, its reply sent on halting
    func respond(to packet: String) -> String? {
        guard let command = packet.first else { return "" }
        let rest = String(packet.dropFirst())
        switch command {
        case "?": return "S05"
        case "g":
            return withChip { core, _ in (0..<Self.registerCount).map { Self.hex(Self.register(core, $0)) }.joined() }
        case "G":
            let bytes = Self.bytes(rest)
            withChip { core, _ in
                var offset = 0
                for n in 0..<Self.registerCount {
                    let size = Self.registerSize(n)
                    guard offset + size <= bytes.count else { break }
                    Self.setRegister(core, n, Array(bytes[offset..<offset + size]))
                    offset += size
                }
            }
            return "OK"
        case "p":
            guard let n = Int(rest, radix: 16), n < Self.registerCount else { return "E01" }
            return withChip { core, _ in Self.hex(Self.register(core, n)) }
        case "P":
            let parts = rest.split(separator: "=")
            guard parts.count == 2, let n = Int(parts[0], radix: 16), n < Self.registerCount else { return "E01" }
            let bytes = Self.bytes(String(parts[1]))
            guard bytes.count == Self.registerSize(n) else { return "E01" }
            withChip { core, _ in Self.setRegister(core, n, bytes) }
            return "OK"
        case "m":
            guard let (address, length) = Self.range(rest), length <= 0x4000 else { return "E01" }
            return withChip { core, stm32 in Self.hex(Self.readMemory(core, stm32, address, length)) }
        case "M":
            let parts = rest.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let (address, length) = Self.range(String(parts[0])) else { return "E01" }
            let bytes = Self.bytes(String(parts[1]))
            guard bytes.count == length else { return "E01" }
            withChip { core, stm32 in Self.writeMemory(core, stm32, address, bytes) }
            return "OK"
        case "c":
            if let address = UInt32(rest, radix: 16) { withChip { core, _ in cm4_set_reg(core, 15, address) } }
            withChip { core, _ in cm4_resume(core) }
            waiting = true
            return ""
        case "s":
            if let address = UInt32(rest, radix: 16) { withChip { core, _ in cm4_set_reg(core, 15, address) } }
            withChip { core, _ in cm4_step_once(core) }
            waiting = true
            return ""
        case "Z", "z":
            // Z0 (software) or Z1 (hardware) breakpoints, both kept by the core
            let fields = rest.split(separator: ",")
            guard fields.count >= 2, fields[0] == "0" || fields[0] == "1", let address = UInt32(fields[1], radix: 16) else {
                return ""  // watchpoints are not kept
            }
            let on = command == "Z"
            let done = withChip { core, _ in cm4_set_breakpoint(core, address, on) }
            guard done else { return "E0E" }
            if on { breakpoints.insert(address & ~1) } else { breakpoints.remove(address & ~1) }
            return "OK"
        case "D":
            return nil
        case "k":
            return nil
        case "H": return "OK"
        case "T": return "OK"
        case "v":
            if rest.hasPrefix("MustReplyEmpty") { return "" }
            if rest.hasPrefix("Kill") { return nil }
            return ""
        case "q":
            return query(rest)
        case "Q":
            return ""
        default:
            return ""
        }
    }

    private func query(_ query: String) -> String {
        if query.hasPrefix("Supported") { return "PacketSize=4000;qXfer:features:read+" }
        if query.hasPrefix("Xfer:features:read:target.xml:") {
            let span = query.dropFirst("Xfer:features:read:target.xml:".count).split(separator: ",")
            guard span.count == 2, let offset = Int(span[0], radix: 16), let length = Int(span[1], radix: 16) else { return "E01" }
            let document = Array(Self.targetDescription.utf8)
            guard offset < document.count else { return "l" }
            let end = min(document.count, offset + length)
            return (end == document.count ? "l" : "m") + String(decoding: document[offset..<end], as: UTF8.self)
        }
        if query == "Attached" { return "1" }
        if query == "C" { return "QC1" }
        if query == "fThreadInfo" { return "m1" }
        if query == "sThreadInfo" { return "l" }
        if query.hasPrefix("Rcmd,") {
            let text = String(decoding: Self.bytes(String(query.dropFirst(5))), as: UTF8.self).trimmingCharacters(in: .whitespaces)
            switch text {
            case "reset", "reset halt", "reset init":
                // (halted either way: GDB takes the target to be stopped after a monitor command)
                withChip { core, stm32 in
                    stm32_reset(stm32)
                    cm4_halt(core)
                }
                return Self.hex(Array("The chip was reset; it is halted at its first instruction.\n".utf8))
            case "halt":
                withChip { core, _ in cm4_halt(core) }
                return "OK"
            case "resume":
                withChip { core, _ in cm4_resume(core) }
                return "OK"
            default:
                return Self.hex(Array("Commands: reset, halt, resume.\n".utf8))
            }
        }
        return ""
    }

    // MARK: - Registers (as the target description below numbers them)

    /// r0-r12, sp, lr, pc, xpsr; d0-d15, fpscr; msp, psp, primask, basepri, faultmask, control
    static let registerCount = 40

    static func registerSize(_ n: Int) -> Int { n >= 17 && n <= 32 ? 8 : 4 }

    static func register(_ core: OpaquePointer, _ n: Int) -> [UInt8] {
        func word(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        switch n {
        case 0...15: return word(cm4_reg(core, Int32(n)))
        case 16: return word(cm4_xpsr(core))
        case 17...32:
            let d = Int32(n - 17)
            return word(cm4_sreg(core, 2 * d)) + word(cm4_sreg(core, 2 * d + 1))
        case 33: return word(cm4_fpscr(core))
        default:
            return word(cm4_special(core, Int32(n - 34)))
        }
    }

    static func setRegister(_ core: OpaquePointer, _ n: Int, _ bytes: [UInt8]) {
        func word(_ k: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[k + $1]) << (8 * $1) } }
        switch n {
        case 0...15: cm4_set_reg(core, Int32(n), n == 15 ? word(0) & ~1 : word(0))
        case 16: cm4_set_xpsr(core, word(0))
        case 17...32:
            let d = Int32(n - 17)
            cm4_set_sreg(core, 2 * d, word(0))
            cm4_set_sreg(core, 2 * d + 1, word(4))
        case 33: cm4_set_fpscr(core, word(0))
        default: cm4_set_special(core, Int32(n - 34), word(0))
        }
    }

    static let targetDescription: String = {
        var lines = ["<?xml version=\"1.0\"?>", "<!DOCTYPE target SYSTEM \"gdb-target.dtd\">", "<target version=\"1.0\">",
                     "<architecture>arm</architecture>", "<feature name=\"org.gnu.gdb.arm.m-profile\">"]
        for n in 0...12 { lines.append("<reg name=\"r\(n)\" bitsize=\"32\" regnum=\"\(n)\" type=\"uint32\" group=\"general\"/>") }
        lines += ["<reg name=\"sp\" bitsize=\"32\" regnum=\"13\" type=\"data_ptr\" group=\"general\"/>",
                  "<reg name=\"lr\" bitsize=\"32\" regnum=\"14\" type=\"int\" group=\"general\"/>",
                  "<reg name=\"pc\" bitsize=\"32\" regnum=\"15\" type=\"code_ptr\" group=\"general\"/>",
                  "<reg name=\"xpsr\" bitsize=\"32\" regnum=\"16\" type=\"int\" group=\"general\"/>",
                  "</feature>", "<feature name=\"org.gnu.gdb.arm.vfp\">"]
        for n in 0...15 { lines.append("<reg name=\"d\(n)\" bitsize=\"64\" regnum=\"\(17 + n)\" type=\"ieee_double\" group=\"float\"/>") }
        lines += ["<reg name=\"fpscr\" bitsize=\"32\" regnum=\"33\" type=\"int\" group=\"float\"/>", "</feature>",
                  "<feature name=\"org.gnu.gdb.arm.m-system\">"]
        for (k, name) in ["msp", "psp", "primask", "basepri", "faultmask", "control"].enumerated() {
            lines.append("<reg name=\"\(name)\" bitsize=\"32\" regnum=\"\(34 + k)\" type=\"\(k < 2 ? "data_ptr" : "uint32")\" group=\"system\"/>")
        }
        lines += ["</feature>", "</target>"]
        return lines.joined(separator: "\n")
    }()

    // MARK: - Memory

    /// Bytes as the core reads them: word by word where they line up (a peripheral's registers), else byte by byte
    static func readMemory(_ core: OpaquePointer, _ chip: OpaquePointer, _ address: UInt32, _ length: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(length)
        var at = address
        var left = length
        while left > 0 {
            if at % 4 == 0 && left >= 4 {
                let v = cm4_read(core, at, 4)
                out += (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
                at &+= 4
                left -= 4
            } else {
                out.append(UInt8(truncatingIfNeeded: cm4_read(core, at, 1)))
                at &+= 1
                left -= 1
            }
        }
        return out
    }

    /// Bytes written as the core would write them, except into flash, which takes them as a programmer writes them
    /// (GDB's `load`)
    static func writeMemory(_ core: OpaquePointer, _ chip: OpaquePointer, _ address: UInt32, _ bytes: [UInt8]) {
        let flashSize = UInt32(stm32_flash_size(chip))
        let flash = stm32_flash(chip)!
        for (k, byte) in bytes.enumerated() {
            let at = address &+ UInt32(k)
            if at >= 0x0800_0000 && at - 0x0800_0000 < flashSize {
                flash[Int(at - 0x0800_0000)] = byte
            } else if at < flashSize {
                flash[Int(at)] = byte
            } else {
                cm4_write(core, at, UInt32(byte), 1)
            }
        }
    }

    // MARK: - Encoding

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func bytes(_ hex: String) -> [UInt8] {
        let digits = Array(hex.utf8)
        var out: [UInt8] = []
        var k = 0
        while k + 1 < digits.count {
            guard let high = Self.nibble(digits[k]), let low = Self.nibble(digits[k + 1]) else { break }
            out.append(high << 4 | low)
            k += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// "addr,length" in hex
    static func range(_ text: String) -> (UInt32, Int)? {
        let parts = text.split(separator: ",")
        guard parts.count == 2, let address = UInt32(parts[0], radix: 16), let length = Int(parts[1], radix: 16) else { return nil }
        return (address, length)
    }
}

public struct GDBServerError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}
