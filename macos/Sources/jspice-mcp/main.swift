import Foundation
import CircuitKit
import JSpiceAutomation

// `jspice-mcp`: a Model Context Protocol server on standard input and output, so an AI agent can build, simulate and
// measure circuits with the JSpice engine. Add it to an MCP client (Claude Desktop, Claude Code) as a stdio server.
//
// If the JSpice app is running (with Allow AI Control on), requests go to the circuit in its frontmost window, so you
// can watch the agent work and undo its changes; otherwise, or with --headless, the server simulates on its own.
// --app insists on the app. --benchmark [seconds] [example…] times the engine alone at the audio sample rate,
// --benchmark-maker PART [seconds] a maker's op-amp model, --benchmark-switch NAME [seconds] [example…] the
// examples with one of the engine's switches off and on, and --benchmark-scale [seconds] [example…] the examples drawn
// several times over in one circuit.

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
        // the nonlinear block's factors below and right of its pivots, and the multiply-adds factoring it takes
        let block = simulator.blockFactorSize
        print("\(name)\(perStep) µs/step \(speed)× real time  \(simulator.convergenceFailures) unconverged  \(solves) solves/step"
              + "  error \(error) dB"
              + "  n \(size.unknowns) nz \(size.nonzeros) lu \(size.factorEntries) nl \(size.nonlinearUnknowns) plans \(simulator.plans) orders \(simulator.pivotOrders)"
              + "  block \(block.lower)+\(block.upper) ops \(block.operations)\(notes)")
    }
}

/// The engine's switches a benchmark can compare, each off against on (all are on as the app runs)
let switches: [String: (Bool) -> Void] = [
    // (changes nothing: what the benchmark makes of two settings alike)
    "nothing": { _ in },
    "reuse-factors": { Simulator.reusesFactors = $0 },
    "bypass": { Simulator.bypassesDevices = $0 },
    "pin-switches": { Simulator.followsPinSwitches = $0 },
    "rest-confirmation": { Simulator.restsConfirmation = $0 },
    "confirm-by-balance": { Simulator.confirmsByBalance = $0 },
    "reuse-past-still-columns": { Simulator.reusesPastStillColumns = $0 },
    "give-up-when-stalled": { Simulator.givesUpWhenStalled = $0 },
    "rest-reuse": { Simulator.restsReuse = $0 },
    "retry-from-memory": { Simulator.retriesFromMemory = $0 },
    "quadratic-predictor": { Simulator.predictsQuadratically = $0 },
    "rest-chords": { Simulator.restsChords = $0 },
    "choose-predictor": { Simulator.choosesPredictor = $0 },
    "reuse-everywhere": { Simulator.reusesFactorsEverywhere = $0 },
    "decode-ahead": { AVR.decodesAhead = $0 },
    "keep-switched-matrices": { Simulator.keepsSwitchedMatrices = $0 },
]

