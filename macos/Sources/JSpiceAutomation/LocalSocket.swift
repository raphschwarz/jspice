import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A Unix domain socket carrying one JSON message per line: the app listens on it, and `jspice-mcp` connects to it to
/// hand an AI agent's requests to the circuit open in the app.
public enum LocalSocket {
    /// ~/Library/Application Support/JSpice/mcp.sock
    public static var defaultPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = support.appendingPathComponent("JSpice", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("mcp.sock").path
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, byte) in bytes.enumerated() { raw[i] = byte }
            raw[bytes.count] = 0
        }
        return address
    }

    private static func noSignalOnClose(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Connects to a listening socket; nil if nothing is listening there
    public static func connect(to path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        noSignalOnClose(fd)
        return fd
    }

    /// Listens at `path` (readable only by this user) and serves each client on its own thread. Returns the listening
    /// socket, to close with `stop`.
    public static func listen(at path: String, handler: @escaping @Sendable (Int32) -> Void) -> Int32? {
        guard var address = address(path) else { return nil }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            close(fd)
            return nil
        }
        chmod(path, 0o600)
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                noSignalOnClose(client)
                Thread.detachNewThread { handler(client) }
            }
        }
        return fd
    }

    public static func stop(_ fd: Int32, path: String) {
        close(fd)
        unlink(path)
    }

    /// Calls `body` with each line read from `fd`, until the other side closes it
    public static func readLines(_ fd: Int32, _ body: (String) -> Void) {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                body(line)
            }
        }
    }

    /// Reads a single line, or nil if the other side closes first
    public static func readLine(_ fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = read(fd, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return nil }
            if byte == 10 { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
    }

    /// Writes one line; false if the other side has gone
    @discardableResult
    public static func write(_ fd: Int32, _ line: String) -> Bool {
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written < 0 && errno == EINTR { continue }
            if written <= 0 { return false }
            offset += written
        }
        return true
    }
}
