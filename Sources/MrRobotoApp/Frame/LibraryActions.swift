import AppKit
import SongGraph
import SwiftUI

/// Something that can be done to an item in the library. The strip on the left offers these as a
/// row's menu and the Library surface as buttons under the item's name, from one list
/// (`LibraryActions`), so the two cannot drift apart. Every one is a call the app already makes,
/// asking first in the words it already used wherever it cannot be undone.
struct LibraryAction: Identifiable {
    enum Kind {
        /// Done at once.
        case run(@MainActor () -> Void)
        /// Asked first: the question, what goes with it, and the button that does it.
        case confirm(question: String, detail: String, verb: String, run: @MainActor () -> Void)
        /// A new name, asked for: the name it starts from, and what renaming does.
        case rename(current: String, message: String, run: @MainActor (String) -> Void)
        /// A choice among several.
        case menu([LibraryAction])
    }

    let id: String
    let title: String
    var help = ""
    var isEnabled = true
    var isDestructive = false
    /// Actions in one group sit together; a menu draws a divider between groups.
    var group = 0
    let kind: Kind

    /// The title as a button says it, without the ellipsis a menu item carries.
    var buttonTitle: String { title.hasSuffix("…") ? String(title.dropLast()) : title }
}

@MainActor
enum LibraryActions {

    /// Everything that can be done to one item, grouped, in the order a menu lists it.
    static func actions(for item: LibraryItemID, in app: AppState) -> [LibraryAction] {
        switch item.shelf {
        case .songs: return song(SongID(rawValue: item.id), app)
        case .records: return record(RecordID(rawValue: item.id), app)
        case .ideas: return idea(VersionID(rawValue: item.id), app)
        case .samples: return sample(SampleID(rawValue: item.id), app)
        case .albums: return album(AlbumID(rawValue: item.id), app)
        }
    }

    /// What a double-click does: open a song or an album, bring a record into the open song (or
    /// start one from it), adopt an idea or a sample.
    static func primary(for item: LibraryItemID, in app: AppState) -> LibraryAction? {
        let all = actions(for: item, in: app).flatMap { action -> [LibraryAction] in
            if case .menu = action.kind { return [] }
            return [action]
        }
        let preferred: [String]
        switch item.shelf {
        case .songs, .albums: preferred = ["open"]
        case .records: preferred = ["add", "start"]
        case .ideas, .samples: preferred = ["adopt"]
        }
        return preferred.lazy.compactMap { id in all.first { $0.id == id && $0.isEnabled } }.first
    }

    /// What the shelf itself offers, whatever is chosen on it.
    static func shelf(_ shelf: LibraryShelf, in app: AppState) -> [LibraryAction] {
        let writable = app.store != nil
        switch shelf {
        case .songs:
            return [LibraryAction(id: "new-song", title: "New Song", help: "File ▸ New Song (⌘N): a title, a tempo and a key first.",
                                  kind: .run { app.open(Song.new(title: MrRobotoApp.untitledName())); app.wantsSongSettings = true })]
        case .records:
            return [LibraryAction(id: "import", title: "Import Records…",
                                  help: "File ▸ Import Records… (⌘I): records into the crate, read and separated in the background.",
                                  isEnabled: writable, kind: .run { MrRobotoApp.importRecords(app) })]
        case .albums:
            return [LibraryAction(id: "new-album", title: "New Album", help: "An empty album, opened to add songs to.",
                                  isEnabled: writable, kind: .run { if let id = app.createAlbum(title: "New album") { app.openAlbum(id) } })]
        case .ideas, .samples:
            return []
        }
    }

    // MARK: Songs

