import Foundation

/// What compiles Arduino sketches for the ATmega328P: avr-gcc (with avr-libc) and the Arduino AVR core.
///
/// JSpice installs both from Arduino's own package index (see `ChipSupport`), into its Application Support folder; an
/// existing Arduino IDE installation, or avr-gcc from Homebrew together with an installed core, works as well.
public struct AVRToolchain: Sendable, Equatable {
    /// The folder with bin/avr-gcc, bin/avr-g++, bin/avr-ar and bin/avr-objcopy
    public let compiler: URL
    /// The Arduino AVR core: the folder with cores/arduino, variants/standard and libraries
    public let core: URL

    public init(compiler: URL, core: URL) {
        self.compiler = compiler
        self.core = core
    }

    func tool(_ name: String) -> URL { compiler.appendingPathComponent("bin").appendingPathComponent(name) }

    /// The first complete toolchain found: the one JSpice installed, an Arduino IDE's, or Homebrew's avr-gcc with a core.
    /// JSPICE_AVR_GCC and JSPICE_ARDUINO_CORE (folders as above) override the search.
    public static func find() -> AVRToolchain? {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        func compilers(in folder: URL) -> [URL] {
            guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return [] }
            return names.sorted(by: newerFirst).map { folder.appendingPathComponent($0) }
                .filter { fileManager.isExecutableFile(atPath: $0.appendingPathComponent("bin/avr-gcc").path) }
        }
        func cores(in folder: URL) -> [URL] {
            guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return [] }
            return names.sorted(by: newerFirst).map { folder.appendingPathComponent($0) }
                .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("cores/arduino/Arduino.h").path) }
        }
        var compilerCandidates: [URL] = []
        var coreCandidates: [URL] = []
        if let path = environment["JSPICE_AVR_GCC"] { compilerCandidates.append(URL(fileURLWithPath: path)) }
        if let path = environment["JSPICE_ARDUINO_CORE"] { coreCandidates.append(URL(fileURLWithPath: path)) }
        let installed = ChipSupport.installFolder(for: .avr)
        compilerCandidates += compilers(in: installed.appendingPathComponent("avr-gcc"))
        coreCandidates += cores(in: installed.appendingPathComponent("core"))
        let home = fileManager.homeDirectoryForCurrentUser
        for arduino in ["Library/Arduino15", ".arduino15"] {
            let packages = home.appendingPathComponent(arduino).appendingPathComponent("packages/arduino")
            compilerCandidates += compilers(in: packages.appendingPathComponent("tools/avr-gcc"))
            coreCandidates += cores(in: packages.appendingPathComponent("hardware/avr"))
        }
        for prefix in ["/opt/homebrew", "/usr/local", "/usr"] {
            let url = URL(fileURLWithPath: prefix)
            if fileManager.isExecutableFile(atPath: url.appendingPathComponent("bin/avr-gcc").path) { compilerCandidates.append(url) }
        }
        guard let compiler = compilerCandidates.first(where: { fileManager.isExecutableFile(atPath: $0.appendingPathComponent("bin/avr-gcc").path) }),
              let core = coreCandidates.first(where: { fileManager.fileExists(atPath: $0.appendingPathComponent("cores/arduino/Arduino.h").path) })
        else { return nil }
        return AVRToolchain(compiler: compiler, core: core)
    }

    /// Version folder names, newest first ("1.8.6" before "1.8.10" is wrong, so compare number by number)
    static func newerFirst(_ a: String, _ b: String) -> Bool {
        let x = a.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let y = b.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        for (p, q) in zip(x, y) where p != q { return p > q }
        return x.count > y.count
    }
}

/// Compiles Arduino sketches into ATmega328P firmware, the way the Arduino IDE does for an Uno
public enum SketchBuilder {
    public struct Diagnostic: Sendable, Equatable, CustomStringConvertible {
        public let line: Int
        public let column: Int
        public let isError: Bool
        public let message: String

        public var description: String { "\(line):\(column): \(isError ? "error" : "warning"): \(message)" }
    }

    public struct Result: Sendable {
        /// The flash image, nil when the build failed
        public let firmware: Data?
        public let diagnostics: [Diagnostic]
        /// Everything the compiler said
        public let log: String
        public var succeeded: Bool { firmware != nil }
        public var errors: [Diagnostic] { diagnostics.filter(\.isError) }
    }

    public enum BuildError: Error, CustomStringConvertible {
        case toolFailed(String)

