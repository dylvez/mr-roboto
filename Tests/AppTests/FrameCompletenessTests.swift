import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// The frame, made whole: a song that keeps its own work, that can be named and set, and a library
// that can be tidied. Every test here is a thing a person could not do before, or a thing the app
// lost for them.

@MainActor
enum CompletenessFixture {
    /// A real store in a scratch directory, a scratch defaults suite, and audio that never reaches
    /// a device. Autosave is off unless a test turns it on: most of these assert on "unsaved".
    static func app(_ label: String, library: Library = Library()) -> (app: AppState, directory: URL, defaults: UserDefaults) {
        let directory = GuidanceFixture.temporaryDirectory("complete-\(label)")
        let defaults = UserDefaults(suiteName: "mrroboto.tests.\(label).\(UUID().uuidString)")!
        let store = LibraryStore(directoryURL: directory)
        let app = AppState(library: library, song: nil, store: store, status: .empty(directory),
                           transportHost: StubTransportHost(), regions: RegionVisibility(defaults: defaults),
                           primers: PrimerStore(defaults: defaults), defaults: defaults)
        app.autosaveDelay = nil
        return (app, directory, defaults)
    }

    static func song(_ title: String) -> Song {
        var song = Song(title: title, artist: "Vessel", key: Key(parsing: "D major"), tempo: 92)
        try? song.append(TransportFixture.grooveVersion())
        return song
    }
}

// MARK: - The song keeps its work

@Suite("Completeness: the song keeps its work") @MainActor
struct SongKeepsWorkTests {

