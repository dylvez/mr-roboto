import Foundation
import Observation
import SongGraph

/// Work on several songs at once that is not the crate's: exporting their masters, one song at a
/// time, each rendered from its own package as File ▸ Export renders the open one. One line says
/// how far it has got, and a song that fails is said against that song and the rest go on.
@MainActor
@Observable
final class LibraryBatchWork {
    let app: AppState
    /// "Exporting Night Bus, 2 of 3 · 40%", while it runs.
    private(set) var line: String?
    /// Where each song's master went.
    private(set) var exported: [SongID: URL] = [:]
    /// Why a song's master did not.
    private(set) var failures: [SongID: String] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Where a song's master goes: its folder under Exports, unless told otherwise (a test).
    @ObservationIgnored var directory: (Song) -> URL = { Export.defaultDirectory(for: $0) }

    init(app: AppState) { self.app = app }

    var isRunning: Bool { task != nil }

    /// Exports each song's master in turn. A batch already running is not started twice.
    func exportMasters(_ songs: [SongID]) {
        guard task == nil, !songs.isEmpty else { return }
        app.keepSurfaceWork()
        task = Task { [weak self] in
            await self?.run(songs)
            self?.task = nil
            self?.line = nil
        }
    }

    /// Waits for the batch running now, if any.
    func finish() async { await task?.value }

    func cancel() {
        task?.cancel()
    }

    private func run(_ ids: [SongID]) async {
        for (number, id) in ids.enumerated() {
            guard !Task.isCancelled else { break }
            guard let song = app.song?.id == id ? app.song : app.library.song(id) else { continue }
            let head = ids.count == 1 ? "Exporting \(song.title)" : "Exporting \(song.title), \(number + 1) of \(ids.count)"
            line = head
            let progress = BatchProgress(work: self, head: head)
            do {
                let plan = SongPreviews.plan(for: song, store: app.store)
                let made = try await Export.master(of: song, plan: plan, in: app, to: directory(song),
                                                   pacing: .init(frames: 12_000, progress: progress.report))
                exported[id] = made.wav
                failures[id] = nil
            } catch is CancellationError {
                break
            } catch {
                failures[id] = "\(error)"
                app.note(.session, "Could not export \(song.title)", detail: "\(error)")
            }
        }
    }

    fileprivate func progress(_ fraction: Double, head: String) {
        guard line?.hasPrefix(head) == true else { return }
        line = "\(head) · \(Int((fraction * 100).rounded()))%"
    }
}

/// How far a render has got, said from the thread that renders it to the batch on the main actor.
private final class BatchProgress: @unchecked Sendable {
    // Read only on the main actor.
    private weak var work: LibraryBatchWork?
    private let head: String

    @MainActor init(work: LibraryBatchWork, head: String) {
        self.work = work
        self.head = head
    }

    func report(_ fraction: Double) {
        Task { @MainActor in self.work?.progress(fraction, head: self.head) }
    }
}

// MARK: - What can be done to several at once

extension LibraryActions {

