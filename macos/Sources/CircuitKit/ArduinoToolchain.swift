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

/// Compiles Arduino sketches into firmware for an AVR board (Uno, Mega 2560, ATtiny85), the way the Arduino IDE does
public enum SketchBuilder {
    /// An error or warning on a line of the sketch itself (messages about the core's or a library's files, and the
    /// linker's, are summed up in `Result.problem` instead)
    public struct Diagnostic: Sendable, Equatable, CustomStringConvertible {
        /// The sketch's line, from 1
        public let line: Int
        public let column: Int
        public let isError: Bool
        public let message: String

        public init(line: Int, column: Int, isError: Bool, message: String) {
            self.line = line
            self.column = column
            self.isError = isError
            self.message = message
        }

        public var description: String { "\(line):\(column): \(isError ? "error" : "warning"): \(message)" }
    }

    public struct Result: Sendable {
        /// The flash image, nil when the build failed
        public let firmware: Data?
        /// Errors and warnings on the sketch's own lines
        public let diagnostics: [Diagnostic]
        /// Everything the compiler said
        public let log: String
        /// Why the build failed when no line of the sketch says: the core or a library did not compile, linking failed,
        /// the sketch does not fit, a header is not available, the compiler could not be run, or the build was cancelled
        public let problem: String?
        /// True when the build was cancelled (`problem` says so)
        public let wasCancelled: Bool

        public init(firmware: Data?, diagnostics: [Diagnostic], log: String, problem: String? = nil, wasCancelled: Bool = false) {
            self.firmware = firmware
            self.diagnostics = diagnostics
            self.log = log
            self.problem = problem
            self.wasCancelled = wasCancelled
        }

        public var succeeded: Bool { firmware != nil }
        public var errors: [Diagnostic] { diagnostics.filter(\.isError) }
        public var warnings: [Diagnostic] { diagnostics.filter { !$0.isError } }
    }

    public enum BuildError: Error, CustomStringConvertible {
        case toolFailed(String)
        /// A file of the core did not compile: the core's name, the file's, and what the compiler said
        case coreFailed(core: String, file: String, output: String)
        /// A tool ran longer than it may
        case timedOut(tool: String, seconds: Int)
        case cancelled

        public var description: String {
            switch self {
            case .toolFailed(let text): return text
            case .coreFailed(let core, let file, let output): return "compiling \(core) failed (\(file)):\n" + output
            case .timedOut(let tool, let seconds): return "\(tool) ran for more than \(seconds) seconds and was stopped"
            case .cancelled: return "Cancelled"
            }
        }

        /// One line for the inspector
        public var summary: String {
            switch self {
            case .coreFailed(let core, let file, let output):
                let first = SketchBuilder.firstError(in: output).map { ": " + $0 } ?? ""
                return "\(core) did not compile (\(file))\(first). Reinstalling it in Chip Support may help."
            case .toolFailed(let text): return text.split(separator: "\n").first.map(String.init) ?? text
            default: return description
            }
        }
    }

    /// How far a build is, for its progress line
    public struct BuildProgress: Sendable, Equatable {
        public enum Phase: Sendable, Equatable {
            /// The core, compiled once for each board and toolchain: files done of all
            case core(done: Int, total: Int)
            /// The libraries the sketch includes
            case libraries(done: Int, total: Int)
            case sketch
            case linking
        }

        public let phase: Phase
        /// The core's name, as `ChipFamily.coreName` gives it
        public let coreName: String

        public init(_ phase: Phase, coreName: String) {
            self.phase = phase
            self.coreName = coreName
        }

        public var message: String {
            switch phase {
            case .core(let done, let total):
                return "Compiling \(coreName) (first build only): \(done) of \(total) files"
            case .libraries(let done, let total): return "Compiling the libraries: \(done) of \(total) files"
            case .sketch: return "Compiling the sketch"
            case .linking: return "Linking"
            }
        }

