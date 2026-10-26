import Foundation
import Instrument
import MusicTheory
import SongGraph

// Ideas from elsewhere (ideas-first, Phase 3): a part kept out of a song, a capture from the phone,
// and an idea kept before ideas could be opened each become an idea of their own — a package with
// a tempo, a key and bars, opened and worked on as a song is. The bare part versions in
// `Library.ideas` stay readable, and become packages the first time each is opened.

extension Song {
    /// The phone capture an idea was started from, while its tempo, key and bars wait for the crate
    /// to read it. Nil once they are read, or once someone has chosen them (`gridChosen`).
    public var captureAwaitingReading: MediaRef? {
        guard isIdea, gridChosen != true else { return nil }
        for seed in seeds {
            if case .hummedTake(let media) = seed.kind { return media }
        }
        return nil
    }
}

extension AppState {

    // MARK: A part of a song, kept as an idea

    /// Whether a version is music on its own, to keep as an idea. A mix, a sound or a reading is a
    /// setting of the song it is in.
    nonisolated static func keepsAsIdea(_ version: PartVersion) -> Bool {
        switch version.kind {
        case .mix, .sound, .analysis: false
        default: true
        }
    }

    /// Keeps a part of the open song as an idea of its own: the part at the song's tempo, key and
    /// meter, as long as the longest section it plays in, on the instrument it plays on, its audio
    /// copied. The song is not touched, and stays open.
    @discardableResult
    public func keepAsIdea(_ id: VersionID) -> SongID? {
        guard let song, let version = song.version(id) else {
            note(.session, "Nothing to keep", detail: "That version is not in the open song.")
            return nil
        }
        guard Self.keepsAsIdea(version) else {
            note(.session, "\(PartLabel.title(of: version)) is not an idea on its own",
                 detail: "A mix, a sound or a reading belongs to the song it is set in. Keep a part that plays.")
            return nil
        }
        let name = PartLabel.title(of: version)
        let idea = Self.idea(keeping: version, from: song, title: "\(name) from \(song.title)")
        guard keepIdeaPackage(idea, mediaFrom: song.id) else { return nil }
        note(.you, "Kept \(name) as an idea",
             detail: "\(idea.title): \(Self.ideaLine(idea)). It is on the Ideas shelf, to open and work on with no song around it.")
        return idea.id
    }

    /// The idea one version of `song` makes: the song's grid, the part on its own — a new part,
    /// with no parents, its note as it was — and what it sounds on when that is not an idea's own.
    static func idea(keeping version: PartVersion, from song: Song, title: String) -> Song {
        var idea = Song.newIdea(title: title, key: song.key, tempo: song.tempo, timeSignature: song.timeSignature,
                                bars: ideaBars(holding: version, in: song))
        idea.gridChosen = true
        idea.genre = song.genre
        var kind = version.kind
        if case .audio(var audio) = kind {
            // Sung: placed by its take or comp — its own, or the one it was corrected from — and
            // moved from the section it was sung to onto the idea's one, so the bar it was sung on
            // in that section is the bar it is on in the idea.
            if audio.take == nil, audio.comp == nil, let placed = TakePlacement.audio(of: version, in: song) {
                audio.take = placed.take
                audio.comp = placed.comp
            }
            let section = idea.sections[0].id
            if var take = audio.take, let sung = take.section {
                take.sectionStartBar = take.sectionStartBar ?? song.startBar(of: sung)
                take.section = section
                audio.take = take
            }
            if var comp = audio.comp, let sung = comp.section {
                comp.sectionStartBar = comp.sectionStartBar ?? song.startBar(of: sung)
                comp.section = section
                audio.comp = comp
            }
            kind = .audio(audio)
        }
        let kept = PartVersion(partID: PartID(), kind: kind, author: version.author, operation: version.operation, note: version.note)
        try? idea.append(kept)
        _ = joinForm(with: kept, in: &idea)
        if let sound = soundCarried(by: version, from: song) {
            let named = InstrumentVoiceSpec.preset(id: sound)?.name ?? SynthMachine.preset(id: sound)?.name ?? sound
            try? idea.append(PartVersion(partID: PartID(), kind: .sound(Sound(instrument: sound, forPart: kept.partID)),
                                         author: version.author, operation: Operation.written,
                                         note: "\(named) for \(PartLabel.title(of: kept))"))
        }
        return idea
    }

