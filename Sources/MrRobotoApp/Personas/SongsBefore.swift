import Foundation
import MusicTheory
import SongGraph

/// What the library's other songs did, for a reading to be made against: each one's key, the
/// loop its chords go round, and how its tune comes in.
///
/// Every reading the band gives is of the song in front of it. Ten songs each read as fine can be
/// the same song ten times — the same key, the same four chords, a tune that comes in on the same
/// note in the same place — and nothing read alone will ever say so. This is the little of the
/// other songs that the Harmonist and the Melodist need in view to say it.
public struct SongsBefore: Hashable, Sendable {

    public struct Entry: Hashable, Sendable {
        public var title: String
        public var key: Key?
        /// The roots of its main progression, in semitones above its tonic, a chord held over a
        /// bar line counted once.
        public var loop: [Int]
        /// Where its main tune comes in: the degree, in semitones above the tonic, and the place
        /// in the bar, in beats.
        public var opening: Opening?
    }

    public struct Opening: Hashable, Sendable {
        public var degree: Int
        public var beat: Double
    }

    /// The other songs, the newest first.
    public var entries: [Entry]

    /// How many songs back a reading looks.
    public static let kept = 6

    public init(entries: [Entry]) { self.entries = entries }

    /// The library's other songs that hold chords or a tune, the newest first.
    public static func of(_ library: Library, besides song: SongID?) -> SongsBefore {
        let others = library.songs.filter { $0.id != song }.sorted { $0.createdAt > $1.createdAt }
        var entries: [Entry] = []
        for other in others {
            let loop = Guidance.progressions(in: other).last.flatMap { version -> [Int]? in
                if case .progression(let sheet) = version.kind { return Self.loop(of: sheet) }
                return nil
            } ?? []
            let opening = Guidance.melodies(in: other).last.flatMap { version -> Opening? in
                if case .melody(let tune) = version.kind { return Self.opening(of: tune.notes, key: other.key, beatsPerBar: other.timeSignature.beatsPerBar) }
                return nil
            }
            guard !loop.isEmpty || opening != nil else { continue }
            entries.append(Entry(title: other.title, key: other.key, loop: loop, opening: opening))
            if entries.count >= kept { break }
        }
        return SongsBefore(entries: entries)
    }

    /// A progression's roots above its own tonic, repeats run together.
    public static func loop(of sheet: Progression) -> [Int] {
        loop(of: sheet.chords, key: sheet.key)
    }

    static func loop(of chords: [Chord], key: Key) -> [Int] {
        var out: [Int] = []
        for chord in chords {
            let degree = key.tonic.pitchClass.distance(to: chord.root)
            if out.last != degree { out.append(degree) }
        }
        return out
    }

    /// How a tune comes in: its first note's degree and its place in the bar, to the eighth.
    public static func opening(of notes: [NoteEvent], key: Key?, beatsPerBar: Int) -> Opening? {
        guard let key, let first = notes.min(by: { $0.start < $1.start }) else { return nil }
        let beat = (first.start.truncatingRemainder(dividingBy: Double(max(1, beatsPerBar))) * 2).rounded() / 2
        return Opening(degree: key.tonic.pitchClass.distance(to: first.pitch.pitchClass), beat: beat)
    }

    /// The songs whose chords go round the same loop.
    public func sharing(loop: [Int]) -> [String] {
        guard loop.count >= 2 else { return [] }
        return entries.filter { $0.loop == loop }.map(\.title)
    }

    /// How many of the songs are in this key.
    public func inKey(_ key: Key) -> Int {
        entries.filter { $0.key?.tonic.pitchClass == key.tonic.pitchClass && $0.key?.mode == key.mode }.count
    }

    /// The songs whose tune comes in on the same degree in the same place.
    public func sharing(opening: Opening) -> [String] {
        entries.filter { $0.opening == opening }.map(\.title)
    }

    /// "First Light", "First Light and Seeking Signal", "First Light, Seeking Signal and Tidewater".
    static func list(_ titles: [String]) -> String {
        guard let last = titles.last else { return "" }
        return titles.count == 1 ? last : titles.dropLast().joined(separator: ", ") + " and " + last
    }
}

extension HouseBook {

    /// The readings a house can turn off: the ones that say a tune or a progression is the usual
    /// one. They are observations about taste, and a house that writes four chords in D minor on
    /// purpose is entitled not to hear about it every time.
    public static let quietable: Set<String> = [
        "harmonist.something-of-its-own", "harmonist.not-the-last-song-again",
        "melodist.something-of-its-own", "melodist.not-the-same-opening-again",
    ]

    /// Whether the house has said, on the question a rule answers to, that it means it.
    public func quiets(_ rule: String, in bible: PersonaBible) -> Bool {
        guard Self.quietable.contains(rule) else { return false }
        return bible.openQuestions.contains { question in
            question.affects.contains(rule) && entry(for: question.id)?.call.choice == .alternative
        }
    }

    /// The readings with the ones the house has turned off no longer flags: the number is still
    /// said, and that the house meant it.
    public func settle(_ readings: [PersonaReading], by bible: PersonaBible) -> [PersonaReading] {
        readings.map { reading in
            guard !reading.holds, quiets(reading.rule, in: bible) else { return reading }
            var settled = reading
            settled.holds = true
            settled.says = (reading.says.components(separatedBy: " Two ways ").first ?? reading.says) + " This house writes it that way on purpose."
            return settled
        }
    }
}
