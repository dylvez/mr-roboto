import AudioEngine
import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// M5 R8–R9: the critics flag the sharp note and the late onset with two fixes each; the Takes
// surface carries the flags; read_take says them back in the band's numbers.

/// Four notes a beat apart from bar 1 in D major: D4, F#4 +31 cents, A4 60 ms late, D4.
enum SungTake {
    static let rate = 48_000.0
    static let clock = TransportClock(tempo: 120, timeSignature: .fourFour, sampleRate: 48_000)

    static func planar() -> [[Float]] {
        let notes: [(midi: Double, at: Double)] = [(62, 0), (66.31, 0.5), (69, 1.06), (62, 1.5)]
        let length = Int(2.2 * rate)
        var out = [Float](repeating: 0, count: length)
        for note in notes {
            let hz = 440 * pow(2, (note.midi - 69) / 12)
            let start = Int(note.at * rate), n = Int(0.4 * rate)
            var phase = 0.0
            for i in 0..<n where start + i < length {
                phase += 2 * .pi * hz / rate
                var env = 1.0
                let ramp = Int(0.01 * rate)
                if i < ramp { env = Double(i) / Double(ramp) }
                if n - i < ramp { env = Double(n - i) / Double(ramp) }
                out[start + i] += Float(0.3 * env * (sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)))
            }
        }
        return [out]
    }

    static var alignment: Double { clock.seconds(forBar: 1) }

    static func analysis() -> TakeAnalysis {
        TakeAnalysis.of(planar(), sampleRate: rate, alignmentSeconds: alignment, key: Key(tonic: NoteName(.d)), clock: clock, label: "Take 1")
    }
}

@Suite("Take critics: a bar and a number, two fixes, the retake always one of them")
struct TakeCriticsTests {

    @Test("pitch drift and timing each flag exactly the note that earns it")
    func flags() {
        let findings = CriticBoard.standard.review(TakeReview(analysis: SungTake.analysis()))
        #expect(findings.count == 2, "\(findings.map(\.headline))")
        let pitch = findings.first { $0.critic == .pitchDrift }!
        #expect(pitch.headline.hasPrefix("Bar 2, +3") && pitch.headline.hasSuffix("cents"), "\(pitch.headline)")
        #expect(pitch.persona == .engineer && pitch.subject == .bar(1) && pitch.severity == .warn)
        #expect(pitch.measurement.unit == "cents" && pitch.measurement.trips)
        #expect(pitch.fixes.count == 2)
        if case .shiftNote(let index, let cents) = pitch.fixes[0].change { #expect(index == 1 && cents < -27 && cents > -35) } else { Issue.record("no shift offered") }
        if case .retake(let bar) = pitch.fixes[1].change { #expect(bar == 1) } else { Issue.record("no retake offered") }
        let timing = findings.first { $0.critic == .timing }!
        #expect(timing.headline.hasPrefix("Bar 2 came in") && timing.headline.hasSuffix("ms late"), "\(timing.headline)")
        #expect(timing.persona == .lyricist)
        if case .nudgeNote(let index, let ms) = timing.fixes[0].change { #expect(index == 2 && ms < -45 && ms > -75) } else { Issue.record("no nudge offered") }
        // Under the noticeable line, nothing is said.
        let quiet = CriticBoard.standard.review(TakeReview(analysis: SungTake.analysis(), noticeableCents: 40, noticeableMS: 80))
        #expect(quiet.isEmpty)
    }

    @Test("read_take says the flags back in cents and milliseconds, with the fixes named")
    func readTake() async throws {
        var song = Song(title: "Arrival", artist: "Vessel", key: Key(tonic: NoteName(.d)), tempo: 120)
        song.sections = [Section(name: "Verse", stitch: [], lengthInBars: 4)]
        let audio = Audio(media: MediaRef(hash: ContentHash(hex: String(repeating: "f", count: 64))!, fileExtension: "wav"), role: .take,
                          sampleRate: SungTake.rate, channelCount: 1, duration: 2.2, alignmentOffset: SungTake.alignment,
                          take: Take(section: song.sections[0].id, startBar: 1, input: "Stub mic", pass: 1))
        let version = PartVersion(partID: PartID(), kind: .audio(audio), author: .user, operation: Operation.recorded, note: "Take 1, Verse")
        try song.append(version)
        let workspace = await MainActor.run { () -> DirectorScratchWorkspace in
            let w = DirectorScratchWorkspace(song: song)
            w.takeAudio[version.id] = Comp.TakeAudio(planar: SungTake.planar(), sampleRate: SungTake.rate, alignmentSeconds: SungTake.alignment)
            return w
        }
        let box = await MainActor.run { DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4)), workspace: workspace) }
        let result = await box.run(ClaudeToolUse(id: "t", name: "read_take", input: .object([.init("take", .string(""))])))
        #expect(!result.isError, "\(result.content)")
        let json = (try? JSONSerialization.jsonObject(with: result.content.data(using: .utf8)!) as? [String: Any]) ?? [:]
        let take = json["take"] as? [String: Any]
        #expect(take?["title"] as? String == "Take 1" && take?["section"] as? String == "Verse" && take?["start_bar"] as? Int == 2)
        let notes = json["notes"] as? [[String: Any]] ?? []
        #expect(notes.count == 4 && notes[1]["note"] as? String == "F♯4" || notes[1]["note"] as? String == "F#4", "\(notes.map { $0["note"] ?? "" })")
        let flags = json["flags"] as? [[String: Any]] ?? []
        #expect(flags.count == 2)
        #expect(flags.contains { ($0["unit"] as? String) == "cents" && ($0["offered"] as? String)?.hasPrefix("Correct it by") == true && ($0["otherwise"] as? String) == "Retake bar 2" })
        #expect(flags.contains { ($0["unit"] as? String) == "ms" && ($0["offered"] as? String)?.contains("earlier") == true })
        #expect((json["detail"] as? String)?.contains("read against D major") == true, "\(json["detail"] ?? "")")

        // The flags reach the Takes surface too.
        let flagsOnSurface = await MainActor.run { () -> Int in
            final class Host: TakesHosting {
                let w: DirectorScratchWorkspace
                init(_ w: DirectorScratchWorkspace) { self.w = w }
                var clock: TransportClock { w.clock }
                var key: Key? { w.song?.key }
                func audio(of version: PartVersion) -> Comp.TakeAudio? { w.takeAudio(of: version) }
                func audition(_ version: PartVersion) async {}
                func stopAudition() {}
                func keepComp(_ rendered: Comp.Rendered, plan: CompPlan, takes: [PartVersion]) -> PartVersion? { nil }
                func openCheck(_ finding: Finding, on take: PartVersion) {}
                func note(_ text: String, detail: String?) {}
            }
            let model = TakesModel(host: Host(workspace), takes: [version], song: workspace.song)
            return model.flags[version.id]?.count ?? -1
        }
        #expect(flagsOnSurface == 2)
    }
}

