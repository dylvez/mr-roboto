import Instrument
import MusicTheory
import Foundation
import SongGraph

// MARK: - The library, written

/// Where a library row was dropped, which decides what adopting it goes on to do.
public enum LibraryDrop: Sendable, Equatable {
    /// The bench: adopt, then open the surface the part belongs on.
    case bench
    /// The Parts ledger: adopt, and nothing more.
    case ledger
    /// Structure: adopt, then stitch into this section.
    case section(SectionID)
}

/// M3's library: ideas kept, samples saved, records flipped again, albums sequenced, and library
/// rows adopted into the open song.
///
/// Two rules hold throughout. A library-level change writes `library.json` alone
/// (`LibraryStore.saveDocument`), never the song packages, so keeping an idea cannot write a stale
/// copy of the song you have open. And adopting copies media *into* the song's package, so a song
/// still opens with the idea or the sample gone from the library.
extension AppState {

    // MARK: Ideas

    /// Copies a version of the open song into the library as an idea: the same music under a fresh
    /// id with no parents, and its media in the library's `ideas/`, so it outlives the song.
    @discardableResult
    public func keepAsIdea(_ id: VersionID) -> VersionID? {
        guard let song, let version = song.version(id) else {
            note(.session, "Nothing to keep", detail: "That version is not in the open song.")
            return nil
        }
        guard let store else {
            note(.session, "Nowhere to keep an idea", detail: "This session has no library directory.")
            return nil
        }
        do {
            try copyMedia(of: version, from: song.id, into: .idea, store: store)
        } catch {
            note(.session, "Could not copy the idea's audio into the library", detail: "\(error)")
            return nil
        }
        var provenance = "\(PartLabel.title(of: version)) from \(song.title)"
        if let text = version.note, !text.isEmpty { provenance += " — \(text)" }
        let idea = PartVersion(partID: PartID(), kind: version.kind, author: version.author,
                               operation: version.operation, note: provenance)
        var updated = library
        updated.ideas.append(idea)
        guard writeLibrary(updated) else { return nil }
        note(.you, "Kept \(PartLabel.title(of: version)) as an idea", detail: provenance)
        return idea.id
    }

    // MARK: Samples

    /// Saves a chop of the open song to the library's samples, dry or dusty as it is, with its
    /// slices, tempo, chain and the record it came from.
    @discardableResult
    public func saveToSamples(_ id: VersionID, name: String? = nil, tags: [String] = []) -> SampleID? {
        guard let song, let version = song.version(id), case .sample(var sample) = version.kind else {
            note(.session, "Only a chop can be saved as a sample")
            return nil
        }
        guard let store else {
            note(.session, "Nowhere to save a sample", detail: "This session has no library directory.")
            return nil
        }
        do {
            try copyMedia(of: version, from: song.id, into: .sample, store: store)
        } catch {
            note(.session, "Could not copy the sample into the library", detail: "\(error)")
            return nil
        }
        if sample.sourceRecord == nil {
            sample.sourceRecord = library.record(forMedia: sample.media)?.id
                ?? version.parents.compactMap { song.version($0) }.compactMap { Guidance.sourceRecord(of: $0, in: song) }.first
        }
        let entry = LibrarySample(name: name ?? "\(PartLabel.title(of: version)) — \(song.title)", sample: sample,
                                  tags: tags.isEmpty ? [song.title] : tags)
        var updated = library
        updated.samples.append(entry)
        guard writeLibrary(updated) else { return nil }
        note(.you, "Saved \(entry.name) to Samples", detail: entry.tags.joined(separator: " · "))
        return entry.id
    }

    // MARK: Adopting

    /// Brings a library item into the open song as a new version, its media copied into the
    /// package. Songs and albums are opened rather than adopted. Returns nil with a line in the
    /// rail saying why.
    ///
    /// - Parameter joiningForm: whether the adopted part joins every section, as anything newly
    ///   made does. False only when the caller is about to place it somewhere particular — a drop
    ///   aimed at one section means *that* section.
    @discardableResult
    public func adopt(_ payload: LibraryDragPayload, joiningForm: Bool = true) -> VersionID? {
        guard let song else {
            note(.session, "Open a song first", detail: "There is nothing to adopt \(payload.title) into.")
            return nil
        }
        switch payload.kind {
        case .song:
            openSong(SongID(rawValue: payload.id))
            return nil
        case .album:
            openAlbum(AlbumID(rawValue: payload.id))
            return nil
        case .idea:
            guard let idea = library.ideas.first(where: { $0.id.rawValue == payload.id }) else {
                note(.session, "That idea is not in the library any more")
                return nil
            }
            guard copyMediaIntoPackage(of: idea, song: song) else { return nil }
            let version = PartVersion(partID: PartID(), kind: idea.kind, author: idea.author,
                                      operation: Operation.adopted, note: "from idea: \(idea.note ?? PartLabel.title(of: idea))")
            return record(version, joiningForm: joiningForm) ? version.id : nil
        case .sample:
            guard let entry = library.samples.first(where: { $0.id.rawValue == payload.id }) else {
                note(.session, "That sample is not in the library any more")
                return nil
            }
            let carrier = PartVersion(partID: PartID(), kind: .sample(entry.sample), author: .user, operation: Operation.adopted)
            guard copyMediaIntoPackage(of: carrier, song: song) else { return nil }
            let version = PartVersion(partID: PartID(), kind: .sample(entry.sample), author: .user,
                                      operation: Operation.adopted, note: "from sample \"\(entry.name)\"")
            return record(version, joiningForm: joiningForm) ? version.id : nil
        case .record:
            return adoptRecord(RecordID(rawValue: payload.id), into: song)
        case .stem:
            askForSource(AskedSource(origin: .record(RecordID(rawValue: payload.id)), stem: payload.stem))
            return nil
        }
    }

