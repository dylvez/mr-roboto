import AppKit
import AudioEngine
import Foundation
import MusicTheory
import Performance
import SongGraph
import SwiftUI
import Testing

@testable import MrRobotoApp

// M6 X3–X5: the Mixer records one version per gesture with the move in its note; the Master
// reads a bounce; Mix is the last step on the path.

@MainActor
private final class StubMixHost: MixHosting {
    var song: Song?
    var playback: SongPlayback
    var isPlaying = false
    var targets = Master()
    var previews: [Mix] = []
    var committed: [(Mix, PartVersion?, String)] = []
    var bounceResult: (planar: [[Float]], sampleRate: Double) = ([[Float](repeating: 0, count: 4800)], 48_000)
    /// Every section a bounce was asked for, nil for the whole song.
    var bounced: [SectionID?] = []
    /// When set, a bounce waits here until the test lets it go: the only way to see a read in flight.
    var hold: AsyncStream<Void>?

    init(song: Song, playback: SongPlayback) { self.song = song; self.playback = playback }

    func preview(_ mix: Mix) { previews.append(mix) }
    func commit(_ mix: Mix, base: PartVersion?, note: String) -> PartVersion? {
        committed.append((mix, base, note))
        let version = PartVersion(partID: base?.partID ?? PartID(), kind: .mix(mix), author: .user, parents: base.map { [$0.id] } ?? [],
                                  operation: Operation.mix, note: note)
        try? song?.append(version)
        return version
    }
    func meters(for parts: [PartID]) async -> [PartID: (peak: Float, rms: Float)] { [:] }
    func bounce(mix: Mix, section: SectionID?) async throws -> (planar: [[Float]], sampleRate: Double) {
        bounced.append(section)
        if let hold { for await _ in hold { break } }
        return bounceResult
    }
    func note(_ text: String, detail: String?) {}
}

@Suite("Mixer: a strip per part, a version per gesture", .serialized) @MainActor
struct MixerTests {

    private func fixture() -> (Song, SongPlayback) {
        let song = FormFixture.build(tempo: 92).song
        let plan = SongPlayback.plan(for: song) { _ in nil }
        return (song, plan)
    }

    @Test("more parts than strips: every part still plays, and the Mixer draws a row for each")
    func morePartsThanStrips() throws {
        var song = FormFixture.build(tempo: 92).song
        // One more pitched part than the graph holds strips, all in one section, so they all sound
        // at once and every one of them wants a fader.
        var lanes = song.sections.first?.stitch ?? []
        for i in 0...(MixGraph.slotCount) {
            let version = PartVersion(partID: PartID(),
                                      kind: .progression(Progression(key: Key(tonic: NoteName(.c)),
                                                                     bars: [ProgressionBar(Chord(.c, .major))])),
                                      author: .user, operation: Operation.written, note: "Chords \(i)")
            try song.append(version)
            lanes.append(Lane(part: version.partID))
        }
        song.sections = [Section(name: "Verse", stitch: lanes, lengthInBars: 8)]

        let plan = SongPlayback.plan(for: song) { _ in nil }
        #expect(plan.parts.count > MixGraph.slotCount, "the point of the test")
        #expect(plan.segments[0].voices.count == lanes.count, "every lane sounds, strip or no strip")

        // The Mixer names them all, including the ones that will not get a strip: a row that says
        // "unmixed" is better than a fader that silently does nothing, which is what used to happen.
        let rows = MixerModel.rows(of: plan, song: song, mix: .unity)
        #expect(Set(rows.map(\.part)) == Set(plan.parts))
    }

    @Test("the chords and the tune get a strip: every part you can hear is a part you can touch")
    func chordsHaveAFader() throws {
        let (song, plan) = fixture()
        let host = StubMixHost(song: song, playback: plan)
        let model = MixerModel(host: host)

        // The instrument sampler has been routed through the progression's part since the transport
        // learned to play chords — so the strip existed in the graph, drew no fader, and could not
        // be levelled, panned, muted or soloed.
        let chords = try #require(plan.progressionPart, "the fixture's song has chords in it")
        #expect(model.rows.contains { $0.part == chords }, "no strip for the chords: \(model.rows.map(\.label))")

        // And it behaves as any other strip does.
        model.setGain(-4, for: chords)
        #expect(model.endGesture() != nil)
        #expect(host.committed.last?.0.strip(for: chords)?.gainDB == -4)
    }

