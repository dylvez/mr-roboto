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

/// How a progression is played: how its chords are voiced, the rhythm they are struck in, and a
/// seed for the hand that strikes them.
///
/// A progression is a lead sheet — which chords, for how long — and a lead sheet says nothing of
/// how a player plays it. This is that, carried on the chords it plays the way a bass line carries
/// its hands: the chords stay chords, to be read and rewritten as chords, and what is heard is a
/// performance of them. `Performance.Voicing` turns the two into notes.
public struct ChordPlaying: Hashable, Codable, Sendable {
    /// The rhythm, by a `Performance.KeysPattern`'s id: "held", "stabs", "arpeggio".
    public var pattern: String
    /// The voicing, by a `Performance.KeysVoicing`'s id: "close", "led", "spread", "rootless".
    public var voicing: String
    /// What the striking varies on. The same seed is the same performance.
    public var seed: UInt64

    public init(pattern: String = ChordPlaying.held, voicing: String = ChordPlaying.close, seed: UInt64 = 0) {
        self.pattern = pattern
        self.voicing = voicing
        self.seed = seed
    }

    public static let held = "held"
    public static let close = "close"

    /// Held, in close position: what every progression played as before it could be played any
    /// other way, and what one with no playing still does.
    public var isPlain: Bool { pattern == Self.held && voicing == Self.close }
}

/// A chord progression: bars of chords with durations, in a key.
public struct Progression: Hashable, Codable, Sendable {
    public var key: Key
    public var bars: [ProgressionBar]
    /// How it is played. Nil — every progression written before this — is held, in close
    /// position. Synthesized coding omits it when nil, so older documents round-trip byte for byte.
    public var playing: ChordPlaying?

    public init(key: Key, bars: [ProgressionBar], playing: ChordPlaying? = nil) {
        self.key = key
        self.bars = bars
        self.playing = playing
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
        return Progression(key: newKey, bars: newBars, playing: playing)
    }
}

// MARK: - Melody and bassline

/// A melody: notes with pitch, start and duration in beats, and velocity.
public struct Melody: Hashable, Codable, Sendable {
    public var notes: [NoteEvent]
    /// How many bars one pass of the tune covers, when it was said. Nil is "to the end of the last
    /// note, rounded up to the bar", which is what every melody meant before this was carried. A
    /// four-bar phrase whose fourth bar is a breath has to say so here, or the breath is lost and
    /// the phrase loops after three. Synthesized coding omits it when nil, so older documents
    /// round-trip byte for byte.
    public var lengthInBars: Int?

    public init(notes: [NoteEvent], lengthInBars: Int? = nil) {
        self.notes = notes
        self.lengthInBars = lengthInBars.map { max(1, $0) }
    }

    /// The melody moved by `semitones`. Moving the pitches does not move the bar line.
    public func transposed(by semitones: Int) -> Melody {
        Melody(notes: notes.map { NoteEvent(pitch: $0.pitch + semitones, start: $0.start, duration: $0.duration, velocity: $0.velocity) },
               lengthInBars: lengthInBars)
    }

    /// Length in beats to the end of the last note.
    public var lengthInBeats: Double { notes.map(\.end).max() ?? 0 }

    /// The bars one pass covers: the stated length, else the notes rounded up to whole bars.
    public func loopBars(beatsPerBar: Int) -> Int {
        phraseBars(stated: lengthInBars, lastNoteEnd: lengthInBeats, beatsPerBar: beatsPerBar)
    }
}

/// A bassline: notes, like a melody, kept as its own kind because personas treat it differently.
public struct Bassline: Hashable, Sendable {
    public var notes: [NoteEvent]
    /// The bass sound it plays through, by the synthesized voice's id (`"finger"`, `"sub"`). Nil
    /// is the app's default. Carried on the part because which bass it is decides who owns the
    /// sub — the Bassist's R9 — and that is a fact about the line, not a playback preference.
    public var sound: String?
    /// The key the line was written in, so a line kept as an idea still knows where it stands and
    /// a merge can move it by arithmetic. Nil for a line from before keys were carried.
    public var key: Key?
    /// How many bars one pass of the line covers, when it was said. Nil is "to the end of the last
    /// note, rounded up", as every line before this meant. An eight-bar phrase over a one-bar
    /// groove, or a line whose last bar is a rest, needs it: the notes alone cannot say where a
    /// silence ends.
    public var lengthInBars: Int?
    /// Whose hands wrote it — a `BassLineage` raw value, "walking", "palladino" — when the writer
    /// wrote it. A reading of the line needs it: note-offs on the beat are Palladino's technique,
    /// and a walking line judged by it is judged by the wrong player. Nil for a line played in.
    public var hands: String?

