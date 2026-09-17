import Foundation
import MusicTheory
import SongGraph

/// A catalogue of named feels with lookup, filtering and suggestion.
///
/// The library is a value, not a singleton: `FeelLibrary.standard` is what ships, and a project
/// (or a persona that has bent a feel to taste) holds its own with `adding(_:)`. Nothing here
/// touches the disk — the shipped feels are code, so they are diffable and testable.
public struct FeelLibrary: Hashable, Sendable {
    public private(set) var feels: [Feel]

    public init(_ feels: [Feel] = []) { self.feels = feels }

    public var count: Int { feels.count }
    public var isEmpty: Bool { feels.isEmpty }
    public var names: [String] { feels.map(\.name) }

    /// Every idiom tag in the library, sorted.
    public var idioms: [Idiom] {
        Set(feels.flatMap(\.idioms)).sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: Lookup

    /// Exact name, then a forgiving match: case and non-alphanumerics are ignored, so "boom bap",
    /// "Boom-Bap" and "boombap" all find the same feel.
    public func feel(named name: String) -> Feel? {
        if let exact = feels.first(where: { $0.name == name }) { return exact }
        let key = FeelLibrary.fold(name)
        return feels.first { FeelLibrary.fold($0.name) == key }
    }

    public subscript(name: String) -> Feel? { feel(named: name) }

    // MARK: Filtering

    /// Feels carrying `idiom`.
    public func feels(idiom: Idiom) -> [Feel] {
        feels.filter { $0.suits(idiom: idiom) }
    }

    /// Feels whose tempo range contains `bpm`.
    public func feels(tempo bpm: Double) -> [Feel] {
        feels.filter { $0.suits(tempo: bpm) }
    }

    /// Feels in `signature`.
    public func feels(timeSignature signature: TimeSignature) -> [Feel] {
        feels.filter { $0.timeSignature == signature }
    }

    /// Everything at once; a nil argument does not filter.
    public func feels(idiom: Idiom? = nil, tempo: Double? = nil,
                      timeSignature signature: TimeSignature? = nil) -> [Feel] {
        feels.filter { feel in
            if let idiom, !feel.suits(idiom: idiom) { return false }
            if let tempo, !feel.suits(tempo: tempo) { return false }
            if let signature, feel.timeSignature != signature { return false }
            return true
        }
    }

    // MARK: Editing

    public func adding(_ feel: Feel) -> FeelLibrary {
        var copy = self
        copy.feels.removeAll { $0.name == feel.name }
        copy.feels.append(feel)
        return copy
    }

    public func removing(named name: String) -> FeelLibrary {
        var copy = self
        copy.feels.removeAll { $0.name == name }
        return copy
    }

    // MARK: Suggestion

    /// What a caller knows when it asks for a feel: usually a detected tempo and an idiom the
    /// director picked, sometimes a meter from the analysis.
    public struct Request: Hashable, Sendable {
        public var tempo: Double?
        public var idiom: Idiom?
        public var timeSignature: TimeSignature?
        /// How many to return.
        public var limit: Int

        public init(tempo: Double? = nil, idiom: Idiom? = nil,
                    timeSignature: TimeSignature? = nil, limit: Int = 5) {
            self.tempo = tempo
            self.idiom = idiom
            self.timeSignature = timeSignature
            self.limit = max(0, limit)
        }
    }

    /// Feels appropriate to a detected tempo and idiom, best first.
    ///
    /// Deliberately a ranking, not a filter. A detected 92 BPM with an idiom of `lo-fi` should not
    /// come back empty because no feel's range starts exactly at 92, and it should not come back
    /// with a drum-and-bass pattern either. So:
    ///
    /// - if an idiom is asked for and anything carries it, only those are considered — an idiom is
    ///   a decision, not a hint;
    /// - a meter, if given, is a hard filter too: a 3/4 pattern cannot play a 4/4 record;
    /// - inside that set, feels are ranked by how well the tempo lands: inside the range scores
    ///   1 and is further rewarded for sitting near the middle, outside it decays with distance
    ///   relative to the range's own width, so a narrow range is fussier than a wide one.
    ///
    /// Ties break on name, so the answer is stable enough to write a test against.
    public func suggest(for request: Request) -> [Feel] {
        var candidates = feels
        if let idiom = request.idiom {
            let tagged = candidates.filter { $0.suits(idiom: idiom) }
            if !tagged.isEmpty { candidates = tagged }
        }
        if let signature = request.timeSignature {
            let matching = candidates.filter { $0.timeSignature == signature }
            if !matching.isEmpty { candidates = matching }
        }
        let scored = candidates.map { (feel: $0, score: FeelLibrary.score($0, for: request)) }
        return scored
            .sorted { a, b in
                a.score == b.score ? a.feel.name < b.feel.name : a.score > b.score
            }
            .prefix(request.limit)
            .map(\.feel)
    }

    /// Convenience over `suggest(for:)` for the common call.
    public func suggest(for tempo: Double, idiom: Idiom? = nil,
                        timeSignature: TimeSignature? = nil, limit: Int = 5) -> [Feel] {
        suggest(for: Request(tempo: tempo, idiom: idiom, timeSignature: timeSignature, limit: limit))
    }

    /// The single best feel for a request, or nil for an empty library.
    public func best(for request: Request) -> Feel? {
        var request = request
        request.limit = max(1, request.limit)
        return suggest(for: request).first
    }

    static func score(_ feel: Feel, for request: Request) -> Double {
        var score = 0.0
        if let idiom = request.idiom {
            if feel.idioms.first == idiom { score += 2 }
            else if feel.suits(idiom: idiom) { score += 1.5 }
        }
        if let tempo = request.tempo {
            let low = feel.tempoRange.lowerBound
            let high = feel.tempoRange.upperBound
            let width = max(1, high - low)
            if feel.tempoRange.contains(tempo) {
                let centre = (low + high) / 2
                // 1 at the edges of the range, 1.5 dead centre.
                score += 1 + 0.5 * (1 - abs(tempo - centre) / (width / 2))
            } else {
                let distance = tempo < low ? low - tempo : tempo - high
                score += max(0, 1 - distance / (width / 2 + 10))
            }
        }
        if let signature = request.timeSignature, feel.timeSignature == signature { score += 0.25 }
        return score
    }

    // MARK: Validation

    /// Every issue in every feel, plus duplicate names.
    public func validate() -> [FeelIssue] {
        var issues = feels.flatMap { $0.validate() }
        var seen = Set<String>()
        for feel in feels {
            if !seen.insert(feel.name).inserted {
                issues.append(FeelIssue(feel: feel.name, kind: .duplicateName, detail: "appears more than once"))
            }
        }
        return issues
    }

    private static func fold(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

// MARK: - The shipped catalogue

extension FeelLibrary {
    /// Everything the app ships with: the `groove-theory` beat templates, the rhythmic skeletons of
    /// The Chorus's accompaniment styles, and the feels the first idiom (electronic, lo-fi,
    /// sample-based) needs that neither source had.
    public static let standard = FeelLibrary(
        Feels.grooveTheory + Feels.accompaniment + Feels.idiom
    )
}

/// The shipped feels, grouped by where they came from. Split across files by provenance so a
/// port stays visibly a port.
public enum Feels {}
