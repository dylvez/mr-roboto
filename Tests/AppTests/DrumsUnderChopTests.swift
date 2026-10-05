import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// A bar of the other stem, played in a feel, was the only "groove" a song had. Structure put it
// and the looped bar it was made from in the same section, called the bar missing when it was taken
// out, and left "the groove" playing when the chop's chip was off — the same strings. The band was
// asked why the beat could not be heard and raised the master. These are the form, the band's
// question and the Director's reading saying what that groove is, and the move that adds drums.

@MainActor
enum DrumlessFixture {
    /// A record and one stem of it, a bar of that stem chopped, and a groove made from the bar in
    /// the lane: on the chop's slices, in a song with no sections yet.
    static func app(_ label: String, stem: String = "other") throws -> (app: AppState, directory: URL, chop: PartVersion, groove: PartVersion) {
        let (app, directory, _) = CompletenessFixture.app(label)
        let (kept, _, _) = try ChopGrooveFixture.keptChop(in: directory)
        guard case .sample(let sample) = kept.kind else { fatalError("not a sample") }
        let audio = PartVersion(partID: PartID(), kind: .audio(Audio(media: sample.media, role: .stem, stem: stem, sampleRate: ChopLaneFixtures.sampleRate,
                                                                    channelCount: 2, duration: ChopLaneFixtures.barLength)),
                                author: .user, operation: Operation.separate, note: "\(stem) stem")
        let chop = PartVersion(partID: kept.partID, kind: kept.kind, author: .user, parents: [audio.id],
                               operation: Operation.chop, note: "Bar 1 of \(stem) stem")
        var song = Song(title: "Flip", tempo: ChopLaneFixtures.bpm)
        try song.append(audio)
        try song.append(chop)
        app.open(song)
        let groove = chop.spawning(.groove(TransportFixture.groove()), by: .user, operation: Operation.regroove,
                                   note: "Lo-Fi Hip-Hop on Bar 1 of \(stem) stem")
        #expect(app.record(groove))
        #expect(app.playGroove(groove.partID, onChop: chop.partID).isEmpty, "no sections yet")
        return (app, directory, chop, groove)
    }

    static func structure(_ app: AppState) -> StructureModel {
        let model = StructureModel(host: StructureAdapter(app: app), song: app.song)
        model.autoKeep.delay = nil
        return model
    }
}

@Suite("A groove on a chop with no drums in it is not the beat", .serialized) @MainActor
struct DrumsUnderChopTests {

