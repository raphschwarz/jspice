// Ported from KiCad 10.0.8: pcbnew/pcbnew_config.cpp (PCB_EDIT_FRAME::LoadProjectSettings, saveProjectSettings and
// SaveProjectLocalSettings: the hidden nets and the nets' colours taken from the project's settings into the view's
// and back), pcbnew/widgets/appearance_controls.cpp (the Nets tab: NET_GRID_TABLE's Rebuild, SetValue,
// updateNetVisibility, updateNetColor, ShowAllNets and HideOtherNets; rebuildNets, OnNetGridClick, showNetclass,
// onNetclassColorChanged, onNetclassContextMenu and onNetColorMode), pcbnew/tools/board_inspection_tool.cpp
// (doHideRatsnestNet: Hide Net in Ratsnest and Show Net in Ratsnest), common/project/net_settings.cpp
// (GetEffectiveNetClass and makeEffectiveNetclass: a net's class, and its colour), common/netclass.cpp
// (ContainsNetclassWithName), include/netclass.h (HasPcbColor), pcbnew/pcb_painter.cpp (PCB_RENDER_SETTINGS::GetColor:
// the nets' colours on copper) and pcbnew/ratsnest/ratsnest_view_item.cpp (RATSNEST_VIEW_ITEM::ViewDraw: which nets'
// ratsnest is drawn, and in which colour).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// The board's nets as KiCad's PCB editor shows them: the colours the project gives nets and net classes, which nets'
/// ratsnest is hidden, and the Nets tab of its Appearance panel that changes them. Kept as KiCad keeps them while the
/// board is open (the view's PCB_RENDER_SETTINGS: hidden nets and nets' colours by net code; the net classes' colours
/// in the project's NET_SETTINGS; the net classes hidden in the local settings), taken from the project's settings as
/// KiCad takes them as it opens the board, and given back as it writes them
public struct NetDisplay: Sendable {
    /// NET_COLOR_MODE: where the nets' and net classes' colours are shown
    public enum ColorMode: Int, Sendable, CaseIterable {
        /// Not at all
        case off = 0
        /// On the ratsnest only (KiCad's default)
        case ratsnest = 1
        /// On the copper and the ratsnest
        case all = 2
    }

    /// A row of the Nets tab's list (NET_GRID_ENTRY): a net, its colour (UNSPECIFIED: none), whether its ratsnest is
    /// shown
    public struct Row: Sendable, Equatable, Identifiable {
        public var code: Int
        public var name: String
        public var color: KiCadColor
        public var visible: Bool
        public var id: Int { code }
    }

    /// A row of its net classes (rebuildNets' appendNetclass): the class, its colour (none shown for the default
    /// class, whose swatch KiCad hides), whether its ratsnest is shown
    public struct ClassRow: Sendable, Equatable, Identifiable {
        public var name: String
        public var color: KiCadColor
        public var visible: Bool
        public var isDefault: Bool
        public var id: String { name }
    }

    /// The board's nets by code, numbered as KiCad numbers them reading the board (0 the "no net" net, ""); by name
    public let netNames: [Int: String]
    public let netCodes: [String: Int]
    /// The nets' codes in NETINFO_LIST's order (by name, as its std::map of names has them)
    let byName: [Int]
    /// Each net's effective net class's classes (NETCLASS's m_constituents), the most important first
    let constituents: [Int: [String]]
    /// The project's classes, the default class first, then the others by name (rebuildNets' order)
    public let classNames: [String]

    /// The nets whose ratsnest is hidden (PCB_RENDER_SETTINGS::m_hiddenNets), by code
    public private(set) var hiddenNets: Set<Int> = []
    /// The nets' own colours (PCB_RENDER_SETTINGS::m_netColors), by code
    public private(set) var netColors: [Int: KiCadColor] = [:]
    /// The project's colours (NET_SETTINGS: the classes' as they now are, the nets' as the project file had them
    /// until written)
    public private(set) var projectColors: KiCadNetColors
    /// The net classes whose ratsnest is hidden (the local settings' m_HiddenNetclasses)
    public private(set) var hiddenNetclasses: Set<String> = []

    /// As KiCad takes them as it opens the board (LoadProjectSettings): the nets the local settings hide by name
    /// that the board has, and those of the classes they hide (a net whose effective class is that class, by its
    /// name: a net of several classes has one of its own, "Effective for net: …"); the project's nets' colours,
    /// those of the board's nets but UNSPECIFIED ones. `appearance`: the local settings' board appearance.
    public init(board: KiCadBoard, project: [String: Any]?, appearance: KiCadBoardAppearance) {
        let world = BoardWorld(board: board, project: project)
        self.init(netNames: world.netNames, project: project, appearance: appearance)
    }

