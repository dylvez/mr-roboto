import AudioEngine
import Foundation
import Instrument
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// What the transport decides to play, and what the frame does with that decision.
//
// The bug these exist to keep fixed: `AppState` had `startTransport`, a `TransportClock` built from
// the song's tempo, and space bound to it — and nothing was ever scheduled against any of it. The
// bar looked like a player. Pressing play moved an enum and made exactly as much sound as not
// pressing it.
//
// Everything here is a pure function of the song graph or of `AppState`'s own transitions, so none
// of it needs an audio device. The half that does — that a started transport actually renders — is
// `TransportPlaybackTests`, offline.

// MARK: - Fixtures

enum TransportFixture {

    /// A groove with a kick on every beat and a hat on every off-beat: something that plainly has
    /// hits in it, so "the groove is silent" is a different case from "there is no groove".
    static func groove(bars: Int = 1) -> Groove {
        var kick = [VelocityTier](repeating: .rest, count: 16 * bars)
        var hat = kick
        for step in stride(from: 0, to: 16 * bars, by: 4) { kick[step] = .accent }
        for step in stride(from: 2, to: 16 * bars, by: 4) { hat[step] = .ghost }
        return Groove(stepsPerBar: 16, bars: bars,
                      patterns: [GroovePattern(voice: .kick, steps: kick),
                                 GroovePattern(voice: .closedHat, steps: hat)])
    }

    static func silentGroove() -> Groove {
        Groove(stepsPerBar: 16, bars: 1,
               patterns: [GroovePattern(voice: .kick, steps: [VelocityTier](repeating: .rest, count: 16))])
    }

    static func grooveVersion(_ groove: Groove = TransportFixture.groove()) -> PartVersion {
        PartVersion(partID: PartID(), kind: .groove(groove), author: .user,
                    operation: Operation.regroove, note: "four on the floor")
    }

    /// Four bars of Cmaj7 | Am7 | Fmaj7 | G7: chords that plainly sound, so "the chords are silent"
    /// is a different case from "there are no chords".
    static func progression() -> Progression {
        Progression(key: Key(tonic: NoteName(.c)), bars: [
            ProgressionBar(Chord(.c, .majorSeventh)),
            ProgressionBar(Chord(.a, .minorSeventh)),
            ProgressionBar(Chord(.f, .majorSeventh)),
            ProgressionBar(Chord(.g, .dominantSeventh)),
        ])
    }

    static func progressionVersion(_ progression: Progression = TransportFixture.progression()) -> PartVersion {
        PartVersion(partID: PartID(), kind: .progression(progression), author: .user,
                    operation: Operation.written, note: "the changes")
    }

    static func melodyVersion(_ melody: Melody = Melody(notes: [
        NoteEvent(pitch: Pitch(midi: 72), start: 0, duration: 1),
        NoteEvent(pitch: Pitch(midi: 74), start: 2, duration: 2),
    ])) -> PartVersion {
        PartVersion(partID: PartID(), kind: .melody(melody), author: .user,
                    operation: Operation.written, note: "the tune")
    }

    static func soundVersion(_ instrument: String) -> PartVersion {
        PartVersion(partID: PartID(), kind: .sound(Sound(instrument: instrument)), author: .user,
                    operation: Operation.written)
    }

    /// A hex character, so every fixture's `ContentHash` is a valid one and distinct.
    static func hex(_ index: Int) -> Character {
        Array("abcdef0123456789")[index % 16]
    }

    static func audioVersion(role: AudioRole, stem: String? = nil, duration: Double = 8,
                             offset: Double? = nil, hash: Character = "a") -> PartVersion {
        let media = MediaRef(hash: ContentHash(hex: String(repeating: hash, count: 64))!,
                             fileExtension: "wav")
        let audio = Audio(media: media, role: role, stem: stem, sampleRate: 48_000,
                          channelCount: 2, duration: duration, alignmentOffset: offset)
        return PartVersion(partID: PartID(), kind: .audio(audio), author: .user,
                           operation: role == .take ? Operation.imported : Operation.separate)
    }

