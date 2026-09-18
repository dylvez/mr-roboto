import AVFAudio
import Analysis
import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// The Gate A guidance layer: what the rail offers, what a ledger row does, and what opening a song
// puts in front of you.
//
// One invariant runs through all of it and is worth naming, because it is the thing that made the
// app feel broken before: **nothing is offered that does not work when it is pressed.** So these
// tests do not check that a suggestion exists — they press it, and check a surface arrived bound to
// the right versions. A suggestion that opened nothing would pass a "the list is non-empty" test and
// fail every one of these.

// MARK: - Fixtures

@MainActor
enum GuidanceFixture {

    static let bpm = 120.0
    /// Four beats at 120 bpm.
    static let barLength = 2.0
    static let duration = 32.0
    /// The drums come in on bar 5. Bar 1 is an intro the stem is silent through, which is exactly
    /// the case "chop a bar" must not walk into.
    static let drumsEnter = 8.0

    /// A believable whole-track analysis: a key, a beat grid with downbeats, bars, one section, and
    /// instrument activity that starts late.
    static func analysis() -> MusicAnalysis {
        var beats: [BeatMarker] = []
        var bars: [SongGraph.TimeRange] = []
        var time = 0.0
        var index = 0
        while time < duration {
            let isDownbeat = index % 4 == 0
            beats.append(BeatMarker(time: time, isDownbeat: isDownbeat))
            if isDownbeat, time + barLength <= duration {
                bars.append(SongGraph.TimeRange(start: time, end: time + barLength))
            }
            time += 60 / bpm
            index += 1
        }
        return MusicAnalysis(duration: duration,
                             keys: [SongGraph.KeyRange(start: 0, end: duration,
                                                       key: Key(tonic: NoteName(.d), mode: .ionian))],
                             beats: beats,
                             bars: bars,
                             tempo: [TempoRange(start: 0, end: duration, bpm: bpm)],
                             sections: [SectionRange(start: 0, end: duration)],
                             instruments: [SongGraph.InstrumentActivity(
                                 instrument: .drums,
                                 ranges: [SongGraph.TimeRange(start: drumsEnter, end: duration)])],
                             loudness: Loudness(integrated: -13.5),
                             analyzer: "fixture")
    }

    static func media(_ seed: Character) -> MediaRef {
        MediaRef(hash: ContentHash(hex: String(repeating: seed, count: 64))!, fileExtension: "wav")
    }

    /// A song plus handles on the versions in it, so a test can name what it expects to be bound.
    struct Built {
        var song: Song
        var analysis: PartVersion
        var take: PartVersion
        var stems: [String: PartVersion] = [:]
        var sample: PartVersion?
        var groove: PartVersion?
        var sound: PartVersion?
    }

    /// Nothing in it at all. Not a mistake and not a prompt for invented work.
    static func emptySong(title: String = "Untitled") -> Song { Song(title: title, tempo: bpm) }

    /// A record, analysed and imported, and nothing else. What `m0 import` leaves behind.
    static func imported(title: String = "Arrival") -> Built {
        var song = Song(title: title, artist: "Vessel", key: Key(tonic: NoteName(.d), mode: .ionian),
                        tempo: bpm)
        let analysisVersion = PartVersion(partID: PartID(), kind: .analysis(analysis()), author: .user,
                                          operation: Operation.imported, note: "analysis of Arrival.mp3")
        let take = PartVersion(partID: PartID(),
                               kind: .audio(Audio(media: media("a"), role: .take, sampleRate: 44_100,
                                                  channelCount: 2, duration: duration)),
                               author: .user, operation: Operation.imported,
                               note: "the record, as imported")
        try? song.append(analysisVersion)
        try? song.append(take)
        return Built(song: song, analysis: analysisVersion, take: take)
    }