/// Simulates each example twice over, with one of the engine's switches off and on, in alternate runs of `seconds` of
/// circuit time (so the machine's ups and downs fall on both alike), and prints the time per step of the fastest of
/// five runs each, and what the switch saves
func benchmarkSwitch(_ name: String, seconds: Double, ids: [String]) {
    guard let flip = switches[name] else {
        log("there is no switch \(name); there are \(switches.keys.sorted().joined(separator: ", "))")
        exit(2)
    }
    let rate = 48_000.0
    let steps = max(1, Int(seconds * rate))
    for id in ids {
        guard let example = Examples.example(id) else {
            log("there is no example \(id)")
            continue
        }
        // each round, both simulators made afresh (the one made first taking turns) and run over the same stretch: a
        // simulator kept from round to round keeps where its memory fell, which alone made one setting an eighth slower
        // than the other where the switch changed nothing
        var fastest = [Double.infinity, .infinity]
        var counts = [[Int]](repeating: [Int](repeating: 0, count: 8), count: 2)
        for round in 0..<5 {
            var simulators: [Simulator?] = [nil, nil]
            for k in (round % 2 == 0 ? [0, 1] : [1, 0]) {
                flip(k == 1)
                let simulator = Simulator(circuit: example.circuit, timeStep: 1 / rate)
                simulator.errorControl = false
                simulators[k] = simulator
            }
            for k in 0..<2 {
                guard let simulator = simulators[k] else { continue }
                flip(k == 1)
                let start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<steps { simulator.step() }
                fastest[k] = min(fastest[k], Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
                let s = simulator
                for (j, value) in [s.newtonIterations, s.factorings, s.reusedFactorings, s.confirmedWithoutSolving,
                                   s.reusedStampings, s.restartedSolves, s.substeps, s.rejectedSubsteps].enumerated() {
                    counts[k][j] += value
                }
            }
        }
        flip(true)
        let per = Double(5 * steps)
        let solves = counts.map { Double($0[0]) / per }
        print(String(format: "%@ %@: off %.2f µs/step (%.2f solves), on %.2f µs/step (%.2f solves), on saves %.1f%%",
                     id.padding(toLength: 18, withPad: " ", startingAt: 0), name, fastest[0] / Double(steps) * 1e6, solves[0],
                     fastest[1] / Double(steps) * 1e6, solves[1], (1 - fastest[1] / fastest[0]) * 100))
        // where the iterations went, a step: factored, solved with kept factors, confirmed without a solve, started from
        // kept stamps, started again, and substeps (rejected)
        let detail = counts.map { c in
            String(format: "%.2f factored %.2f chord %.2f confirmed %.2f from kept stamps %.3f restarted %.3f substeps (%.3f rejected)",
                   Double(c[1]) / per, Double(c[2]) / per, Double(c[3]) / per, Double(c[4]) / per, Double(c[5]) / per,
                   Double(c[6]) / per, Double(c[7]) / per)
        }
        print("    off: \(detail[0])\n    on:  \(detail[1])")
    }
}

/// Simulates each example for `seconds` of circuit time at 48 kHz without error control (as the sound runs it), and
/// prints how many substeps Newton-Raphson gave up on (to be done in halves), the unknowns that moved most at the last
/// iteration of those it gave up on, and the first two such steps iteration by iteration
func benchmarkRejections(seconds: Double, ids: [String]) {
    let rate = 48_000.0
    let steps = max(1, Int(seconds * rate))
    for id in ids {
        guard let example = Examples.example(id) else {
            log("there is no example \(id)")
            continue
        }
        let simulator = Simulator(circuit: example.circuit, timeStep: 1 / rate)
        simulator.errorControl = false
        var lines: [String] = []
        simulator.trace = { lines.append($0) }
        var printed = 0
        var mostMoved: [String: Int] = [:]
        var rejectingSteps: [Int] = []
        for step in 0..<steps where !simulator.isFailed {
            lines.removeAll(keepingCapacity: true)
            let before = simulator.rejectedSubsteps
            simulator.step()
            guard simulator.rejectedSubsteps > before else { continue }
            rejectingSteps.append(step)
            var lastIteration = ""
            for line in lines {
                if line.hasPrefix("    iteration") { lastIteration = line }
                if line.hasPrefix("  substep") && line.contains("rejected") {
                    let moved = lastIteration.range(of: " at ").map { String(lastIteration[$0.upperBound...]) } ?? "?"
                    // (without the value it is at now)
                    let unknown = moved.range(of: " (now").map { String(moved[..<$0.lowerBound]) } ?? moved
                    mostMoved[unknown, default: 0] += 1
                }
            }
            if printed < 2 {
                printed += 1
                print("\(id): step \(step), \(lines.count) lines of trace:")
                for line in lines.prefix(150) { print(line) }
                if lines.count > 150 { print("  … \(lines.count - 150) lines more") }
            }
        }
        var gaps: [Int: Int] = [:]
        for k in rejectingSteps.indices.dropFirst() { gaps[rejectingSteps[k] - rejectingSteps[k - 1], default: 0] += 1 }
        let first = rejectingSteps.prefix(12).map { String($0) }.joined(separator: " ")
        let often = gaps.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) (\($0.value)×)" }.joined(separator: ", ")
        print("\(id): \(simulator.rejectedSubsteps) substeps given up of \(simulator.substeps) kept, in \(rejectingSteps.count) of "
              + "\(steps) steps; the first at steps \(first); steps between them most often \(often)")
        for (unknown, count) in mostMoved.sorted(by: { $0.value > $1.value }).prefix(6) {
            print("    \(count)× moving most at the last iteration: \(unknown)")
        }
    }
}

