import AppKit
import SwiftUI
import CircuitKit

/// The example circuits in a window of their own: categories in a sidebar, a search field, and a grid of cards with a
/// drawing of each schematic. Clicking a card opens the example in a new document window, so nothing open is replaced.
struct ExampleGalleryView: View {
    static let windowID = "examples"

    @Environment(\.newDocument) private var newDocument
    @State private var section: GallerySection? = .all
    @State private var search = ""

    init() {}

    /// What the sidebar picks
    enum GallerySection: Hashable {
        case all
        case sound
        case category(ExampleCategory)
    }

    /// The examples of one category that are shown
    private struct CategoryGroup: Identifiable {
        let category: ExampleCategory
        let examples: [Example]
        var id: String { category.id }
    }

    /// Opens an example in a new, untitled document window. A new window starts running, and fits the circuit in view,
    /// as every newly opened document does.
    @MainActor
    static func openInNewWindow(_ example: Example, newDocument: NewDocumentAction) {
        let circuit = example.circuit
        newDocument { CircuitDocument(circuit: circuit) }
    }

    /// Whether an example matches the search: by title, summary or category
    static func matches(_ example: Example, _ search: String) -> Bool {
        let text = search.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        return example.title.localizedCaseInsensitiveContains(text) || example.summary.localizedCaseInsensitiveContains(text)
            || example.category.displayName.localizedCaseInsensitiveContains(text) || example.id.localizedCaseInsensitiveContains(text)
    }

    private var groups: [CategoryGroup] {
        let categories: [ExampleCategory]
        switch section ?? .all {
        case .category(let category): categories = [category]
        case .all, .sound: categories = ExampleCategory.allCases
        }
        let soundOnly = section == .sound
        return categories.compactMap { category -> CategoryGroup? in
            let examples = category.examples.filter { example in
                (!soundOnly || example.quickFeatures.contains(.sound)) && Self.matches(example, search)
            }
            return examples.isEmpty ? nil : CategoryGroup(category: category, examples: examples)
        }
    }

    private var title: String {
        switch section ?? .all {
        case .all: return "All Examples"
        case .sound: return "Makes Sound"
        case .category(let category): return category.displayName
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Label("All Examples", systemImage: "square.grid.2x2")
                    .badge(Examples.all.count)
                    .tag(GallerySection.all)
                Label("Makes Sound", systemImage: "speaker.wave.2")
                    .badge(Examples.all.filter { $0.quickFeatures.contains(.sound) }.count)
                    .tag(GallerySection.sound)
                Section("Categories") {
                    ForEach(ExampleCategory.allCases) { category in
                        Label(category.displayName, systemImage: category.symbol)
                            .badge(category.examples.count)
                            .tag(GallerySection.category(category))
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            detail
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search examples")
        .navigationTitle(title)
        .frame(minWidth: 820, minHeight: 520)
    }

    @ViewBuilder
    private var detail: some View {
        let groups = self.groups
        if groups.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)], alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.examples) { example in
                                ExampleCard(example: example) {
                                    Self.openInNewWindow(example, newDocument: newDocument)
                                }
                            }
                        } header: {
                            GalleryHeader(category: group.category, count: group.examples.count)
                        }
                    }
                }
                .padding(20)
            }
        }
    }
}

private struct GalleryHeader: View {
    let category: ExampleCategory
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: category.symbol).foregroundStyle(.tint)
            Text(category.displayName).font(.title3.weight(.semibold))
            Text("\(count)").foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 8)
    }
}

