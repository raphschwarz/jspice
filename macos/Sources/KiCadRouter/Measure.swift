// What KiCad's measure tool shows (KiCad 10.0.7: pcbnew/tools/pcb_viewer_tools.cpp, PCB_VIEWER_TOOLS::MeasureTool;
// common/preview_items/ruler_item.cpp, RULER_ITEM::GetDimensionStrings; common/preview_items/preview_utils.cpp,
// DimensionLabel; include/preview_items/two_point_geom_manager.h): a ruler from a click to the pointer, Shift holding
// it to 45°, and its readout. GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// KiCad's measure tool: a click sets the ruler's origin, the pointer moves its end (Shift holding it to the nearest
/// 0, 45 or 90 degrees), the next click leaves it where it is until the next; Esc takes it away. It only shows: it
/// changes nothing on the board.
public struct Ruler: Sendable, Equatable {
    var geometry = TwoPointGeometry()
    /// Whether its origin is set and its end follows the pointer
    public private(set) var originSet = false
    /// Whether it is shown
    public private(set) var visible = false

    public init() {}

    public var origin: IPoint { geometry.origin }
    public var end: IPoint { geometry.end }

    /// A click (or the start of a drag) at `p`: the origin set there; the next click (or the end of the drag) stops it
    public mutating func click(at p: IPoint) {
        if !originSet {
            geometry.setOrigin(p)
            geometry.setEnd(p)
            originSet = true
        } else {
            originSet = false
        }
    }

    /// The pointer at `p` (`shift`: held to 45°): the end there, where the origin is set
    public mutating func move(to p: IPoint, shift: Bool = false) {
        guard originSet else { return }
        geometry.angleSnap = shift ? .deg45 : .direct
        geometry.setEnd(p)
        visible = true
    }

    /// Esc: the ruler taken away; false if there was none being drawn (Esc then leaves the tool)
    @discardableResult
    public mutating func cancel() -> Bool {
        let was = originSet
        originSet = false
        visible = false
        return was
    }

    /// The units its readout is in (KiCad's user units)
    public enum Units: Sendable { case mm, mils, inch }

    /// The ruler's vector, end less origin (mm)
    public var dx: Double { Double(end.x - origin.x) / 1e6 }
    public var dy: Double { Double(end.y - origin.y) / 1e6 }
    /// Its length (VECTOR2D::EuclideanNorm, mm)
    public var distance: Double { DPoint(end - origin).norm / 1e6 }
    /// Its angle, counterclockwise from the right (-EDA_ANGLE of its vector, degrees)
    public var angle: Double { (-EDAAngle(DPoint(end - origin))).degrees }

    /// RULER_ITEM::GetDimensionStrings: x, y, r and θ, as DimensionLabel writes them (a millimetre to three places, a
    /// mil to one, an inch to four, the angle to a tenth of a degree, each with its unit)
    public func readout(_ units: Units = .mm, invertX: Bool = false, invertY: Bool = false) -> [String] {
        let v = DPoint(end - origin)
        let x = invertX ? -v.x : v.x, y = invertY ? -v.y : v.y
        func label(_ prefix: String, _ iu: Double) -> String {
            switch units {
            case .mm: return "\(prefix): " + String(format: "%.3f", iu / 1e6) + " mm"
            case .mils: return "\(prefix): " + String(format: "%.1f", iu / (1e6 * 0.0254)) + " mils"
            case .inch: return "\(prefix): " + String(format: "%.4f", iu / (1e6 * 0.0254) / 1000) + " in"
            }
        }
        return [label("x", x), label("y", y), label("r", v.norm), "θ: " + String(format: "%.1f", angle) + "°"]
    }
}
