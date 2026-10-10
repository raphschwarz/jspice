import Foundation

/// A board's layout as an SVG drawing at its true size, to print at 100 % and build from: the holes 0.1 in (2.54 mm)
/// apart, a ruler of ten holes to check the print's scale against, each part in its holes with its name, the strips
/// and cuts, trails, links or jumpers, what is wired from off the board, and under the board the parts with their
/// holes, the bill of materials and the notes. A sheet for the bench: a stripboard's or perfboard's drawing can be laid
/// over the board itself.
public enum BoardSVG {
    /// The distance between holes, in mm
    static let pitch = 2.54
    static let margin = 10.0
    /// Room above the board for the title, the ruler and the column numbers
    static let header = 22.0

    struct Point {
        var x: Double
        var y: Double
    }

    /// The drawing being built: the board, then the lists under it
    struct Sheet {
        var width: Double
        var body: [String] = []

        mutating func line(_ a: Point, _ b: Point, color: String, width: Double, cap: String = "round", opacity: Double = 1) {
            body.append("<line x1=\"\(BoardSVG.f(a.x))\" y1=\"\(BoardSVG.f(a.y))\" x2=\"\(BoardSVG.f(b.x))\" y2=\"\(BoardSVG.f(b.y))\" stroke=\"\(color)\" stroke-width=\"\(BoardSVG.f(width))\" "
                        + "stroke-linecap=\"\(cap)\"" + (opacity < 1 ? " stroke-opacity=\"\(BoardSVG.f(opacity))\"" : "") + "/>")
        }

        mutating func circle(_ c: Point, _ r: Double, fill: String, stroke: String? = nil) {
            body.append("<circle cx=\"\(BoardSVG.f(c.x))\" cy=\"\(BoardSVG.f(c.y))\" r=\"\(BoardSVG.f(r))\" fill=\"\(fill)\"" + (stroke.map { " stroke=\"\($0)\" stroke-width=\"0.2\"" } ?? "") + "/>")
        }

        mutating func rect(x: Double, y: Double, width: Double, height: Double, fill: String, stroke: String? = nil, radius: Double = 0,
                           rotate: (angle: Double, about: Point)? = nil) {
            body.append("<rect x=\"\(BoardSVG.f(x))\" y=\"\(BoardSVG.f(y))\" width=\"\(BoardSVG.f(width))\" height=\"\(BoardSVG.f(height))\" rx=\"\(BoardSVG.f(radius))\" fill=\"\(fill)\""
                        + (stroke.map { " stroke=\"\($0)\" stroke-width=\"0.25\"" } ?? "")
                        + (rotate.map { " transform=\"rotate(\(BoardSVG.f($0.angle)) \(BoardSVG.f($0.about.x)) \(BoardSVG.f($0.about.y)))\"" } ?? "") + "/>")
        }

        mutating func text(_ string: String, _ p: Point, size: Double, anchor: String = "start", weight: String = "normal", color: String = "#222") {
            body.append("<text x=\"\(BoardSVG.f(p.x))\" y=\"\(BoardSVG.f(p.y))\" font-size=\"\(BoardSVG.f(size))\" text-anchor=\"\(anchor)\" font-weight=\"\(weight)\" "
                        + "fill=\"\(color)\">\(BoardSVG.escaped(string))</text>")
        }