    public init(netNames: [Int: String], project: [String: Any]?, appearance: KiCadBoardAppearance) {
        self.netNames = netNames
        var codes: [String: Int] = [:]
        for (code, name) in netNames { codes[name] = code }
        netCodes = codes
        byName = netNames.keys.sorted { Self.precedes(netNames[$0]!, netNames[$1]!) }
        let classes = NetClasses(project: project)
        var made: [Int: [String]] = [:]
        for (code, name) in netNames { made[code] = classes.effectiveConstituents(name).map(\.name) }
        constituents = made
        classNames = ["Default"] + classes.classes.keys.sorted { Self.precedes($0, $1) }
        projectColors = KiCadNetColors(project: project)
        for name in appearance.hiddenNets { if let code = codes[name] { hiddenNets.insert(code) } }
        for code in byName where Set(appearance.hiddenNetclasses).contains(netClassName(code)) { hiddenNets.insert(code) }
        hiddenNetclasses = Set(appearance.hiddenNetclasses)
        for (name, color) in projectColors.nets where !color.isUnspecified {
            if let code = codes[name] { netColors[code] = color }
        }
    }

    /// The view's settings kept from an older reading of the board (KiCad keeps its render settings while the board
    /// changes, and takes them from the project's settings only as it opens it): the hidden nets and the nets'
    /// colours, by the nets' names, the classes' colours and the hidden classes
    public mutating func keep(_ old: NetDisplay) {
        hiddenNets = Set(old.hiddenNets.compactMap { old.netNames[$0].flatMap { netCodes[$0] } })
        netColors = [:]
        for (code, color) in old.netColors { if let c = old.netNames[code].flatMap({ netCodes[$0] }) { netColors[c] = color } }
        for (name, color) in old.projectColors.classes { projectColors.classes[name] = color }
        projectColors.nets = old.projectColors.nets
        hiddenNetclasses = old.hiddenNetclasses
    }

