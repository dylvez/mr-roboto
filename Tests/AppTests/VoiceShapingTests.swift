import Foundation
@testable import Instrument
import SongGraph
import Testing
@testable import MrRobotoApp

// A drum voice kept on the Sound surface is a voice the song plays, and a voice a recording plays
// shows what a recording has: its level.
//
// Before this the surface opened on the TR-808's kick whatever the song played, kept a voice into
// the ledger that no kit was ever built from, and on a recorded kit showed the knobs of a
// synthesizer that was not sounding.

@MainActor
private enum VoiceFixture {
    /// A song on `machine` with one groove that plays.
    static func song(on machine: String) throws -> (Song, PartVersion) {
        var song = Song(title: "Arrival", artist: "Vessel", tempo: 96)
        let groove = PartVersion(partID: PartID(), kind: .groove(Groove(stepsPerBar: 16, bars: 1, swing: 0, patterns: [
            GroovePattern(voice: .kick, steps: "x---x---x---x---".map { $0 == "x" ? .normal : .rest }),
        ])), author: .user, operation: Operation.written, note: "Four on the floor")
        try song.append(groove)
        try song.append(PartVersion(partID: PartID(), kind: .sound(Sound(instrument: machine)), author: .user,
                                    operation: Operation.written, note: machine))
        return (song, groove)
    }

    static func edit(_ machine: String, _ voice: SynthVoiceKind, _ change: (inout SynthControls) -> Void) -> PartVersion {
        var state = SoundState(machine: machine, voice: voice)
        change(&state.controls)
        return PartVersion(partID: PartID(), kind: .sound(state.sound), author: .user, operation: Operation.written)
    }

    /// A burst of noise that dies away.
    static func hit(seed: UInt64, level: Float = 0.5) -> [Float] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let frames = 9_600
        return (0..<frames).map { frame in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Float(Int64(bitPattern: state >> 11) % 2_000) / 1_000 - 1
            return noise * level * Float(exp(-6 * Double(frame) / Double(frames)))
        }
    }

    /// A kit of recordings brought into `root`: a kick, a snare and hats, on the Studio Kit.
    static func recordedKit(in root: URL) throws -> RecordedKit {
        let folder = root.appendingPathComponent("Pack", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("samples"), withIntermediateDirectories: true)
        var sfz = "<control>\n<global> loop_mode=one_shot\n"
        for key in [36, 38, 42, 46] {
            let file = "samples/k\(key).wav"
            try SynthesizedKit.writeWAV(hit(seed: UInt64(key)), to: folder.appendingPathComponent(file), sampleRate: 48_000)
            sfz += "<region> sample=\(file) key=\(key)\n"
        }
        let url = folder.appendingPathComponent("Room Kit \(UUID().uuidString.prefix(6)).sfz")
        try sfz.write(to: url, atomically: true, encoding: .utf8)
        return try RecordedKits.importSFZ(at: url, into: root.appendingPathComponent("Kits", isDirectory: true)).kit
    }
}

/// A host with a song's side of a voice, and no song: what a recording is called and what it sounds like.
@MainActor
private final class RecordedVoiceHost: SoundSurfaceHost {
    var selectedPart: PartVersion?
    var songMachine: String?
    var recordings: [SynthVoiceKind: String] = [:]
    var hit: [Float] = []
    private(set) var auditions: [SoundAudition] = []
    private(set) var recorded: [PartVersion] = []
    private(set) var asked = 0

    func audition(_ audition: SoundAudition) { auditions.append(audition) }
    func record(_ version: PartVersion) -> Bool { recorded.append(version); return true }
    func keptVoice(_ voice: SynthVoiceKind, on machine: String) -> PartVersion? {
        recorded.last { SoundState($0).map { $0.machine == machine && $0.voice == voice } ?? false }
    }
    func recording(of voice: SynthVoiceKind, on machine: String) -> String? { recordings[voice] }
    func kitHit(of voice: SynthVoiceKind, on machine: SynthMachine) async throws -> SoundAudition {
        asked += 1
        return SoundAudition(samples: hit, sampleRate: 48_000, label: "recorded \(voice.rawValue)", isDry: true)
    }
}

@Suite("A drum voice kept is a voice the song plays", .serialized) @MainActor
struct VoiceShapingTests {