    /// The Sources surface, open on a record of the crate — a stem of it, a section for it —
    /// chosen there to be heard against the song and added. A stem is fitted to the song, never
    /// adopted as it is, so a drop lands here rather than in the song.
    public func askForSource(_ asked: AskedSource) {
        guard song != nil else {
            note(.session, "Open a song first", detail: "A stem is fitted into the open song. Start one from the record's row, or open one.")
            return
        }
        askedSource = asked
        openSurface(.sources, title: "Sources")
    }

    /// A record adopted into a song brings its take and its analysis, stamped with one seed, so a
    /// bar can be chopped from it by the analysis that actually describes it. A record the song
    /// already holds is returned rather than brought in twice.
    private func adoptRecord(_ id: RecordID, into song: Song) -> VersionID? {
        guard let record = library.record(id) else {
            note(.session, "That record is not in the library any more")
            return nil
        }
        if let existing = song.versions.last(where: { Guidance.audio(of: $0)?.media == record.media && Guidance.audio(of: $0)?.role == .take }) {
            note(.session, "\(record.title) is already in \(song.title)")
            return existing.id
        }
        guard let store, let url = try? store.mediaURL(for: record.media), let info = try? AudioFileInfo.read(url) else {
            note(.session, "\(record.title)'s audio is missing from the library")
            return nil
        }
        let seed = Seed(kind: .importedRecord(record.id), note: "adopted from the library")
        var versions: [PartVersion] = []
        if let analysis = record.analysis {
            versions.append(PartVersion(partID: PartID(), kind: analysis.kind, author: .user, operation: Operation.adopted,
                                        note: "analysis of \(record.title)", origin: seed.id))
        }
        let take = Audio(media: record.media, role: .take, stem: nil, sampleRate: info.sampleRate,
                         channelCount: info.channelCount, duration: info.duration)
        let takeVersion = PartVersion(partID: PartID(), kind: .audio(take), author: .user, operation: Operation.adopted,
                                      note: "\(record.title), from the library", origin: seed.id)
        versions.append(takeVersion)
        updateSong { $0.seeds.append(seed) }
        for version in versions { guard self.record(version) else { return nil } }
        return takeVersion.id
    }

    /// What a drop does: adopt, then whatever the target implies.
    @discardableResult
    public func receive(_ payload: LibraryDragPayload, at drop: LibraryDrop) -> Bool {
        switch payload.kind {
        case .song:
            openSong(SongID(rawValue: payload.id))
            return true
        case .album:
            return openAlbum(AlbumID(rawValue: payload.id)) != nil
        case .stem:
            var section: SectionID?
            if case .section(let id) = drop { section = id }
            askForSource(AskedSource(origin: .record(RecordID(rawValue: payload.id)), stem: payload.stem, section: section))
            return song != nil
        case .idea, .sample, .record:
            break
        }
        // A drop aimed at a section places the part itself, below; anywhere else, adopting a part
        // puts it in the song the way making one does.
        let aimed = if case .section = drop { true } else { false }
        guard let id = adopt(payload, joiningForm: !aimed), let song, let version = song.version(id)
        else { return false }
        switch drop {
        case .ledger:
            return true
        case .bench:
            if payload.kind == .record {
                // A record on the bench is there to be chopped: the same path the path strip takes.
                let action = SurfaceAction(surface: .chopLane, title: "Bar of \(payload.title)", prepare: .chopBar(of: id))
                if canPerform(action) { perform(action) } else { perform(SurfaceAction(surface: .importRecord, title: song.title, bound: [id])) }
            } else if let primary = PartActions.primary(for: version, in: song), canPerform(primary.action) {
                perform(primary.action)
            }
            return true
        case .section(let sectionID):
            var sections = song.sections
            guard let index = sections.firstIndex(where: { $0.id == sectionID }) else { return true }
            guard StructureModel.plays(version) else {
                note(.session, "\(PartLabel.title(of: version)) does not play on the transport, so it was adopted but not stitched",
                     detail: version.type == .sample ? "The chop has no slices to play." : nil)
                return true
            }
            sections[index].stitch.append(Lane(part: version.partID))
            return arrange(sections)
        }
    }

    // MARK: Records, again

