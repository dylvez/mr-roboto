import AVFAudio
import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// Two more audits: arranging and mixing, and the vocal path. Each test is one of what they found,
// fixed.

@Suite("Arranging and mixing, audited", .serialized) @MainActor
struct MixAuditTests {

    private func mix(_ gain: Double, on part: PartID) -> Mix {
        var mix = Mix.unity
        var strip = mix.strip(for: part, label: "Groove")
        strip.gainDB = gain
        mix.set(strip)
        return mix
    }

    @Test("the Mixer works on the song's newest mix: a restore and the band's cut reach it, and its next move keeps them")
    func mixerFollowsTheNewestMix() throws {
        let (app, directory, _) = CompletenessFixture.app("audit-mixer")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.discardSurfaceModel = { SurfaceWiring.shared.discardModel(for: $0) }
        app.open(CompletenessFixture.song("Arrival"))
        let groove = try #require(Guidance.grooves(in: app.song!).last).partID
        let id = try #require(app.perform(SurfaceAction(surface: .mixer, title: "Mixer")))
        let item = try #require(app.bench.items.first { $0.id == id })

        let adapter = MixAdapter(app: app)
        let first = try #require(adapter.commit(mix(-6, on: groove), base: nil, note: "−6"))
        #expect(adapter.commit(mix(-12, on: groove), base: first, note: "−12") != nil)
        #expect(app.restore(first.id))
        #expect(SurfaceWiring.shared.mixerModel(for: item, app: app).strip(groove).gainDB == -6, "the restore is what it shows")

        let cut = try #require(AppStateWorkspace(app).recordMix(mix(-2, on: groove), note: "Director's cut"))
        let mixer = SurfaceWiring.shared.mixerModel(for: item, app: app)
        #expect(mixer.base?.id == cut.id && mixer.strip(groove).gainDB == -2)
    }

    @Test("a strip's level can be set for one section, kept as a version, and put back")
    func levelsBySection() throws {
        let (app, directory, _) = CompletenessFixture.app("audit-section-level")
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = FormFixture.build(tempo: 92)
        var song = built.song
        song.sections = [Section(name: "Intro", stitch: [built.groove, built.bass].lanes, lengthInBars: 2),
                         Section(name: "Verse", stitch: [built.groove, built.bass].lanes, lengthInBars: 4)]
        app.open(song)
        let intro = song.sections[0].id
        let id = try #require(app.perform(SurfaceAction(surface: .mixer, title: "Mixer")))
        let mixer = SurfaceWiring.shared.mixerModel(for: app.bench.items.first { $0.id == id }!, app: app)

        mixer.levelSection = intro
        mixer.setLevel(-60, for: built.bass)
        let kept = try #require(mixer.endGesture())
        #expect(kept.note?.contains("in Intro") == true, "\(kept.note ?? "")")
        guard case .mix(let mix) = kept.kind else { Issue.record("not a mix"); return }
        #expect(mix.gainDB(for: built.bass, in: intro) == -60)
        #expect(mix.gainDB(for: built.bass, in: song.sections[1].id) == 0, "the Verse is left as it was")

        mixer.levelSection = nil
        #expect(mixer.level(for: built.bass) == 0, "every section's fader shows the strip's own level")
        mixer.levelSection = intro
        #expect(mixer.hasSectionLevel(for: built.bass))
        mixer.clearSectionLevel(for: built.bass)
        #expect(!mixer.hasSectionLevel(for: built.bass) && app.playback.mix?.sectionGains.isEmpty == true)
    }

    @Test("a part written while the Mixer is open gets its fader")
    func mixerRowsFollow() throws {
        let (app, directory, _) = CompletenessFixture.app("audit-rows")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(CompletenessFixture.song("Arrival"))
        let id = try #require(app.perform(SurfaceAction(surface: .mixer, title: "Mixer")))
        let item = try #require(app.bench.items.first { $0.id == id })
        let mixer = SurfaceWiring.shared.mixerModel(for: item, app: app)
        let bass = PartVersion(partID: PartID(), kind: .bassline(Bassline(notes: [NoteEvent(pitch: Pitch(midi: 38), start: 0, duration: 1)],
                                                                         sound: "finger")),
                               author: .user, operation: Operation.written)
        #expect(!mixer.rows.contains { $0.part == bass.partID })
        #expect(app.record(bass))
        #expect(SurfaceWiring.shared.mixerModel(for: item, app: app).rows.contains { $0.part == bass.partID })
    }

    @Test("a form edit waiting to keep takes a change from outside, and ⌘Z does not take that change out")
    func structureTakesOutsideChanges() throws {
        let groove = TransportFixture.grooveVersion(), chords = TransportFixture.progressionVersion()
        var song = TransportFixture.song([groove, chords], sections: [Section(name: "Verse", stitch: [groove.partID].lanes, lengthInBars: 4)])
        let model = StructureModel(host: StructureStub(), song: song)
        model.autoKeep.delay = nil
        _ = model.add(name: "Outro", bars: 4)
        #expect(model.isDirty && model.canUndo)

        // Chords join the Verse from outside, while the Outro waits to keep.
        song.sections[0].stitch.append(Lane(part: chords.partID))
        model.sync(with: song)
        #expect(model.sections.count == 2, "the Outro is still there")
        #expect(model.sections[0].stitch.contains { $0.part == chords.partID }, "and so are the chords")
        #expect(!model.canUndo, "an undo from before the change would take it out")
    }

