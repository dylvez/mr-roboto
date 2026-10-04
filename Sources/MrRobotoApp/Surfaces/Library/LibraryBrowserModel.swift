import Foundation
import MusicTheory
import Observation
import SongGraph

/// What the Library surface remembers between launches: the shelf it was on, and on each shelf
/// the order and the filters chosen. Not the words typed: a search is for now.
struct LibraryBrowserMemory {
    static let prefix = "library.browser."
    private let read: (String) -> Data?
    private let write: (String, Data) -> Void

    /// Kept in the app's defaults.
    init(defaults: UserDefaults) {
        self.init(read: { defaults.data(forKey: Self.prefix + $0) }, write: { defaults.set($1, forKey: Self.prefix + $0) })
    }

    /// Kept wherever the caller says. A test keeps it in memory: defaults made for one test leave
    /// a file in Preferences every run.
    init(read: @escaping (String) -> Data?, write: @escaping (String, Data) -> Void) {
        self.read = read
        self.write = write
    }

    /// Kept in memory, for as long as this value is.
    static func inMemory() -> LibraryBrowserMemory {
        final class Box { var values: [String: Data] = [:] }
        let box = Box()
        return LibraryBrowserMemory(read: { box.values[$0] }, write: { box.values[$0] = $1 })
    }

    var shelf: LibraryShelf? { read("shelf").flatMap { String(data: $0, encoding: .utf8) }.flatMap(LibraryShelf.init(rawValue:)) }

    func remember(shelf: LibraryShelf) { write("shelf", Data(shelf.rawValue.utf8)) }

    func query(on shelf: LibraryShelf) -> LibraryQuery? {
        read(shelf.rawValue).flatMap { try? JSONDecoder().decode(LibraryQuery.self, from: $0) }.flatMap { $0.shelf == shelf ? $0 : nil }
    }

    func remember(_ query: LibraryQuery) {
        if let data = try? JSONEncoder().encode(Self.kept(query)) { write(query.shelf.rawValue, data) }
    }

    /// What is kept of a query: everything but the words.
    static func kept(_ query: LibraryQuery) -> LibraryQuery {
        var kept = query
        kept.text = ""
        return kept
    }
}

/// The Library surface: one shelf at a time, searched, filtered and sorted from the library's
/// index; one item on each shelf chosen and described; links from one item to another.
@MainActor
@Observable
final class LibraryBrowserModel {
    let app: AppState
    @ObservationIgnored private let memory: LibraryBrowserMemory
    /// Hearing what is on the shelves.
    let preview: LibraryPreview
    @ObservationIgnored private let listening: LibraryListeningHost

    private(set) var shelf: LibraryShelf
    private var queries: [LibraryShelf: LibraryQuery] = [:]
    /// The item chosen on each shelf, kept while you look at another.
    private var selections: [LibraryShelf: LibraryItemID] = [:]

    init(app: AppState, memory: LibraryBrowserMemory, listening: LibraryListeningHost? = nil) {
        self.app = app
        self.memory = memory
        let listening = listening ?? LiveLibraryListening(app: app)
        self.listening = listening
        let preview = LibraryPreview(app: app, host: listening)
        self.preview = preview
        // The song's transport starting is the end of anything heard from here.
        app.beforeTransportStarts = { [weak preview] in await preview?.yieldToTransport() }
        shelf = memory.shelf ?? .songs
        for shelf in LibraryShelf.allCases { queries[shelf] = memory.query(on: shelf) ?? LibraryQuery(shelf: shelf) }
        // The open song, chosen on its shelf, so the surface opens on something you know.
        if let song = app.song, app.libraryIndex.facts(.song(song.id)) != nil { selections[.songs] = .song(song.id) }
        takeAsk()
    }

    var index: LibraryIndex { app.libraryIndex }

    // MARK: The shelf and its query

    /// The query on the shelf showing. Its words are for now; everything else is remembered.
    var query: LibraryQuery {
        get { queries[shelf] ?? LibraryQuery(shelf: shelf) }
        set {
            let before = queries[shelf]
            queries[shelf] = newValue
            if before.map(LibraryBrowserMemory.kept) != LibraryBrowserMemory.kept(newValue) { memory.remember(newValue) }
        }
    }

    /// What the shelf shows, in order.
    var rows: [LibraryFacts] { query.run(index) }

    func count(on shelf: LibraryShelf) -> Int { index.items(on: shelf).count }

    func choose(_ shelf: LibraryShelf) {
        guard shelf != self.shelf else { return }
        self.shelf = shelf
        memory.remember(shelf: shelf)
    }

    var text: String {
        get { query.text }
        set { query.text = newValue }
    }

    /// Up the column, down it, then back to the library's own order.
    func sort(by column: LibraryColumn) {
        switch query.sort {
        case .some(let sort) where sort.column == column && sort.ascending:
            query.sort = .init(column, ascending: false)
        case .some(let sort) where sort.column == column:
            query.sort = nil
        default:
            // Dates and counts are wanted newest and most first.
            query.sort = .init(column, ascending: ![.changed, .songs, .records, .stems, .loudness].contains(column))
        }
    }

    /// The words and every filter gone; the order stays.
    func clearFilters() {
        query = LibraryQuery(shelf: shelf, sort: query.sort)
    }

