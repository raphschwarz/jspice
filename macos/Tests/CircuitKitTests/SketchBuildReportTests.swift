import XCTest
@testable import CircuitKit

/// What a sketch build reports: the compiler's messages on the sketch's lines, plain problems for everything else, the
/// boards that compile and those that do not, and the core build's progress. No compiler is run here.
final class SketchBuildReportTests: XCTestCase {
    typealias Diagnostic = SketchBuilder.Diagnostic

    // MARK: - The compiler's messages

    func testErrorsAndWarningsKeepTheSketchsLines() {
        let output = """
            In file included from /tmp/jspice-sketch-1/sketch.cpp:1:0:
            /opt/core/cores/arduino/Arduino.h:40:2: warning: something in the core
            /tmp/jspice-sketch-1/sketch.ino: In function 'void loop()':
            /tmp/jspice-sketch-1/sketch.ino:12:5: error: 'foo' was not declared in this scope
            sketch.ino:3:7: warning: unused variable 'x' [-Wunused-variable]
            sketch.ino:3:7: warning: unused variable 'x' [-Wunused-variable]
            sketch.ino:12:5: note: suggested alternative: 'for'
            """
        let diagnostics = SketchBuilder.parseDiagnostics(output)
        XCTAssertEqual(diagnostics, [
            Diagnostic(line: 12, column: 5, isError: true, message: "'foo' was not declared in this scope"),
            Diagnostic(line: 3, column: 7, isError: false, message: "unused variable 'x' [-Wunused-variable]"),
        ])
        let result = SketchBuilder.failed(diagnostics, log: output, libraries: [])
        XCTAssertNil(result.problem, "the sketch's own error says it all")
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertEqual(result.warnings.map(\.line), [3])
    }

    func testOnlyTheSketchGetsWarningsTheCoreStaysQuiet() {
        let definitions = ["-mmcu=atmega328p", "-Os", "-w", "-ffunction-sections"]
        XCTAssertEqual(SketchBuilder.sketchFlags(definitions), ["-mmcu=atmega328p", "-Os", "-ffunction-sections", "-Wall"])
    }

