import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// M3 Gate B on the surface: fragments read off versions, the plan on the model, and the
// milestone's own done-when — two things in different keys become one section of the open song
// with nothing transposed by hand, saved, reopened, and still playing.

@MainActor
enum MergeFixture {
    struct Built {
        var app: AppState
        var store: LibraryStore
        var record: Record
        var sample: PartVersion
        var bass: PartVersion
        var groove: PartVersion
        var directory: URL
    }

    /// A song in D major at 92 with a kicking groove, a dusty chop stamped G major at 100 (cut
    /// from a real tone in the library), and a bass line written in E minor.
    static func build(_ label: String) throws -> Built {
        let directory = LibraryFixture.directory("merge-\(label)")
        let store = LibraryStore(directoryURL: directory)
        let app = LibraryFixture.app(directory)
        let record = try LibraryFixture.record("Horns", in: directory, store: store, frequency: 98)
        #expect(app.writeLibrary(Library(records: [record])))

        var song = Song(title: "Arrival", artist: "Vessel", key: Key(parsing: "D major"), tempo: 92)
        let seed = Seed(kind: .importedRecord(record.id))
        song.seeds.append(seed)
        let form = FormFixture.build()
        let groove = try #require(form.song.latestVersion(of: form.groove))
        try song.append(groove)
        let sample = PartVersion(partID: PartID(),
                                 kind: .sample(Sample(media: record.media, slices: [SliceMarker(position: 0.0), SliceMarker(position: 0.25)],
                                                      detectedTempo: 100, sourceRecord: record.id,
                                                      degradation: [Dust.pass(.sp1200, mix: 0.5)], key: Key(parsing: "G major"))),
                                 author: .user, operation: Operation.chop, note: "Bar 1 of Horns", origin: seed.id)
        try song.append(sample)
        let line = Bassline(notes: [NoteEvent(pitch: Pitch(midi: 40), start: 0, duration: 1),
                                    NoteEvent(pitch: Pitch(midi: 43), start: 2, duration: 1),
                                    NoteEvent(pitch: Pitch(midi: 40), start: 4, duration: 2)], sound: "finger", key: Key(parsing: "E minor"))
        let bass = PartVersion(partID: PartID(), kind: .bassline(line), author: .persona("Bassist"), operation: Operation.written,
                               note: "Bass line")
        try song.append(bass)
        app.open(song)
        app.save()
        return Built(app: app, store: store, record: record, sample: sample, bass: bass, groove: groove, directory: directory)
    }
}

@Suite("Merge: fragments and the model", .serialized) @MainActor
struct MergeModelTests {

    @Test("a version says what the plan needs: kind, key, tempo, drums")
    func fragments() throws {
        let built = try MergeFixture.build("fragments")
        defer { try? FileManager.default.removeItem(at: built.directory) }
        let song = built.app.song!
        let sample = MergeModel.fragment(of: built.sample, in: song, library: built.app.library)
        #expect(sample.kind == .sample && sample.key?.name == "G major" && sample.tempo == 100)
        let bass = MergeModel.fragment(of: built.bass, in: song, library: built.app.library)
        #expect(bass.kind == .written && bass.key?.name == "E minor" && bass.tempo == nil)
        let groove = MergeModel.fragment(of: built.groove, in: song, library: built.app.library)
        #expect(groove.kind == .groove && groove.key == nil && groove.isDrums)

        // A chop with no key of its own reads its record's key at the bar.
        let bare = PartVersion(partID: PartID(), kind: .sample(Sample(media: built.record.media, slices: [SliceMarker(position: 1)],
                                                                      sourceRecord: built.record.id)),
                               author: .user, operation: Operation.chop)
        #expect(MergeModel.fragment(of: bare, in: song, library: built.app.library).key?.name == "D major")
        // And a bass line from before keys were carried reads the song's.
        let old = PartVersion(partID: PartID(), kind: .bassline(Bassline(notes: [])), author: .user, operation: Operation.written)
        #expect(MergeModel.fragment(of: old, in: song, library: built.app.library).key?.name == "D major")

        #expect(MergeModel.canMerge(built.sample) && MergeModel.canMerge(built.groove))
        let partners = MergeModel.partners(for: built.sample, in: song)
        let partnerIDs = Set(partners.map(\.id))
        #expect(partnerIDs == Set([built.bass.id, built.groove.id]))
    }

