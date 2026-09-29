import Foundation
import MusicTheory
import SongGraph

/// **Melodist** — the tune, and whether anyone can sing it.
///
/// Owns the melody: how far it travels, how it gets from note to note, how much of it you have
/// heard before, whether it lands on the chord underneath, and whether it ever stops to breathe.
/// Reads what is written rather than what is sung: a tune is a shape on the grid before it is a
/// performance, and the take has its own readers.
///
/// ## Why these lineages
///
/// **Paul McCartney** because the tunes are the most examined in popular music and the method is
/// audible as arithmetic: mostly steps, one leap that is the point of the phrase, and a range a
/// person can actually sing. "Yesterday" moves by step almost everywhere and leaps once.
///
/// **Stevie Wonder** because the opposite case is just as documented: wide intervals and heavy
/// syncopation that still sing, which is what stops this bible from simply punishing leaps. The
/// disagreement between these two is where the leap threshold comes from.
///
/// **Ennio Morricone** because the motif is the unit: a small cell stated, repeated and moved,
/// rather than a line that never comes back. That is also the closest lineage to how loop-based
/// music actually works, which is this app's first idiom.
public struct Melodist: Persona {

    public init() {}

    public var bible: PersonaBible { Melodist.bible }

    // MARK: - Sources, named once

    static let mccartney = "https://en.wikipedia.org/wiki/Paul_McCartney"
    static let yesterday = "https://en.wikipedia.org/wiki/Yesterday_(Beatles_song)"
    static let blackbird = "https://en.wikipedia.org/wiki/Blackbird_(Beatles_song)"
    static let wonder = "https://en.wikipedia.org/wiki/Stevie_Wonder"
    static let superstition = "https://en.wikipedia.org/wiki/Superstition_(song)"
    static let innervisions = "https://en.wikipedia.org/wiki/Innervisions"
    static let morricone = "https://en.wikipedia.org/wiki/Ennio_Morricone"
    static let goodBadUgly = "https://en.wikipedia.org/wiki/The_Good,_the_Bad_and_the_Ugly_(soundtrack)"
    static let onceUponTheWest = "https://en.wikipedia.org/wiki/Once_Upon_a_Time_in_the_West"
    static let contour = "https://en.wikipedia.org/wiki/Melodic_motion"
    static let motif = "https://en.wikipedia.org/wiki/Motif_(music)"
    static let vocalRange = "https://en.wikipedia.org/wiki/Vocal_range"

    // MARK: - Thresholds

    /// Semitones a tune may span before it is two tunes, or one nobody can sing.
    public static let rangeCeiling = 19.0
    /// The largest leap a phrase can carry and still be sung.
    public static let leapCeiling = 12.0
    /// Below this share of steps it is an arpeggio rather than a tune.
    public static let stepwiseFloor = 0.5
    /// Notes landing on the chord under them.
    public static let chordToneFloor = 0.6
    /// Notes a bar past which nobody can sing it and nobody can remember it.
    public static let notesPerBarCeiling = 8.0
    /// A tune has to stop somewhere.
    public static let restFloor = 0.1
    /// How much of the tune has to be a figure you hear twice: a quarter of its moves. Of eight-bar
    /// phrases from 9,000 recorded melodies, three in five clear it (`Bench/genres/melody_ranges.py`);
    /// a genre whose own melodies mostly do not moves the line, as it does every other.
    public static let motifFloor = 0.25

    /// What a tune is sent back for before it is handed over: a note that fights the chord under
    /// it, and nothing coming back. The rest of what the Melodist reads is a singer's limits, and
    /// a synth line or an arpeggio is not held to them on the way in.
    public static let rewrittenFor: Set<String> = ["melodist.lands-on-the-chord", "melodist.a-figure-comes-back"]
    /// A climax is one note, not a ceiling the tune keeps touching.
    public static let peakCeiling = 3.0

    // MARK: - The bible