    @Test("Opening another song saves the one that was open, rather than dropping it")
    func savesBeforeSwitching() throws {
        let (app, directory, _) = CompletenessFixture.app("switch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = CompletenessFixture.song("First")
        let second = CompletenessFixture.song("Second")
        app.open(first)
        app.save()
        #expect(app.record(TransportFixture.progressionVersion()))
        #expect(app.hasUnsavedChanges)

        app.open(second)

        let store = LibraryStore(directoryURL: directory)
        let reloaded = try store.songStore(for: first.id).load()
        #expect(reloaded.versions.count == 2, "the chords written into First are on disk")
        #expect(app.song?.id == second.id)
    }

    @Test("Reopening the song that is open keeps its unsaved work rather than reloading the library's copy")
    func reopenSameSong() {
        let (app, directory, _) = CompletenessFixture.app("reopen-same")
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = CompletenessFixture.song("Same")
        app.open(song)
        app.save()
        #expect(app.record(TransportFixture.progressionVersion()))
        #expect(app.song?.versions.count == 2)

        app.openSong(song.id)

        #expect(app.song?.versions.count == 2, "the chords are still there")
        #expect(app.hasUnsavedChanges, "and still waiting to be saved")
    }

    @Test("Autosave writes the song a little after the last change, quietly")
    func autosaves() async throws {
        let (app, directory, _) = CompletenessFixture.app("autosave")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.autosaveDelay = .milliseconds(30)
        let song = CompletenessFixture.song("Quiet")
        app.open(song)
        let lines = app.log.count
        #expect(app.record(TransportFixture.progressionVersion()))
        #expect(app.hasUnsavedChanges)

        // Polled rather than slept for: under the whole suite the machine is busy, and a fixed
        // wait made this the one flaky test.
        for _ in 0..<200 where app.hasUnsavedChanges { try await Task.sleep(for: .milliseconds(25)) }

        #expect(!app.hasUnsavedChanges)
        let reloaded = try LibraryStore(directoryURL: directory).songStore(for: song.id).load()
        #expect(reloaded.versions.count == 2)
        #expect(!app.log.dropFirst(lines).contains { $0.text.hasPrefix("Saved") }, "an autosave is not a line in the rail")
    }

    @Test("The last song opened is remembered, and reopened on the next launch when the library still holds it")
    func reopensLastSong() {
        let (app, directory, defaults) = CompletenessFixture.app("last")
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = CompletenessFixture.song("Remembered")
        app.open(song)
        app.save()
        #expect(defaults.string(forKey: AppState.lastOpenedSongKey) == song.id.rawValue.uuidString)

        let next = AppState(library: app.library, song: nil, store: app.store, status: .loaded(directory),
                            transportHost: StubTransportHost(), regions: RegionVisibility(defaults: defaults),
                            primers: PrimerStore(defaults: defaults), defaults: defaults)
        #expect(next.song == nil)
        #expect(next.reopenLastSong())
        #expect(next.song?.id == song.id)

        // Gone from the library: nothing opens, nothing complains.
        let empty = AppState(library: Library(), song: nil, store: app.store, status: .empty(directory),
                             transportHost: StubTransportHost(), regions: RegionVisibility(defaults: defaults),
                             primers: PrimerStore(defaults: defaults), defaults: defaults)
        #expect(!empty.reopenLastSong())
        #expect(empty.song == nil)
    }

    @Test("Closing the song saves it, clears the bench and forgets it for the next launch")
    func closeSong() {
        let (app, directory, defaults) = CompletenessFixture.app("close")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(CompletenessFixture.song("Open"))
        app.openSurface(.grid, title: "Grid")
        #expect(app.record(TransportFixture.progressionVersion()))

        app.closeSong()

        #expect(app.song == nil)
        #expect(app.bench.items.isEmpty)
        #expect(!app.hasUnsavedChanges)
        #expect(defaults.string(forKey: AppState.lastOpenedSongKey) == nil)
        #expect(app.library.songs.count == 1, "saved on the way out")
        #expect(app.log.last?.text == "Closed Open")
    }

    @Test("A save that fails is said in the header, not only in the rail")
    func saveFailureIsVisible() {
        let (app, directory, _) = CompletenessFixture.app("savefail")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(CompletenessFixture.song("Doomed"))
        // A library directory nothing can be written into.
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        app.save()
        #expect(app.lastSaveError != nil)
        #expect(app.log.last?.text == "Save failed")
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        app.save()
        #expect(app.lastSaveError == nil, "a save that works clears it")
    }

    @Test("Lines the app writes into a folded rail are counted until the rail is opened")
    func unseenSessionNotes() {
        let (app, directory, _) = CompletenessFixture.app("unseen")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.regions.setCollapsed(true, for: .rail)
        app.note(.session, "Save failed", detail: "disk full")
        app.note(.you, "Opened Grid")
        app.note(.session, "The export failed")
        #expect(app.unseenSessionNotes == 2, "only the app's own lines count")
        app.markRailSeen()
        #expect(app.unseenSessionNotes == 0)
        app.regions.setCollapsed(false, for: .rail)
        app.note(.session, "Something else")
        #expect(app.unseenSessionNotes == 0, "an open rail is being read")
    }
}

// MARK: - The song's settings

@Suite("Completeness: the song's settings") @MainActor
struct SongSettingsTests {

    @Test("Title, artist, tempo, key and meter can be set, each marking the song unsaved")
    func settings() {
        let (app, directory, _) = CompletenessFixture.app("settings")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(CompletenessFixture.song("Untitled, Sept 17"))
        app.save()

        #expect(app.setTitle("Arrival"))
        #expect(app.song?.title == "Arrival")
        #expect(app.library.song(app.song!.id)?.title == "Arrival", "the sidebar follows at once")
        #expect(app.hasUnsavedChanges)
        #expect(!app.setTitle("   "), "an empty name is refused")
        #expect(!app.setTitle("Arrival"), "the same name is not a change")

        #expect(app.setArtist("Vessel Two"))
        #expect(app.song?.artist == "Vessel Two")

        #expect(app.setTempo(113))
        #expect(app.song?.tempo == 113)
        #expect(app.clock.tempo == 113, "the transport clock follows")
        #expect(app.setTempo(9_999))
        #expect(app.song?.tempo == AppState.tempoRange.upperBound, "clamped, not refused")
        #expect(!app.setTempo(.nan))

        #expect(app.setKey(parsing: "F# minor"))
        #expect(app.song?.key?.name == "F♯ minor")
        #expect(!app.setKey(parsing: "purple"), "not a key: nothing changes")
        #expect(app.song?.key?.name == "F♯ minor")
        #expect(app.setKey(parsing: ""))
        #expect(app.song?.key == nil, "blank clears the key")

        #expect(app.setTimeSignature(TimeSignature(7, 8)))
        #expect(app.song?.timeSignature.description == "7/8")
        #expect(!app.setTimeSignature(TimeSignature(4, 3)), "3 is not a beat unit")
    }

