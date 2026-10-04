import AppKit
import Instrument
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
        /// A word asked for — a tag, a search's name — under its own title and button.
        case text(title: String, current: String, message: String, verb: String, run: @MainActor (String) -> Void)
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

    /// Everything that can be done to one item, grouped, in the order a menu lists it: its own
    /// actions, then its favourite and tags, then what cannot be undone.
    static func actions(for item: LibraryItemID, in app: AppState) -> [LibraryAction] {
        let own: [LibraryAction]
        switch item.shelf {
        case .songs: own = song(SongID(rawValue: item.id), app)
        case .records: own = record(RecordID(rawValue: item.id), app)
        case .ideas: own = idea(VersionID(rawValue: item.id), app)
        case .samples: own = sample(SampleID(rawValue: item.id), app)
        case .albums: own = album(AlbumID(rawValue: item.id), app)
        case .instruments: own = instrument(item, app)
        case .kits: own = kit(item, app)
        }
        guard !own.isEmpty else { return [] }
        return own.filter { !$0.isDestructive } + marks(for: [item], in: app) + own.filter(\.isDestructive)
    }

    /// A favourite and tags, for one item or several: one write of `library.json` each.
    static func marks(for items: [LibraryItemID], in app: AppState) -> [LibraryAction] {
        let marks = items.map { app.mark(of: $0) }
        let all = marks.allSatisfy { $0?.isFavourite == true }
        let some = items.count == 1 ? "it" : "them"
        let tags = LibraryIndex.unique(marks.flatMap { $0?.tags ?? [] })
        var actions = [
            LibraryAction(id: "favourite", title: all ? "Unmark Favourite" : "Mark as Favourite",
                          help: all ? "Take the star off" : "A star, and the Favourites filter finds \(some)", group: 3,
                          kind: .run { app.setFavourite(!all, for: items) }),
            LibraryAction(id: "tag", title: "Add a Tag…", help: "A word to find \(some) by: searched, and a filter of its own", group: 3,
                          kind: .text(title: "Add a Tag", current: "",
                                      message: items.count == 1 ? "A tag for it. Every tag is searched, and the Tag filter lists them."
                                                                : "A tag for these \(items.count). Every tag is searched, and the Tag filter lists them.",
                                      verb: "Add", run: { app.addTag($0, to: items) })),
        ]
        if !tags.isEmpty {
            actions.append(LibraryAction(id: "untag", title: "Remove a Tag", group: 3,
                                         kind: .menu(tags.map { tag in
                                             LibraryAction(id: "untag-\(tag)", title: tag, kind: .run { app.removeTag(tag, from: items) })
                                         })))
        }
        return actions
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
        case .instruments, .kits: preferred = ["use"]
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
        case .instruments:
            return [LibraryAction(id: "import-instrument", title: "Import Instrument…",
                                  help: "File ▸ Import Instrument…: an SFZ pack's samples copied into the library and listed in its family.",
                                  isEnabled: writable, kind: .run { if let url = FilePanels.chooseSFZ() { app.importInstrument(from: url) } })]
        case .kits:
            var actions = [
                LibraryAction(id: "import-kit", title: "Import Drum Kit…",
                              help: "File ▸ Import Drum Kit…: an SFZ kit laid out as General MIDI has it, listed beside the machines.",
                              isEnabled: writable, kind: .run {
                                  if let url = FilePanels.chooseSFZ(message: "An SFZ drum kit laid out as General MIDI has it: kick on 36, snare on 38, hats on 42 and 46. Its samples are copied into the library and it is listed beside the machines.") {
                                      app.importDrumKit(from: url)
                                  }
                              }),
            ]
            if let set = app.recordedPercussion {
                actions.append(LibraryAction(id: "percussion", title: set.isOn ? "Recorded Percussion Off" : "Recorded Percussion On",
                                             help: set.isOn ? "Every kit's congas, shaker and claves are \(set.name)'s recordings: go back to the synthesized ones."
                                                            : "Play \(set.name)'s recordings in place of every kit's synthesized hand percussion.",
                                             kind: .run { app.setRecordedPercussion(!set.isOn) }))
            } else {
                actions.append(LibraryAction(id: "import-percussion", title: "Import VCSL Percussion…",
                                             help: "File ▸ Import VCSL Percussion…: congas, bongos, shaker, tambourine and claves every kit plays.",
                                             isEnabled: writable, kind: .run {
                                                 if let url = FilePanels.chooseFolder(message: "The Versilian Community Sample Library folder (its sfz branch). Its congas, bongos, shaker, tambourine and claves are copied into the library and every kit plays them.",
                                                                                      prompt: "Bring In") {
                                                     app.importVCSLPercussion(from: url)
                                                 }
                                             }))
            }
            return actions
        case .ideas, .samples:
            return []
        }
    }

    // MARK: Instruments and kits

    /// An instrument: the chords and the tune play on it, or one part does; one brought in can go.
    private static func instrument(_ item: LibraryItemID, _ app: AppState) -> [LibraryAction] {
        guard let facts = app.libraryIndex.facts(item), let id = facts.code, let spec = InstrumentVoiceSpec.preset(id: id) else { return [] }
        let parts = app.song.map { song in
            song.partIDs.compactMap { part -> PartVersion? in
                guard let newest = song.latestVersion(of: part), [.progression, .melody].contains(newest.type), !song.isVariation(part) else { return nil }
                return newest
            }
        } ?? []
        var actions = [
            LibraryAction(id: "use", title: "Play the Chords and Tune on It",
                          help: app.song.map { "\(spec.name) for \($0.title)'s chords and tune, where a part has not picked its own." } ?? "Open a song to play it on.",
                          isEnabled: app.song != nil, kind: .run { app.setInstrument(id) }),
            LibraryAction(id: "use-on", title: "Play One Part on It",
                          help: parts.isEmpty ? "The open song has no chords or tune to give it." : "\(spec.name) for one part alone.",
                          isEnabled: !parts.isEmpty,
                          kind: .menu(parts.map { version in
                              LibraryAction(id: "use-\(version.partID.rawValue)", title: PartLabel.title(of: version),
                                            kind: .run { app.setInstrument(id, for: version.partID) })
                          })),
        ]
        if facts.isImported {
            actions.append(LibraryAction(id: "remove", title: "Remove from Library…", isDestructive: true, group: 2,
                                         kind: .confirm(question: "Remove \(spec.name)?",
                                                        detail: "Its copied samples are deleted from the library. The SFZ pack it came from is not touched, and a song that played it goes back to its own instrument.",
                                                        verb: "Remove", run: { _ = app.removeImportedInstrument(id: id) })))
        }
        return actions
    }

    /// A drum machine or a recorded kit: the drums play on it, or one groove does; one brought in can go.
    private static func kit(_ item: LibraryItemID, _ app: AppState) -> [LibraryAction] {
        guard let facts = app.libraryIndex.facts(item), let id = facts.code, let machine = SynthMachine.preset(id: id) else { return [] }
        let grooves = app.song.map { song in
            song.partIDs.compactMap { part -> PartVersion? in
                guard let newest = song.latestVersion(of: part), newest.type == .groove, !song.isVariation(part) else { return nil }
                return newest
            }
        } ?? []
        var actions = [
            LibraryAction(id: "use", title: "Play the Drums on It",
                          help: app.song.map { "\(machine.name) for \($0.title)'s drums, where a groove has not picked its own." } ?? "Open a song to play it on.",
                          isEnabled: app.song != nil, kind: .run { app.setMachine(id) }),
            LibraryAction(id: "use-on", title: "Play One Groove on It",
                          help: grooves.isEmpty ? "The open song has no groove to give it." : "\(machine.name) for one groove alone.",
                          isEnabled: !grooves.isEmpty,
                          kind: .menu(grooves.map { version in
                              LibraryAction(id: "use-\(version.partID.rawValue)", title: PartLabel.title(of: version),
                                            kind: .run { app.setMachine(id, for: version.partID) })
                          })),
        ]
        if facts.isImported {
            actions.append(LibraryAction(id: "remove", title: "Remove from Library…", isDestructive: true, group: 2,
                                         kind: .confirm(question: "Remove \(machine.name)?",
                                                        detail: "Its copied samples are deleted from the library. The SFZ it came from is not touched, and a song that played on it goes back to its own machine.",
                                                        verb: "Remove", run: { _ = app.removeRecordedKit(id: id) })))
        }
        return actions
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
        case .confirm, .rename, .text: ask(action)
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
            .alert(renaming(action)?.title ?? "Rename", isPresented: isAsking(confirming: false)) {
                TextField(renaming(action)?.title == "Rename" ? "Title" : "", text: $name)
                if let asked = renaming(action) {
                    Button(asked.verb) { asked.run(name) }
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

    /// A rename, or any word asked for: the alert's title, where the field starts, what it is for
    /// and the button that takes it.
    private func renaming(_ action: LibraryAction?) -> (title: String, current: String, message: String, verb: String, run: @MainActor (String) -> Void)? {
        switch action?.kind {
        case .rename(let current, let message, let run)?: return ("Rename", current, message, "Rename", run)
        case .text(let title, let current, let message, let verb, let run)?: return (title, current, message, verb, run)
        default: return nil
        }
    }
}