    public init(notes: [NoteEvent], sound: String? = nil, key: Key? = nil, lengthInBars: Int? = nil, hands: String? = nil) {
        self.notes = notes
        self.sound = sound
        self.key = key
        self.lengthInBars = lengthInBars.map { max(1, $0) }
        self.hands = hands
    }

    public var lengthInBeats: Double { notes.map(\.end).max() ?? 0 }

    /// The bars one pass covers: the stated length, else the notes rounded up to whole bars.
    public func loopBars(beatsPerBar: Int) -> Int {
        phraseBars(stated: lengthInBars, lastNoteEnd: lengthInBeats, beatsPerBar: beatsPerBar)
    }
}

/// One rule for how long a written line is, so the players, the MIDI file and the Piano roll
/// cannot disagree about where a phrase repeats. A stated length wins, rests at the end and all; a
/// note ringing a hair past it does not double the loop, it overlaps the next pass as a tail would.
/// Without one, the last note's end rounded up to the bar, as it always was — never less than one.
private func phraseBars(stated: Int?, lastNoteEnd: Double, beatsPerBar: Int) -> Int {
    if let stated { return max(1, stated) }
    return max(1, Int((lastNoteEnd / Double(max(1, beatsPerBar))).rounded(.up)))
}

extension Bassline: Codable {
    private enum CodingKeys: String, CodingKey { case notes, sound, key, lengthInBars, hands }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(notes: try c.decode([NoteEvent].self, forKey: .notes),
                  sound: try c.decodeIfPresent(String.self, forKey: .sound),
                  key: try c.decodeIfPresent(Key.self, forKey: .key),
                  lengthInBars: try c.decodeIfPresent(Int.self, forKey: .lengthInBars),
                  hands: try c.decodeIfPresent(String.self, forKey: .hands))
    }

    /// `sound`, `key` and `lengthInBars` are omitted when nil, so a bassline written before they
    /// existed round-trips byte for byte.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(notes, forKey: .notes)
        try c.encodeIfPresent(sound, forKey: .sound)
        try c.encodeIfPresent(key, forKey: .key)
        try c.encodeIfPresent(lengthInBars, forKey: .lengthInBars)
        try c.encodeIfPresent(hands, forKey: .hands)
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
    /// Which stanza is which section: "[Hook]" written above a stanza. Nil for words with no labels,
    /// so a lyric from before labels round-trips byte for byte.
    public var labels: [StanzaLabel]?

    /// A section's name on the stanza that starts at `line`.
    public struct StanzaLabel: Hashable, Codable, Sendable {
        public var line: Int
        public var name: String
        public init(line: Int, name: String) {
            self.line = line
            self.name = name
        }
    }

    public init(lines: [LyricLine], alignedTo: VersionID? = nil, labels: [StanzaLabel]? = nil) {
        self.lines = lines
        self.alignedTo = alignedTo
        self.labels = labels
    }

    /// The lyric as plain text, one line per row, each label written back above its stanza as
    /// "[Name]" — the way it was typed.
    public var text: String {
        var rows: [String] = []
        for (index, line) in lines.enumerated() {
            if let label = labels?.first(where: { $0.line == index }) { rows.append("[\(label.name)]") }
            rows.append(line.text)
        }
        return rows.joined(separator: "\n")
    }

    /// The lines of the stanza labelled `name` (case aside), or nil when no stanza is. A stanza runs
    /// from its label to the next blank line or the next label.
    public func stanza(named name: String) -> [LyricLine]? {
        guard let label = labels?.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
              lines.indices.contains(label.line) else { return nil }
        var out: [LyricLine] = []
        for index in label.line..<lines.count {
            if index > label.line, labels?.contains(where: { $0.line == index }) == true { break }
            if lines[index].syllables.isEmpty { if out.isEmpty { continue } else { break } }
            out.append(lines[index])
        }
        return out
    }

    /// The stanza the section at `index` of `sections` sings: the one labelled with its name, case
    /// aside. The second Verse of the form sings the second stanza labelled Verse when the words
    /// have two; with only one, every Verse sings it. `lines` runs from the stanza's first sung
    /// line to the next blank line or label, blank lines under the label passed over. Nil when no
    /// stanza carries the name, or the one that does has nothing sung under it.
    ///
    /// The Booth shows this stanza while that section records, and Structure shows it under the
    /// section, so the two cannot disagree about which words a section has.
    public func stanza(forSectionAt index: Int, in sections: [Section]) -> (label: StanzaLabel, lines: Range<Int>)? {
        guard let labels, sections.indices.contains(index) else { return nil }
        let name = sections[index].name
        func same(_ other: String) -> Bool { other.caseInsensitiveCompare(name) == .orderedSame }
        let matching = labels.filter { same($0.name) }.sorted { $0.line < $1.line }
        guard !matching.isEmpty else { return nil }
        let occurrence = sections[..<index].filter { same($0.name) }.count
        let label = matching[min(occurrence, matching.count - 1)]
        var first: Int?
        var end = label.line
        for line in label.line..<lines.count {
            if line > label.line, labels.contains(where: { $0.line == line }) { break }
            if lines[line].syllables.isEmpty { if first == nil { continue } else { break } }
            if first == nil { first = line }
            end = line + 1
        }
        guard let first else { return nil }
        return (label, first..<end)
    }

    /// The same words set to a melody's notes: one syllable per note, in order, across the sung
    /// lines. Syllables past the last note stay unset, and a melody with more notes than syllables
    /// leaves the rest as melisma. The version is who the indices refer to.
    ///
    /// The simplest honest setting: a songwriter moves syllables afterwards, and the Lyricist reads
    /// what this gives — a stressed syllable on a weak beat — rather than guessing an intent.
    public func aligned(to melody: Melody, version: VersionID) -> Lyric {
        var copy = self
        copy.alignedTo = version
        // The notes in the order they sound: a note dragged later in the roll stays where it was
        // in the list, and the words used to be set in list order — a syllable on a note after
        // the next one's.
        let order = melody.notes.indices.sorted { (melody.notes[$0].start, $0) < (melody.notes[$1].start, $1) }
        var note = 0
        for l in copy.lines.indices {
            for s in copy.lines[l].syllables.indices {
                copy.lines[l].syllables[s].noteIndex = note < order.count ? order[note] : nil
                note += 1
            }
        }
        return copy
    }

    /// The words with no melody under them.
    public func unaligned() -> Lyric {
        var copy = self
        copy.alignedTo = nil
        for l in copy.lines.indices {
            for s in copy.lines[l].syllables.indices { copy.lines[l].syllables[s].noteIndex = nil }
        }
        return copy
    }

    /// Sung syllables, and how many of them have a note.
    public var syllableCount: Int { lines.reduce(0) { $0 + $1.syllables.count } }
    public var setSyllableCount: Int { lines.reduce(0) { $0 + $1.syllables.count { $0.noteIndex != nil } } }
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
    public static let cowbell = DrumVoice("cowbell")
    // Hand percussion.
    public static let shaker = DrumVoice("shaker")
    public static let tambourine = DrumVoice("tambourine")
    public static let highConga = DrumVoice("highConga")
    public static let lowConga = DrumVoice("lowConga")
    public static let highBongo = DrumVoice("highBongo")
    public static let lowBongo = DrumVoice("lowBongo")
    public static let claves = DrumVoice("claves")
    public static let woodblock = DrumVoice("woodblock")
    /// Unnamed percussion: what MIDI import makes of a note it has no voice for, and what feels
    /// wrote before the hand-percussion voices existed. Kits play it on their shaker.
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