        public var description: String {
            switch self {
            case .toolFailed(let text): return text
            }
        }
    }

    static let flashSize = 32_256  // 32 KB less the Uno's bootloader

    static func definitions(_ toolchain: AVRToolchain) -> [String] {
        ["-mmcu=atmega328p", "-DF_CPU=16000000L", "-DARDUINO=10819", "-DARDUINO_AVR_UNO", "-DARDUINO_ARCH_AVR",
         "-I" + toolchain.core.appendingPathComponent("cores/arduino").path,
         "-I" + toolchain.core.appendingPathComponent("variants/standard").path,
         "-Os", "-w", "-ffunction-sections", "-fdata-sections"]
    }

    static let cppFlags = ["-std=gnu++11", "-fpermissive", "-fno-exceptions", "-fno-threadsafe-statics"]

    /// Builds `source` (an Arduino sketch); the result says what went wrong if it did not compile
    public static func build(_ source: String, toolchain: AVRToolchain) -> Result {
        do {
            return try buildOrThrow(source, toolchain: toolchain)
        } catch {
            return Result(firmware: nil, diagnostics: [], log: "\(error)")
        }
    }

    private static func buildOrThrow(_ source: String, toolchain: AVRToolchain) throws -> Result {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("jspice-sketch-\(UUID().uuidString)")
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        let core = try coreArchive(toolchain)
        var includes: [String] = []
        var librarySources: [URL] = []
        for library in libraries(usedBy: source, toolchain: toolchain) {
            includes.append("-I" + library.path)
            librarySources += sources(in: library)
        }
        let cpp = work.appendingPathComponent("sketch.cpp")
        try preprocess(source).write(to: cpp, atomically: true, encoding: .utf8)

        var log = ""
        var objects: [String] = []
        let sketchObject = work.appendingPathComponent("sketch.o")
        var sketchArguments = ["-c"]
        sketchArguments += cppFlags
        sketchArguments += definitions(toolchain)
        sketchArguments += includes
        sketchArguments += [cpp.path, "-o", sketchObject.path]
        let compile = try run(toolchain.tool("avr-g++"), sketchArguments, in: work)
        log += compile.output
        let diagnostics = parseDiagnostics(compile.output)
        guard compile.status == 0 else { return Result(firmware: nil, diagnostics: diagnostics, log: log) }
        objects.append(sketchObject.path)
        for (k, file) in librarySources.enumerated() {
            let object = work.appendingPathComponent("library\(k).o")
            let isC = file.pathExtension == "c"
            var arguments = ["-c"]
            arguments += isC ? ["-std=gnu11"] : cppFlags
            arguments += definitions(toolchain)
            arguments += includes
            arguments += [file.path, "-o", object.path]
            let result = try run(toolchain.tool(isC ? "avr-gcc" : "avr-g++"), arguments, in: work)
            log += result.output
            guard result.status == 0 else { return Result(firmware: nil, diagnostics: diagnostics, log: log) }
            objects.append(object.path)
        }
        let elf = work.appendingPathComponent("sketch.elf")
        var linkArguments = ["-mmcu=atmega328p", "-Os", "-Wl,--gc-sections", "-o", elf.path]
        linkArguments += objects
        linkArguments += [core.path, "-lm"]
        let link = try run(toolchain.tool("avr-gcc"), linkArguments, in: work)
        log += link.output
        guard link.status == 0 else {
            return Result(firmware: nil, diagnostics: diagnostics + [Diagnostic(line: 0, column: 0, isError: true,
                                                                                 message: "linking failed: " + link.output)], log: log)
        }
        let image = work.appendingPathComponent("sketch.bin")
        let copy = try run(toolchain.tool("avr-objcopy"), ["-O", "binary", "-R", ".eeprom", elf.path, image.path], in: work)
        guard copy.status == 0, let firmware = fileManager.contents(atPath: image.path) else {
            return Result(firmware: nil, diagnostics: diagnostics, log: log + copy.output)
        }
        guard firmware.count <= flashSize else {
            return Result(firmware: nil, diagnostics: diagnostics + [Diagnostic(
                line: 0, column: 0, isError: true,
                message: "the sketch takes \(firmware.count) bytes; the ATmega328P has room for \(flashSize)")], log: log)
        }
        return Result(firmware: firmware, diagnostics: diagnostics, log: log)
    }

    // MARK: - Sketch to C++