    @Test("the form line names only what no section plays at all, which is what its button fills")
    func orphanLineMatchesItsButton() {
        let groove = TransportFixture.grooveVersion(), second = TransportFixture.grooveVersion(), chords = TransportFixture.progressionVersion()
        let song = TransportFixture.song([groove, second, chords], sections: [Section(name: "Verse", stitch: [groove.partID].lanes, lengthInBars: 4)])
        let model = StructureModel(host: StructureStub(), song: song)
        #expect(model.orphanedText == "chords", "a second groove beside the first is not missing: \(model.orphanedText ?? "nil")")
        model.fillAll()
        #expect(model.orphanedText == nil)
    }

    @Test("a solo on a part no section plays silences nothing, live or in export")
    func silentSoloSetAside() throws {
        let built = FormFixture.build(tempo: 92)
        var song = built.song
        song.sections = [Section(name: "Verse", stitch: [built.groove].lanes, lengthInBars: 2)]
        var mix = Mix.unity
        var bass = mix.strip(for: built.bass, label: "Bass")
        bass.isSoloed = true
        mix.set(bass)
        try song.append(PartVersion(partID: PartID(), kind: .mix(mix), author: .user, operation: Operation.mix))
        let plan = SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(URL(fileURLWithPath: "/dev/null")))
        #expect(plan.mix?.hasSolo == false, "the bass plays nowhere, so its solo is set aside")
        #expect(Export.heardStrips(of: plan, song: song).map(\.part) == [built.groove], "the groove is heard")
    }

    @Test("a form with several chops still has room for its takes, and a node for the click")
    func nodeBudget() throws {
        var versions: [PartVersion] = []
        var lanes: [PartID] = []
        for _ in 0..<3 {
            let chop = PartVersion(partID: PartID(), kind: .sample(Sample(media: ChopLaneFixtures.media, slices: [SliceMarker(position: 0)],
                                                                          span: SongGraph.TimeRange(start: 0, end: 2))),
                                   author: .user, operation: Operation.chop)
            versions.append(chop)
            lanes.append(chop.partID)
        }
        var sections: [Section] = []
        for index in 0..<8 {
            let section = Section(name: "S\(index)", stitch: lanes.lanes, lengthInBars: 1)
            sections.append(section)
            let take = TransportFixture.audioVersion(role: .take, duration: 2)
            guard case .audio(var audio) = take.kind else { continue }
            audio.take = Take(section: section.id, startBar: index, sectionStartBar: index)
            versions.append(PartVersion(partID: PartID(), kind: .audio(audio), author: .user, operation: Operation.recorded))
        }
        let song = TransportFixture.song(versions, sections: sections)
        let plan = SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(URL(fileURLWithPath: "/dev/null")))
        #expect(plan.tracks.count == 8, "every sung section plays")
        #expect(plan.tracks.count + 3 + 1 <= SongPlayback.playerNodes)
    }
}

/// A Structure host that takes whatever it is given.
@MainActor
private final class StructureStub: StructureHosting {
    func arrange(_ sections: [Section]) -> Bool { true }
    func play() async {}
    func stop() async {}
    func receive(_ payload: LibraryDragPayload, into section: SectionID) async -> Bool { false }
}

@Suite("The vocal path, audited", .serialized) @MainActor
struct VoxAuditTests {

