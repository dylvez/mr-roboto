import Foundation
import MusicTheory
import Performance
import SongGraph

/// A column of the library browser, and what a shelf can be sorted by.
public enum LibraryColumn: String, CaseIterable, Codable, Sendable {
    case title, artist, key, tempo, bars, length, genre, changed, loudness, stems, tuning
    /// A record's, idea's or sample's songs; an album's tracks.
    case songs
    /// The records a song is made from.
    case records
    case kind, note, root, slices, source
    /// How it goes with the open song.
    case fit

    /// The columns a shelf shows, in order.
    public static func columns(for shelf: LibraryShelf) -> [LibraryColumn] {
        switch shelf {
        case .songs: [.title, .key, .tempo, .length, .genre, .records, .changed, .loudness]
        case .records: [.title, .artist, .key, .tempo, .bars, .tuning, .stems, .songs]
        case .ideas: [.title, .kind, .key, .note]
        case .samples: [.title, .root, .tempo, .slices, .note, .source]
        case .albums: [.title, .songs, .length]
        }
    }

    /// The shelf's columns, with how each item fits the open song beside its title when there is one.
    public static func columns(for shelf: LibraryShelf, fitting: Bool) -> [LibraryColumn] {
        var columns = columns(for: shelf)
        if fitting, [.records, .ideas, .samples].contains(shelf) { columns.insert(.fit, at: 1) }
        return columns
    }
}

/// What the browser is showing: one shelf, the words typed, the filters chosen and the order.
/// Pure and synchronous: it reads an index and touches nothing.
public struct LibraryQuery: Hashable, Codable, Sendable {

    /// Keys a move of at most `within` semitones from `key`, as a merge counts the move: a key and
    /// its relative are one key (A minor under C major moves nothing), and the move keeps the
    /// item's own mode (A minor into D major is two up, to B minor).
    public struct KeyFilter: Hashable, Codable, Sendable {
        public var key: Key
        public var within: Int

        public init(_ key: Key, within: Int = 0) {
            self.key = key
            self.within = max(0, within)
        }

        /// The semitones `other` moves to sit in the key; nil for something with no key.
        public func semitones(from other: Key?) -> Int? { other.map { Merge.semitones(from: $0, to: key) } }

        public func admits(_ other: Key?) -> Bool { semitones(from: other).map { abs($0) <= within } ?? false }
    }

    /// Tempos between `low` and `high`, and — unless told not to — tempos that are there at half
    /// or double time, the way a merge doubles or halves before it stretches: 170 sits under 85.
    public struct TempoFilter: Hashable, Codable, Sendable {
        public enum Reading: String, Codable, Sendable { case asIs, doubled, halved }

        public var low: Double
        public var high: Double
        public var halfAndDouble: Bool

        public init(_ low: Double, _ high: Double, halfAndDouble: Bool = true) {
            self.low = min(low, high)
            self.high = max(low, high)
            self.halfAndDouble = halfAndDouble
        }

        /// Within `percent` of a tempo either way: `around(90, percent: 5)` is 85.5 to 94.5.
        public static func around(_ bpm: Double, percent: Double = 6, halfAndDouble: Bool = true) -> TempoFilter {
            TempoFilter(bpm * (1 - percent / 100), bpm * (1 + percent / 100), halfAndDouble: halfAndDouble)
        }

        /// How a tempo is in range: as it is, doubled, or halved; nil when it is not, or there is none.
        public func reading(of tempo: Double?) -> Reading? {
            guard let tempo, tempo > 0 else { return nil }
            if (low...high).contains(tempo) { return .asIs }
            guard halfAndDouble else { return nil }
            if (low...high).contains(tempo * 2) { return .doubled }
            if (low...high).contains(tempo / 2) { return .halved }
            return nil
        }
    }

    /// Whether anything takes it: a song for a record, an idea or a sample; an album for a song;
    /// a track for an album.
    public enum Usage: String, Codable, Sendable { case used, unused }

    public struct Sort: Hashable, Codable, Sendable {
        public var column: LibraryColumn
        public var ascending: Bool

        public init(_ column: LibraryColumn, ascending: Bool = true) {
            self.column = column
            self.ascending = ascending
        }
    }

    public var shelf: LibraryShelf
    /// Words, each of which must be found somewhere in what the item says about itself.
    public var text: String
    public var key: KeyFilter?
    public var tempo: TempoFilter?
    public var hasStems: Bool?
    public var usage: Usage?
    /// A genre profile's id or name.
    public var genre: String?
    public var offPitch: Bool?
    /// Only what goes with the open song: moved no further than a sample bears (`LibraryFit`).
    /// Holds nothing back while no song is open.
    public var goesWith: Bool?
    /// Only favourites.
    public var favourites: Bool?
    /// Only what carries this tag, however it is cased.
    public var tag: String?
    /// Nil keeps the library's own order.
    public var sort: Sort?

    public init(shelf: LibraryShelf, text: String = "", key: KeyFilter? = nil, tempo: TempoFilter? = nil,
                hasStems: Bool? = nil, usage: Usage? = nil, genre: String? = nil, offPitch: Bool? = nil,
                goesWith: Bool? = nil, favourites: Bool? = nil, tag: String? = nil, sort: Sort? = nil) {
        self.shelf = shelf
        self.text = text
        self.key = key
        self.tempo = tempo
        self.hasStems = hasStems
        self.usage = usage
        self.genre = genre
        self.offPitch = offPitch
        self.goesWith = goesWith
        self.favourites = favourites
        self.tag = tag
        self.sort = sort
    }