    /// A new song from a record already in the library: its analysis, its take and its stems,
    /// referenced where they already are in `records/`, and no re-import.
    @discardableResult
    public func flipAgain(_ id: RecordID) -> Bool {
        guard let record = library.record(id) else {
            note(.session, "That record is not in the library any more")
            return false
        }
        guard let store, let url = try? store.mediaURL(for: record.media), let info = try? AudioFileInfo.read(url) else {
            note(.session, "\(record.title)'s audio is missing from the library")
            return false
        }
        var analysis: MusicAnalysis?
        if let version = record.analysis, case .analysis(let a) = version.kind { analysis = a }
        let flips = library.songs.filter { song in song.seeds.contains { if case .importedRecord(id) = $0.kind { return true }; return false } }.count
        let seed = Seed(kind: .importedRecord(record.id), note: "flipped again from the library")
        var song = Song(title: flips == 0 ? record.title : "\(record.title) flip \(flips + 1)", artist: record.artist,
                        key: analysis?.dominantKey, tempo: analysis?.dominantTempo ?? 120)
        song.seeds.append(seed)
        if let analysis {
            try? song.append(PartVersion(partID: PartID(), kind: .analysis(analysis), author: .user, operation: Operation.imported,
                                         note: "analysis of \(record.title)", origin: seed.id))
        }
        let take = Audio(media: record.media, role: .take, stem: nil, sampleRate: info.sampleRate,
                         channelCount: info.channelCount, duration: info.duration)
        let takeVersion = PartVersion(partID: PartID(), kind: .audio(take), author: .user, operation: Operation.imported,
                                      note: "the record, from the library", origin: seed.id)
        try? song.append(takeVersion)
        // Its stems as the crate keeps them, the same files every song takes from: a song started
        // from a separated record is a song with its stems, as an import with them is.
        for stem in record.stems ?? [] {
            let audio = Audio(media: stem.media, role: .stem, stem: stem.name, sampleRate: stem.sampleRate,
                              channelCount: stem.channelCount, duration: stem.duration)
            try? song.append(PartVersion(partID: PartID(), kind: .audio(audio), author: .user, parents: [takeVersion.id],
                                         operation: Operation.separate, note: "\(stem.name) stem of \(record.title), from the crate",
                                         origin: seed.id))
        }
        open(song)
        return true
    }

    // MARK: Albums

    @discardableResult
    public func createAlbum(title: String, artist: String = "") -> AlbumID? {
        let album = Album(title: title.isEmpty ? "Untitled album" : title, artist: artist)
        var updated = library
        updated.albums.append(album)
        guard writeLibrary(updated) else { return nil }
        note(.you, "New album: \(album.title)")
        return album.id
    }

    @discardableResult
    public func renameAlbum(_ id: AlbumID, to title: String) -> Bool {
        updateAlbum(id) { $0.title = title.isEmpty ? $0.title : title }
    }

    // M7: the record.

    @discardableResult
    public func setGap(_ seconds: Double, before songID: SongID, in id: AlbumID) -> Bool {
        updateAlbum(id) { $0.gaps[songID] = max(0, min(30, seconds)) }
    }

    @discardableResult
    public func setNotes(_ notes: String, for id: AlbumID) -> Bool {
        updateAlbum(id) { $0.notes = notes }
    }

    @discardableResult
    public func setCover(_ design: CoverDesign, for id: AlbumID) -> Bool {
        updateAlbum(id) { $0.cover = .drawn(design) }
    }

    /// An image file becomes the cover, copied into the library's ideas media.
    @discardableResult
    public func setCover(imageAt url: URL, for id: AlbumID) -> Bool {
        guard let store else { return false }
        do {
            let media = try store.addMedia(copying: url, kind: .idea)
            return updateAlbum(id) { $0.cover = .image(media) }
        } catch {
            note(.session, "Could not copy the cover into the library", detail: "\(error)")
            return false
        }
    }

    /// The order and the gaps in one move, with a note in the rail.
    @discardableResult
    public func sequence(_ order: [SongID], gaps: [SongID: Double]? = nil, in id: AlbumID, because: String? = nil,
                         by source: SessionEntry.Source = .you) -> Bool {
        guard let album = library.album(id), Set(order) == Set(album.songs), order.count == album.songs.count else {
            note(.session, "That order does not name every song on the album once")
            return false
        }
        let done = updateAlbum(id) { album in
            album.songs = order
            if let gaps { for (song, gap) in gaps { album.gaps[song] = max(0, min(30, gap)) } }
        }
        if done { note(source, "Sequenced \(album.title)", detail: because ?? order.compactMap { library.song($0)?.title }.joined(separator: " → ")) }
        return done
    }

    func recordReleases(_ releases: [SongID: TrackRelease], for id: AlbumID) {
        updateAlbum(id) { album in for (song, release) in releases { album.releases[song] = release } }
    }

    /// The album, read: its tracks from the library (the open song as it is now).
    public func observe(album: Album) -> AlbumObservation {
        var songs = library.songs
        if let song, let index = songs.firstIndex(where: { $0.id == song.id }) { songs[index] = song } else if let song { songs.append(song) }
        return AlbumObservation.of(album, songs: songs)
    }

    /// Adds a song to an album's sequence, once.
    @discardableResult
    public func addSong(_ songID: SongID, to albumID: AlbumID) -> Bool {
        guard library.song(songID) != nil || song?.id == songID else {
            note(.session, "That song is not in the library")
            return false
        }
        // The open song, never saved, is saved as it joins: an album of songs the library does not
        // hold loses the track the moment another song is opened, and cannot release it.
        if song?.id == songID, library.song(songID) == nil, store != nil { save() }
        return updateAlbum(albumID) { album in
            guard !album.songs.contains(songID) else { return }
            album.songs.append(songID)
        }
    }

