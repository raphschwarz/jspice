@testable import CircuitKit
import XCTest

/// The GDB server takes packets from whatever connects to its port: a malformed one gets an error reply (or none, or a
/// NAK), never a crash. The framing and the replies are checked below the socket.
final class GDBServerTests: XCTestCase {
    func frame(_ data: String) -> [UInt8] {
        let sum = data.utf8.reduce(UInt8(0)) { $0 &+ $1 }
        return Array(("$" + data + "#" + String(format: "%02x", sum)).utf8)
    }

    func testPacketsAreFramedAndTheirChecksumsChecked() {
        var reader = GDBPacketReader()
        reader.feed(Array("+".utf8) + frame("g") + [0x03] + Array("$m0,4#00".utf8) + Array("$qC#B4".utf8))
        XCTAssertEqual(reader.next(), .packet("g"))
        XCTAssertEqual(reader.next(), .interrupt)
        XCTAssertEqual(reader.next(), .corrupt, "a wrong checksum is NAKed")
        XCTAssertEqual(reader.next(), .packet("qC"), "checksum digits in either case")
        XCTAssertNil(reader.next())
        reader.feed(Array("$?#zz".utf8))
        XCTAssertEqual(reader.next(), .corrupt, "checksum digits that are not hex")
        // a packet in pieces
        let packet = frame("m8000000,8")
        reader.feed(packet.prefix(5))
        XCTAssertNil(reader.next())
        reader.feed(packet.dropFirst(5).dropLast(1))
        XCTAssertNil(reader.next())
        reader.feed(packet.suffix(1))
        XCTAssertEqual(reader.next(), .packet("m8000000,8"))
        XCTAssertFalse(reader.overflowed)
    }

    /// The receive buffer is bounded: a packet that never ends is dropped with the connection
    func testAPacketThatNeverEndsOverflows() {
        var reader = GDBPacketReader()
        reader.feed(Array("$M20000000,4000:".utf8))
        for _ in 0..<8 {
            reader.feed([UInt8](repeating: UInt8(ascii: "0"), count: 4096))
            XCTAssertNil(reader.next())
        }
        XCTAssertTrue(reader.overflowed)
        reader.feed(frame("g"))
        XCTAssertNil(reader.next(), "nothing more once it has overflowed")
        // the largest packet GDB may send still fits
        var fits = GDBPacketReader()
        let data = "M20000000,1ff8:" + String(repeating: "00", count: 0x1FF8)
        XCTAssertLessThanOrEqual(data.utf8.count, GDBServer.packetSize)
        fits.feed(frame(data))
        XCTAssertEqual(fits.next(), .packet(data))
        XCTAssertFalse(fits.overflowed)
    }

    func testMalformedPacketsAreAnsweredWithErrors() throws {
        let chip = STM32Microcontroller(firmware: [UInt8](repeating: 0xFF, count: 64))
        let server = try GDBServer(target: chip, port: 0)
        defer { server.stop() }
        let errors = [
            // negative, huge or overflowing offsets and lengths
            "qXfer:features:read:target.xml:-1,10", "qXfer:features:read:target.xml:10,7fffffffffffffff",
            "qXfer:features:read:target.xml:0,-10", "qXfer:features:read:target.xml:0", "qXfer:features:read:target.xml:,",
            "qXfer:features:read:other.xml:0,10",
            // register numbers
            "p-1", "p", "p28", "pffffffffffffffffffff", "p+1", "P-1=00000000", "P0=1234567", "P0=12345678ff", "P0=xyzwxyzw",
            "P28=00000000",
            // memory: negative lengths, past the end of the address space, too long, odd or bad hex
            "m0,-1", "m-8,4", "mffffffff,10", "m0,100000", "m0", "m,", "m20000000,4,4", "mfffffffff,1",
            "M20000000,2:123", "M20000000,2:12345", "M20000000,-1:", "M20000000,2:zzzz", "Mffffffff,2:0000", "M20000000,2",
        ]
        for packet in errors {
            let reply = server.respond(to: packet)
            XCTAssertTrue(reply?.hasPrefix("E") ?? false, "\(packet) → \(reply ?? "nil")")
        }
        // and the well-formed ones still work
        XCTAssertEqual(server.respond(to: "qXfer:features:read:target.xml:0,5"), "m<?xml")
        let whole = try XCTUnwrap(server.respond(to: "qXfer:features:read:target.xml:0,ffffffff"))
        XCTAssertEqual(whole, "l" + GDBServer.targetDescription)
        XCTAssertEqual(server.respond(to: "qXfer:features:read:target.xml:ffffff,10"), "l")
        XCTAssertEqual(server.respond(to: "M20000000,4:78563412"), "OK")
        XCTAssertEqual(server.respond(to: "m20000000,4"), "78563412")
        XCTAssertEqual(server.respond(to: "mfffffffc,4")?.count, 8, "the address space's last word")
        XCTAssertEqual(server.respond(to: "P0=78563412"), "OK")
        XCTAssertEqual(server.respond(to: "p0"), "78563412")
        // breakpoints at addresses that do not parse are not kept (an empty reply: unsupported)
        XCTAssertEqual(server.respond(to: "Z0,-1,2"), "")
        XCTAssertEqual(server.respond(to: "Z0"), "")
        XCTAssertEqual(server.respond(to: ""), "")
    }
}
