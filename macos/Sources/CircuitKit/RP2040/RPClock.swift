import Foundation

// The RP2040 emulator is a port of rp2040js (https://github.com/wokwi/rp2040js, MIT licence, Copyright (c) 2021 Uri
// Shaked): the same structure and the same arithmetic (time in nanoseconds as a Double, as JavaScript numbers are), so
// it can be compared with it instruction by instruction.

/// JavaScript's ToUint32 of a number: integral, wrapped to 32 bits
@inline(__always) func jsUint32(_ value: Double) -> UInt32 {
    guard value.isFinite else { return 0 }
    let whole = value < 0 ? -(-value).rounded(.down) : value.rounded(.down)
    let wrapped = whole.truncatingRemainder(dividingBy: 4_294_967_296)
    return UInt32(wrapped < 0 ? wrapped + 4_294_967_296 : wrapped)
}

/// JavaScript's Math.round: halves round up
@inline(__always) func jsRound(_ value: Double) -> Double { (value + 0.5).rounded(.down) }

/// A one-shot alarm on the simulation clock
final class RPAlarm {
    unowned(unsafe) let clock: RPClock
    let callback: () -> Void
    var next: RPAlarm?
    var nanos: Double = 0
    var scheduled = false

    init(clock: RPClock, callback: @escaping () -> Void) {
        self.clock = clock
        self.callback = callback
    }

    func schedule(_ deltaNanos: Double) {
        if scheduled { cancel() }
        clock.link(deltaNanos, self)
    }

    func cancel() {
        clock.unlink(self)
        scheduled = false
    }
}

/// Simulated time, and the alarms that go off as it passes
final class RPClock {
    private var nextAlarm: RPAlarm? {
        didSet { nextAlarmNanos = nextAlarm?.nanos ?? .infinity }
    }
    /// When the next alarm goes off (infinity if none): ticking short of it is a single addition
    private var nextAlarmNanos = Double.infinity
    private(set) var nanos: Double = 0

    func createAlarm(_ callback: @escaping () -> Void) -> RPAlarm { RPAlarm(clock: self, callback: callback) }

    fileprivate func link(_ delta: Double, _ alarm: RPAlarm) {
        alarm.nanos = nanos + delta
        var item = nextAlarm
        var last: RPAlarm?
        while let current = item, current.nanos < alarm.nanos {
            last = current
            item = current.next
        }
        alarm.next = item
        if let last {
            last.next = alarm
        } else {
            nextAlarm = alarm
        }
        alarm.scheduled = true
    }

    fileprivate func unlink(_ alarm: RPAlarm) {
        var item = nextAlarm
        var last: RPAlarm?
        while let current = item {
            if current === alarm {
                if let last { last.next = current.next } else { nextAlarm = current.next }
                return
            }
            last = current
            item = current.next
        }
    }

    @inline(__always) func tick(_ deltaNanos: Double) {
        let target = nanos + deltaNanos
        if target < nextAlarmNanos {
            nanos = target
            return
        }
        fire(until: target)
    }

    private func fire(until target: Double) {
        while let alarm = nextAlarm, alarm.nanos <= target {
            nextAlarm = alarm.next
            nanos = alarm.nanos
            alarm.callback()
        }
        nanos = target
    }

    var nanosToNextAlarm: Double {
        guard let alarm = nextAlarm else { return 0 }
        return alarm.nanos - nanos
    }

    var hasAlarm: Bool { nextAlarm != nil }

    /// Clears every alarm and starts time over (a reset of the whole chip)
    func restart() {
        var item = nextAlarm
        while let current = item {
            item = current.next
            current.next = nil
            current.scheduled = false
        }
        nextAlarm = nil
        nanos = 0
    }
}

/// A counter that runs from the clock at a frequency (it is worked out from the time when read, not ticked)
final class RPTimer32 {
    enum Mode { case increment, decrement, zigZag }

    let clock: RPClock
    private var baseValue: Double = 0
    private var baseNanos: Double = 0
    private var topValue: Double = 0xFFFF_FFFF
    private var prescalerValue: Double = 1
    private var timerMode: Mode = .increment
    private var enabled = true
    private var baseFrequency: Double
    var listeners: [() -> Void] = []

    init(clock: RPClock, frequency: Double) {
        self.clock = clock
        baseFrequency = frequency
    }

    func reset() {
        baseNanos = clock.nanos
        baseValue = 0
        updated()
    }

    func set(_ value: Double, zigZagDown: Bool = false) {
        baseValue = zigZagDown ? topValue * 2 - value : value
        baseNanos = clock.nanos
        updated()
    }

    /// Moves the counter by `delta` (back when counting down)
    func advance(_ delta: Double) {
        baseValue += delta
        if topValue != 0xFFFF_FFFF {
            let modulo = timerMode == .zigZag ? topValue * 2 : topValue + 1
            baseValue = (baseValue.truncatingRemainder(dividingBy: modulo) + modulo).truncatingRemainder(dividingBy: modulo)
        }
        updated()
    }