    @discardableResult
    public func removeSong(_ songID: SongID, from albumID: AlbumID) -> Bool {
        updateAlbum(albumID) { $0.songs.removeAll { $0 == songID } }
    }

    /// Moves a song so that it lands at `index` in the album's sequence.
    @discardableResult
    public func moveSong(_ songID: SongID, in albumID: AlbumID, to index: Int) -> Bool {
        updateAlbum(albumID) { album in
            guard let from = album.songs.firstIndex(of: songID) else { return }
            let moved = album.songs.remove(at: from)
            album.songs.insert(moved, at: max(0, min(index, album.songs.count)))
        }
    }

    /// Records a clearance state for one source in an album.
    @discardableResult
    public func setClearance(_ status: ClearanceStatus, forSource source: String, record: RecordID?,
                             media: MediaRef? = nil, in albumID: AlbumID) -> Bool {
        updateAlbum(albumID) { album in
            if let index = album.clearances.firstIndex(where: { $0.matches(source: source, record: record, media: media) }) {
                album.clearances[index].status = status
                if album.clearances[index].media == nil { album.clearances[index].media = media }
            } else {
                album.clearances.append(SampleClearance(source: source, status: status, record: record, media: media))
            }
        }
    }

    private func updateAlbum(_ id: AlbumID, _ change: (inout Album) -> Void) -> Bool {
        guard var album = library.album(id) else {
            note(.session, "That album is not in the library any more")
            return false
        }
        change(&album)
        var updated = library
        updated.upsert(album)
        return writeLibrary(updated)
    }

    /// Every source of every sample in the album's songs, with its clearance state — the stored one,
    /// or *uncleared* until someone says otherwise.
    public func sources(of album: Album) -> [SampleClearance] {
        var out: [SampleClearance] = []
        var seen = Set<String>()
        // Keyed by the record when there is one — still, when the record has since left the
        // library — else by the media. Keyed by the name, a source reverted to "uncleared" when
        // its record was removed or its song renamed.
        func add(_ source: String, record: RecordID?, media: MediaRef? = nil) {
            let key = record?.description ?? media.map { "media:\($0.hash)" } ?? source
            guard seen.insert(key).inserted else { return }
            if var stored = album.clearances.first(where: { $0.matches(source: source, record: record, media: media) }) {
                stored.source = source
                stored.media = stored.media ?? media
                out.append(stored)
            } else {
                out.append(SampleClearance(source: source, status: .uncleared, record: record, media: media))
            }
        }
        func named(_ id: RecordID?) -> String? {
            guard let id else { return nil }
            if let record = library.record(id) { return record.artist.isEmpty ? record.title : "\(record.artist) – \(record.title)" }
            return album.clearances.first { $0.record == id }?.source
        }
        for songID in album.songs {
            guard let song = (self.song?.id == songID ? self.song : nil) ?? library.song(songID) else { continue }
            for version in song.versions {
                // A mashup's stems name the record they came out of.
                if case .audio(let audio) = version.kind, let id = audio.sourceRecord {
                    add(named(id) ?? "\(PartLabel.title(of: version)) in \(song.title)", record: id)
                    continue
                }
                guard case .sample(let sample) = version.kind else { continue }
                if let id = sample.sourceRecord ?? library.record(forMedia: sample.media)?.id {
                    add(named(id) ?? "\(PartLabel.title(of: version)) in \(song.title)", record: id)
                } else {
                    add("\(PartLabel.title(of: version)) in \(song.title)", record: nil, media: sample.media)
                }
            }
        }
        return out
    }

    /// Opens the Album surface on an album, reusing one already open on it.
    @discardableResult
    public func openAlbum(_ id: AlbumID) -> SurfaceID? {
        guard let album = library.album(id) else {
            note(.session, "That album is not in the library any more")
            return nil
        }
        if let existing = albumBindings.first(where: { $0.value == id })?.key, bench.items.contains(where: { $0.id == existing }) {
            focusSurface(existing)
            return existing
        }
        let surface = openSurface(.album, title: album.title)
        albumBindings[surface] = id
        return surface
    }

    public func album(for surface: SurfaceID) -> Album? { albumBindings[surface].flatMap { library.album($0) } }

    // MARK: The house voice

    /// The lyrics this house has written, as the Lyricist reads them.
    public var voice: LyricCorpus { LyricCorpus(library.voice ?? []) }

