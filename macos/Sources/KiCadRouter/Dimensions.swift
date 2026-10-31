// Dimensions on the board, as KiCad's PCB editor makes and draws them (KiCad 10.0.7): pcbnew/pcb_dimension.cpp
// (PCB_DIMENSION_BASE and its aligned, orthogonal, leader, radial and centre kinds: updateGeometry, updateText,
// GetValueText, drawAnArrow, segPolyIntersection, segCircleIntersection, CollectKnockedOutSegments, Move, Rotate,
// PCB_DIM_ORTHOGONAL::Rotate), pcbnew/tools/drawing_tool.cpp (DRAWING_TOOL::DrawDimension and constrainDimension: a
// dimension drawn with the pointer, its text and style from the board's design settings), pcbnew/
// board_design_settings.cpp (the dimension defaults: units, precision, units format, suppressed zeroes, text position,
// text kept aligned, arrow length, extension offset), common/eda_units.cpp (GetText, ToUserUnit), libs/kimath/src/
// geometry/circle.cpp (CIRCLE::Contains, Intersect) and libs/kimath/include/math/box2.h (BOX2::Inflate, Centre).
// Written as pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.cpp writes a PCB_DIMENSION_BASE, read as its parser
// (parseDIMENSION) reads one. GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// A dimension of the board's (PCB_DIMENSION_BASE): what it measures (its start and end, an aligned or orthogonal
/// one's height, a radial one's leader), its style and format, its text, and the lines KiCad draws it with
/// (updateGeometry's shapes), in nanometres
public struct BoardDimension: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case aligned, orthogonal, leader, center, radial
    }

    /// DIM_UNITS_MODE
    public enum UnitsMode: Int, Sendable { case inch, mils, mm, automatic }
    /// DIM_UNITS_FORMAT
    public enum UnitsFormat: Int, Sendable { case noSuffix, bareSuffix, parenSuffix }
    /// DIM_TEXT_POSITION
    public enum TextPosition: Int, Sendable { case outside, inline, manual }
    /// One of the lines (and a leader's circle) KiCad draws a dimension with
    public enum Shape: Sendable, Equatable {
        case segment(IPoint, IPoint)
        case circle(IPoint, Int)
    }

    public var kind: Kind
    public var layer: String
    public var start = IPoint.zero
    public var end = IPoint.zero
    /// An aligned or orthogonal dimension's crossbar's distance from what it measures (m_height)
    public var height = 0
    /// An orthogonal dimension's: measuring across (horizontal, 0) or up and down (vertical, 1)
    public var vertical = false
    /// A radial dimension's leader's length
    public var leaderLength = 0
    // the style
    public var lineThickness = 200_000
    public var arrowLength = 1_270_000
    public var extensionOffset = 0
    /// How far an aligned or orthogonal dimension's extension lines go past its crossbar: KiCad's from its default
    /// arrow length (m_arrowLength * s_arrowAngle.Sin(), cut)
    public var extensionHeight = BoardDimension.defaultExtensionHeight
    public var textPosition = TextPosition.outside
    public var keepTextAligned = true
    public var arrowsInward = false
    /// A leader's frame round its text (DIM_TEXT_BORDER: none, rectangle, circle, rounded rectangle)
    public var textFrame = 0
    // the format
    public var prefix = ""
    public var suffix = ""
    public var unitsMode = UnitsMode.inch
    public var unitsFormat = UnitsFormat.bareSuffix
    /// DIM_PRECISION: 0 to 5 decimals, 6 to 9 as many as the units take
    public var precision = 4
    public var suppressZeroes = false
    /// The text shown instead of the measurement, where it has one (m_overrideTextEnabled, m_valueString)
    public var overrideText: String?
    // the text
    public var text = ""
    public var textPos = IPoint.zero
    public var textAngle = EDAAngle.zero
    /// Its width and height
    public var textSize = IPoint(1_000_000, 1_000_000)
    public var textThickness = 150_000
    public var bold = false
    public var italic = false
    public var mirrored = false

    /// What updateGeometry made: its lines, what it measured, its crossbar
    public private(set) var shapes: [Shape] = []
    public private(set) var measuredValue = 0
    public private(set) var crossbarStart = IPoint.zero
    public private(set) var crossbarEnd = IPoint.zero

    /// s_arrowAngle: 27.5°
    static let arrowAngle = EDAAngle(degrees: 27.5)
    static let defaultExtensionHeight = Int(Double(1_270_000) * arrowAngle.sin)

    /// A new dimension of `kind`, as KiCad's constructors make it
    public init(_ kind: Kind, layer: String = "Dwgs.User") {
        self.kind = kind
        self.layer = layer
        switch kind {
        case .leader:
            unitsFormat = .noSuffix
            overrideText = "Leader"
            keepTextAligned = false
        case .radial:
            unitsFormat = .noSuffix
            keepTextAligned = true
            prefix = "R "
            leaderLength = arrowLength * 3
        case .center:
            unitsFormat = .noSuffix
            overrideText = ""
        case .aligned, .orthogonal:
            break
        }
    }

    // MARK: The text

    /// The units the measurement is shown in (EDA_UNITS: automatic is the board's, millimetres)
    enum Units { case inch, mils, mm }
    var units: Units {
        switch unitsMode {
        case .inch: return .inch
        case .mils: return .mils
        case .mm, .automatic: return .mm
        }
    }

    /// GetValueText: the measurement in its units, to its precision, its zeroes after the point taken off where it
    /// suppresses them
    public var valueText: String {
        var p = precision
        if p >= 6 {
            switch units {
            case .inch: p -= 4
            case .mils: p = max(0, p - 7)
            case .mm: p -= 5
            }
        }
        let v = Double(measuredValue)
        let value: Double
        switch units {
        case .mm: value = v / 1e6
        case .mils: value = v / (1e6 * 0.0254)
        case .inch: value = v / (1e6 * 0.0254) / 1000
        }
        var text = String(format: "%.\(p)f", value)
        if suppressZeroes {
            while text.hasSuffix("0") {
                text.removeLast()
                if text.hasSuffix(".") {
                    text.removeLast()
                    break
                }
            }
        }
        return text
    }

    /// EDA_UNIT_UTILS::GetText
    var unitsText: String {
        switch units {
        case .inch: return " in"
        case .mils: return " mils"
        case .mm: return " mm"
        }
    }

    /// PCB_DIMENSION_BASE::updateText: the override or the measurement, its units after it as its format says, its
    /// prefix and suffix
    mutating func updateBaseText() {
        var t = overrideText ?? valueText
        switch unitsFormat {
        case .noSuffix: break
        case .bareSuffix: t += unitsText
        case .parenSuffix: t += " (" + unitsText.drop(while: { $0 == " " }) + ")"
        }
        text = prefix + t + suffix
    }

    /// The text as KiCad writes it in the dimension (a gr_text, centred, of the dimension's id)
    public func textNode(uuid: String) -> SExpr {
        var font: [SExprConvertible] = [SExpr("size", BoardShape.mm(textSize.y), BoardShape.mm(textSize.x)),
                                        SExpr("thickness", BoardShape.mm(textThickness))]
        if bold { font.append(SExpr("bold", Keyword("yes"))) }
        if italic { font.append(SExpr("italic", Keyword("yes"))) }
        var effects: [SExprConvertible] = [SExpr("font", font)]
        if mirrored { effects.append(SExpr("justify", Keyword("mirror"))) }
        return SExpr("gr_text", text, SExpr("at", BoardShape.mm(textPos.x), BoardShape.mm(textPos.y), Self.angle(textAngle)),
                     SExpr("layer", layer), SExpr("uuid", uuid), SExpr("effects", effects))
    }

    /// An angle as KiCad writes it (EDA_UNIT_UTILS::FormatAngle: ten significant digits, where a length is written to
    /// the nanometre)
    static func angle(_ a: EDAAngle) -> SExpr {
        var d = a.degrees
        if d == 0 { d = 0 }
        return SExpr(symbol: String(format: "%.10g", d))
    }

    /// The text as KiCad reads it (its box, its pen)
    var boardText: BoardText? { try? BoardText(textNode(uuid: ""), footprint: nil) }

    /// EDA_TEXT::GetTextBox( nullptr ) (its box, not turned) and GetEffectiveTextPenWidth
    func textBoxAndPen() -> (pos: IPoint, size: IPoint, pen: Int) {
        guard let t = boardText else { return (textPos, .zero, textThickness) }
        let box = t.textBox(Array(text.unicodeScalars))
        return (box.pos, box.size, t.penWidth)
    }

    /// GetEffectiveTextPenWidth
    var textPen: Int { boardText?.penWidth ?? textThickness }

    // MARK: The geometry

    /// Update: the dimension's lines, measurement and text made again from what it measures
    public mutating func update() {
        shapes = []
        switch kind {
        case .aligned: updateAligned()
        case .orthogonal: updateOrthogonal()
        case .leader: updateLeader()
        case .radial: updateRadial()
        case .center: updateCenter()
        }
    }

    /// The box round the text, `dx` and `dy` out (BOX2I::Inflate, which does not let a box shrink past nothing), as
    /// the polygon KiCad turns with the text about the box's centre
    private func textPolygon(_ dx: Int, _ dy: Int) -> (polygon: [IPoint], center: IPoint, width: Int) {
        var (pos, size, _) = textBoxAndPen()
        if size.x >= 0 {
            if size.x < -2 * dx {
                pos.x += size.x / 2
                size.x = 0
            } else {
                pos.x -= dx
                size.x += 2 * dx
            }
        }
        if size.y >= 0 {
            if size.y < -2 * dy {
                pos.y += size.y / 2
                size.y = 0
            } else {
                pos.y -= dy
                size.y += 2 * dy
            }
        }
        let end = pos + size
        let center = IPoint(pos.x + size.x / 2, pos.y + size.y / 2)
        let corners = [pos, IPoint(pos.x, end.y), end, IPoint(end.x, pos.y)]
        return (corners.map { KiMath.rotate($0, around: center, textAngle) }, center, size.x)
    }

    /// SHAPE_POLY_SET::Contains of a polygon of one outline
    private static func contains(_ polygon: [IPoint], _ p: IPoint) -> Bool {
        LineChain(polygon, closed: true).pointInside(p)
    }

    /// segPolyIntersection: the point where `seg` first meets the polygon's edge from its start (from its end if not
    /// `fromStart`), nil if it starts inside the polygon or never meets it
    private static func segPolyIntersection(_ polygon: [IPoint], _ seg: Seg, fromStart: Bool = true) -> IPoint? {
        let start = fromStart ? seg.a : seg.b
        var endpoint = fromStart ? seg.b : seg.a
        if contains(polygon, start) { return nil }
        for i in polygon.indices {
            let edge = Seg(polygon[i], polygon[(i + 1) % polygon.count])
            if let x = edge.intersect(seg), (x - start).squaredNorm < (endpoint - start).squaredNorm { endpoint = x }
        }
        return start == endpoint ? nil : endpoint
    }

    /// segCircleIntersection
    private static func segCircleIntersection(_ circle: Circle, _ seg: Seg) -> IPoint? {
        let start = seg.a
        var endpoint = seg.b
        if circle.contains(start) { return nil }
        for x in circle.intersect(seg) where (x - start).squaredNorm < (endpoint - start).squaredNorm { endpoint = x }
        return start == endpoint ? nil : endpoint
    }

    /// CollectKnockedOutSegments: `seg` with what the polygon covers of it cut out: none, one or two segments
    private mutating func knockOut(_ polygon: [IPoint], _ seg: Seg) {
        let containsA = Self.contains(polygon, seg.a), containsB = Self.contains(polygon, seg.b)
        let endpointA = Self.segPolyIntersection(polygon, seg)
        let endpointB = Self.segPolyIntersection(polygon, seg, fromStart: false)
        if let endpointA { shapes.append(.segment(seg.a, endpointA)) }
        if let endpointB {
            var canAdd = true
            if let endpointA, (endpointB == seg.a && endpointA == seg.b) || (endpointA == endpointB && seg.a == seg.b) {
                canAdd = false
            }
            if canAdd { shapes.append(.segment(endpointB, seg.b)) }
        }
        if !containsA && !containsB && endpointA == nil && endpointB == nil { shapes.append(.segment(seg.a, seg.b)) }
    }

    /// drawAnArrow: an arrow's two barbs at `start` pointing back along `angle`, and a tail of `length` where it has one
    private mutating func drawArrow(_ start: IPoint, _ angle: EDAAngle, _ length: Int) {
        if length != 0 { shapes.append(.segment(start, start + KiMath.rotate(IPoint(length, 0), -angle))) }
        let pos = KiMath.rotate(IPoint(arrowLength, 0), -angle + Self.arrowAngle)
        let neg = KiMath.rotate(IPoint(arrowLength, 0), -angle - Self.arrowAngle)
        shapes.append(.segment(start, start + pos))
        shapes.append(.segment(start, start + neg))
    }

    /// INWARD_ARROW_LENGTH_TO_HEAD_RATIO
    static let inwardArrowRatio = 2

    private mutating func updateAligned() {
        let dimension = end - start
        measuredValue = dimension.norm
        let ext = height > 0 ? IPoint(-dimension.y, dimension.x) : IPoint(dimension.y, -dimension.x)
        let extensionLength = abs(height) - extensionOffset + extensionHeight
        var extStart = start + ext.resized(extensionOffset)
        shapes.append(.segment(extStart, extStart + ext.resized(extensionLength)))
        extStart = end + ext.resized(extensionOffset)
        shapes.append(.segment(extStart, extStart + ext.resized(extensionLength)))
        let crossBarDistance = ext.resized(height) * KiMath.sign(height)
        crossbarStart = start + crossBarDistance
        crossbarEnd = end + crossBarDistance
        updateAlignedText()
        let box = textPolygon(textSize.x / 2, -textPen)
        knockOut(box.polygon, Seg(crossbarStart, crossbarEnd))
        let angle = EDAAngle(DPoint(dimension))
        if arrowsInward {
            drawArrow(crossbarStart, angle + .a180, arrowLength * Self.inwardArrowRatio)
            drawArrow(crossbarEnd, angle, arrowLength * Self.inwardArrowRatio)
        } else {
            drawArrow(crossbarStart, angle, 0)
            drawArrow(crossbarEnd, angle + .a180, 0)
        }
    }

    /// PCB_DIM_ALIGNED::updateText: the text beside the crossbar's middle (outside) or on it (inline), turned with it
    /// and kept the right way up where it is kept aligned
    private mutating func updateAlignedText() {
        let crossbarCenter = (crossbarEnd - crossbarStart).divided(by: 2)
        if textPosition == .outside {
            let offsetDistance = textPen + textSize.y
            let rotation: EDAAngle
            if crossbarCenter.x == 0 {
                rotation = .a90 * Double(KiMath.sign(-crossbarCenter.y))
            } else if crossbarCenter.x < 0 {
                rotation = -EDAAngle.a90
            } else {
                rotation = .a90
            }
            let offset = KiMath.rotate(crossbarCenter, rotation)
            textPos = crossbarStart + crossbarCenter + offset.resized(offsetDistance)
        } else if textPosition == .inline {
            textPos = crossbarStart + crossbarCenter
        }
        if keepTextAligned {
            var a = (EDAAngle.a360 - EDAAngle(DPoint(crossbarCenter))).normalized
            if a > .a90 && a <= .a270 { a -= .a180 }
            textAngle = a
        }
        updateBaseText()
    }

    private mutating func updateOrthogonal() {
        let measurement = vertical ? end.y - start.y : end.x - start.x
        measuredValue = abs(measurement)
        var ext = vertical ? IPoint(height, 0) : IPoint(0, height)
        var extensionLength = abs(height) - extensionOffset + extensionHeight
        var extStart = start + ext.resized(extensionOffset)
        shapes.append(.segment(extStart, extStart + ext.resized(extensionLength)))
        let crossBarDistance = ext.resized(height) * KiMath.sign(height)
        crossbarStart = start + crossBarDistance
        crossbarEnd = vertical ? IPoint(crossbarStart.x, end.y) : IPoint(end.x, crossbarStart.y)
        ext = vertical ? IPoint(end.x - crossbarEnd.x, 0) : IPoint(0, end.y - crossbarEnd.y)
        extensionLength = ext.norm - extensionOffset + extensionHeight
        extStart = crossbarEnd - ext.resized(extensionHeight)
        shapes.append(.segment(extStart, extStart + ext.resized(extensionLength)))
        updateOrthogonalText()
        let box = textPolygon(textSize.x / 2, textPen)
        knockOut(box.polygon, Seg(crossbarStart, crossbarEnd))
        let angle = EDAAngle(DPoint(crossbarEnd - crossbarStart))
        if arrowsInward {
            drawArrow(crossbarStart, angle + .a180, arrowLength * Self.inwardArrowRatio)
            drawArrow(crossbarEnd, angle, arrowLength * Self.inwardArrowRatio)
        } else {
            drawArrow(crossbarStart, angle, 0)
            drawArrow(crossbarEnd, angle + .a180, 0)
        }
    }

    /// PCB_DIM_ORTHOGONAL::updateText: the text above (or left of) the crossbar's middle, level (or upright) where it
    /// is kept aligned; then the aligned dimension's
    private mutating func updateOrthogonalText() {
        let crossbarCenter = (crossbarEnd - crossbarStart).divided(by: 2)
        if textPosition == .outside {
            let offsetDistance = textPen + textSize.y
            var offset = vertical ? IPoint(-offsetDistance, 0) : IPoint(0, -offsetDistance)
            offset += crossbarCenter
            textPos = crossbarStart + offset
        } else if textPosition == .inline {
            textPos = crossbarStart + crossbarCenter
        }
        if keepTextAligned { textAngle = abs(crossbarCenter.x) > abs(crossbarCenter.y) ? .zero : .a90 }
        updateAlignedText()
    }

    private mutating func updateLeader() {
        updateBaseText()
        let box = textPolygon(textSize.x / 2, textPen * 2)
        let firstLine = end - start
        let lineStart = start + firstLine.resized(extensionOffset)
        let arrowSeg = Seg(start, end), textSeg = Seg(end, textPos)
        var arrowSegEnd: IPoint?, textSegEnd: IPoint?
        let (boxPos, boxSize, pen) = inflatedTextBox(textSize.x / 2, textPen * 2)
        let boxCenter = IPoint(boxPos.x + boxSize.x / 2, boxPos.y + boxSize.y / 2)
        if textFrame == 2 {
            let radius = Double(boxSize.x) / 2.0 - Double(pen) / 2.0
            let circle = Circle(boxCenter, Int(radius))
            arrowSegEnd = Self.segCircleIntersection(circle, arrowSeg)
            textSegEnd = Self.segCircleIntersection(circle, textSeg)
        } else {
            arrowSegEnd = Self.segPolyIntersection(box.polygon, arrowSeg)
            textSegEnd = Self.segPolyIntersection(box.polygon, textSeg)
        }
        let arrowEnd = arrowSegEnd ?? end
        shapes.append(.segment(lineStart, arrowEnd))
        drawArrow(lineStart, EDAAngle(DPoint(firstLine)), 0)
        if !text.isEmpty {
            switch textFrame {
            case 1:
                for i in box.polygon.indices { shapes.append(.segment(box.polygon[i], box.polygon[(i + 1) % box.polygon.count])) }
            case 2:
                let radius = Double(boxSize.x) / 2.0 - Double(pen) / 2.0
                shapes.append(.circle(boxCenter, Int(radius)))
            default:
                break
            }
        }
        if let textSegEnd, arrowEnd == end { shapes.append(.segment(end, textSegEnd)) }
    }

    /// The text box inflated, not turned, and the pen
    private func inflatedTextBox(_ dx: Int, _ dy: Int) -> (IPoint, IPoint, Int) {
        var (pos, size, pen) = textBoxAndPen()
        if size.x >= 0 {
            if size.x < -2 * dx { pos.x += size.x / 2; size.x = 0 } else { pos.x -= dx; size.x += 2 * dx }
        }
        if size.y >= 0 {
            if size.y < -2 * dy { pos.y += size.y / 2; size.y = 0 } else { pos.y -= dy; size.y += 2 * dy }
        }
        return (pos, size, pen)
    }

    /// PCB_DIM_RADIAL::GetKnee: where the leader bends towards the text
    public var knee: IPoint { end + (end - start).resized(leaderLength) }

    private mutating func updateRadial() {
        let centerArm = IPoint(0, arrowLength)
        shapes.append(.segment(start - centerArm, start + centerArm))
        let arm = KiMath.rotate(centerArm, -EDAAngle.a90)
        shapes.append(.segment(start - arm, start + arm))
        measuredValue = (end - start).norm
        if keepTextAligned {
            var a = (EDAAngle.a360 - EDAAngle(DPoint(textPos - knee))).normalized
            if a > .a90 && a <= .a270 { a -= .a180 }
            textAngle = EDAAngle(degrees: Double(KiMath.round(a.degrees)))
        }
        updateBaseText()
        let box = textPolygon(textSize.x / 2, textPen)
        let radial = (end - start).resized(leaderLength)
        let arrowSeg = Seg(end, end + radial)
        let textSeg = Seg(arrowSeg.b, textPos)
        knockOut(box.polygon, arrowSeg)
        knockOut(box.polygon, textSeg)
        drawArrow(end, EDAAngle(DPoint(radial)), 0)
    }

    private mutating func updateCenter() {
        let arm = end - start
        shapes.append(.segment(start - arm, start + arm))
        let turned = KiMath.rotate(arm, -EDAAngle.a90)
        shapes.append(.segment(start - turned, start + turned))
        textPos = start
        updateBaseText()
    }

    // MARK: Moving and turning

    /// PCB_DIMENSION_BASE::Move
    public mutating func move(_ d: IPoint) {
        textPos += d
        start += d
        end += d
        update()
    }

    /// PCB_DIMENSION_BASE::Rotate about `c` (an orthogonal dimension's orientation and height turned with it first,
    /// to the nearest quarter turn)
    public mutating func rotate(around c: IPoint, by angle: EDAAngle) {
        var a = angle
        if kind == .orthogonal {
            a = a.normalized180
            if a > .a45 && a <= .a135 {
                if vertical { height = -height }
                vertical.toggle()
            } else if a < -EDAAngle.a45 && a >= -EDAAngle.a135 {
                if !vertical { height = -height }
                vertical.toggle()
            } else if a > .a135 || a < -EDAAngle.a135 {
                height = -height
            }
        }
        textAngle = (textAngle + a).normalized
        textPos = KiMath.rotate(textPos, around: c, a)
        start = KiMath.rotate(start, around: c, a)
        end = KiMath.rotate(end, around: c, a)
        update()
    }

    // MARK: Reading and writing

    /// A dimension as KiCad's parser reads it (parseDIMENSION, then Update); nil for what is not one, or one of the
    /// legacy formats
    public init?(_ node: SExpr) {
        guard node.head == "dimension", let type = node["type"]?.text(at: 0), let kind = Kind(rawValue: type) else { return nil }
        self.init(kind, layer: node.value("layer") ?? "Dwgs.User")
        overrideText = nil
        if let pts = node["pts"]?.all("xy"), pts.count >= 2 {
            start = BoardWorld.point(pts[0])
            end = BoardWorld.point(pts[1])
        }
        if kind == .aligned || kind == .orthogonal, let h = node["height"] { height = BoardWorld.iu(h, 0) }
        if kind == .radial, let l = node["leader_length"] { leaderLength = BoardWorld.iu(l, 0) }
        if kind == .orthogonal, let o = node["orientation"]?.number(at: 0) { vertical = min(max(Int(o), 0), 1) == 1 }
        if let f = node["format"] {
            prefix = f.value("prefix") ?? ""
            suffix = f.value("suffix") ?? ""
            if let u = f["units"]?.number(at: 0) { unitsMode = UnitsMode(rawValue: Int(u)) ?? .automatic }
            if let u = f["units_format"]?.number(at: 0) { unitsFormat = UnitsFormat(rawValue: Int(u)) ?? .noSuffix }
            if let p = f["precision"]?.number(at: 0) { precision = Int(p) }
            if let o = f["override_value"] { overrideText = o.text(at: 0) ?? "" }
            if let z = f["suppress_zeroes"] { suppressZeroes = z.text(at: 0) != "no" } else { suppressZeroes = f.flag("suppress_zeroes") }
        } else if kind == .center {
            overrideText = ""
        } else if kind == .leader {
            overrideText = "Leader"
        }
        if let s = node["style"] {
            keepTextAligned = false
            if let t = s["thickness"] { lineThickness = BoardWorld.iu(t, 0) }
            if let a = s["arrow_length"] { arrowLength = BoardWorld.iu(a, 0) }
            if let m = s["text_position_mode"]?.number(at: 0) { textPosition = TextPosition(rawValue: Int(m)) ?? .outside }
            if let d = s["arrow_direction"]?.text(at: 0) { arrowsInward = d == "inward" }
            if let e = s["extension_height"] { extensionHeight = BoardWorld.iu(e, 0) }
            if let f = s["text_frame"]?.number(at: 0) { textFrame = min(max(Int(f), 0), 3) }
            if let o = s["extension_offset"] { extensionOffset = BoardWorld.iu(o, 0) }
            if let k = s["keep_text_aligned"] { keepTextAligned = k.text(at: 0) != "no" } else if s.flag("keep_text_aligned") { keepTextAligned = true }
        }
        if let t = node["gr_text"] {
            text = t.text(at: 0) ?? ""
            if let at = t["at"] {
                textPos = BoardWorld.point(at)
                textAngle = EDAAngle(degrees: at.number(at: 2) ?? 0)
            }
            if let font = t["effects"]?["font"] {
                if let size = font["size"] { textSize = IPoint(BoardWorld.iu(size, 1), BoardWorld.iu(size, 0)) }
                if let th = font["thickness"] { textThickness = BoardWorld.iu(th, 0) }
                bold = font.flag("bold")
                italic = font.flag("italic")
            }
            mirrored = t["effects"]?["justify"]?.arguments.contains { $0.text == "mirror" } ?? false
        }
        update()
    }

    /// The dimension as KiCad writes it (PCB_IO_KICAD_SEXPR::format), of id `uuid`, its text last; `locked` kept
    public func node(uuid: String, locked: Bool = false) -> SExpr {
        func mm(_ v: Int) -> Double { BoardShape.mm(v) }
        var items: [SExprConvertible] = [SExpr("type", Keyword(kind.rawValue))]
        if locked { items.append(SExpr("locked", Keyword("yes"))) }
        items += [SExpr("layer", layer), SExpr("uuid", uuid),
                  SExpr("pts", SExpr("xy", mm(start.x), mm(start.y)), SExpr("xy", mm(end.x), mm(end.y)))]
        if kind == .aligned || kind == .orthogonal { items.append(SExpr("height", mm(height))) }
        if kind == .radial { items.append(SExpr("leader_length", mm(leaderLength))) }
        if kind == .orthogonal { items.append(SExpr("orientation", vertical ? 1 : 0)) }
        if kind != .center {
            var format: [SExprConvertible] = [SExpr("prefix", prefix), SExpr("suffix", suffix), SExpr("units", unitsMode.rawValue),
                                              SExpr("units_format", unitsFormat.rawValue), SExpr("precision", precision)]
            if let overrideText { format.append(SExpr("override_value", overrideText)) }
            if suppressZeroes { format.append(SExpr("suppress_zeroes", Keyword("yes"))) }
            items.append(SExpr("format", format))
        }
        var style: [SExprConvertible] = [SExpr("thickness", mm(lineThickness)), SExpr("arrow_length", mm(arrowLength)),
                                         SExpr("text_position_mode", textPosition.rawValue)]
        if kind == .aligned || kind == .orthogonal {
            style.append(SExpr("arrow_direction", Keyword(arrowsInward ? "inward" : "outward")))
            style.append(SExpr("extension_height", mm(extensionHeight)))
        }
        if kind == .leader { style.append(SExpr("text_frame", textFrame)) }
        style.append(SExpr("extension_offset", mm(extensionOffset)))
        if keepTextAligned { style.append(SExpr("keep_text_aligned", Keyword("yes"))) }
        items.append(SExpr("style", style))
        if kind != .center { items.append(textNode(uuid: uuid)) }
        return SExpr("dimension", items)
    }

    /// The dimension's lines as segments (a leader's circle as a polyline), each as wide as its line, for drawing
    public var lines: [[IPoint]] {
        shapes.map { s in
            switch s {
            case .segment(let a, let b): return [a, b]
            case .circle(let c, let r):
                return (0...36).map { k in
                    let a = Double(k) * Double.pi / 18
                    return IPoint(c.x + Int((Double(r) * Foundation.cos(a)).rounded()), c.y + Int((Double(r) * Foundation.sin(a)).rounded()))
                }
            }
        }
    }
}

