import Foundation
import MusicTheory

extension Progression {
    /// One typed line of chords as a progression: bars split on `|`, the chords inside a bar
    /// sharing its beats equally. "Dm7 G7 | Cmaj7" is two chords over bar one and one over bar two.
    /// A bar with nothing in it is skipped; a symbol that cannot be read makes the whole line nil,
    /// with `unreadable` naming it.
    public static func parse(_ text: String, key: Key, beatsPerBar: Int = 4) -> Result<Progression, ChordParseError> {
        var bars: [ProgressionBar] = []
        for barText in text.split(separator: "|", omittingEmptySubsequences: true) {
            let symbols = barText.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
            guard !symbols.isEmpty else { continue }
            var chords: [Chord] = []
            for symbol in symbols {
                guard let chord = Chord(parsing: symbol) else { return .failure(ChordParseError(symbol: symbol)) }
                chords.append(chord)
            }
            let beats = Double(beatsPerBar) / Double(chords.count)
            bars.append(ProgressionBar(chords: chords.map { ChordSpan($0, beats: beats) }))
        }
        guard !bars.isEmpty else { return .failure(ChordParseError(symbol: "")) }
        return .success(Progression(key: key, bars: bars))
    }

    /// The progression as a typed line, bars separated by `|`.
    public func symbols(preferring preference: SpellingPreference? = nil) -> String {
        // Spelled in the sheet's own key when nobody asks otherwise: the diminished chord between
        // G and A is G♯dim7 whatever the key signature prefers, because that is what it is.
        return bars.map { bar in
            bar.chords.map { span in preference.map { span.chord.symbol(preferring: $0) } ?? key.symbol(of: span.chord) }.joined(separator: " ")
        }.joined(separator: " | ")
    }

    /// The chords as spans in order, ignoring bar boundaries — what the bass writer takes.
    public var spans: [ChordSpan] { bars.flatMap(\.chords) }
}

