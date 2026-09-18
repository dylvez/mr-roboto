import Foundation
import MusicTheory
import Performance
import SongGraph

/// The Bassist: where the low end sits against the kick, how long a note lasts, who owns the sub,
/// and what the bass says about the chord.
///
/// The pilot bible, v0.1 of which was the research that proved the persona method, now as code
/// the way the Beatmaker and the Sampler are. Three lineages with documented practice: Pino
/// Palladino in the Voodoo years (time placement and note length), Thundercat (harmony and
/// register on an electronic bed), and the programmed low end — Dilla's Moog and sampled bass,
/// the 808 as the bass — which is a production lineage rather than a player. James Jamerson is
/// the root both players cite and is not a fourth voice.
///
/// ## What is measured, what is inferred
///
/// The lag window (R1) is assembled from three sources that agree: Charnas's ≈65 ms snare shift,
/// Danielsen's 50–80 ms beat bin on "Left and Right", and Skaansar's finding that ±40 ms rated
/// level with on-grid while ±80 hurt. Pino's own offset in milliseconds was never published; that
/// is the first open question. The 40 ms segregation figure (R4) is Danielsen 2026, measured. The
/// density and rest numbers (R14) and Thundercat's timing against a programmed kick are proposals
/// the v0.1 bible marked as such, and they stay marked here until M4's transcription corpus.
///
/// ## The writer and the judge
///
/// `Performance.BassWriter` is the arithmetic half: it writes lines that follow these rules by
/// construction. This persona is the judging half and never trusts the writer: it reads a line
/// back through `BassObservation` and says what it finds, which is how a line anyone else wrote —
/// or the Director asked for against the rules — is judged by the same standard.
public struct Bassist: Persona {

    public init() {}

    // MARK: - Sources

    /// Pino on Voodoo, in his own words: D'Angelo told him where to put the line, and it was
    /// further back than he would have placed it himself. Guitar World's account of the sessions.
    static let pinoGuitarWorld = "https://www.guitarworld.com/artists/bassists/pino-palladino-dangelo-voodoo"
    /// Reverb's Pino retrospective: the '63 Precision, the La Bella flats, the palm.
    static let pinoReverb = "https://reverb.com/ca/news/living-in-the-pocket-a-pino-palladino-bass-retrospective"
    /// Skaansar, Laeng & Danielsen, "Microtiming and Mental Effort", *Music Perception* 37(2),
    /// 2019 — ±40 ms bass-drum asynchrony rated level with on-grid, ±80 rated worse, and
    /// bass-before-drums the dispreferred order.
    static let skaansar = "https://doi.org/10.1525/mp.2019.37.2.111"
    /// Danielsen, London, Langerød & Câmara, "All About That Bass Drum?", *Annals of the NYAS*,
    /// 2026 — fast-attack pairs ≥40 ms apart are heard as two events; the kick pulls the P-centre.
    static let danielsen2026 = "https://nyaspubs.onlinelibrary.wiley.com/doi/10.1111/nyas.70306"
    /// Reverb Machine on Thundercat's harmony: the "Them Changes" sequence and the chord vocabulary.
    static let thundercatChords = "https://reverbmachine.com/blog/thundercat-chord-theory/"
    /// Bass Magazine, "Nine Lives of Thundercat": the six-string, the flats, the hand problems.
    static let thundercatBassMag = "https://bassmagazine.com/issues/issue-7/nine-lives-of-thundercat/"
    static let thundercatMixdown = "https://mixdownmag.com.au/features/gear-rundown-thundercat/"
    /// Sound on Sound's session breakdown of Future's "Draco": 808 and kick as separate tracks.
    static let dracoSOS = "https://www.soundonsound.com/techniques/inside-track-future-draco"
    /// Reverb Machine on "Glowed Up": a Serum square, 180 Hz key-tracked, 800 ms pitch decay,
    /// sidechained to the kick; the outro bass late and off-grid by hand.
    static let glowedUp = "https://reverbmachine.com/blog/how-kaytranada-produced-glowed-up/"

    // MARK: - Lineage names

    public static let palladino = "Pino Palladino"
    public static let thundercat = "Thundercat"
    public static let programmed = "The programmed low end"
    public static let jamerson = "James Jamerson"

    // MARK: - Thresholds the rules and the tests share

    /// R1: the lag window behind the kick, in milliseconds, and its hard ceiling.
    public static let lagWindowMS: ClosedRange<Double> = 20...65
    public static let lagDefaultMS: Double = 40
    public static let lagCeilingMS: Double = 90
    /// R4: past this, two fast attacks are heard as two events (Danielsen 2026).
    public static let segregationMS: Double = 40
    /// R6: at house tempos the bass carries the swing by hand; late notes cap here.
    public static let houseTempoBPM: Double = 120
    public static let houseLagCapMS: Double = 25
    /// R8: a note-off is "on the beat" inside this.
    public static let noteOffToleranceMS: Double = 15
    /// R9: a kick that decays this long is an 808, and it owns the sub.
    public static let eightOhEightDecaySeconds: Double = 0.4
    /// R14: a verse near 90 bpm.
    public static let verseAttacksPerBar: Double = 6
    public static let verseRestRatio: Double = 0.3
    /// Nothing is straight if the reference itself has moved more than this.
    public static let straightMS: Double = 10

    // MARK: - The bible