    var rawCounter: Double {
        if baseFrequency == 0 || prescalerValue == 0 || !enabled { return baseValue }
        let zigzag = timerMode == .zigZag
        let ticks = ((clock.nanos - baseNanos) / 1e9) * (baseFrequency / prescalerValue)
        let modulo = zigzag ? topValue * 2 : topValue + 1
        let delta = timerMode == .decrement ? modulo - ticks.truncatingRemainder(dividingBy: modulo) : ticks
        var current = jsRound(baseValue + delta)
        if topValue != 0xFFFF_FFFF { current = current.truncatingRemainder(dividingBy: modulo) }
        return current
    }

    var counter: UInt32 {
        var current = rawCounter
        if timerMode == .zigZag && current > topValue { current = topValue * 2 - current }
        return jsUint32(current)
    }

    var top: Double {
        get { topValue }
        set {
            let current = Double(counter)
            topValue = newValue
            set(current <= topValue ? current : 0)
        }
    }

    var frequency: Double {
        get { baseFrequency }
        set {
            baseValue = Double(counter)
            baseNanos = clock.nanos
            baseFrequency = newValue
            updated()
        }
    }

    var prescaler: Double {
        get { prescalerValue }
        set {
            baseValue = Double(counter)
            baseNanos = clock.nanos
            enabled = prescalerValue != 0
            prescalerValue = newValue
            updated()
        }
    }

    func toNanos(_ cycles: Double) -> Double { (cycles * 1e9) / (baseFrequency / prescalerValue) }

    var enable: Bool {
        get { enabled }
        set {
            guard newValue != enabled else { return }
            if newValue {
                baseNanos = clock.nanos
            } else {
                baseValue = Double(counter)
            }
            enabled = newValue
            updated()
        }
    }

    var mode: Mode {
        get { timerMode }
        set {
            guard timerMode != newValue else { return }
            let current = Double(counter)
            timerMode = newValue
            set(current)
        }
    }

    private func updated() {
        for listener in listeners { listener() }
    }
}

/// An alarm that goes off each time a timer reaches a value
final class RPTimer32PeriodicAlarm {
    let timer: RPTimer32
    let callback: () -> Void
    private var targetValue: Double = 0
    private var enabled = false
    private var clockAlarm: RPAlarm!

    init(timer: RPTimer32, callback: @escaping () -> Void) {
        self.timer = timer
        self.callback = callback
        clockAlarm = timer.clock.createAlarm { [unowned self] in self.handleAlarm() }
        timer.listeners.append { [unowned self] in self.update() }
    }

    var enable: Bool {
        get { enabled }
        set {
            guard newValue != enabled else { return }
            enabled = newValue
            if newValue && timer.enable { schedule() } else { cancel() }
        }
    }

    var target: Double {
        get { targetValue }
        set {
            guard newValue != targetValue else { return }
            targetValue = newValue
            if enabled && timer.enable {
                cancel()
                schedule()
            }
        }
    }

    private func handleAlarm() {
        callback()
        if enabled && timer.enable { schedule() }
    }

    private func update() {
        cancel()
        if enabled && timer.enable { schedule() }
    }

    private func schedule() {
        let top = timer.top
        let mode = timer.mode
        let raw = timer.rawCounter
        var delta = targetValue - raw
        if mode == .zigZag && delta < 0 {
            if delta < -top {
                delta += 2 * top
            } else {
                delta = top * 2 - targetValue - raw
            }
        }
        if top != 0xFFFF_FFFF {
            if delta <= 0 { delta += top + 1 }
            if targetValue > top { return }  // skip the alarm
        }
        if mode == .decrement { delta = top + 1 - delta }
        let cycles = Double(jsUint32(delta))
        clockAlarm.schedule(timer.toNanos(cycles))
    }

    private func cancel() {
        clockAlarm.cancel()
    }
}

/// A first-in first-out queue of 32-bit words, of a fixed size
struct RPFIFO {
    private var buffer: [UInt32]
    private var start = 0
    private(set) var itemCount = 0
    let size: Int

    init(_ size: Int) {
        buffer = [UInt32](repeating: 0, count: size)
        self.size = size
    }

    var empty: Bool { itemCount == 0 }
    var full: Bool { itemCount == size }

    mutating func push(_ value: UInt32) {
        guard itemCount < buffer.count else { return }
        buffer[(start + itemCount) % buffer.count] = value
        itemCount += 1
    }

    mutating func pull() -> UInt32 {
        guard itemCount > 0 else { return 0 }
        let value = buffer[start]
        start = (start + 1) % buffer.count
        itemCount -= 1
        return value
    }

    func peek() -> UInt32 { itemCount > 0 ? buffer[start] : 0 }

    mutating func reset() { itemCount = 0 }

    var items: [UInt32] { (0..<itemCount).map { buffer[(start + $0) % buffer.count] } }
}
