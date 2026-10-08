import Foundation

/// The circuits the JSpice Audio Unit offers as presets: the sound examples that make sense as an effect (sound in,
/// speaker out) or an instrument (keyboard sources and a speaker), and the circuits exported from the app into
/// ~/Music/JSpice/Audio Units.
public enum PluginLibrary {
    public struct Entry: Sendable {
        public var name: String
        public var circuit: Circuit
    }

    /// Where the app exports circuits for the plugin, under the user's home folder
    public static let folder = "Music/JSpice/Audio Units"

    /// The circuit as an effect: its audio inputs take the host's sound; a circuit without one, but with a single
    /// sine source, has the source turned into an audio input at the source's amplitude. Nil without a speaker.
    public static func effect(_ circuit: Circuit) -> Circuit? {
        guard circuit.elements.contains(where: { $0.kind == .speaker }) else { return nil }
        if circuit.flattened().elements.contains(where: { $0.kind == .audioInput }) { return circuit }
        let sources = circuit.elements.indices.filter { circuit.elements[$0].kind == .acVoltage }
        guard sources.count == 1 else { return nil }
        var circuit = circuit
        let source = circuit.elements[sources[0]]
        var input = Element(id: source.id, kind: .audioInput, name: source.name, a: source.a, b: source.b,
                            params: ["input": 1, "loop": 1, "level": min(max(source[param: "amplitude"], 0.001), 10),
                                     "offset": source[param: "offset"]])
        input.flipped = source.flipped
        circuit.elements[sources[0]] = input
        return circuit
    }

    /// The circuit as an instrument: nil unless it has keyboard sources and a speaker
    public static func instrument(_ circuit: Circuit) -> Circuit? {
        let flat = circuit.flattened()
        guard circuit.elements.contains(where: { $0.kind == .speaker }),
              flat.elements.contains(where: { $0.kind == .keyboardPitch || $0.kind == .keyboardGate }) else { return nil }
        return circuit
    }

    /// The presets for an effect or an instrument: the examples, then the circuits in `folder` (if given)
    public static func entries(instrument: Bool, folder: URL? = nil) -> [Entry] {
        let make: (Circuit) -> Circuit? = instrument ? Self.instrument : Self.effect
        var entries = Examples.all.compactMap { example in make(example.circuit).map { Entry(name: example.title, circuit: $0) } }
        if let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for file in files.filter({ $0.pathExtension == "jspice" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let data = try? Data(contentsOf: file), let circuit = try? JSONDecoder().decode(Circuit.self, from: data),
                      let made = make(circuit) else { continue }
                entries.append(Entry(name: file.deletingPathExtension().lastPathComponent, circuit: made))
            }
        }
        return entries
    }
}
