import AVFAudio
import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// The three things the band could not do with a tune it had written: know when a figure came
// back, rewrite it before handing it over, and show it and play it.

@Suite("Melodist: a figure that comes back")
struct FigureTests {
    private let key = Key(tonic: NoteName(.a), mode: .aeolian)

    private func n(_ midi: Int, _ start: Double, _ duration: Double = 0.5) -> NoteEvent {
        NoteEvent(pitch: Pitch(midi: midi), start: start, duration: duration)
    }

    private func observe(_ notes: [NoteEvent]) -> MelodyObservation {
        MelodyObservation(label: "Tune", key: key, notes: notes)
    }

    /// Two bars: four notes in a rhythm, a held note, a breath.
    private func figure(at beat: Double, from midi: Int, ending last: Int = -3) -> [NoteEvent] {
        [n(midi, beat + 0.5), n(midi, beat + 1), n(midi - 2, beat + 1.5), n(midi - 4, beat + 2, 1),
         n(midi + last, beat + 3.5), n(midi - 4, beat + 4, 2)]
    }

    @Test("the same two-bar figure four times is nearly all figure, however long the tune")
    func fourTimes() {
        let tune = observe((0..<4).flatMap { figure(at: Double($0) * 8, from: 76) })
        #expect(tune.notes.count == 24)
        #expect(tune.motifRatio > 0.9, "\(tune.motifRatio)")
        #expect(Melodist().read(tune).first { $0.rule == "melodist.a-figure-comes-back" }?.holds == true)
    }

    @Test("a figure brought back a third up, and an answer that ends somewhere else, are the figure coming back")
    func movedAndAnswered() {
        let moved = observe(figure(at: 0, from: 72) + figure(at: 8, from: 76))
        #expect(moved.motifRatio > 0.8, "\(moved.motifRatio)")
        // The question ends going up a step; the answer ends going down a fourth. The first four
        // notes are the same shape in the same rhythm, and that is what comes back.
        let answered = observe(figure(at: 0, from: 76, ending: -2) + figure(at: 8, from: 76, ending: -9))
        #expect(answered.motifRatio >= 0.5, "\(answered.motifRatio)")
    }

    @Test("the same notes in another rhythm are something else, and so is a line that never repeats a shape")
    func notTheFigure() {
        let stated = figure(at: 0, from: 76)
        let stretched = stated.enumerated().map { index, note in n(note.pitch.midi, 8 + Double(index) * 1.25, 1) }
        #expect(observe(stated + stretched).motifRatio == 0)
        // Up, up, down, down, up, down, down, up, up, up… in gaps that never recur.
        let gaps = [0.5, 1, 0.25, 1.5, 0.75, 2, 0.5, 0.25, 1.25, 1, 1.75]
        let steps = [2, 3, -1, -4, 5, -2, -2, 1, 2, 2, -7]
        var beat = 0.0, pitch = 64
        var walk = [n(pitch, beat)]
        for (gap, step) in zip(gaps, steps) { beat += gap; pitch += step; walk.append(n(pitch, beat)) }
        #expect(observe(walk).motifRatio == 0, "\(observe(walk).motifRatio)")
        #expect(Melodist().read(observe(walk)).first { $0.rule == "melodist.a-figure-comes-back" }?.holds == false)
    }

    @Test("a bed of held chords, and six notes across sixteen bars, are not read for a figure")
    func noRoom() {
        let bed = observe((0..<4).flatMap { bar in [57, 62, 64].map { self.n($0, Double(bar) * 16, 15) } })
        #expect(!bed.hasRoomForAFigure)
        #expect(!Melodist().read(bed).contains { $0.rule == "melodist.a-figure-comes-back" })
        let sparse = observe([n(69, 0, 2), n(72, 12, 2), n(71, 24, 2), n(67, 36, 2), n(69, 48, 2), n(64, 60, 2)])
        #expect(!Melodist().read(sparse).contains { $0.rule == "melodist.a-figure-comes-back" })
    }
}

@Suite("Director: a tune is rewritten before it is handed over", .serialized) @MainActor
struct HandoverTests {