    private func tone(frames: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buffer.floatChannelData![0][i] = Float(0.4 * sin(2 * .pi * 220 * Double(i) / 48_000)) }
        return buffer
    }

    private func song() -> Song {
        var song = FormFixture.build(tempo: 120).song
        let ids = [Guidance.grooves(in: song).last!].lanes
        song.sections = [Section(name: "Verse", stitch: ids, lengthInBars: 4), Section(name: "Hook", stitch: ids, lengthInBars: 2)]
        return song
    }

    @Test("a take stopped from outside the Booth ends where the song was, and is kept")
    func stopFromOutside() async throws {
        let host = StubBoothHost(song: song())
        host.transport = Transport(clock: host.clock, mode: .offline(sampleRate: 48_000, maximumFrames: 4_096), originSampleTime: 0)
        let hook = host.clock.frame(forBar: 4)
        host.buffers = (0..<4).map { i in (tone(frames: 2_048), AVAudioTime(sampleTime: hook + AVAudioFramePosition(i * 2_048), atRate: 48_000)) }
        let suite = "vox-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(1, forKey: "booth.countInBars")
        let model = BoothModel(host: host, defaults: defaults)
        defaults.removePersistentDomain(forName: suite)
        model.section = host.song?.sections[1].id

        await model.record()
        #expect(model.state == .recording)
        host.playhead = host.clock.seconds(forBar: 5)
        try await Task.sleep(for: .milliseconds(150))
        // The space bar: the song stops and its playhead goes back to 0 before the Booth looks.
        host.isPlaying = false
        host.playhead = 0
        for _ in 0..<500 where model.state == .recording { try await Task.sleep(for: .milliseconds(2)) }
        #expect(model.state == .idle)
        #expect(host.kept.count == 1, "\(model.lastError ?? "")")
    }

    @Test("a take moves with its section: the Verse lengthened, the Hook's vocal still plays in the Hook")
    func takesMoveWithTheirSection() throws {
        var song = song()
        let hook = song.sections[1].id
        let sung = TransportFixture.audioVersion(role: .take, duration: 4)
        guard case .audio(var audio) = sung.kind else { Issue.record("no audio"); return }
        let clock = TransportClock(tempo: 120, timeSignature: .fourFour)
        audio.take = Take(section: hook, startBar: 4, sectionStartBar: 4)
        audio.alignmentOffset = clock.seconds(forBar: 3)
        try song.append(PartVersion(partID: PartID(), kind: .audio(audio), author: .user, operation: Operation.recorded))
        let resolver = TransportFixture.resolver(URL(fileURLWithPath: "/dev/null"))
        let before = try #require(SongPlayback.plan(for: song, mediaURL: resolver).tracks.first)
        #expect(abs(before.startsAt - (clock.seconds(forBar: 4) - 0.05)) < 1e-6)

        song.sections[0].lengthInBars = 8
        let after = try #require(SongPlayback.plan(for: song, mediaURL: resolver).tracks.first)
        #expect(abs(after.startsAt - (clock.seconds(forBar: 8) - 0.05)) < 1e-6, "four bars later, with the Hook")
        #expect(abs(after.skip - before.skip) < 1e-6, "the same audio under it")
    }

    @Test("a take sung after a comp does not take the comp's place in the song; a restore does")
    func compKeepsPlaying() throws {
        let part = PartID()
        func take(_ pass: Int) -> PartVersion {
            let version = TransportFixture.audioVersion(role: .take, duration: 4)
            guard case .audio(var audio) = version.kind else { fatalError() }
            audio.take = Take(startBar: 0, pass: pass)
            return PartVersion(partID: part, kind: .audio(audio), author: .user, operation: Operation.recorded)
        }
        let one = take(1), two = take(2)
        guard case .audio(var compAudio) = one.kind else { return }
        compAudio.take = nil
        compAudio.comp = CompPlan(spans: [.init(startBar: 0, endBar: 2, take: one.id)])
        let comp = PartVersion(partID: part, kind: .audio(compAudio), author: .user, parents: [one.id], operation: Operation.comped)
        var song = TransportFixture.song([one, comp], sections: [])
        #expect(SongPlayback.sungVersion(of: part, in: song)?.id == comp.id)
        try song.append(two)
        #expect(SongPlayback.sungVersion(of: part, in: song)?.id == comp.id, "a new take is a candidate, not the comp's replacement")
        let restored = two.deriving(two.kind, by: .user, operation: Operation.restored)
        try song.append(restored)
        #expect(SongPlayback.sungVersion(of: part, in: song)?.id == restored.id)
    }

    @Test("the Lyricist's words reach a page opened blank, and its next keystroke builds on them")
    func lyricsFollowTheLyricist() throws {
        let (app, directory, _) = CompletenessFixture.app("audit-lyrics")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.discardSurfaceModel = { SurfaceWiring.shared.discardModel(for: $0) }
        app.open(Song.new(title: "Glass", tempo: 96))
        let id = try #require(app.perform(SurfaceAction(surface: .lyrics, title: "Lyrics")))
        let item = try #require(app.bench.items.first { $0.id == id })
        let page = SurfaceWiring.shared.lyricsModel(for: item, app: app)
        page.autoKeep.delay = nil
        page.text = "[Verse]\nfirst words"
        let mine = try #require(page.commit())

        let theirs = mine.deriving(.lyric(Lyricist.lyric(from: "[Verse]\nthe Lyricist's words")), by: .persona("Lyricist"),
                                   operation: Operation.written, note: "Lyric")
        #expect(AppStateWorkspace(app).record(theirs))
        let reopened = SurfaceWiring.shared.lyricsModel(for: item, app: app)
        #expect(reopened.text.contains("the Lyricist's words"), "\(reopened.text)")
    }

    @Test("takes at different rates are comped, each brought to the highest")
    func mixedRatesComp() throws {
        func take(rate: Double) -> Comp.TakeAudio {
            let frames = Int(rate * 4)
            return Comp.TakeAudio(planar: [(0..<frames).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / rate)) }],
                                  sampleRate: rate, alignmentSeconds: 0)
        }
        let a = VersionID(), b = VersionID()
        let plan = CompPlan(spans: [.init(startBar: 0, endBar: 1, take: a), .init(startBar: 1, endBar: 2, take: b)])
        let rendered = try Comp.render(plan, takes: [a: take(rate: 48_000), b: take(rate: 44_100)],
                                       clock: TransportClock(tempo: 120, timeSignature: .fourFour))
        #expect(rendered.sampleRate == 48_000)
        #expect(abs(Double(rendered.planar[0].count) - 4 * 48_000) < 480)
    }
}