    /// Reads lyrics out of a file — the house's markdown, or plain text with a title line per
    /// block — and keeps them as the library's voice. Replaces the lot, so importing twice is not
    /// sixty songs.
    @discardableResult
    public func importVoice(from url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            note(.session, "Could not read \(url.lastPathComponent)")
            return 0
        }
        let lyrics = LyricCorpus.parse(markdown: text, source: url.lastPathComponent)
        guard !lyrics.isEmpty else {
            note(.session, "No lyrics found in \(url.lastPathComponent)",
                 detail: "The house's markdown has ### headings with fenced blocks; plain text has a title line per blank-line-separated block.")
            return 0
        }
        var updated = library
        updated.voice = lyrics
        guard writeLibrary(updated) else { return 0 }
        note(.you, "Imported the house voice: \(lyrics.count) lyric\(lyrics.count == 1 ? "" : "s")", detail: url.lastPathComponent)
        return lyrics.count
    }

    // MARK: The cast

    /// Who is in the room for the open song. Empty means everyone the app has.
    public var castInRoom: Cast { Cast.standard.inRoom(for: song) }

    /// Sets the song's cast. An empty list is "everyone". Not a version: the cast is the song's
    /// setting, like its sections.
    @discardableResult
    public func setCast(_ ids: [PersonaID], by source: SessionEntry.Source = .you) -> Bool {
        guard let song else {
            note(.session, "No song open to cast")
            return false
        }
        let cleaned = ids.map(\.rawValue)
        guard cleaned != (song.cast ?? []) else { return true }
        updateSong { $0.cast = cleaned.isEmpty ? nil : cleaned }
        let names = cleaned.compactMap { Cast.standard.persona(PersonaID($0))?.bible.name }
        note(source, cleaned.isEmpty ? "Everyone is in the room" : "Cast: \(names.joined(separator: ", "))")
        return true
    }

    /// The house calls in force for the open song: the library's, with the song's own over them.
    public var houseBook: HouseBook { HouseBook.of(library, song: song) }

    /// Records what this house decided on one of the cast's open questions: in the library, for
    /// every song from now on. With `onlyThisSong` it is kept with the open song instead, as an
    /// exception; otherwise any exception the open song had on the question is cleared, so what
    /// was just chosen is what plays here too.
    @discardableResult
    public func recordHouseCall(question: String, choice: HouseCall.Choice, how: String, onlyThisSong: Bool = false) -> Bool {
        let record = HouseCallRecord(question: question, choice: choice.rawValue, how: how,
                                     decidedOn: ISO8601DateFormatter().string(from: Date()).prefix(10).description)
        if onlyThisSong {
            guard song != nil else { return false }
            updateSong { song in
                var calls = song.houseCalls ?? []
                calls.removeAll { $0.question == question }
                calls.append(record)
                song.houseCalls = calls
            }
            note(.you, "House call, this song only: \(question) → \(choice.rawValue)", detail: how)
            return true
        }
        var updated = library
        var calls = updated.houseCalls ?? []
        calls.removeAll { $0.question == question }
        calls.append(record)
        updated.houseCalls = calls
        guard writeLibrary(updated) else { return false }
        if let own = song?.houseCalls, own.contains(where: { $0.question == question }) {
            updateSong { song in
                song.houseCalls?.removeAll { $0.question == question }
                if song.houseCalls?.isEmpty == true { song.houseCalls = nil }
            }
        }
        note(.you, "House call, every song: \(question) → \(choice.rawValue)", detail: how)
        return true
    }

    // MARK: The genre

    /// The open song's genre: the one it was given, or the one its grooves point to.
    public var genre: GenreBook.Reading? { GenreBook.standard.genre(of: song) }

    /// Places the open song in a genre, by a profile's id, name or alias; nil or "" to leave it to
    /// be guessed again; "none" for no genre at all, the band judging by its own numbers. False when
    /// no song is open or no profile answers to the name.
    @discardableResult
    public func setGenre(_ name: String?, by source: SessionEntry.Source = .you) -> Bool {
        guard song != nil else { return false }
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let none = trimmed.lowercased() == GenreBook.none
        let profile = trimmed.isEmpty || none ? nil : GenreBook.standard.profile(named: trimmed)
        guard trimmed.isEmpty || none || profile != nil else { return false }
        let stored = none ? GenreBook.none : profile?.id
        guard stored != song?.genre else { return true }
        updateSong { $0.genre = stored }
        SurfaceWiring.shared.genreChanged()
        note(source, profile.map { "Genre: \($0.name)" } ?? (none ? "Genre: none — the band's own numbers" : "Genre: guessed from the grooves again"),
             detail: profile?.summary)
        return true
    }

    // MARK: What the band has said

    /// Replaces the library's record of what the band has said, and writes it when there is
    /// somewhere to. Quiet either way: a log is not worth a line in the rail, and a session with no
    /// library still remembers for as long as it runs.
    func keepSaid(_ records: [SaidRecord]) {
        var updated = library
        updated.said = records
        if let store, libraryIsWritable, (try? store.saveDocument(updated)) != nil {
            library = updated
        } else {
            library.said = records
        }
    }

    // MARK: Helpers

    /// Writes `library.json` and keeps the in-memory library in step. False, with the reason in the
    /// rail, when there is no store or the write failed.
    @discardableResult
    func writeLibrary(_ updated: Library) -> Bool {
        guard let store else {
            note(.session, "Nowhere to save the library", detail: "This session has no library directory.")
            return false
        }
        guard libraryIsWritable else {
            note(.session, "The library could not be read, so nothing is written to it",
                 detail: "Move aside what it names, then Reload Library.")
            return false
        }
        do {
            try store.saveDocument(updated)
            library = updated
            libraryStatus = .loaded(store.directoryURL)
            return true
        } catch {
            note(.session, "Could not write the library", detail: "\(error)")
            return false
        }
    }

    private func copyMedia(of version: PartVersion, from songID: SongID, into kind: LibraryStore.MediaKind,
                           store: LibraryStore) throws {
        for media in version.mediaReferences {
            let url = try store.mediaURL(for: media, song: songID)
            try store.addMedia(copying: url, kind: kind)
        }
    }

    /// Copies a library item's media into the open song's package, so the song keeps playing with
    /// the library gone. False, with the reason in the rail, when the media cannot be found.
    private func copyMediaIntoPackage(of version: PartVersion, song: Song) -> Bool {
        guard !version.mediaReferences.isEmpty else { return true }
        guard let store else { return true }
        do {
            let package = try store.songStore(for: song.id)
            for media in version.mediaReferences where !package.hasMedia(media) {
                let url = try store.mediaURL(for: media)
                try package.addMedia(copying: url)
            }
            return true
        } catch {
            // A song not yet saved has no package; its media resolves through the library until it is.
            if (try? store.songStore(for: song.id)) == nil { return true }
            note(.session, "Could not copy the audio into \(song.title)", detail: "\(error)")
            return false
        }
    }
}

