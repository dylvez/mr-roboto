import AVFAudio
import AudioEngine
import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// A take sung at one tempo, the song's tempo changed after: the take plays in its section at the
// song's tempo, stretched with its pitch kept, and every reader of it agrees where it is.

@Suite("Takes follow a tempo change", .serialized)
struct TakeTempoTests {

    /// 4 s at 48 kHz: a bar of count-in at 120 (2 s), then 1 s of 440 Hz, then silence.
    static func takeFile() throws -> URL {
        let rate = 48_000.0
        let frames = Int(4 * rate)
        let tone = (0..<frames).map { i -> Float in
            let t = Double(i) / rate
            return (2..<3).contains(t) ? Float(0.5 * sin(2 * .pi * 440 * t)) : 0
        }
        let url = TransportFixture.temporaryDirectory("tempo-take").appendingPathComponent("take.wav")
        try BoothAdapter.write([tone], sampleRate: rate, to: url)
        return url
    }

    /// Verse then Hook, nothing stitched, and a take sung to the Hook at 120 bpm: counted in from
    /// bar 3, the take itself on bar 4 where the Hook begins.
    static func song(tempo: Double, sungAt sung: Double? = 120) throws -> (song: Song, take: PartVersion) {
        var song = Song(title: "Glass", artist: "Tests", tempo: 120)
        song.sections = [Section(name: "Verse", stitch: [], lengthInBars: 4), Section(name: "Hook", stitch: [], lengthInBars: 2)]
        let recorded = TransportFixture.audioVersion(role: .take, duration: 4)
        guard case .audio(var audio) = recorded.kind else { throw CocoaError(.featureUnsupported) }
        audio.channelCount = 1
        audio.take = Take(section: song.sections[1].id, startBar: 4, sectionStartBar: 4, tempo: sung)
        audio.alignmentOffset = 6
        let take = PartVersion(partID: PartID(), kind: .audio(audio), author: .user, operation: Operation.recorded)
        try song.append(take)
        song.tempo = tempo
        return (song, take)
    }

    @Test("the plan puts the take on the Hook's bar at the new tempo, stretched to it")
    func planned() throws {
        let (song, _) = try Self.song(tempo: 100)
        let track = try #require(SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(URL(fileURLWithPath: "/dev/null"))).tracks.first)
        let clock = TransportClock(tempo: 100, timeSignature: .fourFour)
        #expect(abs(track.stretch - 1.2) < 1e-9)
        #expect(abs(track.startsAt - (clock.seconds(forBar: 4) - 0.05)) < 1e-6, "\(track.startsAt)")
        #expect(abs(track.skip - (clock.secondsPerBar - 0.05)) < 1e-6, "the count-in bar, at the new tempo")
        #expect(abs(track.duration - 4.8) < 1e-6)

        // Sung before the tempo was kept: played as it was sung.
        let (old, _) = try Self.song(tempo: 100, sungAt: nil)
        #expect(SongPlayback.plan(for: old, mediaURL: TransportFixture.resolver(URL(fileURLWithPath: "/dev/null"))).tracks.first?.stretch == 1)
    }

