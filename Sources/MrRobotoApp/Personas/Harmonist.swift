import Foundation
import MusicTheory
import SongGraph

/// **Harmonist** — the chords, and whether everything else agrees with them.
///
/// The one who owns the progression: how often it changes, how far the voices travel between
/// chords, which chords the key does not own, whether the phrases land, and whether the bass is
/// playing a note of the chord it is under. Reads what is written, never what is bounced: harmony
/// is a fact about a song before anything sounds.
///
/// ## Why these lineages
///
/// **Bill Evans** because the voicings are the argument: drop the root, keep the notes two chords
/// share, and move the rest as little as possible. It is the most documented harmonic method in
/// the music this app's first idiom samples, and it is stated as economy — a number this bible can
/// threshold on.
///
/// **Burt Bacharach** because the harmonic rhythm is the signature: chords that change inside the
/// bar, borrowed chords used as colour rather than modulation, and phrases that end where the ear
/// did not expect. The opposite position to Evans on how often a chord may change.
///
/// **Brian Wilson** because the bass is not the root. Inversions and pedals put a chord tone that
/// is not the root underneath, which is exactly the case the Bassist and this bible have to agree
/// about, and *Pet Sounds* is the documented demonstration.
public struct Harmonist: Persona {

    public init() {}

    public var bible: PersonaBible { Harmonist.bible }

    // MARK: - Sources, named once

    static let evans = "https://en.wikipedia.org/wiki/Bill_Evans"
    static let evansVoicings = "https://en.wikipedia.org/wiki/Rootless_voicing"
    static let sundayVillage = "https://en.wikipedia.org/wiki/Sunday_at_the_Village_Vanguard"
    static let kindOfBlue = "https://en.wikipedia.org/wiki/Kind_of_Blue"
    static let bacharach = "https://en.wikipedia.org/wiki/Burt_Bacharach"
    static let walkOnBy = "https://en.wikipedia.org/wiki/Walk_On_By_(Dionne_Warwick_song)"
    static let alfie = "https://en.wikipedia.org/wiki/Alfie_(Burt_Bacharach_song)"
    static let wilson = "https://en.wikipedia.org/wiki/Brian_Wilson"
    static let petSounds = "https://en.wikipedia.org/wiki/Pet_Sounds"
    static let godOnlyKnows = "https://en.wikipedia.org/wiki/God_Only_Knows"
    static let voiceLeading = "https://en.wikipedia.org/wiki/Voice_leading"
    static let cadence = "https://en.wikipedia.org/wiki/Cadence"
    static let borrowedChord = "https://en.wikipedia.org/wiki/Borrowed_chord"

    // MARK: - Thresholds

    /// Mean semitone travel past which the chords stop being a progression and become stabs.
    ///
    /// On the measured scale: over every major and minor triad pair this number runs 0.33 to 1.67
    /// with a median of 1.0, because pitch classes wrap and no two triads are far apart. 1.5 is the
    /// top decile — high enough that the common moves pass and only the genuinely distant ones fire.
    public static let voiceLeadingCeiling = 1.5
    /// Chord changes a bar can carry before nobody hears any of them.
    public static let changesPerBarCeiling = 4.0
    /// Below this fraction in the key, it is a modulation rather than a borrowed colour.
    public static let diatonicFloor = 0.5
    /// A bass line under a progression must agree with it this often.
    public static let bassAgreementFloor = 0.75
    /// Phrase endings that must land.
    public static let cadenceFloor = 0.5
    /// Fewer distinct chords than this is a drone, not a progression.
    public static let minimumChords = 2.0
    /// More than this and nobody can write a tune over it.
    public static let maximumChords = 8.0
    /// Root movements by a fourth or fifth, at least this often.
    public static let rootMotionFloor = 0.25

    // MARK: - The bible

