import SwiftUI
import CircuitKit

/// What an empty circuit shows: how to start drawing, and examples to start from
struct WelcomeView: View {
    @ObservedObject var editor: EditorState
    private let featured = ["led", "rc", "lc", "memristor"].compactMap { Examples.example($0) }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Draw a circuit")
                .font(.title2.weight(.semibold))
            Text("Pick a part in the library, then click or drag on the canvas to place it. Join parts with wires (W). The circuit simulates live as you draw.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Text("Or start from an example")
                .font(.headline)
                .padding(.top, 6)
            LazyVGrid(columns: [GridItem(.fixed(150)), GridItem(.fixed(150))], spacing: 10) {
                ForEach(featured) { example in
                    Button {
                        editor.load(example)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: example.symbol).font(.title2)
                            Text(example.title).font(.callout).multilineTextAlignment(.center)
                        }
                        .frame(width: 136, height: 64)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