// MARK: - From an idea

extension AppState {
    /// A song from nothing but an idea. An open song that holds nothing yet is set up in place;
    /// otherwise the open one is saved and a new one opened. The drum machine is a sound part, so
    /// the transport, the Grid and a controller all play the beat on it.
    @discardableResult
    public func startSong(title: String, tempo requested: Double, key: Key?, machine: String) -> Song? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // The frame's range, as the settings hold a tempo to: a thousand bpm used to be accepted.
        let tempo = requested.isFinite ? min(Self.tempoRange.upperBound, max(Self.tempoRange.lowerBound, requested)) : 120
        // A song that holds only a drum machine is still a blank sketch: changing your mind about
        // the tempo should not leave a trail of empty songs behind.
        if let open = song, open.versions.allSatisfy({ $0.type == .sound }) {
            updateSong { song in
                if !name.isEmpty { song.title = name }
                song.tempo = tempo
                song.key = key
            }
        } else {
            if hasUnsavedChanges { save() }
            // The band's own move: a switch it made must not cancel the turn that asked for it.
            open(Song.new(title: name.isEmpty ? "Untitled" : name, key: key, tempo: tempo), by: .director)
        }
        record(PartVersion(partID: PartID(), kind: .sound(Sound(instrument: machine)), author: .persona("Director"),
                           operation: Operation.written, note: "The drum machine for this song"))
        return song
    }
}

extension AppState {
    /// Saves the open song when it has unsaved work and there is a library to keep it in. Quiet
    /// when there is nothing to do, so it can be called on every landed turn and on the way out.
    public func saveIfNeeded() {
        guard hasUnsavedChanges, store != nil, song != nil else { return }
        save()
    }
}

extension AppState {
    /// The pitched instrument a part plays on, or the song's when no part is named: what chords and
    /// melodies sound through. Recorded as a `.sound` part, the same way the drum machine is, so the
    /// choice travels with the song and shows in the ledger. A preset the app does not know is
    /// ignored rather than recorded, and picking what is already playing records nothing.
    /// The drum machine a groove part plays on, or the song's when no part is named — the way
    /// `setInstrument` does it for chords and tunes, as one `.sound` part a pick at a time.
    @discardableResult
    public func setMachine(_ id: String, for part: PartID? = nil, by author: Author = .user) -> Bool {
        guard let machine = SynthMachine.preset(id: id), let song else { return false }
        // A variation plays on the drums of the part it varies: a pick made on one is that part's.
        let part = part.map(song.strip(of:))
        // Against what the part is heard on, not the machine it last picked: a groove playing on a
        // chop is moved back to its old machine by picking that machine again.
        guard SongPlayback.drumSoundID(for: part, in: song) != machine.id else { return false }
        let name = part.flatMap { id in song.versions.last { $0.partID == id } }.map(PartLabel.title(of:))
        let note = name.map { "\(machine.name) for \($0)" } ?? "\(machine.name) for the drums"
        return recordDrumSound(machine.id, for: part, note: note, by: author)
    }

    /// Puts a groove part's steps on a chop's own slices, the way the Chop lane re-grooved them,
    /// instead of on a machine. Recorded as a pick, the same as a machine, so picking a machine
    /// afterwards takes it back off.
    @discardableResult
    public func setChop(_ chop: PartID, for part: PartID, by author: Author = .user) -> Bool {
        guard let song, song.versions.contains(where: { $0.partID == chop && $0.type == .sample }) else { return false }
        let part = song.strip(of: part)
        let id = ChopSound.id(for: chop)
        guard SongPlayback.drumSoundID(for: part, in: song) != id else { return false }
        let chopName = song.versions.last { $0.partID == chop }.map(PartLabel.title(of:)) ?? "the chop"
        let name = song.versions.last { $0.partID == part }.map(PartLabel.title(of:)) ?? "the groove"
        return recordDrumSound(id, for: part, note: "\(chopName)'s slices for \(name)", by: author)
    }