    /// How long an idea of one part of `song` is: the longest section the part plays in — stitched
    /// there, or sung to it — else the part's own length, else an idea's starting four bars.
    static func ideaBars(holding version: PartVersion, in song: Song) -> Int {
        let audio = TakePlacement.audio(of: version, in: song) ?? Guidance.audio(of: version)
        let sungTo = audio?.take?.section ?? audio?.comp?.section
        let lengths = song.sections.filter { $0.id == sungTo || $0.stitch.contains(part: version.partID) }.map(\.lengthInBars)
        let bars = lengths.max() ?? song.bars(holding: version) ?? Song.startingIdeaBars
        return min(ideaBarsRange.upperBound, max(ideaBarsRange.lowerBound, bars))
    }

    /// What a written part sounds on in `song`, when that is not what it would sound on in an idea
    /// of its own: its own pick, or the song's. A groove on a chop's slices goes on the machine the
    /// song had, since the chop stays in the song.
    static func soundCarried(by version: PartVersion, from song: Song) -> String? {
        switch version.type {
        case .progression, .melody:
            let id = SongPlayback.instrumentID(for: version.partID, in: song)
            return id == InstrumentVoiceSpec.rhodes.id ? nil : id
        case .groove:
            let id = SongPlayback.machineID(for: song.strip(of: version.partID), in: song)
            return id == SynthMachine.tr808.id ? nil : id
        default:
            return nil
        }
    }

    // MARK: A capture from the phone

    /// The idea a capture makes: the audio as the idea's record, waiting for the crate's reading
    /// for its tempo, key and bars (`captureAwaitingReading`), at the starting tempo until then.
    static func captureIdea(title: String, media: MediaRef, sampleRate: Double, channelCount: Int, duration: Double,
                            note: String?, createdAt: Date = Date()) -> Song {
        var idea = Song.newIdea(title: title)
        let seed = Seed(kind: .hummedTake(media), note: "captured on the phone")
        idea.seeds = [seed]
        let audio = Audio(media: media, role: .take, sampleRate: sampleRate, channelCount: channelCount, duration: duration)
        let capture = PartVersion(partID: PartID(), kind: .audio(audio), createdAt: createdAt, author: .user,
                                  operation: Operation.recorded, note: note, origin: seed.id)
        try? idea.append(capture)
        idea.sections[0].lengthInBars = min(ideaBarsRange.upperBound, idea.bars(holding: capture) ?? Song.startingIdeaBars)
        return idea
    }

