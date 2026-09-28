import Foundation
import MusicTheory
import Performance
import SongGraph

/// Every genre profile the app has, and which one a song is in.
public struct GenreBook: Sendable, Equatable {
    public static let directoryName = "Genres"

    public let profiles: [GenreProfile]

    public init(_ profiles: [GenreProfile]) {
        self.profiles = profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The profiles the app ships, read once from `Resources/Genres/`.
    public static let standard: GenreBook = GenreBook(bundled())

    public static func decode(_ data: Data) throws -> GenreProfile {
        try JSONDecoder().decode(GenreProfile.self, from: data)
    }

    public static func encode(_ profile: GenreProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(profile)
    }

    static func bundled() -> [GenreProfile] {
        guard let bundle = FontRegistration.resourceBundle,
              let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: "Resources/\(directoryName)") else { return [] }
        return urls.compactMap { try? decode(try Data(contentsOf: $0)) }
    }

    // MARK: Finding one

    /// A profile by id, name or alias, however it is cased or hyphenated: "Drum & Bass", "dnb",
    /// "drum-and-bass".
    public func profile(named name: String) -> GenreProfile? {
        let key = Self.fold(name)
        guard !key.isEmpty else { return nil }
        return profiles.first { Self.fold($0.id) == key }
            ?? profiles.first { Self.fold($0.name) == key }
            ?? profiles.first { $0.aliases.contains { Self.fold($0) == key } }
    }

    static func fold(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "&", with: "and")
            .filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Which one a song is in

    /// How a song's genre is known.
    public enum Source: Equatable, Sendable {
        /// Someone said: the user, or the Director on their word.
        case set
        /// Guessed from the feel a groove was written in.
        case feel(String)
        /// Guessed from the tempo alone, among the genres the feel library's idioms point to.
        case tempo
    }

    public struct Reading: Equatable, Sendable {
        public var profile: GenreProfile
        public var source: Source

        /// "House (set)", "House (guessed from the Four on the Floor feel)".
        public var description: String {
            switch source {
            case .set: "\(profile.name)"
            case .feel(let feel): "\(profile.name) (guessed from the \(feel) feel)"
            case .tempo: "\(profile.name) (guessed from the tempo)"
            }
        }
    }

    /// The song's genre: what it says it is, or a guess from the feel its newest groove was
    /// written in. Nil when nobody has said and nothing points anywhere. The tempo alone is not
    /// enough to guess from — 120 bpm is house, pop, rock and disco — so it only breaks a tie.
    public func genre(of song: Song?, feels: FeelLibrary = .standard) -> Reading? {
        guard let song else { return nil }
        if let named = song.genre, let profile = profile(named: named) { return Reading(profile: profile, source: .set) }
        for version in Guidance.grooves(in: song).reversed() {
            guard case .groove(let groove) = version.kind, let feelName = groove.feel?.name ?? Self.feelNamed(in: version.note, feels: feels) else { continue }
            if let profile = guess(feel: feelName, tempo: song.tempo, feels: feels) {
                return Reading(profile: profile, source: .feel(feelName))
            }
        }
        return nil
    }

    /// The profile a feel belongs to: among those that name the feel, the one whose style tags are
    /// most like the feel's, the nearer tempo breaking a tie. A feel no profile names goes to the
    /// profile whose tags mostly match its own, or to none — a wrong guess is worse than no guess,
    /// because the band would judge the song by it.
    public func guess(feel name: String, tempo: Double, feels: FeelLibrary = .standard) -> GenreProfile? {
        let key = Self.fold(name)
        let feel = feels.feel(named: name)
        let idioms = Set(feel?.idioms.map(\.rawValue) ?? [])
        func likeness(_ profile: GenreProfile) -> Double {
            let theirs = Set(profile.idioms)
            let union = theirs.union(idioms)
            return union.isEmpty ? 0 : Double(theirs.intersection(idioms).count) / Double(union.count)
        }
        let naming = profiles.filter { $0.feels.contains { Self.fold($0) == key } }
        let pool = naming.isEmpty ? profiles.filter { likeness($0) > 0.5 } : naming
        guard let best = pool.map(likeness).max() else { return nil }
        let meter = feel?.timeSignature ?? .fourFour
        return pool.filter { likeness($0) == best }.min { distance($0, tempo, meter) < distance($1, tempo, meter) }
    }

    private func distance(_ profile: GenreProfile, _ tempo: Double, _ meter: TimeSignature) -> Double {
        guard let range = profile.tempo else { return 1_000 }
        return profile.readings(of: tempo, in: meter).map { t -> Double in
            if range.contains(t) { return abs((range.typical ?? (range.low + range.high) / 2) - t) / 100 }
            return min(abs(range.low - t), abs(range.high - t))
        }.min() ?? 1_000
    }

    /// A feel named at the start of a groove's note, for grooves kept before grooves named their
    /// feel: the Grid writes "Boom-Bap Pocket, 90 bpm".
    static func feelNamed(in note: String?, feels: FeelLibrary) -> String? {
        guard let note else { return nil }
        return feels.feels.filter { note.hasPrefix($0.name) }.max { $0.name.count < $1.name.count }?.name
    }
}