    /// A song with sections, so the strip has something to follow.
    static func song(_ versions: [PartVersion], tempo: Double = 120,
                     sections: [Section] = [Section(name: "Intro", stitch: [], lengthInBars: 4),
                                            Section(name: "Verse", stitch: [], lengthInBars: 16)]) -> Song {
        var song = Song(title: "Arrival", artist: "Vessel", key: Key(parsing: "D major"),
                        tempo: tempo, sections: sections)
        for version in versions { try? song.append(version) }
        return song
    }

    /// Resolves every media ref to the same existing file. The plan's only question about media is
    /// "is it there", so one file answers it for as many stems as a test wants.
    static func resolver(_ url: URL?) -> (MediaRef) -> URL? {
        { _ in url }
    }

    static func temporaryDirectory(_ label: String = "transport") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MrRoboto-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A player that records what it was asked to do and reports whatever reading a test sets.
///
/// An `actor` because `SongPlaybackHost` is deliberately not main-actor — the real one lives on
/// `@AudioActor` with the rest of the audio, and the frame only ever awaits it.
actor StubPlaybackHost: SongPlaybackHost {
    private(set) var began: [SongPlayback] = []
    private(set) var ended = 0
    private var next = PlaybackReading(isRunning: true, seconds: 0)
    var failure: Error?

    init(failure: Error? = nil) { self.failure = failure }

    func begin(_ plan: SongPlayback, clock: TransportClock) async throws {
        if let failure { throw failure }
        began.append(plan)
    }

    func end() async { ended += 1 }

    func reading() async -> PlaybackReading { next }

    func report(_ reading: PlaybackReading) { next = reading }
}

// MARK: - The plan

@Suite("Transport: what the song has that can be played") @MainActor
struct TransportPlanTests {

    private let media = URL(fileURLWithPath: "/dev/null")

    @Test("A groove is playable, and the plan names the machine it plays on")
    func aGroove() {
        let version = TransportFixture.grooveVersion()
        let song = TransportFixture.song([version])
        let plan = SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(nil))

        #expect(plan.isPlayable)
        #expect(plan.groove != nil)
        #expect(plan.grooveVersion == version.id)
        #expect(plan.tracks.isEmpty)
        #expect(plan.machine == SynthMachine.tr808.id)
        #expect(plan.tempo == 120)
        #expect(plan.summary == "Groove")
        #expect(plan.silence == nil)
        // Sections are what a groove with the loop off runs to.
        #expect(plan.lengthInBars == 20)
    }

    @Test("The song's own Sound part decides which machine the groove plays on")
    func theMachineComesFromTheSong() {
        let sound = PartVersion(partID: PartID(),
                                kind: .sound(Sound(instrument: SynthMachine.tr909.id, preset: "kick")),
                                author: .user, operation: Operation.written)
        let song = TransportFixture.song([TransportFixture.grooveVersion(), sound])
        #expect(SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(nil)).machine
                    == SynthMachine.tr909.id)