@Suite("Check on a take: the offer taken is a new version; the take is untouched", .serialized) @MainActor
struct TakeCheckTests {

    @Test("correcting the sharp note records a corrected version that reads within 5 cents, and the retake is refused with directions")
    func offerTaken() async throws {
        let directory = LibraryFixture.directory("take-check")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory)
        let app = AppState(library: Library(), song: nil, store: store, status: .empty(directory), transportHost: StubTransportHost())
        var song = Song(title: "Arrival", artist: "Vessel", key: Key(tonic: NoteName(.d)), tempo: 120)
        song.sections = [Section(name: "Verse", stitch: [], lengthInBars: 4)]
        app.open(song)
        app.save()
        let package = try store.songStore(for: song.id)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sung-\(UUID().uuidString).wav")
        try BoothAdapter.write(SungTake.planar(), sampleRate: SungTake.rate, to: scratch)
        let media = try package.addMedia(copying: scratch)
        let audio = Audio(media: media, role: .take, sampleRate: SungTake.rate, channelCount: 1, duration: 2.2, alignmentOffset: SungTake.alignment,
                          take: Take(section: song.sections[0].id, startBar: 1, input: "Stub mic", pass: 1))
        let take = PartVersion(partID: PartID(), kind: .audio(audio), author: .user, operation: Operation.recorded, note: "Take 1, Verse")
        #expect(app.record(take))

        let findings = CriticBoard.standard.review(TakeReview(analysis: SungTake.analysis()))
        let pitch = try #require(findings.first { $0.critic == .pitchDrift })
        let adapter = CheckAdapter(app: app, service: SurfaceWiring.shared.service(for: app), subject: take.id)

        let outcome = await adapter.apply(pitch.fixes[0], of: pitch)
        guard case .resolved = outcome else { Issue.record("expected resolved, got \(outcome)"); return }
        let corrected = try #require(app.song?.versions.last)
        #expect(corrected.operation == Operation.corrected && corrected.parents == [take.id] && corrected.partID == take.partID)
        #expect(corrected.note?.contains("corrected from Take 1") == true)
        #expect(PartLabel.title(of: corrected) == "Record" || Guidance.audio(of: corrected)?.take == nil, "a corrected version is not itself a take")
        // The take's media is what it was; the corrected version has its own.
        #expect(Guidance.audio(of: app.version(take.id)!)?.media == media)
        let correctedAudio = try #require(Guidance.audio(of: corrected))
        #expect(correctedAudio.media != media)
        let url = try store.mediaURL(for: correctedAudio.media, song: song.id)
        let planar = try BoothAdapter.planar(url)
        let after = TakeAnalysis.of(planar.planar, sampleRate: planar.sampleRate, alignmentSeconds: SungTake.alignment, key: song.key, clock: SungTake.clock)
        #expect(after.notes.count == 4 && abs(after.notes[1].centsFromKey) < 5, "\(after.notes.map(\.centsFromKey))")

        let retake = await adapter.apply(pitch.fixes[1], of: pitch)
        guard case .refused(let why) = retake else { Issue.record("a retake is not a card's to do"); return }
        #expect(why.contains("Booth"))
        #expect(app.song?.versions.count == 2, "the refusal recorded nothing")
    }
}
