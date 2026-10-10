import Foundation
import CircuitKit
import JSpiceAutomation

// `jspice-mcp`: a Model Context Protocol server on standard input and output, so an AI agent can build, simulate and
// measure circuits with the JSpice engine. Add it to an MCP client (Claude Desktop, Claude Code) as a stdio server.
//
// If the JSpice app is running (with Allow AI Control on), requests go to the circuit in its frontmost window, so you
// can watch the agent work and undo its changes; otherwise, or with --headless, the server simulates on its own.
// --app insists on the app. --benchmark [seconds] [example…] times the engine alone at the audio sample rate, and
// --benchmark-maker PART [seconds] a maker's op-amp model.

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
        let solves = String(format: "%5.2f", Double(simulator.newtonIterations) / Double(3 * steps))
        let error = String(format: "%6.1f", accuracy(of: example.circuit, listened: listened))
        let size = simulator.equationStatistics
        print("\(name)\(perStep) µs/step \(speed)× real time  \(simulator.convergenceFailures) unconverged  \(solves) solves/step"
              + "  error \(error) dB"
              + "  n \(size.unknowns) nz \(size.nonzeros) lu \(size.factorEntries) nl \(size.nonlinearUnknowns) plans \(simulator.plans) orders \(simulator.pivotOrders)\(notes)")
    }
}

/// How far the sound's simulation (48 kHz, one step per sample, without error control) is from a 16 times finer one
/// with error control, over the first 50 ms of the listened part's voltage: the error's energy over the signal's, in dB
func accuracy(of circuit: Circuit, listened: Int) -> Double {
    let rate = 48_000.0
    let finer = 16
    let audio = Simulator(circuit: circuit, timeStep: 1 / rate)
    audio.errorControl = false
    let reference = Simulator(circuit: circuit, timeStep: 1 / (rate * Double(finer)))
    var error = 0.0
    var signal = 0.0
    for _ in 0..<Int(0.05 * rate) {
        audio.step()
        for _ in 0..<finer { reference.step() }
        let a = audio.voltageAcross(listened)
        let r = reference.voltageAcross(listened)
        error += (a - r) * (a - r)
        signal += r * r
    }
    guard signal > 0, error.isFinite else { return error == 0 ? -999 : 999 }
    return max(10 * log10(max(error, 1e-300) / signal), -999)
}

