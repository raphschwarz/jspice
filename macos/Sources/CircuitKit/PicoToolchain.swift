import Foundation

/// What compiles Arduino sketches for the Raspberry Pi Pico: arm-none-eabi gcc and Earle Philhower's arduino-pico core
/// (https://github.com/earlephilhower/arduino-pico), installed from its package index by `ChipSupport`, or an Arduino
/// IDE's installation of them.
public struct PicoToolchain: Sendable, Equatable {
    /// The arduino-pico release whose build recipe JSpice follows (platform.txt; tools/pico-reference/build.py is the
    /// same build)
    public static let coreVersion = "6.2.0"

    /// The folder with bin/arm-none-eabi-gcc
    public let compiler: URL
    /// arduino-pico: the folder with cores/rp2040, variants, lib and libraries
    public let core: URL

    public init(compiler: URL, core: URL) {
        self.compiler = compiler
        self.core = core
    }

    func tool(_ name: String) -> URL { compiler.appendingPathComponent("bin/arm-none-eabi-" + name) }

    /// The first complete toolchain found: JSpice's install, or an Arduino IDE's. JSPICE_PICO_GCC and JSPICE_PICO_CORE
    /// (folders as above) override the search.
    public static func find() -> PicoToolchain? {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        func versions(in folder: URL) -> [URL] {
            guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return [] }
            return names.sorted(by: AVRToolchain.newerFirst).map { folder.appendingPathComponent($0) }
        }
        var compilers: [URL] = []
        var cores: [URL] = []
        if let path = environment["JSPICE_PICO_GCC"] { compilers.append(URL(fileURLWithPath: path)) }
        if let path = environment["JSPICE_PICO_CORE"] { cores.append(URL(fileURLWithPath: path)) }
        let installed = ChipSupport.installFolder(for: .rp2040)
        compilers += versions(in: installed.appendingPathComponent(ChipFamily.rp2040.compilerFolder))
        cores += versions(in: installed.appendingPathComponent("core"))
        let home = fileManager.homeDirectoryForCurrentUser
        for arduino in ["Library/Arduino15", ".arduino15"] {
            let packages = home.appendingPathComponent(arduino).appendingPathComponent("packages/rp2040")
            compilers += versions(in: packages.appendingPathComponent("tools/pqt-gcc"))
            // the IDE's core must be the release JSpice builds the way of
            cores += versions(in: packages.appendingPathComponent("hardware/rp2040")).filter { $0.lastPathComponent == coreVersion }
        }
        guard let compiler = compilers.first(where: { fileManager.isExecutableFile(atPath: $0.appendingPathComponent("bin/arm-none-eabi-gcc").path) }),
              let core = cores.first(where: { fileManager.fileExists(atPath: $0.appendingPathComponent("cores/rp2040/Arduino.h").path) })
        else { return nil }
        return PicoToolchain(compiler: compiler, core: core)
    }
}

extension SketchBuilder {
    /// Builds a sketch for `board` (an AVR one's part set to `chip`) with the toolchain installed for its family; without
    /// one the result says to install it
    public static func build(_ source: String, board: Board, chip: AVRVariant? = nil, monitor: BuildMonitor? = nil) -> Result {
        switch board.sketchFamily {
        case .avr?:
            guard let toolchain = AVRToolchain.find() else { return missingToolchain(board) }
            return build(source, board: board, chip: chip, toolchain: toolchain, monitor: monitor)
        case .rp2040?:
            guard let toolchain = PicoToolchain.find() else { return missingToolchain(board) }
            return build(source, board: board, toolchain: toolchain, monitor: monitor)
        case nil:
            return missingToolchain(board)
        }
    }

    /// What to say when the board's family has no compiler yet (or, for an STM32, that it compiles nothing here)
    public static func missingToolchainMessage(_ board: Board) -> String {
        guard let family = board.sketchFamily else {
            return "The \(board.chip) compiles no sketches here: it runs firmware built with its maker's tools (Load Firmware…)"
        }
        return "No compiler for the \(board.chip) yet: install \(family.title) in Chip Support (Microcontroller ▸ Chip Support…)"
    }

