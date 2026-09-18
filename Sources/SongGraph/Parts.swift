import MusicTheory

// MARK: - Shared note event

/// A single note in a melody or bassline: pitch, start and duration in beats, MIDI velocity.
public struct NoteEvent: Hashable, Codable, Sendable {
    public var pitch: Pitch
    /// Start in beats from the beginning of the part.
    public var start: Double
    /// Length in beats.
    public var duration: Double
    /// MIDI velocity 0…127.
    public var velocity: Int

    public init(pitch: Pitch, start: Double, duration: Double, velocity: Int = 100) {
        self.pitch = pitch
        self.start = start
        self.duration = duration
        self.velocity = min(127, max(0, velocity))
    }

    public var end: Double { start + duration }
}

// MARK: - Progression

/// One chord held for a number of beats.
public struct ChordSpan: Hashable, Codable, Sendable {
    public var chord: Chord
    /// Duration in beats.
    public var beats: Double

    public init(chord: Chord, beats: Double) {
        self.chord = chord
        self.beats = beats
    }

    public init(_ chord: Chord, beats: Double) { self.init(chord: chord, beats: beats) }
}

/// One bar of a progression: the chords it holds, in order.
public struct ProgressionBar: Hashable, Codable, Sendable {
    public var chords: [ChordSpan]

    public init(chords: [ChordSpan]) { self.chords = chords }

    /// A bar holding a single chord for `beats` beats.
    public init(_ chord: Chord, beats: Double = 4) { chords = [ChordSpan(chord, beats: beats)] }

    public var beats: Double { chords.reduce(0) { $0 + $1.beats } }
}

/// A chord progression: bars of chords with durations, in a key.
public struct Progression: Hashable, Codable, Sendable {
    public var key: Key
    public var bars: [ProgressionBar]

    public init(key: Key, bars: [ProgressionBar]) {
        self.key = key
        self.bars = bars
    }

    /// Every chord in order, ignoring bar boundaries.
    public var chords: [Chord] { bars.flatMap { $0.chords.map(\.chord) } }

    /// Roman numerals of every chord in the progression's key.
    public var romanNumerals: [RomanNumeral] { chords.compactMap { key.romanNumeral(for: $0) } }

    /// The progression moved by `semitones`, with its key moved to match.
    public func transposed(by semitones: Int) -> Progression {
        let newKey = Key(tonicPitchClass: key.tonic.pitchClass.transposed(by: semitones), mode: key.mode)
        let newBars = bars.map { bar in
            ProgressionBar(chords: bar.chords.map { ChordSpan($0.chord.transposed(by: semitones), beats: $0.beats) })
        }
        return Progression(key: newKey, bars: newBars)
    }
}

// MARK: - Melody and bassline

/// A melody: notes with pitch, start and duration in beats, and velocity.
public struct Melody: Hashable, Codable, Sendable {
    public var notes: [NoteEvent]

    public init(notes: [NoteEvent]) { self.notes = notes }

    /// The melody moved by `semitones`.
    public func transposed(by semitones: Int) -> Melody {
        Melody(notes: notes.map { NoteEvent(pitch: $0.pitch + semitones, start: $0.start, duration: $0.duration, velocity: $0.velocity) })
    }

    /// Length in beats to the end of the last note.
    public var lengthInBeats: Double { notes.map(\.end).max() ?? 0 }
}

/// A bassline: notes, like a melody, kept as its own kind because personas treat it differently.
public struct Bassline: Hashable, Sendable {
    public var notes: [NoteEvent]
    /// The bass sound it plays through, by the synthesized voice's id (`"finger"`, `"sub"`). Nil
    /// is the app's default. Carried on the part because which bass it is decides who owns the
    /// sub — the Bassist's R9 — and that is a fact about the line, not a playback preference.
    public var sound: String?

    public init(notes: [NoteEvent], sound: String? = nil) {
        self.notes = notes
        self.sound = sound
    }

    public var lengthInBeats: Double { notes.map(\.end).max() ?? 0 }
}

