import AudioEngine
import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// A song could take from two records once, by making a third song of them, and from none after.
// These are a song taking a stem or some bars from any record in the library, whenever it likes:
// fitted to its key, tempo and bars, seated in the sections that play it, and fitted again from the
// untouched record when it lands in the wrong place.

@MainActor
enum SourcesFixture {
    /// The mashup of the fixture's two songs (Arrival's other, Exit Interview's drums) at 100 bpm in
    /// D, Lead-in 1 · Verse 3 · Chorus 4, open. A bar is 2.4 s, a beat 0.6.
    static func mashup(_ label: String) async throws -> (app: AppState, directory: URL, a: Song, b: Song) {
        let directory = WiringFixture.temporaryDirectory(label)
        let (app, a, b) = try MashupFixture.app(in: directory)
        app.autosaveDelay = nil
        _ = try await app.makeMashup(MashupRequest(a: a.id, b: b.id, backbone: .a, stemsA: ["other"], stemsB: ["drums"]))
        return (app, directory, a, b)
    }

    /// The worst distance of a rendered file's clicks from the song's beats, given where its first
    /// frame sounds.
    static func worstOffBeat(_ url: URL, laidAt offset: Double, beat: Double = 0.6) throws -> (worst: Double, count: Int) {
        let onsets = try MashupFixture.onsets(url)
        let worst = onsets.map { onset -> Double in
            let beats = (offset + onset) / beat
            return abs(beats - beats.rounded()) * beat
        }.max() ?? 1
        return (worst, onsets.count)
    }
}

@Suite("Sources: any record's stem in the open song", .serialized) @MainActor
struct SourcesTests {

    @Test("a third record's vocal in a mashup: fitted, laid from bar 2, in every section, every click on the song's beat")
    func whole() async throws {
        let (app, directory, _, b) = try await SourcesFixture.mashup("sources-whole")
        defer { WiringFixture.remove(directory) }
        let before = try #require(app.song)
        #expect(Sources.candidates(in: app.library, open: before).count == 2)

        let version = try await app.addSource(SourceRequest(song: b.id, stem: "vocals", atBar: 1))
        let song = try #require(app.song)
        let audio = try #require(Guidance.audio(of: version))
        let fit = try #require(audio.fit)
        #expect(version.operation == Operation.fitted && audio.role == .stem && audio.stem == "vocals")
        #expect(fit.label == "Exit Interview" && fit.song == b.id && fit.atBar == 1 && !fit.isClip)
        #expect(abs(fit.ratio - 1.2) < 1e-9 && fit.semitones == -2 && !fit.byEar)
        #expect(PartLabel.title(of: version) == "Vocals of Exit Interview")
        #expect(audio.sourceRecord == app.library.records.first { $0.title == "Exit Interview" }?.id, "a source to clear")
        #expect(song.mediaReferences.contains(audio.media) && !song.mediaReferences.contains(fit.media),
                "the render is the song's; the record it was read from is not held")

        // Every section plays it, beside the two stems it came in with, and it is a track at its offset.
        #expect(song.sections.allSatisfy { $0.stitch.contains(part: version.partID) })
        #expect(app.playback.tracks.count == 3)
        let track = try #require(app.playback.tracks.first { $0.part == version.partID })
        #expect(abs(track.startsAt - (audio.alignmentOffset ?? -1)) < 1e-9 && abs((audio.alignmentOffset ?? 0) - 2.1) < 1e-9)
        #expect(StemLanesFixture.close(track.windows, [0..<8 * 2.4]))

        // The proof: the record's first downbeat on bar 2, and every click after it on a beat.
        let url = try #require(app.store).mediaURL(for: audio.media, song: song.id)
        let (worst, count) = try SourcesFixture.worstOffBeat(url, laidAt: audio.alignmentOffset ?? 0)
        #expect(count >= 20 && worst < 0.015, "\(count) clicks, the worst \(worst * 1000) ms off")