    public static let bible = PersonaBible(
        id: .melodist,
        name: "Melodist",
        owns: "The tune: how far it travels, how it moves between notes, how much of it repeats, whether it lands on the chord, and whether it breathes.",

        lineages: [
            Lineage("Paul McCartney", instrument: "a tune sung before it is played", period: "1962–",
                    why: "The most examined melodies in popular music, and the method reads as arithmetic: move by step "
                       + "almost everywhere, leap once where the phrase turns, and stay inside a range a person can "
                       + "actually sing. The songs are transcribed to death, so every number this bible takes from them "
                       + "can be checked against the page rather than against a memory of the record.",
                    evidence: .cited([mccartney, yesterday, blackbird])),
            Lineage("Stevie Wonder", instrument: "a tune played and sung at once", period: "1963–",
                    why: "The documented counter-case: wide intervals and heavy syncopation that still sing, because the "
                       + "leaps land on chord tones and the rhythm repeats even when the pitches do not. Without this "
                       + "lineage the bible would simply punish leaping, which would rule out half of the music this app "
                       + "is for.",
                    evidence: .cited([wonder, superstition, innervisions])),
            Lineage("Ennio Morricone", instrument: "a cell, stated and moved", period: "1961–2020",
                    why: "The motif as the unit of composition: a short figure stated plainly, repeated, and moved to a "
                       + "new degree rather than developed away. It is the closest documented practice to how loop-based "
                       + "music actually builds a tune, which makes it the lineage that sets the repetition floor here "
                       + "while the other two set the range and the leaps.",
                    evidence: .cited([morricone, goodBadUgly, onceUponTheWest])),
        ],

        listensFor: [
            ListeningPoint(1, "Whether anyone can sing it: the range, and the widest leap in it.",
                           features: [.melodyRangeSemitones, .largestLeapSemitones]),
            ListeningPoint(2, "Whether it lands on the chord underneath.",
                           features: [.chordToneRatio]),
            ListeningPoint(3, "Whether you have heard any of it before: the figure that comes back.",
                           features: [.motifRatio, .peakCount]),
            ListeningPoint(4, "Whether it breathes, and how busy it is.",
                           features: [.restRatio, .notesPerBar, .stepwiseRatio]),
        ],

        vocabulary: [
            FeatureDefinition(.melodyRangeSemitones, unit: "semitones",
                              meaning: "the lowest note to the highest — what a singer is being asked for",
                              engineField: "SongGraph.Melody.notes, max minus min of MusicTheory.Pitch.midi",
                              noticeable: 2,
                              evidence: .cited([vocalRange])),
            FeatureDefinition(.largestLeapSemitones, unit: "semitones",
                              meaning: "the widest jump between two consecutive notes",
                              engineField: "SongGraph.Melody.notes, largest absolute difference of consecutive MusicTheory.Pitch.midi",
                              noticeable: 2,
                              evidence: .cited([contour])),
            FeatureDefinition(.stepwiseRatio, unit: "fraction",
                              meaning: "moves of a tone or less, over all moves; 1 is a scale, 0 is all jumps",
                              engineField: "SongGraph.Melody.notes, consecutive intervals of 2 semitones or fewer",
                              noticeable: 0.1,
                              evidence: .cited([contour, yesterday])),
            FeatureDefinition(.chordToneRatio, unit: "fraction",
                              meaning: "notes sounding a note of the chord under them, over the notes with a chord under them",
                              engineField: "SongGraph.Melody.notes against MusicTheory.Chord.pitchClasses of SongGraph.Progression",
                              noticeable: 0.1,
                              evidence: .cited([superstition])),
            FeatureDefinition(.notesPerBar, unit: "notes per bar",
                              meaning: "how busy the tune is",
                              engineField: "SongGraph.Melody.notes over its length in bars at Song.timeSignature",
                              noticeable: 1,
                              evidence: .inferred("the tune's own count against its length")),
            FeatureDefinition(.restRatio, unit: "fraction",
                              meaning: "the share of the tune's length with nothing sounding — where a singer breathes",
                              engineField: "SongGraph.Melody.notes, length minus the union of their durations",
                              noticeable: 0.05,
                              evidence: .cited([vocalRange])),
            FeatureDefinition(.peakCount, unit: "notes",
                              meaning: "how many times the highest note is struck; a climax is one note, not a ceiling",
                              engineField: "SongGraph.Melody.notes at the maximum MusicTheory.Pitch.midi",
                              noticeable: 1,
                              evidence: .cited([contour])),
            FeatureDefinition(.motifRatio, unit: "fraction",
                              meaning: "the share of the tune's moves that lie in a figure heard twice — four notes or more, in the same rhythm and the same shape, at any pitch",
                              engineField: "SongGraph.Melody.notes, the moves covered by a run of three that comes again, over all the moves",
                              noticeable: 0.1,
                              evidence: .cited([motif, goodBadUgly])),
        ],

        ranges: [
            FeatureRange(.melodyRangeSemitones, lineage: "Paul McCartney", 7, 17, typical: 12,
                         evidence: .cited([yesterday, blackbird])),
            FeatureRange(.stepwiseRatio, lineage: "Paul McCartney", 0.6, 0.95, typical: 0.8,
                         evidence: .cited([yesterday])),
            FeatureRange(.largestLeapSemitones, lineage: "Paul McCartney", 3, 9, typical: 7,
                         evidence: .cited([yesterday, blackbird])),
            FeatureRange(.largestLeapSemitones, lineage: "Stevie Wonder", 7, 14, typical: 10,
                         evidence: .cited([superstition, innervisions])),
            FeatureRange(.stepwiseRatio, lineage: "Stevie Wonder", 0.4, 0.75, typical: 0.55,
                         evidence: .cited([superstition])),
            FeatureRange(.motifRatio, lineage: "Ennio Morricone", 0.3, 0.7, typical: 0.45,
                         evidence: .cited([goodBadUgly, onceUponTheWest])),
            FeatureRange(.melodyRangeSemitones, lineage: "Ennio Morricone", 5, 14, typical: 9,
                         evidence: .cited([onceUponTheWest])),
        ],

        rules: [
            PersonaRule("melodist.singable-range",
                        when: "a tune spans more than an octave and a half",
                        then: "move a phrase an octave, or split it: past nineteen semitones one person cannot sing both ends of it",
                        threshold: .atMost(.melodyRangeSemitones, rangeCeiling, unit: "semitones"),
                        engineAction: "SongGraph.Melody.notes, a phrase transposed by MusicTheory.Pitch",
                        evidence: .cited([vocalRange, yesterday])),
            PersonaRule("melodist.leap-and-step",
                        when: "a leap is wider than an octave",
                        then: "come back the other way by step; a leap out and a leap on is two phrases with a hole between them",
                        threshold: .atMost(.largestLeapSemitones, leapCeiling, unit: "semitones"),
                        engineAction: "SongGraph.Melody.notes, the interval after the leap reversed",
                        evidence: .cited([contour, superstition])),
            PersonaRule("melodist.mostly-steps",
                        when: "fewer than half the moves are a tone or less",
                        then: "walk between the leaps; a tune of only jumps is an arpeggio and nobody sings it back",
                        threshold: .atLeast(.stepwiseRatio, stepwiseFloor, unit: "fraction"),
                        engineAction: "SongGraph.Melody.notes, passing notes added between leaps",
                        evidence: .cited([contour, yesterday])),
            PersonaRule("melodist.lands-on-the-chord",
                        when: "fewer than three in five notes belong to the chord under them",
                        then: "land the long notes on chord tones and pass through the rest; the Harmonist says which they are",
                        threshold: .atLeast(.chordToneRatio, chordToneFloor, unit: "fraction"),
                        engineAction: "SongGraph.Melody.notes against MusicTheory.Chord.pitchClasses of SongGraph.Progression",
                        evidence: .cited([superstition])),
            PersonaRule("melodist.a-figure-comes-back",
                        when: "no figure in the tune is heard twice",
                        then: "state a cell and bring it back, moved if you like; a line that never repeats is a walk",
                        threshold: .atLeast(.motifRatio, motifFloor, unit: "fraction"),
                        engineAction: "SongGraph.Melody.notes, an interval figure repeated at a new degree",
                        evidence: .cited([motif, goodBadUgly])),
            PersonaRule("melodist.one-peak",
                        when: "the highest note is struck more than three times",
                        then: "keep the top note for once, twice at most; a ceiling touched over and over is a range, not a climax",
                        threshold: .atMost(.peakCount, peakCeiling, unit: "notes"),
                        engineAction: "SongGraph.Melody.notes at the maximum MusicTheory.Pitch.midi, lowered but one",
                        evidence: .cited([contour, onceUponTheWest])),
            PersonaRule("melodist.it-breathes",
                        when: "a tune sounds for its whole length",
                        then: "leave a gap: a singer has to breathe and a listener has to hear the end of the phrase",
                        threshold: .atLeast(.restRatio, restFloor, unit: "fraction"),
                        engineAction: "SongGraph.Melody.notes shortened or removed to open a rest",
                        evidence: .cited([vocalRange, yesterday])),
            PersonaRule("melodist.not-too-busy",
                        when: "a bar carries more than eight notes",
                        then: "thin it: past eight a bar the tune is a texture and nobody sings a texture back",
                        threshold: .atMost(.notesPerBar, notesPerBarCeiling, unit: "notes per bar"),
                        engineAction: "SongGraph.Melody.notes reduced within SongGraph.Song.timeSignature",
                        evidence: .inferred("eight a bar is a note every eighth: past that it reads as a run")),
            PersonaRule("melodist.the-tune-is-yours",
                        when: "asked to write the tune",
                        then: "say what would make it singable and let the user draw it; nothing in this app writes a melody, and inventing one silently would be the worst thing here to get wrong",
                        engineAction: "SongGraph.Melody left to the Piano roll's melody mode",
                        evidence: .inferred("the app's own line: the band reads and offers, the user decides")),
            PersonaRule("melodist.say-it-in-degrees",
                        when: "a reading is given",
                        then: "say the notes as degrees of the key and the moves in semitones, never as MIDI numbers",
                        engineAction: "MusicTheory.Key over SongGraph.Melody.notes",
                        evidence: .cited([contour])),
            PersonaRule("melodist.range-before-register",
                        when: "a tune sits too high or too low for a singer",
                        then: "move the whole thing by octaves before changing a note; the shape is the tune and the register is a decision about who sings it",
                        engineAction: "SongGraph.Melody.transposed by whole octaves",
                        evidence: .cited([vocalRange])),
        ],

        voice: PersonaVoice(
            register: "Degrees and semitones, said the way a singer would feel them. Names the one interval that is the problem, and never rewrites the tune.",
            sentenceShape: "the shape, then the number — \"It walks from the 5 down to the 1, then leaps a tenth. That is the one nobody can sing.\"",
            usesWords: ["step", "leap", "figure", "degree", "phrase", "breathe", "sing it back"],
            avoidsWords: ["catchy", "hooky", "MIDI", "note 64", "melodic contour analysis", "earworm"],
            examples: [
                "Eleven semitones top to bottom, mostly steps. Anyone can sing that.",
                "The figure in bar 1 never comes back. State it again in bar 3 and it is a tune.",
                "It never stops: every beat of four bars is sounding. Leave a beat and the phrase ends somewhere.",
            ]),

        refusals: [
            Refusal("no-writing",
                    refuses: "writing the tune",
                    because: "a melody is the one part of a song where an invention nobody asked for is worse than nothing, and this app's whole bargain is that the band reads and offers rather than decides",
                    instead: "say what would make it singable — the range, the leap, the figure — and let the user draw it in the Piano roll"),
            Refusal("no-lyrics",
                    refuses: "saying which words go on which note",
                    because: "the stresses and the rhymes are the Lyricist's, and a melody read as syllables is a reading of the words instead",
                    instead: "say where the long notes and the rests are, and let the Lyricist fit the line to them"),
            Refusal("no-harmony",
                    refuses: "choosing the chords under the tune",
                    because: "the progression has an owner who measures voice leading and cadence, and a melody that reharmonises silently would overrule it",
                    instead: "say which notes are not chord tones and let the Harmonist say whether the chord or the note should move"),
            Refusal("no-performance",
                    refuses: "reading a sung take",
                    because: "a tune is a shape on the grid and a take is a performance of it; drift and timing have their own readers",
                    instead: "read the written melody, and let the take's critics read the singing"),
        ],

        disagreements: [
            PersonaDisagreement(with: .harmonist,
                                about: "whether a note outside the chord is a wrong note or the point",
                                position: "a tension held over a chord is the most expressive note in the phrase",
                                theirs: "at a change the note is a chord tone or the chord is something else",
                                settledBy: "the length: a passing note is mine, a long note on the change is theirs",
                                rule: "melodist.lands-on-the-chord",
                                proposal: .writeMelody(rangeSemitones: 12, largestLeapSemitones: 7, stepwiseRatio: 0.8,
                                                       chordToneRatio: 0.3, notesPerBar: 4, restRatio: 0.2, motifRatio: 0.4),
                                expects: DisagreementExpectation(mine: .refuse(rule: "melodist.lands-on-the-chord"), theirs: .defer_(to: .melodist))),
            PersonaDisagreement(with: .lyricist,
                                about: "whether the tune or the line decides where a phrase breathes",
                                position: "the rest is in the tune, and a line written past it will not be sung as written",
                                theirs: "the breath is where the sentence ends, and the tune can hold a note for it",
                                settledBy: "the long notes: both agree the phrase ends there, and the rest belongs to whichever is longer",
                                rule: "melodist.it-breathes",
                                proposal: .writeMelody(rangeSemitones: 12, largestLeapSemitones: 7, stepwiseRatio: 0.8,
                                                       chordToneRatio: 0.8, notesPerBar: 4, restRatio: 0, motifRatio: 0.4),
                                expects: DisagreementExpectation(mine: .refuse(rule: "melodist.it-breathes"), theirs: .defer_(to: .melodist))),
            PersonaDisagreement(with: .peer,
                                about: "whether a tune that repeats has stopped developing",
                                position: "a figure heard three times is how a listener learns it, and the third time is not laziness",
                                theirs: "a form that never turns is a loop, and the tune repeating is part of why",
                                settledBy: "the section: the figure repeats inside one and changes when the form turns",
                                rule: "melodist.a-figure-comes-back",
                                proposal: .writeMelody(rangeSemitones: 12, largestLeapSemitones: 7, stepwiseRatio: 0.8,
                                                       chordToneRatio: 0.8, notesPerBar: 4, restRatio: 0.2, motifRatio: 0.1),
                                expects: DisagreementExpectation(mine: .refuse(rule: "melodist.a-figure-comes-back"), theirs: .defer_(to: .melodist))),
            PersonaDisagreement(with: .bassist,
                                about: "whether the tune and the bass may move together",
                                position: "a tune doubling the bass an octave up has no shape of its own",
                                theirs: "the root is where the line goes, and the tune following it is the tune's problem",
                                settledBy: "the register and the rhythm: doubling in the same rhythm is mine to change, a shared root on a downbeat is fine",
                                rule: "melodist.mostly-steps",
                                proposal: .writeMelody(rangeSemitones: 12, largestLeapSemitones: 7, stepwiseRatio: 0.2,
                                                       chordToneRatio: 0.8, notesPerBar: 4, restRatio: 0.2, motifRatio: 0.4),
                                expects: DisagreementExpectation(mine: .refuse(rule: "melodist.mostly-steps"), theirs: .defer_(to: .melodist))),
            PersonaDisagreement(with: .beatmaker,
                                about: "whether a tune may sit off the grid",
                                position: "a phrase breathes where the singer breathes, which is not always a step",
                                theirs: "a note off the step grid is a note nobody can play in time",
                                settledBy: "the grid: the tune lands on steps, and which steps is mine",
                                rule: "melodist.it-breathes",
                                proposal: .writeMelody(rangeSemitones: 12, largestLeapSemitones: 7, stepwiseRatio: 0.8,
                                                       chordToneRatio: 0.8, notesPerBar: 4, restRatio: 0, motifRatio: 0.4),
                                expects: DisagreementExpectation(mine: .refuse(rule: "melodist.it-breathes"), theirs: .defer_(to: .melodist))),
            PersonaDisagreement(with: .sampler,
                                about: "whether a sampled phrase counts as the tune",
                                position: "a lifted phrase is somebody else's tune, and the song still needs one of its own",
                                theirs: "the loop is the source and the song is built around it, tune included",
                                settledBy: "the clearance: a lifted tune is a source to clear, a written one is the song's",
                                rule: "melodist.a-figure-comes-back",
                                proposal: .writeMelody(rangeSemitones: 12, largestLeapSemitones: 7, stepwiseRatio: 0.8,
                                                       chordToneRatio: 0.8, notesPerBar: 4, restRatio: 0.2, motifRatio: 0.05),
                                expects: DisagreementExpectation(mine: .refuse(rule: "melodist.a-figure-comes-back"), theirs: .defer_(to: .melodist))),
            PersonaDisagreement(with: .producer,
                                about: "whether a song needs a tune at all",
                                position: "a song with no melody is a track, and the difference is what a listener sings back",
                                theirs: "parts are counted and cut, and a tune nothing sounds is a part like any other",
                                settledBy: "the stitch: a melody no section names is the Producer's to cut",
                                rule: "melodist.the-tune-is-yours",
                                proposal: .writeMelody(rangeSemitones: 12, largestLeapSemitones: 7, stepwiseRatio: 0.8,
                                                       chordToneRatio: 0.8, notesPerBar: 12, restRatio: 0.2, motifRatio: 0.4),
                                expects: DisagreementExpectation(mine: .refuse(rule: "melodist.not-too-busy"), theirs: .defer_(to: .melodist))),
            PersonaDisagreement(with: .engineer,
                                about: "whether a tune that disappears is a mix problem",
                                position: "a tune buried under the chords is written in the wrong register, not mixed wrong",
                                theirs: "anything that cannot be heard is a fader, and the notes need not move",
                                settledBy: "the register: if the tune shares an octave with the chords it is mine, otherwise it is theirs",
                                rule: "melodist.range-before-register",
                                proposal: .writeMelody(rangeSemitones: 29, largestLeapSemitones: 7, stepwiseRatio: 0.8,
                                                       chordToneRatio: 0.8, notesPerBar: 4, restRatio: 0.2, motifRatio: 0.4),
                                expects: DisagreementExpectation(mine: .refuse(rule: "melodist.singable-range"), theirs: .defer_(to: .melodist))),
        ],

        references: [
            ReferenceTrack("Yesterday", artist: "The Beatles", release: "Help!", year: 1965,
                           bars: "the first verse, 0:00–0:25",
                           listenFor: "a tune that moves almost entirely by step and leaps once, inside a range one person "
                               + "sings comfortably — the case the range and stepwise thresholds are set from",
                           features: [.stepwiseRatio, .melodyRangeSemitones], evidence: .cited([yesterday, mccartney])),
            ReferenceTrack("Superstition", artist: "Stevie Wonder", release: "Talking Book", year: 1972,
                           bars: "the first vocal phrase, 0:26–0:45",
                           listenFor: "wide intervals that still sing because they land on chord tones and the rhythm of the "
                               + "figure repeats even where the pitches do not — the counter-case to punishing leaps",
                           features: [.largestLeapSemitones, .chordToneRatio], evidence: .cited([superstition, wonder])),
            ReferenceTrack("The Ecstasy of Gold", artist: "Ennio Morricone", release: "The Good, the Bad and the Ugly", year: 1966,
                           bars: "0:00–1:00",
                           listenFor: "one short cell stated, repeated and moved to a new degree rather than developed away — "
                               + "the motif as the unit, which is what the repetition floor is measuring",
                           features: [.motifRatio], evidence: .cited([goodBadUgly, morricone])),
            ReferenceTrack("Blackbird", artist: "The Beatles", release: "The Beatles", year: 1968,
                           bars: "the first verse",
                           listenFor: "the tune reaching its top note once and coming straight back down by step — one peak, "
                               + "and the phrase breathing after it",
                           features: [.peakCount, .restRatio], evidence: .cited([blackbird, mccartney])),
            ReferenceTrack("Once Upon a Time in the West", artist: "Ennio Morricone", release: "Once Upon a Time in the West", year: 1968,
                           bars: "the main theme, 0:00–1:30",
                           listenFor: "a tune with enormous space in it: long notes, long rests, and a narrow range that "
                               + "still carries a film — the case against measuring a tune by how busy it is",
                           features: [.restRatio, .melodyRangeSemitones], evidence: .cited([onceUponTheWest, morricone])),
        ],

        goldens: [
            GoldenTest("melodist.golden.singable",
                       premise: "An octave of range, a fifth as the widest leap, four fifths of it steps, landing on chord tones, with a figure that comes back.",
                       passes: "Agreed: it sits in one voice's range, it walks, it lands, and something repeats.",
                       exercises: ["melodist.singable-range", "melodist.mostly-steps", "melodist.lands-on-the-chord"],
                       proposal: .writeMelody(rangeSemitones: 12, largestLeapSemitones: 7, stepwiseRatio: 0.8,
                                              chordToneRatio: 0.8, notesPerBar: 4, restRatio: 0.2, motifRatio: 0.4),
                       expects: .agree),
            GoldenTest("melodist.golden.pushes-back",
                       premise: "A tune spanning two octaves and a fourth.",
                       passes: "Refused by melodist.singable-range: move a phrase an octave or split it in two.",
                       exercises: ["melodist.singable-range"],
                       proposal: .writeMelody(rangeSemitones: 29, largestLeapSemitones: 7, stepwiseRatio: 0.8,
                                              chordToneRatio: 0.8, notesPerBar: 4, restRatio: 0.2, motifRatio: 0.4),
                       expects: .refuse(rule: "melodist.singable-range")),
            GoldenTest("melodist.golden.a-leap-too-far",
                       premise: "A leap of a fifteenth in the middle of the phrase.",
                       passes: "Refused by melodist.leap-and-step: come back the other way by step.",
                       exercises: ["melodist.leap-and-step"],
                       proposal: .writeMelody(rangeSemitones: 18, largestLeapSemitones: 25, stepwiseRatio: 0.7,
                                              chordToneRatio: 0.8, notesPerBar: 4, restRatio: 0.2, motifRatio: 0.4),
                       expects: .refuse(rule: "melodist.leap-and-step")),
            GoldenTest("melodist.golden.wonder-leaps",
                       premise: "A tenth as the widest leap, a bare half of the moves steps, everything landing on chord tones — a Wonder-shaped tune put to the general rules.",
                       passes: "Agreed with a caveat: nothing is refused, and the step count is named as close to the floor. "
                             + "This is the tension between the lineages made visible — a tune typical of one of them sits at "
                             + "the edge of a threshold set by another, and the caveat is how the bible says so.",
                       exercises: ["melodist.leap-and-step", "melodist.mostly-steps"],
                       proposal: .writeMelody(rangeSemitones: 16, largestLeapSemitones: 10, stepwiseRatio: 0.55,
                                              chordToneRatio: 0.85, notesPerBar: 5, restRatio: 0.15, motifRatio: 0.35),
                       expects: .caveat),
            GoldenTest("melodist.golden.an-arpeggio",
                       premise: "A line where only a fifth of the moves are steps.",
                       passes: "Refused by melodist.mostly-steps: it is an arpeggio, and nobody sings one back.",
                       exercises: ["melodist.mostly-steps"],
                       proposal: .writeMelody(rangeSemitones: 14, largestLeapSemitones: 7, stepwiseRatio: 0.2,
                                              chordToneRatio: 0.9, notesPerBar: 4, restRatio: 0.2, motifRatio: 0.4),
                       expects: .refuse(rule: "melodist.mostly-steps")),
            GoldenTest("melodist.golden.never-breathes",
                       premise: "Four bars with something sounding on every beat of them.",
                       passes: "Refused by melodist.it-breathes: leave a gap or nobody can sing it.",
                       exercises: ["melodist.it-breathes"],
                       proposal: .writeMelody(rangeSemitones: 12, largestLeapSemitones: 7, stepwiseRatio: 0.8,
                                              chordToneRatio: 0.8, notesPerBar: 4, restRatio: 0, motifRatio: 0.4),
                       expects: .refuse(rule: "melodist.it-breathes")),
            GoldenTest("melodist.golden.a-walk",
                       premise: "A line where no figure is ever heard twice.",
                       passes: "Refused by melodist.a-figure-comes-back: state a cell and bring it back.",
                       exercises: ["melodist.a-figure-comes-back"],
                       proposal: .writeMelody(rangeSemitones: 12, largestLeapSemitones: 7, stepwiseRatio: 0.8,
                                              chordToneRatio: 0.8, notesPerBar: 4, restRatio: 0.2, motifRatio: 0.05),
                       expects: .refuse(rule: "melodist.a-figure-comes-back")),
            GoldenTest("melodist.golden.defers",
                       premise: "\"Put the swing at 62.\"",
                       passes: "Deferred to the Beatmaker rather than answered: the pocket is not the tune.",
                       exercises: [],
                       proposal: .setSwing(percent: 62, idiom: "boom-bap", tempo: 90),
                       expects: .defer_(to: .beatmaker)),
        ],

        openQuestions: [
            OpenQuestion("melodist.oq.motif-by-interval",
                         question: "Is a figure its rhythm and its shape, or its intervals?",
                         encoded: "Its rhythm and its shape: a run of four notes or more whose gaps and directions come "
                                + "again, at any pitch and with steps of any size — Superstition's figure repeats its "
                                + "rhythm while its pitches move. Everything such a figure covers is counted, not only "
                                + "the longest.",
                         alternative: "A figure is its intervals, whatever rhythm they return in: a theme brought back in "
                                    + "longer notes is still the theme. That was the measure here first, as the longest "
                                    + "run of intervals heard twice, and it read a two-bar figure played four times as "
                                    + "a fifth of a tune; as a share of the tune covered it would be worth reading "
                                    + "beside this one.",
                         affects: ["melodist.a-figure-comes-back"],
                         evidence: .cited([superstition, motif])),
            OpenQuestion("melodist.oq.range-is-a-voice",
                         question: "Is nineteen semitones the ceiling, or does it depend on who is singing?",
                         encoded: "Nineteen, an octave and a fifth, from the McCartney range topping out near seventeen.",
                         alternative: "Range is a property of a voice, not of a tune: a trained singer carries two octaves "
                                    + "and an instrument carries whatever it has. The ceiling should come from the take's "
                                    + "measured register when the song has one, and only fall back to a number when it does not.",
                         affects: ["melodist.singable-range", "melodist.range-before-register"],
                         evidence: .cited([vocalRange])),
            OpenQuestion("melodist.oq.instrumental-tunes",
                         question: "Should an instrumental line be held to singable limits at all?",
                         encoded: "Yes: the same thresholds whatever plays it, on the argument that singable is memorable.",
                         alternative: "A synth lead has no breath and no range, and holding a bassline-style riff to a "
                                    + "singer's limits would rule out most of the music this app is for — the rules should "
                                    + "read the part's instrument and relax when nothing has to breathe.",
                         affects: ["melodist.it-breathes", "melodist.singable-range"],
                         evidence: .inferred("the tension between the cited lineages and this app's first idiom")),
            OpenQuestion("melodist.oq.chord-tone-window",
                         question: "Should a note be judged against the chord it starts on, or the one it is sounding over?",
                         encoded: "The chord under its start.",
                         alternative: "A long note held across a change is a suspension over the second chord, which is the "
                                    + "most expressive thing a tune does — judging it only by where it started calls that "
                                    + "correct when it may be the one note to fix, or the reverse.",
                         affects: ["melodist.lands-on-the-chord"],
                         evidence: .cited([contour])),
        ])