    @Test("Renaming the song retitles the surfaces that were titled for it")
    func renameRetitles() {
        let (app, directory, _) = CompletenessFixture.app("retitle")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(CompletenessFixture.song("Draft"))
        let structure = app.openSurface(.structure, title: "Draft")
        let grid = app.openSurface(.grid, title: "Boom-bap pocket")
        #expect(app.setTitle("Arrival"))
        #expect(app.bench.items.first { $0.id == structure }?.title == "Arrival")
        #expect(app.bench.items.first { $0.id == grid }?.title == "Boom-bap pocket")
    }

    @Test("A meter is two numbers over a slash, and nothing else")
    func meterParsing() {
        #expect(AppState.timeSignature(parsing: "4/4") == TimeSignature(4, 4))
        #expect(AppState.timeSignature(parsing: " 7 / 8 ") == TimeSignature(7, 8))
        #expect(AppState.timeSignature(parsing: "12/8") == TimeSignature(12, 8))
        #expect(AppState.timeSignature(parsing: "4") == nil)
        #expect(AppState.timeSignature(parsing: "4/3") == nil)
        #expect(AppState.timeSignature(parsing: "0/4") == nil)
        #expect(AppState.timeSignature(parsing: "four/four") == nil)
    }

    @Test("A tempo readout keeps a fraction only when there is one")
    func tempoText() {
        #expect(SongSettingsPopover.tempoText(113) == "113")
        #expect(SongSettingsPopover.tempoText(92.5) == "92.5")
    }
}

// MARK: - The library, managed

@Suite("Completeness: the library can be tidied") @MainActor
struct LibraryManagementTests {

    @Test("A song in the library can be renamed inside its package")
    func renameLibrarySong() throws {
        let (app, directory, _) = CompletenessFixture.app("rename")
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = CompletenessFixture.song("Old name")
        app.open(song)
        app.save()
        app.closeSong()

        #expect(app.renameSong(song.id, to: "New name"))
        #expect(app.library.song(song.id)?.title == "New name")
        let reloaded = try LibraryStore(directoryURL: directory).songStore(for: song.id).load()
        #expect(reloaded.title == "New name")
        #expect(!app.renameSong(song.id, to: ""), "an empty name is refused")
    }

    @Test("Duplicating a song copies its versions, sections and cast under a new id, and opens the copy")
    func duplicate() throws {
        let (app, directory, _) = CompletenessFixture.app("duplicate")
        defer { try? FileManager.default.removeItem(at: directory) }
        var song = CompletenessFixture.song("Original")
        song.sections = [Section(name: "Verse", stitch: [], lengthInBars: 8)]
        song.cast = ["beatmaker"]
        app.open(song)
        app.save()

        let copyID = try #require(app.duplicateSong(song.id))
        #expect(copyID != song.id)
        #expect(app.song?.id == copyID, "the copy is what is open")
        #expect(app.song?.title == "Original copy")
        #expect(app.song?.versions.map(\.id) == song.versions.map(\.id))
        #expect(app.song?.sections.map(\.name) == ["Verse"])
        #expect(app.song?.cast == ["beatmaker"])
        #expect(app.library.songs.count == 2)
        #expect(app.library.song(song.id)?.title == "Original", "the original is untouched")
    }