    private static func song(_ id: SongID, _ app: AppState) -> [LibraryAction] {
        guard let song = app.library.song(id) else { return [] }
        let albums = app.library.albums.filter { !$0.songs.contains(id) }
        return [
            LibraryAction(id: "open", title: "Open", help: "Open \(song.title) on the bench.", kind: .run { app.openSong(id) }),
            LibraryAction(id: "rename", title: "Rename…", group: 1,
                          kind: .rename(current: (app.song?.id == id ? app.song?.title : nil) ?? song.title,
                                        message: "A new name for the song. Its package on disk keeps its file name.",
                                        run: { _ = app.renameSong(id, to: $0) })),
            LibraryAction(id: "duplicate", title: "Duplicate", help: "A copy of the song, with its own package.", group: 1,
                          kind: .run { _ = app.duplicateSong(id) }),
            LibraryAction(id: "album", title: "Add to Album",
                          help: albums.isEmpty ? (app.library.albums.isEmpty ? "No albums yet: make one on the Albums shelf." : "It is on every album already.")
                              : "Put it at the end of an album's songs.",
                          isEnabled: !albums.isEmpty, group: 1,
                          kind: .menu(albums.map { album in
                              LibraryAction(id: "album-\(album.id.rawValue)", title: album.title, kind: .run { _ = app.addSong(id, to: album.id) })
                          })),
            LibraryAction(id: "finder", title: "Show in Finder", group: 1, kind: .run { app.revealInFinder(song: id) }),
            LibraryAction(id: "trash", title: "Move to Trash…", isDestructive: true, group: 2,
                          kind: .confirm(question: "Move “\(song.title)” to the Trash?",
                                         detail: "The song's package goes to the Trash, where Finder can put it back. It leaves every album it is on.",
                                         verb: "Move to Trash", run: { _ = app.deleteSong(id) })),
        ]
    }

    // MARK: Albums

    private static func album(_ id: AlbumID, _ app: AppState) -> [LibraryAction] {
        guard let album = app.library.album(id) else { return [] }
        return [
            LibraryAction(id: "open", title: "Open", help: "The album's songs in order, its targets and its clearances.",
                          kind: .run { app.openAlbum(id) }),
            LibraryAction(id: "rename", title: "Rename…", group: 1,
                          kind: .rename(current: album.title, message: "A new name for the album.",
                                        run: { _ = app.renameAlbum(id, to: $0.trimmingCharacters(in: .whitespacesAndNewlines)) })),
            LibraryAction(id: "delete", title: "Delete Album…", isDestructive: true, group: 2,
                          kind: .confirm(question: "Delete the album “\(album.title)”?",
                                         detail: "Its songs stay in the library; only the order, the targets and the clearances go.",
                                         verb: "Delete Album", run: { _ = app.deleteAlbum(id) })),
        ]
    }

    // MARK: Ideas and samples

    private static func idea(_ id: VersionID, _ app: AppState) -> [LibraryAction] {
        guard let idea = app.library.ideas.first(where: { $0.id == id }) else { return [] }
        let title = PartLabel.title(of: idea)
        return [
            adopt(LibraryDragPayload(kind: .idea, id: id.rawValue, title: title), app),
            LibraryAction(id: "remove", title: "Remove from Library…", isDestructive: true, group: 2,
                          kind: .confirm(question: "Remove the idea “\(title)” from the library?",
                                         detail: "Songs that adopted it copied its audio and keep playing.",
                                         verb: "Remove", run: { _ = app.removeIdea(id) })),
        ]
    }

    private static func sample(_ id: SampleID, _ app: AppState) -> [LibraryAction] {
        guard let entry = app.library.sample(id) else { return [] }
        return [
            adopt(LibraryDragPayload(kind: .sample, id: id.rawValue, title: entry.name), app),
            LibraryAction(id: "remove", title: "Remove from Library…", isDestructive: true, group: 2,
                          kind: .confirm(question: "Remove “\(entry.name)” from Samples?",
                                         detail: "Songs that adopted it copied its audio and keep playing.",
                                         verb: "Remove", run: { _ = app.removeSample(id) })),
        ]
    }

    private static func adopt(_ payload: LibraryDragPayload, _ app: AppState) -> LibraryAction {
        LibraryAction(id: "adopt", title: "Adopt into This Song",
                      help: app.song.map { "A part of \($0.title), in every section, opened where it is worked on." } ?? "Open a song to adopt it into.",
                      isEnabled: app.song != nil, kind: .run { _ = app.receive(payload, at: .bench) })
    }

