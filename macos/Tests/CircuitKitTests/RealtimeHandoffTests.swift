import XCTest
import Foundation
#if canImport(Glibc)
import Glibc
#endif
@testable import CircuitKit

/// The hand-offs between the Audio Unit's render thread and the rest, hammered from threads, and the engine built on
/// them playing circuits as the Audio Unit does
final class RealtimeHandoffTests: XCTestCase {
    /// Runs `body` on a thread of its own; the returned semaphore is signalled when it is done
    private func spawn(_ body: @escaping @Sendable () -> Void) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            body()
            done.signal()
        }
        thread.stackSize = 1 << 20
        thread.start()
        return done
    }

    // MARK: Parameter table

    func testKnobMovesArriveInOrderAndNoneIsLost() {
        let table = ParameterTable(capacity: 16)
        table.reset([Double](repeating: -1, count: 8))
        let start = table.currentVersion
        let moves = 300_000
        // slots 0–3 moved the way the render thread moves them (try, and keep what could not go in), 4–7 by another
        // thread waiting for the lock; each slot's values only rise
        let realtime = spawn {
            let pending = PendingParameters(capacity: 16)
            for n in 0..<moves {
                pending.write(n % 4, Double(n), to: table)
            }
            repeat { pending.flush(to: table) } while !pending.isEmpty
        }
        let other = spawn {
            for n in 0..<moves { table.set(4 + n % 4, Double(n)) }
        }
        let finals: [Double] = (0..<4).map { Double(moves - 4 + $0) } + (0..<4).map { Double(moves - 4 + $0) }
        let reader = LockedBox<String?>(nil)
        let consumer = spawn {
            var seen = [Double](repeating: -1, count: 8)
            var since = start
            var reads = 0
            while seen != finals {
                let (version, changed) = table.changes(since: since)
                if version < since { reader.set("the version went back"); return }
                since = version
                for (k, value) in changed {
                    // a change is reported once, and never an older value after a newer
                    if value <= seen[k] { reader.set("slot \(k) went from \(seen[k]) to \(value)"); return }
                    seen[k] = value
                }
                reads += 1
            }
            if reads < 2 { reader.set("the reader saw too little to test anything") }
        }
        realtime.wait()
        other.wait()
        XCTAssertEqual(consumer.wait(timeout: .now() + 60), .success)
        XCTAssertNil(reader.get())
        XCTAssertEqual((0..<8).map { table.value($0) }, finals)
    }

    // MARK: Exchange

    final class Token {
        let id: Int
        let freedOn: LockedBox<[Int]>
        let realtime: LockedBox<pthread_t?>
        /// Set once the producer has taken it back from the retire list
        let collected = LockedBox(false)
        init(_ id: Int, freedOn: LockedBox<[Int]>, realtime: LockedBox<pthread_t?>) {
            self.id = id
            self.freedOn = freedOn
            self.realtime = realtime
        }
        deinit {
            // never freed on the render thread
            if let rt = realtime.get(), pthread_equal(rt, pthread_self()) != 0 { freedOn.update { $0.append(id) } }
        }
    }

    func testSwappingUnderLoadNeverFreesOnTheRenderThreadNorUsesWhatWasRetired() {
        let exchange = ObjectExchange(retireCapacity: 4)
        let count = 200_000
        let freedOnRealtime = LockedBox<[Int]>([])
        let realtimeThread = LockedBox<pthread_t?>(nil)
        let problem = LockedBox<String?>(nil)
        let started = DispatchSemaphore(value: 0)
        let consumer = spawn {
            realtimeThread.set(pthread_self())
            started.signal()
            var live: AnyObject?
            var retiring: AnyObject?
            var last = 0
            var swaps = 0
            while last < count {
                if let done = retiring, exchange.tryRetire(done) { retiring = nil }
                if retiring == nil, let object = exchange.tryTake() {
                    let token = unsafeDowncast(object, to: Token.self)
                    // offered in order: each taken is newer than the last, none twice
                    if token.id <= last { problem.set("took \(token.id) after \(last)"); return }
                    last = token.id
                    retiring = live
                    live = token
                    swaps += 1
                }
                // using the one playing: it must not have been given back and collected
                if let live, unsafeDowncast(live, to: Token.self).collected.get() {
                    problem.set("played \(unsafeDowncast(live, to: Token.self).id) after it was retired")
                    return
                }
            }
            // the render thread ends: what it holds is handed back, not freed here
            while let done = retiring ?? live {
                if exchange.tryRetire(done) {
                    if retiring != nil { retiring = nil } else { live = nil }
                }
            }
            if swaps < 10 { problem.set("only \(swaps) swaps") }
        }
        started.wait()
        @Sendable func collect() {
            for object in exchange.collectRetired() { unsafeDowncast(object, to: Token.self).collected.set(true) }
        }
        let producer = spawn {
            for id in 1...count {
                let replaced = exchange.offer(Token(id, freedOn: freedOnRealtime, realtime: realtimeThread))
                _ = replaced
                if id % 16 == 0 { collect() }
            }
        }
        producer.wait()
        // the render thread finishes once it has taken the last; what it gives back is collected meanwhile
        let deadline = Date().addingTimeInterval(120)
        while consumer.wait(timeout: .now() + 0.005) == .timedOut && Date() < deadline { collect() }
        collect()
        _ = exchange.withdraw()
        XCTAssertNil(problem.get())
        XCTAssertEqual(freedOnRealtime.get(), [])
    }

    // MARK: Load monitor

    func testTheMonitorAsksForFewerStepsOnlyWhenTheCircuitKeepsFallingBehind() {
        var monitor = RenderLoadMonitor()
        let budget = 64 / 48_000.0
        // light: never
        for _ in 0..<2_000 { XCTAssertFalse(monitor.record(busy: 0.3 * budget, budget: budget)) }
        XCTAssertFalse(monitor.overloaded)
        XCTAssertEqual(monitor.load, 0.3, accuracy: 1e-9)
        // one stray slow call: no
        XCTAssertFalse(monitor.record(busy: 3 * budget, budget: budget))
        for _ in 0..<500 { XCTAssertFalse(monitor.record(busy: 0.3 * budget, budget: budget)) }
        XCTAssertFalse(monitor.overloaded)
        // too heavy for half a second: yes
        var asked = false
        for _ in 0..<(48_000 / 64) { asked = monitor.record(busy: 0.95 * budget, budget: budget) || asked }
        XCTAssertTrue(asked)
        XCTAssertTrue(monitor.overloaded)
        // two seconds of ease clear it
        for _ in 0..<(3 * 48_000 / 64) { _ = monitor.record(busy: 0.2 * budget, budget: budget) }
        XCTAssertFalse(monitor.overloaded)
    }

    // MARK: Engine

    static let rate = 48_000.0

    /// Plays blocks through the engine as the Audio Unit's render callback does; the script runs before each block
    /// (knob moves through the model, then the background's work done at once so the swap happens at that block)
    static func play(_ engine: PluginEngine, blocks: Int, script: [Int: [PluginCharacterizationTests.Action]],
                     busy: Double = 0) -> [Double] {
        var phase = 0.0
        var levels: [Double] = []
        for b in 0..<blocks {
            var notes: [PluginCharacterizationTests.Action] = []
            for action in script[b] ?? [] {
                if case .knob(let k, let v) = action { engine.setControl(k, v) } else { notes.append(action) }
            }
            engine.prepareNow()
            let frames = PluginCharacterizationTests.blockSizes[b % PluginCharacterizationTests.blockSizes.count]
            var input = [Float](repeating: 0, count: frames)
            for k in 0..<frames {
                input[k] = Float(0.5 * sin(phase))
                phase += 2 * .pi * 220 / rate
            }
            var output = [Float](repeating: 0, count: frames)
            engine.beginRender()
            if let processor = engine.processor {
                for action in notes {
                    if case .noteOn(let n) = action { processor.noteOn(n) }
                    if case .noteOff(let n) = action { processor.noteOff(n) }
                }
                input.withUnsafeBufferPointer { i in
                    output.withUnsafeMutableBufferPointer { o in
                        processor.process(input: processor.hasInput ? i.baseAddress : nil, output: o.baseAddress!, frames: frames)
                    }
                }
            }
            engine.endRender(busy: busy * Double(frames) / rate, budget: Double(frames) / rate)
            levels.append((output.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(frames)).squareRoot())
        }
        return levels
    }

    static func engine(_ circuit: Circuit) -> PluginEngine {
        let engine = PluginEngine()
        engine.load(circuit)
        engine.allocate(sampleRate: rate, maximumFrames: 4096)
        return engine
    }

    /// The engine (each knob move a new processor taking over the running state) sounds as the processor moving its
    /// knobs in place does
    private func assertSoundsAsInPlace(_ name: String, instrument: Bool = false, blocks: Int,
                                       script: [Int: [PluginCharacterizationTests.Action]]) throws {
        let circuit = try PluginCharacterizationTests.circuit(name, instrument: instrument)
        let inPlace = try XCTUnwrap(CircuitProcessor(circuit: circuit, sampleRate: Self.rate))
        let expected = PluginCharacterizationTests.fingerprint(inPlace, blocks: blocks, script: script)
        let engine = Self.engine(circuit)
        let levels = Self.play(engine, blocks: blocks, script: script)
        XCTAssertEqual(levels.count, expected.count)
        let worst = zip(levels, expected).map { abs($0 - $1) / max($1, 1e-3) }.max() ?? 0
        print("\(name): the engine's levels differ from moving the knobs in place by at most \(worst * 100)%")
        for (k, (a, b)) in zip(levels, expected).enumerated() {
            XCTAssertEqual(a, b, accuracy: 1e-5 + 1e-2 * b, "\(name), block \(k)")
        }
        XCTAssertEqual(engine.status.stepsPerSample, PluginEngine.oversampling)
        XCTAssertFalse(engine.status.overloaded)
    }

    func testAKnobMovedThroughTheEngineSoundsAsMovedInPlace() throws {
        try assertSoundsAsInPlace("Fuzz Face on a guitar riff", blocks: 30, script: PluginCharacterizationTests.effectScript)
    }

    func testAnEchoKeepsItsRepeatsThroughKnobMoves() throws {
        try assertSoundsAsInPlace("PT2399 echo", blocks: 30, script: PluginCharacterizationTests.effectScript)
    }

    func testAnInstrumentKeepsItsNotesThroughKnobMoves() throws {
        try assertSoundsAsInPlace("Synth voice", instrument: true, blocks: 32, script: PluginCharacterizationTests.instrumentScript)
    }

    func testAKnobMoveFromTheRenderThreadReachesTheModelAndTheNextProcessor() throws {
        let engine = Self.engine(try PluginCharacterizationTests.circuit("Fuzz Face on a guitar riff"))
        _ = Self.play(engine, blocks: 2, script: [:])
        let first = try XCTUnwrap(engine.processor)
        engine.requestControl(1, 0.25)
        engine.prepareNow()
        XCTAssertEqual(engine.controlValue(1), 0.25)
        engine.beginRender()
        let second = try XCTUnwrap(engine.processor)
        XCTAssertFalse(first === second)
        XCTAssertEqual(second.controls[1].value, 0.25)
        XCTAssertEqual(engine.circuit.map { CircuitProcessor.controls(of: $0)[1].value }, 0.25)
        // an unchanged model makes nothing new
        engine.prepareNow()
        engine.beginRender()
        XCTAssertTrue(engine.processor === second)
    }

    func testASwitchThatJoinsNodesStartsAfreshAndAPresetLoadsInTheBackground() throws {
        let bypass = try PluginCharacterizationTests.circuit("3PDT true bypass")
        let engine = Self.engine(bypass)
        _ = Self.play(engine, blocks: 4, script: [:])
        let before = try XCTUnwrap(engine.processor)
        let levels = Self.play(engine, blocks: 12, script: [1: [.knob(0, 1)]])
        let after = try XCTUnwrap(engine.processor)
        XCTAssertFalse(before === after)
        XCTAssertEqual(after.controls[0].value, 1)
        XCTAssertNotEqual(before.shapeKey, after.shapeKey)
        XCTAssertTrue(levels.allSatisfy { $0.isFinite && $0 <= 1 })
        XCTAssertFalse(after.isFailed)
        // another circuit: the old one plays until the new one is taken
        engine.load(try PluginCharacterizationTests.circuit("Fuzz Face on a guitar riff"))
        engine.prepareNow()
        XCTAssertEqual(engine.controls.map(\.name), ["FUZZ", "VOLUME"])
        let level = Self.play(engine, blocks: 20, script: [:])
        XCTAssertEqual(engine.processor?.controls.map(\.name), ["FUZZ", "VOLUME"])
        XCTAssertGreaterThan(level.max() ?? 0, 0.01)
    }

    func testACircuitTooHeavyForTheBufferRunsFewerStepsAndSaysSo() throws {
        let engine = Self.engine(try PluginCharacterizationTests.circuit("Fuzz Face on a guitar riff"))
        XCTAssertEqual(Self.play(engine, blocks: 2, script: [:]).count, 2)
        XCTAssertEqual(engine.status.stepsPerSample, 2)
        // render calls that take nearly all of their buffer's time
        var levels: [Double] = []
        for _ in 0..<200 { levels += Self.play(engine, blocks: 1, script: [:], busy: 0.95) }
        XCTAssertTrue(engine.status.overloaded)
        XCTAssertEqual(engine.processor?.oversampling, 1)
        XCTAssertEqual(engine.status.stepsPerSample, 1)
        XCTAssertTrue(levels.allSatisfy { $0.isFinite })
        // no lower than one
        for _ in 0..<80 { _ = Self.play(engine, blocks: 1, script: [:], busy: 0.95) }
        XCTAssertEqual(engine.processor?.oversampling, 1)
        // another circuit starts at the full steps again
        engine.load(try PluginCharacterizationTests.circuit("Fuzz Face with a humbucker"))
        _ = Self.play(engine, blocks: 60, script: [:])
        XCTAssertEqual(engine.processor?.oversampling, 2)
        XCTAssertEqual(engine.status.stepsPerSample, 2)
    }

    func testPreparingAKnobMoveTakesLittleTime() throws {
        let engine = Self.engine(try PluginCharacterizationTests.circuit("Synth voice", instrument: true))
        _ = Self.play(engine, blocks: 2, script: [:])
        let started = Date()
        for k in 0..<10 { _ = Self.play(engine, blocks: 1, script: [0: [.knob(0, 0.1 * Double(k))]]) }
        let each = Date().timeIntervalSince(started) / 10
        print("preparing a knob move on a \(engine.circuit?.flattened().elements.count ?? 0)-part circuit: \(Int(each * 1000)) ms")
        XCTAssertLessThan(each, 2)
    }
}

/// A value shared between test threads
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: Value) { lock.lock(); value = new; lock.unlock() }
    func update(_ body: (inout Value) -> Void) { lock.lock(); body(&value); lock.unlock() }
}