        // A stem laid on the grid is in no analysis's seconds: no bar of it is offered to chop.
        #expect(Guidance.barToChop(of: version, in: song) == nil)
    }

    @Test("two bars of a record looped in the Verse only: exactly two bars, a chop that loops, a grid of its own")
    func clip() async throws {
        let (app, directory, a, _) = try await SourcesFixture.mashup("sources-clip")
        defer { WiringFixture.remove(directory) }
        let verse = try #require(app.song?.sections.first { $0.name == "Verse" })
        let version = try await app.addSource(SourceRequest(song: a.id, stem: "bass", bars: 1..<3, sections: [verse.id]))
        let song = try #require(app.song)
        guard case .sample(let sample) = version.kind else { Issue.record("a clip is a chop"); return }
        let fit = try #require(sample.fit)
        #expect(fit.isClip && fit.fromBar == 1 && fit.toBar == 3 && fit.atBar == nil && fit.stem == "bass")
        #expect(sample.span == SongGraph.TimeRange(start: 0, end: 4.8) && sample.detectedTempo == 100 && sample.slices.count == 2)
        #expect(PartLabel.title(of: version) == "Bass of Arrival, bars 2–3")
        #expect(song.sections.map { $0.stitch.contains(part: version.partID) } == [false, true, false])

        // The media is the two bars to the frame, and the chop loops two of the song's bars.
        let url = try #require(app.store).mediaURL(for: sample.media, song: song.id)
        let info = try AudioFileInfo.read(url)
        #expect(abs(info.duration - 4.8) < 1.0 / 48_000)
        let chop = try #require(app.playback.segments.first { $0.name == "Verse" }?.voices.compactMap(\.chop).first)
        #expect(abs((chop.loopSeconds(songTempo: 100, beatsPerBar: 4) ?? 0) - 4.8) < 1e-9)
        #expect(app.playback.segments.filter { $0.name != "Verse" }.allSatisfy { $0.voices.compactMap(\.chop).isEmpty })

        // A bass clip is not drums, whatever its slices are called; the lane's grid is its own bars.
        #expect(!Guidance.hasDrums(version, in: song))
        let grid = try #require(ChopLaneBinding.grid(span: sample.span!, tempo: 100, beatsPerBar: 4))
        #expect(grid.beats.count == 8 && grid.bars == [0, 2.4])
    }

    @Test("fitted again: another semitone, then a bar later, each a new version of the same part from the untouched record")
    func refit() async throws {
        let (app, directory, _, b) = try await SourcesFixture.mashup("sources-refit")
        defer { WiringFixture.remove(directory) }
        let first = try await app.addSource(SourceRequest(song: b.id, stem: "vocals", atBar: 1))
        let up = try await app.refitSource(first.partID, semitones: 0)
        #expect(up.partID == first.partID && up.parents == [first.id] && up.operation == Operation.fitted)
        let upFit = try #require(Guidance.audio(of: up)?.fit)
        #expect(upFit.semitones == 0 && upFit.byEar && upFit.media == Guidance.audio(of: first)?.fit?.media, "read from the record, not the render")
        #expect(app.song?.sections.allSatisfy { $0.stitch.contains(part: first.partID) } == true, "the form follows the part")
        #expect(app.playback.tracks.contains { $0.version == up.id })

        let later = try await app.refitSource(first.partID, semitones: 0, atBar: 2)
        let offset = try #require(Guidance.audio(of: later)?.alignmentOffset)
        #expect(abs(offset - (2.1 + 2.4)) < 1e-9 && Guidance.audio(of: later)?.fit?.atBar == 2)

        // A part that was not pulled in has nothing to fit again.
        let current = try #require(app.song)
        let other = try #require(Guidance.stems(in: current).first)
        await #expect(throws: SourceError.notFitted) { try await app.refitSource(other.partID, semitones: nil) }
    }

    @Test("a blank song takes the first record's key, tempo and form; the record is not moved")
    func blank() async throws {
        let directory = WiringFixture.temporaryDirectory("sources-blank")
        defer { WiringFixture.remove(directory) }
        let (app, a, _) = try MashupFixture.app(in: directory)
        app.autosaveDelay = nil
        app.open(Song.new(title: "From records"))
        #expect(app.song?.isBlank == true && app.takesGrid(SourceRequest(song: a.id, stem: "other")))
        let version = try await app.addSource(SourceRequest(song: a.id, stem: "other"))
        let song = try #require(app.song)
        #expect(song.tempo == 100 && song.key == a.key)
        #expect(song.sections.map(\.name) == ["Verse", "Chorus"] && song.sections.map(\.lengthInBars) == [3, 4],
                "\(song.sections.map { "\($0.name) \($0.lengthInBars)" })")
        #expect(song.sections.allSatisfy { $0.stitch.contains(part: version.partID) })
        let fit = try #require(Guidance.audio(of: version)?.fit)
        #expect(fit.semitones == 0 && fit.ratio == 1)
        #expect(app.playback.isArranged && app.playback.tracks.map(\.part) == [version.partID])

        // A clip into a blank song is a loop of its bars, eight bars long.
        app.open(Song.new(title: "A loop"))
        let loop = try await app.addSource(SourceRequest(song: a.id, stem: "bass", bars: 0..<2))
        #expect(app.song?.sections.map(\.name) == ["Loop"] && app.song?.sections.first?.lengthInBars == 8)
        #expect(app.song?.sections.first?.stitch.contains(part: loop.partID) == true)
    }

    @Test("a song whose form names nothing plays a source along with its own record, and its first form carries it")
    func formless() async throws {
        let directory = WiringFixture.temporaryDirectory("sources-formless")
        defer { WiringFixture.remove(directory) }
        let (app, a, b) = try MashupFixture.app(in: directory)
        app.autosaveDelay = nil
        app.open(a)
        let version = try await app.addSource(SourceRequest(song: b.id, stem: "vocals"))
        let song = try #require(app.song)
        #expect(song.sections.isEmpty && !app.playback.isArranged)
        // Arrival's own stems, at its own placing, and the vocal where its fit laid it.
        #expect(app.playback.tracks.count == 3 && app.playback.tracks.last?.part == version.partID)
        #expect(abs((app.playback.tracks.last?.startsAt ?? -1) - (Guidance.audio(of: version)?.alignmentOffset ?? 0)) < 1e-9)
        #expect(app.playback.tracks.last?.stretch == 1)
        #expect(song.seatedStems == [version.partID])
        #expect(FormTools.defaultStitch(in: song).contains(part: version.partID))
    }

    @Test("bars that do not exist are refused, the open song is not its own source, and a song with no analysis gives nothing")
    func refusals() async throws {
        let (app, directory, a, _) = try await SourcesFixture.mashup("sources-refusals")
        defer { WiringFixture.remove(directory) }
        #expect(throws: SourceError.noBars("Arrival", 6)) { try app.sourcePick(SourceRequest(song: a.id, stem: "bass", bars: 9..<10)) }
        #expect(throws: SourceError.noStem("vocals", "Arrival")) { try app.sourcePick(SourceRequest(song: a.id, stem: "vocals")) }
        let open = try #require(app.song)
        #expect(throws: SourceError.sameSong) { try app.sourcePick(SourceRequest(song: open.id, stem: "other")) }
        #expect(Sources.candidates(in: app.library, open: nil).allSatisfy { $0.id != open.id }, "a mashup has no record of its own to give")
    }

    @Test("a preview is eight of the song's bars: a clip looped through them, the song under it")
    func preview() async throws {
        let (app, directory, a, _) = try await SourcesFixture.mashup("sources-preview")
        defer { WiringFixture.remove(directory) }
        let request = SourceRequest(song: a.id, stem: "bass", bars: 0..<1)
        let alone = try await app.previewSource(request, fromBar: 0, bars: 8, withSong: false)
        #expect(alone.planar.count == 2 && alone.planar[0].count == Int(8 * 2.4 * alone.sampleRate))
        // One bar of clicks looped: four in every bar of the eight.
        let peaks = (0..<8).map { bar in alone.planar[0][Int(Double(bar) * 2.4 * alone.sampleRate)..<Int(Double(bar + 1) * 2.4 * alone.sampleRate)].map(abs).max() ?? 0 }
        #expect(peaks.allSatisfy { $0 > 0.1 }, "\(peaks)")
        let under = try await app.previewSource(request, fromBar: 0, bars: 8, withSong: true)
        let energy = { (planar: [[Float]]) in planar[0].reduce(0) { $0 + Double($1 * $1) } }
        #expect(under.planar[0].count == alone.planar[0].count && energy(under.planar) > energy(alone.planar) * 1.2)
    }

    @Test("one level for a record: toward the loudness of the records already in the song")
    func level() async throws {
        let directory = WiringFixture.temporaryDirectory("sources-level")
        defer { WiringFixture.remove(directory) }
        let (app, a, b) = try MashupFixture.app(in: directory)
        app.autosaveDelay = nil
        // Arrival read at −16 LUFS, Exit Interview at −9: the vocal comes in 7 dB down.
        for (song, lufs) in [(a, -16.0), (b, -9.0)] {
            var copy = try #require(app.library.song(song.id))
            let read = try #require(copy.versions.last { $0.type == .analysis })
            guard case .analysis(var analysis) = read.kind else { return }
            analysis.loudness = Loudness(integrated: lufs)
            // Read again, now with its loudness: the newest analysis is the one the stems are read by.
            try copy.append(read.deriving(.analysis(analysis), by: .user, operation: Operation.analyzed))
            var library = app.library
            library.upsert(copy)
            try app.store!.save(library)
            app.reloadLibrary()
        }
        app.open(try #require(app.library.song(a.id)))
        let pick = try app.sourcePick(SourceRequest(song: b.id, stem: "vocals"))
        #expect(pick.fit.recordLUFS == -9 && pick.fit.gainDB == -7)
        #expect(app.sentences(for: pick, request: SourceRequest(song: b.id, stem: "vocals")).contains { $0.hasPrefix("Down 7.0 dB") })
        let version = try await app.addSource(SourceRequest(song: b.id, stem: "drums"))
        #expect(Guidance.audio(of: version)?.fit?.gainDB == -7, "every stem of a record takes the same level")
        let clip = try await app.addSource(SourceRequest(song: b.id, stem: "vocals", bars: 0..<1))
        #expect(SourceFitting.fit(of: clip)?.gainDB == -7, "and its bars")
        // A third record now sits with what is there: the fitted record's level, not the song's own.
        let song = try #require(app.song)
        #expect(Sources.levelTarget(in: song, library: app.library) == -16)
    }

    @Test("twenty-four strips and players: three records' stems and the parts over them all play and mix")
    func room() {
        #expect(MixGraph.slotCount == 24 && SongPlayback.playerNodes == 24)
    }

    @Test("a fit round-trips, and a version without one writes what it always wrote")
    func coding() throws {
        let media = MediaRef(hash: ContentHash(hex: String(repeating: "a", count: 64))!, fileExtension: "wav")
        let fit = SourceFit(label: "Exit Interview", media: media, song: SongID(), stem: "vocals", start: 0.25,
                            atBar: 1, semitones: -2, ratio: 1.2, key: Key(tonic: NoteName(.e)), tempo: 120, recordLUFS: -9, gainDB: -7)
        let audio = Audio(media: media, role: .stem, stem: "vocals", sampleRate: 48_000, channelCount: 1, duration: 10, alignmentOffset: 2.1, fit: fit)
        let back = try JSONDecoder().decode(Audio.self, from: JSONEncoder().encode(audio))
        #expect(back == audio)
        let plain = Audio(media: media, role: .stem, stem: "vocals", sampleRate: 48_000, channelCount: 1, duration: 10)
        #expect(!(String(data: try JSONEncoder().encode(plain), encoding: .utf8) ?? "").contains("fit"))
        let sample = Sample(media: media, span: SongGraph.TimeRange(start: 0, end: 4.8), fit: SourceFit(label: "A", media: media, stem: "bass", start: 2.9, end: 7.7, fromBar: 1, toBar: 3))
        #expect(try JSONDecoder().decode(Sample.self, from: JSONEncoder().encode(sample)) == sample)
        #expect(!(String(data: try JSONEncoder().encode(Sample(media: media)), encoding: .utf8) ?? "").contains("fit"))
    }
}

