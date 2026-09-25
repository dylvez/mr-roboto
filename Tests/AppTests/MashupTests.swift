import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// Mashup: stems of two analysed songs become one song on the backbone's grid.

@MainActor
enum MashupFixture {
    static let rate = 48_000.0

    /// A click on every beat from `downbeat`, mono.
    static func clicks(bpm: Double, downbeat: Double, seconds: Double) -> [[Float]] {
        var samples = [Float](repeating: 0, count: Int(seconds * rate))
        var time = downbeat
        while time < seconds - 0.05 {
            let start = Int(time * rate)
            for i in 0..<240 where start + i < samples.count { samples[start + i] = Float(0.8 * sin(2 * .pi * 1_000 * Double(i) / rate)) * Float(1 - Double(i) / 240) }
            time += 60 / bpm
        }
        return [samples]
    }

    static func analysis(bpm: Double, downbeat: Double, seconds: Double, key: Key, sections: [SectionRange]) -> MusicAnalysis {
        var beats: [BeatMarker] = []
        var time = downbeat, index = 0
        while time < seconds { beats.append(BeatMarker(time: time, isDownbeat: index % 4 == 0)); time += 60 / bpm; index += 1 }
        return MusicAnalysis(duration: seconds, keys: [KeyRange(start: 0, end: seconds, key: key)], beats: beats,
                             tempo: [TempoRange(start: 0, end: seconds, bpm: bpm)], sections: sections)
    }

    /// A library on disk with two imported-looking songs: a take, an analysis, stems, and a record each.
    static func app(in directory: URL) throws -> (AppState, a: Song, b: Song) {
        let store = LibraryStore(directoryURL: directory)
        var library = Library()
        var a = Song(title: "Arrival", key: Key(tonic: NoteName(.d)), tempo: 100)
        var b = Song(title: "Exit Interview", key: Key(tonic: NoteName(.e)), tempo: 120)
        library.upsert(a); library.upsert(b)
        try store.save(library)
        for (index, spec) in [(100.0, 0.5, 16.0, ["other", "bass"]), (120.0, 0.25, 12.0, ["drums", "vocals"])].enumerated() {
            var song = index == 0 ? a : b
            let package = try store.songStore(for: song.id)
            let scratch = directory.appendingPathComponent("clicks-\(index).wav")
            try BoothAdapter.write(clicks(bpm: spec.0, downbeat: spec.1, seconds: spec.2), sampleRate: rate, to: scratch)
            let media = try package.addMedia(copying: scratch)
            let take = PartVersion(partID: PartID(), kind: .audio(Audio(media: media, role: .take, sampleRate: rate, channelCount: 1, duration: spec.2)),
                                   author: .user, operation: Operation.imported, note: "Record")
            try song.append(take)
            let sections = index == 0 ? [SectionRange(start: 0.5, end: 8, label: "verse"), SectionRange(start: 8, end: 16, label: "chorus")] : []
            try song.append(PartVersion(partID: PartID(), kind: .analysis(analysis(bpm: spec.0, downbeat: spec.1, seconds: spec.2, key: song.key!, sections: sections)),
                                        author: .user, parents: [take.id], operation: Operation.analyzed))
            for stem in spec.3 {
                try song.append(PartVersion(partID: PartID(), kind: .audio(Audio(media: media, role: .stem, stem: stem, sampleRate: rate, channelCount: 1, duration: spec.2)),
                                            author: .user, parents: [take.id], operation: Operation.separate, note: "\(stem) stem"))
            }
            library.upsert(song)
            library.records.append(Record(title: song.title, artist: index == 0 ? "Vessel" : "", media: media))
            if index == 0 { a = song } else { b = song }
        }
        try store.save(library)
        let app = AppState(library: try store.load(), store: store, transportHost: StubTransportHost())
        return (app, a, b)
    }

    /// Onset times of clicks in a mono file: rising edges through half the peak, 200 ms apart.
    static func onsets(_ url: URL) throws -> [Double] {
        let (planar, rate) = try BoothAdapter.planar(url)
        let samples = planar[0]
        let peak = samples.map(abs).max() ?? 0
        var out: [Double] = []
        var last = -1.0
        for (i, sample) in samples.enumerated() where abs(sample) > peak * 0.5 {
            let time = Double(i) / rate
            if time - last > 0.2 { out.append(time) }
            last = time
        }
        return out
    }
}

@Suite("Mashup: two songs, one grid", .serialized) @MainActor
struct MashupBuildTests {