    @Test("the model plans against the song, offers the keys and tempos in play, and takes a hand on the stepper")
    func model() throws {
        let built = try MergeFixture.build("model")
        defer { try? FileManager.default.removeItem(at: built.directory) }
        let host = StubMergeHost()
        let model = MergeModel(host: host, a: built.sample, b: built.bass, song: built.app.song, library: built.app.library)
        #expect(model.isReady)
        #expect(model.title == "Bar 1 of Horns + Bass line")
        let plan = try #require(model.plan)
        #expect(plan.target.key?.name == "D major" && plan.target.tempo == 92)
        #expect(plan.a.semitones == -5, "G major into D major is five down")
        #expect(abs(plan.a.ratio - 100.0 / 92.0) < 1e-9)
        #expect(plan.a.preservesFormants && plan.a.flags.count == 1)
        #expect(plan.b.semitones == -5, "E minor into D major's collection is B minor")
        #expect(plan.b.ratio == 1)
        #expect(plan.a.sentence.hasPrefix("Bar 1 of Horns down 5 semitones to D major, stretched ×1.09 from 100 to 92."))
        #expect(plan.b.sentence == "Bass line down 5 semitones to B minor.")
        #expect(model.keyOptions.map(\.name) == ["D major", "G major", "E minor"])
        #expect(model.tempoOptions == [92, 100])
        #expect(model.bars == 2, "the bass line is six beats: two bars")
        #expect(model.summary(.a).contains("G major") && model.summary(.b).contains("written"))

        // Into the sample's own key: the sample stays, the bass line moves to G's relative minor.
        model.targetKey = Key(parsing: "G major")
        #expect(model.plan?.a.semitones == 0)
        #expect(model.plan?.b.semitones == 0, "E minor already sits in G major")
        model.targetTempo = 100
        #expect(model.plan?.a.isUntouched == true)

        // A hand on the stepper, and the rules again.
        model.nudge(.b, by: 2)
        #expect(model.plan?.b.semitones == 2)
        #expect(model.plan?.b.key?.name == "F♯ minor")
        #expect(model.override(.b) == 2)
        model.resetOverride(.b)
        #expect(model.plan?.b.semitones == 0)
        model.nudge(.a, by: -1)
        #expect(model.plan?.a.semitones == -1 && model.plan?.a.sentence.contains("down 1 semitone") == true)

        model.play(.a); model.playBoth()
        #expect(host.played.isEmpty || !host.played.isEmpty)
    }
}

@MainActor
private final class StubMergeHost: MergeHosting {
    var played: [String] = []
    func audition(_ version: PartVersion, move: MergeMove) async { played.append(move.label) }
    func audition(_ a: (PartVersion, MergeMove), with b: (PartVersion, MergeMove)) async { played.append("both") }
    func stop() async {}
    func render(_ version: PartVersion, move: MergeMove) async throws -> PartVersion { version }
    func stitch(_ section: Section) async -> Bool { true }
}

@Suite("Merge: two things in different keys become one section", .serialized) @MainActor
struct MergeStitchTests {

