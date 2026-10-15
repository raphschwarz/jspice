import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A request socket of NNG's (nanomsg-next-generation's) scalability protocols, REQ0, over its IPC transport: the
/// socket KiCad's API listens on (nng_rep0). The wire is small enough to speak without the library: after an 8-byte
/// greeting naming each side's protocol, each message is a byte 1, its length (8 bytes, big-endian) and its body; a
/// request's body starts with a 4-byte id with its top bit set, which the reply's body starts with too
/// (nng/src/sp/transport/ipc/ipc.c, nng/src/sp/protocol/reqrep0/req.c).
final class NNGRequestSocket {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    private var fd: Int32 = -1
    private var nextID: UInt32 = UInt32.random(in: 1..<0x7fff_ffff)
    let path: String

    /// Connects to the socket at `path` (a file path, or "ipc://" and one), waiting at most `timeout` for each reply
    init(path: String, timeout: TimeInterval) throws {
        self.path = path.hasPrefix("ipc://") ? String(path.dropFirst(6)) : path
        #if os(Linux)
        fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw Failure(description: "can't open a socket") }
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var tv = timeval()
        tv.tv_sec = Int(timeout)
        tv.tv_usec = numericCast(Int((timeout - timeout.rounded(.down)) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(self.path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { close(fd); throw Failure(description: "the socket's path is too long: \(self.path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (i, b) in bytes.enumerated() { buffer[i] = b }
            buffer[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            fd = -1
            throw Failure(description: "can't connect to \(self.path): \(reason)")
        }
        // the greeting: NNG's SP header, REQ0 (0x30) here, REP0 (0x31) there
        try write([0x00, 0x53, 0x50, 0x00, 0x00, 0x30, 0x00, 0x00])
        let greeting = try read(8)
        guard greeting[0] == 0, greeting[1] == 0x53, greeting[2] == 0x50, greeting[3] == 0, greeting[4] == 0, greeting[5] == 0x31 else {
            close(fd)
            fd = -1
            throw Failure(description: "\(self.path) is not a REP socket of NNG's")
        }
    }

    deinit { if fd >= 0 { close(fd) } }

    /// Sends `body` as a request and waits for the reply's body
    func request(_ body: [UInt8]) throws -> [UInt8] {
        let id = nextID | 0x8000_0000
        nextID = nextID % 0x7fff_fffe + 1
        let header = withUnsafeBytes(of: id.bigEndian) { Array($0) }
        let payload = header + body
        try write([0x01] + withUnsafeBytes(of: UInt64(payload.count).bigEndian) { Array($0) } + payload)
        // replies to earlier requests (that timed out) are passed over
        while true {
            let kind = try read(1)
            guard kind[0] == 0x01 else { throw Failure(description: "an unknown message from \(path)") }
            let length = try read(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard length >= 4, length < 1 << 31 else { throw Failure(description: "a reply \(length) bytes long") }
            let reply = try read(Int(length))
            if Array(reply.prefix(4)) == header { return Array(reply.dropFirst(4)) }
        }
    }

    private func write(_ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            #if os(Linux)
            let n = bytes[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
            #else
            let n = bytes[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            #endif
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw Failure(description: "can't write to \(path): \(String(cString: strerror(errno)))") }
            sent += n
        }
    }

    private func read(_ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, count - got, 0) }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { throw Failure(description: "KiCad did not answer in time") }
            guard n > 0 else { throw Failure(description: "\(path) closed the connection") }
            got += n
        }
        return buffer
    }
}
