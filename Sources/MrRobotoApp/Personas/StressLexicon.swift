import Foundation
import SongGraph

/// Where the syllables and the stresses come from: CMUdict, compacted.
///
/// `Resources/Lexicon/stress.tsv` holds one line per word — the word, its stress digits (one per
/// syllable: 0 unstressed, 1 primary, 2 secondary) and its ending (the phonemes from the last
/// stressed vowel), built from the Carnegie Mellon Pronouncing Dictionary (BSD; the licence ships
/// beside it). 124,903 words in 2.7 MB, read once on first use. A word the lexicon does not hold
/// is guessed from its vowel groups and marked so.
public final class StressLexicon: @unchecked Sendable {

    public struct Entry: Hashable, Sendable {
        public var stresses: [Stress]
        /// Phonemes from the last stressed vowel: what rhymes.
        public var ending: [String]
        public var isGuessed: Bool
    }

    public static let shared = StressLexicon()

    private let lock = NSLock()
    private var table: [String: (String, String)]?

    public init() {}

    /// How many words the lexicon holds; 0 when the resource is missing.
    public var count: Int { load().count }

    private func load() -> [String: (String, String)] {
        lock.lock(); defer { lock.unlock() }
        if let table { return table }
        var built: [String: (String, String)] = [:]
        if let bundle = FontRegistration.resourceBundle,
           let url = bundle.url(forResource: "stress", withExtension: "tsv", subdirectory: "Resources/Lexicon"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            built.reserveCapacity(130_000)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else { continue }
                built[String(parts[0])] = (String(parts[1]), String(parts[2]))
            }
        }
        table = built
        return built
    }

    /// The word's syllables and stresses, from the dictionary or guessed.
    public func entry(for word: String) -> Entry {
        let key = Self.normalise(word)
        if let (stress, ending) = load()[key] {
            return Entry(stresses: stress.map { Self.stress($0) }, ending: ending.split(separator: " ").map(String.init), isGuessed: false)
        }
        // Not held: one syllable per vowel group, the first stressed, and the last vowel group as
        // a stand-in ending so rhymes by spelling still count for something.
        let groups = Self.vowelGroups(in: key)
        let count = max(1, groups.count)
        var stresses = [Stress](repeating: .unstressed, count: count)
        stresses[0] = .primary
        let ending = groups.last.map { [String($0).uppercased()] } ?? [key.uppercased()]
        return Entry(stresses: stresses, ending: ending, isGuessed: true)
    }

    static func stress(_ digit: Character) -> Stress {
        switch digit {
        case "1": return .primary
        case "2": return .secondary
        default: return .unstressed
        }
    }

    public static func normalise(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0 == "'" }
    }

    /// Runs of vowels in a word's spelling: the syllable count a guess is built on.
    static func vowelGroups(in word: String) -> [Substring] {
        var groups: [Substring] = []
        var start: String.Index?
        for index in word.indices {
            let isVowel = "aeiouy".contains(word[index])
            if isVowel, start == nil { start = index }
            if !isVowel, let s = start { groups.append(word[s..<index]); start = nil }
        }
        if let s = start { groups.append(word[s...]) }
        // A trailing silent e is not a syllable: "home" is one.
        if groups.count > 1, word.hasSuffix("e"), groups.last == "e" { groups.removeLast() }
        return groups
    }

    /// Splits a word's spelling into as many chunks as it has syllables: at vowel-group boundaries
    /// when the count matches (the consonants between two groups split down the middle, a single
    /// one going to the syllable after it — me·lo·dy, win·dow, cen·tral), evenly when it does not.
    public static func chunks(of word: String, count: Int) -> [String] {
        guard count > 1 else { return [word] }
        let lower = Array(word.lowercased())
        let letters = Array(word)
        var groups: [(start: Int, end: Int)] = []
        var start: Int?
        for (i, c) in lower.enumerated() {
            let isVowel = "aeiouy".contains(c)
            if isVowel, start == nil { start = i }
            if !isVowel, let s = start { groups.append((s, i)); start = nil }
        }
        if let s = start { groups.append((s, lower.count)) }
        if groups.count > 1, lower.last == "e", groups.last?.start == lower.count - 1 { groups.removeLast() }
        guard groups.count == count else {
            let length = letters.count
            return (0..<count).map { i in String(letters[(i * length / count)..<((i + 1) * length / count)]) }
        }
        var cuts: [Int] = []
        for (previous, next) in zip(groups, groups.dropFirst()) {
            let run = next.start - previous.end
            cuts.append(previous.end + run / 2)
        }
        var out: [String] = []
        var last = 0
        for cut in cuts {
            out.append(String(letters[last..<cut]))
            last = cut
        }
        out.append(String(letters[last...]))
        return out
    }
}
