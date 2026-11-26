import Foundation
#if canImport(Darwin)
import Darwin
#if canImport(os)
import os
#endif
#elseif canImport(Glibc)
import Glibc
#endif

// Hand-offs between a real-time thread (an Audio Unit's render callback) and the rest of the program.
//
// The rule they keep: the real-time thread never waits and never frees memory. Everything here is guarded by a small
// lock that the other threads hold only for a few loads and stores (never while allocating, freeing or calling out),
// and that the real-time thread only ever *tries*: when another thread holds it at that instant, the real-time thread
// skips the hand-off and tries again on its next call. A lock gives the memory ordering for free (whatever was written
// before an unlock is seen by the thread that next takes the lock), so there is no atomics reasoning to get wrong, and
// the package needs neither `Synchronization` (macOS 15) nor a C target.
//
// Objects handed to the real-time thread are retained and released there (an atomic count, no lock, no free); the
// last reference to one is always dropped on another thread, which takes it back through `ObjectExchange`'s retire list.

/// A lock the real-time side only ever tries (`tryLock`); other threads may wait for it (`lock`). It must be unlocked by
/// the thread that took it.
public final class TryLock: @unchecked Sendable {
    #if canImport(Darwin)
    // os_unfair_lock must not move once in use, so it lives in memory of its own rather than in a stored property
    private let raw: UnsafeMutablePointer<os_unfair_lock>

    public init() {
        raw = .allocate(capacity: 1)
        raw.initialize(to: os_unfair_lock())
    }

    deinit {
        raw.deinitialize(count: 1)
        raw.deallocate()
    }

    @inline(__always) public func lock() { os_unfair_lock_lock(raw) }
    @inline(__always) public func tryLock() -> Bool { os_unfair_lock_trylock(raw) }
    @inline(__always) public func unlock() { os_unfair_lock_unlock(raw) }
    #else
    private let raw: UnsafeMutablePointer<pthread_mutex_t>

    public init() {
        raw = .allocate(capacity: 1)
        raw.initialize(to: pthread_mutex_t())
        pthread_mutex_init(raw, nil)
    }

    deinit {
        pthread_mutex_destroy(raw)
        raw.deinitialize(count: 1)
        raw.deallocate()
    }

    @inline(__always) public func lock() { pthread_mutex_lock(raw) }
    @inline(__always) public func tryLock() -> Bool { pthread_mutex_trylock(raw) == 0 }
    @inline(__always) public func unlock() { pthread_mutex_unlock(raw) }
    #endif

    /// Waits for the lock: never on the real-time thread
    @inline(__always) public func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// Knob and switch positions by index, written by any thread and read by the thread that builds processors. Moves
/// coalesce: a reader sees each slot's latest value, never an older one after a newer, and each change at most once
/// (`changes(since:)`). The storage is allocated once, so no write allocates.
public final class ParameterTable: @unchecked Sendable {
    public let capacity: Int
    private let lock = TryLock()
    private let values: UnsafeMutablePointer<Double>
    /// The table's version when each slot last changed
    private let versions: UnsafeMutablePointer<UInt64>
    private var version: UInt64 = 0
    private var used = 0

    public init(capacity: Int) {
        self.capacity = max(capacity, 1)
        values = .allocate(capacity: self.capacity)
        values.initialize(repeating: 0, count: self.capacity)
        versions = .allocate(capacity: self.capacity)
        versions.initialize(repeating: 0, count: self.capacity)
    }

    deinit {
        values.deallocate()
        versions.deallocate()
    }

    /// Must be called with the lock held
    @inline(__always) private func store(_ index: Int, _ value: Double) {
        guard index >= 0, index < used, values[index] != value else { return }
        version &+= 1
        values[index] = value
        versions[index] = version
    }

    /// Starts again with these slots (a new circuit's controls)
    public func reset(_ initial: [Double]) {
        lock.withLock {
            used = min(initial.count, capacity)
            version &+= 1
            for k in 0..<used {
                values[k] = initial[k]
                versions[k] = version
            }
        }
    }

    /// Any thread but the real-time one
    public func set(_ index: Int, _ value: Double) {
        lock.withLock { store(index, value) }
    }

