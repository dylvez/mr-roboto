import AVFAudio
import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// The transport, actually playing — driven offline.
//
// This shell has no audio device, and neither does CI, so "does it play" is asked the only way it
// can honestly be asked: the engine is put in manual rendering mode (`Engine.prepare(offlineSampleRate:)`,
// the same door `InstrumentTests` and `AudioEngineTests` go through), the transport is started, and
// the render is inspected for samples at the frames the plan put them on. Nothing here waits to hear
// anything.
//
// Serialized: each test builds a whole `AVAudioEngine` graph and, for the groove, a synthesized kit.
@Suite("Transport: a started transport renders what the plan said", .serialized)
struct TransportPlaybackTests {

    private static let sampleRate: Double = 48_000

    // MARK: Harness

    @AudioActor
    private func engine(players: Int = 4, channels: AVAudioChannelCount = 2) throws -> Engine {
        let engine = try Engine(playerCount: players, sampleRate: Self.sampleRate, channels: channels)
        try engine.prepare(offlineSampleRate: Self.sampleRate, maximumFrames: 4_096)
        try engine.start()
        return engine
    }

    private var clock: TransportClock {
        TransportClock(tempo: 120, timeSignature: .fourFour, sampleRate: Self.sampleRate)
    }

    @AudioActor
    private func teardown(_ player: LiveSongPlayer, _ service: AuditionService, _ engine: Engine) async {
        await player.end()
        await service.shutdown()
        engine.stopTransport()
        engine.stop()
    }

    /// Peak magnitude over a window of one channel, in seconds.
    private func peak(_ buffer: AVAudioPCMBuffer, from: Double, to: Double, channel: Int = 0) -> Float {
        guard let data = buffer.floatChannelData,
              buffer.format.channelCount > AVAudioChannelCount(channel) else { return 0 }
        let stride = buffer.stride
        let first = max(0, Int(from * Self.sampleRate))
        let last = min(Int(buffer.frameLength), Int(to * Self.sampleRate))
        guard last > first else { return 0 }
        return (first..<last).reduce(Float(0)) { max($0, abs(data[channel][$1 * stride])) }
    }

