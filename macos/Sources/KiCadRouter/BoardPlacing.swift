// Texts and footprints placed on the board on their own, as KiCad's PCB editor places them (KiCad 10.0.7:
// pcbnew/tools/drawing_tool.cpp, DRAWING_TOOL::PlaceText: a new text's attributes from the board's design settings,
// pcbnew/board_design_settings.cpp, GetTextSize, GetTextThickness, GetTextItalic, GetTextUpright and GetLayerClass, and
// include/gr_text.h, InferBold; pcbnew/tools/board_editor_control.cpp, BOARD_EDITOR_CONTROL::PlaceFootprint, with
// pcbnew/load_select_footprint.cpp, PCB_BASE_FRAME::loadFootprint: a library's footprint on no net, on the front,
// unturned, its reference and value as the library has them). Texts written as pcbnew/pcb_io/kicad_sexpr/
// pcb_io_kicad_sexpr.cpp writes them. GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardEditing {
    /// What a new text on a layer is like (BOARD_DESIGN_SETTINGS' text defaults for the layer's class, from the
    /// project's board.design_settings.defaults, KiCad's own where it has none): its height and width, its pen's
    /// width (mm), bold where the pen is nearer a bold one's than a normal one's (InferBold), italic, kept upright
    /// (which KiCad keeps in the file for a footprint's texts only: a board's own text reads back as not), and
    /// mirrored on the back's layers
    public struct TextStyle: Sendable, Equatable {
        public var height: Double
        public var width: Double
        public var thickness: Double
        public var bold: Bool
        public var italic: Bool
        public var upright: Bool
        public var mirrored: Bool
    }

    /// BOARD_DESIGN_SETTINGS::GetLayerClass, by the names of the project's defaults
    static func textClass(_ layer: String) -> String {
        if layer == "F.SilkS" || layer == "B.SilkS" { return "silk" }
        if layer.hasSuffix(".Cu") { return "copper" }
        if layer == "Edge.Cuts" { return "edges" }
        if layer == "F.CrtYd" || layer == "B.CrtYd" { return "courtyard" }
        if layer == "F.Fab" || layer == "B.Fab" { return "fab" }
        return "other"
    }

    /// The style KiCad's Add Text gives a new text on `layer`
    public func textStyle(layer: String) -> TextStyle {
        let defaults = ((project?["board"] as? [String: Any])?["design_settings"] as? [String: Any])?["defaults"] as? [String: Any] ?? [:]
        let kind = Self.textClass(layer)
        // (the constructor's values, which a project without them leaves; edges and courtyards take no others)
        let size = kind == "silk" ? 1.0 : kind == "copper" ? 1.5 : 1.0
        let pen = kind == "silk" ? 0.1 : kind == "copper" ? 0.3 : 0.15
        let has = kind != "edges" && kind != "courtyard"
        func number(_ key: String, _ fallback: Double) -> Double {
            has ? (defaults["\(kind)_\(key)"] as? NSNumber)?.doubleValue ?? fallback : fallback
        }
        func flag(_ key: String) -> Bool { has ? (defaults["\(kind)_\(key)"] as? Bool) ?? false : false }
        let height = number("text_size_v", size), width = number("text_size_h", size), thickness = number("text_thickness", pen)
        // (InferBold, in board units)
        let iu = { (mm: Double) in BoardWorld.iu(mm) }
        let smaller = Double(min(iu(height), iu(width)))
        let bold = abs(iu(thickness) - KiMath.round(smaller / 5)) < abs(iu(thickness) - KiMath.round(smaller / 8))
        return TextStyle(height: height, width: width, thickness: thickness, bold: bold, italic: flag("text_italic"),
                         upright: flag("text_upright"), mirrored: layer.hasPrefix("B."))
    }

    /// A text on the board, as KiCad's Add Text places one with the pointer at `p` (mm): of the layer's style, its
    /// left end on the baseline there, turned by `angle` (degrees), as one change (Edit.drawings has it). nil for a
    /// text of nothing printable, as KiCad's
    public func addText(_ text: String, at p: KiCadPoint, layer: String, angle: Double = 0) -> Edit? {
        guard !isRouting, text.contains(where: { !$0.isWhitespace }) else { return nil }
        let style = textStyle(layer: layer)
        let uuid = KiCadBoard.newUUID()
        router.board.addDrawing(Self.textNode(text, at: p, angle: angle, layer: layer, style: style, uuid: uuid))
        router.boardChanged()
        return change("Add Text", drawings: [uuid])
    }

    /// A gr_text as KiCad writes it (PCB_IO_KICAD_SEXPR::format: its size height first, justified left and to its
    /// baseline as Add Text makes it)
    static func textNode(_ text: String, at p: KiCadPoint, angle: Double, layer: String, style: TextStyle, uuid: String) -> SExpr {
        func mm(_ v: Double) -> Double { Double(BoardWorld.iu(v)) / 1e6 }
        var font: [SExprConvertible] = [SExpr("size", mm(style.height), mm(style.width)), SExpr("thickness", mm(style.thickness))]
        if style.bold { font.append(SExpr("bold", Keyword("yes"))) }
        if style.italic { font.append(SExpr("italic", Keyword("yes"))) }
        var justify: [SExprConvertible] = [Keyword("left"), Keyword("bottom")]
        if style.mirrored { justify.append(Keyword("mirror")) }
        return SExpr("gr_text", text, SExpr("at", mm(p.x), mm(p.y), Self.normalizedAngle(angle)), SExpr("layer", layer), SExpr("uuid", uuid),
                     SExpr("effects", SExpr("font", font), SExpr("justify", justify)))
    }

    /// An angle in [0, 360) (EDA_ANGLE::Normalize, as a text's angle is kept)
    static func normalizedAngle(_ a: Double) -> Double {
        var a = a.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return a == 0 ? 0 : a
    }

    /// The board's own texts, by id
    private func texts(_ uuids: [String]) -> [SExpr] {
        let wanted = Set(uuids)
        return router.board.boardDrawings.filter { $0.head == "gr_text" && wanted.contains($0.value("uuid") ?? "") }
    }

    /// A text's words changed, as one change; nil if it has no text of that id, or the words are those it has or
    /// nothing printable
    public func setText(_ uuid: String, to text: String) -> Edit? {
        guard !isRouting, text.contains(where: { !$0.isWhitespace }), let node = texts([uuid]).first,
              node.text(at: 0) != text else { return nil }
        node.items[1] = SExpr(string: text)
        router.boardChanged()
        return change("Edit Text", drawings: [uuid])
    }

    /// The board's texts and drawings (its outline aside) moved by `delta` (mm), as one change
    public func moveDrawings(_ uuids: [String], by delta: KiCadPoint) -> Edit? {
        guard !isRouting, delta != .zero else { return nil }
        let wanted = Set(uuids)
        var moved: [String] = []
        func shifted(_ list: SExpr) {
            guard let x = list.number(at: 0), let y = list.number(at: 1) else { return }
            list.items[1] = (Double(BoardWorld.iu(x + delta.x)) / 1e6).sexpr
            list.items[2] = (Double(BoardWorld.iu(y + delta.y)) / 1e6).sexpr
        }
        for node in router.board.boardDrawings where wanted.contains(node.value("uuid") ?? "") {
            for head in ["at", "start", "end", "center", "mid"] { if let list = node[head] { shifted(list) } }
            for list in node["pts"]?.all("xy") ?? [] { shifted(list) }
            moved.append(node.value("uuid") ?? "")
        }
        guard !moved.isEmpty else { return nil }
        router.boardChanged()
        return change(moved.count == 1 ? "Move" : "Move Items", drawings: moved)
    }

    /// The board's texts turned by `degrees` counterclockwise about their own positions, as KiCad's Rotate turns a
    /// text selected alone, as one change
    public func rotateTexts(_ uuids: [String], by degrees: Double = 90) -> Edit? {
        guard !isRouting else { return nil }
        let nodes = texts(uuids)
        guard !nodes.isEmpty else { return nil }
        for node in nodes {
            guard let at = node["at"], let x = at.number(at: 0), let y = at.number(at: 1) else { continue }
            node.set(SExpr("at", x, y, Self.normalizedAngle((at.number(at: 2) ?? 0) + degrees)))
        }
        router.boardChanged()
        return change("Rotate", drawings: nodes.compactMap { $0.value("uuid") })
    }

    /// The board's texts and drawings (its outline aside) taken away, by id, as one change
    public func removeDrawings(_ uuids: Set<String>) -> Edit? {
        guard !isRouting else { return nil }
        let gone = router.board.boardDrawings.filter { uuids.contains($0.value("uuid") ?? "") }
        guard !gone.isEmpty else { return nil }
        for node in gone { router.board.root.remove(node) }
        router.boardChanged()
        return change(gone.count == 1 ? "Delete" : "Delete Items", drawings: gone.compactMap { $0.value("uuid") })
    }

    /// A footprint of a library placed on its own with the pointer at `p` (mm), as KiCad's Add Footprint places one:
    /// on the front, unturned, its pads on no net, its reference and value as the library has them (or `reference`);
    /// a part of the board alone (board only: no symbol in the schematic, and kept by its updates); as one change
    /// (Edit.footprints has it)
    public func addFootprint(_ footprint: SExpr, libID: String, at p: KiCadPoint, reference: String? = nil) -> Edit? {
        guard !isRouting else { return nil }
        func field(_ name: String) -> String? {
            footprint.all("property").first { $0.text(at: 0) == name }?.text(at: 1)
                ?? footprint.all("fp_text").first { $0.text(at: 0) == name.lowercased() }?.text(at: 1)
        }
        let value = field("Value") ?? KiCadFootprintLibrary.split(libID)?.name ?? libID
        let at = KiCadPoint(Double(BoardWorld.iu(p.x)) / 1e6, Double(BoardWorld.iu(p.y)) / 1e6)
        let node = KiCadFootprintLibrary.placeable(footprint.copy(), libID: libID, reference: reference ?? field("Reference") ?? "REF**",
                                                   value: value, at: at)
        router.board.add(node)
        guard let uuid = node.value("uuid"), let placed = router.board.footprint(uuid: uuid) else { return nil }
        placed.attributes.insert("board_only")
        router.boardChanged()
        return change("Place Footprint", footprints: [uuid])
    }
}