    @Test("the rows are the parts the plan plays; a fader let go of is one version whose note says the move")
    func gestures() throws {
        let (song, plan) = fixture()
        let host = StubMixHost(song: song, playback: plan)
        let initial = Guidance.mixes(in: song).count
        let model = MixerModel(host: host)
        #expect(model.rows.count >= 2, "\(model.rows.map(\.label))")
        let bass = try #require(model.rows.first { $0.part == plan.basslinePart })
        #expect(bass.label == "Palladino line")
        model.setGain(-2, for: bass.part)
        model.setGain(-3, for: bass.part)
        #expect(host.previews.count == 2 && host.committed.isEmpty, "a drag previews, it does not record")
        let version = try #require(model.endGesture())
        #expect(host.committed.count == 1)
        #expect(version.operation == Operation.mix && version.note == "Palladino line -3.0 dB", "\(version.note ?? "")")
        #expect(model.endGesture() == nil, "nothing moved, nothing recorded")
        model.setEQ(band: 1, gainDB: -6, for: bass.part)
        model.setEQ(band: 1, frequency: 80, for: bass.part)
        let second = try #require(model.endGesture())
        #expect(second.parents == [version.id] && second.partID == version.partID)
        #expect(second.note == "Palladino line EQ 80 Hz -6.0 dB", "\(second.note ?? "")")
        model.toggleMute(bass.part)
        #expect(host.committed.last?.2 == "Palladino line muted")
        model.setMaster(ceilingDBTP: -0.5)
        #expect(model.endGesture()?.note == "master ceiling -0.5 dBTP")
        #expect(Guidance.mixes(in: host.song!).count == initial + 4 && Guidance.mix(in: host.song!)?.master.ceilingDBTP == -0.5)
    }

    @Test("the Master reads a bounce: loudness, true peak, the spectrum, and what to change first")
    func master() async throws {
        let (song, plan) = fixture()
        let host = StubMixHost(song: song, playback: plan)
        let rate = 48_000.0
        host.bounceResult = ([(0..<Int(2 * rate)).map { Float(0.05 * sin(2 * .pi * 1_000 * Double($0) / rate)) }], rate)
        let model = MasterModel(host: host)
        #expect(model.reading == nil)
        await model.read()
        let reading = try #require(model.reading)
        #expect(reading.observation.integratedLUFS < -20 && reading.observation.integratedLUFS > -40)
        #expect(abs(reading.truePeakDBTP - 20 * log10(0.05)) < 0.3)
        #expect(reading.spectrumDB.count == 48 && reading.spectrumDB.max() == 0)
        #expect(reading.firstToChange?.rule == "engineer.delivery-loudness", "\(reading.firstToChange?.rule ?? "")")
        let suggested = try #require(model.suggestedGainDB)
        #expect(suggested > 6 && suggested < 30)
        model.hitTheTarget()
        #expect(host.committed.count == 1 && host.committed[0].2.hasPrefix("master +"))
        // Counted from the gain the reading was bounced at, so it is not suggested again on top of
        // itself: pressing it twice is the same as pressing it once.
        #expect(model.suggestedGainDB == suggested)
        model.hitTheTarget()
        #expect(host.committed.count == 1)
    }

    @Test("the Master says what it read — the whole song — and marks the reading stale once the bounce would differ")
    func readingScope() async throws {
        let (song, plan) = fixture()
        let host = StubMixHost(song: song, playback: plan)
        let model = MasterModel(host: host)
        // Whatever the plan, the reading is of the whole song: the bounce is asked for no section,
        // and the scope counts what `SectionBounce` will render when it is asked for none.
        let bars = try SectionBounce.isolate(plan, section: nil).2
        #expect(model.scope == MasterModel.Scope(bars: bars, sections: plan.segments.count))
        #expect(model.scope.label == "Whole song")
        #expect(MasterModel.Scope(bars: 24, sections: 3).detail == "3 sections · 24 bars")
        #expect(MasterModel.Scope(bars: 1, sections: 0).detail == "1 bar")
        #expect(MasterModel.Scope(bars: 46, sections: 5).progressLine == "Bouncing 46 bars…")

        await model.read()
        let reading = try #require(model.reading)
        #expect(reading.scope == model.scope && reading.scope.label == "Whole song")
        #expect(host.bounced == [nil], "a section was asked for: \(host.bounced)")
        #expect(abs(reading.seconds - 0.1) < 1e-9, "4 800 frames at 48 kHz")
        #expect(!model.isStale)

        // The target is what the numbers are judged against, not something in the bounce.
        model.setTarget(-16)
        #expect(!model.isStale)
        // The gain and the ceiling are in the bounce, so the numbers are of a mix that is gone.
        model.setGain(3)
        #expect(model.isStale)
        await model.read()
        #expect(!model.isStale)
        model.setCeiling(-2)
        #expect(model.isStale)
        // A lever put back where it was is not a change.
        model.setCeiling(-2)
        await model.read()
        model.setCeiling(model.mix.master.ceilingDBTP)
        #expect(!model.isStale)
        model.setGain(6)
        model.setGain(3)
        #expect(!model.isStale, "back where it was read")
    }

