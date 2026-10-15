import Foundation
import KiCadKit

/// The circuit as a KiCad netlist (the S-expression netlist of KiCad 6 and later, version E), for laying out a printed
/// circuit board in KiCad's PCB editor (File ▸ Import ▸ Netlist). The parts are those the breadboard has: op-amps and
/// gates packed into their chips (with the supplies the chips need), each part on a through-hole footprint from KiCad's
/// own libraries, its pads numbered as KiCad numbers them (a transistor's in its pinout's order, a diode's and an LED's
/// cathode pad 1, an electrolytic's + pad 1 on the higher DC voltage); supplies, sources, speakers, switches and the
/// modules wired from off the board each on a pin header. A part whose footprint JSpice does not know (an audio choke,
/// a lamp, a vactrol) is left for KiCad's footprint assignment, and named. The same netlist the board link keeps the
/// board up to date with (PCBNetlistBuilder): nets the schematic leaves unnamed are named after their first pad, as
/// KiCad names them (Net-(R1-Pad2)), and pins left free each on a net of their own.
public enum KiCadNetlist {
    public struct Export: Sendable {
        public var text: String
        /// The parts left without a footprint
        public var unassigned: [String]
        public var components: Int
        public var nets: Int
        /// What to know: supplies the chips need that the circuit leaves implicit, electrolytics whose polarity the
        /// circuit's resting voltages could not settle
        public var notes: [String] = []
    }

    public static func export(_ circuit: Circuit, title: String = "JSpice circuit", date: Date = Date()) -> Export {
        let board = PCBNetlistBuilder.netlist(circuit)
        let netlist = PCBNetlist(components: board.netlist.components.filter { !$0.excludeFromBoard })
        return Export(text: netlist.kicadNetlist(source: title, date: date), unassigned: board.unassigned,
                      components: netlist.components.count, nets: netlist.netNames.count, notes: board.notes)
    }

    /// An id made from a name, the same each time (FNV-1a, twice over)
    static func uuid(_ text: String) -> UUID {
        var h1: UInt64 = 0xcbf2_9ce4_8422_2325, h2: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in text.utf8 {
            h1 = (h1 ^ UInt64(byte)) &* 0x100_0000_01b3
            h2 = ((h2 ^ UInt64(byte)) &* 0x100_0000_01b3) &+ 0x9e37_79b9_7f4a_7c15
        }
        let b = withUnsafeBytes(of: (h1.bigEndian, h2.bigEndian)) { Array($0) }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