extension Bassline: Codable {
    private enum CodingKeys: String, CodingKey { case notes, sound }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(notes: try c.decode([NoteEvent].self, forKey: .notes),
                  sound: try c.decodeIfPresent(String.self, forKey: .sound))
    }

    /// `sound` is omitted when nil, so a bassline written before it existed round-trips byte for byte.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(notes, forKey: .notes)
        try c.encodeIfPresent(sound, forKey: .sound)
    }
}

// MARK: - Lyric

/// Metrical stress of a syllable.
public enum Stress: String, Codable, Sendable, Hashable, CaseIterable {
    case unstressed, secondary, primary
}

/// One syllable of a lyric line, optionally aligned to a note of a melody.
public struct Syllable: Hashable, Codable, Sendable {
    public var text: String
    public var stress: Stress
    /// False when this syllable continues the previous one's word ("mel" + "o" + "dy").
    public var startsWord: Bool
    /// Index into the notes of the melody the lyric is aligned to, if aligned.
    public var noteIndex: Int?

    public init(_ text: String, stress: Stress = .unstressed, startsWord: Bool = true, noteIndex: Int? = nil) {
        self.text = text
        self.stress = stress
        self.startsWord = startsWord
        self.noteIndex = noteIndex
    }
}

/// One line of a lyric as syllables.
public struct LyricLine: Hashable, Codable, Sendable {
    public var syllables: [Syllable]

    public init(syllables: [Syllable]) { self.syllables = syllables }

    /// The line as words, joining syllables that continue a word.
    public var text: String {
        var out = ""
        for (index, syllable) in syllables.enumerated() {
            if index > 0 && syllable.startsWord { out += " " }
            out += syllable.text
        }
        return out
    }
}

/// A lyric: lines of syllables with stress marks, optionally aligned to the notes of a melody version.
public struct Lyric: Hashable, Codable, Sendable {
    public var lines: [LyricLine]
    /// The melody version the syllables' `noteIndex` values refer to.
    public var alignedTo: VersionID?

    public init(lines: [LyricLine], alignedTo: VersionID? = nil) {
        self.lines = lines
        self.alignedTo = alignedTo
    }

    /// The lyric as plain text, one line per row.
    public var text: String { lines.map(\.text).joined(separator: "\n") }
}

// MARK: - Groove

/// A drum voice. Extensible: the statics are the usual kit, any string is allowed.
public struct DrumVoice: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ name: String) { rawValue = name }

    public static let kick = DrumVoice("kick")
    public static let snare = DrumVoice("snare")
    public static let clap = DrumVoice("clap")
    public static let rim = DrumVoice("rim")
    public static let closedHat = DrumVoice("closedHat")
    public static let openHat = DrumVoice("openHat")
    public static let ride = DrumVoice("ride")
    public static let crash = DrumVoice("crash")
    public static let lowTom = DrumVoice("lowTom")
    public static let midTom = DrumVoice("midTom")
    public static let highTom = DrumVoice("highTom")
    public static let perc = DrumVoice("perc")

    public var description: String { rawValue }
}

/// Velocity tier of a groove step.
public enum VelocityTier: String, Codable, Sendable, Hashable, CaseIterable {
    case rest, ghost, normal, accent

    /// A representative MIDI velocity for the tier (0, 40, 90, 120).
    public var velocity: Int {
        switch self {
        case .rest: return 0
        case .ghost: return 40
        case .normal: return 90
        case .accent: return 120
        }
    }
}

/// The step pattern for one drum voice.
public struct GroovePattern: Hashable, Codable, Sendable {
    public var voice: DrumVoice
    /// One tier per step; the count should equal `stepsPerBar * bars` of the groove.
    public var steps: [VelocityTier]

    public init(voice: DrumVoice, steps: [VelocityTier]) {
        self.voice = voice
        self.steps = steps
    }
}

/// A groove: a step pattern per drum voice with velocity tiers and swing.
public struct Groove: Hashable, Sendable {
    /// Steps per bar (16 for sixteenths in 4/4).
    public var stepsPerBar: Int
    public var bars: Int
    /// Swing on the odd steps, spanning the MPC's own 50–75% range: 0 = 50% (straight),
    /// 2/3 = 66.67% (triplet), 1 = 75% (the machine's maximum, the odd step halfway to the next).
    /// Triplet is therefore 2/3, not 1. See `Performance.Swing` for the conversion a UI shows.
    public var swing: Double
    public var patterns: [GroovePattern]
    /// The chain the groove plays through, first pass nearest the kit. Empty is dry. See
    /// `Degradation` for why dust is carried on the part it dirties.
    public var degradation: [Degradation]