    private static let keywords: Set<String> = ["if", "for", "while", "switch", "return", "else", "do", "sizeof"]

    /// The sketch as C++: Arduino.h included, and every top-level function declared before the first one is defined, so
    /// functions can be used before their definitions as in the Arduino IDE. #line keeps compiler messages on the
    /// sketch's own line numbers.
    public static func preprocess(_ source: String) -> String {
        let (prototypes, first) = self.prototypes(source)
        let characters = Array(source)
        let head = String(characters[..<first])
        let tail = String(characters[first...])
        let line = head.filter { $0 == "\n" }.count + 1
        return "#include <Arduino.h>\n#line 1 \"sketch.ino\"\n" + head + prototypes.joined(separator: "\n")
            + "\n#line \(line) \"sketch.ino\"\n" + tail
    }

    /// Comments, string and character literals and preprocessor lines turned into spaces (newlines kept)
    static func blank(_ text: [Character]) -> [Character] {
        var out = text
        var i = 0
        let n = text.count
        func clear(_ from: Int, _ to: Int) {
            for k in from..<min(to, n) where out[k] != "\n" { out[k] = " " }
        }
        var lineStart = true
        while i < n {
            let c = text[i]
            if c == "/" && i + 1 < n && text[i + 1] == "/" {
                var j = i
                while j < n && text[j] != "\n" { j += 1 }
                clear(i, j)
                i = j
            } else if c == "/" && i + 1 < n && text[i + 1] == "*" {
                var j = i + 2
                while j + 1 < n && !(text[j] == "*" && text[j + 1] == "/") { j += 1 }
                j = min(j + 2, n)
                clear(i, j)
                i = j
            } else if c == "\"" || c == "'" {
                var j = i + 1
                while j < n && text[j] != c && text[j] != "\n" { j += text[j] == "\\" ? 2 : 1 }
                j = min(j + 1, n)
                clear(i, j)
                i = j
            } else if c == "#" && lineStart {
                var j = i
                while j < n {
                    if text[j] == "\n" {
                        if j > 0 && text[j - 1] == "\\" {
                            j += 1
                            continue
                        }
                        break
                    }
                    j += 1
                }
                clear(i, j)
                i = j
            } else {
                if c == "\n" {
                    lineStart = true
                } else if c != " " && c != "\t" {
                    lineStart = false
                }
                i += 1
                continue
            }
            lineStart = false
        }
        return out
    }

