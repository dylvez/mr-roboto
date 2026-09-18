import Foundation
import SongGraph

/// The house voice, read: lyrics the house has written, one text each, and the words they share.
public struct LyricCorpus: Hashable, Sendable {
    public var lyrics: [VoiceLyric]

    public init(_ lyrics: [VoiceLyric]) { self.lyrics = lyrics }

    public var isEmpty: Bool { lyrics.isEmpty }

    /// Words that carry an image: alphabetic, four letters or more, and not the connective tissue.
    public static let stopwords: Set<String> = [
        "that", "this", "with", "what", "when", "then", "than", "them", "they", "there", "their", "your", "have",
        "from", "into", "like", "just", "were", "been", "will", "would", "could", "should", "about", "again",
        "still", "every", "never", "always", "where", "which", "while", "these", "those", "some", "more", "over",
        "under", "only", "want", "know", "said", "says", "does", "doesn't", "don't", "didn't", "can't", "won't",
        "keep", "going", "make", "made", "take", "took", "come", "came", "back", "down", "here", "away", "thing",
        "things", "something", "nothing", "everything", "anything", "because", "through", "until", "before",
        "after", "being", "gonna", "wanna", "yeah", "okay", "really", "little", "much", "very", "each", "other",
        // Contractions with the apostrophe gone, as `images(in:)` sees them.
        "doesnt", "didnt", "dont", "cant", "wont", "isnt", "wasnt", "werent", "arent", "hasnt", "havent", "hadnt",
        "couldnt", "wouldnt", "shouldnt", "thats", "whats", "theres", "youre", "theyre", "weve", "youve", "theyve",
        "youll", "theyll", "well", "shes", "hes", "its", "lets", "aint", "gotta",
    ]

    /// The images in a text: content words, normalised, once each.
    public static func images(in text: String) -> Set<String> {
        var out = Set<String>()
        for raw in text.split(whereSeparator: { !$0.isLetter && $0 != "'" }) {
            let word = raw.lowercased().replacingOccurrences(of: "'", with: "")
            guard word.count >= 4, !stopwords.contains(word) else { continue }
            out.insert(word)
        }
        return out
    }

    /// How many of the house's songs each image appears in.
    public var imageCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for lyric in lyrics {
            for image in Self.images(in: lyric.text) { counts[image, default: 0] += 1 }
        }
        return counts
    }

    /// The images of `text` that the house has used most, with how many songs they appear in.
    public func reuse(in text: String, excluding title: String? = nil) -> [(image: String, songs: Int)] {
        let counts = LyricCorpus(lyrics.filter { $0.title != title }).imageCounts
        return Self.images(in: text).compactMap { image in
            guard let n = counts[image], n > 0 else { return nil }
            return (image, n)
        }.sorted { $0.songs > $1.songs || ($0.songs == $1.songs && $0.image < $1.image) }
    }

    // MARK: Reading a file

    /// Lyrics out of a markdown file of the house's shape — `### N. Title` headings, each followed
    /// by a fenced block with `[Section]` tags — or, failing that, one lyric per blank-line-separated
    /// block with its first line as the title.
    public static func parse(markdown text: String, source: String? = nil) -> [VoiceLyric] {
        var out: [VoiceLyric] = []
        let lines = text.components(separatedBy: "\n")
        var title: String?
        var inFence = false
        var buffer: [String] = []
        func flush() {
            if let title, !buffer.joined().trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(VoiceLyric(title: title, text: buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), source: source))
            }
            buffer = []
        }
        for line in lines {
            if line.hasPrefix("### ") {
                flush()
                title = line.dropFirst(4).replacingOccurrences(of: #"^\d+\.\s*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("```") { inFence.toggle(); if !inFence { flush() }; continue }
            guard inFence, title != nil else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { if !buffer.isEmpty, buffer.last != "" { buffer.append("") }; continue }
            buffer.append(trimmed)
        }
        flush()
        if out.isEmpty {
            // Plain text: blocks separated by blank lines, the first line of each the title.
            for block in text.components(separatedBy: "\n\n") {
                let rows = block.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard rows.count >= 2 else { continue }
                out.append(VoiceLyric(title: rows[0], text: rows.dropFirst().joined(separator: "\n"), source: source))
            }
        }
        return out
    }
}