/// The feel a groove was written from, and the seed its humanizing plays with.
///
/// A feel's velocities, per-voice pocket and jitter are render options, not steps, so a groove that
/// kept only its steps played every feel on the grid. This is the name to look the feel up by
/// again, and a seed of the groove's own: two songs on the same feel breathe differently, and one
/// song plays the same way every time it is opened.
public struct GrooveFeel: Hashable, Codable, Sendable {
    public var name: String
    public var seed: UInt64

    public init(name: String, seed: UInt64) {
        self.name = name
        self.seed = seed
    }

    /// A seed nobody chose. Kept under 2^53 so it survives any JSON reader as an exact integer.
    public static func freshSeed() -> UInt64 { UInt64.random(in: 1...(1 << 53)) }
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
    /// The feel it plays in. Nil plays the steps as written, on the grid.
    public var feel: GrooveFeel?

    public init(stepsPerBar: Int = 16, bars: Int = 1, swing: Double = 0, patterns: [GroovePattern],
                degradation: [Degradation] = [], feel: GrooveFeel? = nil) {
        self.stepsPerBar = stepsPerBar
        self.bars = bars
        self.swing = swing
        self.patterns = patterns
        self.degradation = degradation
        self.feel = feel
    }

    public var stepCount: Int { stepsPerBar * bars }