    private static func missingToolchain(_ board: Board) -> Result {
        let message = missingToolchainMessage(board)
        return Result(firmware: nil, diagnostics: [], log: message, problem: message)
    }

    /// Builds a sketch for the Raspberry Pi Pico as arduino-pico's platform.txt does (the rpipico board with its menu's
    /// defaults, but 125 MHz): a flash image from 0x10000000, boot stage 2 first
    public static func build(_ source: String, board: Board = .pico, toolchain: PicoToolchain,
                             monitor: BuildMonitor? = nil) -> Result {
        guarded { try PicoBuild(toolchain: toolchain, board: board, monitor: monitor).run(source) }
    }
}

/// One build for the Pico (tools/pico-reference/build.py does the same)
private struct PicoBuild {
    let toolchain: PicoToolchain
    let board: Board
    let monitor: SketchBuilder.BuildMonitor?
    // the 2 MB flash with no file system: the sketch, then 4 KB for EEPROM emulation
    static let flashTotal = 2_097_152, flashLength = 2_093_056, eepromStart = 270_528_512

    var corePath: String { toolchain.core.path + "/" }

    var defines: [String] {
        let fileSystem = PicoBuild.eepromStart
        return ["-Werror=return-type", "-Wno-psabi",
                "-DUSBD_PID=0x000a", "-DUSBD_VID=0x2e8a", "-DUSBD_MAX_POWER_MA=250",
                "-DUSB_MANUFACTURER=\"Raspberry Pi\"", "-DUSB_PRODUCT=\"Pico\"",
                "-DLWIP_IPV6=0", "-DLWIP_IPV4=1", "-DLWIP_IGMP=1", "-DLWIP_CHECKSUM_CTRL_PER_NETIF=1",
                "-DFILE_COPY_CONSTRUCTOR_SELECT=FILE_COPY_CONSTRUCTOR_PUBLIC", "-DUSE_UTF8_LONG_NAMES=1",
                "-DDISABLE_FS_H_WARNING=1",
                "-DARDUINO_VARIANT=\"rpipico\"", "-DPICO_FLASH_SIZE_BYTES=\(PicoBuild.flashTotal)",
                "-DFS_START=\(fileSystem)", "-DFS_END=\(fileSystem)",
                "@" + corePath + "lib/platform_def.txt", "@" + corePath + "lib/rp2040/platform_def.txt"]
    }

    var includes: [String] {
        ["-iprefix" + corePath, "@" + corePath + "lib/rp2040/platform_inc.txt", "@" + corePath + "lib/core_inc.txt",
         "-I" + corePath + "include"]
    }

    static let architecture = ["-march=armv6-m", "-mcpu=cortex-m0plus", "-mthumb"]
    static let common = architecture + ["-ffunction-sections", "-fdata-sections", "-fno-exceptions"]
    static let boardFlags = ["-DF_CPU=125000000L", "-DARDUINO=10819", "-DARDUINO_RASPBERRY_PI_PICO",
                             "-DBOARD_NAME=\"RASPBERRY_PI_PICO\"", "-DARDUINO_ARCH_RP2040", "-Os"]

    /// The compiler and its arguments for one source file
    func compileCommand(_ source: URL, _ object: URL, _ extraIncludes: [String]) -> (URL, [String]) {
        let variant = ["-I" + corePath + "cores/rp2040", "-I" + corePath + "variants/rpipico"] + extraIncludes
        var arguments: [String]
        let tool: URL
        switch source.pathExtension {
        case "c":
            tool = toolchain.tool("gcc")
            arguments = ["-c"] + defines + PicoBuild.common + ["-MMD"] + includes + ["-std=gnu23", "-g", "-pipe"]
                + PicoBuild.boardFlags + variant
        case "S":
            tool = toolchain.tool("gcc")
            arguments = ["-c"] + defines + ["-g", "-x", "assembler-with-cpp", "-MMD"] + includes + PicoBuild.architecture
                + ["-g"] + PicoBuild.boardFlags.dropLast() + variant
        default:
            tool = toolchain.tool("g++")
            arguments = ["-c"] + defines + PicoBuild.common + ["-MMD"] + includes
                + ["-fno-rtti", "-std=gnu++23", "-g", "-pipe", "-Wno-volatile"] + PicoBuild.boardFlags + variant
        }
        return (tool, arguments + [source.path, "-o", object.path])
    }