        /// 0 to 1 within the phase, where it has steps
        public var fraction: Double? {
            switch phase {
            case .core(let done, let total), .libraries(let done, let total): return total > 0 ? Double(done) / Double(total) : nil
            case .sketch, .linking: return nil
            }
        }
    }

    /// Follows a build and stops it: `progress` hears each step (on the building thread), `cancel()` stops the tool
    /// running and the build ends with `Result.wasCancelled`
    public final class BuildMonitor: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var running: Process?
        private let progress: @Sendable (BuildProgress) -> Void

        public init(progress: @escaping @Sendable (BuildProgress) -> Void = { _ in }) {
            self.progress = progress
        }

        public var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        public func cancel() {
            lock.lock()
            cancelled = true
            let process = running
            lock.unlock()
            if let process, process.isRunning { process.terminate() }
        }

        func report(_ step: BuildProgress) { progress(step) }

        func checkCancelled() throws {
            if isCancelled { throw BuildError.cancelled }
        }

        /// Starts `process` unless the build is cancelled
        func launch(_ process: Process) throws {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { throw BuildError.cancelled }
            try process.run()
            running = process
        }

        func finished() {
            lock.lock()
            running = nil
            lock.unlock()
        }
    }

    /// avr-gcc's name for the chip a sketch is built for: the board's, or the one its part is set to
    static func mcu(_ board: Board, _ chip: AVRVariant?) -> String { chip.map { $0.name.lowercased() } ?? board.mcu }

    static func definitions(_ toolchain: AVRToolchain, _ board: Board, _ chip: AVRVariant? = nil) throws -> [String] {
        ["-mmcu=" + mcu(board, chip), "-DF_CPU=\(Int(chip?.clock ?? board.clock))L", "-DARDUINO=10819", board.boardDefine,
         "-DARDUINO_ARCH_AVR",
         "-I" + toolchain.core.appendingPathComponent("cores/arduino").path,
         "-I" + (try variantFolder(toolchain, board)).path,
         "-Os", "-w", "-ffunction-sections", "-fdata-sections"]
    }

    /// The board's pin map: the core's own (variants/standard, variants/mega), or JSpice's for the ATtiny85, written to
    /// the caches folder
    static func variantFolder(_ toolchain: AVRToolchain, _ board: Board) throws -> URL {
        if let name = board.coreVariant { return toolchain.core.appendingPathComponent("variants").appendingPathComponent(name) }
        let folder = cachesFolder().appendingPathComponent("variants/\(board.rawValue)")
        let header = folder.appendingPathComponent("pins_arduino.h")
        if (try? String(contentsOf: header, encoding: .utf8)) != board.variantHeader {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try board.variantHeader.write(to: header, atomically: true, encoding: .utf8)
        }
        return folder
    }

    static func cachesFolder() -> URL {
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return caches.appendingPathComponent("JSpice")
    }

    static let cppFlags = ["-std=gnu++11", "-fpermissive", "-fno-exceptions", "-fno-threadsafe-statics"]

    /// Builds `source` (an Arduino sketch) for `board`, or for the chip its part is set to (an ATmega168 or 88 in the
    /// Uno's place, a clock other than its 16 MHz); the result says what went wrong if it did not compile
    public static func build(_ source: String, board: Board = .uno, chip: AVRVariant? = nil, toolchain: AVRToolchain,
                             monitor: BuildMonitor? = nil) -> Result {
        guarded { try buildOrThrow(source, board: board, chip: chip, toolchain: toolchain, monitor: monitor) }
    }

    /// A build's result, or the failure that stopped it as a one-line problem
    static func guarded(_ build: () throws -> Result) -> Result {
        do {
            return try build()
        } catch BuildError.cancelled {
            return Result(firmware: nil, diagnostics: [], log: "Cancelled", problem: "Cancelled", wasCancelled: true)
        } catch let error as BuildError {
            return Result(firmware: nil, diagnostics: [], log: error.description, problem: error.summary)
        } catch {
            return Result(firmware: nil, diagnostics: [], log: "\(error)", problem: "The build failed: \(error.localizedDescription)")
        }
    }

    /// The sketch's own file is compiled with gcc's warnings on (-Wall), so that they can be shown on its lines; the
    /// core and libraries stay quiet (-w), as in the Arduino IDE
    static func sketchFlags(_ definitions: [String]) -> [String] { definitions.filter { $0 != "-w" } + ["-Wall"] }

    private static func buildOrThrow(_ source: String, board: Board, chip: AVRVariant?, toolchain: AVRToolchain,
                                     monitor: BuildMonitor?) throws -> Result {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("jspice-sketch-\(UUID().uuidString)")
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }
        let coreName = ChipFamily.avr.coreName
        let available = libraryNames(in: toolchain.core.appendingPathComponent("libraries"))

        let core = try coreArchive(toolchain, board, chip, monitor: monitor)
        let definitions = try self.definitions(toolchain, board, chip)
        var includes: [String] = []
        var librarySources: [URL] = []
        for library in libraries(usedBy: source, toolchain: toolchain) {
            includes.append("-I" + library.path)
            librarySources += sources(in: library)
        }
        let cpp = work.appendingPathComponent("sketch.cpp")
        try preprocess(source).write(to: cpp, atomically: true, encoding: .utf8)

        try monitor?.checkCancelled()
        monitor?.report(BuildProgress(.sketch, coreName: coreName))
        var log = ""
        var objects: [String] = []
        let sketchObject = work.appendingPathComponent("sketch.o")
        var sketchArguments = ["-c"]
        sketchArguments += cppFlags
        sketchArguments += sketchFlags(definitions)
        sketchArguments += includes
        sketchArguments += [cpp.path, "-o", sketchObject.path]
        let compile = try run(toolchain.tool("avr-g++"), sketchArguments, in: work, monitor: monitor)
        log += compile.output
        let diagnostics = parseDiagnostics(compile.output, libraries: available)
        guard compile.status == 0 else { return failed(diagnostics, log: log, libraries: available) }
        objects.append(sketchObject.path)
        for (k, file) in librarySources.enumerated() {
            try monitor?.checkCancelled()
            monitor?.report(BuildProgress(.libraries(done: k, total: librarySources.count), coreName: coreName))
            let object = work.appendingPathComponent("library\(k).o")
            let isC = file.pathExtension == "c"
            var arguments = ["-c"]
            arguments += isC ? ["-std=gnu11"] : cppFlags
            arguments += definitions
            arguments += includes
            arguments += [file.path, "-o", object.path]
            let result = try run(toolchain.tool(isC ? "avr-gcc" : "avr-g++"), arguments, in: work, monitor: monitor)
            log += result.output
            guard result.status == 0 else { return failed(diagnostics, log: log, libraries: available) }
            objects.append(object.path)
        }
        try monitor?.checkCancelled()
        monitor?.report(BuildProgress(.linking, coreName: coreName))
        let elf = work.appendingPathComponent("sketch.elf")
        var linkArguments = ["-mmcu=" + mcu(board, chip), "-Os", "-Wl,--gc-sections", "-o", elf.path]
        linkArguments += objects
        linkArguments += [core.path, "-lm"]
        let link = try run(toolchain.tool("avr-gcc"), linkArguments, in: work, monitor: monitor)
        log += link.output
        guard link.status == 0 else { return linkFailed(diagnostics, log: log, output: link.output) }
        let image = work.appendingPathComponent("sketch.bin")
        let copy = try run(toolchain.tool("avr-objcopy"), ["-O", "binary", "-R", ".eeprom", elf.path, image.path], in: work,
                           monitor: monitor)
        guard copy.status == 0, let firmware = fileManager.contents(atPath: image.path) else {
            return Result(firmware: nil, diagnostics: diagnostics, log: log + copy.output,
                          problem: "avr-objcopy could not make the flash image (see the compiler's output)")
        }
        // (the board's room, its bootloader's left out; another chip's whole flash)
        let room = chip.map { $0.name == board.chip ? board.flashSize : $0.flashBytes } ?? board.flashSize
        guard firmware.count <= room else {
            let problem = sizeProblem(bytes: firmware.count, room: room, chip: chip?.name ?? board.chip)
            return Result(firmware: nil, diagnostics: diagnostics, log: log + problem + "\n", problem: problem)
        }
        return Result(firmware: firmware, diagnostics: diagnostics, log: log)
    }

    /// A failed compile's result: the sketch's own errors, or else what the log says went wrong elsewhere
    static func failed(_ diagnostics: [Diagnostic], log: String, libraries: [String]) -> Result {
        let problem = diagnostics.contains(where: \.isError) ? nil
            : self.problem(in: log, libraries: libraries) ?? "The sketch did not compile (see the compiler's output)"
        return Result(firmware: nil, diagnostics: diagnostics, log: log, problem: problem)
    }

    /// A failed link's result: undefined references the linker can place on the sketch's lines, and a summary
    static func linkFailed(_ diagnostics: [Diagnostic], log: String, output: String) -> Result {
        let (lines, problem) = linkProblem(output)
        return Result(firmware: nil, diagnostics: diagnostics + lines, log: log, problem: problem)
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
        libraries(usedBy: source, in: toolchain.core.appendingPathComponent("libraries"))
    }

    /// The libraries in `folder` (each one's sources in <name>/src) whose headers the sketch includes, and those their
    /// own headers include in turn (arduino-pico's I2S needs its AudioBufferManager)
    static func libraries(usedBy source: String, in folder: URL) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var headers = includedHeaders(source)
        var found = Set<String>()
        var result: [URL] = []
        var added = true
        while added {
            added = false
            for name in names.sorted() where !found.contains(name) {
                let src = folder.appendingPathComponent(name).appendingPathComponent("src")
                guard headers.contains(where: { FileManager.default.fileExists(atPath: src.appendingPathComponent($0 + ".h").path) })
                else { continue }
                found.insert(name)
                result.append(src)
                added = true
                for file in (try? FileManager.default.contentsOfDirectory(atPath: src.path)) ?? [] where file.hasSuffix(".h") {
                    if let text = try? String(contentsOf: src.appendingPathComponent(file), encoding: .utf8) {
                        headers.formUnion(includedHeaders(text))
                    }
                }
            }
        }
        return result
    }

    /// The headers a source includes, without their ".h"
    private static func includedHeaders(_ source: String) -> Set<String> {
        let pattern = try? NSRegularExpression(pattern: #"#\s*include\s*[<"]([^>"]+)\.h[>"]"#)
        let range = NSRange(source.startIndex..., in: source)
        return Set((pattern?.matches(in: source, range: range) ?? []).compactMap { match -> String? in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        })
    }

    /// The names of the libraries the core brings (the folders in its libraries folder), sorted
    public static func libraryNames(in folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted { $0.lowercased() < $1.lowercased() }
    }

    static func sources(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { ["c", "cpp", "S"].contains($0.pathExtension) }
            .sorted { $0.path < $1.path }
    }

    /// The Arduino core compiled once into an archive, kept in the caches folder for later builds
    static func coreArchive(_ toolchain: AVRToolchain, _ board: Board, _ chip: AVRVariant? = nil,
                            monitor: BuildMonitor? = nil) throws -> URL {
        let definitions = try self.definitions(toolchain, board, chip)
        let key = String((toolchain.compiler.path + "|" + toolchain.core.path + "|" + definitions.joined(separator: " ")
                          + "|" + board.variantHeader).hashValueStable, radix: 16)
        let folder = cachesFolder().appendingPathComponent("arduino-core-\(board.rawValue)-\(key)")
        return try buildCoreArchive(
            sources: sources(in: toolchain.core.appendingPathComponent("cores/arduino")), folder: folder,
            coreName: ChipFamily.avr.coreName, monitor: monitor,
            compile: { file, object, folder in
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
                arguments += definitions
                arguments += [file.path, "-o", object.path]
                return try run(toolchain.tool(tool), arguments, in: folder, monitor: monitor)
            },
            archive: { archive, objects, folder in
                try run(toolchain.tool("avr-ar"), ["rcs", archive.path] + objects, in: folder, monitor: monitor)
            })
    }

    /// A core compiled into `folder`/core.a, which later builds use as it is. It is built in a folder of its own beside
    /// `folder` and moved into place only once complete, so that a build that fails, is cancelled or is stopped part way
    /// leaves nothing a later build would trust (and two builds at once do not share a half-built folder).
    /// `compile(source, object, folder)` and `archive(archive, objects, folder)` run the tools in `folder`.
    static func buildCoreArchive(sources: [URL], folder: URL, coreName: String, monitor: BuildMonitor?,
                                 compile: (URL, URL, URL) throws -> ToolResult,
                                 archive: (URL, [String], URL) throws -> ToolResult) throws -> URL {
        let fileManager = FileManager.default
        let finished = folder.appendingPathComponent("core.a")
        if fileManager.fileExists(atPath: finished.path) { return finished }
        let parent = folder.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let building = parent.appendingPathComponent(folder.lastPathComponent + ".building-" + UUID().uuidString)
        try fileManager.createDirectory(at: building, withIntermediateDirectories: true)
        var complete = false
        defer { if !complete { try? fileManager.removeItem(at: building) } }

        var objects: [String] = []
        for (k, file) in sources.enumerated() {
            try monitor?.checkCancelled()
            monitor?.report(BuildProgress(.core(done: k, total: sources.count), coreName: coreName))
            let object = building.appendingPathComponent("\(k)-\(file.lastPathComponent).o")
            let result = try compile(file, object, building)
            guard result.status == 0 else {
                throw BuildError.coreFailed(core: coreName, file: file.lastPathComponent, output: result.output)
            }
            objects.append(object.path)
        }
        try monitor?.checkCancelled()
        monitor?.report(BuildProgress(.core(done: sources.count, total: sources.count), coreName: coreName))
        let built = building.appendingPathComponent("core.a")
        let ar = try archive(built, objects, building)
        guard ar.status == 0, fileManager.fileExists(atPath: built.path) else {
            throw BuildError.toolFailed("archiving \(coreName) failed:\n" + ar.output)
        }
        try monitor?.checkCancelled()
        // (another build may have finished the same core meanwhile: its archive is as good)
        if fileManager.fileExists(atPath: finished.path) { return finished }
        // what an earlier, interrupted build of an older JSpice left, without its archive
        try? fileManager.removeItem(at: folder)
        do {
            try fileManager.moveItem(at: building, to: folder)
        } catch {
            if fileManager.fileExists(atPath: finished.path) { return finished }
            throw error
        }
        complete = true
        return finished
    }

    // MARK: - Running the tools

    struct ToolResult {
        let status: Int32
        let output: String
    }

    /// The longest one tool may run: a file of the core, the sketch or the link takes seconds
    static let toolTimeout = 300

    static func run(_ tool: URL, _ arguments: [String], in folder: URL, monitor: BuildMonitor? = nil) throws -> ToolResult {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = folder
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            if let monitor { try monitor.launch(process) } else { try process.run() }
        } catch BuildError.cancelled {
            throw BuildError.cancelled
        } catch {
            throw BuildError.toolFailed("Cannot run \(tool.lastPathComponent) (\(tool.path)): \(error.localizedDescription)."
                                        + " On a Mac with Apple silicon the compiler may need Rosetta: softwareupdate --install-rosetta")
        }
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
            func set() { lock.lock(); value = true; lock.unlock() }
        }
        let timedOut = Flag()
        let timer = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(toolTimeout), execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        monitor?.finished()
        if monitor?.isCancelled == true { throw BuildError.cancelled }
        if timedOut.isSet { throw BuildError.timedOut(tool: tool.lastPathComponent, seconds: toolTimeout) }
        return ToolResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    // MARK: - What the compiler said

    /// The errors and warnings on the sketch's own lines: "sketch.ino:12:5: error: 'foo' was not declared in this
    /// scope". A header that is not there is said plainly (see `missingLibraryMessage`); the same message twice is
    /// kept once.
    static func parseDiagnostics(_ output: String, libraries: [String] = []) -> [Diagnostic] {
        let pattern = try? NSRegularExpression(pattern: #"(?:^|[/\\ ])sketch\.ino:(\d+):(\d+): (fatal error|error|warning): (.*)"#)
        var result: [Diagnostic] = []
        for line in output.split(separator: "\n") {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = pattern?.firstMatch(in: text, range: range),
                  let lineRange = Range(match.range(at: 1), in: text), let columnRange = Range(match.range(at: 2), in: text),
                  let kindRange = Range(match.range(at: 3), in: text), let messageRange = Range(match.range(at: 4), in: text)
            else { continue }
            var message = String(text[messageRange])
            if let header = missingHeader(in: message) { message = missingLibraryMessage(header, libraries: libraries) }
            let diagnostic = Diagnostic(line: Int(text[lineRange]) ?? 0, column: Int(text[columnRange]) ?? 0,
                                        isError: !text[kindRange].hasPrefix("warning"), message: message)
            if !result.contains(diagnostic) { result.append(diagnostic) }
        }
        return result
    }

    /// The header gcc could not find, from its message "Servo.h: No such file or directory"
    static func missingHeader(in message: String) -> String? {
        let marker = ": No such file or directory"
        guard let range = message.range(of: marker) else { return nil }
        let header = message[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        guard !header.isEmpty, !header.contains(" ") else { return nil }
        return header
    }

    /// What to say of a header that is not there: only the core's own libraries are available
    public static func missingLibraryMessage(_ header: String, libraries: [String]) -> String {
        let shown = libraries.prefix(12).joined(separator: ", ")
        let more = libraries.count > 12 ? " and \(libraries.count - 12) more" : ""
        let list = libraries.isEmpty ? "" : " (\(shown)\(more))"
        return "\(header) is not available: JSpice compiles sketches with the core's own libraries only\(list)."
            + " Libraries from elsewhere cannot be added; paste the code you need into the sketch instead."
    }

    /// The first error in a compiler's output, as "file line N: message" (the file's name only)
    static func firstError(in output: String) -> String? {
        let pattern = try? NSRegularExpression(pattern: #"^(.*?):(\d+)(?::\d+)?: (?:fatal error|error): (.*)$"#)
        for line in output.split(separator: "\n") {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = pattern?.firstMatch(in: text, range: range),
                  let fileRange = Range(match.range(at: 1), in: text), let lineRange = Range(match.range(at: 2), in: text),
                  let messageRange = Range(match.range(at: 3), in: text) else { continue }
            let file = URL(fileURLWithPath: String(text[fileRange])).lastPathComponent
            return "\(file) line \(text[lineRange]): \(text[messageRange])"
        }
        return nil
    }

    /// Why a compile failed when no error is on the sketch's own lines: a header that is not there, an error in a
    /// library's or the core's file, or the compiler's own complaint
    static func problem(in output: String, libraries: [String]) -> String? {
        let pattern = try? NSRegularExpression(pattern: #"^(.*?):(\d+)(?::\d+)?: (?:fatal error|error): (.*)$"#)
        for line in output.split(separator: "\n") {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = pattern?.firstMatch(in: text, range: range),
                  let fileRange = Range(match.range(at: 1), in: text), let lineRange = Range(match.range(at: 2), in: text),
                  let messageRange = Range(match.range(at: 3), in: text) else { continue }
            let file = URL(fileURLWithPath: String(text[fileRange])).lastPathComponent
            let message = String(text[messageRange])
            if let header = missingHeader(in: message) {
                return "\(file) includes " + missingLibraryMessage(header, libraries: libraries)
            }
            return "In \(file), line \(text[lineRange]): \(message)"
        }
        // "avr-g++: error: …", "cc1plus: fatal error: …"
        for line in output.split(separator: "\n") {
            if let range = line.range(of: "error: ") { return String(line[range.upperBound...]) }
        }
        return nil
    }

    /// What the linker said, made plain: functions used and never defined (on the sketch's lines where the linker
    /// gives them), defined twice, or memory too small
    static func linkProblem(_ output: String) -> (lines: [Diagnostic], problem: String) {
        func names(after marker: String) -> [String] {
            var found: [String] = []
            for line in output.split(separator: "\n") {
                guard let range = line.range(of: marker) else { continue }
                // `name' (older ld), 'name' or ‘name’: up to the closing quote
                var rest = line[range.upperBound...].drop(while: { "`'‘\"".contains($0) })
                if let close = rest.firstIndex(where: { "'’\"".contains($0) }) { rest = rest[..<close] }
                let name = rest.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !found.contains(name) { found.append(name) }
            }
            return found
        }
        func list(_ names: [String]) -> String {
            let shown = names.prefix(3)
            return shown.count < 2 ? shown.joined() : shown.dropLast().joined(separator: ", ") + " and " + shown.last!
                + (names.count > 3 ? " (and \(names.count - 3) more)" : "")
        }
        var lines: [Diagnostic] = []
        let placed = try? NSRegularExpression(pattern: #"sketch\.ino:(\d+):.*undefined reference to [`'‘](.*?)['’]"#)
        for line in output.split(separator: "\n") {
            let text = String(line)
            guard let match = placed?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let lineRange = Range(match.range(at: 1), in: text), let nameRange = Range(match.range(at: 2), in: text),
                  let number = Int(text[lineRange]) else { continue }
            let diagnostic = Diagnostic(line: number, column: 0, isError: true,
                                        message: "\(text[nameRange]) is used but never defined")
            if !lines.contains(diagnostic) { lines.append(diagnostic) }
        }
        let undefined = names(after: "undefined reference to ")
        if !undefined.isEmpty {
            let verb = undefined.count == 1 ? "is" : "are"
            return (lines, "Linking failed: \(list(undefined)) \(verb) used but never defined"
                    + " (a function declared but not written, or a library's that is not available)")
        }
        let twice = names(after: "multiple definition of ")
        if !twice.isEmpty { return (lines, "Linking failed: \(list(twice)) \(twice.count == 1 ? "is" : "are") defined more than once") }
        let overflow = try? NSRegularExpression(pattern: #"region [`'‘]?(\w+)['’]? overflowed by (\d+) bytes"#)
        if let match = overflow?.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           let regionRange = Range(match.range(at: 1), in: output), let bytesRange = Range(match.range(at: 2), in: output) {
            let region = output[regionRange].lowercased()
            let memory = region.contains("ram") || region.contains("data") ? "RAM" : region.contains("text") || region.contains("flash") ? "flash" : String(output[regionRange])
            return (lines, "The sketch does not fit: it needs \(output[bytesRange]) bytes more \(memory) than the chip has")
        }
        if let first = output.split(separator: "\n").first(where: { $0.contains("error") && !$0.hasPrefix("collect2") }) {
            return (lines, "Linking failed: " + first.trimmingCharacters(in: .whitespaces))
        }
        return (lines, "Linking failed (see the compiler's output)")
    }

    /// A sketch too large for the chip's flash
    static func sizeProblem(bytes: Int, room: Int, chip: String) -> String {
        "The sketch does not fit: it takes \(bytes) bytes of flash, and the \(chip) has room for \(room)"
            + " (\(bytes - room) bytes too many)"
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
