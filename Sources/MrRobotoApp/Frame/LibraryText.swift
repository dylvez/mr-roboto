import Foundation
import MusicTheory
import SongGraph

// How the library's facts read: a row's line in the strip on the left, a cell in the Library
// surface's list, a fact in its detail pane. One place, so the two views say the same thing.

extension LibraryFacts {
    /// The second line of a row in the strip on the left: "D major · 113 bpm · 78 bars".
    var line: String {
        switch id.shelf {
        case .songs:
            var pieces: [String] = []
            if let key { pieces.append(key.name) }
            if let tempo { pieces.append("\(Int(tempo.rounded())) bpm") }
            if let bars, bars > 0 { pieces.append("\(bars) bars") }
            return pieces.joined(separator: " · ")
        case .records:
            return recordLine(stems: true)
        case .ideas:
            return note ?? ""
        case .samples:
            var pieces: [String] = []
            if let root { pieces.append("\(root)") }
            if let tempo { pieces.append("\(Int(tempo.rounded())) bpm") }
            if let slices, slices > 0 { pieces.append("\(slices) slices") }
            if let note { pieces.append(note) }
            return pieces.isEmpty ? tags.joined(separator: " · ") : pieces.joined(separator: " · ")
        case .albums:
            return LibraryText.count(songs, "song")
        }
    }

    /// "D major · 113 bpm · 78 bars · 21¢ flat · 4 stems": a record as read. The tuning only when
    /// it is far enough off that fitting moves it; the stems only when the row does not mark them.
    func recordLine(stems showsStems: Bool) -> String {
        var pieces: [String] = []
        if let key { pieces.append(key.name) }
        if let tempo { pieces.append("\(Int(tempo.rounded())) bpm") }
        if let bars { pieces.append("\(bars) bars") }
        if isOffPitch, let tuning { pieces.append(LibraryText.cents(tuning, words: true)) }
        if showsStems, let stems { pieces.append(LibraryText.count(stems, "stem")) }
        if pieces.isEmpty, !artist.isEmpty { pieces.append(artist) }
        return pieces.joined(separator: " · ")
    }
}

extension LibraryColumn {
    /// The column's header, as the shelf calls it.
    func title(on shelf: LibraryShelf) -> String {
        switch self {
        case .title: shelf == .samples ? "Name" : "Title"
        case .artist: "Artist"
        case .key: "Key"
        case .tempo: "Tempo"
        case .bars: "Bars"
        case .length: "Length"
        case .genre: "Genre"
        case .changed: "Worked on"
        case .loudness: "LUFS"
        case .stems: "Stems"
        case .tuning: "Tuning"
        case .songs: shelf == .albums ? "Songs" : "Used in"
        case .records: "Made from"
        case .kind: "Kind"
        case .note: shelf == .samples ? "Dust" : "Note"
        case .root: "Root"
        case .slices: "Slices"
        case .source: "Cut from"
        }
    }

    /// What a cell says; empty when the item does not have it.
    func text(_ facts: LibraryFacts) -> String {
        switch self {
        case .title: facts.title
        case .artist: facts.artist
        case .key: facts.key?.name ?? ""
        case .tempo: facts.tempo.map(LibraryText.tempo) ?? ""
        case .bars: facts.bars.map { $0 > 0 ? "\($0)" : "" } ?? ""
        case .length: facts.seconds.map(LibraryText.duration) ?? ""
        case .genre: facts.genre ?? ""
        case .changed: LibraryText.day(facts.changed)
        case .loudness: facts.loudness.map { String(format: "%.1f", $0) } ?? ""
        case .stems: facts.stems.map { "\($0)" } ?? ""
        case .tuning: facts.tuning.map { LibraryText.cents($0) } ?? ""
        case .songs: facts.songs > 0 ? "\(facts.songs)" : ""
        case .records: facts.records > 0 ? "\(facts.records)" : ""
        case .kind: facts.kind.map(LibraryText.kind) ?? ""
        case .note: facts.note ?? ""
        case .root: facts.root.map { "\($0)" } ?? ""
        case .slices: facts.slices.map { $0 > 0 ? "\($0)" : "" } ?? ""
        case .source: facts.source ?? ""
        }
    }

    /// Numbers read down a column from the right.
    var isNumeric: Bool {
        switch self {
        case .tempo, .bars, .length, .loudness, .stems, .tuning, .songs, .records, .slices: true
        default: false
        }
    }
}

enum LibraryText {
    /// "song", "record": one of a shelf.
    static func noun(_ shelf: LibraryShelf) -> String {
        switch shelf {
        case .songs: "song"
        case .records: "record"
        case .ideas: "idea"
        case .samples: "sample"
        case .albums: "album"
        }
    }

    /// "1 song", "3 songs".
    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// "113", or "95.7" for a tempo read between whole numbers.
    static func tempo(_ bpm: Double) -> String {
        abs(bpm - bpm.rounded()) < 0.05 ? "\(Int(bpm.rounded()))" : String(format: "%.1f", bpm)
    }

    /// "3:04".
    static func duration(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// "+12¢", "−21¢", "0¢"; in words, "12¢ sharp", "21¢ flat".
    static func cents(_ cents: Double, words: Bool = false) -> String {
        let whole = Int(cents.rounded())
        if words { return whole == 0 ? "at pitch" : "\(abs(whole))¢ \(whole > 0 ? "sharp" : "flat")" }
        return whole == 0 ? "0¢" : "\(whole > 0 ? "+" : "−")\(abs(whole))¢"
    }

    /// "3 Oct", or "3 Oct 2025" in another year.
    static func day(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? .dateTime.day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year())
    }

    /// "Progression", "Bass line".
    static func kind(_ type: PartType) -> String {
        switch type {
        case .progression: "Progression"
        case .melody: "Melody"
        case .lyric: "Lyric"
        case .groove: "Groove"
        case .bassline: "Bass line"
        case .sample: "Chop"
        case .audio: "Audio"
        case .sound: "Sound"
        case .analysis: "Analysis"
        case .mix: "Mix"
        }
    }
}