// MARK: - The design settings' dimension defaults

/// What a new dimension takes from the board's design settings (BOARD_DESIGN_SETTINGS' m_Dimension…, from the
/// project's board.design_settings.defaults, KiCad's own where it has none or one out of range)
public struct DimensionDefaults: Sendable, Equatable {
    public var unitsMode = BoardDimension.UnitsMode.automatic
    public var precision = 4
    public var unitsFormat = BoardDimension.UnitsFormat.noSuffix
    public var suppressZeroes = true
    public var textPosition = BoardDimension.TextPosition.outside
    public var keepTextAligned = true
    /// 50 mils (DEFAULT_DIMENSION_ARROW_LENGTH), and 0.5 mm, in nanometres as the project keeps them (PARAM<int>)
    public var arrowLength = 1_270_000
    public var extensionOffset = 500_000

    public init() {}

    public init(project: [String: Any]?) {
        let defaults = ((project?["board"] as? [String: Any])?["design_settings"] as? [String: Any])?["defaults"] as? [String: Any] ?? [:]
        let dims = defaults["dimensions"] as? [String: Any] ?? [:]
        // (PARAM_ENUM: a number in its range, else the default)
        func number(_ d: [String: Any], _ key: String) -> Int? { (d[key] as? NSNumber)?.intValue }
        if let u = number(defaults, "dimension_units"), (0...3).contains(u) { unitsMode = BoardDimension.UnitsMode(rawValue: u)! }
        if let p = number(defaults, "dimension_precision"), (0...9).contains(p) { precision = p }
        if let f = number(dims, "units_format"), (0...2).contains(f) { unitsFormat = BoardDimension.UnitsFormat(rawValue: f)! }
        if let z = dims["suppress_zeroes"] as? Bool { suppressZeroes = z }
        if let t = number(dims, "text_position"), (0...1).contains(t) { textPosition = BoardDimension.TextPosition(rawValue: t)! }
        if let k = dims["keep_text_aligned"] as? Bool { keepTextAligned = k }
        if let a = number(dims, "arrow_length") { arrowLength = a }
        if let o = number(dims, "extension_offset") { extensionOffset = o }
    }
}

