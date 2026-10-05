import Foundation

/// What a microcontroller pin does, as the circuit sees it
public enum PinState: Equatable, Sendable {
    /// Read by the chip: high impedance, or pulled up to the supply
    case input(pullUp: Bool)
    /// Driven high or low
    case output(high: Bool)
}

/// A microcontroller running its firmware: the circuit sets the voltages on its pins and runs it for a number of
/// clock cycles, then reads back what each pin does
public protocol Microcontroller: AnyObject {
    /// The pins the circuit can reach, in the order of the part's terminals
    var pinCount: Int { get }
    /// Clock cycles per second
    var clock: Double { get }
    /// Clock cycles run since reset
    var cycles: Int { get }
    /// The supply, which is also the logic high level (and the ADC's reference by default)
    var supply: Double { get set }
    /// The voltage on each pin, set by the circuit before it runs
    var pinVoltages: [Double] { get set }
    /// What each pin does now
    var pinStates: [PinState] { get }
    /// Bytes sent by the chip's serial port (the one a board connects to the computer), oldest first
    var serialOutput: [UInt8] { get }
    /// Bytes waiting to be received
    var serialInput: [UInt8] { get set }

    /// Runs whole instructions until at least `count` more cycles have passed
    func run(cycles count: Int)
    /// Power-on reset: the program starts over (its firmware kept)
    func reset()
    /// Takes on another chip's whole state (the sound thread's chip, for the window's simulator to show)
    func adopt(_ other: Microcontroller)
}