    /// One pick is one part: a groove's next choice of drums, machine or chop, is a version of its
    /// last one.
    private func recordDrumSound(_ id: String, for part: PartID?, note: String, by author: Author) -> Bool {
        guard let song else { return false }
        let kind = PartKind.sound(Sound(instrument: id, forPart: part))
        if let previous = song.versions.last(where: { version in
            if case .sound(let sound) = version.kind, sound.forPart == part { return SongPlayback.isDrumSound(sound.instrument) }
            return false
        }) {
            return record(previous.deriving(kind, by: author, operation: Operation.written, note: note))
        }
        return record(PartVersion(partID: PartID(), kind: kind, author: author, operation: Operation.written, note: note))
    }

    /// A groove made from a chop, heard where the chop was: played on the chop's slices, and put in
    /// the chop's place in every section that played it (`sections(of:playing:inPlaceOf:)`).
    ///
    /// - Returns: the names of the sections the groove took over.
    @discardableResult
    public func playGroove(_ groove: PartID, onChop chop: PartID, by author: Author = .user,
                           source: SessionEntry.Source = .you) -> [String] {
        setChop(chop, for: groove, by: author)
        guard let song, !song.sections.isEmpty else { return [] }
        let swapped = Self.sections(of: song, playing: groove, inPlaceOf: chop)
        if !swapped.took.isEmpty { arrange(swapped.sections, by: source) }
        return swapped.took
    }

    /// The form with `groove` in the chop's place in every section that played the chop. The looped
    /// bar stays out, since under its own re-groove it would play the same drums twice. Any other
    /// groove in those sections goes too, the way a second part of a kind is used instead of the
    /// first rather than stacked on it.
    nonisolated static func sections(of song: Song, playing groove: PartID,
                                     inPlaceOf chop: PartID) -> (sections: [Section], took: [String]) {
        var took: [String] = []
        let onChop = ChopSound.id(for: chop)
        // The chop's place: its loop, or a groove made from it before this one — a second feel tried
        // on the same bar replaces the first, as a second groove from the Grid would.
        func holdsChop(_ lane: Lane) -> Bool {
            lane.part == chop || (lane.part != groove && SongPlayback.drumSoundID(for: lane.part, in: song) == onChop
                                  && song.versions.last { $0.partID == lane.part }?.type == .groove)
        }
        let sections = song.sections.map { section -> Section in
            guard let at = section.stitch.firstIndex(where: holdsChop) else { return section }
            var section = section
            section.stitch[at] = Lane(part: groove)
            section.stitch.removeAll { lane in
                lane.part == chop
                    || (lane.part != groove && song.versions.last { $0.partID == lane.part }?.type == .groove)
            }
            // The groove may already have been in the stitch, joined when it was recorded.
            var seen = false
            section.stitch.removeAll { lane in
                guard lane.part == groove else { return false }
                defer { seen = true }
                return seen
            }
            took.append(section.name)
            return section
        }
        return (sections, took)
    }

    /// Drums under a groove that plays a chop's slices: the same pattern as a groove of its own,
    /// on the song's drum machine, in every section that plays the first. The slices keep playing.
    /// The two are two chips in Structure and two strips in the mix, so either is heard alone.
    ///
    /// A groove on a chop is the chop in a rhythm. Cut from a stem with no drums in it, it was the
    /// only thing in the song called a groove, and "the beat" was the strings again.
    ///
    /// - Returns: the drums' part, or nil when `groove` is not a groove on a chop.
    @discardableResult
    public func addDrums(under groove: PartID, by author: Author = .user,
                         source: SessionEntry.Source = .you) -> PartID? {
        guard let song else { return nil }
        // A variation of the groove is the same player: the drums go under the part it varies.
        let root = song.strip(of: groove)
        guard let version = song.latestVersion(of: root), case .groove(let pattern) = version.kind,
              let chop = SongPlayback.chop(under: root, in: song) else { return nil }
        let family = song.family(of: root)
        // Drums made for it before are put back rather than made again.
        let ours = Set(song.versions.filter { $0.partID == root }.map(\.id))
        let made = song.partIDs.first { part in
            guard !family.contains(part), !song.isVariation(part), SongPlayback.chop(under: part, in: song) == nil,
                  song.latestVersion(of: part)?.type == .groove else { return false }
            return song.versions.contains { $0.partID == part && !ours.isDisjoint(with: $0.parents) }
        }
        let machine = SongPlayback.machine(in: song)
        let title = PartLabel.title(of: version)
        let suffix = " on \(PartLabel.title(of: chop))"
        let name = title.hasSuffix(suffix) ? "\(title.dropLast(suffix.count)) drums" : "Drums under \(title)"
        let drums = made.flatMap(song.latestVersion(of:))
            ?? version.spawning(.groove(pattern), by: author, operation: Operation.written, note: name)
        var took: [String] = []
        let sections = song.sections.map { section -> Section in
            guard !section.stitch.contains(part: drums.partID),
                  let at = section.stitch.lastIndex(where: { family.contains($0.part) }) else { return section }
            var section = section
            section.stitch.insert(Lane(part: drums.partID), at: at + 1)
            took.append(section.name)
            return section
        }
        guard keep(made == nil ? [drums] : [], arranged: sections) else { return nil }
        note(source, took.isEmpty ? "\(PartLabel.title(of: drums)) is in the song" : "\(PartLabel.title(of: drums)) plays in \(Self.listed(took))",
             detail: "The same pattern on the \(machine.name), beside \(PartLabel.title(of: chop))'s slices. "
                 + "Each has its own chip in Structure and its own strip in the Mixer.")
        return drums.partID
    }