    @Test("bounced at 100 bpm, a take sung at 120 sounds on the Hook's first beat, 20% longer, at its own pitch")
    @AudioActor
    func bounced() async throws {
        let url = try Self.takeFile()
        let kits = TransportFixture.temporaryDirectory("tempo-kits")
        defer {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: kits)
        }
        let (song, _) = try Self.song(tempo: 100)
        let plan = SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(url))
        let stems = try await SectionBounce.render(plan, kitsDirectory: kits, onlyTheMix: true, mastered: false)
        let rate = stems.sampleRate
        let mix = stems.mix[0]
        func rms(_ from: Double, _ to: Double) -> Double {
            let lane = mix[Int(from * rate)..<min(mix.count, Int(to * rate))]
            return sqrt(lane.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, lane.count)))
        }
        // The Hook starts at bar 4: 9.6 s at 100. The tone was the take's first beat and a bit —
        // 1 s at 120 — and is 1.2 s now.
        #expect(rms(9.7, 10.7) > 0.2, "the tone, on the Hook's first beat")
        #expect(rms(8.0, 9.5) < 0.01, "nothing where it was sung, at 8 s")
        #expect(rms(11.0, 12.0) < 0.02, "and over by 10.8 s")
        // Its pitch: zero crossings over the held part.
        let held = mix[Int(9.8 * rate)..<Int(10.6 * rate)]
        let crossings = zip(held, held.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        let hz = Double(crossings) / 2 / 0.8
        #expect(abs(hz - 440) < 6, "\(hz) Hz")
    }

    @Test("a stretched take is made once and read from the cache after, only the newest kept; at 1 it is the file itself")
    func cached() throws {
        let url = try Self.takeFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try TakePlacement.url(url, stretch: 1) == url)
        #expect(try BoothAdapter.planar(url).planar[0].count == 192_000, "the take, read whole")
        let first = try TakePlacement.url(url, stretch: 0.8)
        let made = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date
        let second = try TakePlacement.url(url, stretch: 0.8)
        #expect(first == second)
        #expect(try FileManager.default.attributesOfItem(atPath: second.path)[.modificationDate] as? Date == made)
        let (planar, rate) = try BoothAdapter.planar(first)
        #expect(abs(Double(planar[0].count) / rate - 3.2) < 0.01, "\(planar[0].count) frames at \(rate), \(planar.count) channels")
        let other = try TakePlacement.url(url, stretch: 1.25)
        #expect(other != first)
        #expect(!FileManager.default.fileExists(atPath: first.path), "only the newest stretch of a take is kept")
        try? FileManager.default.removeItem(at: other)
    }

    @Test("a take corrected from a Check still plays in its section: it is placed by the take it came from")
    func correctedPlays() throws {
        var (song, take) = try Self.song(tempo: 120)
        guard case .audio(var corrected) = take.kind else { return }
        corrected.take = nil
        let fixed = take.deriving(.audio(corrected), by: .user, operation: Operation.corrected, note: "corrected")
        try song.append(fixed)
        let resolver = TransportFixture.resolver(URL(fileURLWithPath: "/dev/null"))
        let track = try #require(SongPlayback.plan(for: song, mediaURL: resolver).tracks.first)
        #expect(track.version == fixed.id)
        #expect(abs(track.startsAt - (TransportClock(tempo: 120, timeSignature: .fourFour).seconds(forBar: 4) - 0.05)) < 1e-6,
                "\(track.startsAt), \(track.skip), \(fixed.parents), \(take.id)")
    }

    @Test("the Takes lanes draw a take where the song plays it, and a comp keeps the tempo it was made at")
    @MainActor
    func lanesAndComps() throws {
        let (song, take) = try Self.song(tempo: 100)
        let clock = TransportClock(tempo: 100, timeSignature: .fourFour)
        let span = try #require(TakesModel.seconds(of: take, clock: clock, song: song))
        #expect(abs(span.start - clock.seconds(forBar: 4)) < 1e-6)
        #expect(abs(span.end - (6 * 1.2 + 4.8)) < 1e-6, "from the count-in's second at 100, for 4.8 s")

        let plan = BoothAdapter.placed(CompPlan(spans: [.init(startBar: 4, endBar: 6, take: take.id)]), takes: [take], in: song)
        #expect(plan.tempo == 100)
        let comp = Audio(media: TransportFixture.audioVersion(role: .take).kind.audioMedia!, role: .take, sampleRate: 48_000,
                         channelCount: 1, duration: 4, alignmentOffset: 9.6, comp: plan)
        var faster = song
        faster.tempo = 125
        #expect(abs(comp.stretch(in: faster) - 0.8) < 1e-9)
        #expect(comp.stretch(in: song) == 1)
    }

    @Test("a Check's fix after the tempo changed shifts the note the lanes flagged, in the take's own audio, and the fix plays in place")
    @MainActor
    func correctedAfterATempoChange() async throws {
        let directory = LibraryFixture.directory("tempo-check")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory)
        let app = AppState(library: Library(), song: nil, store: store, status: .empty(directory), transportHost: StubTransportHost())
        // Sung at 120; the song is at 100 now.
        var song = Song(title: "Arrival", artist: "Vessel", key: Key(tonic: NoteName(.d)), tempo: 100)
        song.sections = [Section(name: "Verse", stitch: [], lengthInBars: 4)]
        app.open(song)
        app.save()
        let package = try store.songStore(for: song.id)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sung-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try BoothAdapter.write(SungTake.planar(), sampleRate: SungTake.rate, to: scratch)
        let media = try package.addMedia(copying: scratch)
        let audio = Audio(media: media, role: .take, sampleRate: SungTake.rate, channelCount: 1, duration: 2.2, alignmentOffset: SungTake.alignment,
                          take: Take(section: song.sections[0].id, startBar: 1, input: "Stub mic", pass: 1, sectionStartBar: 0, tempo: 120))
        let take = PartVersion(partID: PartID(), kind: .audio(audio), author: .user, operation: Operation.recorded, note: "Take 1, Verse")
        #expect(app.record(take))

        // The flag as the lanes read it: the take at the song's tempo.
        let heard = try #require(BoothAdapter(app: app, service: SurfaceWiring.shared.service(for: app)).audio(of: take))
        #expect(abs(heard.alignmentSeconds - SungTake.alignment * 1.2) < 1e-9)
        #expect(abs(Double(heard.planar[0].count) / heard.sampleRate - 2.2 * 1.2) < 0.01)
        let analysis = TakeAnalysis.of(heard.planar, sampleRate: heard.sampleRate, alignmentSeconds: heard.alignmentSeconds,
                                       key: song.key, clock: app.clock, label: "Take 1")
        let pitch = try #require(CriticBoard.standard.review(TakeReview(analysis: analysis)).first { $0.critic == .pitchDrift })
        #expect(pitch.subject == .bar(1), "still the second bar's note at 100")

        let adapter = CheckAdapter(app: app, service: SurfaceWiring.shared.service(for: app), subject: take.id)
        let outcome = await adapter.apply(pitch.fixes[0], of: pitch)
        guard case .resolved = outcome else { Issue.record("expected resolved, got \(outcome)"); return }
        let corrected = try #require(app.song?.versions.last)
        let correctedAudio = try #require(Guidance.audio(of: corrected))
        // The take's own audio, read as it was sung: the sharp note is in tune, the others as they were.
        let planar = try BoothAdapter.planar(try store.mediaURL(for: correctedAudio.media, song: song.id))
        let after = TakeAnalysis.of(planar.planar, sampleRate: planar.sampleRate, alignmentSeconds: SungTake.alignment, key: song.key, clock: SungTake.clock)
        #expect(after.notes.count == 4 && abs(after.notes[1].centsFromKey) < 5, "\(after.notes.map(\.centsFromKey))")
        #expect(abs(Double(planar.planar[0].count) / planar.sampleRate - 2.2) < 0.01, "the fix is in the take's length, not the song's")

        // The song plays the fix where the take was, stretched as the take was; the record is not it.
        let current = try #require(app.song)
        #expect(Guidance.take(in: current) == nil)
        let track = try #require(app.playback.tracks.first)
        #expect(track.version == corrected.id && abs(track.stretch - 1.2) < 1e-9)
    }

    @Test("set_song says the sung takes follow the new tempo, and which were sung before tempos were kept")
    @MainActor
    func setSongSaysSo() async throws {
        let (sung, _) = try Self.song(tempo: 120)
        var song = sung
        let old = TransportFixture.audioVersion(role: .take, duration: 4, hash: "b")
        guard case .audio(var audio) = old.kind else { return }
        audio.take = Take(startBar: 0, pass: 1)
        try song.append(PartVersion(partID: PartID(), kind: .audio(audio), author: .user, operation: Operation.recorded))
        let rig = WritingFixture.rig(song)
        defer { rig.clean() }
        let result = await WritingFixture.run(rig.box, "set_song", #"{"title":"","artist":"","tempo":100,"key":"","time_signature":""}"#)
        let detail = WritingFixture.json(result)["detail"] as? String ?? ""
        #expect(detail.contains("The sung take plays stretched to 100 bpm, pitch kept — up to 20%"), "\(detail)")
        #expect(detail.contains("One take was sung before tempos were kept and is not stretched"), "\(detail)")
        #expect(rig.app.log.contains { $0.detail?.contains("sung takes follow it") == true })
    }

    @Test("in 3/4 now, a take sung in 4/4 to the Hook starts on the Hook's first bar, its count-in before it")
    func meterChanged() throws {
        var song = Song(title: "Glass", artist: "Tests", tempo: 120)
        song.sections = [Section(name: "Verse", stitch: [], lengthInBars: 20), Section(name: "Hook", stitch: [], lengthInBars: 4)]
        let recorded = TransportFixture.audioVersion(role: .take, duration: 12)
        guard case .audio(var audio) = recorded.kind else { return }
        // Counted in from bar 19 of 4/4 at 120: the audio starts at 38 s, the take at 40 s.
        audio.take = Take(section: song.sections[1].id, startBar: 20, sectionStartBar: 20, tempo: 120, meter: .fourFour)
        audio.alignmentOffset = 38
        try song.append(PartVersion(partID: PartID(), kind: .audio(audio), author: .user, operation: Operation.recorded))
        song.timeSignature = TimeSignature(beatsPerBar: 3)
        let track = try #require(SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(URL(fileURLWithPath: "/dev/null"))).tracks.first)
        // The Hook is at bar 20 of 3/4 now: 30 s. The take's two seconds of count-in come before it.
        #expect(abs(track.startsAt - 29.95) < 1e-6, "\(track.startsAt)")
        #expect(abs(track.skip - 1.95) < 1e-6, "\(track.skip)")
        #expect(track.stretch == 1)
    }

    @Test("the record and its stems play at the song's tempo, as its chops do; a half-time reading is left alone")
    func recordFollows() throws {
        func song(analysed bpm: Double, now: Double) throws -> Song {
            var song = Song(title: "Flip", artist: "Tests", tempo: now)
            try song.append(PartVersion(partID: PartID(), kind: .analysis(MusicAnalysis(duration: 180, tempo: [TempoRange(start: 0, end: 180, bpm: bpm)])),
                                        author: .user, operation: Operation.imported))
            try song.append(TransportFixture.audioVersion(role: .take, duration: 180, offset: 0.5))
            return song
        }
        let resolver = TransportFixture.resolver(URL(fileURLWithPath: "/dev/null"))
        let followed = try #require(SongPlayback.plan(for: try song(analysed: 92, now: 100), mediaURL: resolver).tracks.first)
        #expect(abs(followed.stretch - 0.92) < 1e-9 && abs(followed.duration - 180 * 0.92) < 1e-6 && abs(followed.startsAt - 0.46) < 1e-9)
        #expect(SongPlayback.plan(for: try song(analysed: 92, now: 92), mediaURL: resolver).tracks.first?.stretch == 1)
        #expect(SongPlayback.plan(for: try song(analysed: 92, now: 184), mediaURL: resolver).tracks.first?.stretch == 1,
                "double time is a reading, not a request")
    }

    @Test("a tempo set while the song plays is heard next play: the fade and the readout keep to what is playing")
    @MainActor
    func tempoWhilePlaying() async throws {
        let (app, _, _) = CompletenessFixture.app("tempo-live")
        let host = StubPlaybackHost()
        app.attach(playback: host)
        let groove = TransportFixture.grooveVersion()
        var song = TransportFixture.song([groove])
        song.sections = [Section(name: "Verse", stitch: [Lane(part: groove.partID)], lengthInBars: 32)]
        var mix = Mix.unity
        mix.master.fadeOutBars = 4
        try song.append(PartVersion(partID: PartID(), kind: .mix(mix), author: .user, operation: Operation.mix, note: "Fade"))
        app.open(song)
        await app.startTransport()
        #expect(app.fadeSpan == 56...64)
        #expect(app.setTempo(160))
        #expect(app.fadeSpan == 56...64, "the running song is still at 120")
        #expect(app.soundingClock.tempo == 120 && app.clock.tempo == 160)
        await app.stopTransport()
        #expect(app.soundingClock.tempo == 160)
    }

    @Test("a take kept before the tempo was, reads with none")
    func olderTakesDecode() throws {
        let data = try JSONEncoder().encode(Take(startBar: 2, tempo: 96))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["tempo"] = nil
        let old = try JSONDecoder().decode(Take.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.tempo == nil && old.startBar == 2)
    }
}

private extension PartKind {
    var audioMedia: MediaRef? {
        if case .audio(let audio) = self { return audio.media }
        return nil
    }
}
