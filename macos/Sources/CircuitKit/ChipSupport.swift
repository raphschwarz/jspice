import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The microcontroller families JSpice can compile for
public enum ChipFamily: String, CaseIterable, Identifiable, Sendable {
    case avr
    case rp2040

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .avr: return "AVR: Arduino Uno, Mega 2560 and ATtiny85"
        case .rp2040: return "RP2040: Raspberry Pi Pico"
        }
    }

    public var summary: String {
        switch self {
        case .avr: return "avr-gcc with avr-libc and the Arduino AVR core, from Arduino's package index (about 40 MB)"
        case .rp2040:
            return "arm-none-eabi-gcc and Earle Philhower's arduino-pico core, from its package index (about 240 MB to download)"
        }
    }

    /// The package index the compiler and core come from
    var indexURL: URL {
        switch self {
        case .avr: return URL(string: "https://downloads.arduino.cc/packages/package_index.json")!
        case .rp2040:
            return URL(string: "https://github.com/earlephilhower/arduino-pico/releases/download/global/package_rp2040_index.json")!
        }
    }

    /// The compiler's folder name in the install folder, and a file inside it
    public var compilerFolder: String { self == .avr ? "avr-gcc" : "arm-none-eabi-gcc" }
    var compilerMarker: String { self == .avr ? "bin/avr-gcc" : "bin/arm-none-eabi-gcc" }
    /// A file inside the core's folder
    var coreMarker: String { self == .avr ? "cores/arduino/Arduino.h" : "cores/rp2040/Arduino.h" }
    /// What the progress messages call the core
    public var coreName: String { self == .avr ? "the Arduino AVR core" : "arduino-pico" }
}

/// Installs what compiling for a chip family takes (the compiler and the Arduino core), like the Arduino IDE's boards
/// manager: from Arduino's package index (arduino-pico's for the RP2040), each archive checked against its SHA-256
/// checksum, into JSpice's Application Support folder.
public enum ChipSupport {
    public struct Progress: Sendable {
        /// 0 to 1
        public var fraction: Double
        public var message: String

        public init(fraction: Double, message: String) {
            self.fraction = fraction
            self.message = message
        }
    }

    public enum InstallError: Error, CustomStringConvertible {
        case index(String)
        case download(String)
        case checksum(String)
        case unpack(String)

        public var description: String {
            switch self {
            case .index(let text): return "The package index: \(text)"
            case .download(let text): return "Download failed: \(text)"
            case .checksum(let text): return "\(text) did not arrive intact (its checksum differs); try again"
            case .unpack(let text): return "Could not unpack \(text)"
            }
        }
    }

    /// ~/Library/Application Support/JSpice/Chips (JSPICE_CHIPS overrides it)
    public static var supportFolder: URL {
        if let path = ProcessInfo.processInfo.environment["JSPICE_CHIPS"] { return URL(fileURLWithPath: path) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".jspice")
        return base.appendingPathComponent("JSpice/Chips")
    }

    public static func installFolder(for family: ChipFamily) -> URL {
        supportFolder.appendingPathComponent(family.rawValue)
    }

    /// What JSpice installed: versions of the compiler and the core
    public static func installedVersions(_ family: ChipFamily) -> (compiler: String, core: String)? {
        let manifest = installFolder(for: family).appendingPathComponent("installed.json")
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let compiler = object["compiler"], let core = object["core"] else { return nil }
        return (compiler, core)
    }

    /// True when sketches for the family can be compiled (with JSpice's install, or an Arduino IDE's)
    public static func isAvailable(_ family: ChipFamily) -> Bool {
        switch family {
        case .avr: return AVRToolchain.find() != nil
        case .rp2040: return PicoToolchain.find() != nil
        }
    }

