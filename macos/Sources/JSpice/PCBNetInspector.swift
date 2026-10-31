import SwiftUI
import KiCadKit
import KiCadRouter

/// KiCad's Net Inspector under the board (PCB_NET_INSPECTOR_PANEL): the board's nets, each with its net class, total
/// length, via count and length, track length, length to the dies, pad count and its length of tracks on each copper
/// layer, as KiCad works them out (NetInspector); filtered by name or net class, grouped by net class and by the
/// user's rules (a regular expression between ^ and $ or slashes, a wildcard pattern, or a part of a name), sorted by
/// a click on a column's title as KiCad's panel sorts them. A net clicked is highlighted, and the board zoomed to it.
/// Its settings are kept in the board's local settings, as KiCad keeps them.
struct PCBNetInspector: View {
    @ObservedObject var appearance: PCBAppearance
    let picture: KiCadBoardPicture?
    @State private var expanded: Set<String> = []
    @State private var rulesText = ""

    private var settings: Binding<NetInspector.Settings> { $appearance.inspectorSettings }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let inspector = appearance.inspector {
                table(inspector)
            } else {
                ProgressView("Measuring the nets…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { rulesText = appearance.inspectorSettings.customGroupRules.joined(separator: ", ") }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text("Nets").font(.headline)
            TextField("Filter", text: settings.filterText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
                .help("Nets whose name or net class holds this, case aside")
            Toggle("Group by net class", isOn: settings.groupByNetclass)
            Toggle("Nets of no pads", isOn: settings.showZeroPadNets)
                .help("Show nets that have no pads too")
            TextField("Group rules", text: $rulesText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .onSubmit {
                    appearance.inspectorSettings.customGroupRules = rulesText.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
                .help("Custom groups, separated by commas: a regular expression between ^ and $ or between slashes, a wildcard pattern (* and ?), or a part of the nets' names")
            Spacer()
            if !appearance.highlighted.isEmpty {
                Button("Clear Highlight") { appearance.clearHighlight() }
                    .help("Take the nets' highlight off (~)")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private static func width(_ column: Int) -> CGFloat { column == 0 ? 170 : column == 1 ? 100 : 96 }

    private func table(_ inspector: NetInspector) -> some View {
        let rows = inspector.rows(appearance.inspectorSettings)
        let columns = inspector.titles.count
        return ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(rows) { row in
                        rowView(row, inspector, columns: columns)
                        if row.isGroup && expanded.contains(row.id) {
                            ForEach(row.children) { child in rowView(child, inspector, columns: columns, indent: true) }
                        }
                    }
                } header: {
                    header(inspector)
                }
            }
        }
    }

    private func header(_ inspector: NetInspector) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(inspector.titles.enumerated()), id: \.offset) { column, title in
                Button {
                    var s = appearance.inspectorSettings
                    if s.sortingColumn == column { s.sortAscending.toggle() } else {
                        s.sortingColumn = column
                        s.sortAscending = true
                    }
                    appearance.inspectorSettings = s
                } label: {
                    HStack(spacing: 2) {
                        Text(title).lineLimit(1)
                        if appearance.inspectorSettings.sortingColumn == column {
                            Image(systemName: appearance.inspectorSettings.sortAscending ? "chevron.up" : "chevron.down").font(.system(size: 8))
                        }
                    }
                    .frame(width: Self.width(column) - 8, alignment: column < 2 ? .leading : .trailing)
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .help("Sort by \(title)")
            }
        }
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func rowView(_ row: NetInspector.Row, _ inspector: NetInspector, columns: Int, indent: Bool = false) -> some View {
        let highlighted = row.net.map { appearance.highlighted.contains($0.name) } ?? false
        return HStack(spacing: 0) {
            ForEach(0..<columns, id: \.self) { column in
                HStack(spacing: 2) {
                    if column == 0 && row.isGroup {
                        Image(systemName: expanded.contains(row.id) ? "chevron.down" : "chevron.right").font(.system(size: 8))
                    }
                    Text(inspector.value(row, column: column))
                        .lineLimit(1)
                        .font(column < 2 ? .callout : .callout.monospacedDigit())
                }
                .padding(.leading, column == 0 && indent ? 16 : 0)
                .frame(width: Self.width(column) - 8, alignment: column < 2 ? .leading : .trailing)
                .padding(.horizontal, 4)
            }
        }
        .padding(.vertical, 2)
        .background(highlighted ? Color.accentColor.opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if row.isGroup {
                if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
            } else if let net = row.net, let picture {
                appearance.show(net, in: picture)
            }
        }
        .fontWeight(row.isGroup ? .semibold : .regular)
    }
}