/// One example: a drawing of its schematic, its title, its summary and badges
private struct ExampleCard: View {
    let example: Example
    let open: () -> Void
    @State private var thumbnail: ExampleThumbnails.Entry?
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04))
                    if let image = thumbnail?.image {
                        Image(nsImage: image)
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        Image(systemName: example.symbol)
                            .font(.system(size: 30))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 124)
                .frame(maxWidth: .infinity)
                Text(example.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(example.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                ExampleBadges(features: example.quickFeatures.union(thumbnail?.features ?? []))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(hovering ? 0.08 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(example.summary)\n\nOpens in a new window.")
        .task(id: example.id) {
            thumbnail = await ExampleThumbnails.shared.entry(for: example)
        }
    }
}

/// Small capsules for what an example does: makes sound, runs a microcontroller, has knobs, plays from a keyboard
struct ExampleBadges: View {
    let features: ExampleFeatures

    private struct Badge: Hashable {
        let feature: ExampleFeatures
        let label: String
        let symbol: String
    }

    private static let badges = [
        Badge(feature: .sound, label: "Sound", symbol: "speaker.wave.2.fill"),
        Badge(feature: .keyboard, label: "Playable", symbol: "pianokeys"),
        Badge(feature: .knobs, label: "Knobs", symbol: "dial.medium"),
        Badge(feature: .microcontroller, label: "Code", symbol: "cpu"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.badges.filter { features.contains($0.feature) }, id: \.self) { badge in
                Label(badge.label, systemImage: badge.symbol)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
        .frame(height: 18, alignment: .leading)
    }
}

/// Drawings of the examples' schematics for the gallery, made off the main thread the first time a card appears and
/// kept for the rest of the session
@MainActor
final class ExampleThumbnails {
    static let shared = ExampleThumbnails()

    struct Entry {
        /// A template image (black on clear), tinted by the view; nil when the circuit is empty
        let image: NSImage?
        /// What the built circuit has (sound, knobs, keyboard, a microcontroller)
        let features: ExampleFeatures
    }

    static let size = CGSize(width: 300, height: 150)
    private var entries: [String: Entry] = [:]

    func cached(_ id: String) -> Entry? { entries[id] }

    func entry(for example: Example) async -> Entry {
        if let entry = entries[example.id] { return entry }
        let size = Self.size
        let made = await Task.detached(priority: .utility) { () -> (CGImage?, ExampleFeatures) in
            let circuit = example.circuit
            return (SchematicThumbnail.render(circuit, size: size), Example.features(of: circuit))
        }.value
        let image = made.0.map { cgImage -> NSImage in
            let image = NSImage(cgImage: cgImage, size: NSSize(width: size.width, height: size.height))
            image.isTemplate = true
            return image
        }
        let entry = Entry(image: image, features: made.1)
        entries[example.id] = entry
        return entry
    }
}

/// A circuit's parts drawn with the canvas's symbol renderer into a bitmap, without a window: one ink, no grid, values
/// or simulation. Pure CoreGraphics and CoreText, so it runs on any thread.
enum SchematicThumbnail {
    static func render(_ circuit: Circuit, size: CGSize, scale: Int = 2) -> CGImage? {
        guard let box = circuit.bounds else { return nil }
        let width = Int(size.width)
        let height = Int(size.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // y down, like the canvas
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        // a margin of two grid units round the parts, for symbols that reach past their terminals
        let spanX = CGFloat(box.max.x - box.min.x) + 4
        let spanY = CGFloat(box.max.y - box.min.y) + 4
        let unit = min(size.width / spanX, size.height / spanY, 14)
        let originX = size.width / 2 - CGFloat(box.min.x + box.max.x) / 2 * unit
        let originY = size.height / 2 - CGFloat(box.min.y + box.max.y) / 2 * unit
        func screen(_ p: GridPoint) -> CGPoint {
            CGPoint(x: originX + CGFloat(p.x) * unit, y: originY + CGFloat(p.y) * unit)
        }
        let ink = RGBA(0, 0, 0)
        let lineWidth = max(0.7, unit * 0.12)
        for element in circuit.elements {
            let posts = element.posts.map(screen)
            let style = SymbolStyle(lineWidth: lineWidth, terminalColors: Array(repeating: ink, count: posts.count),
                                    fill: ink, accent: ink)
            SymbolRenderer.draw(element, posts: posts, at: screen(element.a), screen(element.b), unit: unit, style: style, in: ctx)
        }
        return ctx.makeImage()
    }
}