    /// The same record with its four stems separated out.
    static func separated() -> Built {
        var built = imported()
        for (seed, name) in zip("bcde", ["bass", "drums", "other", "vocals"]) {
            let stem = PartVersion(partID: PartID(),
                                   kind: .audio(Audio(media: media(seed), role: .stem, stem: name,
                                                      sampleRate: 44_100, channelCount: 2,
                                                      duration: duration)),
                                   author: .user, parents: [built.take.id],
                                   operation: Operation.separate, note: "\(name) stem of Arrival")
            try? built.song.append(stem)
            built.stems[name] = stem
        }
        return built
    }

    /// A bar of the drums, cut.
    static func chopped() -> Built {
        var built = separated()
        let drums = built.stems["drums"]!
        let sample = drums.spawning(.sample(Sample(media: media("c"),
                                                   slices: [SliceMarker(position: drumsEnter)],
                                                   detectedTempo: bpm)),
                                    by: .user, operation: Operation.chop, note: "Bar 5 of drums stem")
        try? built.song.append(sample)
        built.sample = sample
        return built
    }

    /// The chop re-grooved, which is what puts something in the Grid.
    static func grooved() -> Built {
        var built = chopped()
        let groove = built.sample!.spawning(.groove(GridModel.emptyGroove()), by: .user,
                                            operation: Operation.regroove, note: "Motown, 120")
        try? built.song.append(groove)
        built.groove = groove
        return built
    }

    /// One version of every `PartType` there is, over a real analysis so the chopable ones are
    /// chopable. The ledger has to have an answer — including "nothing" — for each of these.
    static func everyKind() -> Built {
        var built = grooved()
        let sound = PartVersion(partID: PartID(), kind: .sound(SoundState().sound), author: .user,
                                operation: Operation.written, note: "tr808 kick")
        try? built.song.append(sound)
        built.sound = sound

        let key = Key(tonic: NoteName(.d), mode: .ionian)
        let others: [PartKind] = [
            .progression(Progression(key: key, bars: [ProgressionBar(Chord(key.tonic.pitchClass, .major))])),
            .melody(Melody(notes: [])),
            .lyric(Lyric(lines: [])),
            .bassline(Bassline(notes: [])),
        ]
        for kind in others {
            try? built.song.append(PartVersion(partID: PartID(), kind: kind, author: .user,
                                               operation: Operation.written))
        }
        return built
    }

    /// A real `AppState` over a real temporary library, which is what `canPerform` wants to see
    /// before it will offer anything that writes.
    static func app(_ song: Song?, in directory: URL) -> AppState {
        AppState(library: Library(), song: nil, store: LibraryStore(directoryURL: directory),
                 status: .empty(directory), transportHost: StubTransportHost())
    }

    static func temporaryDirectory(_ label: String = "guidance") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MrRoboto-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Opening a song

@Suite("Guidance: opening a song") @MainActor
struct GuidanceOpeningTests {

    @Test("opening a song puts the record on the bench, bound to its take and its analysis")
    func openingPopulatesTheBench() {
        let directory = GuidanceFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = GuidanceFixture.separated()
        let app = GuidanceFixture.app(nil, in: directory)

        app.open(built.song)

        let item = try? #require(app.bench.items.first)
        #expect(app.bench.items.count == 1)
        #expect(item?.kind == .importRecord)
        #expect(item.map { app.bound(for: $0.id) } == [built.take.id, built.analysis.id])
        // The accented row is the record itself, not its analysis.
        #expect(app.selectedVersion == built.take.id)
    }

    @Test("a song with no record opens on the newest thing anyone made in it")
    func openingFallsBackToTheNewestWork() {
        let directory = GuidanceFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var song = Song(title: "Sketch", tempo: 120)
        let groove = PartVersion(partID: PartID(), kind: .groove(GridModel.emptyGroove()),
                                 author: .user, operation: Operation.written, note: "straight, 120")
        try? song.append(groove)
        let app = GuidanceFixture.app(nil, in: directory)

        app.open(song)

        #expect(app.bench.items.first?.kind == .grid)
        #expect(app.bench.items.first.map { app.bound(for: $0.id) } == [groove.id])
    }