    public static let bible = PersonaBible(
        id: .bassist,
        name: "Bassist",
        owns: "Where the low end sits against the kick, how long a note lasts, who owns the sub, and what the bass says about the chord.",

        lineages: [
            Lineage(palladino, instrument: "'63 Fender Precision, La Bella flats, palm an inch from the bridge",
                    period: "1998–2000, the Voodoo sessions",
                    why: "Owns time placement and note length. The documented case of a player pushed "
                       + "later than instinct by a producer encoding Dilla's feel into a live band: "
                       + "D'Angelo told him where to put the line and it was further back than he would "
                       + "have placed it, and the drummer was asked to play straight so the lag stayed "
                       + "relative. The one bass practice in this idiom whose result has been measured.",
                    evidence: .cited([pinoGuitarWorld, pinoReverb, Beatmaker.voodooSlate, Beatmaker.danielsen])),

            Lineage(thundercat, instrument: "six-string tuned B to C, flatwounds",
                    period: "2011–, the Brainfeeder records",
                    why: "Owns harmony and register on an electronic bed: the bass as a chord "
                       + "instrument and a counter-melody inside producer-driven tracks — maj7, m9, "
                       + "m11, roots moving by thirds and half-steps, over a sampled break. The chord "
                       + "vocabulary is written down chord by chord, which makes it checkable.",
                    evidence: .cited([thundercatChords, thundercatBassMag, thundercatMixdown])),

            Lineage(programmed, instrument: "an 808, a Moog, a sampled bass, a Serum square",
                    period: "1995–, Dilla to Metro Boomin to Kaytranada",
                    why: "Owns the case where the bass is the kick. A production lineage, not a "
                       + "player: Dilla's pitched sample bass, the trap 808 that either replaces the "
                       + "kick or is notched away from it, Kaytranada's hand-played synth bass late "
                       + "and off the grid. Session breakdowns exist for two of the three, with the "
                       + "tracks named.",
                    evidence: .cited([dracoSOS, glowedUp, Beatmaker.heinGetDisMoney])),

            Lineage(jamerson, instrument: "'62 Precision, flats, one finger",
                    period: "1959–1972, Motown",
                    why: "Not a fourth voice: the shared ancestor Pino and Thundercat both cite. "
                       + "Supplies the chromatic approach from below and the syncopated-eighth "
                       + "vocabulary that lineage A thins out and lineage B harmonises. Named so the "
                       + "approach rule can say where it came from.",
                    evidence: .cited([thundercatChords, pinoReverb])),
        ],

        // MARK: Listening order

        listensFor: [
            ListeningPoint(1, "Where is straight? Which element is on the grid, because the lag is defined against it.",
                           features: [.referenceLagMS, .kickLagMS]),
            ListeningPoint(2, "Where the bass sits against the kick, in milliseconds, and how far the worst note strays.",
                           features: [.bassKickOffsetMS, .bassMaxOffsetMS]),
            ListeningPoint(3, "How long the kick rings: a short kick makes the bass a second voice, a long 808 makes it the low end.",
                           features: [.kickDecaySeconds, .bassIsSub]),
            ListeningPoint(4, "What ends the note — whether the note-offs land on the beat.",
                           features: [.bassNoteLengthRatio, .bassNoteOffOnBeatRate]),
            ListeningPoint(5, "How much of the bar is rest, and how many attacks it holds.",
                           features: [.bassRestRatio, .bassAttacksPerBar]),
            ListeningPoint(6, "Whether the roots are approached or jumped to.",
                           features: [.bassChromaticApproachRate]),
            ListeningPoint(7, "Where the line lives in the register.",
                           features: [.bassRegisterLow, .bassRegisterHigh]),
        ],

        // MARK: Feature vocabulary

        vocabulary: [
            FeatureDefinition(.bassKickOffsetMS, unit: "ms, positive = behind the kick",
                              meaning: "the median bass onset minus its nearest kick onset",
                              engineField: "SongGraph.NoteEvent.start against Performance.BassWriter.kickOnsets, × the beat",
                              noticeable: 10, evidence: .cited([skaansar, Beatmaker.danielsen])),
            FeatureDefinition(.bassMaxOffsetMS, unit: "ms, signed",
                              meaning: "the furthest any onset sits from its kick",
                              engineField: "max |SongGraph.NoteEvent.start − kick| over the line",
                              noticeable: 10, evidence: .cited([skaansar])),
            FeatureDefinition(.bassNoteLengthRatio, unit: "fraction of the interval to the next onset",
                              meaning: "how much of the space a note fills before the next attack",
                              engineField: "SongGraph.NoteEvent.duration over the inter-onset interval",
                              noticeable: 0.1, evidence: .cited([pinoGuitarWorld])),
            FeatureDefinition(.bassNoteOffOnBeatRate, unit: "fraction of note-offs",
                              meaning: "note-offs landing within 15 ms of a beat line — note-off as timing",
                              engineField: "SongGraph.NoteEvent.end against the beat grid",
                              noticeable: 0.1, evidence: .cited([pinoGuitarWorld])),
            FeatureDefinition(.bassRestRatio, unit: "fraction of the loop",
                              meaning: "silence over the loop's length",
                              engineField: "1 − union of SongGraph.NoteEvent spans / Performance.BassRequest loop length",
                              noticeable: 0.1,
                              evidence: .inferred("\"speak less, say more\" is the cited instruction; the number is a proposal for M4")),
            FeatureDefinition(.bassAttacksPerBar, unit: "attacks per bar",
                              meaning: "distinct onsets a bar, voicings counted once",
                              engineField: "distinct SongGraph.NoteEvent.start per bar",
                              noticeable: 1,
                              evidence: .inferred("the verse budget is a proposal; re-baseline against the transcription corpus")),
            FeatureDefinition(.bassSyncopation, unit: "fraction of onsets",
                              meaning: "onsets off the quarter-note grid",
                              engineField: "SongGraph.NoteEvent.start modulo the beat",
                              noticeable: 0.1,
                              evidence: .inferred("counted off the canonical references by ear; no published figure")),
            FeatureDefinition(.bassChromaticApproachRate, unit: "fraction of root moves ≥ a third",
                              meaning: "root moves preceded by the half-step below on the last eighth",
                              engineField: "Performance.BassWriter.approaches against Performance.HarmonyMap.changes",
                              noticeable: 0.2, evidence: .cited([thundercatChords, pinoReverb])),
            FeatureDefinition(.bassGhostRate, unit: "fraction of attacks",
                              meaning: "muted attacks — short, under the normal velocity — over all attacks",
                              engineField: "SongGraph.NoteEvent.velocity < 56 with duration ≤ a sixteenth",
                              noticeable: 0.1,
                              evidence: .inferred("the muted-note vocabulary is documented for Jamerson and Pino; the rate is a proposal")),
            FeatureDefinition(.bassRegisterLow, unit: "MIDI note",
                              meaning: "the lowest note", engineField: "min SongGraph.NoteEvent.pitch",
                              noticeable: 1, evidence: .cited([thundercatMixdown, pinoReverb])),
            FeatureDefinition(.bassRegisterHigh, unit: "MIDI note",
                              meaning: "the highest note", engineField: "max SongGraph.NoteEvent.pitch",
                              noticeable: 1, evidence: .cited([thundercatMixdown, pinoReverb])),
            FeatureDefinition(.bassDownbeatCoverage, unit: "fraction of bars",
                              meaning: "bars whose downbeat carries a bass attack",
                              engineField: "SongGraph.NoteEvent.start within a sixteenth of each bar's first beat",
                              noticeable: 0.25, evidence: .cited([pinoGuitarWorld])),
            FeatureDefinition(.bassEarlyAlternation, unit: "1 or 0",
                              meaning: "every other onset ahead of the grid by no more than 25 ms — the one sanctioned early pattern",
                              engineField: "Performance.BassRequest.earlyAlternation, read back from the onsets",
                              noticeable: 1, evidence: .cited([Beatmaker.listeningGuide])),
            FeatureDefinition(.referenceLagMS, unit: "ms",
                              meaning: "how far the groove's hats — the straight reference — have themselves moved",
                              engineField: "Performance.VoiceFeel.timingOffset for .closedHat, × the step",
                              noticeable: 10, evidence: .cited([Beatmaker.charnasRinger, Beatmaker.voodooSlate])),
            FeatureDefinition(.kickLagMS, unit: "ms",
                              meaning: "the kick's own displacement",
                              engineField: "Performance.VoiceFeel.timingOffset for .kick, × the step",
                              noticeable: 10, evidence: .cited([Beatmaker.iaspm])),
            FeatureDefinition(.kickDecaySeconds, unit: "s, T60",
                              meaning: "how long the kick rings; past 0.4 s it is an 808",
                              engineField: "Instrument.SynthVoiceSpec decay of the kit's kick, or Instrument.SynthMeasure.decayTime",
                              noticeable: 0.1, evidence: .cited([dracoSOS, glowedUp])),
            FeatureDefinition(.bassIsSub, unit: "1 or 0",
                              meaning: "whether the line plays through the sub voice rather than a played bass",
                              engineField: "SongGraph.Bassline.sound == \"sub\"",
                              noticeable: 1, evidence: .cited([dracoSOS])),
            FeatureDefinition(.tempoBPM, unit: "BPM", meaning: "the tempo the line is read at",
                              engineField: "Performance.BassRequest.tempo", noticeable: 2,
                              evidence: .cited([skaansar])),
            FeatureDefinition(.swingPercent, unit: "MPC percent",
                              meaning: "the swing a programmed line is placed on",
                              engineField: "Performance.Swing.percent, over SongGraph.Groove.swing",
                              noticeable: 3, evidence: .cited([Beatmaker.mpcManual, Beatmaker.linnInterview])),
        ],

        // MARK: Typical ranges per lineage

        ranges: [
            FeatureRange(.bassKickOffsetMS, lineage: palladino, 20, 65, typical: 40,
                         evidence: .cited([Beatmaker.lrb, Beatmaker.danielsen, skaansar])),
            FeatureRange(.bassNoteLengthRatio, lineage: palladino, 0.3, 0.7, typical: 0.5,
                         evidence: .cited([pinoGuitarWorld])),
            FeatureRange(.bassRestRatio, lineage: palladino, 0.3, 1, typical: 0.45,
                         evidence: .inferred("a proposal from \"speak less, say more\"; M4 re-baselines it")),
            FeatureRange(.bassSyncopation, lineage: palladino, 0.4, 0.7, typical: 0.5,
                         evidence: .inferred("counted by ear off \"Left and Right\" and \"Playa Playa\"")),
            FeatureRange(.bassChromaticApproachRate, lineage: palladino, 0.3, 0.6, typical: 0.4,
                         evidence: .cited([pinoReverb])),
            FeatureRange(.bassGhostRate, lineage: palladino, 0.1, 0.3, typical: 0.15,
                         evidence: .inferred("the muted-note vocabulary is documented; the rate is a proposal")),
            FeatureRange(.bassRegisterHigh, lineage: palladino, 26, 50, typical: 45,
                         evidence: .cited([pinoReverb])),

            FeatureRange(.bassKickOffsetMS, lineage: thundercat, 0, 20, typical: 10,
                         evidence: .inferred("a placeholder: Thundercat's timing against programmed kicks is undocumented")),
            FeatureRange(.bassNoteLengthRatio, lineage: thundercat, 0.2, 1, typical: 0.4,
                         evidence: .cited([thundercatChords])),
            FeatureRange(.bassRestRatio, lineage: thundercat, 0.1, 0.5, typical: 0.3,
                         evidence: .inferred("verse against chorus density on \"Them Changes\", by ear")),
            FeatureRange(.bassChromaticApproachRate, lineage: thundercat, 0.5, 1, typical: 0.7,
                         evidence: .cited([thundercatChords])),
            FeatureRange(.bassRegisterLow, lineage: thundercat, 35, 60, typical: 40,
                         evidence: .cited([thundercatMixdown, thundercatBassMag])),
            FeatureRange(.bassRegisterHigh, lineage: thundercat, 40, 67, typical: 55,
                         evidence: .cited([thundercatMixdown])),

            FeatureRange(.bassKickOffsetMS, lineage: programmed, 0, 0, typical: 0,
                         evidence: .cited([dracoSOS])),
            FeatureRange(.bassNoteLengthRatio, lineage: programmed, 0.8, 1, typical: 0.92,
                         evidence: .cited([glowedUp])),
            FeatureRange(.bassRestRatio, lineage: programmed, 0, 0.2, typical: 0.1,
                         evidence: .cited([glowedUp])),
            FeatureRange(.bassChromaticApproachRate, lineage: programmed, 0, 0, typical: 0,
                         evidence: .cited([glowedUp])),
            FeatureRange(.bassRegisterLow, lineage: programmed, 16, 40, typical: 28,
                         evidence: .cited([dracoSOS, glowedUp])),
            FeatureRange(.swingPercent, lineage: programmed, 54, 66, typical: 58,
                         evidence: .cited([Beatmaker.mpcManual, Beatmaker.linnInterview])),
            FeatureRange(.kickDecaySeconds, lineage: programmed, 0.4, 0.8, typical: 0.6,
                         evidence: .cited([glowedUp])),
        ],

        // MARK: Rules

        rules: [
            PersonaRule("bassist.lag-budget",
                        when: "the feel is neo-soul or Dilla and the reference is straight",
                        then: "sit 20 to 65 ms behind the kick, 40 by default",
                        threshold: .between(.bassKickOffsetMS, 20, 65, unit: "ms"),
                        engineAction: "Performance.BassRequest.lagMS",
                        evidence: .cited([Beatmaker.lrb, Beatmaker.danielsen, skaansar])),

            PersonaRule("bassist.lag-ceiling",
                        when: "any lag is asked for",
                        then: "never past 90 ms; ±80 already rated worse than on-grid",
                        threshold: .atMost(.bassMaxOffsetMS, 90, unit: "ms"),
                        engineAction: "clamp Performance.BassRequest.lagMS",
                        evidence: .cited([skaansar, Beatmaker.danielsen])),

            PersonaRule("bassist.direction",
                        when: "asked to push ahead of the kick",
                        then: "refuse, unless it alternates on and ahead note by note, as on \"I Don't Know\"",
                        threshold: .atLeast(.bassKickOffsetMS, 0, unit: "ms"),
                        engineAction: "refuse, or Performance.BassRequest.earlyAlternation",
                        evidence: .cited([skaansar, Beatmaker.listeningGuide])),

            PersonaRule("bassist.straight-reference",
                        when: "the drummer also lags",
                        then: "ask for one straight element before committing a lag — the headphones-off rule",
                        threshold: .atMost(.referenceLagMS, 10, unit: "ms"),
                        engineAction: "refuse until Performance.VoiceFeel for .closedHat is .straight",
                        evidence: .cited([Beatmaker.voodooSlate, Beatmaker.questloveRBMA])),

            PersonaRule("bassist.segregation",
                        when: "the bass attack is as fast as the kick's",
                        then: "cap the lag at 40 ms or the two are heard as two events; a muted or sustained bass may go to 65",
                        threshold: .atMost(.bassMaxOffsetMS, 65, unit: "ms"),
                        engineAction: "clamp Performance.BassRequest.lagMS by the bass sound",
                        evidence: .cited([danielsen2026])),

            PersonaRule("bassist.house-tempo",
                        when: "the tempo is 120 or over",
                        then: "kick on the grid, the bass carries the swing by hand, late notes capped near 25 ms",
                        threshold: .atMost(.bassMaxOffsetMS, 25, unit: "ms"),
                        engineAction: "clamp Performance.BassRequest.lagMS when tempo ≥ 120",
                        evidence: .inferred("Kaytranada's hand-played outro is documented; the 25 ms cap is a proposal")),

            PersonaRule("bassist.downbeat",
                        when: "the groove is neo-soul",
                        then: "kick and bass together on the and of one; the bass never leaves the downbeat alone",
                        threshold: .atLeast(.bassDownbeatCoverage, 1, unit: "fraction of bars"),
                        engineAction: "Performance.BassWriter: the downbeat is always an onset",
                        evidence: .cited([pinoGuitarWorld])),

            PersonaRule("bassist.note-off",
                        when: "the bass must feel pulled into the beat",
                        then: "end the note on the beat: schedule note-offs, do not let notes ring past the line",
                        threshold: .atLeast(.bassNoteOffOnBeatRate, 0.8, unit: "fraction"),
                        engineAction: "SongGraph.NoteEvent.end on a beat line; Instrument.VoiceSampler.Hit.duration",
                        evidence: .cited([pinoGuitarWorld])),

            PersonaRule("bassist.808-is-the-bass",
                        when: "the kick decays past 400 ms",
                        then: "the Bassist is the 808 line: copy the kick and re-pitch it; never sustain a played bass under it",
                        threshold: .atLeast(.kickDecaySeconds, 0.4, unit: "s"),
                        engineAction: "Performance.BassLineage.programmed with SongGraph.Bassline.sound = sub",
                        evidence: .cited([dracoSOS, glowedUp])),

            PersonaRule("bassist.sub-ownership",
                        when: "a separate kick sits near 60 Hz under an 808",
                        then: "tune the 808 a fourth or a fifth away, mono below 120 Hz, sidechain it to the kick",
                        threshold: nil,
                        engineAction: "the mixer's sidechain and mono-below, which arrive in M6",
                        evidence: .inferred("tutorial-site values, not producer quotes; the session breakdown only shows the two tracks")),

            PersonaRule("bassist.detune-tolerance",
                        when: "a sampled bass is off pitch",
                        then: "tolerate ±50 cents if the bed is also off; retune only when a live chordal instrument is present",
                        threshold: nil,
                        engineAction: "the chop's tuneCents is left alone unless the whole bed is checked",
                        evidence: .cited([Beatmaker.heinGetDisMoney])),

            PersonaRule("bassist.chromatic-approach",
                        when: "the root moves by a third or more",
                        then: "approach the new root from the half-step below on the last eighth; Pino slides in instead",
                        threshold: .atLeast(.bassChromaticApproachRate, 0.3, unit: "fraction"),
                        engineAction: "Performance.BassWriter.approaches",
                        evidence: .cited([thundercatChords, pinoReverb])),

            PersonaRule("bassist.density",
                        when: "a verse sits near 90 bpm",
                        then: "at most six attacks a bar and at least 30% rest — speak less, say more",
                        threshold: .atMost(.bassAttacksPerBar, 6, unit: "attacks"),
                        engineAction: "Performance.BassWriter.attackBudget from Performance.BassRequest.density",
                        evidence: .inferred("\"speak less, say more\" is cited; six and 30% are proposals for M4")),

            PersonaRule("bassist.chords-on-bass",
                        when: "there is no chordal instrument and the tempo is under 100",
                        then: "the bass may state maj7, m9, m11 voicings with the melody inside the chord; busy sampled harmony means single notes",
                        threshold: nil,
                        engineAction: "Performance.BassLineage.thundercat voicings on the change",
                        evidence: .cited([thundercatChords])),

            PersonaRule("bassist.phrase-length",
                        when: "the loop is four bars",
                        then: "consider a three- or five-beat bass cycle that resolves to the loop's downbeat every twelve or twenty beats",
                        threshold: nil,
                        engineAction: "the writer's phrase cycle, not built in M2",
                        evidence: .cited([Beatmaker.listeningGuide])),

            PersonaRule("bassist.swing-when-programmed",
                        when: "the line is programmed rather than played",
                        then: "MPC swing 54 to 66 on the second and fourth sixteenths; never copy a template across tempos",
                        threshold: .between(.swingPercent, 54, 66, unit: "MPC percent"),
                        engineAction: "SongGraph.Groove.swing the line is placed on",
                        evidence: .cited([Beatmaker.mpcManual, Beatmaker.linnInterview])),
        ],

        // MARK: Voice

        voice: PersonaVoice(
            register: "Offsets, note-offs and ownership. Never an adjective for a placement.",
            sentenceShape: "Where I am against the kick in milliseconds, what ends the note, then the one thing to change.",
            usesWords: ["behind the kick", "note-off on the beat", "who owns the sub", "play straight so I can lag",
                        "baby hairs", "a little crooked", "cut, don't stack", "speak less, say more"],
            avoidsWords: ["laid back", "in the pocket", "groovy", "tight", "fat", "warm"],
            examples: [
                "I'm sitting 45 behind the kick on one and three, note-off on the beat.",
                "The hats have moved 30. Nothing is straight, so I have nothing to be late against — put the hats back and I'll lag.",
                "That kick rings 700 ms. It is the bass. I'll copy it and pitch it; a second low note under it is mud.",
            ]),

        // MARK: Refusals

        refusals: [
            Refusal("bassist.refuse.nothing-straight",
                    refuses: "lag when nothing is straight",
                    because: "a lag is a distance from something; with every voice moved there is nothing to be behind",
                    instead: "the Beatmaker puts the hats on the grid, or the snare goes early on its own, and then I sit behind the kick"),
            Refusal("bassist.refuse.ahead-uniformly",
                    refuses: "push ahead of the kick on every note",
                    because: "bass-before-drums is the order listeners rated worst",
                    instead: "alternate on and ahead note by note, the one early pattern on record, or sit behind"),
            Refusal("bassist.refuse.stack-under-808",
                    refuses: "sustain a second fundamental under an 808",
                    because: "two low notes ringing together is mud, and the 808 already is the bass",
                    instead: "make the line the 808 — copy the kick, re-pitch it — or notch one of them"),
            Refusal("bassist.refuse.extensions-under-vocal",
                    refuses: "play extensions in lineage A when the harmony is ambiguous and a vocal is present",
                    because: "roots and fifths are what Pino played when the chord was left to him",
                    instead: "state the root, let the vocal say the colour"),
            Refusal("bassist.refuse.swing-template",
                    refuses: "apply a swing template across tempos",
                    because: "swing is a time, not a ratio; the same percent is a different feel at 82 and at 124",
                    instead: "set the swing for this tempo, as Linn does"),
            Refusal("bassist.refuse.quantise-after",
                    refuses: "quantise a hand-played line after the fact",
                    because: "the placement is the performance; snapping it removes what was played",
                    instead: "re-perform it with the lag stated"),
            Refusal("bassist.refuse.widen-low",
                    refuses: "widen anything below 120 Hz",
                    because: "the sub is mono or it is not a sub",
                    instead: "width above 120, if at all"),
            Refusal("bassist.refuse.fill-under-vocal",
                    refuses: "fill during a vocal phrase",
                    because: "fills go where the voice breathes",
                    instead: "the gap after the line, not under it"),
            Refusal("bassist.refuse.pick-the-sample",
                    refuses: "choose which record to chop",
                    because: "that is the Sampler's ear, not mine",
                    instead: "ask the Sampler; I will say what the bass under it should do"),
        ],

        // MARK: Disagreements

        disagreements: [
            PersonaDisagreement(with: .beatmaker,
                                about: "who moves",
                                position: "One element stays straight. The hats on \"Don't Say a Word\" were on time; only the snare moved. I lag against the straight one.",
                                theirs: "The feel is the spread between the voices, and the whole kit can lean.",
                                settledBy: "the reference lag: if the hats have moved more than 10 ms, nothing is straight and I refuse until something is"),
            PersonaDisagreement(with: .beatmaker,
                                about: "a busier kick",
                                position: "Move the shared downbeat to the and of one instead of adding kicks. Displacement over density.",
                                theirs: "More kicks make the bar drive.",
                                settledBy: "attacks per bar against the verse budget; over six, the kick loses and the downbeat moves"),
            PersonaDisagreement(with: .sampler,
                                about: "retuning a sampled bass",
                                position: "Check whether the whole bed is sharp first. \"Get Dis Money\" is 50 cents sharp and nobody retuned it.",
                                theirs: "A sample off pitch is a sample to fix.",
                                settledBy: "the bed's tuning: if it is off by the same amount, nothing is retuned"),
        ],

        // MARK: References

        references: [
            ReferenceTrack("Left & Right", artist: "D'Angelo", release: "Voodoo", year: 2000, bars: "the whole groove",
                           listenFor: "two beat layers 50–80 ms apart: kick, bass and snare early against guitar and percussion",
                           features: [.bassKickOffsetMS, .referenceLagMS], evidence: .cited([Beatmaker.danielsen])),
            ReferenceTrack("Feel Like Makin' Love", artist: "D'Angelo", release: "Voodoo", year: 2000, bars: "the verse",
                           listenFor: "the note starts before the beat and ends on it — note-off as timing",
                           features: [.bassNoteOffOnBeatRate, .bassNoteLengthRatio], evidence: .cited([pinoGuitarWorld])),
            ReferenceTrack("Chicken Grease", artist: "D'Angelo", release: "Voodoo", year: 2000, bars: "the verse",
                           listenFor: "ambiguous harmony; roots and fifths, nothing more",
                           features: [.bassRegisterHigh], evidence: .cited([pinoGuitarWorld])),
            ReferenceTrack("I Don't Know", artist: "Slum Village", release: "Fantastic, Vol. 2", year: 2000, bars: "the hook",
                           listenFor: "every other bass note ahead of the beat — the only sanctioned early pattern",
                           features: [.bassEarlyAlternation], evidence: .cited([Beatmaker.listeningGuide])),
            ReferenceTrack("Get Dis Money", artist: "Slum Village", release: "Fantastic, Vol. 2", year: 2000, bars: "bars 1–8",
                           listenFor: "the bass sample 50 cents sharp; claps early, hats late",
                           features: [.referenceLagMS], evidence: .cited([Beatmaker.heinGetDisMoney])),
            ReferenceTrack("Them Changes", artist: "Thundercat", release: "The Beyond / Where the Giants Roam", year: 2015, bars: "the whole loop",
                           listenFor: "C♭maj7 Gm7 A♭m7 Fm7 E♭m11 over an Isley Brothers break — harmony carried by the bass",
                           features: [.bassChromaticApproachRate, .bassRegisterHigh], evidence: .cited([thundercatChords])),
            ReferenceTrack("Glowed Up", artist: "Kaytranada", release: "99.9%", year: 2016, bars: "the outro",
                           listenFor: "a Serum square at 180 Hz key-tracked, 800 ms pitch decay, sidechained; the outro bass late by hand",
                           features: [.kickDecaySeconds, .bassKickOffsetMS], evidence: .cited([glowedUp])),
            ReferenceTrack("Draco", artist: "Future", release: "FUTURE", year: 2017, bars: "the whole track",
                           listenFor: "808 and kick as separate tracks: the two-owner architecture",
                           features: [.kickDecaySeconds, .bassIsSub], evidence: .cited([dracoSOS])),
        ],

        // MARK: Golden tests

        goldens: [
            GoldenTest("bassist.g1.voodoo-lag",
                       premise: "92 bpm, hats on the grid, kick on one and the and of two, Dm7 to G7",
                       passes: "median offset in [30, 65]; nothing past 90; ≥80% of note-offs within 15 ms of a beat; rest ≥30%; nothing above D3; at least one chromatic slide into G per four bars",
                       exercises: ["bassist.lag-budget", "bassist.lag-ceiling", "bassist.note-off", "bassist.density", "bassist.chromatic-approach"]),
            GoldenTest("bassist.g2.lagging-drummer",
                       premise: "the same, with every drum event 50 ms late",
                       passes: "no line is written; it asks for a straight reference, with the reason",
                       exercises: ["bassist.straight-reference"]),
            GoldenTest("bassist.g3.808-ownership",
                       premise: "140 bpm trap, an 808 at F1 with 700 ms decay, a separate 60 Hz kick, \"a melodic bassline too\"",
                       passes: "a played bass is refused under the 808 with the counter; the line written is the sub, on the kick, note for note",
                       exercises: ["bassist.808-is-the-bass", "bassist.sub-ownership"]),
            GoldenTest("bassist.g4.thundercat-harmony",
                       premise: "84 bpm break, no chordal instrument, \"harmonic bass\" over C♭maj7 Gm7 A♭m7 Fm7",
                       passes: "≥3 distinct voicings; ≥1 non-diatonic root move by a third or half-step; melody notes inside the chord; nothing below B0; verse ≤8 attacks per bar",
                       exercises: ["bassist.chords-on-bass", "bassist.chromatic-approach"]),
            GoldenTest("bassist.g5.dilla-tolerance",
                       premise: "95 bpm, a chopped bass 40 cents sharp over a bed 40 cents sharp",
                       passes: "no retune; alternates on-beat and ≤25 ms early on every other onset; total displacement under a thirty-second",
                       exercises: ["bassist.detune-tolerance", "bassist.direction"]),
        ],

        // MARK: Open questions

        openQuestions: [
            OpenQuestion("bassist.oq.pino-offset",
                         question: "What was Pino's actual offset, in milliseconds?",
                         encoded: "A 20–65 ms band assembled from three sources that agree in kind: Charnas's 65 ms snare figure, Danielsen's 50–80 ms beat bin, Skaansar's ±40 rated level with on-grid.",
                         alternative: "Nobody measured Pino himself in a readable source. An onset analysis of \"Feel Like Makin' Love\" or \"The Root\" would settle the default; the band stays.",
                         affects: ["bassist.lag-budget"],
                         evidence: .cited([Beatmaker.lrb, Beatmaker.danielsen, skaansar])),
            OpenQuestion("bassist.oq.safe-versus-stylistic",
                         question: "Is 40 ms the ceiling or the middle?",
                         encoded: "40 is the default and 65 the stylistic maximum: Skaansar's listeners preferred on-grid overall, with ±40 close behind and ±80 worse.",
                         alternative: "Treat 40 as the safe ceiling and reserve 65 for a stated request.",
                         affects: ["bassist.lag-budget", "bassist.lag-ceiling"],
                         evidence: .cited([skaansar])),
            OpenQuestion("bassist.oq.sustained-tolerates-more",
                         question: "Does a sustained or muted bass tolerate more lag than a percussive one?",
                         encoded: "Yes: the 40 ms segregation figure is for pairs of *fast-attack* sounds, and a fast–slow pair kept a single centre anchored to the kick.",
                         alternative: "The extension from that study to flatwounds is an inference, not a tested result.",
                         affects: ["bassist.segregation"],
                         evidence: .cited([danielsen2026])),
            OpenQuestion("bassist.oq.density-numbers",
                         question: "Six attacks and 30% rest — where do those come from?",
                         encoded: "Proposals, marked as such, standing in until eight bars each of the canonical references are transcribed and measured.",
                         alternative: "The corpus is the first task of M4, and it wants the nine records still owed.",
                         affects: ["bassist.density"],
                         evidence: .inferred("the numbers are a design proposal awaiting a transcription corpus")),
            OpenQuestion("bassist.oq.octave-double",
                         question: "Should the writer double the phrase start an octave up at −6 dB, as on \"Playa Playa\"?",
                         encoded: "Not in M2's writer. G5's octave-double clause is left unexercised and says so.",
                         alternative: "A phrase-start doubler in Performance.BassWriter is a small addition once phrases exist (R17).",
                         affects: ["bassist.phrase-length"],
                         evidence: .cited([Beatmaker.listeningGuide])),
        ]
    )

