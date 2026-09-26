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
    public func setTitle(_ title: String, by source: SessionEntry.Source = .you) -> Bool {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = song, !name.isEmpty, name != current.title else { return false }
        let was = current.title
        updateSong { $0.title = name }
        if let song { library.upsert(song) }
        for item in bench.items where item.title == was { retitleSurface(item.id, to: name) }
        note(source, "Renamed \(was) to \(name)")
        return true
    }

    @discardableResult
    public func setArtist(_ artist: String, by source: SessionEntry.Source = .you) -> Bool {
        let name = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = song, name != current.artist else { return false }
        updateSong { $0.artist = name }
        if let song { library.upsert(song) }
        note(source, name.isEmpty ? "Cleared the artist" : "Artist: \(name)")
        return true
    }

    /// Sets the tempo the clock runs at, clamped to `tempoRange`. Every part keeps its own beats;
    /// they simply go by faster or slower. A tempo changed while the song plays lands on the next
    /// press of play, and the rail says so rather than letting the readout disagree with the ear.
    @discardableResult
    public func setTempo(_ bpm: Double, by source: SessionEntry.Source = .you) -> Bool {
        guard let current = song, bpm.isFinite else { return false }
        let clamped = min(Self.tempoRange.upperBound, max(Self.tempoRange.lowerBound, bpm))
        guard abs(clamped - current.tempo) > 0.001 else { return false }
        updateSong { $0.tempo = clamped }
        note(source, String(format: "Tempo %.0f bpm", clamped),
             detail: transport.isPlaying ? "Takes effect the next time you press play." : nil)
        return true
    }

    /// Sets the key the writers and the personas read the song in, or clears it. Nothing already
    /// written moves: a key is what the next part is written to, not a transposition.
    @discardableResult
    public func setKey(_ key: Key?, by source: SessionEntry.Source = .you) -> Bool {
        guard let current = song, key != current.key else { return false }
        updateSong { $0.key = key }
        note(source, key.map { "Key: \($0.name)" } ?? "Cleared the key")
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
    public func setTimeSignature(_ signature: TimeSignature, by source: SessionEntry.Source = .you) -> Bool {
        guard let current = song, signature != current.timeSignature,
              signature.beatsPerBar >= 1, [1, 2, 4, 8, 16].contains(signature.beatUnit) else { return false }
        updateSong { $0.timeSignature = signature }
        note(source, "Meter \(signature.description)",
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

// MARK: - A new song has a shape

extension Song {
    /// The form a new song starts with: an intro, a verse and a hook, empty. Every part you make
    /// joins all three (`AppState.joinForm`), so the transport plays a form from the first groove,
    /// and Structure is where you shape it rather than a step you have to remember to take.
    public static let startingForm: [(name: String, bars: Int)] = [("Intro", 4), ("Verse", 16), ("Hook", 8)]

    /// A new song from nothing, with the starting form.
    public static func new(title: String, key: Key? = nil, tempo: Double = 120) -> Song {
        Song(title: title, key: key, tempo: tempo,
             sections: startingForm.map { Section(name: $0.name, stitch: [], lengthInBars: $0.bars) })
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
        // The open song's last edit goes into the copy too: it was a moment from keeping itself.
        if song?.id == id { keepSurfaceWork() }
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

// MARK: - A step back, from the ledger

/// "Back one version", and "make this one current" — the ledger's half of undo.
///
/// ⌘Z steps a surface back through its own edits. This steps a *part* back through its versions,
/// from anywhere, whether a surface is open on it or not: the Director's line you did not want, a
/// mix move from yesterday. Nothing is deleted — the graph only grows — so a restore is a new
/// version carrying the older music, and the one it replaced is a step back from that.
extension AppState {

    /// Makes an older version of its part current again. False when the song does not hold it,
    /// or it is already the newest.
    @discardableResult
    public func restore(_ id: VersionID) -> Bool {
        guard let song, let target = song.version(id) else { return false }
        let history = song.versions.filter { $0.partID == target.partID }
        guard let newest = history.last, newest.id != id else { return false }
        let number = history.firstIndex { $0.id == id }.map { $0 + 1 }
        let restored = newest.deriving(target.kind, by: .user, operation: Operation.restored,
                                       note: target.note ?? PartLabel.title(of: target),
                                       alsoFrom: [target.id])
        guard record(restored, joiningForm: false) else { return false }
        note(.you, "Back to \(PartLabel.title(of: target))\(number.map { " (v\($0))" } ?? "")",
             detail: "A new version with v\(number ?? 0)'s music; nothing was removed.")
        refreshSurfaces(showing: target.partID, now: restored.id)
        return true
    }

    /// The version "back one" would restore: the one before the music the part plays now. After a
    /// restore that is the one before the version it restored, so pressing it again keeps going
    /// back rather than bouncing between two.
    public func stepBackTarget(for part: PartID) -> PartVersion? {
        guard let song else { return nil }
        let history = song.versions.filter { $0.partID == part }
        guard let newest = history.last else { return nil }
        let pointer = newest.operation == Operation.restored ? (newest.parents.last ?? newest.id) : newest.id
        guard let index = history.firstIndex(where: { $0.id == pointer }), index > 0 else { return nil }
        return history[index - 1]
    }

    /// Back one version of a part.
    @discardableResult
    public func stepBack(_ part: PartID) -> Bool {
        guard let target = stepBackTarget(for: part) else { return false }
        return restore(target.id)
    }

    /// Rebinds every open surface showing this part to its new version, so the surface draws what
    /// the song now plays instead of the draft it was holding.
    /// Surfaces of these kinds rebuilt from the song as it is now: the Mixer reads the newest mix
    /// whatever it is bound to.
    func refreshSurfaces(of kinds: Set<SurfaceKind>) {
        for item in bench.items where kinds.contains(item.kind) { discardSurfaceModel(item.id) }
    }

    func refreshSurfaces(showing part: PartID, now version: VersionID) {
        guard let song else { return }
        for item in bench.items {
            let bound = self.bound(for: item.id)
            guard bound.contains(where: { song.version($0)?.partID == part }) else { continue }
            rebindSurface(item.id, to: bound.map { song.version($0)?.partID == part ? version : $0 })
            discardSurfaceModel(item.id)
        }
    }
}

// MARK: - Is it heard?

/// Whether a part plays in the song, and if not, why — said on the surface that holds it.
///
/// Doing the right thing and hearing nothing was the one failure the frame never explained: a part
/// written after the form was arranged sat in no section; a second groove in an unarranged song was
/// quietly replaced by the newest; the record and its stems stop the moment a section plays
/// anything. Each was documented somewhere. Now the surface says it, in its header.
public enum Audibility: Equatable, Sendable {
    /// Heard: "in Verse and Hook", "in the song".
    case plays(String)
    /// Not heard, the reason, and — when one move fixes it — that move.
    case silent(String, fix: AudibilityFix?)
}

public enum AudibilityFix: Equatable, Sendable {
    /// Stitch the part into every section.
    case addToEverySection(PartID)
    /// Open Structure, where the choice is the person's.
    case openStructure
}

extension AppState {

    /// Nil for a part that is not the kind of thing that plays (an analysis, a sound pick, a mix,
    /// words), so no header says "not in the song" about a lyric.
    public func audibility(of part: PartID) -> Audibility? {
        guard let song, let newest = song.versions.last(where: { $0.partID == part }) else { return nil }
        let plan = playback
        if let audio = Guidance.audio(of: newest) {
            if audio.take != nil || audio.comp != nil {
                return plan.tracks.contains { $0.part == part } ? .plays("in the song, where it was sung")
                    : .silent("Its audio is missing, or every player is taken", fix: nil)
            }
            if plan.isArranged {
                return .silent("The record and its stems stop once a section plays something; chop what you want from them", fix: nil)
            }
            return plan.tracks.contains { $0.part == part } ? .plays("in the song") : nil
        }
        guard StructureModel.playableTypes.contains(newest.type) else { return nil }
        guard StructureModel.plays(newest) else { return .silent("Empty: nothing in it plays yet", fix: nil) }
        let kind = StructureModel.name(of: newest.type).lowercased()
        if plan.isArranged {
            let sections = song.sections.filter { $0.stitch.contains { $0.part == part } }.map(\.name)
            guard !sections.isEmpty else {
                return .silent("In no section, so the form never plays it", fix: .addToEverySection(part))
            }
            if sections.count == song.sections.count { return .plays("in every section") }
            return .plays("in " + Self.listed(sections))
        }
        if plan.parts.contains(part) { return .plays("in the song") }
        return .silent("The song plays its newest \(kind) until it is arranged; put this one in a section to hear it",
                       fix: .openStructure)
    }

    /// Carries out a fix from a surface header.
    public func apply(_ fix: AudibilityFix) {
        switch fix {
        case .addToEverySection(let part):
            // In every section, in place of the part of its kind each one plays now: a second bass
            // line is chosen instead of the first, not stacked on it. Structure layers two when
            // that is what is wanted.
            guard let song, !song.sections.isEmpty,
                  let kind = song.versions.last(where: { $0.partID == part })?.type else { return }
            let sections = song.sections.map { section -> Section in
                var section = section
                section.stitch.removeAll { lane in
                    lane.part != part && song.versions.last { $0.partID == lane.part }?.type == kind
                }
                if !section.stitch.contains(where: { $0.part == part }) { section.stitch.append(Lane(part: part)) }
                return section
            }
            arrange(sections)
        case .openStructure:
            perform(Guidance.dockAction(for: .structure, in: song))
        }
    }

    /// "Verse", "Verse and Hook", "Intro, Verse and Hook".
    static func listed(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}

extension AppState {
    /// A version for a song that is not the one open: written into that song's own package. Work
    /// that finishes after its song was left — stems a minute in the making, a merge rendering —
    /// used to be recorded into whatever song was open by then, its media in the other package.
    @discardableResult
    func record(_ version: PartVersion, intoLibrarySong id: SongID) -> Bool {
        if song?.id == id { return record(version) }
        guard let store, var target = library.song(id) else {
            note(.session, "\(PartLabel.title(of: version)) finished after its song was closed", detail: "There was nowhere to keep it.")
            return false
        }
        do {
            try target.append(version)
            var updated = library
            updated.upsert(target)
            try store.save(updated)
            library = updated
            note(.session, "\(PartLabel.title(of: version)) is in \(target.title)",
                 detail: "It finished after you left that song, and is there when you open it.")
            return true
        } catch {
            note(.session, "Could not keep \(PartLabel.title(of: version)) in \(target.title)", detail: "\(error)")
            return false
        }
    }
}