    /// Prototypes of the sketch's top-level functions, and the offset (in characters) of the first definition
    static func prototypes(_ source: String) -> ([String], Int) {
        let original = Array(source)
        let text = blank(original)
        var found: [String] = []
        var first: Int?
        var depth = 0
        var start = 0
        let header = try? NSRegularExpression(
            pattern: #"^([A-Za-z_][\w\s\*&:<>,]*?[\s\*&]+)([A-Za-z_]\w*)\s*\(([^()]*)\)\s*(const\s*)?$"#,
            options: [.dotMatchesLineSeparators])
        let declaration = try? NSRegularExpression(pattern: #"\b(struct|class|enum|union|namespace|typedef)\b"#)
        for (i, c) in text.enumerated() {
            if c == "{" {
                if depth == 0 {
                    let chunk = String(text[start..<i])
                    let words = chunk.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
                    let joined = words.joined(separator: " ")
                    let range = NSRange(joined.startIndex..., in: joined)
                    if let match = header?.firstMatch(in: joined, range: range),
                       declaration?.firstMatch(in: joined, range: range) == nil, !joined.contains("="),
                       let typeRange = Range(match.range(at: 1), in: joined),
                       let nameRange = Range(match.range(at: 2), in: joined),
                       let parametersRange = Range(match.range(at: 3), in: joined),
                       !keywords.contains(String(joined[nameRange])) {
                        let type = joined[typeRange].split(separator: " ").joined(separator: " ")
                        let parameters = joined[parametersRange].trimmingCharacters(in: .whitespaces)
                        found.append("\(type) \(joined[nameRange])(\(parameters));")
                        if first == nil {
                            var offset = start
                            while offset < i && text[offset].isWhitespace { offset += 1 }
                            first = offset
                        }
                    }
                }
                depth += 1
            } else if c == "}" {
                depth = max(0, depth - 1)
                if depth == 0 { start = i + 1 }
            } else if c == ";" && depth == 0 {
                start = i + 1
            }
        }
        return (found, first ?? original.count)
    }

    // MARK: - Libraries and the core

    /// The core's bundled libraries (EEPROM, SPI, Wire, SoftwareSerial…) whose headers the sketch includes: their
    /// source folders
    static func libraries(usedBy source: String, toolchain: AVRToolchain) -> [URL] {
        let pattern = try? NSRegularExpression(pattern: #"#\s*include\s*[<"]([^>"]+)\.h[>"]"#)
        let range = NSRange(source.startIndex..., in: source)
        let headers = Set((pattern?.matches(in: source, range: range) ?? []).compactMap { match -> String? in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        })
        let folder = toolchain.core.appendingPathComponent("libraries")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var result: [URL] = []
        for name in names.sorted() {
            let src = folder.appendingPathComponent(name).appendingPathComponent("src")
            if headers.contains(where: { FileManager.default.fileExists(atPath: src.appendingPathComponent($0 + ".h").path) }) {
                result.append(src)
            }
        }
        return result
    }

    static func sources(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { ["c", "cpp", "S"].contains($0.pathExtension) }
            .sorted { $0.path < $1.path }
    }

    /// The Arduino core compiled once into an archive, kept in the caches folder for later builds
    static func coreArchive(_ toolchain: AVRToolchain) throws -> URL {
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        let key = String((toolchain.compiler.path + "|" + toolchain.core.path).hashValueStable, radix: 16)
        let folder = caches.appendingPathComponent("JSpice/arduino-core-\(key)")
        let archive = folder.appendingPathComponent("core.a")
        if fileManager.fileExists(atPath: archive.path) { return archive }
        try? fileManager.removeItem(at: folder)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var objects: [String] = []
        for (k, file) in sources(in: toolchain.core.appendingPathComponent("cores/arduino")).enumerated() {
            let object = folder.appendingPathComponent("\(k)-\(file.lastPathComponent).o")
            var arguments = ["-c"]
            let tool: String
            switch file.pathExtension {
            case "c":
                tool = "avr-gcc"
                arguments.append("-std=gnu11")
            case "S":
                tool = "avr-gcc"
                arguments += ["-x", "assembler-with-cpp"]
            default:
                tool = "avr-g++"
                arguments += cppFlags
            }
            arguments += definitions(toolchain)
            arguments += [file.path, "-o", object.path]
            let result = try run(toolchain.tool(tool), arguments, in: folder)
            guard result.status == 0 else { throw BuildError.toolFailed("compiling the Arduino core failed:\n" + result.output) }
            objects.append(object.path)
        }
        let partial = folder.appendingPathComponent("core.partial.a")
        var archiveArguments = ["rcs", partial.path]
        archiveArguments += objects
        let ar = try run(toolchain.tool("avr-ar"), archiveArguments, in: folder)
        guard ar.status == 0 else { throw BuildError.toolFailed("archiving the Arduino core failed:\n" + ar.output) }
        try fileManager.moveItem(at: partial, to: archive)
        return archive
    }

    // MARK: - Running the tools

    struct ToolResult {
        let status: Int32
        let output: String
    }

    static func run(_ tool: URL, _ arguments: [String], in folder: URL) throws -> ToolResult {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = folder
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw BuildError.toolFailed("cannot run \(tool.path): \(error.localizedDescription)"
                                        + " (on a Mac with Apple silicon, the compiler may need Rosetta: softwareupdate --install-rosetta)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ToolResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// "sketch.ino:12:5: error: 'foo' was not declared in this scope"
    static func parseDiagnostics(_ output: String) -> [Diagnostic] {
        let pattern = try? NSRegularExpression(pattern: #"sketch\.ino:(\d+):(\d+): (fatal error|error|warning): (.*)"#)
        var result: [Diagnostic] = []
        for line in output.split(separator: "\n") {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = pattern?.firstMatch(in: text, range: range),
                  let lineRange = Range(match.range(at: 1), in: text), let columnRange = Range(match.range(at: 2), in: text),
                  let kindRange = Range(match.range(at: 3), in: text), let messageRange = Range(match.range(at: 4), in: text)
            else { continue }
            result.append(Diagnostic(line: Int(text[lineRange]) ?? 0, column: Int(text[columnRange]) ?? 0,
                                     isError: !text[kindRange].hasPrefix("warning"), message: String(text[messageRange])))
        }
        return result
    }
}

extension String {
    /// A hash that is the same from one run to the next (Swift's own hashValue is seeded per process)
    var hashValueStable: UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