    /// The groove as it plays for `bars` bars: its steps repeated from its own start, the last
    /// pass cut at the bar line. Same steps per bar, same swing, same chain — the pattern the
    /// transport loops, written out.
    ///
    /// What a line longer than its groove is read against. A four-bar bass phrase over a one-bar
    /// kick is four bars of that kick; the writer, the Bassist and the lane under the Piano roll
    /// all need the kick to be there in bar four, not only in bar one. Asked for fewer bars than
    /// it has, it is the first `bars` of itself.
    public func tiled(toBars bars: Int) -> Groove {
        let target = max(1, bars)
        guard target != self.bars else { return self }
        let cycle = max(1, stepCount)
        let count = stepsPerBar * target
        let tiledPatterns = patterns.map { pattern in
            // A pattern shorter than the groove is silent past its end, as the player plays it.
            GroovePattern(voice: pattern.voice, steps: (0..<count).map { index in
                let step = index % cycle
                return step < pattern.steps.count ? pattern.steps[step] : .rest
            })
        }
        return Groove(stepsPerBar: stepsPerBar, bars: target, swing: swing, patterns: tiledPatterns,
                      degradation: degradation, feel: feel)
    }
}

extension Groove: Codable {
    private enum CodingKeys: String, CodingKey { case stepsPerBar, bars, swing, patterns, degradation, feel }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(stepsPerBar: try c.decode(Int.self, forKey: .stepsPerBar),
                  bars: try c.decode(Int.self, forKey: .bars),
                  swing: try c.decode(Double.self, forKey: .swing),
                  patterns: try c.decode([GroovePattern].self, forKey: .patterns),
                  degradation: try c.decodeIfPresent([Degradation].self, forKey: .degradation) ?? [],
                  feel: try c.decodeIfPresent(GrooveFeel.self, forKey: .feel))
    }

    /// A dry groove writes exactly what it always wrote: `degradation` is omitted when empty and
    /// `feel` when nil, so documents from before either existed round-trip byte for byte.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(stepsPerBar, forKey: .stepsPerBar)
        try c.encode(bars, forKey: .bars)
        try c.encode(swing, forKey: .swing)
        try c.encode(patterns, forKey: .patterns)
        if !degradation.isEmpty { try c.encode(degradation, forKey: .degradation) }
        try c.encodeIfPresent(feel, forKey: .feel)
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

/// How one pad of a chop plays its slice: tuned, louder or quieter, reversed, stretched. Keyed by
/// the slice's index in marker order, the same way a marker's label carries its class.
public struct PadTrim: Hashable, Codable, Sendable {
    public var slice: Int
    /// Pitch offset in cents.
    public var tuneCents: Double
    public var gainDB: Double
    public var reverse: Bool
    /// Output duration over input duration. Nil plays the slice at its natural length.
    public var stretchRatio: Double?