    /// A capture's idea on its reading: the reading's tempo and key, the reading kept in it, the
    /// capture placed with its first downbeat on a bar line — the next one, what comes before it a
    /// pickup — and as many bars as hold it. Nil, and nothing changed, when it is not waiting for a
    /// reading or this one has no tempo; else what to say.
    static func read(_ idea: inout Song, _ reading: MusicAnalysis) -> (line: String, detail: String)? {
        guard let media = idea.captureAwaitingReading, let bpm = reading.dominantTempo, bpm > 0,
              let seed = idea.seeds.first(where: { $0.kind == .hummedTake(media) }),
              let capture = idea.versions.last(where: { Guidance.audio(of: $0)?.media == media }),
              case .audio(var audio) = capture.kind else { return nil }
        let tempo = min(tempoRange.upperBound, max(tempoRange.lowerBound, (bpm * 10).rounded() / 10))
        idea.tempo = tempo
        if let key = reading.dominantKey { idea.key = key }
        idea.gridChosen = true
        try? idea.append(PartVersion(partID: PartID(), kind: .analysis(reading), author: .user, operation: Operation.imported,
                                     note: "reading of \(idea.title)", origin: seed.id))
        // The record plays from its first frame and cannot start before the idea does, so the
        // downbeat goes on the first bar line at or after it: the next bar's when there is a pickup.
        let bar = Double(idea.timeSignature.beatsPerBar) * 60 / tempo
        let first = reading.bars.first?.start ?? reading.downbeats.first ?? 0
        let offset = max(0, bar * ((first - 0.06) / bar).rounded(.up) - first)
        let downbeatBar = Int(((first + offset) / bar).rounded()) + 1
        var placed = capture
        if offset > 0.005 {
            audio.alignmentOffset = offset
            placed = capture.deriving(.audio(audio), by: .user, operation: Operation.fitted,
                                      note: "\(PartLabel.title(of: capture)): on its reading, its first downbeat on bar \(downbeatBar)")
            try? idea.append(placed)
        }
        let bars = idea.bars(holding: placed) ?? idea.sections[0].lengthInBars
        idea.sections[0].lengthInBars = min(ideaBarsRange.upperBound, max(ideaBarsRange.lowerBound, bars))
        let detail = downbeatBar > 1
            ? String(format: "Its first downbeat comes %.2f s in, so it lands on bar %d and what is before it is a pickup.", first, downbeatBar)
            : "Read in the crate, as a record is."
        return (ideaLine(idea), detail)
    }

    /// Every idea waiting for its capture to be read, given the reading when the crate has one: the
    /// open idea in the frame, the rest in their packages. Said once for each.
    func readCaptures() {
        guard let store, libraryIsWritable else { return }
        let ids = library.ideaSongs.map(\.id) + [song?.id].compactMap { $0 }
        var seen = Set<SongID>()
        for id in ids where seen.insert(id).inserted {
            guard var idea = song?.id == id ? song : library.song(id),
                  let media = idea.captureAwaitingReading,
                  let reading = library.record(forMedia: media)?.reading,
                  let said = Self.read(&idea, reading) else { continue }
            if song?.id == id {
                updateSong { $0 = idea }
            } else {
                do { try store.songStore(for: id).save(idea) } catch {
                    note(.session, "Could not write \(idea.title)'s reading into it", detail: "\(error)")
                    continue
                }
            }
            library.upsert(idea)
            note(.session, "\(idea.title) is read: \(said.line)", detail: said.detail)
        }
    }

    /// An idea opened before its capture is read: read now when the crate has it; otherwise its
    /// settings open for a tempo, and the crate is asked to read it unless it is already on it.
    func captureOpened() {
        readCaptures()
        guard let song, let media = song.captureAwaitingReading else { return }
        wantsSongSettings = true
        var detail = "Its capture is read in the crate for its tempo, key and bars, and the idea takes them when that is done. A tempo set here is kept instead."
        if let record = library.record(forMedia: media) {
            if record.reading == nil, crate.status(of: record.id) == nil {
                crate.enqueue(CrateJob(kind: .analyse, record: record.id, title: record.title))
            }
            if let failed = crate.failures[record.id] { detail = "The crate could not read it: \(failed). Set its tempo here." }
        } else if let url = try? store?.mediaURL(for: media, song: song.id),
                  crate.running?.file != url, !crate.waiting.contains(where: { $0.file == url }) {
            crate.enqueue(CrateJob(kind: .bring, file: url, title: song.title, separating: false))
        }
        note(.session, "\(song.title) has no tempo of its own yet", detail: detail)
    }

    // MARK: An idea kept before ideas could be opened