    /// What can be done to several items of one shelf at once: their own batch actions, their
    /// favourites and tags, then what cannot be undone, asked first with how many and what goes.
    static func batch(_ items: [LibraryItemID], in app: AppState, work: LibraryBatchWork) -> [LibraryAction] {
        guard let shelf = items.first?.shelf else { return [] }
        let count = items.count
        var own: [LibraryAction] = []
        switch shelf {
        case .songs:
            let ids = items.map { SongID(rawValue: $0.id) }
            let albums = app.library.albums.filter { album in ids.contains { !album.songs.contains($0) } }
            own.append(LibraryAction(id: "album", title: "Add to Album",
                                     help: albums.isEmpty ? "They are on every album already, or there is none." : "Each at the end of the album's songs, unless it is on it already.",
                                     isEnabled: !albums.isEmpty,
                                     kind: .menu(albums.map { album in
                                         LibraryAction(id: "album-\(album.id.rawValue)", title: album.title, kind: .run {
                                             for id in ids where app.library.album(album.id)?.songs.contains(id) == false { _ = app.addSong(id, to: album.id) }
                                         })
                                     })))
            own.append(LibraryAction(id: "export", title: "Export Masters…",
                                     help: work.isRunning ? "Exporting already." : "Each song's master, one at a time, into its folder in ~/Music/Mr. Roboto/Exports.",
                                     isEnabled: !work.isRunning && app.store != nil, group: 1,
                                     kind: .confirm(question: "Export \(count) masters?",
                                                    detail: "Each song is rendered from its own package as File ▸ Export renders it, one at a time, into its own folder in ~/Music/Mr. Roboto/Exports. Nothing already there is replaced.",
                                                    verb: "Export", run: { work.exportMasters(ids) })))
            own.append(LibraryAction(id: "trash", title: "Move to Trash…", isDestructive: true, group: 2,
                                     kind: .confirm(question: "Move \(count) songs to the Trash?",
                                                    detail: "Their packages go to the Trash, where Finder can put them back. They leave every album they are on.",
                                                    verb: "Move to Trash", run: { for id in ids { _ = app.deleteSong(id) } })))
        case .records:
            let ids = items.map { RecordID(rawValue: $0.id) }
            let records = ids.compactMap { app.library.record($0) }
            let separable = records.filter { !app.crate.isQueued(.separate, for: $0.id) }
            let readable = records.filter { !app.crate.isQueued(.analyse, for: $0.id) }
            own.append(LibraryAction(id: "separate", title: "Separate Their Stems",
                                     help: "Each into vocals, drums, bass and other, one at a time in the background, kept with the record.",
                                     isEnabled: !separable.isEmpty,
                                     kind: .run { for record in separable { app.separateRecord(record.id) } }))
            own.append(LibraryAction(id: "read", title: "Read Them Again",
                                     help: "Each one's key, tempo, bars, form and tuning, read again in the background.",
                                     isEnabled: !readable.isEmpty,
                                     kind: .run { for record in readable { app.analyseRecord(record.id) } }))
            if records.contains(where: { app.crate.status(of: $0.id) != nil }) {
                own.append(LibraryAction(id: "stop", title: "Stop", help: "Stop what the crate is doing to them.",
                                         kind: .run { for record in records { app.crate.cancel(record.id) } }))
            }
            own.append(LibraryAction(id: "remove", title: "Remove from Library…", isDestructive: true, group: 2,
                                     kind: .confirm(question: "Remove \(count) records from Records?",
                                                    detail: "Their audio and their stems stay in the library folder, so songs made from them still play. Only the rows go.",
                                                    verb: "Remove", run: { for id in ids { _ = app.removeRecord(id) } })))
        case .ideas:
            let ideas = items.compactMap { item in app.library.ideas.first { $0.id.rawValue == item.id } }
            own.append(adoptAll(ideas.map { LibraryDragPayload(kind: .idea, id: $0.id.rawValue, title: PartLabel.title(of: $0)) }, app))
            own.append(LibraryAction(id: "remove", title: "Remove from Library…", isDestructive: true, group: 2,
                                     kind: .confirm(question: "Remove \(count) ideas from the library?",
                                                    detail: "Songs that adopted them copied their audio and keep playing.",
                                                    verb: "Remove", run: { for idea in ideas { _ = app.removeIdea(idea.id) } })))
        case .samples:
            let entries = items.compactMap { app.library.sample(SampleID(rawValue: $0.id)) }
            own.append(adoptAll(entries.map { LibraryDragPayload(kind: .sample, id: $0.id.rawValue, title: $0.name) }, app))
            own.append(LibraryAction(id: "remove", title: "Remove from Library…", isDestructive: true, group: 2,
                                     kind: .confirm(question: "Remove \(count) samples from Samples?",
                                                    detail: "Songs that adopted them copied their audio and keep playing.",
                                                    verb: "Remove", run: { for entry in entries { _ = app.removeSample(entry.id) } })))
        case .instruments, .kits:
            break
        case .albums:
            let ids = items.map { AlbumID(rawValue: $0.id) }
            own.append(LibraryAction(id: "delete", title: "Delete Albums…", isDestructive: true, group: 2,
                                     kind: .confirm(question: "Delete \(count) albums?",
                                                    detail: "Their songs stay in the library; only the order, the targets and the clearances go.",
                                                    verb: "Delete Albums", run: { for id in ids { _ = app.deleteAlbum(id) } })))
        }
        return own.filter { !$0.isDestructive } + marks(for: items, in: app) + own.filter(\.isDestructive)
    }

    /// Several ideas or samples into the open song, each a part in every section, no surface opened.
    private static func adoptAll(_ payloads: [LibraryDragPayload], _ app: AppState) -> LibraryAction {
        LibraryAction(id: "adopt", title: "Adopt into This Song",
                      help: app.song.map { "Each a part of \($0.title), in every section." } ?? "Open a song to adopt them into.",
                      isEnabled: app.song != nil, kind: .run { for payload in payloads { _ = app.adopt(payload) } })
    }
}
