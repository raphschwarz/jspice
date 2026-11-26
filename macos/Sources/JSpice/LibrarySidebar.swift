import AppKit
import SwiftUI
import CircuitKit

/// Small template images of each part's schematic symbol, drawn with the same renderer as the canvas.
@MainActor
enum SymbolIcons {
    private static var cache: [ElementKind: NSImage] = [:]

    static func image(_ kind: ElementKind) -> NSImage {
        if let cached = cache[kind] { return cached }
        let width = 34
        let height = 22
        let scale = 2
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return NSImage() }
        // y down, like the canvas
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let black = RGBA(0, 0, 0)
        let style = SymbolStyle(lineWidth: 1.4, terminalColors: [black, black, black], fill: black, accent: black)
        let element: Element
        let a: CGPoint
        let b: CGPoint
        let unit: CGFloat
        switch kind {
        case .ground:
            element = Element(kind: kind, a: .zero, b: GridPoint(0, 1))
            (a, b, unit) = (CGPoint(x: 17, y: 4), CGPoint(x: 17, y: 14), 10)
        case .nmos, .pmos, .npn, .pnp, .njfet, .pjfet, .triode, .pentode:
            element = Element(kind: kind, a: .zero, b: GridPoint(2, 0))
            (a, b, unit) = (CGPoint(x: 7, y: 11), CGPoint(x: 16, y: 11), 4.5)
        case .opAmp, .multiplier, .comparator, .delayLine, .digitalDelay, .vco, .vcf, .envelope, .vca, .sampleHold, .divider,
             .logicGate, .levelDetector, .springReverb, .agcPreamp:
            element = Element(kind: kind, a: .zero, b: GridPoint(4, 0))
            (a, b, unit) = (CGPoint(x: 5, y: 11), CGPoint(x: 29, y: 11), 5.5)
        case .ota, .vactrol, .transformer:
            element = Element(kind: kind, a: .zero, b: GridPoint(4, 0))
            (a, b, unit) = (CGPoint(x: 7, y: 9), CGPoint(x: 27, y: 9), 4.6)
        case .timer555:
            element = Element(kind: kind, a: .zero, b: GridPoint(0, 5))
            (a, b, unit) = (CGPoint(x: 17, y: -0.5), CGPoint(x: 17, y: 22), 4.5)
        case .atmega328p, .atmega2560, .attiny85, .rp2040, .stm32f405, .stm32f373, .stm32f103, .flipFlop, .decadeCounter, .binaryCounter, .shiftRegister, .shiftIn, .ledDriver, .ledSink, .i2cEeprom, .analogMux, .analogSelector, .pll, .dac, .dualDac, .spiAdc, .i2cDac, .i2sDac, .codec, .cvDac,
             .microphone, .instrumentationAmp, .lineReceiver, .lineDriver, .audioPowerAmp, .compander, .balancedModulator, .mixerOscillator, .tappedTransformer, .functionGenerator, .nortonAmp, .bbdClock, .multiTapDelay, .effectsProcessor, .reverbBrick, .analogEngine, .footswitch, .jack, .regulator, .toneControl, .barGraphDriver,
             .balancedCable:
            let length = CGFloat(kind.chipPackage?.length ?? 13)
            element = Element(kind: kind, a: .zero, b: GridPoint(0, Int(length)))
            unit = min(19.6 / length, 4.4)
            (a, b) = (CGPoint(x: 17, y: 11 - length * unit / 2), CGPoint(x: 17, y: 11 + length * unit / 2))
        case .block:
            // a box with an input and an output
            var inner = Circuit()
            inner.elements = [Element(kind: .port, name: "in", a: GridPoint(0, 0), b: GridPoint(1, 0), params: ["side": 1]),
                              Element(kind: .port, name: "out", a: GridPoint(4, 0), b: GridPoint(5, 0), params: ["side": 2])]
            var box = Element(kind: kind, a: .zero, b: GridPoint(0, 2))
            box.block = inner.asBlock(named: "")
            element = box
            unit = 4.4
            (a, b) = (CGPoint(x: 17, y: 11 - unit), CGPoint(x: 17, y: 11 + unit))
        case .analogSwitch:
            element = Element(kind: kind, a: .zero, b: GridPoint(4, 0))
            (a, b, unit) = (CGPoint(x: 2, y: 16), CGPoint(x: 32, y: 16), 6.5)
        case .potentiometer:
            // lower, to leave room for the wiper above
            element = Element(kind: kind, a: .zero, b: GridPoint(4, 0))
            (a, b, unit) = (CGPoint(x: 2, y: 15), CGPoint(x: 32, y: 15), 6.5)
        default:
            element = Element(kind: kind, a: .zero, b: GridPoint(4, 0), closed: false)
            (a, b, unit) = (CGPoint(x: 2, y: 13), CGPoint(x: 32, y: 13), 6.5)
        }
        var posts: [CGPoint] = []
        switch kind {
        case .potentiometer, .analogSwitch:
            posts = [a, b, CGPoint(x: (a.x + b.x) / 2, y: 2)]
        case .ota, .timer555, .atmega328p, .atmega2560, .attiny85, .rp2040, .stm32f405, .stm32f373, .stm32f103, .flipFlop, .decadeCounter, .binaryCounter, .shiftRegister, .shiftIn, .ledDriver, .ledSink, .i2cEeprom, .analogMux,
             .analogSelector, .pll, .dac, .dualDac, .spiAdc, .i2cDac, .i2sDac, .codec, .cvDac, .block:
            // the element's own terminal layout, scaled into the icon
            posts = element.posts.map { CGPoint(x: a.x + CGFloat($0.x) * unit, y: a.y + CGFloat($0.y) * unit) }
        default:
            break
        }
        SymbolRenderer.draw(element, posts: posts, at: a, b, unit: unit, style: style, in: ctx)
        guard let cgImage = ctx.makeImage() else { return NSImage() }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        image.isTemplate = true
        cache[kind] = image
        return image
    }
}