// MARK: - The dimension tool

/// KiCad's dimension tools (DRAWING_TOOL::DrawDimension: Add Aligned, Orthogonal, Center and Radial Dimension, Add
/// Leader), driven as the pointer drives them: a click for its origin, the pointer to its end and a click, for an
/// aligned or orthogonal one the pointer to its height and a click. It hands back each dimension finished, to commit
/// as KiCad's Draw Dimension does.
public struct DimensionTool: Sendable {
    public let kind: BoardDimension.Kind
    public private(set) var layer: String
    public var angleSnap: LeaderMode
    let defaults: DimensionDefaults
    let widths: LineWidths
    let texts: TextDefaults
    /// The leader's text (its properties dialog's, which KiCad opens as a leader is made)
    public var leaderText = "Leader"
    /// The dimension being drawn
    public private(set) var dimension: BoardDimension?
    /// SET_ORIGIN, SET_END, SET_HEIGHT
    var step = 0

    public init(_ kind: BoardDimension.Kind, layer: String, defaults: DimensionDefaults = DimensionDefaults(), widths: LineWidths = LineWidths(),
                texts: TextDefaults = TextDefaults(project: nil), angleSnap: LeaderMode = .direct) {
        self.kind = kind
        self.layer = layer
        self.defaults = defaults
        self.widths = widths
        self.texts = texts
        self.angleSnap = angleSnap
    }