    public static func uninstall(_ family: ChipFamily) throws {
        let folder = installFolder(for: family)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    // MARK: - Installing

    struct Archive {
        let name: String
        let version: String
        let url: URL
        let checksum: String
        let size: Int
    }

    /// Downloads and unpacks the family's compiler and core; `progress` is called along the way (on any thread)
    public static func install(_ family: ChipFamily, progress: @escaping @Sendable (Progress) -> Void) async throws {
        progress(Progress(fraction: 0, message: "Reading the package index…"))
        let (indexData, response) = try await URLSession.shared.data(from: family.indexURL)
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { throw InstallError.index("the server refused") }
        let (core, compiler) = family == .avr ? try archives(in: indexData) : try picoArchives(in: indexData)
        let total = Double(max(core.size + compiler.size, 1))

        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent("jspice-chips-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        var done = 0.0
        var files: [URL] = []
        for archive in [compiler, core] {
            let file = staging.appendingPathComponent(archive.url.lastPathComponent)
            let start = done
            try await download(archive, to: file) { received in
                let fraction = (start + Double(received)) / total * 0.9
                progress(Progress(fraction: fraction, message: "Downloading \(archive.name) \(archive.version)…"))
            }
            done += Double(archive.size)
            files.append(file)
        }

        progress(Progress(fraction: 0.92, message: "Unpacking…"))
        let destination = installFolder(for: family)
        let compilerFolder = try unpack(files[0], in: staging.appendingPathComponent("compiler"), containing: family.compilerMarker)
        let coreFolder = try unpack(files[1], in: staging.appendingPathComponent("core"), containing: family.coreMarker)
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination.appendingPathComponent(family.compilerFolder), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination.appendingPathComponent("core"), withIntermediateDirectories: true)
        try fileManager.moveItem(at: compilerFolder,
                                 to: destination.appendingPathComponent("\(family.compilerFolder)/\(compiler.version)"))
        try fileManager.moveItem(at: coreFolder, to: destination.appendingPathComponent("core/\(core.version)"))
        let manifest = try JSONSerialization.data(withJSONObject: ["compiler": compiler.version, "core": core.version])
        try manifest.write(to: destination.appendingPathComponent("installed.json"))
        progress(Progress(fraction: 1, message: "Installed \(compiler.name) \(compiler.version) and \(family.coreName) \(core.version)"))
    }

    /// The newest Arduino AVR core in the index, and the avr-gcc it was made with, for this computer
    static func archives(in indexData: Data) throws -> (core: Archive, compiler: Archive) {
        guard let index = try JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              let packages = index["packages"] as? [[String: Any]],
              let arduino = packages.first(where: { $0["name"] as? String == "arduino" }),
              let platforms = arduino["platforms"] as? [[String: Any]],
              let tools = arduino["tools"] as? [[String: Any]] else { throw InstallError.index("not in the expected form") }
        let avr = platforms.filter { $0["architecture"] as? String == "avr" }
            .sorted { AVRToolchain.newerFirst($0["version"] as? String ?? "", $1["version"] as? String ?? "") }
        guard let platform = avr.first, let core = archive(platform, name: "Arduino AVR core") else {
            throw InstallError.index("no Arduino AVR core")
        }
        let dependency = (platform["toolsDependencies"] as? [[String: Any]])?.first { $0["name"] as? String == "avr-gcc" }
        guard let version = dependency?["version"] as? String,
              let tool = tools.first(where: { $0["name"] as? String == "avr-gcc" && $0["version"] as? String == version }),
              let systems = tool["systems"] as? [[String: Any]] else { throw InstallError.index("no avr-gcc for the AVR core") }
        guard let system = bestSystem(systems), let compiler = archive(system, name: "avr-gcc", version: version) else {
            throw InstallError.index("no avr-gcc \(version) for this computer")
        }
        return (core, compiler)
    }

    /// arduino-pico (the release JSpice's build follows, else the newest) and the arm-none-eabi gcc it was made with
    static func picoArchives(in indexData: Data) throws -> (core: Archive, compiler: Archive) {
        guard let index = try JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              let packages = index["packages"] as? [[String: Any]],
              let package = packages.first(where: { $0["name"] as? String == "rp2040" }),
              let platforms = package["platforms"] as? [[String: Any]],
              let tools = package["tools"] as? [[String: Any]] else { throw InstallError.index("not in the expected form") }
        let releases = platforms.filter { $0["architecture"] as? String == "rp2040" }
            .sorted { AVRToolchain.newerFirst($0["version"] as? String ?? "", $1["version"] as? String ?? "") }
        guard let platform = releases.first(where: { $0["version"] as? String == PicoToolchain.coreVersion }) ?? releases.first,
              let core = archive(platform, name: "arduino-pico") else { throw InstallError.index("no arduino-pico") }
        let dependency = (platform["toolsDependencies"] as? [[String: Any]])?.first { $0["name"] as? String == "pqt-gcc" }
        guard let version = dependency?["version"] as? String,
              let tool = tools.first(where: { $0["name"] as? String == "pqt-gcc" && $0["version"] as? String == version }),
              let systems = tool["systems"] as? [[String: Any]] else { throw InstallError.index("no gcc for arduino-pico") }
        guard let system = bestSystem(systems), let compiler = archive(system, name: "arm-none-eabi-gcc", version: version) else {
            throw InstallError.index("no arm-none-eabi-gcc \(version) for this computer")
        }
        return (core, compiler)
    }

    private static func archive(_ entry: [String: Any], name: String, version: String? = nil) -> Archive? {
        guard let urlText = entry["url"] as? String, let url = URL(string: urlText),
              let checksum = entry["checksum"] as? String else { return nil }
        let size = (entry["size"] as? String).flatMap { Int($0) } ?? (entry["size"] as? Int) ?? 0
        return Archive(name: name, version: version ?? entry["version"] as? String ?? "?", url: url, checksum: checksum, size: size)
    }

    /// The build for this computer's processor and system: a native one if there is one (Apple silicon), otherwise one
    /// the system can run (Intel builds run under Rosetta)
    static func bestSystem(_ systems: [[String: Any]]) -> [String: Any]? {
        func host(_ system: [String: Any]) -> String { (system["host"] as? String ?? "").lowercased() }
        #if os(macOS)
        #if arch(arm64)
        let preferences = ["arm64-apple-darwin", "aarch64-apple-darwin", "x86_64-apple-darwin", "i386-apple-darwin"]
        #else
        let preferences = ["x86_64-apple-darwin", "i386-apple-darwin"]
        #endif
        #else
        #if arch(arm64)
        let preferences = ["aarch64-linux-gnu", "aarch64-pc-linux-gnu"]
        #else
        let preferences = ["x86_64-linux-gnu", "x86_64-pc-linux-gnu"]
        #endif
        #endif
        for preference in preferences {
            if let system = systems.first(where: { host($0).hasPrefix(preference) }) { return system }
        }
        return nil
    }

    private static func download(_ archive: Archive, to file: URL, received: @escaping (Int) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: archive.url)
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
            throw InstallError.download("\(archive.url.lastPathComponent): HTTP \(status)")
        }
        var data = Data()
        data.reserveCapacity(archive.size)
        var buffer = [UInt8]()
        buffer.reserveCapacity(1 << 16)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count == 1 << 16 {
                data.append(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                received(data.count)
            }
        }
        data.append(contentsOf: buffer)
        received(data.count)
        try verify(data, archive)
        try data.write(to: file)
    }

    static func verify(_ data: Data, _ archive: Archive) throws {
        #if canImport(CryptoKit)
        let parts = archive.checksum.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0].uppercased() == "SHA-256" else { return }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == parts[1].lowercased() else { throw InstallError.checksum(archive.url.lastPathComponent) }
        #endif
    }

    /// Unpacks an archive (.tar.bz2, .tar.gz, .zip) with the system's tar, and finds the folder holding `marker`
    private static func unpack(_ file: URL, in folder: URL, containing marker: String) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", file.path, "-C", folder.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        let errors = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.unpack(file.lastPathComponent + ": " + String(decoding: errors, as: UTF8.self))
        }
        var queue = [folder]
        for _ in 0..<4 {
            var next: [URL] = []
            for candidate in queue {
                if fileManager.fileExists(atPath: candidate.appendingPathComponent(marker).path) { return candidate }
                let children = (try? fileManager.contentsOfDirectory(at: candidate, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                next += children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            }
            queue = next
        }
        throw InstallError.unpack("\(file.lastPathComponent): no \(marker) inside")
    }
}