/// The part kinds placed or chosen most recently, newest first, kept in the user defaults for every window
@MainActor
final class RecentParts: ObservableObject {
    static let shared = RecentParts()
    static let limit = 6
    static let defaultsKey = "RecentPartKinds"

    @Published private(set) var kinds: [ElementKind]

    init() {
        let names = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        kinds = Array(names.compactMap { ElementKind(rawValue: $0) }.filter(Self.isRecordable).prefix(Self.limit))
    }

    /// Parts worth offering again: not wires (drawn all the time, W) and not blocks (the Blocks section lists them)
    static func isRecordable(_ kind: ElementKind) -> Bool {
        kind.isPlaceable && kind != .wire && kind != .block
    }

    func record(_ kind: ElementKind) {
        guard Self.isRecordable(kind), kinds.first != kind else { return }
        var next = kinds.filter { $0 != kind }
        next.insert(kind, at: 0)
        kinds = Array(next.prefix(Self.limit))
        UserDefaults.standard.set(kinds.map(\.rawValue), forKey: Self.defaultsKey)
    }
}

struct LibrarySidebar: View {
    @ObservedObject var editor: EditorState
    @ObservedObject private var recents = RecentParts.shared
    @State private var search = ""
    /// The library sections folded away, by name (kept between launches)
    @AppStorage("LibraryCollapsedSections") private var collapsedSections = ""
    @Environment(\.openWindow) private var openWindow

    private var searchText: String { search.trimmingCharacters(in: .whitespaces).lowercased() }

    /// The parts of a category that match the search (by name, category or the real parts they model)
    private func kinds(in category: ElementCategory) -> [ElementKind] {
        let text = searchText
        return ElementKind.allCases.filter { kind in
            kind.isPlaceable && kind.category == category
                && (text.isEmpty || kind.searchTerms.contains { $0.lowercased().contains(text) })
        }
    }

    /// The saved blocks that match the search
    private var blocks: [BlockDefinition] {
        let text = searchText
        return editor.libraryBlocks.filter { text.isEmpty || $0.name.lowercased().contains(text) || "block".contains(text) }
    }

    /// Whether a section is unfolded; every section is while searching, so nothing that matches is hidden
    private func isExpanded(_ name: String) -> Binding<Bool> {
        Binding(
            get: { !searchText.isEmpty || !collapsedSections.split(separator: "|").contains { $0 == name } },
            set: { expanded in
                var names = collapsedSections.split(separator: "|").map(String.init).filter { $0 != name }
                if !expanded { names.append(name) }
                collapsedSections = names.joined(separator: "|")
            })
    }

    private func partRow(_ kind: ElementKind) -> some View {
        ToolRow(title: kind.displayName, shortcut: kind.shortcutLabel, isActive: editor.tool == kind) {
            Image(nsImage: SymbolIcons.image(kind))
                .renderingMode(.template)
                .frame(width: 34, height: 22)
        } action: {
            // back to the canvas, so Esc and the shortcuts work at once
            editor.choose(editor.tool == kind ? nil : kind)
        }
    }

    var body: some View {
        List {
            Section {
                Button {
                    openWindow(id: ExampleGalleryView.windowID)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2.fill")
                            .foregroundStyle(.tint)
                            .frame(width: 34, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Examples")
                            Text("Pedals, synths, amps, Arduino…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Browse about ninety ready-made circuits, by category, in their own window")
                ToolRow(title: "Select", shortcut: "Esc", isActive: editor.tool == nil) {
                    Image(systemName: "cursorarrow").frame(width: 34, height: 22)
                } action: {
                    editor.tool = nil
                }
            }
            if searchText.isEmpty && !recents.kinds.isEmpty {
                Section(isExpanded: isExpanded("Recent")) {
                    ForEach(recents.kinds) { kind in
                        partRow(kind)
                    }
                } header: {
                    Text("Recent")
                }
            }
            ForEach(ElementCategory.allCases.filter { !kinds(in: $0).isEmpty || ($0 == .blocks && !blocks.isEmpty) }) { category in
                Section(isExpanded: isExpanded(category.rawValue)) {
                    if category == .blocks {
                        // the blocks saved with Circuit ▸ Save as Block
                        ForEach(blocks, id: \.name) { block in
                            ToolRow(title: block.name, shortcut: nil, isActive: editor.tool == .block && editor.blockToPlace?.name == block.name) {
                                Image(systemName: "square.on.square.dashed").frame(width: 34, height: 22)
                            } action: {
                                editor.choose(block: block)
                            }
                            .contextMenu {
                                Button("Delete from Library", role: .destructive) {
                                    try? BlockLibrary.delete(named: block.name)
                                    editor.reloadBlockLibrary()
                                }
                            }
                        }
                    }
                    ForEach(kinds(in: category)) { kind in
                        partRow(kind)
                    }
                } header: {
                    Text(category.rawValue)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search parts")
    }
}

private struct ToolRow<Icon: View>: View {
    let title: String
    let shortcut: String?
    let isActive: Bool
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon().foregroundStyle(isActive ? Color.accentColor : Color.primary)
                Text(title)
                Spacer(minLength: 4)
                if let shortcut {
                    KeyCap(shortcut)
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(shortcut.map { "\(title) (\($0))" } ?? title)
    }
}