    /// The real-time thread: false (and nothing written) if another thread held the table at that instant
    public func trySet(_ index: Int, _ value: Double) -> Bool {
        guard lock.tryLock() else { return false }
        store(index, value)
        lock.unlock()
        return true
    }

    /// The real-time thread: everything `pending` holds, in one go; false if the table was busy (`pending` keeps it)
    public func tryApply(_ pending: PendingParameters) -> Bool {
        if pending.isEmpty { return true }
        guard lock.tryLock() else { return false }
        for k in 0..<min(pending.capacity, capacity) where pending.dirty[k] {
            store(k, pending.values[k])
            pending.dirty[k] = false
        }
        pending.isEmpty = true
        lock.unlock()
        return true
    }

    public func value(_ index: Int) -> Double {
        lock.withLock { index >= 0 && index < used ? values[index] : 0 }
    }

    public var currentVersion: UInt64 { lock.withLock { version } }

    /// Every slot's value, and the version they are at
    public func snapshot() -> (version: UInt64, values: [Double]) {
        var copy = [Double](repeating: 0, count: capacity)
        let (v, n) = lock.withLock { () -> (UInt64, Int) in
            for k in 0..<used { copy[k] = values[k] }
            return (version, used)
        }
        return (v, Array(copy[0..<n]))
    }

    /// The slots changed after version `since`, in index order, and the version now
    public func changes(since: UInt64) -> (version: UInt64, changed: [(index: Int, value: Double)]) {
        var changed: [(index: Int, value: Double)] = []
        changed.reserveCapacity(capacity)
        let v = lock.withLock { () -> UInt64 in
            for k in 0..<used where versions[k] > since { changed.append((k, values[k])) }
            return version
        }
        return (v, changed)
    }
}

/// The real-time thread's own note of moves it could not hand over yet (the table was busy): kept by slot, the latest
/// winning, so that once handed over nothing older overwrites something newer. Used by that thread alone.
public final class PendingParameters: @unchecked Sendable {
    public let capacity: Int
    let values: UnsafeMutablePointer<Double>
    let dirty: UnsafeMutablePointer<Bool>
    var isEmpty = true

    public init(capacity: Int) {
        self.capacity = max(capacity, 1)
        values = .allocate(capacity: self.capacity)
        values.initialize(repeating: 0, count: self.capacity)
        dirty = .allocate(capacity: self.capacity)
        dirty.initialize(repeating: false, count: self.capacity)
    }

    deinit {
        values.deallocate()
        dirty.deallocate()
    }

    /// Hands `value` for `index` to `table` now if it can, else keeps it for `flush`. Order per slot is kept: a move
    /// goes straight in only when nothing is waiting.
    public func write(_ index: Int, _ value: Double, to table: ParameterTable) {
        guard index >= 0, index < capacity else { return }
        if isEmpty && table.trySet(index, value) { return }
        values[index] = value
        dirty[index] = true
        isEmpty = false
        _ = table.tryApply(self)
    }

    /// Tries again to hand over what is waiting
    public func flush(to table: ParameterTable) {
        if !isEmpty { _ = table.tryApply(self) }
    }
}

/// One object offered at a time from a preparing thread to the real-time thread, and the objects that thread is done
/// with taken back to be freed elsewhere.
///
/// Objects are `AnyObject` rather than a generic parameter so that the real-time side runs no unspecialized generic
/// code (which can look up type metadata at run time); callers cast back with `unsafeDowncast`.
public final class ObjectExchange: @unchecked Sendable {
    private let lock = TryLock()
    private var offered: AnyObject?
    private let retired: UnsafeMutablePointer<AnyObject?>
    private let retireCapacity: Int
    private var retiredCount = 0

    public init(retireCapacity: Int = 8) {
        self.retireCapacity = max(retireCapacity, 1)
        retired = .allocate(capacity: self.retireCapacity)
        retired.initialize(repeating: nil, count: self.retireCapacity)
    }

    deinit {
        retired.deinitialize(count: retireCapacity)
        retired.deallocate()
    }