    @Test("an empty song opens on nothing rather than on a surface with a shrug in it")
    func openingAnEmptySongOpensNothing() {
        let directory = GuidanceFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = GuidanceFixture.app(nil, in: directory)

        app.open(GuidanceFixture.emptySong())

        #expect(app.bench.items.isEmpty)
        #expect(app.log.contains { $0.text == "Opened Untitled" })
    }

    @Test("opening a second song clears the first song's bench before filling it")
    func openingAgainReplacesTheBench() {
        let directory = GuidanceFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = GuidanceFixture.app(nil, in: directory)

        app.open(GuidanceFixture.separated().song)
        let first = try? #require(app.bench.items.first?.id)
        app.open(GuidanceFixture.imported(title: "Second").song)

        #expect(app.bench.items.count == 1)
        #expect(app.bench.items.first?.id != first)
        #expect(first.map { app.bound(for: $0).isEmpty } == true)
    }
}

// MARK: - What next

@Suite("Guidance: what next") @MainActor
struct GuidanceSuggestionTests {

    /// Every state the Gate A workflow passes through, by the name the milestone gives it.
    private static let states: [(String, Song)] = {
        MainActor.assumeIsolated {
            [("imported", GuidanceFixture.imported().song),
             ("separated", GuidanceFixture.separated().song),
             ("chopped", GuidanceFixture.chopped().song),
             ("grooved", GuidanceFixture.grooved().song),
             ("everything", GuidanceFixture.everyKind().song)]
        }
    }()

    @Test("an empty song suggests nothing, and so does no song at all")
    func emptyButHonest() {
        let directory = GuidanceFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = GuidanceFixture.app(nil, in: directory)

        #expect(Guidance.proposals(for: nil).isEmpty)
        #expect(app.proposals.isEmpty)

        app.open(GuidanceFixture.emptySong())

        #expect(Guidance.proposals(for: app.song).isEmpty)
        #expect(app.proposals.isEmpty, "an empty song must not have work invented for it")
    }