    @Test("Deleting a song moves its package out, forgets it, and takes it off every album")
    func deleteSong() throws {
        let (app, directory, defaults) = CompletenessFixture.app("delete")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bin = GuidanceFixture.temporaryDirectory("bin")
        defer { try? FileManager.default.removeItem(at: bin) }
        app.trash = { url in
            let moved = bin.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: moved)
            return moved
        }
        let song = CompletenessFixture.song("Doomed")
        app.open(song)
        app.save()
        let album = try #require(app.createAlbum(title: "Record"))
        #expect(app.addSong(song.id, to: album))
        app.openSurface(.grid, title: "Grid")

        #expect(app.deleteSong(song.id))

        #expect(app.song == nil, "the open song was closed first")
        #expect(app.bench.items.isEmpty)
        #expect(app.library.song(song.id) == nil)
        #expect(app.library.album(album)?.songs.isEmpty == true)
        #expect(defaults.string(forKey: AppState.lastOpenedSongKey) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).contains { $0.hasSuffix(".roboto") })
        app.reloadLibrary()
        #expect(app.library.song(song.id) == nil, "the package is gone from the directory, so a reload does not find it")
        #expect(app.log.last?.text == "Moved Doomed to the Trash")
    }

    @Test("Albums, ideas, samples and records can be removed; songs and audio stay")
    func removeTheRest() throws {
        let (app, directory, _) = CompletenessFixture.app("remove")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory)
        let record = try LibraryFixture.record("Arrival", in: directory, store: store)
        #expect(app.writeLibrary(Library(records: [record])))
        let (song, groove, chop) = try LibraryFixture.songWithChop("Arrival", record: record, app: app)
        let idea = try #require(app.keepAsIdea(groove))
        let sample = try #require(app.saveToSamples(chop))
        let album = try #require(app.createAlbum(title: "Record"))
        app.openAlbum(album)
        #expect(app.bench.items.contains { $0.kind == .album })

        #expect(app.deleteAlbum(album))
        #expect(app.library.album(album) == nil)
        #expect(!app.bench.items.contains { $0.kind == .album }, "its surface closed with it")
        #expect(app.removeIdea(idea))
        #expect(app.library.ideas.isEmpty)
        #expect(app.removeSample(sample))
        #expect(app.library.samples.isEmpty)
        #expect(app.removeRecord(record.id))
        #expect(app.library.records.isEmpty)
        #expect(app.library.song(song.id) != nil, "the song is still there")
        #expect(store.hasMedia(record.media), "the record's audio stays: a song flipped from it still plays")
        #expect(!app.removeIdea(idea), "gone is gone")
    }
}

// MARK: - The ledger reaches everything

@Suite("Completeness: every part opens somewhere") @MainActor
struct LedgerReachTests {

    @Test("A melody row opens the Piano roll on the melody, in melody mode")
    func melodyOpens() {
        let song = TransportFixture.song([TransportFixture.grooveVersion(), TransportFixture.melodyVersion()])
        let melody = song.versions.last!
        let action = PartActions.primary(for: melody, in: song)
        #expect(action?.action.surface == .pianoRoll)
        #expect(action?.action.bound == [melody.id])

        let host = StubRollHost()
        let model = PianoRollModel(host: host, groove: TransportFixture.groove(), key: .cMajor, tempo: 92,
                                   melody: melody, instrument: "rhodes")
        #expect(model.mode == .melody)
        #expect(model.notes.count == 2)
        #expect(model.base?.id == melody.id)
        let kept = model.commit(note: "edited")
        #expect(kept.partID == melody.partID, "a keep is a version of the same part")
        #expect(kept.parents == [melody.id])
        if case .melody = kept.kind {} else { Issue.record("a melody roll keeps a melody") }
    }

    @Test("A sung take opens in Takes, on every take of its part")
    func takesOpen() {
        var song = TransportFixture.song([TransportFixture.grooveVersion()])
        let part = PartID()
        let takes = (1...2).map { pass -> PartVersion in
            let audio = Audio(media: GuidanceFixture.media("a"), role: .take, sampleRate: 48_000, channelCount: 1,
                              duration: 4, alignmentOffset: 2, take: Take(section: song.sections[1].id, startBar: 4, pass: pass))
            return PartVersion(partID: part, kind: .audio(audio), author: .user, operation: Operation.recorded, note: "Take \(pass)")
        }
        for take in takes { try? song.append(take) }
        let action = PartActions.primary(for: takes[0], in: song)
        #expect(action?.action.surface == .takes)
        #expect(action?.action.bound == takes.map(\.id))
        #expect(action?.action.title == "Verse takes")
    }