    func testAThirdPartyIncludeIsSaidPlainly() {
        let libraries = ["EEPROM", "HID", "SoftwareSerial", "SPI", "Wire"]
        let output = """
            sketch.ino:1:10: fatal error: Adafruit_NeoPixel.h: No such file or directory
             #include <Adafruit_NeoPixel.h>
                      ^~~~~~~~~~~~~~~~~~~~~
            compilation terminated.
            """
        let diagnostics = SketchBuilder.parseDiagnostics(output, libraries: libraries)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].line, 1)
        XCTAssertTrue(diagnostics[0].message.hasPrefix("Adafruit_NeoPixel.h is not available"), diagnostics[0].message)
        XCTAssertTrue(diagnostics[0].message.contains("(EEPROM, HID, SoftwareSerial, SPI, Wire)"), diagnostics[0].message)
        XCTAssertFalse(diagnostics[0].message.contains("No such file"))

        XCTAssertEqual(SketchBuilder.missingHeader(in: "Servo.h: No such file or directory"), "Servo.h")
        XCTAssertEqual(SketchBuilder.missingHeader(in: "utility/twi.h: No such file or directory"), "utility/twi.h")
        XCTAssertNil(SketchBuilder.missingHeader(in: "'foo' was not declared in this scope"))

        // a long list is cut short
        let many = (1...20).map { "Lib\($0)" }
        let message = SketchBuilder.missingLibraryMessage("X.h", libraries: many)
        XCTAssertTrue(message.contains("Lib12 and 8 more"), message)
        XCTAssertFalse(message.contains("Lib13"))
    }

    func testAFailureInALibraryOrTheCoreIsAProblemNotAnEmptyList() {
        let output = """
            /core/libraries/Servo/src/Servo.cpp:42:3: error: 'TCCR5A' was not declared in this scope
            """
        let result = SketchBuilder.failed([], log: output, libraries: [])
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.problem, "In Servo.cpp, line 42: 'TCCR5A' was not declared in this scope")

        // a library including a header that is not there
        let missing = SketchBuilder.failed([], log: "/core/libraries/Foo/src/Foo.h:3:10: fatal error: Bar.h: No such file or directory",
                                           libraries: ["Wire"])
        XCTAssertTrue(missing.problem?.hasPrefix("Foo.h includes Bar.h is not available") == true, missing.problem ?? "nil")

        // the compiler's own complaint, with no file
        let driver = SketchBuilder.failed([], log: "avr-g++: error: unrecognized command line option '-std=gnu++23'", libraries: [])
        XCTAssertEqual(driver.problem, "unrecognized command line option '-std=gnu++23'")

        // nothing to go on
        XCTAssertEqual(SketchBuilder.failed([], log: "", libraries: []).problem, "The sketch did not compile (see the compiler's output)")
    }

    func testLinkFailuresHaveNoLineZero() {
        let output = """
            /usr/bin/avr-ld: /tmp/sketch.o: in function `loop':
            sketch.cpp:(.text.loop+0x2): undefined reference to `blinkTwice(int)'
            sketch.cpp:(.text.loop+0x8): undefined reference to `blinkTwice(int)'
            collect2: error: ld returned 1 exit status
            """
        let result = SketchBuilder.linkFailed([], log: output, output: output)
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        XCTAssertEqual(result.problem, "Linking failed: blinkTwice(int) is used but never defined"
                       + " (a function declared but not written, or a library's that is not available)")

        // with debug information (the Pico's -g) the linker names the sketch's line
        let placed = """
            /tmp/w/sketch.ino:5:(.text.loop+0x4): undefined reference to `helper()'
            /tmp/w/sketch.ino:9:(.text.setup+0x2): undefined reference to `other()'
            """
        let (lines, problem) = SketchBuilder.linkProblem(placed)
        XCTAssertEqual(lines, [Diagnostic(line: 5, column: 0, isError: true, message: "helper() is used but never defined"),
                               Diagnostic(line: 9, column: 0, isError: true, message: "other() is used but never defined")])
        XCTAssertTrue(problem.hasPrefix("Linking failed: helper() and other() are used but never defined"), problem)

        XCTAssertEqual(SketchBuilder.linkProblem("x.o: multiple definition of `counter'; y.o: first defined here").problem,
                       "Linking failed: counter is defined more than once")
        XCTAssertEqual(SketchBuilder.linkProblem("avr-ld: region `data' overflowed by 120 bytes").problem,
                       "The sketch does not fit: it needs 120 bytes more RAM than the chip has")
        XCTAssertEqual(SketchBuilder.linkProblem("collect2: error: ld returned 1 exit status").problem,
                       "Linking failed (see the compiler's output)")
    }

    func testASketchTooLargeSaysSoWithoutALine() {
        let problem = SketchBuilder.sizeProblem(bytes: 33_000, room: 32_256, chip: "ATmega328P")
        XCTAssertEqual(problem, "The sketch does not fit: it takes 33000 bytes of flash, and the ATmega328P has room for 32256 (744 bytes too many)")
        XCTAssertFalse(problem.contains("Line 0"))
    }

    func testBuildFailuresBecomeProblems() {
        let cancelled = SketchBuilder.guarded { throw SketchBuilder.BuildError.cancelled }
        XCTAssertTrue(cancelled.wasCancelled)
        XCTAssertEqual(cancelled.problem, "Cancelled")

        let core = SketchBuilder.guarded {
            throw SketchBuilder.BuildError.coreFailed(core: "the Arduino AVR core", file: "wiring.c",
                                                      output: "/core/cores/arduino/wiring.c:10:1: error: expected ';'")
        }
        XCTAssertFalse(core.wasCancelled)
        XCTAssertEqual(core.problem, "the Arduino AVR core did not compile (wiring.c): wiring.c line 10: expected ';'."
                       + " Reinstalling it in Chip Support may help.")
        XCTAssertTrue(core.log.contains("wiring.c:10:1"))

        let tool = SketchBuilder.guarded { throw SketchBuilder.BuildError.toolFailed("Cannot run avr-g++ (/x/avr-g++): no such file.\nmore") }
        XCTAssertEqual(tool.problem, "Cannot run avr-g++ (/x/avr-g++): no such file.")

        let slow = SketchBuilder.guarded { throw SketchBuilder.BuildError.timedOut(tool: "avr-g++", seconds: 300) }
        XCTAssertEqual(slow.problem, "avr-g++ ran for more than 300 seconds and was stopped")
    }

    // MARK: - Boards

    func testEveryBoardSaysWhatItCompilesWith() {
        for board in Board.allCases {
            switch board {
            case .uno, .mega, .attiny85:
                XCTAssertEqual(board.sketchFamily, .avr, board.rawValue)
            case .pico:
                XCTAssertEqual(board.sketchFamily, .rp2040)
            case .stm32f405, .stm32f373, .stm32f103:
                XCTAssertNil(board.sketchFamily, board.rawValue)
            }
            XCTAssertEqual(board.compilesSketches, board.sketchFamily != nil, board.rawValue)
            XCTAssertEqual(board.compilesSketches, board.stm32Model == nil, board.rawValue)
            let missing = SketchBuilder.missingToolchainMessage(board)
            if board.compilesSketches {
                XCTAssertEqual(board.programNoun, "sketch")
                XCTAssertTrue(board.serialMonitorPlaceholder.contains("Serial.begin"), board.rawValue)
                XCTAssertTrue(missing.contains("install \(board.sketchFamily!.title) in Chip Support"), missing)
            } else {
                XCTAssertEqual(board.programNoun, "firmware")
                XCTAssertFalse(board.serialMonitorPlaceholder.contains("Serial.begin"), board.rawValue)
                XCTAssertFalse(missing.contains("install"), missing)
                XCTAssertFalse(missing.contains("Chip Support"), missing)
                // building for it says it compiles nothing, without running anything
                let result = SketchBuilder.build("void setup() {}\nvoid loop() {}\n", board: board)
                XCTAssertFalse(result.succeeded)
                XCTAssertTrue(result.diagnostics.isEmpty)
                XCTAssertEqual(result.problem, missing)
            }
        }
    }

    // MARK: - Chip support's states

    func testInstallProgressMakesStates() {
        XCTAssertEqual(ChipSupport.State(ChipSupport.Progress(fraction: 0.3, message: "Downloading")),
                       .downloading(fraction: 0.3, message: "Downloading"))
        XCTAssertEqual(ChipSupport.State(ChipSupport.Progress(fraction: 0.92, message: "Unpacking", stage: .unpacking)),
                       .unpacking(message: "Unpacking"))
        XCTAssertEqual(ChipSupport.State(ChipSupport.Progress(fraction: 1, message: "Installed: x", stage: .installed)),
                       .installed("Installed: x"))
        XCTAssertTrue(ChipSupport.State.downloading(fraction: 0, message: "").isBusy)
        XCTAssertTrue(ChipSupport.State.unpacking(message: "").isBusy)
        XCTAssertFalse(ChipSupport.State.installed("").isBusy)
        XCTAssertFalse(ChipSupport.State.failed("").isBusy)
        XCTAssertFalse(ChipSupport.State.notInstalled.isBusy)
    }

    // MARK: - The core's build

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [SketchBuilder.BuildProgress] = []
        func add(_ step: SketchBuilder.BuildProgress) { lock.lock(); steps.append(step); lock.unlock() }
        var all: [SketchBuilder.BuildProgress] { lock.lock(); defer { lock.unlock() }; return steps }
    }

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-core-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func fakeSources(_ count: Int) -> [URL] {
        (0..<count).map { URL(fileURLWithPath: "/core/cores/arduino/file\($0).cpp") }
    }

    private func writes(_ file: URL) -> SketchBuilder.ToolResult {
        FileManager.default.createFile(atPath: file.path, contents: Data("o".utf8))
        return SketchBuilder.ToolResult(status: 0, output: "")
    }

    func testTheCoreBuildReportsEachFileAndIsKept() throws {
        let caches = try scratch()
        let folder = caches.appendingPathComponent("arduino-core-uno-abc")
        let recorder = Recorder()
        let monitor = SketchBuilder.BuildMonitor { recorder.add($0) }
        var compiled = 0
        let archive = try SketchBuilder.buildCoreArchive(
            sources: fakeSources(112), folder: folder, coreName: ChipFamily.avr.coreName, monitor: monitor,
            compile: { _, object, _ in compiled += 1; return self.writes(object) },
            archive: { archive, objects, _ in
                XCTAssertEqual(objects.count, 112)
                return self.writes(archive)
            })
        XCTAssertEqual(archive, folder.appendingPathComponent("core.a"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertEqual(compiled, 112)
        let messages = recorder.all.map(\.message)
        XCTAssertEqual(messages.first, "Compiling the Arduino AVR core (first build only): 0 of 112 files")
        XCTAssertTrue(messages.contains("Compiling the Arduino AVR core (first build only): 37 of 112 files"))
        XCTAssertEqual(messages.last, "Compiling the Arduino AVR core (first build only): 112 of 112 files")
        XCTAssertEqual(recorder.all.last?.fraction, 1)
        // nothing left beside it
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: caches.path), ["arduino-core-uno-abc"])

        // the next build uses it as it is
        let again = try SketchBuilder.buildCoreArchive(
            sources: fakeSources(112), folder: folder, coreName: "core", monitor: nil,
            compile: { _, _, _ in XCTFail("compiled again"); return SketchBuilder.ToolResult(status: 1, output: "") },
            archive: { _, _, _ in XCTFail("archived again"); return SketchBuilder.ToolResult(status: 1, output: "") })
        XCTAssertEqual(again, archive)
    }

    func testAFailedCoreBuildLeavesNothingALaterBuildTrusts() throws {
        let caches = try scratch()
        let folder = caches.appendingPathComponent("pico-core-abc")
        XCTAssertThrowsError(try SketchBuilder.buildCoreArchive(
            sources: fakeSources(10), folder: folder, coreName: "arduino-pico", monitor: nil,
            compile: { file, object, _ in
                file.lastPathComponent == "file4.cpp" ? SketchBuilder.ToolResult(status: 1, output: "file4.cpp:1:1: error: bad")
                                                      : self.writes(object)
            },
            archive: { archive, _, _ in self.writes(archive) })) { error in
            guard case .coreFailed(let core, let file, _)? = error as? SketchBuilder.BuildError else { return XCTFail("\(error)") }
            XCTAssertEqual(core, "arduino-pico")
            XCTAssertEqual(file, "file4.cpp")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: caches.path), [])

        // an archiver that fails does not leave its archive either
        XCTAssertThrowsError(try SketchBuilder.buildCoreArchive(
            sources: fakeSources(3), folder: folder, coreName: "arduino-pico", monitor: nil,
            compile: { _, object, _ in self.writes(object) },
            archive: { archive, _, _ in
                _ = self.writes(archive)
                return SketchBuilder.ToolResult(status: 1, output: "ar: out of space")
            }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: caches.path), [])
    }

    func testACancelledCoreBuildStopsAndLeavesNothing() throws {
        let caches = try scratch()
        let folder = caches.appendingPathComponent("arduino-core-uno-abc")
        // a folder an older, interrupted build left, without its archive
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let monitor = SketchBuilder.BuildMonitor()
        var compiled = 0
        XCTAssertThrowsError(try SketchBuilder.buildCoreArchive(
            sources: fakeSources(20), folder: folder, coreName: "core", monitor: monitor,
            compile: { _, object, _ in
                compiled += 1
                if compiled == 5 { monitor.cancel() }
                return self.writes(object)
            },
            archive: { archive, _, _ in self.writes(archive) })) { error in
            guard case .cancelled? = error as? SketchBuilder.BuildError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(compiled, 5)
        XCTAssertTrue(monitor.isCancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("core.a").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: caches.path), ["arduino-core-uno-abc"])

        // a later build replaces the leftover folder with a whole one
        let archive = try SketchBuilder.buildCoreArchive(
            sources: fakeSources(2), folder: folder, coreName: "core", monitor: nil,
            compile: { _, object, _ in self.writes(object) }, archive: { archive, _, _ in self.writes(archive) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: caches.path), ["arduino-core-uno-abc"])
    }

    func testTheBuildsPhasesReadPlainly() {
        let name = ChipFamily.rp2040.coreName
        XCTAssertEqual(SketchBuilder.BuildProgress(.core(done: 37, total: 112), coreName: name).message,
                       "Compiling arduino-pico (first build only): 37 of 112 files")
        XCTAssertEqual(SketchBuilder.BuildProgress(.libraries(done: 1, total: 4), coreName: name).message,
                       "Compiling the libraries: 1 of 4 files")
        XCTAssertEqual(SketchBuilder.BuildProgress(.sketch, coreName: name).message, "Compiling the sketch")
        XCTAssertEqual(SketchBuilder.BuildProgress(.linking, coreName: name).message, "Linking")
        XCTAssertEqual(SketchBuilder.BuildProgress(.core(done: 28, total: 112), coreName: name).fraction, 0.25)
        XCTAssertNil(SketchBuilder.BuildProgress(.sketch, coreName: name).fraction)
    }
}