    @Test("every suggestion, in every state, opens a surface bound to what it named")
    func noDeadSuggestions() {
        for (name, song) in Self.states {
            let proposals = Guidance.proposals(for: song)
            #expect(!proposals.isEmpty, "\(name) should have something to suggest")

            for proposal in proposals {
                // A fresh frame per suggestion: the bench holds three, and what is under test is
                // that *this* suggestion opens something, not that four of them fit.
                let directory = GuidanceFixture.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let app = GuidanceFixture.app(nil, in: directory)
                app.open(song)
                let before = app.bench.items.count

                #expect(app.canPerform(proposal.action),
                        "\(name): \"\(proposal.title)\" is offered but cannot be carried out")
                guard let id = app.perform(proposal.action) else {
                    Issue.record("\(name): \"\(proposal.title)\" opened nothing")
                    continue
                }
                let item = app.bench.items.first { $0.id == id }
                #expect(item?.kind == proposal.action.surface,
                        "\(name): \"\(proposal.title)\" opened \(item?.kind.rawValue ?? "nothing")")
                #expect(app.bench.items.count >= before)

                switch proposal.action.prepare {
                case .none:
                    #expect(app.bound(for: id) == proposal.action.bound)
                case .chopBar:
                    // Preparation binds what it made, so the lane is not opened on nothing.
                    let bound = app.bound(for: id)
                    #expect(bound.count == 1)
                    #expect(bound.first.flatMap { app.version($0)?.type } == .sample)
                case .separateStems:
                    #expect(app.requests[id] != nil, "the surface was opened but never asked to run")
                }
            }
        }
    }

    @Test("the rail only ever shows suggestions the frame could carry out")
    func theRailFiltersOnWhatWorks() {
        let directory = GuidanceFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = GuidanceFixture.app(nil, in: directory)
        app.open(GuidanceFixture.grooved().song)

        #expect(!app.proposals.isEmpty)
        #expect(app.proposals.allSatisfy { app.canPerform($0.action) })

        // A proposal naming a version this song does not hold — a stale one, or one that arrives
        // from somewhere else later — is refused rather than drawn.
        let stale = SurfaceAction(surface: .grid, title: "Ghost", bound: [VersionID()])
        #expect(!app.canPerform(stale))
        #expect(app.perform(stale) == nil)
    }

    @Test("the suggestions follow the workflow: stems, then a chop, then a groove, then the Grid")
    func theSuggestionsFollowTheWorkflow() {
        #expect(Guidance.proposals(for: GuidanceFixture.imported().song).first?.title == "Separate the stems")
        #expect(Guidance.proposals(for: GuidanceFixture.separated().song).first?.title == "Chop a bar of the drums")
        #expect(Guidance.proposals(for: GuidanceFixture.chopped().song).first?.title.hasPrefix("Re-groove") == true)
        #expect(Guidance.proposals(for: GuidanceFixture.grooved().song).first?.title.hasSuffix("in the Grid") == true)
    }

    @Test("a session with nowhere to write is not offered separation")
    func separationNeedsALibrary() {
        // No store: the Preview and test case. Separation writes stems into the song's package, so
        // offering it here would be the dead suggestion this design forbids.
        let app = AppState(library: Library(), song: GuidanceFixture.imported().song,
                           transportHost: StubTransportHost())
        #expect(Guidance.proposals(for: app.song).contains { $0.title == "Separate the stems" })
        #expect(!app.proposals.contains { $0.title == "Separate the stems" })
    }

    @Test("the rail renders whatever the Director puts in it, held to the same standard")
    func theDirectorSeamUsesTheSameList() {
        let directory = GuidanceFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = GuidanceFixture.grooved()
        let app = GuidanceFixture.app(nil, in: directory)
        app.open(built.song)

        app.director = [
            Proposal(title: "Try it at 96", rationale: "slower",
                     action: SurfaceAction(surface: .grid, title: "96", bound: [built.groove!.id]),
                     source: .persona("Nile")),
            Proposal(title: "Open a part that is not here", rationale: "stale",
                     action: SurfaceAction(surface: .grid, title: "Ghost", bound: [VersionID()]),
                     source: .persona("Nile")),
        ]

        #expect(app.proposals.count == 1, "a persona's dead proposal is filtered exactly like ours")
        #expect(app.proposals.first?.title == "Try it at 96")
        #expect(app.proposals.first?.source == .persona("Nile"))
    }
}

// MARK: - The parts ledger

@Suite("Guidance: parts ledger") @MainActor
struct GuidanceLedgerTests {

    /// Which surface each kind of part belongs in. `nil` is an answer: Gate A builds four surfaces
    /// and none of them edits a progression, a melody, a lyric or a bassline, so those rows select
    /// and say nothing rather than offering a button that opens nothing.
    private static let expected: [PartType: SurfaceKind?] = [
        .analysis: .importRecord,
        .audio: .chopLane,          // a stem; the take is checked separately
        .sample: .chopLane,
        .groove: .grid,
        .sound: .sound,
        .progression: .chords,
        .melody: nil,
        .lyric: nil,
        .bassline: .pianoRoll,
    ]

    @Test("every PartKind has an answer, and it is the right surface")
    func everyKindIsAnswered() throws {
        let built = GuidanceFixture.everyKind()
        let song = built.song
        var seen: Set<PartType> = []

        for version in song.versions {
            let action = PartActions.primary(for: version, in: song)
            seen.insert(version.type)

            // The take is the one `audio` that is not a stem: it shows the record.
            if case .audio(let audio) = version.kind, audio.role == .take {
                #expect(action?.action.surface == .importRecord)
                continue
            }
            let wanted = try #require(Self.expected[version.type])
            #expect(action?.action.surface == wanted,
                    "\(version.type.rawValue) offered \(action?.action.surface.rawValue ?? "nothing")")
        }

