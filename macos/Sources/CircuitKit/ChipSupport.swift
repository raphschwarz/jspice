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
    public struct Progress: Sendable, Equatable {
        public enum Stage: Sendable, Equatable {
            case downloading
            case unpacking
            case installed
        }

        /// 0 to 1
        public var fraction: Double
        public var message: String
        public var stage: Stage

        public init(fraction: Double, message: String, stage: Stage = .downloading) {
            self.fraction = fraction
            self.message = message
            self.stage = stage
        }
    }

    /// Where a family's chip support is, for a list of families to show
    public enum State: Sendable, Equatable {
        case notInstalled
        case downloading(fraction: Double, message: String)
        case unpacking(message: String)
        /// What is installed, in words: JSpice's install, or an Arduino IDE's toolchain
        case installed(String)
        case failed(String)

        public var isBusy: Bool {
            switch self {
            case .downloading, .unpacking: return true
            case .notInstalled, .installed, .failed: return false
            }
        }

        /// The state a progress report puts an install in
        public init(_ progress: Progress) {
            switch progress.stage {
            case .downloading: self = .downloading(fraction: progress.fraction, message: progress.message)
            case .unpacking: self = .unpacking(message: progress.message)
            case .installed: self = .installed(progress.message)
            }
        }
    }

    /// The family's state as it is on disk: installed by JSpice, available from an Arduino IDE, or not installed
    public static func installedState(_ family: ChipFamily) -> State {
        if let versions = installedVersions(family) {
            return .installed("Installed: \(family.compilerFolder) \(versions.compiler), \(family.coreName) \(versions.core)")
        }
        if isAvailable(family) { return .installed("Using the toolchain of an Arduino IDE installed on this Mac") }
        return .notInstalled
    }

    public enum InstallError: Error, CustomStringConvertible {
        case index(String)
        case download(String)
        case checksum(String)
        case unpack(String)
        /// An archive whose checksum could not be checked, so it was not installed
        case unverifiable(String)

        public var description: String {
            switch self {
            case .index(let text): return "The package index: \(text)"
            case .download(let text): return "Download failed: \(text)"
            case .checksum(let text): return "\(text) did not arrive intact (its checksum differs); try again"
            case .unverifiable(let text): return "\(text), so it was not installed"
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

    /// Downloads and unpacks the family's compiler and core; `progress` is called along the way (on any thread).
    /// Cancelling the task stops the download or the unpacking (it throws CancellationError) and leaves what was
    /// installed before as it was; the partial files are deleted.
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
            try Task.checkCancellation()
            let file = staging.appendingPathComponent(archive.url.lastPathComponent)
            let start = done
            try await download(archive, to: file) { received in
                let fraction = min((start + Double(received)) / total, 1) * 0.9
                let megabytes = Double(received) / 1_048_576
                let of = archive.size > 0 ? String(format: " of %.0f", Double(archive.size) / 1_048_576) : ""
                progress(Progress(fraction: fraction,
                                  message: "Downloading \(archive.name) \(archive.version): \(String(format: "%.0f", megabytes))\(of) MB"))
            }
            done += Double(archive.size)
            files.append(file)
        }

        try Task.checkCancellation()
        progress(Progress(fraction: 0.92, message: "Unpacking \(compiler.name)…", stage: .unpacking))
        let compilerFolder = try await unpack(files[0], in: staging.appendingPathComponent("compiler"), containing: family.compilerMarker)
        progress(Progress(fraction: 0.96, message: "Unpacking \(family.coreName)…", stage: .unpacking))
        let coreFolder = try await unpack(files[1], in: staging.appendingPathComponent("core"), containing: family.coreMarker)
        try Task.checkCancellation()

        // put together beside the install folder, then swapped in, so that the old install stays whole until the new
        // one is
        let destination = installFolder(for: family)
        let assembling = supportFolder.appendingPathComponent(".\(family.rawValue)-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: assembling) }
        try fileManager.createDirectory(at: assembling.appendingPathComponent(family.compilerFolder), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: assembling.appendingPathComponent("core"), withIntermediateDirectories: true)
        try fileManager.moveItem(at: compilerFolder,
                                 to: assembling.appendingPathComponent("\(family.compilerFolder)/\(compiler.version)"))
        try fileManager.moveItem(at: coreFolder, to: assembling.appendingPathComponent("core/\(core.version)"))
        let manifest = try JSONSerialization.data(withJSONObject: ["compiler": compiler.version, "core": core.version])
        try manifest.write(to: assembling.appendingPathComponent("installed.json"))
        try Task.checkCancellation()
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: assembling, to: destination)
        progress(Progress(fraction: 1, message: "Installed: \(family.compilerFolder) \(compiler.version), \(family.coreName) \(core.version)",
                          stage: .installed))
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
        guard let platform = avr.first, let core = try archive(platform, name: "Arduino AVR core") else {
            throw InstallError.index("no Arduino AVR core")
        }
        let dependency = (platform["toolsDependencies"] as? [[String: Any]])?.first { $0["name"] as? String == "avr-gcc" }
        guard let version = dependency?["version"] as? String,
              let tool = tools.first(where: { $0["name"] as? String == "avr-gcc" && $0["version"] as? String == version }),
              let systems = tool["systems"] as? [[String: Any]] else { throw InstallError.index("no avr-gcc for the AVR core") }
        guard let system = bestSystem(systems), let compiler = try archive(system, name: "avr-gcc", version: version) else {
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
              let core = try archive(platform, name: "arduino-pico") else { throw InstallError.index("no arduino-pico") }
        let dependency = (platform["toolsDependencies"] as? [[String: Any]])?.first { $0["name"] as? String == "pqt-gcc" }
        guard let version = dependency?["version"] as? String,
              let tool = tools.first(where: { $0["name"] as? String == "pqt-gcc" && $0["version"] as? String == version }),
              let systems = tool["systems"] as? [[String: Any]] else { throw InstallError.index("no gcc for arduino-pico") }
        guard let system = bestSystem(systems), let compiler = try archive(system, name: "arm-none-eabi-gcc", version: version) else {
            throw InstallError.index("no arm-none-eabi-gcc \(version) for this computer")
        }
        return (core, compiler)
    }

    /// An index entry's archive; nil where it has no URL or checksum. Only an https URL is taken: the checksum beside
    /// it is all that vouches for the archive, and it came over https with the index.
    static func archive(_ entry: [String: Any], name: String, version: String? = nil) throws -> Archive? {
        guard let urlText = entry["url"] as? String, let url = URL(string: urlText),
              let checksum = entry["checksum"] as? String else { return nil }
        guard url.scheme?.lowercased() == "https" else {
            throw InstallError.index("\(name)'s archive is not served over https (\(urlText)); it was not downloaded")
        }
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

    /// Streams the archive to `file` (a megabyte at a time, so a 240 MB download is never held in memory), then checks
    /// the file against the index's checksum; a file that does not match is deleted and refused
    private static func download(_ archive: Archive, to file: URL, received: (Int) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: archive.url)
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
            throw InstallError.download("\(archive.url.lastPathComponent): HTTP \(status)")
        }
        let fileManager = FileManager.default
        guard fileManager.createFile(atPath: file.path, contents: nil) else {
            throw InstallError.download("cannot write \(file.path)")
        }
        var verified = false
        defer { if !verified { try? fileManager.removeItem(at: file) } }
        let handle = try FileHandle(forWritingTo: file)
        // (an archive far larger than the index says is not what it lists)
        let limit = archive.size > 0 ? archive.size * 2 + (16 << 20) : Int.max
        var count = 0
        var buffer = [UInt8]()
        let chunk = 1 << 20
        buffer.reserveCapacity(chunk)
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count == chunk {
                    try Task.checkCancellation()
                    try handle.write(contentsOf: buffer)
                    count += buffer.count
                    buffer.removeAll(keepingCapacity: true)
                    guard count <= limit else {
                        throw InstallError.download("\(archive.url.lastPathComponent) is larger than the package index says")
                    }
                    received(count)
                }
            }
            try handle.write(contentsOf: buffer)
            count += buffer.count
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        received(count)
        try Task.checkCancellation()
        // the file as written, mapped rather than read into memory
        try verify(try Data(contentsOf: file, options: .alwaysMapped), archive)
        verified = true
    }

    /// The archive's bytes against the index's checksum, "SHA-256:" and 64 hex digits (as both Arduino's and
    /// arduino-pico's indexes give every archive). An archive whose checksum is in any other form (the index format's
    /// SHA-1 or MD5, or none JSpice can read), or that cannot be hashed here, is not installed: unchecked, it could be
    /// anything.
    static func verify(_ data: Data, _ archive: Archive) throws {
        let parts = archive.checksum.split(separator: ":", maxSplits: 1)
        let expected = parts.count == 2 ? parts[1].lowercased() : ""
        guard parts.count == 2, parts[0].uppercased() == "SHA-256", expected.count == 64,
              expected.allSatisfy({ $0.isHexDigit }) else {
            throw InstallError.unverifiable("\(archive.url.lastPathComponent)'s checksum in the package index (\"\(archive.checksum)\") is not a SHA-256")
        }
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { throw InstallError.checksum(archive.url.lastPathComponent) }
        #else
        throw InstallError.unverifiable("\(archive.url.lastPathComponent) cannot be checked: SHA-256 is not available on this system")
        #endif
    }

    /// Unpacks an archive (.tar.bz2, .tar.gz, .zip) with the system's tar, and finds the folder holding `marker`
    /// (cancelling the task stops tar)
    private static func unpack(_ file: URL, in folder: URL, containing marker: String) async throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", file.path, "-C", folder.path]
        let pipe = Pipe()
        process.standardError = pipe
        let run = CancellableProcess(process)
        let errors = try await withTaskCancellationHandler {
            try run.start()
            let errors = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return errors
        } onCancel: {
            run.cancel()
        }
        try Task.checkCancellation()
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

/// A process that a task's cancellation can stop, whether it comes before the process starts or while it runs
final class CancellableProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var cancelled = false
    private var started = false

    init(_ process: Process) { self.process = process }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
        started = true
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if started && process.isRunning { process.terminate() }
    }
}