    public var isDrawing: Bool { step > 0 }

    /// Whether the pointer goes to the grid now: not while an aligned dimension's height is set, unless it lies along
    /// x or y (DrawDimension: "Grid snapping doesn't make sense for height")
    public var snapsToGrid: Bool {
        guard step == 2, kind != .orthogonal, let d = dimension else { return true }
        return d.start.x == d.end.x || d.start.y == d.end.y
    }

    /// The layer the dimension is on (KiCad's active layer changed): its text and line the new layer's
    public mutating func setLayer(_ l: String) {
        layer = l
        guard var d = dimension else { return }
        d.layer = l
        applyStyle(&d)
        d.update()
        dimension = d
    }

    private func applyStyle(_ d: inout BoardDimension) {
        let style = texts.style(d.layer)
        d.textSize = IPoint(BoardWorld.iu(style.width), BoardWorld.iu(style.height))
        d.textThickness = BoardWorld.iu(style.thickness)
        d.italic = style.italic
        d.lineThickness = widths.width(d.layer)
    }

    /// The pointer at `p` (as KiCad's grid helper snaps it)
    public mutating func move(to p: IPoint, ctrl: Bool = false) {
        guard var d = dimension else { return }
        let constrained = (ctrl ? .direct : angleSnap) != .direct
        switch step {
        case 1:
            d.end = p
            if constrained || kind == .center { d.end = d.start + vectorSnapped45(d.end - d.start) }
            switch kind {
            case .orthogonal:
                // (the longer way measured, for the preview)
                d.vertical = abs(d.end.x - d.start.x) < abs(d.end.y - d.start.y)
            case .radial:
                var offset = IPoint(d.arrowLength * 10, 0)
                if d.end.x < d.start.x { offset = IPoint(-offset.x, 0) }
                d.textPos = d.knee + offset
            case .leader:
                var offset = IPoint(d.arrowLength * 10, 0)
                if d.end.x < d.start.x { offset = IPoint(-offset.x, 0) }
                d.textPos = d.end + offset
            default:
                break
            }
            d.update()
        case 2:
            if kind == .aligned {
                let angle = atan2(Double(d.end.y - d.start.y), Double(d.end.x - d.start.x)) + Double.pi / 2
                let delta = p - d.end
                d.height = Int(Double(delta.x) * Foundation.cos(angle) + Double(delta.y) * Foundation.sin(angle))
                d.update()
            } else if kind == .orthogonal {
                // (BOX2I( start, end - start ): not normalized, as KiCad makes it, its left its start's and its right
                // its end's; BOX2I::Contains takes it either way round)
                let bx = d.start.x, by = d.start.y, bw = d.end.x - d.start.x, bh = d.end.y - d.start.y
                let left = bx, right = bx + bw, top = by, bottom = by + bh
                let centre = IPoint(bx + bw / 2, by + bh / 2)
                let direction = p - centre
                let inside = p.x >= min(left, right) && p.x <= max(left, right) && p.y >= min(top, bottom) && p.y <= max(top, bottom)
                var vert: Bool
                if !inside {
                    if bw == 0 { vert = true } else if bh == 0 { vert = false } else if p.x > left && p.x < right { vert = false } else if p.y > top && p.y < bottom { vert = true } else {
                        vert = abs(direction.y) < abs(direction.x)
                    }
                    d.vertical = vert
                } else {
                    vert = d.vertical
                }
                let h = p - d.start
                d.height = vert ? h.x : h.y
                d.update()
            }
        default:
            break
        }
        dimension = d
    }