    @Test("drums of one on the other's grid: a new song, its stems offset so every click lands on the backbone's beats")
    func build() async throws {
        let directory = WiringFixture.temporaryDirectory("mashup")
        defer { WiringFixture.remove(directory) }
        let (app, a, b) = try MashupFixture.app(in: directory)
        #expect(Mashups.stems(of: a) == ["bass", "other", "full"] && Mashups.stems(of: b) == ["vocals", "drums", "full"])

        var said: [String] = []
        let mashup = try await app.makeMashup(MashupRequest(a: a.id, b: b.id, backbone: .a, stemsA: ["other"], stemsB: ["drums"])) { what, _ in said.append(what) }
        #expect(said == ["Other of Arrival", "Drums of Exit Interview", "Saving"])
        #expect(mashup.title == "Arrival × Exit Interview" && mashup.tempo == 100 && mashup.key == a.key)
        #expect(app.song?.id == mashup.id, "the mashup is opened")
        #expect(app.library.song(mashup.id) != nil, "and in the library")
        #expect(mashup.sections.map(\.name) == ["Lead-in", "Verse", "Chorus"] && mashup.sections.map(\.lengthInBars) == [1, 3, 4], "\(mashup.sections.map { "\($0.name) \($0.lengthInBars)" })")

        let stems = Guidance.stems(in: mashup)
        #expect(stems.count == 2 && stems.allSatisfy { $0.operation == Operation.mashup })
        let other = try #require(Guidance.audio(of: stems[0])), drums = try #require(Guidance.audio(of: stems[1]))
        #expect(abs((other.alignmentOffset ?? -1) - 1.9) < 1e-9, "one bar of lead-in less the half-second pickup")
        #expect(abs((drums.alignmentOffset ?? -1) - 2.1) < 1e-9)
        #expect(abs(drums.duration - 14.4) < 0.05, "stretched from 120 to 100")
        #expect(stems[1].note?.contains("Drums of Exit Interview") == true)

        // The proof: every click of the moved drums is on the backbone's beat grid (0.6 s from bar 1).
        let store = try #require(app.store)
        let url = try store.mediaURL(for: drums.media, song: mashup.id)
        let onsets = try MashupFixture.onsets(url)
        #expect(onsets.count >= 20, "\(onsets.count) clicks")
        let worst = onsets.map { onset -> Double in
            let onTransport = (drums.alignmentOffset ?? 0) + onset - 2.4
            let beats = onTransport / 0.6
            return abs(beats - beats.rounded()) * 0.6
        }.max() ?? 1
        #expect(worst < 0.015, "worst click is \(worst * 1000) ms off the grid")

        // It plays: both stems are tracks at their offsets, bounded by the form.
        #expect(app.playback.tracks.count == 2 && app.playback.lengthInBars == 8)
        #expect(app.playback.tracks.map(\.startsAt).sorted() == [other.alignmentOffset!, drums.alignmentOffset!].sorted())

        // On an album, both records are sources to clear.
        let album = try #require(app.createAlbum(title: "Mashups"))
        #expect(app.addSong(mashup.id, to: album))
        let sources = app.sources(of: try #require(app.library.album(album))).map(\.source)
        #expect(sources == ["Vessel – Arrival", "Exit Interview"], "\(sources)")
    }

    @Test("what it refuses, and why")
    func refusals() async throws {
        let directory = WiringFixture.temporaryDirectory("mashup-no")
        defer { WiringFixture.remove(directory) }
        let (app, a, b) = try MashupFixture.app(in: directory)
        await #expect(throws: MashupError.sameSong) { try await app.makeMashup(MashupRequest(a: a.id, b: a.id, stemsA: ["other"], stemsB: [])) }
        await #expect(throws: MashupError.nothingChosen) { try await app.makeMashup(MashupRequest(a: a.id, b: b.id, stemsA: [], stemsB: [])) }
        await #expect(throws: MashupError.tooManyStems(5)) { try await app.makeMashup(MashupRequest(a: a.id, b: b.id, stemsA: ["other", "bass", "full"], stemsB: ["drums", "vocals"])) }
        await #expect(throws: MashupError.noStem("vocals", "Arrival")) { try await app.makeMashup(MashupRequest(a: a.id, b: b.id, stemsA: ["vocals"], stemsB: ["drums"])) }
        let bare = Song(title: "Bare")
        var library = app.library
        library.upsert(bare)
        #expect(app.writeLibrary(library))
        await #expect(throws: MashupError.notAnalysed("Bare")) { try await app.makeMashup(MashupRequest(a: bare.id, b: b.id, stemsA: ["full"], stemsB: ["drums"])) }
        #expect(app.library.songs.count == 3, "nothing was made")
    }

    @Test("the model: the usual picks, the blockers, a nudge by ear, the other song as the grid")
    func model() async throws {
        let directory = WiringFixture.temporaryDirectory("mashup-model")
        defer { WiringFixture.remove(directory) }
        let (app, a, b) = try MashupFixture.app(in: directory)
        let model = MashupModel(app: app)
        #expect(model.candidates.map(\.title) == ["Arrival", "Exit Interview"])
        #expect(model.blocker == "Choose two songs." && model.plan == nil)
        model.a = a.id
        model.b = b.id
        #expect(model.stems(.a) == ["bass", "other"] && model.stems(.b) == ["vocals"], "everything but the voice from the grid, the voice from the other")
        #expect(model.blocker == nil)
        let plan = try #require(model.plan)
        #expect(plan.target.tempo == 100 && plan.b.semitones == -2)
        model.nudge(.b, by: 1)
        #expect(model.semitones(.b) == -1 && model.plan?.b.semitones == -1)
        model.resetSemitones(.b)
        #expect(model.plan?.b.semitones == -2)
        model.toggle(Mashups.full, on: .a)
        #expect(model.stems(.a) == [Mashups.full], "the full record replaces its stems")
        model.toggle("drums", on: .b); model.toggle("other", on: .a)
        #expect(model.stems(.a) == ["other"] && model.stems(.b) == ["vocals", "drums"])
        model.setBackbone(.b)
        #expect(model.plan?.target.tempo == 120 && model.stems(.b) == ["drums"] && model.stems(.a) == [Mashups.full], "B has the drums; A has no voice stem, so its record")
        model.b = a.id
        #expect(model.blocker == MashupError.sameSong.description)
        model.b = b.id
        model.title = "Arrival Interview"
        let made = try #require(await model.make())
        #expect(made.title == "Arrival Interview" && app.song?.id == made.id && model.lastError == nil)
    }

    @Test("the bar shift keeps to its range, typed or stepped")
    func barShiftRange() {
        #expect(MashupModel.clampedBarShift(3) == 3)
        #expect(MashupModel.clampedBarShift(-100) == MashupModel.barShiftRange.lowerBound)
        #expect(MashupModel.clampedBarShift(999) == MashupModel.barShiftRange.upperBound)
    }

    @Test("the Director: plan_mashup says the plan, mashup makes the song")
    func tools() async throws {
        let directory = WiringFixture.temporaryDirectory("mashup-tools")
        defer { WiringFixture.remove(directory) }
        let (app, _, _) = try MashupFixture.app(in: directory)
        let workspace = AppStateWorkspace(app)
        let read = try await PlanMashupTool(workspace: workspace).run(.init(a: "arrival", b: "Exit Interview", backbone: "a", bar_shift: 0))
        #expect(read.tempo == 100 && read.key == "D major" && read.stems_b == ["vocals", "drums", "full"])
        #expect(read.sentences.contains { $0.contains("Exit Interview") && $0.contains("down 2") }, "\(read.sentences)")
        let made = try await MashupTool(workspace: workspace).run(.init(a: "Arrival", b: "Exit Interview", backbone: "a", stems_a: ["other", "bass"], stems_b: ["Vocals"], bar_shift: 4))
        #expect(made.song == "Arrival × Exit Interview" && made.stems.count == 3)
        #expect(app.song?.title == made.song)
        await #expect(throws: DirectorToolFailure.self) { try await PlanMashupTool(workspace: workspace).run(.init(a: "Nope", b: "Arrival", backbone: "a", bar_shift: 0)) }
        await #expect(throws: DirectorToolFailure.self) { try await MashupTool(workspace: workspace).run(.init(a: "Arrival", b: "Exit Interview", backbone: "a", stems_a: ["vocals"], stems_b: [], bar_shift: 0)) }
        let scratch = DirectorScratchWorkspace(song: nil, library: app.library)
        await #expect(throws: DirectorToolFailure.self) { try await MashupTool(workspace: scratch).run(.init(a: "Arrival", b: "Exit Interview", backbone: "a", stems_a: ["other"], stems_b: ["drums"], bar_shift: 0)) }
    }
}