    @Test("a send at the bottom of its travel is off, and reads as off rather than as -60 dB")
    func sendReadsOff() {
        #expect(MixerModel.sendReadout(nil) == "off")
        #expect(MixerModel.sendReadout(MixerModel.sendOffDB) == "off")
        #expect(MixerModel.sendReadout(-12) == "-12 dB")
        #expect(MixerModel.sendReadout(0) == "0 dB")
        #expect(MixerModel.send(fromFader: MixerModel.sendOffDB) == nil)
        #expect(MixerModel.send(fromFader: -59.8) == nil, "the fader's bottom notch is off, not a level")
        #expect(MixerModel.send(fromFader: -30) == -30)
        // And what the fader sets is what the readout says.
        let (song, plan) = fixture()
        let host = StubMixHost(song: song, playback: plan)
        let model = MixerModel(host: host)
        let part = model.rows[0].part
        model.setSend(MixerModel.send(fromFader: -60), for: part)
        #expect(model.strip(part).sendDB == nil && MixerModel.sendReadout(model.strip(part).sendDB) == "off")
        model.setSend(MixerModel.send(fromFader: -18), for: part)
        #expect(model.strip(part).sendDB == -18 && MixerModel.sendReadout(model.strip(part).sendDB) == "-18 dB")

    }

    @Test("Mix is the last step on both paths and opens the Mixer, then the Master once arranged and mixed")
    func path() throws {
        var (song, _) = fixture()
        #expect(WorkPath.flip.steps.last == .mix && WorkPath.beat.steps.last == .mix)
        let initial = Guidance.mixes(in: song).count
        let before = WorkPath.steps(for: song, active: nil, canPerform: { _ in true }).steps.first { $0.kind == .mix }!
        #expect(before.count == initial && before.action?.surface == .mixer, "no sections: the Mixer")
        try song.append(PartVersion(partID: PartID(), kind: .mix(Mix()), author: .user, operation: Operation.mix, note: "Mix"))
        song.sections = [Section(name: "Verse", stitch: [Guidance.grooves(in: song).last!].lanes, lengthInBars: 4)]
        let after = WorkPath.steps(for: song, active: (kind: .master, bound: []), canPerform: { _ in true }).steps.first { $0.kind == .mix }!
        #expect(after.count == initial + 1 && after.isHere && after.action?.surface == .master)
        #expect(PartLabel.title(of: Guidance.mixes(in: song)[0]) == "Mix")
    }
}

// The Mixer and the Master folded into one surface: the Master as the Mixer's second tab, working
// on the Mixer's mix, and reading the whole song rather than its first section.

@Suite("Mixer: the Master as a tab, on one mix", .serialized) @MainActor
struct MixerMasterTabTests {