    public init(stepsPerBar: Int = 16, bars: Int = 1, swing: Double = 0, patterns: [GroovePattern],
                degradation: [Degradation] = []) {
        self.stepsPerBar = stepsPerBar
        self.bars = bars
        self.swing = swing
        self.patterns = patterns
        self.degradation = degradation
    }

    public var stepCount: Int { stepsPerBar * bars }
}

extension Groove: Codable {
    private enum CodingKeys: String, CodingKey { case stepsPerBar, bars, swing, patterns, degradation }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(stepsPerBar: try c.decode(Int.self, forKey: .stepsPerBar),
                  bars: try c.decode(Int.self, forKey: .bars),
                  swing: try c.decode(Double.self, forKey: .swing),
                  patterns: try c.decode([GroovePattern].self, forKey: .patterns),
                  degradation: try c.decodeIfPresent([Degradation].self, forKey: .degradation) ?? [])
    }

    /// A dry groove writes exactly what it always wrote: `degradation` is omitted when empty, so
    /// documents from before dust existed round-trip byte for byte.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(stepsPerBar, forKey: .stepsPerBar)
        try c.encode(bars, forKey: .bars)
        try c.encode(swing, forKey: .swing)
        try c.encode(patterns, forKey: .patterns)
        if !degradation.isEmpty { try c.encode(degradation, forKey: .degradation) }
    }
}

// MARK: - Sample

/// A slice marker in a sample, in seconds from the start of the media.
public struct SliceMarker: Hashable, Codable, Sendable {
    public var position: Double
    public var label: String?

    public init(position: Double, label: String? = nil) {
        self.position = position
        self.label = label
    }
}

/// A chopped sample: media by hash, slice markers, root pitch and detected tempo.
public struct Sample: Hashable, Sendable {
    public var media: MediaRef
    public var slices: [SliceMarker]
    public var rootPitch: Pitch?
    /// Detected tempo in BPM.
    public var detectedTempo: Double?
    /// The library record this sample was cut from, when known (drives clearances).
    public var sourceRecord: RecordID?
    /// The chain the chop plays through, first pass nearest the media. Empty is dry. The media is
    /// never printed through it, so the dry chop is always one parent away. See `Degradation`.
    public var degradation: [Degradation]

    public init(media: MediaRef, slices: [SliceMarker] = [], rootPitch: Pitch? = nil, detectedTempo: Double? = nil,
                sourceRecord: RecordID? = nil, degradation: [Degradation] = []) {
        self.media = media
        self.slices = slices
        self.rootPitch = rootPitch
        self.detectedTempo = detectedTempo
        self.sourceRecord = sourceRecord
        self.degradation = degradation
    }
}

extension Sample: Codable {
    private enum CodingKeys: String, CodingKey { case media, slices, rootPitch, detectedTempo, sourceRecord, degradation }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(media: try c.decode(MediaRef.self, forKey: .media),
                  slices: try c.decode([SliceMarker].self, forKey: .slices),
                  rootPitch: try c.decodeIfPresent(Pitch.self, forKey: .rootPitch),
                  detectedTempo: try c.decodeIfPresent(Double.self, forKey: .detectedTempo),
                  sourceRecord: try c.decodeIfPresent(RecordID.self, forKey: .sourceRecord),
                  degradation: try c.decodeIfPresent([Degradation].self, forKey: .degradation) ?? [])
    }

    /// A dry sample writes exactly what it always wrote; see `Groove.encode(to:)`.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(media, forKey: .media)
        try c.encode(slices, forKey: .slices)
        try c.encodeIfPresent(rootPitch, forKey: .rootPitch)
        try c.encodeIfPresent(detectedTempo, forKey: .detectedTempo)
        try c.encodeIfPresent(sourceRecord, forKey: .sourceRecord)
        if !degradation.isEmpty { try c.encode(degradation, forKey: .degradation) }
    }
}