@Suite("Sources: the surface", .serialized) @MainActor
struct SourcesSurfaceTests {

    @Test("opens on a song with something to give, the voice chosen, every section on; a clip chooses the sections with no chop")
    func defaults() async throws {
        let (app, directory, a, b) = try await SourcesFixture.mashup("sources-model")
        defer { WiringFixture.remove(directory) }
        let model = SourcesModel(app: app)
        #expect(model.candidates.map(\.title) == ["Arrival", "Exit Interview"])
        #expect(model.records.isEmpty, "the fixture's records were never read, so the crate offers none")
        #expect(model.from == .song(a.id) && model.stem == "bass", "Arrival has no voice: its first stem")
        model.from = .song(b.id)
        #expect(model.stem == "vocals" && model.sections.count == 3 && model.blocker == nil)
        #expect(model.sentences.first?.contains("down 2 semitones to D major") == true, "\(model.sentences)")
        model.nudge(by: 1)
        #expect(model.semitones == -1 && model.request?.semitones == -1)
        model.resetSemitones()

        // Some bars of Arrival's bass for the Verse: the sections with no chop are all of them, until one has one.
        model.from = .song(a.id)
        model.choose(stem: "bass")
        model.isClip = true
        model.fromBar = 2
        model.toBar = 3
        #expect(model.request?.bars == 1..<3 && model.sections.count == 3)
        let verse = try #require(app.song?.sections.first { $0.name == "Verse" })
        model.sections = [verse.id]
        let added = try #require(await model.add())
        #expect(model.inSong.map(\.id) == [added.id] && model.line(for: added).hasPrefix("bars 2–3, looped"))
        model.isClip = false
        model.isClip = true
        #expect(!model.sections.contains(verse.id), "the Verse plays a chop now")

        // Fitted again from the list: a semitone up is a new version of the same part.
        await model.refit(added.partID, semitones: 1)
        #expect(app.song?.latestVersion(of: added.partID)?.parents == [added.id])
        #expect(model.lastError == nil)

        // Nothing to choose sections for in a song whose form names nothing.
        app.open(try #require(app.library.song(a.id)))
        model.follow()
        #expect(!model.choosesSections && model.from == .song(b.id))
    }
}

@Suite("Sources: the Director", .serialized) @MainActor
struct SourcesDirectorTests {