    public init(slice: Int, tuneCents: Double = 0, gainDB: Double = 0, reverse: Bool = false,
                stretchRatio: Double? = nil) {
        self.slice = slice
        self.tuneCents = tuneCents
        self.gainDB = gainDB
        self.reverse = reverse
        self.stretchRatio = stretchRatio
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
    /// The key the record was in where this chop was cut, when the analysis said. What a merge
    /// reads to decide how far to move it.
    public var key: Key?
    /// The span of the media this chop covers, in the media's own seconds, when the media is not a
    /// bar of an analysed record — a merged render, which *is* the bar. Nil means "find the bar
    /// from the slices and the analysis", as every chop cut from a record does.
    public var span: TimeRange?
    /// The pads' trims, one per slice that has any, in slice order. Empty plays every slice as it
    /// was cut.
    public var pads: [PadTrim]
    /// The level the chop is played at, in dB over its media's own: its loop, its pads and a
    /// groove on its slices alike. Set when a quiet bar is cut, so the chop sits where an
    /// instrument does and nothing downstream has to make it up. Nil plays it as recorded.
    public var gainDB: Double?
    /// How these bars of another record were fitted to the song, when they were pulled in from one
    /// (`SourceFit`). Nil for a chop cut here.
    public var fit: SourceFit?

    public init(media: MediaRef, slices: [SliceMarker] = [], rootPitch: Pitch? = nil, detectedTempo: Double? = nil,
                sourceRecord: RecordID? = nil, degradation: [Degradation] = [], key: Key? = nil, span: TimeRange? = nil,
                pads: [PadTrim] = [], gainDB: Double? = nil, fit: SourceFit? = nil) {
        self.media = media
        self.slices = slices
        self.rootPitch = rootPitch
        self.detectedTempo = detectedTempo
        self.sourceRecord = sourceRecord
        self.degradation = degradation
        self.key = key
        self.span = span
        self.pads = pads
        self.gainDB = gainDB
        self.fit = fit
    }
}

extension Sample: Codable {
    private enum CodingKeys: String, CodingKey { case media, slices, rootPitch, detectedTempo, sourceRecord, degradation, key, span, pads, gainDB, fit }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(media: try c.decode(MediaRef.self, forKey: .media),
                  slices: try c.decode([SliceMarker].self, forKey: .slices),
                  rootPitch: try c.decodeIfPresent(Pitch.self, forKey: .rootPitch),
                  detectedTempo: try c.decodeIfPresent(Double.self, forKey: .detectedTempo),
                  sourceRecord: try c.decodeIfPresent(RecordID.self, forKey: .sourceRecord),
                  degradation: try c.decodeIfPresent([Degradation].self, forKey: .degradation) ?? [],
                  key: try c.decodeIfPresent(Key.self, forKey: .key),
                  span: try c.decodeIfPresent(TimeRange.self, forKey: .span),
                  pads: try c.decodeIfPresent([PadTrim].self, forKey: .pads) ?? [],
                  gainDB: try c.decodeIfPresent(Double.self, forKey: .gainDB),
                  fit: try c.decodeIfPresent(SourceFit.self, forKey: .fit))
    }

    /// A dry sample writes exactly what it always wrote; see `Groove.encode(to:)`. `key` and
    /// `span` are omitted when nil for the same reason, `pads` when there are none, and `gainDB`
    /// when the chop plays as recorded. `fit` only for bars pulled in from another record.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(media, forKey: .media)
        try c.encode(slices, forKey: .slices)
        try c.encodeIfPresent(rootPitch, forKey: .rootPitch)
        try c.encodeIfPresent(detectedTempo, forKey: .detectedTempo)
        try c.encodeIfPresent(sourceRecord, forKey: .sourceRecord)
        if !degradation.isEmpty { try c.encode(degradation, forKey: .degradation) }
        try c.encodeIfPresent(key, forKey: .key)
        try c.encodeIfPresent(span, forKey: .span)
        if !pads.isEmpty { try c.encode(pads, forKey: .pads) }
        try c.encodeIfPresent(gainDB, forKey: .gainDB)
        try c.encodeIfPresent(fit, forKey: .fit)
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
    /// How a take was recorded, when `role` is `.take` and it was recorded here (M5). Nil for a
    /// take imported from elsewhere, and for every version written before M5.
    public var take: Take?
    /// The plan a comp was rendered from, when this audio is a comp of takes (M5).
    public var comp: CompPlan?
    /// The record this audio was taken from when it came out of another song — a mashup's stems —
    /// so the album's clearances can name it. Nil for audio made here.
    public var sourceRecord: RecordID?
    /// How this stem of another record was fitted to the song, when it was pulled in from one
    /// (`SourceFit`). Nil for audio made or separated here, and for a mashup's stems.
    public var fit: SourceFit?

    public init(media: MediaRef, role: AudioRole, stem: String? = nil, sampleRate: Double, channelCount: Int, duration: Double,
                alignmentOffset: Double? = nil, take: Take? = nil, comp: CompPlan? = nil, sourceRecord: RecordID? = nil,
                fit: SourceFit? = nil) {
        self.media = media
        self.role = role
        self.stem = stem
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.duration = duration
        self.alignmentOffset = alignmentOffset
        self.take = take
        self.comp = comp
        self.sourceRecord = sourceRecord
        self.fit = fit
    }
}