        #expect(seen == Set(PartType.allCases), "the fixture has to cover every kind for this to mean anything")
    }

    @Test("a ledger action opens its surface bound to that very version")
    func aLedgerActionBindsTheRowItCameFrom() throws {
        let directory = GuidanceFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = GuidanceFixture.everyKind()
        let app = GuidanceFixture.app(nil, in: directory)
        app.open(built.song)

        for (version, kind) in [(built.sample!, SurfaceKind.chopLane),
                                (built.groove!, SurfaceKind.grid),
                                (built.sound!, SurfaceKind.sound)] {
            let action = try #require(PartActions.primary(for: version, in: app.song!)).action
            let id = try #require(app.perform(action))
            #expect(app.bench.items.first { $0.id == id }?.kind == kind)
            #expect(app.bound(for: id) == [version.id],
                    "\(kind.rawValue) was not bound to the row that opened it")
            #expect(app.selectedVersion == version.id, "opening a row should accent it too")
        }
    }

    @Test("a drum stem's action cuts a real bar, on the beat the drums come in, and opens the lane on it")
    func aStemChopsABar() throws {
        let directory = GuidanceFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = GuidanceFixture.separated()
        let app = GuidanceFixture.app(nil, in: directory)
        app.open(built.song)
        let drums = try #require(built.stems["drums"])

        let action = try #require(PartActions.primary(for: drums, in: app.song!)).action
        let id = try #require(app.perform(action))

        let cut = try #require(app.bound(for: id).first.flatMap { app.version($0) })
        #expect(app.bench.items.first { $0.id == id }?.kind == .chopLane)
        guard case .sample(let sample) = cut.kind else {
            Issue.record("the lane was not opened on a sample")
            return
        }
        // The media is the *stem's*, so the lane reads drums, not the whole mix.
        #expect(sample.media == GuidanceFixture.media("c"))
        #expect(cut.parents == [drums.id])
        #expect(cut.operation == Operation.chop)
        // Bar 5 — where the drums enter — not bar 1, which is an intro they are silent through.
        #expect(sample.slices.map(\.position) == [GuidanceFixture.drumsEnter])
        #expect(sample.detectedTempo == GuidanceFixture.bpm)
    }

    @Test("chopping the same stem twice reopens the chop rather than cutting another")
    func choppingIsIdempotent() throws {
        let directory = GuidanceFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = GuidanceFixture.separated()
        let app = GuidanceFixture.app(nil, in: directory)
        app.open(built.song)
        let drums = try #require(built.stems["drums"])

        let firstAction = try #require(PartActions.primary(for: drums, in: app.song!)).action
        let first = try #require(app.perform(firstAction))
        let samples = app.versions.filter { $0.type == .sample }.count
        let secondAction = try #require(PartActions.primary(for: drums, in: app.song!)).action
        let second = try #require(app.perform(secondAction))

        #expect(app.versions.filter { $0.type == .sample }.count == samples)
        #expect(first == second, "the second press should return to the lane, not open a twin")
        #expect(app.bench.items.filter { $0.kind == .chopLane }.count == 1)
    }

    @Test("a part Gate A cannot edit offers nothing rather than a button that opens nothing")
    func inertKindsSayNothing() {
        let built = GuidanceFixture.everyKind()
        for version in built.song.versions where [.melody, .lyric].contains(version.type) {
            #expect(PartActions.primary(for: version, in: built.song) == nil)
        }
    }

    @Test("a stem in a song with no analysis offers nothing: there is no bar to cut")
    func noAnalysisMeansNoChop() {
        var song = Song(title: "Unanalysed", tempo: 120)
        let take = PartVersion(partID: PartID(),
                               kind: .audio(Audio(media: GuidanceFixture.media("a"), role: .take,
                                                  sampleRate: 44_100, channelCount: 2, duration: 32)),
                               author: .user, operation: Operation.imported)
        let stem = PartVersion(partID: PartID(),
                               kind: .audio(Audio(media: GuidanceFixture.media("b"), role: .stem,
                                                  stem: "drums", sampleRate: 44_100, channelCount: 2,
                                                  duration: 32)),
                               author: .user, parents: [take.id], operation: Operation.separate)
        try? song.append(take)
        try? song.append(stem)

        #expect(PartActions.primary(for: stem, in: song) == nil)
        #expect(!Guidance.proposals(for: song).contains { $0.title == "Chop a bar of the drums" })
    }
}