    @Test("read_library says what each song gives; adopt brings a stem in, then some bars, then fits the stem again")
    func adopt() async throws {
        let (app, directory, a, b) = try await SourcesFixture.mashup("sources-director")
        defer { WiringFixture.remove(directory) }
        let toolbox = DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4)),
                                            workspace: AppStateWorkspace(app))
        func json(_ result: ClaudeToolResult) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any]) ?? [:]
        }
        let library = await toolbox.run(ClaudeToolUse(id: "l", name: "read_library", input: .object([])))
        let songs = json(library)["songs"] as? [[String: Any]] ?? []
        let exit = try #require(songs.first { $0["title"] as? String == "Exit Interview" })
        #expect(exit["stems"] as? [String] == ["vocals", "drums", "full"] && exit["record_bars"] as? Int == 5 && exit["record_tempo"] as? Double == 120)

        let whole = await toolbox.run(ClaudeToolUse(id: "w", name: "adopt", input: .object([
            .init("kind", .string("song")), .init("id", .string(b.id.description)), .init("stem", .string("vocals")),
            .init("at_bar", .int(2)),
        ])))
        #expect(!whole.isError, "\(whole.content)")
        let out = json(whole)
        #expect((out["sentences"] as? [String])?.contains { $0.contains("bar 2 of the song") } == true)
        #expect((out["sections"] as? [String]) == ["Lead-in", "Verse", "Chorus"])
        let vocal = try #require(app.song?.fittedSources.first)
        #expect(vocal.author == .persona("Director"))

        let bars = await toolbox.run(ClaudeToolUse(id: "b", name: "adopt", input: .object([
            .init("kind", .string("song")), .init("id", .string(a.title)), .init("stem", .string("bass")),
            .init("bars", .array([.int(2), .int(3)])),
        ])))
        #expect(!bars.isError, "\(bars.content)")
        #expect(app.song?.fittedSources.count == 2 && app.song?.fittedSources.last?.type == .sample)

        let again = await toolbox.run(ClaudeToolUse(id: "f", name: "adopt", input: .object([
            .init("kind", .string("fitted")), .init("id", .string(vocal.id.description)), .init("at_bar", .int(3)),
        ])))
        #expect(!again.isError, "\(again.content)")
        let refit = try #require(app.song?.latestVersion(of: vocal.partID))
        #expect(refit.parents == [vocal.id] && Guidance.audio(of: refit)?.fit?.atBar == 2)

        let wrong = await toolbox.run(ClaudeToolUse(id: "x", name: "adopt", input: .object([
            .init("kind", .string("song")), .init("id", .string(a.id.description)), .init("stem", .string("vocals")),
        ])))
        #expect(wrong.isError && wrong.content.contains("no vocals stem"))
    }
}

