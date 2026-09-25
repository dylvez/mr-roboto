import AudioEngine
import Foundation
import Instrument
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// Inputs I5/I6: a controller plays through as a hit now; what it plays while a take runs is a groove
// on the sixteenth grid with its swing, or a bass line with the lag as played.

private struct NoDevice: Error {}

@Suite("MIDI capture: played in, kept as a part", .serialized) @MainActor
struct MIDICaptureTests {
    private let clock = TransportClock(tempo: 92, timeSignature: .fourFour, sampleRate: 48_000, startHostTime: 1_000_000)

    private func at(_ seconds: Double) -> UInt64 { clock.hostTime(forSeconds: seconds)! }
    private func on(_ note: Int, _ velocity: Int, _ seconds: Double, source: String = "Launchkey") -> MIDIEvent {
        MIDIEvent(kind: .noteOn(note: note, velocity: velocity), channel: 9, hostTime: at(seconds), source: source)
    }
    private func off(_ note: Int, _ seconds: Double) -> MIDIEvent {
        MIDIEvent(kind: .noteOff(note: note), channel: 9, hostTime: at(seconds), source: "Launchkey")
    }

    /// One bar at 92: kick on the beats, snare accents on 2 and 4, ghost hats on the odd sixteenths
    /// played a third of a step late — a 66.7% swing.
    private func kitBar(from start: Double) -> [MIDIEvent] {
        let step = clock.secondsPerBeat / 4
        var events: [MIDIEvent] = []
        for beat in 0..<4 { events.append(on(36, 100, start + Double(beat) * clock.secondsPerBeat)) }
        for beat in [1, 3] { events.append(on(38, 120, start + Double(beat) * clock.secondsPerBeat)) }
        for odd in stride(from: 1, to: 16, by: 2) { events.append(on(42, 40, start + (Double(odd) + 1.0 / 3) * step)) }
        return events
    }

    @Test("pure: the bar lands on its steps, the swing reads as played, the tiers follow velocity")
    func grooveCapture() throws {
        let timed = kitBar(from: 2.0).map { (kind: $0.kind, seconds: clock.seconds(forHostTime: $0.hostTime)!) }
        let notes = MIDICapture.notes(from: timed)
        #expect(notes.count == 4 + 2 + 8)
        let groove = try #require(MIDICapture.groove(notes, clock: clock, sectionStart: 2.0, bars: 2))
        #expect(groove.bars == 2 && groove.stepsPerBar == 16)
        #expect(abs(groove.swing - 2.0 / 3) < 0.03, "swing \(groove.swing)")
        let kick = try #require(groove.patterns.first { $0.voice == .kick })
        #expect(kick.steps.enumerated().filter { $0.element != .rest }.map(\.offset) == [0, 4, 8, 12])
        #expect(kick.steps[0] == .normal)
        let snare = try #require(groove.patterns.first { $0.voice == .snare })
        #expect(snare.steps.enumerated().filter { $0.element != .rest }.map(\.offset) == [4, 12] && snare.steps[4] == .accent)
        let hat = try #require(groove.patterns.first { $0.voice == .closedHat })
        #expect(hat.steps.enumerated().filter { $0.element != .rest }.map(\.offset) == Array(stride(from: 1, to: 16, by: 2)))
        #expect(hat.steps[1] == .ghost)
        // Nothing played: no part. Bars not given: the bars played.
        #expect(MIDICapture.groove([], clock: clock, sectionStart: 0, bars: nil) == nil)
        #expect(MIDICapture.groove(notes, clock: clock, sectionStart: 2.0, bars: nil)?.bars == 1)
    }

    @Test("pure: a bass note 40 ms behind the kick is 40 ms behind in beats, held as long as the key was")
    func basslineCapture() throws {
        let start = 2.0
        let timed: [(kind: MIDIEvent.Kind, seconds: Double)] = [
            (.noteOn(note: 40, velocity: 96), start + 0.040), (.noteOff(note: 40), start + 0.440),
            (.noteOn(note: 43, velocity: 80), start + clock.secondsPerBeat * 2), // still held at the end
        ]
        let notes = MIDICapture.notes(from: timed)
        #expect(notes[0].end != nil && notes[1].end == nil)
        let line = try #require(MIDICapture.bassline(notes, clock: clock, sectionStart: start, end: start + clock.secondsPerBeat * 3, key: Key(tonic: NoteName(.e), mode: .aeolian), sound: "sub"))
        #expect(line.sound == "sub" && line.key?.tonic == NoteName(.e))
        let lagBeats = clock.beat(forSeconds: 0.040)
        #expect(abs(line.notes[0].start - lagBeats) < 1e-9 && line.notes[0].pitch.midi == 40 && line.notes[0].velocity == 96)
        #expect(abs(line.notes[0].duration - clock.beat(forSeconds: 0.4)) < 1e-9)
        #expect(abs(line.notes[1].start - 2) < 1e-9 && abs(line.notes[1].duration - 1) < 1e-9, "held to the end of the take")
    }

