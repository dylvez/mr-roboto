import AppKit
import Foundation
import MusicTheory
import SongGraph

// MARK: - The song's own settings

/// The song as a thing with a name, a tempo, a key and a meter — the four values the transport
/// clock, every writer and every persona read, and which until now only the Director could set.
/// File ▸ New Song made "Untitled, Sept 17" at 120 with no key, and the only way to change any of
/// that was to ask the band for it in a sentence.
///
/// None of these is a version. Like the sections and the cast they are the song's setting, edited
/// in place, marked unsaved, and saved with the song.
extension AppState {

    /// The tempo a song may be set to. Below this nothing is a beat; above it nothing is a bar.
    public static let tempoRange: ClosedRange<Double> = 20...300

    /// The meters the settings offer by name. Any other is typed as "7/8".
    public static let commonTimeSignatures: [TimeSignature] = [
        TimeSignature(4, 4), TimeSignature(3, 4), TimeSignature(6, 8), TimeSignature(2, 4),
        TimeSignature(5, 4), TimeSignature(7, 8), TimeSignature(12, 8),
    ]

    /// Renames the open song. The sidebar follows at once; the package keeps its file name (a
    /// song is found by the id inside it, not by its name). Surfaces titled for the song are
    /// retitled, so the bench does not go on calling it what it was.
    @discardableResult
    public func setTitle(_ title: String) -> Bool {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = song, !name.isEmpty, name != current.title else { return false }
        let was = current.title
        updateSong { $0.title = name }
        if let song { library.upsert(song) }
        for item in bench.items where item.title == was { retitleSurface(item.id, to: name) }
        note(.you, "Renamed \(was) to \(name)")
        return true
    }

    @discardableResult
    public func setArtist(_ artist: String) -> Bool {
        let name = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = song, name != current.artist else { return false }
        updateSong { $0.artist = name }
        if let song { library.upsert(song) }
        note(.you, name.isEmpty ? "Cleared the artist" : "Artist: \(name)")
        return true
    }

    /// Sets the tempo the clock runs at, clamped to `tempoRange`. Every part keeps its own beats;
    /// they simply go by faster or slower. A tempo changed while the song plays lands on the next
    /// press of play, and the rail says so rather than letting the readout disagree with the ear.
    @discardableResult
    public func setTempo(_ bpm: Double) -> Bool {
        guard let current = song, bpm.isFinite else { return false }
        let clamped = min(Self.tempoRange.upperBound, max(Self.tempoRange.lowerBound, bpm))
        guard abs(clamped - current.tempo) > 0.001 else { return false }
        updateSong { $0.tempo = clamped }
        note(.you, String(format: "Tempo %.0f bpm", clamped),
             detail: transport.isPlaying ? "Takes effect the next time you press play." : nil)
        return true
    }

    /// Sets the key the writers and the personas read the song in, or clears it. Nothing already
    /// written moves: a key is what the next part is written to, not a transposition.
    @discardableResult
    public func setKey(_ key: Key?) -> Bool {
        guard let current = song, key != current.key else { return false }
        updateSong { $0.key = key }
        note(.you, key.map { "Key: \($0.name)" } ?? "Cleared the key")
        return true
    }

    /// Sets the key from what a person types: "D major", "F# minor", "Eb", "A dorian". Returns
    /// false, with nothing changed, for text that is not a key — the settings say so in place.
    @discardableResult
    public func setKey(parsing text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return setKey(nil) }
        guard let key = Key(parsing: trimmed) else { return false }
        return setKey(key)
    }

    @discardableResult
    public func setTimeSignature(_ signature: TimeSignature) -> Bool {
        guard let current = song, signature != current.timeSignature,
              signature.beatsPerBar >= 1, [1, 2, 4, 8, 16].contains(signature.beatUnit) else { return false }
        updateSong { $0.timeSignature = signature }
        note(.you, "Meter \(signature.description)",
             detail: transport.isPlaying ? "Takes effect the next time you press play." : nil)
        return true
    }

    /// "4/4", "7/8". Nil for anything that is not two numbers over a slash.
    public static func timeSignature(parsing text: String) -> TimeSignature? {
        let parts = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let beats = Int(parts[0]), let unit = Int(parts[1]),
              beats >= 1, beats <= 32, [1, 2, 4, 8, 16].contains(unit) else { return nil }
        return TimeSignature(beatsPerBar: beats, beatUnit: unit)
    }
}

// MARK: - The library, managed

/// Songs, albums, ideas, samples and records could be made and never unmade: the sidebar had no
/// rename, no duplicate, no delete, and a library that only grows is one you stop trusting the
/// contents of. Everything here is recoverable — a song goes to the Trash, not away — and says
/// where it went.
extension AppState {

    /// Renames a song wherever it is: the open one in place, any other inside its package.
    @discardableResult
    public func renameSong(_ id: SongID, to title: String) -> Bool {
        if song?.id == id { return setTitle(title) }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let store, let existing = library.song(id), existing.title != name else { return false }
        do {
            let package = try store.songStore(for: id)
            var loaded = try package.load()
            loaded.title = name
            try package.save(loaded)
        } catch {
            note(.session, "Could not rename \(existing.title)", detail: "\(error)")
            return false
        }
        reloadLibrary()
        note(.you, "Renamed \(existing.title) to \(name)")
        return true
    }