@MainActor
enum DriftFixture {
    /// A library holding "Drifter": twenty bars of clicks, one on every beat from 0.5 s, each bar at
    /// its own tempo between 95 and 105 bpm (100 on average), separated into a drums stem, its
    /// analysis's bars on its real bar lines and a second tracker agreeing on `agreement` of its
    /// beats. And "Kit", open: 100 bpm, one section of 24 bars playing a groove. A bar is 2.4 s.
    ///   - misread: the analysis's bar lines wrong for eight bars in the middle — read at a tempo
    ///     a fifth faster, then a long bar to catch up — as victor 1's are.
    static func app(_ label: String, agreement: Double?, misread: Bool = false) throws -> (app: AppState, directory: URL, drifter: Song) {
        let directory = WiringFixture.temporaryDirectory(label)
        let store = LibraryStore(directoryURL: directory)
        var library = Library()
        var drifter = Song(title: "Drifter", key: Key(tonic: NoteName(.d)), tempo: 100)
        library.upsert(drifter)
        try store.save(library)
        var beats: [BeatMarker] = [], bars: [SongGraph.TimeRange] = []
        var time = 0.5
        for bar in 0..<20 {
            let beat = 60 / (100 + 5 * sin(Double(bar) * 0.9))
            let start = time
            for index in 0..<4 { beats.append(BeatMarker(time: time, isDownbeat: index == 0)); time += beat }
            bars.append(SongGraph.TimeRange(start: start, end: time))
        }
        let seconds = time + 1
        if misread {
            for index in 5..<13 {
                let start = index == 5 ? bars[5].start : bars[index - 1].end
                bars[index] = SongGraph.TimeRange(start: start, end: start + 1.9)
            }
            bars[13].start = bars[12].end
        }
        var samples = [Float](repeating: 0, count: Int(seconds * MashupFixture.rate))
        for beat in beats {
            let at = Int(beat.time * MashupFixture.rate)
            for i in 0..<240 where at + i < samples.count { samples[at + i] = Float(0.8 * sin(2 * .pi * 1_000 * Double(i) / MashupFixture.rate)) * Float(1 - Double(i) / 240) }
        }
        let package = try store.songStore(for: drifter.id)
        let scratch = directory.appendingPathComponent("drifter.wav")
        try BoothAdapter.write([samples], sampleRate: MashupFixture.rate, to: scratch)
        let media = try package.addMedia(copying: scratch)
        let take = PartVersion(partID: PartID(), kind: .audio(Audio(media: media, role: .take, sampleRate: MashupFixture.rate, channelCount: 1, duration: seconds)),
                               author: .user, operation: Operation.imported, note: "Record")
        try drifter.append(take)
        let analysis = MusicAnalysis(duration: seconds, keys: [KeyRange(start: 0, end: seconds, key: drifter.key!)], beats: beats, bars: bars,
                                     tempo: [TempoRange(start: 0, end: seconds, bpm: 100)],
                                     beatCheck: agreement.map { BeatGridCheck(checker: "beat-this", agreement: $0, primaryBPM: 100, checkerBPM: 100, usedChecker: false) })
        try drifter.append(PartVersion(partID: PartID(), kind: .analysis(analysis), author: .user, parents: [take.id], operation: Operation.analyzed))
        try drifter.append(PartVersion(partID: PartID(), kind: .audio(Audio(media: media, role: .stem, stem: "drums", sampleRate: MashupFixture.rate, channelCount: 1, duration: seconds)),
                                       author: .user, parents: [take.id], operation: Operation.separate, note: "drums stem"))
        library.upsert(drifter)
        library.records.append(Record(title: "Drifter", media: media))
        var kit = Song(title: "Kit", key: Key(tonic: NoteName(.d)), tempo: 100)
        let groove = TransportFixture.grooveVersion()
        try kit.append(groove)
        kit.sections = [Section(name: "Song", stitch: [Lane(part: groove.partID)], lengthInBars: 24)]
        library.upsert(kit)
        try store.save(library)
        let app = AppState(library: try store.load(), store: store, transportHost: StubTransportHost())
        app.autosaveDelay = nil
        app.open(try #require(app.library.song(kit.id)))
        return (app, directory, drifter)
    }
}

@Suite("Sources: tightened to the grid", .serialized) @MainActor
struct SourcesTightenTests {