    @Test("the newest edit of each voice is on the machine the song plays, and another machine's is not")
    func shaped() throws {
        var (song, groove) = try VoiceFixture.song(on: "linn")
        #expect(SongPlayback.machine(in: song) == SynthMachine.preset(id: "linn"), "nothing kept: the preset")

        try song.append(VoiceFixture.edit("linn", .kick) { $0.decay = 0.2 })
        try song.append(VoiceFixture.edit("linn", .snare) { $0.level = 0.5 })
        try song.append(VoiceFixture.edit("tr808", .kick) { $0.decay = 0.9 })
        try song.append(VoiceFixture.edit("linn", .kick) { $0.decay = 0.7 })

        let machine = SongPlayback.machine(for: groove.partID, in: song)
        #expect(machine.id == "linn" && machine.name == SynthMachine.preset(id: "linn")?.name)
        #expect(machine.spec(for: .kick)?.controls.decay == 0.7, "the newest kick")
        #expect(machine.spec(for: .snare)?.controls.level == 0.5)
        #expect(machine.spec(for: .closedHat) == SynthMachine.preset(id: "linn")?.spec(for: .closedHat), "a voice nobody kept is the preset's")
        #expect(SongPlayback.shaped(.tr808, in: song).spec(for: .kick)?.controls.decay == 0.9, "the 808's is the 808's")

        // It is a kit of its own, and it is what the transport's voice carries.
        #expect(SynthesizedKit.folderName(for: machine) != SynthesizedKit.folderName(for: SynthMachine.preset(id: "linn")!))
        let voice = try #require(SongPlayback.plan(for: song, mediaURL: { _ in nil }).voices.first { $0.groove != nil })
        #expect(voice.sound == "linn" && voice.drumMachine == machine)
        #expect(SongPlayback.voiceEdit(of: .kick, on: "linn", in: song)?.id == song.versions.last?.id)
    }

    @Test("Sound opens on the machine the song plays, and a knob kept there is in the song's kit, on a part of its own")
    func keptOnTheSurface() throws {
        let directory = WiringFixture.temporaryDirectory()
        defer { WiringFixture.remove(directory) }
        let (song, _) = try VoiceFixture.song(on: "linn")
        let pick = try #require(song.versions.last)
        let app = WiringFixture.app(in: directory, song: song)
        let wiring = SurfaceWiring()
        wiring.use(WiringFixture.silentService())
        // Opened on the machine's pick, as the dock opens it.
        let id = try #require(app.perform(SurfaceAction(surface: .sound, title: "Sound", bound: [pick.id])))
        let item = try #require(app.bench.items.first { $0.id == id })
        let (surface, _) = wiring.soundSurface(for: item, app: app)
        #expect(surface.draft.machine == "linn" && surface.draft.voice == .kick, "\(surface.draft.label)")
        #expect(surface.recordedAs == nil && surface.controls(for: .voice).count > 1)

        surface.setValue(0.25, for: .machine(.decay))
        let kept = try #require(surface.commit())
        #expect(kept.partID != pick.partID, "a voice is a part of its own, not the machine's pick")
        let now = try #require(app.song)
        #expect(SongPlayback.machineID(in: now) == "linn", "the pick still stands")
        #expect(SongPlayback.machine(in: now).spec(for: .kick)?.controls.decay == 0.25)

        // Again, it is that voice's next version; another voice opens as the preset has it.
        surface.setValue(0.5, for: .machine(.decay))
        let again = try #require(surface.commit())
        #expect(again.partID == kept.partID && again.parents == [kept.id])
        surface.select(.snare)
        #expect(surface.draft.controls == SynthMachine.preset(id: "linn")?.spec(for: .snare)?.controls)
        surface.select(.kick)
        #expect(surface.draft.controls.decay == 0.5, "back on the kick, it is the kick as kept")

        // A surface opened afresh on the song opens on what was kept.
        let other = BenchItem(id: SurfaceID(), kind: .sound, title: "Sound")
        let (fresh, _) = wiring.soundSurface(for: other, app: app)
        #expect(fresh.draft.machine == "linn" && fresh.draft.controls.decay == 0.5)
    }