    /// A copy of a song under a new id: the same versions, sections, seeds and cast, its media
    /// copied into the new package, and the copy opened. The original is untouched.
    @discardableResult
    public func duplicateSong(_ id: SongID) -> SongID? {
        guard let store else {
            note(.session, "Nowhere to keep a copy", detail: "This session has no library directory.")
            return nil
        }
        guard let original = song?.id == id ? song : library.song(id) else {
            note(.session, "That song is not in the library")
            return nil
        }
        var copy = Song(title: "\(original.title) copy", artist: original.artist, key: original.key,
                        tempo: original.tempo, timeSignature: original.timeSignature, sections: original.sections,
                        versions: original.versions, seeds: original.seeds, experiments: original.experiments)
        copy.cast = original.cast
        copy.houseCalls = original.houseCalls
        var updated = library
        if let song { updated.upsert(song) }
        updated.upsert(copy)
        do {
            try store.save(updated)
            let source = try store.songStore(for: original.id)
            let target = try store.songStore(for: copy.id)
            for ref in try source.storedMedia() where !target.hasMedia(ref) {
                try target.addMedia(copying: source.mediaURL(for: ref))
            }
        } catch {
            note(.session, "Could not copy \(original.title)", detail: "\(error)")
            reloadLibrary()
            return nil
        }
        hasUnsavedChanges = false
        reloadLibrary()
        note(.you, "Duplicated \(original.title) as \(copy.title)")
        open(copy)
        return copy.id
    }

    /// Moves a song's package to the Trash and forgets it: out of the library, out of every
    /// album, and closed if it was open. The Trash is the point — Finder puts it back.
    @discardableResult
    public func deleteSong(_ id: SongID) -> Bool {
        guard let store else {
            note(.session, "Nowhere to delete from", detail: "This session has no library directory.")
            return false
        }
        guard let existing = song?.id == id ? song : library.song(id) else {
            note(.session, "That song is not in the library")
            return false
        }
        if song?.id == id { closeSong(saving: false) }
        let destination: URL?
        do {
            destination = try store.trashSong(id, using: trash)
        } catch {
            note(.session, "Could not move \(existing.title) to the Trash", detail: "\(error)")
            return false
        }
        var updated = library
        updated.songs.removeAll { $0.id == id }
        for index in updated.albums.indices {
            updated.albums[index].songs.removeAll { $0 == id }
            updated.albums[index].gaps[id] = nil
            updated.albums[index].releases[id] = nil
        }
        guard writeLibrary(updated) else { return false }
        if defaults.string(forKey: Self.lastOpenedSongKey) == id.rawValue.uuidString {
            defaults.removeObject(forKey: Self.lastOpenedSongKey)
        }
        note(.you, "Moved \(existing.title) to the Trash", detail: destination?.path)
        return true
    }

    /// Forgets an album. Its songs stay; an album is an ordering of them, not their home.
    @discardableResult
    public func deleteAlbum(_ id: AlbumID) -> Bool {
        guard let album = library.album(id) else {
            note(.session, "That album is not in the library any more")
            return false
        }
        for (surface, bound) in albumBindings where bound == id { closeSurface(surface) }
        var updated = library
        updated.albums.removeAll { $0.id == id }
        guard writeLibrary(updated) else { return false }
        note(.you, "Deleted the album \(album.title)",
             detail: album.songs.isEmpty ? nil : "Its \(album.songs.count) song\(album.songs.count == 1 ? " is" : "s are") still in the library.")
        return true
    }

    /// Forgets an idea. Songs that adopted it copied its audio, so they keep playing.
    @discardableResult
    public func removeIdea(_ id: VersionID) -> Bool {
        guard let idea = library.ideas.first(where: { $0.id == id }) else { return false }
        var updated = library
        updated.ideas.removeAll { $0.id == id }
        guard writeLibrary(updated) else { return false }
        note(.you, "Removed the idea \(PartLabel.title(of: idea)) from the library")
        return true
    }

    @discardableResult
    public func removeSample(_ id: SampleID) -> Bool {
        guard let entry = library.sample(id) else { return false }
        var updated = library
        updated.samples.removeAll { $0.id == id }
        guard writeLibrary(updated) else { return false }
        note(.you, "Removed \(entry.name) from Samples")
        return true
    }

    /// Forgets a record. Its audio stays in the library folder, because a song flipped from it
    /// may still play that file; only the row goes.
    @discardableResult
    public func removeRecord(_ id: RecordID) -> Bool {
        guard let record = library.record(id) else { return false }
        var updated = library
        updated.records.removeAll { $0.id == id }
        guard writeLibrary(updated) else { return false }
        note(.you, "Removed \(record.title) from Records",
             detail: "Its audio stays in the library folder, so songs flipped from it still play.")
        return true
    }

    /// Shows a song's package in Finder.
    public func revealInFinder(song id: SongID) {
        guard let store, let package = try? store.songStore(for: id) else {
            note(.session, "That song has no package on disk yet", detail: "Save it first.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([package.packageURL])
    }
}
