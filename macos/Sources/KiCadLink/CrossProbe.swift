import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// What KiCad's PCB editor says about its selection as it changes, heard as its schematic editor hears it: a PCB
/// editor running on its own sends each selection to localhost's port 4243 ("$SELECT: 0,FR1,FU2,PU2/3": footprints
/// and pads by reference, pcbnew/cross-probing.cpp), one message a connection. JSpice listens there while no
/// schematic editor of KiCad's does.
public final class KiCadCrossProbe: @unchecked Sendable {
    public static let schematicPort: UInt16 = 4243
    public static let pcbPort: UInt16 = 4242

    private var listener: Int32 = -1
    private let queue = DispatchQueue(label: "org.knowm.jspice.kicad-cross-probe")
    private let handler: @Sendable ([String]) -> Void
    private var running = false

    /// Listens on `port`, calling `handler` with the references selected in the PCB editor (a pad's footprint's for a
    /// pad) each time its selection changes; nil if the port is taken (KiCad's own schematic editor has it)
    public init?(port: UInt16 = schematicPort, handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
        #if os(Linux)
        listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        listener = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard listener >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 8) == 0 else {
            close(listener)
            return nil
        }
        running = true
        queue.async { [self] in serve() }
    }

    deinit { stop() }

    public func stop() {
        guard running else { return }
        running = false
        #if os(Linux)
        shutdown(listener, Int32(SHUT_RDWR))
        #else
        shutdown(listener, SHUT_RDWR)
        #endif
        close(listener)
    }

    private func serve() {
        while running {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { if running { continue } else { return } }
            var data = [UInt8]()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while data.count < 65536 {
                let n = recv(client, &buffer, buffer.count, 0)
                if n <= 0 { break }
                data += buffer[0..<n]
            }
            close(client)
            if let references = Self.selection(String(decoding: data, as: UTF8.self)) { handler(references) }
        }
    }

    /// The references a "$SELECT: …" message names, its pads' footprints' included; nil for other messages
    public static func selection(_ message: String) -> [String]? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("$SELECT:") else { return nil }
        let specs = text.dropFirst(8).trimmingCharacters(in: .whitespaces).split(separator: ",").dropFirst()
        var references: [String] = []
        for spec in specs {
            let unescaped = String(spec).replacingOccurrences(of: "{slash}", with: "/")
                .replacingOccurrences(of: "{comma}", with: ",").replacingOccurrences(of: "{dblquote}", with: "\"")
            guard let kind = unescaped.first else { continue }
            let body = String(unescaped.dropFirst())
            switch kind {
            case "F": references.append(body)
            case "P": references.append(String(body.split(separator: "/").first ?? ""))
            default: continue
            }
        }
        var seen = Set<String>()
        return references.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Asks the PCB editor to highlight a net (or none), as KiCad's schematic editor does
    public static func highlight(net: String?) {
        post("$NET: \"\(net ?? "")\"", to: pcbPort)
    }

    static func post(_ message: String, to port: UInt16) {
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return }
        let bytes = Array(message.utf8)
        _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    }
}