    /// A song in two sections, so "the first section" and "the whole song" are different lengths.
    private func arranged(verse: Int = 4, hook: Int = 8) throws -> (Song, SongPlayback) {
        var song = FormFixture.build(tempo: 92).song
        let lanes = [try #require(Guidance.grooves(in: song).last), try #require(Guidance.basslines(in: song).last)].lanes
        song.sections = [Section(name: "Verse", stitch: lanes, lengthInBars: verse),
                         Section(name: "Hook", stitch: lanes, lengthInBars: hook)]
        return (song, SongPlayback.plan(for: song) { _ in nil })
    }

    @Test("an arranged song is read whole — every section in order — and says so while it bounces")
    func wholeSongOfAnArrangement() async throws {
        let (song, plan) = try arranged()
        #expect(plan.isArranged && plan.segments.count == 2, "the point of the test")
        let host = StubMixHost(song: song, playback: plan)
        let (stream, release) = AsyncStream.makeStream(of: Void.self)
        host.hold = stream
        let model = MasterModel(host: host)
        #expect(model.scope == MasterModel.Scope(bars: 12, sections: 2))
        #expect(model.scope.label == "Whole song" && model.scope.detail == "2 sections · 12 bars")
        #expect(model.progressLine == nil)

        let reading = Task { await model.read() }
        for _ in 0..<1_000 where !model.isReading { await Task.yield() }
        #expect(model.isReading)
        #expect(model.progressLine == "Bouncing 12 bars…")
        // A lever moved while the bounce runs: the reading is of the mix as it was, and lands stale.
        model.setGain(2)
        release.yield()
        await reading.value
        #expect(!model.isReading && model.progressLine == nil)
        #expect(host.bounced == [nil], "the Master asked for a section: \(host.bounced)")
        let read = try #require(model.reading)
        #expect(read.scope == MasterModel.Scope(bars: 12, sections: 2) && read.scope.label == "Whole song")
        #expect(read.mix.master.gainDB == 0 && model.isStale)
    }

    @Test("through the real adapter, a reading of an arranged song is as long as the song, not its first section")
    func wholeSongThroughTheAdapter() async throws {
        let (song, _) = try arranged(verse: 1, hook: 2)
        let directory = WiringFixture.temporaryDirectory("master-whole-song")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory, song: song)
        app.refreshPlayback()
        #expect(app.playback.isArranged)
        let model = MasterModel(host: MixAdapter(app: app))
        #expect(model.scope == MasterModel.Scope(bars: 3, sections: 2))
        await model.read()
        let reading = try #require(model.reading, "\(model.lastError ?? "")")
        let bar = 4 * 60 / 92.0
        // Three bars and the half-second tail; the Verse alone would be one.
        #expect(abs(reading.seconds - (3 * bar + 0.5)) < 0.05, "\(reading.seconds) s")
        #expect(reading.observation.integratedLUFS.isFinite)
    }

    @Test("the Mixer shows a Master tab only when it is given a Master, and the Master then reads the Mixer's mix")
    func masterTab() throws {
        let (song, plan) = try arranged()
        let host = StubMixHost(song: song, playback: plan)
        // A song on an album with its own targets and never mixed: both start there, not at −14.
        host.playback.mix = nil
        host.targets = Master(gainDB: 0, ceilingDBTP: -2, targetLUFS: -16)
        let mixer = MixerModel(host: host)
        #expect(mixer.mix.master == host.targets)

        let alone = MixerSurfaceView(model: mixer)
        #expect(alone.tabs == [.strips])
        mixer.tab = .master
        #expect(alone.shownTab == .strips, "asked for a Master it was not given: the strips")

        let master = MasterModel(host: host)
        #expect(!master.isFollowingMixer && master.mix.master == host.targets)
        let folded = MixerSurfaceView(model: mixer, master: master)
        #expect(folded.tabs == [.strips, .master] && folded.shownTab == .master)
        #expect(master.isFollowingMixer)
        _ = MixerSurfaceView(model: mixer, master: master)
        #expect(master.isFollowingMixer, "building the view again changes nothing")

        // A strip moved on the Strips tab is in the mix the Master tab reads and bounces.
        let part = try #require(mixer.rows.first?.part)
        mixer.setGain(-5, for: part)
        #expect(master.mix.strip(for: part)?.gainDB == -5)

        // It draws at the bench's minimum, on either tab.
        for tab in MixerModel.Tab.allCases {
            mixer.tab = tab
            let renderer = ImageRenderer(content: MixerSurfaceView(model: mixer, master: master)
                .frame(width: Design.Metric.surfaceMinimumWidth, height: Design.Metric.surfaceMinimumHeight))
            #expect(renderer.nsImage != nil, "\(tab)")
        }
    }

