import AppKit
import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import SwiftUI
import Testing

@testable import MrRobotoApp

// One key a chord: the controller in Chords, the Chords sheet's pad, and what either keeps — the
// next bar on the sheet while Record is on it, a progression a section long from Play in.

private struct NoDevice: Error {}

@Suite("Chord keys: the controller in Chords, the sheet's pad, played in as a progression", .serialized) @MainActor
struct ChordKeyPlayTests {
    /// 120 bpm: half a second a beat, two seconds a bar.
    private let clock = TransportClock(tempo: 120, timeSignature: .fourFour, sampleRate: 48_000, startHostTime: 1_000_000)

    private func at(_ seconds: Double) -> UInt64 { clock.hostTime(forSeconds: seconds)! }
    private func on(_ note: Int, _ seconds: Double = 0, velocity: Int = 90) -> MIDIEvent {
        MIDIEvent(kind: .noteOn(note: note, velocity: velocity), channel: 0, hostTime: at(seconds), source: "Launchkey")
    }
    private func off(_ note: Int, _ seconds: Double = 0) -> MIDIEvent {
        MIDIEvent(kind: .noteOff(note: note), channel: 0, hostTime: at(seconds), source: "Launchkey")
    }

    /// A song with an Intro of two bars and a Verse of four, its chords voice-led and struck as stabs.
    private func fixture() -> (AppState, MIDIControl, () -> Void) {
        let directory = WiringFixture.temporaryDirectory("chord-keys")
        var built = FormFixture.build(tempo: 120)
        if let chords = Guidance.progressions(in: built.song).last, case .progression(var progression) = chords.kind {
            progression.playing = ChordPlaying(pattern: KeysPattern.stabs.rawValue, voicing: KeysVoicing.led.rawValue, seed: 7)
            try? built.song.append(chords.deriving(.progression(progression), by: .user, operation: Operation.edit, note: "stabs"))
        }
        let ids = [Guidance.grooves(in: built.song).last!, Guidance.basslines(in: built.song).last!].lanes
        built.song.sections = [Section(name: "Intro", stitch: ids, lengthInBars: 2), Section(name: "Verse", stitch: ids, lengthInBars: 4)]
        let app = BandFixture.app(in: directory, song: built.song)
        let suite = "chord-keys-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let kits = WiringFixture.temporaryDirectory("chord-keys-kits")
        let service = AuditionService(engine: { throw NoDevice() }, kitsDirectory: kits)
        let control = MIDIControl(app: app, service: service, defaults: defaults)
        return (app, control, {
            WiringFixture.remove(directory)
            WiringFixture.remove(kits)
            defaults.removePersistentDomain(forName: suite)
        })
    }

    // MARK: The controller

