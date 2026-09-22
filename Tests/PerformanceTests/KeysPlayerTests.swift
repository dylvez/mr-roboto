import AVFoundation
import AudioEngine
import Foundation
import Instrument
import MusicTheory
import SongGraph
import Testing
@testable import Performance

// The chords and the tune, sounded.
//
// The bug these exist to keep fixed: a song could hold three progressions, a melody and a chosen
// pad, and pressing play would give you the drums. Every pitched part in this app was writable,
// keepable, drawable and auditionable — and there was no `ScheduledSource` that could put one on
// the transport, so the form never played the harmony. `KeysPlayer` is that source; `Voicing` is
// the one rule for turning a written chord into notes, shared with the audition so the Chords
// surface and the song cannot disagree.

@Suite("Voicing: a written chord as notes")
struct VoicingTests {

    static func progression(_ chords: [Chord], beats: Double = 4) -> Progression {
        Progression(key: Key(tonic: NoteName(.c)), bars: chords.map { ProgressionBar($0, beats: beats) })
    }

    @Test("a triad is its three chord tones, rooted in the octave below middle C")
    func aTriad() {
        let notes = Voicing.notes(for: Self.progression([Chord(.c, .major)]))
        #expect(notes.map(\.pitch.midi) == [60 - 12, 64 - 12, 67 - 12], "C3 E3 G3")
        #expect(notes.allSatisfy { $0.start == 0 })
        #expect(notes.allSatisfy { $0.velocity == Voicing.velocity })
    }

    @Test("a seventh is four notes, and every chord starts where the last one ended")
    func spansFollowEachOther() {
        let progression = Self.progression([Chord(.d, .minorSeventh), Chord(.g, .dominantSeventh)])
        let notes = Voicing.notes(for: progression)

        #expect(notes.count == 8, "two sevenths")
        #expect(Set(notes.filter { $0.start == 0 }.map(\.pitch.midi)) == [50, 53, 57, 60], "Dm7 from D3")
        #expect(notes.filter { $0.start == 4 }.count == 4, "the second chord begins on beat 4")
        #expect(Voicing.lengthInBeats(of: progression) == 8)
    }

    @Test("a chord is let go just before the next, so a repeat re-articulates rather than blurring")
    func theChordBreathes() {
        let notes = Voicing.notes(for: Self.progression([Chord(.c, .major), Chord(.c, .major)]))
        let first = notes[0]
        #expect(first.duration < 4, "a chord held its whole span would run into the next")
        #expect(first.end < 4, "and the gap is before the downbeat, not after it")
        #expect(first.duration == 4 * Voicing.hold)
    }

    @Test("an inversion is honoured: the bottom note moves up an octave, it is not ignored")
    func inversionsAreVoiced() {
        let root = Voicing.notes(for: Self.progression([Chord(root: .c, quality: .major)]))
        let first = Voicing.notes(for: Self.progression([Chord(root: .c, quality: .major, inversion: 1)]))

        #expect(root.map(\.pitch.midi) == [48, 52, 55])
        #expect(first.map(\.pitch.midi).sorted() == [52, 55, 60], "E3 G3 C4: the C went up")
        #expect(root.map(\.pitch.midi) != first.map(\.pitch.midi))
    }

    @Test("a progression with no chords in it voices to nothing rather than to a silent note")
    func emptyIsEmpty() {
        #expect(Voicing.notes(for: Progression(key: Key(tonic: NoteName(.c)), bars: [])).isEmpty)
    }

    @Test("the written length is the sum of the spans, not where the last note stops")
    func writtenLength() {
        // Four bars of 4 = 16 beats written; the last chord is let go at 15.8 by `hold`.
        let progression = Self.progression([Chord(.c, .major), Chord(.a, .minor),
                                            Chord(.f, .major), Chord(.g, .major)])
        let notes = Voicing.notes(for: progression)
        #expect(Voicing.lengthInBeats(of: progression) == 16)
        #expect((notes.map(\.end).max() ?? 0) < 16, "the last chord breathes too")
    }
}

@Suite("Keys player")
struct KeysPlayerTests {

    static let sampleRate = 48_000.0

    /// Four bars: Cmaj7 | Am7 | Fmaj7 | G7.
    static let fourBars = Progression(key: Key(tonic: NoteName(.c)), bars: [
        ProgressionBar(Chord(.c, .majorSeventh)),
        ProgressionBar(Chord(.a, .minorSeventh)),
        ProgressionBar(Chord(.f, .majorSeventh)),
        ProgressionBar(Chord(.g, .dominantSeventh)),
    ])
    static let notesPerPass = 16