    @Test("a voice a recording plays has LEVEL and nothing else, and plays the recording at it")
    func recordedVoice() async throws {
        let host = RecordedVoiceHost()
        host.songMachine = "studio"
        host.recordings = [.kick: "Room Kit kick"]
        host.hit = VoiceFixture.hit(seed: 7)
        let surface = SoundSurface(host: host)
        #expect(surface.draft.machine == "studio" && surface.recordedAs == "Room Kit kick")
        let controls = surface.controls(for: .voice)
        #expect(controls.map(\.parameter) == [.machine(.level)], "\(controls.map(\.name))")
        #expect(surface.prominentControls.count == 1 && surface.quietControls.isEmpty)

        // Touched, it is the recording that plays, as the kit has it.
        surface.audition()
        await surface.waitForRecording()
        #expect(host.asked == 1)
        #expect(host.auditions.last?.samples == host.hit)
        #expect(surface.rendered(.dry) == host.hit)

        // LEVEL is a gain on that hit, and does not ask for the kit again.
        let level = surface.draft.controls.level
        surface.setValue(level / 2, for: .machine(.level))
        #expect(host.asked == 1)
        let played = try #require(host.auditions.last?.samples)
        #expect(played.count == host.hit.count)
        #expect(abs(SoundFixture.peak(played) - SoundFixture.peak(host.hit) / 2) < 1e-4)
        let kept = try #require(surface.commit())
        #expect(SoundState(kept)?.controls.level == level / 2)

        // The snare beside it is the synthesizer's, with the synthesizer's knobs.
        surface.select(.snare)
        #expect(surface.recordedAs == nil)
        #expect(surface.controls(for: .voice).count > 1)
        #expect(host.auditions.last?.samples != host.hit)
    }

    @Test("on a recorded kit the adapter says which voices are recordings, plays one, and its LEVEL moves the kit")
    func recordedKit() async throws {
        let directory = WiringFixture.temporaryDirectory("recorded-voice")
        defer { WiringFixture.remove(directory) }
        let kit = try VoiceFixture.recordedKit(in: directory)
        defer { RecordedKits.unregister(id: kit.id) }
        var (song, _) = try VoiceFixture.song(on: kit.id)
        let app = WiringFixture.app(in: directory.appendingPathComponent("Library"), song: song)
        let service = AuditionService(engine: { throw NoAudioDevice() }, kitsDirectory: directory.appendingPathComponent("built"))
        let adapter = SoundAdapter(app: app, service: service)

        #expect(adapter.songMachine == kit.id)
        #expect(adapter.recording(of: .kick, on: kit.id)?.hasSuffix("kick") == true)
        #expect(adapter.recording(of: .snare, on: kit.id) != nil && adapter.recording(of: .closedHat, on: kit.id) != nil)
        #expect(adapter.recording(of: .crash, on: kit.id) == nil, "the base machine plays what was not recorded")
        #expect(adapter.recording(of: .kick, on: "studio") == nil)

        let surface = SoundSurface(host: adapter)
        #expect(surface.draft.machine == kit.id && surface.recordedAs != nil)
        #expect(surface.controls(for: .voice).map(\.parameter) == [.machine(.level)])

        // The hit is the recording, not the Studio Kit's synthesized kick.
        let machine = try #require(SynthMachine.preset(id: kit.id))
        let hit = try await adapter.kitHit(of: .kick, on: machine)
        #expect(!hit.samples.isEmpty && hit.durationSeconds < SoundAdapter.longestHit)
        let loud = SoundFixture.peak(hit.samples)
        #expect(loud > 0.01)

        // LEVEL kept, and the kit the song plays has the recording that much quieter. Measured
        // between two turns well down, because a short recording stood in for a long kick sits
        // at the kit's ceiling until it is turned down past it.
        song = try #require(app.song)
        let level = try #require(machine.spec(for: .kick)).controls.level
        #expect(app.record(VoiceFixture.edit(kit.id, .kick) { $0.level = level / 4 }))
        let quiet = try await adapter.kitHit(of: .kick, on: machine)
        #expect(app.record(VoiceFixture.edit(kit.id, .kick) { $0.level = level / 8 }))
        let quieter = try await adapter.kitHit(of: .kick, on: machine)
        #expect(SoundFixture.peak(quiet.samples) < loud)
        let ratio = SoundFixture.peak(quieter.samples) / SoundFixture.peak(quiet.samples)
        #expect(abs(ratio - 0.5) < 0.03, "peak went from \(loud) to \(SoundFixture.peak(quiet.samples)) to \(SoundFixture.peak(quieter.samples))")

        // The snare was not turned, and it is where it was: one voice down is not the others up.
        let snare = try await adapter.kitHit(of: .snare, on: machine)
        let presetKit = try SynthesizedKit.build(machine, in: directory.appendingPathComponent("preset"))
        let shapedKit = try SynthesizedKit.build(SongPlayback.machine(in: try #require(app.song)), in: directory.appendingPathComponent("shaped"))
        func gain(_ kit: LoadedKit, _ kind: SynthVoiceKind) -> Float? {
            kit.manifest.zones.first { $0.key.noteRange.contains(kind.generalMIDINote) }?.gainDB
        }
        #expect(gain(presetKit, .snare) == gain(shapedKit, .snare))
        #expect(!snare.samples.isEmpty)
    }
}