/// Simulates each example (one with a microcontroller) for `seconds`, untimed and then counting the chip's instructions:
/// prints the time per step, the instructions run a step and the time each took (the circuit's share included), and
/// the instructions most run, by kind
func benchmarkInstructions(seconds: Double, ids: [String]) {
    let rate = 48_000.0
    let steps = max(1, Int(seconds * rate))
    for id in ids {
        guard let example = Examples.example(id) else {
            log("there is no example \(id)")
            continue
        }
        let timed = Simulator(circuit: example.circuit, timeStep: 1 / rate)
        timed.errorControl = false
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<steps where !timed.isFailed { timed.step() }
        let nanosPerStep = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(steps)
        AVR.instructionCounts = [Int](repeating: 0, count: 256)
        Pico.instructionCounts = [Int](repeating: 0, count: 256)
        AVR.countsInstructions = true
        Pico.countsInstructions = true
        let counted = Simulator(circuit: example.circuit, timeStep: 1 / rate)
        counted.errorControl = false
        for _ in 0..<steps where !counted.isFailed { counted.step() }
        AVR.countsInstructions = false
        Pico.countsInstructions = false
        for (chip, counts, name) in [("AVR", AVR.instructionCounts, AVR.instructionName),
                                     ("RP2040", Pico.instructionCounts, Pico.instructionName)] {
            let total = counts.reduce(0, +)
            guard total > 0 else { continue }
            let perStep = Double(total) / Double(steps)
            print("\(id) (\(chip)): " + String(format: "%.2f µs/step, %.0f instructions/step, %.2f ns each", nanosPerStep / 1000,
                                                    perStep, nanosPerStep / perStep))
            let most = counts.enumerated().filter { $0.element > 0 }.sorted { $0.element > $1.element }.prefix(16)
            print("    " + most.map { name($0.offset) + String(format: " %.1f%%", 100 * Double($0.element) / Double(total)) }
                .joined(separator: ", "))
        }
    }
}

/// The circuit drawn `count` times side by side, each copy on nets of its own (its net labels renamed, but for ground):
/// a bigger circuit of the same parts, for how the engine's cost grows with a circuit's size
func copies(of circuit: Circuit, _ count: Int) -> Circuit {
    guard count > 1, let bounds = circuit.bounds else { return circuit }
    let width = bounds.max.x - bounds.min.x + 8
    var result = circuit
    result.elements = []
    result.scopes = []
    for copy in 0..<count {
        for var element in circuit.elements {
            if copy > 0 { element.id = UUID() }
            element.a.x += copy * width
            element.b.x += copy * width
            let label = element.name.trimmingCharacters(in: .whitespaces).lowercased()
            if element.kind == .netLabel && copy > 0 && !["gnd", "0", "ground"].contains(label) {
                element.name += "_\(copy)"
            }
            result.elements.append(element)
        }
    }
    return result
}

