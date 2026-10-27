import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// The port's texts against KiCad's: tools/kicad-reference/texts.py has KiCad make each text's and field's shape
/// (PCB_TEXT::GetEffectiveShape, the KiCad font's strokes as segments; NAME.texts next to NAME.kicad_pcb) and its
/// boxes, and BoardWorld.textStrokes, made of the same board, must give the same: the same segments in the same order,
/// the same pen width, text box and bounding box, the same text shown and the same fields hidden. What the port does
/// not make (a knockout text, another font) must be what KiCad does not make of strokes. KICAD_BOARD_REFERENCE names a
/// folder of such boards (or several, separated by colons); with none, Fixtures/texts (texts drawn to take KiCad's
/// text drawing down its other ways: every justification, angles off the axes, mirrored, several lines, bold and
/// italic, markup, characters the font does not have, footprints turned and flipped, texts kept upright or not).
final class TextTests: XCTestCase {
    private static var folders: [URL] {
        if let f = ProcessInfo.processInfo.environment["KICAD_BOARD_REFERENCE"] {
            return f.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        return ["texts"].compactMap { Bundle.module.url(forResource: $0, withExtension: nil, subdirectory: "Fixtures") }
    }

    private static func box(_ any: Any?) -> IBox? {
        guard let v = (any as? [NSNumber])?.map(\.intValue), v.count == 4 else { return nil }
        return IBox(minX: v[0], minY: v[1], maxX: v[0] + v[2], maxY: v[1] + v[3])
    }

    /// The differences between KiCad's text and the port's
    private static func compare(_ theirs: [String: Any], _ ours: TextStrokes?, _ reason: String?, _ what: String) -> [String] {
        guard let segs = theirs["segments"] as? [[NSNumber]], (theirs["font"] as? String ?? "").isEmpty,
              !(theirs["knockout"] as? Bool ?? false) else {
            return ours == nil ? [] : ["\(what): KiCad makes no strokes of it (\(theirs["shape"] ?? "font \(theirs["font"] ?? "")")), the port does"]
        }
        guard let ours else { return ["\(what): the port makes none of it (\(reason ?? "?"))"] }
        var out: [String] = []
        let kicad = segs.map { Seg(IPoint($0[0].intValue, $0[1].intValue), IPoint($0[2].intValue, $0[3].intValue)) }
        if kicad != ours.segments {
            let first = zip(kicad, ours.segments).enumerated().first { $0.element.0 != $0.element.1 }
            out.append("\(what): KiCad's \(kicad.count) segments, ours \(ours.segments.count)"
                       + (first.map { ", first different #\($0.offset): KiCad's \($0.element.0), ours \($0.element.1)" } ?? ""))
        }
        let pen = (theirs["penWidth"] as? NSNumber)?.intValue ?? -1
        let widths = (theirs["widths"] as? [NSNumber] ?? []).map(\.intValue)
        if pen != ours.width || (!widths.isEmpty && widths != [ours.width]) {
            out.append("\(what): KiCad's pen \(pen) (segments \(widths)), ours \(ours.width)")
        }
        if let b = box(theirs["textBox"]), b != ours.textBox { out.append("\(what): KiCad's text box \(b), ours \(ours.textBox)") }
        if let b = box(theirs["boundingBox"]), b != ours.boundingBox {
            out.append("\(what): KiCad's bounding box \(b), ours \(ours.boundingBox)")
        }
        if let v = theirs["visible"] as? Bool, v != ours.visible { out.append("\(what): KiCad's visible \(v), ours \(ours.visible)") }
        if let s = theirs["shown"] as? String, s != ours.shownText { out.append("\(what): KiCad shows \(s.debugDescription), ours \(ours.shownText.debugDescription)") }
        return out
    }

    func testTextsAsKiCadDrawsThem() throws {
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
        var boards = 0, texts = 0, segments = 0, hidden = 0, notStrokes = 0
        var differences: [String] = []
        for file in files {
            let referenceURL = file.deletingPathExtension().appendingPathExtension("texts")
            guard let data = try? Data(contentsOf: referenceURL),
                  let reference = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { continue }
            let board = try KiCadBoard.read(file)
            boards += 1
            let name = file.deletingPathExtension().lastPathComponent
            var items: [(SExpr, SExpr?)] = board.root.all("gr_text").map { ($0, nil) }
            for fp in board.root.all("footprint") {
                items += fp.items.filter { $0.head == "property" || $0.head == "fp_text" }.map { ($0, fp) }
            }
            var seen = Set<String>()
            for (node, fp) in items {
                let uuid = node.value("uuid") ?? node.value("tstamp") ?? ""
                guard let theirs = reference[uuid] else {
                    if BoardWorld.textStrokes(node, footprint: fp) != nil {
                        differences.append("\(name): text \(uuid) \(node.text(at: 0) ?? "") not in KiCad's texts")
                    }
                    continue
                }
                seen.insert(uuid)
                var reason: String?
                let ours = BoardWorld.textStrokes(node, footprint: fp) { reason = $0 }
                let what = "\(name) \(theirs["kind"] ?? "") \((theirs["text"] as? String ?? uuid).debugDescription)"
                texts += 1
                if ours == nil { notStrokes += 1 }
                if let ours {
                    segments += ours.segments.count
                    if !ours.visible { hidden += 1 }
                }
                differences += Self.compare(theirs, ours, reason, what)
            }
            for uuid in reference.keys where !seen.contains(uuid) {
                differences.append("\(name): KiCad's text \(uuid) not on the port's board")
            }
        }
        print("TextTests: \(boards) boards, \(texts) texts (\(hidden) hidden, \(notStrokes) not strokes), \(segments) segments")
        XCTAssertGreaterThan(boards, 0)
        XCTAssertTrue(differences.isEmpty, "\(differences.count) differences:\n" + differences.prefix(40).joined(separator: "\n"))
    }

    /// The markup as KiCad's parser keeps it: runs of text, links, and subscripts, superscripts and overbars of what
    /// is in their braces, none kept empty
    func testMarkupTree() {
        func tree(_ s: String) -> String {
            func show(_ n: StrokeFont.Node) -> String {
                let content = n.content.map { "\"" + String(String.UnicodeScalarView($0)) + "\"" } ?? ""
                let kids = n.children.map(show).joined(separator: " ")
                return "\(n.kind)\(content)" + (kids.isEmpty ? "" : "(\(kids))")
            }
            return StrokeFont.MarkupParser(s: Array(s.unicodeScalars)).parse().map(show) ?? "nil"
        }
        XCTAssertEqual(tree("a~{b}c"), #"root(text"a" overbar(text"b") text"c")"#)
        XCTAssertEqual(tree("~{}x"), #"root(text"x")"#)
        XCTAssertEqual(tree("~{a"), #"root(text"~{a")"#)
        XCTAssertEqual(tree("x^{2_{i}}"), #"root(text"x" raised(text"2" lowered(text"i")))"#)
        XCTAssertEqual(tree("^{{slash}}"), #"root(raised(text"{slash}"))"#)
        XCTAssertEqual(tree("see http://a.b/c d"), #"root(text"see " url"http://a.b/c" text" d")"#)
        XCTAssertEqual(tree(""), "root")
    }
}