    @Test("What next carries on past the arrangement: sing, comp, mix, master")
    func laterProposals() {
        // A lean song — a groove, a bass line, arranged — so the four the rail shows are the later
        // steps and not the record's own.
        let groove = TransportFixture.grooveVersion()
        let bass = PartVersion(partID: PartID(), kind: .bassline(Bassline(notes: [NoteEvent(pitch: Pitch(midi: 40), start: 0, duration: 1)], sound: "finger")),
                               author: .user, operation: Operation.written, note: "Bass")
        var song = TransportFixture.song([groove, bass],
                                         sections: [Section(name: "Verse", stitch: [Lane(part: groove.partID), Lane(part: bass.partID)], lengthInBars: 8)])
        var titles = Guidance.proposals(for: song).map(\.title)
        #expect(titles.contains("Sing over Arrival"))
        #expect(titles.contains("Mix Arrival"))
        #expect(titles.firstIndex(of: "Write the words")! < titles.firstIndex(of: "Sing over Arrival")!, "the words before the microphone")

        // Words, and a tune they are not set to: the setting is proposed instead.
        var worded = song
        let tune = PartVersion(partID: PartID(), kind: .melody(Melody(notes: [NoteEvent(pitch: Pitch(midi: 72), start: 0, duration: 1)])),
                               author: .user, operation: Operation.written, note: "Tune")
        try? worded.append(tune)
        try? worded.append(PartVersion(partID: PartID(), kind: .lyric(Lyricist.lyric(from: "[Verse]\nsoft machine")),
                                       author: .user, operation: Operation.written, note: "Lyric"))
        let wordedTitles = Guidance.proposals(for: worded).map(\.title)
        #expect(!wordedTitles.contains("Write the words"))
        #expect(wordedTitles.contains("Set the words to \(PartLabel.title(of: tune))"), "\(wordedTitles)")

        let part = PartID()
        let take = PartVersion(partID: part, kind: .audio(Audio(media: GuidanceFixture.media("f"), role: .take, sampleRate: 48_000,
                                                                channelCount: 1, duration: 4, take: Take(startBar: 0))),
                               author: .user, operation: Operation.recorded, note: "Take 1")
        try? song.append(take)
        titles = Guidance.proposals(for: song).map(\.title)
        #expect(titles.contains("Comp the 1 take"))
        #expect(!titles.contains("Sing over Arrival"))
        #expect(!titles.contains("Write the words"), "sung without written words: not nagged")

        try? song.append(PartVersion(partID: PartID(), kind: .mix(Mix.unity), author: .user, operation: Operation.written))
        titles = Guidance.proposals(for: song).map(\.title)
        #expect(titles.contains("Read the master"))
        #expect(!titles.contains("Mix Arrival"))
    }

    @Test("Choosing an instrument again is a version of the same pick, not a new part")
    func instrumentIsOnePart() {
        let (app, directory, _) = CompletenessFixture.app("instrument")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(CompletenessFixture.song("Keys"))
        let before = app.song!.partIDs.count
        #expect(!app.setInstrument("rhodes"), "the Rhodes is what a song plays before it has chosen: nothing to record")
        #expect(app.setInstrument("wurlitzer"))
        #expect(app.setInstrument("rhodes"))
        #expect(app.setInstrument("wurlitzer"))
        #expect(app.song!.partIDs.count == before + 1, "three picks, one part")
        #expect(app.song!.versions.filter { $0.type == .sound }.count == 3, "and three versions of it")
        #expect(SongPlayback.instrumentID(in: app.song!) == "wurlitzer")
    }
}