    static func preparedSampler() throws -> (VoiceSampler, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeysPlayerTests-\(UUID().uuidString)", isDirectory: true)
        let kit = try SynthesizedInstrument.build(.rhodes, in: folder, sampleRate: sampleRate)
        let sampler = VoiceSampler(cache: SampleCache())
        try sampler.prepare(kit, sampleRate: sampleRate, channels: 1)
        return (sampler, folder)
    }

    // MARK: Shape, with no audio at all

    @AudioActor
    @Test("one iteration is the progression's written bars, not where its last chord stops")
    func loopLength() async throws {
        let (sampler, folder) = try Self.preparedSampler()
        defer { try? FileManager.default.removeItem(at: folder) }

        let player = KeysPlayer(sampler: sampler, progression: Self.fourBars, timeline: .tempo(120), bars: 16)
        #expect(player.barsPerLoop == 4)
        #expect(player.beatsPerLoop == 16)
        #expect(player.loopsPerPass == 4, "four bars of chords fill a sixteen-bar section four times")
        #expect(player.startBeat(ofLoop: 1) == 16)
    }

    @AudioActor
    @Test("a melody keeps its own length, so eight bars of tune over four of chords stays eight")
    func aMelodyKeepsItsLength() async throws {
        let (sampler, folder) = try Self.preparedSampler()
        defer { try? FileManager.default.removeItem(at: folder) }

        let melody = Melody(notes: (0..<8).map {
            NoteEvent(pitch: Pitch(midi: 72), start: Double($0) * 4, duration: 1)
        })
        let player = KeysPlayer(sampler: sampler, melody: melody, timeline: .tempo(120), bars: 16)
        #expect(player.barsPerLoop == 8)
        #expect(player.loopsPerPass == 2)
    }

    @Test("hits land at the beats they were written on, offset by the loop they belong to")
    func hitsAtTheirBeats() {
        let timeline = GrooveTimeline.tempo(120)          // one beat = 0.5 s
        let hits = KeysPlayer.hits(for: Voicing.notes(for: Self.fourBars), on: timeline, offsetBeats: 16)

        #expect(hits.count == Self.notesPerPass)
        #expect(hits.first?.time == 8.0, "bar 5 at 120 bpm")
        #expect(hits.allSatisfy { ($0.duration ?? 0) > 0 }, "every chord tone is held, then let go")
        #expect(zip(hits, hits.dropFirst()).allSatisfy { $0.time <= $1.time }, "hits come out in time order")
    }

    // MARK: Through a real sampler, rendered offline

    @AudioActor
    @Test("four bars of chords through a real Rhodes: every note arrives, and it makes a sound")
    func chordsSound() async throws {
        let (sampler, folder) = try Self.preparedSampler()
        defer { try? FileManager.default.removeItem(at: folder) }

        let bpm = 120.0
        let player = KeysPlayer(sampler: sampler, progression: Self.fourBars, timeline: .tempo(bpm), bars: 4)
        let host = try OfflineGrooveHost(sampler: sampler, sampleRate: Self.sampleRate)
        defer { host.stop() }

        host.startTransport(player)
        let barSeconds = 60.0 / bpm * 4
        let peak = try host.render(seconds: 4 * barSeconds + 1.0, driving: player)

        #expect(player.scheduledLoopCount == 1, "four bars of chords fill a four-bar performance once")
        #expect(player.scheduledHitCount == Self.notesPerPass)
        #expect(player.isFinished)
        #expect(sampler.droppedEventCount == 0, "the core dropped events")
        #expect(sampler.unmappedHitCount == 0, "the kit had no zone for a chord tone")
        #expect(sampler.pendingHitCount == 0, "notes were left queued past the end of the run")
        #expect(peak > 0.01, "four bars of chords should make a sound")
    }

    @AudioActor
    @Test("a section clips its chords at its own bar line rather than ringing into the next section")
    func clippedToTheSection() async throws {
        let (sampler, folder) = try Self.preparedSampler()
        defer { try? FileManager.default.removeItem(at: folder) }

        // A four-bar progression in a two-bar section: only the first two bars' chords belong.
        let player = KeysPlayer(sampler: sampler, progression: Self.fourBars, timeline: .tempo(120), bars: 2)
        player.clipsToBars = true
        let host = try OfflineGrooveHost(sampler: sampler, sampleRate: Self.sampleRate)
        defer { host.stop() }

        host.startTransport(player)
        _ = try host.render(seconds: 6, driving: player)

        #expect(player.scheduledHitCount == 8, "two sevenths, not four: the section ends at bar 2")
        #expect(sampler.droppedEventCount == 0)
    }
}