    private func fixture() -> (AppState, MIDIControl, URL, UserDefaults, String) {
        let directory = WiringFixture.temporaryDirectory("midi-capture")
        var song = FormFixture.build(tempo: 92).song
        let ids = [Guidance.grooves(in: song).last!, Guidance.basslines(in: song).last!].lanes
        song.sections = [Section(name: "Intro", stitch: ids, lengthInBars: 2), Section(name: "Verse", stitch: ids, lengthInBars: 4)]
        let app = BandFixture.app(in: directory, song: song)
        let suite = "midi-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let kits = WiringFixture.temporaryDirectory("midi-kits")
        let service = AuditionService(engine: { throw NoDevice() }, kitsDirectory: kits)
        let control = MIDIControl(app: app, service: service, defaults: defaults)
        return (app, control, directory, defaults, suite)
    }

    @Test("through the control: Kit plays a pad as a hit now, and a take captured in Kit lands as a played groove on the Verse")
    func kitThroughControl() async throws {
        let (app, control, directory, defaults, suite) = fixture()
        defer { WiringFixture.remove(directory); defaults.removePersistentDomain(forName: suite) }
        #expect(control.mode == .off)
        control.mode = .kit
        #expect(defaults.string(forKey: MIDIControl.modeKey) == "kit", "remembered")
        control.handle(on(38, 110, 0.5))
        #expect(control.lastHit?.voice == .snare && control.lastHit?.time == 0 && control.lastHit?.velocity == 110)
        #expect(control.lastSource == "Launchkey")

        let verse = app.song!.sections[1]
        let verseStart = clock.seconds(forBar: 2)
        let before = app.song!.versions.count
        control.beginCapture(section: verse.id, clock: clock, startedAt: verseStart)
        #expect(control.isCapturing)
        for event in kitBar(from: verseStart) { control.handle(event) }
        let version = try #require(control.endCapture(endedAt: verseStart + clock.secondsPerBar))
        #expect(!control.isCapturing)
        #expect(version.operation == Operation.played && version.author == .user)
        #expect(version.note?.hasPrefix("Played on Launchkey into Verse") == true, "\(version.note ?? "")")
        guard case .groove(let groove) = version.kind else { Issue.record("not a groove"); return }
        #expect(groove.bars == 4 && abs(groove.swing - 2.0 / 3) < 0.03)
        #expect(app.song!.versions.count == before + 1)
        // Nothing captured while the mode is off, or without a running clock.
        control.mode = .off
        control.beginCapture(section: verse.id, clock: clock, startedAt: 0)
        #expect(!control.isCapturing)
        control.mode = .kit
        control.beginCapture(section: verse.id, clock: TransportClock(tempo: 92), startedAt: 0)
        #expect(!control.isCapturing, "a clock with no start host time places nothing")
    }

    @Test("through the control: Bass holds a key until it is let go, and a take in Bass lands as a played bass line")
    func bassThroughControl() async throws {
        let (app, control, directory, defaults, suite) = fixture()
        defer { WiringFixture.remove(directory); defaults.removePersistentDomain(forName: suite) }
        control.mode = .bass
        control.handle(on(40, 96, 0.1))
        #expect(control.lastHit?.note == 40 && control.lastHit?.duration == nil, "held, not a one-shot")
        let verse = app.song!.sections[1]
        let verseStart = clock.seconds(forBar: 2)
        control.beginCapture(section: verse.id, clock: clock, startedAt: verseStart)
        control.handle(on(40, 96, verseStart + 0.040))
        control.handle(off(40, verseStart + 0.440))
        control.handle(on(43, 90, verseStart + clock.secondsPerBeat))
        control.handle(off(43, verseStart + clock.secondsPerBeat * 1.5))
        let version = try #require(control.endCapture(endedAt: verseStart + clock.secondsPerBar))
        guard case .bassline(let line) = version.kind else { Issue.record("not a bass line"); return }
        #expect(line.notes.count == 2)
        #expect(abs(line.notes[0].start - clock.beat(forSeconds: 0.040)) < 1e-6, "host ticks are 41.67 ns")
        #expect(abs(line.notes[1].start - 1) < 1e-6 && abs(line.notes[1].duration - 0.5) < 1e-6)
        #expect(line.key == app.song?.key)
        #expect(version.note?.contains("as a bass line") == true)
    }