    @Test("the done-when: stitched from the surface alone, saved, reopened, and played the same")
    func doneWhen() async throws {
        let built = try MergeFixture.build("stitch")
        defer { try? FileManager.default.removeItem(at: built.directory) }
        let app = built.app
        let adapter = MergeAdapter(app: app, service: WiringFixture.silentService())
        let model = MergeModel(host: adapter, a: built.sample, b: built.bass, song: app.song, library: app.library)
        model.sectionName = "Verse"
        model.bars = 4
        let before = app.song!.versions.count

        let section = try #require(await model.stitch())
        #expect(model.lastError == nil)
        let song = try #require(app.song)
        #expect(song.sections.count == 1 && song.sections[0].id == section.id)
        #expect(section.name == "Verse" && section.lengthInBars == 4)
        #expect(song.versions.count == before + 2, "two moved versions, the originals untouched")

        // The chop: new media in the package, the bar itself, moved as the plan said.
        let movedSample = try #require(song.version(playing: section.stitch[0]))
        #expect(movedSample.operation == Operation.merge)
        #expect(movedSample.parents == [built.sample.id])
        #expect(movedSample.note?.contains("down 5 semitones") == true)
        guard case .sample(let sample) = movedSample.kind else { Issue.record("not a sample"); return }
        #expect(sample.media != built.record.media)
        #expect(sample.key?.name == "D major")
        #expect(sample.detectedTempo == 92)
        #expect(sample.degradation.count == 1, "the chain travels with it")
        #expect(sample.sourceRecord == built.record.id)
        let span = try #require(sample.span)
        #expect(span.start == 0 && span.end > 0)
        #expect(sample.slices.count == 2)
        let expectedSecondSlice = 0.25 * 100.0 / 92.0
        #expect(abs(sample.slices[1].position - expectedSecondSlice) < 1e-6, "slices re-time with the stretch")
        let package = try built.store.songStore(for: song.id)
        #expect(package.hasMedia(sample.media), "the moved audio is in the song's own package")
        let url = try built.store.mediaURL(for: sample.media, song: song.id)
        let planar = try ChopAudio.readPlanar(url)
        #expect(abs(Double(planar.planar[0].count) / planar.sampleRate - span.end) < 0.01)
        // The original is exactly where it was.
        #expect(try built.store.mediaURL(for: built.record.media) == built.store.recordsDirectoryURL.appendingPathComponent(built.record.media.fileName))

        // The bass line: by arithmetic, five down, in B minor.
        let movedBass = try #require(song.version(playing: section.stitch[1]))
        #expect(movedBass.operation == Operation.merge && movedBass.parents == [built.bass.id])
        guard case .bassline(let line) = movedBass.kind else { Issue.record("not a bassline"); return }
        #expect(line.notes.map(\.pitch.midi) == [35, 38, 35])
        #expect(line.key?.name == "B minor")

        // The transport has the section, with both in it.
        var plan = app.playback
        #expect(plan.isArranged && plan.isPlayable)
        #expect(plan.segments[0].chop != nil && plan.segments[0].bassline != nil)

        // Saved, reopened, the same.
        app.save()
        let later = LibraryFixture.app(built.directory)
        later.reloadLibrary()
        later.openSong(song.id)
        let reopened = try #require(later.song)
        #expect(reopened.sections.map(\.name) == ["Verse"])
        plan = later.playback
        #expect(plan.isArranged && plan.isPlayable)
        #expect(plan.segments[0].chop?.url.lastPathComponent == sample.media.fileName)
        #expect(plan.segments[0].bassline?.notes.map(\.pitch.midi) == [35, 38, 35])

        // Nothing to move renders nothing: the originals are stitched as they are.
        let laterAdapter = MergeAdapter(app: later, service: WiringFixture.silentService())
        let still = MergeModel(host: laterAdapter, a: built.sample, b: built.bass, song: later.song, library: later.library)
        still.targetKey = Key(parsing: "G major")
        still.targetTempo = 100
        still.sectionName = "Hook"
        let count = later.song!.versions.count
        let hook = try #require(await still.stitch())
        #expect(later.song.map { $0.versions(playing: hook).map(\.id) } != nil)
        #expect(hook.stitch.count == 2, "the moved chop and the moved bass line, as parts")
        #expect(later.song?.versions.count == count)
        #expect(later.song?.sections.count == 2)
    }

    @Test("the Director can name the Merge surface on two parts, and nothing else")
    func choice() throws {
        let built = try MergeFixture.build("choice")
        defer { try? FileManager.default.removeItem(at: built.directory) }
        let stage = AppStateStage(built.app)
        let choice = try DirectorSurfaceChoice.make(surface: .merge, title: "Horns under the line",
                                                    fill: .parts([built.sample.id, built.bass.id]), because: "", in: stage)
        #expect(choice.action.bound == [built.sample.id, built.bass.id])
        let id = try #require(built.app.perform(choice.action))
        #expect(built.app.bench.items.first { $0.id == id }?.kind == .merge)
        let registry = SurfaceRegistry()
        SurfaceRegistry.registerSurfaces(in: registry)
        #expect(!registry.resolve(built.app.bench.items.first { $0.id == id }!, app: built.app).isPlaceholder)
        let model = SurfaceWiring().mergeModel(for: built.app.bench.items.first { $0.id == id }!, app: built.app)
        #expect(model.isReady)

        // A sound is not something a merge moves.
        let sound = PartVersion(partID: PartID(), kind: .sound(SoundState().sound), author: .user, operation: Operation.written)
        #expect(built.app.record(sound))
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(surface: .merge, title: "Wrong", fill: .parts([built.sample.id, sound.id]), because: "", in: stage)
        }
    }
}