    /// arduino-pico's core, compiled once into an archive kept in the caches folder
    func coreArchive() throws -> URL {
        let key = String((toolchain.compiler.path + "|" + toolchain.core.path + "|" + defines.joined(separator: " ")
                          + PicoBuild.boardFlags.joined(separator: " ")).hashValueStable, radix: 16)
        let folder = SketchBuilder.cachesFolder().appendingPathComponent("pico-core-\(key)")
        let monitor = self.monitor
        return try SketchBuilder.buildCoreArchive(
            sources: SketchBuilder.sources(in: toolchain.core.appendingPathComponent("cores/rp2040")), folder: folder,
            coreName: ChipFamily.rp2040.coreName, monitor: monitor,
            compile: { file, object, folder in
                let (tool, arguments) = compileCommand(file, object, [])
                return try SketchBuilder.run(tool, arguments, in: folder, monitor: monitor)
            },
            archive: { archive, objects, folder in
                try SketchBuilder.run(toolchain.tool("ar"), ["rcs", archive.path] + objects, in: folder, monitor: monitor)
            })
    }

    func run(_ source: String) throws -> SketchBuilder.Result {
        typealias Diagnostic = SketchBuilder.Diagnostic
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("jspice-pico-\(UUID().uuidString)")
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        let coreName = ChipFamily.rp2040.coreName
        let available = SketchBuilder.libraryNames(in: toolchain.core.appendingPathComponent("libraries"))
        let core = try coreArchive()
        var extraIncludes: [String] = []
        var librarySources: [URL] = []
        for library in SketchBuilder.libraries(usedBy: source, in: toolchain.core.appendingPathComponent("libraries")) {
            extraIncludes.append("-I" + library.path)
            librarySources += SketchBuilder.sources(in: library)
        }
        let cpp = work.appendingPathComponent("sketch.cpp")
        try SketchBuilder.preprocess(source).write(to: cpp, atomically: true, encoding: .utf8)

        var log = ""
        var diagnostics: [Diagnostic] = []
        var objects: [String] = []
        for (k, file) in ([cpp] + librarySources).enumerated() {
            try monitor?.checkCancelled()
            let phase: SketchBuilder.BuildProgress.Phase = k == 0 ? .sketch : .libraries(done: k - 1, total: librarySources.count)
            monitor?.report(SketchBuilder.BuildProgress(phase, coreName: coreName))
            let object = work.appendingPathComponent("\(k).o")
            var (tool, arguments) = compileCommand(file, object, extraIncludes)
            // (the sketch's own file with gcc's warnings on, to show them on its lines)
            if k == 0 { arguments.insert("-Wall", at: 1) }
            let result = try SketchBuilder.run(tool, arguments, in: work, monitor: monitor)
            log += result.output
            if k == 0 { diagnostics = SketchBuilder.parseDiagnostics(result.output, libraries: available) }
            guard result.status == 0 else { return SketchBuilder.failed(diagnostics, log: log, libraries: available) }
            objects.append(object.path)
        }

        // the linker script for this flash layout, and boot stage 2 for the Pico's W25Q080 flash
        let lib = corePath + "lib/rp2040/"
        var script = try String(contentsOfFile: lib + "memmap_default.ld", encoding: .utf8)
        for (key, value) in [("__FLASH_LENGTH__", "\(PicoBuild.flashLength)"), ("__EEPROM_START__", "\(PicoBuild.eepromStart)"),
                             ("__FS_START__", "\(PicoBuild.eepromStart)"), ("__FS_END__", "\(PicoBuild.eepromStart)"),
                             ("__RAM_LENGTH__", "256k"), ("__PSRAM_LENGTH__", "0")] {
            script = script.replacingOccurrences(of: key, with: value)
        }
        let scriptFile = work.appendingPathComponent("memmap_default.ld")
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)
        let boot2 = work.appendingPathComponent("boot2.o")
        let boot2Arguments = defines + PicoBuild.common + ["-Os", "-u", "_printf_float", "-u", "_scanf_float", "-c",
                                                           corePath + "boot2/rp2040/boot2_w25q080_2_padded_checksum.S",
                                                           "-I" + corePath + "pico-sdk/src/rp2040/hardware_regs/include/",
                                                           "-I" + corePath + "pico-sdk/src/common/pico_binary_info/include",
                                                           "-o", boot2.path]
        try monitor?.checkCancelled()
        monitor?.report(SketchBuilder.BuildProgress(.linking, coreName: coreName))
        let boot = try SketchBuilder.run(toolchain.tool("gcc"), boot2Arguments, in: work, monitor: monitor)
        guard boot.status == 0 else {
            let first = SketchBuilder.firstError(in: boot.output) ?? "see the compiler's output"
            return SketchBuilder.Result(firmware: nil, diagnostics: diagnostics, log: log + boot.output,
                                        problem: "Boot stage 2 did not assemble: " + first)
        }