// MARK: - Audio

/// Whether an audio part is a recorded take or a separated stem.
public enum AudioRole: String, Codable, Sendable, Hashable, CaseIterable {
    case take, stem
}

/// An audio take or stem.
public struct Audio: Hashable, Codable, Sendable {
    public var media: MediaRef
    public var role: AudioRole
    /// Stem name ("vocals", "drums", "bass", "other") when `role` is `.stem`.
    public var stem: String?
    public var sampleRate: Double
    public var channelCount: Int
    /// Length in seconds.
    public var duration: Double
    /// Seconds to shift the audio so it lines up with the song grid; nil when unaligned.
    public var alignmentOffset: Double?

    public init(media: MediaRef, role: AudioRole, stem: String? = nil, sampleRate: Double, channelCount: Int, duration: Double, alignmentOffset: Double? = nil) {
        self.media = media
        self.role = role
        self.stem = stem
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.duration = duration
        self.alignmentOffset = alignmentOffset
    }
}

// MARK: - Sound

/// A sound preset: an instrument or chain identifier plus parameter values.
public struct Sound: Hashable, Codable, Sendable {
    /// Instrument or chain identifier, e.g. "synth.sub", "sampler", "chain.lofi-tape".
    public var instrument: String
    public var preset: String?
    public var parameters: [String: Double]

    public init(instrument: String, preset: String? = nil, parameters: [String: Double] = [:]) {
        self.instrument = instrument
        self.preset = preset
        self.parameters = parameters
    }
}

// MARK: - Analysis

/// A span of time in seconds.
public struct TimeRange: Hashable, Codable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { end - start }
    public func contains(_ time: Double) -> Bool { time >= start && time < end }
}

/// A key holding over a time range.
public struct KeyRange: Hashable, Codable, Sendable {
    public var start: Double
    public var end: Double
    public var key: Key

    public init(start: Double, end: Double, key: Key) {
        self.start = start
        self.end = end
        self.key = key
    }

    public var range: TimeRange { TimeRange(start: start, end: end) }
}

/// A beat, marked when it is the first beat of a bar.
public struct BeatMarker: Hashable, Codable, Sendable {
    public var time: Double
    public var isDownbeat: Bool

    public init(time: Double, isDownbeat: Bool = false) {
        self.time = time
        self.isDownbeat = isDownbeat
    }
}

/// A tempo holding over a time range.
public struct TempoRange: Hashable, Codable, Sendable {
    public var start: Double
    public var end: Double
    public var bpm: Double

    public init(start: Double, end: Double, bpm: Double) {
        self.start = start
        self.end = end
        self.bpm = bpm
    }
}

/// A detected section of a record (intro, verse, chorus …), labelled when the analyzer names it.
public struct SectionRange: Hashable, Codable, Sendable {
    public var start: Double
    public var end: Double
    public var label: String?

    public init(start: Double, end: Double, label: String? = nil) {
        self.start = start
        self.end = end
        self.label = label
    }
}

/// The four instrument classes Music Understanding reports activity for.
public enum InstrumentKind: String, Codable, Sendable, Hashable, CaseIterable {
    case vocals, drums, bass, other
}

/// When an instrument class is active.
public struct InstrumentActivity: Hashable, Codable, Sendable {
    public var instrument: InstrumentKind
    public var ranges: [TimeRange]

    public init(instrument: InstrumentKind, ranges: [TimeRange]) {
        self.instrument = instrument
        self.ranges = ranges
    }
}

/// Loudness measurements.
public struct Loudness: Hashable, Codable, Sendable {
    /// Integrated loudness in LUFS.
    public var integrated: Double
    /// Loudness range in LU.
    public var range: Double?
    /// True peak in dBTP.
    public var truePeak: Double?

    public init(integrated: Double, range: Double? = nil, truePeak: Double? = nil) {
        self.integrated = integrated
        self.range = range
        self.truePeak = truePeak
    }
}

