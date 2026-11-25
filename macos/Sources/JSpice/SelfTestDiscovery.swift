import AppKit
import SwiftUI
import CircuitKit

/// The self-test's checks of finding things: recent parts, the ⌘K palette's ranking, the featured examples and the
/// gallery's thumbnails. (Opening an example in a new window needs SwiftUI's document scene, so it is not driven here.)
extension InteractionTest {
    private static func isPart(_ item: QuickAddPalette.Item) -> Bool {
        if case .part = item { return true }
        return false
    }

    static func checkDiscovery(editor: EditorState, document: CircuitDocument) async {
        let before = document.circuit

        // recent parts: choosing a part puts it first, once; wires are not recorded
        editor.choose(.capacitor)
        editor.choose(.resistor)
        let recents = RecentParts.shared.kinds
        check(recents.first == .resistor && recents.dropFirst().first == .capacitor,
              "choosing parts lists them as recent, newest first (\(recents.map(\.rawValue)))")
        editor.choose(.resistor)
        check(RecentParts.shared.kinds.filter { $0 == .resistor }.count == 1, "a part chosen again is listed once")
        editor.choose(.wire)
        check(RecentParts.shared.kinds.first == .resistor, "the wire tool is not listed as a recent part")
        check(RecentParts.shared.kinds.count <= RecentParts.limit, "the recent parts are at most \(RecentParts.limit)")
        let stored = UserDefaults.standard.stringArray(forKey: RecentParts.defaultsKey) ?? []
        check(stored.first == ElementKind.resistor.rawValue, "the recent parts are kept in the user defaults")
        editor.choose(nil)
        check(document.circuit == before, "choosing parts leaves the circuit as it was")

        // the palette: parts first for a part's name, commands and examples found by theirs
        let resistor = QuickAddPalette.rankedItems(for: "resistor")
        check(resistor.first == .part(.resistor), "the palette puts the resistor first for “resistor”")
        let res = QuickAddPalette.rankedItems(for: "res")
        check(res.first.map(isPart) ?? false,
              "a part comes first for “res”, ahead of the Reset command")
        check(res.contains(.command(.reset)), "the palette offers Reset for “res”")
        check(QuickAddPalette.rankedItems(for: "tidy").contains(.command(.tidyUp)), "the palette offers Tidy Up for “tidy”")
        check(QuickAddPalette.rankedItems(for: "zoom").first == .command(.zoomToFit), "the palette offers Zoom to Fit first for “zoom”")
        check(QuickAddPalette.rankedItems(for: "gallery").contains(.command(.exampleGallery)),
              "the palette offers the example gallery for “gallery”")
        check(QuickAddPalette.rankedItems(for: "tube screamer").contains(.example("tube-screamer")),
              "the palette finds the Tube Screamer example")
        check(QuickAddPalette.rankedItems(for: "TL072").first.map(isPart) ?? false,
              "a modelled part's number still finds its part first (“TL072”)")
        check(QuickAddPalette.rankedItems(for: "").allSatisfy(isPart),
              "with nothing typed the palette lists parts only")

        // the welcome view's examples and the gallery's categories
        let featured = Examples.featured.flatMap(\.ids)
        check(!featured.isEmpty && featured.allSatisfy { Examples.example($0) != nil },
              "every featured example exists (\(featured.filter { Examples.example($0) == nil }))")
        check(Examples.featured.first?.examples.contains { $0.quickFeatures.contains(.sound) } ?? false,
              "the welcome view leads with examples that make sound")
        check(ExampleCategory.allCases.allSatisfy { !$0.examples.isEmpty }, "every gallery category has examples")
        check(ExampleGalleryView.matches(Examples.example("rat")!, "distortion")
                && !ExampleGalleryView.matches(Examples.example("led")!, "distortion"),
              "the gallery's search finds examples by their text")

        // thumbnails: drawn without a window, with the built circuit's badges
        if let fuzz = Examples.example("tube-screamer") {
            let entry = await ExampleThumbnails.shared.entry(for: fuzz)
            check(entry.image != nil, "the gallery draws a thumbnail of the Tube Screamer's schematic")
            check(entry.features.contains(.sound) && entry.features.contains(.knobs),
                  "the Tube Screamer's card shows it makes sound and has knobs")
        }
        let blank = SchematicThumbnail.render(Circuit(), size: ExampleThumbnails.size)
        check(blank == nil, "an empty circuit has no thumbnail (the card keeps its symbol)")
    }
}