/// Runs a maker's op-amp model (downloaded from its maker as the app does, or taken from the cache) as a follower of a
/// 1 V, 1 kHz sine at 48 kHz, one step per sample without error control, as the live sound runs it, for `seconds` of
/// circuit time, and prints the time per step, Newton iterations and factorings
func benchmarkMaker(_ part: String, seconds: Double, stages: Int = 1) throws {
    guard let model = MakerModelCatalog.models.first(where: { $0.part == part }) else {
        log("no maker's model \(part); there are \(MakerModelCatalog.models.map(\.part).joined(separator: ", "))")
        exit(2)
    }
    let imported = try MakerModelCatalog.download(model)
    guard let pins = imported.block.source?.pins else {
        log("\(part)'s model has no pins")
        exit(1)
    }
    let input = NetlistPart(kind: .acVoltage, name: "VI", params: ["amplitude": 1, "frequency": 1000, "offset": 0],
                            connections: ["plus": "inp", "minus": "GND"])
    let circuit = try MakerModels.bench(imported.block, pins: pins, supply: model.supply, load: model.load, input: input, follower: true,
                                        stages: stages)
    let simulator = Simulator(circuit: circuit, timeStep: 1 / 48_000)
    simulator.errorControl = false
    let steps = max(1, Int(seconds * 48_000))
    let start = DispatchTime.now().uptimeNanoseconds
    var done = 0
    // timed in five rounds as well, each a whole number of the sine's cycles where it can be: the fastest is the least
    // disturbed by whatever else the machine is doing
    let round = max(1, steps / 5)
    var roundStart = start
    var fastest = Double.infinity
    // Newton iterations by where the sine is in its cycle, in twelve 30° slices
    var slices = [(steps: Int, iterations: Int)](repeating: (steps: 0, iterations: 0), count: 12)
    // the steps that took most iterations, and what they spent them on
    var heavy = 0, heaviest = 0
    while done < steps && !simulator.isFailed {
        let before = simulator.newtonIterations
        simulator.step()
        let taken = simulator.newtonIterations - before
        let slice = min(11, Int((simulator.time * 1000).truncatingRemainder(dividingBy: 1) * 12))
        slices[slice].steps += 1
        slices[slice].iterations += taken
        if taken > 10 { heavy += 1 }
        heaviest = max(heaviest, taken)
        done += 1
        if done % round == 0 {
            let now = DispatchTime.now().uptimeNanoseconds
            fastest = min(fastest, Double(now - roundStart) / Double(round))
            roundStart = now
        }
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    let shape = simulator.planShape
    let size = simulator.equationStatistics
    // what the model is made of, as simulated: the most numerous kinds of part
    var kinds: [String: Int] = [:]
    for element in circuit.flattened().elements { kinds[element.kind.displayName, default: 0] += 1 }
    let made = kinds.sorted { $0.value > $1.value }.prefix(12).map { "\($0.value) \($0.key)" }.joined(separator: ", ")
    print("\(part): Newton iterations a step through the sine's cycle, every 30° from 0°: "
          + slices.map { String(format: "%.1f", Double($0.iterations) / Double(max($0.steps, 1))) }.joined(separator: " ")
          + "; \(simulator.limitedIterations) iterations limited, \(simulator.dampedIterations) damped, "
          + "\(simulator.convergenceFailures) convergence failures, \(simulator.substeps) substeps (\(simulator.rejectedSubsteps) rejected); "
          + "\(heavy) steps of more than 10 iterations, the most \(heaviest); \(simulator.decisionSolves) solves again for decisions "
          + "that moved, \(simulator.chatteringSolves) left chattering; \(simulator.bypassedEvaluations) behavioural sources' "
          + "evaluations bypassed; \(simulator.confirmedWithoutSolving) iterations confirmed without a solve; "
          + "\(simulator.reusedStampings) first iterations started from the confirmed stamps, "
          + "\(simulator.restartedSolves) started again without them")
    let block = simulator.blockFactorSize
    print("\(part)'s model as simulated: \(size.unknowns) unknowns, \(size.nonzeros) nonzeros, \(size.factorEntries) entries "
          + "factored, \(size.nonlinearUnknowns) nonlinear (its factors \(block.lower) below and \(block.upper) right of the "
          + "pivots, \(block.operations) multiply-adds to factor); \(made)")
    print(String(format: "%@ %@, 1 kHz at 48 kHz: %.1f µs/step (the fastest fifth %.1f), %.2f× real time, %.2f Newton iterations a step "
                 + "(%ld factored, %ld with kept factors), %ld unknowns, %ld in the nonlinear block%@",
                 part, stages > 1 ? "\(stages) followers in a row" : "follower", elapsed / Double(done) * 1e6,
                 fastest.isFinite ? fastest / 1e3 : elapsed / Double(done) * 1e6, Double(done) / 48_000 / elapsed,
                 Double(simulator.newtonIterations) / Double(done), simulator.factorings, simulator.reusedFactorings,
                 shape.unknowns, shape.nonlinear, simulator.isFailed ? " FAILED: " + simulator.problems.joined(separator: "; ") : ""))
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

// --capture-eval directory: reads each drawing there (named for the example it shows: fuzz.png, lowpass.pdf) with
// schematic capture, and scores the circuit read against the example. Needs ANTHROPIC_API_KEY.
if let flag = arguments.firstIndex(of: "--capture-eval"), flag + 1 < arguments.count {
    let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    guard !key.isEmpty else {
        log("--capture-eval needs ANTHROPIC_API_KEY")
        exit(2)
    }
    let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
    let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
        .filter { ["png", "pdf", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let done = DispatchSemaphore(value: 0)
    final class Scores: @unchecked Sendable { var lines: [String] = []; var connections: [Double] = [] }
    let scores = Scores()
    Task.detached {
        for file in files {
            let id = file.deletingPathExtension().lastPathComponent
            let name = file.lastPathComponent.padding(toLength: 24, withPad: " ", startingAt: 0)
            guard let truth = Examples.example(id)?.circuit else {
                scores.lines.append("\(name) no example \(id)")
                continue
            }
            let started = Date()
            do {
                let capture = try await SchematicCapture.capture(file, key: key)
                let score = CaptureScore.compare(capture.circuit, to: truth)
                scores.connections.append(score.connections)
                scores.lines.append("\(name) \(score)  \(capture.attempts) turn(s), \(Int(Date().timeIntervalSince(started))) s")
                for mistake in score.mistakes.prefix(12) { scores.lines.append("    " + mistake) }
                for note in capture.notes.prefix(6) { scores.lines.append("    note: " + note) }
            } catch {
                scores.connections.append(0)
                scores.lines.append("\(name) failed: \(error)")
            }
            print(scores.lines.joined(separator: "\n"))
            scores.lines = []
        }
        done.signal()
    }
    done.wait()
    let mean = scores.connections.isEmpty ? 0 : scores.connections.reduce(0, +) / Double(scores.connections.count)
    print(String(format: "mean connection score %.3f over %d drawings", mean, scores.connections.count))
    exit(0)
}

// --benchmark-maker PART [seconds] [stages]: a maker's op-amp model at the sound's rate, or that many in a row (see
// benchmarkMaker)
if let flag = arguments.firstIndex(of: "--benchmark-maker"), flag + 1 < arguments.count {
    let seconds = flag + 2 < arguments.count ? Double(arguments[flag + 2]) ?? 1 : 1
    let stages = flag + 3 < arguments.count ? max(1, Int(arguments[flag + 3]) ?? 1) : 1
    do {
        try benchmarkMaker(arguments[flag + 1], seconds: seconds, stages: stages)
    } catch {
        log("\(error)")
        exit(1)
    }
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
