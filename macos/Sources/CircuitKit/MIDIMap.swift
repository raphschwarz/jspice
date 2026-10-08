import Foundation

/// A MIDI controller (a knob, fader or button sending control changes) mapped to one of the circuit's controls: a
/// potentiometer follows it across its travel, a switch or push button is on from 64 up. Mappings are kept in the
/// circuit file, so a pedal or synth comes back with its knobs where they were learned.
public struct MIDIMapping: Codable, Hashable, Sendable {
    /// Controller number, 0 to 127
    public var controller: Int
    /// MIDI channel, 0 to 15; nil listens on every channel
    public var channel: Int?
    /// The part, or the block part that holds it
    public var part: UUID
    /// For a control inside a block: its id in the block's circuit
    public var inner: UUID?

    public init(controller: Int, channel: Int? = nil, part: UUID, inner: UUID? = nil) {
        self.controller = controller
        self.channel = channel
        self.part = part
        self.inner = inner
    }

    /// The kinds of part a controller can move
    public static let mappable: Set<ElementKind> = [.potentiometer, .toggleSwitch, .pushButton]

    /// Whether a message on `channel` from `controller` is this mapping's
    public func matches(controller: Int, channel: Int) -> Bool {
        self.controller == controller && (self.channel == nil || self.channel == channel)
    }

    /// "CC 21", or "CC 21 · ch 2" on one channel (counted from 1, as on the devices)
    public var label: String {
        channel.map { "CC \(controller) · ch \($0 + 1)" } ?? "CC \(controller)"
    }
}

extension Circuit {
    /// The mapping of a control, if it has one
    public func midiMapping(part: UUID, inner: UUID? = nil) -> MIDIMapping? {
        midiMappings.first { $0.part == part && $0.inner == inner }
    }

    /// Maps a controller to a control, replacing what either was mapped to before: one controller moves one control,
    /// and a control follows one controller
    public mutating func learnMIDI(controller: Int, channel: Int?, part: UUID, inner: UUID? = nil) {
        midiMappings.removeAll { ($0.part == part && $0.inner == inner) || ($0.controller == controller && $0.channel == channel) }
        midiMappings.append(MIDIMapping(controller: controller, channel: channel, part: part, inner: inner))
    }

    public mutating func forgetMIDI(part: UUID, inner: UUID? = nil) {
        midiMappings.removeAll { $0.part == part && $0.inner == inner }
    }

    /// Moves the controls mapped to a control change (value 0 to 127); true if anything changed
    @discardableResult
    public mutating func applyControlChange(controller: Int, channel: Int, value: Int) -> Bool {
        var changed = false
        let level = Double(min(max(value, 0), 127)) / 127
        for mapping in midiMappings where mapping.matches(controller: controller, channel: channel) {
            guard let i = index(of: mapping.part) else { continue }
            if let inner = mapping.inner {
                guard var block = elements[i].block, let j = block.circuit.index(of: inner) else { continue }
                if Self.set(&block.circuit.elements[j], to: level) {
                    elements[i].block = block
                    changed = true
                }
            } else if Self.set(&elements[i], to: level) {
                changed = true
            }
        }
        return changed
    }

    /// Sets a control to a controller's level, 0 to 1; true if it changed
    private static func set(_ element: inout Element, to level: Double) -> Bool {
        switch element.kind {
        case .potentiometer:
            guard element[param: "position"] != level else { return false }
            element[param: "position"] = level
        case .toggleSwitch, .pushButton:
            let on = level >= 64.0 / 127
            guard element.closed != on else { return false }
            element.closed = on
        default:
            return false
        }
        return true
    }
}