    /// Over A minor then F: a walk that lands on the chords and never repeats a shape.
    static let walk = "A4 0 0.5, C5 0.5 1, B4 1.5 0.25, E5 1.75 1.5, C5 3.25 0.75, A4 4 1.5, F4 5.5 0.5, A4 6 0.25, C5 6.25 1.25, F4 7.5 0.5"
    /// A bar stated and brought again, moved for the second chord.
    static let figure = "A4 0.5 0.5, A4 1 0.5, C5 1.5 0.5, E5 2 1.5, A4 4.5 0.5, A4 5 0.5, C5 5.5 0.5, F5 6 1.5"
    /// An arpeggio up the chords: every move a leap, the same figure twice.
    static let arpeggio = "A3 0 0.5, C4 0.5 0.5, E4 1 0.5, A4 1.5 0.5, C5 2 0.5, E5 2.5 0.5, A5 3 1, F3 4 0.5, A3 4.5 0.5, C4 5 0.5, F4 5.5 0.5, A4 6 0.5, C5 6.5 0.5, F5 7 1"

    private func rig() async -> WritingFixture.Rig {
        let rig = WritingFixture.rig(Song.new(title: "Signal", key: Key(tonic: NoteName(.a), mode: .aeolian), tempo: 110))
        let chords = await WritingFixture.run(rig.box, "set_progression", #"{"chords":"Am7 | Fmaj7","key":"A minor"}"#)
        #expect(!chords.isError, "\(chords.content)")
        return rig
    }

    private func write(_ rig: WritingFixture.Rig, _ notes: String, draft: Int, parent: String = "") async -> [String: Any] {
        let result = await WritingFixture.run(rig.box, "write_melody",
            #"{"notes":"\#(notes)","bars":2,"instrument":"","parent":"\#(parent)","note":"The tune","draft":\#(draft)}"#)
        #expect(!result.isError, "\(result.content)")
        return WritingFixture.json(result)
    }

    private func tunes(_ rig: WritingFixture.Rig) -> [PartVersion] {
        rig.app.song?.versions.filter { $0.type == .melody } ?? []
    }

    @Test("a first draft in which nothing comes back is not kept, and the user is told nothing of it")
    func firstDraftGoesBack() async throws {
        let rig = await rig()
        defer { rig.clean() }
        let lines = rig.app.log.count
        let out = await write(rig, Self.walk, draft: 1)
        #expect(out["recorded"] as? Bool == false)
        #expect(out["version"] as? String == "")
        #expect((out["flags"] as? [String])?.contains { $0.contains("comes back") } == true, "\(out["flags"] ?? "")")
        let detail = out["detail"] as? String ?? ""
        #expect(detail.hasPrefix("Not kept.") && detail.contains("draft 2"), "\(detail)")
        #expect(tunes(rig).isEmpty)
        #expect(rig.app.log.count == lines, "\(rig.app.log.dropFirst(lines).map(\.text))")
    }

    @Test("the rewrite that answers it is kept, as the only version of the tune")
    func theRewriteIsKept() async throws {
        let rig = await rig()
        defer { rig.clean() }
        _ = await write(rig, Self.walk, draft: 1)
        let out = await write(rig, Self.figure, draft: 2)
        #expect(out["recorded"] as? Bool == true)
        #expect((out["flags"] as? [String])?.contains { $0.contains("comes back") } == false)
        #expect(tunes(rig).count == 1)
        #expect(rig.app.playback.segments.allSatisfy { $0.melody != nil }, "and it plays in the form")
    }

    @Test("the third draft is kept whatever it flags, and what it flags is said in the rail")
    func theThirdIsKept() async throws {
        let rig = await rig()
        defer { rig.clean() }
        #expect(await write(rig, Self.walk, draft: 2)["recorded"] as? Bool == false)
        let out = await write(rig, Self.walk, draft: 3)
        #expect(out["recorded"] as? Bool == true)
        #expect(tunes(rig).count == 1)
        #expect(rig.app.log.contains { $0.source == .persona("Melodist") && $0.text.contains("comes back") })
    }

    @Test("a singer's limits send nothing back: an arpeggio is kept the first time")
    func anArpeggioIsNotAVoice() async throws {
        let rig = await rig()
        defer { rig.clean() }
        let out = await write(rig, Self.arpeggio, draft: 1)
        #expect(out["recorded"] as? Bool == true, "\(out["detail"] ?? "")")
        #expect((out["flags"] as? [String])?.contains { $0.contains("arpeggio") } == true, "it is still read, and said")
        #expect(tunes(rig).count == 1)
    }

    @Test("a draft that fights the chords goes back, naming the first note that does")
    func fightsTheChords() async throws {
        let rig = await rig()
        defer { rig.clean() }
        // The figure, a semitone off the chord all the way through.
        let out = await write(rig, "Bb4 0.5 0.5, Bb4 1 0.5, C#5 1.5 0.5, F5 2 1.5, Bb4 4.5 0.5, Bb4 5 0.5, C#5 5.5 0.5, F#5 6 1.5", draft: 1)
        #expect(out["recorded"] as? Bool == false)
        #expect((out["detail"] as? String)?.contains("land on the chord") == true, "\(out["detail"] ?? "")")
    }

    @Test("a rewrite of a tune the song holds goes back the same way, and is kept as its next version")
    func aRewriteOfAKeptTune() async throws {
        let rig = await rig()
        defer { rig.clean() }
        let first = await write(rig, Self.figure, draft: 1)
        let id = try #require(first["version"] as? String)
        let refused = await write(rig, Self.walk, draft: 1, parent: id)
        #expect(refused["recorded"] as? Bool == false)
        #expect((refused["detail"] as? String)?.contains(id) == true)
        #expect(tunes(rig).count == 1)
        let kept = await write(rig, Self.arpeggio, draft: 2, parent: id)
        #expect(kept["recorded"] as? Bool == true)
        #expect(tunes(rig).count == 2 && tunes(rig).last?.parents.first?.description == id)
    }

    @Test("the schema asks for the draft, and the prompt says what it is for")
    func told() throws {
        let box = WritingFixture.toolbox(DirectorScratchWorkspace(song: DirectorSongFixture.song()))
        let tool = try #require(box.tool(named: "write_melody"))
        #expect(tool.definition.inputSchema["required"]?.arrayValue?.contains(.string("draft")) == true)
        #expect(DirectorPrompt.system.contains("A tune is rewritten before it is handed over"))
        #expect(DirectorPrompt.system.contains("the third is kept as it is"))
    }
}

@Suite("Director: a tune can be shown and heard") @MainActor
struct TuneOnTheBenchTests {

    struct Built {
        var app: AppState
        var stage: AppStateStage
        var directory: URL
        var chords: PartVersion
        var tunes: [PartVersion]
        var groove: PartVersion
    }

    static func build() throws -> Built {
        let directory = GuidanceFixture.temporaryDirectory("tune")
        let loop = try DevelopFixture.loop()
        var song = loop.song
        var tunes = [loop.tune]
        for name in ["Second pass", "Third pass"] {
            let extra = PartVersion(partID: PartID(), kind: loop.tune.kind, author: .persona("Melodist"),
                                    operation: Operation.written, note: name)
            try song.append(extra)
            tunes.append(extra)
        }
        let app = GuidanceFixture.app(nil, in: directory)
        app.open(song)
        return Built(app: app, stage: AppStateStage(app), directory: directory, chords: loop.chords, tunes: tunes, groove: loop.drums)
    }

    @Test("the Piano roll opens on a tune the Director wrote")
    func pianoRoll() throws {
        let built = try Self.build()
        defer { try? FileManager.default.removeItem(at: built.directory) }
        #expect(SurfaceKind.pianoRoll.notation == [.bassline, .melody, .groove])
        let choice = try DirectorSurfaceChoice.make(surface: .pianoRoll, title: "The hook", fill: .parts([built.tunes[0].id]),
                                                    because: "The tune as written.", in: built.stage)
        let id = try #require(built.stage.open(choice))
        #expect(built.app.bound(for: id) == [built.tunes[0].id])
        #expect(built.app.bench.items.contains { $0.id == id && $0.kind == .pianoRoll })
    }

    @Test("tunes are judged against the chords they are over, and against nothing else that is not a tune")
    func compare() throws {
        let built = try Self.build()
        defer { try? FileManager.default.removeItem(at: built.directory) }
        let choice = try DirectorSurfaceChoice.make(
            surface: .compare, title: "Three passes at the counter-melody",
            fill: .compare(against: built.chords.id, candidates: built.tunes.map(\.id)),
            because: "Each over the same two chords.", in: built.stage)
        #expect(choice.fill.reference == built.chords.id)
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(
                surface: .compare, title: "Against the drums",
                fill: .compare(against: built.groove.id, candidates: built.tunes.map(\.id)),
                because: "", in: built.stage)
        }
    }

    @Test("a tune and the chords are hits at the song's tempo, a phrase of them and no more")
    func hits() throws {
        let tune = [NoteEvent(pitch: Pitch(midi: 72), start: 0, duration: 1, velocity: 96),
                    NoteEvent(pitch: Pitch(midi: 76), start: 2, duration: 1.5, velocity: 80),
                    NoteEvent(pitch: Pitch(midi: 79), start: 40, duration: 1)]
        let hits = CompareAdapter.hits(for: tune, levers: [:], tempo: 120, timeSignature: .fourFour)
        #expect(hits.map(\.note) == [72, 76], "beat 40 at 120 is twenty seconds in: past the phrase")
        #expect(hits.map(\.velocity) == [96, 80])
        #expect(abs(hits[1].time - 1) < 1e-9)
        // The tempo lever re-times it, as it does a groove.
        let slower = CompareAdapter.hits(for: tune, levers: [.tempo: 60], tempo: 120, timeSignature: .fourFour)
        #expect(abs(slower[1].time - 2) < 1e-9)
        let chords = Voicing.notes(for: Progression(key: Key.cMajor, bars: [ProgressionBar(Chord(parsing: "Cmaj7")!, beats: 4)]))
        #expect(CompareAdapter.hits(for: chords, levers: [:], tempo: 90, timeSignature: .fourFour).count == 4)
    }

    @AudioActor
    private func offlineEngine() throws -> Engine {
        let engine = try Engine(playerCount: 1, sampleRate: 48_000, channels: 2)
        try engine.prepare(offlineSampleRate: 48_000, maximumFrames: 4096)
        try engine.start()
        _ = try engine.startTransport(clock: TransportClock(tempo: 120, sampleRate: 48_000))
        return engine
    }

    @AudioActor
    private func peakAfterRendering(_ engine: Engine, seconds: Double) throws -> Float {
        WiringFixture.peak(try OfflineRenderer.renderBuffer(engine: engine, frames: AVAudioFramePosition(48_000 * seconds)))
    }

    @Test("a Compare plays a tune and the chords, and says nothing about not being able to")
    func plays() async throws {
        let built = try Self.build()
        let kits = WiringFixture.temporaryDirectory("tune-kits")
        defer { try? FileManager.default.removeItem(at: built.directory); WiringFixture.remove(kits) }
        let engine = try await offlineEngine()
        let service = AuditionService(engine: { engine }, kitsDirectory: kits)
        let adapter = CompareAdapter(app: built.app, service: service, surface: SurfaceID())

        await adapter.audition(CompareCandidate(id: "a", title: "The hook", version: built.tunes[0]), levers: [:])
        #expect(await service.lastFailure == nil)
        #expect(try await peakAfterRendering(engine, seconds: 2) > 0.001, "the tune made no sound")

        await adapter.auditionReference(CompareReference(title: "Am7 Fmaj7", kind: "the chords", version: built.chords.id), levers: [:])
        #expect(await service.lastFailure == nil)
        #expect(try await peakAfterRendering(engine, seconds: 2) > 0.001, "the chords made no sound")
        #expect(!built.app.log.contains { $0.text.contains("cannot be auditioned") }, "\(built.app.log.map(\.text))")

        await service.shutdown()
        await engine.stopTransport()
        await engine.stop()
    }
}

@Suite("Director: what it is told about the bench")
struct BenchToldTests {
    @Test("one surface of each kind, three to an answer, and a song that mostly starts from an idea")
    func prompt() {
        let prompt = DirectorPrompt.system
        #expect(!prompt.contains("Never more than three surfaces open"))
        #expect(!prompt.contains("retires the oldest"))
        #expect(prompt.contains("The bench holds one surface of each kind"))
        #expect(prompt.contains("One answer opens three surfaces at most"))
        #expect(!prompt.contains("in the order it usually happens"))
        #expect(prompt.contains("most start from an idea"))
        #expect(prompt.contains("A loop is made into a song with develop"))
    }
}
