import AudioEngine
import Foundation
import MusicTheory
import Performance
import SongGraph
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
    func bounce(mix: Mix, section: SectionID?) async throws -> (planar: [[Float]], sampleRate: Double) { bounceResult }
    func note(_ text: String, detail: String?) {}
}

@Suite("Mixer: a strip per part, a version per gesture", .serialized) @MainActor
struct MixerTests {

    private func fixture() -> (Song, SongPlayback) {
        let song = FormFixture.build(tempo: 92).song
        let plan = SongPlayback.plan(for: song) { _ in nil }
        return (song, plan)
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
    }

    @Test("Mix is the last step on both paths and opens the Mixer, then the Master once arranged and mixed")
    func path() throws {
        var (song, _) = fixture()
        #expect(WorkPath.flip.steps.last == .mix && WorkPath.beat.steps.last == .mix)
        let initial = Guidance.mixes(in: song).count
        let before = WorkPath.steps(for: song, active: nil, canPerform: { _ in true }).steps.first { $0.kind == .mix }!
        #expect(before.count == initial && before.action?.surface == .mixer, "no sections: the Mixer")
        try song.append(PartVersion(partID: PartID(), kind: .mix(Mix()), author: .user, operation: Operation.mix, note: "Mix"))
        song.sections = [Section(name: "Verse", stitch: [Guidance.grooves(in: song).last!.id], lengthInBars: 4)]
        let after = WorkPath.steps(for: song, active: (kind: .master, bound: []), canPerform: { _ in true }).steps.first { $0.kind == .mix }!
        #expect(after.count == initial + 1 && after.isHere && after.action?.surface == .master)
        #expect(PartLabel.title(of: Guidance.mixes(in: song)[0]) == "Mix")
    }
}