    /// A click at `p`: the dimension, where it finishes one (`double`: a double click, which clicks again)
    public mutating func click(at p: IPoint, double: Bool = false) -> BoardDimension? {
        switch step {
        case 0:
            var d = BoardDimension(kind, layer: layer)
            if kind == .aligned || kind == .orthogonal || kind == .radial {
                d.unitsMode = defaults.unitsMode
                d.unitsFormat = defaults.unitsFormat
                d.precision = defaults.precision
                d.suppressZeroes = defaults.suppressZeroes
                d.textPosition = defaults.textPosition
                d.keepTextAligned = defaults.keepTextAligned
            }
            if kind == .leader { d.textPos = p }
            d.mirrored = layer.hasPrefix("B.")
            applyStyle(&d)
            d.arrowLength = defaults.arrowLength
            d.extensionOffset = defaults.extensionOffset
            d.start = p
            d.end = p
            d.update()
            dimension = d
            step = 1
            return nil
        case 1:
            guard let d = dimension, d.start != d.end else { return nil }
            if kind == .aligned || kind == .orthogonal {
                step = 2
                if double { return click(at: p) }
                return nil
            }
            return finish()
        default:
            return finish()
        }
    }

    private mutating func finish() -> BoardDimension? {
        guard var d = dimension else { return nil }
        if kind == .leader {
            d.overrideText = leaderText
            d.update()
        }
        dimension = nil
        step = 0
        return d
    }

    /// Esc: the dimension being drawn dropped; false if there was none
    @discardableResult
    public mutating func cancel() -> Bool {
        let was = step > 0
        dimension = nil
        step = 0
        return was
    }
}