    @Test("tight: every click of a drifting record on the song's beat, twenty bars in; as recorded it drifts off")
    func tight() async throws {
        let (app, directory, drifter) = try DriftFixture.app("tighten-on", agreement: 0.92)
        defer { WiringFixture.remove(directory) }
        let request = SourceRequest(song: drifter.id, stem: "drums", atBar: 1)
        let pick = try app.sourcePick(request)
        #expect(pick.plan.isTightened && pick.plan.held == 0 && pick.declined == nil)
        #expect(app.sentences(for: pick, request: request).contains { $0.hasPrefix("Tightened") })
        let tight = try await app.addSource(request)
        let audio = try #require(Guidance.audio(of: tight))
        #expect(audio.fit?.tightened == true)
        let store = try #require(app.store)
        let song = try #require(app.song)
        let (worst, count) = try SourcesFixture.worstOffBeat(try store.mediaURL(for: audio.media, song: song.id), laidAt: audio.alignmentOffset ?? 0)
        #expect(count >= 76 && worst < 0.01, "\(count) clicks, the worst \(worst * 1000) ms off the beat")

        // Let loose: the same record at one stretch wanders a good part of a beat off.
        let loose = try await app.refitSource(tight.partID, semitones: nil, tighten: false)
        let looseAudio = try #require(Guidance.audio(of: loose))
        #expect(loose.parents == [tight.id] && looseAudio.fit?.tightened == false)
        let (drift, _) = try SourcesFixture.worstOffBeat(try store.mediaURL(for: looseAudio.media, song: song.id), laidAt: looseAudio.alignmentOffset ?? 0)
        #expect(drift > 0.05, "as recorded it drifts \(drift * 1000) ms")

        // And tightened again, kept that way through "fit again".
        let again = try await app.refitSource(tight.partID, semitones: nil, tighten: true)
        let refit = try await app.refitSource(again.partID, semitones: nil)
        #expect(SourceFitting.fit(of: refit)?.tightened == true)
    }