    @Test("a master lever moved on the Mixer's tab is a mix version on the Mixer's line, and stales the reading")
    func leverOnTheTab() async throws {
        let (song, plan) = try arranged()
        let host = StubMixHost(song: song, playback: plan)
        let mixer = MixerModel(host: host)
        let master = MasterModel(host: host)
        _ = MixerSurfaceView(model: mixer, master: master)

        let part = try #require(mixer.rows.first?.part)
        mixer.setGain(-4, for: part)
        let stripMove = try #require(mixer.endGesture())

        await master.read()
        #expect(master.reading != nil && !master.isStale)
        #expect(master.reading?.mix.strip(for: part)?.gainDB == -4, "the Master read the Mixer's mix, strip move and all")

        master.setGain(2)
        #expect(master.isStale)
        #expect(mixer.mix.master.gainDB == 2, "the master row on the strips shows it")
        #expect(host.previews.last?.master.gainDB == 2, "heard while held")
        let version = try #require(master.endGesture())
        #expect(version.parents == [stripMove.id], "one line of versions, not a sibling of the strip move")
        #expect(version.note == "master +2.0 dB", "\(version.note ?? "")")
        guard case .mix(let kept) = version.kind else { Issue.record("not a mix version"); return }
        #expect(kept.strip(for: part)?.gainDB == -4 && kept.master.gainDB == 2, "the strip move survives the master move")
        #expect(mixer.base?.id == version.id && master.base?.id == version.id)
        #expect(master.lastNote == "master +2.0 dB")
        #expect(master.endGesture() == nil, "nothing moved since")

        // The target is what the numbers are judged against: it moves without staling them...
        await master.read()
        master.setTarget(-10)
        #expect(!master.isStale && mixer.mix.master.targetLUFS == -10)
        #expect(master.endGesture()?.note == "target -10 LUFS")
        // ...while a strip moved on the other tab stales them, as a lever does,
        mixer.setGain(-8, for: part)
        #expect(master.isStale)
        // and so does the controller's master knob, which moves the Mixer.
        mixer.setGain(-4, for: part)
        #expect(!master.isStale)
        mixer.setMaster(gainDB: 5)
        #expect(master.mix.master.gainDB == 5 && master.isStale)
    }
}

// The folded Mixer drawn offscreen, both tabs, at the bench's minimum and at a working width. Off
// by default, like the frame renders:
//
//     MRROBOTO_RENDER=/path/to/dir swift test --filter MixerRender

@Suite("Mixer render", .enabled(if: ProcessInfo.processInfo.environment["MRROBOTO_RENDER"] != nil,
                                "set MRROBOTO_RENDER to a directory to write the renders"))
@MainActor
struct MixerRenderTests {

    @Test("the Mixer's strips and Master tabs, at the bench's minimum and wide")
    func tabs() async throws {
        FontRegistration.registerBundledFonts()
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MRROBOTO_RENDER"]))
        var song = FormFixture.build(tempo: 92).song
        let lanes = [try #require(Guidance.grooves(in: song).last), try #require(Guidance.basslines(in: song).last)].lanes
        song.sections = [Section(name: "Verse", stitch: lanes, lengthInBars: 4), Section(name: "Hook", stitch: lanes, lengthInBars: 8)]
        let host = StubMixHost(song: song, playback: SongPlayback.plan(for: song) { _ in nil })
        let rate = 48_000.0
        host.bounceResult = ([(0..<Int(2 * rate)).map { Float(0.05 * sin(2 * .pi * 1_000 * Double($0) / rate)) }], rate)
        let mixer = MixerModel(host: host)
        let master = MasterModel(host: host)
        _ = MixerSurfaceView(model: mixer, master: master)
        await master.read()
        mixer.setGain(-3, for: mixer.rows[0].part)
        mixer.endGesture()

        let sizes = [("minimum", CGSize(width: Design.Metric.surfaceMinimumWidth, height: Design.Metric.surfaceMinimumHeight)),
                     ("wide", CGSize(width: 1100, height: 720))]
        for tab in MixerModel.Tab.allCases {
            mixer.tab = tab
            for (name, size) in sizes {
                try write(MixerSurfaceView(model: mixer, master: master), size: size, to: directory, name: "mixer-\(tab.rawValue.lowercased())-\(name)")
            }
        }
        for (name, size) in sizes {
            try write(MasterSurfaceView(model: MasterModel(host: host)), size: size, to: directory, name: "master-alone-\(name)")
        }
    }

    private func write<V: View>(_ view: V, size: CGSize, to directory: URL, name: String) throws {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
