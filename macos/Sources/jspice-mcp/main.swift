import Foundation
import CircuitKit
import JSpiceAutomation

// `jspice-mcp`: a Model Context Protocol server on standard input and output, so an AI agent can build, simulate and
// measure circuits with the JSpice engine. Add it to an MCP client (Claude Desktop, Claude Code) as a stdio server.
//
// If the JSpice app is running (with Allow AI Control on), requests go to the circuit in its frontmost window, so you
// can watch the agent work and undo its changes; otherwise, or with --headless, the server simulates on its own.
// --app insists on the app. --benchmark [seconds] [example…] times the engine alone at the audio sample rate.

let arguments = CommandLine.arguments
let path = ProcessInfo.processInfo.environment["JSPICE_SOCKET"] ?? LocalSocket.defaultPath

func log(_ message: String) {
    FileHandle.standardError.write(("jspice-mcp: " + message + "\n").data(using: .utf8)!)
}

/// Simulates each example for three runs of `seconds` of circuit time at 48 kHz, one step per sample as with sound on,
/// and prints the time per step of the fastest run (the others are slowed by whatever else the machine was doing) and
/// how many times faster than real time that is
func benchmark(seconds: Double, ids: [String]) {
    let rate = 48_000.0
    for id in ids {
        guard let example = Examples.example(id) else {
            log("there is no example \(id)")
            continue
        }
        let simulator = Simulator(circuit: example.circuit, timeStep: 1 / rate)
        // as the sound runs it: substeps only where Newton-Raphson needs them
        simulator.errorControl = false
        let listened = example.circuit.elements.firstIndex { $0.kind == .speaker } ?? 0
        let steps = max(1, Int(seconds * rate))
        var total = 0.0
        var fastest = Double.infinity
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<steps {
                simulator.step()
                total += simulator.voltageAcross(listened)
            }
            fastest = min(fastest, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        let perStep = String(format: "%7.2f", fastest / Double(steps) * 1e6)
        let speed = String(format: "%6.1f", seconds / fastest)
        let name = id.padding(toLength: 18, withPad: " ", startingAt: 0)
        let notes = (simulator.isFailed ? " FAILED" : "") + (total.isFinite ? "" : " (not finite)")
        print("\(name)\(perStep) µs/step \(speed)× real time  \(simulator.convergenceFailures) unconverged\(notes)")
    }
}

/// Holds what a background task produced, for the main code waiting on it
final class Outcome: @unchecked Sendable {
    var error: Error?
    /// the last progress logged, in percent
    var logged = -1
}

// --install-chip-support [avr|rp2040]: installs a chip family's compiler and core, as the app's Chip Support window does
if let flag = arguments.firstIndex(of: "--install-chip-support") {
    let name = flag + 1 < arguments.count ? arguments[flag + 1] : ChipFamily.avr.rawValue
    guard let family = ChipFamily(rawValue: name) else {
        log("unknown chip family \(name); known: \(ChipFamily.allCases.map(\.rawValue).joined(separator: ", "))")
        exit(2)
    }
    let outcome = Outcome()
    let done = DispatchSemaphore(value: 0)
    Task {
        do {
            try await ChipSupport.install(family) { progress in
                let percent = Int(progress.fraction * 100)
                if percent / 10 != outcome.logged / 10 || progress.fraction >= 1 {
                    outcome.logged = percent
                    log("\(percent)% \(progress.message)")
                }
            }
        } catch {
            outcome.error = error
        }
        done.signal()
    }
    done.wait()
    if let error = outcome.error {
        log("\(error)")
        exit(1)
    }
    exit(0)
}

// --compile-sketch file.ino [out.bin] [--board uno|mega|attiny85|pico]: compiles an Arduino sketch
if let flag = arguments.firstIndex(of: "--compile-sketch"), flag + 1 < arguments.count {
    var board = Board.uno
    if let option = arguments.firstIndex(of: "--board"), option + 1 < arguments.count {
        guard let named = Board(rawValue: arguments[option + 1]) else {
            log("unknown board \(arguments[option + 1]); known: \(Board.allCases.map(\.rawValue).joined(separator: ", "))")
            exit(2)
        }
        board = named
    }
    guard ChipSupport.isAvailable(board.family) else {
        log("no compiler for the \(board.chip): run jspice-mcp --install-chip-support \(board.family.rawValue)")
        exit(1)
    }
    guard let source = try? String(contentsOfFile: arguments[flag + 1], encoding: .utf8) else {
        log("cannot read \(arguments[flag + 1])")
        exit(1)
    }
    let result = SketchBuilder.build(source, board: board)
    guard let firmware = result.firmware else {
        log(result.log)
        exit(1)
    }
    if flag + 2 < arguments.count, !arguments[flag + 2].hasPrefix("--") { try? firmware.write(to: URL(fileURLWithPath: arguments[flag + 2])) }
    print("\(firmware.count) bytes")
    exit(0)
}

if let flag = arguments.firstIndex(of: "--benchmark") {
    var rest = Array(arguments[(flag + 1)...])
    var seconds = 1.0
    if let first = rest.first, let value = Double(first) {
        guard value > 0, value < 1e4 else {
            log("--benchmark takes a number of seconds between 0 and 10000")
            exit(2)
        }
        seconds = value
        rest.removeFirst()
    }
    benchmark(seconds: seconds, ids: rest.isEmpty ? Examples.all.map(\.id) : rest)
    exit(0)
}

if !arguments.contains("--headless"), let fd = LocalSocket.connect(to: path) {
    log("connected to the JSpice app")
    // replies (and anything else the app sends) go straight to the client
    Thread.detachNewThread {
        LocalSocket.readLines(fd) { line in
            FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
        }
        log("the JSpice app closed the connection")
        exit(0)
    }
    while let line = readLine(strippingNewline: true) {
        guard LocalSocket.write(fd, line) else {
            log("lost the connection to the JSpice app")
            exit(1)
        }
    }
    // the client is done sending: tell the app, and wait for the replies still coming (the reader exits when the
    // app closes the connection after answering)
    shutdown(fd, Int32(SHUT_WR))
    DispatchSemaphore(value: 0).wait()
} else if arguments.contains("--app") {
    log("the JSpice app is not running, or Allow AI Control is off")
    exit(1)
} else {
    log("simulating on its own (the JSpice app is not running)")
    MCPServer(session: CircuitSession()).runOnStandardIO()
}
