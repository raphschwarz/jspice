import Foundation

/// Note names and MIDI note numbers: middle C is "C4", note 60; "A4" is 69 (440 Hz)
public enum NoteName {
    private static let letters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
    private static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// MIDI note number of a name such as "C4", "F#3" or "Bb2", or of a plain number
    public static func number(_ name: String) -> Double? {
        let text = name.trimmingCharacters(in: .whitespaces)
        if let number = Double(text) { return number.isFinite && abs(number) < 1000 ? number : nil }
        guard let first = text.first?.uppercased().first, let base = letters[first] else { return nil }
        var rest = text.dropFirst()
        var semitone = base
        if rest.first == "#" || rest.first == "♯" {
            semitone += 1
            rest = rest.dropFirst()
        } else if rest.first == "b" || rest.first == "♭" {
            semitone -= 1
            rest = rest.dropFirst()
        }
        guard let octave = Int(rest), (-2...12).contains(octave) else { return nil }
        return Double((octave + 1) * 12 + semitone)
    }

    /// Name of the nearest note, such as "C4" for 60
    public static func name(_ note: Double) -> String {
        guard note.isFinite, abs(note) < 1e6 else { return "?" }
        let n = Int(note.rounded())
        let octave = Int((Double(n) / 12).rounded(.down)) - 1
        return names[((n % 12) + 12) % 12] + "\(octave)"
    }
}