    /// True when anything narrows the shelf: words, or a filter.
    public var narrows: Bool {
        !words.isEmpty || key != nil || tempo != nil || hasStems != nil || usage != nil || genre != nil || offPitch != nil
            || goesWith != nil || favourites != nil || tag != nil
    }

    /// The words typed, folded the way the index folds what it searches.
    public var words: [String] {
        LibraryIndex.fold(text).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // MARK: Running it

    /// The shelf's items that pass, in the order asked for. A sort is stable: items that tie keep
    /// the library's order, and an item without the fact sorts last whichever way the column runs.
    public func run(_ index: LibraryIndex) -> [LibraryFacts] {
        let fitting = index.fitTarget != nil
        let passing = index.items(on: shelf).filter { admits($0, fitting: fitting) }
        guard let sort else { return passing }
        return passing.enumerated().sorted { a, b in
            switch Self.order(a.element, b.element, by: sort.column) {
            case .some(let ascending): return ascending == sort.ascending
            case .none:
                // Equal, or neither has it: the library's order. One has it: that one first.
                let (aHas, bHas) = (Self.has(a.element, sort.column), Self.has(b.element, sort.column))
                return aHas != bHas ? aHas : a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Whether an item passes the words and every filter. `fitting`: whether a song is open for
    /// "goes with" to mean anything.
    public func admits(_ facts: LibraryFacts, fitting: Bool = true) -> Bool {
        guard facts.id.shelf == shelf else { return false }
        for word in words where !facts.searchText.contains(word) { return false }
        if let key, !key.admits(facts.key) { return false }
        if let tempo, tempo.reading(of: facts.tempo) == nil { return false }
        if let hasStems, ((facts.stems ?? 0) > 0) != hasStems { return false }
        if let usage, Self.isUsed(facts) != (usage == .used) { return false }
        if let genre {
            let folded = GenreBook.fold(genre)
            guard facts.genreID.map({ GenreBook.fold($0) == folded }) == true
                    || facts.genre.map({ GenreBook.fold($0) == folded }) == true else { return false }
        }
        if let offPitch, facts.isOffPitch != offPitch { return false }
        if goesWith == true, fitting {
            guard let fit = facts.fit, fit.verdict <= .moves else { return false }
        }
        if favourites == true, !facts.favourite { return false }
        if let tag, !facts.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { return false }
        return true
    }

    static func isUsed(_ facts: LibraryFacts) -> Bool {
        switch facts.id.shelf {
        case .songs: facts.albums > 0
        case .records, .ideas, .samples, .albums: facts.songs > 0
        }
    }

    // MARK: Ordering

    /// True when `a` comes before `b` going up the column; nil when they tie or either lacks it.
    static func order(_ a: LibraryFacts, _ b: LibraryFacts, by column: LibraryColumn) -> Bool? {
        func text(_ x: String?, _ y: String?) -> Bool? {
            guard let x, let y, !x.isEmpty, !y.isEmpty else { return nil }
            let result = x.localizedStandardCompare(y)
            return result == .orderedSame ? nil : result == .orderedAscending
        }
        func number<T: Comparable>(_ x: T?, _ y: T?) -> Bool? {
            guard let x, let y, x != y else { return nil }
            return x < y
        }
        switch column {
        case .title: return text(a.title, b.title)
        case .artist: return text(a.artist, b.artist)
        case .genre: return text(a.genre, b.genre)
        case .note: return text(a.note, b.note)
        case .source: return text(a.source, b.source)
        case .kind: return text(a.kind?.rawValue, b.kind?.rawValue)
        case .key: return number(a.key.map(keyRank), b.key.map(keyRank))
        case .tempo: return number(a.tempo, b.tempo)
        case .bars: return number(a.bars, b.bars)
        case .length: return number(a.seconds, b.seconds)
        case .changed: return number(a.changed, b.changed)
        case .loudness: return number(a.loudness, b.loudness)
        case .stems: return number(a.stems, b.stems)
        // How far off pitch, either way.
        case .tuning: return number(a.tuning.map(abs), b.tuning.map(abs))
        case .songs: return number(a.songs, b.songs)
        case .records: return number(a.records, b.records)
        case .root: return number(a.root?.midi, b.root?.midi)
        case .slices: return number(a.slices, b.slices)
        case .fit: return number(a.fit.flatMap { $0.verdict == .unknown ? nil : $0.cost }, b.fit.flatMap { $0.verdict == .unknown ? nil : $0.cost })
        }
    }

    static func has(_ facts: LibraryFacts, _ column: LibraryColumn) -> Bool {
        switch column {
        case .title: !facts.title.isEmpty
        case .artist: !facts.artist.isEmpty
        case .genre: facts.genre != nil
        case .note: facts.note?.isEmpty == false
        case .source: facts.source != nil
        case .kind: facts.kind != nil
        case .key: facts.key != nil
        case .tempo: facts.tempo != nil
        case .bars: facts.bars != nil
        case .length: facts.seconds != nil
        case .changed, .songs, .records: true
        case .loudness: facts.loudness != nil
        case .stems: facts.stems != nil
        case .tuning: facts.tuning != nil
        case .root: facts.root != nil
        case .slices: facts.slices != nil
        case .fit: facts.fit.map { $0.verdict != .unknown } ?? false
        }
    }

    /// Keys up the keyboard from C, a major key before the minor on the same tonic, then the modes.
    static func keyRank(_ key: Key) -> Int {
        let mode = key.mode == .ionian ? 0 : key.mode == .aeolian ? 1 : 2 + key.mode.rawValue
        return key.tonic.pitchClass.rawValue * 100 + mode
    }
}