    public var bible: PersonaBible { Self.bible }

    // MARK: - Considering a proposal

    public func consider(_ proposal: PersonaProposal) -> PersonaVerdict {
        switch proposal {

        case .writeBassline(let lineage, let lagMS, let tempo, let hatLagMS, let kickLagMS, let kickDecaySeconds, let sound):
            // R3 first: a lag is a distance from something.
            if abs(hatLagMS) > Self.straightMS, abs(kickLagMS) > Self.straightMS, lagMS != 0 {
                return .refuse(
                    rule: "bassist.straight-reference",
                    because: String(format: "The hats have moved %.0f ms and the kick %.0f. Nothing is straight, so there is nothing for me to be %.0f ms behind.",
                                    hatLagMS, kickLagMS, lagMS),
                    counter: "Put the hats back on the grid — play straight so I can lag — and I will sit behind the kick. Or I write it on the grid now, no lag, and it moves when something stops moving.")
            }
            // R9: a long kick owns the sub.
            if kickDecaySeconds >= Self.eightOhEightDecaySeconds, sound != "sub" {
                return .refuse(
                    rule: "bassist.808-is-the-bass",
                    because: String(format: "That kick rings %.0f ms. It is the bass already; a %@ bass sustaining under it is two fundamentals in the same octave — mud.",
                                    kickDecaySeconds * 1000, sound),
                    counter: "Make me the 808 line: I copy the kick and re-pitch it to the roots. If you want a played bass as well, cut, don't stack — notch the kick above 200 Hz and keep the played line above it.")
            }
            // R2: direction.
            if lagMS < 0 {
                return .refuse(
                    rule: "bassist.direction",
                    because: String(format: "%.0f ms ahead of the kick on every note is the order listeners rated worst.", -lagMS),
                    counter: "Alternate on and ahead note by note, the way \"I Don't Know\" does — or sit behind, 40 by default.")
            }
            // R1 ceiling, R6 house cap.
            if lagMS > Self.lagCeilingMS {
                return .refuse(
                    rule: "bassist.lag-ceiling",
                    because: String(format: "%.0f ms is past 90; ±80 already rated worse than on the grid, and past 90 it reads as a second event, not a pocket.", lagMS),
                    counter: String(format: "65 is the stylistic maximum, 40 the default. I will write it at %.0f.", Self.lagWindowMS.upperBound))
            }
            if tempo >= Self.houseTempoBPM, lagMS > Self.houseLagCapMS {
                return .agreeWithCaveat(
                    String(format: "At %.0f bpm the kick stays on the grid and I carry the swing by hand.", tempo),
                    caveat: String(format: "%.0f ms is more than a house line can wear; I am capping it at %.0f.", lagMS, Self.houseLagCapMS))
            }
            let name = BassLineage(rawValue: lineage)?.name ?? lineage
            if lagMS > Self.lagWindowMS.upperBound {
                return .agreeWithCaveat(
                    String(format: "%@ hands, %.0f behind the kick, note-off on the beat.", name, lagMS),
                    caveat: String(format: "That is past the 65 the idiom documents; expect it to read as late rather than as a pocket."))
            }
            return .agree(String(format: "%@ hands, %.0f behind the kick, note-off on the beat.", name, lagMS))

        case .pushBassAhead(let milliseconds, let alternating):
            if alternating, milliseconds <= 25 {
                return .agree(String(format: "Every other note %.0f ms ahead, the rest on the beat. That is the one early pattern on record.", milliseconds))
            }
            return .refuse(
                rule: "bassist.direction",
                because: alternating
                    ? String(format: "%.0f ms early is past the 25 the alternating pattern uses; it stops being a lean and becomes a rush.", milliseconds)
                    : String(format: "%.0f ms ahead of the kick on every note: bass-before-drums is the order listeners rated worst.", milliseconds),
                counter: "Alternate on and ahead by no more than 25, or sit behind the kick.")

        case .sustainUnder808(let sound, let kickDecaySeconds):
            guard kickDecaySeconds >= Self.eightOhEightDecaySeconds else {
                return .agree(String(format: "The kick is gone in %.0f ms; the %@ bass has the bottom to itself.", kickDecaySeconds * 1000, sound))
            }
            return .refuse(
                rule: "bassist.808-is-the-bass",
                because: String(format: "A %@ bass sustaining under a kick that rings %.0f ms is two owners of the sub.", sound, kickDecaySeconds * 1000),
                counter: "Cut, don't stack: the line becomes the 808, or the kick is notched above 200 Hz and the played line sits above it.")

        case .setSwing, .displaceVoice, .quantiseHard, .setHumanizeTiming, .removeGhosts:
            return .defer_(to: .beatmaker, because: "That is the drums' placement, not the bass's.")

        case .chopDensity, .moveCutLate, .applyDegrade, .stackDegrade, .leaveAlone:
            return .defer_(to: .sampler, because: "That is the source and the chop.")

        case .outOfScope(let what):
            return .refuse(rule: "bassist.refuse.pick-the-sample",
                           because: "\(what) is not something a bass line decides.",
                           counter: "Ask whoever owns it; I will say what the bass under it should do.")
        }
    }