    @Test("bars of it tightened: a loop of exactly its bars whose clicks are on the song's beats")
    func clip() async throws {
        let (app, directory, drifter) = try DriftFixture.app("tighten-clip", agreement: 0.92)
        defer { WiringFixture.remove(directory) }
        let clip = try await app.addSource(SourceRequest(song: drifter.id, stem: "drums", bars: 2..<6))
        guard case .sample(let sample) = clip.kind else { Issue.record("a clip is a chop"); return }
        #expect(sample.fit?.tightened == true && sample.span?.duration == 4 * 2.4)
        let url = try #require(app.store).mediaURL(for: sample.media, song: try #require(app.song).id)
        let (worst, count) = try SourcesFixture.worstOffBeat(url, laidAt: 0)
        #expect(count == 16 && worst < 0.01, "\(count) clicks, the worst \(worst * 1000) ms off")
    }

    @Test("bar lines that look misread leave it as recorded and say why; asked, it is tightened all the same; the trackers do not decide")
    func misread() async throws {
        let (app, directory, drifter) = try DriftFixture.app("tighten-misread", agreement: 0.92, misread: true)
        defer { WiringFixture.remove(directory) }
        let request = SourceRequest(song: drifter.id, stem: "drums")
        let pick = try app.sourcePick(request)
        let declined = try #require(pick.declined)
        #expect(!pick.plan.isTightened && declined.held > 2)
        #expect(app.sentences(for: pick, request: request).contains { $0.contains("look misread") && $0.contains("Tighten it to try anyway") })
        var asked = request
        asked.tighten = true
        let forced = try app.sourcePick(asked)
        #expect(forced.plan.isTightened && forced.plan.looksMisread && forced.plan.flags.contains { $0.contains("held") })

        // A clean grid the trackers disagree on, as victor2's and russianfreedom's: tightened.
        let (clean, cleanDirectory, cleanDrifter) = try DriftFixture.app("tighten-clean", agreement: 0.16)
        defer { WiringFixture.remove(cleanDirectory) }
        #expect(try clean.sourcePick(SourceRequest(song: cleanDrifter.id, stem: "drums")).plan.isTightened)
    }
}

@Suite("Sources: tightened by the Director", .serialized) @MainActor
struct SourcesTightenDirectorTests {