/// How a stem, or a few bars, of another record were fitted to a song: what was read and what was
/// done to it.
///
/// The fitted audio is a render — moved to the song's key, stretched to its tempo, levelled — and a
/// render cannot be moved again without moving it twice. So the fit keeps the untouched source and
/// the numbers, and a re-pitch or a re-time renders the next version from the source, not from the
/// last render. The source media is another package's (`song`), or the library's records, and is
/// not one of this version's media references: it is read, never held.
public struct SourceFit: Hashable, Codable, Sendable {
    /// What the source is called where it is read: the song or record it came from.
    public var label: String
    /// The untouched audio the fit reads: a stem as it was separated, or the record.
    public var media: MediaRef
    /// The library song whose package holds `media`, when it is a song's.
    public var song: SongID?
    /// The record on the library's shelf whose stem or mix `media` is, when it came from there
    /// rather than from a song.
    public var record: RecordID?
    /// "vocals", "drums", "bass", "other", or "record" for the full mix.
    public var stem: String
    /// The source second the fit is anchored on: a whole stem's first downbeat, a clip's first bar.
    public var start: Double
    /// Where a clip ends in the source's seconds. Nil for a whole stem, which runs to its end.
    public var end: Double?
    /// A clip's bars of the source, 0-based from its first, the end not included. Nil for a whole stem.
    public var fromBar: Int?
    public var toBar: Int?
    /// The song bar, 0-based, a whole stem's first bar lands on. Nil for a clip, which loops in
    /// each section that plays it.
    public var atBar: Int?
    /// Semitones the source was moved, and whether by ear rather than by the key arithmetic.
    public var semitones: Int
    public var byEar: Bool
    /// Output over input duration: one constant stretch, or a clip fitted to whole bars.
    public var ratio: Double
    /// Each bar stretched onto a bar of the song rather than one ratio for all. False until a
    /// source is tightened.
    public var tightened: Bool
    /// The source's key and tempo as read when it was fitted, so a re-fit moves from the same place.
    public var key: Key?
    public var tempo: Double?
    /// The record's integrated loudness, and the gain given to it so two records sit together: in
    /// the render, the same for every stem and every clip of one record. Nil when the record's
    /// loudness was never read.
    public var recordLUFS: Double?
    public var gainDB: Double?

    public init(label: String, media: MediaRef, song: SongID? = nil, stem: String, start: Double, end: Double? = nil,
                fromBar: Int? = nil, toBar: Int? = nil, atBar: Int? = nil, semitones: Int = 0, byEar: Bool = false,
                ratio: Double = 1, tightened: Bool = false, key: Key? = nil, tempo: Double? = nil,
                recordLUFS: Double? = nil, gainDB: Double? = nil, record: RecordID? = nil) {
        self.label = label
        self.media = media
        self.song = song
        self.record = record
        self.stem = stem
        self.start = start
        self.end = end
        self.fromBar = fromBar
        self.toBar = toBar
        self.atBar = atBar
        self.semitones = semitones
        self.byEar = byEar
        self.ratio = ratio
        self.tightened = tightened
        self.key = key
        self.tempo = tempo
        self.recordLUFS = recordLUFS
        self.gainDB = gainDB
    }

    /// Whether this is a few bars that loop, rather than a stem that runs along the song.
    public var isClip: Bool { end != nil }
}

/// Where and how a take was recorded: the section it was sung to, the bar and beat the transport
/// was at when the first frame landed, the input it came from, and the latency the recorder
/// folded into the alignment.
public struct Take: Hashable, Codable, Sendable {
    public var section: SectionID?
    /// The song bar (0-based) and beat within it where the take's first frame sits, after latency.
    public var startBar: Int
    public var startBeat: Double
    /// The input device's name, when known.
    public var input: String?
    /// Input plus output latency the recorder compensated for, seconds.
    public var latencyCompensation: Double
    /// Which pass of the section this was: 1 for the first take, 2 for the second…
    public var pass: Int
    /// The bar `section` started on when the take was sung. The take is placed in bars of the song
    /// as it was then; a section moved since — a verse before it lengthened, an intro added — moves
    /// the take with it (`Audio.barsMoved`). Nil for a take from before this was kept.
    public var sectionStartBar: Int?
    /// The song's tempo when the take was sung. A song whose tempo has changed since plays the take
    /// stretched to the tempo it has now, its pitch kept (`Audio.stretch(in:)`). Nil for a take from
    /// before this was kept, which plays as it was sung.
    public var tempo: Double?
    /// The song's meter when the take was sung: its bars are bars of this. A meter changed since
    /// places the take by beats from its section's start, not by the seconds of the old bars.
    public var meter: TimeSignature?