        // A machine this build does not have falls back rather than failing to play.
        let unknown = PartVersion(partID: PartID(), kind: .sound(Sound(instrument: "moog-9000")),
                                  author: .user, operation: Operation.written)
        let other = TransportFixture.song([TransportFixture.grooveVersion(), unknown])
        #expect(SongPlayback.plan(for: other, mediaURL: TransportFixture.resolver(nil)).machine
                    == SynthMachine.tr808.id)
    }

    @Test("A take plays, from the transport position it was aligned to")
    func aTake() {
        let take = TransportFixture.audioVersion(role: .take, duration: 12, offset: 1.5)
        let song = TransportFixture.song([take])
        let plan = SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(media))

        #expect(plan.isPlayable)
        #expect(plan.groove == nil)
        #expect(plan.tracks.count == 1)
        #expect(plan.tracks[0].version == take.id)
        #expect(plan.tracks[0].name == "Record")
        #expect(plan.tracks[0].startsAt == 1.5)
        #expect(plan.tracks[0].duration == 12)
        #expect(plan.audioDuration == 13.5)
        #expect(plan.summary == "Record")
    }

    @Test("Stems rather than the take when the song holds both: the stems are the take")
    func stemsWinOverTheTake() {
        let take = TransportFixture.audioVersion(role: .take, hash: "a")
        let stems = ["drums", "bass", "vocals", "other"].enumerated().map { index, name in
            TransportFixture.audioVersion(role: .stem, stem: name,
                                          hash: TransportFixture.hex(index + 1))
        }
        let song = TransportFixture.song([take] + stems)
        let plan = SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(media))

        #expect(plan.tracks.count == 4)
        #expect(plan.tracks.contains { $0.version == take.id } == false)
        #expect(plan.tracks.map(\.name).contains("Drums stem"))
        #expect(plan.summary == "4 stems")
    }

    @Test("A groove and audio together: both, at the song's own tempo and grid")
    func both() {
        let song = TransportFixture.song([TransportFixture.grooveVersion(),
                                          TransportFixture.audioVersion(role: .take)],
                                         tempo: 96)
        let plan = SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(media))

        #expect(plan.groove != nil)
        #expect(plan.tracks.count == 1)
        #expect(plan.tempo == 96)
        #expect(plan.timeSignature == .fourFour)
        #expect(plan.summary == "Groove · Record")
    }

    @Test("More stems than the engine has players is capped rather than half-scheduled")
    func trackCap() {
        let stems = (0..<6).map { index in
            TransportFixture.audioVersion(role: .stem, stem: "s\(index)",
                                          hash: TransportFixture.hex(index))
        }
        let plan = SongPlayback.plan(for: TransportFixture.song(stems), maximumTracks: 4,
                                     mediaURL: TransportFixture.resolver(media))
        #expect(plan.tracks.count == 4)
    }

    // MARK: Nothing to play

    @Test("No song: the transport says so rather than starting a clock")
    func noSong() throws {
        let plan = SongPlayback.plan(for: nil, mediaURL: TransportFixture.resolver(media))
        #expect(plan.isPlayable == false)
        let silence = try #require(plan.silence)
        #expect(silence.headline == "No song open")
        #expect(silence.detail.isEmpty == false)
    }

    @Test("A song of melodies and lyrics reports what it holds and what would make it sound")
    func nothingPlayable() throws {
        let melody = PartVersion(partID: PartID(), kind: .melody(Melody(notes: [])),
                                 author: .user, operation: Operation.hummed)
        let lyric = PartVersion(partID: PartID(), kind: .lyric(Lyric(lines: [])),
                                author: .user, operation: Operation.written)
        let plan = SongPlayback.plan(for: TransportFixture.song([melody, lyric]),
                                     mediaURL: TransportFixture.resolver(media))

        #expect(plan.isPlayable == false)
        let silence = try #require(plan.silence)
        #expect(silence.headline.contains("Arrival"))
        #expect(silence.detail.contains("melody"))
        #expect(silence.detail.contains("lyric"))
        #expect(plan.summary == silence.headline)
    }

    @Test("A groove with no hits in it is not the same as no groove, and says which")
    func aSilentGroove() throws {
        let song = TransportFixture.song([TransportFixture.grooveVersion(TransportFixture.silentGroove())])
        let plan = SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(media))

        #expect(plan.isPlayable == false)
        #expect(plan.groove == nil)
        let silence = try #require(plan.silence)
        #expect(silence.headline == "The groove is silent")
        #expect(silence.detail.contains("Grid"))
    }

    @Test("Audio whose media is not in the package is not playable, and the reason is the media")
    func missingMedia() throws {
        let song = TransportFixture.song([TransportFixture.audioVersion(role: .take)])
        let plan = SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(nil))

        #expect(plan.isPlayable == false)
        let silence = try #require(plan.silence)
        #expect(silence.headline.contains("audio is missing"))
        #expect(silence.detail.contains("package"))
    }

    @Test("An empty song says it is empty rather than listing nothing")
    func emptySong() throws {
        let plan = SongPlayback.plan(for: Song(title: "Untitled"),
                                     mediaURL: TransportFixture.resolver(media))
        #expect(plan.isPlayable == false)
        #expect(try #require(plan.silence).headline.contains("is empty"))
    }

    // MARK: The chords and the tune

    // The bug: a song could hold a progression, a melody and a chosen pad, and the transport would
    // play the drums and nothing else. Chords were writable, keepable, drawable and auditionable —
    // and had no way onto the transport at all.

    @Test("Chords are playable: the newest progression reaches the plan, and the summary says so")
    func chordsPlay() {
        let plan = SongPlayback.plan(for: TransportFixture.song([TransportFixture.progressionVersion()]),
                                     mediaURL: TransportFixture.resolver(nil))

        #expect(plan.isPlayable, "a song of chords is a song that makes a sound")
        #expect(plan.silence == nil)
        #expect(plan.progression?.chords.count == 4)
        #expect(plan.progressionVersion != nil)
        #expect(plan.summary.contains("Chords"))
    }

    @Test("A tune is playable on its own, and alongside the chords it shares an instrument with")
    func theTunePlays() {
        let chordsOnly = SongPlayback.plan(for: TransportFixture.song([TransportFixture.melodyVersion()]),
                                           mediaURL: TransportFixture.resolver(nil))
        #expect(chordsOnly.isPlayable)
        #expect(chordsOnly.melody?.notes.count == 2)
        #expect(chordsOnly.summary.contains("Tune"))

        let both = SongPlayback.plan(for: TransportFixture.song([TransportFixture.grooveVersion(),
                                                                 TransportFixture.progressionVersion(),
                                                                 TransportFixture.melodyVersion()]),
                                     mediaURL: TransportFixture.resolver(nil))
        #expect(both.groove != nil)
        #expect(both.progression != nil)
        #expect(both.melody != nil)
        #expect(both.summary == "Groove · Chords · Tune")
    }

    @Test("An empty progression is not a sound, the way an empty groove is not")
    func silentChords() {
        let empty = TransportFixture.progressionVersion(Progression(key: Key(tonic: NoteName(.c)), bars: []))
        let plan = SongPlayback.plan(for: TransportFixture.song([empty]),
                                     mediaURL: TransportFixture.resolver(media))
        #expect(plan.isPlayable == false)
        #expect(plan.progression == nil)
    }

    @Test("The song's own Sound part decides which instrument the chords and the tune play on")
    func theSongsInstrument() {
        let bare = SongPlayback.plan(for: TransportFixture.song([TransportFixture.progressionVersion()]),
                                     mediaURL: TransportFixture.resolver(nil))
        #expect(bare.instrument == InstrumentVoiceSpec.rhodes.id, "a song that never chose gets the Rhodes")

        let chosen = SongPlayback.plan(for: TransportFixture.song([TransportFixture.progressionVersion(),
                                                                   TransportFixture.soundVersion(InstrumentVoiceSpec.warmPad.id)]),
                                       mediaURL: TransportFixture.resolver(nil))
        #expect(chosen.instrument == InstrumentVoiceSpec.warmPad.id)
        // A drum machine is not an instrument pick, and does not displace one.
        #expect(chosen.machine == SynthMachine.tr808.id)
    }

    @Test("A part may name its own instrument, and its pick is not the song's")
    func aPartsOwnInstrument() {
        let chords = TransportFixture.progressionVersion()
        let tune = TransportFixture.melodyVersion()
        // The song's own pick, then one for the chords' part only.
        let songWide = TransportFixture.soundVersion(InstrumentVoiceSpec.warmPad.id)
        let forChords = PartVersion(partID: PartID(),
                                    kind: .sound(Sound(instrument: InstrumentVoiceSpec.squareLead.id,
                                                       forPart: chords.partID)),
                                    author: .user, operation: Operation.written)
        let song = TransportFixture.song([chords, tune, songWide, forChords])

        #expect(SongPlayback.instrumentID(for: chords.partID, in: song) == InstrumentVoiceSpec.squareLead.id,
                "the chords play on their own pick")
        #expect(SongPlayback.instrumentID(for: tune.partID, in: song) == InstrumentVoiceSpec.warmPad.id,
                "the tune has no pick of its own, so it takes the song's")
        // The one that would have been quietly wrong: a part's pick becoming everyone's default.
        #expect(SongPlayback.instrumentID(in: song) == InstrumentVoiceSpec.warmPad.id,
                "a part's own instrument is not the song's")

        // With nothing chosen at all, both fall through to the Rhodes.
        let bare = TransportFixture.song([chords])
        #expect(SongPlayback.instrumentID(for: chords.partID, in: bare) == InstrumentVoiceSpec.rhodes.id)
        #expect(SongPlayback.instrumentID(in: bare) == InstrumentVoiceSpec.rhodes.id)

        // And the drum machine is read the same way, off the same list, without confusing the two.
        #expect(SongPlayback.machineID(in: song) == SynthMachine.tr808.id,
                "a pitched pick is not a drum machine")
    }

    @Test("A stitched progression reaches its section, with the bars the section says")
    func chordsInASection() throws {
        let chords = TransportFixture.progressionVersion()
        let groove = TransportFixture.grooveVersion()
        let song = TransportFixture.song([groove, chords], sections: [
            Section(name: "Intro", stitch: [chords].lanes, lengthInBars: 4),
            Section(name: "Loop", stitch: [groove, chords].lanes, lengthInBars: 16),
        ])
        let plan = SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(nil))

        #expect(plan.isArranged)
        #expect(plan.isPlayable)
        let intro = try #require(plan.segments.first)
        #expect(intro.progression != nil)
        #expect(intro.groove == nil)
        #expect(intro.isSounding, "an intro of chords alone is four bars of chords, not four bars of rest")
        #expect(plan.segments[1].progression != nil)
        #expect(plan.segments[1].groove != nil)
        #expect(plan.summary.contains("Chords"))
    }

    @Test("The bar counts what a section doubles, and spells the plural")
    func summaryCountsDoubles() {
        let groove = TransportFixture.grooveVersion()
        let bassA = PartVersion(partID: PartID(), kind: .bassline(Bassline(notes: [
            NoteEvent(pitch: Pitch(midi: 40), start: 0, duration: 1)], sound: "finger")),
            author: .user, operation: Operation.written)
        let bassB = PartVersion(partID: PartID(), kind: .bassline(Bassline(notes: [
            NoteEvent(pitch: Pitch(midi: 45), start: 0, duration: 1)], sound: "sub")),
            author: .user, operation: Operation.written)
        let song = TransportFixture.song([groove, bassA, bassB], sections: [
            Section(name: "Verse", stitch: [groove, bassA].lanes, lengthInBars: 8),
            Section(name: "Loop", stitch: [groove, bassA, bassB].lanes, lengthInBars: 16),
        ])
        let plan = SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(nil))

        #expect(plan.segments[1].voices.count == 3, "the loop plays both bass lines")
        // Not "2 basss", which is what lowercasing the singular and appending an s produces.
        #expect(plan.summary == "2 sections · Groove · 2 bass lines")
    }

    @Test("The loop flag is carried into the plan rather than being a light nothing reads")
    func looping() {
        let plan = SongPlayback.plan(for: TransportFixture.song([TransportFixture.grooveVersion()]),
                                     mediaURL: TransportFixture.resolver(nil))
        #expect(plan.loops == false)
        #expect(plan.looping(true).loops)
        #expect(plan.looping(true).groove == plan.groove)
    }
}