/// The result of analyzing a record, as plain values: times in seconds, keys as MusicTheory keys.
/// Mirrors what Music Understanding reports (key ranges, beats and downbeats, bars, tempo, sections,
/// instrument activity, loudness) so any analyzer can fill it.
public struct MusicAnalysis: Hashable, Codable, Sendable {
    /// Length of the analyzed media in seconds.
    public var duration: Double
    public var keys: [KeyRange]
    public var beats: [BeatMarker]
    public var bars: [TimeRange]
    public var tempo: [TempoRange]
    public var sections: [SectionRange]
    public var instruments: [InstrumentActivity]
    public var loudness: Loudness?
    /// The analyzer that produced this, e.g. "MusicUnderstanding 1.0" or "BeatThis 0.3".
    public var analyzer: String?

    public init(duration: Double, keys: [KeyRange] = [], beats: [BeatMarker] = [], bars: [TimeRange] = [],
                tempo: [TempoRange] = [], sections: [SectionRange] = [], instruments: [InstrumentActivity] = [],
                loudness: Loudness? = nil, analyzer: String? = nil) {
        self.duration = duration
        self.keys = keys
        self.beats = beats
        self.bars = bars
        self.tempo = tempo
        self.sections = sections
        self.instruments = instruments
        self.loudness = loudness
        self.analyzer = analyzer
    }

    /// The key holding for the longest time, if any.
    public var dominantKey: Key? { keys.max { $0.range.duration < $1.range.duration }?.key }

    /// The tempo holding for the longest time, if any.
    public var dominantTempo: Double? { tempo.max { ($0.end - $0.start) < ($1.end - $1.start) }?.bpm }

    /// Downbeat times.
    public var downbeats: [Double] { beats.filter(\.isDownbeat).map(\.time) }
}

// MARK: - Part kind

/// The kind of a part, as a plain name. Also the JSON discriminator for `PartKind`.
public enum PartType: String, Codable, Sendable, Hashable, CaseIterable {
    case progression, melody, lyric, groove, bassline, sample, audio, sound, analysis
}

/// The payload of a part version, one case per kind.
///
/// JSON: `{"type": "<kind>", …payload fields…}` — the payload's fields sit beside `type` rather than nested.
public enum PartKind: Hashable, Sendable {
    case progression(Progression)
    case melody(Melody)
    case lyric(Lyric)
    case groove(Groove)
    case bassline(Bassline)
    case sample(Sample)
    case audio(Audio)
    case sound(Sound)
    case analysis(MusicAnalysis)

    public var type: PartType {
        switch self {
        case .progression: return .progression
        case .melody: return .melody
        case .lyric: return .lyric
        case .groove: return .groove
        case .bassline: return .bassline
        case .sample: return .sample
        case .audio: return .audio
        case .sound: return .sound
        case .analysis: return .analysis
        }
    }

    /// Media files this payload depends on.
    public var mediaReferences: [MediaRef] {
        switch self {
        case .sample(let sample): return [sample.media]
        case .audio(let audio): return [audio.media]
        default: return []
        }
    }
}

extension PartKind: Codable {
    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(PartType.self, forKey: .type) {
        case .progression: self = .progression(try Progression(from: decoder))
        case .melody: self = .melody(try Melody(from: decoder))
        case .lyric: self = .lyric(try Lyric(from: decoder))
        case .groove: self = .groove(try Groove(from: decoder))
        case .bassline: self = .bassline(try Bassline(from: decoder))
        case .sample: self = .sample(try Sample(from: decoder))
        case .audio: self = .audio(try Audio(from: decoder))
        case .sound: self = .sound(try Sound(from: decoder))
        case .analysis: self = .analysis(try MusicAnalysis(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .progression(let payload): try payload.encode(to: encoder)
        case .melody(let payload): try payload.encode(to: encoder)
        case .lyric(let payload): try payload.encode(to: encoder)
        case .groove(let payload): try payload.encode(to: encoder)
        case .bassline(let payload): try payload.encode(to: encoder)
        case .sample(let payload): try payload.encode(to: encoder)
        case .audio(let payload): try payload.encode(to: encoder)
        case .sound(let payload): try payload.encode(to: encoder)
        case .analysis(let payload): try payload.encode(to: encoder)
        }
    }
}
