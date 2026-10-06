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
        case .nmos, .pmos, .npn, .pnp, .njfet:
            element = Element(kind: kind, a: .zero, b: GridPoint(2, 0))
            (a, b, unit) = (CGPoint(x: 7, y: 11), CGPoint(x: 16, y: 11), 4.5)
        case .opAmp, .multiplier, .comparator, .delayLine, .digitalDelay, .vco, .vcf, .envelope, .vca, .sampleHold, .divider,
             .logicGate:
            element = Element(kind: kind, a: .zero, b: GridPoint(4, 0))
            (a, b, unit) = (CGPoint(x: 5, y: 11), CGPoint(x: 29, y: 11), 5.5)
        case .ota, .vactrol:
            element = Element(kind: kind, a: .zero, b: GridPoint(4, 0))
            (a, b, unit) = (CGPoint(x: 7, y: 9), CGPoint(x: 27, y: 9), 4.6)
        case .timer555:
            element = Element(kind: kind, a: .zero, b: GridPoint(0, 5))
            (a, b, unit) = (CGPoint(x: 17, y: -0.5), CGPoint(x: 17, y: 22), 4.5)
        case .atmega328p, .atmega2560, .attiny85, .rp2040, .flipFlop, .decadeCounter, .binaryCounter, .analogMux, .analogSelector, .pll:
            let length = CGFloat(kind.chipPackage?.length ?? 13)
            element = Element(kind: kind, a: .zero, b: GridPoint(0, Int(length)))
            unit = min(19.6 / length, 4.4)
            (a, b) = (CGPoint(x: 17, y: 11 - length * unit / 2), CGPoint(x: 17, y: 11 + length * unit / 2))
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
        case .ota, .timer555, .atmega328p, .atmega2560, .attiny85, .rp2040, .flipFlop, .decadeCounter, .binaryCounter, .analogMux,
             .analogSelector, .pll:
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

struct LibrarySidebar: View {
    @ObservedObject var editor: EditorState
    @State private var search = ""

    /// The parts of a category that match the search (by name, category or the real parts they model)
    private func kinds(in category: ElementCategory) -> [ElementKind] {
        let text = search.trimmingCharacters(in: .whitespaces).lowercased()
        return ElementKind.allCases.filter { kind in
            kind.category == category && (text.isEmpty || kind.searchTerms.contains { $0.lowercased().contains(text) })
        }
    }

    var body: some View {
        List {
            Section("Tools") {
                ToolRow(title: "Select", shortcut: "Esc", isActive: editor.tool == nil) {
                    Image(systemName: "cursorarrow").frame(width: 34, height: 22)
                } action: {
                    editor.tool = nil
                }
            }
            ForEach(ElementCategory.allCases.filter { !kinds(in: $0).isEmpty }) { category in
                Section(category.rawValue) {
                    ForEach(kinds(in: category)) { kind in
                        ToolRow(title: kind.displayName, shortcut: kind.shortcutLabel, isActive: editor.tool == kind) {
                            Image(nsImage: SymbolIcons.image(kind))
                                .renderingMode(.template)
                                .frame(width: 34, height: 22)
                        } action: {
                            // back to the canvas, so Esc and the shortcuts work at once
                            editor.choose(editor.tool == kind ? nil : kind)
                        }
                    }
                }
            }
            Section("Examples") {
                ForEach(Examples.all.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { example in
                    Button {
                        editor.load(example)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(example.title)
                                Text(example.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        } icon: {
                            Image(systemName: example.symbol)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Parts and examples")
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