// MARK: - The frame

@Suite("Transport: the frame plays what the plan says", .serialized) @MainActor
struct TransportFrameTests {

    private func app(_ song: Song?, host: StubPlaybackHost,
                     transport: StubTransportHost = StubTransportHost()) -> AppState {
        let state = AppState(library: Library(), song: song, transportHost: transport)
        state.attach(playback: host)
        return state
    }

    @Test("A song with a groove starts: the plan reaches the player and the clock reaches the host")
    func aGroovePlays() async {
        let player = StubPlaybackHost()
        let transport = StubTransportHost()
        let app = self.app(TransportFixture.song([TransportFixture.grooveVersion()], tempo: 113),
                           host: player, transport: transport)

        await app.startTransport()

        #expect(app.transport == .playing)
        #expect(transport.started.count == 1)
        #expect(transport.started[0].tempo == 113)
        let began = await player.began
        #expect(began.count == 1)
        #expect(began[0].groove != nil)
        #expect(app.log.last?.text == "Play")
        #expect(app.log.last?.detail?.contains("Groove") == true)

        await app.stopTransport()
        #expect(app.transport == .stopped)
        #expect(await player.ended == 1)
        #expect(transport.stopped == 1)
        #expect(app.playhead == 0)
    }

    @Test("A song with nothing playable reports not-playable and never touches the audio")
    func nothingToPlay() async throws {
        let player = StubPlaybackHost()
        let transport = StubTransportHost()
        let melody = PartVersion(partID: PartID(), kind: .melody(Melody(notes: [])),
                                 author: .user, operation: Operation.hummed)
        let app = self.app(TransportFixture.song([melody]), host: player, transport: transport)

        await app.startTransport()

        let silence = try #require(app.transport.silence)
        #expect(silence.headline.contains("Arrival"))
        #expect(app.transport.isPlaying == false)
        // The whole point: nothing was started, so nothing has to be stopped.
        #expect(transport.started.isEmpty)
        #expect(await player.began.isEmpty)
        #expect(app.log.last?.source == .session)
        #expect(app.log.last?.text == silence.headline)
    }

