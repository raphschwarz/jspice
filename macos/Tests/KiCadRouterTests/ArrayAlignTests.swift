import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// Create Array and align and distribute (BoardEditing.createArray, align) against KiCad's own PCB editor
/// (tools/kicad-reference/editing.py, on the boards of Fixtures/clipboard): each array KiCad's Create Array dialog made
/// of a box's items (grids of counts, spacings, offsets and stagger by rows and by columns, centred or not; circles
/// about a centre, by an angle or a full circle, either way round, the items turned or not; the selection arranged;
/// references kept or made unique) the port makes from the same selection with the dialog's fields as KiCad read them;
/// each of KiCad's ten align and distribute actions, one after another, with the pointer where KiCad's was. The boards
/// must come out alike (ClipboardTests.compare: their items, ids aside).
final class ArrayAlignTests: XCTestCase {
    /// A dialog field's number (the text's leading number, as EDA_UNIT_UTILS reads it)
    static func number(_ v: Any?) -> Double {
        let s = (v as? String) ?? "\(v ?? "0")"
        let lead = s.prefix { "0123456789.-+eE".contains($0) }
        return Double(lead) ?? 0
    }

    /// The options KiCad's dialog took (TransferDataFromWindow), from its fields as they were when OK was pressed
    static func options(_ d: [String: Any], kind: String) -> ArrayOptions {
        func flag(_ k: String) -> Bool { (d[k] as? Bool) ?? ((d[k] as? NSNumber)?.boolValue ?? false) }
        let layout: ArrayOptions.Layout
        if kind == "grid" {
            var g = ArrayOptions.Grid(columns: Int(number(d["Horizontal count:"])), rows: Int(number(d["Vertical count:"])),
                                      spacing: KiCadPoint(number(d["Horizontal spacing:"]), number(d["Vertical spacing:"])),
                                      offset: KiCadPoint(number(d["Horizontal offset:"]), number(d["Vertical offset:"])),
                                      stagger: Int(number(d["Stagger:"])), staggerRows: flag("Rows"),
                                      centred: flag("Centre on source items"))
            g.horizontalThenVertical = true
            layout = .grid(g)
        } else {
            layout = .circular(ArrayOptions.Circular(centre: KiCadPoint(number(d["Center pos X:"]), number(d["Center pos Y:"])),
                                                     count: Int(number(d["Item count:"])), angle: number(d["Angle between items:"]),
                                                     angleOffset: number(d["First item angle:"]),
                                                     clockwise: (d["Direction"] as? NSNumber)?.intValue == 0,
                                                     rotateItems: flag("Rotate items")))
        }
        return ArrayOptions(layout, arrange: flag("Arrange selection"), uniqueReferences: flag("Assign unique reference designators"))
    }