        func svg(height: Double) -> String {
            ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
             "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(BoardSVG.f(width))mm\" height=\"\(BoardSVG.f(height))mm\" viewBox=\"0 0 \(BoardSVG.f(width)) \(BoardSVG.f(height))\" "
                + "font-family=\"Helvetica, Arial, sans-serif\">",
             "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>"]
                .joined(separator: "\n") + "\n" + body.joined(separator: "\n") + "\n</svg>\n"
        }
    }

    static func f(_ value: Double) -> String { String(format: "%.2f", value) }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A net's wire colour: ground blue, supplies red, the rest from a palette by name
    static func color(_ net: String, supplies: Set<String>) -> String {
        if net == "GND" { return "#1f5fd1" }
        if supplies.contains(net) { return net.hasPrefix("−") || net.hasPrefix("-") ? "#222222" : "#d12f1f" }
        let palette = ["#e07b00", "#1f9d3a", "#8a3fd1", "#c9a400", "#11908f", "#8b5a2b", "#d14f9a", "#3c8dbc", "#5b5bd6", "#0aa5c2"]
        let hash = net.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }

    /// The title, the ruler of ten holes, and the printing advice
    static func heading(_ sheet: inout Sheet, title: String, board: String) {
        sheet.text(title + " — " + board, Point(x: margin, y: 7), size: 4, weight: "bold")
        sheet.text("Print at 100 % (not fitted to the page): the ruler's ten holes span 25.4 mm. Seen from the parts' side.",
                   Point(x: margin, y: 11.5), size: 2.4, color: "#555")
        let y = 14.5
        sheet.line(Point(x: margin, y: y), Point(x: margin + 10 * pitch, y: y), color: "#222", width: 0.25, cap: "butt")
        for k in 0...10 {
            let x = margin + Double(k) * pitch
            sheet.line(Point(x: x, y: y - (k % 5 == 0 ? 1.4 : 0.8)), Point(x: x, y: y), color: "#222", width: 0.2, cap: "butt")
        }
        sheet.text("25.4 mm", Point(x: margin + 10 * pitch + 1.5, y: y), size: 2.2)
    }

    /// A part in its holes: a two-legged part as a body on the line between its legs, the rest as an outline round its
    /// legs; its name beside it, pin 1 or + marked
    static func part(_ sheet: inout Sheet, name: String, title: String, style: Breadboard.Style, legs: [(name: String, point: Point)]) {
        guard !legs.isEmpty else { return }
        let fill: String
        switch style {
        case .resistor: fill = "#e8d3a8"
        case .ceramic: fill = "#e9a23b"
        case .electrolytic: fill = "#3f5f9f"
        case .diode, .zener: fill = "#c96b5a"
        case .led: fill = "#f2d24b"
        case .transistor: fill = "#444444"
        case .dip: fill = "#333333"
        default: fill = "#9aa4ad"
        }
        if legs.count == 2 {
            let (a, b) = (legs[0].point, legs[1].point)
            let length = hypot(b.x - a.x, b.y - a.y)
            sheet.line(a, b, color: "#888", width: 0.35)
            let mid = Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let body = min(max(length - 1.6, 1.2), 7)
            let angle = atan2(b.y - a.y, b.x - a.x) * 180 / .pi
            sheet.rect(x: mid.x - body / 2, y: mid.y - 0.9, width: body, height: 1.8, fill: fill, stroke: "#333", radius: 0.6,
                       rotate: (angle: angle, about: mid))
            for leg in legs { sheet.circle(leg.point, 0.45, fill: "#111") }
            if case .electrolytic = style, let plus = legs.first(where: { $0.name == "+" }) {
                sheet.text("+", Point(x: plus.point.x + 0.9, y: plus.point.y - 0.6), size: 2.2, weight: "bold", color: "#d12f1f")
            }
            var marksCathode = style == .diode || style == .zener
            if case .led = style { marksCathode = true }
            if marksCathode, let cathode = legs.first(where: { $0.name == "cathode" }) {
                sheet.text("K", Point(x: cathode.point.x + 0.9, y: cathode.point.y - 0.6), size: 1.8, color: "#555")
            }
            sheet.text(name, Point(x: mid.x + 1.3, y: mid.y - 1.2), size: 1.8, weight: "bold")
            return
        }
        let xs = legs.map(\.point.x), ys = legs.map(\.point.y)
        let pad = 0.9
        let (left, right, top, bottom) = (xs.min()! - pad, xs.max()! + pad, ys.min()! - pad, ys.max()! + pad)
        sheet.rect(x: left, y: top, width: right - left, height: bottom - top, fill: fill, stroke: "#111", radius: 0.5)
        for leg in legs { sheet.circle(leg.point, 0.45, fill: "#d9d9d9") }
        if case .dip = style {
            // pin 1
            sheet.circle(legs[0].point, 0.75, fill: "none", stroke: "#ffffff")
        }
        sheet.text(name, Point(x: (left + right) / 2, y: (top + bottom) / 2 + 0.7), size: 2, anchor: "middle", weight: "bold", color: "#ffffff")
    }

    /// Lines of text, wrapped at about `width` characters
    static func wrapped(_ text: String, width: Int = 120) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if !line.isEmpty && line.count + word.count + 1 > width {
                lines.append(line)
                line = "   "
            }
            line += (line.isEmpty || line == "   " ? "" : " ") + word
        }
        if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
        return lines
    }

    /// The lists under the board: the parts with their holes, what is wired from off the board, the bill of materials,
    /// the notes; returns the sheet's height
    static func lists(_ sheet: inout Sheet, from y0: Double, parts: [(String, String)], offBoard: [String], bom: [Breadboard.Item],
                      notes: [String]) -> Double {
        var y = y0
        func heading(_ title: String) {
            y += 3
            sheet.text(title, Point(x: margin, y: y), size: 3, weight: "bold")
            y += 4
        }
        func row(_ text: String) {
            for line in wrapped(text) {
                sheet.text(line, Point(x: margin, y: y), size: 2.3)
                y += 3.2
            }
        }
        heading("Parts and their holes")
        for (title, holes) in parts { row(title + ":  " + holes) }
        if !offBoard.isEmpty {
            heading("Off the board")
            for item in offBoard { row(item) }
        }
        heading("Bill of materials")
        for item in bom { row("\(item.quantity) × \(item.description)" + (item.parts.isEmpty ? "" : "  (" + item.parts.joined(separator: ", ") + ")")) }
        if !notes.isEmpty {
            heading("Notes")
            for note in notes { row("• " + note) }
        }
        return y + margin
    }

    // MARK: - Stripboard and perfboard

    static func gridPoint(_ hole: Stripboard.Hole) -> Point {
        Point(x: margin + 4 + (Double(hole.column) + 0.5) * pitch, y: header + 4 + (Double(hole.row) + 0.5) * pitch)
    }

    /// The board, its row letters and column numbers
    static func grid(_ sheet: inout Sheet, rows: Int, columns: Int, color: String) {
        let origin = Point(x: margin + 4, y: header + 4)
        sheet.rect(x: origin.x - pitch / 2, y: origin.y - pitch / 2, width: Double(columns + 1) * pitch, height: Double(rows + 1) * pitch,
                   fill: color, radius: 1)
        for row in 0..<rows {
            sheet.text(Stripboard.letters(row), Point(x: origin.x - pitch * 1.1, y: gridPoint(Stripboard.Hole(row: row, column: 0)).y + 0.7),
                       size: 1.8, anchor: "end", color: "#555")
        }
        for column in stride(from: 0, to: columns, by: 5) {
            sheet.text("\(column + 1)", Point(x: gridPoint(Stripboard.Hole(row: 0, column: column)).x, y: origin.y - pitch * 0.8),
                       size: 1.8, anchor: "middle", color: "#555")
        }
    }

    static func holes(_ sheet: inout Sheet, rows: Int, columns: Int) {
        for row in 0..<rows {
            for column in 0..<columns { sheet.circle(gridPoint(Stripboard.Hole(row: row, column: column)), 0.4, fill: "#3a3a3a") }
        }
    }

    static func partsAndWires(_ sheet: inout Sheet, placements: [Stripboard.Placement], links: [Stripboard.Link],
                              offBoard: [Stripboard.OffBoard], supplies: Set<String>) {
        for link in links {
            sheet.line(gridPoint(link.from), gridPoint(link.to), color: color(link.net, supplies: supplies), width: 0.6)
        }
        for item in offBoard {
            for wire in item.wires {
                let a = gridPoint(wire.hole)
                sheet.line(a, Point(x: a.x + 1.6, y: a.y - 2), color: color(wire.net, supplies: supplies), width: 0.6)
                sheet.text("\(item.name) \(wire.name)", Point(x: a.x + 1.8, y: a.y - 2.2), size: 1.6, color: "#444")
            }
        }
        for placement in placements {
            part(&sheet, name: placement.name, title: placement.title, style: placement.style,
                 legs: placement.legs.map { (name: $0.name, point: gridPoint($0.hole)) })
        }
    }

    static func partList(_ placements: [Stripboard.Placement]) -> [(String, String)] {
        placements.map { ($0.name + "  " + $0.title, $0.legs.filter { !$0.net.isEmpty }.map { "\($0.name) \($0.hole)" }.joined(separator: " · ")) }
    }

    public static func stripboard(_ layout: Stripboard.Layout, title: String) -> String {
        var sheet = Sheet(width: max(margin * 2 + 8 + Double(layout.columns + 1) * pitch, 190))
        heading(&sheet, title: title, board: "stripboard, \(layout.rows) strips × \(layout.columns) holes")
        grid(&sheet, rows: layout.rows, columns: layout.columns, color: "#e3d3ad")
        let supplies = Set(layout.buses.values)
        // the strips, broken where they are cut
        for row in 0..<layout.rows {
            let a = gridPoint(Stripboard.Hole(row: row, column: 0)), b = gridPoint(Stripboard.Hole(row: row, column: layout.columns - 1))
            sheet.rect(x: a.x - pitch * 0.45, y: a.y - pitch * 0.38, width: b.x - a.x + pitch * 0.9, height: pitch * 0.76,
                       fill: layout.buses[row] == nil ? "#e2a46c" : "#d98c4a", radius: 0.4)
            if let net = layout.buses[row] {
                sheet.text(net, Point(x: margin, y: a.y + 0.7), size: 1.8, weight: "bold", color: color(net, supplies: supplies))
            }
        }
        for cut in layout.cuts {
            let c = gridPoint(cut)
            sheet.rect(x: c.x - pitch / 2, y: c.y - pitch * 0.42, width: pitch, height: pitch * 0.84, fill: "#e3d3ad")
            sheet.line(Point(x: c.x - 0.8, y: c.y - 0.8), Point(x: c.x + 0.8, y: c.y + 0.8), color: "#d12f1f", width: 0.4)
            sheet.line(Point(x: c.x + 0.8, y: c.y - 0.8), Point(x: c.x - 0.8, y: c.y + 0.8), color: "#d12f1f", width: 0.4)
        }
        holes(&sheet, rows: layout.rows, columns: layout.columns)
        partsAndWires(&sheet, placements: layout.placements, links: layout.links, offBoard: layout.offBoard, supplies: supplies)
        let bottom = gridPoint(Stripboard.Hole(row: layout.rows - 1, column: 0)).y + pitch * 2
        let height = lists(&sheet, from: bottom, parts: partList(layout.placements),
                           offBoard: layout.offBoard.map { "\($0.name): \($0.title) — " + $0.wires.map { "\($0.name) → \($0.hole)" }.joined(separator: " · ") },
                           bom: layout.bom, notes: layout.notes + ["Cuts are marked ✕, links drawn coloured; strips run left to right under the board."])
        return sheet.svg(height: height)
    }

    public static func perfboard(_ layout: Perfboard.Layout, title: String) -> String {
        var sheet = Sheet(width: max(margin * 2 + 8 + Double(layout.columns + 1) * pitch, 190))
        heading(&sheet, title: title, board: "perfboard, \(layout.rows) × \(layout.columns) holes")
        grid(&sheet, rows: layout.rows, columns: layout.columns, color: "#e8dcbc")
        let supplies = Set(layout.buses.values)
        for row in 0..<layout.rows {
            for column in 0..<layout.columns { sheet.circle(gridPoint(Perfboard.Hole(row: row, column: column)), 0.9, fill: "#e2a46c") }
            if let net = layout.buses[row] {
                sheet.text(net, Point(x: margin, y: gridPoint(Perfboard.Hole(row: row, column: 0)).y + 0.7), size: 1.8, weight: "bold",
                           color: color(net, supplies: supplies))
            }
        }
        // the trails on the copper side, seen through the board
        for trail in layout.trails {
            let a = gridPoint(Perfboard.Hole(row: trail.row, column: trail.from)), b = gridPoint(Perfboard.Hole(row: trail.row, column: trail.to))
            sheet.line(a, b, color: "#9a9a9a", width: 1.1)
            sheet.line(a, b, color: color(trail.net, supplies: supplies), width: 0.35, opacity: 0.8)
        }
        holes(&sheet, rows: layout.rows, columns: layout.columns)
        partsAndWires(&sheet, placements: layout.placements, links: layout.links, offBoard: layout.offBoard, supplies: supplies)
        let bottom = gridPoint(Perfboard.Hole(row: layout.rows - 1, column: 0)).y + pitch * 2
        let height = lists(&sheet, from: bottom, parts: partList(layout.placements),
                           offBoard: layout.offBoard.map { "\($0.name): \($0.title) — " + $0.wires.map { "\($0.name) → \($0.hole)" }.joined(separator: " · ") },
                           bom: layout.bom, notes: layout.notes + ["Trails (grey, under the board) join pads on the copper side; links are drawn coloured on the parts' side."])
        return sheet.svg(height: height)
    }

    // MARK: - Breadboard

    /// A breadboard's hole: the rails above and below, strips a–e and f–j either side of a 0.3 in channel
    static func breadboardPoint(_ hole: Breadboard.Hole) -> Point {
        let left = margin + 6
        let top = header + 4
        func x(_ column: Int) -> Double { left + Double(column - 1) * pitch }
        func rowY(_ row: Int) -> Double { top + 4 * pitch + Double(row) * pitch + (row >= 5 ? 2 * pitch : 0) }
        switch hole {
        case .strip(let column, let row): return Point(x: x(column), y: rowY(row))
        case .rail(let rail, let column):
            let y: Double
            switch rail {
            case .topPositive: y = top
            case .topNegative: y = top + pitch
            case .bottomNegative: y = rowY(9) + 3 * pitch
            case .bottomPositive: y = rowY(9) + 4 * pitch
            }
            return Point(x: x(column), y: y)
        }
    }

    public static func breadboard(_ layout: Breadboard.Layout, title: String) -> String {
        let width = layout.width
        var sheet = Sheet(width: max(margin * 2 + 10 + Double(width + 1) * pitch, 190))
        heading(&sheet, title: title, board: "\(layout.boards) × solderless breadboard, " + layout.size.title.lowercased())
        let first = breadboardPoint(.rail(.topPositive, column: 1)), last = breadboardPoint(.rail(.bottomPositive, column: width))
        sheet.rect(x: first.x - pitch * 1.5, y: first.y - pitch * 1.2, width: last.x - first.x + pitch * 3, height: last.y - first.y + pitch * 2.4,
                   fill: "#f2f0e8", stroke: "#bbb", radius: 1.5)
        // the channel, and the gaps between boards
        let e = breadboardPoint(.strip(column: 1, row: 4)), f = breadboardPoint(.strip(column: 1, row: 5))
        sheet.rect(x: first.x - pitch * 1.5, y: e.y + pitch * 0.6, width: last.x - first.x + pitch * 3, height: f.y - e.y - pitch * 1.2, fill: "#e2dfd4")
        if layout.boards > 1 {
            for k in 1..<layout.boards {
                let x = (breadboardPoint(.strip(column: k * layout.size.columns, row: 0)).x + breadboardPoint(.strip(column: k * layout.size.columns + 1, row: 0)).x) / 2
                sheet.rect(x: x - 0.3, y: first.y - pitch * 1.2, width: 0.6, height: last.y - first.y + pitch * 2.4, fill: "#ffffff")
            }
        }
        let supplies = Set(layout.rails.values)
        for rail in Breadboard.Rail.allCases {
            let a = breadboardPoint(.rail(rail, column: 1)), b = breadboardPoint(.rail(rail, column: width))
            let positive = rail == .topPositive || rail == .bottomPositive
            let offset = (rail == .topPositive || rail == .bottomNegative) ? -1.3 : 1.3
            sheet.line(Point(x: a.x - pitch, y: a.y + offset), Point(x: b.x + pitch, y: b.y + offset), color: positive ? "#d12f1f" : "#1f5fd1",
                       width: 0.3, cap: "butt")
            if let net = layout.rails[rail] {
                sheet.text(net, Point(x: margin, y: a.y + 0.7), size: 1.8, weight: "bold", color: positive ? "#d12f1f" : "#1f5fd1")
            }
        }
        for column in 1...width {
            for row in 0..<10 { sheet.circle(breadboardPoint(.strip(column: column, row: row)), 0.4, fill: "#555") }
            for rail in Breadboard.Rail.allCases { sheet.circle(breadboardPoint(.rail(rail, column: column)), 0.4, fill: "#555") }
            if column == 1 || column % 5 == 0 {
                let p = breadboardPoint(.strip(column: column, row: 0))
                sheet.text("\(column)", Point(x: p.x, y: p.y - pitch * 1.2), size: 1.8, anchor: "middle", color: "#555")
            }
        }
        for row in 0..<10 {
            let p = breadboardPoint(.strip(column: 1, row: row))
            sheet.text(String(Character(UnicodeScalar(UInt8(97 + row)))), Point(x: p.x - pitch * 1.1, y: p.y + 0.7), size: 1.8, anchor: "end", color: "#555")
        }
        for jumper in layout.jumpers {
            sheet.line(breadboardPoint(jumper.from), breadboardPoint(jumper.to), color: color(jumper.net, supplies: supplies), width: 0.6)
        }
        for item in layout.offBoard {
            for wire in item.wires {
                let a = breadboardPoint(wire.hole)
                sheet.line(a, Point(x: a.x + 1.6, y: a.y - 2), color: color(wire.net, supplies: supplies), width: 0.6)
                sheet.text("\(item.name) \(wire.name)", Point(x: a.x + 1.8, y: a.y - 2.2), size: 1.6, color: "#444")
            }
        }
        for placement in layout.placements {
            part(&sheet, name: placement.name, title: placement.title, style: placement.style,
                 legs: placement.legs.map { (name: $0.name, point: breadboardPoint($0.hole)) })
        }
        let height = lists(&sheet, from: last.y + pitch * 2,
                           parts: layout.placements.map { ($0.name + "  " + $0.title,
                                                           $0.legs.filter { !$0.net.isEmpty }.map { "\($0.name) \($0.hole)" }.joined(separator: " · ")) },
                           offBoard: layout.offBoard.map { "\($0.name): \($0.title) — " + $0.wires.map { "\($0.name) → \($0.hole)" }.joined(separator: " · ") },
                           bom: layout.bom, notes: layout.notes)
        return sheet.svg(height: height)
    }
}