    @Test("through the control: Keys holds a note on the instrument, and a take in Keys lands as a played melody a section long")
    func keysThroughControl() async throws {
        let (app, control, directory, defaults, suite) = fixture()
        defer { WiringFixture.remove(directory); defaults.removePersistentDomain(forName: suite) }
        control.mode = .keys
        #expect(defaults.string(forKey: MIDIControl.modeKey) == "keys", "remembered")
        control.handle(on(67, 90, 0.1))
        #expect(control.lastHit?.note == 67 && control.lastHit?.duration == nil, "held, not a one-shot")
        let verse = app.song!.sections[1]
        let verseStart = clock.seconds(forBar: 2)
        let before = app.song!.versions.count
        control.beginCapture(section: verse.id, clock: clock, startedAt: verseStart)
        control.handle(on(67, 90, verseStart + 0.020))
        control.handle(off(67, verseStart + clock.secondsPerBeat))
        control.handle(on(70, 84, verseStart + clock.secondsPerBeat * 2))
        let version = try #require(control.endCapture(endedAt: verseStart + clock.secondsPerBar))
        guard case .melody(let tune) = version.kind else { Issue.record("not a melody"); return }
        #expect(tune.notes.map(\.pitch.midi) == [67, 70])
        #expect(abs(tune.notes[1].start - 2) < 1e-6 && abs(tune.notes[1].duration - 2) < 1e-6, "still held: runs to the end of the take")
        #expect(tune.lengthInBars == verse.lengthInBars, "one pass is the section, breath and all")
        #expect(version.operation == Operation.played && version.author == .user)
        #expect(version.note?.contains("as a melody") == true)
        #expect(app.song!.versions.count == before + 1)
    }

    @Test("the sound a mode plays is the song's as it stands: a new instrument is heard on the next key, and no song plays the defaults")
    func soundFollowsTheSong() throws {
        let (app, control, directory, defaults, suite) = fixture()
        defer { WiringFixture.remove(directory); defaults.removePersistentDomain(forName: suite) }
        #expect(control.sound() == nil, "Off plays nothing")
        control.mode = .keys
        #expect(control.sound() == .keys(InstrumentVoiceSpec.rhodes.id))
        #expect(app.setInstrument("juno"))
        #expect(control.sound() == .keys("juno"), "picked after the mode was: still what the next key plays")
        control.mode = .kit
        #expect(control.sound() == .kit(SongPlayback.machineID(in: app.song!)))
        app.closeSong(saving: false)
        #expect(control.sound() == .kit(SynthMachine.tr808.id), "no song: the 808")
        control.mode = .bass
        #expect(control.sound() == .bass(BassVoiceSpec.finger.id))
    }

    @Test("pure: a melody keeps the notes as played and says how many bars one pass is")
    func melodyCapture() throws {
        let start = 1.0
        let timed: [(kind: MIDIEvent.Kind, seconds: Double)] = [
            (.noteOn(note: 72, velocity: 100), start + 0.030), (.noteOff(note: 72), start + clock.secondsPerBeat),
            (.noteOn(note: 74, velocity: 70), start - 1.0), // before the section: not in it
        ]
        let tune = try #require(MIDICapture.melody(MIDICapture.notes(from: timed), clock: clock, sectionStart: start, end: nil, bars: 4))
        #expect(tune.notes.count == 1 && tune.notes[0].pitch.midi == 72 && tune.notes[0].velocity == 100)
        #expect(abs(tune.notes[0].start - clock.beat(forSeconds: 0.030)) < 1e-9)
        #expect(tune.loopBars(beatsPerBar: 4) == 4)
        #expect(MIDICapture.melody([], clock: clock, sectionStart: 0, end: nil, bars: 4) == nil)
    }
}