    @Test("in Chords the octave below middle C holds the buttons and a key from it up plays its chord in the song's key, voiced as the song's chords, held until let go")
    func controllerPlaysChords() throws {
        let (app, control, cleanup) = fixture()
        defer { cleanup() }
        control.mode = .chords
        #expect(control.mode.title == "Chords" && control.mode.capturedKind == "progression")
        let key = try #require(app.song?.key)
        let context = control.songChordContext()
        #expect(context.key == key && context.voicing == .led, "the song's chords are voice-led")
        #expect(control.sound() == .keys(context.instrument))

        control.handle(on(62))
        let first = try #require(control.chordKeys.last)
        #expect(first.played.chord == ChordKeys.chord(root: .d, in: key, holding: []).chord)
        #expect(first.voiced == Voicing.voicings(of: [first.played.chord], as: .led)[0])
        #expect(control.lastHit?.note.map { first.voiced.contains($0) } == true && control.lastHit?.duration == nil, "held, not a one-shot")
        #expect(control.chordKeys.down[62] == .d)
        control.handle(off(62))
        #expect(control.chordKeys.down.isEmpty)

        // B♭ below the split holds the seventh; G above it plays the chord with it.
        control.handle(on(58))
        #expect(control.chordKeys.held == [.seventh])
        control.handle(on(67))
        let second = try #require(control.chordKeys.last)
        #expect(second.played.chord == ChordKeys.chord(root: .g, in: key, holding: [.seventh]).chord)
        #expect(second.voiced == Voicing.voicings(of: [first.played.chord, second.played.chord], as: .led)[1],
                "voice-led from the chord before")
        control.handle(off(67))
        control.handle(off(58))
        #expect(control.chordKeys.held.isEmpty)
        // C below the split holds nothing and plays nothing.
        control.handle(on(48))
        #expect(control.chordKeys.held.isEmpty && control.chordKeys.last == second)
    }

    @Test("Play in on chord keys lands as a progression a section long: each chord from the beat it was struck nearest, played as the song's chords are")
    func playedInAsAProgression() throws {
        let (app, control, cleanup) = fixture()
        defer { cleanup() }
        control.mode = .chords
        let song = try #require(app.song)
        let key = try #require(song.key)
        let verse = song.sections[1]
        let start = clock.seconds(forBar: 2)
        func beat(_ beats: Double) -> Double { start + clock.seconds(forBeat: beats) }
        let before = song.versions.count
        control.beginCapture(section: verse.id, clock: clock, startedAt: start)
        // A hair late on one, a hair early into bar two, on three of bar three, and an A minor
        // made so with a button on the third beat of the last bar.
        control.handle(on(62, beat(0.1))); control.handle(off(62, beat(3.5)))
        control.handle(on(67, beat(3.9))); control.handle(off(67, beat(7.5)))
        control.handle(on(60, beat(8))); control.handle(off(60, beat(13)))
        control.handle(on(51, beat(13.5)))
        control.handle(on(69, beat(14))); control.handle(off(69, beat(15.5)))
        control.handle(off(51, beat(15.5)))
        let version = try #require(control.endCapture(endedAt: beat(16)))
        guard case .progression(let progression) = version.kind else { Issue.record("not a progression"); return }
        func chord(_ root: PitchClass, _ buttons: Set<ChordButton> = []) -> Chord { ChordKeys.chord(root: root, in: key, holding: buttons).chord }
        #expect(progression.bars.count == verse.lengthInBars)
        #expect(progression.bars.map { $0.chords.map(\.chord) } == [[chord(.d)], [chord(.g)], [chord(.c)], [chord(.c), chord(.a, [.minor])]])
        #expect(progression.bars[3].chords.map(\.beats) == [2, 2])
        #expect(progression.key == key)
        #expect(progression.playing?.keysPattern == .stabs && progression.playing?.keysVoicing == .led,
                "played the way the song's chords already are")
        #expect(version.operation == Operation.played && version.author == .user)
        #expect(version.note?.hasPrefix("Played on Launchkey into Verse") == true && version.note?.contains("as a progression") == true,
                "\(version.note ?? "")")
        #expect(app.song!.versions.count == before + 1)
    }

    @Test("pure: chords snap to the beat, carry across the bar line, a chord struck again is one, and none struck is no part")
    func progressionFromStruckChords() throws {
        let key = Key(tonic: NoteName(.c))
        let c = Chord(.c, .major), f = Chord(.f, .major), g = Chord(.g, .dominantSeventh)
        func at(_ beat: Double) -> Double { clock.seconds(forBeat: beat) }
        // C a hair late, and again on three; G and then F nearest beat six, and G on beat ten.
        let struck: [(chord: Chord, lift: Int, seconds: Double)] = [(c, 0, at(0.4)), (c, 0, at(2)), (g, 0, at(5.6)), (f, 0, at(6.4)), (g, 0, at(10))]
        let progression = try #require(MIDICapture.progression(struck, clock: clock, sectionStart: 0, end: at(11), bars: nil, key: key))
        #expect(progression.bars.count == 3, "to the end of the bar the take ended in")
        #expect(progression.bars[0].chords.map(\.chord) == [c] && progression.bars[0].beats == 4, "struck again, one chord")
        #expect(progression.bars[1].chords.map(\.chord) == [c, f] && progression.bars[1].chords.map(\.beats) == [2, 2],
                "of two nearest beat six, the later")
        #expect(progression.bars[2].chords.map(\.chord) == [f, g] && progression.bars[2].chords.map(\.beats) == [2, 2],
                "F held over the bar line")
        #expect(progression.spans.allSatisfy { $0.lift == nil }, "nothing turned")
        // A section's length wins, and what is struck past it is not kept.
        let held = try #require(MIDICapture.progression(struck + [(f, 0, at(20))], clock: clock, sectionStart: 0, end: nil, bars: 2, key: key))
        #expect(held.bars.count == 2)
        // Struck in the count-in, more than half a beat early: nothing to keep.
        #expect(MIDICapture.progression([(c, 0, -at(1))], clock: clock, sectionStart: 0, end: nil, bars: 4, key: key) == nil)
        #expect(MIDICapture.progression([], clock: clock, sectionStart: 0, end: nil, bars: 4, key: key) == nil)
        // The same chord struck again turned another way is a change, and keeps its turn.
        let turned = try #require(MIDICapture.progression([(c, 0, at(0)), (c, 1, at(2))], clock: clock, sectionStart: 0,
                                                          end: nil, bars: 1, key: key))
        #expect(turned.bars[0].chords.map(\.lift) == [nil, 1] && turned.bars[0].chords.map(\.beats) == [2, 2])
    }

    // MARK: The sheet

    @Test("Record on the sheet in Chords: each chord key writes the next bar in the sheet's key; the pad too; a button it cannot take is said")
    func chordKeysIntoTheSheet() throws {
        let (_, control, cleanup) = fixture()
        defer { cleanup() }
        let sheet = ChordsModel(host: ChordsStub(), key: Key(tonic: NoteName(.d), mode: .dorian))
        sheet.autoKeep.delay = nil
        sheet.setVoicing(.spread)
        #expect(sheet.chordContext == ChordContext(key: sheet.key, voicing: .spread, instrument: sheet.instrument))
        control.mode = .chords
        control.beginTake(into: sheet, clock: nil, sectionStart: 0, bars: nil, punchOut: nil)
        control.handle(on(62)); control.handle(off(62))
        #expect(sheet.text == "Dm", "the first chord is the first bar: the suggestion was not the song's")
        #expect(control.chordKeys.last?.voiced == Voicing.voicings(of: [Chord(.d, .minor)], as: .spread)[0], "voiced as the sheet voices")
        control.handle(on(58)); control.handle(on(67)); control.handle(off(67)); control.handle(off(58))
        #expect(sheet.text == "Dm | G7")
        // The pad, while Record is on, writes the same way.
        control.chordDown(.c, key: 1000, source: "the chord pad", sheet: sheet)
        control.chordUp(key: 1000)
        #expect(sheet.text == "Dm | G7 | C")
        // B in D dorian is its diminished six; a major seventh will not go on it, and the line says so.
        control.handle(on(59)); control.handle(on(71)); control.handle(off(71)); control.handle(off(59))
        #expect(sheet.text == "Dm | G7 | C | Bdim")
        #expect(sheet.takeLine == "Bdim — maj7 did not go on it", "\(sheet.takeLine ?? "")")
        #expect(control.takeNotes == 4)
        sheet.undo()
        #expect(sheet.text == "Dm | G7 | C", "a chord at a time")

        // In Keys, a controller on the sheet plays chords whole, as it did.
        control.mode = .keys
        for note in [60, 64, 67] { control.handle(on(note)) }
        for note in [60, 64, 67] { control.handle(off(note)) }
        #expect(sheet.text == "Dm | G7 | C | C")
        control.finishTake(at: nil)
    }

    @Test("the pad off Record plays the sheet's chord and writes nothing; Chords on another surface's take is that surface's")
    func padWithoutRecord() throws {
        let (_, control, cleanup) = fixture()
        defer { cleanup() }
        let sheet = ChordsModel(host: ChordsStub(), key: Key(tonic: NoteName(.e), mode: .aeolian))
        sheet.autoKeep.delay = nil
        let text = sheet.text
        control.chordDown(.c, key: 1000, source: "the chord pad", sheet: sheet)
        #expect(control.chordKeys.last?.played.chord == Chord(.c, .major) && control.chordKeys.last?.key == sheet.key,
                "C in E minor is its six, played in the sheet's key")
        #expect(control.chordKeys.down[1000] == .c)
        control.chordUp(key: 1000)
        #expect(control.chordKeys.down.isEmpty && sheet.text == text && control.takeNotes == 0)

        // The Grid recording in Chords mode still takes drum hits: chord keys are the sheet's.
        let grid = GridModel(host: StubGridHost(), tempo: 120)
        grid.autoKeep.delay = nil
        control.mode = .chords
        control.beginTake(into: grid, clock: nil, sectionStart: 0, bars: 1, punchOut: nil)
        control.handle(on(62))
        #expect(control.chordKeys.last?.played.chord == Chord(.c, .major), "no chord struck")
        control.finishTake(at: nil)
    }

    @Test("buttons from three hands are one set: a controller's, the computer's and a click's, and a click holds until clicked again")
    func buttonsFromEverywhere() {
        let keyboard = ChordKeyboard()
        #expect(keyboard.controllerKey(51, isDown: true) && keyboard.held == [.minor])
        #expect(!keyboard.controllerKey(55, isDown: true), "G below the split is nothing")
        keyboard.key(.ninth, isDown: true)
        keyboard.toggle(.seventh)
        #expect(keyboard.held == [.minor, .ninth, .seventh])
        let context = ChordContext(key: Key(tonic: NoteName(.c)), voicing: .close, instrument: InstrumentVoiceSpec.rhodes.id)
        #expect(keyboard.chord(for: .a, in: context).chord == Chord(.a, .minorNinth))
        keyboard.letGoOfKeys()
        _ = keyboard.controllerKey(51, isDown: false)
        #expect(keyboard.held == [.seventh], "the click's holds")
        keyboard.toggle(.seventh)
        #expect(keyboard.held.isEmpty)
    }

    // MARK: Layout

    /// How big a view draws when offered `width`; nothing proposed is the view's own size.
    private func drawn<V: View>(_ view: V, width: CGFloat? = nil) throws -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return try #require(renderer.nsImage).size
    }

    @Test("the transport's MIDI switch, five chips with Chords, fits its block beside its label")
    func switchFits() throws {
        FontRegistration.registerBundledFonts()
        let width = try drawn(HStack(spacing: 4) {
            SmallLabel("MIDI", color: Design.Palette.inkTertiary)
            SegmentedChoice(options: MIDIControl.Mode.allCases, selection: .chords, title: \.title) { _ in }
        }).width
        #expect(width <= TransportBar.midiWidth, "\(width)")
    }

    @Test("the chord pad is one row from the default window up, and two at the window's minimum")
    func padFits() throws {
        FontRegistration.registerBundledFonts()
        let sheet = ChordsModel(host: ChordsStub(), key: Key(tonic: NoteName(.c)))
        let widths = SurfaceGeometry.all.map { SurfaceGeometry.content(of: $0).width }
        let heights = try widths.map { try drawn(ChordPad(model: sheet), width: $0).height }
        #expect(heights[1] <= 140 && heights[2] <= 140, "one row: \(heights)")
        #expect(heights[0] <= 250, "two rows at the minimum: \(heights)")
        let widest = try widths.map { try drawn(ChordPad(model: sheet), width: $0).width }
        for (drawn, offered) in zip(widest, widths) { #expect(drawn <= offered + 0.5, "\(drawn) in \(offered)") }
    }
}