/// Simulates each example drawn once, twice, four and eight times over in one circuit, for `seconds` of circuit time
/// at 48 kHz as the sound runs it, and prints the time per step per copy (flat where the cost grows with the size),
/// solves a step, and the nonlinear block's size and factors
func benchmarkScale(seconds: Double, ids: [String]) {
    let rate = 48_000.0
    let steps = max(1, Int(seconds * rate))
    for id in ids {
        guard let example = Examples.example(id) else {
            log("there is no example \(id)")
            continue
        }
        var single = 0.0
        for count in [1, 2, 4, 8] {
            let simulator = Simulator(circuit: copies(of: example.circuit, count), timeStep: 1 / rate)
            simulator.errorControl = false
            var fastest = Double.infinity
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<steps { simulator.step() }
                fastest = min(fastest, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            }
            let perStep = fastest / Double(steps) * 1e6
            if count == 1 { single = perStep }
            let size = simulator.equationStatistics
            let factors = simulator.blockFactorSize
            print(String(format: "%@ ×%d %8.2f µs/step %6.2f a copy (%.2f× one's) %5.2f solves/step  n %d nl %d L %d U %d ops %d%@",
                         id.padding(toLength: 18, withPad: " ", startingAt: 0), count, perStep, perStep / Double(count),
                         perStep / Double(count) / single, Double(simulator.newtonIterations) / Double(3 * steps),
                         size.unknowns, size.nonlinearUnknowns, factors.lower, factors.upper, factors.operations,
                         simulator.isFailed ? " FAILED" : ""))
        }
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
          + "that moved, \(simulator.chatteringSolves) left chattering, \(simulator.memoryRetries) started again from a solution "
          + "before the decisions moved (\(simulator.memoryRetriesConverged) converged); \(simulator.bypassedEvaluations) behavioural sources' "
          + "evaluations bypassed (\(simulator.straightBypasses) on straight stretches); \(simulator.confirmedWithoutSolving) iterations confirmed without a solve; "
          + "\(simulator.reusedStampings) first iterations started from the confirmed stamps, "
          + "\(simulator.restartedSolves) started again without them")
    let busiest = simulator.mostEvaluatedSources(6)
    print("\(part): the behavioural sources run most, in outline (times run; reach at the last run, in volts or amps): "
          + busiest.map { "[\($0.outline)] (\($0.evaluations); \(String(format: "%.3g", $0.reach))\($0.decides ? ", decides" : ""))" }
          .joined(separator: "; "))
    let block = simulator.blockFactorSize
    print("\(part)'s model as simulated: \(size.unknowns) unknowns, \(size.nonzeros) nonzeros, \(size.factorEntries) entries "
          + "factored, \(size.nonlinearUnknowns) nonlinear (its factors \(block.lower) below and \(block.upper) right of the "
          + "pivots, \(block.operations) multiply-adds to factor); \(made)")
    print(String(format: "%@ %@, 1 kHz at 48 kHz: %.1f µs/step (the fastest fifth %.1f), %.2f× real time, %.2f Newton iterations a step "
                 + "(%ld factored, %ld with kept factors, %ld factorings taken up again), %ld unknowns, %ld in the nonlinear block%@",
                 part, stages > 1 ? "\(stages) followers in a row" : "follower", elapsed / Double(done) * 1e6,
                 fastest.isFinite ? fastest / 1e3 : elapsed / Double(done) * 1e6, Double(done) / 48_000 / elapsed,
                 Double(simulator.newtonIterations) / Double(done), simulator.factorings, simulator.reusedFactorings,
                 simulator.restoredFactorings, shape.unknowns, shape.nonlinear, simulator.isFailed ? " FAILED: " + simulator.problems.joined(separator: "; ") : ""))
    // where steps take many iterations, the heaviest of the second and third cycles, iteration by iteration
    guard heaviest > 30 else { return }
    let traced = Simulator(circuit: circuit, timeStep: 1 / 48_000)
    traced.errorControl = false
    var lines: [String] = [], kept: [String] = [], most = 0, keptStep = 0, ordinary: [String] = []
    traced.trace = { lines.append($0) }
    for step in 0..<144 where !traced.isFailed {
        lines.removeAll(keepingCapacity: true)
        let before = traced.newtonIterations
        traced.step()
        let taken = traced.newtonIterations - before
        if step >= 48 && taken > most { (most, kept, keptStep) = (taken, lines, step) }
        // and one between the crossings (at 90°)
        if step == 59 { ordinary = lines }
    }
    print("\(part): an ordinary step, step 59 (ending at 90°):")
    for line in ordinary.prefix(40) { print(line) }
    print("\(part): the heaviest step of the second and third cycles, step \(keptStep) (ending at \((keptStep + 1) % 48 * 15 / 2)°), "
          + "\(most) iterations:")
    for line in kept.prefix(300) { print(line) }
    if kept.count > 300 { print("  … \(kept.count - 300) lines more") }
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

// --benchmark-switch NAME [seconds] [example…]: the examples with one of the engine's switches off and on
if let flag = arguments.firstIndex(of: "--benchmark-switch"), flag + 1 < arguments.count {
    var rest = Array(arguments[(flag + 2)...])
    var seconds = 0.25
    if let first = rest.first, let value = Double(first), value > 0, value < 1e4 {
        seconds = value
        rest.removeFirst()
    }
    benchmarkSwitch(arguments[flag + 1], seconds: seconds, ids: rest.isEmpty ? Examples.all.map(\.id) : rest)
    exit(0)
}

// --benchmark-rejections [seconds] [example…]: where Newton-Raphson gives substeps up
if let flag = arguments.firstIndex(of: "--benchmark-rejections") {
    var rest = Array(arguments[(flag + 1)...])
    var seconds = 0.25
    if let first = rest.first, let value = Double(first), value > 0, value < 1e4 {
        seconds = value
        rest.removeFirst()
    }
    benchmarkRejections(seconds: seconds, ids: rest.isEmpty ? ["voice"] : rest)
    exit(0)
}

// --benchmark-instructions [seconds] [example…]: what the microcontrollers' instructions cost, and which run most
if let flag = arguments.firstIndex(of: "--benchmark-instructions") {
    var rest = Array(arguments[(flag + 1)...])
    var seconds = 0.25
    if let first = rest.first, let value = Double(first), value > 0, value < 1e4 {
        seconds = value
        rest.removeFirst()
    }
    benchmarkInstructions(seconds: seconds, ids: rest.isEmpty ? ["pico-knob", "arduino-fade"] : rest)
    exit(0)
}

// --benchmark-scale [seconds] [example…]: the examples drawn 1, 2, 4 and 8 times over in one circuit
if let flag = arguments.firstIndex(of: "--benchmark-scale") {
    var rest = Array(arguments[(flag + 1)...])
    var seconds = 0.1
    if let first = rest.first, let value = Double(first), value > 0, value < 1e4 {
        seconds = value
        rest.removeFirst()
    }
    benchmarkScale(seconds: seconds, ids: rest.isEmpty ? ["voice", "acid"] : rest)
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