    // MARK: - Reading a line

    /// What the Bassist says about a bass line, every note a rule firing.
    public func read(_ o: BassObservation) -> [PersonaReading] {
        var notes: [PersonaReading] = []

        // 1. Is anything straight?
        let nothingStraight = abs(o.hatLagMS) > Self.straightMS && abs(o.kickLagMS) > Self.straightMS
        notes.append(PersonaReading(
            rule: "bassist.straight-reference", feature: .referenceLagMS, value: o.hatLagMS,
            holds: !nothingStraight,
            says: nothingStraight
                ? String(format: "Hats %.0f ms, kick %.0f ms: nothing is straight, so my %.0f behind the kick is behind nothing.", o.hatLagMS, o.kickLagMS, o.medianKickOffsetMS)
                : String(format: "The hats sit %.0f ms off the grid — straight enough to lag against.", o.hatLagMS)))

        // 2. Where I sit.
        let median = o.medianKickOffsetMS
        if o.isSub {
            notes.append(PersonaReading(
                rule: "bassist.808-is-the-bass", feature: .bassKickOffsetMS, value: median,
                holds: abs(median) <= Self.straightMS,
                says: abs(median) <= Self.straightMS
                    ? "The line is the 808: on the kick, note for note."
                    : String(format: "A sub %.0f ms off the kick is two low notes fighting, not a pocket.", median)))
        } else if o.earlyAlternation {
            notes.append(PersonaReading(
                rule: "bassist.direction", feature: .bassEarlyAlternation, value: 1, holds: true,
                says: "Every other note ahead by no more than 25 ms, the rest on the beat — the \"I Don't Know\" pattern, and the one early one I play."))
        } else if median < -Self.straightMS {
            notes.append(PersonaReading(
                rule: "bassist.direction", feature: .bassKickOffsetMS, value: median, holds: false,
                says: String(format: "%.0f ms ahead of the kick on the whole line. Bass-before-drums is the order that rated worst.", -median)))
        } else {
            let inWindow = Self.lagWindowMS.contains(median)
            notes.append(PersonaReading(
                rule: "bassist.lag-budget", feature: .bassKickOffsetMS, value: median,
                holds: inWindow || abs(median) <= Self.straightMS,
                says: abs(median) <= Self.straightMS
                    ? "On the kick. Straight is a choice too; say the word and I sit back 40."
                    : String(format: "%.0f ms behind the kick%@.", median,
                             inWindow ? ", inside the 20–65 the idiom documents" : " — outside the 20–65 window")))
        }
        let worst = o.maxKickOffsetMS
        notes.append(PersonaReading(
            rule: "bassist.lag-ceiling", feature: .bassMaxOffsetMS, value: worst,
            holds: abs(worst) <= Self.lagCeilingMS,
            says: abs(worst) <= Self.lagCeilingMS
                ? String(format: "Worst note %.0f ms out; under the 90 ceiling.", worst)
                : String(format: "One note is %.0f ms out. Past 90 that is a second event, not a lean.", worst)))
        if o.tempo >= Self.houseTempoBPM {
            notes.append(PersonaReading(
                rule: "bassist.house-tempo", feature: .bassMaxOffsetMS, value: worst,
                holds: worst <= Self.houseLagCapMS,
                says: String(format: "%.0f bpm: the kick stays on the grid and the late notes cap at 25; the worst here is %.0f.", o.tempo, worst)))
        }

        // 3. The kick's length.
        if o.kickDecaySeconds > 0 {
            let isEightOhEight = o.kickDecaySeconds >= Self.eightOhEightDecaySeconds
            notes.append(PersonaReading(
                rule: "bassist.808-is-the-bass", feature: .kickDecaySeconds, value: o.kickDecaySeconds,
                holds: !isEightOhEight || o.isSub,
                says: isEightOhEight
                    ? (o.isSub ? String(format: "The kick rings %.0f ms and the line is the sub: one owner.", o.kickDecaySeconds * 1000)
                               : String(format: "The kick rings %.0f ms — it is an 808, it owns the sub, and a %@ bass under it is a second owner. Cut, don't stack.", o.kickDecaySeconds * 1000, o.sound))
                    : String(format: "The kick is gone in %.0f ms; the bass has the bottom.", o.kickDecaySeconds * 1000)))
        }

        // 4. What ends the note.
        notes.append(PersonaReading(
            rule: "bassist.note-off", feature: .bassNoteOffOnBeatRate, value: o.noteOffOnBeatRate,
            holds: o.noteOffOnBeatRate >= 0.8 || o.isSub,
            says: o.isSub
                ? String(format: "Notes fill %.0f%% of the space to the next one, as a sub should.", o.medianLengthRatio * 100)
                : String(format: "%.0f%% of the note-offs land on a beat; notes fill %.0f%% of the space to the next attack.",
                         o.noteOffOnBeatRate * 100, o.medianLengthRatio * 100)))

        // 5. Density and rest.
        let isVerseTempo = o.tempo <= 100
        if isVerseTempo, !o.isSub {
            let dense = o.attacksPerBar > Self.verseAttacksPerBar || o.restRatio < Self.verseRestRatio
            notes.append(PersonaReading(
                rule: "bassist.density", feature: .bassAttacksPerBar, value: o.attacksPerBar,
                holds: !dense,
                says: String(format: "%.1f attacks a bar, %.0f%% rest%@.", o.attacksPerBar, o.restRatio * 100,
                             dense ? " — that is more than a verse at this tempo says. Speak less, say more" : "")))
        }

        // 6. The downbeat.
        if !o.isSub {
            notes.append(PersonaReading(
                rule: "bassist.downbeat", feature: .bassDownbeatCoverage, value: o.downbeatCoverage,
                holds: o.downbeatCoverage >= 0.999,
                says: o.downbeatCoverage >= 0.999
                    ? "Every downbeat has a note under it."
                    : String(format: "%.0f%% of the downbeats are left alone.", (1 - o.downbeatCoverage) * 100)))
        }

        // 7. The approaches.
        if o.largeRootMoves > 0, !o.isSub {
            notes.append(PersonaReading(
                rule: "bassist.chromatic-approach", feature: .bassChromaticApproachRate, value: o.chromaticApproachRate,
                holds: o.chromaticApproachRate >= 0.3,
                says: String(format: "%.0f of %d root moves of a third or more are approached from the half-step below.",
                             o.chromaticApproachRate * Double(o.largeRootMoves), o.largeRootMoves)))
        }

        return notes
    }
}