@MainActor
private final class StubRollHost: PianoRollHosting {
    var committed: [PartVersion] = []
    func audition(note: Int, velocity: Int, duration: Double, sound: String) async {}
    func play(_ bassline: Bassline, tempo: Double, timeSignature: TimeSignature) async {}
    func auditionMelody(note: Int, velocity: Int, duration: Double, instrument: String) async {}
    func playMelody(_ notes: [NoteEvent], tempo: Double, timeSignature: TimeSignature, instrument: String) async {}
    func setInstrument(_ id: String, for part: PartID?) {}
    func stop() async {}
    func commit(_ version: PartVersion) -> Bool { committed.append(version); return true }
}

// MARK: - The window and the files

@Suite("Completeness: the window fits its frame, and exports never overwrite") @MainActor
struct WindowAndFilesTests {

    @Test("A window narrower than the frame's minimum grows to it, and moves left when the screen is short")
    func fittedFrame() {
        let screen = CGRect(x: 0, y: 0, width: 1710, height: 1069)
        #expect(FrameLayout.fittedFrame(for: CGRect(x: 100, y: 100, width: 1600, height: 900),
                                        minimum: CGSize(width: 1509, height: 600), visible: screen) == nil,
                "already fits: nothing moves")
        let grown = FrameLayout.fittedFrame(for: CGRect(x: 100, y: 100, width: 1440, height: 900),
                                            minimum: CGSize(width: 1509, height: 600), visible: screen)
        #expect(grown == CGRect(x: 100, y: 100, width: 1509, height: 900))
        let pushed = FrameLayout.fittedFrame(for: CGRect(x: 400, y: 100, width: 1440, height: 900),
                                             minimum: CGSize(width: 1509, height: 600), visible: screen)
        #expect(pushed?.width == 1509)
        #expect(pushed?.maxX == screen.maxX, "pushed left rather than off the edge")
        let capped = FrameLayout.fittedFrame(for: CGRect(x: 0, y: 0, width: 800, height: 500),
                                             minimum: CGSize(width: 3000, height: 2000), visible: screen)
        #expect(capped?.size == screen.size, "never past the screen")
        let taller = FrameLayout.fittedFrame(for: CGRect(x: 0, y: 400, width: 1600, height: 500),
                                             minimum: CGSize(width: 1000, height: 700), visible: screen)
        #expect(taller == CGRect(x: 0, y: 200, width: 1600, height: 700), "grows down, keeping its top")
    }

    @Test("An export path that is taken gets a number, not an overwrite")
    func uniquePaths() throws {
        let directory = GuidanceFixture.temporaryDirectory("unique")
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("Arrival — master.wav")
        #expect(Export.unique(wav) == wav)
        FileManager.default.createFile(atPath: wav.path, contents: Data())
        let second = Export.unique(wav)
        #expect(second.lastPathComponent == "Arrival — master 2.wav")
        FileManager.default.createFile(atPath: second.path, contents: Data())
        #expect(Export.unique(wav).lastPathComponent == "Arrival — master 3.wav")
    }
}

// MARK: - Playing from a section

@Suite("Completeness: the transport plays from a section") @MainActor
struct PlayFromSectionTests {

    private func arrangedApp() -> (app: AppState, host: StubPlaybackHost, verse: SectionID) {
        let (app, _, _) = CompletenessFixture.app("from-section")
        let groove = TransportFixture.grooveVersion()
        var song = TransportFixture.song([groove])
        song.sections = [Section(name: "Intro", stitch: [Lane(part: groove.partID)], lengthInBars: 4),
                         Section(name: "Verse", stitch: [Lane(part: groove.partID)], lengthInBars: 8)]
        let host = StubPlaybackHost()
        app.attach(playback: host)
        app.open(song)
        return (app, host, song.sections[1].id)
    }