    @Test("Pressing play again after a not-playable answer tries again rather than sticking")
    func nothingToPlayIsNotTerminal() async {
        let player = StubPlaybackHost()
        let app = self.app(TransportFixture.song([]), host: player)

        await app.toggleTransport()
        #expect(app.transport.silence != nil)

        // Record a groove into the open song; the plan should notice without a reopen.
        app.record(TransportFixture.grooveVersion())
        #expect(app.playback.isPlayable)

        await app.toggleTransport()
        #expect(app.transport == .playing)
    }

    @Test("No audio device: the engine's own words, and the player is given the graph back")
    func noAudioDevice() async {
        let player = StubPlaybackHost()
        let transport = StubTransportHost()
        transport.failure = NoAudioDevice()
        let app = self.app(TransportFixture.song([TransportFixture.grooveVersion()]),
                           host: player, transport: transport)

        await app.startTransport()

        #expect(app.transport == .unavailable("no audio device"))
        #expect(app.transport.isPlaying == false)
        // Begun, then unwound: a half-started transport must not leave sources on the engine.
        #expect(await player.began.count == 1)
        #expect(await player.ended == 1)
    }

    @Test("A player that cannot schedule reports why rather than claiming to play")
    func playerFailure() async {
        let player = StubPlaybackHost(failure: NoAudioDevice())
        let app = self.app(TransportFixture.song([TransportFixture.grooveVersion()]), host: player)

        await app.startTransport()
        #expect(app.transport == .unavailable("no audio device"))
    }