        let elf = work.appendingPathComponent("sketch.elf")
        let initializers = ["runtime_init_install_ram_vector_table", "__pre_init_runtime_init_clocks",
                            "__pre_init_runtime_init_bootrom_reset", "__pre_init_runtime_init_early_resets",
                            "__pre_init_runtime_init_usb_power_down", "__pre_init_runtime_init_post_clock_resets",
                            "__pre_init_runtime_init_spin_locks_reset", "__pre_init_runtime_init_boot_locks_reset",
                            "__pre_init_runtime_init_bootrom_locking_enable", "__pre_init_runtime_init_mutex",
                            "__pre_init_runtime_init_default_alarm_pool", "__pre_init_first_per_core_initializer",
                            "__pre_init_runtime_init_per_core_bootrom_reset", "__pre_init_runtime_init_per_core_h3_irq_registers",
                            "__pre_init_runtime_init_per_core_irq_priorities"]
        var link = ["-L" + work.path] + defines + PicoBuild.common
        link += ["-Os", "-u", "_printf_float", "-u", "_scanf_float", "@" + lib + "platform_wrap.txt", "@" + corePath + "lib/core_wrap.txt",
                 "-Wl,--cref", "-Wl,--check-sections", "-Wl,--gc-sections", "-Wl,--unresolved-symbols=report-all",
                 "-Wl,--warn-common"]
        link += initializers.map { "-Wl,--undefined=" + $0 }
        link += ["-Wl,--script=" + scriptFile.path, "-Wl,-Map," + work.appendingPathComponent("sketch.map").path,
                 "-o", elf.path, "-Wl,--no-warn-rwx-segments", "-Wl,--start-group"]
        link += objects
        link += [core.path, boot2.path, lib + "ota.o", lib + "libpico.a", lib + "liblwip.a", lib + "libbearssl.a",
                 "-lm", "-lc", "-lstdc++", "-lc", "-Wl,--end-group"]
        let linked = try SketchBuilder.run(toolchain.tool("g++"), link, in: work, monitor: monitor)
        log += linked.output
        guard linked.status == 0 else { return SketchBuilder.linkFailed(diagnostics, log: log, output: linked.output) }
        let image = work.appendingPathComponent("sketch.bin")
        let copy = try SketchBuilder.run(toolchain.tool("objcopy"), ["-Obinary", elf.path, image.path], in: work, monitor: monitor)
        guard copy.status == 0, let firmware = fileManager.contents(atPath: image.path) else {
            return SketchBuilder.Result(firmware: nil, diagnostics: diagnostics, log: log + copy.output,
                                        problem: "objcopy could not make the flash image (see the compiler's output)")
        }
        guard firmware.count <= board.flashSize else {
            let problem = SketchBuilder.sizeProblem(bytes: firmware.count, room: board.flashSize, chip: board.chip)
            return SketchBuilder.Result(firmware: nil, diagnostics: diagnostics, log: log + problem + "\n", problem: problem)
        }
        return SketchBuilder.Result(firmware: firmware, diagnostics: diagnostics, log: log)
    }
}