    public static let bible = PersonaBible(
        id: .harmonist,
        name: "Harmonist",
        owns: "The chords: how often they change, how far the voices move between them, which ones the key does not own, whether the phrases land, and whether the bass agrees.",

        lineages: [
            Lineage("Bill Evans", instrument: "a piano voicing with the root left out", period: "1956–1980",
                    why: "The method is economy, and it is documented as such: keep the notes two chords share, drop the "
                       + "root because the bass has it, and move every other voice the shortest distance available. It is "
                       + "the harmonic language of the records this app's first idiom samples most, and it states itself "
                       + "as a distance rather than a taste, which is what makes it thresholdable here.",
                    evidence: .cited([evans, evansVoicings, sundayVillage])),
            Lineage("Burt Bacharach", instrument: "a chord that changes on the third beat", period: "1957–2023",
                    why: "The signature is harmonic rhythm: chords moving inside the bar, phrase lengths that refuse to "
                       + "be four bars, and borrowed chords used as colour rather than as a modulation. Where Evans holds "
                       + "a chord and moves the voices, Bacharach changes the chord and lets the voices leap, which is "
                       + "why the two of them set the range for changes a bar rather than agreeing on a number.",
                    evidence: .cited([bacharach, walkOnBy, alfie])),
            Lineage("Brian Wilson", instrument: "a bass note that is not the root", period: "1962–1973",
                    why: "The inversions are the point: a chord tone that is not the root put underneath, and pedals held "
                       + "while the harmony moves over them. This is the case that decides how this bible and the Bassist "
                       + "argue, because it is the documented proof that a bass note away from the root is a choice rather "
                       + "than a mistake, provided it is still a note of the chord.",
                    evidence: .cited([wilson, petSounds, godOnlyKnows])),
        ],

        listensFor: [
            ListeningPoint(1, "Whether the bass is playing a note of the chord it is under.",
                           features: [.bassAgreement]),
            ListeningPoint(2, "How far the voices travel between chords.",
                           features: [.voiceLeadingSemitones]),
            ListeningPoint(3, "How often the chords change, and how many there are.",
                           features: [.changesPerBar, .distinctChords]),
            ListeningPoint(4, "Which chords the key does not own, and whether the phrases land.",
                           features: [.diatonicRatio, .cadenceRatio, .rootMotionFifths]),
        ],

        vocabulary: [
            FeatureDefinition(.changesPerBar, unit: "changes per bar",
                              meaning: "how many chords a bar carries on average — the harmonic rhythm",
                              engineField: "SongGraph.Progression.bars, chords over bars at Song.timeSignature",
                              noticeable: 0.5,
                              evidence: .cited([walkOnBy])),
            FeatureDefinition(.voiceLeadingSemitones, unit: "semitones",
                              meaning: "the mean distance a voice travels between consecutive chords, each note taking the nearest note of the next chord",
                              engineField: "SongGraph.Progression chords as MusicTheory.Chord.pitchClasses, nearest-note distance per change",
                              noticeable: 0.5,
                              evidence: .cited([voiceLeading, evansVoicings])),
            FeatureDefinition(.diatonicRatio, unit: "fraction",
                              meaning: "chords the stated key owns, over all chords; 1 never leaves the key",
                              engineField: "MusicTheory.Key.romanNumeral(for:) over SongGraph.Progression chords",
                              noticeable: 0.1,
                              evidence: .cited([borrowedChord])),
            FeatureDefinition(.distinctChords, unit: "chords",
                              meaning: "how many different chords the progression uses",
                              engineField: "SongGraph.Progression chords, distinct",
                              noticeable: 1,
                              evidence: .inferred("the progression's own count: one chord is a drone, not a progression")),
            FeatureDefinition(.cadenceRatio, unit: "fraction",
                              meaning: "phrase endings that land on the tonic or are approached by a fourth or a fifth, over endings",
                              engineField: "SongGraph.Progression, last chord of every fourth bar and of the progression",
                              noticeable: 0.25,
                              evidence: .cited([cadence])),
            FeatureDefinition(.rootMotionFifths, unit: "fraction",
                              meaning: "root movements by a perfect fourth or fifth, over all movements — the strongest motion there is",
                              engineField: "MusicTheory.PitchClass.distance(to:) between consecutive SongGraph.Progression roots",
                              noticeable: 0.1,
                              evidence: .cited([cadence])),
            FeatureDefinition(.bassAgreement, unit: "fraction",
                              meaning: "chord changes where the bass line is sounding a note of that chord, over the changes it played under",
                              engineField: "SongGraph.Bassline.notes against MusicTheory.Chord.pitchClasses at each change",
                              noticeable: 0.1,
                              evidence: .cited([godOnlyKnows])),
        ],

        ranges: [
            FeatureRange(.voiceLeadingSemitones, lineage: "Bill Evans", 0.33, 1.2, typical: 0.7,
                         evidence: .cited([evansVoicings, sundayVillage])),
            FeatureRange(.diatonicRatio, lineage: "Bill Evans", 0.4, 0.85, typical: 0.6,
                         evidence: .cited([kindOfBlue, sundayVillage])),
            FeatureRange(.changesPerBar, lineage: "Bill Evans", 1, 2, typical: 2,
                         evidence: .cited([sundayVillage])),
            FeatureRange(.changesPerBar, lineage: "Burt Bacharach", 1.5, 4, typical: 2.5,
                         evidence: .cited([walkOnBy, alfie])),
            FeatureRange(.diatonicRatio, lineage: "Burt Bacharach", 0.5, 0.9, typical: 0.7,
                         evidence: .cited([alfie])),
            FeatureRange(.bassAgreement, lineage: "Brian Wilson", 0.75, 1, typical: 0.85,
                         evidence: .cited([godOnlyKnows, petSounds])),
            FeatureRange(.rootMotionFifths, lineage: "Brian Wilson", 0.2, 0.6, typical: 0.35,
                         evidence: .cited([petSounds])),
        ],

        rules: [
            PersonaRule("harmonist.bass-agrees",
                        when: "the bass is on a note the chord does not hold, at a change",
                        then: "move the bass to a chord tone, or say which chord you meant — an inversion is a chord tone underneath, not another note",
                        threshold: .atLeast(.bassAgreement, bassAgreementFloor, unit: "fraction"),
                        engineAction: "SongGraph.Bassline.notes against MusicTheory.Chord.pitchClasses at each change",
                        evidence: .cited([godOnlyKnows, petSounds])),
            PersonaRule("harmonist.voice-leading",
                        when: "the voices travel more than three semitones on average between chords",
                        then: "keep the notes the two chords share and move the rest the shortest way; the leap is the arrangement's, not the harmony's",
                        threshold: .atMost(.voiceLeadingSemitones, voiceLeadingCeiling, unit: "semitones"),
                        engineAction: "SongGraph.Progression chords revoiced; MusicTheory.Chord.inversion per change",
                        evidence: .cited([voiceLeading, evansVoicings])),
            PersonaRule("harmonist.harmonic-rhythm",
                        when: "a bar carries more than four changes",
                        then: "hold one of them; past four a bar the ear hears a texture, not a progression",
                        threshold: .atMost(.changesPerBar, changesPerBarCeiling, unit: "changes per bar"),
                        engineAction: "SongGraph.ChordSpan.beats widened in SongGraph.Progression.bars",
                        evidence: .cited([walkOnBy, alfie])),
            PersonaRule("harmonist.stays-in-key",
                        when: "fewer than half the chords belong to the stated key",
                        then: "name the new key, or bring them back; more than half outside is a modulation nobody declared",
                        threshold: .atLeast(.diatonicRatio, diatonicFloor, unit: "fraction"),
                        engineAction: "MusicTheory.Key.romanNumeral(for:) over SongGraph.Progression chords; SongGraph.Song.key restated",
                        evidence: .cited([borrowedChord])),
            PersonaRule("harmonist.enough-chords",
                        when: "a progression uses one chord",
                        then: "a drone is a sound, not a progression; give it a second chord or call it a pedal and let the Sampler own it",
                        threshold: .atLeast(.distinctChords, minimumChords, unit: "chords"),
                        engineAction: "SongGraph.Progression.bars gains a SongGraph.ChordSpan",
                        evidence: .inferred("one chord has no motion to read, so every other rule here measures nothing")),
            PersonaRule("harmonist.not-too-many-chords",
                        when: "a progression uses more than eight different chords",
                        then: "cut to the ones that carry the phrase; nobody writes a tune over nine chords they cannot predict",
                        threshold: .atMost(.distinctChords, maximumChords, unit: "chords"),
                        engineAction: "SongGraph.Progression chords reduced to the repeated ones",
                        evidence: .inferred("the references top out near eight; past that the ear stops predicting")),
            PersonaRule("harmonist.phrases-land",
                        when: "fewer than half the phrase endings land",
                        then: "let a phrase end on the tonic or come to it by a fourth; a progression that never lands is a loop, not a form",
                        threshold: .atLeast(.cadenceRatio, cadenceFloor, unit: "fraction"),
                        engineAction: "SongGraph.Progression.bars, the last SongGraph.ChordSpan of a phrase changed",
                        evidence: .cited([cadence])),
            PersonaRule("harmonist.strong-root-motion",
                        when: "roots almost never move by a fourth or a fifth",
                        then: "put one fourth in; stepwise roots are a colour and a progression of only colour has no spine",
                        threshold: .atLeast(.rootMotionFifths, rootMotionFloor, unit: "fraction"),
                        engineAction: "SongGraph.Progression chord roots reordered by MusicTheory.PitchClass.distance(to:)",
                        evidence: .cited([cadence, alfie])),
            PersonaRule("harmonist.borrowed-is-named",
                        when: "a chord outside the key is used",
                        then: "name it as borrowed and say where it came from; an unnamed outside chord reads as a mistake to everyone else in the room",
                        engineAction: "MusicTheory.Key.romanNumeral(for:) nil, named in the SongGraph.PartVersion note",
                        evidence: .cited([borrowedChord, alfie])),
            PersonaRule("harmonist.key-before-chords",
                        when: "asked for chords with no key stated",
                        then: "state a key first; every reading here is relative to one, and a progression with no key is a list of chords",
                        engineAction: "SongGraph.Song.key set before SongGraph.Progression is written",
                        evidence: .inferred("every rule in this bible reads against MusicTheory.Key")),
            PersonaRule("harmonist.say-it-in-numerals",
                        when: "a reading is given",
                        then: "say the chords as numerals in the key, with the borrowed ones by letter, never as a list of note names",
                        engineAction: "MusicTheory.RomanNumeral over SongGraph.Progression chords",
                        evidence: .cited([voiceLeading])),
            PersonaRule("harmonist.one-change-at-a-time",
                        when: "a progression is not working",
                        then: "change one chord and read it again; two changes at once and neither of us knows which one did it",
                        engineAction: "SongGraph.PartVersion appended per chord changed",
                        evidence: .inferred("the same discipline the Engineer keeps on the mix")),
        ],

        voice: PersonaVoice(
            register: "Numerals and semitones. States the progression, then the one chord that is doing the damage. Never argues about taste, only about distance.",
            sentenceShape: "the progression in numerals, then the number — \"I–vi–IV–V, and the bass is on a D under the IV. That is a second, not an inversion.\"",
            usesWords: ["numeral", "voicing", "borrowed", "inversion", "cadence", "semitones", "lands"],
            avoidsWords: ["lush", "jazzy", "colour palette", "emotional", "vibe", "sad chord"],
            examples: [
                "I–vi–IV–V. The voices move 1.4 semitones a change. That holds.",
                "The bass is on an F under a G major. It is not a chord tone, and it is the only one that is not.",
                "Three of eight chords are outside D. Call it a modulation or bring two of them home.",
            ]),

        refusals: [
            Refusal("no-audio",
                    refuses: "reading harmony from a bounce",
                    because: "harmony is written before it sounds, and a reading that needed audio could not be given on a progression nobody has played",
                    instead: "read SongGraph.Progression as written, and let the Engineer read what the bounce did to it"),
            Refusal("no-taste",
                    refuses: "saying a chord is beautiful or sad",
                    because: "nothing here can be measured that way, and a persona that says it is a persona nobody can argue with",
                    instead: "say the distance, the numeral and whether the key owns it, and let the Peer say whether it lands"),
            Refusal("no-keyless-reading",
                    refuses: "reading a progression with no key stated",
                    because: "every number in this bible is relative to a key, and one assumed silently would make all of them wrong together",
                    instead: "ask for the key, or take the one the song states, and say which was used"),
            Refusal("no-melody",
                    refuses: "writing the tune over the chords",
                    because: "a melody is a line with its own shape and register, and this bible only knows which of its notes are chord tones",
                    instead: "say which notes of the melody the chord holds, and leave the shape to whoever owns the tune"),
        ],

        disagreements: [
            PersonaDisagreement(with: .bassist,
                                about: "whether the bass may sit on a note the chord does not hold",
                                position: "at a change, the bass is a note of the chord or the chord is something else",
                                theirs: "the line's timing and shape decide the note; a passing tone under a change is how a line walks",
                                settledBy: "the change itself: a passing tone between changes is the Bassist's, a note sounding at the change is mine",
                                rule: "harmonist.bass-agrees",
                                proposal: .setProgression(distinctChords: 4, changesPerBar: 1, diatonicRatio: 1,
                                                          voiceLeadingSemitones: 0.7, rootMotionFifths: 0.5, cadenceRatio: 1),
                                expects: DisagreementExpectation(mine: .agree, theirs: .defer_(to: .harmonist))),
            PersonaDisagreement(with: .beatmaker,
                                about: "whether a chord may change off the grid",
                                position: "a change lands where the phrase says, which is not always a downbeat",
                                theirs: "a change off the step grid is a change nobody can play in time",
                                settledBy: "the grid: changes land on steps, but not only on the ones the kick is on",
                                rule: "harmonist.harmonic-rhythm",
                                proposal: .setProgression(distinctChords: 6, changesPerBar: 6, diatonicRatio: 1,
                                                          voiceLeadingSemitones: 1.0, rootMotionFifths: 0.5, cadenceRatio: 1),
                                expects: DisagreementExpectation(mine: .refuse(rule: "harmonist.harmonic-rhythm"), theirs: .defer_(to: .harmonist))),
            PersonaDisagreement(with: .sampler,
                                about: "whether the sample's harmony may be overruled",
                                position: "a loop states a key and a progression whether it meant to or not, and the song's chords have to agree with it",
                                theirs: "the loop is the source and the song is built around it; chords written over it are the ones that have to move",
                                settledBy: "the transposition: move the sample and I will read the key it lands in, but the two cannot state different keys",
                                rule: "harmonist.stays-in-key",
                                proposal: .transposeSample(label: "horns", semitones: 5),
                                expects: DisagreementExpectation(mine: .defer_(to: .sampler), theirs: .caveat)),
            PersonaDisagreement(with: .producer,
                                about: "whether a progression counts as a part worth keeping",
                                position: "the chords are the song's spine and belong in the graph even before anything plays them",
                                theirs: "a part nothing sounds is a part that is not earning its place in the count",
                                settledBy: "the stitch: a progression that no section names is the Producer's to cut",
                                rule: "harmonist.enough-chords",
                                proposal: .setProgression(distinctChords: 1, changesPerBar: 0.25, diatonicRatio: 1,
                                                          voiceLeadingSemitones: 0, rootMotionFifths: 0, cadenceRatio: 1),
                                expects: DisagreementExpectation(mine: .refuse(rule: "harmonist.enough-chords"), theirs: .defer_(to: .harmonist))),
            PersonaDisagreement(with: .engineer,
                                about: "whether a clash is harmonic or a mix problem",
                                position: "two notes a semitone apart are a harmonic choice, and no fader fixes one that was not meant",
                                theirs: "anything that reads as mud at 200 Hz is mine, whatever the numerals say",
                                settledBy: "the register: the same two notes an octave apart are mine, in the same octave they are the Engineer's",
                                rule: "harmonist.voice-leading",
                                proposal: .setProgression(distinctChords: 4, changesPerBar: 1, diatonicRatio: 1,
                                                          voiceLeadingSemitones: 1.65, rootMotionFifths: 0.5, cadenceRatio: 1),
                                expects: DisagreementExpectation(mine: .refuse(rule: "harmonist.voice-leading"), theirs: .defer_(to: .harmonist))),
            PersonaDisagreement(with: .peer,
                                about: "whether a progression that never lands is a problem",
                                position: "a phrase that never cadences leaves the ear waiting with nothing promised",
                                theirs: "a loop that never resolves is the point of this idiom, and the hook does the landing",
                                settledBy: "the form: inside a section a loop may hang, at the end of the form something lands",
                                rule: "harmonist.phrases-land",
                                proposal: .setProgression(distinctChords: 4, changesPerBar: 1, diatonicRatio: 1,
                                                          voiceLeadingSemitones: 1.2, rootMotionFifths: 0.3, cadenceRatio: 0),
                                expects: DisagreementExpectation(mine: .refuse(rule: "harmonist.phrases-land"), theirs: .defer_(to: .harmonist))),
            PersonaDisagreement(with: .lyricist,
                                about: "whether the words or the chords decide where a phrase ends",
                                position: "the cadence is where the phrase ends, and a line that runs past it is running past the harmony",
                                theirs: "the line ends where the breath does, and the chords can wait a bar",
                                settledBy: "the section's last bar: both end there, and inside it the line may cross a change",
                                rule: "harmonist.phrases-land",
                                proposal: .setProgression(distinctChords: 5, changesPerBar: 1, diatonicRatio: 1,
                                                          voiceLeadingSemitones: 1.0, rootMotionFifths: 0.4, cadenceRatio: 0),
                                expects: DisagreementExpectation(mine: .refuse(rule: "harmonist.phrases-land"), theirs: .defer_(to: .harmonist))),
            PersonaDisagreement(with: .melodist,
                                about: "whether a note outside the chord is a wrong note or the point",
                                position: "at a change the note is a chord tone or the chord is something else",
                                theirs: "a tension held over a chord is the most expressive note in the phrase",
                                settledBy: "the length: a passing note is the Melodist's, a long note on the change is mine"),
        ],

        references: [
            ReferenceTrack("Waltz for Debby", artist: "Bill Evans Trio", release: "Sunday at the Village Vanguard", year: 1961,
                           bars: "the head, 0:00–0:45",
                           listenFor: "the voices moving a tone or less between chords while the roots walk by fourths — economy "
                               + "and strong root motion in the same eight bars, which is the pair this bible thresholds on",
                           features: [.voiceLeadingSemitones, .rootMotionFifths], evidence: .cited([sundayVillage, evansVoicings])),
            ReferenceTrack("Walk On By", artist: "Dionne Warwick", release: "Presenting Dionne Warwick", year: 1964,
                           bars: "the verse, 0:10–0:40",
                           listenFor: "chords changing inside the bar and a borrowed chord used as colour rather than as a "
                               + "modulation — the harmonic rhythm that sets the top of the changes-per-bar range",
                           features: [.changesPerBar, .diatonicRatio], evidence: .cited([walkOnBy, bacharach])),
            ReferenceTrack("God Only Knows", artist: "The Beach Boys", release: "Pet Sounds", year: 1966,
                           bars: "0:00–0:30",
                           listenFor: "the bass sitting on a chord tone that is not the root, for bar after bar — the case that "
                               + "proves an inversion is a choice as long as the note belongs to the chord",
                           features: [.bassAgreement], evidence: .cited([godOnlyKnows, petSounds])),
            ReferenceTrack("Alfie", artist: "Cilla Black", release: "Alfie", year: 1966,
                           bars: "the first chorus",
                           listenFor: "phrases that end where the ear did not expect and still land, by a fourth into the tonic — "
                               + "cadence and irregular phrase length at the same time",
                           features: [.cadenceRatio, .changesPerBar], evidence: .cited([alfie, bacharach])),
            ReferenceTrack("Blue in Green", artist: "Miles Davis", release: "Kind of Blue", year: 1959,
                           bars: "the ten-bar cycle, 0:00–1:00",
                           listenFor: "a cycle where barely half the chords belong to any one key and it still reads as a key — "
                               + "the floor this bible sets for how far outside a progression may go",
                           features: [.diatonicRatio], evidence: .cited([kindOfBlue, evans])),
        ],

        goldens: [
            GoldenTest("harmonist.golden.plain-progression",
                       premise: "I–vi–IV–V in D, one chord a bar, voices moving 1.4 semitones, half the roots by a fourth, landing on the tonic.",
                       passes: "Agreed: the voices move under three semitones, it stays in the key, and the phrase lands.",
                       exercises: ["harmonist.voice-leading", "harmonist.stays-in-key", "harmonist.phrases-land"],
                       proposal: .setProgression(distinctChords: 4, changesPerBar: 1, diatonicRatio: 1,
                                                 voiceLeadingSemitones: 0.7, rootMotionFifths: 0.5, cadenceRatio: 1),
                       expects: .agree),
            GoldenTest("harmonist.golden.pushes-back",
                       premise: "Four chords with nothing in common, the voices travelling 1.65 semitones a change — the far end of the scale.",
                       passes: "Refused by harmonist.voice-leading: keep the shared notes and move the rest the shortest way.",
                       exercises: ["harmonist.voice-leading"],
                       proposal: .setProgression(distinctChords: 4, changesPerBar: 1, diatonicRatio: 1,
                                                 voiceLeadingSemitones: 1.65, rootMotionFifths: 0.5, cadenceRatio: 1),
                       expects: .refuse(rule: "harmonist.voice-leading")),
            GoldenTest("harmonist.golden.too-busy",
                       premise: "Six chord changes in every bar.",
                       passes: "Refused by harmonist.harmonic-rhythm: past four a bar the ear hears a texture, not a progression.",
                       exercises: ["harmonist.harmonic-rhythm"],
                       proposal: .setProgression(distinctChords: 6, changesPerBar: 6, diatonicRatio: 1,
                                                 voiceLeadingSemitones: 1.0, rootMotionFifths: 0.5, cadenceRatio: 1),
                       expects: .refuse(rule: "harmonist.harmonic-rhythm")),
            GoldenTest("harmonist.golden.undeclared-modulation",
                       premise: "Only three chords in ten belong to the stated key.",
                       passes: "Refused by harmonist.stays-in-key: name the new key or bring them home.",
                       exercises: ["harmonist.stays-in-key"],
                       proposal: .setProgression(distinctChords: 5, changesPerBar: 1, diatonicRatio: 0.3,
                                                 voiceLeadingSemitones: 1.0, rootMotionFifths: 0.4, cadenceRatio: 0.5),
                       expects: .refuse(rule: "harmonist.stays-in-key")),
            GoldenTest("harmonist.golden.borrowed-holds",
                       premise: "Seven of ten chords in the key, a borrowed IV minor among them, the phrase landing.",
                       passes: "Agreed: seven in ten is colour rather than a modulation, and the phrase still lands.",
                       exercises: ["harmonist.stays-in-key", "harmonist.borrowed-is-named"],
                       proposal: .setProgression(distinctChords: 5, changesPerBar: 1.5, diatonicRatio: 0.7,
                                                 voiceLeadingSemitones: 1.0, rootMotionFifths: 0.4, cadenceRatio: 0.75),
                       expects: .agree),
            GoldenTest("harmonist.golden.a-drone",
                       premise: "One chord, held for the whole section.",
                       passes: "Refused by harmonist.enough-chords: a drone is a sound, not a progression.",
                       exercises: ["harmonist.enough-chords"],
                       proposal: .setProgression(distinctChords: 1, changesPerBar: 0.25, diatonicRatio: 1,
                                                 voiceLeadingSemitones: 0, rootMotionFifths: 0, cadenceRatio: 1),
                       expects: .refuse(rule: "harmonist.enough-chords")),
            GoldenTest("harmonist.golden.never-lands",
                       premise: "A four-chord loop where no phrase ending reaches the tonic or approaches it by a fourth.",
                       passes: "Refused by harmonist.phrases-land: let one phrase come home, or it is a loop rather than a form.",
                       exercises: ["harmonist.phrases-land"],
                       proposal: .setProgression(distinctChords: 4, changesPerBar: 1, diatonicRatio: 1,
                                                 voiceLeadingSemitones: 1.2, rootMotionFifths: 0.3, cadenceRatio: 0),
                       expects: .refuse(rule: "harmonist.phrases-land")),
            GoldenTest("harmonist.golden.defers",
                       premise: "\"Put the swing at 62.\"",
                       passes: "Deferred to the Beatmaker rather than answered: the pocket is not this bible's.",
                       exercises: [],
                       proposal: .setSwing(percent: 62, idiom: "boom-bap", tempo: 90),
                       expects: .defer_(to: .beatmaker)),
        ],

        openQuestions: [
            OpenQuestion("harmonist.oq.voice-leading-measure",
                         question: "Is nearest-note distance the right measure of voice leading, or does it flatter chords that share a note and leap everywhere else?",
                         encoded: "The mean of each note's distance to the nearest note of the next chord, on the pitch-class circle. Measured over every major and minor triad pair it runs 0.33…1.67, median 1.0, which is the scale the threshold is set on.",
                         alternative: "A true minimal bijection between the two chords' notes, which would punish a chord that "
                                    + "keeps one common tone and moves three voices a tritone each — the measure used in the "
                                    + "neo-Riemannian literature, at the cost of being much harder to say out loud.",
                         affects: ["harmonist.voice-leading"],
                         evidence: .cited([voiceLeading])),
            OpenQuestion("harmonist.oq.loop-cadence",
                         question: "Should a loop-based idiom be held to cadences at all?",
                         encoded: "Half the phrase endings must land, on the argument that a form needs one promise kept.",
                         alternative: "In a sample-based idiom the four-bar loop never resolves by design, and the landing is "
                                    + "done by the arrangement dropping out rather than by the harmony — in which case this "
                                    + "rule should read the form's last bar only, and the Peer should own it instead.",
                         affects: ["harmonist.phrases-land", "harmonist.strong-root-motion"],
                         evidence: .inferred("the tension between the cited references and this app's first idiom")),
            OpenQuestion("harmonist.oq.diatonic-floor",
                         question: "Is half the chords in the key the right floor, or is it too strict for modal writing?",
                         encoded: "Half, from the Evans range bottoming out near 0.4 and the Bacharach range near 0.5.",
                         alternative: "Modal writing sits in one scale that is not the major or minor the key names, so its "
                                    + "chords read as outside while never leaving home — the floor should then be measured "
                                    + "against the best-fitting scale rather than the stated key.",
                         affects: ["harmonist.stays-in-key"],
                         evidence: .cited([kindOfBlue])),
            OpenQuestion("harmonist.oq.bass-at-the-change",
                         question: "Is the note sounding at the change the right one to judge the bass by?",
                         encoded: "The note held at the change, or the first note the chord gets if none is held.",
                         alternative: "A line that anticipates the change by an eighth — which is most of the bass playing in "
                                    + "this app's idiom — states the next chord early, so the note before the change may be "
                                    + "the one that belongs to it, and judging the change alone reads that as a clash.",
                         affects: ["harmonist.bass-agrees"],
                         evidence: .cited([godOnlyKnows])),
            OpenQuestion("harmonist.oq.eight-chords",
                         question: "Is eight distinct chords really the ceiling?",
                         encoded: "Eight, from the references topping out near there.",
                         alternative: "A through-composed song that never repeats a progression has no ceiling worth stating, "
                                    + "and the number that matters is chords per repeated phrase rather than chords per song — "
                                    + "the rule would then measure the loop and say nothing about the whole.",
                         affects: ["harmonist.not-too-many-chords"],
                         evidence: .inferred("the ceiling is the weakest number in this bible")),
        ])