    @Test("Starting from a section hands the player the shifted plan and reads the song's own bars")
    func fromSection() async {
        let (app, host, verse) = arrangedApp()
        await app.startTransport(fromSection: verse)
        #expect(app.transport.isPlaying)
        #expect(app.playbackStartBar == 4)
        let began = await host.began
        #expect(began.last?.startsAtBar == 4)
        #expect(began.last?.segments.map(\.name) == ["Verse"])
        #expect(abs(app.playhead - 8) < 0.001, "the readout starts at the verse, not at 0")
        #expect(app.activeSection == verse)
        #expect(app.positionText == "5.1")
        #expect(app.log.last(where: { $0.source == .you })?.text == "Play from Verse")

        // Following: the engine's two seconds are the song's ten.
        #expect(app.section(atSeconds: 8 + 2) == verse)
        await app.stopTransport()
        #expect(app.playbackStartBar == 0)
    }

    @Test("Looping from a section comes round to that section, not to the top")
    func loopingFromSection() async {
        let (app, _, verse) = arrangedApp()
        app.toggleLoop()
        await app.startTransport(fromSection: verse)
        // Twelve bars in all; from bar 4 the loop is eight bars, so bar 13 is bar 5 again.
        let intro = app.song!.sections[0].id
        #expect(app.section(atSeconds: app.clock.seconds(forBar: 12)) == verse)
        #expect(app.section(atSeconds: app.clock.seconds(forBar: 2)) == intro, "before the start it is still the intro")
    }

    @Test("A section the song does not hold plays from the top")
    func unknownSection() async {
        let (app, host, _) = arrangedApp()
        await app.startTransport(fromSection: SectionID())
        let began = await host.began
        #expect(began.last?.startsAtBar == 0)
        #expect(app.playhead == 0)
    }
}

// MARK: - The bench does not lose work

@Suite("Completeness: the bench keeps unkept work") @MainActor
struct BenchGuardTests {

    private func item(_ title: String, at seconds: Double) -> BenchItem {
        BenchItem(id: SurfaceID(), kind: .grid, title: title, openedAt: Date(timeIntervalSinceReferenceDate: seconds))
    }

    @Test("A full bench retires the oldest unpinned surface that has nothing to lose")
    func retiresTheCleanOne() {
        let bench = Bench()
        let oldest = item("oldest, dirty", at: 0)
        let middle = item("middle, clean", at: 1)
        let newest = item("newest, dirty", at: 2)
        for each in [oldest, middle, newest] { bench.open(each) }
        let retired = bench.open(item("fourth", at: 3)) { $0.id == middle.id }
        #expect(retired?.id == middle.id)
        #expect(bench.items.count == Design.maximumOpenSurfaces)
        #expect(bench.items.contains { $0.id == oldest.id }, "the oldest stays because it is holding work")
    }

    @Test("When every unpinned surface is holding work the bench goes one over rather than losing any")
    func goesOneOver() {
        let bench = Bench()
        for index in 0..<3 { bench.open(item("dirty \(index)", at: Double(index))) }
        let retired = bench.open(item("fourth", at: 3)) { _ in false }
        #expect(retired == nil)
        #expect(bench.items.count == Design.maximumOpenSurfaces + 1)
    }

    @Test("The frame asks the wiring, and says so in the rail when the bench goes over")
    func frameAsks() {
        let (app, directory, _) = CompletenessFixture.app("bench-guard")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(CompletenessFixture.song("Guarded"))
        var dirty: Set<SurfaceID> = []
        app.hasUnkeptChanges = { dirty.contains($0.id) }
        let first = app.openSurface(.grid, title: "one")
        let second = app.openSurface(.chords, title: "two")
        let third = app.openSurface(.lyrics, title: "three")
        dirty = [first, second, third]
        #expect(app.closingWouldLoseWork(first))
        let fourth = app.openSurface(.structure, title: "four")
        #expect(app.bench.items.count == 4)
        #expect(app.log.last?.text.hasPrefix("The bench is one over") == true)
        #expect(!app.closingWouldLoseWork(fourth))

        dirty = [first, third]
        _ = app.openSurface(.pianoRoll, title: "five")
        #expect(!app.bench.items.contains { $0.id == second }, "the one with nothing to lose went")
        #expect(app.bench.items.contains { $0.id == first })
    }
}