    // MARK: Records

    private static func record(_ id: RecordID, _ app: AppState) -> [LibraryAction] {
        guard let record = app.library.record(id) else { return [] }
        let read = record.reading != nil
        var actions = [
            LibraryAction(id: "start", title: "Start a Song from It",
                          help: read ? "A new song of its own, made from its reading, its take and its stems." : "Read it first.",
                          isEnabled: read, kind: .run { _ = app.flipAgain(id) }),
            LibraryAction(id: "add", title: "Add to This Song…",
                          help: app.song == nil ? "Open a song to bring it into." : read ? "Sources, open on it: a stem or some bars, fitted to the song." : "Read it first.",
                          isEnabled: app.song != nil && read,
                          kind: .run { app.askForSource(AskedSource(origin: .record(id))) }),
            LibraryAction(id: "adopt", title: "Adopt the Record into This Song",
                          help: "Its take and its reading into the open song, to chop a bar from.",
                          isEnabled: app.song != nil,
                          kind: .run { _ = app.receive(LibraryDragPayload(kind: .record, id: id.rawValue, title: record.title), at: .bench) }),
        ]
        if record.stems == nil {
            if let holder = app.songsHoldingStems(of: id).first {
                actions.append(LibraryAction(id: "gather", title: "Keep \(holder.title)'s Stems with It",
                                             help: "\(holder.title) separated it already; its stems are kept with the record for every song.",
                                             isEnabled: !app.crate.isQueued(.gather, for: id), group: 1,
                                             kind: .run { app.gatherStems(of: id, from: holder.id) }))
            }
            actions.append(LibraryAction(id: "separate", title: "Separate Its Stems",
                                         help: "Vocals, drums, bass and other, kept with the record.",
                                         isEnabled: !app.crate.isQueued(.separate, for: id), group: 1,
                                         kind: .run { app.separateRecord(id) }))
        } else {
            actions.append(LibraryAction(id: "separate", title: "Separate Its Stems Again",
                                         isEnabled: !app.crate.isQueued(.separate, for: id), group: 1,
                                         kind: .run { app.separateRecord(id) }))
        }
        actions.append(LibraryAction(id: "read", title: read ? "Read It Again" : "Read It",
                                     help: "Its key, tempo, bars and form.",
                                     isEnabled: !app.crate.isQueued(.analyse, for: id), group: 1,
                                     kind: .run { app.analyseRecord(id) }))
        if record.readingAsRead != nil {
            actions.append(LibraryAction(id: "grid", title: "Its Grid",
                                         help: record.grid.map { "Its grid: \($0.description)." } ?? "Its bar lines, as the tracker read them.",
                                         group: 1, kind: .menu(gridMoves(record, app))))
        }
        if app.crate.status(of: id) != nil {
            actions.append(LibraryAction(id: "stop", title: "Stop", help: "Stop what the crate is doing to it.", group: 1,
                                         kind: .run { app.crate.cancel(id) }))
        }
        actions.append(LibraryAction(id: "rename", title: "Rename…", group: 2,
                                     kind: .rename(current: app.suggestedName(for: id),
                                                   message: "A new name for the record. Sources already fitted from it keep the name they were fitted under.",
                                                   run: { _ = app.renameRecord(id, to: $0) })))
        actions.append(LibraryAction(id: "remove", title: "Remove from Library…", isDestructive: true, group: 2,
                                     kind: .confirm(question: "Remove “\(record.title)” from Records?",
                                                    detail: "Its audio and its stems stay in the library folder, so songs made from it still play. Only the row goes.",
                                                    verb: "Remove", run: { _ = app.removeRecord(id) })))
        return actions
    }

    private static func gridMoves(_ record: Record, _ app: AppState) -> [LibraryAction] {
        GridMove.allCases.map { move in
            if move == .secondTracker, app.refusal(of: move, for: record.id) == .noSecondTracker(record.title) {
                return LibraryAction(id: "grid-listen", title: "Listen with the Second Tracker",
                                     isEnabled: !app.crate.isQueued(.listen, for: record.id),
                                     kind: .run { app.listenForSecondTracker(record.id) })
            }
            return LibraryAction(id: "grid-\(move.rawValue)", title: gridTitle(move, record),
                                 isEnabled: app.refusal(of: move, for: record.id) == nil,
                                 kind: .run { app.correctGridAsked(record.id, move) })
        }
    }