    /// Opens a bare idea from the library — a part kept before ideas were packages — by making it
    /// one: written once, said in the rail, listed once on the Ideas shelf from then on. A capture
    /// from the phone takes its reading from the crate as one coming in now does.
    @discardableResult
    public func openBareIdea(_ id: VersionID) -> SongID? {
        guard let bare = library.ideas.first(where: { $0.id == id }) else {
            note(.session, "That idea is not in the library any more")
            return nil
        }
        let idea = Self.idea(from: bare)
        guard keepIdeaPackage(idea, mediaFrom: nil, changing: { $0.ideas.removeAll { $0.id == id } }) else { return nil }
        note(.session, "\(idea.title) is an idea of its own now",
             detail: "It was kept before ideas could be opened. From now on it opens like a song, with a tempo, a key and bars of its own.")
        openSong(idea.id)
        return idea.id
    }

    /// A bare idea as an idea package: a capture waiting for its reading, or any other part at the
    /// starting tempo, as long as it is.
    static func idea(from bare: PartVersion) -> Song {
        let title = PartLabel.title(of: bare)
        if case .audio(let audio) = bare.kind, audio.role == .take, audio.take == nil, audio.comp == nil {
            return captureIdea(title: title, media: audio.media, sampleRate: audio.sampleRate, channelCount: audio.channelCount,
                               duration: audio.duration, note: bare.note, createdAt: bare.createdAt)
        }
        var idea = Song.newIdea(title: title)
        let part = PartVersion(partID: PartID(), kind: bare.kind, createdAt: bare.createdAt, author: bare.author,
                               operation: bare.operation, note: bare.note)
        try? idea.append(part)
        _ = joinForm(with: part, in: &idea)
        idea.sections[0].lengthInBars = min(ideaBarsRange.upperBound, max(ideaBarsRange.lowerBound,
                                                                           idea.bars(holding: part) ?? Song.startingIdeaBars))
        return idea
    }

    // MARK: Writing one

    /// Writes a new idea into a package of its own, its media copied in — from `files` where named,
    /// else from wherever the library keeps it for `mediaFrom` — and lists it in `library.json` with
    /// `change`, in one write of the document. What is open stays open. False, with the reason in
    /// the rail, when it could not be written; nothing is left half made.
    @discardableResult
    func keepIdeaPackage(_ idea: Song, mediaFrom songID: SongID?, files: [MediaRef: URL] = [:],
                         changing change: (inout Library) -> Void = { _ in }) -> Bool {
        guard let store else {
            note(.session, "Nowhere to keep an idea", detail: "This session has no library directory.")
            return false
        }
        guard libraryIsWritable else {
            note(.session, "The library could not be read, so nothing is written to it",
                 detail: "Move aside what it names, then Reload Library.")
            return false
        }
        var package: SongStore?
        do {
            let made = try store.savePackage(idea)
            package = made
            for media in idea.mediaReferences where !made.hasMedia(media) {
                let source = try files[media] ?? store.mediaURL(for: media, song: songID)
                guard try made.addMedia(copying: source) == media else {
                    throw SongGraphError.missingMedia(media, searched: [source.path])
                }
            }
        } catch {
            if let package { try? FileManager.default.removeItem(at: package.packageURL) }
            note(.session, "Could not keep \(idea.title) as an idea", detail: "\(error)")
            return false
        }
        var updated = library
        updated.upsert(idea)
        change(&updated)
        guard writeLibrary(updated) else {
            if let package { try? FileManager.default.removeItem(at: package.packageURL) }
            return false
        }
        return true
    }

    /// "8 bars at 92 bpm in A minor", with the meter when it is not 4/4; "its tempo still to be
    /// read" for a capture waiting for its reading.
    static func ideaLine(_ idea: Song) -> String {
        let bars = Guidance.count(idea.sections.first?.lengthInBars ?? 0, "bar")
        guard idea.captureAwaitingReading == nil else { return "\(bars), its tempo still to be read" }
        let tempo = idea.tempo.rounded() == idea.tempo ? "\(Int(idea.tempo))" : String(format: "%.1f", idea.tempo)
        var line = "\(bars) at \(tempo) bpm"
        if let key = idea.key { line += " in \(key.name)" }
        if idea.timeSignature != .fourFour { line += ", \(idea.timeSignature.description)" }
        return line
    }
}