    @Test("adopt with tighten on tightens a record its trackers disagree on; fitted with tighten off lets it loose")
    func adopt() async throws {
        let (app, directory, drifter) = try DriftFixture.app("tighten-director", agreement: 0.4)
        defer { WiringFixture.remove(directory) }
        let toolbox = DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4)),
                                            workspace: AppStateWorkspace(app))
        let on = await toolbox.run(ClaudeToolUse(id: "t", name: "adopt", input: .object([
            .init("kind", .string("song")), .init("id", .string(drifter.title)), .init("stem", .string("drums")),
            .init("bars", .array([])), .init("at_bar", .int(0)), .init("tighten", .string("on")),
        ])))
        #expect(!on.isError, "\(on.content)")
        let source = try #require(app.song?.fittedSources.first)
        #expect(SourceFitting.fit(of: source)?.tightened == true)
        #expect(on.content.contains("Tightened"))

        let off = await toolbox.run(ClaudeToolUse(id: "o", name: "adopt", input: .object([
            .init("kind", .string("fitted")), .init("id", .string(source.partID.description)), .init("stem", .string("")),
            .init("bars", .array([])), .init("at_bar", .int(0)), .init("tighten", .string("off")),
        ])))
        #expect(!off.isError, "\(off.content)")
        let loose = try #require(app.song?.latestVersion(of: source.partID))
        #expect(loose.parents == [source.id] && SourceFitting.fit(of: loose)?.tightened == false)
        #expect(SourceFitting.fit(of: loose)?.atBar == SourceFitting.fit(of: source)?.atBar, "at_bar 0 leaves it where it was")
    }
}
