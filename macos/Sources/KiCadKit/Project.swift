import Foundation

/// A new KiCad project for a board: the board as KiCad 10 makes a new one (its layers, its setup, its plot settings),
/// with a title block, an outline and the parts arranged on it, and the project file beside it with the net classes
/// the board's tracks follow
public enum KiCadProject {
    /// A net class: the widths and gaps the tracks of its nets are routed with
    public struct NetClass: Sendable, Hashable {
        public var name: String
        public var trackWidth: Double
        public var clearance: Double
        public var viaDiameter: Double
        public var viaDrill: Double
        /// The nets it takes, by name or pattern ("GND", "+*V", "VCC*")
        public var patterns: [String]

        public init(name: String, trackWidth: Double, clearance: Double, viaDiameter: Double = 0.6, viaDrill: Double = 0.3,
                    patterns: [String] = []) {
            (self.name, self.trackWidth, self.clearance, self.viaDiameter, self.viaDrill, self.patterns) =
                (name, trackWidth, clearance, viaDiameter, viaDrill, patterns)
        }

        /// KiCad's default class, at widths every board maker makes
        public static let standard = NetClass(name: "Default", trackWidth: 0.25, clearance: 0.2)
    }

    /// A new, empty board, as KiCad 10 makes one: `copperLayers` layers of copper (2, 4 or 6) and KiCad's default setup
    public static func newBoard(title: String, date: Date = Date(), company: String = "", revision: String = "1",
                                copperLayers: Int = 2) -> KiCadBoard {
        let root = try! SExpr.parse(template)
        let stamp = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate])
        var block: [SExprConvertible] = [SExpr("title", title), SExpr("date", stamp), SExpr("rev", revision)]
        if !company.isEmpty { block.append(SExpr("company", company)) }
        root.insert(SExpr("title_block", block), after: ["paper"])
        // inner layers between F.Cu and B.Cu, numbered as KiCad numbers them (In1.Cu is 4, In2.Cu 6…)
        if copperLayers > 2, let layers = root["layers"] {
            let inner = (1...(copperLayers - 2)).map { n in SExpr(list: [SExpr(symbol: String(2 + 2 * n)), SExpr(string: "In\(n).Cu"), SExpr(symbol: "signal")]) }
            layers.items.insert(contentsOf: inner, at: 3)
        }
        return KiCadBoard(root)
    }

    /// Draws the board's edge: a rectangle on Edge.Cuts
    public static func addOutline(_ board: KiCadBoard, _ box: KiCadBox) {
        let rect = SExpr("gr_rect", SExpr("start", box.minX, box.minY), SExpr("end", box.maxX, box.maxY),
                         SExpr("stroke", SExpr("width", 0.05), SExpr("type", Keyword("default"))),
                         SExpr("fill", Keyword("no")), SExpr("layer", "Edge.Cuts"), SExpr("uuid", KiCadBoard.newUUID()))
        board.root.insert(rect, after: ["gr_rect", "gr_line", "gr_poly", "gr_arc", "gr_circle", "footprint", "setup", "layers"])
    }

    /// The project file (.kicad_pro) for a board named `name`: its net classes, the nets each takes by pattern; KiCad
    /// fills in the rest with its defaults as it opens it
    public static func projectFile(name: String, netClasses: [NetClass] = [.standard]) -> String {
        var classes: [[String: Any]] = []
        var patterns: [[String: String]] = []
        for (i, c) in netClasses.enumerated() {
            classes.append([
                "name": c.name, "track_width": c.trackWidth, "clearance": c.clearance,
                "via_diameter": c.viaDiameter, "via_drill": c.viaDrill,
                "microvia_diameter": 0.3, "microvia_drill": 0.1,
                "diff_pair_width": 0.2, "diff_pair_gap": 0.25, "diff_pair_via_gap": 0.25,
                "wire_width": 6, "bus_width": 12, "line_style": 0,
                "pcb_color": "rgba(0, 0, 0, 0.000)", "schematic_color": "rgba(0, 0, 0, 0.000)",
                "priority": c.name == "Default" ? 2147483647 : i,
            ])
            for pattern in c.patterns { patterns.append(["netclass": c.name, "pattern": pattern]) }
        }
        let project: [String: Any] = [
            "meta": ["filename": name + ".kicad_pro", "version": 3],
            "net_settings": ["classes": classes, "meta": ["version": 5], "net_colors": [String: String](),
                             "netclass_assignments": [String: String](), "netclass_patterns": patterns],
            "pcbnew": ["last_paths": [String: String]()],
        ]
        let data = try! JSONSerialization.data(withJSONObject: project, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: - Arranging parts

    /// Arranges footprints in rows from `origin` (their top left), in the order given, `gap` apart, rows no wider than
    /// `width` (as KiCad spreads new footprints out, SpreadFootprints); returns the box they take
    @discardableResult
    public static func arrange(_ footprints: [KiCadFootprint], from origin: KiCadPoint, width: Double, gap: Double = 2) -> KiCadBox {
        var x = origin.x, y = origin.y, rowHeight = 0.0
        var used = KiCadBox(minX: origin.x, minY: origin.y, maxX: origin.x, maxY: origin.y)
        for footprint in footprints {
            guard let box = footprint.bounds else { continue }
            if x > origin.x && x + box.width > origin.x + width {
                x = origin.x
                y += rowHeight + gap
                rowHeight = 0
            }
            // the footprint's box's top left at (x, y)
            let shift = KiCadPoint(x - box.minX, y - box.minY)
            footprint.move(to: footprint.position + shift, rotation: footprint.rotation)
            used.include(KiCadBox(minX: x, minY: y, maxX: x + box.width, maxY: y + box.height))
            x += box.width + gap
            rowHeight = max(rowHeight, box.height)
        }
        return used
    }

    /// The width rows of these footprints should keep to: about one and a half times as wide as tall when packed
    public static func rowWidth(for footprints: [KiCadFootprint], gap: Double = 2) -> Double {
        let boxes = footprints.compactMap(\.bounds)
        let area = boxes.reduce(0) { $0 + ($1.width + gap) * ($1.height + gap) }
        let widest = boxes.map(\.width).max() ?? 0
        return max(widest, (area * 1.5).squareRoot())
    }

    /// A new board's footprints arranged in the order given (the schematic's, read left to right and top to bottom)
    /// and an outline round them `margin` away, its corner at `corner`, its sides whole millimetres
    public static func arrangeNewBoard(_ board: KiCadBoard, order: [KiCadFootprint], corner: KiCadPoint = KiCadPoint(100, 60),
                                       margin: Double = 5) {
        let used = arrange(order, from: corner + KiCadPoint(margin, margin), width: rowWidth(for: order))
        let width = ((used.maxX - corner.x) + margin).rounded(.up)
        let height = ((used.maxY - corner.y) + margin).rounded(.up)
        addOutline(board, KiCadBox(minX: corner.x, minY: corner.y, maxX: corner.x + max(width, 20), maxY: corner.y + max(height, 20)))
    }

    /// An empty board as KiCad 10.0 writes one (pcbnew's NewBoard, saved)
    static let template = """
        (kicad_pcb (version 20260206) (generator "pcbnew") (generator_version "10.0") (general (thickness 1.6) \
        (legacy_teardrops no)) (paper "A4") (layers (0 "F.Cu" signal) (2 "B.Cu" signal) (9 "F.Adhes" user "F.Adhesive") \
        (11 "B.Adhes" user "B.Adhesive") (13 "F.Paste" user) (15 "B.Paste" user) (5 "F.SilkS" user "F.Silkscreen") \
        (7 "B.SilkS" user "B.Silkscreen") (1 "F.Mask" user) (3 "B.Mask" user) (17 "Dwgs.User" user "User.Drawings") \
        (19 "Cmts.User" user "User.Comments") (21 "Eco1.User" user "User.Eco1") (23 "Eco2.User" user "User.Eco2") \
        (25 "Edge.Cuts" user) (27 "Margin" user) (31 "F.CrtYd" user "F.Courtyard") (29 "B.CrtYd" user "B.Courtyard") \
        (35 "F.Fab" user) (33 "B.Fab" user) (39 "User.1" user) (41 "User.2" user) (43 "User.3" user) (45 "User.4" user)) \
        (setup (pad_to_mask_clearance 0) (allow_soldermask_bridges_in_footprints no) (tenting (front yes) (back yes)) \
        (covering (front no) (back no)) (plugging (front no) (back no)) (capping no) (filling no) (pcbplotparams \
        (layerselection 0x00000000_00000000_55555555_5755f5ff) \
        (plot_on_all_layers_selection 0x00000000_00000000_00000000_00000000) (disableapertmacros no) \
        (usegerberextensions no) (usegerberattributes yes) (usegerberadvancedattributes yes) (creategerberjobfile yes) \
        (dashed_line_dash_ratio 12) (dashed_line_gap_ratio 3) (svgprecision 4) (plotframeref no) (mode 1) \
        (useauxorigin no) (pdf_front_fp_property_popups yes) (pdf_back_fp_property_popups yes) (pdf_metadata yes) \
        (pdf_single_document no) (dxfpolygonmode yes) (dxfimperialunits yes) (dxfusepcbnewfont yes) (psnegative no) \
        (psa4output no) (plot_black_and_white yes) (sketchpadsonfab no) (plotpadnumbers no) (hidednponfab no) \
        (sketchdnponfab yes) (crossoutdnponfab yes) (subtractmaskfromsilk no) (outputformat 1) (mirror no) \
        (drillshape 1) (scaleselection 1) (outputdirectory ""))) (embedded_fonts no))
        """
}
