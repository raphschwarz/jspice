import Foundation
import KiCadKit
import KiCadRouter

/// The board's own texts in KiCad's font: each one's strokes and boxes worked out once (BoardWorld.textStrokes, the
/// port of KiCad's stroke font), for drawing them and finding the one under the pointer
final class PCBTextStrokes: @unchecked Sendable {
    static let shared = PCBTextStrokes()
    private var cache: [String: TextStrokes] = [:]
    private var unmade: Set<String> = []
    private let lock = NSLock()

    /// The text's strokes, nil for one the port does not make (another font, a knockout)
    func strokes(_ text: KiCadBoardPicture.Text) -> TextStrokes? {
        lock.lock()
        defer { lock.unlock() }
        if let made = cache[text.source] { return made }
        if unmade.contains(text.source) { return nil }
        if cache.count > 4000 { cache = [:] }
        guard let node = try? SExpr.parse(text.source), let made = BoardWorld.textStrokes(node, footprint: nil) else {
            unmade.insert(text.source)
            return nil
        }
        cache[text.source] = made
        return made
    }

    /// The box round a text as drawn (mm)
    func box(_ text: KiCadBoardPicture.Text) -> KiCadBox? {
        guard let b = strokes(text)?.boundingBox else { return nil }
        return KiCadBox(minX: Double(b.minX) / 1e6, minY: Double(b.minY) / 1e6, maxX: Double(b.maxX) / 1e6, maxY: Double(b.maxY) / 1e6)
    }

    /// The text whose box holds `p` (mm), of those on `layers` (the one drawn last first): its id
    func text(at p: KiCadPoint, in picture: KiCadBoardPicture, layers: Set<String>) -> String? {
        picture.texts.reversed().first { layers.contains($0.layer) && (box($0)?.contains(p) ?? false) }?.uuid
    }
}
