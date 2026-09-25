import AudioEngine
import Foundation
import Instrument
import MusicTheory
import SongGraph
import Testing
@testable import Performance

// A line is as long as it says, not as long as its groove and not as far as its last note: a
// four-bar tune whose fourth bar is a breath loops after the breath, and an eight-bar bass phrase
// over a one-bar groove is eight bars with a kick under every one.

@Suite("Line length: the players loop at it, the writer writes to it")
struct LineLengthPlayerTests {

    /// Three bars of notes and a fourth that is a rest.
    static let threeBarsAndARest: [NoteEvent] = (0..<3).map {
        NoteEvent(pitch: Pitch(midi: 38), start: Double($0) * 4, duration: 2)
    }

    // MARK: The bass player

    @AudioActor
    @Test("a bass line with a stated length loops at it, the trailing rest bar included")
    func bassLoopsAtItsLength() async throws {
        let sampler = VoiceSampler(cache: SampleCache())
        let stated = Bassline(notes: Self.threeBarsAndARest, sound: "finger", lengthInBars: 4)
        let player = BasslinePlayer(sampler: sampler, bassline: stated, timeline: .tempo(120), bars: 16)
        player.drivesSampler = false
        #expect(player.barsPerLoop == 4)
        #expect(player.loopsPerPass == 4)
        #expect(player.startBeat(ofLoop: 1) == 16, "the second pass starts after the rest, not on it")

        // The same notes without a length: as they always were, the last note rounded up.
        let derived = BasslinePlayer(sampler: sampler, bassline: Bassline(notes: Self.threeBarsAndARest),
                                     timeline: .tempo(120), bars: 16)
        #expect(derived.barsPerLoop == 3)

        // Scheduled: the second pass's first note is at bar five.
        player.transportDidStart(originSampleTime: 0, sampleRate: 48_000)
        player.schedule(through: 60)
        #expect(player.scheduledLoopCount == 4)
        #expect(player.scheduledHitCount == 12)
        let pass2 = BasslinePlayer.hits(for: stated, on: .tempo(120), offsetBeats: player.startBeat(ofLoop: 1))
        #expect(pass2.first?.time == 8.0, "bar 5 at 120 bpm")
    }

    @AudioActor
    @Test("a note ringing past a stated end does not add a bar to the loop")
    func aTailDoesNotLengthen() async throws {
        let sampler = VoiceSampler(cache: SampleCache())
        let line = Bassline(notes: [NoteEvent(pitch: Pitch(midi: 40), start: 3.5, duration: 0.75)], lengthInBars: 1)
        let player = BasslinePlayer(sampler: sampler, bassline: line, timeline: .tempo(90))
        #expect(player.barsPerLoop == 1)
    }

    // MARK: The keys player

    @AudioActor
    @Test("a melody with a stated length loops at it; without one, at its last note")
    func melodyLoopsAtItsLength() async throws {
        let sampler = VoiceSampler(cache: SampleCache())
        let tune = Melody(notes: Self.threeBarsAndARest.map {
            NoteEvent(pitch: Pitch(midi: 72), start: $0.start, duration: $0.duration)
        }, lengthInBars: 4)
        let player = KeysPlayer(sampler: sampler, melody: tune, timeline: .tempo(120), bars: 16)
        #expect(player.barsPerLoop == 4)
        #expect(player.beatsPerLoop == 16)
        #expect(player.lengthInBeats == 16)
        #expect(player.loopsPerPass == 4)

        let untold = KeysPlayer(sampler: sampler, melody: Melody(notes: tune.notes), timeline: .tempo(120), bars: 16)
        #expect(untold.barsPerLoop == 3)

        // A tail past the stated end: still the stated length.
        let tail = Melody(notes: [NoteEvent(pitch: Pitch(midi: 72), start: 7, duration: 2)], lengthInBars: 2)
        #expect(KeysPlayer(sampler: sampler, melody: tail, timeline: .tempo(120)).barsPerLoop == 2)
    }

    // MARK: The writer

    /// One bar: kick on 1 and the and of 2.
    static func oneBarGroove() -> Groove {
        func line(_ voice: DrumVoice, _ pattern: String) -> GroovePattern {
            GroovePattern(voice: voice, steps: pattern.map { $0 == "x" ? .normal : .rest })
        }
        return Groove(stepsPerBar: 16, bars: 1, swing: 0, patterns: [
            line(.kick, "x-----x---------"),
            line(.closedHat, "x-x-x-x-x-x-x-x-"),
        ])
    }

    static let dm7g7: [ChordSpan] = [
        ChordSpan(Chord(.d, .minorSeventh), beats: 4),
        ChordSpan(Chord(.g, .dominantSeventh), beats: 4),
    ]

    static func request(_ lineage: BassLineage, bars: Int?) -> BassRequest {
        BassRequest(key: Key(tonic: NoteName(.d), mode: .aeolian), chords: dm7g7, groove: oneBarGroove(),
                    tempo: 92, lineage: lineage, seed: 7, bars: bars)
    }

    @Test("asked for four bars over a one-bar groove, the writer writes four, the kick repeated under all of them")
    func writesTheWholeLength() {
        let request = Self.request(.programmed, bars: 4)
        #expect(request.lineBars == 4)
        #expect(request.lineGroove.bars == 4)
        let line = BassWriter.write(request)
        #expect(line.lengthInBars == 4)
        // The programmed line is the kick: one note per kick, in every bar.
        #expect(line.notes.map(\.start) == [0, 1.5, 4, 5.5, 8, 9.5, 12, 13.5])
        // The harmony cycles over the whole line: D, G, D, G by the bar.
        let roots = line.notes.filter { $0.start.truncatingRemainder(dividingBy: 4) == 0 }.map(\.pitch.pitchClass)
        #expect(roots == [.d, .g, .d, .g], "\(roots)")
    }

    @Test("Palladino over a longer line: every bar's downbeat is sounded, and on its bar's chord")
    func palladinoOverTheWholeLength() {
        let line = BassWriter.write(Self.request(.palladino, bars: 4))
        #expect(line.lengthInBars == 4)
        #expect(line.notes.allSatisfy { $0.start < 16 }, "nothing past the line's end")
        for bar in 0..<4 {
            let downbeat = line.notes.first { $0.velocity > 60 && $0.start >= Double(bar * 4) && $0.start < Double(bar * 4) + 0.25 }
            #expect(downbeat != nil, "bar \(bar + 1) has no downbeat")
            #expect(downbeat?.pitch.pitchClass == (bar % 2 == 0 ? .d : .g), "bar \(bar + 1)")
        }
        // R13's wrap is at the end of the line, not the end of the groove's one bar.
        #expect(line.notes.contains { $0.pitch.pitchClass == .cSharp && $0.start >= 15 && $0.start < 16 })
    }

    @Test("without a length the line is the groove's, and says so")
    func theGroovesLengthByDefault() {
        let line = BassWriter.write(Self.request(.palladino, bars: nil))
        #expect(line.lengthInBars == 1)
        #expect(line.notes.allSatisfy { $0.start < 4 })
    }
}