    /// The menu's words for a correction, with what it would make of the tempo.
    static func gridTitle(_ move: GridMove, _ record: Record) -> String {
        if move == .secondTracker, record.grid?.secondTracker == true { return "The First Tracker's Grid" }
        guard move != .asRead, let now = record.reading?.dominantTempo, let read = record.readingAsRead else { return move.title }
        let next = move.applied(to: record.grid, beatsPerBar: Sources.beatsPerBar(in: record.reading ?? read))
        guard let then = read.regridded(next).dominantTempo, abs(then - now) > 0.05 else { return move.title }
        return String(format: "%@ (%.1f → %.1f bpm)", move.title, now, then)
    }
}

// MARK: - Drawing them

/// A list of actions as menu items: groups divided, a choice among several as a submenu. An action
/// that asks first, or asks for a name, is handed to `ask`; the view holding the menu shows the
/// question (`LibraryActionPrompt`).
struct LibraryActionMenuItems: View {
    let actions: [LibraryAction]
    let ask: (LibraryAction) -> Void

    var body: some View {
        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
            if index > 0, actions[index - 1].group != action.group { Divider() }
            item(action)
        }
    }

    @ViewBuilder
    private func item(_ action: LibraryAction) -> some View {
        switch action.kind {
        case .menu(let choices):
            Menu(action.title) {
                ForEach(choices) { choice in
                    Button(choice.title) { LibraryActions.perform(choice, ask: ask) }.disabled(!choice.isEnabled)
                }
            }
            .disabled(!action.isEnabled)
        default:
            Button(action.title, role: action.isDestructive ? .destructive : nil) { LibraryActions.perform(action, ask: ask) }
                .disabled(!action.isEnabled)
        }
    }
}

extension LibraryActions {
    /// Does an action now, or hands it to `ask` when it asks something first.
    static func perform(_ action: LibraryAction, ask: (LibraryAction) -> Void) {
        guard action.isEnabled else { return }
        switch action.kind {
        case .run(let run): run()
        case .confirm, .rename: ask(action)
        case .menu: break
        }
    }
}

/// The question an action asks before it does anything: a confirmation in the words the app
/// already used, or a new name. Attach to the view whose menu or buttons hand actions to `pending`.
struct LibraryActionPrompt: ViewModifier {
    @Binding var pending: LibraryAction?
    @State private var name = ""

    func body(content: Content) -> some View {
        let action = pending
        content
            .confirmationDialog(confirmation(action)?.question ?? "", isPresented: isAsking(confirming: true),
                                titleVisibility: .visible) {
                if let asked = confirmation(action) {
                    Button(asked.verb, role: .destructive) { asked.run() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmation(action)?.detail ?? "")
            }
            .alert("Rename", isPresented: isAsking(confirming: false)) {
                TextField("Title", text: $name)
                if let asked = renaming(action) {
                    Button("Rename") { asked.run(name) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(renaming(action)?.message ?? "")
            }
            .onChange(of: pending?.id) {
                if let asked = renaming(pending) { name = asked.current }
            }
    }

    private func isAsking(confirming: Bool) -> Binding<Bool> {
        Binding(get: { confirming ? confirmation(pending) != nil : renaming(pending) != nil },
                set: { if !$0 { pending = nil } })
    }

    private func confirmation(_ action: LibraryAction?) -> (question: String, detail: String, verb: String, run: @MainActor () -> Void)? {
        if case .confirm(let question, let detail, let verb, let run) = action?.kind { return (question, detail, verb, run) }
        return nil
    }

    private func renaming(_ action: LibraryAction?) -> (current: String, message: String, run: @MainActor (String) -> Void)? {
        if case .rename(let current, let message, let run) = action?.kind { return (current, message, run) }
        return nil
    }
}