    @Test("With no player attached at all the frame says so instead of pretending")
    func noPlayerAttached() async {
        let app = AppState(library: Library(),
                           song: TransportFixture.song([TransportFixture.grooveVersion()]),
                           transportHost: StubTransportHost())
        await app.startTransport()
        #expect(app.transport.isPlaying == false)
        if case .unavailable(let reason) = app.transport {
            #expect(reason.contains("no player"))
        } else {
            Issue.record("expected .unavailable, got \(app.transport)")
        }
    }

    // MARK: Following

    @Test("The section strip follows the playhead, from the sections' own bar lengths")
    func sectionsFollowTheBar() {
        let app = self.app(TransportFixture.song([TransportFixture.grooveVersion()], tempo: 120),
                           host: StubPlaybackHost())
        let sections = app.song!.sections
        // 120 bpm, 4/4: a bar is two seconds. Intro is bars 0..<4, Verse 4..<20.
        #expect(app.section(atSeconds: 0) == sections[0].id)
        #expect(app.section(atSeconds: 7.9) == sections[0].id)
        #expect(app.section(atSeconds: 8.1) == sections[1].id)
        #expect(app.section(atSeconds: 39) == sections[1].id)
        // Past the end it stays on the last section rather than going nil mid-play.
        #expect(app.section(atSeconds: 500) == sections[1].id)
    }