    /// The items arranged by KiCad in the order of their places in the array, then those it left (KiCad arranges as
    /// many as the array has places, in the order they were selected): the first the one left where it was, each
    /// other where its place's offset from the first's position took it (a track's start, which its SetPosition
    /// moves; a zone, which SetPosition does not move, its place's offset from where it was); one other not moved
    /// from where it was on `original` one of those left
    static func arrangedOrder(_ uuids: [String], in board: KiCadBoard, original: KiCadBoard, options: ArrayOptions,
                              _ what: String) throws -> [String] {
        func place(_ node: SExpr, _ board: KiCadBoard) -> IPoint {
            if node.head == "group" {
                // (PCB_GROUP::GetPosition: its members' box's centre)
                let boxes = Dictionary(BoxSelection(board: board).footprints.map { ($0.uuid, $0.box) }, uniquingKeysWith: { a, _ in a })
                let all = BoardItems.descendants(node, in: board).compactMap { BoardItems.boundingBox($0, footprintBoxes: boxes, board: board) }
                return all.dropFirst().reduce(all.first ?? IBox(minX: 0, minY: 0, maxX: 0, maxY: 0)) { var b = $0; b.merge($1); return b }.center
            }
            return node.head == "segment" || node.head == "arc" ? BoardWorld.point(node["start"]) : BoardItems.position(node)
        }
        let nodes = try uuids.map { try XCTUnwrap(BoardItems.item(board, $0), "\(what): \($0)") }
        let places = nodes.map { place($0, board) }
        let before = try nodes.map { node in try place(XCTUnwrap(BoardItems.item(original, node.value("uuid") ?? "")), original) }
        let unmoved = nodes.indices.map { places[$0] == before[$0] }
        let arranged = min(options.size, nodes.count)
        for f in nodes.indices where unmoved[f] {
            var order: [(Int, String)] = [], left: [String] = []
            var taken = Set<Int>()
            for (i, node) in nodes.enumerated() {
                let id = node.value("uuid") ?? ""
                if unmoved[i] && i != f {
                    left.append(id)
                    continue
                }
                let d = places[i] - (node.head == "zone" && i != f ? before[i] : places[f])
                guard let k = (0..<options.size).first(where: { !taken.contains($0) && options.transform($0, places[i]).offset == d })
                else { break }
                taken.insert(k)
                order.append((k, id))
            }
            if order.count + left.count == nodes.count, order.count == arranged {
                return order.sorted { $0.0 < $1.0 }.map(\.1) + left
            }
        }
        XCTFail("\(what): no order of the items puts them where KiCad did")
        return uuids
    }

    func testArraysAreKiCads() throws {
        var arrays = 0
        for record in try ClipboardTests.files("arrays") {
            let board = record.deletingPathExtension().appendingPathExtension("kicad_pcb")
            for (n, run) in try XCTUnwrap(ClipboardTests.json(record)["arrays"] as? [[String: Any]]).enumerated() {
                let what = "\(board.lastPathComponent) array \(n)"
                let session = try ClipboardTests.session(board)
                let settings = try XCTUnwrap(run["settings"] as? [String: Any])
                let options = Self.options(try XCTUnwrap(run["dialog"] as? [String: Any]), kind: settings["kind"] as? String ?? "grid")
                let theirs = try KiCadBoard.read(board.deletingLastPathComponent()
                    .appendingPathComponent(board.deletingPathExtension().lastPathComponent + "-array-\(n).kicad_pcb"))
                var selection = try XCTUnwrap(run["selection"] as? [String])
                if options.arrange {
                    // (the order KiCad arranged them in, the order they were added to its selection, which its
                    // module does not tell: each item's place in the array, from where KiCad put it)
                    selection = try Self.arrangedOrder(selection, in: theirs, original: session.board, options: options, what)
                }
                XCTAssertNotNil(session.createArray(selection, options: options), what)
                ClipboardTests.compare(session.board, theirs, what)
                arrays += 1
            }
        }
        XCTAssertGreaterThan(arrays, 0)
    }

    func testAlignmentsAreKiCads() throws {
        var actions = 0
        for record in try ClipboardTests.files("aligns") {
            let board = record.deletingPathExtension().appendingPathExtension("kicad_pcb")
            let session = try ClipboardTests.session(board)
            for a in try XCTUnwrap(ClipboardTests.json(record)["aligns"] as? [[String: Any]]) {
                let name = try XCTUnwrap(a["action"] as? String)
                let how: BoardEditing.Alignment = switch name {
                case "alignTop": .top
                case "alignBottom": .bottom
                case "alignLeft": .left
                case "alignRight": .right
                case "alignCenterX": .centerX
                case "alignCenterY": .centerY
                default: try XCTUnwrap(BoardEditing.Alignment(rawValue: name))
                }
                _ = session.align(try XCTUnwrap(a["selection"] as? [String]), how, cursor: ClipboardTests.point(a["cursor"]))
                let theirs = board.deletingLastPathComponent().appendingPathComponent(try XCTUnwrap(a["board"] as? String))
                ClipboardTests.compare(session.board, try KiCadBoard.read(theirs), "\(board.lastPathComponent) \(name)")
                actions += 1
            }
        }
        XCTAssertGreaterThan(actions, 0)
    }
}