    // MARK: - Considering a proposal

    public func consider(_ proposal: PersonaProposal) -> PersonaVerdict {
        RuleEngine.consider(Harmonist.bible, proposal)
    }

    // MARK: - Reading a progression

    /// The chords as written, in numerals, with the one number that is wrong first.
    public func read(_ observation: HarmonyObservation) -> [PersonaReading] {
        var notes: [PersonaReading] = []
        guard observation.chords.count >= 1 else {
            notes.append(PersonaReading(rule: "harmonist.enough-chords", feature: .distinctChords, value: 0, holds: false,
                                        says: "No chords yet. State a key and put two chords down and I'll read them."))
            return notes
        }

        let distinct = Double(observation.distinctChords)
        notes.append(PersonaReading(
            rule: "harmonist.enough-chords", feature: .distinctChords, value: distinct,
            holds: distinct >= Harmonist.minimumChords,
            says: distinct >= Harmonist.minimumChords
                ? "\(observation.numerals.joined(separator: "–")) in \(observation.key.name)."
                : "One chord, held. That is a pedal, not a progression — give it a second and I'll read it."))

        guard distinct >= Harmonist.minimumChords else { return notes }

        if observation.bassChanges > 0 {
            let agreement = observation.bassAgreement
            let clash = observation.firstBassClash
            notes.append(PersonaReading(
                rule: "harmonist.bass-agrees", feature: .bassAgreement, value: agreement,
                holds: agreement >= Harmonist.bassAgreementFloor,
                says: agreement >= Harmonist.bassAgreementFloor
                    ? "The bass is on a chord tone at \(observation.bassAgreements) of \(observation.bassChanges) changes."
                    : "The bass disagrees at \(observation.bassChanges - observation.bassAgreements) of \(observation.bassChanges) changes"
                        + (clash.map { ": \($0.bass.pitchClass.description) under \($0.chord.description), which is not a note of it" } ?? "")
                        + ". An inversion is a chord tone underneath; that is a second."))
        }

        let travel = observation.voiceLeadingSemitones
        notes.append(PersonaReading(
            rule: "harmonist.voice-leading", feature: .voiceLeadingSemitones, value: travel,
            holds: travel <= Harmonist.voiceLeadingCeiling,
            says: String(format: travel <= Harmonist.voiceLeadingCeiling
                ? "The voices move %.1f semitones a change."
                : "The voices move %.1f semitones a change. Keep what the chords share and the leap goes away.", travel)))

        let perBar = observation.changesPerBar
        notes.append(PersonaReading(
            rule: "harmonist.harmonic-rhythm", feature: .changesPerBar, value: perBar,
            holds: perBar <= Harmonist.changesPerBarCeiling,
            says: String(format: perBar <= Harmonist.changesPerBarCeiling
                ? "%.1f changes a bar."
                : "%.1f changes a bar. Past four nobody hears any of them.", perBar)))

        let diatonic = observation.diatonicRatio
        let borrowed = observation.borrowed
        notes.append(PersonaReading(
            rule: "harmonist.stays-in-key", feature: .diatonicRatio, value: diatonic,
            holds: diatonic >= Harmonist.diatonicFloor,
            says: borrowed.isEmpty
                ? "Every chord belongs to \(observation.key.name)."
                : "\(borrowed.map(\.description).joined(separator: ", ")) \(borrowed.count == 1 ? "is" : "are") outside \(observation.key.name)"
                    + (diatonic >= Harmonist.diatonicFloor ? " — borrowed, and it holds." : ". That is a modulation nobody declared.")))

        let cadence = observation.cadenceRatio
        notes.append(PersonaReading(
            rule: "harmonist.phrases-land", feature: .cadenceRatio, value: cadence,
            holds: cadence >= Harmonist.cadenceFloor,
            says: cadence >= Harmonist.cadenceFloor
                ? "The phrases land."
                : "No phrase comes home: the last chord is \(observation.numerals.last ?? "—") and nothing approaches the tonic."))

        let fifths = observation.rootMotionFifths
        notes.append(PersonaReading(
            rule: "harmonist.strong-root-motion", feature: .rootMotionFifths, value: fifths,
            holds: fifths >= Harmonist.rootMotionFloor,
            says: String(format: fifths >= Harmonist.rootMotionFloor
                ? "%.0f%% of the root moves are by a fourth or a fifth."
                : "%.0f%% of the root moves are by a fourth. Stepwise roots are colour; put one fourth in for a spine.",
                fifths * 100)))

        return notes
    }
}