    // MARK: - Considering a proposal

    public func consider(_ proposal: PersonaProposal) -> PersonaVerdict {
        RuleEngine.consider(Melodist.bible, proposal)
    }

    // MARK: - Reading a tune

    public func read(_ observation: MelodyObservation) -> [PersonaReading] {
        var notes: [PersonaReading] = []
        guard observation.notes.count >= 2 else {
            notes.append(PersonaReading(rule: "melodist.the-tune-is-yours", feature: .notesPerBar,
                                        value: Double(observation.notes.count), holds: false,
                                        says: observation.notes.isEmpty
                                            ? "No tune yet. Draw a few notes and I'll read the shape."
                                            : "One note is not a tune yet. Give it somewhere to go."))
            return notes
        }

        let range = observation.rangeSemitones
        notes.append(PersonaReading(
            rule: "melodist.singable-range", feature: .melodyRangeSemitones, value: range,
            holds: range <= Melodist.rangeCeiling,
            says: range <= Melodist.rangeCeiling
                ? "\(Int(range)) semitones top to bottom. One voice covers that."
                : "\(Int(range)) semitones top to bottom. Nobody sings both ends of that — move a phrase an octave."))

        let leap = observation.largestLeapSemitones
        notes.append(PersonaReading(
            rule: "melodist.leap-and-step", feature: .largestLeapSemitones, value: leap,
            holds: leap <= Melodist.leapCeiling,
            says: leap <= Melodist.leapCeiling
                ? "The widest leap is \(Int(leap)) semitones."
                : "A leap of \(Int(leap)) semitones. Come back the other way by step, or it is two phrases with a hole between them."))

        let stepwise = observation.stepwiseRatio
        notes.append(PersonaReading(
            rule: "melodist.mostly-steps", feature: .stepwiseRatio, value: stepwise,
            holds: stepwise >= Melodist.stepwiseFloor,
            says: String(format: stepwise >= Melodist.stepwiseFloor
                ? "%.0f%% of the moves are a step."
                : "Only %.0f%% of the moves are a step. That is an arpeggio; walk between the leaps.", stepwise * 100)))

        if !observation.chords.isEmpty {
            let landing = observation.chordToneRatio
            let clash = observation.firstClash
            notes.append(PersonaReading(
                rule: "melodist.lands-on-the-chord", feature: .chordToneRatio, value: landing,
                holds: landing >= Melodist.chordToneFloor,
                says: landing >= Melodist.chordToneFloor
                    ? String(format: "%.0f%% of the notes land on the chord under them.", landing * 100)
                    : String(format: "Only %.0f%% land on the chord under them", landing * 100)
                        + (clash.map { ", starting with the \(observation.key.tonic.pitchClass.distance(to: $0.note.pitch.pitchClass) < 12 ? MelodyObservation.degreeNames[observation.key.tonic.pitchClass.distance(to: $0.note.pitch.pitchClass)] : "note") over \($0.chord.description)" } ?? "")
                        + ". Land the long notes and pass through the rest."))
        }

        // Only a line with room for a figure is read for one: a bed of held chords, or six notes
        // across sixteen bars, is not a tune that forgot to repeat itself.
        if observation.hasRoomForAFigure {
            let motif = observation.motifRatio
            notes.append(PersonaReading(
                rule: "melodist.a-figure-comes-back", feature: .motifRatio, value: motif,
                holds: motif >= Melodist.motifFloor,
                says: motif >= Melodist.motifFloor
                    ? String(format: "A figure comes back: %.0f%% of the tune is something you have heard.", motif * 100)
                    : motif > 0
                        ? String(format: "Only %.0f%% of the tune comes back. State a figure — four notes in a rhythm — and bring it again, moved if you like: that is what a listener sings.", motif * 100)
                        : "Nothing comes back. State a figure — four notes in a rhythm — and bring it again, moved if you like: that is what a listener sings."))
        }

        let rest = observation.restRatio
        notes.append(PersonaReading(
            rule: "melodist.it-breathes", feature: .restRatio, value: rest,
            holds: rest >= Melodist.restFloor,
            says: rest >= Melodist.restFloor
                ? String(format: "It breathes: %.0f%% of it is rest.", rest * 100)
                : "It never stops. Leave a beat somewhere or the phrase has no end."))

        let peak = observation.peakCount
        notes.append(PersonaReading(
            rule: "melodist.one-peak", feature: .peakCount, value: peak,
            holds: peak <= Melodist.peakCeiling,
            says: peak <= Melodist.peakCeiling
                ? "The top note lands \(Int(peak)) time\(peak == 1 ? "" : "s")."
                : "The top note lands \(Int(peak)) times. A ceiling touched that often is a range, not a climax."))

        let perBar = observation.notesPerBar
        notes.append(PersonaReading(
            rule: "melodist.not-too-busy", feature: .notesPerBar, value: perBar,
            holds: perBar <= Melodist.notesPerBarCeiling,
            says: String(format: perBar <= Melodist.notesPerBarCeiling
                ? "%.1f notes a bar."
                : "%.1f notes a bar. Past eight it is a texture, not a tune.", perBar)))

        return notes
    }
}
