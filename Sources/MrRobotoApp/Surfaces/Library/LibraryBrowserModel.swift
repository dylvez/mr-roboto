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

    /// The searches saved by name, words and all, in the order they were saved.
    var saved: [SavedSearch] {
        read("saved").flatMap { try? JSONDecoder().decode([SavedSearch].self, from: $0) } ?? []
    }

    func remember(saved: [SavedSearch]) {
        if let data = try? JSONEncoder().encode(saved) { write("saved", data) }
    }
}

/// A search kept by name: a shelf, its words, its filters and its order, one press away.
struct SavedSearch: Codable, Hashable, Sendable, Identifiable {
    var name: String
    var query: LibraryQuery
    var id: String { name }
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
    /// Exporting several songs' masters.
    let work: LibraryBatchWork
    /// The searches saved by name.
    private(set) var saved: [SavedSearch]
    @ObservationIgnored private let listening: LibraryListeningHost

    private(set) var shelf: LibraryShelf
    private var queries: [LibraryShelf: LibraryQuery] = [:]
    /// The item chosen on each shelf, kept while you look at another: the one the detail shows,
    /// and where a ⇧-click runs from.
    private var selections: [LibraryShelf: LibraryItemID] = [:]
    /// Everything chosen on each shelf, the item above among them: more than one is a batch.
    private var chosen: [LibraryShelf: Set<LibraryItemID>] = [:]

    init(app: AppState, memory: LibraryBrowserMemory, listening: LibraryListeningHost? = nil) {
        self.app = app
        self.memory = memory
        let listening = listening ?? LiveLibraryListening(app: app)
        self.listening = listening
        let preview = LibraryPreview(app: app, host: listening)
        self.preview = preview
        work = LibraryBatchWork(app: app)
        saved = memory.saved
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
    enum Filter: String, CaseIterable, Sendable { case goesWith, favourites, tag, key, tempo, genre, stems, usage, offPitch }

    var filters: [Filter] {
        // What goes with the open song, first, while there is one; then what you marked.
        let fitting: [Filter] = index.fitTarget != nil ? [.goesWith] : []
        let marked: [Filter] = [.favourites] + (index.tags(on: shelf).isEmpty && query.tag == nil ? [] : [.tag])
        switch shelf {
        case .songs: return marked + [.key, .tempo, .genre, .usage]
        case .records: return fitting + marked + [.key, .tempo, .stems, .usage, .offPitch]
        case .ideas: return fitting + marked + [.key, .usage]
        case .samples: return fitting + marked + [.key, .tempo, .usage]
        case .albums, .instruments, .kits: return marked
        }
    }

    func toggleFavourites() { query.favourites = query.favourites == true ? nil : true }

    func setTag(_ tag: String?) { query.tag = tag }

    /// The tags on the shelf showing, to filter by.
    var tagsOnShelf: [String] { index.tags(on: shelf) }

    /// Only what goes with the open song, nearest first unless another order was chosen.
    func toggleGoesWith() {
        if query.goesWith == true {
            query.goesWith = nil
            if query.sort?.column == .fit { query.sort = nil }
        } else {
            query.goesWith = true
            if query.sort == nil { query.sort = .init(.fit) }
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

    /// Chooses an item on its own shelf, turning to it, and only it.
    func select(_ id: LibraryItemID?) {
        guard let id else {
            selections[shelf] = nil
            chosen[shelf] = nil
            return
        }
        choose(id.shelf)
        selections[id.shelf] = id
        chosen[id.shelf] = [id]
    }

    // MARK: Choosing several

    /// What is chosen on the shelf showing, in the order the rows are, while the library holds it.
    var chosenRows: [LibraryFacts] {
        let set = chosen[shelf] ?? selection.map { [$0] } ?? []
        return rows.filter { set.contains($0.id) }
    }

    /// More than one chosen: what the detail shows is what can be done to them all.
    var isBatch: Bool { chosenRows.count > 1 }

    func isChosen(_ id: LibraryItemID) -> Bool { (chosen[id.shelf] ?? selections[id.shelf].map { [$0] } ?? []).contains(id) }

    /// ⌘-click: in or out of what is chosen.
    func toggleChoice(_ id: LibraryItemID) {
        guard id.shelf == shelf else { return select(id) }
        var set = chosen[shelf] ?? selection.map { [$0] } ?? []
        if set.contains(id) {
            set.remove(id)
            if selections[shelf] == id { selections[shelf] = rows.first { set.contains($0.id) }?.id }
        } else {
            set.insert(id)
            selections[shelf] = id
        }
        chosen[shelf] = set
    }

    /// ⇧-click: every row from the one chosen last to this one.
    func extendChoice(to id: LibraryItemID) {
        let rows = rows
        guard id.shelf == shelf, let anchor = selection, let from = rows.firstIndex(where: { $0.id == anchor }),
              let to = rows.firstIndex(where: { $0.id == id }) else { return select(id) }
        chosen[shelf] = Set(rows[min(from, to)...max(from, to)].map(\.id))
    }

    /// ⌘A: every row the shelf shows.
    func chooseAll() {
        let rows = rows
        guard !rows.isEmpty else { return }
        if selection.map({ id in rows.contains { $0.id == id } }) != true { selections[shelf] = rows.first?.id }
        chosen[shelf] = Set(rows.map(\.id))
    }

    /// What can be done to everything chosen.
    var batchActions: [LibraryAction] { LibraryActions.batch(chosenRows.map(\.id), in: app, work: work) }

    // MARK: Saved searches

    /// Keeps the search showing under a name; a name already kept is replaced.
    func saveSearch(named name: String) {
        let name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty else { return }
        saved.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        saved.append(SavedSearch(name: name, query: query))
        memory.remember(saved: saved)
    }

    /// Turns to a saved search's shelf with its words, filters and order.
    func apply(_ search: SavedSearch) {
        choose(search.query.shelf)
        query = search.query
    }

    func forget(_ search: SavedSearch) {
        saved.removeAll { $0.name == search.name }
        memory.remember(saved: saved)
    }

    /// The saved search the shelf is showing now, word for word.
    var appliedSearch: SavedSearch? { saved.first { $0.query == query } }

    /// "Save This Search…": asks for a name.
    var saveSearchAction: LibraryAction {
        LibraryAction(id: "save-search", title: "Save This Search…", help: "Keep these words, filters and order under a name, beside the shelves",
                      isEnabled: query.narrows,
                      kind: .text(title: "Save This Search", current: "", message: "A name for it. It is kept beside the shelves, one press away.",
                                  verb: "Save", run: { [weak self] in self?.saveSearch(named: $0) }))
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

    /// An item or a search asked for from elsewhere (`AppState.showInLibrary`), taken once.
    func takeAsk() {
        if let query = app.libraryQueryAsk {
            app.libraryQueryAsk = nil
            choose(query.shelf)
            self.query = query
        }
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