    /// Offers `object` in place of whatever was offered and not yet taken, which is handed back (to be released by the
    /// caller, not here under the lock)
    @discardableResult
    public func offer(_ object: AnyObject) -> AnyObject? {
        lock.withLock {
            let previous = offered
            offered = object
            return previous
        }
    }

    /// Takes back what was offered and not taken
    public func withdraw() -> AnyObject? {
        lock.withLock {
            let previous = offered
            offered = nil
            return previous
        }
    }

    /// Whatever is offered and not yet taken (it may be taken a moment later)
    public func peek() -> AnyObject? {
        lock.withLock { offered }
    }

    /// The real-time thread: what is offered, if anything and if the exchange was free at that instant
    public func tryTake() -> AnyObject? {
        guard lock.tryLock() else { return nil }
        let object = offered
        offered = nil
        lock.unlock()
        return object
    }

    /// The real-time thread: gives back an object it no longer uses, *moving* the caller's reference into the retire
    /// list (`object` is nil afterwards). True if it went (or there was nothing to give); false (keep it, and try again
    /// later) when the exchange was busy or the list is full, and `object` is then untouched.
    ///
    /// The move happens under the lock on purpose: if the caller kept a reference of its own while handing over a copy
    /// (`if let o = held, tryRetire(o) { held = nil }`), the collecting thread could take and drop the list's reference
    /// before the caller dropped its own, and the object would then be freed on the real-time thread.
    public func tryRetire(_ object: inout AnyObject?) -> Bool {
        guard object != nil else { return true }
        guard lock.tryLock() else { return false }
        defer { lock.unlock() }
        guard retiredCount < retireCapacity else { return false }
        retired[retiredCount] = object
        object = nil
        retiredCount += 1
        return true
    }

    /// The objects given back since the last call: the caller drops them (outside the lock), which frees them on its
    /// own thread
    public func collectRetired() -> [AnyObject] {
        var taken: [AnyObject] = []
        taken.reserveCapacity(retireCapacity)
        lock.withLock {
            for k in 0..<retiredCount {
                if let object = retired[k] { taken.append(object) }
                retired[k] = nil
            }
            retiredCount = 0
        }
        return taken
    }
}

/// Watches how long each render call takes against the time its buffer lasts, and says when the circuit cannot keep up.
/// Pure arithmetic: the caller measures (on the render thread, with `mach_absolute_time`) and acts.
public struct RenderLoadMonitor: Sendable {
    /// Seconds of audio in each judgement
    public var window = 0.25
    /// Fraction of a buffer's time that is too much to spend on it: the host has other work in the same deadline
    public var heavy = 0.7
    private var busy = 0.0
    private var budget = 0.0
    private var nearMisses = 0
    private var heavyWindows = 0
    private var calmWindows = 0
    /// Time spent over time available, in the last window
    public private(set) var load = 0.0
    /// Whether the circuit has recently been too heavy to keep up (stays set until two seconds of ease)
    public private(set) var overloaded = false

    public init() {}

    /// Judges afresh (another processor started): what was measured so far no longer counts; the overload shown stays
    /// until the new one has shown it can keep up
    public mutating func restart() {
        (busy, budget, nearMisses, heavyWindows) = (0, 0, 0, 0)
    }

    /// One render call that took `busy` seconds for a buffer lasting `budget`; true when it should run fewer steps
    public mutating func record(busy: Double, budget: Double) -> Bool {
        guard budget > 0, busy >= 0 else { return false }
        self.busy += busy
        self.budget += budget
        if busy > 0.9 * budget { nearMisses += 1 }
        guard self.budget >= window else { return false }
        load = self.busy / self.budget
        // one stray slow call (a page fault, the host busy) is not enough; a window mostly spent, or several calls that
        // nearly missed their deadline, is
        let tooHeavy = load > heavy || nearMisses >= 2
        (self.busy, self.budget, nearMisses) = (0, 0, 0)
        if tooHeavy {
            heavyWindows += 1
            calmWindows = 0
        } else {
            heavyWindows = 0
            calmWindows += 1
        }
        if heavyWindows >= 2 { overloaded = true }
        if calmWindows >= Int((2 / window).rounded()) { overloaded = false }
        return tooHeavy && heavyWindows >= 2
    }
}