// MARK: - The dock

@Suite("Guidance: the dock") @MainActor
struct GuidanceDockTests {

    @Test("every surface picked by name opens, and opens on something useful when there is something")
    func everyDockChipOpens() throws {
        let directory = GuidanceFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = GuidanceFixture.everyKind()
        let app = GuidanceFixture.app(nil, in: directory)
        app.open(built.song)

        let bindings: [SurfaceKind: [VersionID]] = [
            .importRecord: [built.take.id, built.analysis.id],
            .chopLane: [built.sample!.id],
            .grid: [built.groove!.id],
            .sound: [built.sound!.id],
            .chords: [built.song.versions.first { $0.type == .progression }!.id],
            .pianoRoll: [built.song.versions.first { $0.type == .bassline }!.id],
            .structure: [],
        ]
        for kind in SurfaceKind.gateA {
            let action = Guidance.dockAction(for: kind, in: app.song)
            #expect(app.canPerform(action))
            #expect(action.bound == bindings[kind], "\(kind.rawValue) opened on the wrong part")
            // One at a time: the bench holds three and a retired surface is not what is under test.
            let id = try #require(app.perform(action))
            #expect(app.bench.items.first { $0.id == id }?.kind == kind)
            app.closeSurface(id)
        }
    }

    @Test("with no song every surface still opens, unbound, because every one of them is usable empty")
    func theDockWorksWithNothingOpen() throws {
        let directory = GuidanceFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = GuidanceFixture.app(nil, in: directory)

        for kind in SurfaceKind.gateA {
            let action = Guidance.dockAction(for: kind, in: nil)
            #expect(action.bound.isEmpty)
            #expect(app.canPerform(action))
            let id = try #require(app.perform(action))
            app.closeSurface(id)
        }
    }
}

// MARK: - Showing a song that was already imported

@Suite("Guidance: the record of an imported song") @MainActor
struct GuidanceRecordSurfaceTests {