    @Test("a new section plays the re-groove without the looped bar under it, and calls nothing missing")
    func theLoopStaysOut() throws {
        let (app, directory, chop, groove) = try DrumlessFixture.app("drumless-stitch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DrumlessFixture.structure(app)
        #expect(model.layer(groove.partID)?.kit?.part == chop.partID)
        #expect(model.layer(groove.partID)?.kit?.hasDrums == false)
        #expect(model.defaultStitch.map(\.part) == [groove.partID], "the bar is not put under its own re-groove")

        let intro = model.add(.intro)
        #expect(model.keep())
        #expect(app.song?.sections.first?.stitch.map(\.part) == [groove.partID])
        #expect(model.missingText(from: intro) == nil, "its chop is playing, re-grooved")
        #expect(model.orphanedText == nil)
        #expect(FormTools.defaultStitch(in: app.song!).map(\.part) == [groove.partID], "the Director's default is the same")

        // The loop is still one chip away, and the chip says what it adds.
        let loop = try #require(model.layer(chop.partID))
        #expect(model.help(for: loop, in: intro).contains("looped as it was cut"), "\(model.help(for: loop, in: intro))")
        #expect(model.help(for: model.layer(groove.partID)!, in: intro).hasSuffix("played on Bar 1 of other stem's slices, not on a drum machine"))
        model.toggle(chop.partID, in: intro.id)
        #expect(model.selectedSection?.stitch.map(\.part) == [groove.partID, chop.partID])
    }

    @Test("the Producer counts the chop a stitched groove plays as in the song, and a chop nothing plays as in no section")
    func theProducerCounts() throws {
        let (app, directory, chop, groove) = try DrumlessFixture.app("drumless-producer")
        defer { try? FileManager.default.removeItem(at: directory) }
        var song = try #require(app.song)
        let name = PartLabel.title(of: chop)
        song.sections = [Section(name: "Loop", stitch: [Lane(part: groove.partID)], lengthInBars: 4)]
        #expect(!SongObservation.of(song).orphanedParts.contains(name), "the groove sounds its pads")
        song.sections = [Section(name: "Loop", stitch: [], lengthInBars: 4)]
        #expect(SongObservation.of(song).orphanedParts.contains(name), "nothing plays it")
    }

    @Test("Structure says the groove is the chop in a rhythm, and Add drums puts the pattern on the machine beside it")
    func addDrums() throws {
        let (app, directory, chop, groove) = try DrumlessFixture.app("drumless-add")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DrumlessFixture.structure(app)
        let intro = model.add(.intro)
        _ = model.add(.verse)
        let offer = try #require(model.drumsOffer(for: intro))
        #expect(offer.groove == groove.partID)
        #expect(offer.text == "This section has no drums: its groove plays Bar 1 of other stem's slices.")
        // It sits with the chop, so the row called Groove is the drums: none yet.
        #expect(model.choices(for: intro).map(\.type) == [.sample, .audio], "and the stem it was cut from, off, in a row of its own")
        #expect(model.choices(for: intro).first?.layers.map(\.id) == [chop.partID, groove.partID])
        #expect(model.kinds(of: intro) == ["Chop"] && model.isRegrooved(model.layer(chop.partID)!))
        #expect(offer.help.contains("TR-808"), "\(offer.help)")

        model.addDrums(under: offer.groove)
        let song = try #require(app.song)
        let drums = try #require(song.versions.last { $0.type == .groove })
        #expect(drums.partID != groove.partID && !song.isVariation(drums.partID), "a groove of its own, on its own strip")
        #expect(drums.kind == groove.kind && drums.parents == [groove.id])
        #expect(PartLabel.title(of: drums) == "Lo-Fi Hip-Hop drums")
        #expect(SongPlayback.chop(under: drums.partID, in: song) == nil)
        #expect(SongPlayback.chop(under: groove.partID, in: song)?.partID == chop.partID, "the slices keep playing")
        #expect(song.sections.map { $0.stitch.map(\.part) } == [[groove.partID, drums.partID], [groove.partID, drums.partID]],
                "in every section that plays it")

        // The transport plays both: one on the chop, one on the machine.
        let plan = SongPlayback.plan(for: song) { _ in directory.appendingPathComponent("bar.wav") }
        let grooves = try #require(plan.segments.first).voices.filter { $0.groove != nil }
        #expect(grooves.map { $0.kit?.part } == [chop.partID, nil])

        // Said once: the drums have a chip now, and that is how a section takes or leaves them.
        model.sync(with: song)
        #expect(model.drumsOffer(for: model.sections[0]) == nil)
        #expect(model.choices(for: model.sections[0]).filter { $0.type != .audio }.map { $0.layers.map(\.id) } == [[drums.partID], [chop.partID, groove.partID]],
                "Groove is the drums; turning the Chop row off leaves only the beat")
        #expect(model.kinds(of: model.sections[0]) == ["Groove", "Chop"])
        model.toggle(drums.partID, in: model.sections[0].id)
        #expect(model.drumsOffer(for: model.sections[0]) == nil, "taking them out of a section is not asked about again")