    @discardableResult
    public func setInstrument(_ id: String, for part: PartID? = nil, by author: Author = .user) -> Bool {
        guard let spec = InstrumentVoiceSpec.preset(id: id), let song else { return false }
        // A variation plays on the instrument of the part it varies, so a pick made on one is
        // that part's pick.
        let part = part.map(song.strip(of:))
        guard SongPlayback.instrumentID(for: part, in: song) != spec.id else { return false }
        let name = part.flatMap { id in song.versions.last { $0.partID == id } }.map(PartLabel.title(of:))
        let note = name.map { "\(spec.name) for \($0)" } ?? "\(spec.name) for the chords and the tune"
        // One pick is one part: the next choice is a version of it, not a part of its own. The
        // picker used to make a fresh part on every click, so trying five presets to hear them
        // left five "Kit" rows in the ledger, each with one version.
        if let previous = song.versions.last(where: { version in
            if case .sound(let sound) = version.kind, sound.forPart == part { return InstrumentVoiceSpec.preset(id: sound.instrument) != nil }
            return false
        }) {
            return record(previous.deriving(.sound(Sound(instrument: spec.id, forPart: part)), by: author,
                                            operation: Operation.written, note: note))
        }
        return record(PartVersion(partID: PartID(),
                                  kind: .sound(Sound(instrument: spec.id, forPart: part)), author: author,
                                  operation: Operation.written, note: note))
    }
}

extension AppState {
    /// A file copied into the open song's package, for a version to point at. A song never saved
    /// is saved first, so it has a package to keep it in. Nil, with the reason in the rail, when
    /// there is nowhere to keep it. The Booth keeps its takes this way, and the band its comps.
    public func keepMedia(copying url: URL, what: String = "the audio") -> MediaRef? {
        guard let song else { return nil }
        guard let store else {
            note(.session, "There is no library to keep \(what) in")
            return nil
        }
        do {
            if (try? store.songStore(for: song.id)) == nil { save() }
            return try store.songStore(for: song.id).addMedia(copying: url)
        } catch {
            note(.session, "Could not keep \(what)", detail: "\(error)")
            return nil
        }
    }

    /// Rendered audio — a comp, a bounce — written out and kept the same way.
    public func keepAudio(_ planar: [[Float]], sampleRate: Double, what: String = "the audio") -> MediaRef? {
        guard song != nil else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MrRoboto-kept-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try BoothAdapter.write(planar, sampleRate: sampleRate, to: url)
        } catch {
            note(.session, "Could not render \(what)", detail: "\(error)")
            return nil
        }
        return keepMedia(copying: url, what: what)
    }
}

// MARK: - Favourites and tags

extension LibraryItemID {
    /// What `library.json` calls this kind of item in a mark.
    var markKind: LibraryMark.Kind {
        switch shelf {
        case .songs: .song
        case .records: .record
        case .ideas: .idea
        case .samples: .sample
        case .albums: .album
        }
    }
}

extension AppState {
    /// The mark on an item: a favourite, tags, both, or nil.
    public func mark(of item: LibraryItemID) -> LibraryMark? { library.mark(item.markKind, item.id) }

    /// Marks the items favourites, or not, in one write of `library.json`. Nothing in a song moves.
    @discardableResult
    public func setFavourite(_ on: Bool, for items: [LibraryItemID]) -> Bool {
        changeMarks(of: items) { $0.favourite = on ? true : nil }
    }

    /// Tags the items, in one write. A tag is trimmed, and one that differs only in case from a tag
    /// already on the item is that tag.
    @discardableResult
    public func addTag(_ tag: String, to items: [LibraryItemID]) -> Bool {
        let tag = tag.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !tag.isEmpty else { return false }
        return changeMarks(of: items) { mark in
            var tags = mark.tags ?? []
            if !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { tags.append(tag) }
            mark.tags = tags
        }
    }

    /// Takes a tag off the items, in one write.
    @discardableResult
    public func removeTag(_ tag: String, from items: [LibraryItemID]) -> Bool {
        changeMarks(of: items) { mark in
            let tags = (mark.tags ?? []).filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
            mark.tags = tags.isEmpty ? nil : tags
        }
    }

    /// Every tag in the library, in the order first used.
    public var allTags: [String] {
        LibraryIndex.unique((library.marks ?? []).flatMap { $0.tags ?? [] })
    }

    private func changeMarks(of items: [LibraryItemID], _ change: (inout LibraryMark) -> Void) -> Bool {
        guard !items.isEmpty else { return false }
        var updated = library
        for item in items {
            var mark = updated.mark(item.markKind, item.id) ?? LibraryMark(kind: item.markKind, id: item.id)
            change(&mark)
            updated.setMark(mark)
        }
        guard updated.marks != library.marks else { return true }
        return writeLibrary(updated)
    }
}