    /// A short real file. Real, because the waveform, the durations and the package are the point;
    /// short, because none of that needs three minutes of audio to be true.
    private static func writeTone(to url: URL, seconds: Double = 2, sampleRate: Double = 44_100) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frames) {
            samples[frame] = Float(sin(2 * .pi * 220 * Double(frame) / sampleRate) * 0.4)
        }
        try file.write(from: buffer)
    }

    private static func report(path: String, duration: Double, bpm: Double = 120) -> AnalysisReport {
        var report = AnalysisReport(sourcePath: path, duration: duration)
        report.key = KeyEstimate(key: Key(tonic: NoteName(.d), mode: .ionian), duration: duration)
        var beats: [Double] = []
        var downbeats: [Double] = []
        var time = 0.0
        var index = 0
        while time < duration {
            beats.append(time)
            if index % 4 == 0 { downbeats.append(time) }
            time += 60 / bpm
            index += 1
        }
        report.beats = BeatTrackingResult(beats: beats, downbeats: downbeats, bpm: bpm)
        report.structure = StructureAnalysis(sections: [Analysis.TimeRange(start: 0, end: duration)])
        report.loudness = LoudnessAnalysis(integrated: -13.4, truePeak: -0.8)
        report.instruments = Analysis.InstrumentActivity(presence: [
            .drums: [Analysis.TimeRange(start: 0, end: duration)],
        ])
        report.capabilities = [.key, .beats, .structure, .loudness, .instrumentActivity]
        report.provenance = [.key: "stub", .beats: "stub"]
        return report
    }

    @Test("a song already in the library reaches the state an import leaves behind")
    func adoptingASong() async throws {
        let directory = GuidanceFixture.temporaryDirectory("record")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Tone.wav")
        try Self.writeTone(to: source)

        // Import it once, the ordinary way, so the library holds a real song package.
        let library = LibraryStore(directoryURL: directory.appendingPathComponent("Library"))
        let info = try AudioFileInfo.read(source)
        let importer = ImportModel(host: StubImportHost(
            library: library, report: Self.report(path: source.path, duration: info.duration)))
        await importer.run(source)
        #expect(importer.state.phase == .ready)

        let song = try #require(try library.load().songs.first)

        // Now reach the same surface from the other end: a fresh model, handed the song.
        let reader = ImportModel(host: StubImportHost(
            library: library, report: Self.report(path: source.path, duration: info.duration)))
        reader.open(song)
        await reader.waitForCompletion()

        #expect(reader.state == .ready(song.id))
        #expect(reader.title == song.title)
        #expect(!reader.waveform.isEmpty, "the record has to be on screen, not described")
        #expect(abs(reader.waveform.duration - info.duration) < 0.1)
        #expect(!reader.downbeats.isEmpty)
        #expect(reader.detectedTempo == 120)
        #expect(reader.detectedKey != nil)
        #expect(reader.barCount > 0)
        #expect(reader.stems.isEmpty)
        #expect(reader.canSeparateStems, "the one thing this record is missing should be offered")

        // And the lever the surface exists for still works on an adopted song: promoting a bar is
        // how the Chop lane is reached, and it must not care which end the surface was filled from.
        let bar = try #require(reader.range(ofBar: 0))
        let promoted = try reader.promote(bar)
        #expect(promoted.type == .sample)
        #expect(promoted.parents.count == 1)
    }

    @Test("separating an already-imported record hands its stems back as versions in the package")
    func separatingAnAdoptedSong() async throws {
        let directory = GuidanceFixture.temporaryDirectory("separate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Tone.wav")
        try Self.writeTone(to: source)
        let drums = directory.appendingPathComponent("drums.wav")
        try Self.writeTone(to: drums, seconds: 2)

        let library = LibraryStore(directoryURL: directory.appendingPathComponent("Library"))
        let info = try AudioFileInfo.read(source)
        let report = Self.report(path: source.path, duration: info.duration)
        let importer = ImportModel(host: StubImportHost(library: library, report: report))
        await importer.run(source)
        let song = try #require(try library.load().songs.first)

        let host = StubImportHost(library: library, report: report, stems: [.drums: drums])
        let reader = ImportModel(host: host)
        reader.open(song)
        await reader.waitForCompletion()
        #expect(reader.canSeparateStems)

        reader.separateStems()
        await reader.waitForCompletion()

        #expect(reader.state.phase == .ready)
        #expect(reader.stems.map(\.name) == [.drums])
        #expect(!reader.canSeparateStems, "a record with stems is not missing stems")

        // The stem reached the host as a part version, which is how it reaches the parts ledger.
        let committed = host.log.committed.filter { version in
            if case .audio(let audio) = version.kind { return audio.role == .stem }
            return false
        }
        #expect(committed.count == 1)
        #expect(committed.first?.operation == Operation.separate)

        // …and its bytes are in the song's own package, not in the scratch directory.
        let package = try library.songStore(for: song.id)
        let media = try #require(committed.first?.mediaReferences.first)
        #expect(package.hasMedia(media))
        #expect(reader.stems.first?.url.path.hasPrefix(package.packageURL.path) == true)
    }
}
