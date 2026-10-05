import CoreMIDI
import Foundation

/// Plays the front window's keyboard sources from any connected MIDI keyboard: note on and off, and pitch bend over
/// two semitones. Devices plugged in later are picked up as they appear.
final class MIDIInput: @unchecked Sendable {
    static let shared = MIDIInput()

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: Set<MIDIEndpointRef> = []
    /// Running status (the last status byte, which later messages may leave out) and the data bytes so far, kept for
    /// each source, so two keyboards playing at once do not mix up each other's messages
    private struct Parser {
        var status: UInt8 = 0
        var data: [UInt8] = []
    }
    private var parsers: [UInt: Parser] = [:]

    func start() {
        guard client == 0 else { return }
        let created = MIDIClientCreateWithBlock("JSpice" as CFString, &client) { [weak self] notification in
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { self?.connectSources() }
        }
        guard created == noErr else { return }
        let opened = MIDIInputPortCreateWithBlock(client, "JSpice keyboard" as CFString, &port) { [weak self] list, source in
            self?.receive(list, from: UInt(bitPattern: source))
        }
        guard opened == noErr else { return }
        connectSources()
    }

    private func connectSources() {
        guard port != 0 else { return }
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            guard source != 0, !connected.contains(source) else { continue }
            // the source's reference comes back with each of its packets
            if MIDIPortConnectSource(port, source, UnsafeMutableRawPointer(bitPattern: UInt(source))) == noErr {
                connected.insert(source)
            }
        }
    }

    /// Runs on CoreMIDI's thread: decodes the bytes and hands the notes to the main thread
    private func receive(_ list: UnsafePointer<MIDIPacketList>, from source: UInt) {
        var events: [(kind: UInt8, a: UInt8, b: UInt8)] = []
        var parser = parsers[source] ?? Parser()
        defer { parsers[source] = parser }
        // walk the packets in place: each may be shorter than MIDIPacket's 256 data bytes
        let lengthOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.length) ?? 8
        let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data) ?? 10
        let firstOffset = MemoryLayout<MIDIPacketList>.offset(of: \MIDIPacketList.packet) ?? 4
        var packet = (UnsafeRawPointer(list) + firstOffset).assumingMemoryBound(to: MIDIPacket.self)
        let count = UnsafeRawPointer(list).loadUnaligned(as: UInt32.self)
        for _ in 0..<count {
            let raw = UnsafeRawPointer(packet)
            let length = Int(raw.loadUnaligned(fromByteOffset: lengthOffset, as: UInt16.self))
            for byte in UnsafeRawBufferPointer(start: raw + dataOffset, count: length) {
                if byte >= 0xF8 { continue }                    // real-time messages (clock…) can come anywhere
                if byte >= 0x80 {
                    parser.status = byte < 0xF0 ? byte : 0      // system messages carry no channel data
                    parser.data = []
                    continue
                }
                guard parser.status != 0 else { continue }
                parser.data.append(byte)
                let kind = parser.status & 0xF0
                let needed = (kind == 0xC0 || kind == 0xD0) ? 1 : 2
                if parser.data.count == needed {
                    events.append((kind, parser.data[0], needed == 2 ? parser.data[1] : 0))
                    parser.data = []
                }
            }
            packet = UnsafePointer(MIDIPacketNext(packet))
        }
        guard !events.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let simulation = EditorRegistry.active?.simulation else { return }
                for event in events {
                    switch event.kind {
                    case 0x90 where event.b > 0:
                        simulation.noteOn(Int(event.a))
                    case 0x80, 0x90:
                        simulation.noteOff(Int(event.a))
                    case 0xE0:
                        let value = Int(event.b) << 7 | Int(event.a)
                        simulation.pitchBend(Double(value - 8192) / 8192 * 2)
                    case 0xB0 where event.a == 123 || event.a == 120:
                        // all notes off, all sound off
                        simulation.allNotesOff()
                    default:
                        break
                    }
                }
            }
        }
    }
}