    public init(section: SectionID? = nil, startBar: Int, startBeat: Double = 0, input: String? = nil,
                latencyCompensation: Double = 0, pass: Int = 1, sectionStartBar: Int? = nil, tempo: Double? = nil,
                meter: TimeSignature? = nil) {
        self.section = section
        self.startBar = startBar
        self.startBeat = startBeat
        self.input = input
        self.latencyCompensation = latencyCompensation
        self.pass = pass
        self.sectionStartBar = sectionStartBar
        self.tempo = tempo
        self.meter = meter
    }
}

/// A comp: which take each span of bars comes from, in order. Rendered into one audio version
/// whose parents are every take named here.
public struct CompPlan: Hashable, Codable, Sendable {
    public struct Span: Hashable, Codable, Sendable {
        /// Song bars, 0-based, `endBar` exclusive.
        public var startBar: Int
        public var endBar: Int
        public var take: VersionID
        public init(startBar: Int, endBar: Int, take: VersionID) {
            self.startBar = startBar
            self.endBar = max(startBar + 1, endBar)
            self.take = take
        }
    }
    public var spans: [Span]
    /// Seconds of equal-power crossfade at every seam.
    public var crossfade: Double
    /// The section the takes were sung to, and the bar it started on when the comp was made: a
    /// comp moves with its section, as a take does (`Take.sectionStartBar`).
    public var section: SectionID?
    public var sectionStartBar: Int?
    /// The song's tempo when the comp was rendered: a comp follows a tempo change as a take does
    /// (`Take.tempo`).
    public var tempo: Double?
    /// The song's meter when the comp was rendered (`Take.meter`).
    public var meter: TimeSignature?

    public init(spans: [Span], crossfade: Double = 0.01, section: SectionID? = nil, sectionStartBar: Int? = nil,
                tempo: Double? = nil, meter: TimeSignature? = nil) {
        self.spans = spans.sorted { $0.startBar < $1.startBar }
        self.crossfade = crossfade
        self.section = section
        self.sectionStartBar = sectionStartBar
        self.tempo = tempo
        self.meter = meter
    }

    public var takes: [VersionID] {
        var seen: [VersionID] = []
        for span in spans where !seen.contains(span.take) { seen.append(span.take) }
        return seen
    }
}

extension Audio {
    /// How many bars the section this was sung to has moved since it was sung: where the section
    /// starts in `song` now, less where it started then. 0 when either is not known.
    public func barsMoved(in song: Song) -> Int {
        let section = take?.section ?? comp?.section
        let then = take?.sectionStartBar ?? comp?.sectionStartBar
        guard let section, let then, let now = song.startBar(of: section) else { return 0 }
        return now - then
    }

    /// How much longer the audio plays in `song` than it was sung: the tempo it was sung at over
    /// the song's tempo now — 100 bpm after 92 plays it at 0.92 of its length. 1 when the tempo
    /// has not changed, or when the audio does not say what it was sung at.
    public func stretch(in song: Song) -> Double {
        guard let sung = take?.tempo ?? comp?.tempo, sung > 0, song.tempo > 0 else { return 1 }
        let ratio = sung / song.tempo
        return abs(ratio - 1) < 0.0001 ? 1 : ratio
    }
}

extension Song {
    /// The bar a section starts on, 0-based: the sections before it laid end to end.
    public func startBar(of section: SectionID) -> Int? {
        var bar = 0
        for candidate in sections {
            if candidate.id == section { return bar }
            bar += max(1, candidate.lengthInBars)
        }
        return nil
    }
}

// MARK: - Sound

/// A sound preset: an instrument or chain identifier plus parameter values.
public struct Sound: Hashable, Sendable {
    /// Instrument or chain identifier, e.g. "synth.sub", "sampler", "chain.lofi-tape".
    public var instrument: String
    public var preset: String?
    public var parameters: [String: Double]
    /// The part this sound is for, when it is a part's own rather than the song's. Nil is the
    /// song's default: what every part that names none plays on.
    ///
    /// A song used to have exactly one pitched instrument, found by scanning its versions backwards
    /// for the newest `.sound`, so a pad playing the chords and a lead playing the tune could not
    /// sound together — the app said as much in its own part notes, which read "for the chords and
    /// the tune" because there was one slot for both.
    ///
    /// It lives here rather than on the stitch because a sound is a decision about a *part*, and
    /// this payload is already versioned: picking an instrument goes through `AppState.record`,
    /// shows in the ledger with its provenance, and is undone by recording a newer one. A stitch is
    /// edited in place and versions nothing, so the same choice there would be un-undoable and
    /// would have to be repeated in every section the part plays in.
    public var forPart: PartID?