    // MARK: Filters

    /// The filters a shelf offers, in the order its chips sit.
    enum Filter: String, CaseIterable, Sendable { case key, tempo, genre, stems, usage, offPitch }

    var filters: [Filter] {
        switch shelf {
        case .songs: [.key, .tempo, .genre, .usage]
        case .records: [.key, .tempo, .stems, .usage, .offPitch]
        case .ideas: [.key, .usage]
        case .samples: [.key, .tempo, .usage]
        case .albums: []
        }
    }

    /// The keys the shelf holds, up the keyboard from C.
    var keysOnShelf: [Key] {
        let keys = LibraryIndex.unique(index.items(on: shelf).compactMap(\.key))
        return keys.sorted { LibraryQuery.keyRank($0) < LibraryQuery.keyRank($1) }
    }

    /// The genres the songs are in, by profile id and name.
    var genresOnShelf: [(id: String, name: String)] {
        var seen = Set<String>()
        return index.items(on: .songs).compactMap { facts -> (id: String, name: String)? in
            guard let id = facts.genreID, let name = facts.genre, seen.insert(id).inserted else { return nil }
            return (id, name)
        }.sorted { $0.name < $1.name }
    }

    func setKey(_ filter: LibraryQuery.KeyFilter?) { query.key = filter }

    /// The key filter kept, moved to admit keys within `semitones`.
    func setWithin(_ semitones: Int) {
        guard var key = query.key else { return }
        key.within = max(0, semitones)
        query.key = key
    }

    func setTempo(_ filter: LibraryQuery.TempoFilter?) { query.tempo = filter }

    func setHalfAndDouble(_ on: Bool) {
        guard var tempo = query.tempo else { return }
        tempo.halfAndDouble = on
        query.tempo = tempo
    }

    func setGenre(_ id: String?) { query.genre = id }

    /// Any, with, without.
    func cycleStems() {
        query.hasStems = switch query.hasStems { case nil: true; case true?: false; case false?: nil }
    }

    /// Any, used, unused.
    func cycleUsage() {
        query.usage = switch query.usage { case nil: .used; case .used?: .unused; case .unused?: nil }
    }

    func toggleOffPitch() { query.offPitch = query.offPitch == true ? nil : true }

    /// The open song's key and tempo, to filter by when there is a song.
    var songKey: Key? { app.song?.key }
    var songTempo: Double? { app.song?.tempo }

    // MARK: Choosing

    /// The item chosen on the shelf showing, while the library still holds it.
    var selection: LibraryItemID? {
        selections[shelf].flatMap { index.facts($0) != nil ? $0 : nil }
    }

    var selected: LibraryFacts? { selection.flatMap(index.facts) }

    /// Chooses an item on its own shelf, turning to it.
    func select(_ id: LibraryItemID?) {
        guard let id else {
            selections[shelf] = nil
            return
        }
        choose(id.shelf)
        selections[id.shelf] = id
    }

    /// Chooses an item and makes sure it is in view: a link to something the words or the filters
    /// hide clears them, keeping the order.
    func show(_ id: LibraryItemID) {
        guard index.facts(id) != nil else { return }
        select(id)
        if !rows.contains(where: { $0.id == id }) { clearFilters() }
    }

    /// The next or the previous row, from the one chosen; the first when none is.
    func moveSelection(by step: Int) {
        let rows = rows
        guard !rows.isEmpty else { return }
        guard let current = selection, let at = rows.firstIndex(where: { $0.id == current }) else {
            select(step < 0 ? rows.last?.id : rows.first?.id)
            return
        }
        select(rows[min(max(0, at + step), rows.count - 1)].id)
    }

    /// An item asked for from elsewhere (`AppState.showInLibrary`), taken once.
    func takeAsk() {
        guard let asked = app.libraryAsk else { return }
        app.libraryAsk = nil
        show(asked)
    }

    // MARK: Acting

    func actions(for id: LibraryItemID) -> [LibraryAction] { LibraryActions.actions(for: id, in: app) }

    var shelfActions: [LibraryAction] { LibraryActions.shelf(shelf, in: app) }

    func primary(for id: LibraryItemID) -> LibraryAction? { LibraryActions.primary(for: id, in: app) }

    // MARK: What is said about the chosen item

    /// A song as it stands: the open one as it is in the frame, any other as the library holds it.
    func song(_ id: SongID) -> Song? { app.song?.id == id ? app.song : app.library.song(id) }

    func songTitle(_ id: SongID) -> String { index.facts(.song(id))?.title ?? song(id)?.title ?? "A song" }

    /// The records a song takes from, each with what it takes.
    func madeFrom(_ id: SongID) -> [(record: Record, uses: [RecordUse])] {
        index.records(in: id).compactMap { recordID in
            app.library.record(recordID).map { ($0, index.uses(of: recordID).filter { $0.song == id }) }
        }
    }

    /// The songs that take from a record, each with what it takes.
    func usedIn(_ id: RecordID) -> [(song: SongID, uses: [RecordUse])] {
        let uses = index.uses(of: id)
        return index.songs(using: id).map { song in (song, uses.filter { $0.song == song }) }
    }
}
