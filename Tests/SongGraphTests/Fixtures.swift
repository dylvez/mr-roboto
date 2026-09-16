import Foundation
import MusicTheory
@testable import SongGraph

/// Hand-built payloads and graphs shared by the tests.
enum Fixtures {
    static let bassist = Author.persona("Bassist")

    static func mediaRef(_ seedByte: UInt8, ext: String = "wav") -> MediaRef {
        MediaRef(hash: ContentHash(of: mediaData(seedByte)), fileExtension: ext)
    }

    static func mediaData(_ seedByte: UInt8, count: Int = 4096) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: Int(seedByte) &+ $0 * 7) })
    }

    static let dMajor = Key(tonic: NoteName(.d), mode: .ionian)

    static var progression: Progression {
        let chords = dMajor.diatonicTriads
        return Progression(key: dMajor, bars: [
            ProgressionBar(chords[0]),
            ProgressionBar(chords: [ChordSpan(chords[4], beats: 2), ChordSpan(chords[5], beats: 2)]),
            ProgressionBar(chords[3]),
            ProgressionBar(Chord(.a, .dominantSeventh).inverted(1)),
        ])
    }

    static var melody: Melody {
        Melody(notes: [
            NoteEvent(pitch: Pitch(name: "D4")!, start: 0, duration: 1, velocity: 96),
            NoteEvent(pitch: Pitch(name: "F#4")!, start: 1, duration: 0.5, velocity: 80),
            NoteEvent(pitch: Pitch(name: "A4")!, start: 1.5, duration: 2.5, velocity: 110),
        ])
    }

    static var lyric: Lyric {
        Lyric(lines: [
            LyricLine(syllables: [
                Syllable("Ar", stress: .primary, noteIndex: 0),
                Syllable("ri", startsWord: false, noteIndex: 1),
                Syllable("val", stress: .secondary, startsWord: false, noteIndex: 2),
            ]),
            LyricLine(syllables: [Syllable("in", noteIndex: nil), Syllable("light", stress: .primary)]),
        ], alignedTo: VersionID())
    }

    static var groove: Groove {
        let kick: [VelocityTier] = [.accent, .rest, .rest, .rest, .rest, .rest, .ghost, .rest,
                                    .normal, .rest, .rest, .rest, .rest, .rest, .rest, .rest]
        let hat: [VelocityTier] = Array(repeating: [.normal, .ghost], count: 8).flatMap { $0 }
        return Groove(stepsPerBar: 16, bars: 1, swing: 0.58, patterns: [
            GroovePattern(voice: .kick, steps: kick),
            GroovePattern(voice: .closedHat, steps: hat),
            GroovePattern(voice: DrumVoice("shaker"), steps: hat),
        ])
    }

    static var bassline: Bassline {
        Bassline(notes: [
            NoteEvent(pitch: Pitch(name: "D2")!, start: 0, duration: 1.5, velocity: 100),
            NoteEvent(pitch: Pitch(name: "A2")!, start: 2, duration: 0.5, velocity: 70),
        ])
    }

    static var sample: Sample {
        Sample(media: mediaRef(1), slices: [SliceMarker(position: 0), SliceMarker(position: 0.53, label: "snare")],
               rootPitch: Pitch(name: "F3"), detectedTempo: 93.2, sourceRecord: RecordID())
    }

    static var audio: Audio {
        Audio(media: mediaRef(2, ext: "m4a"), role: .stem, stem: "vocals", sampleRate: 44100, channelCount: 2,
              duration: 164.96, alignmentOffset: -0.04)
    }

    static var sound: Sound {
        Sound(instrument: "synth.sub", preset: "808 warm", parameters: ["decay": 0.62, "drive": 0.15, "cutoff": 1200])
    }

    static var analysis: MusicAnalysis {
        MusicAnalysis(
            duration: 164.96,
            keys: [KeyRange(start: 0, end: 164.96, key: dMajor)],
            beats: [BeatMarker(time: 0.36), BeatMarker(time: 0.9, isDownbeat: true), BeatMarker(time: 1.44), BeatMarker(time: 1.96)],
            bars: [TimeRange(start: 0.9, end: 3.04), TimeRange(start: 3.04, end: 5.14)],
            tempo: [TempoRange(start: 0, end: 164.96, bpm: 113)],
            sections: [SectionRange(start: 0, end: 17.3, label: "intro"), SectionRange(start: 17.3, end: 51.2, label: "verse")],
            instruments: [
                InstrumentActivity(instrument: .vocals, ranges: [TimeRange(start: 17.3, end: 160)]),
                InstrumentActivity(instrument: .drums, ranges: [TimeRange(start: 0.9, end: 164)]),
            ],
            loudness: Loudness(integrated: -13.7, range: 6.1, truePeak: -0.3),
            analyzer: "MusicUnderstanding"
        )
    }

    /// One payload of every kind.
    static var everyKind: [PartKind] {
        [.progression(progression), .melody(melody), .lyric(lyric), .groove(groove), .bassline(bassline),
         .sample(sample), .audio(audio), .sound(sound), .analysis(analysis)]
    }

    /// The hand-built graph from the task: a hummed seed → melody v1 → melody v2; progression v1..v3;
    /// a section using melody v2 and progression v2; an experiment using melody v2 and progression v3.
    struct Graph {
        var song: Song
        let seed: Seed
        let melody1: PartVersion
        let melody2: PartVersion
        let progression1: PartVersion
        let progression2: PartVersion
        let progression3: PartVersion
        let section: Section
        let experiment: Experiment
    }

    static func graph() throws -> Graph {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let seed = Seed(kind: .hummedTake(mediaRef(9)), createdAt: t0, note: "hummed on the walk home")
        let melody1 = PartVersion(partID: PartID(), kind: .melody(melody), createdAt: t0.addingTimeInterval(1),
                                  author: .user, operation: Operation.hummed, origin: seed.id)
        let melody2 = melody1.deriving(.melody(melody.transposed(by: 2)), by: .user, operation: Operation.transpose,
                                       note: "up a tone", createdAt: t0.addingTimeInterval(2))
        let progression1 = melody1.spawning(.progression(progression), by: bassist, operation: Operation.harmonize,
                                            createdAt: t0.addingTimeInterval(3))
        let progression2 = progression1.deriving(.progression(progression.transposed(by: 2)), by: bassist,
                                                 operation: Operation.transpose, createdAt: t0.addingTimeInterval(4),
                                                 alsoFrom: [melody2.id])
        let progression3 = progression2.deriving(.progression(progression.transposed(by: 2)), by: .persona("Keys"),
                                                 operation: Operation.reharmonize, createdAt: t0.addingTimeInterval(5))
        let section = Section(name: "Verse", stitch: [melody2.id, progression2.id], lengthInBars: 8, intensity: 0.4,
                              transitionIn: Transition(kind: .fill, beats: 2), transitionOut: Transition(kind: .riser, beats: 4))
        let experiment = Experiment(name: "reharm verse", versions: [melody2.id, progression3.id], author: .persona("Keys"),
                                    createdAt: t0.addingTimeInterval(6))
        var song = Song(title: "Arrival", artist: "Vessel", key: dMajor, tempo: 113, createdAt: t0)
        song.seeds = [seed]
        try song.append(contentsOf: [melody1, melody2, progression1, progression2, progression3])
        song.sections = [section]
        song.experiments = [experiment]
        return Graph(song: song, seed: seed, melody1: melody1, melody2: melody2, progression1: progression1,
                     progression2: progression2, progression3: progression3, section: section, experiment: experiment)
    }

    /// A fresh temporary directory for one test.
    static func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SongGraphTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