    /// wxString's order (by code point)
    static func precedes(_ a: String, _ b: String) -> Bool { a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) }

    /// The name of a net's effective class (NETINFO_ITEM::GetNetClass()->GetName()): its class's, or, of several,
    /// its own composite's
    public func netClassName(_ code: Int) -> String {
        let c = constituents[code] ?? ["Default"]
        return c.count == 1 ? c[0] : "Effective for net: " + (netNames[code] ?? "")
    }

    /// NETCLASS::ContainsNetclassWithName: whether one of the net's classes' names matches `name` (wxString::Matches,
    /// the class's name a mask)
    func netClass(_ code: Int, contains name: String) -> Bool {
        (constituents[code] ?? ["Default"]).contains { WildMatch.matches($0, name) }
    }

    // MARK: - The Nets tab

    /// The Nets tab's nets (NET_GRID_TABLE::Rebuild): the board's but the "no net" net and those whose names start
    /// "unconnected-(", by name
    public var rows: [Row] {
        byName.compactMap { code in
            let name = netNames[code]!
            guard code > 0, !name.hasPrefix("unconnected-(") else { return nil }
            return Row(code: code, name: name, color: netColors[code] ?? .unspecified, visible: !hiddenNets.contains(code))
        }
    }

    /// Its net classes (rebuildNets): the default class, then the others by name
    public var classRows: [ClassRow] {
        classNames.map { name in
            ClassRow(name: name, color: projectColors.pcbColor(ofClass: name), visible: !hiddenNetclasses.contains(name),
                     isDefault: name == "Default")
        }
    }

    /// A net's colour set from its swatch (the colour picker's, which the grid's editor gives the table as its CSS
    /// string: NET_GRID_TABLE::SetValue, updateNetColor), or taken off (UNSPECIFIED: Clear Net Color)
    public mutating func setNetColor(_ code: Int, _ color: KiCadColor) {
        let c = KiCadColor(wxString: color.css) ?? .unspecified
        if c.isUnspecified { netColors.removeValue(forKey: code) } else { netColors[code] = c }
    }

    /// A net's eye clicked (OnNetGridClick, updateNetVisibility: Show or Hide Net in Ratsnest of its code)
    public mutating func toggleNet(_ code: Int) {
        hideNetInRatsnest(code, hide: !hiddenNets.contains(code))
    }

    /// Hide Net in Ratsnest or Show Net in Ratsnest (BOARD_INSPECTION_TOOL::doHideRatsnestNet) of a net's code;
    /// with none (0), of the nets of the items selected (`selection`: their nets' codes, those of no net let go), or
    /// with nothing selected, of the "no net" net itself
    public mutating func hideNetInRatsnest(_ code: Int, hide: Bool, selection: [Int] = []) {
        if code <= 0 && !selection.isEmpty {
            for c in selection where c > 0 { hideNetInRatsnest(c, hide: hide) }
            return
        }
        if hide { hiddenNets.insert(code) } else { hiddenNets.remove(code) }
    }

    /// Show All Nets (NET_GRID_TABLE::ShowAllNets): each of the tab's nets shown
    public mutating func showAllNets() {
        for row in rows { hideNetInRatsnest(row.code, hide: false) }
    }

    /// Hide All Other Nets (HideOtherNets): each of the tab's nets hidden but `code`
    public mutating func hideOtherNets(_ code: Int) {
        for row in rows { hideNetInRatsnest(row.code, hide: row.code != code) }
    }

    /// A net class's eye clicked (showNetclass): the ratsnest of every net of the board one of whose classes it is
    /// shown or hidden, and the class kept among the local settings' hidden ones or not
    public mutating func showNetclass(_ name: String, _ show: Bool) {
        for code in byName where netClass(code, contains: name) { hideNetInRatsnest(code, hide: !show) }
        if show { hiddenNetclasses.remove(name) } else { hiddenNetclasses.insert(name) }
    }

    /// Show All Netclasses (onNetclassContextMenu): showNetclass of the default class, then of each of the others
    public mutating func showAllNetclasses() {
        for name in classNames { showNetclass(name, true) }
    }

    /// Hide All Other Netclasses: showNetclass of the default class, then of each of the others, each shown if it is
    /// `name`, else hidden
    public mutating func hideOtherNetclasses(_ name: String) {
        for other in classNames { showNetclass(other, other == name) }
    }

    /// A net class's colour chosen with its swatch (onNetclassColorChanged: the colour picker's, as it is), or taken
    /// off (UNSPECIFIED: Clear Netclass Color); the default class has none to set
    public mutating func setNetclassColor(_ name: String, _ color: KiCadColor) {
        guard name != "Default", classNames.contains(name) else { return }
        projectColors.classes[name] = color
    }

    // MARK: - Written back

    /// The hidden nets' names as saveProjectSettings writes them into the local settings: the view's, in the order of
    /// their codes, of the nets the board has
    public var hiddenNetNames: [String] { hiddenNets.sorted().compactMap { netNames[$0] } }

    /// The local settings' net classes hidden, sorted (their std::set)
    public var hiddenNetclassNames: [String] { hiddenNetclasses.sorted { Self.precedes($0, $1) } }

    /// The project's colours as SaveProjectLocalSettings leaves them (as the board closes): the nets' those of the
    /// view, by the names of the board's nets, the classes' as they now are. (KiCad's File > Save writes the project
    /// before it copies the view's nets' colours into it: it writes the nets' as they were opened, the classes' as
    /// they now are, `opened`.)
    public var closedColors: KiCadNetColors {
        var c = projectColors
        c.nets = [:]
        for (code, color) in netColors { if let name = netNames[code] { c.nets[name] = color } }
        return c
    }

    /// The same as KiCad's File > Save writes them
    public var savedColors: KiCadNetColors { projectColors }

    // MARK: - Drawing

    /// The colour a net's class gives it (the effective class's HasPcbColor and GetPcbColor: of several classes, the
    /// most important one's that has one, as makeEffectiveNetclass takes it; none for the default class)
    public func classColor(_ code: Int) -> KiCadColor? {
        let names = constituents[code] ?? ["Default"]
        for name in names where name != "Default" {
            let c = projectColors.pcbColor(ofClass: name)
            if !c.isUnspecified { return c }
        }
        return nil
    }

    /// PCB_RENDER_SETTINGS::GetColor's net colour for a copper item of net `code`, with the net colour mode `mode`:
    /// in mode All, its net's own colour, else its class's; nil where the item takes its layer's (the highlight and
    /// the high contrast mode then change either as they change the layer's)
    public func copperColor(_ code: Int, mode: ColorMode) -> KiCadColor? {
        guard mode == .all else { return nil }
        if let c = netColors[code] { return c }
        return classColor(code)
    }

    /// Whether the ratsnest of net `code` is drawn (RATSNEST_VIEW_ITEM::ViewDraw: the "no net" net never, a hidden
    /// net not)
    public func showsRatsnest(_ code: Int) -> Bool { code > 0 && !hiddenNets.contains(code) }

    /// The colour the ratsnest of net `code` is drawn in (ViewDraw, the board's ratsnest): with net colours shown
    /// (mode not off), its own colour, else its class's, else the ratsnest's (`base`, the theme's); its alpha halved
    /// where nets are highlighted (`dimmed`: a net highlighted, or a ratsnest of items being moved); a highlighted net
    /// brightened by 0.8 (the background being dark), its alpha 0.4 more
    public func ratsnestColor(_ code: Int, mode: ColorMode, base: KiCadColor, highlighted: Bool, dimmed: Bool,
                              background: KiCadColor = KiCadColor(KiCadColorTheme.background)) -> KiCadColor {
        var color = base
        if mode != .off, let c = netColors[code] {
            color = c
        } else if mode != .off, let c = classColor(code) {
            color = c
        }
        if color.isUnspecified { color = base }
        func adjust(_ c: KiCadColor, _ delta: Double, _ alpha: Double) -> KiCadColor {
            (background.brightness < 0.5 ? c.brightened(delta) : c.darkened(delta)).withAlpha(min(alpha, 1))
        }
        if dimmed { color = adjust(color, 0, color.a / 2) }
        if highlighted { color = adjust(color, 0.8, color.a + 0.4) }
        return color
    }
}