    @Test("A song with no sections has nothing to follow, and says nothing")
    func noSections() {
        let app = self.app(TransportFixture.song([TransportFixture.grooveVersion()], sections: []),
                           host: StubPlaybackHost())
        #expect(app.section(atSeconds: 4) == nil)
    }

    @Test("The position readout is bar and beat, and is quiet until something plays")
    func positionReadout() async {
        let player = StubPlaybackHost()
        let app = self.app(TransportFixture.song([TransportFixture.grooveVersion()], tempo: 120),
                           host: player)
        #expect(app.playhead == 0)
        #expect(app.positionText == "1.1")
        #expect(app.elapsedText == "0:00")

        await player.report(PlaybackReading(isRunning: true, seconds: 9.5, scheduledHits: 12))
        await app.startTransport()
        #expect(app.transport == .playing)

        // The poll runs on the main actor; wait for it to land rather than assuming a tick.
        await waitUntil { app.playhead > 0 }
        #expect(abs(app.playhead - 9.5) < 0.001)
        // 9.5 s at 120 bpm is bar 5 (0-based 4), beat 4 of that bar (0-based 3).
        #expect(app.positionText == "5.4")
        #expect(app.elapsedText == "0:09")
        #expect(app.activeSection == app.song?.sections.last?.id)
        // And following playback is not something you did: the rail is not filled with it.
        #expect(app.log.filter { $0.text.hasPrefix("Moved to") }.isEmpty)

        await app.stopTransport()
    }

    @Test("When the plan runs out the transport stops itself rather than staying lit")
    func playbackEndsTheTransport() async {
        let player = StubPlaybackHost()
        let app = self.app(TransportFixture.song([TransportFixture.grooveVersion()]), host: player)

        await app.startTransport()
        #expect(app.transport == .playing)

        await player.report(PlaybackReading(isRunning: false, seconds: 40))
        await waitUntil { app.transport == .stopped }
        #expect(app.transport == .stopped)
        #expect(await player.ended >= 1)
    }

    @Test("Loop is carried into the plan and says when it takes effect")
    func loop() async {
        let player = StubPlaybackHost()
        let app = self.app(TransportFixture.song([TransportFixture.grooveVersion()]), host: player)

        app.toggleLoop()
        #expect(app.isLooping)
        #expect(app.playback.loops)

        await app.startTransport()
        #expect(await player.began.first?.loops == true)
        await app.stopTransport()
    }

    /// Waits for a main-actor condition, with a bound so a failure is a failure rather than a hang.
    private func waitUntil(_ condition: @MainActor () -> Bool, within seconds: Double = 2) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
