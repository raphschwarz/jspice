import SwiftUI
import CircuitKit

/// What an empty window shows over the canvas: how to draw a circuit, and examples to start from, by interest. An
/// example opens in this window (there is nothing to lose); the whole collection is in the example gallery.
struct WelcomeView: View {
    @ObservedObject var editor: EditorState
    @Environment(\.openWindow) private var openWindow

    /// The title without the "(sound)" the library adds: the card shows a speaker instead
    static func shortTitle(_ example: Example) -> String {
        example.title.replacingOccurrences(of: " (sound)", with: "")
    }

    /// The card in the middle of the canvas, or, in a window too short for it, scrolling
    var body: some View {
        ViewThatFits(in: .vertical) {
            card
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ScrollView {
                card
                    .padding(16)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var card: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Draw a circuit")
                .font(.title2.weight(.semibold))
                .headingAccessibility()
            Text("Pick a part in the library, then click or drag on the canvas to place it. Join parts with wires (W). The circuit simulates live as you draw.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 2)
            Text("Or start from an example")
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Examples.featured) { group in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(group.title, systemImage: group.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .headingAccessibility()
                        // (as many to a row as the canvas has room for)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(group.examples) { example in
                                exampleButton(example)
                            }
                        }
                    }
                }
            }
            Button {
                openWindow(id: ExampleGalleryView.windowID)
            } label: {
                Label("Browse All \(Examples.all.count) Examples…", systemImage: "square.grid.2x2")
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }

    private func exampleButton(_ example: Example) -> some View {
        Button {
            editor.load(example)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: example.symbol)
                    .font(.title3)
                    .frame(width: 24)
                Text(Self.shortTitle(example))
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if example.quickFeatures.contains(.sound) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Makes sound: turn on sound in the toolbar")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .help(example.summary)
        .welcomeExampleAccessibility(example)
    }
}