    public init(instrument: String, preset: String? = nil, parameters: [String: Double] = [:],
                forPart: PartID? = nil) {
        self.instrument = instrument
        self.preset = preset
        self.parameters = parameters
        self.forPart = forPart
    }
}

extension Sound: Codable {
    private enum CodingKeys: String, CodingKey { case instrument, preset, parameters, forPart }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(instrument: try c.decode(String.self, forKey: .instrument),
                  preset: try c.decodeIfPresent(String.self, forKey: .preset),
                  parameters: try c.decodeIfPresent([String: Double].self, forKey: .parameters) ?? [:],
                  forPart: try c.decodeIfPresent(PartID.self, forKey: .forPart))
    }

    /// `forPart` is omitted when nil, so every sound written before parts could name one round-trips
    /// byte for byte and the document needs no schema bump to carry this.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(instrument, forKey: .instrument)
        try c.encodeIfPresent(preset, forKey: .preset)
        try c.encode(parameters, forKey: .parameters)
        try c.encodeIfPresent(forPart, forKey: .forPart)
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
    /// A second beat tracker's check of `beats`. Nil in analyses made before there was one.
    public var beatCheck: BeatGridCheck?

    public init(duration: Double, keys: [KeyRange] = [], beats: [BeatMarker] = [], bars: [TimeRange] = [],
                tempo: [TempoRange] = [], sections: [SectionRange] = [], instruments: [InstrumentActivity] = [],
                loudness: Loudness? = nil, analyzer: String? = nil, beatCheck: BeatGridCheck? = nil) {
        self.duration = duration
        self.keys = keys
        self.beats = beats
        self.bars = bars
        self.tempo = tempo
        self.sections = sections
        self.instruments = instruments
        self.loudness = loudness
        self.analyzer = analyzer
        self.beatCheck = beatCheck
    }

    /// The key holding for the longest time, if any.
    public var dominantKey: Key? { keys.max { $0.range.duration < $1.range.duration }?.key }

    /// The key the record is in at `seconds`, or the dominant key when no range covers it.
    public func key(at seconds: Double) -> Key? {
        keys.first { $0.start <= seconds && seconds < $0.end }?.key ?? dominantKey
    }

    /// The tempo holding for the longest time, if any.
    public var dominantTempo: Double? { tempo.max { ($0.end - $0.start) < ($1.end - $1.start) }?.bpm }

    /// Downbeat times.
    public var downbeats: [Double] { beats.filter(\.isDownbeat).map(\.time) }
}

/// What a second beat tracker made of an analysis's beat grid, kept with it: whether the two
/// agreed, or whether the grid is the second one's because the first found none.
public struct BeatGridCheck: Hashable, Codable, Sendable {
    /// The tracker that checked the grid, or stood in for it.
    public var checker: String
    /// The share of beats the two trackers placed within 70 ms of each other (an F-measure, 0…1).
    /// Nil when the checker stood in.
    public var agreement: Double?
    public var primaryBPM: Double?
    public var checkerBPM: Double?
    /// Whether the grid is the checker's.
    public var usedChecker: Bool

    public init(checker: String, agreement: Double?, primaryBPM: Double?, checkerBPM: Double?, usedChecker: Bool) {
        self.checker = checker
        self.agreement = agreement
        self.primaryBPM = primaryBPM
        self.checkerBPM = checkerBPM
        self.usedChecker = usedChecker
    }
}

// MARK: - Part kind

/// The kind of a part, as a plain name. Also the JSON discriminator for `PartKind`.
public enum PartType: String, Codable, Sendable, Hashable, CaseIterable {
    case progression, melody, lyric, groove, bassline, sample, audio, sound, analysis
    /// M6: the mix — strips, master, section gains.
    case mix
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
    case mix(Mix)

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
        case .mix: return .mix
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
        case .mix: self = .mix(try Mix(from: decoder))
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
        case .mix(let payload): try payload.encode(to: encoder)
        }
    }
}