        // Asked again from elsewhere, the same drums go back rather than a second set being made.
        #expect(model.keep())
        #expect(app.addDrums(under: groove.partID) == drums.partID)
        #expect(app.song?.versions.filter { $0.type == .groove }.count == 2)
        #expect(app.song?.sections.first?.stitch.map(\.part) == [groove.partID, drums.partID])
    }

    @Test("a chop of the drums stem, re-grooved, is the beat: nothing is offered")
    func drumsAreDrums() throws {
        let (app, directory, _, groove) = try DrumlessFixture.app("drumless-not", stem: "drums")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DrumlessFixture.structure(app)
        let intro = model.add(.intro)
        #expect(model.layer(groove.partID)?.kit?.hasDrums == true)
        #expect(model.drumsOffer(for: intro) == nil)
        #expect(model.kinds(of: intro) == ["Groove"], "a re-grooved break is the groove")
        #expect(Guidance.drumless(in: app.song!) == nil)
        #expect(!app.nextQuestion.options.contains { $0.kind == "drums" })
    }

    @Test("the Beatmaker asks for drums first, and taking the answer adds them with no form to put them in")
    func theBandAsks() throws {
        let (app, directory, chop, groove) = try DrumlessFixture.app("drumless-next")
        defer { try? FileManager.default.removeItem(at: directory) }
        let question = app.nextQuestion
        let first = try #require(question.options.first)
        #expect(first.kind == "drums" && first.move == .addDrums(groove.partID), "\(question.options.map(\.kind))")
        #expect(question.asker == .persona("Beatmaker"))
        #expect(question.question.hasPrefix("Drums under it next"), "\(question.question)")
        #expect(question.observation.contains("there are no drums yet"), "\(question.observation)")

        app.take(first, from: question)
        let song = try #require(app.song)
        #expect(Guidance.drumless(in: song) == nil)
        #expect(!app.nextQuestion.options.contains { $0.kind == "drums" })
        // Unarranged, the newest groove is the drums and the bar loops beside them.
        let plan = SongPlayback.plan(for: song) { _ in directory.appendingPathComponent("bar.wav") }
        #expect(plan.voices.compactMap(\.groove).count == 1 && plan.voices.first { $0.groove != nil }?.kit == nil)
        #expect(plan.chop?.part == chop.partID)
    }

    @Test("the lane's rail line says the groove is the chop in a feel, and where drums come from")
    func theRailSays() throws {
        let directory = WiringFixture.temporaryDirectory()
        defer { WiringFixture.remove(directory) }
        let app = WiringFixture.app(in: directory)
        let host = ChopLaneAdapter(app: app, service: WiringFixture.silentService(), surface: SurfaceID())
        let audio = PartVersion(partID: PartID(), kind: .audio(Audio(media: ChopLaneFixtures.media, role: .stem, stem: "other", sampleRate: 44_100,
                                                                    channelCount: 2, duration: 30)),
                                author: .user, operation: Operation.separate)
        #expect(app.record(audio))
        let (kept, _, _) = try ChopGrooveFixture.keptChop(in: directory)
        #expect(host.record(kept))
        let groove = kept.spawning(.groove(TransportFixture.groove()), by: .user, operation: Operation.regroove, note: "Lo-Fi Hip-Hop on Bar 1")
        #expect(host.record(groove))
        host.madeGroove(groove, fromChop: kept.partID)
        let line = try #require(app.log.last { $0.text == "Lo-Fi Hip-Hop on Bar 1 plays the chop's own slices" })
        #expect(line.detail?.contains("no drums in it") == true, "\(line.detail ?? "nil")")
    }

    @Test("read_song says what each groove is heard on, and audition says a version id is not a handle")
    func theDirectorReads() async throws {
        let (app, directory, chop, groove) = try DrumlessFixture.app("drumless-read")
        defer { try? FileManager.default.removeItem(at: directory) }
        var output = try await ReadSongTool(workspace: AppStateWorkspace(app)).run(.init())
        let read = try #require(output.versions.first { $0.id == groove.id.description }?.playsOn)
        #expect(read.contains(chop.partID.description) && read.contains("not drums") && read.contains("write_groove"), "\(read)")
        #expect(output.versions.first { $0.id == chop.id.description }?.playsOn == nil)

        let drums = try #require(app.addDrums(under: groove.partID))
        output = try await ReadSongTool(workspace: AppStateWorkspace(app)).run(.init())
        #expect(output.versions.last { $0.part == drums.description }?.playsOn == "the TR-808 drum machine")

        await #expect(throws: DirectorToolFailure.self) {
            _ = try await AuditionTool(workbench: DirectorWorkbench(), audition: nil).run(.init(groove: groove.id.description, bars: nil))
        }
    }
}