    /// A WAV of a steady tone on disk, so a track test plays a real file through a real decode.
    private func writeTone(_ directory: URL, seconds: Double = 1.0,
                           frequency: Double = 220, rate: Double = 44_100) throws -> URL {
        let url = directory.appendingPathComponent("take-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              let data = buffer.floatChannelData else {
            throw EngineError.renderFailed("could not build a tone buffer")
        }
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            data[0][frame] = Float(sin(2 * .pi * frequency * Double(frame) / rate) * 0.6)
        }
        try file.write(from: buffer)
        return url
    }

    // MARK: A groove

    @Test("A song with a groove schedules hits when started, and renders them")
    @AudioActor
    func aGrooveSchedulesAndSounds() async throws {
        let kits = TransportFixture.temporaryDirectory("kits")
        defer { try? FileManager.default.removeItem(at: kits) }
        let engine = try engine()
        let service = AuditionService(engine: { engine }, kitsDirectory: kits)
        let player = LiveSongPlayer(service: service)

        var plan = SongPlayback(tempo: 120, groove: TransportFixture.groove(bars: 1))
        plan.machine = SynthMachine.tr808.id

        try await player.begin(plan, clock: clock)
        _ = try engine.startTransport(clock: clock)

        // Started means scheduled: the engine hands every source its transport and the first
        // look-ahead window before a frame is rendered.
        var reading = await player.reading()
        #expect(reading.isRunning)
        #expect(reading.scheduledHits > 0, "the groove player queued nothing at transport start")

        // Two seconds at 120 bpm is four beats, so four kicks: 0, 0.5, 1.0, 1.5.
        let out = try OfflineRenderer.renderBuffer(engine: engine,
                                                   frames: AVAudioFramePosition(2 * Self.sampleRate))
        #expect(out.frameLength == AVAudioFrameCount(2 * Self.sampleRate))
        #expect(peak(out, from: 0, to: 2) > 0.001, "nothing came out of the graph")

        // At the frames the plan put them on, not merely somewhere.
        for beat in [0.0, 0.5, 1.0, 1.5] {
            #expect(peak(out, from: beat, to: beat + 0.06) > 0.001,
                    "no hit at beat starting \(beat) s")
        }
        // And the gap before the second kick is quieter than the kick itself: the hits are spread
        // across the bar rather than fired at once.
        #expect(peak(out, from: 0.40, to: 0.49) < peak(out, from: 0.5, to: 0.56))

        reading = await player.reading()
        #expect(reading.seconds > 1.9)
        #expect(reading.scheduledHits >= 4)

        await teardown(player, service, engine)
    }

    @Test("Stopping is clean: the sources come off the engine and nothing is left running")
    @AudioActor
    func stoppingIsClean() async throws {
        let kits = TransportFixture.temporaryDirectory("kits")
        defer { try? FileManager.default.removeItem(at: kits) }
        let engine = try engine()
        let service = AuditionService(engine: { engine }, kitsDirectory: kits)
        let player = LiveSongPlayer(service: service)

        try await player.begin(SongPlayback(tempo: 120, groove: TransportFixture.groove()),
                               clock: clock)
        _ = try engine.startTransport(clock: clock)
        _ = try OfflineRenderer.renderBuffer(engine: engine,
                                             frames: AVAudioFramePosition(Self.sampleRate / 4))

        await player.end()
        #expect(await player.reading() == .stopped)

        // The engine itself is untouched — stopping playback is not shutting the app's audio down —
        // and it can be started again.
        #expect(engine.isRunning)
        engine.stopTransport()
        _ = try engine.startTransport(clock: clock)
        #expect(engine.isTransportRunning)

        // Starting again after a stop is an ordinary thing to do.
        engine.stopTransport()
        try await player.begin(SongPlayback(tempo: 120, groove: TransportFixture.groove()),
                               clock: clock)
        _ = try engine.startTransport(clock: clock)
        #expect(await player.reading().isRunning)

        await teardown(player, service, engine)
    }

    // MARK: The chords and the tune

    // The user-visible bug, end to end: a song whose form held chords played the drums and nothing
    // else. These render the whole path — plan, `LiveSongPlayer`, the shared instrument sampler,
    // the graph — and ask whether the harmony actually came out.

    @Test("A song of nothing but chords makes a sound: the transport sounds the harmony")
    @AudioActor
    func chordsSound() async throws {
        let kits = TransportFixture.temporaryDirectory("kits-chords")
        defer { try? FileManager.default.removeItem(at: kits) }
        let engine = try engine()
        let service = AuditionService(engine: { engine }, kitsDirectory: kits)
        let player = LiveSongPlayer(service: service)

        var plan = SongPlayback(tempo: 120, voices: [.progression(TransportFixture.progression())])
        plan.instrument = InstrumentVoiceSpec.rhodes.id
        plan.lengthInBars = 4

        try await player.begin(plan, clock: clock)
        _ = try engine.startTransport(clock: clock)

        let reading = await player.reading()
        #expect(reading.isRunning)
        #expect(reading.scheduledHits > 0, "the keys player queued nothing at transport start")

        // Four bars at 120 bpm is eight seconds; bar 2 falls at 2 s, so render past it.
        let out = try OfflineRenderer.renderBuffer(engine: engine,
                                                   frames: AVAudioFramePosition(3 * Self.sampleRate))
        #expect(peak(out, from: 0, to: 3) > 0.001, "nothing came out of the graph")
        // A chord on each downbeat, not one chord ringing for the whole pass.
        #expect(peak(out, from: 0, to: 0.1) > 0.001, "no chord on bar 1")
        #expect(peak(out, from: 2.0, to: 2.1) > 0.001, "no chord on bar 2")

        await teardown(player, service, engine)
    }

    @Test("An arranged song plays its sections' chords, and the drums do not drown the plan")
    @AudioActor
    func arrangedChordsSound() async throws {
        let kits = TransportFixture.temporaryDirectory("kits-form")
        defer { try? FileManager.default.removeItem(at: kits) }
        let engine = try engine()
        let service = AuditionService(engine: { engine }, kitsDirectory: kits)
        let player = LiveSongPlayer(service: service)

        // The shape of the song this was found in: a four-bar intro of chords alone, then a loop
        // with the groove under them. The intro is the proof — if only the drums are wired up, the
        // first four bars are silence.
        let intro = SongPlayback.Segment(section: SectionID(), name: "Intro", startBar: 0, lengthInBars: 4,
                                         voices: [.progression(TransportFixture.progression())])
        let loop = SongPlayback.Segment(section: SectionID(), name: "Loop", startBar: 4, lengthInBars: 4,
                                        voices: [.groove(TransportFixture.groove()),
                                                 .progression(TransportFixture.progression())])

        var plan = SongPlayback(tempo: 120)
        plan.segments = [intro, loop]
        plan.instrument = InstrumentVoiceSpec.rhodes.id
        plan.lengthInBars = 8

        try await player.begin(plan, clock: clock)
        _ = try engine.startTransport(clock: clock)
        #expect(await player.reading().scheduledHits > 0)

        // Eight bars at 120 bpm is sixteen seconds; three covers the chords-only intro.
        let out = try OfflineRenderer.renderBuffer(engine: engine,
                                                   frames: AVAudioFramePosition(3 * Self.sampleRate))
        #expect(peak(out, from: 0, to: 3) > 0.001,
                "the intro is chords alone: if it is silent, the form is playing drums and nothing else")

        await teardown(player, service, engine)
    }

    @Test("The whole band at once: drums, bass and chords each add to what comes out")
    @AudioActor
    func everythingAtOnce() async throws {
        let kits = TransportFixture.temporaryDirectory("kits-band")
        defer { try? FileManager.default.removeItem(at: kits) }

        /// One plan, rendered for three seconds, as total energy rather than peak: a part that is
        /// quiet but present still moves this, and a part routed into nowhere cannot.
        func energy(_ build: (inout SongPlayback) -> Void) async throws -> Double {
            let engine = try engine()
            let service = AuditionService(engine: { engine }, kitsDirectory: kits)
            let player = LiveSongPlayer(service: service)
            var plan = SongPlayback(tempo: 120)
            plan.instrument = InstrumentVoiceSpec.rhodes.id
            plan.lengthInBars = 4
            build(&plan)
            try await player.begin(plan, clock: clock)
            _ = try engine.startTransport(clock: clock)
            let out = try OfflineRenderer.renderBuffer(engine: engine,
                                                       frames: AVAudioFramePosition(3 * Self.sampleRate))
            var sum = 0.0
            if let data = out.floatChannelData {
                for frame in 0..<Int(out.frameLength) {
                    let sample = Double(data[0][frame * out.stride])
                    sum += sample * sample
                }
            }
            await teardown(player, service, engine)
            return sum
        }

        let line = Bassline(notes: [NoteEvent(pitch: Pitch(midi: 40), start: 0, duration: 3.5),
                                    NoteEvent(pitch: Pitch(midi: 45), start: 4, duration: 3.5)],
                            sound: "finger")
        let drums = try await energy { $0.voices = [.groove(TransportFixture.groove())] }
        let bass = try await energy { $0.voices = [.bassline(line)] }
        let chords = try await energy { $0.voices = [.progression(TransportFixture.progression())] }
        let all = try await energy {
            $0.voices = [.groove(TransportFixture.groove()), .bassline(line),
                         .progression(TransportFixture.progression())]
        }

        #expect(drums > 0, "the drums alone made no sound")
        #expect(bass > 0, "the bass alone made no sound")
        #expect(chords > 0, "the chords alone made no sound")
        // Each part is still there when the others are: three sources on three samplers into one
        // mixer, not three taking turns at one bus.
        #expect(all > drums, "adding bass and chords to the drums changed nothing: a part is being dropped")
        #expect(all > bass, "adding drums and chords to the bass changed nothing")
        #expect(all > chords, "adding drums and bass to the chords changed nothing")
    }

    // MARK: Several parts of a kind

    @Test("two grooves in one section both hit: the form plays everything it names, not the last of it")
    @AudioActor
    func twoGroovesSound() async throws {
        let kits = TransportFixture.temporaryDirectory("kits-two")
        defer { try? FileManager.default.removeItem(at: kits) }
        let engine = try engine()
        let service = AuditionService(engine: { engine }, kitsDirectory: kits)
        let player = LiveSongPlayer(service: service)

        // One part kicks on the beats, another puts a hat between them. Neither alone can make a
        // sound at 0.25 s — so if only one is scheduled, as a stitch naming two of a kind used to
        // do, the offbeat windows are silent.
        func pattern(_ voice: DrumVoice, every step: Int, from first: Int) -> Groove {
            var steps = [VelocityTier](repeating: .rest, count: 16)
            for i in stride(from: first, to: 16, by: step) { steps[i] = .accent }
            return Groove(stepsPerBar: 16, bars: 1, patterns: [GroovePattern(voice: voice, steps: steps)])
        }
        let onBeats = pattern(.kick, every: 4, from: 0)
        let offBeats = pattern(.closedHat, every: 4, from: 2)

        var plan = SongPlayback(tempo: 120)
        plan.segments = [SongPlayback.Segment(
            section: SectionID(), name: "Loop", startBar: 0, lengthInBars: 1,
            voices: [.groove(onBeats, part: PartID()), .groove(offBeats, part: PartID())])]
        plan.lengthInBars = 1

        try await player.begin(plan, clock: clock)
        _ = try engine.startTransport(clock: clock)
        let out = try OfflineRenderer.renderBuffer(engine: engine,
                                                   frames: AVAudioFramePosition(2 * Self.sampleRate))

        for beat in [0.0, 0.5, 1.0, 1.5] {
            #expect(peak(out, from: beat, to: beat + 0.06) > 0.001, "no kick at \(beat) s")
        }
        for off in [0.25, 0.75, 1.25, 1.75] {
            #expect(peak(out, from: off, to: off + 0.06) > 0.001,
                    "nothing at \(off) s: the second groove in the section was dropped")
        }
        #expect(await player.reading().scheduledHits >= 8)

        await teardown(player, service, engine)
    }

    @Test("the chords and the tune sound together, each on its own instrument")
    @AudioActor
    func twoPitchedLanes() async throws {
        let kits = TransportFixture.temporaryDirectory("kits-pad")
        defer { try? FileManager.default.removeItem(at: kits) }

        /// Total energy of a render, so a part that is present but quiet still moves it.
        func energy(_ voices: [SongPlayback.Voice]) async throws -> Double {
            let engine = try engine()
            let service = AuditionService(engine: { engine }, kitsDirectory: kits)
            let player = LiveSongPlayer(service: service)
            var plan = SongPlayback(tempo: 120, voices: voices)
            plan.lengthInBars = 4
            try await player.begin(plan, clock: clock)
            _ = try engine.startTransport(clock: clock)
            let out = try OfflineRenderer.renderBuffer(engine: engine,
                                                       frames: AVAudioFramePosition(2 * Self.sampleRate))
            var sum = 0.0
            if let data = out.floatChannelData {
                for frame in 0..<Int(out.frameLength) {
                    let sample = Double(data[0][frame * out.stride])
                    sum += sample * sample
                }
            }
            await teardown(player, service, engine)
            return sum
        }

        // The two pitched kinds, on two parts, naming two different instruments — which the plan
        // could not say at all until a voice carried its own sound.
        //
        // The marimba and the organ rather than the pad and the lead this is really about: the
        // claim is "two instruments", not "these two", and a kit is nineteen roots × its velocity
        // layers × its length rendered before a note sounds. These are the two cheapest to build,
        // which is about a minute of this suite's time.
        let chords = SongPlayback.Voice.progression(TransportFixture.progression(), part: PartID(),
                                                    sound: InstrumentVoiceSpec.marimba.id)
        let tune = SongPlayback.Voice.melody(Melody(notes: (0..<4).map {
            NoteEvent(pitch: Pitch(midi: 76), start: Double($0), duration: 0.75)
        }), part: PartID(), sound: InstrumentVoiceSpec.organ.id)

        let pad = try await energy([chords])
        let lead = try await energy([tune])
        let both = try await energy([chords, tune])

        #expect(pad > 0, "the pad alone made no sound")
        #expect(lead > 0, "the lead alone made no sound")
        #expect(both > pad, "adding the lead to the pad changed nothing")
        #expect(both > lead, "adding the pad to the lead changed nothing")
    }

    // MARK: The sampler pool

    @Test("a lane's sampler is its own: the transport no longer takes the one a surface is holding")
    @AudioActor
    func lanesAndSurfacesDoNotShare() async throws {
        let kits = TransportFixture.temporaryDirectory("kits-pool")
        defer { try? FileManager.default.removeItem(at: kits) }
        let engine = try engine()
        let service = AuditionService(engine: { engine }, kitsDirectory: kits)
        let player = LiveSongPlayer(service: service)

        // A surface has an 808 under your finger.
        try await service.prepare(machine: .tr808)
        #expect(await service.currentKitID == SynthMachine.tr808.id)

        // The song plays a different machine. It used to displace the surface's kit, costing a
        // re-prepare on the next touch and, in between, the wrong sound under your finger.
        let groovePart = PartID()
        var plan = SongPlayback(tempo: 120,
                                voices: [.groove(TransportFixture.groove(), part: groovePart,
                                                 sound: SynthMachine.tr909.id)])
        plan.machine = SynthMachine.tr909.id
        try await player.begin(plan, clock: clock)
        _ = try engine.startTransport(clock: clock)

        #expect(await service.currentKitID == SynthMachine.tr808.id,
                "the transport took the surface's sampler")
        _ = try OfflineRenderer.renderBuffer(engine: engine,
                                             frames: AVAudioFramePosition(Self.sampleRate / 2))
        await teardown(player, service, engine)
    }

    @Test("a lane sampler is let go when the next plan does not name its part")
    @AudioActor
    func lanesAreRetired() async throws {
        let kits = TransportFixture.temporaryDirectory("kits-retire")
        defer { try? FileManager.default.removeItem(at: kits) }
        let engine = try engine()
        let service = AuditionService(engine: { engine }, kitsDirectory: kits)
        let player = LiveSongPlayer(service: service)

        let first = PartID(), second = PartID()
        func plan(_ part: PartID) -> SongPlayback {
            SongPlayback(tempo: 120, voices: [.groove(TransportFixture.groove(), part: part)])
        }

        try await player.begin(plan(first), clock: clock)
        #expect(await service.laneParts == [first])

        // A different song, a different part: the first one's kit is not kept resident forever.
        try await player.begin(plan(second), clock: clock)
        #expect(await service.laneParts == [second])

        await player.end()
        await service.shutdown()
        engine.stop()
    }

    // MARK: A take

    @Test("A song with a take plays it, from the transport position it was placed at")
    @AudioActor
    func aTakePlays() async throws {
        let directory = TransportFixture.temporaryDirectory("take")
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try engine()
        let service = AuditionService(engine: { engine }, kitsDirectory: directory)
        let player = LiveSongPlayer(service: service)

        let url = try writeTone(directory, seconds: 1.0)
        let track = SongPlayback.Track(version: VersionID(), name: "Record", url: url,
                                       startsAt: 0.5, duration: 1.0)
        try await player.begin(SongPlayback(tempo: 120, tracks: [track]), clock: clock)
        _ = try engine.startTransport(clock: clock)

        let out = try OfflineRenderer.renderBuffer(engine: engine,
                                                   frames: AVAudioFramePosition(2 * Self.sampleRate))

        // Placed at half a second: quiet before it, loud after it, quiet again once it has run out.
        #expect(peak(out, from: 0, to: 0.45) < 0.01, "the take sounded before its start")
        #expect(peak(out, from: 0.55, to: 1.4) > 0.1, "the take never sounded")
        #expect(peak(out, from: 1.6, to: 2.0) < 0.01, "the take outlasted its own length")

        // The file is 44.1 kHz and the graph is 48: the conversion happens on the way in, so a
        // second of audio is still a second rather than 1.09 of one.
        #expect(peak(out, from: 1.30, to: 1.45) > 0.1, "the take ended early")

        await teardown(player, service, engine)
    }

    @Test("A groove and a take together, on one engine")
    @AudioActor
    func both() async throws {
        let directory = TransportFixture.temporaryDirectory("both")
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try engine()
        let service = AuditionService(engine: { engine }, kitsDirectory: directory)
        let player = LiveSongPlayer(service: service)

        let url = try writeTone(directory, seconds: 1.5)
        var plan = SongPlayback(tempo: 120, groove: TransportFixture.groove())
        plan.tracks = [SongPlayback.Track(version: VersionID(), name: "Record", url: url,
                                          startsAt: 0, duration: 1.5)]

        try await player.begin(plan, clock: clock)
        _ = try engine.startTransport(clock: clock)

        let reading = await player.reading()
        #expect(reading.scheduledHits > 0)

        let out = try OfflineRenderer.renderBuffer(engine: engine,
                                                   frames: AVAudioFramePosition(Self.sampleRate))
        #expect(peak(out, from: 0, to: 1) > 0.1)

        await teardown(player, service, engine)
    }

    @Test("A looping take repeats end to end; one that does not, does not")
    @AudioActor
    func looping() async throws {
        let directory = TransportFixture.temporaryDirectory("loop")
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try engine()
        let service = AuditionService(engine: { engine }, kitsDirectory: directory)
        let player = LiveSongPlayer(service: service)

        let url = try writeTone(directory, seconds: 0.5)
        var plan = SongPlayback(tempo: 120,
                                tracks: [SongPlayback.Track(version: VersionID(), name: "Record",
                                                            url: url, startsAt: 0, duration: 0.5)])
        plan.loops = true

        try await player.begin(plan, clock: clock)
        _ = try engine.startTransport(clock: clock)
        let out = try OfflineRenderer.renderBuffer(engine: engine,
                                                   frames: AVAudioFramePosition(1.5 * Self.sampleRate))

        // Half a second of audio, still sounding a second later.
        #expect(peak(out, from: 0.1, to: 0.4) > 0.1)
        #expect(peak(out, from: 1.0, to: 1.4) > 0.1, "the loop did not come round")

        await teardown(player, service, engine)
    }

    // MARK: The form

    /// Three sections at 120: a bar of groove, a bar of rest, a bar of groove and bass — so the
    /// render has sound, then none, then sound again, at the bars the sections say.
    private func form(loops: Bool) -> SongPlayback {
        var plan = SongPlayback(tempo: 120, loops: loops)
        plan.machine = SynthMachine.tr808.id
        plan.lengthInBars = 3
        let groove = TransportFixture.groove(bars: 1)
        let line = Bassline(notes: [NoteEvent(pitch: Pitch(midi: 38), start: 0, duration: 1, velocity: 100)], sound: "finger")
        plan.segments = [
            SongPlayback.Segment(section: SectionID(), name: "Intro", startBar: 0, lengthInBars: 1,
                                 groove: groove, grooveVersion: VersionID()),
            SongPlayback.Segment(section: SectionID(), name: "Rest", startBar: 1, lengthInBars: 1),
            SongPlayback.Segment(section: SectionID(), name: "Hook", startBar: 2, lengthInBars: 1,
                                 groove: groove, grooveVersion: VersionID(),
                                 bassline: line, basslineVersion: VersionID(), bassSound: "finger"),
        ]
        return plan
    }

    @Test("An arranged song plays its sections in order: sound, a rest, sound again, then it ends")
    @AudioActor
    func sectionsInOrder() async throws {
        let kits = TransportFixture.temporaryDirectory("form")
        defer { try? FileManager.default.removeItem(at: kits) }
        let engine = try engine()
        let service = AuditionService(engine: { engine }, kitsDirectory: kits)
        let player = LiveSongPlayer(service: service)

        try await player.begin(form(loops: false), clock: clock)
        _ = try engine.startTransport(clock: clock)
        #expect(await player.reading().scheduledHits > 0)

        // Bars are two seconds at 120. Seven seconds covers the form and a second past it.
        let out = try OfflineRenderer.renderBuffer(engine: engine, frames: AVAudioFramePosition(7 * Self.sampleRate))
        for beat in [0.0, 0.5, 1.0, 1.5] {
            #expect(peak(out, from: beat, to: beat + 0.06) > 0.001, "no hit at \(beat) s in the intro")
        }
        // The rest: the intro's last kick rings on, but nothing new lands for a bar — every window
        // of it is quieter than the one before, and all of them are well under a hit.
        let hit = peak(out, from: 0, to: 0.06)
        #expect(peak(out, from: 2.5, to: 3.95) < 0.1 * hit, "the rest section made a sound")
        #expect(peak(out, from: 3.0, to: 3.5) <= peak(out, from: 2.5, to: 3.0), "something landed in the rest")
        #expect(peak(out, from: 3.5, to: 3.95) <= peak(out, from: 3.0, to: 3.5), "something landed in the rest")
        for beat in [4.0, 4.5, 5.0, 5.5] {
            #expect(peak(out, from: beat, to: beat + 0.06) > 0.001, "no hit at \(beat) s in the hook")
        }
        // The bass is under the hook and not under the intro: its note is longer than a kick.
        #expect(peak(out, from: 4.3, to: 4.45) > peak(out, from: 0.3, to: 0.45), "no bass under the hook")
        // And the form ends: nothing new after bar three.
        #expect(peak(out, from: 6.5, to: 7.0) < 0.1 * hit, "the form did not end")
        #expect(peak(out, from: 6.5, to: 7.0) <= peak(out, from: 6.0, to: 6.5), "something landed after the form")

        let reading = await player.reading()
        #expect(!reading.isRunning, "the transport reports the end of the form")
        #expect(reading.seconds == 6)

        await teardown(player, service, engine)
    }

    @Test("With the loop on, the form comes round: the intro plays again after the outro")
    @AudioActor
    func formLoops() async throws {
        let kits = TransportFixture.temporaryDirectory("form-loop")
        defer { try? FileManager.default.removeItem(at: kits) }
        let engine = try engine()
        let service = AuditionService(engine: { engine }, kitsDirectory: kits)
        let player = LiveSongPlayer(service: service)

        try await player.begin(form(loops: true), clock: clock)
        _ = try engine.startTransport(clock: clock)

        let out = try OfflineRenderer.renderBuffer(engine: engine, frames: AVAudioFramePosition(9 * Self.sampleRate))
        let hit = peak(out, from: 0, to: 0.06)
        #expect(peak(out, from: 2.5, to: 3.95) < 0.1 * hit, "the rest section made a sound")
        for beat in [6.0, 6.5, 7.0, 7.5] {
            #expect(peak(out, from: beat, to: beat + 0.06) > 0.001, "no hit at \(beat) s: the form did not come round")
        }
        #expect(peak(out, from: 8.5, to: 8.95) < 0.1 * hit, "the second pass's rest made a sound")
        #expect(peak(out, from: 8.5, to: 8.95) <= peak(out, from: 8.0, to: 8.5), "something landed in the second rest")
        #expect(await player.reading().isRunning)

        await teardown(player, service, engine)
    }

    // MARK: Refusing

    @Test("A plan with nothing schedulable throws rather than starting a silent transport")
    @AudioActor
    func nothingSchedulable() async throws {
        let kits = TransportFixture.temporaryDirectory("empty")
        defer { try? FileManager.default.removeItem(at: kits) }
        let engine = try engine()
        let service = AuditionService(engine: { engine }, kitsDirectory: kits)
        let player = LiveSongPlayer(service: service)

        await #expect(throws: LiveSongPlayer.Failure.self) {
            try await player.begin(SongPlayback(tempo: 120), clock: clock)
        }
        #expect(await player.reading() == .stopped)

        await teardown(player, service, engine)
    }

    @Test("A track whose file cannot be read names the track rather than trapping")
    @AudioActor
    func unreadableTrack() async throws {
        let directory = TransportFixture.temporaryDirectory("missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try engine()
        let service = AuditionService(engine: { engine }, kitsDirectory: directory)
        let player = LiveSongPlayer(service: service)

        let track = SongPlayback.Track(version: VersionID(), name: "Drums stem",
                                       url: directory.appendingPathComponent("gone.wav"),
                                       startsAt: 0, duration: 4)
        do {
            try await player.begin(SongPlayback(tempo: 120, tracks: [track]), clock: clock)
            Issue.record("a missing file should not begin")
        } catch let failure as LiveSongPlayer.Failure {
            #expect("\(failure)".contains("Drums stem"))
        }

        await teardown(player, service, engine)
    }

    @Test("With no engine at all, beginning fails and says why")
    @AudioActor
    func noEngine() async {
        let kits = TransportFixture.temporaryDirectory("noengine")
        defer { try? FileManager.default.removeItem(at: kits) }
        let service = AuditionService(engine: { throw NoAudioDevice() }, kitsDirectory: kits)
        let player = LiveSongPlayer(service: service)

        await #expect(throws: (any Error).self) {
            try await player.begin(SongPlayback(tempo: 120, groove: TransportFixture.groove()),
                                   clock: clock)
        }
        #expect(await player.reading() == .stopped)
        await player.end()
    }
}
